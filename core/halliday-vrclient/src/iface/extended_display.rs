//! `IVRExtendedDisplay_001`: where the headset's display is, for games that ask even in direct
//! mode (Unreal 4 sizes its window from `GetWindowBounds`; left unanswered, it asked Metal for a
//! texture 32768 pixels high). Halliday answers with the PS VR2's panel, 4000 × 2040, both eyes
//! side by side, and no desktop output (the display isn't on the desktop: `IsDisplayOnDesktop`).

use crate::Iface;

type This = *mut Iface;

/// The PS VR2's panel.
const PANEL: (u32, u32) = (4000, 2040);

pub unsafe extern "C" fn get_window_bounds(
    _: This,
    x: *mut i32,
    y: *mut i32,
    width: *mut u32,
    height: *mut u32,
) {
    crate::log::seen!("IVRExtendedDisplay::get_window_bounds");
    // SAFETY: the game's out pointers (checked).
    unsafe {
        for (p, v) in [(x, 0), (y, 0)] {
            if !p.is_null() {
                *p = v;
            }
        }
        for (p, v) in [(width, PANEL.0), (height, PANEL.1)] {
            if !p.is_null() {
                *p = v;
            }
        }
    }
}

pub unsafe extern "C" fn get_eye_output_viewport(
    _: This,
    eye: i32,
    x: *mut u32,
    y: *mut u32,
    width: *mut u32,
    height: *mut u32,
) {
    crate::log::seen!("IVRExtendedDisplay::get_eye_output_viewport");
    let half = PANEL.0 / 2;
    let left = if eye == 1 { half } else { 0 };
    // SAFETY: the game's out pointers (checked).
    unsafe {
        for (p, v) in [(x, left), (y, 0), (width, half), (height, PANEL.1)] {
            if !p.is_null() {
                *p = v;
            }
        }
    }
}

pub unsafe extern "C" fn get_dxgi_output_info(_: This, adapter: *mut i32, output: *mut i32) {
    crate::log::seen!("IVRExtendedDisplay::get_dxgi_output_info");
    // SAFETY: the game's out pointers (checked). -1: no desktop output (as OpenVR documents).
    unsafe {
        for p in [adapter, output] {
            if !p.is_null() {
                *p = -1;
            }
        }
    }
}
