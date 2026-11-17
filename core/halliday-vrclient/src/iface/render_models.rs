//! `IVRRenderModels_005/006`: no models (the game draws its own controllers, or none).

use crate::Iface;
use crate::iface::system::write_string;
use crate::log::{CStr, log};
use core::ffi::{c_char, c_void};
use core::sync::atomic::{AtomicU64, Ordering};

type This = *mut Iface;

const INVALID_MODEL: i32 = 301;

fn null_out(out: *mut *mut c_void) {
    if !out.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *out = core::ptr::null_mut() };
    }
}

pub unsafe extern "C" fn load_render_model_async(
    _: This,
    name: *const c_char,
    out: *mut *mut c_void,
) -> i32 {
    crate::log::seen!("IVRRenderModels::load_render_model_async");
    static LOGGED: AtomicU64 = AtomicU64::new(0);
    if LOGGED.fetch_add(1, Ordering::Relaxed) < 4 {
        log!("render model asked for: {} (none)", CStr(name));
    }
    null_out(out);
    INVALID_MODEL
}
pub unsafe extern "C" fn free_render_model(_: This, _model: *mut c_void) {}
pub unsafe extern "C" fn load_texture_async(_: This, _id: i32, out: *mut *mut c_void) -> i32 {
    crate::log::seen!("IVRRenderModels::free_render_model");
    null_out(out);
    INVALID_MODEL
}
pub unsafe extern "C" fn free_texture(_: This, _texture: *mut c_void) {}
pub unsafe extern "C" fn load_texture_d3d11_async(
    _: This,
    _id: i32,
    _device: *mut c_void,
    out: *mut *mut c_void,
) -> i32 {
    crate::log::seen!("IVRRenderModels::free_texture");
    null_out(out);
    INVALID_MODEL
}
pub unsafe extern "C" fn load_into_texture_d3d11_async(
    _: This,
    _id: i32,
    _dst: *mut c_void,
) -> i32 {
    crate::log::seen!("IVRRenderModels::load_into_texture_d3d11_async");
    INVALID_MODEL
}
pub unsafe extern "C" fn free_texture_d3d11(_: This, _texture: *mut c_void) {}
pub unsafe extern "C" fn get_render_model_name(
    _: This,
    _index: u32,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRRenderModels::free_texture_d3d11");
    write_string(b"\0", out, size);
    0
}
pub unsafe extern "C" fn get_render_model_count(_: This) -> u32 {
    crate::log::seen!("IVRRenderModels::get_render_model_count");
    0
}
pub unsafe extern "C" fn get_component_count(_: This, _name: *const c_char) -> u32 {
    crate::log::seen!("IVRRenderModels::get_component_count");
    0
}
pub unsafe extern "C" fn get_component_name(
    _: This,
    _name: *const c_char,
    _i: u32,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRRenderModels::get_component_name");
    write_string(b"\0", out, size);
    0
}
pub unsafe extern "C" fn get_component_button_mask(
    _: This,
    _name: *const c_char,
    _component: *const c_char,
) -> u64 {
    crate::log::seen!("IVRRenderModels::get_component_button_mask");
    0
}
pub unsafe extern "C" fn get_component_render_model_name(
    _: This,
    _name: *const c_char,
    _component: *const c_char,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRRenderModels::get_component_render_model_name");
    write_string(b"\0", out, size);
    0
}
pub unsafe extern "C" fn get_component_state_for_device_path(
    _: This,
    _name: *const c_char,
    _component: *const c_char,
    _device: u64,
    _state: *const c_void,
    _out: *mut c_void,
) -> bool {
    crate::log::seen!("IVRRenderModels::get_component_state_for_device_path");
    false
}
pub unsafe extern "C" fn get_component_state(
    _: This,
    _name: *const c_char,
    _component: *const c_char,
    _controller: *const c_void,
    _state: *const c_void,
    _out: *mut c_void,
) -> bool {
    crate::log::seen!("IVRRenderModels::get_component_state");
    false
}
pub unsafe extern "C" fn render_model_has_component(
    _: This,
    _name: *const c_char,
    _component: *const c_char,
) -> bool {
    crate::log::seen!("IVRRenderModels::render_model_has_component");
    false
}
pub unsafe extern "C" fn get_render_model_thumbnail_url(
    _: This,
    _name: *const c_char,
    out: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVRRenderModels::get_render_model_thumbnail_url");
    write_string(b"\0", out, size);
    if !error.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *error = INVALID_MODEL };
    }
    0
}
pub unsafe extern "C" fn get_render_model_original_path(
    _: This,
    name: *const c_char,
    out: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVRRenderModels::get_render_model_original_path");
    // SAFETY: as above.
    unsafe { get_render_model_thumbnail_url(core::ptr::null_mut(), name, out, size, error) }
}
pub unsafe extern "C" fn get_render_model_error_name_from_enum(_: This, _e: i32) -> *const c_char {
    crate::log::seen!("IVRRenderModels::get_render_model_error_name_from_enum");
    c"VRRenderModelError".as_ptr()
}
