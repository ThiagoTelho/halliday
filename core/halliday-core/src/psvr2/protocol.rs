//! PS VR2 USB protocol: endpoint map, packet layouts and parsers.
//!
//! Ported from Monado's `psvr2` driver (`psvr2_protocol.h`, `psvr2.c`; BSL-1.0, authors Jan Schmidt,
//! Joel Valenciano, Beyley Cardellio) and cross-checked against GAV PSVR2 Player's `cpsvr2.c` (MIT),
//! which runs this protocol on macOS. See THIRD-PARTY.md.
//!
//! Everything here is pure parsing: no I/O, so it is unit tested without a headset. All multi-byte
//! fields are little-endian.

use thiserror::Error;

// --- Interfaces and endpoints -------------------------------------------------------------------

/// Headset-computed SLAM pose stream (bulk IN).
pub const SLAM_INTERFACE: u8 = 3;
pub const SLAM_ENDPOINT: u8 = 0x83;

/// Eye-gaze stream (bulk IN). Not used yet.
pub const GAZE_INTERFACE: u8 = 5;
pub const GAZE_ENDPOINT: u8 = 0x85;

/// Camera stream (bulk IN). Not used yet.
pub const CAMERA_INTERFACE: u8 = 6;
pub const CAMERA_ENDPOINT: u8 = 0x87;

/// Status + IMU stream (interrupt IN). Only exists in alternate setting 1, and only on a
/// high-speed-or-better link: at full speed (USB 2 hub or cable) alt setting 1 is missing.
pub const STATUS_INTERFACE: u8 = 7;
pub const STATUS_ALT_SETTING: u8 = 1;
pub const STATUS_ENDPOINT: u8 = 0x88;

/// Buffer size for a single SLAM or status read.
pub const READ_BUFFER_SIZE: usize = 1024;

// --- Control requests ---------------------------------------------------------------------------

/// `bRequest` for vendor control reads.
pub const CONTROL_GET_REQUEST: u8 = 0x01;
/// `bRequest` for vendor control writes.
pub const CONTROL_SET_REQUEST: u8 = 0x09;

/// Report ids used with the control requests (`wValue`).
pub mod report {
    pub const SET_PERIPHERAL: u16 = 0x08;
    pub const SET_CAMERA_MODE: u16 = 0x0B;
    pub const SET_GAZE_STREAM: u16 = 0x0C;
    pub const SET_GAZE_USER_CALIBRATION: u16 = 0x0D;
    pub const SET_BRIGHTNESS: u16 = 0x12;
    /// Not a report to ask for: a GET of 0x80 was never answered, and the headset
    /// then refused its interfaces and dropped off USB until it was unplugged. Don't scan the
    /// GET range for unknown reports.
    pub const GET_FIRMWARE_INFO: u16 = 0x81;
    pub const GET_DISTORTION_CALIBRATION: u16 = 0x8F;
}

/// Size of the control packet header (report id, sub-command, payload length).
pub const CONTROL_HEADER_SIZE: usize = 8;
/// Maximum control payload (the packet is 512 bytes in total).
pub const CONTROL_MAX_PAYLOAD: usize = 512 - CONTROL_HEADER_SIZE;

/// Encodes a control packet: `report_id: u16, subcmd: u16, len: u32, data`.
pub fn encode_control(report_id: u16, subcmd: u16, payload: &[u8]) -> Result<Vec<u8>, ParseError> {
    if payload.len() > CONTROL_MAX_PAYLOAD {
        return Err(ParseError::TooLong {
            max: CONTROL_MAX_PAYLOAD,
            got: payload.len(),
        });
    }
    let mut pkt = Vec::with_capacity(CONTROL_HEADER_SIZE + payload.len());
    pkt.extend_from_slice(&report_id.to_le_bytes());
    pkt.extend_from_slice(&subcmd.to_le_bytes());
    pkt.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    pkt.extend_from_slice(payload);
    Ok(pkt)
}

/// Payload of a brightness command: `brightness` in 0..=1 maps to the panel's 0..=31 steps.
pub fn brightness_payload(brightness: f32) -> [u8; 1] {
    [(brightness.clamp(0.0, 1.0) * 31.0) as u8]
}

// --- Errors -------------------------------------------------------------------------------------

#[derive(Debug, Error, PartialEq, Eq)]
pub enum ParseError {
    #[error("packet too short: need {need} bytes, got {got}")]
    TooShort { need: usize, got: usize },
    #[error("payload too long: max {max} bytes, got {got}")]
    TooLong { max: usize, got: usize },
    #[error("bad packet signature")]
    BadSignature,
}

fn need(buf: &[u8], n: usize) -> Result<(), ParseError> {
    if buf.len() < n {
        Err(ParseError::TooShort {
            need: n,
            got: buf.len(),
        })
    } else {
        Ok(())
    }
}

fn u16_at(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn i16_at(b: &[u8], o: usize) -> i16 {
    i16::from_le_bytes([b[o], b[o + 1]])
}
fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn f32_at(b: &[u8], o: usize) -> f32 {
    f32::from_bits(u32_at(b, o))
}

// --- Math types ---------------------------------------------------------------------------------

pub use crate::math::Quat;

// --- Status + IMU stream ------------------------------------------------------------------------

/// Status header at the start of every status-stream packet.
pub const STATUS_HEADER_SIZE: usize = 32;
/// One IMU record following the status header.
pub const IMU_RECORD_SIZE: usize = 24;

/// Gyro full scale: ±2000 °/s.
pub const GYRO_SCALE_DEG_S: f32 = 2000.0 / 32767.0;
/// Accelerometer full scale: ±4 g.
pub const ACCEL_SCALE_M_S2: f32 = 4.0 * 9.80665 / 32767.0;
/// IMU sample rate.
pub const IMU_RATE_HZ: f32 = 2000.0;

/// A status-stream packet: headset state plus a batch of IMU samples.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusReport {
    /// DisplayPort receiver status (0 = not ready).
    pub dprx_status: u8,
    /// Proximity sensor: the headset is being worn.
    pub worn: bool,
    /// Fn button on the underside of the visor.
    pub function_button: bool,
    /// IPD dial, 59..=72 mm.
    pub ipd_mm: u8,
    pub imu: Vec<ImuRecord>,
}

/// One raw IMU record, in the headset's own axes.
///
/// Samples are nominally 2000 Hz but USB reports can regroup them. Bit 0 of `status` marks the
/// early half-cycle; when clear, the sample is 500 us later than its `vts_us` label. Common early/
/// late pairs share VTS, but consecutive late samples can have different VTS labels: do not infer
/// phase from packet size or equality with the previous record. `imu_ts_us` is a separate precise
/// wrapping 16-bit clock; its long-run rate must not be assumed identical to SLAM's VTS domain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ImuRecord {
    /// Timestamp on the VTS timeline, shared with SLAM poses.
    pub vts_us: u32,
    pub accel: [i16; 3],
    pub gyro: [i16; 3],
    /// Display frame and line counters: where scanout was when the sample was taken.
    pub dp_frame_count: u16,
    pub dp_line_count: u16,
    /// Wrapping 16-bit microsecond IMU clock.
    pub imu_ts_us: u16,
    pub status: u16,
}

impl ImuRecord {
    fn parse(b: &[u8]) -> ImuRecord {
        ImuRecord {
            vts_us: u32_at(b, 0),
            accel: [i16_at(b, 4), i16_at(b, 6), i16_at(b, 8)],
            gyro: [i16_at(b, 10), i16_at(b, 12), i16_at(b, 14)],
            dp_frame_count: u16_at(b, 16),
            dp_line_count: u16_at(b, 18),
            imu_ts_us: u16_at(b, 20),
            status: u16_at(b, 22),
        }
    }

    /// Angular velocity in rad/s, in tracking axes (x right, y up, -z forward), as Monado maps it.
    pub fn gyro_rad_s(&self) -> [f32; 3] {
        let s = GYRO_SCALE_DEG_S.to_radians();
        [
            -(self.gyro[1] as f32) * s,
            (self.gyro[2] as f32) * s,
            -(self.gyro[0] as f32) * s,
        ]
    }

    /// Acceleration in m/s², in tracking axes, as Monado maps it.
    pub fn accel_m_s2(&self) -> [f32; 3] {
        let s = ACCEL_SCALE_M_S2;
        [
            -(self.accel[1] as f32) * s,
            (self.accel[2] as f32) * s,
            -(self.accel[0] as f32) * s,
        ]
    }
}

impl StatusReport {
    pub fn parse(buf: &[u8]) -> Result<StatusReport, ParseError> {
        need(buf, STATUS_HEADER_SIZE)?;
        let imu = buf[STATUS_HEADER_SIZE..]
            .chunks_exact(IMU_RECORD_SIZE)
            .map(ImuRecord::parse)
            .collect();
        Ok(StatusReport {
            dprx_status: buf[0],
            worn: buf[1] != 0,
            function_button: buf[2] != 0,
            ipd_mm: buf[5],
            imu,
        })
    }
}

// --- SLAM stream --------------------------------------------------------------------------------

/// Size of one SLAM record.
pub const SLAM_RECORD_SIZE: usize = 512;

/// A pose computed by the headset's own SLAM tracker (~60 Hz), in the headset's raw axes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SlamRecord {
    /// Timestamp on the VTS timeline, shared with the IMU.
    pub vts_us: u32,
    /// Usually 3; other values are not understood yet.
    pub unknown1: u32,
    /// Raw position in meters.
    pub position: [f32; 3],
    /// Raw orientation as sent (w, x, y, z order on the wire).
    pub orientation: Quat,
}

impl SlamRecord {
    pub fn parse(buf: &[u8]) -> Result<SlamRecord, ParseError> {
        need(buf, SLAM_RECORD_SIZE)?;
        // "SLP" then a version byte (1) on firmware 07000102, on a real headset;
        // "SLA" was a guess from before it. Monado checks no signature.
        if &buf[0..3] != b"SLP" && &buf[0..3] != b"SLA" {
            return Err(ParseError::BadSignature);
        }
        Ok(SlamRecord {
            vts_us: u32_at(buf, 8),
            unknown1: u32_at(buf, 12),
            position: [f32_at(buf, 16), f32_at(buf, 20), f32_at(buf, 24)],
            orientation: Quat {
                w: f32_at(buf, 28),
                x: f32_at(buf, 32),
                y: f32_at(buf, 36),
                z: f32_at(buf, 40),
            },
        })
    }

    /// Position in tracking axes (x right, y up, -z forward), as Monado maps it.
    pub fn tracking_position(&self) -> [f32; 3] {
        let p = self.position;
        [p[2], p[1], -p[0]]
    }

    /// Orientation in tracking axes, as Monado maps it. Monado then applies a fixed 90° roll
    /// correction about z; that belongs to the tracker, not here.
    pub fn tracking_orientation(&self) -> Quat {
        let q = self.orientation;
        Quat {
            w: q.w,
            x: -q.y,
            y: -q.x,
            z: q.z,
        }
    }
}

// --- Firmware info ------------------------------------------------------------------------------

pub const FIRMWARE_INFO_SIZE: usize = 84;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FirmwareInfo {
    pub version: u32,
    /// Git commit hash of the firmware build, as text.
    pub commit_hash: String,
    /// PCB id; Monado uses it as the serial number.
    pub pcb_id: String,
    pub recovery_version: u32,
}

fn text(b: &[u8]) -> String {
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

impl FirmwareInfo {
    pub fn parse(buf: &[u8]) -> Result<FirmwareInfo, ParseError> {
        need(buf, FIRMWARE_INFO_SIZE)?;
        Ok(FirmwareInfo {
            version: u32_at(buf, 0),
            commit_hash: text(&buf[8..48]),
            pcb_id: text(&buf[56..72]),
            recovery_version: u32_at(buf, 80),
        })
    }
}

// --- Distortion calibration ---------------------------------------------------------------------

/// Bytes requested from the headset for the distortion calibration block.
pub const DISTORTION_BLOCK_SIZE: usize = 0x100;

/// Per-headset lens calibration, converted to the 8 parameters used by Monado's
/// `psvr2_compute_distortion_asymmetric`: per eye an x/y offset and a rotation (cos, sin).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DistortionCalibration {
    /// `[offset_x_left, offset_y_left, offset_x_right, offset_y_right,
    ///   cos_left, sin_left, cos_right, sin_right]`
    pub params: [f32; 8],
    /// Calibration block version reported by the headset.
    pub version: u8,
}

impl DistortionCalibration {
    /// Parameters used when the headset has no usable calibration (version < 4): Monado's lens
    /// offsets with an identity rotation. Monado (and GAV) leave the rotation's cos/sin at zero,
    /// which maps every pixel to the lens center; that is a bug, not a calibration.
    pub const FALLBACK: [f32; 8] = [-0.099_192_93, 0.0, 0.099_192_93, 0.0, 1.0, 0.0, 1.0, 0.0];

    pub fn parse(buf: &[u8]) -> Result<DistortionCalibration, ParseError> {
        need(buf, 8 + 8 * 4)?;
        let version = buf[0];
        if version < 4 {
            return Ok(DistortionCalibration {
                params: Self::FALLBACK,
                version,
            });
        }
        let p: [f32; 8] = std::array::from_fn(|i| f32_at(buf, 8 + i * 4));
        let left = (-p[4]).to_radians();
        let right = (-p[5]).to_radians();
        let params = [
            (((-p[0] - p[6]) * 29.9 + 14.95) / 1000.0 - 3.22) / 32.461_99,
            (((-p[1] * 29.9) + 14.95) / 1000.0) / 32.461_99,
            (((p[6] - p[2]) * 29.9 + 14.95) / 1000.0 + 3.22) / 32.461_99,
            (((-p[3] * 29.9) + 14.95) / 1000.0) / 32.461_99,
            left.cos(),
            left.sin(),
            right.cos(),
            right.sin(),
        ];
        Ok(DistortionCalibration { params, version })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn imu_bytes(vts: u32, accel: [i16; 3], gyro: [i16; 3], ts: u16) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(&vts.to_le_bytes());
        for v in accel.iter().chain(gyro.iter()) {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&7u16.to_le_bytes()); // dp_frame_cnt
        b.extend_from_slice(&1234u16.to_le_bytes()); // dp_line_cnt
        b.extend_from_slice(&ts.to_le_bytes());
        b.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(b.len(), IMU_RECORD_SIZE);
        b
    }

    #[test]
    fn status_report_with_two_imu_samples() {
        let mut buf = vec![0u8; STATUS_HEADER_SIZE];
        buf[0] = 2; // dprx ready
        buf[1] = 1; // worn
        buf[2] = 0; // fn released
        buf[5] = 64; // ipd
        buf.extend(imu_bytes(1000, [0, 8192, 0], [32767, 0, -32767], 500));
        buf.extend(imu_bytes(1000, [1, 2, 3], [4, 5, 6], 1000));

        let r = StatusReport::parse(&buf).unwrap();
        assert_eq!(r.dprx_status, 2);
        assert!(r.worn);
        assert!(!r.function_button);
        assert_eq!(r.ipd_mm, 64);
        assert_eq!(r.imu.len(), 2);
        assert_eq!(r.imu[0].vts_us, 1000);
        assert_eq!(r.imu[0].dp_line_count, 1234);
        assert_eq!(r.imu[1].imu_ts_us, 1000);
        assert_eq!(r.imu[1].gyro, [4, 5, 6]);

        // Full-scale gyro on raw x maps to -z at 2000 deg/s; raw z maps to +y.
        let g = r.imu[0].gyro_rad_s();
        assert!((g[2] + 2000f32.to_radians()).abs() < 1e-3);
        assert!((g[1] + 2000f32.to_radians()).abs() < 1e-3);
        assert_eq!(g[0], 0.0);
        // 8192 on raw y is 1 g, mapped to -x.
        let a = r.imu[0].accel_m_s2();
        assert!((a[0] + 9.80665).abs() < 1e-2);
    }

    #[test]
    fn status_report_ignores_partial_trailing_record() {
        let mut buf = vec![0u8; STATUS_HEADER_SIZE];
        buf.extend(imu_bytes(1, [0; 3], [0; 3], 0));
        buf.extend_from_slice(&[0u8; 10]);
        assert_eq!(StatusReport::parse(&buf).unwrap().imu.len(), 1);
    }

    #[test]
    fn status_report_too_short() {
        assert_eq!(
            StatusReport::parse(&[0u8; 10]),
            Err(ParseError::TooShort {
                need: STATUS_HEADER_SIZE,
                got: 10
            })
        );
    }

    fn slam_bytes(vts: u32, pos: [f32; 3], q: [f32; 4]) -> Vec<u8> {
        let mut b = vec![0u8; SLAM_RECORD_SIZE];
        b[0..4].copy_from_slice(b"SLP\x01");
        b[3] = 1;
        b[4..8].copy_from_slice(&512u32.to_le_bytes());
        b[8..12].copy_from_slice(&vts.to_le_bytes());
        b[12..16].copy_from_slice(&3u32.to_le_bytes());
        for (i, v) in pos.iter().chain(q.iter()).enumerate() {
            b[16 + i * 4..20 + i * 4].copy_from_slice(&v.to_le_bytes());
        }
        b
    }

    #[test]
    fn slam_record_parses_and_maps_axes() {
        let buf = slam_bytes(42_000, [1.0, 2.0, 3.0], [0.5, 0.1, 0.2, 0.3]);
        let s = SlamRecord::parse(&buf).unwrap();
        assert_eq!(s.vts_us, 42_000);
        assert_eq!(s.unknown1, 3);
        assert_eq!(s.position, [1.0, 2.0, 3.0]);
        assert_eq!(
            s.orientation,
            Quat {
                w: 0.5,
                x: 0.1,
                y: 0.2,
                z: 0.3
            }
        );
        assert_eq!(s.tracking_position(), [3.0, 2.0, -1.0]);
        // Same remap as GAV's `mapped` quaternion: {q0, -q2, -q1, q3}.
        assert_eq!(
            s.tracking_orientation(),
            Quat {
                w: 0.5,
                x: -0.2,
                y: -0.1,
                z: 0.3
            }
        );
    }

    #[test]
    fn slam_record_rejects_bad_signature_and_short_packets() {
        let mut buf = slam_bytes(0, [0.0; 3], [1.0, 0.0, 0.0, 0.0]);
        buf[0] = b'X';
        assert_eq!(SlamRecord::parse(&buf), Err(ParseError::BadSignature));
        assert!(matches!(
            SlamRecord::parse(&buf[..100]),
            Err(ParseError::TooShort { .. })
        ));
    }

    #[test]
    fn control_packet_layout() {
        let pkt = encode_control(report::SET_BRIGHTNESS, 1, &brightness_payload(1.0)).unwrap();
        assert_eq!(pkt, vec![0x12, 0, 1, 0, 1, 0, 0, 0, 31]);
        assert_eq!(brightness_payload(0.5), [15]);
        assert_eq!(brightness_payload(-3.0), [0]);
        assert!(encode_control(0, 0, &[0u8; CONTROL_MAX_PAYLOAD + 1]).is_err());
    }

    #[test]
    fn firmware_info_parses_text_fields() {
        let mut b = vec![0u8; FIRMWARE_INFO_SIZE];
        b[0..4].copy_from_slice(&0x0600_0102u32.to_le_bytes());
        b[8..14].copy_from_slice(b"abc123");
        b[56..62].copy_from_slice(b"PCB-01");
        b[80..84].copy_from_slice(&7u32.to_le_bytes());
        let f = FirmwareInfo::parse(&b).unwrap();
        assert_eq!(f.version, 0x0600_0102);
        assert_eq!(f.commit_hash, "abc123");
        assert_eq!(f.pcb_id, "PCB-01");
        assert_eq!(f.recovery_version, 7);
    }

    #[test]
    fn distortion_fallback_for_old_blocks() {
        let mut b = vec![0u8; DISTORTION_BLOCK_SIZE];
        b[0] = 3;
        let d = DistortionCalibration::parse(&b).unwrap();
        assert_eq!(d.params, DistortionCalibration::FALLBACK);
    }

    #[test]
    fn distortion_conversion_matches_monado() {
        // With all raw parameters zero, Monado's formulas give these values.
        let mut b = vec![0u8; DISTORTION_BLOCK_SIZE];
        b[0] = 4;
        let d = DistortionCalibration::parse(&b).unwrap();
        let ox = (14.95 / 1000.0 - 3.22) / 32.461_99;
        let oy = (14.95 / 1000.0) / 32.461_99;
        let expected = [
            ox,
            oy,
            (14.95 / 1000.0 + 3.22) / 32.461_99,
            oy,
            1.0,
            0.0,
            1.0,
            0.0,
        ];
        for (got, want) in d.params.iter().zip(expected) {
            assert!((got - want).abs() < 1e-6, "{got} vs {want}");
        }

        // A 10 degree left-lens rotation becomes cos/sin of -10 degrees.
        b[8 + 4 * 4..8 + 5 * 4].copy_from_slice(&10f32.to_le_bytes());
        let d = DistortionCalibration::parse(&b).unwrap();
        assert!((d.params[4] - (-10f32).to_radians().cos()).abs() < 1e-6);
        assert!((d.params[5] - (-10f32).to_radians().sin()).abs() < 1e-6);
    }
}
