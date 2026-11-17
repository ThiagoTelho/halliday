//! `IVRCompositor_021`: frame pacing (`WaitGetPoses`) and the frames the game submits. Methods in
//! the order of OpenVR 1.0.10's `openvr.h`.

use crate::Iface;
use crate::log::log;
use crate::ovr::{self, TrackedDevicePose};
use crate::runtime::{self, TRACKING_SPACE};
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

type This = *mut Iface;

pub unsafe extern "C" fn set_tracking_space(_: This, universe: u32) {
    crate::log::seen!("IVRCompositor::set_tracking_space");
    TRACKING_SPACE.store(universe, Ordering::Relaxed);
    // Unity sets it every frame: log changes only.
    static LOGGED: AtomicU32 = AtomicU32::new(u32::MAX);
    if LOGGED.swap(universe, Ordering::Relaxed) == universe {
        return;
    }
    log!(
        "tracking space {}",
        if universe == ovr::UNIVERSE_SEATED {
            "seated"
        } else {
            "standing"
        }
    );
}

pub unsafe extern "C" fn get_tracking_space(_: This) -> u32 {
    crate::log::seen!("IVRCompositor::get_tracking_space");
    TRACKING_SPACE.load(Ordering::Relaxed)
}

pub unsafe extern "C" fn wait_get_poses(
    _: This,
    render: *mut TrackedDevicePose,
    render_count: u32,
    game: *mut TrackedDevicePose,
    game_count: u32,
) -> i32 {
    crate::log::seen!("IVRCompositor::wait_get_poses");
    static FIRST: AtomicBool = AtomicBool::new(true);
    if FIRST.swap(false, Ordering::Relaxed) {
        log!("first WaitGetPoses: the game is rendering");
    }
    runtime::touch();
    // As SteamVR: not before the GPU has finished the previous frame (at most three display
    // frames), so the game can't queue frames drawn from old poses.
    crate::d3d11::wait_frame_end(f64::from(crate::scene::frame_interval()) * 3000.0);
    let state = runtime::wait_for_frame();
    let universe = TRACKING_SPACE.load(Ordering::Relaxed);
    runtime::fill_poses(&state, universe, render, render_count);
    runtime::fill_poses(&state, universe, game, game_count);
    ovr::COMPOSITOR_NONE
}

pub unsafe extern "C" fn get_last_poses(
    _: This,
    render: *mut TrackedDevicePose,
    render_count: u32,
    game: *mut TrackedDevicePose,
    game_count: u32,
) -> i32 {
    crate::log::seen!("IVRCompositor::get_last_poses");
    let state = runtime::SHARED.with(|s| s.state);
    let universe = TRACKING_SPACE.load(Ordering::Relaxed);
    runtime::fill_poses(&state, universe, render, render_count);
    runtime::fill_poses(&state, universe, game, game_count);
    ovr::COMPOSITOR_NONE
}

pub unsafe extern "C" fn get_last_pose_for_tracked_device_index(
    _: This,
    device: u32,
    pose: *mut TrackedDevicePose,
    game: *mut TrackedDevicePose,
) -> i32 {
    crate::log::seen!("IVRCompositor::get_last_pose_for_tracked_device_index");
    if device >= ovr::MAX_DEVICES {
        return 2; // IndexOutOfRange
    }
    let state = runtime::SHARED.with(|s| s.state);
    let mut all = [ovr::INVALID_POSE; 3];
    runtime::fill_poses(
        &state,
        TRACKING_SPACE.load(Ordering::Relaxed),
        all.as_mut_ptr(),
        3,
    );
    let p = if device < 3 {
        all[device as usize]
    } else {
        ovr::INVALID_POSE
    };
    // SAFETY: the game's out pointers (checked).
    unsafe {
        if !pose.is_null() {
            *pose = p;
        }
        if !game.is_null() {
            *game = p;
        }
    }
    ovr::COMPOSITOR_NONE
}

pub unsafe extern "C" fn submit(
    _: This,
    eye: i32,
    texture: *const ovr::Texture,
    bounds: *const [f32; 4],
    flags: i32,
) -> i32 {
    crate::log::seen!("IVRCompositor::submit");
    if texture.is_null() {
        return ovr::COMPOSITOR_INVALID_TEXTURE;
    }
    // SAFETY: the game's structs (bounds may be null).
    let (t, b) = unsafe { (&*texture, (!bounds.is_null()).then(|| *bounds)) };
    runtime::submit(eye as u32, t, b, flags)
}

pub unsafe extern "C" fn get_frame_timing(_: This, timing: *mut c_void, ago: u32) -> bool {
    crate::log::seen!("IVRCompositor::get_frame_timing");
    // Only the last frame is kept.
    // SAFETY: the game's struct, its size set.
    ago == 0 && unsafe { crate::scene::frame_timing(timing.cast()) }
}

pub unsafe extern "C" fn get_frame_timings(_: This, timing: *mut c_void, frames: u32) -> u32 {
    crate::log::seen!("IVRCompositor::get_frame_timings");
    // SAFETY: as above (the first of the game's array).
    (frames > 0 && unsafe { crate::scene::frame_timing(timing.cast()) }) as u32
}

pub unsafe extern "C" fn get_frame_time_remaining(_: This) -> f32 {
    crate::log::seen!("IVRCompositor::get_frame_time_remaining");
    let (since, _) = runtime::vsync_info();
    (crate::scene::frame_interval() - since).max(0.0)
}

pub unsafe extern "C" fn get_cumulative_stats(_: This, stats: *mut u8, size: u32) {
    crate::log::seen!("IVRCompositor::get_cumulative_stats");
    if !stats.is_null() {
        // SAFETY: the game's struct of `size` bytes.
        unsafe { core::ptr::write_bytes(stats, 0, size as usize) };
    }
}

pub unsafe extern "C" fn fade_to_color(
    _: This,
    seconds: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    background: bool,
) {
    crate::log::seen!("IVRCompositor::fade_to_color");
    let a = a.clamp(0.0, 1.0);
    crate::scene::edit(|scene, _| {
        let c = [r * a, g * a, b * a, a];
        if background {
            scene.background_color = c;
            scene.background_seconds = seconds.max(0.0);
        } else {
            scene.fade_color = c;
            scene.fade_seconds = seconds.max(0.0);
        }
    });
}

pub unsafe extern "C" fn get_current_fade_color(
    _: This,
    out: *mut ovr::HmdColor,
    background: bool,
) -> *mut ovr::HmdColor {
    crate::log::seen!("IVRCompositor::get_current_fade_color");
    let c = crate::scene::read().map_or([0.0; 4], |(s, _)| {
        let f = if background {
            s.background_color
        } else {
            s.fade_color
        };
        if f[3] > 0.0 {
            [f[0] / f[3], f[1] / f[3], f[2] / f[3], f[3]]
        } else {
            [0.0; 4]
        }
    });
    // SAFETY: the hidden return slot.
    unsafe { out.write(ovr::HmdColor(c)) };
    out
}

pub unsafe extern "C" fn fade_grid(_: This, seconds: f32, fade_in: bool) {
    crate::log::seen!("IVRCompositor::fade_grid");
    crate::scene::edit(|scene, _| {
        scene.grid = fade_in as u32;
        scene.grid_seconds = seconds.max(0.0);
    });
}

pub unsafe extern "C" fn get_current_grid_alpha(_: This) -> f32 {
    crate::log::seen!("IVRCompositor::get_current_grid_alpha");
    crate::scene::read().map_or(0.0, |(s, _)| s.grid as f32)
}

pub unsafe extern "C" fn set_skybox_override(
    _: This,
    textures: *const ovr::Texture,
    count: u32,
) -> i32 {
    crate::log::seen!("IVRCompositor::set_skybox_override");
    crate::scene::set_skybox(textures, count)
}

fn process_id() -> u32 {
    runtime::header().map_or(0, |h| {
        // SAFETY: a mapped header.
        unsafe { (*h).client_pid }
    })
}

pub unsafe extern "C" fn get_mirror_texture_d3d11(
    _: This,
    _eye: i32,
    _device: *mut c_void,
    _view: *mut *mut c_void,
) -> i32 {
    crate::log::seen!("IVRCompositor::mirror_d3d11");
    ovr::COMPOSITOR_REQUEST_FAILED
}

pub unsafe extern "C" fn release_mirror_texture_d3d11(_: This, _view: *mut c_void) {
    crate::log::seen!("IVRCompositor::release_mirror_d3d11");
}

pub unsafe extern "C" fn get_mirror_texture_gl(
    _: This,
    _eye: i32,
    _texture: *mut u32,
    _shared: *mut *mut c_void,
) -> i32 {
    crate::log::seen!("IVRCompositor::mirror_gl");
    ovr::COMPOSITOR_REQUEST_FAILED
}

pub unsafe extern "C" fn release_shared_gl_texture(
    _: This,
    _texture: u32,
    _shared: *mut c_void,
) -> bool {
    crate::log::seen!("IVRCompositor::release_shared_gl");
    false
}

pub unsafe extern "C" fn get_vulkan_instance_extensions_required(
    _: This,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRCompositor::vulkan_instance_extensions");
    crate::iface::system::write_string(b"\0", out, size);
    1
}

pub unsafe extern "C" fn get_vulkan_device_extensions_required(
    _: This,
    _device: *mut c_void,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRCompositor::vulkan_device_extensions");
    crate::iface::system::write_string(b"\0", out, size);
    1
}

pub unsafe extern "C" fn submit_explicit_timing_data(_: This) -> i32 {
    crate::log::seen!("IVRCompositor::submit_explicit_timing_data");
    ovr::COMPOSITOR_NONE
}

// Methods with nothing to do here, by name (the tables put each in its place).

pub unsafe extern "C" fn clear_last_submitted_frame(_: This) {}
pub unsafe extern "C" fn post_present_handoff(_: This) {}
pub unsafe extern "C" fn clear_skybox_override(_: This) {
    crate::log::seen!("IVRCompositor::clear_skybox_override");
    crate::scene::edit(|scene, _| scene.skybox = 0);
}
pub unsafe extern "C" fn compositor_bring_to_front(_: This) {}
pub unsafe extern "C" fn compositor_go_to_back(_: This) {}
pub unsafe extern "C" fn compositor_quit(_: This) {}
pub unsafe extern "C" fn show_mirror_window(_: This) {}
pub unsafe extern "C" fn hide_mirror_window(_: This) {}
pub unsafe extern "C" fn compositor_dump_images(_: This) {}
pub unsafe extern "C" fn force_reconnect_process(_: This) {}
pub unsafe extern "C" fn force_interleaved_reprojection_on(_: This, _on: bool) {}
pub unsafe extern "C" fn suspend_rendering(_: This, suspend: bool) {
    crate::log::seen!("IVRCompositor::suspend_rendering");
    crate::scene::edit(|scene, _| scene.suspended = suspend as u32);
}
pub unsafe extern "C" fn set_explicit_timing_mode(_: This, _mode: bool) {}
pub unsafe extern "C" fn lock_gl_shared_texture_for_access(_: This, _shared: *mut c_void) {}
pub unsafe extern "C" fn unlock_gl_shared_texture_for_access(_: This, _shared: *mut c_void) {}

pub unsafe extern "C" fn is_fullscreen(_: This) -> bool {
    true
}
pub unsafe extern "C" fn can_render_scene(_: This) -> bool {
    true
}
pub unsafe extern "C" fn is_mirror_window_visible(_: This) -> bool {
    false
}
pub unsafe extern "C" fn should_app_render_with_low_resources(_: This) -> bool {
    false
}
pub unsafe extern "C" fn get_current_scene_focus_process(_: This) -> u32 {
    process_id()
}
pub unsafe extern "C" fn get_last_frame_renderer(_: This) -> u32 {
    process_id()
}

// Added at the end of IVRCompositor_022 by OpenVR 1.7.

pub unsafe extern "C" fn is_motion_smoothing_enabled(_: This) -> bool {
    false
}
pub unsafe extern "C" fn is_motion_smoothing_supported(_: This) -> bool {
    false
}
pub unsafe extern "C" fn is_current_scene_focus_app_loading(_: This) -> bool {
    false
}
