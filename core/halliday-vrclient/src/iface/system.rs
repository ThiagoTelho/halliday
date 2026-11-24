//! `IVRSystem_017`: the headset, its displays and lenses, the tracked devices, controller state
//! and events. Methods in the order of OpenVR 1.0.10's `openvr.h`.

use crate::Iface;
use crate::log::{CStr, log};
use crate::ovr::{self, HmdMatrix34, HmdMatrix44, TrackedDevicePose};
use crate::runtime::{self, SHARED};
use core::ffi::{c_char, c_void};

type This = *mut Iface;

fn config() -> (u32, u32, f32, f32, [[f32; 4]; 2]) {
    match runtime::header() {
        // SAFETY: a mapped header; Halliday wrote these before the game started.
        Some(h) => unsafe {
            (
                (*h).eye_width,
                (*h).eye_height,
                1.0 / crate::scene::frame_interval(),
                (*h).ipd,
                (*h).tangents,
            )
        },
        None => (
            1440,
            1468,
            90.0,
            0.063,
            [[-1.88, 0.95, 1.33, -1.33], [-0.95, 1.88, 1.33, -1.33]],
        ),
    }
}

/// OpenVR's raw projection: left, right, top, bottom tangents. OpenVR's "top" is the lower edge's
/// tangent and "bottom" the upper one's (a quirk every runtime reproduces).
fn raw_projection(eye: i32) -> [f32; 4] {
    let t = config().4[(eye != 0) as usize];
    [t[0], t[1], t[3], t[2]]
}

pub unsafe extern "C" fn get_recommended_render_target_size(_: This, w: *mut u32, h: *mut u32) {
    crate::log::seen!("IVRSystem::get_recommended_render_target_size");
    let (ew, eh, ..) = config();
    // Logged when it changes: Unity asks every frame.
    static LAST: core::sync::atomic::AtomicU64 = core::sync::atomic::AtomicU64::new(0);
    let size = ((ew as u64) << 32) | eh as u64;
    if LAST.swap(size, core::sync::atomic::Ordering::Relaxed) != size {
        log!("render target {ew}x{eh} per eye");
    }
    // SAFETY: the game's out pointers (checked).
    unsafe {
        if !w.is_null() {
            *w = ew;
        }
        if !h.is_null() {
            *h = eh;
        }
    }
}

pub unsafe extern "C" fn get_projection_matrix(
    _: This,
    out: *mut HmdMatrix44,
    eye: i32,
    near: f32,
    far: f32,
) -> *mut HmdMatrix44 {
    crate::log::seen!("IVRSystem::get_projection_matrix");
    let [l, r, t, b] = raw_projection(eye);
    let (idx, idy, idz) = (1.0 / (r - l), 1.0 / (b - t), 1.0 / (far - near));
    let (sx, sy) = (r + l, b + t);
    let m = [
        [2.0 * idx, 0.0, sx * idx, 0.0],
        [0.0, 2.0 * idy, sy * idy, 0.0],
        [0.0, 0.0, -far * idz, -far * near * idz],
        [0.0, 0.0, -1.0, 0.0],
    ];
    // SAFETY: the hidden return slot.
    unsafe { out.write(HmdMatrix44(m)) };
    out
}

pub unsafe extern "C" fn get_projection_raw(
    _: This,
    eye: i32,
    l: *mut f32,
    r: *mut f32,
    t: *mut f32,
    b: *mut f32,
) {
    crate::log::seen!("IVRSystem::get_projection_raw");
    let p = raw_projection(eye);
    // SAFETY: the game's out pointers (checked).
    unsafe {
        for (ptr, v) in [(l, p[0]), (r, p[1]), (t, p[2]), (b, p[3])] {
            if !ptr.is_null() {
                *ptr = v;
            }
        }
    }
}

pub unsafe extern "C" fn compute_distortion(
    _: This,
    _eye: i32,
    u: f32,
    v: f32,
    out: *mut [f32; 6],
) -> bool {
    crate::log::seen!("IVRSystem::compute_distortion");
    // Halliday corrects for the lenses itself: the game's image is used undistorted.
    if !out.is_null() {
        // SAFETY: the game's out struct (red, green, blue UVs).
        unsafe { *out = [u, v, u, v, u, v] };
    }
    true
}

pub unsafe extern "C" fn get_eye_to_head_transform(
    _: This,
    out: *mut HmdMatrix34,
    eye: i32,
) -> *mut HmdMatrix34 {
    crate::log::seen!("IVRSystem::get_eye_to_head_transform");
    let half = config().3 / 2.0;
    let mut m = ovr::IDENTITY34;
    m[0][3] = if eye == 0 { -half } else { half };
    // SAFETY: the hidden return slot.
    unsafe { out.write(m) };
    out
}

pub unsafe extern "C" fn get_time_since_last_vsync(
    _: This,
    seconds: *mut f32,
    frame: *mut u64,
) -> bool {
    crate::log::seen!("IVRSystem::get_time_since_last_vsync");
    let (s, f) = runtime::vsync_info();
    // SAFETY: the game's out pointers (checked).
    unsafe {
        if !seconds.is_null() {
            *seconds = s;
        }
        if !frame.is_null() {
            *frame = f;
        }
    }
    true
}

pub unsafe extern "C" fn get_d3d9_adapter_index(_: This) -> i32 {
    crate::log::seen!("IVRSystem::get_d3d9_adapter_index");
    0
}

pub unsafe extern "C" fn get_dxgi_output_info(_: This, index: *mut i32) {
    crate::log::seen!("IVRSystem::get_dxgi_output_info");
    if !index.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *index = 0 };
    }
}

pub unsafe extern "C" fn get_output_device(
    _: This,
    device: *mut u64,
    _kind: i32,
    _instance: *mut c_void,
) {
    crate::log::seen!("IVRSystem::get_output_device");
    if !device.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *device = 0 };
    }
}

pub unsafe extern "C" fn is_display_on_desktop(_: This) -> bool {
    crate::log::seen!("IVRSystem::is_display_on_desktop");
    false
}

pub unsafe extern "C" fn set_display_visibility(_: This, _visible: bool) -> bool {
    crate::log::seen!("IVRSystem::set_display_visibility");
    false
}

pub unsafe extern "C" fn get_device_to_absolute_tracking_pose(
    _: This,
    universe: u32,
    _ahead: f32,
    out: *mut TrackedDevicePose,
    count: u32,
) {
    crate::log::seen!("IVRSystem::get_device_to_absolute_tracking_pose");
    let state = runtime::latest_state();
    runtime::fill_poses(&state, universe, out, count);
}

pub unsafe extern "C" fn reset_seated_zero_pose(_: This) {
    crate::log::seen!("IVRSystem::reset_seated_zero_pose");
    let head = runtime::latest_state().head;
    SHARED.with(|s| s.seated_zero = head.position);
}

pub unsafe extern "C" fn get_seated_zero_pose_to_standing_absolute_tracking_pose(
    _: This,
    out: *mut HmdMatrix34,
) -> *mut HmdMatrix34 {
    crate::log::seen!("IVRSystem::get_seated_zero_pose_to_standing_absolute_tracking_pose");
    let zero = SHARED.with(|s| s.seated_zero);
    let mut m = ovr::IDENTITY34;
    for (row, v) in m.iter_mut().zip(zero) {
        row[3] = v;
    }
    // SAFETY: the hidden return slot.
    unsafe { out.write(m) };
    out
}

pub unsafe extern "C" fn get_raw_zero_pose_to_standing_absolute_tracking_pose(
    _: This,
    out: *mut HmdMatrix34,
) -> *mut HmdMatrix34 {
    crate::log::seen!("IVRSystem::get_raw_zero_pose_to_standing_absolute_tracking_pose");
    // SAFETY: the hidden return slot.
    unsafe { out.write(ovr::IDENTITY34) };
    out
}

pub unsafe extern "C" fn get_sorted_tracked_device_indices_of_class(
    _: This,
    class: i32,
    out: *mut u32,
    count: u32,
    _relative: u32,
) -> u32 {
    crate::log::seen!("IVRSystem::get_sorted_tracked_device_indices_of_class");
    let state = runtime::latest_state();
    let mut found = [0u32; 2];
    let n = match class {
        ovr::CLASS_HMD => {
            found[0] = ovr::HMD;
            1
        }
        ovr::CLASS_CONTROLLER => {
            let mut n = 0;
            for (i, c) in state.controllers.iter().enumerate() {
                if c.connected != 0 {
                    found[n] = i as u32 + 1;
                    n += 1;
                }
            }
            n
        }
        _ => 0,
    };
    if !out.is_null() {
        for (i, &d) in found.iter().take(n.min(count as usize)).enumerate() {
            // SAFETY: the game's array holds `count`.
            unsafe { *out.add(i) = d };
        }
    }
    n as u32
}

pub unsafe extern "C" fn get_tracked_device_activity_level(_: This, _device: u32) -> i32 {
    crate::log::seen!("IVRSystem::get_tracked_device_activity_level");
    1 // user interaction
}

#[allow(clippy::needless_range_loop)] // matrix product, by index
pub unsafe extern "C" fn apply_transform(
    _: This,
    out: *mut TrackedDevicePose,
    pose: *const TrackedDevicePose,
    t: *const HmdMatrix34,
) {
    crate::log::seen!("IVRSystem::apply_transform");
    if out.is_null() || pose.is_null() || t.is_null() {
        return;
    }
    // SAFETY: the game's structs.
    unsafe {
        let mut r = *pose;
        let (a, b) = (&(*pose).device_to_absolute, &*t);
        for i in 0..3 {
            for j in 0..4 {
                r.device_to_absolute[i][j] = a[i][0] * b[0][j]
                    + a[i][1] * b[1][j]
                    + a[i][2] * b[2][j]
                    + if j == 3 { a[i][3] } else { 0.0 };
            }
        }
        *out = r;
    }
}

pub unsafe extern "C" fn get_tracked_device_index_for_controller_role(_: This, role: i32) -> u32 {
    crate::log::seen!("IVRSystem::get_tracked_device_index_for_controller_role");
    match role {
        ovr::ROLE_LEFT => ovr::LEFT,
        ovr::ROLE_RIGHT => ovr::RIGHT,
        _ => ovr::DEVICE_INVALID,
    }
}

pub unsafe extern "C" fn get_controller_role_for_tracked_device_index(_: This, device: u32) -> i32 {
    crate::log::seen!("IVRSystem::get_controller_role_for_tracked_device_index");
    match device {
        ovr::LEFT => ovr::ROLE_LEFT,
        ovr::RIGHT => ovr::ROLE_RIGHT,
        _ => ovr::ROLE_INVALID,
    }
}

fn class_of(device: u32) -> i32 {
    match device {
        ovr::HMD => ovr::CLASS_HMD,
        ovr::LEFT | ovr::RIGHT => {
            let state = runtime::latest_state();
            if state.controllers[(device - 1) as usize].connected != 0 {
                ovr::CLASS_CONTROLLER
            } else {
                ovr::CLASS_INVALID
            }
        }
        _ => ovr::CLASS_INVALID,
    }
}

pub unsafe extern "C" fn get_tracked_device_class(_: This, device: u32) -> i32 {
    crate::log::seen!("IVRSystem::get_tracked_device_class");
    class_of(device)
}

pub unsafe extern "C" fn is_tracked_device_connected(_: This, device: u32) -> bool {
    crate::log::seen!("IVRSystem::is_tracked_device_connected");
    class_of(device) != ovr::CLASS_INVALID
}

/// A property's value, by type.
enum Value {
    Bool(bool),
    Float(f32),
    Int(i32),
    U64(u64),
    Str(&'static [u8]),
}

fn property(device: u32, prop: i32) -> Result<Value, i32> {
    use Value::*;
    let class = class_of(device);
    if class == ovr::CLASS_INVALID {
        return Err(ovr::PROP_INVALID_DEVICE);
    }
    let hmd = class == ovr::CLASS_HMD;
    let (_, _, hz, ipd, _) = config();
    let buttons: u64 = [0u32, 1, 2, 32, 33].iter().fold(0, |m, b| m | 1 << b);
    // The emulated controllers are Vive wands, so games that only know a few kinds bind them.
    Ok(match prop {
        ovr::PROP_TRACKING_SYSTEM_NAME => Str(b"lighthouse\0"),
        ovr::PROP_MODEL_NUMBER => Str(if hmd {
            b"PlayStation VR2 (Halliday)\0"
        } else {
            b"Vive. Controller MV\0"
        }),
        ovr::PROP_SERIAL_NUMBER => Str(match device {
            ovr::HMD => b"HALLIDAY-HMD\0",
            ovr::LEFT => b"HALLIDAY-LEFT\0",
            _ => b"HALLIDAY-RIGHT\0",
        }),
        ovr::PROP_RENDER_MODEL_NAME => Str(if hmd {
            b"generic_hmd\0"
        } else {
            b"vr_controller_vive_1_5\0"
        }),
        ovr::PROP_MANUFACTURER_NAME => Str(if hmd { b"Halliday\0" } else { b"HTC\0" }),
        ovr::PROP_TRACKING_FIRMWARE_VERSION | ovr::PROP_HARDWARE_REVISION => Str(b"1\0"),
        ovr::PROP_DRIVER_VERSION => {
            Str(concat!("halliday ", env!("CARGO_PKG_VERSION"), "\0").as_bytes())
        }
        ovr::PROP_WILL_DRIFT_IN_YAW
        | ovr::PROP_DEVICE_IS_WIRELESS
        | ovr::PROP_DEVICE_IS_CHARGING
        | ovr::PROP_CONTAINS_PROXIMITY_SENSOR
        | ovr::PROP_PROVIDES_BATTERY_STATUS
        | ovr::PROP_DEVICE_CAN_POWER_OFF
        | ovr::PROP_HAS_CAMERA
        | ovr::PROP_IS_ON_DESKTOP => Bool(false),
        ovr::PROP_BATTERY_PERCENTAGE => Float(1.0),
        ovr::PROP_DEVICE_CLASS => Int(class),
        ovr::PROP_SECONDS_VSYNC_TO_PHOTONS if hmd => Float(0.011),
        ovr::PROP_DISPLAY_FREQUENCY if hmd => Float(hz),
        ovr::PROP_USER_IPD if hmd => Float(ipd),
        ovr::PROP_USER_HEAD_TO_EYE_DEPTH if hmd => Float(0.0),
        ovr::PROP_CURRENT_UNIVERSE_ID => U64(1),
        ovr::PROP_SUPPORTED_BUTTONS if !hmd => U64(buttons),
        ovr::PROP_CONTROLLER_ROLE_HINT if !hmd => Int(if device == ovr::LEFT {
            ovr::ROLE_LEFT
        } else {
            ovr::ROLE_RIGHT
        }),
        p if !hmd && (ovr::PROP_AXIS0_TYPE..=ovr::PROP_AXIS4_TYPE).contains(&p) => {
            Int(match p - ovr::PROP_AXIS0_TYPE {
                0 => ovr::AXIS_TRACKPAD,
                1 => ovr::AXIS_TRIGGER,
                _ => ovr::AXIS_NONE,
            })
        }
        _ => return Err(ovr::PROP_UNKNOWN),
    })
}

fn set_error(error: *mut i32, e: i32) {
    if !error.is_null() {
        // SAFETY: the game's out pointer.
        unsafe { *error = e };
    }
}

fn logged_unknown(device: u32, prop: i32) {
    static SEEN: runtime::Locked<[i32; 32]> = runtime::Locked::new([0; 32]);
    let new = SEEN.with(|seen| {
        if seen.contains(&prop) {
            return false;
        }
        if let Some(free) = seen.iter_mut().find(|p| **p == 0) {
            *free = prop;
        }
        true
    });
    if new {
        log!("property {prop} of device {device} asked for (not provided)");
    }
}

pub unsafe extern "C" fn get_bool_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    error: *mut i32,
) -> bool {
    crate::log::seen!("IVRSystem::get_bool_tracked_device_property");
    match property(device, prop) {
        Ok(Value::Bool(v)) => {
            set_error(error, ovr::PROP_SUCCESS);
            v
        }
        Ok(_) => {
            set_error(error, ovr::PROP_WRONG_TYPE);
            false
        }
        Err(e) => {
            logged_unknown(device, prop);
            set_error(error, e);
            false
        }
    }
}

pub unsafe extern "C" fn get_float_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    error: *mut i32,
) -> f32 {
    crate::log::seen!("IVRSystem::get_float_tracked_device_property");
    match property(device, prop) {
        Ok(Value::Float(v)) => {
            set_error(error, ovr::PROP_SUCCESS);
            v
        }
        Ok(_) => {
            set_error(error, ovr::PROP_WRONG_TYPE);
            0.0
        }
        Err(e) => {
            logged_unknown(device, prop);
            set_error(error, e);
            0.0
        }
    }
}

pub unsafe extern "C" fn get_int32_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    error: *mut i32,
) -> i32 {
    crate::log::seen!("IVRSystem::get_int32_tracked_device_property");
    match property(device, prop) {
        Ok(Value::Int(v)) => {
            set_error(error, ovr::PROP_SUCCESS);
            v
        }
        Ok(_) => {
            set_error(error, ovr::PROP_WRONG_TYPE);
            0
        }
        Err(e) => {
            logged_unknown(device, prop);
            set_error(error, e);
            0
        }
    }
}

pub unsafe extern "C" fn get_uint64_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    error: *mut i32,
) -> u64 {
    crate::log::seen!("IVRSystem::get_uint64_tracked_device_property");
    match property(device, prop) {
        Ok(Value::U64(v)) => {
            set_error(error, ovr::PROP_SUCCESS);
            v
        }
        Ok(_) => {
            set_error(error, ovr::PROP_WRONG_TYPE);
            0
        }
        Err(e) => {
            logged_unknown(device, prop);
            set_error(error, e);
            0
        }
    }
}

pub unsafe extern "C" fn get_matrix34_tracked_device_property(
    _: This,
    out: *mut HmdMatrix34,
    device: u32,
    prop: i32,
    error: *mut i32,
) -> *mut HmdMatrix34 {
    crate::log::seen!("IVRSystem::get_matrix34_tracked_device_property");
    logged_unknown(device, prop);
    set_error(error, ovr::PROP_UNKNOWN);
    // SAFETY: the hidden return slot.
    unsafe { out.write(ovr::IDENTITY34) };
    out
}

/// Copies a NUL-terminated `value` into the game's buffer; the size it needs, with the NUL.
pub fn write_string(value: &[u8], out: *mut c_char, size: u32) -> (u32, bool) {
    let needed = value.len() as u32;
    if out.is_null() || size < needed {
        if !out.is_null() && size > 0 {
            // SAFETY: the buffer holds `size` bytes.
            unsafe { *out = 0 };
        }
        return (needed, false);
    }
    // SAFETY: the buffer holds at least `needed` bytes.
    unsafe { core::ptr::copy_nonoverlapping(value.as_ptr().cast(), out, value.len()) };
    (needed, true)
}

pub unsafe extern "C" fn get_string_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    out: *mut c_char,
    size: u32,
    error: *mut i32,
) -> u32 {
    crate::log::seen!("IVRSystem::get_string_tracked_device_property");
    match property(device, prop) {
        Ok(Value::Str(v)) => {
            let (needed, ok) = write_string(v, out, size);
            set_error(
                error,
                if ok {
                    ovr::PROP_SUCCESS
                } else {
                    ovr::PROP_BUFFER_TOO_SMALL
                },
            );
            needed
        }
        Ok(_) => {
            set_error(error, ovr::PROP_WRONG_TYPE);
            0
        }
        Err(e) => {
            logged_unknown(device, prop);
            write_string(b"\0", out, size);
            set_error(error, e);
            0
        }
    }
}

pub unsafe extern "C" fn get_prop_error_name_from_enum(_: This, _error: i32) -> *const c_char {
    crate::log::seen!("IVRSystem::get_prop_error_name_from_enum");
    c"TrackedProp_Error".as_ptr()
}

unsafe fn write_event(out: *mut c_void, size: u32, event: (u32, u32, u32)) {
    if out.is_null() || (size as usize) < core::mem::size_of::<ovr::EventHeader>() {
        return;
    }
    // SAFETY: the game's event struct holds `size` bytes.
    unsafe {
        core::ptr::write_bytes(out.cast::<u8>(), 0, size as usize);
        out.cast::<ovr::EventHeader>().write(ovr::EventHeader {
            event_type: event.0,
            device: event.1,
            age_seconds: 0.0,
            _pad: 0,
            button: event.2,
        });
    }
}

pub unsafe extern "C" fn poll_next_event(_: This, out: *mut c_void, size: u32) -> bool {
    crate::log::seen!("IVRSystem::poll_next_event");
    runtime::touch();
    match runtime::next_event() {
        Some(e) => {
            // SAFETY: the game's event struct.
            unsafe { write_event(out, size, e) };
            true
        }
        None => false,
    }
}

pub unsafe extern "C" fn poll_next_event_with_pose(
    _: This,
    universe: u32,
    out: *mut c_void,
    size: u32,
    pose: *mut TrackedDevicePose,
) -> bool {
    crate::log::seen!("IVRSystem::poll_next_event_with_pose");
    match runtime::next_event() {
        Some(e) => {
            // SAFETY: the game's event struct.
            unsafe { write_event(out, size, e) };
            if !pose.is_null() {
                let state = runtime::latest_state();
                let mut all = [ovr::INVALID_POSE; 3];
                runtime::fill_poses(&state, universe, all.as_mut_ptr(), 3);
                // SAFETY: the game's pose.
                unsafe { *pose = all[(e.1 as usize).min(2)] };
            }
            true
        }
        None => false,
    }
}

pub unsafe extern "C" fn get_event_type_name_from_enum(_: This, _kind: u32) -> *const c_char {
    crate::log::seen!("IVRSystem::get_event_type_name_from_enum");
    c"VREvent".as_ptr()
}

pub unsafe extern "C" fn get_hidden_area_mesh(
    _: This,
    out: *mut ovr::HiddenAreaMesh,
    _eye: i32,
    _kind: i32,
) -> *mut ovr::HiddenAreaMesh {
    crate::log::seen!("IVRSystem::get_hidden_area_mesh");
    // SAFETY: the hidden return slot.
    unsafe {
        out.write(ovr::HiddenAreaMesh {
            vertices: core::ptr::null(),
            triangle_count: 0,
        })
    };
    out
}

fn controller_state(device: u32, out: *mut ovr::ControllerState) -> bool {
    if !(ovr::LEFT..=ovr::RIGHT).contains(&device) || out.is_null() {
        return false;
    }
    let c = runtime::latest_state().controllers[(device - 1) as usize];
    // SAFETY: the game's struct.
    unsafe {
        out.write(ovr::ControllerState {
            packet_num: c.packet,
            pressed: c.pressed,
            touched: c.touched,
            axes: c.axes,
        });
    }
    c.connected != 0
}

pub unsafe extern "C" fn get_controller_state(
    _: This,
    device: u32,
    out: *mut ovr::ControllerState,
    _size: u32,
) -> bool {
    crate::log::seen!("IVRSystem::get_controller_state");
    controller_state(device, out)
}

pub unsafe extern "C" fn get_controller_state_with_pose(
    _: This,
    universe: u32,
    device: u32,
    out: *mut ovr::ControllerState,
    _size: u32,
    pose: *mut TrackedDevicePose,
) -> bool {
    crate::log::seen!("IVRSystem::get_controller_state_with_pose");
    let ok = controller_state(device, out);
    if !pose.is_null() {
        let state = runtime::latest_state();
        let mut all = [ovr::INVALID_POSE; 3];
        runtime::fill_poses(&state, universe, all.as_mut_ptr(), 3);
        // SAFETY: the game's pose.
        unsafe { *pose = all[(device as usize).min(2)] };
    }
    ok
}

pub unsafe extern "C" fn trigger_haptic_pulse(_: This, _device: u32, _axis: u32, _us: u16) {
    crate::log::seen!("IVRSystem::trigger_haptic_pulse");
}

pub unsafe extern "C" fn get_button_id_name_from_enum(_: This, _button: i32) -> *const c_char {
    crate::log::seen!("IVRSystem::get_button_id_name_from_enum");
    c"k_EButton".as_ptr()
}

pub unsafe extern "C" fn get_controller_axis_type_name_from_enum(
    _: This,
    _kind: i32,
) -> *const c_char {
    crate::log::seen!("IVRSystem::get_controller_axis_type_name_from_enum");
    c"k_eControllerAxis".as_ptr()
}

pub unsafe extern "C" fn capture_input_focus(_: This) -> bool {
    crate::log::seen!("IVRSystem::capture_input_focus");
    true
}

pub unsafe extern "C" fn release_input_focus(_: This) {
    crate::log::seen!("IVRSystem::release_input_focus");
}

pub unsafe extern "C" fn is_input_focus_captured_by_another_process(_: This) -> bool {
    crate::log::seen!("IVRSystem::is_input_focus_captured_by_another_process");
    crate::scene::dashboard()
}

pub unsafe extern "C" fn driver_debug_request(
    _: This,
    _device: u32,
    request: *const c_char,
    out: *mut c_char,
    size: u32,
) -> u32 {
    crate::log::seen!("IVRSystem::driver_debug_request");
    log!("driver debug request: {}", CStr(request));
    write_string(b"\0", out, size);
    0
}

pub unsafe extern "C" fn perform_firmware_update(_: This, _device: u32) -> i32 {
    crate::log::seen!("IVRSystem::perform_firmware_update");
    0
}

pub unsafe extern "C" fn acknowledge_quit_exiting(_: This) {
    crate::log::seen!("IVRSystem::acknowledge_quit_exiting");
    crate::scene::acknowledge_quit();
}

pub unsafe extern "C" fn acknowledge_quit_user_prompt(_: This) {
    crate::log::seen!("IVRSystem::acknowledge_quit_user_prompt");
    crate::scene::acknowledge_quit();
}

// Added in IVRSystem_019 and _020.

pub unsafe extern "C" fn get_array_tracked_device_property(
    _: This,
    device: u32,
    prop: i32,
    _kind: u32,
    _buffer: *mut c_void,
    _size: u32,
    error: *mut i32,
) -> u32 {
    logged_unknown(device, prop);
    set_error(error, ovr::PROP_UNKNOWN);
    0
}

pub unsafe extern "C" fn is_input_available(_: This) -> bool {
    crate::log::seen!("IVRSystem::is_input_available");
    !crate::scene::dashboard()
}

pub unsafe extern "C" fn is_steam_vr_drawing_controllers(_: This) -> bool {
    false
}

pub unsafe extern "C" fn should_application_pause(_: This) -> bool {
    crate::log::seen!("IVRSystem::should_application_pause");
    crate::scene::dashboard()
}

pub unsafe extern "C" fn should_application_reduce_rendering_work(_: This) -> bool {
    false
}

pub unsafe extern "C" fn get_app_container_file_paths(_: This, out: *mut c_char, size: u32) -> u32 {
    write_string(b"\0", out, size).0
}

pub unsafe extern "C" fn get_runtime_version(_: This) -> *const c_char {
    c"1.7.15".as_ptr()
}
