//! Sessions, spaces, Metal swapchains, the frame loop and a first answer to actions
//! (ROADMAP W15, 15.1): what makes the runtime show an application's frames in Halliday.
//!
//! The runtime lives in the application's process; Halliday.app owns the headset. The two meet
//! in the file the Windows games' runtime already uses (`halliday-bridge`): this side is the
//! native [`GameSide`]. So to Halliday an OpenXR application is one more game: it appears with
//! its first frame, Halliday can come up over it, and it is asked to quit the same way.
//!
//! - `xrWaitFrame` waits for Halliday's next display frame and takes the head's pose with it.
//! - `xrLocateViews` and `xrLocateSpace` answer from that pose. STAGE is Halliday's own space
//!   (the floor at y = 0); LOCAL is where the head was, and the way it faced, at the session's
//!   first frame; VIEW is the head.
//! - Swapchains are Metal textures on the application's own device (`XR_KHR_metal_enable`).
//! - `xrEndFrame` reads each eye's rectangle of the first projection layer back (a copy on the
//!   application's queue, behind its own drawing) into the bridge, with the pose the frame was
//!   drawn for, which Halliday reprojects from. A copy through memory, as the games' fallback
//!   is: sharing the textures themselves (IOSurface) comes next.
//! - Actions are taken and answered as inactive; an action space is the hand's pose Halliday
//!   publishes. The controllers' buttons are 15.2.
//!
//! One session at a time. Written from the OpenXR specification; types from `openxr-sys`.

use std::collections::{HashMap, VecDeque};
use std::ffi::{CStr, c_char, c_void};
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::vulkan::{
    ReadbackRequest, hxvk_destroy_context, hxvk_destroy_image, hxvk_image, hxvk_image_handle,
    hxvk_prepare_image, hxvk_read_batch,
};
use halliday_bridge as bridge;
use halliday_core::game_bridge::{Config, GameSide, PanelImage};
use openxr_sys as xr;
use openxr_sys::Handle;
use openxr_sys::pfn;

#[path = "projection_geometry.rs"]
mod projection_geometry;

unsafe extern "C" {
    fn hx_default_device() -> *mut c_void;
    fn hx_queue_device(queue: *mut c_void) -> *mut c_void;
    fn hx_retain(object: *mut c_void) -> *mut c_void;
    fn hx_release(object: *mut c_void);
    fn hx_texture(
        device: *mut c_void,
        format: u64,
        width: u32,
        height: u32,
        layers: u32,
        samples: u32,
        usage: u64,
    ) -> *mut c_void;
    fn hx_buffer(device: *mut c_void, bytes: u64) -> *mut c_void;
    #[allow(clippy::too_many_arguments)]
    fn hx_read_batch(
        queue: *mut c_void,
        scratch: *mut c_void,
        reads: *const ReadbackRequest,
        count: u32,
    ) -> i32;
}

/// Metal's pixel formats the swapchains are offered in, the ones first that hold what the
/// bridge carries (8 bits, sRGB-encoded): `MTLPixelFormatBGRA8Unorm_sRGB`, `RGBA8Unorm_sRGB`,
/// `BGRA8Unorm`, `RGBA8Unorm`.
const FORMATS: [i64; 4] = [81, 71, 80, 70];
const VULKAN_FORMATS: [i64; 4] = [50, 43, 44, 37];
/// Images in a swapchain.
const IMAGES: usize = 3;
/// How far ahead of `xrWaitFrame`'s return a frame is shown: two display frames, as the games'
/// runtime has it.
const FRAMES_AHEAD: f64 = 2.0;

const IDENTITY: xr::Posef = xr::Posef {
    orientation: xr::Quaternionf {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 1.0,
    },
    position: xr::Vector3f {
        x: 0.0,
        y: 0.0,
        z: 0.0,
    },
};

fn rotate(q: xr::Quaternionf, v: xr::Vector3f) -> xr::Vector3f {
    // v + 2w(u × v) + 2u × (u × v)
    let u = [q.x, q.y, q.z];
    let v = [v.x, v.y, v.z];
    let cross = |a: [f32; 3], b: [f32; 3]| {
        [
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        ]
    };
    let t = cross(u, v).map(|c| 2.0 * c);
    let c = cross(u, t);
    xr::Vector3f {
        x: v[0] + q.w * t[0] + c[0],
        y: v[1] + q.w * t[1] + c[1],
        z: v[2] + q.w * t[2] + c[2],
    }
}

fn multiply(a: xr::Quaternionf, b: xr::Quaternionf) -> xr::Quaternionf {
    xr::Quaternionf {
        w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    }
}

/// `outer` then `inner`: the pose of something given in `outer`'s frame as `inner`.
fn compose(outer: xr::Posef, inner: xr::Posef) -> xr::Posef {
    let p = rotate(outer.orientation, inner.position);
    xr::Posef {
        orientation: multiply(outer.orientation, inner.orientation),
        position: xr::Vector3f {
            x: outer.position.x + p.x,
            y: outer.position.y + p.y,
            z: outer.position.z + p.z,
        },
    }
}

fn inverse(p: xr::Posef) -> xr::Posef {
    let q = xr::Quaternionf {
        x: -p.orientation.x,
        y: -p.orientation.y,
        z: -p.orientation.z,
        w: p.orientation.w,
    };
    let t = rotate(
        q,
        xr::Vector3f {
            x: -p.position.x,
            y: -p.position.y,
            z: -p.position.z,
        },
    );
    xr::Posef {
        orientation: q,
        position: t,
    }
}

fn cross(a: xr::Vector3f, b: xr::Vector3f) -> xr::Vector3f {
    xr::Vector3f {
        x: a.y * b.z - a.z * b.y,
        y: a.z * b.x - a.x * b.z,
        z: a.x * b.y - a.y * b.x,
    }
}
fn add(a: xr::Vector3f, b: xr::Vector3f) -> xr::Vector3f {
    xr::Vector3f {
        x: a.x + b.x,
        y: a.y + b.y,
        z: a.z + b.z,
    }
}
fn sub(a: xr::Vector3f, b: xr::Vector3f) -> xr::Vector3f {
    xr::Vector3f {
        x: a.x - b.x,
        y: a.y - b.y,
        z: a.z - b.z,
    }
}
fn vector(v: [f32; 3]) -> xr::Vector3f {
    xr::Vector3f {
        x: v[0],
        y: v[1],
        z: v[2],
    }
}

/// How many of the heads given to the application are kept to find a frame's among.
const GIVEN: usize = 32;
/// Full input snapshots, keyed by the display time requested by the application.
/// Never mix a newer hand with an older head just because calls were interleaved.
const POSE_SAMPLES: usize = 32;

#[derive(Clone, Copy)]
struct PoseSample {
    time: i64,
    state: bridge::State,
    motion_mask: u32,
    local: Option<xr::Posef>,
}

/// The head a frame was drawn for: of the heads `given` to the application, the one its layer's
/// views are of (with its stamp, by which Halliday knows when it was published); the layer's
/// own pose with the newest head's stamp when it is none of them (an application that moves
/// the poses it is given); `newest` when the layer's pose is no rotation at all.
fn drawn_for(
    given: &std::collections::VecDeque<bridge::Pose>,
    head: xr::Posef,
    newest: bridge::Pose,
) -> bridge::Pose {
    let q = head.orientation;
    let norm = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).sqrt();
    if !(0.5..2.0).contains(&norm) {
        return newest;
    }
    // 1 - |cos(half the angle between them)|: 1.25e-7 is 0.06 degrees.
    let apart = |p: &bridge::Pose| {
        let o = from_bridge(p).orientation;
        1.0 - ((o.x * q.x + o.y * q.y + o.z * q.z + o.w * q.w) / norm).abs()
    };
    let nearest = given
        .iter()
        .rev()
        .filter(|p| {
            // Equal orientation is common while walking/leaning without turning. Preserve
            // the pose stamp only when the layer's centre also matches that historical head.
            let d = [
                p.position[0] - head.position.x,
                p.position[1] - head.position.y,
                p.position[2] - head.position.z,
            ];
            d.iter().map(|v| v * v).sum::<f32>() < 1e-8
        })
        .min_by(|a, b| apart(a).total_cmp(&apart(b)));
    if let Some(nearest) = nearest
        && apart(nearest) < 1.25e-7
    {
        return *nearest;
    }
    let mut pose = newest;
    pose.position = [head.position.x, head.position.y, head.position.z];
    pose.orientation = [q.x / norm, q.y / norm, q.z / norm, q.w / norm];
    pose
}

fn from_bridge(p: &bridge::Pose) -> xr::Posef {
    let n = p
        .orientation
        .iter()
        .map(|v| v * v)
        .sum::<f32>()
        .sqrt()
        .max(1e-6);
    xr::Posef {
        orientation: xr::Quaternionf {
            x: p.orientation[0] / n,
            y: p.orientation[1] / n,
            z: p.orientation[2] / n,
            w: p.orientation[3] / n,
        },
        position: xr::Vector3f {
            x: p.position[0],
            y: p.position[1],
            z: p.position[2],
        },
    }
}

#[derive(Clone, Copy, PartialEq)]
enum SpaceKind {
    View,
    Local,
    Stage,
    /// An action space retains its semantic action and optional declared hand.
    /// The source is resolved only by xrSyncActions, never guessed from a null path.
    Action {
        action: u64,
        hand: Option<usize>,
    },
}

#[derive(Clone, Copy)]
struct Space {
    kind: SpaceKind,
    offset: xr::Posef,
}

struct Swapchain {
    width: u32,
    height: u32,
    layers: u32,
    vulkan: bool,
    bgra: bool,
    transfer: u32,
    textures: Vec<*mut c_void>,
    next: usize,
    acquired: VecDeque<usize>,
    /// Exactly one acquired image may be writable at a time.
    waited: bool,
    static_image: bool,
    static_acquired: bool,
    /// The image the application finished last: what `xrEndFrame` shows.
    released: Option<usize>,
}

/// Private, opt-in boundary for Halliday's legacy native-Alyx launcher adapter.
/// That producer uploads already display-encoded SDR bytes into Vulkan UNORM
/// images. Its original OpenXR bridge has no transfer declaration. Keep the
/// images and bytes intact, and declare their source transfer before first use.
/// Ordinary OpenXR UNORM swapchains retain their standard linear interpretation.
/// This is deliberately not exposed through OpenXR's function/extension table.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_openxr_set_legacy_encoded_swapchain(
    swapchain: xr::Swapchain,
    source_transfer: u32,
) -> xr::Result {
    with(|r| {
        let Some(chain) = r.session.as_mut().and_then(|s| s.swapchains.get_mut(&swapchain.into_raw())) else {
            return xr::Result::ERROR_HANDLE_INVALID;
        };
        if source_transfer != bridge::FRAME_COLOR_SRGB {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        // All supported Vulkan swapchains are RGBA/BGRA8 UNORM or SRGB. Metal
        // clients do not belong to this legacy upload adapter.
        if !chain.vulkan {
            return xr::Result::ERROR_FEATURE_UNSUPPORTED;
        }
        if !chain.acquired.is_empty() || chain.released.is_some() || chain.next != 0 || chain.static_acquired {
            return xr::Result::ERROR_CALL_ORDER_INVALID;
        }
        chain.transfer = bridge::FRAME_COLOR_SRGB;
        xr::Result::SUCCESS
    })
}

/// Keep the client alive while an engine is loading shaders or waiting in an
/// event-only loop. Stop/join before relinquishing the session's registration.
struct Heartbeat {
    stop: Option<std::sync::mpsc::Sender<()>>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl Heartbeat {
    fn start(path: &std::path::Path) -> Option<Self> {
        let side = GameSide::view(path).ok()?;
        let (stop, receiver) = std::sync::mpsc::channel();
        let worker = std::thread::Builder::new()
            .name("halliday-xr-heartbeat".into())
            .spawn(move || {
                while let Err(std::sync::mpsc::RecvTimeoutError::Timeout) =
                    receiver.recv_timeout(Duration::from_millis(200))
                {
                    if !side.heartbeat() {
                        break;
                    }
                }
            })
            .ok()?;
        Some(Self {
            stop: Some(stop),
            worker: Some(worker),
        })
    }
}
impl Drop for Heartbeat {
    fn drop(&mut self) {
        self.stop.take();
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct Session {
    handle: u64,
    instance: u64,
    queue: *mut c_void,
    device: *mut c_void,
    vulkan: *mut c_void,
    readback: [Vec<u8>; 2],
    panel_readback: [Vec<u8>; bridge::OVERLAYS],
    scratch: *mut c_void,
    scratch_bytes: u64,
    side: GameSide,
    config: Config,
    display_period_override: Option<i64>,
    state: xr::SessionState,
    running: bool,
    spaces: HashMap<u64, Space>,
    swapchains: HashMap<u64, Swapchain>,
    /// Halliday's newest state, taken at `xrWaitFrame`.
    newest: Option<bridge::State>,
    newest_motion: u32,
    pose_samples: VecDeque<PoseSample>,
    /// Uncached times before the last reference change cannot be reconstructed.
    pose_epoch_start: i64,
    pose_latest_time: i64,
    /// The heads given at the last waits, oldest first: a frame is drawn for one of them.
    given: std::collections::VecDeque<bridge::Pose>,
    /// LOCAL's place in Halliday's space: the head at the first frame, level.
    local: Option<xr::Posef>,
    /// The controllers at the last `xrSyncActions`, and at the one before (for "changed").
    synced: [bridge::Controller; 2],
    synced_before: [bridge::Controller; 2],
    profile_connected: Option<[bool; 2]>,
    attached_sets: Option<Vec<u64>>,
    active_sets: HashMap<u64, [bool; 2]>,
    pose_sources: HashMap<u64, PoseSources>,
    readings: HashMap<(u64, Option<usize>), Reading>,
    waited: bool,
    begun: bool,
    display_time: i64,
    quit_requests: u32,
    haptic_epoch: u64,
    haptic_actions: [Option<u64>; 2],
    focus_generation: u32,
    space_epoch: u32,
    wait_space_epoch: u32,
    frame_space_epoch: u32,
    heartbeat: Option<Heartbeat>,
    registered: bool,
    last_host_tick: u64,
    last_host_progress: Instant,
    frames: u64,
}

// SAFETY: the Metal objects are only used under the runtime's lock, and Metal's command queues,
// devices, textures and buffers may be used from any thread.
unsafe impl Send for Session {}

enum RuntimeEvent {
    State(u64, xr::SessionState, i64),
    Reference(u64, xr::ReferenceSpaceType, i64),
    Profile(u64),
}
impl RuntimeEvent {
    fn session(&self) -> u64 {
        match *self {
            Self::State(s, _, _) | Self::Reference(s, _, _) | Self::Profile(s) => s,
        }
    }
}

#[derive(Default)]
struct Runtime {
    session: Option<Session>,
    events: VecDeque<RuntimeEvent>,
    paths: HashMap<u64, String>,
    /// Public handles and session-retained action resources are separate lifetimes.
    actions: HashMap<u64, Action>,
    /// Effective bindings selected from the attached sets' per-hand profiles.
    bindings: HashMap<u64, Vec<Binding>>,
    /// Suggestions are instance-owned and replaced independently per profile.
    suggested_profiles: HashMap<u64, SuggestedProfile>,
    /// Effective profiles/bindings belong to the currently attached sets.
    selected_profiles: [Option<u64>; 2],
    action_sets: HashMap<u64, ActionSet>,
    next_handle: u64,
    default_device: usize,
    last_event_time: i64,
}

static RUNTIME: Mutex<Option<Runtime>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut Runtime) -> R) -> R {
    let mut guard = RUNTIME.lock().unwrap_or_else(|e| e.into_inner());
    f(guard.get_or_insert_with(|| Runtime {
        next_handle: 0x1000,
        ..Default::default()
    }))
}

impl Runtime {
    fn select_bindings(&mut self, sets: &[u64]) {
        let mut selected: [Option<(u64, u8)>; 2] = [None; 2];
        for (&profile, suggestion) in &self.suggested_profiles {
            for hand in 0..2 {
                let usable = suggestion.bindings.iter().any(|(handle, bindings)| {
                    self.actions.get(handle).is_some_and(|action| {
                        sets.contains(&action.set) && action_allows_hand(&self.paths, action, hand)
                            && bindings.iter().any(|binding| binding.hand == hand)
                    })
                });
                if usable && selected[hand].is_none_or(|(old, rank)| {
                    suggestion.rank > rank || (suggestion.rank == rank && profile < old)
                }) {
                    selected[hand] = Some((profile, suggestion.rank));
                }
            }
        }
        let mut bindings = HashMap::<u64, Vec<Binding>>::new();
        for hand in 0..2 {
            let Some((profile, _)) = selected[hand] else { continue };
            for (&handle, suggested) in &self.suggested_profiles[&profile].bindings {
                let Some(action) = self.actions.get(&handle) else { continue };
                if !sets.contains(&action.set) || !action_allows_hand(&self.paths, action, hand) { continue; }
                bindings.entry(handle).or_default().extend(suggested.iter()
                    .filter(|binding| binding.hand == hand).copied());
            }
        }
        self.selected_profiles = selected.map(|choice| choice.map(|(profile, _)| profile));
        self.bindings = bindings;
    }

    fn public_action(&self, handle: u64) -> Option<&Action> {
        self.actions.get(&handle).filter(|a| a.handle_alive)
    }

    fn public_action_set(&self, handle: u64) -> bool {
        self.action_sets
            .get(&handle)
            .is_some_and(|set| set.handle_alive)
    }

    fn handle(&mut self) -> u64 {
        self.next_handle += 1;
        self.next_handle
    }

    fn session(&mut self, session: xr::Session) -> Result<&mut Session, xr::Result> {
        match self.session.as_mut() {
            Some(s) if s.handle == session.into_raw() => Ok(s),
            _ => Err(xr::Result::ERROR_HANDLE_INVALID),
        }
    }

    fn change(&mut self, to: &[xr::SessionState]) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        for state in to {
            if s.state == *state {
                continue;
            }
            s.state = *state;
            let time = halliday_core::time::host_time_ns().max(self.last_event_time + 1);
            self.last_event_time = time;
            self.events.push_back(RuntimeEvent::State(s.handle, *state, time));
        }
    }

    /// Refresh lifecycle independently of the frame loop. A paused application can
    /// wait for focus in xrPollEvent without ever calling xrWaitFrame again.
    fn refresh_lifecycle(&mut self) {
        let Some(s) = self.session.as_mut() else {
            return;
        };
        if matches!(
            s.state,
            xr::SessionState::STOPPING | xr::SessionState::EXITING | xr::SessionState::LOSS_PENDING
        ) {
            return;
        }
        let focus_generation = s.side.focus_generation();
        if focus_generation != s.focus_generation {
            s.focus_generation = focus_generation;
            s.cancel_haptics();
        }
        let epoch = s.side.space_epoch();
        if epoch != s.space_epoch {
            s.space_epoch = epoch;
            s.local = None;
            s.newest = None;
            s.given.clear();
            let time = halliday_core::time::host_time_ns();
            // Retain known historical coordinates before changeTime, but never
            // reuse a future sample expressed in the previous reference frame.
            s.pose_samples.retain(|sample| sample.time < time);
            s.pose_epoch_start = time;
            s.pose_latest_time = time;
            for kind in [xr::ReferenceSpaceType::LOCAL, xr::ReferenceSpaceType::STAGE] {
                self.events
                    .push_back(RuntimeEvent::Reference(s.handle, kind, time));
            }
        }
        let tick = s.side.host_tick();
        if tick != s.last_host_tick {
            s.last_host_tick = tick;
            s.last_host_progress = Instant::now();
        }
        let (quit, dashboard, _) = s.side.requests();
        let quitting = quit != s.quit_requests
            || !s.side.halliday_alive()
            || s.last_host_progress.elapsed() > Duration::from_secs(2);
        if quit != s.quit_requests {
            s.side.acknowledge_quit(quit);
        }
        s.quit_requests = quit;
        if quitting {
            s.cancel_haptics();
            let states: &[xr::SessionState] = match (s.running, s.state) {
                (false, _) => &[xr::SessionState::IDLE, xr::SessionState::EXITING],
                (_, xr::SessionState::FOCUSED) => &STOPPING,
                (_, xr::SessionState::VISIBLE) => {
                    &[xr::SessionState::SYNCHRONIZED, xr::SessionState::STOPPING]
                }
                _ => &[xr::SessionState::STOPPING],
            };
            self.change(states);
        } else if s.running {
            let desired = if dashboard {
                xr::SessionState::VISIBLE
            } else {
                xr::SessionState::FOCUSED
            };
            if s.state != desired {
                if dashboard {
                    s.cancel_haptics();
                }
                self.change(&[desired]);
            }
        }
    }
}

/// Where Halliday keeps the bridge (`HALLIDAY_BRIDGE` names another file, for tests).
fn bridge_path() -> PathBuf {
    if let Some(path) = std::env::var_os("HALLIDAY_BRIDGE") {
        return PathBuf::from(path);
    }
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
        .join("Library/Application Support/Halliday/OpenVR")
        .join(bridge::FILE_NAME)
}

/// `HALLIDAY_EYE_SIZE=WxH`: the size this application is asked to draw each eye at, in place
/// of the bridge's (Halliday sets it for a Quest app: the bridge's own size is a small one,
/// for games whose frames are copied through memory by the processor). Must fit a slot.
fn asked_eye_size() -> Option<(u32, u32)> {
    let text = std::env::var("HALLIDAY_EYE_SIZE").ok()?;
    let (w, h) = text.split_once('x')?;
    let (w, h) = (w.trim().parse().ok()?, h.trim().parse().ok()?);
    (w >= 64 && h >= 64 && bridge::fits(w, h)).then_some((w, h))
}

// The launcher supplies an initial game-cadence hint for native port scripts.
// Preserve it as fallback without pinning a session whose live host changes rate.
// A manually supplied value without that marker remains an explicit override.
fn apply_display_hz_hint(config: &mut Config, value: Option<&str>, initial: bool) -> Option<i64> {
    let hz = value?.parse::<f32>().ok()
        .filter(|v| v.is_finite() && (20.0..=240.0).contains(v))?;
    config.display_hz = hz;
    (!initial).then(|| (1e9 / f64::from(hz)) as i64)
}

/// The size Halliday asks each eye to be drawn at, while it runs.
pub(crate) fn eye_size() -> Option<(u32, u32)> {
    if let Some(asked) = asked_eye_size() {
        return Some(asked);
    }
    let live = with(|r| {
        r.session
            .as_ref()
            .map(|s| (s.config.eye_width, s.config.eye_height))
    });
    live.or_else(|| {
        let c = GameSide::view(&bridge_path()).ok()?.config();
        (c.eye_width > 0 && c.eye_height > 0).then_some((c.eye_width, c.eye_height))
    })
}

/// Takes instances' pending session events: the next one, if any, written into `buffer`.
///
/// # Safety
/// `buffer` must be valid for a write of an `XrEventDataBuffer`.
pub(crate) unsafe fn poll(instance: u64, buffer: *mut xr::EventDataBuffer) -> xr::Result {
    let Some(event) = with(|r| {
        if r.session.as_ref().is_none_or(|s| s.instance != instance) {
            return None;
        }
        r.refresh_lifecycle();
        r.events.pop_front()
    }) else {
        return xr::Result::EVENT_UNAVAILABLE;
    };
    unsafe {
        match event {
            RuntimeEvent::State(session, state, time) => buffer
                .cast::<xr::EventDataSessionStateChanged>()
                .write(xr::EventDataSessionStateChanged {
                    ty: xr::EventDataSessionStateChanged::TYPE,
                    next: std::ptr::null(),
                    session: xr::Session::from_raw(session),
                    state,
                    time: xr::Time::from_nanos(time),
                }),
            RuntimeEvent::Reference(session, kind, time) => buffer
                .cast::<xr::EventDataReferenceSpaceChangePending>()
                .write(xr::EventDataReferenceSpaceChangePending {
                    ty: xr::EventDataReferenceSpaceChangePending::TYPE,
                    next: std::ptr::null(),
                    session: xr::Session::from_raw(session),
                    reference_space_type: kind,
                    change_time: xr::Time::from_nanos(time),
                    pose_valid: xr::FALSE,
                    pose_in_previous_space: IDENTITY,
                }),
            RuntimeEvent::Profile(session) => buffer
                .cast::<xr::EventDataInteractionProfileChanged>()
                .write(xr::EventDataInteractionProfileChanged {
                    ty: xr::EventDataInteractionProfileChanged::TYPE,
                    next: std::ptr::null(),
                    session: xr::Session::from_raw(session),
                }),
        }
    }
    xr::Result::SUCCESS
}

/// Forgets an instance's session, events, actions and paths.
pub(crate) fn instance_destroyed(instance: u64) {
    with(|r| {
        if r.session.as_ref().is_some_and(|s| s.instance == instance) {
            drop_session(r);
        }
        r.events.clear();
        r.actions.clear();
        r.action_sets.clear();
        r.bindings.clear();
        r.suggested_profiles.clear();
        r.selected_profiles = [None; 2];
        r.paths.clear();
    });
}

fn drop_session(r: &mut Runtime) {
    if let Some(mut s) = r.session.take() {
        s.release_client();
        r.events.retain(|event| event.session() != s.handle);
        // SAFETY: retained when the session and its swapchains were made.
        unsafe {
            for chain in s.swapchains.values() {
                for texture in &chain.textures {
                    if chain.vulkan {
                        hxvk_destroy_image(*texture);
                    } else {
                        hx_release(*texture);
                    }
                }
            }
            hx_release(s.scratch);
            hx_release(s.device);
            hx_release(s.queue);
            hxvk_destroy_context(s.vulkan);
        }
    }
    // Actions belong to the instance: even a destroyed public action still
    // participates in binding priority when its live set attaches to another
    // session. Instance destruction, rather than session teardown, releases it.
}

macro_rules! fp {
    ($f:expr, $t:ty) => {{
        let f: $t = $f;
        // SAFETY: OpenXR hands out every function as a `PFN_xrVoidFunction`; callers cast it back
        // to its real type before calling it.
        Some(unsafe { std::mem::transmute::<$t, pfn::VoidFunction>(f) })
    }};
}

/// The functions of this module, by OpenXR name.
pub(crate) fn lookup(name: &[u8]) -> Option<pfn::VoidFunction> {
    match name {
        b"xrGetMetalGraphicsRequirementsKHR" => fp!(
            get_metal_graphics_requirements,
            pfn::GetMetalGraphicsRequirementsKHR
        ),
        b"xrCreateSession" => fp!(create_session, pfn::CreateSession),
        b"xrDestroySession" => fp!(destroy_session, pfn::DestroySession),
        b"xrBeginSession" => fp!(begin_session, pfn::BeginSession),
        b"xrEndSession" => fp!(end_session, pfn::EndSession),
        b"xrRequestExitSession" => fp!(request_exit_session, pfn::RequestExitSession),
        b"xrEnumerateReferenceSpaces" => {
            fp!(enumerate_reference_spaces, pfn::EnumerateReferenceSpaces)
        }
        b"xrCreateReferenceSpace" => fp!(create_reference_space, pfn::CreateReferenceSpace),
        b"xrGetReferenceSpaceBoundsRect" => fp!(
            get_reference_space_bounds_rect,
            pfn::GetReferenceSpaceBoundsRect
        ),
        b"xrCreateActionSpace" => fp!(create_action_space, pfn::CreateActionSpace),
        b"xrLocateSpace" => fp!(locate_space, pfn::LocateSpace),
        b"xrLocateSpaces" => fp!(locate_spaces, pfn::LocateSpaces),
        b"xrDestroySpace" => fp!(destroy_space, pfn::DestroySpace),
        b"xrEnumerateSwapchainFormats" => {
            fp!(enumerate_swapchain_formats, pfn::EnumerateSwapchainFormats)
        }
        b"xrCreateSwapchain" => fp!(create_swapchain, pfn::CreateSwapchain),
        b"xrDestroySwapchain" => fp!(destroy_swapchain, pfn::DestroySwapchain),
        b"xrEnumerateSwapchainImages" => {
            fp!(enumerate_swapchain_images, pfn::EnumerateSwapchainImages)
        }
        b"xrAcquireSwapchainImage" => fp!(acquire_swapchain_image, pfn::AcquireSwapchainImage),
        b"xrWaitSwapchainImage" => fp!(wait_swapchain_image, pfn::WaitSwapchainImage),
        b"xrReleaseSwapchainImage" => fp!(release_swapchain_image, pfn::ReleaseSwapchainImage),
        b"xrWaitFrame" => fp!(wait_frame, pfn::WaitFrame),
        b"xrBeginFrame" => fp!(begin_frame, pfn::BeginFrame),
        b"xrEndFrame" => fp!(end_frame, pfn::EndFrame),
        b"xrLocateViews" => fp!(locate_views, pfn::LocateViews),
        b"xrStringToPath" => fp!(string_to_path, pfn::StringToPath),
        b"xrPathToString" => fp!(path_to_string, pfn::PathToString),
        b"xrCreateActionSet" => fp!(create_action_set, pfn::CreateActionSet),
        b"xrDestroyActionSet" => fp!(destroy_action_set, pfn::DestroyActionSet),
        b"xrCreateAction" => fp!(create_action, pfn::CreateAction),
        b"xrDestroyAction" => fp!(destroy_action, pfn::DestroyAction),
        b"xrSuggestInteractionProfileBindings" => fp!(
            suggest_interaction_profile_bindings,
            pfn::SuggestInteractionProfileBindings
        ),
        b"xrAttachSessionActionSets" => {
            fp!(attach_session_action_sets, pfn::AttachSessionActionSets)
        }
        b"xrGetCurrentInteractionProfile" => fp!(
            get_current_interaction_profile,
            pfn::GetCurrentInteractionProfile
        ),
        b"xrGetActionStateBoolean" => fp!(get_action_state_boolean, pfn::GetActionStateBoolean),
        b"xrGetActionStateFloat" => fp!(get_action_state_float, pfn::GetActionStateFloat),
        b"xrGetActionStateVector2f" => {
            fp!(get_action_state_vector2f, pfn::GetActionStateVector2f)
        }
        b"xrGetActionStatePose" => fp!(get_action_state_pose, pfn::GetActionStatePose),
        b"xrSyncActions" => fp!(sync_actions, pfn::SyncActions),
        b"xrEnumerateBoundSourcesForAction" => fp!(
            enumerate_bound_sources_for_action,
            pfn::EnumerateBoundSourcesForAction
        ),
        b"xrGetInputSourceLocalizedName" => fp!(
            get_input_source_localized_name,
            pfn::GetInputSourceLocalizedName
        ),
        b"xrApplyHapticFeedback" => fp!(apply_haptic_feedback, pfn::ApplyHapticFeedback),
        b"xrStopHapticFeedback" => fp!(stop_haptic_feedback, pfn::StopHapticFeedback),
        _ => None,
    }
}

// --- The session ---------------------------------------------------------------------------------

unsafe extern "system" fn get_metal_graphics_requirements(
    instance: xr::Instance,
    system: xr::SystemId,
    out: *mut xr::GraphicsRequirementsMetalKHR,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if out.ty != xr::GraphicsRequirementsMetalKHR::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let check = crate::vulkan::metal_requirements(instance, system, true);
    if check != xr::Result::SUCCESS {
        return check;
    }
    out.metal_device = with(|r| {
        if r.default_device == 0 {
            // SAFETY: Metal's own default device, kept for the process's life.
            r.default_device = unsafe { hx_default_device() } as usize;
        }
        r.default_device as *mut c_void
    });
    xr::Result::SUCCESS
}

unsafe extern "system" fn create_session(
    instance: xr::Instance,
    info: *const xr::SessionCreateInfo,
    out: *mut xr::Session,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !crate::is_live(instance) {
        return xr::Result::ERROR_HANDLE_INVALID;
    }
    if info.system_id.into_raw() != crate::SYSTEM_ID {
        return xr::Result::ERROR_SYSTEM_INVALID;
    }
    // The graphics binding, somewhere along the chain.
    let mut next = info.next.cast::<xr::BaseInStructure>();
    let mut queue = std::ptr::null_mut();
    let mut vk_binding = None;
    while let Some(link) = unsafe { next.as_ref() } {
        if link.ty == xr::StructureType::GRAPHICS_BINDING_METAL_KHR {
            queue = unsafe { (*next.cast::<xr::GraphicsBindingMetalKHR>()).command_queue };
        }
        if link.ty == xr::StructureType::GRAPHICS_BINDING_VULKAN_KHR {
            vk_binding = Some(unsafe { *next.cast::<xr::GraphicsBindingVulkanKHR>() });
        }
        next = link.next;
    }
    if queue.is_null() && vk_binding.is_none() {
        return xr::Result::ERROR_GRAPHICS_DEVICE_INVALID;
    }
    // Halliday shows the application under its executable's name, or the one whoever started
    // it gives (`HALLIDAY_APP_NAME`: Klepton's runner is the same executable for every app).
    let app = std::env::var("HALLIDAY_APP_NAME")
        .ok()
        .filter(|name| !name.is_empty())
        .or_else(|| {
            let exe = std::env::current_exe().ok()?;
            Some(exe.file_name()?.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "OpenXR application".to_owned());
    let side = match GameSide::view(&bridge_path()) {
        Ok(side) if side.halliday_alive() => side,
        _ => {
            eprintln!(
                "Halliday's OpenXR runtime: Halliday isn't running (no bridge at {})",
                bridge_path().display()
            );
            return xr::Result::ERROR_RUNTIME_FAILURE;
        }
    };
    with(|r| {
        if r.session.is_some() {
            return xr::Result::ERROR_LIMIT_REACHED;
        }
        if side.client_owner().is_some() {
            return xr::Result::ERROR_LIMIT_REACHED;
        }
        if !queue.is_null() && vk_binding.is_some() {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        let vulkan = if let Some(binding) = vk_binding {
            match unsafe { crate::vulkan::context(instance, info.system_id, &binding) } {
                Ok(c) => c,
                Err(e) => return e,
            }
        } else {
            let check = crate::vulkan::metal_requirements(instance, info.system_id, false);
            if check != xr::Result::SUCCESS {
                return check;
            }
            std::ptr::null_mut()
        };
        let mut config = side.config();
        let display_hz = std::env::var("HALLIDAY_DISPLAY_HZ").ok();
        let initial_hint = std::env::var("HALLIDAY_DISPLAY_HZ_INITIAL").ok().as_deref() == Some("1");
        let display_period_override = apply_display_hz_hint(&mut config, display_hz.as_deref(), initial_hint);
        let space_epoch = side.space_epoch();
        let focus_generation = side.focus_generation();
        let host_tick = side.host_tick();
        let handle = r.handle();
        if !side.register_client_as(&app) {
            unsafe {
                hxvk_destroy_context(vulkan);
            }
            return xr::Result::ERROR_LIMIT_REACHED;
        }
        let Some(heartbeat) = Heartbeat::start(&bridge_path()) else {
            side.unregister_client();
            unsafe {
                hxvk_destroy_context(vulkan);
            }
            return xr::Result::ERROR_RUNTIME_FAILURE;
        };
        // SAFETY: the application's queue, valid for the call; kept (retained) for the session.
        let (queue, device) = if vulkan.is_null() {
            unsafe { (hx_retain(queue), hx_queue_device(queue)) }
        } else {
            (std::ptr::null_mut(), std::ptr::null_mut())
        };
        r.session = Some(Session {
            handle,
            instance: instance.into_raw(),
            queue,
            device,
            vulkan,
            readback: Default::default(),
            panel_readback: Default::default(),
            scratch: std::ptr::null_mut(),
            scratch_bytes: 0,
            side,
            config,
            display_period_override,
            state: xr::SessionState::UNKNOWN,
            running: false,
            spaces: HashMap::new(),
            swapchains: HashMap::new(),
            newest: None,
            newest_motion: bridge::motion::ALL,
            pose_samples: Default::default(),
            pose_epoch_start: 0,
            pose_latest_time: 0,
            given: Default::default(),
            local: None,
            synced: Default::default(),
            synced_before: Default::default(),
            profile_connected: None,
            attached_sets: None,
            active_sets: HashMap::new(),
            pose_sources: HashMap::new(),
            readings: HashMap::new(),
            waited: false,
            begun: false,
            display_time: 0,
            quit_requests: 0,
            haptic_epoch: 0,
            haptic_actions: [None; 2],
            focus_generation,
            space_epoch,
            wait_space_epoch: space_epoch,
            frame_space_epoch: space_epoch,
            heartbeat: Some(heartbeat),
            registered: true,
            last_host_tick: host_tick,
            last_host_progress: Instant::now(),
            frames: 0,
        });
        if let Some(s) = r.session.as_mut() {
            s.quit_requests = s.side.requests().0;
            s.haptic_epoch = s.side.begin_haptics();
        }
        r.change(&[xr::SessionState::IDLE, xr::SessionState::READY]);
        *out = xr::Session::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn destroy_session(session: xr::Session) -> xr::Result {
    with(|r| {
        if let Err(e) = r.session(session) {
            return e;
        }
        drop_session(r);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn begin_session(
    session: xr::Session,
    info: *const xr::SessionBeginInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.primary_view_configuration_type != xr::ViewConfigurationType::PRIMARY_STEREO {
        return xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    with(|r| {
        r.refresh_lifecycle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if s.running {
            return xr::Result::ERROR_SESSION_RUNNING;
        }
        if s.state != xr::SessionState::READY {
            return xr::Result::ERROR_SESSION_NOT_READY;
        }
        s.running = true;
        let dashboard = s.side.requests().1;
        r.change(&[xr::SessionState::SYNCHRONIZED, xr::SessionState::VISIBLE]);
        if !dashboard {
            r.change(&[xr::SessionState::FOCUSED]);
        }
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn end_session(session: xr::Session) -> xr::Result {
    with(|r| {
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        if s.state != xr::SessionState::STOPPING {
            return xr::Result::ERROR_SESSION_NOT_STOPPING;
        }
        s.running = false;
        s.release_client();
        s.waited = false;
        s.begun = false;
        r.change(&[xr::SessionState::IDLE, xr::SessionState::EXITING]);
        xr::Result::SUCCESS
    })
}

/// The states a running session goes through on its way out.
const STOPPING: [xr::SessionState; 3] = [
    xr::SessionState::VISIBLE,
    xr::SessionState::SYNCHRONIZED,
    xr::SessionState::STOPPING,
];

unsafe extern "system" fn request_exit_session(session: xr::Session) -> xr::Result {
    with(|r| {
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        if s.state != xr::SessionState::STOPPING {
            s.cancel_haptics();
            let states: &[xr::SessionState] = match s.state {
                xr::SessionState::FOCUSED => &STOPPING,
                xr::SessionState::VISIBLE => {
                    &[xr::SessionState::SYNCHRONIZED, xr::SessionState::STOPPING]
                }
                _ => &[xr::SessionState::STOPPING],
            };
            r.change(states);
        }
        xr::Result::SUCCESS
    })
}

// --- Spaces --------------------------------------------------------------------------------------

unsafe extern "system" fn enumerate_reference_spaces(
    session: xr::Session,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::ReferenceSpaceType,
) -> xr::Result {
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    let kinds = [
        xr::ReferenceSpaceType::VIEW,
        xr::ReferenceSpaceType::LOCAL,
        xr::ReferenceSpaceType::STAGE,
    ];
    unsafe { crate::two_call(&kinds, capacity, count, out) }
}

unsafe extern "system" fn create_reference_space(
    session: xr::Session,
    info: *const xr::ReferenceSpaceCreateInfo,
    out: *mut xr::Space,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !valid_action_offset(info.pose_in_reference_space) {
        return xr::Result::ERROR_POSE_INVALID;
    }
    let kind = match info.reference_space_type {
        xr::ReferenceSpaceType::VIEW => SpaceKind::View,
        xr::ReferenceSpaceType::LOCAL => SpaceKind::Local,
        xr::ReferenceSpaceType::STAGE => SpaceKind::Stage,
        _ => return xr::Result::ERROR_REFERENCE_SPACE_UNSUPPORTED,
    };
    new_space(session, kind, info.pose_in_reference_space, out)
}

fn new_space(
    session: xr::Session,
    kind: SpaceKind,
    offset: xr::Posef,
    out: &mut xr::Space,
) -> xr::Result {
    with(|r| {
        if let Err(e) = r.session(session) {
            return e;
        }
        let handle = r.handle();
        if let Some(s) = r.session.as_mut() {
            s.spaces.insert(handle, Space { kind, offset });
        }
        *out = xr::Space::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn get_reference_space_bounds_rect(
    session: xr::Session,
    _kind: xr::ReferenceSpaceType,
    bounds: *mut xr::Extent2Df,
) -> xr::Result {
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    if let Some(bounds) = unsafe { bounds.as_mut() } {
        *bounds = xr::Extent2Df {
            width: 0.0,
            height: 0.0,
        };
    }
    // No play area is measured yet.
    xr::Result::SPACE_BOUNDS_UNAVAILABLE
}

unsafe extern "system" fn create_action_space(
    session: xr::Session,
    info: *const xr::ActionSpaceCreateInfo,
    out: *mut xr::Space,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !valid_action_offset(info.pose_in_action_space) {
        return xr::Result::ERROR_POSE_INVALID;
    }
    with(|r| {
        if let Err(e) = r.session(session) {
            return e;
        }
        let Some(action) = r.public_action(info.action.into_raw()) else {
            return xr::Result::ERROR_HANDLE_INVALID;
        };
        if action.kind != xr::ActionType::POSE_INPUT {
            return xr::Result::ERROR_ACTION_TYPE_MISMATCH;
        }
        let hand = match requested_hand(&r.paths, action, info.subaction_path) {
            Ok(hand) => hand,
            Err(e) => return e,
        };
        let handle = r.handle();
        r.session.as_mut().unwrap().spaces.insert(
            handle,
            Space {
                kind: SpaceKind::Action {
                    action: info.action.into_raw(),
                    hand,
                },
                offset: info.pose_in_action_space,
            },
        );
        *out = xr::Space::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn destroy_space(space: xr::Space) -> xr::Result {
    with(|r| {
        match r
            .session
            .as_mut()
            .and_then(|s| s.spaces.remove(&space.into_raw()))
        {
            Some(_) => xr::Result::SUCCESS,
            None => xr::Result::ERROR_HANDLE_INVALID,
        }
    })
}

impl Session {
    fn anchor_local(&mut self, state: &bridge::State) {
        if self.local.is_some() || state.head.valid == 0 {
            return;
        }
        let head = from_bridge(&state.head);
        let forward = rotate(head.orientation, vector([0.0, 0.0, -1.0]));
        let yaw = (-forward.x).atan2(-forward.z) * 0.5;
        self.local = Some(xr::Posef {
            orientation: xr::Quaternionf {
                x: 0.0,
                y: yaw.sin(),
                z: 0.0,
                w: yaw.cos(),
            },
            position: head.position,
        });
    }

    fn remember_pose_sample(&mut self, sample: PoseSample) -> PoseSample {
        self.pose_latest_time = self.pose_latest_time.max(sample.time);
        if let Some(previous) = self.pose_samples.iter().find(|p| p.time == sample.time) {
            return *previous;
        }
        if self.pose_samples.len() == POSE_SAMPLES {
            self.pose_samples.pop_front();
        }
        self.pose_samples.push_back(sample);
        sample
    }

    /// The v6 transport has no predictor. Keep its complete measured state
    /// stable for each XrTime, rather than inventing extrapolated poses or
    /// re-reading head/hands independently. WaitFrame seeds the normal time;
    /// an application's first other-time query seeds that time once.
    fn pose_sample(&mut self, time: i64) -> PoseSample {
        if let Some(sample) = self.pose_samples.iter().find(|p| p.time == time) {
            return *sample;
        }
        if time < self.pose_epoch_start || time < self.pose_latest_time {
            // An evicted/unknown old timestamp cannot be relabeled with the
            // current pose. These requests never evict useful recent samples.
            return PoseSample {
                time,
                state: bridge::State::default(),
                motion_mask: 0,
                local: None,
            };
        }
        let (state,motion_mask) = self
            .side
            .state_snapshot_with_motion()
            .or(self.newest.map(|state|(state,self.newest_motion)))
            .unwrap_or((bridge::State::default(),0));
        self.anchor_local(&state);
        self.remember_pose_sample(PoseSample {
            time,
            state,
            motion_mask,
            local: self.local,
        })
    }

    fn release_client(&mut self) {
        self.cancel_haptics();
        drop(self.heartbeat.take());
        self.side.end_haptics(self.haptic_epoch);
        self.haptic_epoch = 0;
        if self.registered {
            self.side.unregister_client();
            self.registered = false;
        }
    }

    fn cancel_haptics(&mut self) {
        if self.haptic_epoch != 0 {
            for hand in 0..2 {
                self.side.send_haptic(self.haptic_epoch, hand, 0, 0.0, 0.0);
            }
        }
        self.haptic_actions = [None; 2];
    }

    /// A space's pose in Halliday's own space (STAGE), and whether it is tracked now.
    fn in_stage(&self, space: &Space, sample: &PoseSample) -> (xr::Posef, bool) {
        let state = sample.state;
        let (base, tracked) = match space.kind {
            SpaceKind::Stage => (IDENTITY, true),
            SpaceKind::Local => (sample.local.unwrap_or(IDENTITY), sample.local.is_some()),
            SpaceKind::View => (
                from_bridge(&state.head),
                state.head.valid != 0
                    && self.side.halliday_alive()
                    && !matches!(
                        self.state,
                        xr::SessionState::STOPPING
                            | xr::SessionState::EXITING
                            | xr::SessionState::LOSS_PENDING
                    ),
            ),
            SpaceKind::Action { action, hand } => {
                let source = self.pose_sources.get(&action);
                let selected = hand.or_else(|| source.and_then(|s| s.selected));
                match (source, selected) {
                    (Some(source), Some(hand))
                        if source.eligible[hand]
                            && self.side.halliday_alive()
                            && !matches!(
                                self.state,
                                xr::SessionState::STOPPING
                                    | xr::SessionState::EXITING
                                    | xr::SessionState::LOSS_PENDING
                            )
                            && source.kinds[hand].is_some_and(Part::is_pose) =>
                    {
                        let c = &state.controllers[hand];
                        // The legacy bridge has one canonical pose per hand. Grip/aim
                        // identities remain distinct, without inventing a mount offset.
                        (from_bridge(&c.pose), c.connected != 0 && c.pose.valid != 0)
                    }
                    _ => (IDENTITY, false),
                }
            }
        };
        (compose(base, space.offset), tracked)
    }

    fn same_entity(&self, a: &Space, b: &Space) -> bool {
        if a.kind == b.kind {
            return true;
        }
        let action_entity = |space: &Space| {
            let SpaceKind::Action { action, hand } = space.kind else { return None };
            let source = self.pose_sources.get(&action)?;
            let hand = hand.or(source.selected)?;
            if !source.eligible[hand] { return None; }
            source.kinds[hand].filter(|part| part.is_pose()).map(|part| (hand, part))
        };
        // Distinct action/subaction handles may track the same bound entity.
        // Resolve only active, synchronized sources: two missing bindings must
        // never be mistaken for a shared controller, nor grip for aim.
        action_entity(a).is_some_and(|entity| Some(entity) == action_entity(b))
    }

    fn locate(
        &self,
        space: u64,
        base: u64,
        sample: &PoseSample,
    ) -> Option<(xr::Posef, xr::SpaceLocationFlags)> {
        let (space, base) = (self.spaces.get(&space)?, self.spaces.get(&base)?);
        if self.same_entity(space, base) {
            let tracked = self.in_stage(space, sample).1 && self.in_stage(base, sample).1;
            let valid =
                xr::SpaceLocationFlags::ORIENTATION_VALID | xr::SpaceLocationFlags::POSITION_VALID;
            return Some((
                compose(inverse(base.offset), space.offset),
                // A common entity cancels exactly, independently of its
                // absolute tracking. xrLocateSpace requires POSITION_TRACKED
                // for this known application-defined relative transform.
                valid | xr::SpaceLocationFlags::POSITION_TRACKED | flags(tracked),
            ));
        }
        let ((a, a_ok), (b, b_ok)) = (self.in_stage(space, sample), self.in_stage(base, sample));
        Some((compose(inverse(b), a), flags(a_ok && b_ok)))
    }

    fn motion(&self, space: &Space, sample: &PoseSample) -> (xr::Vector3f, xr::Vector3f, bool, bool) {
        let zero = vector([0.0; 3]);
        let state = sample.state;
        let source = match space.kind {
            SpaceKind::View => Some((state.head,0)),
            SpaceKind::Action { action, hand } => self.pose_sources.get(&action)
                .and_then(|source| hand.or(source.selected).filter(|&hand| source.eligible[hand]))
                .map(|hand| (state.controllers[hand].pose,hand+1)),
            _ => None,
        };
        let Some((pose,device)) = source else {return (zero,zero,true,true)};
        let bits = (sample.motion_mask >> (device*2)) & 3;
        let finite = |v:xr::Vector3f| [v.x,v.y,v.z].iter().all(|x|x.is_finite());
        let angular = vector(pose.angular_velocity);
        let angular_ok = bits&2 != 0 && finite(angular);
        let angular = if angular_ok {angular} else {zero};
        let lever = rotate(from_bridge(&pose).orientation,space.offset.position);
        let no_lever = lever.x == 0. && lever.y == 0. && lever.z == 0.;
        let linear = add(vector(pose.velocity),cross(angular,lever));
        let linear_ok = bits&1 != 0 && (no_lever || angular_ok) && finite(linear);
        (if linear_ok {linear}else{zero},angular,linear_ok,angular_ok)
    }

    fn velocity(&self, space:u64, base:u64, sample:&PoseSample)
        -> Option<(xr::Vector3f,xr::Vector3f,xr::SpaceVelocityFlags)> {
        let (space,base) = (self.spaces.get(&space)?,self.spaces.get(&base)?);
        let zero = vector([0.;3]);
        let all = xr::SpaceVelocityFlags::LINEAR_VALID|xr::SpaceVelocityFlags::ANGULAR_VALID;
        if self.same_entity(space, base) {return Some((zero,zero,all));}
        let ((a,a_ok),(b,b_ok)) = (self.in_stage(space,sample),self.in_stage(base,sample));
        if !a_ok || !b_ok {return Some((zero,zero,xr::SpaceVelocityFlags::EMPTY));}
        let ((va,wa,la,aa),(vb,wb,lb,ab)) = (self.motion(space,sample),self.motion(base,sample));
        let rotation = inverse(b).orientation;
        let radius = sub(a.position,b.position);
        let same_origin = radius.x == 0. && radius.y == 0. && radius.z == 0.;
        let mut linear = rotate(rotation,sub(sub(va,vb),cross(wb,radius)));
        let mut angular = rotate(rotation,sub(wa,wb));
        let finite = |v:xr::Vector3f| [v.x,v.y,v.z].iter().all(|x|x.is_finite());
        let mut flags = xr::SpaceVelocityFlags::EMPTY;
        if la && lb && (same_origin || ab) && finite(linear) {flags |= xr::SpaceVelocityFlags::LINEAR_VALID;}
        else {linear=zero;}
        if aa && ab && finite(angular) {flags |= xr::SpaceVelocityFlags::ANGULAR_VALID;}
        else {angular=zero;}
        Some((linear,angular,flags))
    }

}

fn flags(tracked: bool) -> xr::SpaceLocationFlags {
    if tracked {
        xr::SpaceLocationFlags::ORIENTATION_VALID
            | xr::SpaceLocationFlags::POSITION_VALID
            | xr::SpaceLocationFlags::ORIENTATION_TRACKED
            | xr::SpaceLocationFlags::POSITION_TRACKED
    } else {
        xr::SpaceLocationFlags::EMPTY
    }
}

unsafe extern "system" fn locate_space(
    space: xr::Space,
    base: xr::Space,
    time: xr::Time,
    out: *mut xr::SpaceLocation,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if time.as_nanos() <= 0 {
        return xr::Result::ERROR_TIME_INVALID;
    }
    let found = with(|r| {
        r.refresh_lifecycle();
        let s = r.session.as_mut()?;
        if !s.spaces.contains_key(&space.into_raw()) || !s.spaces.contains_key(&base.into_raw()) {
            return None;
        }
        let sample = s.pose_sample(time.as_nanos());
        let (pose, location_flags) = s.locate(space.into_raw(), base.into_raw(), &sample)?;
        Some((
            pose,
            location_flags,
            s.velocity(space.into_raw(), base.into_raw(), &sample),
        ))
    });
    let Some((pose, location_flags, velocity)) = found else {
        return xr::Result::ERROR_HANDLE_INVALID;
    };
    out.location_flags = location_flags;
    out.pose = pose;
    let mut next = out.next.cast::<xr::BaseOutStructure>();
    for _ in 0..32 {
        if next.is_null() {
            break;
        }
        let (ty, following) = unsafe { ((*next).ty, (*next).next) };
        if ty == xr::SpaceVelocity::TYPE {
            let output = unsafe { &mut *next.cast::<xr::SpaceVelocity>() };
            output.velocity_flags = xr::SpaceVelocityFlags::EMPTY;
            output.linear_velocity = vector([0.0; 3]);
            output.angular_velocity = vector([0.0; 3]);
            if let Some((linear, angular, flags)) = velocity {
                output.velocity_flags = flags;
                output.linear_velocity = linear;
                output.angular_velocity = angular;
            }
        }
        next = following;
    }
    xr::Result::SUCCESS
}

unsafe extern "system" fn locate_spaces(
    session: xr::Session,
    info: *const xr::SpacesLocateInfo,
    out: *mut xr::SpaceLocations,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.time.as_nanos() <= 0 {
        return xr::Result::ERROR_TIME_INVALID;
    }
    if out.location_count < info.space_count
        || (info.space_count > 0 && (out.locations.is_null() || info.spaces.is_null()))
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| {
        r.refresh_lifecycle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if !s.spaces.contains_key(&info.base_space.into_raw()) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        let sample = s.pose_sample(info.time.as_nanos());
        let mut velocities = std::ptr::null_mut::<xr::SpaceVelocities>();
        let mut next = out.next.cast::<xr::BaseOutStructure>();
        for _ in 0..32 {
            if next.is_null() {
                break;
            }
            let (ty, following) = unsafe { ((*next).ty, (*next).next) };
            if ty == xr::SpaceVelocities::TYPE {
                let value = unsafe { &*next.cast::<xr::SpaceVelocities>() };
                if value.velocity_count < info.space_count
                    || (info.space_count > 0 && value.velocities.is_null())
                {
                    return xr::Result::ERROR_VALIDATION_FAILURE;
                }
                velocities = next.cast();
            }
            next = following;
        }
        for i in 0..info.space_count as usize {
            // SAFETY: the caller's arrays hold `space_count` entries (checked above).
            let space = unsafe { *info.spaces.add(i) };
            let Some((pose, location_flags)) =
                s.locate(space.into_raw(), info.base_space.into_raw(), &sample)
            else {
                return xr::Result::ERROR_HANDLE_INVALID;
            };
            unsafe {
                out.locations.add(i).write(xr::SpaceLocationData {
                    location_flags,
                    pose,
                });
                if !velocities.is_null() {
                    let output = (*velocities).velocities.add(i);
                    *output = xr::SpaceVelocityData::default();
                    if let Some((linear, angular, flags)) =
                        s.velocity(space.into_raw(), info.base_space.into_raw(), &sample)
                    {
                        (*output).velocity_flags = flags;
                        (*output).linear_velocity = linear;
                        (*output).angular_velocity = angular;
                    }
                }
            }
        }
        xr::Result::SUCCESS
    })
}

// --- Swapchains ----------------------------------------------------------------------------------

unsafe extern "system" fn enumerate_swapchain_formats(
    session: xr::Session,
    capacity: u32,
    count: *mut u32,
    out: *mut i64,
) -> xr::Result {
    let formats = match with(|r| {
        r.session(session).map(|s| {
            if s.vulkan.is_null() {
                FORMATS
            } else {
                VULKAN_FORMATS
            }
        })
    }) {
        Ok(f) => f,
        Err(e) => return e,
    };
    unsafe { crate::two_call(&formats, capacity, count, out) }
}

unsafe extern "system" fn create_swapchain(
    session: xr::Session,
    info: *const xr::SwapchainCreateInfo,
    out: *mut xr::Swapchain,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = xr::Swapchain::NULL;
    if info.ty != xr::SwapchainCreateInfo::TYPE
        || info.create_flags.into_raw()
            & !(xr::SwapchainCreateFlags::STATIC_IMAGE
                | xr::SwapchainCreateFlags::PROTECTED_CONTENT)
                .into_raw()
            != 0
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    if info
        .create_flags
        .contains(xr::SwapchainCreateFlags::PROTECTED_CONTENT)
    {
        // The current transport reads pixels on the CPU, so it cannot promise
        // protected storage. Never silently create an unprotected image.
        return xr::Result::ERROR_FEATURE_UNSUPPORTED;
    }
    let static_image = info
        .create_flags
        .contains(xr::SwapchainCreateFlags::STATIC_IMAGE);
    if info.width == 0
        || info.height == 0
        || info.width > bridge::MAX_IMAGE_SIDE * 2
        || info.height > bridge::MAX_IMAGE_SIDE
        || info.face_count != 1
        || info.array_size == 0
        || info.array_size > 2
    {
        return xr::Result::ERROR_FEATURE_UNSUPPORTED;
    }
    with(|r| {
        let handle = r.handle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        let vulkan = !s.vulkan.is_null();
        if !(if vulkan { &VULKAN_FORMATS } else { &FORMATS }).contains(&info.format) {
            return xr::Result::ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
        }
        let supported_usage = xr::SwapchainUsageFlags::COLOR_ATTACHMENT
            | xr::SwapchainUsageFlags::UNORDERED_ACCESS
            | xr::SwapchainUsageFlags::TRANSFER_SRC
            | xr::SwapchainUsageFlags::TRANSFER_DST
            | xr::SwapchainUsageFlags::SAMPLED
            | xr::SwapchainUsageFlags::MUTABLE_FORMAT;
        // Unsupported usage must fail before allocation, rather than promise
        // input/depth/unknown graphics semantics the runtime does not expose.
        if info.usage_flags.into_raw() & !supported_usage.into_raw() != 0 {
            return xr::Result::ERROR_FEATURE_UNSUPPORTED;
        }
        if info.mip_count != 1 || info.sample_count != 1 {
            return xr::Result::ERROR_FEATURE_UNSUPPORTED;
        }
        let textures: Vec<*mut c_void> = (0..if static_image { 1 } else { IMAGES })
            .map(|_| {
                // SAFETY: the session's device; the texture is ours until the swapchain goes.
                unsafe {
                    if vulkan {
                        hxvk_image(
                            s.vulkan,
                            info.format as u64,
                            info.width,
                            info.height,
                            info.array_size,
                            info.usage_flags.into_raw(),
                        )
                    } else {
                        hx_texture(
                            s.device,
                            info.format as u64,
                            info.width,
                            info.height,
                            info.array_size,
                            info.sample_count.max(1),
                            info.usage_flags.into_raw(),
                        )
                    }
                }
            })
            .collect();
        if textures.iter().any(|t| t.is_null()) {
            for t in textures {
                // SAFETY: ours, or null (which hx_release takes).
                unsafe {
                    if vulkan {
                        hxvk_destroy_image(t);
                    } else {
                        hx_release(t);
                    }
                };
            }
            return xr::Result::ERROR_RUNTIME_FAILURE;
        }
        s.swapchains.insert(
            handle,
            Swapchain {
                width: info.width,
                height: info.height,
                layers: info.array_size,
                vulkan,
                bgra: if vulkan {
                    info.format == 44 || info.format == 50
                } else {
                    info.format == 80 || info.format == 81
                },
                transfer: if (vulkan && (info.format == 50 || info.format == 43))
                    || (!vulkan && (info.format == 81 || info.format == 71))
                {
                    bridge::FRAME_COLOR_SRGB
                } else {
                    bridge::FRAME_COLOR_LINEAR
                },
                textures,
                next: 0,
                acquired: VecDeque::new(),
                waited: false,
                static_image,
                static_acquired: false,
                released: None,
            },
        );
        *out = xr::Swapchain::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn destroy_swapchain(swapchain: xr::Swapchain) -> xr::Result {
    with(|r| {
        match r
            .session
            .as_mut()
            .and_then(|s| s.swapchains.remove(&swapchain.into_raw()))
        {
            Some(chain) => {
                for texture in chain.textures {
                    // SAFETY: retained when the swapchain was made.
                    unsafe {
                        if chain.vulkan {
                            hxvk_destroy_image(texture);
                        } else {
                            hx_release(texture);
                        }
                    };
                }
                xr::Result::SUCCESS
            }
            None => xr::Result::ERROR_HANDLE_INVALID,
        }
    })
}

fn chain<R>(
    swapchain: xr::Swapchain,
    f: impl FnOnce(&mut Swapchain) -> R,
) -> Result<R, xr::Result> {
    with(|r| {
        r.session
            .as_mut()
            .and_then(|s| s.swapchains.get_mut(&swapchain.into_raw()))
            .map(f)
            .ok_or(xr::Result::ERROR_HANDLE_INVALID)
    })
}

unsafe extern "system" fn enumerate_swapchain_images(
    swapchain: xr::Swapchain,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::SwapchainImageBaseHeader,
) -> xr::Result {
    let Some(count) = (unsafe { count.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let (textures, vulkan) = match chain(swapchain, |c| (c.textures.clone(), c.vulkan)) {
        Ok(t) => t,
        Err(e) => return e,
    };
    *count = textures.len() as u32;
    if capacity == 0 {
        return xr::Result::SUCCESS;
    }
    if (capacity as usize) < textures.len() {
        return xr::Result::ERROR_SIZE_INSUFFICIENT;
    }
    if out.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    if vulkan {
        let out = out.cast::<xr::SwapchainImageVulkanKHR>();
        for (i, texture) in textures.iter().enumerate() {
            if unsafe { (*out.add(i)).ty } != xr::SwapchainImageVulkanKHR::TYPE {
                return xr::Result::ERROR_VALIDATION_FAILURE;
            }
            unsafe { (*out.add(i)).image = hxvk_image_handle(*texture) };
        }
    } else {
        let out = out.cast::<xr::SwapchainImageMetalKHR>();
        for (i, texture) in textures.iter().enumerate() {
            if unsafe { (*out.add(i)).ty } != xr::SwapchainImageMetalKHR::TYPE {
                return xr::Result::ERROR_VALIDATION_FAILURE;
            }
            unsafe { (*out.add(i)).texture = *texture };
        }
    }
    xr::Result::SUCCESS
}

unsafe extern "system" fn acquire_swapchain_image(
    swapchain: xr::Swapchain,
    info: *const xr::SwapchainImageAcquireInfo,
    index: *mut u32,
) -> xr::Result {
    let Some(index) = (unsafe { index.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *index = u32::MAX;
    if !info.is_null() && unsafe { (*info).ty } != xr::SwapchainImageAcquireInfo::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    match chain(swapchain, |c| {
        if (c.static_image && c.static_acquired) || c.acquired.len() >= c.textures.len() {
            return Err(xr::Result::ERROR_CALL_ORDER_INVALID);
        }
        let i = c.next;
        if c.vulkan && unsafe { hxvk_prepare_image(c.textures[i]) } != 0 {
            return Err(xr::Result::ERROR_RUNTIME_FAILURE);
        }
        c.next = (c.next + 1) % c.textures.len();
        c.acquired.push_back(i);
        c.static_acquired = c.static_image;
        Ok(i as u32)
    }) {
        Ok(Ok(i)) => {
            *index = i;
            xr::Result::SUCCESS
        }
        Ok(Err(e)) | Err(e) => e,
    }
}

unsafe extern "system" fn wait_swapchain_image(
    swapchain: xr::Swapchain,
    info: *const xr::SwapchainImageWaitInfo,
) -> xr::Result {
    if info.is_null() || unsafe { (*info).ty } != xr::SwapchainImageWaitInfo::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    // An acquired image is never in use by the runtime: `xrEndFrame` has read it by the time
    // it returns.
    match chain(swapchain, |c| {
        if c.waited || c.acquired.is_empty() {
            return false;
        }
        c.waited = true;
        true
    }) {
        Ok(true) => xr::Result::SUCCESS,
        Ok(false) => xr::Result::ERROR_CALL_ORDER_INVALID,
        Err(e) => e,
    }
}

unsafe extern "system" fn release_swapchain_image(
    swapchain: xr::Swapchain,
    info: *const xr::SwapchainImageReleaseInfo,
) -> xr::Result {
    if !info.is_null() && unsafe { (*info).ty } != xr::SwapchainImageReleaseInfo::TYPE {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    match chain(swapchain, |c| {
        if !c.waited {
            return None;
        }
        let i = c.acquired.pop_front()?;
        c.waited = false;
        c.released = Some(i);
        Some(())
    }) {
        Ok(Some(())) => xr::Result::SUCCESS,
        Ok(None) => xr::Result::ERROR_CALL_ORDER_INVALID,
        Err(e) => e,
    }
}

// --- The frame loop ------------------------------------------------------------------------------

unsafe extern "system" fn wait_frame(
    session: xr::Session,
    _info: *const xr::FrameWaitInfo,
    out: *mut xr::FrameState,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    // Halliday's next display frame, looked for in short steps so other threads' calls get
    // through meanwhile; a quarter of a second without one (Halliday busy, or gone) and the
    // application goes on with the state it has.
    let start = Instant::now();
    loop {
        let step = with(|r| {
            r.refresh_lifecycle();
            let s = match r.session(session) {
                Ok(s) => s,
                Err(e) => return Err(e),
            };
            if !s.running {
                return Err(xr::Result::ERROR_SESSION_NOT_RUNNING);
            }
            // OpenXR permits the next WaitFrame on a separate thread, but it
            // must not return before BeginFrame consumes the previous wait.
            // Drop the runtime mutex between retries so BeginFrame, events and
            // normal session shutdown can continue while this caller waits.
            if s.waited {
                return Ok(None);
            }
            let late = s.state == xr::SessionState::STOPPING
                || start.elapsed() > Duration::from_millis(250);
            let state = match s.side.poll_frame_with_motion() {
                Some(state) => Some(state),
                None if late => s.side.wait_frame_with_motion(Duration::ZERO),
                None => None,
            };
            if state.is_none() && !late {
                return Ok(None);
            }
            if let Some((state,motion_mask)) = state {
                s.anchor_local(&state);
                s.newest = Some(state);
                s.newest_motion = motion_mask;
                if state.head.valid != 0 {
                    if s.given.len() == GIVEN {
                        s.given.pop_front();
                    }
                    s.given.push_back(state.head);
                }
            }
            let period = s.display_period_override
                .or_else(|| s.side.frame_interval_ns().map(|ns| ns as i64))
                .unwrap_or_else(|| (1e9 / f64::from(s.config.display_hz.clamp(20.0, 240.0))) as i64);
            let target = halliday_core::time::host_time_ns() + (period as f64 * FRAMES_AHEAD) as i64;
            // A shorter live interval reduces the horizon. Keep already returned
            // predictions ordered without adding another extrapolation stage.
            s.display_time = target.max(s.display_time.saturating_add(1));
            s.remember_pose_sample(PoseSample {
                time: s.display_time,
                state: s.newest.unwrap_or_default(),
                motion_mask: s.newest_motion,
                local: s.local,
            });
            s.waited = true;
            s.wait_space_epoch = s.space_epoch;
            Ok(Some((
                s.display_time,
                period,
                matches!(
                    s.state,
                    xr::SessionState::VISIBLE | xr::SessionState::FOCUSED
                ),
            )))
        });
        match step {
            Err(e) => return e,
            Ok(Some((time, period, should_render))) => {
                out.predicted_display_time = xr::Time::from_nanos(time);
                out.predicted_display_period = xr::Duration::from_nanos(period);
                out.should_render = should_render.into();
                return xr::Result::SUCCESS;
            }
            Ok(None) => std::thread::sleep(Duration::from_micros(500)),
        }
    }
}

unsafe extern "system" fn begin_frame(
    session: xr::Session,
    _info: *const xr::FrameBeginInfo,
) -> xr::Result {
    with(|r| {
        r.refresh_lifecycle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        if !s.waited {
            return xr::Result::ERROR_CALL_ORDER_INVALID;
        }
        s.waited = false;
        let discarded = s.begun;
        s.begun = true;
        s.frame_space_epoch = s.wait_space_epoch;
        if discarded {
            xr::Result::FRAME_DISCARDED
        } else {
            xr::Result::SUCCESS
        }
    })
}

/// One eye of a frame to show: where it is in which texture.
#[derive(Clone, Copy)]
struct Eye {
    texture: *mut c_void,
    slice: u32,
    x: u32,
    y: u32,
    bgra: bool,
    transfer: u32,
}

fn composition_flags(value: xr::CompositionLayerFlags) -> Result<u32, xr::Result> {
    let supported = xr::CompositionLayerFlags::CORRECT_CHROMATIC_ABERRATION
        | xr::CompositionLayerFlags::BLEND_TEXTURE_SOURCE_ALPHA
        | xr::CompositionLayerFlags::UNPREMULTIPLIED_ALPHA;
    if value.into_raw() & !supported.into_raw() != 0 {
        return Err(xr::Result::ERROR_LAYER_INVALID);
    }
    Ok(
        u32::from(value.contains(xr::CompositionLayerFlags::BLEND_TEXTURE_SOURCE_ALPHA))
            | (u32::from(value.contains(xr::CompositionLayerFlags::UNPREMULTIPLIED_ALPHA)) << 1),
    )
}

fn validate_projection_view(view: &xr::CompositionLayerProjectionView) -> Result<(), xr::Result> {
    if view.ty != xr::CompositionLayerProjectionView::TYPE {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    }
    if !view.next.is_null() {
        return Err(xr::Result::ERROR_LAYER_INVALID);
    }
    if !valid_action_offset(view.pose) {
        return Err(xr::Result::ERROR_POSE_INVALID);
    }
    // Bounds are exclusive. Reversed pairs are legal horizontal/vertical
    // image flips (XrFovf); do not mistake them for malformed FOV values.
    if [view.fov.angle_left, view.fov.angle_right, view.fov.angle_up, view.fov.angle_down]
        .iter().any(|angle| !angle.is_finite() || angle.abs() >= std::f32::consts::FRAC_PI_2) {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    }
    Ok(())
}

fn flip_projection_pixels(pixels: &mut [u8], width: u32, height: u32, horizontal: bool, vertical: bool) {
    let row_bytes = width as usize * 4;
    debug_assert_eq!(pixels.len(), row_bytes * height as usize);
    if vertical {
        for y in 0..height as usize / 2 {
            let opposite = height as usize - 1 - y;
            let (top, bottom) = pixels.split_at_mut(opposite * row_bytes);
            top[y * row_bytes..(y + 1) * row_bytes].swap_with_slice(&mut bottom[..row_bytes]);
        }
    }
    if horizontal {
        for row in pixels.chunks_exact_mut(row_bytes) {
            for x in 0..width as usize / 2 {
                for channel in 0..4 { row.swap(x * 4 + channel, (width as usize - 1 - x) * 4 + channel); }
            }
        }
    }
}

impl Session {
    fn projection_views(&self, space: &Space, sample: &PoseSample,
                        views: &[xr::CompositionLayerProjectionView]) -> Option<[bridge::projection::View; 2]> {
        let (base, known) = self.in_stage(space, sample);
        if !known || views.len() != 2 { return None; }
        Some([projection_geometry::view(base, &views[0]), projection_geometry::view(base, &views[1])])
    }

    fn submitted_image(
        &self,
        sub: &xr::SwapchainSubImage,
    ) -> Result<(Eye, (u32, u32)), xr::Result> {
        let chain = self
            .swapchains
            .get(&sub.swapchain.into_raw())
            .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
        let image = chain.released.ok_or(xr::Result::ERROR_LAYER_INVALID)?;
        let rect = sub.image_rect;
        if rect.offset.x < 0
            || rect.offset.y < 0
            || rect.extent.width <= 0
            || rect.extent.height <= 0
            || sub.image_array_index >= chain.layers
        {
            return Err(xr::Result::ERROR_SWAPCHAIN_RECT_INVALID);
        }
        let (x, y, w, h) = (
            rect.offset.x as u32,
            rect.offset.y as u32,
            rect.extent.width as u32,
            rect.extent.height as u32,
        );
        if x > chain.width || y > chain.height || w > chain.width - x || h > chain.height - y {
            return Err(xr::Result::ERROR_SWAPCHAIN_RECT_INVALID);
        }
        Ok((
            Eye {
                texture: chain.textures[image],
                slice: sub.image_array_index,
                x,
                y,
                bgra: chain.bgra,
                transfer: chain.transfer,
            },
            (w, h),
        ))
    }

    fn ensure_scratch(&mut self, bytes: u64) -> Result<(), xr::Result> {
        if self.vulkan.is_null() && self.scratch_bytes < bytes {
            let replacement = unsafe { hx_buffer(self.device, bytes) };
            if replacement.is_null() {
                return Err(xr::Result::ERROR_RUNTIME_FAILURE);
            }
            unsafe {
                hx_release(self.scratch);
                self.scratch = replacement;
            }
            self.scratch_bytes = bytes;
        }
        Ok(())
    }
}

#[derive(Clone, Copy)]
struct SubmittedPanel {
    image: Eye,
    image_size: (u32, u32),
    pose: bridge::Pose,
    width_m: f32,
    height_m: f32,
    eye_visibility: u32,
    flags: u32,
    order: u32,
    anchor: u32,
}

unsafe extern "system" fn end_frame(
    session: xr::Session,
    info: *const xr::FrameEndInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    with(|r| {
        r.refresh_lifecycle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        if !s.begun {
            return xr::Result::ERROR_CALL_ORDER_INVALID;
        }
        s.begun = false;
        if s.state == xr::SessionState::STOPPING || s.frame_space_epoch != s.space_epoch {
            return xr::Result::SUCCESS;
        }
        if info.display_time.as_nanos() <= 0 {
            return xr::Result::ERROR_TIME_INVALID;
        }
        if info.environment_blend_mode != xr::EnvironmentBlendMode::OPAQUE {
            return xr::Result::ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED;
        }
        if info.layer_count > (bridge::OVERLAYS + 1) as u32 {
            return xr::Result::ERROR_LAYER_LIMIT_EXCEEDED;
        }
        if !info.next.is_null() || (info.layer_count > 0 && info.layers.is_null()) {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        // All layer pointers/geometry are checked before any pixels or metadata
        // are published. Preserve their exact array order, including panels
        // below the projection and quad-only menu frames.
        let sample = s.pose_sample(info.display_time.as_nanos());
        let mut projection = None;
        let mut panels = Vec::<SubmittedPanel>::new();
        for order in 0..info.layer_count as usize {
            let pointer = unsafe { *info.layers.add(order) };
            let Some(header) = (unsafe { pointer.as_ref() }) else {
                return xr::Result::ERROR_LAYER_INVALID;
            };
            if !header.next.is_null() {
                return xr::Result::ERROR_LAYER_INVALID;
            }
            let layer_flags = match composition_flags(header.layer_flags) {
                Ok(flags) => flags,
                Err(e) => return e,
            };
            if !s.spaces.contains_key(&header.space.into_raw()) {
                return xr::Result::ERROR_HANDLE_INVALID;
            }
            match header.ty {
                xr::StructureType::COMPOSITION_LAYER_PROJECTION => {
                    if projection.is_some() {
                        return xr::Result::ERROR_LAYER_LIMIT_EXCEEDED;
                    }
                    let layer = unsafe { &*pointer.cast::<xr::CompositionLayerProjection>() };
                    if layer.view_count != 2 || layer.views.is_null() {
                        return xr::Result::ERROR_VALIDATION_FAILURE;
                    }
                    projection = Some((layer, order as u32, layer_flags));
                }
                xr::StructureType::COMPOSITION_LAYER_QUAD => {
                    if !s.side.supports_panels() {
                        return xr::Result::ERROR_FEATURE_UNSUPPORTED;
                    }
                    if panels.len() == bridge::OVERLAYS {
                        return xr::Result::ERROR_LAYER_LIMIT_EXCEEDED;
                    }
                    let quad = unsafe { &*pointer.cast::<xr::CompositionLayerQuad>() };
                    if !valid_action_offset(quad.pose) {
                        return xr::Result::ERROR_POSE_INVALID;
                    }
                    if !quad.size.width.is_finite()
                        || !quad.size.height.is_finite()
                        || quad.size.width <= 0.0
                        || quad.size.height <= 0.0
                    {
                        return xr::Result::ERROR_LAYER_INVALID;
                    }
                    let eye_visibility = match quad.eye_visibility {
                        xr::EyeVisibility::BOTH => 0,
                        xr::EyeVisibility::LEFT => 1,
                        xr::EyeVisibility::RIGHT => 2,
                        _ => return xr::Result::ERROR_LAYER_INVALID,
                    };
                    let (image, size) = match s.submitted_image(&quad.sub_image) {
                        Ok(value) => value,
                        Err(e) => return e,
                    };
                    if size.0 as usize * size.1 as usize * 4 > bridge::OVERLAY_BYTES {
                        return xr::Result::ERROR_LIMIT_REACHED;
                    }
                    let space = s.spaces.get(&quad.space.into_raw()).unwrap();
                    let (pose, anchor) = if space.kind == SpaceKind::View {
                        (compose(space.offset, quad.pose), 1)
                    } else {
                        let (base, known) = s.in_stage(space, &sample);
                        if !known {
                            continue;
                        } // An unavailable tracked space contributes no layer.
                        (compose(base, quad.pose), 0)
                    };
                    let mut tagged = sample.state.head;
                    tagged.position = [pose.position.x, pose.position.y, pose.position.z];
                    tagged.orientation = [
                        pose.orientation.x,
                        pose.orientation.y,
                        pose.orientation.z,
                        pose.orientation.w,
                    ];
                    panels.push(SubmittedPanel {
                        image,
                        image_size: size,
                        pose: tagged,
                        width_m: quad.size.width,
                        height_m: quad.size.height,
                        eye_visibility,
                        flags: layer_flags,
                        order: order as u32,
                        anchor,
                    });
                }
                _ => return xr::Result::ERROR_LAYER_INVALID,
            }
        }
        let mut eyes = None;
        let mut size = (8, 8); // Quad-only frame: transport ticket, never displayed as a projection.
        let mut pose = sample.state.head;
        let mut projection_order = None;
        let mut projection_flags = 0;
        let mut projection_geometry = None;
        let mut transfers = [bridge::FRAME_COLOR_SRGB; 2];
        let mut bgra = false;
        let mut projection_flips = [(false, false); 2];
        if let Some((layer, order, flags)) = projection {
            let views = unsafe { std::slice::from_raw_parts(layer.views, 2) };
            for (eye, view) in views.iter().enumerate() {
                if let Err(error) = validate_projection_view(view) { return error; }
                projection_flips[eye] = (view.fov.angle_left > view.fov.angle_right,
                                        view.fov.angle_down > view.fov.angle_up);
            }
            let left = match s.submitted_image(&views[0].sub_image) {
                Ok(value) => value,
                Err(e) => return e,
            };
            let right = match s.submitted_image(&views[1].sub_image) {
                Ok(value) => value,
                Err(e) => return e,
            };
            if left.1 != right.1 || !bridge::fits(left.1.0, left.1.1) {
                return xr::Result::ERROR_SWAPCHAIN_RECT_INVALID;
            }
            let space = s.spaces.get(&layer.space.into_raw()).unwrap();
            if let Some(geometry) = s.projection_views(space, &sample, views) {
                if geometry.iter().any(|view| !view.valid()) { return xr::Result::ERROR_LAYER_INVALID; }
                let head = xr::Posef {
                    orientation: xr::Quaternionf { x: geometry[0].orientation[0], y: geometry[0].orientation[1],
                        z: geometry[0].orientation[2], w: geometry[0].orientation[3] },
                    position: xr::Vector3f {
                        x: (geometry[0].position[0] + geometry[1].position[0]) * 0.5,
                        y: (geometry[0].position[1] + geometry[1].position[1]) * 0.5,
                        z: (geometry[0].position[2] + geometry[1].position[2]) * 0.5,
                    },
                };
                pose = drawn_for(&s.given, head, sample.state.head);
                if s.side.has_projection_geometry() { projection_geometry = Some(geometry); }
                else if !projection_geometry::legacy_compatible(&geometry, pose, &s.config) {
                    // An older peer cannot place custom cameras/FOV correctly.
                    // Reject before GPU work instead of silently stretching it.
                    return xr::Result::ERROR_LAYER_INVALID;
                }
                size = left.1;
                bgra = left.0.bgra;
                transfers = [left.0.transfer, right.0.transfer];
                eyes = Some([left.0, right.0]);
                projection_order = Some(order);
                projection_flags = flags;
            } // An unlocatable layer space contributes no projection.
        }
        if (!panels.is_empty() || projection_flags & bridge::panels::SOURCE_ALPHA != 0)
            && !s.side.supports_panels()
        {
            // Ordered/transparent layers cannot degrade to an ordinary opaque
            // projection. Pure empty frames may still use legacy black pixels.
            return xr::Result::ERROR_LAYER_INVALID;
        }
        let bytes = size.0 as usize * size.1 as usize * 4;
        let batch_bytes = panels
            .iter()
            .map(|p| p.image_size.0 as usize * p.image_size.1 as usize * 4)
            .sum::<usize>()
            + if eyes.is_some() { bytes * 2 } else { 0 };
        if let Err(e) = s.ensure_scratch(batch_bytes as u64) {
            return e;
        }
        let empty_read = ReadbackRequest {
            image: std::ptr::null_mut(),
            slice: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            output: std::ptr::null_mut(),
        };
        let mut reads = [empty_read; 10];
        let mut read_count = 0;
        for eye in 0..2 {
            s.readback[eye].resize(bytes, 0);
            if let Some(images) = eyes {
                reads[read_count] = ReadbackRequest {
                    image: images[eye].texture,
                    slice: images[eye].slice,
                    x: images[eye].x,
                    y: images[eye].y,
                    width: size.0,
                    height: size.1,
                    output: s.readback[eye].as_mut_ptr(),
                };
                read_count += 1;
            } else {
                s.readback[eye].fill(0);
            }
        }
        for (i, panel) in panels.iter().enumerate() {
            let bytes = panel.image_size.0 as usize * panel.image_size.1 as usize * 4;
            s.panel_readback[i].resize(bytes, 0);
            reads[read_count] = ReadbackRequest {
                image: panel.image.texture,
                slice: panel.image.slice,
                x: panel.image.x,
                y: panel.image.y,
                width: panel.image_size.0,
                height: panel.image_size.1,
                output: s.panel_readback[i].as_mut_ptr(),
            };
            read_count += 1;
        }
        if !s.vulkan.is_null() && read_count != 0 {
            // Both eyes and every quad share one ordered submission/fence.
            // The bounded request array borrows stable, already-sized outputs.
            if unsafe { hxvk_read_batch(s.vulkan, reads.as_ptr(), read_count as u32) } != 0 {
                return xr::Result::ERROR_RUNTIME_FAILURE;
            }
        } else if read_count != 0 {
            if unsafe { hx_read_batch(s.queue, s.scratch, reads.as_ptr(), read_count as u32) } != 0
            {
                return xr::Result::ERROR_RUNTIME_FAILURE;
            }
        }
        if let Some(images) = eyes {
            for eye in 0..2 {
                let (horizontal, vertical) = projection_flips[eye];
                if horizontal || vertical {
                    flip_projection_pixels(&mut s.readback[eye], size.0, size.1, horizontal, vertical);
                }
                if images[eye].bgra != bgra {
                    for pixel in s.readback[eye].chunks_exact_mut(4) {
                        pixel.swap(0, 2);
                    }
                }
            }
        }
        let images: Vec<_> = panels
            .iter()
            .enumerate()
            .map(|(i, panel)| PanelImage {
                pose: panel.pose,
                width_m: panel.width_m,
                height_m: panel.height_m,
                eye_visibility: panel.eye_visibility,
                flags: panel.flags,
                order: panel.order,
                anchor: panel.anchor,
                color_space: panel.image.transfer,
                bgra: panel.image.bgra,
                image_width: panel.image_size.0,
                image_height: panel.image_size.1,
                pixels: &s.panel_readback[i],
            })
            .collect();
        s.side.see_through = projection_flags & bridge::panels::SOURCE_ALPHA != 0;
        let readback = &s.readback;
        let published = s.side.submit_layers_with_geometry(
            pose,
            size,
            false,
            bgra,
            if s.vulkan.is_null() { 6 } else { 2 },
            transfers,
            projection_order,
            projection_flags,
            projection_geometry.as_ref(),
            &images,
            |eye, pixels| pixels.copy_from_slice(&readback[eye]),
        );
        if published {
            s.frames += 1;
        }
        // A host-held panel picture makes the bounded transport drop this frame
        // without mutating the preceding frame. The application keeps running.
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn locate_views(
    session: xr::Session,
    info: *const xr::ViewLocateInfo,
    state: *mut xr::ViewState,
    capacity: u32,
    count: *mut u32,
    views: *mut xr::View,
) -> xr::Result {
    let (Some(info), Some(state), Some(count)) = (
        unsafe { info.as_ref() },
        unsafe { state.as_mut() },
        unsafe { count.as_mut() },
    ) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.view_configuration_type != xr::ViewConfigurationType::PRIMARY_STEREO {
        return xr::Result::ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    }
    if info.display_time.as_nanos() <= 0 {
        return xr::Result::ERROR_TIME_INVALID;
    }
    *count = 2;
    if capacity > 0 && views.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| {
        r.refresh_lifecycle();
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        let Some(base) = s.spaces.get(&info.space.into_raw()).copied() else {
            return xr::Result::ERROR_HANDLE_INVALID;
        };
        let sample = s.pose_sample(info.display_time.as_nanos());
        let newest = sample.state;
        let (base, base_ok) = s.in_stage(&base, &sample);
        let head = compose(inverse(base), from_bridge(&newest.head));
        let tracked = base_ok
            && newest.head.valid != 0
            && s.side.halliday_alive()
            && !matches!(
                s.state,
                xr::SessionState::STOPPING
                    | xr::SessionState::EXITING
                    | xr::SessionState::LOSS_PENDING
            );
        state.view_state_flags = if tracked {
            xr::ViewStateFlags::ORIENTATION_VALID
                | xr::ViewStateFlags::POSITION_VALID
                | xr::ViewStateFlags::ORIENTATION_TRACKED
                | xr::ViewStateFlags::POSITION_TRACKED
        } else {
            xr::ViewStateFlags::EMPTY
        };
        // The zero-capacity count query still returns confidence and validates
        // the session/base, and seeds the same complete display-time sample as
        // a subsequent data query. It only omits writing the view array.
        if capacity == 0 {
            return xr::Result::SUCCESS;
        }
        if capacity < 2 {
            return xr::Result::ERROR_SIZE_INSUFFICIENT;
        }
        for eye in 0..2 {
            let side = if eye == 0 { -0.5 } else { 0.5 };
            let offset = xr::Posef {
                position: xr::Vector3f {
                    x: side * s.config.ipd,
                    y: 0.0,
                    z: 0.0,
                },
                ..IDENTITY
            };
            let t = s.config.tangents[eye];
            // SAFETY: the caller's array of at least two views (checked above).
            let view = unsafe { &mut *views.add(eye) };
            view.pose = compose(head, offset);
            view.fov = xr::Fovf {
                angle_left: t[0].atan(),
                angle_right: t[1].atan(),
                angle_up: t[2].atan(),
                angle_down: t[3].atan(),
            };
        }
        xr::Result::SUCCESS
    })
}

// --- Paths and actions ---------------------------------------------------------------------------

unsafe extern "system" fn string_to_path(
    _instance: xr::Instance,
    string: *const c_char,
    out: *mut xr::Path,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if string.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let Ok(text) = unsafe { CStr::from_ptr(string) }.to_str() else {
        return xr::Result::ERROR_PATH_FORMAT_INVALID;
    };
    if !text.starts_with('/') {
        return xr::Result::ERROR_PATH_FORMAT_INVALID;
    }
    *out = with(|r| {
        if let Some((&handle, _)) = r.paths.iter().find(|(_, p)| p.as_str() == text) {
            return xr::Path::from_raw(handle);
        }
        let handle = r.handle();
        r.paths.insert(handle,text.to_owned());
        xr::Path::from_raw(handle)
    });
    xr::Result::SUCCESS
}

unsafe extern "system" fn path_to_string(
    _instance: xr::Instance,
    path: xr::Path,
    capacity: u32,
    count: *mut u32,
    out: *mut c_char,
) -> xr::Result {
    let Some(text) = with(|r| {
        r.paths
            .get(&path.into_raw())
            .cloned()
    }) else {
        return xr::Result::ERROR_PATH_INVALID;
    };
    let mut bytes: Vec<c_char> = text.bytes().map(|b| b as c_char).collect();
    bytes.push(0);
    unsafe { crate::two_call(&bytes, capacity, count, out) }
}

unsafe extern "system" fn create_action_set(
    _instance: xr::Instance,
    info: *const xr::ActionSetCreateInfo,
    out: *mut xr::ActionSet,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = with(|r| {
        let handle = r.handle();
        r.action_sets.insert(
            handle,
            ActionSet {
                priority: info.priority,
                handle_alive: true,
                attached: false,
            },
        );
        xr::ActionSet::from_raw(handle)
    });
    xr::Result::SUCCESS
}

unsafe extern "system" fn destroy_action_set(set: xr::ActionSet) -> xr::Result {
    with(|r| {
        let handle = set.into_raw();
        if !r.public_action_set(handle) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        r.action_sets.get_mut(&handle).unwrap().handle_alive = false;
        let children = r
            .actions
            .iter()
            .filter_map(|(h, a)| (a.set == handle).then_some(*h))
            .collect::<Vec<_>>();
        for action in children {
            r.actions.get_mut(&action).unwrap().handle_alive = false;
        }
        // Attached sessions and existing action spaces own the backing objects.
        // Invalidating the public handle must not invalidate those references.
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn create_action(
    set: xr::ActionSet,
    info: *const xr::ActionCreateInfo,
    out: *mut xr::Action,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    with(|r| {
        if !r.public_action_set(set.into_raw()) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        if r.action_sets.get(&set.into_raw()).is_some_and(|set| set.attached) {
            return xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED;
        }
        if !matches!(
            info.action_type,
            xr::ActionType::BOOLEAN_INPUT
                | xr::ActionType::FLOAT_INPUT
                | xr::ActionType::VECTOR2F_INPUT
                | xr::ActionType::POSE_INPUT
                | xr::ActionType::VIBRATION_OUTPUT
        ) {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        if info.count_subaction_paths > 0 && info.subaction_paths.is_null() {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        let subactions = if info.count_subaction_paths == 0 {
            Vec::new()
        } else {
            // SAFETY: the caller supplied this array; its count/pointer were checked.
            unsafe {
                std::slice::from_raw_parts(
                    info.subaction_paths,
                    info.count_subaction_paths as usize,
                )
            }
            .iter()
            .map(|p| p.into_raw())
            .collect::<Vec<_>>()
        };
        for path in &subactions {
            if *path == 0 || !r.paths.contains_key(path) {
                return xr::Result::ERROR_PATH_INVALID;
            }
        }
        if subactions
            .iter()
            .enumerate()
            .any(|(i, p)| subactions[..i].contains(p))
        {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        let handle = r.handle();
        r.actions.insert(
            handle,
            Action {
                handle_alive: true,
                kind: info.action_type,
                set: set.into_raw(),
                subactions,
            },
        );
        *out = xr::Action::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn destroy_action(action: xr::Action) -> xr::Result {
    with(|r| {
        let handle = action.into_raw();
        if r.public_action(handle).is_none() {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        r.actions.get_mut(&handle).unwrap().handle_alive = false;
        xr::Result::SUCCESS
    })
}

/// A part of a controller an action can read: what Halliday publishes of each hand (the Sense
/// controllers, or the hands the mouse and keyboard stand in for), under a Touch controller's
/// names, which is the profile Quest applications bind.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Part {
    Trigger,
    TriggerClick,
    Squeeze,
    Stick,
    StickX,
    StickY,
    StickClick,
    StickTouch,
    /// A or X (cross, square).
    Primary,
    /// B or Y (circle, triangle).
    Secondary,
    Menu,
    GripPose,
    AimPose,
    Haptic,
    TriggerTouch,
    SqueezeTouch,
    PrimaryTouch,
    SecondaryTouch,
    ThumbrestTouch,
}

#[derive(Clone, Copy)]
struct Binding {
    hand: usize,
    part: Part,
    path: u64,
}

struct SuggestedProfile {
    rank: u8,
    bindings: HashMap<u64, Vec<Binding>>,
}

impl Part {
    fn is_pose(self) -> bool {
        matches!(self, Self::GripPose | Self::AimPose)
    }

    /// A higher-priority set captures a physical input source, including its
    /// component paths. Keep grip and aim distinct even on the legacy bridge.
    fn source_group(self) -> u8 {
        match self {
            Self::Trigger | Self::TriggerClick | Self::TriggerTouch => 0,
            Self::Squeeze | Self::SqueezeTouch => 1,
            Self::Stick | Self::StickX | Self::StickY | Self::StickClick | Self::StickTouch => 2,
            Self::Primary | Self::PrimaryTouch => 3,
            Self::Secondary | Self::SecondaryTouch => 4,
            Self::Menu => 5,
            Self::GripPose => 6,
            Self::AimPose => 7,
            Self::Haptic => 8,
            Self::ThumbrestTouch => 9,
        }
    }
}

#[derive(Clone)]
struct Action {
    handle_alive: bool,
    kind: xr::ActionType,
    set: u64,
    subactions: Vec<u64>,
}

struct ActionSet {
    priority: u32,
    handle_alive: bool,
    /// Attachment makes the set immutable for its entire lifetime, including
    /// after the original session is destroyed and before another attaches it.
    attached: bool,
}

#[derive(Clone, Copy, Default)]
struct PoseSources {
    eligible: [bool; 2],
    kinds: [Option<Part>; 2],
    selected: Option<usize>,
}

fn choose_pose_source(previous: Option<usize>, eligible: [bool; 2]) -> Option<usize> {
    previous
        .filter(|&hand| hand < 2 && eligible[hand])
        .or_else(|| eligible.iter().position(|active| *active))
}

fn path_hand(paths: &HashMap<u64,String>, path: xr::Path) -> Result<usize, xr::Result> {
    let Some(path) = paths.get(&path.into_raw()) else {
        return Err(xr::Result::ERROR_PATH_INVALID);
    };
    match path.as_str() {
        "/user/hand/left" => Ok(0),
        "/user/hand/right" => Ok(1),
        _ => Err(xr::Result::ERROR_PATH_UNSUPPORTED),
    }
}

fn requested_hand(
    paths: &HashMap<u64,String>,
    action: &Action,
    path: xr::Path,
) -> Result<Option<usize>, xr::Result> {
    if path == xr::Path::NULL {
        return Ok(None);
    }
    let hand = path_hand(paths, path)?;
    if !action.subactions.contains(&path.into_raw()) {
        return Err(xr::Result::ERROR_PATH_UNSUPPORTED);
    }
    Ok(Some(hand))
}

fn action_allows_hand(paths: &HashMap<u64,String>, action: &Action, hand: usize) -> bool {
    action.subactions.is_empty()
        || action
            .subactions
            .iter()
            .any(|path| path_hand(paths, xr::Path::from_raw(*path)) == Ok(hand))
}

fn valid_action_offset(pose: xr::Posef) -> bool {
    let p = pose.position;
    let q = pose.orientation;
    [p.x, p.y, p.z, q.x, q.y, q.z, q.w]
        .iter()
        .all(|v| v.is_finite())
        && (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w - 1.0).abs() < 0.001
}

/// The bridge's button bits (OpenVR's `EVRButtonId`): system, menu, grip, A, touchpad, trigger.
const BIT_SYSTEM: u64 = 1 << 0;
const BIT_MENU: u64 = 1 << 1;
const BIT_GRIP: u64 = 1 << 2;
const BIT_A: u64 = 1 << 7;
const BIT_PAD: u64 = 1 << 32;
const BIT_TRIGGER: u64 = 1 << 33;

/// The hand (0 left, 1 right) and part a binding path names, if Halliday has it.
fn part(path: &str) -> Option<(usize, Part)> {
    let rest = path.strip_prefix("/user/hand/")?;
    let (hand, rest) = rest.split_once('/')?;
    let hand = match hand {
        "left" => 0,
        "right" => 1,
        _ => return None,
    };
    let part = match rest {
        "input/trigger/value" | "input/trigger" => {
            Part::Trigger
        }
        "input/trigger/click" | "input/select/click" => Part::TriggerClick,
        "input/squeeze/value" | "input/squeeze" | "input/squeeze/click" => Part::Squeeze,
        "input/thumbstick" | "input/trackpad" => Part::Stick,
        "input/thumbstick/x" | "input/trackpad/x" => Part::StickX,
        "input/thumbstick/y" | "input/trackpad/y" => Part::StickY,
        "input/thumbstick/click" | "input/trackpad/click" => Part::StickClick,
        "input/thumbstick/touch" | "input/trackpad/touch" => Part::StickTouch,
        "input/a/click" | "input/x/click" => Part::Primary,
        "input/b/click" | "input/y/click" => Part::Secondary,
        "input/menu/click" | "input/system/click" => Part::Menu,
        "input/grip/pose" => Part::GripPose,
        "input/aim/pose" => Part::AimPose,
        "output/haptic" => Part::Haptic,
        "input/trigger/touch" => Part::TriggerTouch,
        "input/squeeze/touch" => Part::SqueezeTouch,
        "input/a/touch" | "input/x/touch" => Part::PrimaryTouch,
        "input/b/touch" | "input/y/touch" => Part::SecondaryTouch,
        "input/thumbrest/touch" => Part::ThumbrestTouch,
        _ => return None,
    };
    Some((hand, part))
}

/// A part's value now: two numbers for the stick, one (0 to 1) for the rest.
fn read(c: &bridge::Controller, part: Part) -> [f32; 2] {
    let held = |bit: u64| f32::from(u8::from(c.pressed & bit != 0));
    match part {
        Part::Trigger | Part::TriggerClick => [c.axes[1][0].max(held(BIT_TRIGGER)), 0.0],
        Part::Squeeze => [c.axes[2][0].max(held(BIT_GRIP)), 0.0],
        Part::Stick => c.axes[0],
        Part::StickX => [c.axes[0][0], 0.0],
        Part::StickY => [c.axes[0][1], 0.0],
        Part::StickClick => [held(BIT_PAD), 0.0],
        Part::StickTouch => [f32::from(u8::from(c.touched & BIT_PAD != 0)), 0.0],
        Part::Primary => [held(BIT_A), 0.0],
        Part::Secondary => [held(BIT_MENU), 0.0],
        Part::Menu => [held(BIT_SYSTEM), 0.0],
        Part::TriggerTouch => [f32::from(u8::from(c.touched & BIT_TRIGGER != 0)), 0.0],
        Part::SqueezeTouch => [f32::from(u8::from(c.touched & BIT_GRIP != 0)), 0.0],
        Part::PrimaryTouch => [f32::from(u8::from(c.touched & BIT_A != 0)), 0.0],
        Part::SecondaryTouch => [f32::from(u8::from(c.touched & BIT_MENU != 0)), 0.0],
        Part::ThumbrestTouch => [0.0, 0.0], // No separate thumb-rest sensor in v6.
        Part::GripPose | Part::AimPose | Part::Haptic => [0.0, 0.0],
    }
}

/// Validate all suggestions before replacing a profile, including a lower-ranked
/// profile. Repeated calls for the selected profile replace its previous list.
unsafe extern "system" fn suggest_interaction_profile_bindings(
    _instance: xr::Instance,
    info: *const xr::InteractionProfileSuggestedBinding,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.ty != xr::InteractionProfileSuggestedBinding::TYPE
        || (info.count_suggested_bindings > 0 && info.suggested_bindings.is_null())
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let suggested = if info.count_suggested_bindings == 0 {
        &[][..]
    } else {
        unsafe {
            std::slice::from_raw_parts(
                info.suggested_bindings,
                info.count_suggested_bindings as usize,
            )
        }
    };
    with(|r| {
        let Some(profile) = r
            .paths
            .get(&info.interaction_profile.into_raw())
        else {
            return xr::Result::ERROR_PATH_INVALID;
        };
        let fit = match profile.as_str() {
            "/interaction_profiles/oculus/touch_controller" => 4,
            "/interaction_profiles/valve/index_controller" => 3,
            "/interaction_profiles/htc/vive_controller"
            | "/interaction_profiles/microsoft/motion_controller"
            | "/interaction_profiles/hp/mixed_reality_controller" => 2,
            "/interaction_profiles/khr/simple_controller" => 1,
            _ => return xr::Result::ERROR_PATH_UNSUPPORTED,
        };
        let mut bindings = HashMap::<u64, Vec<Binding>>::new();
        for binding in suggested {
            let Some(action) = r.public_action(binding.action.into_raw()) else {
                return xr::Result::ERROR_HANDLE_INVALID;
            };
            if r.action_sets.get(&action.set).is_some_and(|set| set.attached) {
                return xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED;
            }
            let Some(path) = r
                .paths
                .get(&binding.binding.into_raw())
            else {
                return xr::Result::ERROR_PATH_INVALID;
            };
            if let Some((hand, part)) = part(path) {
                let matches = if part.is_pose() {
                    action.kind == xr::ActionType::POSE_INPUT
                } else if part == Part::Haptic {
                    action.kind == xr::ActionType::VIBRATION_OUTPUT
                } else {
                    matches!(
                        action.kind,
                        xr::ActionType::BOOLEAN_INPUT
                            | xr::ActionType::FLOAT_INPUT
                            | xr::ActionType::VECTOR2F_INPUT
                    )
                };
                if !matches {
                    return xr::Result::ERROR_ACTION_TYPE_MISMATCH;
                }
                let entries = bindings.entry(binding.action.into_raw()).or_default();
                if !entries.iter().any(|b| b.path == binding.binding.into_raw()) {
                    entries.push(Binding {
                        hand,
                        part,
                        path: binding.binding.into_raw(),
                    });
                }
            } else {
                return xr::Result::ERROR_PATH_UNSUPPORTED;
            }
        }
        r.suggested_profiles.insert(info.interaction_profile.into_raw(),
            SuggestedProfile { rank: fit, bindings });
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn attach_session_action_sets(
    session: xr::Session,
    info: *const xr::SessionActionSetsAttachInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.count_action_sets == 0 || info.action_sets.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    // SAFETY: caller array, with pointer/count checked above.
    let sets =
        unsafe { std::slice::from_raw_parts(info.action_sets, info.count_action_sets as usize) };
    with(|r| {
        if let Err(e) = r.session(session) {
            return e;
        }
        if r.session.as_ref().unwrap().attached_sets.is_some() {
            return xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED;
        }
        if sets.iter().any(|s| !r.public_action_set(s.into_raw())) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        for set in sets {
            r.action_sets.get_mut(&set.into_raw()).unwrap().attached = true;
        }
        r.select_bindings(&sets.iter().map(|set| set.into_raw()).collect::<Vec<_>>());
        let s = r.session.as_mut().unwrap();
        s.attached_sets = Some(sets.iter().map(|s| s.into_raw()).collect());
        // The attachment event announces the initial anticipated profile.
        // Thereafter its connection-dependent selection changes only at Sync.
        s.profile_connected = Some(s.side.state_snapshot().or(s.newest)
            .unwrap_or_default().controllers.map(|c| c.connected != 0));
        r.events
            .push_back(RuntimeEvent::Profile(session.into_raw()));
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn get_current_interaction_profile(
    session: xr::Session,
    top_level: xr::Path,
    out: *mut xr::InteractionProfileState,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    with(|r| {
        let hand = match path_hand(&r.paths, top_level) {
            Ok(hand) => hand,
            Err(e) => return e,
        };
        let s = r.session.as_ref().unwrap();
        if s.attached_sets.is_none() {
            return xr::Result::ERROR_ACTIONSET_NOT_ATTACHED;
        }
        let connected = s.profile_connected.unwrap_or([false; 2]);
        out.interaction_profile = if !connected[hand] {
            xr::Path::NULL
        } else {
            r.selected_profiles[hand].map_or(xr::Path::NULL, xr::Path::from_raw)
        };
        xr::Result::SUCCESS
    })
}

/// Cached at xrSyncActions, including change time. Queries never re-read buttons
/// or manufacture a fresh timestamp between synchronization calls.
#[derive(Clone, Copy, Default)]
struct Reading {
    active: bool,
    now: [f32; 2],
    changed: bool,
    time: i64,
}

fn reading(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    expected_type: xr::ActionType,
) -> Result<Reading, xr::Result> {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    };
    if info.ty != xr::ActionStateGetInfo::TYPE {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    }
    with(|r| {
        r.refresh_lifecycle();
        r.session(session)?;
        let handle = info.action.into_raw();
        let action = r
            .public_action(handle)
            .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
        if action.kind != expected_type {
            return Err(xr::Result::ERROR_ACTION_TYPE_MISMATCH);
        }
        let hand = requested_hand(&r.paths, action, info.subaction_path)?;
        let s = r.session.as_ref().unwrap();
        if !s
            .attached_sets
            .as_ref()
            .is_some_and(|sets| sets.contains(&action.set))
        {
            return Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED);
        }
        if s.state != xr::SessionState::FOCUSED {
            return Ok(Reading::default());
        }
        Ok(s.readings.get(&(handle, hand)).copied().unwrap_or_default())
    })
}

fn aggregate_reading(
    action: &Action,
    paths: &HashMap<u64,String>,
    bindings: &[Binding],
    controllers: &[bridge::Controller; 2],
    active: [bool; 2],
    requested: Option<usize>,
    old: Reading,
    time: i64,
) -> Reading {
    let mut result = Reading::default();
    let size = |v: [f32; 2]| v[0] * v[0] + v[1] * v[1];
    for binding in bindings {
        let hand = binding.hand;
        if requested.is_some_and(|h| h != hand)
            || !active[hand]
            || !action_allows_hand(paths, action, hand)
            || controllers[hand].connected == 0
            || binding.part.is_pose()
            || binding.part == Part::Haptic
        {
            continue;
        }
        let mut value = read(&controllers[hand], binding.part);
        if action.kind == xr::ActionType::BOOLEAN_INPUT {
            value = [f32::from(u8::from(value[0] > 0.5)), 0.0];
        }
        if action.kind == xr::ActionType::FLOAT_INPUT {
            // The measured analog value is independent of the host's click
            // threshold. Keep Boolean/click conversion on its existing path.
            if binding.part == Part::Trigger {
                value[0] = controllers[hand].axes[1][0];
            }
            value[1] = 0.0;
        }
        if !result.active || size(value) > size(result.now) {
            result.now = value;
        }
        result.active = true;
    }
    if result.active {
        let differs = result.now != old.now;
        result.changed = old.active && differs;
        result.time = if differs { time } else { old.time };
    }
    result
}

unsafe extern "system" fn get_action_state_boolean(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    out: *mut xr::ActionStateBoolean,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let state = match reading(session, info, xr::ActionType::BOOLEAN_INPUT) {
        Ok(state) => state,
        Err(e) => return e,
    };
    out.current_state = (state.now[0] > 0.5).into();
    out.changed_since_last_sync = state.changed.into();
    out.last_change_time = xr::Time::from_nanos(state.time);
    out.is_active = state.active.into();
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_action_state_float(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    out: *mut xr::ActionStateFloat,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let state = match reading(session, info, xr::ActionType::FLOAT_INPUT) {
        Ok(state) => state,
        Err(e) => return e,
    };
    out.current_state = state.now[0];
    out.changed_since_last_sync = state.changed.into();
    out.last_change_time = xr::Time::from_nanos(state.time);
    out.is_active = state.active.into();
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_action_state_vector2f(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    out: *mut xr::ActionStateVector2f,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let state = match reading(session, info, xr::ActionType::VECTOR2F_INPUT) {
        Ok(state) => state,
        Err(e) => return e,
    };
    out.current_state = xr::Vector2f {
        x: state.now[0],
        y: state.now[1],
    };
    out.changed_since_last_sync = state.changed.into();
    out.last_change_time = xr::Time::from_nanos(state.time);
    out.is_active = state.active.into();
    xr::Result::SUCCESS
}

unsafe extern "system" fn get_action_state_pose(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    out: *mut xr::ActionStatePose,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    out.is_active = xr::FALSE;
    with(|r| {
        r.refresh_lifecycle();
        if let Err(e) = r.session(session) {
            return e;
        }
        let Some(action) = r.public_action(info.action.into_raw()).cloned() else {
            return xr::Result::ERROR_HANDLE_INVALID;
        };
        if action.kind != xr::ActionType::POSE_INPUT {
            return xr::Result::ERROR_ACTION_TYPE_MISMATCH;
        }
        let hand = match requested_hand(&r.paths, &action, info.subaction_path) {
            Ok(v) => v,
            Err(e) => return e,
        };
        let s = r.session.as_ref().unwrap();
        if !s
            .attached_sets
            .as_ref()
            .is_some_and(|sets| sets.contains(&action.set))
        {
            return xr::Result::ERROR_ACTIONSET_NOT_ATTACHED;
        }
        if s.state != xr::SessionState::FOCUSED || s.side.requests().1 {
            return xr::Result::SUCCESS;
        }
        if let Some(sources) = s.pose_sources.get(&info.action.into_raw()) {
            let selected = hand.or(sources.selected);
            out.is_active = selected.is_some_and(|hand| sources.eligible[hand]).into();
        }
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn sync_actions(
    session: xr::Session,
    info: *const xr::ActionsSyncInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.count_active_action_sets > 0 && info.active_action_sets.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let sets = if info.count_active_action_sets == 0 {
        &[][..]
    } else {
        // SAFETY: caller's checked pointer/count.
        unsafe {
            std::slice::from_raw_parts(
                info.active_action_sets,
                info.count_active_action_sets as usize,
            )
        }
    };
    with(|r| {
        r.refresh_lifecycle();
        if let Err(e) = r.session(session) {
            return e;
        }
        let attached = r.session.as_ref().unwrap().attached_sets.as_ref();
        let Some(attached) = attached else {
            return xr::Result::ERROR_ACTIONSET_NOT_ATTACHED;
        };
        let mut active = HashMap::<u64, [bool; 2]>::new();
        for set in sets {
            if !r.public_action_set(set.action_set.into_raw()) {
                return xr::Result::ERROR_HANDLE_INVALID;
            }
            if !attached.contains(&set.action_set.into_raw()) {
                return xr::Result::ERROR_ACTIONSET_NOT_ATTACHED;
            }
            let hands = if set.subaction_path == xr::Path::NULL {
                [true, true]
            } else {
                let hand = match path_hand(&r.paths, set.subaction_path) {
                    Ok(h) => h,
                    Err(e) => return e,
                };
                if !r.actions.values().any(|action| {
                    action.set == set.action_set.into_raw()
                        && action.subactions.contains(&set.subaction_path.into_raw())
                }) {
                    return xr::Result::ERROR_PATH_UNSUPPORTED;
                }
                [hand == 0, hand == 1]
            };
            let mask = active.entry(set.action_set.into_raw()).or_default();
            for hand in 0..2 {
                mask[hand] |= hands[hand];
            }
        }
        let definitions = r.actions.clone();
        let mut bindings = r.bindings.clone();
        let paths = r.paths.clone();
        // Resolve priorities per physical source and hand, not for the whole
        // controller. Equal-priority bindings remain active together; inactive
        // sets and undeclared subactions cannot capture a source.
        let mut priorities = HashMap::<(usize, u8), u32>::new();
        for (handle, bound) in &bindings {
            let Some(action) = definitions.get(handle) else {
                continue;
            };
            if action.kind == xr::ActionType::VIBRATION_OUTPUT {
                continue;
            }
            let mask = active.get(&action.set).copied().unwrap_or([false; 2]);
            for binding in bound {
                if mask[binding.hand] && action_allows_hand(&paths, action, binding.hand) {
                    let priority = r.action_sets.get(&action.set).map_or(0, |set| set.priority);
                    priorities
                        .entry((binding.hand, binding.part.source_group()))
                        .and_modify(|old| *old = (*old).max(priority))
                        .or_insert(priority);
                }
            }
        }
        for (handle, bound) in &mut bindings {
            let Some(action) = definitions.get(handle) else {
                continue;
            };
            if action.kind == xr::ActionType::VIBRATION_OUTPUT {
                continue;
            }
            let priority = r.action_sets.get(&action.set).map_or(0, |set| set.priority);
            bound.retain(|b| {
                priorities
                    .get(&(b.hand, b.part.source_group()))
                    .is_none_or(|maximum| priority == *maximum)
            });
        }
        let s = r.session.as_mut().unwrap();
        let focused = s.state == xr::SessionState::FOCUSED && !s.side.requests().1;
        if !focused {
            active.clear();
        }
        s.synced_before = s.synced;
        s.synced = s
            .side
            .state_snapshot()
            .or(s.newest)
            .map(|state| state.controllers)
            .unwrap_or_default();
        let connected = s.synced.map(|c| c.connected != 0);
        let profile_changed = s.profile_connected.is_some_and(|old| old != connected);
        s.profile_connected = Some(connected);
        s.active_sets = active;
        let old_sources = std::mem::take(&mut s.pose_sources);
        let old_readings = std::mem::take(&mut s.readings);
        let time = halliday_core::time::host_time_ns();
        for (handle, action) in definitions {
            let mask = s
                .active_sets
                .get(&action.set)
                .copied()
                .unwrap_or([false; 2]);
            let bound = bindings.get(&handle).map(Vec::as_slice).unwrap_or_default();
            if action.kind == xr::ActionType::POSE_INPUT {
                let kinds = std::array::from_fn(|hand| {
                    bound
                        .iter()
                        .find(|b| b.hand == hand && b.part.is_pose())
                        .map(|b| b.part)
                });
                let eligible = std::array::from_fn(|hand| {
                    action_allows_hand(&paths, &action, hand)
                        && mask[hand]
                        && s.synced[hand].connected != 0
                        && kinds[hand].is_some_and(Part::is_pose)
                });
                let previous = old_sources.get(&handle).and_then(|p| p.selected);
                s.pose_sources.insert(
                    handle,
                    PoseSources {
                        eligible,
                        kinds,
                        selected: choose_pose_source(previous, eligible),
                    },
                );
            } else if action.kind != xr::ActionType::VIBRATION_OUTPUT {
                for requested in [None, Some(0), Some(1)] {
                    let old = old_readings
                        .get(&(handle, requested))
                        .copied()
                        .unwrap_or_default();
                    let reading = aggregate_reading(
                        &action, &paths, bound, &s.synced, mask, requested, old, time,
                    );
                    s.readings.insert((handle, requested), reading);
                }
            }
        }
        if profile_changed {
            r.events
                .push_back(RuntimeEvent::Profile(session.into_raw()));
        }
        if focused {
            xr::Result::SUCCESS
        } else {
            xr::Result::SESSION_NOT_FOCUSED
        }
    })
}

unsafe extern "system" fn enumerate_bound_sources_for_action(
    session: xr::Session,
    info: *const xr::BoundSourcesForActionEnumerateInfo,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::Path,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let sources = with(|r| {
        r.session(session)?;
        let action = r
            .public_action(info.action.into_raw())
            .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
        let s = r.session.as_ref().unwrap();
        if !s
            .attached_sets
            .as_ref()
            .is_some_and(|sets| sets.contains(&action.set))
        {
            return Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED);
        }
        Ok(r.bindings
            .get(&info.action.into_raw())
            .into_iter()
            .flatten()
            .filter(|b| {
                action_allows_hand(&r.paths, action, b.hand) && s.synced[b.hand].connected != 0
            })
            .map(|b| xr::Path::from_raw(b.path))
            .collect::<Vec<_>>())
    });
    match sources {
        Ok(paths) => unsafe { crate::two_call(&paths, capacity, count, out) },
        Err(e) => e,
    }
}

unsafe extern "system" fn get_input_source_localized_name(
    session: xr::Session,
    info: *const xr::InputSourceLocalizedNameGetInfo,
    capacity: u32,
    count: *mut u32,
    out: *mut c_char,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let text = with(|r| {
        r.session(session)?;
        let s = r.session.as_ref().unwrap();
        if s.attached_sets.is_none() {
            return Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED);
        }
        let path = r
            .paths
            .get(&info.source_path.into_raw())
            .ok_or(xr::Result::ERROR_PATH_INVALID)?;
        let (hand, component) = part(path).ok_or(xr::Result::ERROR_PATH_UNSUPPORTED)?;
        if info.which_components == xr::InputSourceLocalizedNameFlags::EMPTY {
            return Err(xr::Result::ERROR_VALIDATION_FAILURE);
        }
        let mut labels = Vec::new();
        if info
            .which_components
            .contains(xr::InputSourceLocalizedNameFlags::USER_PATH)
        {
            labels.push(if hand == 0 { "Left hand" } else { "Right hand" });
        }
        if info
            .which_components
            .contains(xr::InputSourceLocalizedNameFlags::INTERACTION_PROFILE)
        {
            labels.push("Halliday controller");
        }
        if info
            .which_components
            .contains(xr::InputSourceLocalizedNameFlags::COMPONENT)
        {
            labels.push(match component {
                Part::Trigger | Part::TriggerClick | Part::TriggerTouch => "Trigger",
                Part::Squeeze | Part::SqueezeTouch => "Grip",
                Part::Stick | Part::StickX | Part::StickY | Part::StickClick | Part::StickTouch => {
                    "Thumbstick"
                }
                Part::Primary | Part::PrimaryTouch => "Primary button",
                Part::Secondary | Part::SecondaryTouch => "Secondary button",
                Part::Menu => "Menu",
                Part::GripPose => "Grip pose",
                Part::AimPose => "Aim pose",
                Part::Haptic => "Vibration",
                Part::ThumbrestTouch => "Thumb rest",
            });
        }
        Ok(labels.join(" / "))
    });
    match text {
        Ok(text) => {
            let bytes = text
                .bytes()
                .map(|b| b as c_char)
                .chain(std::iter::once(0))
                .collect::<Vec<_>>();
            unsafe { crate::two_call(&bytes, capacity, count, out) }
        }
        Err(e) => e,
    }
}

fn haptic_targets(
    r: &Runtime,
    session: xr::Session,
    info: &xr::HapticActionInfo,
) -> Result<[bool; 2], xr::Result> {
    let s = r
        .session
        .as_ref()
        .filter(|s| s.handle == session.into_raw())
        .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
    if info.ty != xr::HapticActionInfo::TYPE {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    }
    let action = r
        .public_action(info.action.into_raw())
        .ok_or(xr::Result::ERROR_HANDLE_INVALID)?;
    if action.kind != xr::ActionType::VIBRATION_OUTPUT {
        return Err(xr::Result::ERROR_ACTION_TYPE_MISMATCH);
    }
    let requested = requested_hand(&r.paths, action, info.subaction_path)?;
    if !s
        .attached_sets
        .as_ref()
        .is_some_and(|sets| sets.contains(&action.set))
    {
        return Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED);
    }
    let connected = s
        .side
        .state_snapshot()
        .or(s.newest)
        .map(|state| state.controllers)
        .unwrap_or_default();
    Ok(std::array::from_fn(|hand| {
        requested.is_none_or(|h| h == hand)
            && action_allows_hand(&r.paths, action, hand)
            && connected[hand].connected != 0
            && r.bindings
                .get(&info.action.into_raw())
                .is_some_and(|bindings| {
                    bindings
                        .iter()
                        .any(|b| b.hand == hand && b.part == Part::Haptic)
                })
    }))
}
unsafe extern "system" fn apply_haptic_feedback(
    session: xr::Session,
    info: *const xr::HapticActionInfo,
    haptic: *const xr::HapticBaseHeader,
) -> xr::Result {
    let (Some(info), Some(haptic)) = (unsafe { info.as_ref() }, unsafe { haptic.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if haptic.ty != xr::StructureType::HAPTIC_VIBRATION {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let vibration =
        unsafe { &*(haptic as *const xr::HapticBaseHeader).cast::<xr::HapticVibration>() };
    let ns = vibration.duration.as_nanos();
    if (ns < 0 && vibration.duration != xr::Duration::MIN_HAPTIC)
        || !vibration.frequency.is_finite()
        || vibration.frequency < 0.0
        || !vibration.amplitude.is_finite()
        || !(0.0..=1.0).contains(&vibration.amplitude)
    {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let duration = if vibration.duration == xr::Duration::MIN_HAPTIC {
        10_000_000
    } else {
        ns as u64
    };
    with(|r| {
        r.refresh_lifecycle();
        let targets = match haptic_targets(r, session, info) {
            Ok(v) => v,
            Err(e) => return e,
        };
        let s = r.session.as_mut().unwrap();
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        if s.state != xr::SessionState::FOCUSED {
            return xr::Result::SESSION_NOT_FOCUSED;
        }
        for (hand, target) in targets.into_iter().enumerate() {
            if target {
                if s.haptic_epoch != 0
                    && !s.side.send_haptic(
                        s.haptic_epoch,
                        hand,
                        duration,
                        vibration.frequency,
                        vibration.amplitude,
                    )
                {
                    return xr::Result::ERROR_RUNTIME_FAILURE;
                }
                s.haptic_actions[hand] =
                    (duration != 0 && vibration.amplitude > 0.0).then_some(info.action.into_raw());
            }
        }
        xr::Result::SUCCESS
    })
}
unsafe extern "system" fn stop_haptic_feedback(
    session: xr::Session,
    info: *const xr::HapticActionInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    with(|r| {
        r.refresh_lifecycle();
        let targets = match haptic_targets(r, session, info) {
            Ok(v) => v,
            Err(e) => return e,
        };
        // A disconnected source may still own an issued request, but an
        // explicit subaction stop must never cancel the other hand's request.
        let requested = if info.subaction_path == xr::Path::NULL {
            None
        } else {
            Some(path_hand(&r.paths, info.subaction_path).unwrap())
        };
        let s = r.session.as_mut().unwrap();
        if !s.running {
            return xr::Result::ERROR_SESSION_NOT_RUNNING;
        }
        for (hand, target) in targets.into_iter().enumerate() {
            if requested.is_none_or(|selected| selected == hand)
                && (target || s.haptic_actions[hand] == Some(info.action.into_raw()))
                && s.haptic_actions[hand].is_none_or(|a| a == info.action.into_raw())
            {
                if s.haptic_epoch != 0 {
                    s.side.send_haptic(s.haptic_epoch, hand, 0, 0.0, 0.0);
                }
                s.haptic_actions[hand] = None;
            }
        }
        if s.state == xr::SessionState::FOCUSED {
            xr::Result::SUCCESS
        } else {
            xr::Result::SESSION_NOT_FOCUSED
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn near(a: xr::Vector3f, b: [f32; 3]) -> bool {
        (a.x - b[0]).abs() < 1e-5 && (a.y - b[1]).abs() < 1e-5 && (a.z - b[2]).abs() < 1e-5
    }

    #[test]
    fn poses_compose_and_invert() {
        // A quarter turn to the left about up, one meter up.
        let half = std::f32::consts::FRAC_PI_4;
        let a = xr::Posef {
            orientation: xr::Quaternionf {
                x: 0.0,
                y: half.sin(),
                z: 0.0,
                w: half.cos(),
            },
            position: xr::Vector3f {
                x: 0.0,
                y: 1.0,
                z: 0.0,
            },
        };
        // What is a meter ahead of it (−z) is a meter to the left (−x) of the origin, a meter up.
        let ahead = xr::Posef {
            position: xr::Vector3f {
                x: 0.0,
                y: 0.0,
                z: -1.0,
            },
            ..IDENTITY
        };
        assert!(near(compose(a, ahead).position, [-1.0, 1.0, 0.0]));
        let back = compose(inverse(a), compose(a, ahead));
        assert!(near(back.position, [0.0, 0.0, -1.0]));
        assert!((back.orientation.w - 1.0).abs() < 1e-5);
    }

    #[test]
    fn every_session_function_resolves() {
        for name in crate::CORE_SESSION {
            assert!(lookup(name).is_some(), "{}", String::from_utf8_lossy(name));
        }
        assert!(lookup(b"xrGetMetalGraphicsRequirementsKHR").is_some());
        assert!(lookup(b"xrNoSuchThing").is_none());
    }

    #[test]
    fn a_frame_is_shown_for_the_head_it_was_drawn_for() {
        // Three heads given, each turned a little further about y; the frame drawn for the
        // middle one is ended after the application has waited for the next.
        let head = |degrees: f32, stamp: f32| {
            let half = degrees.to_radians() * 0.5;
            bridge::Pose {
                position: [0.0, 1.6, 0.0],
                valid: 1,
                orientation: [0.0, half.sin(), 0.0, half.cos()],
                stamp,
                ..Default::default()
            }
        };
        let given: std::collections::VecDeque<_> =
            [head(10.0, 1.0), head(10.3, 2.0), head(10.6, 3.0)].into();
        let drawn = drawn_for(&given, from_bridge(&given[1]), given[2]);
        assert_eq!(drawn.stamp, 2.0);
        // A pose that is none of them is taken as the layer says, under the newest stamp.
        let own = drawn_for(&given, from_bridge(&head(40.0, 0.0)), given[2]);
        assert_eq!(own.stamp, 3.0);
        assert!((own.orientation[1] - 20f32.to_radians().sin()).abs() < 1e-6);
        // And a layer with no orientation at all leaves the newest head.
        let none = xr::Posef {
            orientation: xr::Quaternionf {
                x: 0.0,
                y: 0.0,
                z: 0.0,
                w: 0.0,
            },
            position: xr::Vector3f {
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
        };
        assert_eq!(drawn_for(&given, none, given[2]).stamp, 3.0);
        // Same orientation at distinct positions must not attach a newer/older position or
        // pose stamp to a correctly submitted frame.
        let translated: VecDeque<_> = (0..3)
            .map(|i| bridge::Pose {
                position: [i as f32 * 0.1, 1.6, 0.0],
                orientation: [0.0, 0.0, 0.0, 1.0],
                valid: 1,
                stamp: i as f32 + 20.0,
                ..Default::default()
            })
            .collect();
        let exact = drawn_for(&translated, from_bridge(&translated[1]), translated[2]);
        assert_eq!(exact, translated[1]);
    }

    #[test]
    fn a_touch_binding_reads_the_published_controller() {
        assert_eq!(
            part("/user/hand/left/input/trigger/value"),
            Some((0, Part::Trigger))
        );
        assert_eq!(
            part("/user/hand/right/input/a/click"),
            Some((1, Part::Primary))
        );
        assert_eq!(
            part("/user/hand/left/input/thumbstick"),
            Some((0, Part::Stick))
        );
        assert_eq!(
            part("/user/hand/right/output/haptic"),
            Some((1, Part::Haptic))
        );
        assert_eq!(part("/user/head/input/trigger/value"), None);
        let mut c = bridge::Controller::default();
        c.axes[0] = [0.25, -0.5];
        c.axes[1][0] = 0.7;
        c.pressed = BIT_GRIP | BIT_A;
        assert_eq!(read(&c, Part::Trigger), [0.7, 0.0]);
        assert_eq!(read(&c, Part::Squeeze), [1.0, 0.0]);
        assert_eq!(read(&c, Part::Stick), [0.25, -0.5]);
        assert_eq!(read(&c, Part::StickY), [-0.5, 0.0]);
        assert_eq!(read(&c, Part::Primary), [1.0, 0.0]);
        assert_eq!(read(&c, Part::Secondary), [0.0, 0.0]);
        // A trigger held by the mouse's hand has the button and no axis.
        let held = bridge::Controller {
            pressed: BIT_TRIGGER,
            ..Default::default()
        };
        assert_eq!(read(&held, Part::Trigger), [1.0, 0.0]);
    }
}

#[cfg(test)]
#[path = "native_action_tests.rs"]
mod native_action_tests;

#[cfg(test)]
#[path = "native_layer_tests.rs"]
mod native_layer_tests;
