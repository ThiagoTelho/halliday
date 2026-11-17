//! Statistics over a recording: what arrived, how often, and whether it parsed. Used by
//! `halliday-probe replay` and as a sanity check on new recordings.

use std::collections::BTreeMap;
use std::io::Read;

use crate::psvr2::protocol::{FirmwareInfo, SlamRecord, StatusReport};
use crate::recording::{Reader, RecordingError, Stream};

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Summary {
    /// Host time span between the first and last record, in seconds.
    pub duration_s: f64,
    pub notes: Vec<String>,
    pub firmware: Option<FirmwareInfo>,
    pub status_packets: usize,
    pub imu_samples: usize,
    pub slam_records: usize,
    /// Packets that failed to parse, per stream.
    pub parse_errors: BTreeMap<&'static str, usize>,
    /// IMU samples whose VTS timestamp went backwards (wrap excluded).
    pub imu_vts_regressions: usize,
    /// Fraction of status packets with the headset worn.
    pub worn_fraction: f64,
    pub ipd_mm: Option<u8>,
    /// First and last SLAM position in tracking axes, meters.
    pub first_position: Option<[f32; 3]>,
    pub last_position: Option<[f32; 3]>,
}

impl Summary {
    pub fn imu_rate_hz(&self) -> f64 {
        rate(self.imu_samples, self.duration_s)
    }

    pub fn slam_rate_hz(&self) -> f64 {
        rate(self.slam_records, self.duration_s)
    }
}

fn rate(n: usize, s: f64) -> f64 {
    if s > 0.0 { n as f64 / s } else { 0.0 }
}

pub fn summarize<R: Read>(reader: Reader<R>) -> Result<Summary, RecordingError> {
    let mut s = Summary::default();
    let (mut first_t, mut last_t) = (None, 0u64);
    let mut worn = 0usize;
    let mut last_vts: Option<u32> = None;

    for record in reader {
        let r = record?;
        first_t.get_or_insert(r.t_ns);
        last_t = r.t_ns;
        match r.stream {
            Stream::Note => s.notes.push(String::from_utf8_lossy(&r.data).into_owned()),
            Stream::FirmwareInfo => match FirmwareInfo::parse(&r.data) {
                Ok(f) => s.firmware = Some(f),
                Err(_) => *s.parse_errors.entry("firmware").or_default() += 1,
            },
            Stream::DistortionCalibration => {}
            Stream::Status => match StatusReport::parse(&r.data) {
                Ok(st) => {
                    s.status_packets += 1;
                    worn += usize::from(st.worn);
                    s.ipd_mm = Some(st.ipd_mm);
                    for imu in &st.imu {
                        // A real regression is a small step back; a huge one is the u32 wrapping.
                        if let Some(prev) = last_vts
                            && imu.vts_us < prev
                            && prev - imu.vts_us < u32::MAX / 2
                        {
                            s.imu_vts_regressions += 1;
                        }
                        last_vts = Some(imu.vts_us);
                    }
                    s.imu_samples += st.imu.len();
                }
                Err(_) => *s.parse_errors.entry("status").or_default() += 1,
            },
            Stream::Slam => match SlamRecord::parse(&r.data) {
                Ok(slam) => {
                    s.slam_records += 1;
                    let p = slam.tracking_position();
                    s.first_position.get_or_insert(p);
                    s.last_position = Some(p);
                }
                Err(_) => *s.parse_errors.entry("slam").or_default() += 1,
            },
        }
    }

    if let Some(first) = first_t {
        s.duration_s = (last_t - first) as f64 / 1e9;
    }
    if s.status_packets > 0 {
        s.worn_fraction = worn as f64 / s.status_packets as f64;
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::psvr2::protocol::{IMU_RECORD_SIZE, SLAM_RECORD_SIZE, STATUS_HEADER_SIZE};
    use crate::recording::Writer;

    fn status(vts: [u32; 2], worn: bool) -> Vec<u8> {
        let mut b = vec![0u8; STATUS_HEADER_SIZE];
        b[1] = u8::from(worn);
        b[5] = 63;
        for v in vts {
            let mut rec = vec![0u8; IMU_RECORD_SIZE];
            rec[0..4].copy_from_slice(&v.to_le_bytes());
            b.extend(rec);
        }
        b
    }

    fn slam(x: f32) -> Vec<u8> {
        let mut b = vec![0u8; SLAM_RECORD_SIZE];
        b[0..3].copy_from_slice(b"SLA");
        b[16..20].copy_from_slice(&x.to_le_bytes()); // raw x -> tracking -z
        b[28..32].copy_from_slice(&1f32.to_le_bytes());
        b
    }

    #[test]
    fn summarizes_a_synthetic_second() {
        let mut w = Writer::new(Vec::new(), 0).unwrap();
        w.write(Stream::Note, 0, b"synthetic").unwrap();
        // 1000 status packets of 2 samples each over one second = 2000 Hz IMU.
        for i in 0..1000u64 {
            let vts = 1000 + i as u32;
            w.write(
                Stream::Status,
                i * 1_000_000,
                &status([vts, vts], i % 2 == 0),
            )
            .unwrap();
        }
        for i in 0..60u64 {
            w.write(Stream::Slam, i * 16_666_667, &slam(i as f32 * 0.01))
                .unwrap();
        }
        w.write(Stream::Slam, 999_000_000, b"garbage").unwrap();
        let bytes = w.into_inner();

        let s = summarize(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert_eq!(s.notes, vec!["synthetic"]);
        assert_eq!(s.status_packets, 1000);
        assert_eq!(s.imu_samples, 2000);
        assert_eq!(s.slam_records, 60);
        assert_eq!(s.parse_errors.get("slam"), Some(&1));
        assert_eq!(s.imu_vts_regressions, 0);
        assert_eq!(s.ipd_mm, Some(63));
        assert!((s.worn_fraction - 0.5).abs() < 1e-9);
        assert!(
            (s.imu_rate_hz() - 2002.0).abs() < 5.0,
            "{}",
            s.imu_rate_hz()
        );
        assert_eq!(s.first_position, Some([0.0, 0.0, -0.0]));
        assert!((s.last_position.unwrap()[2] + 0.59).abs() < 1e-5);
    }

    #[test]
    fn counts_vts_regressions_but_not_wraps() {
        let mut w = Writer::new(Vec::new(), 0).unwrap();
        w.write(Stream::Status, 0, &status([500, 400], true))
            .unwrap(); // regression
        w.write(Stream::Status, 1, &status([u32::MAX, 3], true))
            .unwrap(); // wrap
        let bytes = w.into_inner();
        let s = summarize(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert_eq!(s.imu_vts_regressions, 1);
    }
}
