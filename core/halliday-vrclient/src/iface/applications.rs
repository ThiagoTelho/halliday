//! `IVRApplications_006`: no application manifests and no launching; the game may identify itself.

use crate::Iface;
use crate::iface::system::write_string;
use crate::log::{CStr, log};
use core::ffi::{c_char, c_void};

type This = *mut Iface;

const NO_APPLICATION: i32 = 102;
const INVALID_INDEX: i32 = 103;
const UNKNOWN_APPLICATION: i32 = 104;
const LAUNCH_FAILED: i32 = 109;
const PROPERTY_NOT_SET: i32 = 201;

fn set_error(error: *mut i32, e: i32) {
    if !error.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *error = e };
    }
}

pub unsafe extern "C" fn add_application_manifest(
    _: This,
    _path: *const c_char,
    _temporary: bool,
) -> i32 {
    crate::log::seen!("IVRApplications::add_application_manifest");
    0
}
pub unsafe extern "C" fn remove_application_manifest(_: This, _path: *const c_char) -> i32 {
    crate::log::seen!("IVRApplications::remove_application_manifest");
    0
}
pub unsafe extern "C" fn is_application_installed(_: This, _key: *const c_char) -> bool {
    crate::log::seen!("IVRApplications::is_application_installed");
    false
}
pub unsafe extern "C" fn get_application_count(_: This) -> u32 {
    crate::log::seen!("IVRApplications::get_application_count");
    0
}
pub unsafe extern "C" fn get_application_key_by_index(
    _: This,
    _index: u32,
    out: *mut c_char,
    size: u32,
) -> i32 {
    crate::log::seen!("IVRApplications::get_application_key_by_index");
    write_string(b"\0", out, size);
    INVALID_INDEX
}
pub unsafe extern "C" fn get_application_key_by_process_id(
    _: This,
    _pid: u32,
    out: *mut c_char,
    size: u32,
) -> i32 {
    crate::log::seen!("IVRApplications::get_application_key_by_process_id");
    write_string(b"\0", out, size);
    NO_APPLICATION
}
pub unsafe extern "C" fn launch_application(_: This, _key: *const c_char) -> i32 {
    crate::log::seen!("IVRApplications::launch_application");
    UNKNOWN_APPLICATION
}
pub unsafe extern "C" fn launch_template_application(
    _: This,
    _t: *const c_char,
    _n: *const c_char,
    _keys: *const c_void,
    _count: u32,
) -> i32 {
    crate::log::seen!("IVRApplications::launch_template_application");
    UNKNOWN_APPLICATION
}
pub unsafe extern "C" fn launch_application_from_mime_type(
    _: This,
    _mime: *const c_char,
    _args: *const c_char,
) -> i32 {
    crate::log::seen!("IVRApplications::launch_application_from_mime_type");
    UNKNOWN_APPLICATION
}
pub unsafe extern "C" fn launch_dashboard_overlay(_: This, _key: *const c_char) -> i32 {
    crate::log::seen!("IVRApplications::launch_dashboard_overlay");
    UNKNOWN_APPLICATION
}
pub unsafe extern "C" fn cancel_application_launch(_: This, _key: *const c_char) -> bool {
    crate::log::seen!("IVRApplications::cancel_application_launch");
    false
}
pub unsafe extern "C" fn identify_application(_: This, pid: u32, key: *const c_char) -> i32 {
    crate::log::seen!("IVRApplications::identify_application");
    log!(
        "the game identifies itself as {} (process {pid})",
        CStr(key)
    );
    0
}
pub unsafe extern "C" fn get_application_process_id(_: This, _key: *const c_char) -> u32 {
    crate::log::seen!("IVRApplications::get_application_process_id");
    0
}
pub unsafe extern "C" fn get_applications_error_name_from_enum(_: This, _e: i32) -> *const c_char {
    crate::log::seen!("IVRApplications::get_applications_error_name_from_enum");
    c"VRApplicationError".as_ptr()
}
pub unsafe extern "C" fn get_application_property_string(
    _: This,
    _key: *const c_char,
    _prop: i32,
    out: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVRApplications::get_application_property_string");
    write_string(b"\0", out, size);
    set_error(error, PROPERTY_NOT_SET);
    0
}
pub unsafe extern "C" fn get_application_property_bool(
    _: This,
    _key: *const c_char,
    _prop: i32,
    error: *mut i32,
) -> bool {
    crate::log::seen!("IVRApplications::get_application_property_bool");
    set_error(error, PROPERTY_NOT_SET);
    false
}
pub unsafe extern "C" fn get_application_property_uint64(
    _: This,
    _key: *const c_char,
    _prop: i32,
    error: *mut i32,
) -> u64 {
    crate::log::seen!("IVRApplications::get_application_property_uint64");
    set_error(error, PROPERTY_NOT_SET);
    0
}
pub unsafe extern "C" fn set_application_auto_launch(
    _: This,
    _key: *const c_char,
    _auto: bool,
) -> i32 {
    crate::log::seen!("IVRApplications::set_application_auto_launch");
    0
}
pub unsafe extern "C" fn get_application_auto_launch(_: This, _key: *const c_char) -> bool {
    crate::log::seen!("IVRApplications::get_application_auto_launch");
    false
}
pub unsafe extern "C" fn set_default_application_for_mime_type(
    _: This,
    _key: *const c_char,
    _mime: *const c_char,
) -> i32 {
    crate::log::seen!("IVRApplications::set_default_application_for_mime_type");
    0
}
pub unsafe extern "C" fn get_default_application_for_mime_type(
    _: This,
    _mime: *const c_char,
    out: *mut c_char,
    size: u32,
) -> bool {
    crate::log::seen!("IVRApplications::get_default_application_for_mime_type");
    write_string(b"\0", out, size);
    false
}
pub unsafe extern "C" fn get_application_supported_mime_types(
    _: This,
    _key: *const c_char,
    out: *mut c_char,
    size: u32,
) -> bool {
    crate::log::seen!("IVRApplications::get_application_supported_mime_types");
    write_string(b"\0", out, size);
    false
}
pub unsafe extern "C" fn get_applications_that_support_mime_type(
    _: This,
    _mime: *const c_char,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRApplications::get_applications_that_support_mime_type");
    write_string(b"\0", out, size);
    0
}
pub unsafe extern "C" fn get_application_launch_arguments(
    _: This,
    _handle: u32,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRApplications::get_application_launch_arguments");
    write_string(b"\0", out, size);
    0
}
pub unsafe extern "C" fn get_starting_application(_: This, out: *mut c_char, size: u32) -> i32 {
    crate::log::seen!("IVRApplications::get_starting_application");
    write_string(b"\0", out, size);
    NO_APPLICATION
}
pub unsafe extern "C" fn get_transition_state(_: This) -> i32 {
    crate::log::seen!("IVRApplications::get_transition_state");
    0
}
pub unsafe extern "C" fn perform_application_prelaunch_check(_: This, _key: *const c_char) -> i32 {
    crate::log::seen!("IVRApplications::perform_application_prelaunch_check");
    UNKNOWN_APPLICATION
}
pub unsafe extern "C" fn get_applications_transition_state_name_from_enum(
    _: This,
    _state: i32,
) -> *const c_char {
    crate::log::seen!("IVRApplications::get_applications_transition_state_name_from_enum");
    c"VRApplicationTransition_None".as_ptr()
}
pub unsafe extern "C" fn is_quit_user_prompt_requested(_: This) -> bool {
    crate::log::seen!("IVRApplications::is_quit_user_prompt_requested");
    false
}
pub unsafe extern "C" fn launch_internal_process(
    _: This,
    _b: *const c_char,
    _a: *const c_char,
    _w: *const c_char,
) -> u32 {
    crate::log::seen!("IVRApplications::launch_internal_process");
    LAUNCH_FAILED as u32
}
pub unsafe extern "C" fn get_current_scene_process_id(_: This) -> u32 {
    crate::log::seen!("IVRApplications::get_current_scene_process_id");
    crate::runtime::header().map_or(0, |h| {
        // SAFETY: a mapped header.
        unsafe { (*h).client_pid }
    })
}
