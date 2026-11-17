//! What the runtime tells Halliday besides frames, and what Halliday tells the game (ROADMAP
//! W14.11): the heartbeat while the game runs (it may stop submitting frames while it loads),
//! fades and the compositor's grid, the skybox for loads, overlays' pictures, Halliday's requests
//! as OpenVR events (quit, its interface over the game), and frame timing.

use crate::log::log;
use crate::ovr;
use crate::runtime::{self, Locked, header};
use crate::win;
use core::ffi::c_void;
use core::sync::atomic::{AtomicBool, Ordering};
use halliday_bridge::picture::{self, Source};
use halliday_bridge::{self as bridge, OVERLAYS, Overlay, Picture, Scene};

// --- The heartbeat ---

static BEATING: AtomicBool = AtomicBool::new(false);

unsafe extern "system" fn beat(_: *mut c_void) -> u32 {
    loop {
        // SAFETY: plain call.
        unsafe { win::Sleep(250) };
        if let Some(h) = header() {
            // SAFETY: a mapped header.
            unsafe { (*h).client_heartbeat.fetch_add(1, Ordering::SeqCst) };
        }
    }
}

/// Starts the heartbeat once the bridge is mapped: Halliday then knows the game runs even while
/// it sends no frames.
pub fn start_heartbeat() {
    if BEATING.swap(true, Ordering::SeqCst) {
        return;
    }
    runtime::pin_this_dll();
    // SAFETY: plain Win32 call; the thread lives as long as the process.
    unsafe {
        let t = win::CreateThread(
            core::ptr::null_mut(),
            0,
            beat,
            core::ptr::null_mut(),
            0,
            core::ptr::null_mut(),
        );
        if t.is_null() {
            BEATING.store(false, Ordering::SeqCst);
        } else {
            win::CloseHandle(t);
        }
    }
}

/// Between VR_Init and VR_Shutdown.
pub fn set_initialized(on: bool) {
    if let Some(h) = header() {
        // SAFETY: a mapped header.
        unsafe { (*h).client_initialized.store(on as u32, Ordering::SeqCst) };
    }
}

// --- The scene and overlays ---

/// Serializes the game's threads writing the scene (the bridge's lock has one writer).
static WRITER: Locked<()> = Locked::new(());

/// Changes the scene and overlays.
pub fn edit<R>(f: impl FnOnce(&mut Scene, &mut [Overlay; OVERLAYS]) -> R) -> Option<R> {
    let h = header()?;
    WRITER.with(|_| {
        let mut out = None;
        // SAFETY: a mapped header; writers serialized above.
        unsafe { bridge::write_scene(h, |s, o| out = Some(f(s, o))) };
        out
    })
}

/// The scene and overlays as last written.
pub fn read() -> Option<(Scene, [Overlay; OVERLAYS])> {
    let h = header()?;
    // SAFETY: a mapped header.
    unsafe { bridge::read_scene(h) }
}

// --- Pictures ---

#[derive(Clone, Copy, PartialEq)]
pub enum Target {
    Overlay(usize),
    Skybox,
}

fn picture_of(h: *mut bridge::Header, t: Target) -> (&'static Picture, *mut u8) {
    // SAFETY: a mapped header (lives as long as the process); the areas are inside the file.
    unsafe {
        match t {
            Target::Overlay(i) => (
                &*core::ptr::addr_of!((*h).overlay_pictures[i]),
                (h as *mut u8).add(bridge::overlay_offset(i)),
            ),
            Target::Skybox => (
                &*core::ptr::addr_of!((*h).skybox_picture),
                (h as *mut u8).add(bridge::skybox_offset()),
            ),
        }
    }
}

fn wait_a_little() {
    // SAFETY: plain call.
    unsafe { win::Sleep(1) };
}

/// Writes a picture: `paint(area)` fills it and returns the size it painted.
fn write_picture(t: Target, paint: impl FnOnce(*mut u8) -> Option<(u32, u32)>) -> bool {
    let Some(h) = header() else {
        return false;
    };
    let (p, area) = picture_of(h, t);
    // The size is known only once painted: mark the picture as being written first.
    bridge::begin_picture(p, 0, 0, wait_a_little, 50);
    let size = paint(area);
    let (w, ht) = size.unwrap_or((0, 0));
    p.width.store(w, Ordering::Relaxed);
    p.height.store(ht, Ordering::Relaxed);
    bridge::end_picture(p);
    size.is_some()
}

/// An overlay's picture from a game's texture (Direct3D 11 or OpenGL), scaled down to fit.
pub fn overlay_texture(i: usize, texture: &ovr::Texture) -> bool {
    let side = bridge::OVERLAY_SIDE;
    match texture.kind {
        ovr::TEXTURE_DIRECTX => write_picture(Target::Overlay(i), |area| {
            // SAFETY: the game's texture; `area` holds an overlay's picture.
            unsafe {
                crate::d3d11::read_once(texture.handle, |src| {
                    picture::copy_scaled(src, area, side, side)
                })
            }
        }),
        ovr::TEXTURE_OPENGL => write_picture(Target::Overlay(i), |area| {
            // SAFETY: as above; OpenGL rows come bottom-up and are turned in place.
            unsafe {
                let size = crate::gl::read_into(texture.handle as usize as u32, area, side)?;
                picture::finish_in_place(area, size.0, size.1, true);
                Some(size)
            }
        }),
        kind => {
            runtime::warn_once(
                10,
                format_args!("[halliday-vrclient] overlay texture type {kind} isn't supported yet"),
            );
            false
        }
    }
}

/// An overlay's picture from the game's memory (`SetOverlayRaw`: 1, 3 or 4 bytes a pixel).
pub fn overlay_raw(i: usize, pixels: *const u8, w: u32, h: u32, depth: u32) -> bool {
    if pixels.is_null() || w == 0 || h == 0 || !matches!(depth, 1 | 3 | 4) {
        return false;
    }
    let side = bridge::OVERLAY_SIDE;
    write_picture(Target::Overlay(i), |area| {
        if depth == 4 {
            let src = Source {
                ptr: pixels,
                pitch: w as usize * 4,
                width: w,
                height: h,
                bgra: false,
                bottom_up: false,
                opaque: false,
                premultiplied: false,
            };
            // SAFETY: the game's `w * h * 4` bytes; `area` holds an overlay's picture.
            return Some(unsafe { picture::copy_scaled(&src, area, side, side) });
        }
        let (dw, dh, k) = picture::scaled_size(w, h, side, side);
        for y in 0..dh {
            for x in 0..dw {
                // SAFETY: inside the game's buffer and `area` (nearest texel of each block).
                unsafe {
                    let s = pixels.add(((y * k * w + x * k) * depth) as usize);
                    let (r, g, b) = if depth == 3 {
                        (*s, *s.add(1), *s.add(2))
                    } else {
                        (*s, *s, *s)
                    };
                    let d = area.add(((y * dw + x) * 4) as usize);
                    *d = r;
                    *d.add(1) = g;
                    *d.add(2) = b;
                    *d.add(3) = 255;
                }
            }
        }
        Some((dw, dh))
    })
}

/// One transparent texel: an overlay whose texture was cleared.
pub fn overlay_clear(i: usize) {
    write_picture(Target::Overlay(i), |area| {
        // SAFETY: inside the area.
        unsafe { core::ptr::write_bytes(area, 0, 4) };
        Some((1, 1))
    });
}

/// `SetSkyboxOverride`: one equirectangular picture, a stereo pair of them, or a cube's six faces
/// (made equirectangular). Direct3D 11 textures only, so far.
pub fn set_skybox(textures: *const ovr::Texture, count: u32) -> i32 {
    if textures.is_null() || !matches!(count, 1 | 2 | 6) {
        return ovr::COMPOSITOR_REQUEST_FAILED;
    }
    // SAFETY: the game's array of `count` textures.
    let list = unsafe { core::slice::from_raw_parts(textures, count as usize) };
    if list.iter().any(|t| t.kind != ovr::TEXTURE_DIRECTX) {
        runtime::warn_once(
            11,
            format_args!(
                "[halliday-vrclient] skybox textures other than Direct3D 11 aren't supported yet"
            ),
        );
        return ovr::COMPOSITOR_INVALID_TEXTURE;
    }
    let w = bridge::SKYBOX_WIDTH;
    let half = w / 2;
    let t0 = runtime::now_ticks();
    let ok = write_picture(Target::Skybox, |area| {
        let mut all = true;
        for (k, t) in list.iter().enumerate() {
            // SAFETY: the game's textures; `area` holds the skybox (two equirect pictures).
            let done = unsafe {
                crate::d3d11::read_once(t.handle, |src| {
                    let mut s = *src;
                    s.opaque = true;
                    match count {
                        6 => picture::cube_face_to_equirect(k, &s, area, w, half),
                        _ => picture::resample(&s, area.add(k * (w * half * 4) as usize), w, half),
                    }
                })
            };
            all &= done.is_some();
        }
        all.then_some((w, if count == 2 { w } else { half }))
    });
    let ms = runtime::ticks_to_ms(runtime::now_ticks().wrapping_sub(t0));
    edit(|scene, _| {
        scene.skybox = if !ok {
            0
        } else if count == 2 {
            2
        } else {
            1
        }
    });
    log!(
        "skybox: {} {} ({ms:.0} ms)",
        match count {
            6 => "a cube's six faces",
            2 => "a stereo pair",
            _ => "one picture",
        },
        if ok {
            "shown while the game loads"
        } else {
            "couldn't be read"
        }
    );
    if ok {
        ovr::COMPOSITOR_NONE
    } else {
        ovr::COMPOSITOR_INVALID_TEXTURE
    }
}

// --- Halliday's requests, as OpenVR events ---

struct Seen {
    quit: u32,
    dashboard: u32,
    started: bool,
    queue: [(u32, u32, u32); 4],
    queued: usize,
}

static SEEN: Locked<Seen> = Locked::new(Seen {
    quit: 0,
    dashboard: 0,
    started: false,
    queue: [(0, 0, 0); 4],
    queued: 0,
});

pub const EVENT_INPUT_FOCUS_CAPTURED: u32 = 400;
pub const EVENT_INPUT_FOCUS_RELEASED: u32 = 401;
pub const EVENT_DASHBOARD_ACTIVATED: u32 = 502;
pub const EVENT_DASHBOARD_DEACTIVATED: u32 = 503;
pub const EVENT_QUIT: u32 = 700;

/// The next event Halliday's requests make: (type, device, data's first word: the process).
pub fn next_event() -> Option<(u32, u32, u32)> {
    let h = header()?;
    // SAFETY: a mapped header; plain call.
    let (quit, dashboard, pid) = unsafe {
        (
            (*h).quit_requests.load(Ordering::SeqCst),
            (*h).dashboard.load(Ordering::SeqCst),
            win::GetCurrentProcessId(),
        )
    };
    SEEN.with(|s| {
        if !s.started {
            // Requests from before this game connected aren't for it.
            s.started = true;
            s.quit = quit;
        }
        if s.quit != quit {
            s.quit = quit;
            log!("Halliday asks the game to quit");
            return Some((EVENT_QUIT, ovr::DEVICE_INVALID, pid));
        }
        if s.dashboard != dashboard {
            s.dashboard = dashboard;
            let on = dashboard != 0;
            s.queue[0] = if on {
                (EVENT_INPUT_FOCUS_CAPTURED, ovr::DEVICE_INVALID, 0)
            } else {
                (EVENT_INPUT_FOCUS_RELEASED, ovr::DEVICE_INVALID, 0)
            };
            s.queued = 1;
            return Some(if on {
                (EVENT_DASHBOARD_ACTIVATED, ovr::DEVICE_INVALID, 0)
            } else {
                (EVENT_DASHBOARD_DEACTIVATED, ovr::DEVICE_INVALID, 0)
            });
        }
        if s.queued > 0 {
            s.queued -= 1;
            return Some(s.queue[s.queued]);
        }
        None
    })
}

/// Halliday's interface is over the game: input goes to Halliday, the game should pause.
pub fn dashboard() -> bool {
    header().is_some_and(|h| {
        // SAFETY: a mapped header.
        unsafe { (*h).dashboard.load(Ordering::SeqCst) != 0 }
    })
}

pub fn acknowledge_quit() {
    log!("the game acknowledged the quit request");
    if let Some(h) = header() {
        // SAFETY: a mapped header.
        unsafe { (*h).quit_acknowledged.fetch_add(1, Ordering::SeqCst) };
    }
}

// --- Timing ---

/// Halliday's display period in seconds (measured; the configured rate until known).
pub fn frame_interval() -> f32 {
    let Some(h) = header() else {
        return 1.0 / 90.0;
    };
    // SAFETY: a mapped header.
    let (ns, hz) = unsafe {
        (
            (*h).frame_interval_ns.load(Ordering::Relaxed),
            (*h).display_hz,
        )
    };
    if ns > 1_000_000 && ns < 100_000_000 {
        ns as f32 * 1e-9
    } else if hz > 1.0 {
        1.0 / hz
    } else {
        1.0 / 90.0
    }
}

/// How far ahead of Halliday's newest head pose the game's frame is seen: its own frame, then
/// the frame it is read back in.
pub fn prediction_seconds() -> f32 {
    2.0 * frame_interval()
}

/// `p` moved on by its velocities for `dt` seconds.
pub fn predict(p: &bridge::Pose, dt: f32) -> bridge::Pose {
    let mut out = *p;
    out.orientation = bridge::math::rotate_by(p.orientation, p.angular_velocity, dt);
    for i in 0..3 {
        out.position[i] += p.velocity[i] * dt;
    }
    out
}

/// One frame's times, for `GetFrameTiming`.
#[derive(Clone, Copy)]
pub struct FrameRecord {
    pub index: u32,
    /// When the vsync the frame started from was seen (ticks).
    pub vsync: u64,
    pub wait_called: u64,
    pub wait_returned: u64,
    pub last_submit: u64,
    pub submit_ticks: u64,
    pub previous_wait: u64,
    pub late_at_start: u64,
    pub late_since: u32,
    pub pose: bridge::Pose,
}

pub static FRAMES: Locked<FrameRecord> = Locked::new(FrameRecord {
    index: 0,
    vsync: 0,
    wait_called: 0,
    wait_returned: 0,
    last_submit: 0,
    submit_ticks: 0,
    previous_wait: 0,
    late_at_start: 0,
    late_since: 0,
    pose: bridge::Pose {
        position: [0.0; 3],
        valid: 0,
        orientation: [0.0, 0.0, 0.0, 1.0],
        velocity: [0.0; 3],
        _pad0: 0.0,
        angular_velocity: [0.0; 3],
        stamp: 0.0,
    },
});

pub fn late_vsyncs() -> u64 {
    header().map_or(0, |h| {
        // SAFETY: a mapped header.
        unsafe { (*h).late_vsyncs.load(Ordering::Relaxed) }
    })
}

/// `Compositor_FrameTiming` (openvr.h, packed to 8): 184 bytes in 1.7, 176 before.
#[repr(C)]
struct FrameTiming {
    size: u32,
    frame_index: u32,
    num_frame_presents: u32,
    num_mis_presented: u32,
    num_dropped_frames: u32,
    reprojection_flags: u32,
    system_time_s: f64,
    pre_submit_gpu_ms: f32,
    post_submit_gpu_ms: f32,
    total_render_gpu_ms: f32,
    compositor_render_gpu_ms: f32,
    compositor_render_cpu_ms: f32,
    compositor_idle_cpu_ms: f32,
    client_frame_interval_ms: f32,
    present_call_cpu_ms: f32,
    wait_for_present_cpu_ms: f32,
    submit_frame_ms: f32,
    wait_get_poses_called_ms: f32,
    new_poses_ready_ms: f32,
    new_frame_ready_ms: f32,
    compositor_update_start_ms: f32,
    compositor_update_end_ms: f32,
    compositor_render_start_ms: f32,
    hmd_pose: ovr::TrackedDevicePose,
    num_vsyncs_ready_for_use: u32,
    num_vsyncs_to_first_view: u32,
}

const _: () = assert!(core::mem::size_of::<FrameTiming>() == 184);

/// Fills the game's `Compositor_FrameTiming` (as much of it as its `m_nSize` says) for the last
/// frame: what Halliday measured (late display frames), what the runtime saw (the game's CPU time
/// between `WaitGetPoses` and its last `Submit`, standing in for GPU time, which isn't measured).
///
/// # Safety
/// `out` is the game's struct, `m_nSize` set.
pub unsafe fn frame_timing(out: *mut u8) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: the game's struct starts with its size.
    let size = unsafe { (out as *const u32).read_unaligned() } as usize;
    if size < 24 {
        return false;
    }
    let r = FRAMES.with(|f| *f);
    let ms = runtime::ticks_to_ms;
    let rel = |t: u64| {
        if t >= r.vsync {
            ms(t - r.vsync) as f32
        } else {
            0.0
        }
    };
    let work = if r.last_submit > r.wait_returned {
        ms(r.last_submit - r.wait_returned) as f32
    } else {
        0.0
    };
    let interval_ms = frame_interval() * 1000.0;
    let t = FrameTiming {
        size: size.min(184) as u32,
        frame_index: r.index,
        num_frame_presents: 1,
        num_mis_presented: 0,
        num_dropped_frames: r.late_since,
        reprojection_flags: 0,
        system_time_s: ms(r.vsync) / 1000.0,
        pre_submit_gpu_ms: work,
        post_submit_gpu_ms: 0.0,
        total_render_gpu_ms: work,
        compositor_render_gpu_ms: 0.0,
        compositor_render_cpu_ms: 0.0,
        compositor_idle_cpu_ms: (interval_ms - work).max(0.0),
        client_frame_interval_ms: if r.previous_wait != 0 && r.wait_called > r.previous_wait {
            ms(r.wait_called - r.previous_wait) as f32
        } else {
            interval_ms
        },
        present_call_cpu_ms: 0.0,
        wait_for_present_cpu_ms: 0.0,
        submit_frame_ms: ms(r.submit_ticks) as f32,
        wait_get_poses_called_ms: rel(r.wait_called),
        new_poses_ready_ms: rel(r.wait_returned),
        new_frame_ready_ms: rel(r.last_submit),
        compositor_update_start_ms: 0.0,
        compositor_update_end_ms: 0.0,
        compositor_render_start_ms: 0.0,
        hmd_pose: ovr::device_pose(&r.pose, true, [0.0; 3]),
        num_vsyncs_ready_for_use: 1,
        num_vsyncs_to_first_view: 1,
    };
    // SAFETY: the game's struct holds `size` bytes; ours is copied up to that.
    unsafe {
        core::ptr::copy_nonoverlapping(
            (&t as *const FrameTiming).cast::<u8>(),
            out,
            size.min(core::mem::size_of::<FrameTiming>()),
        )
    };
    true
}
