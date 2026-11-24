//! PS VR2 head tracker.
//!
//! The headset runs SLAM on board and sends a pose about 60 times a second, already ~23 ms old on
//! arrival. The tracker carries that pose forward with the 2000 Hz gyro and extrapolates it to the
//! time a frame will be on the panel. The prediction scheme is GAV PSVR2 Player's (MIT), measured
//! on hardware: integrate every IMU sample newer than the pose (the first one only from the pose
//! time on), then extrapolate with the last angular velocity. Frame conventions (axis mapping, the
//! 90° SLAM correction, the SLAM→head offset) are Monado's (BSL-1.0). See THIRD-PARTY.md.
//!
//! Position is carried forward too: held as sent, it moved in 60 Hz steps on a 120 Hz panel, about
//! 50 ms late, and near panels shimmered as the head turned.
//! Most of the headset's movement is the head turning about the neck, which the gyro predicts
//! well, so the position is split in two: a pivot (the tracker's origin minus `NECK_LEVER` turned
//! by the orientation), which moves little and is carried forward with a velocity smoothed over
//! SLAM poses, and the lever, turned by the predicted orientation.
//!
//! Steadiness (things fixed in space trembled with the headset): measured
//! on the worn recordings as how much one frame's step differs from the one before
//! (`replay::HorizonEvaluation`'s shake), most of it was the position: every SLAM pose moved the
//! view at once to where it said the head was, sixty small steps a second, and the velocity taken
//! from two such poses carried their shake up to 60 ms ahead. So a pose's correction is taken
//! gradually (`correction_smoothing_ns`), the velocity is trusted less the slower the head moves
//! (`still_speed`), and while the head hardly turns the gyro that carries the orientation ahead
//! is averaged over longer (`still_window_ns`, `still_turn`), as Oculus described for theirs
//! (prediction and smoothing set by how fast the head turns: a still head shows the tremble, a
//! turning one the lag).
//!
//! Hardware check pending: Monado rotates the SLAM orientation by its 90° correction but leaves
//! the position unrotated. Confirm on the headset that stepping forward moves −z and turning left
//! gives positive yaw (see docs/first-hardware-session.md).

use std::collections::VecDeque;

use crate::math::{Pose, Quat, Vec3};
use crate::psvr2::protocol::{SlamRecord, StatusReport};
use crate::tracking::clock::{ClockOffset, VtsUnwrapper};

/// Weight of the newest SLAM-to-SLAM velocity of the pivot in the smoothed one.
const VELOCITY_SMOOTHING: f32 = 0.5;
/// From the point the head turns about (the top of the neck) to the SLAM tracker's origin, in the
/// headset's axes: fitted to the first recording worn (`halliday-probe axes`, 2.75 mm left over).
/// People differ by a centimetre or two; what the lever misses the pivot's velocity picks up.
pub const NECK_LEVER: Vec3 = [0.012, 0.090, -0.185];
/// Position extrapolation stops after this (a dropped SLAM pose shouldn't fling the view).
const MAX_POSITION_EXTRAPOLATION_NS: i64 = 60_000_000;

/// Duration one IMU sample covers (2000 Hz).
const IMU_PERIOD_NS: i64 = 500_000;
/// IMU history kept: ~256 ms, comfortably more than a SLAM pose's age plus a frame.
const IMU_HISTORY: usize = 512;

/// Monado's fixed correction applied to the SLAM orientation: 90° about z.
pub const SLAM_CORRECTION: Quat = Quat {
    w: std::f32::consts::FRAC_1_SQRT_2,
    x: 0.0,
    y: 0.0,
    z: std::f32::consts::FRAC_1_SQRT_2,
};

/// Monado's constant transform from the SLAM tracker's origin to the head (center of the eyes).
pub const SLAM_TO_HEAD: Pose = Pose {
    position: [0.000_247, -0.000_273, 0.104_826],
    orientation: Quat::IDENTITY,
};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackerConfig {
    /// A SLAM pose older than this (by host arrival time) means the stream is dead.
    pub stale_after_ns: i64,
    /// Upper bound on extrapolation past the newest IMU sample.
    pub max_extrapolation_ns: i64,
    /// The angular velocity that carries the pose past the newest IMU sample is the mean over
    /// this long: one 0.5 ms sample, carried 30 ms ahead, turned every vibration of the headset
    /// into a wobble of the view.
    pub extrapolation_window_ns: i64,
    /// While the head turns slower than `still_turn` (rad/s; 0: never), the mean is taken over
    /// up to this long instead: a head held still shows the gyro's own noise, carried ahead, as a
    /// tremble, and has no motion that a long mean would lag behind. In between, in proportion.
    pub still_window_ns: i64,
    pub still_turn: f32,
    /// Carry the position forward with the SLAM velocity (off: held as sent).
    pub predict_position: bool,
    /// Each SLAM pose differs a little from where the last one, carried forward, said the head
    /// would be (its own noise, the gyro's drift): taken at once, that is a small step of the
    /// whole view sixty times a second, a tremble of everything that should stand still. The
    /// difference is taken over this long instead (it dies away with this time constant). 0: at
    /// once.
    pub correction_smoothing_ns: i64,
    /// The position's velocity comes from differences of SLAM positions, which shake: below this
    /// speed (m/s) it is smoothed harder and carried forward less (at a standstill, not at all).
    /// 0: always carried forward in full.
    pub still_speed: f32,
    /// The head's turning changes over the tens of milliseconds a pose is carried ahead: a nod
    /// or a shake of a few hertz reverses several times a second, and carried ahead at the
    /// rate of this instant the view overshot every reversal (what is fixed in space swung
    /// with the head). The rate's own change is measured as the difference of the gyro's means
    /// over this long and the same span before, and carried ahead too. 0: the rate is taken as
    /// constant. Only while the head turns (`still_turn`): at rest it would be noise.
    pub acceleration_window_ns: i64,
}

impl Default for TrackerConfig {
    fn default() -> Self {
        TrackerConfig {
            stale_after_ns: 500_000_000,
            max_extrapolation_ns: 100_000_000,
            extrapolation_window_ns: 0,
            // The steadiness settings, chosen on the two worn recordings (`halliday-probe
            // track`): against none of them, the eyes' position shook a sixth to an
            // eighth as much from frame to frame while the head was nearly still (0.37 and
            // 0.49 mm to 0.06), the orientation 0.6 to 0.7 as much, and the prediction's own
            // error went down a little (0.145 to 0.131° and 0.072 to 0.064°, 34 ms ahead).
            still_window_ns: 24_000_000,
            still_turn: 0.175,
            predict_position: true,
            correction_smoothing_ns: 60_000_000,
            still_speed: 0.05,
            acceleration_window_ns: 0,
        }
    }
}

/// A predicted head pose.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HeadPose {
    /// Head pose in the tracking space, after recentering.
    pub pose: Pose,
    /// Latest angular velocity in rad/s, in the head's own frame (for rolling-shutter correction).
    pub angular_velocity: Vec3,
    /// Eye-centre velocity in the same recentered world axes as `pose.position`.
    pub linear_velocity: Vec3,
    /// Bit 0: measured linear motion; bit 1: measured angular motion.
    pub motion_flags: u32,
    /// Age of the SLAM pose the prediction started from, at the requested time.
    pub slam_age_ns: i64,
    /// False until IMU data has arrived: the pose is then the plain SLAM pose, not predicted.
    pub predicted: bool,
}

#[derive(Debug, Clone, Copy)]
struct ImuSample {
    vts_ns: i64,
    gyro: Vec3,
}

#[derive(Debug, Clone, Copy)]
struct SlamSample {
    vts_ns: i64,
    host_ns: i64,
    /// Orientation in tracking axes, before the 90° correction (the frame the gyro is in).
    orientation: Quat,
    position: Vec3,
    /// The position minus the neck lever: the point the head turns about.
    pivot: Vec3,
}

/// Headset state from the status stream.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct HeadsetStatus {
    pub worn: bool,
    pub function_button: bool,
    pub ipd_mm: u8,
}

#[derive(Debug, Default)]
pub struct HeadTracker {
    config: TrackerConfig,
    vts: VtsUnwrapper,
    clock: ClockOffset,
    last_imu_raw_vts: Option<u32>,
    imu: VecDeque<ImuSample>,
    slam: Option<SlamSample>,
    /// Tracker-space velocity in m/s, smoothed over SLAM poses.
    velocity: Vec3,
    /// The same SLAM-derived estimator, reset for reporting across discontinuities.
    /// Keeping it separate leaves the existing display prediction trajectory intact.
    motion_velocity: Option<Vec3>,
    /// What the newest SLAM pose changed, still to be taken (`correction_smoothing_ns`): the
    /// turn (in the pose's own frame) and the pivot's shift that put the view back where it was
    /// when the pose arrived, and the time (headset clock) they were taken at.
    held_turn: Quat,
    held_shift: Vec3,
    held_at_vts: i64,
    /// The newest time a pose was asked for ahead of the data (a frame's), on the headset's clock.
    last_target_vts: std::sync::atomic::AtomicI64,
    recenter: Option<Pose>,
    status: HeadsetStatus,
}

impl HeadTracker {
    pub fn new(config: TrackerConfig) -> HeadTracker {
        HeadTracker {
            config,
            imu: VecDeque::with_capacity(IMU_HISTORY),
            ..Default::default()
        }
    }

    pub fn status(&self) -> HeadsetStatus {
        self.status
    }

    /// Estimated `host_ns - vts_ns`, once IMU data has arrived.
    pub fn clock_offset_ns(&self) -> Option<i64> {
        self.clock.offset_ns()
    }

    /// Feeds a status packet received at `host_ns` (host monotonic clock).
    pub fn ingest_status(&mut self, report: &StatusReport, host_ns: i64) {
        self.status = HeadsetStatus {
            worn: report.worn,
            function_button: report.function_button,
            ipd_mm: report.ipd_mm,
        };
        let mut newest = None;
        for rec in &report.imu {
            // vts_us ticks once per millisecond, so the two samples of a pair share a value; the
            // second one is really 500 us later (measured by GAV).
            let pair_fix = if self.last_imu_raw_vts == Some(rec.vts_us) {
                500
            } else {
                0
            };
            self.last_imu_raw_vts = Some(rec.vts_us);
            let vts_ns = self.vts.unwrap_ns(rec.vts_us) + pair_fix * 1000;
            if self.imu.len() == IMU_HISTORY {
                self.imu.pop_front();
            }
            self.imu.push_back(ImuSample {
                vts_ns,
                gyro: rec.gyro_rad_s(),
            });
            newest = Some(vts_ns);
        }
        if let Some(vts_ns) = newest {
            self.clock.update(vts_ns, host_ns);
        }
    }

    /// Feeds a SLAM record received at `host_ns`.
    pub fn ingest_slam(&mut self, record: &SlamRecord, host_ns: i64) {
        let mut orientation = record.tracking_orientation().normalized();
        // The tracker does not keep its quaternion sign continuous; pick the closer of q and -q.
        if let Some(prev) = self.slam
            && prev.orientation.dot(orientation) < 0.0
        {
            orientation = -orientation;
        }
        let position = record.tracking_position();
        let lever = (SLAM_CORRECTION * orientation).rotate(NECK_LEVER);
        let sample = SlamSample {
            vts_ns: self.vts.unwrap_ns(record.vts_us),
            host_ns,
            orientation,
            position,
            pivot: [0, 1, 2].map(|i| position[i] - lever[i]),
        };
        // Where the view was, for the frame being drawn now, before this pose: what it changes
        // is taken gradually.
        let anchor = self
            .last_target_vts
            .load(std::sync::atomic::Ordering::Relaxed)
            .max(sample.vts_ns);
        let before = match self.slam {
            Some(prev)
                if self.config.correction_smoothing_ns > 0
                    && (5_000_000..=100_000_000).contains(&(sample.vts_ns - prev.vts_ns)) =>
            {
                Some(self.carried(&prev, anchor))
            }
            _ => None,
        };
        match self.slam {
            Some(prev) if (5_000_000..=100_000_000).contains(&(sample.vts_ns - prev.vts_ns)) => {
                let dt = (sample.vts_ns - prev.vts_ns) as f32 * 1e-9;
                let v = [0, 1, 2].map(|i| (sample.pivot[i] - prev.pivot[i]) / dt);
                // Nearly still, the differences are mostly the positions' own shake: smoothed
                // harder there.
                let speed = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
                let weight = if self.config.still_speed > 0.0 {
                    VELOCITY_SMOOTHING * (speed / self.config.still_speed).clamp(0.2, 1.0)
                } else {
                    VELOCITY_SMOOTHING
                };
                for (smoothed, newest) in self.velocity.iter_mut().zip(v) {
                    *smoothed += (newest - *smoothed) * weight;
                }
                let previous = self.motion_velocity.unwrap_or([0.; 3]);
                self.motion_velocity = v
                    .iter()
                    .all(|x| x.is_finite())
                    .then(|| [0, 1, 2].map(|i| previous[i] + (v[i] - previous[i]) * weight));
            }
            _ => {
                self.velocity = [0.0; 3];
                self.motion_velocity = None;
            }
        }
        self.slam = Some(sample);
        self.held_turn = Quat::IDENTITY;
        self.held_shift = [0.0; 3];
        self.held_at_vts = anchor;
        if let Some((orientation, pivot)) = before {
            let (now, now_pivot) = self.carried(&sample, anchor);
            let turn = (now.conjugate() * orientation).normalized();
            let shift = [0, 1, 2].map(|i| pivot[i] - now_pivot[i]);
            let far = shift[0].abs().max(shift[1].abs()).max(shift[2].abs());
            // A real jump (tracking found again, a relocalization) is taken at once.
            if Quat::IDENTITY.angle_to(turn) < 0.035 && far < 0.03 {
                self.held_turn = turn;
                self.held_shift = shift;
            } else {
                // Reuse the tracker's existing relocalization/correction test:
                // a source-coordinate jump is not physical head velocity.
                self.motion_velocity = None;
            }
        }
    }

    /// How much of the held correction is still untaken at `target_vts`.
    fn held(&self, target_vts: i64) -> f32 {
        if self.config.correction_smoothing_ns <= 0 {
            return 0.0;
        }
        let since = (target_vts - self.held_at_vts).max(0) as f32;
        (-since / self.config.correction_smoothing_ns as f32).exp()
    }

    /// The speed below which the velocity is carried forward less: its share at this speed.
    fn carried_share(&self) -> f32 {
        if self.config.still_speed <= 0.0 {
            return 1.0;
        }
        let v = self.velocity;
        let speed = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
        (speed / self.config.still_speed).clamp(0.0, 1.0)
    }

    /// The orientation (the gyro's frame, before the 90° correction) and the pivot a pose gives
    /// for `target_vts`, with what is held of the last correction.
    fn carried(&self, slam: &SlamSample, target_vts: i64) -> (Quat, Vec3) {
        let k = self.held(target_vts);
        let mut orientation = self.integrate(slam, target_vts);
        if k > 0.0 {
            orientation = (orientation * Quat::IDENTITY.nlerp(self.held_turn, k)).normalized();
        }
        let ahead =
            (target_vts - slam.vts_ns).clamp(0, MAX_POSITION_EXTRAPOLATION_NS) as f32 * 1e-9;
        let share = self.carried_share();
        let pivot = [0, 1, 2]
            .map(|i| slam.pivot[i] + self.velocity[i] * ahead * share + self.held_shift[i] * k);
        (orientation, pivot)
    }

    /// Head pose predicted for host time `at_host_ns`, or `None` without a live SLAM stream.
    pub fn predict(&self, at_host_ns: i64) -> Option<HeadPose> {
        let slam = self.slam?;
        if at_host_ns - slam.host_ns > self.config.stale_after_ns {
            return None;
        }
        let latest_gyro = self.imu.back().map_or([0.0; 3], |s| s.gyro);

        let (orientation, pivot, predicted, slam_age_ns) = match self.clock.host_to_vts(at_host_ns)
        {
            None => (
                slam.orientation,
                slam.pivot,
                false,
                at_host_ns - slam.host_ns,
            ),
            Some(target) => {
                // A pose asked for ahead of the data is a frame's: where the next
                // correction will be taken from.
                if self.imu.back().is_some_and(|s| target > s.vts_ns) {
                    self.last_target_vts
                        .fetch_max(target, std::sync::atomic::Ordering::Relaxed);
                }
                let (orientation, pivot) = self.carried(&slam, target);
                (orientation, pivot, true, target - slam.vts_ns)
            }
        };

        let position = if predicted && self.config.predict_position {
            let lever = (SLAM_CORRECTION * orientation).rotate(NECK_LEVER);
            [0, 1, 2].map(|i| pivot[i] + lever[i])
        } else {
            slam.position
        };
        let tracker = Pose {
            position,
            orientation: SLAM_CORRECTION * orientation,
        };
        let head = tracker.compose(SLAM_TO_HEAD);
        let pose = match self.recenter {
            Some(r) => r.compose(head),
            None => head,
        };
        let gyro_fresh = self.imu.back().is_some_and(|s| {
            self.clock
                .host_to_vts(at_host_ns)
                .is_some_and(|target| (target - s.vts_ns).abs() <= self.config.max_extrapolation_ns)
        });
        let angular_known = gyro_fresh && latest_gyro.iter().all(|x| x.is_finite());
        let linear_known = angular_known
            && slam_age_ns >= 0
            && slam_age_ns <= MAX_POSITION_EXTRAPOLATION_NS
            && self.motion_velocity.is_some();
        let linear_velocity = if linear_known {
            let omega = tracker.orientation.rotate(latest_gyro);
            let lever = tracker
                .orientation
                .rotate([0, 1, 2].map(|i| NECK_LEVER[i] + SLAM_TO_HEAD.position[i]));
            let pivot = self.motion_velocity.unwrap();
            let spin = [
                omega[1] * lever[2] - omega[2] * lever[1],
                omega[2] * lever[0] - omega[0] * lever[2],
                omega[0] * lever[1] - omega[1] * lever[0],
            ];
            let velocity = [0, 1, 2].map(|i| pivot[i] + spin[i]);
            self.recenter
                .map_or(velocity, |r| r.orientation.rotate(velocity))
        } else {
            [0.; 3]
        };
        let linear_known = linear_known && linear_velocity.iter().all(|x| x.is_finite());
        Some(HeadPose {
            pose,
            angular_velocity: latest_gyro,
            linear_velocity: if linear_known {
                linear_velocity
            } else {
                [0.; 3]
            },
            motion_flags: u32::from(linear_known) | (u32::from(angular_known) << 1),
            slam_age_ns,
            predicted,
        })
    }

    /// SLAM orientation carried forward to `target_vts` by the gyro.
    fn integrate(&self, slam: &SlamSample, target_vts: i64) -> Quat {
        if target_vts <= slam.vts_ns {
            return slam.orientation;
        }
        let mut delta = Quat::IDENTITY;
        let mut covered_until = slam.vts_ns;
        let mut gyro = [0.0; 3];
        for s in self
            .imu
            .iter()
            .filter(|s| s.vts_ns > slam.vts_ns && s.vts_ns <= target_vts)
        {
            // A sample stands for the period before its timestamp; the first one after the pose
            // only counts from the pose time on, so the start is sub-sample accurate.
            let dt_ns = (s.vts_ns - covered_until.max(s.vts_ns - IMU_PERIOD_NS)).max(0);
            delta = delta * Quat::from_rotation_vector(scaled(s.gyro, dt_ns));
            covered_until = s.vts_ns;
            gyro = s.gyro;
        }
        if covered_until == slam.vts_ns {
            // No IMU sample since the pose yet: extrapolate with the latest one we have.
            gyro = self.imu.back().map_or([0.0; 3], |s| s.gyro);
        }
        // Past the newest sample: the mean angular velocity of the last few milliseconds.
        let mut moving = 1.0f32;
        if let Some(newest) = self.imu.back() {
            let mut window = self.config.extrapolation_window_ns;
            if self.config.still_turn > 0.0 {
                // How fast the head turns now: the mean of the last 4 ms.
                let mut sum = [0.0f32; 3];
                let mut n = 0.0f32;
                for s in self
                    .imu
                    .iter()
                    .rev()
                    .take_while(|s| s.vts_ns > newest.vts_ns - 4_000_000)
                {
                    sum = [sum[0] + s.gyro[0], sum[1] + s.gyro[1], sum[2] + s.gyro[2]];
                    n += 1.0;
                }
                let speed =
                    (sum[0] * sum[0] + sum[1] * sum[1] + sum[2] * sum[2]).sqrt() / n.max(1.0);
                let still = 1.0 - (speed / self.config.still_turn).clamp(0.0, 1.0);
                moving = 1.0 - still;
                if self.config.still_window_ns > window {
                    window += ((self.config.still_window_ns - window) as f32 * still) as i64;
                }
            }
            let from = newest.vts_ns - window;
            let mut sum = [0.0f32; 3];
            let mut n = 0.0f32;
            for s in self.imu.iter().rev().take_while(|s| s.vts_ns > from) {
                sum = [sum[0] + s.gyro[0], sum[1] + s.gyro[1], sum[2] + s.gyro[2]];
                n += 1.0;
            }
            if n > 0.0 {
                gyro = [sum[0] / n, sum[1] / n, sum[2] / n];
            }
        }
        let tail_ns = (target_vts - covered_until).min(self.config.max_extrapolation_ns);
        // The rate's change, carried ahead with it: the rate at the newest sample is the last
        // span's mean plus half a span of change, and over the tail it changes on.
        let span = self.config.acceleration_window_ns;
        if span > 0
            && moving > 0.0
            && tail_ns > 0
            && let Some(newest) = self.imu.back()
        {
            let mean = |from: i64, to: i64| {
                let mut sum = [0.0f32; 3];
                let mut n = 0.0f32;
                for s in self
                    .imu
                    .iter()
                    .rev()
                    .skip_while(|s| s.vts_ns > to)
                    .take_while(|s| s.vts_ns > from)
                {
                    sum = [sum[0] + s.gyro[0], sum[1] + s.gyro[1], sum[2] + s.gyro[2]];
                    n += 1.0;
                }
                (n > 0.0).then(|| [sum[0] / n, sum[1] / n, sum[2] / n])
            };
            let now = newest.vts_ns;
            if let (Some(late), Some(early)) =
                (mean(now - span, now), mean(now - 2 * span, now - span))
            {
                let span_s = span as f32 * 1e-9;
                let tail_s = tail_ns as f32 * 1e-9;
                for i in 0..3 {
                    let change = (late[i] - early[i]) / span_s;
                    let ahead = late[i] + change * (span_s * 0.5 + tail_s * 0.5);
                    gyro[i] += (ahead - gyro[i]) * moving;
                }
            }
        }
        delta = delta * Quat::from_rotation_vector(scaled(gyro, tail_ns));
        (slam.orientation * delta).normalized()
    }

    /// Recenters so that the current heading becomes forward (−z) and the current position the
    /// origin, keeping the horizon level and the height.
    pub fn recenter_yaw(&mut self, at_host_ns: i64) {
        self.recenter = None;
        let Some(h) = self.predict(at_host_ns) else {
            return;
        };
        let r = Quat::from_axis_angle([0.0, 1.0, 0.0], -h.pose.orientation.yaw());
        let p = h.pose.position;
        let moved = r.rotate([p[0], 0.0, p[2]]);
        self.recenter = Some(Pose {
            position: [-moved[0], -moved[1], -moved[2]],
            orientation: r,
        });
    }

    /// Recenters fully: the current orientation becomes identity (useful lying down).
    pub fn recenter_full(&mut self, at_host_ns: i64) {
        self.recenter = None;
        let Some(h) = self.predict(at_host_ns) else {
            return;
        };
        let r = h.pose.orientation.conjugate();
        let rp = r.rotate(h.pose.position);
        self.recenter = Some(Pose {
            position: [-rp[0], h.pose.position[1] - rp[1], -rp[2]],
            orientation: r,
        });
    }

    pub fn clear_recenter(&mut self) {
        self.recenter = None;
    }
}

fn scaled(gyro: Vec3, dt_ns: i64) -> Vec3 {
    let dt = dt_ns as f32 * 1e-9;
    [gyro[0] * dt, gyro[1] * dt, gyro[2] * dt]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::math::tests::{assert_quat, assert_vec};
    use crate::psvr2::protocol::{GYRO_SCALE_DEG_S, ImuRecord};

    const MS: i64 = 1_000_000;
    /// Host clock = VTS clock + 7 ms + 1 ms transport delay in these tests.
    const OFFSET: i64 = 7 * MS;
    const DELAY: i64 = MS;

    /// Raw gyro counts for an angular velocity in tracking axes (inverse of `gyro_rad_s`).
    fn raw_gyro(rad_s: Vec3) -> [i16; 3] {
        let s = GYRO_SCALE_DEG_S.to_radians();
        let r = |v: f32| (v / s).round() as i16;
        [r(-rad_s[2]), r(-rad_s[0]), r(rad_s[1])]
    }

    /// Raw SLAM orientation for an orientation in tracking axes (inverse of `tracking_orientation`).
    fn slam_record(vts_us: u32, orientation: Quat, position: Vec3) -> SlamRecord {
        let q = orientation;
        SlamRecord {
            vts_us,
            unknown1: 3,
            position: [-position[2], position[1], position[0]],
            orientation: Quat {
                w: q.w,
                x: -q.y,
                y: -q.x,
                z: q.z,
            },
        }
    }

    /// One status packet with two IMU samples, like the hardware sends at 1 kHz.
    fn status_pair(vts_us: u32, gyro: [i16; 3]) -> StatusReport {
        let rec = ImuRecord {
            vts_us,
            accel: [0, 8192, 0],
            gyro,
            dp_frame_count: 0,
            dp_line_count: 0,
            imu_ts_us: 0,
            status: 0,
        };
        StatusReport {
            dprx_status: 2,
            worn: true,
            function_button: false,
            ipd_mm: 63,
            imu: vec![rec, rec],
        }
    }

    /// Feeds `ms` milliseconds of IMU at a constant rate starting at VTS `start_us`.
    fn feed_imu(t: &mut HeadTracker, start_us: u32, ms: u32, gyro: [i16; 3]) {
        for i in 0..ms {
            let vts = start_us + i * 1000;
            // The pair's second sample is at vts + 500 us; the packet arrives after it.
            t.ingest_status(
                &status_pair(vts, gyro),
                (vts as i64 + 500) * 1000 + OFFSET + DELAY,
            );
        }
    }

    fn expected(orientation: Quat, position: Vec3) -> Pose {
        Pose {
            position,
            orientation: SLAM_CORRECTION * orientation,
        }
        .compose(SLAM_TO_HEAD)
    }

    #[test]
    fn nothing_without_slam() {
        let t = HeadTracker::new(TrackerConfig::default());
        assert!(t.predict(0).is_none());
    }

    #[test]
    fn slam_only_until_imu_arrives() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        let q = Quat::from_axis_angle([0.0, 1.0, 0.0], 0.3);
        t.ingest_slam(&slam_record(10_000, q, [0.1, 1.6, -0.2]), 50 * MS);
        let h = t.predict(60 * MS).unwrap();
        assert!(!h.predicted);
        let e = expected(q, [0.1, 1.6, -0.2]);
        assert_quat(h.pose.orientation, e.orientation, 1e-6);
        assert_vec(h.pose.position, e.position, 1e-6);
    }

    #[test]
    fn still_headset_predicts_the_slam_pose() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        feed_imu(&mut t, 0, 100, [0; 3]);
        let q = Quat::from_axis_angle([1.0, 0.0, 0.0], -0.2);
        t.ingest_slam(&slam_record(77_000, q, [0.0, 1.7, 0.0]), 100 * MS + OFFSET);
        let h = t.predict(120 * MS + OFFSET).unwrap();
        assert!(h.predicted);
        assert_quat(
            h.pose.orientation,
            expected(q, [0.0, 1.7, 0.0]).orientation,
            1e-6,
        );
    }

    #[test]
    fn a_moving_head_is_carried_forward() {
        // 0.3 m/s along x, no turning: SLAM poses 60 times a second, each arriving 23 ms old.
        let v = 0.3f32;
        let at = |us: u32| [v * us as f32 * 1e-6, 1.6, 0.0];
        let mut t = HeadTracker::new(TrackerConfig::default());
        let mut held = HeadTracker::new(TrackerConfig {
            predict_position: false,
            ..Default::default()
        });
        feed_imu(&mut t, 0, 700, [0; 3]);
        feed_imu(&mut held, 0, 700, [0; 3]);
        let mut last = 0;
        // (Forty poses: the first ones' corrections, taken gradually, have died away by then.)
        for i in 1..=40u32 {
            last = i * 16_667;
            let host = (last as i64 * 1000) + 23 * MS + OFFSET;
            t.ingest_slam(&slam_record(last, Quat::IDENTITY, at(last)), host);
            held.ingest_slam(&slam_record(last, Quat::IDENTITY, at(last)), host);
        }
        // 30 ms after the newest pose was sampled.
        let target = last + 30_000;
        let host = target as i64 * 1000 + OFFSET;
        let want = expected(Quat::IDENTITY, at(target)).position;
        let got = t.predict(host).unwrap().pose.position;
        assert_vec(got, want, 1e-3);
        // Held as sent, it is 9 mm behind.
        let behind = held.predict(host).unwrap().pose.position;
        assert!((want[0] - behind[0] - v * 0.03).abs() < 1e-3);
    }

    #[test]
    fn reported_eye_velocity_matches_translated_rotating_pose_and_recenter_basis() {
        // Independently differentiate the existing predicted position, with
        // smoothing disabled so correction decay cannot masquerade as motion.
        for seed in 1..=20 {
            let a = seed as f32 * 0.13;
            let q = Quat::from_axis_angle([1., 0., 0.], a)
                * Quat::from_axis_angle([0., 1., 0.], -a * 0.7)
                * Quat::from_axis_angle([0., 0., 1.], a * 0.3);
            let gyro = [0.21 + a * 0.02, -0.31, 0.17];
            let raw = raw_gyro(gyro);
            let mut t = HeadTracker::new(TrackerConfig {
                correction_smoothing_ns: 0,
                still_speed: 0.,
                still_window_ns: 0,
                still_turn: 0.,
                ..Default::default()
            });
            feed_imu(&mut t, 0, 700, raw);
            let velocity = [0.3, -0.13, 0.19];
            let mut last = 0;
            for i in 1..=40u32 {
                last = i * 16_667;
                let position = [0, 1, 2].map(|axis| {
                    velocity[axis] * last as f32 * 1e-6 + if axis == 1 { 1.6 } else { 0. }
                });
                t.ingest_slam(
                    &slam_record(last, q, position),
                    last as i64 * 1000 + OFFSET + 23 * MS,
                );
            }
            let at = last as i64 * 1000 + OFFSET + 20 * MS;
            let pose = t.predict(at).unwrap();
            assert_eq!(pose.motion_flags, 3);
            let delta = 100_000;
            let before = t.predict(at - delta).unwrap().pose.position;
            let after = t.predict(at + delta).unwrap().pose.position;
            let measured = [0, 1, 2].map(|i| (after[i] - before[i]) / (2 * delta) as f32 * 1e9);
            assert_vec(pose.linear_velocity, measured, 0.002);
            let r = Pose {
                position: [100., -13., 87.],
                orientation: Quat::from_axis_angle([0., 1., 0.], a)
                    * Quat::from_axis_angle([0., 0., 1.], -0.4),
            };
            t.recenter = Some(r);
            let transformed = t.predict(at).unwrap();
            assert_eq!(transformed.motion_flags, 3);
            assert_vec(
                transformed.linear_velocity,
                r.orientation.rotate(pose.linear_velocity),
                1e-5,
            );
            // No velocity from recenter translation, and gyro remains body-local.
            assert_vec(transformed.angular_velocity, pose.angular_velocity, 1e-6);
        }
    }

    #[test]
    fn motion_unknown_on_first_sample_gaps_and_relocalization_then_recovers() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        feed_imu(&mut t, 0, 200, [0; 3]);
        t.ingest_slam(
            &slam_record(180_000, Quat::IDENTITY, [0., 1.6, 0.]),
            188 * MS,
        );
        assert_eq!(
            t.predict(198 * MS).unwrap().motion_flags,
            2,
            "one SLAM sample cannot measure translation"
        );
        t.ingest_slam(
            &slam_record(196_000, Quat::IDENTITY, [0., 1.6, 0.]),
            204 * MS,
        );
        let still = t.predict(208 * MS).unwrap();
        assert_eq!(still.motion_flags, 3);
        assert_vec(still.linear_velocity, [0.; 3], 1e-6);
        assert_eq!(
            t.predict(310 * MS).unwrap().motion_flags,
            0,
            "stale gyro and capped translation are unknown"
        );
        feed_imu(&mut t, 200_000, 160, [0; 3]);
        t.ingest_slam(
            &slam_record(330_000, Quat::IDENTITY, [0., 1.6, 0.]),
            338 * MS,
        );
        assert_eq!(
            t.predict(348 * MS).unwrap().motion_flags,
            2,
            "gap resets translation history"
        );
        t.ingest_slam(
            &slam_record(346_000, Quat::IDENTITY, [1., 1.6, 0.]),
            354 * MS,
        );
        assert_eq!(
            t.predict(360 * MS).unwrap().motion_flags,
            2,
            "relocalization is not physical velocity"
        );
        feed_imu(&mut t, 360_000, 970, [0; 3]);
        // The existing display correction may still be unwinding the jump;
        // report no translation until the tracker's continuity test settles.
        for i in 1..=60 {
            let us = 346_000 + i * 16_000;
            t.ingest_slam(
                &slam_record(us, Quat::IDENTITY, [1., 1.6, 0.]),
                us as i64 * 1000 + 8 * MS,
            );
        }
        let recovered = t.predict(1320 * MS).unwrap();
        assert_eq!(recovered.motion_flags, 3);
        assert_vec(recovered.linear_velocity, [0.; 3], 1e-6);
    }

    #[test]
    fn a_pose_that_disagrees_is_taken_gradually() {
        // A still head whose SLAM poses shake by a fifth of a millimetre: frame to frame, the view moves
        // far less than the poses do, and ends where they say.
        let mut steady = HeadTracker::new(TrackerConfig::default());
        let mut at_once = HeadTracker::new(TrackerConfig {
            correction_smoothing_ns: 0,
            still_speed: 0.0,
            ..Default::default()
        });
        feed_imu(&mut steady, 0, 1200, [0; 3]);
        feed_imu(&mut at_once, 0, 1200, [0; 3]);
        let (mut steady_steps, mut at_once_steps) = (0.0f32, 0.0f32);
        let mut before = [None, None];
        for i in 1..=60u32 {
            let vts = i * 16_667;
            let x = if i % 2 == 0 { 0.0002 } else { 0.0 };
            let host = (vts as i64 * 1000) + 23 * MS + OFFSET;
            for (k, t) in [&mut steady, &mut at_once].into_iter().enumerate() {
                t.ingest_slam(&slam_record(vts, Quat::IDENTITY, [x, 1.6, 0.0]), host);
                let now = t.predict(host + 34 * MS).unwrap().pose.position[0];
                if let Some(b) = before[k] {
                    let step: f32 = now - b;
                    if k == 0 {
                        steady_steps += step.abs();
                    } else {
                        at_once_steps += step.abs();
                    }
                }
                before[k] = Some(now);
            }
        }
        assert!(at_once_steps > 0.01, "{at_once_steps}");
        assert!(
            steady_steps < at_once_steps * 0.3,
            "{steady_steps} of {at_once_steps}"
        );
        // And it is where the poses are (within their own shake of the view that follows each).
        assert!((before[0].unwrap() - before[1].unwrap()).abs() < 0.0004);
    }

    #[test]
    fn constant_yaw_rate_is_integrated_and_extrapolated() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        let gyro = raw_gyro([0.0, 1.0, 0.0]); // ~1 rad/s, turning left
        let rate = status_pair(0, gyro).imu[0].gyro_rad_s()[1];
        feed_imu(&mut t, 0, 100, gyro);

        // SLAM pose taken at VTS 60 ms (arrives 23 ms later), heading 0.5 rad.
        let q0 = Quat::from_axis_angle([0.0, 1.0, 0.0], 0.5);
        t.ingest_slam(&slam_record(60_000, q0, [0.0; 3]), 83 * MS + OFFSET);

        // Predict 20 ms past the newest IMU sample (VTS 99.5 ms): 59.5 ms after the pose.
        let target_vts = 119_500_000i64;
        let h = t.predict(target_vts + OFFSET).unwrap();
        let elapsed_s = (target_vts - 60 * MS) as f32 * 1e-9;
        let want = Quat::from_axis_angle([0.0, 1.0, 0.0], 0.5 + rate * elapsed_s);
        // Clock offset estimate is off by the minimum transport delay (1 ms), i.e. 1 mrad here.
        assert_quat(
            h.pose.orientation,
            expected(want, [0.0; 3]).orientation,
            2.5e-3,
        );
        assert!((h.angular_velocity[1] - rate).abs() < 1e-6);
        assert!((h.slam_age_ns - (target_vts - 60 * MS)).abs() <= 2 * MS);
    }

    #[test]
    fn integration_starts_exactly_at_the_pose_time() {
        // Pose between two IMU samples: only the part after the pose may count.
        let mut t = HeadTracker::new(TrackerConfig::default());
        let gyro = raw_gyro([0.0, 2.0, 0.0]);
        let rate = status_pair(0, gyro).imu[0].gyro_rad_s()[1];
        feed_imu(&mut t, 0, 50, gyro);
        t.ingest_slam(
            &slam_record(20_200, Quat::IDENTITY, [0.0; 3]),
            45 * MS + OFFSET,
        );
        let target_vts = 40_000_000i64; // an IMU sample time
        let q = t.integrate(t.slam.as_ref().unwrap(), target_vts);
        let want = Quat::from_axis_angle([0.0, 1.0, 0.0], rate * 0.0198);
        assert_quat(q, want, 1e-4);
    }

    #[test]
    fn stale_stream_is_invalid() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        t.ingest_slam(&slam_record(0, Quat::IDENTITY, [0.0; 3]), 0);
        assert!(t.predict(499 * MS).is_some());
        assert!(t.predict(501 * MS).is_none());
    }

    #[test]
    fn quaternion_sign_flips_are_removed() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        let q = Quat::from_axis_angle([0.0, 1.0, 0.0], 3.0);
        t.ingest_slam(&slam_record(0, q, [0.0; 3]), 0);
        t.ingest_slam(&slam_record(16_000, -q, [0.0; 3]), 16 * MS);
        assert!(t.slam.unwrap().orientation.dot(q) > 0.0);
    }

    #[test]
    fn recenter_yaw_keeps_horizon_and_height() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        // Find the SLAM orientation whose head pose is yawed 1 rad and pitched 0.3 rad.
        let head = Quat::from_axis_angle([0.0, 1.0, 0.0], 1.0)
            * Quat::from_axis_angle([1.0, 0.0, 0.0], 0.3);
        let slam_q = SLAM_CORRECTION.conjugate() * head;
        t.ingest_slam(&slam_record(0, slam_q, [0.5, 1.6, -0.4]), 0);

        t.recenter_yaw(0);
        let h = t.predict(0).unwrap().pose;
        assert!(
            h.orientation.yaw().abs() < 1e-5,
            "yaw {}",
            h.orientation.yaw()
        );
        let fwd = h.orientation.rotate([0.0, 0.0, -1.0]);
        assert!((fwd[1] - 0.3f32.sin()).abs() < 1e-5, "pitch kept");
        assert!(h.position[0].abs() < 1e-5 && h.position[2].abs() < 1e-5);
        assert!((h.position[1] - expected(slam_q, [0.5, 1.6, -0.4]).position[1]).abs() < 1e-5);

        t.recenter_full(0);
        let h = t.predict(0).unwrap().pose;
        assert_quat(h.orientation, Quat::IDENTITY, 1e-5);
        assert!(h.position[0].abs() < 1e-5 && h.position[2].abs() < 1e-5);

        t.clear_recenter();
        assert_quat(t.predict(0).unwrap().pose.orientation, head, 1e-5);
    }

    #[test]
    fn status_is_exposed() {
        let mut t = HeadTracker::new(TrackerConfig::default());
        t.ingest_status(&status_pair(0, [0; 3]), 0);
        assert_eq!(
            t.status(),
            HeadsetStatus {
                worn: true,
                function_button: false,
                ipd_mm: 63
            }
        );
        assert_eq!(t.clock_offset_ns(), Some(-500_000));
    }
}
