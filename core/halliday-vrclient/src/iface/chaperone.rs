//! `IVRChaperone_003`: a 2 × 2 m play area, calibrated, bounds hidden.

use crate::Iface;
use core::ffi::c_void;

type This = *mut Iface;

// --- IVRChaperone_003 ---

pub unsafe extern "C" fn get_calibration_state(_: This) -> i32 {
    crate::log::seen!("IVRChaperone::get_calibration_state");
    1 // OK
}

pub unsafe extern "C" fn get_play_area_size(_: This, x: *mut f32, z: *mut f32) -> bool {
    crate::log::seen!("IVRChaperone::get_play_area_size");
    // SAFETY: the game's out pointers (checked).
    unsafe {
        if !x.is_null() {
            *x = 2.0;
        }
        if !z.is_null() {
            *z = 2.0;
        }
    }
    true
}

pub unsafe extern "C" fn get_play_area_rect(_: This, rect: *mut [[f32; 3]; 4]) -> bool {
    crate::log::seen!("IVRChaperone::get_play_area_rect");
    if !rect.is_null() {
        // SAFETY: the game's HmdQuad_t.
        unsafe {
            *rect = [
                [-1.0, 0.0, -1.0],
                [1.0, 0.0, -1.0],
                [1.0, 0.0, 1.0],
                [-1.0, 0.0, 1.0],
            ]
        };
    }
    true
}

pub unsafe extern "C" fn reload_info(_: This) {
    crate::log::seen!("IVRChaperone::reload_info");
}
pub unsafe extern "C" fn set_scene_color(_: This, _p: *const c_void) {
    crate::log::seen!("IVRChaperone::set_scene_color");
}
pub unsafe extern "C" fn get_bounds_color(
    _: This,
    _out: *mut c_void,
    _n: i32,
    _fade: f32,
    _camera: *mut c_void,
) {
    crate::log::seen!("IVRChaperone::get_bounds_color");
}
pub unsafe extern "C" fn are_bounds_visible(_: This) -> bool {
    crate::log::seen!("IVRChaperone::are_bounds_visible");
    false
}
pub unsafe extern "C" fn force_bounds_visible(_: This, _b: bool) {
    crate::log::seen!("IVRChaperone::force_bounds_visible");
}
