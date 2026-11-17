//! Where a hand-held controller is between the cameras' sightings of it, and at the moment a
//! frame is seen: the cameras' places (a fix every 16.7 ms when the LEDs are found, 30 to 40 ms
//! old when it arrives, none at all while the controller is hidden or out of view) fused with
//! the controller's own accelerometer, which says several hundred times a second how its
//! motion changes.
//!
//! The method is the usual one for LED-tracked controllers (Monado's Rift S and PS VR trackers,
//! the Windows Mixed Reality papers): a Kalman filter per axis over place, velocity and the
//! accelerometer's bias, driven by the acceleration in the room's frame with gravity taken off
//! and corrected by each fix. A fix is of a moment already past, so the filter itself stays at
//! the newest fix's time and the accelerometer's samples since are kept: a place is asked for by
//! carrying a copy of the state through them, and a little past the newest. Nothing here is
//! ported: the model is the textbook one.
//!
//! Through a loss the place is carried by the accelerometer alone, which is good for a quarter
//! of a second or so; after that its velocity is let die away, so a hidden controller comes to
//! rest instead of sailing off. A fix after a loss, or one that moves the place by more than a
//! few millimeters, is taken over a short glide: what is drawn never jumps.

use crate::math::Vec3;

/// The accelerometer's noise as the model takes it, m/s² (it also stands for the error of the
/// orientation that turns it into the room's frame: a degree is 0.17 m/s²).
const ACCEL_NOISE: f64 = 0.8;
/// How fast the accelerometer's bias is let wander, m/s² per √s.
const BIAS_WALK: f64 = 0.3;
/// A fix's noise, m (the solver is steady to under a millimeter; this also covers its
/// occasional wrong lock a few millimeters off).
const FIX_NOISE: f64 = 0.002;
/// Without a fix for this long the velocity starts to die away, s.
const COAST: f64 = 0.25;
/// With this time constant, s.
const COAST_FADE: f64 = 0.12;
/// Without a fix for this long there is no place any more, s.
const LOST: f64 = 3.0;
/// A fix this far from where the filter had the controller is a new start, not a correction, m.
const JUMP: f64 = 0.35;
/// A correction larger than this is glided over, m.
const GLIDE_FROM: f64 = 0.004;
/// The glide's time constant, s.
const GLIDE: f64 = 0.045;
/// A place is carried at most this far past the newest accelerometer sample, s.
const PAST_NEWEST: f64 = 0.06;
/// Samples older than this are dropped (a fix is never that old), s.
const KEEP: f64 = 0.6;

/// One axis: place, velocity, the accelerometer's bias, and how sure each is.
#[derive(Debug, Clone, Copy)]
struct Axis {
    p: f64,
    v: f64,
    b: f64,
    /// Covariance, symmetric: pp, pv, pb, vv, vb, bb.
    c: [f64; 6],
}

impl Axis {
    fn at(p: f64) -> Axis {
        Axis {
            p,
            v: 0.0,
            b: 0.0,
            c: [FIX_NOISE * FIX_NOISE, 0.0, 0.0, 1.0, 0.0, 0.25],
        }
    }

    /// Carried on `dt` seconds under the measured acceleration `a` (m/s², gravity taken off).
    /// `fade`: the share of the velocity kept (1 while fixes come).
    fn carry(&mut self, a: f64, dt: f64, fade: f64) {
        let acc = a - self.b;
        self.p += self.v * dt + 0.5 * acc * dt * dt;
        self.v = (self.v + acc * dt) * fade;
        // P = F P Fᵀ + Q, with F = [1 dt -dt²/2; 0 1 -dt; 0 0 1].
        let [pp, pv, pb, vv, vb, bb] = self.c;
        let h = 0.5 * dt * dt;
        let n_pp =
            pp + 2.0 * dt * pv - 2.0 * h * pb + dt * dt * vv - 2.0 * dt * h * vb + h * h * bb;
        let n_pv = pv + dt * vv - h * vb - dt * (pb + dt * vb - h * bb);
        let n_pb = pb + dt * vb - h * bb;
        let n_vv = vv - 2.0 * dt * vb + dt * dt * bb;
        let n_vb = vb - dt * bb;
        let q = ACCEL_NOISE * ACCEL_NOISE;
        self.c = [
            n_pp + q * h * h,
            n_pv + q * h * dt,
            n_pb,
            n_vv + q * dt * dt,
            n_vb,
            bb + BIAS_WALK * BIAS_WALK * dt,
        ];
    }

    /// Corrected by a fix `z` of the place. Returns how far the place moved.
    fn fix(&mut self, z: f64) -> f64 {
        let [pp, pv, pb, vv, vb, bb] = self.c;
        let s = pp + FIX_NOISE * FIX_NOISE;
        let (kp, kv, kb) = (pp / s, pv / s, pb / s);
        let e = z - self.p;
        self.p += kp * e;
        self.v += kv * e;
        self.b = (self.b + kb * e).clamp(-3.0, 3.0);
        self.c = [
            pp - kp * pp,
            pv - kp * pv,
            pb - kp * pb,
            vv - kv * pv,
            vb - kv * pb,
            bb - kb * pb,
        ];
        kp * e
    }
}

/// A controller's place over time.
#[derive(Debug, Clone, Default)]
pub struct PlaceFilter {
    /// The state at `time` (the newest fix's moment), per axis; none before the first fix.
    axes: Option<[Axis; 3]>,
    time: f64,
    /// The accelerometer since then: when (s), and the acceleration in the room's frame with
    /// gravity taken off (m/s²). Oldest first.
    samples: std::collections::VecDeque<(f64, Vec3)>,
    /// What is still to be taken of the last large correction (m), as of `time`.
    glide: [f64; 3],
}

impl PlaceFilter {
    /// One accelerometer sample at `time` (seconds, the clock the fixes are on).
    pub fn sample(&mut self, time: f64, acceleration: Vec3) {
        if self.samples.back().is_some_and(|s| time <= s.0) {
            return;
        }
        self.samples.push_back((time, acceleration));
        while self.samples.front().is_some_and(|s| s.0 < time - KEEP) {
            self.samples.pop_front();
        }
    }

    /// The cameras saw the controller at `place` (m, the room's frame) at `time`.
    pub fn fix(&mut self, time: f64, place: Vec3) {
        let z = place.map(f64::from);
        let Some(mut axes) = self.axes else {
            self.start(time, z);
            return;
        };
        if time <= self.time {
            return;
        }
        let since = time - self.time;
        let before = self.glide_at(time);
        Self::carry(&mut axes, &self.samples, self.time, time, self.time);
        let off = (0..3)
            .map(|i| (z[i] - axes[i].p).powi(2))
            .sum::<f64>()
            .sqrt();
        if since > LOST || off > JUMP {
            // Not the same track any more: found again elsewhere.
            let shown: Vec<f64> = (0..3).map(|i| axes[i].p + before[i]).collect();
            self.start(time, z);
            if since <= LOST {
                self.glide = [shown[0] - z[0], shown[1] - z[1], shown[2] - z[2]];
            }
            return;
        }
        let moved = [0, 1, 2].map(|i| axes[i].fix(z[i]));
        // What is shown goes on from where it was: a large correction is taken gradually.
        let size = moved.iter().map(|m| m * m).sum::<f64>().sqrt();
        self.glide = before;
        if size > GLIDE_FROM {
            self.glide = [0, 1, 2].map(|i| self.glide[i] - moved[i]);
        }
        self.axes = Some(axes);
        self.time = time;
        self.drop_before(time);
    }

    /// Where the controller is at `time` and how it moves (m, m/s), or none: never seen, or not
    /// for too long.
    pub fn place(&self, time: f64) -> Option<(Vec3, Vec3)> {
        let mut axes = self.axes?;
        if time - self.time > LOST {
            return None;
        }
        let newest = self.samples.back().map_or(self.time, |s| s.0);
        let until = time.min(newest + PAST_NEWEST).max(self.time);
        Self::carry(&mut axes, &self.samples, self.time, until, self.time);
        // (The glide goes by the clock, also while no sample comes.)
        let glide = self.glide_at(time);
        Some((
            [0, 1, 2].map(|i| (axes[i].p + glide[i]) as f32),
            [0, 1, 2].map(|i| axes[i].v as f32),
        ))
    }

    /// Forgets the controller (it disconnected, the room's frame changed).
    pub fn reset(&mut self) {
        *self = PlaceFilter::default();
    }

    fn start(&mut self, time: f64, z: [f64; 3]) {
        self.axes = Some([Axis::at(z[0]), Axis::at(z[1]), Axis::at(z[2])]);
        self.time = time;
        self.glide = [0.0; 3];
        self.drop_before(time);
    }

    /// Drops the samples before `time`, but for the one in force at it.
    fn drop_before(&mut self, time: f64) {
        while self.samples.len() > 1 && self.samples[1].0 <= time {
            self.samples.pop_front();
        }
    }

    fn glide_at(&self, time: f64) -> [f64; 3] {
        let left = (-(time - self.time).max(0.0) / GLIDE).exp();
        self.glide.map(|g| g * left)
    }

    /// Carries `axes` from `from` to `to` through the samples in between (each stands until the
    /// next), the last one's acceleration held to the end. `fixed`: when the last fix was.
    fn carry(
        axes: &mut [Axis; 3],
        samples: &std::collections::VecDeque<(f64, Vec3)>,
        from: f64,
        to: f64,
        fixed: f64,
    ) {
        let mut now = from;
        let mut acceleration = [0.0f64; 3];
        // The sample in force at `from` (the newest at or before it), if any is kept.
        let mut next = 0;
        while next < samples.len() && samples[next].0 <= from {
            acceleration = samples[next].1.map(f64::from);
            next += 1;
        }
        while now < to {
            let end = if next < samples.len() {
                samples[next].0.min(to)
            } else {
                to
            };
            // In steps of 5 ms at most, so the fade is applied evenly.
            let mut t = now;
            while t < end {
                let dt = (end - t).min(0.005);
                let coasting = (t + dt - fixed - COAST).max(0.0);
                let fade = if coasting > 0.0 {
                    (-dt / COAST_FADE).exp()
                } else {
                    1.0
                };
                for i in 0..3 {
                    // Past the coast the accelerometer is no longer trusted to push the place.
                    let a = if coasting > 0.0 {
                        axes[i].b
                    } else {
                        acceleration[i]
                    };
                    axes[i].carry(a, dt, fade);
                }
                t += dt;
            }
            now = end;
            if next < samples.len() && samples[next].0 <= now {
                acceleration = samples[next].1.map(f64::from);
                next += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A hand swinging: where it is, how fast, and its acceleration at `t`.
    fn swing(t: f64) -> ([f64; 3], [f64; 3]) {
        let w = std::f64::consts::TAU * 1.2;
        let p = [
            0.25 * (w * t).sin(),
            1.2 + 0.10 * (1.7 * w * t).sin(),
            -0.4 + 0.15 * (0.6 * w * t).cos(),
        ];
        let a = [
            -0.25 * w * w * (w * t).sin(),
            -0.10 * (1.7 * w).powi(2) * (1.7 * w * t).sin(),
            -0.15 * (0.6 * w).powi(2) * (0.6 * w * t).cos(),
        ];
        (p, a)
    }

    /// A little noise, the same every run.
    fn noise(seed: &mut u64) -> f64 {
        *seed = seed
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((*seed >> 33) as f64 / (1u64 << 31) as f64) - 1.0
    }

    /// Runs the swing for 6 s: the accelerometer at 250 Hz with noise and a bias, fixes at
    /// 60 Hz arriving 35 ms late, none during `hidden`. Returns the mean and the worst error of
    /// the place asked for at each display frame (120 Hz, 12 ms ahead of "now"), in mm, for the
    /// filter and for what was done before it (the newest fix carried along its velocity).
    fn run(hidden: std::ops::Range<f64>) -> ((f64, f64), (f64, f64)) {
        let mut filter = PlaceFilter::default();
        let mut seed = 7u64;
        let bias = [0.15, -0.1, 0.2];
        let (mut next_sample, mut next_fix, mut next_frame) = (0.0, 0.0, 1.0);
        let mut pending: std::collections::VecDeque<(f64, f64, [f64; 3])> = Default::default();
        // The old way's memory: the newest fix, when it was of, the velocity between fixes.
        let mut old: Option<(f64, [f64; 3], [f64; 3])> = None;
        let (mut sum, mut worst, mut old_sum, mut old_worst, mut n) =
            (0.0, 0.0f64, 0.0, 0.0f64, 0.0);
        let mut t = 0.0;
        while t < 6.0 {
            if t >= next_sample {
                let (_, a) = swing(t);
                filter.sample(
                    t,
                    [0, 1, 2].map(|i| (a[i] + bias[i] + 0.3 * noise(&mut seed)) as f32),
                );
                next_sample += 1.0 / 250.0;
            }
            if t >= next_fix {
                if !hidden.contains(&t) {
                    let (p, _) = swing(t);
                    pending.push_back((
                        t + 0.035,
                        t,
                        [0, 1, 2].map(|i| p[i] + 0.0004 * noise(&mut seed)),
                    ));
                }
                next_fix += 1.0 / 60.0;
            }
            while pending.front().is_some_and(|f| f.0 <= t) {
                let (_, of, z) = pending.pop_front().unwrap();
                filter.fix(of, z.map(|v| v as f32));
                let velocity = match old {
                    Some((before, p, v)) if of - before < 0.06 => {
                        [0, 1, 2].map(|i| 0.5 * v[i] + 0.5 * (z[i] - p[i]) / (of - before))
                    }
                    _ => [0.0; 3],
                };
                old = Some((of, z, velocity));
            }
            if t >= next_frame {
                let seen = t + 0.012;
                let (truth, _) = swing(seen);
                if let Some((p, _)) = filter.place(seen) {
                    let e = (0..3)
                        .map(|i| (f64::from(p[i]) - truth[i]).powi(2))
                        .sum::<f64>()
                        .sqrt()
                        * 1000.0;
                    sum += e;
                    worst = worst.max(e);
                }
                if let Some((of, p, v)) = old {
                    // As `AppDelegate.handPlace` did: along the velocity, dying away in 120 ms.
                    let since = seen - of;
                    let reach = 0.12 * (1.0 - (-since / 0.12).exp());
                    let e = (0..3)
                        .map(|i| (p[i] + v[i] * reach - truth[i]).powi(2))
                        .sum::<f64>()
                        .sqrt()
                        * 1000.0;
                    old_sum += e;
                    old_worst = old_worst.max(e);
                }
                n += 1.0;
                next_frame += 1.0 / 120.0;
            }
            t += 0.0005;
        }
        ((sum / n, worst), (old_sum / n, old_worst))
    }

    #[test]
    fn a_swinging_hand_is_followed_far_closer_than_by_its_last_fix() {
        let ((mean, worst), (old_mean, old_worst)) = run(0.0..0.0);
        println!(
            "seen throughout: {mean:.1} mm (worst {worst:.1}); before: {old_mean:.1} mm (worst {old_worst:.1})"
        );
        assert!(mean < 4.0, "mean {mean}");
        assert!(mean < old_mean / 3.0, "{mean} against {old_mean}");
    }

    #[test]
    fn a_short_loss_is_bridged_by_the_accelerometer() {
        // Hidden for 200 ms in the middle of the swing.
        let ((mean, worst), (old_mean, old_worst)) = run(3.0..3.2);
        println!(
            "hidden 200 ms: {mean:.1} mm (worst {worst:.1}); before: {old_mean:.1} mm (worst {old_worst:.1})"
        );
        assert!(worst < old_worst / 2.0, "{worst} against {old_worst}");
        assert!(worst < 40.0, "worst {worst}");
    }

    #[test]
    fn a_hidden_controller_comes_to_rest_and_is_then_lost() {
        let mut filter = PlaceFilter::default();
        for k in 0..30 {
            let t = f64::from(k) / 60.0;
            filter.sample(t, [0.0; 3]);
            filter.fix(t, [(0.5 * t) as f32, 1.0, 0.0]); // moving at 0.5 m/s
        }
        let last = 29.0 / 60.0;
        for k in 1..500 {
            filter.sample(last + f64::from(k) / 250.0, [0.0; 3]);
        }
        let (soon, _) = filter.place(last + 0.1).unwrap();
        let (later, velocity) = filter.place(last + 1.5).unwrap();
        assert!(
            soon[0] > (0.5 * last) as f32 + 0.03,
            "it is carried on at first"
        );
        assert!(
            (later[0] - (0.5 * last) as f32) < 0.35,
            "and doesn't sail off: {}",
            later[0]
        );
        assert!(velocity[0].abs() < 0.01, "at rest: {}", velocity[0]);
        assert!(filter.place(last + 4.0).is_none());
    }

    #[test]
    fn a_fix_far_off_is_a_new_start_shown_without_a_jump() {
        let mut filter = PlaceFilter::default();
        for k in 0..20 {
            filter.fix(f64::from(k) / 60.0, [0.0, 1.0, 0.0]);
        }
        let t = 20.0 / 60.0;
        filter.fix(t, [0.6, 1.0, 0.0]);
        let (at_once, _) = filter.place(t).unwrap();
        let (after, _) = filter.place(t + 0.3).unwrap();
        assert!(
            at_once[0] < 0.05,
            "what is shown starts where it was: {}",
            at_once[0]
        );
        assert!((after[0] - 0.6).abs() < 0.01, "and arrives: {}", after[0]);
    }
}
