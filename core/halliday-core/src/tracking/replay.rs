//! Runs a recording through the head tracker and measures prediction quality.
//!
//! Metric: every time a SLAM pose arrives, the tracker's prediction for that pose's timestamp,
//! made from earlier data only (previous pose + gyro), is compared with the pose itself. The angle
//! between them is the prediction error the renderer would have shown, minus the extra
//! extrapolation to scanout.

use std::io::Read;

use crate::psvr2::protocol::{SlamRecord, StatusReport};
use crate::recording::{Reader, RecordingError, Stream};
use crate::tracking::{HeadTracker, TrackerConfig};

#[derive(Debug, Default, Clone, PartialEq)]
pub struct TrackEvaluation {
    pub slam_poses: usize,
    /// Poses that had a prediction to compare against (all but the first ones).
    pub evaluated: usize,
    pub mean_error_deg: f64,
    pub p95_error_deg: f64,
    pub max_error_deg: f64,
    /// Mean angle the head turned between consecutive SLAM poses: the error with no prediction.
    pub mean_motion_deg: f64,
    /// The same for the eyes' position, in mm: predicted, and held from the previous pose.
    pub mean_position_error_mm: f64,
    pub p95_position_error_mm: f64,
    pub mean_position_motion_mm: f64,
    /// Final estimate of `host - vts`, in ms.
    pub clock_offset_ms: Option<f64>,
}

pub fn evaluate<R: Read>(reader: Reader<R>) -> Result<TrackEvaluation, RecordingError> {
    evaluate_with(reader, TrackerConfig::default())
}

pub fn evaluate_with<R: Read>(
    reader: Reader<R>,
    config: TrackerConfig,
) -> Result<TrackEvaluation, RecordingError> {
    let mut tracker = HeadTracker::new(config);
    let mut errors = Vec::new();
    let mut motion = Vec::new();
    let mut position_errors = Vec::new();
    let mut position_motion = Vec::new();
    let mut eval = TrackEvaluation::default();

    for record in reader {
        let r = record?;
        let host_ns = r.t_ns as i64;
        match r.stream {
            Stream::Status => {
                if let Ok(s) = StatusReport::parse(&r.data) {
                    tracker.ingest_status(&s, host_ns);
                }
            }
            Stream::Slam => {
                let Ok(s) = SlamRecord::parse(&r.data) else {
                    continue;
                };
                eval.slam_poses += 1;
                // Host time the pose was sampled at, on the tracker's clock mapping.
                let sampled_host = tracker
                    .clock_offset_ns()
                    .map(|o| s.vts_us as i64 * 1000 + o);
                let before = sampled_host.and_then(|t| tracker.predict(t).map(|p| (t, p)));
                let previous = tracker.predict(host_ns);
                tracker.ingest_slam(&s, host_ns);
                if let Some((t, b)) = before
                    && b.predicted
                    && let Some(a) = tracker.predict(t)
                {
                    errors
                        .push(b.pose.orientation.angle_to(a.pose.orientation).to_degrees() as f64);
                    position_errors.push(distance_mm(b.pose.position, a.pose.position));
                    if let Some(p) = previous {
                        motion.push(
                            p.pose.orientation.angle_to(a.pose.orientation).to_degrees() as f64
                        );
                        position_motion.push(distance_mm(p.pose.position, a.pose.position));
                    }
                }
            }
            _ => {}
        }
    }

    eval.evaluated = errors.len();
    if !errors.is_empty() {
        eval.mean_error_deg = errors.iter().sum::<f64>() / errors.len() as f64;
        errors.sort_by(f64::total_cmp);
        eval.p95_error_deg = errors[((errors.len() - 1) as f64 * 0.95) as usize];
        eval.max_error_deg = *errors.last().unwrap();
    }
    if !motion.is_empty() {
        eval.mean_motion_deg = motion.iter().sum::<f64>() / motion.len() as f64;
    }
    if !position_errors.is_empty() {
        eval.mean_position_error_mm =
            position_errors.iter().sum::<f64>() / position_errors.len() as f64;
        position_errors.sort_by(f64::total_cmp);
        eval.p95_position_error_mm =
            position_errors[((position_errors.len() - 1) as f64 * 0.95) as usize];
    }
    if !position_motion.is_empty() {
        eval.mean_position_motion_mm =
            position_motion.iter().sum::<f64>() / position_motion.len() as f64;
    }
    eval.clock_offset_ms = tracker.clock_offset_ns().map(|o| o as f64 / 1e6);
    Ok(eval)
}

/// How far a pose predicted `predict_ahead_ns` ahead of "now" is from where the head really was
/// `shown_ahead_ns` after that now (the SLAM poses around that time, interpolated): what the eyes
/// get when frames are shown that long after they are started. A prediction is made every 8 ms.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct HorizonEvaluation {
    pub samples: usize,
    pub mean_error_deg: f64,
    pub p95_error_deg: f64,
    pub mean_position_error_mm: f64,
    pub p95_position_error_mm: f64,
    /// Shake: how much one frame's step differs from the step before it (what the eye sees as
    /// a tremble of things that should stand still), in arc minutes and in mm of the eyes'
    /// position. `still_*`: over the frames in which the head hardly turned (under 12°/s),
    /// where it shows most; `shake_*`: over all of them. Means, and the 95th percentile.
    pub still_frames: usize,
    pub still_shake_arcmin: f64,
    pub still_shake_p95_arcmin: f64,
    pub still_shake_mm: f64,
    pub still_shake_p95_mm: f64,
    pub shake_arcmin: f64,
    pub shake_mm: f64,
}

pub fn evaluate_horizon<R: Read>(
    reader: Reader<R>,
    config: TrackerConfig,
    predict_ahead_ns: i64,
    shown_ahead_ns: i64,
) -> Result<HorizonEvaluation, RecordingError> {
    let mut tracker = HeadTracker::new(config);
    let mut truth: Vec<(i64, crate::math::Pose)> = Vec::new();
    let mut predictions: Vec<(i64, crate::math::Pose)> = Vec::new();
    let mut last_prediction = 0i64;
    for record in reader {
        let r = record?;
        let host_ns = r.t_ns as i64;
        match r.stream {
            Stream::Status => {
                if let Ok(s) = StatusReport::parse(&r.data) {
                    tracker.ingest_status(&s, host_ns);
                }
            }
            Stream::Slam => {
                let Ok(s) = SlamRecord::parse(&r.data) else {
                    continue;
                };
                let sampled = tracker
                    .clock_offset_ns()
                    .map(|o| s.vts_us as i64 * 1000 + o);
                tracker.ingest_slam(&s, host_ns);
                if let Some(t) = sampled
                    && let Some(p) = tracker.predict(t)
                {
                    truth.push((t, p.pose));
                }
            }
            _ => {}
        }
        if host_ns - last_prediction >= 8_000_000
            && let Some(p) = tracker.predict(host_ns + predict_ahead_ns)
            && p.predicted
        {
            last_prediction = host_ns;
            predictions.push((host_ns + shown_ahead_ns, p.pose));
        }
    }
    // Shake, from the predictions alone: three in a row, a frame apart.
    let (mut still, mut still_mm, mut all, mut all_mm) = (Vec::new(), Vec::new(), 0.0f64, 0.0f64);
    let mut triples = 0usize;
    for w in predictions.windows(3) {
        let (a, b, c) = (w[0].1, w[1].1, w[2].1);
        if w[2].0 - w[0].0 > 24_000_000 {
            continue;
        }
        let first = a.orientation.conjugate() * b.orientation;
        let second = b.orientation.conjugate() * c.orientation;
        let change = small_angle_deg(first, second) * 60.0;
        let moved = [0, 1, 2].map(|k| c.position[k] - 2.0 * b.position[k] + a.position[k]);
        let moved_mm = distance_mm(moved, [0.0; 3]);
        triples += 1;
        all += change;
        all_mm += moved_mm;
        let step = small_angle_deg(a.orientation, b.orientation)
            .max(small_angle_deg(b.orientation, c.orientation));
        if step < 0.1 {
            still.push(change);
            still_mm.push(moved_mm);
        }
    }
    let mut angles = Vec::new();
    let mut distances = Vec::new();
    let mut i = 0;
    for (t, p) in predictions {
        while i + 1 < truth.len() && truth[i + 1].0 < t {
            i += 1;
        }
        if i + 1 >= truth.len() || truth[i].0 > t || truth[i + 1].0 - truth[i].0 > 40_000_000 {
            continue;
        }
        let (t0, a) = truth[i];
        let (t1, b) = truth[i + 1];
        let f = (t - t0) as f32 / (t1 - t0).max(1) as f32;
        let sign = if a.orientation.dot(b.orientation) < 0.0 {
            -1.0
        } else {
            1.0
        };
        let q = crate::math::Quat {
            w: a.orientation.w * (1.0 - f) + sign * b.orientation.w * f,
            x: a.orientation.x * (1.0 - f) + sign * b.orientation.x * f,
            y: a.orientation.y * (1.0 - f) + sign * b.orientation.y * f,
            z: a.orientation.z * (1.0 - f) + sign * b.orientation.z * f,
        }
        .normalized();
        let at = [0, 1, 2].map(|k| a.position[k] * (1.0 - f) + b.position[k] * f);
        angles.push(f64::from(p.orientation.angle_to(q).to_degrees()));
        distances.push(distance_mm(p.position, at));
    }
    let mut e = HorizonEvaluation {
        samples: angles.len(),
        ..Default::default()
    };
    if !angles.is_empty() {
        let n = angles.len();
        e.mean_error_deg = angles.iter().sum::<f64>() / n as f64;
        e.mean_position_error_mm = distances.iter().sum::<f64>() / n as f64;
        angles.sort_by(f64::total_cmp);
        distances.sort_by(f64::total_cmp);
        e.p95_error_deg = angles[((n - 1) as f64 * 0.95) as usize];
        e.p95_position_error_mm = distances[((n - 1) as f64 * 0.95) as usize];
    }
    if triples > 0 {
        e.shake_arcmin = all / triples as f64;
        e.shake_mm = all_mm / triples as f64;
    }
    if !still.is_empty() {
        let n = still.len();
        e.still_frames = n;
        e.still_shake_arcmin = still.iter().sum::<f64>() / n as f64;
        e.still_shake_mm = still_mm.iter().sum::<f64>() / n as f64;
        still.sort_by(f64::total_cmp);
        still_mm.sort_by(f64::total_cmp);
        e.still_shake_p95_arcmin = still[((n - 1) as f64 * 0.95) as usize];
        e.still_shake_p95_mm = still_mm[((n - 1) as f64 * 0.95) as usize];
    }
    Ok(e)
}

/// The angle between two orientations, in degrees, good for very small ones (the arc cosine of
/// a dot product near 1 has only about an arc minute of precision in 32 bits).
fn small_angle_deg(a: crate::math::Quat, b: crate::math::Quat) -> f64 {
    let d = a.conjugate() * b;
    let v = (f64::from(d.x).powi(2) + f64::from(d.y).powi(2) + f64::from(d.z).powi(2)).sqrt();
    (2.0 * v.atan2(f64::from(d.w).abs())).to_degrees()
}

fn distance_mm(a: [f32; 3], b: [f32; 3]) -> f64 {
    let d = [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    f64::from((d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).sqrt()) * 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::Quat;
    use crate::psvr2::protocol::{
        GYRO_SCALE_DEG_S, IMU_RECORD_SIZE, SLAM_RECORD_SIZE, STATUS_HEADER_SIZE,
    };
    use crate::recording::Writer;

    const RATE: f32 = 1.5; // rad/s yaw

    fn status_bytes(vts_us: u32, gyro_y_raw: i16) -> Vec<u8> {
        let mut b = vec![0u8; STATUS_HEADER_SIZE];
        b[1] = 1;
        for half in 0..2 {
            let mut rec = vec![0u8; IMU_RECORD_SIZE];
            rec[0..4].copy_from_slice(&vts_us.to_le_bytes());
            rec[14..16].copy_from_slice(&gyro_y_raw.to_le_bytes()); // raw z -> tracking +y
            rec[20..22].copy_from_slice(&((vts_us + half * 500) as u16).to_le_bytes());
            rec[22..24].copy_from_slice(&(if half == 0 { 1u16 } else { 0u16 }).to_le_bytes());
            b.extend(rec);
        }
        b
    }

    fn slam_bytes(vts_us: u32, yaw: f32) -> Vec<u8> {
        // Tracking-space yaw about +y; raw wire order is (w, -y_t, -x_t, z_t).
        let q = Quat::from_axis_angle([0.0, 1.0, 0.0], yaw);
        let raw = [q.w, -q.y, -q.x, q.z];
        let mut b = vec![0u8; SLAM_RECORD_SIZE];
        b[0..3].copy_from_slice(b"SLA");
        b[8..12].copy_from_slice(&vts_us.to_le_bytes());
        for (i, v) in raw.iter().enumerate() {
            b[28 + i * 4..32 + i * 4].copy_from_slice(&v.to_le_bytes());
        }
        b
    }

    /// Two seconds of a head turning at a constant rate, with realistic delays: IMU packets arrive
    /// 1 ms after sampling, SLAM poses 23 ms after.
    fn turning_recording(gyro_matches_slam: bool) -> Vec<u8> {
        let raw = (RATE / GYRO_SCALE_DEG_S.to_radians()).round() as i16;
        let gyro = if gyro_matches_slam { raw } else { 0 };
        let rate = raw as f32 * GYRO_SCALE_DEG_S.to_radians();
        let offset_ns: u64 = 1_000_000_000;
        let mut events: Vec<(u64, Stream, Vec<u8>)> = Vec::new();
        for ms in 0..2000u32 {
            let vts = ms * 1000;
            events.push((
                vts as u64 * 1000 + 500_000 + 1_000_000 + offset_ns,
                Stream::Status,
                status_bytes(vts, gyro),
            ));
        }
        for i in 0..120u32 {
            let vts = i * 16_667;
            let yaw = rate * vts as f32 * 1e-6;
            events.push((
                vts as u64 * 1000 + 23_000_000 + offset_ns,
                Stream::Slam,
                slam_bytes(vts, yaw),
            ));
        }
        events.sort_by_key(|e| e.0);
        let mut w = Writer::new(Vec::new(), 0).unwrap();
        for (t, s, d) in events {
            w.write(s, t, &d).unwrap();
        }
        w.into_inner()
    }

    #[test]
    fn gyro_prediction_tracks_a_constant_turn() {
        let bytes = turning_recording(true);
        let e = evaluate(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert_eq!(e.slam_poses, 120);
        assert!(e.evaluated > 100, "{e:?}");
        // Per-pose motion is ~1.4 degrees; the prediction should be far better.
        assert!(e.mean_motion_deg > 1.0, "{e:?}");
        assert!(e.mean_error_deg < 0.15, "{e:?}");
        assert!(e.max_error_deg < 0.3, "{e:?}");
        let offset = e.clock_offset_ms.unwrap();
        assert!((offset - 1001.0).abs() < 0.2, "offset {offset}");
    }

    #[test]
    fn without_gyro_the_error_equals_the_motion() {
        let bytes = turning_recording(false);
        let e = evaluate(Reader::new(&bytes[..]).unwrap()).unwrap();
        assert!((e.mean_error_deg - e.mean_motion_deg).abs() < 0.2, "{e:?}");
    }
}
