//! Transactional two-controller association over one immutable exposure.
//! No change to Sense geometry, sensor orientation or the accepted game mount.

use super::super::stereo::{PSVR2_BOTTOM, PSVR2_BOTTOM_PLACE, PSVR2_TOP};
use super::*;
use std::collections::BTreeSet;

type Claims = BTreeSet<(usize, usize)>; // exact (view, original source-spot index)

#[derive(Clone, Copy, Debug, Default)]
pub struct PairDiagnostics {
    pub exposures: u64,
    pub disjoint_fast_path: u64,
    pub conflicting_exposures: u64,
    pub ambiguous_exposures: u64,
    pub temporal_rejections: [u64; 2],
}

#[derive(Clone)]
struct Candidate {
    tracker: HandTracker,
    solution: Option<Solution>,
}

impl Candidate {
    fn claims(&self) -> Claims {
        self.solution
            .as_ref()
            .map(|s| s.sightings.iter().map(|v| (v.view, v.spot)).collect())
            .unwrap_or_default()
    }
    fn quality(&self) -> f64 {
        self.solution
            .as_ref()
            .map_or(0., |s| s.sightings.len() as f64 / (1. + s.rms * s.rms))
    }
}

#[derive(Clone, Copy)]
struct Accepted {
    time: u64,
    position: V3,
    velocity: V3,
}

#[derive(Clone, Copy)]
struct Pending {
    time: u64,
    counter: u64,
    position: V3,
    heading: f64,
    /// Separate provisional hypothesis, never the committed solver heading/pose.
    stereo_tilt: Option<[f64; 2]>,
}

/// One camera exposure cannot assign the same actual blob to both controllers.
/// Individual fits run on clones. Only a selected, temporally accepted result
/// can update last position, heading or tilt; a rejected fit never reaches the
/// controller's inertial position filter.
#[derive(Clone)]
pub struct PairedHandTracker {
    trackers: [HandTracker; 2],
    accepted: [Option<Accepted>; 2],
    pending: [Option<Pending>; 2],
    last_frame: Option<u64>,
    fisheyes: bool,
    alignment: V3,
    diagnostics: PairDiagnostics,
}

impl Default for PairedHandTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl PairedHandTracker {
    pub fn new() -> Self {
        let mut trackers = [HandTracker::new(Hand::Left), HandTracker::new(Hand::Right)];
        for tracker in &mut trackers {
            tracker.paired_confirmation = true;
        }
        Self {
            trackers,
            accepted: [None; 2],
            pending: [None; 2],
            last_frame: None,
            fisheyes: false,
            alignment: [0.; 3],
            diagnostics: PairDiagnostics::default(),
        }
    }
    fn configure(&mut self, fisheyes: bool, alignment: V3) {
        *self = Self::new();
        self.fisheyes = fisheyes;
        self.alignment = alignment;
        for tracker in &mut self.trackers {
            tracker.set_bottom_fisheyes(fisheyes);
            assert!(tracker.set_bottom_fisheye_alignment(alignment));
        }
    }
    pub fn set_bottom_fisheyes(&mut self, on: bool) {
        if self.fisheyes != on {
            self.configure(on, self.alignment);
        }
    }
    pub fn set_bottom_fisheye_alignment(&mut self, rotation: V3) -> bool {
        if !rotation.iter().all(|v| v.is_finite())
            || dot(rotation, rotation) > 5f64.to_radians().powi(2)
        {
            return false;
        }
        if self.alignment != rotation {
            self.configure(self.fisheyes, rotation);
        }
        true
    }
    pub fn diagnostics(&self) -> PairDiagnostics {
        self.diagnostics
    }

    fn propose(&self, hand: usize, frame: &Frame, seen: &Seen, world: &M3) -> Candidate {
        let mut tracker = self.trackers[hand].clone();
        tracker.required_sightings = if frame.hands[1 - hand].is_none() {
            SCAN_SIGHTINGS
        } else {
            MIN_SIGHTINGS
        };
        if let (Some(q), Some(pending)) = (frame.hands[hand], self.pending[hand]) {
            if let Some(tilt) = pending.stereo_tilt
                && frame.t_ns > pending.time
                && frame.t_ns - pending.time < 100_000_000
            {
                let mut trial = tracker.clone();
                trial.heading = pending.heading;
                trial.tilt = tilt;
                trial.last = Some(Self::camera_position(frame, pending.position));
                trial.lost = 0;
                if let Some(solution) = trial
                    .locate(seen, world, &from_quat(q))
                    .filter(Solution::strong_stereo)
                {
                    return Candidate {
                        tracker: trial,
                        solution: Some(solution),
                    };
                }
            }
        }
        let solution = frame.hands[hand].and_then(|q| tracker.locate(seen, world, &from_quat(q)));
        if frame.hands[hand].is_none() {
            tracker.lost = tracker.lost.saturating_add(1);
        }
        self.admit_candidate(hand, frame, tracker, solution)
    }

    fn admit_candidate(
        &self,
        hand: usize,
        frame: &Frame,
        tracker: HandTracker,
        solution: Option<Solution>,
    ) -> Candidate {
        if frame.hands[1 - hand].is_none()
            && solution
                .as_ref()
                .is_some_and(|s| s.sightings.len() < SCAN_SIGHTINGS)
        {
            // Without the peer's orientation no competing identity can claim
            // its LEDs. A weak unilateral fit must not silently commit the
            // heading/last/tilt already mutated on the solver's trial clone.
            let mut retained = self.trackers[hand].clone();
            retained.lost = retained.lost.saturating_add(1);
            retained.monocular_trial = None;
            return Candidate {
                tracker: retained,
                solution: None,
            };
        }
        Candidate { tracker, solution }
    }

    fn masked(
        &self,
        hand: usize,
        frame: &Frame,
        seen: &Seen,
        world: &M3,
        claims: &Claims,
    ) -> Candidate {
        let mut ids = Vec::new();
        let views: Vec<Vec<Spot>> = seen
            .spots
            .iter()
            .enumerate()
            .map(|(view, spots)| {
                let kept: Vec<usize> = (0..spots.len())
                    .filter(|&i| !claims.contains(&(view, seen.spot_ids[view][i])))
                    .collect();
                ids.push(kept.iter().map(|&i| seen.spot_ids[view][i]).collect());
                kept.into_iter().map(|i| spots[i]).collect()
            })
            .collect();
        let others: Vec<_> = seen
            .cameras
            .iter()
            .copied()
            .skip(2)
            .zip(views.iter().skip(2).map(Vec::as_slice))
            .collect();
        let mut masked = Seen::new(
            &PSVR2_BOTTOM,
            &views[0],
            &views[1],
            &others,
            self.trackers[hand].bottom.as_ref(),
        );
        masked.spot_ids = ids;
        self.propose(hand, frame, &masked, world)
    }

    fn equivalent(
        a: &[Candidate; 2],
        b: &[Candidate; 2],
        accepted_a: [bool; 2],
        accepted_b: [bool; 2],
    ) -> bool {
        (0..2).all(|i| {
            match (
                a[i].solution.as_ref().filter(|_| accepted_a[i]),
                b[i].solution.as_ref().filter(|_| accepted_b[i]),
            ) {
                (None, None) => true,
                (Some(a), Some(b)) => {
                    let d = sub(a.position, b.position);
                    let angle = (a.heading - b.heading + std::f64::consts::PI)
                        .rem_euclid(std::f64::consts::TAU)
                        - std::f64::consts::PI;
                    dot(d, d) < (2. * VOTE_REACH).powi(2) && angle.abs() < 2f64.to_radians()
                }
                _ => false,
            }
        })
    }

    fn plan_acceptance(&self, frame: &Frame, plan: &[Candidate; 2]) -> [bool; 2] {
        // This is a dry run: an unconfirmed candidate must not gain ownership
        // priority over the other hand or modify either track while scoring.
        std::array::from_fn(|hand| {
            plan[hand].solution.as_ref().is_some_and(|s| {
                let mut trial = self.clone();
                trial.temporal(hand, frame, s)
            })
        })
    }

    fn world_position(frame: &Frame, position: V3) -> V3 {
        let p = PSVR2_BOTTOM
            .in_head(PSVR2_BOTTOM_PLACE, position)
            .map(|x| x as f32);
        let rotated = frame.head.unwrap_or(Quat::IDENTITY).rotate(p);
        let origin = frame.head_position.unwrap_or([0.; 3]);
        std::array::from_fn(|i| f64::from(origin[i]) + f64::from(rotated[i]))
    }

    fn camera_position(frame: &Frame, position: V3) -> V3 {
        let origin = frame.head_position.unwrap_or([0.; 3]);
        let relative = std::array::from_fn(|i| (position[i] - f64::from(origin[i])) as f32);
        let local = frame
            .head
            .unwrap_or(Quat::IDENTITY)
            .conjugate()
            .rotate(relative)
            .map(f64::from);
        apply(
            &PSVR2_BOTTOM.camera_from_head(),
            sub(local, PSVR2_BOTTOM_PLACE),
        )
    }

    fn temporal(&mut self, hand: usize, frame: &Frame, s: &Solution) -> bool {
        let p = Self::world_position(frame, s.position);
        if self.pending[hand].is_some_and(|p| frame.t_ns.saturating_sub(p.time) >= 100_000_000) {
            self.pending[hand] = None;
        }
        if self.accepted[hand].is_none()
            && self.pending[hand].is_some_and(|p| p.stereo_tilt.is_some())
            && !s.strong_stereo()
        {
            self.diagnostics.temporal_rejections[hand] += 1;
            return false;
        }
        let heading_jump = (s.heading - self.trackers[hand].heading + std::f64::consts::PI)
            .rem_euclid(std::f64::consts::TAU)
            - std::f64::consts::PI;
        let expanded_acquisition = s.strong_stereo()
            && (self.accepted[hand].is_none()
                || self.trackers[hand].lost >= SCAN_AFTER
                || heading_jump.abs() > HEADING_JUMP);
        if expanded_acquisition && !self.confirmed(hand, frame, s, p) {
            self.set_pending(hand, frame, s, p);
            return false;
        }
        let Some(old) = self.accepted[hand] else {
            self.accepted[hand] = Some(Accepted {
                time: frame.t_ns,
                position: p,
                velocity: [0.; 3],
            });
            self.pending[hand] = None;
            return true;
        };
        let dt = frame.t_ns.saturating_sub(old.time) as f64 * 1e-9;
        let predicted = add(old.position, old.velocity.map(|v| v * dt.min(0.12)));
        let innovation = sub(p, predicted);
        // Normal motion, including a 3m/s swing, passes without confirmation.
        // A discontinuous new location must repeat in a separate exposure; it
        // must not overwrite the old solver state on its first weak sighting.
        let discontinuous = dot(innovation, innovation) > 0.12f64.powi(2) || dt > 0.25;
        if discontinuous && !self.confirmed(hand, frame, s, p) {
            self.set_pending(hand, frame, s, p);
            return false;
        }
        let velocity = if dt > 0.002 && dt < 0.25 {
            let v = sub(p, old.position).map(|v| v / dt);
            std::array::from_fn(|i| 0.5 * old.velocity[i] + 0.5 * v[i])
        } else {
            [0.; 3]
        };
        self.accepted[hand] = Some(Accepted {
            time: frame.t_ns,
            position: p,
            velocity,
        });
        self.pending[hand] = None;
        true
    }

    fn confirmed(&self, hand: usize, frame: &Frame, s: &Solution, p: V3) -> bool {
        self.pending[hand].is_some_and(|pending| {
            let since = frame.t_ns.saturating_sub(pending.time) as f64 * 1e-9;
            let d = sub(p, pending.position);
            let angle = (s.heading - pending.heading + std::f64::consts::PI)
                .rem_euclid(std::f64::consts::TAU)
                - std::f64::consts::PI;
            since > 0.
                && since < 0.1
                && frame.counter != pending.counter
                && dot(d, d) < (0.06 + 12. * since + 25. * since * since).powi(2)
                && angle.abs() < 15f64.to_radians()
                && s.sightings.len() >= SCAN_SIGHTINGS
                && s.rms < MAX_RMS
                && (pending.stereo_tilt.is_none() || s.strong_stereo())
        })
    }

    fn set_pending(&mut self, hand: usize, frame: &Frame, s: &Solution, p: V3) {
        self.pending[hand] = Some(Pending {
            time: frame.t_ns,
            counter: frame.counter,
            position: p,
            heading: s.heading,
            stereo_tilt: s.strong_stereo().then_some(s.tilt),
        });
        self.diagnostics.temporal_rejections[hand] += 1;
    }

    fn rejected(&mut self, hand: usize) {
        self.trackers[hand].lost = self.trackers[hand].lost.saturating_add(1);
        self.trackers[hand].monocular_trial = None;
    }

    pub fn update_frame(&mut self, frame: &Frame) -> [Option<Fix>; 2] {
        if self.last_frame.is_some_and(|t| frame.t_ns <= t) {
            if self.last_frame.is_some_and(|t| frame.t_ns < t) {
                // An out-of-order/old epoch cannot corroborate a pending sample.
                self.pending = [None; 2];
            }
            return [None; 2];
        }
        self.last_frame = Some(frame.t_ns);
        self.diagnostics.exposures += 1;
        let head = frame.head.unwrap_or(Quat::IDENTITY);
        let world = PSVR2_BOTTOM.camera_from_world(head);
        let others = [
            (PSVR2_TOP[0], frame.top[0].as_slice()),
            (PSVR2_TOP[1], frame.top[1].as_slice()),
        ];
        let seen = Seen::new(
            &PSVR2_BOTTOM,
            &frame.left,
            &frame.right,
            &others,
            self.trackers[0].bottom.as_ref(),
        );
        let independent = [
            self.propose(0, frame, &seen, &world),
            self.propose(1, frame, &seen, &world),
        ];
        let claims = [independent[0].claims(), independent[1].claims()];
        let both = independent.iter().all(|c| c.solution.is_some());
        let selected = if both && claims[0].is_disjoint(&claims[1]) {
            self.diagnostics.disjoint_fast_path += 1;
            independent
        } else if both {
            self.diagnostics.conflicting_exposures += 1;
            let a = [
                independent[0].clone(),
                self.masked(1, frame, &seen, &world, &claims[0]),
            ];
            let b = [
                self.masked(0, frame, &seen, &world, &claims[1]),
                independent[1].clone(),
            ];
            let accepted_a = self.plan_acceptance(frame, &a);
            let accepted_b = self.plan_acceptance(frame, &b);
            let score = |plan: &[Candidate; 2], accepted: [bool; 2]| {
                (0..2)
                    .filter(|&i| accepted[i])
                    .map(|i| plan[i].quality())
                    .sum::<f64>()
            };
            let sa = score(&a, accepted_a);
            let sb = score(&b, accepted_b);
            let ambiguous = (sa - sb).abs() <= 0.05 * sa.max(sb)
                && !Self::equivalent(&a, &b, accepted_a, accepted_b);
            let no_confirmed_owner =
                sa == 0. && sb == 0. && !Self::equivalent(&a, &b, [true; 2], [true; 2]);
            if ambiguous || no_confirmed_owner {
                self.diagnostics.ambiguous_exposures += 1;
                for hand in 0..2 {
                    self.rejected(hand);
                    self.pending[hand] = None;
                }
                return [None; 2];
            }
            if sa >= sb { a } else { b }
        } else if independent[0].solution.is_some() {
            [
                independent[0].clone(),
                self.masked(1, frame, &seen, &world, &claims[0]),
            ]
        } else if independent[1].solution.is_some() {
            [
                self.masked(0, frame, &seen, &world, &claims[1]),
                independent[1].clone(),
            ]
        } else {
            independent
        };
        let mut fixes = [None; 2];
        for (hand, candidate) in selected.into_iter().enumerate() {
            if let Some(s) = candidate.solution {
                if self.temporal(hand, frame, &s) {
                    self.trackers[hand] = candidate.tracker;
                    fixes[hand] = Some(Fix {
                        position: s.position.map(|v| v as f32),
                        heading: s.heading as f32,
                        tilt: s.tilt.map(|v| v as f32),
                        sightings: s.sightings.len() as u32,
                        rms: s.rms as f32,
                    });
                } else {
                    self.rejected(hand);
                }
            } else {
                self.trackers[hand] = candidate.tracker;
                // A nonscan/missing exposure is no new evidence against the
                // provisional fit. Retain it only to its existing 100 ms deadline;
                // a later independent, strong, consistent fit must still confirm.
                if self.pending[hand]
                    .is_some_and(|p| frame.t_ns.saturating_sub(p.time) >= 100_000_000)
                {
                    self.pending[hand] = None;
                }
            }
        }
        fixes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(time: u64) -> Frame {
        Frame {
            counter: time,
            t_ns: time,
            left: Vec::new(),
            right: Vec::new(),
            top: [Vec::new(), Vec::new()],
            hands: [None; 2],
            hands_at: [None; 2],
            head: Some(Quat::IDENTITY),
            head_position: Some([0.; 3]),
        }
    }

    fn solution(position: V3, heading: f64, sightings: usize) -> Solution {
        Solution {
            position,
            heading,
            tilt: [0.; 2],
            rms: 0.,
            sightings: (0..sightings)
                .map(|i| Sighting {
                    view: i % 2,
                    spot: i,
                    led: i,
                    at: [0.; 2],
                })
                .collect(),
        }
    }

    fn pending_pair() -> PairedHandTracker {
        let mut pair = PairedHandTracker::new();
        assert!(pair.temporal(0, &frame(1_000_000_000), &solution([0., 0., 0.5], 0., 8)));
        assert!(!pair.temporal(0, &frame(1_300_000_000), &solution([0., 0.2, 0.5], 0., 8)));
        assert!(pair.pending[0].is_some());
        pair.last_frame = Some(1_300_000_000);
        pair
    }

    #[test]
    fn pending_survives_missing_exposure_but_not_exact_confirmation_deadline() {
        let mut before = pending_pair();
        let original = before.accepted[0].unwrap();
        before.update_frame(&frame(1_350_000_000));
        assert!(before.pending[0].is_some());
        assert_eq!(before.accepted[0].unwrap().time, original.time);
        assert_eq!(before.accepted[0].unwrap().position, original.position);
        assert_eq!(before.trackers[0].heading, 0.);
        assert!(
            before.trackers[0].last.is_none(),
            "Pending cannot update optical solver state"
        );
        assert!(before.temporal(0, &frame(1_399_999_999), &solution([0., 0.2, 0.5], 0., 8)));

        let mut expired = pending_pair();
        expired.update_frame(&frame(1_400_000_000));
        assert!(expired.pending[0].is_none());
        assert!(
            !expired.temporal(0, &frame(1_400_000_000), &solution([0., 0.2, 0.5], 0., 8)),
            "At exactly100ms the same geometry must start a new pending observation"
        );
    }

    #[test]
    fn pending_does_not_confirm_heading_position_or_quality_mismatch() {
        for candidate in [
            solution([0., 0.2, 0.5], 16f64.to_radians(), 8),
            solution([0.7, 0.2, 0.5], 0., 8),
            solution([0., 0.2, 0.5], 0., 7),
            Solution {
                rms: 2.,
                ..solution([0., 0.2, 0.5], 0., 8)
            },
        ] {
            let mut pair = pending_pair();
            pair.update_frame(&frame(1_316_666_667));
            assert!(!pair.temporal(0, &frame(1_333_333_334), &candidate));
            assert_eq!(pair.accepted[0].unwrap().time, 1_000_000_000);
            assert!(pair.trackers[0].last.is_none());
        }
    }

    #[test]
    fn pending_rejects_duplicate_confirmation_and_retires_on_time_or_geometry_reset() {
        let mut duplicate = pending_pair();
        duplicate.update_frame(&frame(1_300_000_000));
        assert!(duplicate.pending[0].is_some());
        assert!(!duplicate.temporal(0, &frame(1_300_000_000), &solution([0., 0.2, 0.5], 0., 8)));
        let mut backwards = pending_pair();
        backwards.update_frame(&frame(1_299_999_999));
        assert!(backwards.pending[0].is_none());
        let mut geometry = pending_pair();
        geometry.set_bottom_fisheyes(true);
        assert!(geometry.pending[0].is_none());
        let mut alignment = pending_pair();
        assert!(alignment.set_bottom_fisheye_alignment([0.01, 0., 0.]));
        assert!(alignment.pending[0].is_none());
    }
    #[test]
    fn strong_cold_hypothesis_requires_another_strong_exposure_without_publishing_trial_state() {
        let mut pair = PairedHandTracker::new();
        let mut strong = solution([0., 0.2, 0.5], 0., 16);
        strong.rms = 1.6;
        assert!(strong.strong_stereo());
        assert!(!pair.temporal(0, &frame(1_000_000_000), &strong));
        assert!(pair.accepted[0].is_none());
        assert!(pair.trackers[0].last.is_none());
        assert_eq!(pair.trackers[0].heading, 0.);
        assert!(!pair.temporal(0, &frame(1_016_666_667), &solution([0., 0.2, 0.5], 0., 8)));
        assert!(pair.accepted[0].is_none());
        assert!(pair.temporal(0, &frame(1_033_333_334), &strong));
        assert!(pair.accepted[0].is_some());
        assert!(pair.pending[0].is_none());
    }

    #[test]
    fn provisional_world_seed_roundtrips_camera_motion_without_changing_the_pose() {
        let mut f = frame(1_000_000_000);
        f.head = Some(Quat::from_rotation_vector([0.2, -0.3, 0.1]));
        f.head_position = Some([0.14, -0.1, 0.2]);
        let original = [0.03, -0.2, 0.5];
        let world = PairedHandTracker::world_position(&f, original);
        let returned = PairedHandTracker::camera_position(&f, world);
        let d = sub(returned, original);
        assert!(dot(d, d) < 1e-12);
    }
    #[test]
    fn a_remapped_timestamp_on_the_same_exposure_cannot_confirm() {
        let mut pair = pending_pair();
        let mut duplicate = frame(1_333_333_334);
        duplicate.counter = 1_300_000_000;
        assert!(!pair.temporal(0, &duplicate, &solution([0., 0.2, 0.5], 0., 8)));
        assert_eq!(pair.accepted[0].unwrap().time, 1_000_000_000);
    }
    #[test]
    fn rejected_unilateral_weak_clone_cannot_commit_heading_tilt_position_or_claims() {
        for hand in 0..2 {
            let pair = PairedHandTracker::new();
            let mut f = frame(1_000_000_000);
            f.hands[hand] = Some(Quat::IDENTITY);
            let original = pair.trackers[hand].clone();
            let mut mutated = original.clone();
            mutated.heading = 1.;
            mutated.tilt = [0.1, 0.2];
            mutated.last = Some([0.2, 0.1, 0.5]);
            let candidate = pair.admit_candidate(
                hand,
                &f,
                mutated.clone(),
                Some(solution([0.2, 0.1, 0.5], 1., 6)),
            );
            assert!(candidate.solution.is_none());
            assert!(candidate.claims().is_empty());
            assert_eq!(candidate.tracker.heading, original.heading);
            assert_eq!(candidate.tracker.tilt, original.tilt);
            assert_eq!(candidate.tracker.last, original.last);
            assert_eq!(candidate.tracker.lost, original.lost + 1);
            assert!(pair.accepted[hand].is_none());
            assert!(pair.pending[hand].is_none());
            f.hands[1 - hand] = Some(Quat::IDENTITY);
            let legacy =
                pair.admit_candidate(hand, &f, mutated, Some(solution([0.2, 0.1, 0.5], 1., 6)));
            assert!(
                legacy.solution.is_some(),
                "Both known orientations preserve ordinary weak continuation"
            );
        }
    }
}
