//! PS VR2 Sense controllers: input reports, IMU calibration and orientation.
//!
//! The report layout, the button bits and the calibration arithmetic are ported from Monado's
//! `pssense` driver (BSL-1.0; see THIRD-PARTY.md), and were checked against two controllers over
//! Bluetooth on macOS: report 0x31, 78 bytes, 60 to 70 a second each.
//!
//! The app reads the HID reports (IOKit, in Swift) and hands the bytes to a [`Controller`], which
//! keeps the newest inputs and an orientation fused from the gyro and the accelerometer. The
//! controllers have no compass and, until the headset's cameras track them (PLAN.md §5), no
//! position: heading drifts slowly and is set again with [`Controller::recenter`].
//!
//! Axes: the IMU's x points right, y up and z back as the controller is held (Monado feeds them
//! to its fusion unchanged); the orientation turns that frame into the tracking space's.

use crate::math::{Quat, Vec3};
pub use crate::sense_orientation_history::OrientationHistory;

pub const VENDOR_ID: u16 = 0x054C;
pub const PRODUCT_ID_LEFT: u16 = 0x0E45;
pub const PRODUCT_ID_RIGHT: u16 = 0x0E46;

/// Input report over Bluetooth: id, a header byte, the common part, 9 more bytes and a CRC.
pub const REPORT_ID_BLUETOOTH: u8 = 0x31;
pub const REPORT_LEN_BLUETOOTH: usize = 78;
/// Input report over USB: id and the common part.
pub const REPORT_ID_USB: u8 = 0x01;
pub const REPORT_LEN_USB: usize = 64;
const COMMON_LEN: usize = 63;

/// Feature report holding half of the calibration (asked for twice: parts 0x00 and 0x81).
pub const CALIBRATION_REPORT_ID: u8 = 0x05;
pub const CALIBRATION_REPORT_LEN: usize = 64;
const CALIBRATION_PART_LEN: usize = 58;

/// IMU time is in thirds of a microsecond.
const IMU_TICK_S: f64 = 1.0 / 3_000_000.0;
const GRAVITY: f32 = 9.806_65;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Hand {
    Left,
    Right,
}

impl Hand {
    pub fn from_product_id(id: u16) -> Option<Hand> {
        match id {
            PRODUCT_ID_LEFT => Some(Hand::Left),
            PRODUCT_ID_RIGHT => Some(Hand::Right),
            _ => None,
        }
    }
}

/// Buttons and touch sensors, the same bits for both hands. "Lower" is square on the left
/// controller and cross on the right; "upper" is triangle and circle; "menu" is Create and
/// Options.
pub mod buttons {
    pub const TRIGGER: u32 = 1 << 0;
    pub const GRIP: u32 = 1 << 1;
    pub const STICK: u32 = 1 << 2;
    pub const PS: u32 = 1 << 3;
    pub const MENU: u32 = 1 << 4;
    pub const LOWER: u32 = 1 << 5;
    pub const UPPER: u32 = 1 << 6;
    pub const TRIGGER_TOUCH: u32 = 1 << 8;
    pub const GRIP_TOUCH: u32 = 1 << 9;
    pub const STICK_TOUCH: u32 = 1 << 10;
    pub const LOWER_TOUCH: u32 = 1 << 11;
    pub const UPPER_TOUCH: u32 = 1 << 12;
}

/// One input report, as sent.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InputReport {
    /// −1..1, x to the right and y away from the user.
    pub stick: [f32; 2],
    /// 0..1.
    pub trigger: f32,
    /// How near the finger is to the trigger and the hand to the grip, 0..1.
    pub trigger_proximity: f32,
    pub grip_proximity: f32,
    /// [`buttons`] bits.
    pub buttons: u32,
    pub sequence: u32,
    pub gyro_raw: [i16; 3],
    pub accel_raw: [i16; 3],
    pub imu_ticks: u32,
    /// The controller's clock when the report was sent, in thirds of a microsecond.
    pub device_ticks: u32,
    /// 5 to 100.
    pub battery_percent: u8,
    pub charging: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportError {
    /// Not an input report of a Sense controller (wrong id or length).
    NotAnInputReport,
    /// A Bluetooth report whose CRC doesn't match.
    BadChecksum,
}

impl InputReport {
    /// Parses a report as HID delivers it, report id first.
    pub fn parse(hand: Hand, bytes: &[u8]) -> Result<InputReport, ReportError> {
        let common = match bytes.first() {
            Some(&REPORT_ID_BLUETOOTH) if bytes.len() == REPORT_LEN_BLUETOOTH => {
                let sent = u32::from_le_bytes([bytes[74], bytes[75], bytes[76], bytes[77]]);
                if crc32(&[0xA1], &bytes[..74]) != sent {
                    return Err(ReportError::BadChecksum);
                }
                &bytes[2..2 + COMMON_LEN]
            }
            Some(&REPORT_ID_USB) if bytes.len() == REPORT_LEN_USB => &bytes[1..1 + COMMON_LEN],
            _ => return Err(ReportError::NotAnInputReport),
        };
        let b = [common[7], common[8], common[9]];
        let mut pressed = 0;
        let mut set = |on: bool, bit: u32| {
            if on {
                pressed |= bit;
            }
        };
        set(b[1] & 0x10 != 0, buttons::PS);
        set(b[1] & 0x80 != 0, buttons::TRIGGER_TOUCH);
        set(b[2] & 0x08 != 0, buttons::GRIP_TOUCH);
        set(b[2] & 0x04 != 0, buttons::STICK_TOUCH);
        set(b[2] & 0x02 != 0, buttons::LOWER_TOUCH);
        set(b[2] & 0x01 != 0, buttons::UPPER_TOUCH);
        match hand {
            Hand::Left => {
                set(b[1] & 0x01 != 0, buttons::MENU);
                set(b[0] & 0x01 != 0, buttons::LOWER);
                set(b[0] & 0x08 != 0, buttons::UPPER);
                set(b[0] & 0x10 != 0, buttons::GRIP);
                set(b[0] & 0x40 != 0, buttons::TRIGGER);
                set(b[1] & 0x04 != 0, buttons::STICK);
            }
            Hand::Right => {
                set(b[1] & 0x02 != 0, buttons::MENU);
                set(b[0] & 0x02 != 0, buttons::LOWER);
                set(b[0] & 0x04 != 0, buttons::UPPER);
                set(b[0] & 0x20 != 0, buttons::GRIP);
                set(b[0] & 0x80 != 0, buttons::TRIGGER);
                set(b[1] & 0x08 != 0, buttons::STICK);
            }
        }
        let i16_at = |i: usize| i16::from_le_bytes([common[i], common[i + 1]]);
        let u32_at =
            |i: usize| u32::from_le_bytes([common[i], common[i + 1], common[i + 2], common[i + 3]]);
        let battery = common[41];
        Ok(InputReport {
            stick: [
                (f32::from(common[0]) - 128.0) / 128.0,
                (f32::from(common[1]) - 128.0) / -128.0,
            ],
            trigger: f32::from(common[2]) / 255.0,
            trigger_proximity: f32::from(common[3]) / 255.0,
            grip_proximity: f32::from(common[4]) / 255.0,
            buttons: pressed,
            sequence: u32_at(11),
            gyro_raw: [i16_at(15), i16_at(17), i16_at(19)],
            accel_raw: [i16_at(21), i16_at(23), i16_at(25)],
            imu_ticks: u32_at(27),
            device_ticks: u32_at(47),
            // The level is 0 to 10; 5% is added so a working controller never shows 0.
            battery_percent: ((battery & 0x0F).min(10) * 10 + 5).min(100),
            charging: battery >> 4 == 1,
        })
    }
}

/// The feature report that asks a controller for more reports a second: about 133 over
/// Bluetooth, where it sends 60 by itself (Monado's "PC polling rate"). Sent as it is, report id
/// first.
pub const POLLING_RATE_REPORT_LEN: usize = 48;
pub fn polling_rate_report() -> [u8; POLLING_RATE_REPORT_LEN] {
    let mut r = [0u8; POLLING_RATE_REPORT_LEN];
    r[0] = 0x08;
    r[1] = 0x0E;
    r[2..4].copy_from_slice(&0x000Cu16.to_le_bytes());
    r[4..6].copy_from_slice(&0x0002u16.to_le_bytes());
    let crc = crc32(&[0x53], &r[..POLLING_RATE_REPORT_LEN - 4]);
    r[POLLING_RATE_REPORT_LEN - 4..].copy_from_slice(&crc.to_le_bytes());
    r
}

/// What a controller's tracking LEDs do (Monado's `pssense_led_sync_phase`). The phases between
/// are the steps of syncing the blink to the cameras' exposure, not used yet.
pub mod led_phase {
    /// Blinking: one pulse per cycle, as long as the period says, at the cycle's position.
    pub const PRESCAN: u8 = 1;
    pub const ALL_OFF: u8 = 5;
    pub const ALL_ON: u8 = 6;
}

/// Output report over Bluetooth (the PS5's layout): id, sequence, tag, 38 bytes of settings, a
/// counter, 32 haptic samples, CRC.
pub const OUTPUT_REPORT_LEN: usize = 78;

/// How the tracking LEDs blink: every LED pulses once per cycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LedBlink {
    /// [`led_phase`].
    pub phase: u8,
    /// Goes up when the timing changes.
    pub sequence: u8,
    /// The pulse lasts this many times 50 µs (Monado uses 20 to 42: 1 to 2.1 ms).
    pub period_id: u8,
    /// The middle of a pulse, on the controller's own clock (`InputReport::device_ticks`), in
    /// thirds of a microsecond.
    pub cycle_position: u32,
    /// From one pulse to the next, in thirds of a nanosecond.
    pub cycle_length: u32,
}

/// An output report that only sets the tracking LEDs: no rumble, no trigger effect. `sequence`
/// (0..16) and `counter` go up by one with every report sent; `host_us` is the host's clock in
/// microseconds when it is sent.
pub fn led_report(
    sequence: u8,
    counter: u8,
    blink: LedBlink,
    host_us: u32,
) -> [u8; OUTPUT_REPORT_LEN] {
    let mut r = [0u8; OUTPUT_REPORT_LEN];
    r[0] = 0x31;
    r[1] = (sequence & 0x0F) << 4; // low bits zero: the PS5's packet format
    r[2] = 0x10;
    r[18..22].copy_from_slice(&host_us.to_le_bytes());
    r[22] = blink.phase;
    r[23] = blink.sequence;
    r[24] = blink.period_id;
    r[25..29].copy_from_slice(&blink.cycle_position.to_le_bytes());
    r[29..33].copy_from_slice(&blink.cycle_length.to_le_bytes());
    r[33..37].copy_from_slice(&[0xFF; 4]); // every LED
    r[41] = counter;
    let crc = crc32(&[0xA2], &r[..OUTPUT_REPORT_LEN - 4]);
    r[OUTPUT_REPORT_LEN - 4..].copy_from_slice(&crc.to_le_bytes());
    r
}

/// A Bluetooth vibration-only output report, from Monado's pssense driver
/// ae43b1893e4544189bb6333c79e19dc3ecfee673 (BSL-1.0; THIRD-PARTY.md).
/// This standalone builder has no previous tracking-LED settings. Once LEDs
/// are programmed, use [`vibration_report_retaining_led`] so an unrelated
/// vibration report cannot latch phase INIT with a zero LED sequence. The actuator
/// offers 60/120 Hz and classic-rumble modes, rather than arbitrary PCM frequency.
/// Zero amplitude explicitly stops it. Duration/resend policy belongs to the
/// caller: Monado documents a five-second device timeout and two-second refresh.
pub fn vibration_report(
    sequence: u8,
    counter: u8,
    amplitude: f32,
    frequency_hz: f32,
    host_us: u32,
) -> [u8; OUTPUT_REPORT_LEN] {
    let mut report = [0; OUTPUT_REPORT_LEN];
    report[0] = 0x31;
    report[1] = (sequence & 0x0f) << 4;
    report[2] = 0x10;
    let mode = if frequency_hz.is_finite() && frequency_hz > 0.0 && frequency_hz <= 70.0 {
        0x20
    } else if frequency_hz.is_finite() && frequency_hz >= 110.0 {
        0x00
    } else {
        0x40
    };
    report[3] = 0x03 | mode;
    report[5] = if amplitude.is_finite() {
        (amplitude.clamp(0.0, 1.0) * 255.0) as u8
    } else {
        0
    };
    report[18..22].copy_from_slice(&host_us.to_le_bytes());
    report[41] = counter;
    let crc = crc32(&[0xa2], &report[..OUTPUT_REPORT_LEN - 4]);
    report[OUTPUT_REPORT_LEN - 4..].copy_from_slice(&crc.to_le_bytes());
    report
}

/// Compose vibration and the same connection's most recently programmed LED
/// settings. LED settings have their own latch sequence: zeroing them in an
/// otherwise valid haptic packet is a new LED command, not an omitted field.
/// Match Monado's per-device output composition without advancing that latch.
/// `None` retains the standalone, not-yet-programmed output format.
pub fn vibration_report_retaining_led(
    sequence: u8,
    counter: u8,
    amplitude: f32,
    frequency_hz: f32,
    host_us: u32,
    programmed: Option<&[u8; OUTPUT_REPORT_LEN]>,
) -> Option<[u8; OUTPUT_REPORT_LEN]> {
    let mut report = vibration_report(sequence, counter, amplitude, frequency_hz, host_us);
    if let Some(programmed) = programmed {
        let checksum = u32::from_le_bytes(programmed[74..78].try_into().unwrap());
        if programmed[0] != 0x31
            || programmed[1] & 0x0f != 0
            || programmed[2] != 0x10
            || crc32(&[0xa2], &programmed[..74]) != checksum
        {
            return None;
        }
        // Only pssense_led_settings: phase, latch, duration, absolute/delta
        // position, cycle and four LED selectors. Keep fresh haptic flags,
        // amplitude, transport IDs and host timestamp from this output.
        report[22..37].copy_from_slice(&programmed[22..37]);
        let checksum = crc32(&[0xa2], &report[..74]);
        report[74..78].copy_from_slice(&checksum.to_le_bytes());
    }
    Some(report)
}

/// CRC-32 (the common reflected one) over `seed` then `data`, as the controller computes it.
fn crc32(seed: &[u8], data: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &byte in seed.iter().chain(data) {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

/// What turns raw IMU counts into rad/s and m/s².
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Calibration {
    pub gyro_bias: [f32; 3],
    pub gyro_scale: [f32; 3],
    pub accel_bias: [f32; 3],
    pub accel_scale: [f32; 3],
}

impl Default for Calibration {
    /// Close to the two controllers measured: 540°/s at 4420 counts, 1 g at 4080.
    fn default() -> Self {
        Calibration {
            gyro_bias: [0.0; 3],
            gyro_scale: [540f32.to_radians() / 4420.0; 3],
            accel_bias: [0.0; 3],
            accel_scale: [GRAVITY / 4080.0; 3],
        }
    }
}

impl Calibration {
    /// From the two feature reports (in either order), each as HID delivers it, report id first.
    /// `None` if either isn't a calibration report, fails its CRC or holds nonsense.
    pub fn parse(first: &[u8], second: &[u8]) -> Option<Calibration> {
        let mut data = [0u8; CALIBRATION_PART_LEN * 2];
        let mut seen = [false; 2];
        for report in [first, second] {
            if report.len() != CALIBRATION_REPORT_LEN || report[0] != CALIBRATION_REPORT_ID {
                return None;
            }
            let sent = u32::from_le_bytes([report[60], report[61], report[62], report[63]]);
            // Over USB the CRC is left zero.
            if sent != 0 && crc32(&[0xA3], &report[..60]) != sent {
                return None;
            }
            let part = match report[1] {
                0x00 => 0,
                0x81 => 1,
                _ => return None,
            };
            seen[part] = true;
            data[part * CALIBRATION_PART_LEN..(part + 1) * CALIBRATION_PART_LEN]
                .copy_from_slice(&report[2..2 + CALIBRATION_PART_LEN]);
        }
        if seen != [true, true] {
            return None;
        }
        let at = |i: usize| f32::from(i16::from_le_bytes([data[i], data[i + 1]]));
        let accel = [
            (at(0x00), at(0x06)),
            (at(0x0E), at(0x14)),
            (at(0x1C), at(0x22)),
        ];
        let gyro_bias = [at(0x24), at(0x26), at(0x28)];
        let gyro = [
            (at(0x2A), at(0x30)),
            (at(0x38), at(0x3E)),
            (at(0x46), at(0x4C)),
        ];
        let mut reference = ((at(0x4E) + at(0x50)) * 0.5).to_radians();
        if reference <= 0.0 {
            reference = std::f32::consts::PI * 3.0;
        }
        let mut c = Calibration {
            gyro_bias,
            ..Default::default()
        };
        for k in 0..3 {
            let span = ((gyro[k].0 - gyro_bias[k]).abs() + (gyro[k].1 - gyro_bias[k]).abs()) / 2.0;
            let bias = (accel[k].0 + accel[k].1) / 2.0;
            let reach = accel[k].0 - bias;
            if span < 1.0 || reach.abs() < 1.0 {
                return None;
            }
            c.gyro_scale[k] = reference / span;
            c.accel_bias[k] = bias;
            c.accel_scale[k] = GRAVITY / reach;
        }
        Some(c)
    }
}

/// How strongly the accelerometer pulls the orientation's "up" towards gravity, per second.
const GRAVITY_GAIN: f32 = 1.5;
/// The pull is only trusted while the controller is close to resting (1 g ± this, in g).
const GRAVITY_WINDOW: f32 = 0.15;

/// Below this rate (rad/s, about 2°/s) a controller at rest is taken to be still, and what its
/// gyro still reads is its bias: the left controller measured drifted 12° of heading a minute.
const STILL_RATE: f32 = 0.035;
/// How fast the bias estimate follows, per report.
const BIAS_GAIN: f32 = 0.02;

/// One controller: its newest inputs and its orientation.
#[derive(Debug, Clone)]
pub struct Controller {
    pub hand: Hand,
    calibration: Calibration,
    /// IMU axes to the tracking space, before the heading set by `recenter`.
    orientation: Quat,
    /// Turn about y applied on top (set by `recenter`).
    heading: f32,
    angular_velocity: Vec3,
    /// What the gyro reads while the controller is still, in rad/s (on top of the calibration's).
    gyro_trim: Vec3,
    last_ticks: Option<u32>,
    /// When the newest report was taken.
    taken: Option<std::time::Instant>,
    newest: Option<InputReport>,
    reports: u32,
    missed: u32,
    settled: bool,
    /// Where the controller is, from the cameras' fixes and the accelerometer (`tracking::place`).
    place: crate::tracking::place::PlaceFilter,
    /// What turns the controller's tracking space into the room's, about y (radians): the
    /// cameras see where it really points. None until they have: the accelerometer's sideways
    /// part can't be put in the room's frame without it, and is then left out.
    room_yaw: Option<f32>,
    /// The controller's own clock since its first report (s), and what is added to it for the
    /// host's: the least seen of arrival minus that clock, so a report held up on its way
    /// doesn't count as taken late.
    device_s: f64,
    clock_offset: Option<f64>,
    orientation_history: OrientationHistory,
}

impl Controller {
    pub fn new(hand: Hand) -> Controller {
        Controller {
            hand,
            calibration: Calibration::default(),
            orientation: Quat::IDENTITY,
            heading: 0.0,
            angular_velocity: [0.0; 3],
            gyro_trim: [0.0; 3],
            last_ticks: None,
            taken: None,
            newest: None,
            reports: 0,
            missed: 0,
            settled: false,
            place: Default::default(),
            room_yaw: None,
            device_s: 0.0,
            clock_offset: None,
            orientation_history: OrientationHistory::new(),
        }
    }

    pub fn set_calibration(&mut self, calibration: Calibration) {
        self.calibration = calibration;
        self.orientation_history.reset();
    }

    /// Takes one input report (report id first). Returns the parsed report.
    pub fn ingest(&mut self, bytes: &[u8]) -> Result<InputReport, ReportError> {
        let report = InputReport::parse(self.hand, bytes)?;
        if let Some(prev) = self.newest {
            let step = report.sequence.wrapping_sub(prev.sequence);
            if step > 1 && step < 1000 {
                self.missed += step - 1;
            }
        }
        let c = &self.calibration;
        let gyro: Vec3 =
            [0, 1, 2].map(|k| (f32::from(report.gyro_raw[k]) - c.gyro_bias[k]) * c.gyro_scale[k]);
        let accel: Vec3 = [0, 1, 2]
            .map(|k| (f32::from(report.accel_raw[k]) - c.accel_bias[k]) * c.accel_scale[k]);
        let dt = match self.last_ticks {
            Some(last) => (f64::from(report.imu_ticks.wrapping_sub(last)) * IMU_TICK_S) as f32,
            None => 0.0,
        };
        self.last_ticks = Some(report.imu_ticks);
        let resting = (crate::math::length(accel) / GRAVITY - 1.0).abs() < GRAVITY_WINDOW;
        let gyro = crate::math::sub(gyro, self.gyro_trim);
        if resting && crate::math::length(gyro) < STILL_RATE {
            self.gyro_trim = crate::math::add(self.gyro_trim, crate::math::scale(gyro, BIAS_GAIN));
        }
        self.fuse(gyro, accel, dt);
        self.feed_place(accel, dt);
        self.angular_velocity = gyro;
        self.taken = Some(std::time::Instant::now());
        self.newest = Some(report);
        self.reports = self.reports.wrapping_add(1);
        Ok(report)
    }

    /// The accelerometer's sample to the place filter: in the room's frame, gravity taken off,
    /// at the host's time for the moment it was taken.
    fn feed_place(&mut self, accel: Vec3, dt: f32) {
        if dt > 0.25 {
            // A gap: the clocks are matched again, and nothing is carried across it.
            self.clock_offset = None;
            self.orientation_history.reset();
            self.place.reset();
        }
        // A duplicate timestamp is not a new clock epoch. Keeping the existing
        // minimum offset also makes the position filter ignore that repeated
        // sample, rather than moving its clock forward by transport delay.
        self.device_s += f64::from(dt.max(0.0));
        let arrived = crate::time::host_time_ns() as f64 * 1e-9;
        let offset = arrived - self.device_s;
        // The least offset is the report that came through fastest; it is let rise slowly
        // (0.2 ms a second) so the two clocks' drift is followed.
        let kept = self
            .clock_offset
            .map_or(offset, |o| (o + 0.0002 * f64::from(dt)).min(offset));
        self.clock_offset = Some(kept);
        if self.settled {
            self.orientation_history
                .push_device_time((self.device_s * 1e9).round() as i64, self.orientation);
        }
        let (Some(yaw), true) = (self.room_yaw, self.settled) else {
            return;
        };
        let room = Quat::from_axis_angle([0.0, 1.0, 0.0], yaw) * self.orientation();
        let a = room.rotate(accel);
        self.place
            .sample(self.device_s + kept, [a[0], a[1] - GRAVITY, a[2]]);
    }

    /// The cameras see where the controller really points: `yaw` (radians about y) on top of its
    /// own orientation gives the room's.
    pub fn set_room_yaw(&mut self, yaw: f32) {
        self.room_yaw = Some(yaw);
    }

    /// The cameras saw the controller at `place` (m, the room's frame) at host time `ns`.
    pub fn place_fix(&mut self, ns: i64, place: Vec3) {
        self.place.fix(ns as f64 * 1e-9, place);
    }

    /// Where the controller is at host time `ns`, and its velocity (m, m/s; the room's frame).
    pub fn place(&self, ns: i64) -> Option<(Vec3, Vec3)> {
        self.place.place(ns as f64 * 1e-9)
    }

    /// Forgets where the controller was (the room's frame changed).
    pub fn reset_place(&mut self) {
        self.place.reset();
    }

    /// Gyro integration with the accelerometer keeping "up" true (a complementary filter).
    fn fuse(&mut self, gyro: Vec3, accel: Vec3, dt: f32) {
        let g = crate::math::length(accel);
        let resting = (g / GRAVITY - 1.0).abs() < GRAVITY_WINDOW;
        if !self.settled {
            // The first report at rest gives "up" at once, with no heading.
            if resting {
                let up = crate::math::scale(accel, 1.0 / g);
                self.orientation = rotation_between(up, [0.0, 1.0, 0.0]);
                self.settled = true;
            }
            return;
        }
        // A gap (the controller slept, reports were lost) is not integrated across.
        if dt <= 0.0 || dt > 0.25 {
            return;
        }
        let mut rate = gyro;
        if resting {
            // Where the orientation says up is, in the controller's own axes, against where the
            // accelerometer says it is: turn towards the latter.
            let expected = self.orientation.conjugate().rotate([0.0, 1.0, 0.0]);
            let measured = crate::math::scale(accel, 1.0 / g);
            let error = crate::math::cross(measured, expected);
            rate = crate::math::add(rate, crate::math::scale(error, GRAVITY_GAIN));
        }
        let step = Quat::from_rotation_vector(crate::math::scale(rate, dt));
        self.orientation = (self.orientation * step).normalized();
    }

    /// The controller's orientation in the tracking space (x right, y up, −z forward).
    pub fn orientation(&self) -> Quat {
        Quat::from_axis_angle([0.0, 1.0, 0.0], self.heading) * self.orientation
    }

    /// A bracketed sensor orientation at a camera exposure in the existing
    /// common host clock. No latest-pose fallback and no extra prediction/wait.
    pub fn orientation_at_host_ns(&self, exposure_ns: i64) -> Option<Quat> {
        let offset = (self.clock_offset? * 1e9).round() as i64;
        let q = self
            .orientation_history
            .sample_host_time(exposure_ns, offset)?;
        Some(Quat::from_axis_angle([0., 1., 0.], self.heading) * q)
    }

    /// Makes the direction the controller points now (its −z, flattened) the heading `yaw`
    /// (radians about y; 0 is the tracking space's forward).
    pub fn recenter(&mut self, yaw: f32) {
        self.orientation_history.reset();
        self.heading = yaw - self.orientation.yaw();
    }

    /// Angular velocity in rad/s, in the controller's own axes.
    pub fn angular_velocity(&self) -> Vec3 {
        self.angular_velocity
    }

    /// Seconds since the newest report was taken (to carry the orientation forward from it).
    pub fn age(&self) -> f32 {
        self.taken.map_or(0.0, |t| t.elapsed().as_secs_f32())
    }

    /// Sensor sample time on the same monotonic host clock as camera exposures.
    /// Unlike `age`, this includes the existing minimum-transport clock mapping.
    /// It is not the time the Bluetooth callback happened to deliver the report.
    pub fn sample_host_ns(&self) -> Option<i64> {
        self.newest?;
        let time = (self.device_s + self.clock_offset?) * 1e9;
        (time.is_finite() && time > 0. && time < i64::MAX as f64).then(|| time.round() as i64)
    }

    pub fn newest(&self) -> Option<InputReport> {
        self.newest
    }

    /// Reports taken so far, and reports the sequence numbers show were lost.
    pub fn counts(&self) -> (u32, u32) {
        (self.reports, self.missed)
    }

    /// False until a report at rest has given the orientation its "up".
    pub fn is_settled(&self) -> bool {
        self.settled
    }
}

/// The shortest rotation taking unit vector `from` to unit vector `to`.
fn rotation_between(from: Vec3, to: Vec3) -> Quat {
    let axis = crate::math::cross(from, to);
    let sin = crate::math::length(axis);
    let cos = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
    if sin < 1e-6 {
        return if cos > 0.0 {
            Quat::IDENTITY
        } else {
            Quat::from_axis_angle([1.0, 0.0, 0.0], std::f32::consts::PI)
        };
    }
    Quat::from_axis_angle(crate::math::scale(axis, 1.0 / sin), sin.atan2(cos))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    /// Reports captured from two controllers over Bluetooth, lying still.
    const RIGHT: &str = "31 c1 80 82 00 00 00 00 01 00 00 00 00 2d 68 44 8b ff ff 01 00 f9 ff 88 fd 9f 0a 21 f4 f5 bf 8d 0b fe 00 00 00 00 00 00 00 09 00 06 00 02 00 00 00 b4 1c 8e 0b 01 00 00 00 36 3c 39 1e fe da a6 90 00 00 00 00 00 00 00 00 00 45 e6 3d 97";
    const LEFT: &str = "31 01 80 7d 00 00 00 00 01 00 00 00 00 01 af 8e 9f 02 00 00 00 fa ff 03 02 8d 0a e0 f3 42 a5 f8 0d 01 00 00 00 00 00 00 00 09 00 06 00 02 00 00 00 37 02 f9 0d 01 00 00 00 43 c2 cd 0a 4e aa d5 84 00 00 00 00 00 00 00 00 00 e2 00 a2 5d";
    const RIGHT_CAL: [&str; 2] = [
        "05 00 ef 0f 00 00 50 ff f9 ef 09 00 6e 00 f5 ff 00 10 f3 ff f6 ff 0a f0 d2 ff 88 00 e7 ff d4 0f 64 ff 17 00 e4 ef 01 00 00 00 f9 ff 44 11 0b 00 48 ff be ee f5 ff a9 00 fa ff 51 11 f1 39 f0 a4",
        "05 81 f9 ff 08 00 b2 ee f9 ff 7d 00 ed ff 48 11 84 ff 13 00 a9 ee 1c 02 1c 02 06 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 05 e5 99 71",
    ];

    #[test]
    fn a_captured_report_parses() {
        let r = InputReport::parse(Hand::Right, &hex(RIGHT)).unwrap();
        assert_eq!(r.buttons, 0);
        assert_eq!(r.trigger, 0.0);
        assert!(r.stick[0].abs() < 0.05 && r.stick[1].abs() < 0.05);
        assert_eq!(r.sequence, 0x8b44_682d);
        assert_eq!(r.gyro_raw, [-1, 1, -7]);
        assert_eq!(r.accel_raw, [-632, 2719, -3039]);
        assert_eq!(r.battery_percent, 65);
        assert!(!r.charging);
        let l = InputReport::parse(Hand::Left, &hex(LEFT)).unwrap();
        assert_eq!(l.accel_raw, [515, 2701, -3104]);
    }

    #[test]
    fn the_polling_rate_report_is_checksummed() {
        let r = polling_rate_report();
        assert_eq!(&r[..6], &[0x08, 0x0E, 0x0C, 0x00, 0x02, 0x00]);
        assert_eq!(crc32(&[0x53], &r[..44]).to_le_bytes(), r[44..]);
        // The CRC itself, against the standard check value.
        assert_eq!(crc32(&[], b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn an_led_report_is_laid_out_as_the_controller_expects() {
        let blink = LedBlink {
            phase: led_phase::ALL_ON,
            sequence: 9,
            period_id: 42,
            cycle_position: 0x0807_0605,
            cycle_length: 50_000_000,
        };
        let r = led_report(0x13, 7, blink, 0x0403_0201);
        assert_eq!(&r[23..33], &[9, 42, 5, 6, 7, 8, 0x80, 0xF0, 0xFA, 0x02]);
        assert_eq!(&r[..3], &[0x31, 0x30, 0x10]);
        assert_eq!(&r[18..22], &[1, 2, 3, 4]);
        assert_eq!(r[22], 6);
        assert_eq!(&r[33..37], &[0xFF; 4]);
        assert_eq!(r[41], 7);
        assert_eq!(crc32(&[0xA2], &r[..74]).to_le_bytes(), r[74..]);
    }

    #[test]
    fn documented_vibration_modes_and_golden_bluetooth_report() {
        let report = vibration_report(0x13, 7, 0.5, 60.0, 0x0403_0201);
        assert_eq!(&report[..8], &[0x31, 0x30, 0x10, 0x23, 0, 127, 0, 0]);
        assert_eq!(&report[18..22], &[1, 2, 3, 4]);
        assert_eq!(report[41], 7);
        // Independent standard CRC-32/zlib vector over A2 followed by the
        // documented report bytes, rather than calling the encoder's CRC.
        assert_eq!(&report[74..], &[0x37, 0x08, 0xe1, 0x44]);
        assert!(report[22..41].iter().all(|b| *b == 0)); // standalone, no retained LED configuration
        assert_eq!(vibration_report(0, 0, 1.0, 120.0, 0)[3], 0x03);
        assert_eq!(vibration_report(0, 0, 1.0, 90.0, 0)[3], 0x43);
        assert_eq!(vibration_report(0, 0, 1.0, 0.0, 0)[3], 0x43);
        assert_eq!(vibration_report(0, 0, 0.0, 160.0, 0)[5], 0);
        assert_eq!(vibration_report(0, 0, f32::NAN, 160.0, 0)[5], 0);
    }

    #[test]
    fn vibration_retains_led_latch_without_replacing_haptic_transport() {
        let blink = LedBlink {
            phase: led_phase::PRESCAN,
            sequence: 255,
            period_id: 42,
            cycle_position: 0xfedc_ba98,
            cycle_length: 50_050_000,
        };
        let led = led_report(3, 7, blink, 123);
        let standalone = vibration_report(4, 8, 0.5, 60.0, 456);
        assert_eq!(standalone[23], 0); // This would change the device's LED latch.
        let kept = vibration_report_retaining_led(4, 8, 0.5, 60.0, 456, Some(&led)).unwrap();
        assert_eq!(&kept[22..37], &led[22..37]);
        for i in (0..22).chain(37..74) {
            assert_eq!(kept[i], standalone[i]);
        }
        assert_eq!(
            u32::from_le_bytes(kept[74..78].try_into().unwrap()),
            crc32(&[0xa2], &kept[..74])
        );
        let stopped = vibration_report_retaining_led(5, 9, 0.0, 0.0, 789, Some(&led)).unwrap();
        assert_eq!(stopped[5], 0);
        assert_eq!(&stopped[22..37], &led[22..37]);
        assert_eq!(
            vibration_report_retaining_led(4, 8, 0.5, 60.0, 456, None),
            Some(standalone)
        );
        let mut damaged = led;
        damaged[22] ^= 1;
        assert!(vibration_report_retaining_led(4, 8, 0.5, 60.0, 456, Some(&damaged)).is_none());
        let mut wrong_mode = led;
        wrong_mode[1] |= 1;
        let checksum = crc32(&[0xa2], &wrong_mode[..74]);
        wrong_mode[74..78].copy_from_slice(&checksum.to_le_bytes());
        assert!(vibration_report_retaining_led(4, 8, 0.5, 60.0, 456, Some(&wrong_mode)).is_none());
    }

    #[test]
    fn a_damaged_report_is_refused() {
        let mut bytes = hex(RIGHT);
        bytes[4] = 0xFF; // a trigger pull the CRC doesn't cover
        assert_eq!(
            InputReport::parse(Hand::Right, &bytes),
            Err(ReportError::BadChecksum)
        );
        assert_eq!(
            InputReport::parse(Hand::Right, &bytes[..40]),
            Err(ReportError::NotAnInputReport)
        );
    }

    /// A Bluetooth report with the given inputs and a right CRC.
    fn report(
        hand_buttons: [u8; 3],
        trigger: u8,
        gyro: [i16; 3],
        accel: [i16; 3],
        ticks: u32,
        seq: u32,
    ) -> Vec<u8> {
        let mut b = vec![0u8; REPORT_LEN_BLUETOOTH];
        b[0] = REPORT_ID_BLUETOOTH;
        b[2] = 128;
        b[3] = 128;
        b[4] = trigger;
        b[9..12].copy_from_slice(&hand_buttons);
        b[13..17].copy_from_slice(&seq.to_le_bytes());
        for k in 0..3 {
            b[17 + k * 2..19 + k * 2].copy_from_slice(&gyro[k].to_le_bytes());
            b[23 + k * 2..25 + k * 2].copy_from_slice(&accel[k].to_le_bytes());
        }
        b[29..33].copy_from_slice(&ticks.to_le_bytes());
        b[43] = 0x1A; // charging, full
        let crc = crc32(&[0xA1], &b[..74]);
        b[74..78].copy_from_slice(&crc.to_le_bytes());
        b
    }

    #[test]
    fn analog_trigger_travel_is_independent_of_digital_click_for_both_hands() {
        for (hand, click_bit) in [(Hand::Left, 0x40), (Hand::Right, 0x80)] {
            for pressure in [0u8, 64, 153, 191, 255] {
                for clicked in [false, true] {
                    let input = InputReport::parse(
                        hand,
                        &report(
                            [if clicked { click_bit } else { 0 }, 0, 0],
                            pressure,
                            [0; 3],
                            [0; 3],
                            0,
                            0,
                        ),
                    )
                    .unwrap();
                    assert_eq!(input.trigger, f32::from(pressure) / 255.0);
                    assert_eq!(
                        input.buttons & buttons::TRIGGER != 0,
                        clicked,
                        "digital contact must not overwrite the independent HID travel byte"
                    );
                }
            }
        }
    }

    #[test]
    fn buttons_are_the_same_bits_for_both_hands() {
        // Left: trigger click, grip click, square, triangle, Create, stick click.
        let l = InputReport::parse(
            Hand::Left,
            &report(
                [0x40 | 0x10 | 0x01 | 0x08, 0x01 | 0x04, 0],
                255,
                [0; 3],
                [0; 3],
                0,
                0,
            ),
        )
        .unwrap();
        // Right: the same, with cross, circle and Options.
        let r = InputReport::parse(
            Hand::Right,
            &report(
                [0x80 | 0x20 | 0x02 | 0x04, 0x02 | 0x08, 0],
                255,
                [0; 3],
                [0; 3],
                0,
                0,
            ),
        )
        .unwrap();
        let all = buttons::TRIGGER
            | buttons::GRIP
            | buttons::LOWER
            | buttons::UPPER
            | buttons::MENU
            | buttons::STICK;
        assert_eq!(l.buttons, all);
        assert_eq!(r.buttons, all);
        assert_eq!(l.trigger, 1.0);
        assert!(l.charging && l.battery_percent == 100);
        let touch = InputReport::parse(
            Hand::Right,
            &report([0, 0x80 | 0x10, 0x0F], 0, [0; 3], [0; 3], 0, 0),
        )
        .unwrap();
        assert_eq!(
            touch.buttons,
            buttons::PS
                | buttons::TRIGGER_TOUCH
                | buttons::GRIP_TOUCH
                | buttons::STICK_TOUCH
                | buttons::LOWER_TOUCH
                | buttons::UPPER_TOUCH
        );
    }

    #[test]
    fn the_captured_calibration_parses() {
        let c = Calibration::parse(&hex(RIGHT_CAL[0]), &hex(RIGHT_CAL[1])).unwrap();
        // In the other order too.
        assert_eq!(
            Calibration::parse(&hex(RIGHT_CAL[1]), &hex(RIGHT_CAL[0])),
            Some(c)
        );
        // 540°/s over about 4420 counts; 1 g over about 4090.
        for k in 0..3 {
            assert!(
                (c.gyro_scale[k] - 540f32.to_radians() / 4420.0).abs() < 2e-5,
                "{c:?}"
            );
            assert!((c.accel_scale[k] - GRAVITY / 4090.0).abs() < 2e-5, "{c:?}");
            assert!(c.gyro_bias[k].abs() < 20.0 && c.accel_bias[k].abs() < 60.0);
        }
        let mut bad = hex(RIGHT_CAL[0]);
        bad[10] ^= 1;
        assert_eq!(Calibration::parse(&bad, &hex(RIGHT_CAL[1])), None);
        assert_eq!(
            Calibration::parse(&hex(RIGHT_CAL[0]), &hex(RIGHT_CAL[0])),
            None
        );
    }

    /// Counts for a rate in rad/s and for 1 g, with the default calibration.
    fn counts(rate: f32) -> i16 {
        (rate / Calibration::default().gyro_scale[0]).round() as i16
    }
    const ONE_G: i16 = 4080;

    #[test]
    fn exposure_orientation_history_uses_current_clock_offset_without_changing_live_pose() {
        for hand in [Hand::Left, Hand::Right] {
            let mut c = Controller::new(hand);
            c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 0, 0))
                .unwrap();
            let first = c.orientation;
            c.ingest(&report(
                [0; 3],
                0,
                [0, counts(1.), 0],
                [0, ONE_G, 0],
                50_000,
                1,
            ))
            .unwrap();
            let current = c.orientation();
            let device = (c.device_s * 1e9).round() as i64 / 2;
            let offset = (c.clock_offset.unwrap() * 1e9).round() as i64;
            let expected = crate::sense_orientation_history::between(
                (0, first),
                ((c.device_s * 1e9).round() as i64, c.orientation),
                device,
            )
            .unwrap();
            let sampled = c.orientation_at_host_ns(device + offset).unwrap();
            assert!(sampled.angle_to(expected) < 1e-5);
            assert_eq!(
                c.orientation(),
                current,
                "Historical lookup cannot change the current game pose"
            );
            // A lower transport estimate must rebase every sample consistently.
            c.clock_offset = Some(c.clock_offset.unwrap() - 0.01);
            let shifted = (c.clock_offset.unwrap() * 1e9).round() as i64;
            assert!(
                c.orientation_at_host_ns(device + shifted)
                    .unwrap()
                    .angle_to(expected)
                    < 1e-5
            );
            c.recenter(0.4);
            assert!(c.orientation_at_host_ns(device + shifted).is_none());
            c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 100_000, 2))
                .unwrap();
            let now =
                (c.device_s * 1e9).round() as i64 + (c.clock_offset.unwrap() * 1e9).round() as i64;
            assert_eq!(c.orientation_at_host_ns(now), Some(c.orientation()));
            let unchanged = c.orientation();
            c.set_calibration(Calibration::default());
            assert!(c.orientation_at_host_ns(now).is_none());
            assert_eq!(c.orientation(), unchanged);
        }
    }

    #[test]
    fn exposure_orientation_history_retires_device_clock_gaps_and_resets() {
        let mut c = Controller::new(Hand::Left);
        for i in 0..4 {
            c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], i * 50_000, i))
                .unwrap();
        }
        let old_device = (c.device_s * 1e9).round() as i64;
        c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 1, 5))
            .unwrap(); // device clock reset
        let offset = (c.clock_offset.unwrap() * 1e9).round() as i64;
        assert!(
            c.orientation_history
                .sample_host_time(old_device + offset, offset)
                .is_none()
        );
        let current = (c.device_s * 1e9).round() as i64;
        assert!(
            c.orientation_history
                .sample_host_time(current + offset, offset)
                .is_some()
        );
        c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 3_000_001, 6))
            .unwrap(); // >250ms gap
        let offset = (c.clock_offset.unwrap() * 1e9).round() as i64;
        assert!(
            c.orientation_history
                .sample_host_time(current + offset, offset)
                .is_none()
        );
    }

    #[test]
    fn exposure_orientation_duplicate_report_keeps_the_clock_and_existing_bracket() {
        let mut c = Controller::new(Hand::Right);
        c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 0, 0))
            .unwrap();
        c.ingest(&report(
            [0; 3],
            0,
            [0, counts(1.), 0],
            [0, ONE_G, 0],
            50_000,
            1,
        ))
        .unwrap();
        let offset = c.clock_offset;
        let offset_ns = (offset.unwrap() * 1e9).round() as i64;
        let device = (c.device_s * 1e9).round() as i64 / 2;
        let expected = c.orientation_at_host_ns(device + offset_ns).unwrap();
        c.ingest(&report(
            [0; 3],
            0,
            [0, counts(1.), 0],
            [0, ONE_G, 0],
            50_000,
            1,
        ))
        .unwrap();
        assert_eq!(
            c.clock_offset, offset,
            "Duplicate device time cannot become a transport-offset reset"
        );
        assert_eq!(c.orientation_at_host_ns(device + offset_ns), Some(expected));
    }

    #[test]
    fn exposure_orientation_device_tick_wrap_keeps_one_unwrapped_history() {
        let mut c = Controller::new(Hand::Left);
        c.ingest(&report(
            [0; 3],
            0,
            [0; 3],
            [0, ONE_G, 0],
            u32::MAX - 50_000,
            0,
        ))
        .unwrap();
        c.ingest(&report([0; 3], 0, [0, counts(1.), 0], [0, ONE_G, 0], 1, 1))
            .unwrap();
        assert!(c.device_s > 0. && c.device_s < 0.02);
        let device = (c.device_s * 1e9).round() as i64 / 2;
        let offset = (c.clock_offset.unwrap() * 1e9).round() as i64;
        assert!(
            c.orientation_history
                .sample_host_time(device + offset, offset)
                .is_some(),
            "A normal wrapping hardware counter is not a reconnect/reset epoch"
        );
    }

    #[test]
    fn at_rest_up_is_found_and_kept() {
        let mut c = Controller::new(Hand::Right);
        // Lying tilted: gravity's reaction along y and −z, as in the captured report.
        for i in 0..120u32 {
            c.ingest(&report([0; 3], 0, [0; 3], [0, 2885, -2885], i * 50_000, i))
                .unwrap();
        }
        assert!(c.is_settled());
        // The controller's (0, 1, −1)/√2 is the world's up.
        let up = c.orientation().rotate([
            0.0,
            std::f32::consts::FRAC_1_SQRT_2,
            -std::f32::consts::FRAC_1_SQRT_2,
        ]);
        assert!((up[1] - 1.0).abs() < 1e-3, "{up:?}");
    }

    #[test]
    fn a_turn_is_integrated_and_recentered() {
        let mut c = Controller::new(Hand::Left);
        let mut seq = 0;
        let mut feed = |c: &mut Controller, gyro: [i16; 3], n: u32| {
            for _ in 0..n {
                seq += 1;
                // 60 reports a second: 50 000 ticks apart.
                c.ingest(&report([0; 3], 0, gyro, [0, ONE_G, 0], seq * 50_000, seq))
                    .unwrap();
            }
        };
        feed(&mut c, [0; 3], 10);
        // 90° to the left about y in one second.
        feed(&mut c, [0, counts(std::f32::consts::FRAC_PI_2), 0], 60);
        let forward = c.orientation().rotate([0.0, 0.0, -1.0]);
        assert!(
            (forward[0] + 1.0).abs() < 0.02 && forward[2].abs() < 0.02,
            "{forward:?}"
        );
        assert!((c.angular_velocity()[1] - std::f32::consts::FRAC_PI_2).abs() < 0.01);
        // Recentered, where it points now is straight ahead.
        c.recenter(0.0);
        let forward = c.orientation().rotate([0.0, 0.0, -1.0]);
        assert!(
            forward[0].abs() < 0.02 && (forward[2] + 1.0).abs() < 0.02,
            "{forward:?}"
        );
        assert_eq!(c.counts(), (70, 0));
    }

    #[test]
    fn a_still_controller_stops_drifting() {
        let mut c = Controller::new(Hand::Left);
        // A bias of about 0.6°/s about y, for five seconds, then a minute more.
        let bias = [0, counts(0.01), 0];
        for i in 0..300u32 {
            c.ingest(&report([0; 3], 0, bias, [0, ONE_G, 0], i * 50_000, i))
                .unwrap();
        }
        let before = c.orientation().yaw();
        for i in 300..3900u32 {
            c.ingest(&report([0; 3], 0, bias, [0, ONE_G, 0], i * 50_000, i))
                .unwrap();
        }
        let drift = (c.orientation().yaw() - before).to_degrees().abs();
        assert!(drift < 0.5, "{drift}° in a minute (36° unchecked)");
    }

    #[test]
    fn lost_reports_are_counted_and_gaps_not_integrated() {
        let mut c = Controller::new(Hand::Right);
        c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 0, 1))
            .unwrap();
        c.ingest(&report([0; 3], 0, [0; 3], [0, ONE_G, 0], 50_000, 2))
            .unwrap();
        // Three reports lost, then a spin reported across two seconds of silence.
        c.ingest(&report(
            [0; 3],
            0,
            [0, counts(3.0), 0],
            [0, ONE_G, 0],
            6_050_000,
            6,
        ))
        .unwrap();
        assert_eq!(c.counts(), (3, 3));
        let forward = c.orientation().rotate([0.0, 0.0, -1.0]);
        assert!((forward[2] + 1.0).abs() < 1e-3, "{forward:?}");
    }
    #[test]
    fn mapped_sample_timestamp_is_sensor_time_not_callback_age() {
        let mut c = Controller::new(Hand::Right);
        assert_eq!(c.sample_host_ns(), None);
        c.ingest(&hex(RIGHT)).unwrap();
        c.device_s = 12.25;
        c.clock_offset = Some(1000.5);
        assert_eq!(c.sample_host_ns(), Some(1_012_750_000_000));
        c.clock_offset = Some(f64::NAN);
        assert_eq!(c.sample_host_ns(), None);
        c.clock_offset = None;
        assert_eq!(c.sample_host_ns(), None);
    }
}
