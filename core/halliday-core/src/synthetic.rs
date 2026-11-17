//! Synthetic recordings: realistic-looking headset streams for development and tests without a
//! headset. The head looks left and right in a sine wave while standing still.
//!
//! Timing mimics the hardware: status packets with two IMU samples at 1 kHz arriving 1 ms after
//! sampling, SLAM poses at 60 Hz arriving 23 ms after sampling, both on one VTS clock.

use crate::math::Quat;
use crate::psvr2::protocol::{
    FIRMWARE_INFO_SIZE, GYRO_SCALE_DEG_S, IMU_RECORD_SIZE, SLAM_RECORD_SIZE, STATUS_HEADER_SIZE,
};
use crate::recording::{Stream, Writer};

#[derive(Debug, Clone, Copy)]
pub struct LookAround {
    pub seconds: f32,
    /// Peak yaw, radians.
    pub amplitude: f32,
    /// Oscillations per second.
    pub frequency_hz: f32,
    /// Eye height, meters.
    pub height: f32,
}

impl Default for LookAround {
    fn default() -> Self {
        LookAround {
            seconds: 20.0,
            amplitude: 0.6,
            frequency_hz: 0.2,
            height: 1.65,
        }
    }
}

impl LookAround {
    fn yaw(&self, t: f32) -> f32 {
        self.amplitude * (std::f32::consts::TAU * self.frequency_hz * t).sin()
    }

    fn yaw_rate(&self, t: f32) -> f32 {
        let w = std::f32::consts::TAU * self.frequency_hz;
        self.amplitude * w * (w * t).cos()
    }

    /// Encodes the motion as a `.hrec` recording.
    pub fn record(&self) -> Vec<u8> {
        let mut events: Vec<(u64, Stream, Vec<u8>)> = Vec::new();
        let host0: u64 = 1_000_000_000;
        let ms_total = (self.seconds * 1000.0) as u32;
        let raw_scale = GYRO_SCALE_DEG_S.to_radians();

        let mut fw = vec![0u8; FIRMWARE_INFO_SIZE];
        fw[56..65].copy_from_slice(b"SYNTHETIC");
        events.push((host0, Stream::FirmwareInfo, fw));

        for ms in 0..ms_total {
            let vts = ms * 1000;
            let mut b = vec![0u8; STATUS_HEADER_SIZE];
            b[0] = 2;
            b[1] = 1;
            b[5] = 64;
            for half in 0..2 {
                let t = (vts + half * 500) as f32 * 1e-6;
                // Tracking +y rotation comes from raw gyro z.
                let raw_z = (self.yaw_rate(t) / raw_scale).round() as i16;
                let mut rec = vec![0u8; IMU_RECORD_SIZE];
                rec[0..4].copy_from_slice(&vts.to_le_bytes());
                rec[4..6].copy_from_slice(&0i16.to_le_bytes());
                rec[6..8].copy_from_slice(&8192i16.to_le_bytes()); // 1 g
                rec[14..16].copy_from_slice(&raw_z.to_le_bytes());
                rec[20..22].copy_from_slice(&((vts + half * 500) as u16).to_le_bytes());
                b.extend(rec);
            }
            events.push((host0 + vts as u64 * 1000 + 1_500_000, Stream::Status, b));
        }

        let mut i = 0u32;
        loop {
            let vts = i * 16_667;
            if vts >= ms_total * 1000 {
                break;
            }
            let t = vts as f32 * 1e-6;
            // SLAM orientation before Monado's 90-degree correction; tracking -> raw wire order.
            let q = crate::tracking::head::SLAM_CORRECTION.conjugate()
                * Quat::from_axis_angle([0.0, 1.0, 0.0], self.yaw(t));
            let raw_q = [q.w, -q.y, -q.x, q.z];
            // Tracking position (0, h, 0) -> raw (-z, y, x).
            let raw_p = [0.0f32, self.height, 0.0];
            let mut b = vec![0u8; SLAM_RECORD_SIZE];
            b[0..3].copy_from_slice(b"SLA");
            b[3] = 1;
            b[4..8].copy_from_slice(&512u32.to_le_bytes());
            b[8..12].copy_from_slice(&vts.to_le_bytes());
            b[12..16].copy_from_slice(&3u32.to_le_bytes());
            for (k, v) in raw_p.iter().chain(raw_q.iter()).enumerate() {
                b[16 + k * 4..20 + k * 4].copy_from_slice(&v.to_le_bytes());
            }
            events.push((host0 + vts as u64 * 1000 + 23_000_000, Stream::Slam, b));
            i += 1;
        }

        events.sort_by_key(|e| e.0);
        let mut w = Writer::new(Vec::new(), 0).expect("in-memory write");
        w.write(
            Stream::Note,
            host0,
            b"synthetic: looking left and right, standing still",
        )
        .expect("in-memory write");
        for (t, s, d) in events {
            w.write(s, t, &d).expect("in-memory write");
        }
        w.into_inner()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::recording::Reader;

    #[test]
    fn tracker_follows_the_synthetic_motion() {
        let motion = LookAround {
            seconds: 3.0,
            ..Default::default()
        };
        let bytes = motion.record();
        let e = crate::tracking::replay::evaluate(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert!(e.evaluated > 150, "{e:?}");
        assert!(e.mean_error_deg < 0.1, "{e:?}");

        // Stream rates and metadata look like the hardware.
        let s = crate::summary::summarize(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert_eq!(s.firmware.as_ref().unwrap().pcb_id, "SYNTHETIC");
        assert!((s.imu_rate_hz() - 2000.0).abs() < 5.0);
        assert!((s.slam_rate_hz() - 60.0).abs() < 1.0);
    }
}
