//! `IVRSettings_002`: no settings of its own; every read says unset, so the game uses its defaults.

use crate::Iface;
use crate::iface::system::write_string;
use crate::log::{CStr, log};
use core::ffi::c_char;
use core::sync::atomic::{AtomicU64, Ordering};

type This = *mut Iface;

fn set_error(error: *mut i32, e: i32) {
    if !error.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *error = e };
    }
}

// --- IVRSettings_002 ---

static SETTINGS_LOGGED: AtomicU64 = AtomicU64::new(0);

fn note_setting(section: *const c_char, key: *const c_char) {
    if SETTINGS_LOGGED.fetch_add(1, Ordering::Relaxed) < 40 {
        log!(
            "setting asked for: {} / {} (none: the game's default)",
            CStr(section),
            CStr(key)
        );
    }
}

pub unsafe extern "C" fn get_settings_error_name_from_enum(_: This, _e: i32) -> *const c_char {
    crate::log::seen!("IVRSettings::get_settings_error_name_from_enum");
    c"VRSettingsError".as_ptr()
}
pub unsafe extern "C" fn sync(_: This, _force: bool, error: *mut i32) -> bool {
    crate::log::seen!("IVRSettings::sync");
    set_error(error, 0);
    true
}
pub unsafe extern "C" fn set_bool(
    _: This,
    _s: *const c_char,
    _k: *const c_char,
    _v: bool,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::set_bool");
    set_error(error, 0);
}
pub unsafe extern "C" fn set_int32(
    _: This,
    _s: *const c_char,
    _k: *const c_char,
    _v: i32,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::set_int32");
    set_error(error, 0);
}
pub unsafe extern "C" fn set_float(
    _: This,
    _s: *const c_char,
    _k: *const c_char,
    _v: f32,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::set_float");
    set_error(error, 0);
}
pub unsafe extern "C" fn set_string(
    _: This,
    _s: *const c_char,
    _k: *const c_char,
    _v: *const c_char,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::set_string");
    set_error(error, 0);
}
const UNSET: i32 = 5; // UnsetSettingHasNoDefault
pub unsafe extern "C" fn get_bool(
    _: This,
    s: *const c_char,
    k: *const c_char,
    error: *mut i32,
) -> bool {
    crate::log::seen!("IVRSettings::get_bool");
    note_setting(s, k);
    set_error(error, UNSET);
    false
}
pub unsafe extern "C" fn get_int32(
    _: This,
    s: *const c_char,
    k: *const c_char,
    error: *mut i32,
) -> i32 {
    crate::log::seen!("IVRSettings::get_int32");
    note_setting(s, k);
    set_error(error, UNSET);
    0
}
pub unsafe extern "C" fn get_float(
    _: This,
    s: *const c_char,
    k: *const c_char,
    error: *mut i32,
) -> f32 {
    crate::log::seen!("IVRSettings::get_float");
    note_setting(s, k);
    set_error(error, UNSET);
    0.0
}
pub unsafe extern "C" fn get_string(
    _: This,
    s: *const c_char,
    k: *const c_char,
    out: *mut c_char,
    size: u32,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::get_string");
    note_setting(s, k);
    write_string(b"\0", out, size);
    set_error(error, UNSET);
}
pub unsafe extern "C" fn remove_section(_: This, _s: *const c_char, error: *mut i32) {
    crate::log::seen!("IVRSettings::remove_section");
    set_error(error, 0);
}
pub unsafe extern "C" fn remove_key_in_section(
    _: This,
    _s: *const c_char,
    _k: *const c_char,
    error: *mut i32,
) {
    crate::log::seen!("IVRSettings::remove_key_in_section");
    set_error(error, 0);
}
