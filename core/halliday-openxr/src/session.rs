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

use halliday_bridge as bridge;
use halliday_core::game_bridge::{Config, GameSide};
use openxr_sys as xr;
use openxr_sys::Handle;
use openxr_sys::pfn;

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
    ) -> *mut c_void;
    fn hx_buffer(device: *mut c_void, bytes: u64) -> *mut c_void;
    #[allow(clippy::too_many_arguments)]
    fn hx_read(
        queue: *mut c_void,
        texture: *mut c_void,
        slice: u32,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        scratch: *mut c_void,
        out: *mut u8,
    ) -> i32;
}

/// Metal's pixel formats the swapchains are offered in, the ones first that hold what the
/// bridge carries (8 bits, sRGB-encoded): `MTLPixelFormatBGRA8Unorm_sRGB`, `RGBA8Unorm_sRGB`,
/// `BGRA8Unorm`, `RGBA8Unorm`.
const FORMATS: [i64; 4] = [81, 71, 80, 70];
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

/// How many of the heads given to the application are kept to find a frame's among.
const GIVEN: usize = 32;

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
    /// A hand's pose: 0 left, 1 right.
    Hand(usize),
}

#[derive(Clone, Copy)]
struct Space {
    kind: SpaceKind,
    offset: xr::Posef,
}

struct Swapchain {
    width: u32,
    height: u32,
    bgra: bool,
    textures: Vec<*mut c_void>,
    next: usize,
    acquired: VecDeque<usize>,
    /// The image the application finished last: what `xrEndFrame` shows.
    released: Option<usize>,
}

struct Session {
    handle: u64,
    instance: u64,
    queue: *mut c_void,
    device: *mut c_void,
    scratch: *mut c_void,
    scratch_bytes: u64,
    side: GameSide,
    config: Config,
    state: xr::SessionState,
    running: bool,
    spaces: HashMap<u64, Space>,
    swapchains: HashMap<u64, Swapchain>,
    /// Halliday's newest state, taken at `xrWaitFrame`.
    newest: Option<bridge::State>,
    /// The heads given at the last waits, oldest first: a frame is drawn for one of them.
    given: std::collections::VecDeque<bridge::Pose>,
    /// LOCAL's place in Halliday's space: the head at the first frame, level.
    local: Option<xr::Posef>,
    /// The controllers at the last `xrSyncActions`, and at the one before (for "changed").
    synced: [bridge::Controller; 2],
    synced_before: [bridge::Controller; 2],
    waited: bool,
    begun: bool,
    display_time: i64,
    quit_requests: u32,
    frames: u64,
}

// SAFETY: the Metal objects are only used under the runtime's lock, and Metal's command queues,
// devices, textures and buffers may be used from any thread.
unsafe impl Send for Session {}

#[derive(Default)]
struct Runtime {
    session: Option<Session>,
    events: VecDeque<(u64, xr::SessionState)>,
    paths: Vec<String>,
    /// Action and action set handles that are live, with an action's kind.
    actions: HashMap<u64, xr::ActionType>,
    /// What each action reads, per hand (left, right), from the profile taken (`profile`).
    bindings: HashMap<u64, [Option<Part>; 2]>,
    /// The interaction profile whose bindings were taken (a path), and how well it fits.
    profile: Option<(u64, u8)>,
    action_sets: Vec<u64>,
    next_handle: u64,
    default_device: usize,
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
            s.state = *state;
            self.events.push_back((s.handle, *state));
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
pub(crate) unsafe fn poll(buffer: *mut xr::EventDataBuffer) -> xr::Result {
    let Some((session, state)) = with(|r| r.events.pop_front()) else {
        return xr::Result::EVENT_UNAVAILABLE;
    };
    let event = xr::EventDataSessionStateChanged {
        ty: xr::StructureType::EVENT_DATA_SESSION_STATE_CHANGED,
        next: std::ptr::null(),
        session: xr::Session::from_raw(session),
        state,
        time: xr::Time::from_nanos(halliday_core::time::host_time_ns()),
    };
    // SAFETY: the buffer is larger than any event; the caller made it valid.
    unsafe {
        buffer
            .cast::<xr::EventDataSessionStateChanged>()
            .write(event)
    };
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
    });
}

fn drop_session(r: &mut Runtime) {
    if let Some(s) = r.session.take() {
        // SAFETY: retained when the session and its swapchains were made.
        unsafe {
            for chain in s.swapchains.values() {
                for texture in &chain.textures {
                    hx_release(*texture);
                }
            }
            hx_release(s.scratch);
            hx_release(s.device);
            hx_release(s.queue);
        }
    }
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
    _instance: xr::Instance,
    _system: xr::SystemId,
    out: *mut xr::GraphicsRequirementsMetalKHR,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
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
    // The graphics binding, somewhere along the chain.
    let mut next = info.next.cast::<xr::BaseInStructure>();
    let mut queue = std::ptr::null_mut();
    while let Some(link) = unsafe { next.as_ref() } {
        if link.ty == xr::StructureType::GRAPHICS_BINDING_METAL_KHR {
            queue = unsafe { (*next.cast::<xr::GraphicsBindingMetalKHR>()).command_queue };
        }
        next = link.next;
    }
    if queue.is_null() {
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
    let side = match GameSide::open_as(&bridge_path(), &app) {
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
        let config = side.config();
        let handle = r.handle();
        // SAFETY: the application's queue, valid for the call; kept (retained) for the session.
        let (queue, device) = unsafe { (hx_retain(queue), hx_queue_device(queue)) };
        r.session = Some(Session {
            handle,
            instance: instance.into_raw(),
            queue,
            device,
            scratch: std::ptr::null_mut(),
            scratch_bytes: 0,
            side,
            config,
            state: xr::SessionState::IDLE,
            running: false,
            spaces: HashMap::new(),
            swapchains: HashMap::new(),
            newest: None,
            given: Default::default(),
            local: None,
            synced: Default::default(),
            synced_before: Default::default(),
            waited: false,
            begun: false,
            display_time: 0,
            quit_requests: 0,
            frames: 0,
        });
        if let Some(s) = r.session.as_mut() {
            s.quit_requests = s.side.requests().0;
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
        r.change(&[
            xr::SessionState::SYNCHRONIZED,
            xr::SessionState::VISIBLE,
            xr::SessionState::FOCUSED,
        ]);
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
            r.change(&STOPPING);
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
    // The hand is in the subaction path; an action made for one hand only has none, and is
    // taken for the right.
    let hand = with(|r| {
        let path = r
            .paths
            .get((info.subaction_path.into_raw() as usize).wrapping_sub(1));
        usize::from(!path.is_some_and(|p| p.contains("/left")))
    });
    new_space(
        session,
        SpaceKind::Hand(hand),
        info.pose_in_action_space,
        out,
    )
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
    /// A space's pose in Halliday's own space (STAGE), and whether it is tracked now.
    fn in_stage(&self, space: &Space) -> (xr::Posef, bool) {
        let state = self.newest.unwrap_or_default();
        let (base, tracked) = match space.kind {
            SpaceKind::Stage => (IDENTITY, true),
            SpaceKind::Local => (self.local.unwrap_or(IDENTITY), self.local.is_some()),
            SpaceKind::View => (from_bridge(&state.head), state.head.valid != 0),
            SpaceKind::Hand(hand) => {
                let c = &state.controllers[hand];
                (from_bridge(&c.pose), c.connected != 0 && c.pose.valid != 0)
            }
        };
        (compose(base, space.offset), tracked)
    }

    fn locate(&self, space: u64, base: u64) -> Option<(xr::Posef, bool)> {
        let (space, base) = (self.spaces.get(&space)?, self.spaces.get(&base)?);
        let ((a, a_ok), (b, b_ok)) = (self.in_stage(space), self.in_stage(base));
        Some((compose(inverse(b), a), a_ok && b_ok))
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
    _time: xr::Time,
    out: *mut xr::SpaceLocation,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let found = with(|r| {
        r.session
            .as_ref()
            .and_then(|s| s.locate(space.into_raw(), base.into_raw()))
    });
    let Some((pose, tracked)) = found else {
        return xr::Result::ERROR_HANDLE_INVALID;
    };
    out.location_flags = flags(tracked);
    out.pose = pose;
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
    if out.location_count < info.space_count || out.locations.is_null() || info.spaces.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| {
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        for i in 0..info.space_count as usize {
            // SAFETY: the caller's arrays hold `space_count` entries (checked above).
            let space = unsafe { *info.spaces.add(i) };
            let Some((pose, tracked)) = s.locate(space.into_raw(), info.base_space.into_raw())
            else {
                return xr::Result::ERROR_HANDLE_INVALID;
            };
            unsafe {
                out.locations.add(i).write(xr::SpaceLocationData {
                    location_flags: flags(tracked),
                    pose,
                });
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
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    unsafe { crate::two_call(&FORMATS, capacity, count, out) }
}

unsafe extern "system" fn create_swapchain(
    session: xr::Session,
    info: *const xr::SwapchainCreateInfo,
    out: *mut xr::Swapchain,
) -> xr::Result {
    let (Some(info), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if !FORMATS.contains(&info.format) {
        return xr::Result::ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }
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
        let textures: Vec<*mut c_void> = (0..IMAGES)
            .map(|_| {
                // SAFETY: the session's device; the texture is ours until the swapchain goes.
                unsafe {
                    hx_texture(
                        s.device,
                        info.format as u64,
                        info.width,
                        info.height,
                        info.array_size,
                        info.sample_count.max(1),
                    )
                }
            })
            .collect();
        if textures.iter().any(|t| t.is_null()) {
            for t in textures {
                // SAFETY: ours, or null (which hx_release takes).
                unsafe { hx_release(t) };
            }
            return xr::Result::ERROR_RUNTIME_FAILURE;
        }
        s.swapchains.insert(
            handle,
            Swapchain {
                width: info.width,
                height: info.height,
                bgra: info.format == 80 || info.format == 81,
                textures,
                next: 0,
                acquired: VecDeque::new(),
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
                    unsafe { hx_release(texture) };
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
    let textures = match chain(swapchain, |c| c.textures.clone()) {
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
    let out = out.cast::<xr::SwapchainImageMetalKHR>();
    for (i, texture) in textures.iter().enumerate() {
        // SAFETY: the caller's array holds `capacity` Metal image structs, their types set.
        unsafe { (*out.add(i)).texture = *texture };
    }
    xr::Result::SUCCESS
}

unsafe extern "system" fn acquire_swapchain_image(
    swapchain: xr::Swapchain,
    _info: *const xr::SwapchainImageAcquireInfo,
    index: *mut u32,
) -> xr::Result {
    let Some(index) = (unsafe { index.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    match chain(swapchain, |c| {
        if c.acquired.len() >= c.textures.len() {
            return None;
        }
        let i = c.next;
        c.next = (c.next + 1) % c.textures.len();
        c.acquired.push_back(i);
        Some(i as u32)
    }) {
        Ok(Some(i)) => {
            *index = i;
            xr::Result::SUCCESS
        }
        Ok(None) => xr::Result::ERROR_CALL_ORDER_INVALID,
        Err(e) => e,
    }
}

unsafe extern "system" fn wait_swapchain_image(
    swapchain: xr::Swapchain,
    _info: *const xr::SwapchainImageWaitInfo,
) -> xr::Result {
    // An acquired image is never in use by the runtime: `xrEndFrame` has read it by the time
    // it returns.
    match chain(swapchain, |c| !c.acquired.is_empty()) {
        Ok(true) => xr::Result::SUCCESS,
        Ok(false) => xr::Result::ERROR_CALL_ORDER_INVALID,
        Err(e) => e,
    }
}

unsafe extern "system" fn release_swapchain_image(
    swapchain: xr::Swapchain,
    _info: *const xr::SwapchainImageReleaseInfo,
) -> xr::Result {
    match chain(swapchain, |c| {
        let i = c.acquired.pop_front()?;
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
            let s = match r.session(session) {
                Ok(s) => s,
                Err(e) => return Err(e),
            };
            if !s.running {
                return Err(xr::Result::ERROR_SESSION_NOT_RUNNING);
            }
            let late = start.elapsed() > Duration::from_millis(250);
            let state = match s.side.poll_frame() {
                Some(state) => Some(state),
                None if late => s.side.wait_frame(Duration::ZERO),
                None => None,
            };
            if state.is_none() && !late {
                return Ok(None);
            }
            if let Some(state) = state {
                // LOCAL: where the head is at the first frame, level, facing the way it does.
                if s.local.is_none() && state.head.valid != 0 {
                    let head = from_bridge(&state.head);
                    let forward = rotate(
                        head.orientation,
                        xr::Vector3f {
                            x: 0.0,
                            y: 0.0,
                            z: -1.0,
                        },
                    );
                    let yaw = (-forward.x).atan2(-forward.z) * 0.5;
                    s.local = Some(xr::Posef {
                        orientation: xr::Quaternionf {
                            x: 0.0,
                            y: yaw.sin(),
                            z: 0.0,
                            w: yaw.cos(),
                        },
                        position: head.position,
                    });
                }
                s.newest = Some(state);
                if state.head.valid != 0 {
                    if s.given.len() == GIVEN {
                        s.given.pop_front();
                    }
                    s.given.push_back(state.head);
                }
            }
            let period = 1e9 / f64::from(s.config.display_hz.max(30.0));
            s.display_time = halliday_core::time::host_time_ns() + (period * FRAMES_AHEAD) as i64;
            s.waited = true;
            // Halliday asking the application to quit (its own quit, or "Quit game").
            let quits = s.side.requests().0;
            let asked = quits != s.quit_requests;
            s.quit_requests = quits;
            let result = (s.display_time, period as i64);
            if asked && s.state != xr::SessionState::STOPPING {
                r.change(&STOPPING);
            }
            Ok(Some(result))
        });
        match step {
            Err(e) => return e,
            Ok(Some((time, period))) => {
                out.predicted_display_time = xr::Time::from_nanos(time);
                out.predicted_display_period = xr::Duration::from_nanos(period);
                out.should_render = xr::TRUE;
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
}

unsafe extern "system" fn end_frame(
    session: xr::Session,
    info: *const xr::FrameEndInfo,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    with(|r| {
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
        // The first projection layer is the picture; the others (quads, a second projection)
        // aren't composited yet.
        let mut projection = None;
        for i in 0..info.layer_count as usize {
            if info.layers.is_null() {
                break;
            }
            // SAFETY: the caller's array of `layer_count` layer pointers.
            let layer = unsafe { *info.layers.add(i) };
            if let Some(header) = unsafe { layer.as_ref() }
                && header.ty == xr::StructureType::COMPOSITION_LAYER_PROJECTION
            {
                projection = Some(layer.cast::<xr::CompositionLayerProjection>());
                break;
            }
        }
        let Some(projection) = projection else {
            return xr::Result::SUCCESS;
        };
        // SAFETY: a projection layer, by its type.
        let projection = unsafe { &*projection };
        if projection.view_count < 2 || projection.views.is_null() {
            return xr::Result::ERROR_VALIDATION_FAILURE;
        }
        let mut eyes = [None; 2];
        let mut size = (u32::MAX, u32::MAX);
        for (eye, slot) in eyes.iter_mut().enumerate() {
            // SAFETY: `view_count` views, at least two.
            let view = unsafe { &*projection.views.add(eye) };
            let Some(chain) = s.swapchains.get(&view.sub_image.swapchain.into_raw()) else {
                return xr::Result::ERROR_HANDLE_INVALID;
            };
            let Some(image) = chain.released else {
                return xr::Result::ERROR_LAYER_INVALID;
            };
            let rect = view.sub_image.image_rect;
            let (x, y) = (rect.offset.x.max(0) as u32, rect.offset.y.max(0) as u32);
            let (w, h) = (
                rect.extent.width.max(0) as u32,
                rect.extent.height.max(0) as u32,
            );
            if x + w > chain.width || y + h > chain.height || w == 0 || h == 0 {
                return xr::Result::ERROR_SWAPCHAIN_RECT_INVALID;
            }
            size = (size.0.min(w), size.1.min(h));
            *slot = Some(Eye {
                texture: chain.textures[image],
                slice: view.sub_image.image_array_index,
                x,
                y,
                bgra: chain.bgra,
            });
        }
        let (Some(left), Some(right)) = (eyes[0], eyes[1]) else {
            return xr::Result::ERROR_LAYER_INVALID;
        };
        if !bridge::fits(size.0, size.1) {
            return xr::Result::ERROR_SWAPCHAIN_RECT_INVALID;
        }
        let bytes = u64::from(size.0) * u64::from(size.1) * 4;
        if s.scratch_bytes < bytes {
            // SAFETY: the session's device; the old buffer was ours.
            unsafe {
                hx_release(s.scratch);
                s.scratch = hx_buffer(s.device, bytes);
            }
            s.scratch_bytes = bytes;
        }
        // A layer blended by its alpha: where the picture is clear, the application wants what
        // is behind it (the room) to show.
        s.side.see_through = projection
            .layer_flags
            .contains(xr::CompositionLayerFlags::BLEND_TEXTURE_SOURCE_ALPHA);
        // The pose the application drew for: the one its layer says, not the head's at its
        // last wait. An engine that draws on a thread of its own has waited for the next frame
        // by the time it ends this one, and its picture was then shown as drawn for a head a
        // frame newer than it was: everything it drew moved with every movement of the head
        // in between, a vibration most of all.
        let newest = s.newest.map(|state| state.head).unwrap_or_default();
        let pose = match s.spaces.get(&projection.space.into_raw()) {
            Some(space) if matches!(space.kind, SpaceKind::Stage | SpaceKind::Local) => {
                let (base, _) = s.in_stage(space);
                // SAFETY: two views at least (checked above).
                let (a, b) = unsafe { (&*projection.views, &*projection.views.add(1)) };
                let (a, b) = (compose(base, a.pose), compose(base, b.pose));
                let head = xr::Posef {
                    orientation: a.orientation,
                    position: xr::Vector3f {
                        x: (a.position.x + b.position.x) * 0.5,
                        y: (a.position.y + b.position.y) * 0.5,
                        z: (a.position.z + b.position.z) * 0.5,
                    },
                };
                drawn_for(&s.given, head, newest)
            }
            _ => newest,
        };
        let (queue, scratch) = (s.queue, s.scratch);
        let mut failed = false;
        s.side
            .submit_as(pose, size, false, left.bgra, |eye, pixels| {
                let e = if eye == 0 { left } else { right };
                // SAFETY: live Metal objects of this session; `pixels` is the bridge's slot
                // for this eye, `size` pixels of 4 bytes.
                let status = unsafe {
                    hx_read(
                        queue,
                        e.texture,
                        e.slice,
                        e.x,
                        e.y,
                        size.0,
                        size.1,
                        scratch,
                        pixels.as_mut_ptr(),
                    )
                };
                failed |= status != 0;
            });
        s.frames += 1;
        if failed {
            xr::Result::ERROR_RUNTIME_FAILURE
        } else {
            xr::Result::SUCCESS
        }
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
    *count = 2;
    if capacity == 0 {
        return xr::Result::SUCCESS;
    }
    if capacity < 2 {
        return xr::Result::ERROR_SIZE_INSUFFICIENT;
    }
    if views.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| {
        let s = match r.session(session) {
            Ok(s) => s,
            Err(e) => return e,
        };
        let Some(base) = s.spaces.get(&info.space.into_raw()) else {
            return xr::Result::ERROR_HANDLE_INVALID;
        };
        let newest = s.newest.unwrap_or_default();
        let (base, base_ok) = s.in_stage(base);
        let head = compose(inverse(base), from_bridge(&newest.head));
        let tracked = base_ok && newest.head.valid != 0;
        state.view_state_flags = if tracked {
            xr::ViewStateFlags::ORIENTATION_VALID
                | xr::ViewStateFlags::POSITION_VALID
                | xr::ViewStateFlags::ORIENTATION_TRACKED
                | xr::ViewStateFlags::POSITION_TRACKED
        } else {
            xr::ViewStateFlags::EMPTY
        };
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
        let index = r.paths.iter().position(|p| p == text).unwrap_or_else(|| {
            r.paths.push(text.to_owned());
            r.paths.len() - 1
        });
        xr::Path::from_raw(index as u64 + 1)
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
            .get((path.into_raw() as usize).wrapping_sub(1))
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
    let (Some(_), Some(out)) = (unsafe { info.as_ref() }, unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    *out = with(|r| {
        let handle = r.handle();
        r.action_sets.push(handle);
        xr::ActionSet::from_raw(handle)
    });
    xr::Result::SUCCESS
}

unsafe extern "system" fn destroy_action_set(set: xr::ActionSet) -> xr::Result {
    with(|r| {
        let before = r.action_sets.len();
        r.action_sets.retain(|h| *h != set.into_raw());
        if r.action_sets.len() == before {
            xr::Result::ERROR_HANDLE_INVALID
        } else {
            xr::Result::SUCCESS
        }
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
        if !r.action_sets.contains(&set.into_raw()) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        let handle = r.handle();
        r.actions.insert(handle, info.action_type);
        *out = xr::Action::from_raw(handle);
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn destroy_action(action: xr::Action) -> xr::Result {
    with(|r| match r.actions.remove(&action.into_raw()) {
        Some(_) => xr::Result::SUCCESS,
        None => xr::Result::ERROR_HANDLE_INVALID,
    })
}

/// A part of a controller an action can read: what Halliday publishes of each hand (the Sense
/// controllers, or the hands the mouse and keyboard stand in for), under a Touch controller's
/// names, which is the profile Quest applications bind.
#[derive(Clone, Copy, Debug, PartialEq)]
enum Part {
    Trigger,
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
        "input/trigger/value" | "input/trigger" | "input/trigger/click" | "input/select/click" => {
            Part::Trigger
        }
        "input/squeeze/value" | "input/squeeze" | "input/squeeze/click" => Part::Squeeze,
        "input/thumbstick" | "input/trackpad" => Part::Stick,
        "input/thumbstick/x" | "input/trackpad/x" => Part::StickX,
        "input/thumbstick/y" | "input/trackpad/y" => Part::StickY,
        "input/thumbstick/click" | "input/trackpad/click" => Part::StickClick,
        "input/thumbstick/touch" | "input/trackpad/touch" => Part::StickTouch,
        "input/a/click" | "input/x/click" => Part::Primary,
        "input/b/click" | "input/y/click" => Part::Secondary,
        "input/menu/click" | "input/system/click" => Part::Menu,
        _ => return None,
    };
    Some((hand, part))
}

/// A part's value now: two numbers for the stick, one (0 to 1) for the rest.
fn read(c: &bridge::Controller, part: Part) -> [f32; 2] {
    let held = |bit: u64| f32::from(u8::from(c.pressed & bit != 0));
    match part {
        Part::Trigger => [c.axes[1][0].max(held(BIT_TRIGGER)), 0.0],
        Part::Squeeze => [c.axes[2][0].max(held(BIT_GRIP)), 0.0],
        Part::Stick => c.axes[0],
        Part::StickX => [c.axes[0][0], 0.0],
        Part::StickY => [c.axes[0][1], 0.0],
        Part::StickClick => [held(BIT_PAD), 0.0],
        Part::StickTouch => [f32::from(u8::from(c.touched & BIT_PAD != 0)), 0.0],
        Part::Primary => [held(BIT_A), 0.0],
        Part::Secondary => [held(BIT_MENU), 0.0],
        Part::Menu => [held(BIT_SYSTEM), 0.0],
    }
}

unsafe extern "system" fn suggest_interaction_profile_bindings(
    _instance: xr::Instance,
    info: *const xr::InteractionProfileSuggestedBinding,
) -> xr::Result {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if info.suggested_bindings.is_null() && info.count_suggested_bindings > 0 {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    let suggested: &[xr::ActionSuggestedBinding] = if info.count_suggested_bindings == 0 {
        &[]
    } else {
        // SAFETY: the application says the array holds that many.
        unsafe {
            std::slice::from_raw_parts(
                info.suggested_bindings,
                info.count_suggested_bindings as usize,
            )
        }
    };
    with(|r| {
        // One profile's bindings are used: a Touch controller's when the application offers
        // them (Halliday's hands are published under its names), else the first offered.
        let name = |r: &Runtime, path: xr::Path| {
            r.paths
                .get((path.into_raw() as usize).wrapping_sub(1))
                .cloned()
                .unwrap_or_default()
        };
        let fit = if name(r, info.interaction_profile).ends_with("/oculus/touch_controller") {
            2
        } else {
            1
        };
        if r.profile.is_some_and(|(_, taken)| taken >= fit) {
            return xr::Result::SUCCESS;
        }
        r.profile = Some((info.interaction_profile.into_raw(), fit));
        r.bindings.clear();
        for b in suggested {
            if let Some((hand, part)) = part(&name(r, b.binding)) {
                r.bindings.entry(b.action.into_raw()).or_default()[hand].get_or_insert(part);
            }
        }
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn attach_session_action_sets(
    session: xr::Session,
    info: *const xr::SessionActionSetsAttachInfo,
) -> xr::Result {
    if info.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| r.session(session).map(|_| ())).map_or_else(|e| e, |()| xr::Result::SUCCESS)
}

unsafe extern "system" fn get_current_interaction_profile(
    session: xr::Session,
    _top_level: xr::Path,
    out: *mut xr::InteractionProfileState,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    out.interaction_profile = with(|r| {
        r.profile
            .map_or(xr::Path::NULL, |(p, _)| xr::Path::from_raw(p))
    });
    xr::Result::SUCCESS
}

/// An action's state at the last sync.
struct Reading {
    active: bool,
    now: [f32; 2],
    before: [f32; 2],
    time: i64,
}

/// What an action reads at the last `xrSyncActions`: from the hand its subaction path names,
/// or with none from whichever hand holds it further.
fn reading(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
) -> Result<Reading, xr::Result> {
    let Some(info) = (unsafe { info.as_ref() }) else {
        return Err(xr::Result::ERROR_VALIDATION_FAILURE);
    };
    with(|r| {
        r.session(session)?;
        let action = info.action.into_raw();
        if !r.actions.contains_key(&action) {
            return Err(xr::Result::ERROR_HANDLE_INVALID);
        }
        let bound = r.bindings.get(&action).copied().unwrap_or_default();
        let hands: &[usize] = match r
            .paths
            .get((info.subaction_path.into_raw() as usize).wrapping_sub(1))
        {
            Some(p) if p.contains("/left") => &[0],
            Some(p) if p.contains("/right") => &[1],
            _ => &[0, 1],
        };
        let s = r.session(session)?;
        let mut out = Reading {
            active: false,
            now: [0.0; 2],
            before: [0.0; 2],
            time: s.display_time,
        };
        let size = |v: [f32; 2]| v[0].abs().max(v[1].abs());
        for &hand in hands {
            let (Some(part), c) = (bound[hand], &s.synced[hand]) else {
                continue;
            };
            if c.connected == 0 {
                continue;
            }
            let (now, before) = (read(c, part), read(&s.synced_before[hand], part));
            if !out.active || size(now) > size(out.now) {
                out.now = now;
                out.before = before;
            }
            out.active = true;
        }
        Ok(out)
    })
}

unsafe extern "system" fn get_action_state_boolean(
    session: xr::Session,
    info: *const xr::ActionStateGetInfo,
    out: *mut xr::ActionStateBoolean,
) -> xr::Result {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    };
    let state = match reading(session, info) {
        Ok(state) => state,
        Err(e) => return e,
    };
    let (now, before) = (state.now[0] > 0.5, state.before[0] > 0.5);
    out.current_state = now.into();
    out.changed_since_last_sync = (now != before).into();
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
    let state = match reading(session, info) {
        Ok(state) => state,
        Err(e) => return e,
    };
    out.current_state = state.now[0];
    out.changed_since_last_sync = (state.now[0] != state.before[0]).into();
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
    let state = match reading(session, info) {
        Ok(state) => state,
        Err(e) => return e,
    };
    out.current_state = xr::Vector2f {
        x: state.now[0],
        y: state.now[1],
    };
    out.changed_since_last_sync = (state.now != state.before).into();
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
    // A pose action follows the hand Halliday publishes (see `create_action_space`).
    with(|r| {
        if let Err(e) = r.session(session) {
            return e;
        }
        if !r.actions.contains_key(&info.action.into_raw()) {
            return xr::Result::ERROR_HANDLE_INVALID;
        }
        out.is_active = xr::TRUE;
        xr::Result::SUCCESS
    })
}

unsafe extern "system" fn sync_actions(
    session: xr::Session,
    info: *const xr::ActionsSyncInfo,
) -> xr::Result {
    if info.is_null() {
        return xr::Result::ERROR_VALIDATION_FAILURE;
    }
    with(|r| match r.session(session) {
        Err(e) => e,
        Ok(s) => {
            // The controllers as Halliday published them last (taken at `xrWaitFrame`).
            s.synced_before = s.synced;
            if let Some(state) = s.newest {
                s.synced = state.controllers;
            }
            xr::Result::SUCCESS
        }
    })
}

unsafe extern "system" fn enumerate_bound_sources_for_action(
    session: xr::Session,
    _info: *const xr::BoundSourcesForActionEnumerateInfo,
    capacity: u32,
    count: *mut u32,
    out: *mut xr::Path,
) -> xr::Result {
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    unsafe { crate::two_call::<xr::Path>(&[], capacity, count, out) }
}

unsafe extern "system" fn get_input_source_localized_name(
    session: xr::Session,
    _info: *const xr::InputSourceLocalizedNameGetInfo,
    capacity: u32,
    count: *mut u32,
    out: *mut c_char,
) -> xr::Result {
    if let Err(e) = with(|r| r.session(session).map(|_| ())) {
        return e;
    }
    unsafe { crate::two_call::<c_char>(&[0], capacity, count, out) }
}

unsafe extern "system" fn apply_haptic_feedback(
    session: xr::Session,
    _info: *const xr::HapticActionInfo,
    _haptic: *const xr::HapticBaseHeader,
) -> xr::Result {
    with(|r| r.session(session).map(|_| ())).map_or_else(|e| e, |()| xr::Result::SUCCESS)
}

unsafe extern "system" fn stop_haptic_feedback(
    session: xr::Session,
    _info: *const xr::HapticActionInfo,
) -> xr::Result {
    with(|r| r.session(session).map(|_| ())).map_or_else(|e| e, |()| xr::Result::SUCCESS)
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
        assert_eq!(part("/user/hand/right/output/haptic"), None);
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
