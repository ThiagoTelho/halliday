//! Halliday's OpenVR runtime for Windows games under Wine: `vrclient_x64.dll`.
//!
//! A game's `openvr_api.dll` finds this DLL through `openvrpaths.vrpath` in the Wine prefix
//! (`%LOCALAPPDATA%\openvr`), loads it from `<runtime>\bin\` and calls `VRClientCoreFactory`. The
//! runtime answers the OpenVR 1.0.10 interfaces (`IVRSystem_017`, `IVRCompositor_021`, …) from the
//! state Halliday.app shares through `halliday-bridge.shm` in the runtime folder, and copies each
//! submitted frame there for Halliday to show. Written for Halliday; the interface layouts follow
//! Valve's `openvr.h` (BSD-3-Clause, see THIRD-PARTY.md). No code is taken from other runtimes.
//!
//! It is `no_std` and links nothing but kernel32 and opengl32 (`raw-dylib`), so it builds on the
//! Mac with Rust's own linker (`make vrclient`).

#![no_std]
#![allow(clippy::missing_safety_doc)]

mod d3d11;
mod gl;
mod glfix;
mod iface;
mod json;
mod log;
mod ovr;
mod present;
mod runtime;
mod scene;
mod win;

use core::ffi::{c_char, c_void};
use log::{CStr, log};

/// A C++ interface object: a pointer to its table of methods.
#[repr(C)]
pub struct Iface {
    vtable: *const c_void,
}

unsafe impl Sync for Iface {}

/// A table of methods.
#[repr(C)]
pub struct VTable<const N: usize>(pub [*const c_void; N]);

unsafe impl<const N: usize> Sync for VTable<N> {}

macro_rules! slot {
    ($f:expr) => {
        $f as *const ::core::ffi::c_void
    };
}
pub(crate) use slot;

impl Iface {
    pub const fn new<const N: usize>(table: &'static VTable<N>) -> Iface {
        Iface {
            vtable: table as *const VTable<N> as *const c_void,
        }
    }
}

static CLIENT_CORE: Iface = Iface::new(&CLIENT_CORE_VTABLE);

/// A method not written yet (tables.rs fills every such slot with one): does nothing, returns 0,
/// and logs its first call with its interface and index.
pub unsafe extern "C" fn stand_in<const I: usize, const S: usize>() -> u64 {
    use core::sync::atomic::{AtomicU64, Ordering};
    static SEEN: [[AtomicU64; 2]; iface::tables::NAMES.len()] =
        [const { [const { AtomicU64::new(0) }; 2] }; iface::tables::NAMES.len()];
    let (word, bit) = (S / 64, S % 64);
    if SEEN[I][word.min(1)].fetch_or(1 << bit, Ordering::Relaxed) & (1 << bit) == 0 {
        log!(
            "{} method {S} called (not provided: returned 0)",
            iface::tables::NAMES[I]
        );
    }
    0
}

/// The interfaces this runtime answers, by their versioned names (C++ objects, or `FnTable:`
/// C function tables).
fn interface(name: &[u8]) -> Option<*const c_void> {
    iface::tables::lookup(name)
}

fn bytes(s: *const c_char) -> &'static [u8] {
    if s.is_null() {
        return b"";
    }
    let mut n = 0;
    // SAFETY: a NUL-terminated string from the loader or the game; at most 256 bytes looked at.
    while n < 256 && unsafe { *s.add(n) } != 0 {
        n += 1;
    }
    // SAFETY: `n` bytes just read.
    unsafe { core::slice::from_raw_parts(s.cast(), n) }
}

// --- IVRClientCore_003, what openvr_api.dll talks to ---

type This = *mut Iface;

unsafe extern "C" fn core_init(_: This, app_type: i32, startup: *const c_char) -> i32 {
    crate::log::seen!("IVRClientCore::core_init");
    if !runtime::connect() {
        return ovr::INIT_HMD_NOT_FOUND;
    }
    log!(
        "VR_Init: application type {app_type}, startup info {}",
        CStr(startup)
    );
    glfix::install();
    runtime::touch();
    scene::set_initialized(true);
    ovr::INIT_NONE
}

unsafe extern "C" fn core_cleanup(_: This) {
    crate::log::seen!("IVRClientCore::core_cleanup");
    log!("VR_Shutdown");
    scene::set_initialized(false);
}

unsafe extern "C" fn core_is_interface_version_valid(_: This, name: *const c_char) -> i32 {
    log!("interface version {} checked", CStr(name));
    if interface(bytes(name)).is_some() {
        ovr::INIT_NONE
    } else {
        ovr::INIT_INTERFACE_NOT_FOUND
    }
}

unsafe extern "C" fn core_get_generic_interface(
    _: This,
    name: *const c_char,
    error: *mut i32,
) -> *mut c_void {
    crate::log::seen!("IVRClientCore::core_get_generic_interface");
    let found = interface(bytes(name));
    log!(
        "interface {} asked for{}",
        CStr(name),
        if found.is_some() {
            ""
        } else {
            ": not provided"
        }
    );
    if !error.is_null() {
        // SAFETY: the caller's out pointer.
        unsafe {
            *error = if found.is_some() {
                ovr::INIT_NONE
            } else {
                ovr::INIT_INTERFACE_NOT_FOUND
            }
        };
    }
    found.map_or(core::ptr::null_mut(), |p| p as *mut c_void)
}

unsafe extern "C" fn core_is_hmd_present(_: This) -> bool {
    crate::log::seen!("IVRClientCore::core_is_hmd_present");
    runtime::is_hmd_present()
}

unsafe extern "C" fn core_error_string(_: This, error: i32) -> *const c_char {
    crate::log::seen!("IVRClientCore::core_error_string");
    match error {
        ovr::INIT_NONE => c"No error".as_ptr(),
        ovr::INIT_HMD_NOT_FOUND => c"Halliday isn't running (start Halliday.app first)".as_ptr(),
        ovr::INIT_INTERFACE_NOT_FOUND => {
            c"This OpenVR interface isn't provided by Halliday yet".as_ptr()
        }
        _ => c"Halliday OpenVR error".as_ptr(),
    }
}

unsafe extern "C" fn core_error_id(_: This, error: i32) -> *const c_char {
    crate::log::seen!("IVRClientCore::core_error_id");
    match error {
        ovr::INIT_NONE => c"VRInitError_None".as_ptr(),
        ovr::INIT_HMD_NOT_FOUND => c"VRInitError_Init_HmdNotFound".as_ptr(),
        ovr::INIT_INTERFACE_NOT_FOUND => c"VRInitError_Init_InterfaceNotFound".as_ptr(),
        _ => c"VRInitError_Unknown".as_ptr(),
    }
}

static CLIENT_CORE_VTABLE: VTable<7> = VTable([
    slot!(core_init),
    slot!(core_cleanup),
    slot!(core_is_interface_version_valid),
    slot!(core_get_generic_interface),
    slot!(core_is_hmd_present),
    slot!(core_error_string),
    slot!(core_error_id),
]);

/// The DLL's one export: `openvr_api.dll` asks it for `IVRClientCore_003`.
///
/// # Safety
/// `name` is a NUL-terminated string; `code` is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn VRClientCoreFactory(name: *const c_char, code: *mut i32) -> *mut c_void {
    let ok = bytes(name) == b"IVRClientCore_003";
    if !code.is_null() {
        // SAFETY: the caller's out pointer.
        unsafe { *code = if ok { 0 } else { ovr::INIT_INTERFACE_NOT_FOUND } };
    }
    if ok {
        &CLIENT_CORE as *const Iface as *mut c_void
    } else {
        core::ptr::null_mut()
    }
}

// The pieces of a C runtime this DLL needs (shared with the test program).
#[path = "crt.rs"]
mod crt;
pub use crt::fast_copy;

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    log!("panic: stopping");
    loop {
        // SAFETY: plain call.
        unsafe { win::Sleep(1000) };
    }
}
