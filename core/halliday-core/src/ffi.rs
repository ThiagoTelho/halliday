//! C ABI used by the Swift app. Keep in step with `include/halliday_core.h`.
//!
//! Rules: no panics cross this boundary (a panic in an `extern "C"` function aborts), pointers
//! from C are checked for null, and every handle returned by `*_open*` is released with
//! `halliday_session_close`.

use std::ffi::{CStr, c_char};

use crate::psvr2::distortion::{self, DistortionMesh, Eye};
use crate::session::Session;

/// NUL-terminated copy of [`crate::VERSION`], valid for the life of the program.
static VERSION_C: &str = concat!(env!("CARGO_PKG_VERSION"), "\0");

/// Returns the core library version as a static NUL-terminated UTF-8 string.
/// The caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_core_version() -> *const c_char {
    VERSION_C.as_ptr().cast()
}

/// Returns 1 if the USB vendor/product id pair is a PS VR2 headset, otherwise 0.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_is_psvr2_headset(vendor_id: u16, product_id: u16) -> i32 {
    i32::from(crate::psvr2::is_headset(vendor_id, product_id))
}

/// Host monotonic clock in ns: the clock of `CACurrentMediaTime()` and display-link timestamps.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_host_time_ns() -> i64 {
    crate::time::host_time_ns()
}

// --- Tracking cameras ---------------------------------------------------------------------------

/// One bright spot in a camera's picture. Keep in step with the header.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayCameraSpot {
    /// Pixels from the picture's top-left corner, finer than a pixel.
    pub x: f32,
    pub y: f32,
    pub area: u32,
    pub peak: u32,
}

/// What a view's newest frame was. Keep in step with the header.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayCameraView {
    /// When the cameras exposed, host clock (0 until the headset's clock is known).
    pub exposure_host_ns: i64,
    pub counter: u32,
    /// Frames this view has had since the cameras were switched on.
    pub frames: u32,
    pub width: u32,
    pub height: u32,
    /// Spots found (may be more than were written).
    pub spots: u32,
    /// `halliday_session_camera_image` only: 0 8-bit pixels; 1 BC4 blocks (camera mode 0x10:
    /// the two bottom fisheyes one above the other, `width` × `height` pixels).
    pub format: u32,
}

/// Switches the headset's tracking cameras to `mode` (0 off, 1 the two bottom cameras with a
/// normal exposure, 4 controller tracking); a pixel at or above `threshold` is part of a spot.
///
/// # Safety
/// `session` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_set_camera(
    session: *const HallidaySession,
    mode: u32,
    threshold: u8,
) {
    if session.is_null() {
        return;
    }
    // SAFETY: checked for null.
    unsafe { &*session }.0.set_camera(mode, threshold);
}

/// Passthrough: whether the bottom cameras' newest picture is kept for
/// `halliday_session_camera_image` (in memory only; off drops it).
///
/// # Safety
/// `session` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_set_camera_keep(
    session: *const HallidaySession,
    on: bool,
) {
    if session.is_null() {
        return;
    }
    // SAFETY: checked for null.
    unsafe { &*session }.0.set_camera_keep(on);
}

/// Copies the bottom cameras' newest picture (left then right, side by side, 8 bits a pixel)
/// into `out` if there is one other than the one whose counter `info` holds, and it fits in
/// `capacity` bytes; `info` then says which it is (its spots are not counted here).
///
/// # Safety
/// `session` must be null or a live handle; `info` null or readable and writable; `out` null
/// or writable for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_camera_image(
    session: *const HallidaySession,
    info: *mut HallidayCameraView,
    out: *mut u8,
    capacity: u32,
) -> bool {
    if session.is_null() || info.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: checked for null; the caller guarantees `capacity` writable bytes.
    let (have, buffer) = unsafe {
        (
            (*info).counter,
            std::slice::from_raw_parts_mut(out, capacity as usize),
        )
    };
    // SAFETY: checked for null.
    let Some(image) = unsafe { &*session }.0.camera_image(have, buffer) else {
        return false;
    };
    // SAFETY: checked for null.
    unsafe {
        info.write(HallidayCameraView {
            exposure_host_ns: image.exposure_host_ns,
            counter: image.counter,
            frames: 0,
            width: image.width,
            height: image.height,
            spots: 0,
            format: u32::from(image.bc4),
        });
    }
    true
}

/// The newest bright spots of a camera view (0..4), brightest first: writes up to `max` of them
/// and the view's frame. False for a view that has had no frame.
///
/// # Safety
/// `session` must be null or a live handle; `info` null or writable; `out` null or writable for
/// `max` spots.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_camera_view(
    session: *const HallidaySession,
    view: u32,
    info: *mut HallidayCameraView,
    out: *mut HallidayCameraSpot,
    max: u32,
) -> bool {
    if session.is_null() || info.is_null() {
        return false;
    }
    // SAFETY: checked for null.
    let Some(v) = unsafe { &*session }.0.camera_view(view as usize) else {
        return false;
    };
    // SAFETY: checked for null; the caller guarantees `max` writable spots.
    unsafe {
        info.write(HallidayCameraView {
            exposure_host_ns: v.exposure_host_ns,
            counter: v.counter,
            frames: v.frames,
            width: u32::from(v.width),
            height: u32::from(v.height),
            spots: v.spots.len() as u32,
            format: 0,
        });
        if !out.is_null() {
            for (i, b) in v.spots.iter().take(max as usize).enumerate() {
                out.add(i).write(HallidayCameraSpot {
                    x: b.x,
                    y: b.y,
                    area: b.area,
                    peak: u32::from(b.peak),
                });
            }
        }
    }
    true
}

// --- A controller's place, from the cameras -----------------------------------------------------

/// Opaque handle to one controller's tracker (`tracking/hands.rs`), with the PS VR2's bottom
/// cameras' numbers. Used from one thread.
pub struct HallidayHand(std::sync::Mutex<crate::tracking::hands::HandTracker>);

/// A controller found in one exposure. Keep in step with the header.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayHandFix {
    /// The controller's IMU in the head's frame at the exposure (x right, y up, z back), meters.
    pub position: [f32; 3],
    /// What the cameras add to the IMU's heading, radians about up.
    pub heading: f32,
    /// LEDs matched to spots, counting each picture, and how far off they are, pixels.
    pub sightings: u32,
    pub rms: f32,
    /// The lean the cameras see between the IMU's "up" and the head tracking's: turns about the
    /// tracking space's x and z, radians. The controller is turned lean · heading · IMU
    /// (`Fix::correction`).
    pub tilt: [f32; 2],
}

/// A tracker for the left or the right controller. Release with `halliday_hand_close`.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_hand_open(left: bool) -> *mut HallidayHand {
    let hand = if left {
        crate::sense::Hand::Left
    } else {
        crate::sense::Hand::Right
    };
    Box::into_raw(Box::new(HallidayHand(std::sync::Mutex::new(
        crate::tracking::hands::HandTracker::new(hand),
    ))))
}

/// # Safety
/// `hand` must be null or a handle from `halliday_hand_open`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_close(hand: *mut HallidayHand) {
    if !hand.is_null() {
        // SAFETY: the caller hands back a handle from `halliday_hand_open`.
        drop(unsafe { Box::from_raw(hand) });
    }
}

/// Whether the bottom pair's spots handed to `halliday_hand_update` are from the raw fisheyes
/// (camera mode 0x10, in their own pictures' pixels) or the rectified pair (modes 1 and 3).
///
/// # Safety
/// `hand` must be null or a live handle from `halliday_hand_open`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_set_fisheyes(hand: *const HallidayHand, on: bool) {
    if hand.is_null() {
        return;
    }
    // SAFETY: checked for null.
    let tracker = unsafe { &*hand };
    tracker
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .set_bottom_fisheyes(on);
}

/// A measured per-headset raw-camera alignment, not an offset of either hand.
/// Right camera-local rotation vector in radians (x right, y down, z forward).
/// Zero restores the generic model. Invalid values leave the tracker unchanged.
///
/// # Safety
/// `hand` must be null or a live handle. `rotation` must be null or readable for
/// three floats. The calibration belongs to the connected headset's identity.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_set_fisheye_alignment(
    hand: *const HallidayHand,
    rotation: *const f32,
) -> bool {
    if hand.is_null() || rotation.is_null() {
        return false;
    }
    // SAFETY: null checked; the caller guarantees three readable floats.
    let rotation = unsafe { [*rotation, *rotation.add(1), *rotation.add(2)] };
    // SAFETY: null checked; the caller supplies a live tracker.
    unsafe { &*hand }
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .set_bottom_fisheye_alignment(rotation.map(f64::from))
}

/// One exposure: the head's and the controller's orientations in the tracking space at that
/// moment (x, y, z, w), the bottom pair's two pictures' spots (views 0 and 1) and, in camera
/// mode 3, the top cameras' (views 2 and 3; null or none when that picture was missed).
/// True, with `out` written, when the controller is found.
///
/// # Safety
/// `hand` must be null or a live handle; the pointers must be null or valid for what they
/// name, `left` and `right` for that many spots.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_hand_update(
    hand: *const HallidayHand,
    head: *const f32,
    controller: *const f32,
    left: *const HallidayCameraSpot,
    left_count: u32,
    right: *const HallidayCameraSpot,
    right_count: u32,
    top_left: *const HallidayCameraSpot,
    top_left_count: u32,
    top_right: *const HallidayCameraSpot,
    top_right_count: u32,
    out: *mut HallidayHandFix,
) -> bool {
    use crate::tracking::hands::Spot;
    use crate::tracking::stereo::{PSVR2_BOTTOM, PSVR2_BOTTOM_PLACE};
    if hand.is_null() || head.is_null() || controller.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: checked for null; the caller guarantees four floats each.
    let quat = |p: *const f32| unsafe {
        crate::math::Quat {
            x: *p,
            y: *p.add(1),
            z: *p.add(2),
            w: *p.add(3),
        }
        .normalized()
    };
    // SAFETY: the caller guarantees `count` spots behind a non-null pointer.
    let spots = |p: *const HallidayCameraSpot, count: u32| -> Vec<Spot> {
        if p.is_null() {
            return Vec::new();
        }
        unsafe { std::slice::from_raw_parts(p, count as usize) }
            .iter()
            .map(|s| Spot {
                x: s.x,
                y: s.y,
                area: s.area,
            })
            .collect()
    };
    let pair = PSVR2_BOTTOM;
    // SAFETY: checked for null.
    let mut tracker = unsafe { &*hand }
        .0
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let top = [
        spots(top_left, top_left_count),
        spots(top_right, top_right_count),
    ];
    let cameras = crate::tracking::stereo::PSVR2_TOP;
    let Some(fix) = tracker.update_with(
        &pair,
        &[(cameras[0], &top[0]), (cameras[1], &top[1])],
        &pair.camera_from_world(quat(head)),
        quat(controller),
        &spots(left, left_count),
        &spots(right, right_count),
    ) else {
        return false;
    };
    let at = pair.in_head(PSVR2_BOTTOM_PLACE, fix.position.map(f64::from));
    // SAFETY: checked for null.
    unsafe {
        out.write(HallidayHandFix {
            position: at.map(|v| v as f32),
            heading: fix.heading,
            sightings: fix.sightings,
            rms: fix.rms,
            tilt: fix.tilt,
        });
    }
    true
}

// --- Sense controllers --------------------------------------------------------------------------

/// Opaque handle to one Sense controller's state. The app reads the HID reports and feeds them
/// in from its own thread; the state is read from another.
pub struct HallidaySense(std::sync::Mutex<crate::sense::Controller>);

/// A controller's newest inputs and orientation. Keep in step with the header.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidaySenseState {
    /// x, y, z, w: the controller's axes (x right, y up, −z forward) in the tracking space.
    pub orientation: [f32; 4],
    /// rad/s, in the controller's own axes.
    pub angular_velocity: [f32; 3],
    pub stick: [f32; 2],
    pub trigger: f32,
    pub trigger_proximity: f32,
    pub grip_proximity: f32,
    pub buttons: u32,
    pub reports: u32,
    pub missed: u32,
    /// Seconds since the newest report was taken.
    pub age: f32,
    /// The controller's clock at its newest report, in thirds of a microsecond.
    pub device_ticks: u32,
    pub battery_percent: u8,
    pub charging: u8,
    /// 1 once the orientation has found "up" (a report at rest).
    pub settled: u8,
}

/// A handle for the controller with this USB/Bluetooth product id; null if it isn't a Sense
/// controller. Release with `halliday_sense_close`.
#[unsafe(no_mangle)]
pub extern "C" fn halliday_sense_open(product_id: u16) -> *mut HallidaySense {
    match crate::sense::Hand::from_product_id(product_id) {
        Some(hand) => Box::into_raw(Box::new(HallidaySense(std::sync::Mutex::new(
            crate::sense::Controller::new(hand),
        )))),
        None => std::ptr::null_mut(),
    }
}

/// # Safety
/// `sense` must be null or a handle from `halliday_sense_open`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_close(sense: *mut HallidaySense) {
    if !sense.is_null() {
        // SAFETY: the caller hands back a handle from `halliday_sense_open`.
        drop(unsafe { Box::from_raw(sense) });
    }
}

/// The two halves of the IMU calibration (feature report 0x05, read twice), each `len` bytes,
/// report id first. False, and the defaults stay, if they aren't a valid pair.
///
/// # Safety
/// `sense` must be null or a live handle; `first` and `second` null or readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_calibrate(
    sense: *const HallidaySense,
    first: *const u8,
    second: *const u8,
    len: usize,
) -> bool {
    if sense.is_null() || first.is_null() || second.is_null() {
        return false;
    }
    // SAFETY: checked for null; the caller guarantees the lengths.
    let (sense, first, second) = unsafe {
        (
            &*sense,
            std::slice::from_raw_parts(first, len),
            std::slice::from_raw_parts(second, len),
        )
    };
    let Some(calibration) = crate::sense::Calibration::parse(first, second) else {
        return false;
    };
    if let Ok(mut c) = sense.0.lock() {
        c.set_calibration(calibration);
    }
    true
}

/// One HID input report, report id first. False if it isn't one, or fails its checksum.
///
/// # Safety
/// `sense` must be null or a live handle; `bytes` null or readable for `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_report(
    sense: *const HallidaySense,
    bytes: *const u8,
    len: usize,
) -> bool {
    if sense.is_null() || bytes.is_null() {
        return false;
    }
    // SAFETY: checked for null; the caller guarantees the length.
    let (sense, bytes) = unsafe { (&*sense, std::slice::from_raw_parts(bytes, len)) };
    match sense.0.lock() {
        Ok(mut c) => c.ingest(bytes).is_ok(),
        Err(_) => false,
    }
}

/// The newest state. False until a report has been taken.
///
/// # Safety
/// `sense` must be null or a live handle; `out` null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_state(
    sense: *const HallidaySense,
    out: *mut HallidaySenseState,
) -> bool {
    if sense.is_null() || out.is_null() {
        return false;
    }
    // SAFETY: checked for null.
    let sense = unsafe { &*sense };
    let Ok(c) = sense.0.lock() else {
        return false;
    };
    let Some(r) = c.newest() else {
        return false;
    };
    let q = c.orientation();
    let (reports, missed) = c.counts();
    let state = HallidaySenseState {
        orientation: [q.x, q.y, q.z, q.w],
        angular_velocity: c.angular_velocity(),
        stick: r.stick,
        trigger: r.trigger,
        trigger_proximity: r.trigger_proximity,
        grip_proximity: r.grip_proximity,
        buttons: r.buttons,
        reports,
        missed,
        age: c.age(),
        device_ticks: r.device_ticks,
        battery_percent: r.battery_percent,
        charging: u8::from(r.charging),
        settled: u8::from(c.is_settled()),
    };
    // SAFETY: checked for null; the caller guarantees it is writable.
    unsafe { out.write(state) };
    true
}

/// Writes the 48-byte feature report (id 0x08 first) that asks a controller for about 133
/// reports a second where it sends 60 by itself. The app sends it once after connecting.
///
/// # Safety
/// `out` must be null or writable for 48 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_polling_report(out: *mut u8) {
    if out.is_null() {
        return;
    }
    let report = crate::sense::polling_rate_report();
    // SAFETY: checked for null; the caller guarantees 48 writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(report.as_ptr(), out, report.len()) };
}

/// Writes the 78-byte Bluetooth output report (id 0x31 first) that sets a controller's tracking
/// LEDs: `phase` 1 blinks (a pulse of `period_id` × 50 µs every `cycle_length` thirds of a
/// nanosecond, its middle at `cycle_position` on the controller's clock, thirds of a
/// microsecond), 5 is off. `sequence` and `counter` go up by one per report sent, `led_sequence`
/// when the timing changes.
///
/// # Safety
/// `out` must be null or writable for 78 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_led_report(
    sequence: u8,
    counter: u8,
    phase: u8,
    led_sequence: u8,
    period_id: u8,
    cycle_position: u32,
    cycle_length: u32,
    host_us: u32,
    out: *mut u8,
) {
    if out.is_null() {
        return;
    }
    let blink = crate::sense::LedBlink {
        phase,
        sequence: led_sequence,
        period_id,
        cycle_position,
        cycle_length,
    };
    let report = crate::sense::led_report(sequence, counter, blink, host_us);
    // SAFETY: checked for null; the caller guarantees 78 writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(report.as_ptr(), out, report.len()) };
}

/// Monado-documented Bluetooth output report. No USB layout is inferred here.
/// # Safety
/// `out` is null or writable for 78 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_vibration_report(
    sequence: u8,
    counter: u8,
    amplitude: f32,
    frequency_hz: f32,
    host_us: u32,
    out: *mut u8,
) {
    if out.is_null() {
        return;
    }
    let report =
        crate::sense::vibration_report(sequence, counter, amplitude, frequency_hz, host_us);
    unsafe {
        std::ptr::copy_nonoverlapping(report.as_ptr(), out, report.len());
    }
}

/// Vibration output retaining the current connection's LED settings and latch.
/// A null programmed report means no LED configuration exists yet. False for
/// null output or a retained packet with an invalid Bluetooth header/checksum.
/// # Safety
/// `programmed` is null or readable for 78 bytes; `out` is null or writable for
/// 78 bytes. The input is copied before output is written, so they may alias.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_vibration_report_with_led(
    sequence: u8,
    counter: u8,
    amplitude: f32,
    frequency_hz: f32,
    host_us: u32,
    programmed: *const u8,
    out: *mut u8,
) -> bool {
    if out.is_null() {
        return false;
    }
    let programmed = if programmed.is_null() {
        None
    } else {
        // SAFETY: the caller provides a complete readable packet; u8 array alignment is 1.
        Some(unsafe { std::ptr::read(programmed.cast::<[u8; crate::sense::OUTPUT_REPORT_LEN]>()) })
    };
    let Some(report) = crate::sense::vibration_report_retaining_led(
        sequence,
        counter,
        amplitude,
        frequency_hz,
        host_us,
        programmed.as_ref(),
    ) else {
        return false;
    };
    // SAFETY: output is checked and the complete input was copied above.
    unsafe { std::ptr::copy_nonoverlapping(report.as_ptr(), out, report.len()) };
    true
}

/// Makes the direction the controller points now the heading `yaw` (radians about y, 0 forward).
///
/// # Safety
/// `sense` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_recenter(sense: *const HallidaySense, yaw: f32) {
    if sense.is_null() {
        return;
    }
    // SAFETY: checked for null.
    if let Ok(mut c) = unsafe { &*sense }.0.lock() {
        c.recenter(yaw);
    }
}

/// What the cameras add to the controller's own heading (radians about y): with it the
/// accelerometer is put in the room's frame for `halliday_sense_place`.
///
/// # Safety
/// `sense` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_room_yaw(sense: *const HallidaySense, yaw: f32) {
    if sense.is_null() {
        return;
    }
    // SAFETY: checked for null.
    if let Ok(mut c) = unsafe { &*sense }.0.lock() {
        c.set_room_yaw(yaw);
    }
}

/// The cameras saw the controller at `position` (x, y, z in meters, the room's frame) at host
/// time `host_ns`. A null `position` forgets where it was (the room's frame changed).
///
/// # Safety
/// `sense` must be null or a live handle; `position` null or three floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_place_fix(
    sense: *const HallidaySense,
    host_ns: i64,
    position: *const f32,
) {
    if sense.is_null() {
        return;
    }
    // SAFETY: checked for null.
    if let Ok(mut c) = unsafe { &*sense }.0.lock() {
        if position.is_null() {
            c.reset_place();
        } else {
            // SAFETY: three floats, by the contract.
            let p = unsafe { std::slice::from_raw_parts(position, 3) };
            c.place_fix(host_ns, [p[0], p[1], p[2]]);
        }
    }
}

/// Where the controller is at host time `host_ns` (the cameras' fixes carried on by its
/// accelerometer), and its velocity: three floats each. False when it wasn't seen lately.
///
/// # Safety
/// `sense` must be null or a live handle; `position` and `velocity` three floats each.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_sense_place(
    sense: *const HallidaySense,
    host_ns: i64,
    position: *mut f32,
    velocity: *mut f32,
) -> bool {
    if sense.is_null() || position.is_null() || velocity.is_null() {
        return false;
    }
    // SAFETY: checked for null.
    let Ok(c) = unsafe { &*sense }.0.lock() else {
        return false;
    };
    let Some((p, v)) = c.place(host_ns) else {
        return false;
    };
    // SAFETY: three floats each, by the contract.
    unsafe {
        std::slice::from_raw_parts_mut(position, 3).copy_from_slice(&p);
        std::slice::from_raw_parts_mut(velocity, 3).copy_from_slice(&v);
    }
    true
}

// --- Sessions -----------------------------------------------------------------------------------

/// Opaque session handle.
pub struct HallidaySession(Session);

/// Starts a USB session; it connects and reconnects in the background. Never returns null.
#[cfg(feature = "usb")]
#[unsafe(no_mangle)]
pub extern "C" fn halliday_session_open_usb() -> *mut HallidaySession {
    Box::into_raw(Box::new(HallidaySession(Session::usb())))
}

/// Starts replaying a recording (UTF-8 path). Returns null if the file can't be read.
///
/// # Safety
/// `path` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_open_replay(
    path: *const c_char,
    looping: bool,
) -> *mut HallidaySession {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: caller guarantees a valid NUL-terminated string.
    let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str() else {
        return std::ptr::null_mut();
    };
    match Session::replay(path, looping) {
        Ok(s) => Box::into_raw(Box::new(HallidaySession(s))),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Stops the session's threads and frees it. Null is ignored.
///
/// # Safety
/// `session` must be null or a handle from `halliday_session_open_*`, not used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_close(session: *mut HallidaySession) {
    if !session.is_null() {
        // SAFETY: the handle came from Box::into_raw and is closed only once.
        drop(unsafe { Box::from_raw(session) });
    }
}

/// Borrow a session from a C pointer.
///
/// # Safety
/// `session` must be null or a live handle.
unsafe fn session<'a>(session: *const HallidaySession) -> Option<&'a Session> {
    // SAFETY: caller guarantees the pointer is null or live.
    unsafe { session.as_ref() }.map(|s| &s.0)
}

/// Link state, see `HallidayLinkState` in the header. Null session: searching (0).
///
/// # Safety
/// `session` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_link_state(session: *const HallidaySession) -> i32 {
    // SAFETY: forwarded from the caller.
    unsafe { self::session(session) }.map_or(0, |s| s.link_state() as i32)
}

/// Predicted head pose, laid out for C.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayHeadPose {
    /// Meters, tracking space (x right, y up, −z forward).
    pub position: [f32; 3],
    /// Unit quaternion as x, y, z, w (the order of `simd_quatf`'s vector).
    pub orientation: [f32; 4],
    /// rad/s in the head's frame.
    pub angular_velocity: [f32; 3],
    /// Age of the SLAM pose the prediction started from, ns.
    pub slam_age_ns: i64,
    /// 1 when the pose came from gyro prediction, 0 when it is the plain SLAM pose.
    pub predicted: u8,
}

/// Additive motion API; the legacy 56-byte pose and getter remain unchanged.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayHeadPoseMotion {
    pub pose: HallidayHeadPose,
    pub linear_velocity: [f32; 3],
    pub motion_flags: u32,
}

fn head_pose_for_c(h: crate::tracking::HeadPose) -> HallidayHeadPose {
    let q = h.pose.orientation;
    HallidayHeadPose {
        position: h.pose.position,
        orientation: [q.x, q.y, q.z, q.w],
        angular_velocity: h.angular_velocity,
        slam_age_ns: h.slam_age_ns,
        predicted: u8::from(h.predicted),
    }
}

/// Pose and measured velocity from one tracker lock and requested timestamp.
/// # Safety
/// `session` is null/live and `out` is null or a writable complete motion DTO.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_predict_motion(
    session: *const HallidaySession,
    at_host_ns: i64,
    out: *mut HallidayHeadPoseMotion,
) -> bool {
    let (Some(s), Some(out)) = (unsafe { self::session(session) }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(h) = s.predict(at_host_ns) else {
        return false;
    };
    *out = HallidayHeadPoseMotion {
        pose: head_pose_for_c(h),
        linear_velocity: h.linear_velocity,
        motion_flags: h.motion_flags,
    };
    true
}

/// Fills `out` with the head pose predicted for `at_host_ns`. Returns false (and leaves `out`
/// untouched) when there is no live tracking.
///
/// # Safety
/// `session` must be null or a live handle; `out` must be null or point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_predict(
    session: *const HallidaySession,
    at_host_ns: i64,
    out: *mut HallidayHeadPose,
) -> bool {
    // SAFETY: forwarded from the caller.
    let (Some(s), Some(out)) = (unsafe { self::session(session) }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(h) = s.predict(at_host_ns) else {
        return false;
    };
    *out = head_pose_for_c(h);
    true
}

/// Headset state from the status stream.
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayHeadsetStatus {
    pub worn: u8,
    pub function_button: u8,
    pub ipd_mm: u8,
}

/// # Safety
/// `session` must be null or a live handle; `out` must be null or point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_status(
    session: *const HallidaySession,
    out: *mut HallidayHeadsetStatus,
) -> bool {
    // SAFETY: forwarded from the caller.
    let (Some(s), Some(out)) = (unsafe { self::session(session) }, unsafe { out.as_mut() }) else {
        return false;
    };
    let st = s.status();
    *out = HallidayHeadsetStatus {
        worn: u8::from(st.worn),
        function_button: u8::from(st.function_button),
        ipd_mm: st.ipd_mm,
    };
    true
}

/// Copies the connected headset's cached PCB identity, including a trailing NUL.
/// Returns false and leaves `out` untouched for an unknown device or a short buffer.
/// This does not issue a USB request.
/// # Safety
/// `session` is null/live; `out` is null or writable for `capacity` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_headset_identity(
    session: *const HallidaySession,
    out: *mut u8,
    capacity: u32,
) -> bool {
    let Some(id) = (unsafe { self::session(session) }).and_then(|s| s.headset_identity()) else {
        return false;
    };
    // SAFETY: the caller provides the writable destination, or null.
    unsafe { copy_headset_identity(&id, out, capacity) }
}

unsafe fn copy_headset_identity(id: &str, out: *mut u8, capacity: u32) -> bool {
    if out.is_null() || id.len() >= capacity as usize {
        return false;
    }
    // SAFETY: the length check above reserves the terminator as well.
    unsafe {
        std::ptr::copy_nonoverlapping(id.as_ptr(), out, id.len());
        *out.add(id.len()) = 0;
    }
    true
}

/// Recenters: `full` false keeps the horizon (yaw only), true also resets pitch and roll.
///
/// # Safety
/// `session` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_recenter(session: *const HallidaySession, full: bool) {
    // SAFETY: forwarded from the caller.
    if let Some(s) = unsafe { self::session(session) } {
        s.recenter(full);
    }
}

/// Panel brightness 0..1. Returns false without a connected USB headset.
///
/// # Safety
/// `session` must be null or a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_set_brightness(
    session: *const HallidaySession,
    brightness: f32,
) -> bool {
    // SAFETY: forwarded from the caller.
    unsafe { self::session(session) }.is_some_and(|s| s.set_brightness(brightness))
}

/// Writes the headset's 8 lens calibration parameters (the fallback until one was read).
///
/// # Safety
/// `session` must be null or a live handle; `out` must be null or point to 8 writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_session_calibration(
    session: *const HallidaySession,
    out: *mut f32,
) -> bool {
    // SAFETY: forwarded from the caller.
    let Some(s) = (unsafe { self::session(session) }) else {
        return false;
    };
    if out.is_null() {
        return false;
    }
    let cal = s.calibration();
    // SAFETY: caller guarantees 8 writable floats.
    unsafe { std::ptr::copy_nonoverlapping(cal.as_ptr(), out, 8) };
    true
}

/// Writes a synthetic recording (a head looking left and right) of `seconds` to `path`.
/// Returns false if the path is invalid or the file can't be written.
///
/// # Safety
/// `path` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_write_synthetic_recording(
    path: *const c_char,
    seconds: f32,
) -> bool {
    if path.is_null() || !(seconds > 0.0 && seconds <= 3600.0) {
        return false;
    }
    // SAFETY: caller guarantees a valid NUL-terminated string.
    let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str() else {
        return false;
    };
    let motion = crate::synthetic::LookAround {
        seconds,
        ..Default::default()
    };
    std::fs::write(path, motion.record()).is_ok()
}

// --- Video formats ---

/// A VR video format guess (see `video.rs`).
#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct HallidayVideoFormat {
    /// 0 equirect 360, 1 equirect 180, 2 fisheye, 3 flat screen.
    pub projection: i32,
    /// 0 mono, 1 side by side, 2 top/bottom.
    pub stereo: i32,
    pub fisheye_fov_deg: f32,
    /// Picture aspect of one eye on a flat screen (width / height).
    pub flat_aspect: f32,
}

/// Guesses a video's format from its file name, then fills in what the name left open from the
/// track: `projection_kind` / `view_packing` (container metadata strings, may be null), whether it
/// is MV-HEVC multiview, and the frame size (0 × 0 if unknown).
///
/// # Safety
/// `file_name` must be a valid NUL-terminated string; the other strings may be null or valid; `out`
/// must point to writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_video_detect(
    file_name: *const c_char,
    projection_kind: *const c_char,
    view_packing: *const c_char,
    multiview: bool,
    width: u32,
    height: u32,
    out: *mut HallidayVideoFormat,
) -> bool {
    // SAFETY: caller guarantees valid or null pointers.
    let (Some(out), false) = (unsafe { out.as_mut() }, file_name.is_null()) else {
        return false;
    };
    // SAFETY: caller guarantees a valid NUL-terminated string.
    let name = unsafe { CStr::from_ptr(file_name) }.to_string_lossy();
    let opt = |p: *const c_char| -> Option<String> {
        // SAFETY: caller guarantees null or a valid NUL-terminated string.
        (!p.is_null()).then(|| unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
    };
    let (kind, packing) = (opt(projection_kind), opt(view_packing));
    let mut d = crate::video::detect(&name);
    if width > 0 && height > 0 || kind.is_some() || packing.is_some() || multiview {
        d.refine(&crate::video::TrackInfo {
            projection_kind: kind.as_deref(),
            view_packing: packing.as_deref(),
            multiview,
            width,
            height,
        });
    }
    let f = d.format;
    *out = HallidayVideoFormat {
        projection: f.projection as i32,
        stereo: f.stereo as i32,
        fisheye_fov_deg: f.fisheye_fov_deg,
        flat_aspect: crate::video::flat_aspect(width, height, f.stereo),
    };
    true
}

// --- Optics -------------------------------------------------------------------------------------

fn eye(e: i32) -> Eye {
    if e == 0 { Eye::Left } else { Eye::Right }
}

/// Field of view of an eye (0 left, 1 right) in radians: left, right, up, down.
///
/// # Safety
/// `out` must be null or point to 4 writable floats.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_eye_fov(eye_index: i32, out: *mut f32) {
    if out.is_null() {
        return;
    }
    let f = distortion::fov(eye(eye_index));
    let v = [f.angle_left, f.angle_right, f.angle_up, f.angle_down];
    // SAFETY: caller guarantees 4 writable floats.
    unsafe { std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4) };
}

/// One distortion mesh vertex; same layout as [`distortion::MeshVertex`].
pub type HallidayMeshVertex = distortion::MeshVertex;

/// Builds an eye's distortion mesh of `cols × rows` cells into caller buffers holding at least
/// `(cols + 1) * (rows + 1)` vertices and `cols * rows * 6` indices. Returns false (writing
/// nothing) if a buffer is null or too small, or the calibration is null.
///
/// # Safety
/// `calibration` must point to 8 floats; the buffers must hold the given capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_distortion_mesh(
    calibration: *const f32,
    eye_index: i32,
    cols: u32,
    rows: u32,
    vertices: *mut HallidayMeshVertex,
    vertex_capacity: u32,
    indices: *mut u32,
    index_capacity: u32,
) -> bool {
    if calibration.is_null() || vertices.is_null() || indices.is_null() || cols == 0 || rows == 0 {
        return false;
    }
    let (nv, ni) = (
        (cols as u64 + 1) * (rows as u64 + 1),
        cols as u64 * rows as u64 * 6,
    );
    if nv > vertex_capacity as u64 || ni > index_capacity as u64 {
        return false;
    }
    // SAFETY: caller guarantees 8 readable floats.
    let cal: [f32; 8] = unsafe { std::ptr::read(calibration.cast()) };
    let mesh = DistortionMesh::new(&cal, eye(eye_index), cols, rows);
    // SAFETY: capacities checked above; caller guarantees the buffers hold them.
    unsafe {
        std::ptr::copy_nonoverlapping(mesh.vertices.as_ptr(), vertices, mesh.vertices.len());
        std::ptr::copy_nonoverlapping(mesh.indices.as_ptr(), indices, mesh.indices.len());
    }
    true
}

// --- The bridge to a VR game under Wine (game_bridge.rs) ---

pub use halliday_bridge::{
    Controller as HallidayBridgeController, Overlay as HallidayBridgeOverlay,
    Pose as HallidayBridgePose, Scene as HallidayBridgeScene, State as HallidayBridgeState,
};

/// Opaque: the mapped bridge file.
pub struct HallidayGameBridge(crate::game_bridge::GameBridge);

#[repr(C)]
pub struct HallidayBridgeConfig {
    pub eye_width: u32,
    pub eye_height: u32,
    pub display_hz: f32,
    pub ipd: f32,
    /// Per eye: tangents of the left, right, up and down edges (left and down negative).
    pub tangents: [[f32; 4]; 2],
}

pub type HallidayBridgeProjectionView = halliday_bridge::projection::View;
pub type HallidayBridgeProjectionGeometry = halliday_bridge::projection::Snapshot;

// --- Game controller output ---

pub use crate::game_haptics::GameHapticCommand as HallidayGameHapticCommand;

/// Independent from the mutable frame host: a fast haptic poller may run on another thread.
pub struct HallidayBridgeHaptics(std::sync::Mutex<crate::bridge_haptics::Receiver>);

/// # Safety
/// `bridge` is live and owned by the host. Notify only a real coordinate change.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_reference_changed(bridge: *const HallidayGameBridge) {
    if let Some(bridge) = unsafe { bridge.as_ref() } {
        let ext = unsafe { halliday_bridge::haptics::extension(bridge.0.base().cast()) };
        if ext.available() {
            ext.space_epoch
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }
    }
}

/// # Safety
/// `path` is a readable NUL-terminated bridge path. Mapping is independent of rendering.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_haptics_open(
    path: *const c_char,
) -> *mut HallidayBridgeHaptics {
    if path.is_null() {
        return std::ptr::null_mut();
    }
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else {
        return std::ptr::null_mut();
    };
    match crate::bridge_haptics::Receiver::open(std::path::Path::new(path)) {
        Ok(receiver) => Box::into_raw(Box::new(HallidayBridgeHaptics(std::sync::Mutex::new(
            receiver,
        )))),
        Err(_) => std::ptr::null_mut(),
    }
}
/// # Safety
/// `handle` is live; `out` holds at least four commands. Close never overlaps a call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_haptics_poll(
    handle: *const HallidayBridgeHaptics,
    now: u64,
    focused: bool,
    connected: u32,
    out: *mut HallidayGameHapticCommand,
    capacity: u32,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if out.is_null() || capacity < 4 {
        return 0;
    }
    let Ok(mut receiver) = handle.0.lock() else {
        return 0;
    };
    let now = if now == 0 {
        crate::time::host_time_ns() as u64
    } else {
        now
    };
    let commands = receiver.poll(now, focused, connected);
    unsafe {
        std::ptr::copy_nonoverlapping(commands.as_ptr(), out, commands.len());
    }
    commands.len() as u32
}
/// # Safety
/// Same requirements as poll; capacity is at least two.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_haptics_stop(
    handle: *const HallidayBridgeHaptics,
    out: *mut HallidayGameHapticCommand,
    capacity: u32,
) -> u32 {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return 0;
    };
    if out.is_null() || capacity < 2 {
        return 0;
    }
    let Ok(mut receiver) = handle.0.lock() else {
        return 0;
    };
    let commands = receiver.stop_all();
    unsafe {
        std::ptr::copy_nonoverlapping(commands.as_ptr(), out, commands.len());
    }
    commands.len() as u32
}
/// # Safety
/// No poll or remaining handle use is allowed after close.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_haptics_close(handle: *mut HallidayBridgeHaptics) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}
#[repr(C)]
pub struct HallidayBridgeFrame {
    pub width: u32,
    pub height: u32,
    pub bottom_up: u32,
    pub slot: u32,
    /// 1: pixels are B, G, R, A.
    pub bgra: u32,
    /// 1: the picture's alpha is meant: the room may show where it is clear.
    pub see_through: u32,
    pub bounds: [[f32; 4]; 2],
    pub pose: HallidayBridgePose,
    pub frame_index: u64,
    /// Byte offsets of each eye's image from the start of the mapping.
    pub offsets: [u64; 2],
}

#[repr(C)]
pub struct HallidayBridgeClient {
    pub frames: u64,
    pub calls: u64,
    pub pid: u32,
    pub name: [u8; 64],
    /// Beats about every 250 ms while the runtime is loaded in a game.
    pub heartbeat: u64,
    /// 1 between the game's VR_Init and VR_Shutdown.
    pub initialized: u32,
    pub quit_acknowledged: u32,
}

/// A picture of the game's claimed for reading (RGBA rows top-down, premultiplied).
#[repr(C)]
pub struct HallidayBridgePicture {
    pub seq: u32,
    pub width: u32,
    pub height: u32,
    pub _pad: u32,
    /// Its first row, from the start of the mapping.
    pub offset: u64,
}

fn picture_id(index: i32) -> crate::game_bridge::PictureId {
    if index < 0 {
        crate::game_bridge::PictureId::Skybox
    } else {
        crate::game_bridge::PictureId::Overlay(index as usize)
    }
}

/// The game's scene (fades, grid, skybox) and its `HALLIDAY_BRIDGE_OVERLAYS` overlays; false if
/// they kept changing while read.
///
/// # Safety
/// `bridge` is open; `scene` is writable; `overlays` holds `HALLIDAY_BRIDGE_OVERLAYS` entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_scene(
    bridge: *const HallidayGameBridge,
    scene: *mut HallidayBridgeScene,
    overlays: *mut HallidayBridgeOverlay,
) -> bool {
    // SAFETY: caller guarantees valid or null pointers.
    let (Some(b), Some(scene)) = (unsafe { bridge.as_ref() }, unsafe { scene.as_mut() }) else {
        return false;
    };
    if overlays.is_null() {
        return false;
    }
    let Some((s, o)) = b.0.scene() else {
        return false;
    };
    *scene = s;
    // SAFETY: caller guarantees room for every overlay.
    unsafe { std::ptr::copy_nonoverlapping(o.as_ptr(), overlays, o.len()) };
    true
}

/// Claims overlay `index`'s picture (-1: the skybox's) if it changed since `seen`; release it with
/// `halliday_bridge_release_picture` once copied.
///
/// # Safety
/// `bridge` is open; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_claim_picture(
    bridge: *const HallidayGameBridge,
    index: i32,
    seen: u32,
    out: *mut HallidayBridgePicture,
) -> bool {
    // SAFETY: caller guarantees valid or null pointers.
    let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(p) = b.0.claim_picture(picture_id(index), seen) else {
        return false;
    };
    *out = HallidayBridgePicture {
        seq: p.seq,
        width: p.width,
        height: p.height,
        _pad: 0,
        offset: p.offset as u64,
    };
    true
}

/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_release_picture(
    bridge: *const HallidayGameBridge,
    index: i32,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.release_picture(picture_id(index));
    }
}

/// Halliday's display period (ns), and whether this display frame showed an older game frame
/// again (`late`).
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_frame_shown(
    bridge: *const HallidayGameBridge,
    interval_ns: u64,
    late: bool,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.set_frame_interval(interval_ns);
        if late {
            b.0.count_late_vsync();
        }
    }
}

/// Asks the game to quit.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_request_quit(bridge: *const HallidayGameBridge) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.request_quit();
    }
}

/// Halliday's own interface is over the game (true) or not.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_set_dashboard(
    bridge: *const HallidayGameBridge,
    shown: bool,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.set_dashboard(shown);
    }
}

/// The game's window of frames (W14.9): its state (0 off, 1 starting, 2 on, 3 failed) and its
/// size in pixels, band included.
#[repr(C)]
pub struct HallidayBridgePresent {
    pub state: u32,
    pub width: u32,
    pub height: u32,
    pub _pad: u32,
}

/// One window frame's record (`halliday_bridge::PresentInfo`).
#[repr(C)]
pub struct HallidayBridgePresentFrame {
    pub number: u32,
    pub eye_width: u32,
    pub eye_height: u32,
    /// 1: the image is upside down.
    pub flipped: u32,
    pub frame_index: u64,
    pub texture_type: u32,
    pub _pad: u32,
    pub pose: HallidayBridgePose,
}

/// Tells the game where its window of frames goes (`enabled`), or that Halliday can't capture one.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_set_present(
    bridge: *const HallidayGameBridge,
    enabled: bool,
    x: i32,
    y: i32,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.set_present(enabled.then_some((x, y)));
    }
}

/// Where a hand points at one of the game's overlays that takes the mouse: `overlay` is its
/// index plus 1 (0: none), `device` the hand (1 left, 2 right), `buttons` bit 0 the trigger,
/// `u`/`v` 0…1 from the picture's top left, `scroll` the notches so far in hundredths.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_set_pointer(
    bridge: *const HallidayGameBridge,
    overlay: u32,
    device: u32,
    buttons: u32,
    u: f32,
    v: f32,
    scroll: i32,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.set_pointer(&halliday_bridge::PointerState {
            overlay,
            device,
            buttons,
            u,
            v,
            scroll,
        });
    }
}

/// Overlay `index`'s height in meters as Halliday shows it.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_set_overlay_height(
    bridge: *const HallidayGameBridge,
    index: u32,
    meters: f32,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.set_overlay_height(index as usize, meters);
    }
}

/// The game's window of frames.
///
/// # Safety
/// `bridge` is open (null is ignored); `out` points to a struct.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_present_status(
    bridge: *const HallidayGameBridge,
    out: *mut HallidayBridgePresent,
) {
    // SAFETY: caller guarantees valid or null pointers.
    if let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) {
        let (state, width, height) = b.0.present_status();
        *out = HallidayBridgePresent {
            state,
            width,
            height,
            _pad: 0,
        };
    }
}

/// Window frame `number`'s record; false if it is no longer (or not yet) in the ring.
///
/// # Safety
/// `bridge` is open (null is ignored); `out` points to a struct.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_present_frame(
    bridge: *const HallidayGameBridge,
    number: u32,
    out: *mut HallidayBridgePresentFrame,
) -> bool {
    // SAFETY: caller guarantees valid or null pointers.
    let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(f) = b.0.present_frame(number) else {
        return false;
    };
    *out = HallidayBridgePresentFrame {
        number: f.number,
        eye_width: f.eye_width,
        eye_height: f.eye_height,
        flipped: f.flipped as u32,
        frame_index: f.frame_index,
        texture_type: f.texture_type,
        _pad: 0,
        pose: f.pose,
    };
    true
}

/// Halliday captured window frame `number`.
///
/// # Safety
/// `bridge` is open (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_present_seen(
    bridge: *const HallidayGameBridge,
    number: u32,
) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.present_seen(number);
    }
}

/// Creates the bridge file at `path` (replacing any) and maps it; null on failure.
///
/// # Safety
/// `path` is a NUL-terminated string; `config` points to a config.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_open(
    path: *const c_char,
    config: *const HallidayBridgeConfig,
) -> *mut HallidayGameBridge {
    if path.is_null() || config.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: caller guarantees both pointers.
    let (path, c) = unsafe {
        (
            CStr::from_ptr(path).to_string_lossy().into_owned(),
            &*config,
        )
    };
    let config = crate::game_bridge::Config {
        eye_width: c.eye_width,
        eye_height: c.eye_height,
        display_hz: c.display_hz,
        ipd: c.ipd,
        tangents: c.tangents,
    };
    match crate::game_bridge::GameBridge::create(std::path::Path::new(&path), config) {
        Ok(b) => Box::into_raw(Box::new(HallidayGameBridge(b))),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Retires the public bridge immediately without releasing its mapping.
/// Pending GPU readers may keep the handle alive until their copies complete.
///
/// # Safety
/// `bridge` is a live owned handle or null. It remains valid after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_retire(bridge: *const HallidayGameBridge) {
    if let Some(bridge) = unsafe { bridge.as_ref() } {
        bridge.0.retire();
    }
}

/// Unmaps the bridge and retires its publication if not already retired.
///
/// # Safety
/// `bridge` came from `halliday_bridge_open` and isn't used afterwards (null is ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_close(bridge: *mut HallidayGameBridge) {
    if !bridge.is_null() {
        // SAFETY: caller hands back ownership.
        drop(unsafe { Box::from_raw(bridge) });
    }
}

/// Publishes this display frame's head and controllers.
///
/// # Safety
/// `bridge` is open; `state` points to a state.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_publish(
    bridge: *const HallidayGameBridge,
    state: *const HallidayBridgeState,
) {
    // SAFETY: caller guarantees valid or null pointers.
    if let (Some(b), Some(s)) = unsafe { (bridge.as_ref(), state.as_ref()) } {
        b.0.publish(s);
    }
}

/// Publishes the latest pose/input state; only `notify_game` advances the game's
/// frame-wait counter. The mapped v6 Header layout and legacy publish API stay unchanged.
///
/// # Safety
/// `bridge` is open; `state` points to a state (null pointers are ignored).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_publish_frame(
    bridge: *const HallidayGameBridge,
    state: *const HallidayBridgeState,
    notify_game: bool,
) {
    // SAFETY: caller guarantees valid or null pointers.
    if let (Some(b), Some(s)) = unsafe { (bridge.as_ref(), state.as_ref()) } {
        b.0.publish_frame(s, notify_game);
    }
}

/// Explicit head/left/right linear+angular validity associated with this state.
/// # Safety
/// Same pointer requirements as `halliday_bridge_publish_frame`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_publish_frame_with_motion(
    bridge: *const HallidayGameBridge,
    state: *const HallidayBridgeState,
    notify_game: bool,
    motion_mask: u32,
) {
    if let (Some(b), Some(s)) = unsafe { (bridge.as_ref(), state.as_ref()) } {
        b.0.publish_frame_with_motion(s, notify_game, motion_mask);
    }
}

/// Claims the game's newest frame; false if there is none. Release it with `halliday_bridge_end_read`.
///
/// # Safety
/// `bridge` is open; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_begin_read(
    bridge: *const HallidayGameBridge,
    out: *mut HallidayBridgeFrame,
) -> bool {
    // SAFETY: caller guarantees valid or null pointers.
    let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(f) = b.0.begin_read() else {
        return false;
    };
    *out = HallidayBridgeFrame {
        width: f.width,
        height: f.height,
        bottom_up: f.bottom_up as u32,
        slot: f.slot as u32,
        bgra: f.bgra as u32,
        see_through: f.see_through as u32,
        bounds: f.bounds,
        pose: f.pose,
        frame_index: f.frame_index,
        offsets: [f.offsets[0] as u64, f.offsets[1] as u64],
    };
    true
}

/// # Safety
/// `bridge` is open.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_end_read(bridge: *const HallidayGameBridge) {
    // SAFETY: caller guarantees valid or null.
    if let Some(b) = unsafe { bridge.as_ref() } {
        b.0.end_read();
    }
}

/// Transfer tag for one eye in the currently claimed frame. Zero preserves legacy handling.
/// # Safety
/// `bridge` is open, and the caller owns the frame until `halliday_bridge_end_read`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_frame_color_space(
    bridge: *const HallidayGameBridge,
    slot: u32,
    eye: u32,
) -> u32 {
    // SAFETY: caller guarantees a valid or null handle.
    unsafe { bridge.as_ref() }.map_or(0, |b| b.0.frame_color_space(slot as usize, eye as usize))
}

/// 0: legacy frame without required geometry, 1: complete matching geometry,
/// -1: invalid/unavailable required geometry. On -1 retain the previous frame.
/// # Safety
/// `bridge` is live or null, `out` writable or null. The caller owns the frame
/// lease from begin_read until end_read while reading this associated record.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_projection_geometry(
    bridge: *const HallidayGameBridge,
    slot: u32,
    frame_index: u64,
    out: *mut HallidayBridgeProjectionGeometry,
) -> i32 {
    let Some(out) = (unsafe { out.as_mut() }) else {
        return -1;
    };
    *out = HallidayBridgeProjectionGeometry::default();
    let Some(bridge) = (unsafe { bridge.as_ref() }) else {
        return -1;
    };
    match bridge.0.projection_geometry(slot as usize, frame_index) {
        Ok(Some(snapshot)) => {
            *out = snapshot;
            1
        }
        Ok(None) => 0,
        Err(()) => -1,
    }
}

/// The start of the mapping (page-aligned, `halliday_bridge_file_size()` bytes).
///
/// # Safety
/// `bridge` is open.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_base(bridge: *const HallidayGameBridge) -> *mut u8 {
    // SAFETY: caller guarantees valid or null.
    unsafe { bridge.as_ref() }.map_or(std::ptr::null_mut(), |b| b.0.base())
}

#[unsafe(no_mangle)]
pub extern "C" fn halliday_bridge_file_size() -> u64 {
    halliday_bridge::FILE_BYTES as u64
}

/// The game's side: frames and calls so far, its process id and executable name.
///
/// # Safety
/// `bridge` is open; `out` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_client(
    bridge: *const HallidayGameBridge,
    out: *mut HallidayBridgeClient,
) {
    // SAFETY: caller guarantees valid or null pointers.
    if let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) {
        let c = b.0.client();
        *out = HallidayBridgeClient {
            frames: c.frames,
            calls: c.calls,
            pid: c.pid,
            name: c.name,
            heartbeat: c.heartbeat,
            initialized: c.initialized as u32,
            quit_acknowledged: c.quit_acknowledged,
        };
    }
}

/// Raw producer lease status (0 unowned, 1 ready, UINT_MAX initializing).
///
/// # Safety
/// `bridge` is open or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_client_status(bridge: *const HallidayGameBridge) -> u32 {
    unsafe { bridge.as_ref() }.map_or(0, |b| b.0.client_status())
}

/// The currently ready independent client's session generation, or zero for legacy clients.
///
/// # Safety
/// `bridge` is open or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_client_epoch(bridge: *const HallidayGameBridge) -> u64 {
    // SAFETY: caller guarantees a valid or null handle.
    unsafe { bridge.as_ref() }.map_or(0, |b| b.0.client_epoch())
}

pub type HallidayBridgePanel = halliday_bridge::panels::Panel;
#[repr(C)]
pub struct HallidayBridgePanelBatch {
    pub epoch: u64,
    pub frame_index: u64,
    pub count: u32,
    pub projection_order: u32,
    pub projection_flags: u32,
    pub _reserved: u32,
}

/// # Safety
/// Live or null bridge; writable batch and capacity-sized panel output.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_panels(
    bridge: *const HallidayGameBridge,
    slot: u32,
    frame_index: u64,
    batch: *mut HallidayBridgePanelBatch,
    panels: *mut HallidayBridgePanel,
    capacity: u32,
) -> bool {
    unsafe { halliday_bridge_layer_batch(bridge, slot, frame_index, batch, panels, capacity) == 1 }
}

/// 1 = complete batch, 0 = optional legacy metadata absent, -1 = required batch
/// unavailable or invalid call. No partial batch is returned on failure.
/// # Safety
/// Live or null bridge; writable batch and capacity-sized panel output.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_layer_batch(
    bridge: *const HallidayGameBridge,
    slot: u32,
    frame_index: u64,
    batch: *mut HallidayBridgePanelBatch,
    panels: *mut HallidayBridgePanel,
    capacity: u32,
) -> i32 {
    let Some(batch) = (unsafe { batch.as_mut() }) else {
        return -1;
    };
    *batch = HallidayBridgePanelBatch {
        epoch: 0,
        frame_index: 0,
        count: 0,
        projection_order: 0,
        projection_flags: 0,
        _reserved: 0,
    };
    let Some(b) = (unsafe { bridge.as_ref() }) else {
        return -1;
    };
    let snapshot = match b.0.checked_panels(slot as usize, frame_index) {
        Ok(Some(batch)) => batch,
        Ok(None) => return 0,
        Err(()) => return -1,
    };
    if capacity < snapshot.count as u32 || (snapshot.count > 0 && panels.is_null()) {
        return -1;
    }
    if snapshot.count > 0 {
        unsafe {
            std::ptr::copy_nonoverlapping(snapshot.panels.as_ptr(), panels, snapshot.count);
        }
    }
    *batch = HallidayBridgePanelBatch {
        epoch: snapshot.epoch,
        frame_index: snapshot.frame_index,
        count: snapshot.count as u32,
        projection_order: snapshot.projection_order,
        projection_flags: snapshot.projection_flags,
        _reserved: 0,
    };
    1
}

/// # Safety
/// Live or null bridge, writable output. Release a successful picture claim after GPU completion.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_bridge_claim_panel(
    bridge: *const HallidayGameBridge,
    index: u32,
    sequence: u32,
    out: *mut HallidayBridgePicture,
) -> bool {
    let (Some(b), Some(out)) = (unsafe { bridge.as_ref() }, unsafe { out.as_mut() }) else {
        return false;
    };
    let Some(picture) = b.0.claim_panel(index as usize, sequence) else {
        return false;
    };
    *out = HallidayBridgePicture {
        seq: picture.seq,
        width: picture.width,
        height: picture.height,
        _pad: 0,
        offset: picture.offset as u64,
    };
    true
}

// --- Android packages (Quest apps) --------------------------------------------------------------

/// Reads an APK's `AndroidManifest.xml` (Android's binary XML, `len` bytes) and writes, as
/// UTF-8 without a terminator, either the whole document as text (`xml`) or a line-per-fact
/// summary: `package=…`, `versionName=…`, `versionCode=…`, `native=…` (the library a
/// NativeActivity runs, if any) and `launcher=…` (the activity a launcher starts, if any).
/// Returns the text's length, which may be more than `capacity` (then nothing is written:
/// ask again with room), or -1 when it isn't a manifest.
///
/// # Safety
/// `bytes` must be valid for `len` bytes and `out` for `capacity` (or null with capacity 0).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn halliday_apk_manifest(
    bytes: *const u8,
    len: usize,
    xml: bool,
    out: *mut u8,
    capacity: usize,
) -> i64 {
    if bytes.is_null() {
        return -1;
    }
    // SAFETY: the caller's buffer of `len` bytes.
    let Ok(manifest) =
        crate::apk::Manifest::parse(unsafe { std::slice::from_raw_parts(bytes, len) })
    else {
        return -1;
    };
    let text = if xml {
        manifest.to_xml()
    } else {
        let launcher = manifest.activities.iter().find(|a| a.launcher);
        format!(
            "package={}\nversionName={}\nversionCode={}\nnative={}\nlauncher={}\n",
            manifest.package,
            manifest.version_name.replace('\n', " "),
            manifest.version_code,
            manifest.native_library().unwrap_or_default(),
            launcher.map_or("", |a| a.name.as_str()),
        )
    };
    if text.len() <= capacity && !out.is_null() {
        // SAFETY: room for `capacity` bytes, and the text is no longer.
        unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), out, text.len()) };
    }
    text.len() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn camera_identity_c_buffer_is_bounded_and_unchanged_on_failure() {
        let mut bytes = [0xa5; 6];
        // SAFETY: all non-null destinations address the complete buffer above.
        unsafe {
            assert!(!halliday_session_headset_identity(
                std::ptr::null(),
                bytes.as_mut_ptr(),
                6
            ));
            assert!(!copy_headset_identity("PCB12", std::ptr::null_mut(), 6));
            assert!(!copy_headset_identity("PCB12", bytes.as_mut_ptr(), 5));
            assert!(!copy_headset_identity("PCB12", bytes.as_mut_ptr(), 0));
            assert_eq!(bytes, [0xa5; 6]);
            assert!(copy_headset_identity("PCB12", bytes.as_mut_ptr(), 6));
            assert_eq!(&bytes, b"PCB12\0");
        }
    }

    #[test]
    fn hand_camera_alignment_c_api_validates_pointers_and_values() {
        let hand = halliday_hand_open(true);
        let rotation = [-0.0041120713, 0.0033288613, -0.0149200596];
        // SAFETY: each non-null pointer below addresses three readable floats or
        // the exclusively owned live handle, which is released exactly once.
        unsafe {
            assert!(!halliday_hand_set_fisheye_alignment(
                std::ptr::null(),
                rotation.as_ptr()
            ));
            assert!(!halliday_hand_set_fisheye_alignment(hand, std::ptr::null()));
            assert!(halliday_hand_set_fisheye_alignment(hand, rotation.as_ptr()));
            assert!(!halliday_hand_set_fisheye_alignment(
                hand,
                [f32::NAN, 0.0, 0.0].as_ptr()
            ));
            assert!(!halliday_hand_set_fisheye_alignment(
                hand,
                [0.0, 0.0, 0.1].as_ptr()
            ));
            assert!(halliday_hand_set_fisheye_alignment(hand, [0.0; 3].as_ptr()));
            halliday_hand_close(hand);
        }
    }

    #[test]
    fn version_is_nul_terminated_and_matches() {
        // SAFETY: halliday_core_version returns a pointer to a static NUL-terminated string.
        let v = unsafe { CStr::from_ptr(halliday_core_version()) };
        assert_eq!(v.to_str().unwrap(), crate::VERSION);
    }

    #[test]
    fn header_declares_every_exported_function() {
        let header = include_str!("../include/halliday_core.h");
        let source = include_str!("ffi.rs");
        let exported: Vec<&str> = source
            .lines()
            .filter_map(|l| l.split("extern \"C\" fn ").nth(1))
            .filter_map(|rest| rest.split('(').next())
            .filter(|name| name.starts_with("halliday_"))
            .collect();
        assert!(exported.len() >= 16, "{exported:?}");
        for name in exported {
            assert!(
                header.contains(&format!("{name}(")),
                "{name} missing from halliday_core.h"
            );
        }
    }

    #[test]
    fn mesh_vertex_layout_matches_the_header() {
        assert_eq!(std::mem::size_of::<HallidayMeshVertex>(), 32);
        // 10 floats, then the i64 at offset 40, then the u8 and padding: same as C.
        assert_eq!(std::mem::offset_of!(HallidayHeadPose, slam_age_ns), 40);
        assert_eq!(std::mem::offset_of!(HallidayHeadPose, predicted), 48);
        assert_eq!(std::mem::size_of::<HallidayHeadPose>(), 56);
        assert_eq!(
            std::mem::offset_of!(HallidayHeadPoseMotion, linear_velocity),
            56
        );
        assert_eq!(
            std::mem::offset_of!(HallidayHeadPoseMotion, motion_flags),
            68
        );
        assert_eq!(std::mem::size_of::<HallidayHeadPoseMotion>(), 72);
        assert_eq!(std::mem::size_of::<HallidayHeadsetStatus>(), 3);
        // The bridge's types as the header declares them.
        assert_eq!(std::mem::size_of::<HallidayBridgeState>(), 64 + 2 * 128);
        assert_eq!(
            std::mem::size_of::<HallidayBridgeFrame>(),
            16 + 8 + 32 + 64 + 8 + 16
        );
        assert_eq!(
            std::mem::size_of::<HallidayBridgeClient>(),
            8 + 8 + 4 + 64 + 4 + 8 + 4 + 4
        );
        assert_eq!(std::mem::offset_of!(HallidayBridgeClient, heartbeat), 88);
        assert_eq!(std::mem::size_of::<HallidayBridgePresent>(), 16);
        assert_eq!(std::mem::size_of::<HallidayBridgePresentFrame>(), 32 + 64);
        assert_eq!(std::mem::offset_of!(HallidayBridgePresentFrame, pose), 32);
        assert_eq!(std::mem::size_of::<HallidayBridgeScene>(), 60);
        assert_eq!(std::mem::size_of::<HallidayBridgeOverlay>(), 432);
        assert_eq!(std::mem::offset_of!(HallidayBridgeOverlay, key), 112);
        assert_eq!(std::mem::size_of::<HallidayBridgePicture>(), 24);
        assert_eq!(
            halliday_bridge::OVERLAYS,
            8,
            "HALLIDAY_BRIDGE_OVERLAYS in the header"
        );
    }

    #[test]
    fn null_pointers_are_rejected() {
        // SAFETY: null handles and buffers are documented as accepted.
        unsafe {
            assert!(!halliday_session_predict(
                std::ptr::null(),
                0,
                std::ptr::null_mut()
            ));
            assert_eq!(halliday_session_link_state(std::ptr::null()), 0);
            assert!(halliday_session_open_replay(std::ptr::null(), false).is_null());
            halliday_session_close(std::ptr::null_mut());
            assert!(!halliday_distortion_mesh(
                std::ptr::null(),
                0,
                1,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                0
            ));
        }
    }

    #[test]
    fn mesh_checks_capacity() {
        let cal = crate::psvr2::protocol::DistortionCalibration::FALLBACK;
        let mut v = vec![
            HallidayMeshVertex {
                position: [0.0; 2],
                uv_r: [0.0; 2],
                uv_g: [0.0; 2],
                uv_b: [0.0; 2]
            };
            9
        ];
        let mut i = vec![0u32; 24];
        // SAFETY: buffers sized as passed.
        unsafe {
            assert!(halliday_distortion_mesh(
                cal.as_ptr(),
                1,
                2,
                2,
                v.as_mut_ptr(),
                9,
                i.as_mut_ptr(),
                24
            ));
            assert!(!halliday_distortion_mesh(
                cal.as_ptr(),
                1,
                3,
                2,
                v.as_mut_ptr(),
                9,
                i.as_mut_ptr(),
                24
            ));
        }
        assert_eq!(v[8].position, [1.0, 1.0]);
    }
}
