//! OpenVR 1.0.10's types as the game sees them on 64-bit Windows (default 8-byte packing, which is
//! `repr(C)`'s). Ported from Valve's `openvr.h` (BSD-3-Clause); see THIRD-PARTY.md.
//!
//! Interfaces are C++ classes: an object whose first word points at a table of functions. On x64
//! Windows a member function takes `this` first, like any other argument; one that returns a
//! struct by value takes a hidden pointer to the result right after `this` and returns it.

use core::ffi::c_void;

/// OpenVR's matrices and color as C structs (so a function table can return them by value),
/// read and written as their arrays.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HmdMatrix34(pub [[f32; 4]; 3]);
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HmdMatrix44(pub [[f32; 4]; 4]);
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HmdColor(pub [f32; 4]);

macro_rules! as_array {
    ($t:ty, $a:ty) => {
        impl core::ops::Deref for $t {
            type Target = $a;
            fn deref(&self) -> &$a {
                &self.0
            }
        }
        impl core::ops::DerefMut for $t {
            fn deref_mut(&mut self) -> &mut $a {
                &mut self.0
            }
        }
    };
}
as_array!(HmdMatrix34, [[f32; 4]; 3]);
as_array!(HmdMatrix44, [[f32; 4]; 4]);
pub type HmdVector3 = [f32; 3];

#[repr(C)]
#[derive(Clone, Copy)]
pub struct TrackedDevicePose {
    pub device_to_absolute: HmdMatrix34,
    pub velocity: HmdVector3,
    pub angular_velocity: HmdVector3,
    pub tracking_result: i32,
    pub pose_is_valid: bool,
    pub device_is_connected: bool,
}

pub const INVALID_POSE: TrackedDevicePose = TrackedDevicePose {
    device_to_absolute: IDENTITY34,
    velocity: [0.0; 3],
    angular_velocity: [0.0; 3],
    tracking_result: TRACKING_UNINITIALIZED,
    pose_is_valid: false,
    device_is_connected: false,
};

#[repr(C)]
pub struct ControllerState {
    pub packet_num: u32,
    pub pressed: u64,
    pub touched: u64,
    pub axes: [[f32; 2]; 5],
}

#[repr(C)]
pub struct Texture {
    pub handle: *mut c_void,
    pub kind: i32,
    pub color_space: i32,
}

#[repr(C)]
pub struct HiddenAreaMesh {
    pub vertices: *const c_void,
    pub triangle_count: u32,
}

#[repr(C)]
pub struct EventHeader {
    pub event_type: u32,
    pub device: u32,
    pub age_seconds: f32,
    pub _pad: u32,
    /// `data.controller.button` (the union starts 8-aligned at 16).
    pub button: u32,
}

pub const IDENTITY34: HmdMatrix34 = HmdMatrix34([
    [1.0, 0.0, 0.0, 0.0],
    [0.0, 1.0, 0.0, 0.0],
    [0.0, 0.0, 1.0, 0.0],
]);

// Enums (values from openvr.h 1.0.10).
pub const MAX_DEVICES: u32 = 16;
pub const DEVICE_INVALID: u32 = 0xFFFF_FFFF;
pub const HMD: u32 = 0;
pub const LEFT: u32 = 1;
pub const RIGHT: u32 = 2;

pub const CLASS_INVALID: i32 = 0;
pub const CLASS_HMD: i32 = 1;
pub const CLASS_CONTROLLER: i32 = 2;

pub const ROLE_INVALID: i32 = 0;
pub const ROLE_LEFT: i32 = 1;
pub const ROLE_RIGHT: i32 = 2;

pub const TRACKING_UNINITIALIZED: i32 = 1;
pub const TRACKING_OK: i32 = 200;

pub const UNIVERSE_SEATED: u32 = 0;

pub const INIT_NONE: i32 = 0;
pub const INIT_INTERFACE_NOT_FOUND: i32 = 105;
pub const INIT_HMD_NOT_FOUND: i32 = 108;

pub const PROP_SUCCESS: i32 = 0;
pub const PROP_WRONG_TYPE: i32 = 1;
pub const PROP_BUFFER_TOO_SMALL: i32 = 3;
pub const PROP_UNKNOWN: i32 = 4;
pub const PROP_INVALID_DEVICE: i32 = 5;

pub const COMPOSITOR_NONE: i32 = 0;
pub const COMPOSITOR_REQUEST_FAILED: i32 = 1;
pub const COMPOSITOR_INVALID_TEXTURE: i32 = 102;

pub const TEXTURE_DIRECTX: i32 = 0;
pub const TEXTURE_OPENGL: i32 = 1;
pub const SUBMIT_GL_RENDER_BUFFER: i32 = 0x02;

pub const EVENT_DEVICE_ACTIVATED: u32 = 100;
pub const EVENT_BUTTON_PRESS: u32 = 200;
pub const EVENT_BUTTON_UNPRESS: u32 = 201;
pub const EVENT_BUTTON_TOUCH: u32 = 202;
pub const EVENT_BUTTON_UNTOUCH: u32 = 203;

pub const AXIS_NONE: i32 = 0;
pub const AXIS_TRACKPAD: i32 = 1;
pub const AXIS_TRIGGER: i32 = 3;

// Properties.
pub const PROP_TRACKING_SYSTEM_NAME: i32 = 1000;
pub const PROP_MODEL_NUMBER: i32 = 1001;
pub const PROP_SERIAL_NUMBER: i32 = 1002;
pub const PROP_RENDER_MODEL_NAME: i32 = 1003;
pub const PROP_WILL_DRIFT_IN_YAW: i32 = 1004;
pub const PROP_MANUFACTURER_NAME: i32 = 1005;
pub const PROP_TRACKING_FIRMWARE_VERSION: i32 = 1006;
pub const PROP_HARDWARE_REVISION: i32 = 1007;
pub const PROP_DEVICE_IS_WIRELESS: i32 = 1010;
pub const PROP_DEVICE_IS_CHARGING: i32 = 1011;
pub const PROP_BATTERY_PERCENTAGE: i32 = 1012;
pub const PROP_CONTAINS_PROXIMITY_SENSOR: i32 = 1025;
pub const PROP_PROVIDES_BATTERY_STATUS: i32 = 1026;
pub const PROP_DEVICE_CAN_POWER_OFF: i32 = 1027;
pub const PROP_DEVICE_CLASS: i32 = 1029;
pub const PROP_HAS_CAMERA: i32 = 1030;
pub const PROP_DRIVER_VERSION: i32 = 1031;
pub const PROP_SECONDS_VSYNC_TO_PHOTONS: i32 = 2001;
pub const PROP_DISPLAY_FREQUENCY: i32 = 2002;
pub const PROP_USER_IPD: i32 = 2003;
pub const PROP_CURRENT_UNIVERSE_ID: i32 = 2004;
pub const PROP_IS_ON_DESKTOP: i32 = 2007;
pub const PROP_USER_HEAD_TO_EYE_DEPTH: i32 = 2026;
pub const PROP_SUPPORTED_BUTTONS: i32 = 3001;
pub const PROP_AXIS0_TYPE: i32 = 3002;
pub const PROP_AXIS4_TYPE: i32 = 3006;
pub const PROP_CONTROLLER_ROLE_HINT: i32 = 3007;

/// A pose from the bridge as OpenVR's 3×4 matrix, moved by `offset` (subtracted).
pub fn pose_matrix(p: &halliday_bridge::Pose, offset: [f32; 3]) -> HmdMatrix34 {
    let [x, y, z, w] = p.orientation;
    let t = [
        p.position[0] - offset[0],
        p.position[1] - offset[1],
        p.position[2] - offset[2],
    ];
    HmdMatrix34([
        [
            1.0 - 2.0 * (y * y + z * z),
            2.0 * (x * y - z * w),
            2.0 * (x * z + y * w),
            t[0],
        ],
        [
            2.0 * (x * y + z * w),
            1.0 - 2.0 * (x * x + z * z),
            2.0 * (y * z - x * w),
            t[1],
        ],
        [
            2.0 * (x * z - y * w),
            2.0 * (y * z + x * w),
            1.0 - 2.0 * (x * x + y * y),
            t[2],
        ],
    ])
}

pub fn device_pose(
    p: &halliday_bridge::Pose,
    connected: bool,
    offset: [f32; 3],
) -> TrackedDevicePose {
    if !connected {
        return INVALID_POSE;
    }
    TrackedDevicePose {
        device_to_absolute: pose_matrix(p, offset),
        velocity: p.velocity,
        angular_velocity: p.angular_velocity,
        tracking_result: if p.valid != 0 {
            TRACKING_OK
        } else {
            TRACKING_UNINITIALIZED
        },
        pose_is_valid: p.valid != 0,
        device_is_connected: true,
    }
}
