//! Cold-start acquisition with an initially unknown yaw and only one bottom camera.
use halliday_core::math::Quat;
use halliday_core::sense::Hand;
use halliday_core::tracking::hands::{HandTracker, Spot};
use halliday_core::tracking::leds::sense_leds;
use halliday_core::tracking::stereo::{
    Camera, M3, PSVR2_BOTTOM, PSVR2_BOTTOM_FISHEYE, V3, apply, from_quat, mul, turn_y,
};

fn picture(hand: Hand, camera: &Camera, rotation: &M3, position: V3) -> Vec<Spot> {
    sense_leds(hand)
        .iter()
        .filter_map(|led| {
            let offset = apply(rotation, led.position);
            let at = std::array::from_fn(|k| position[k] + offset[k]);
            let normal = apply(rotation, led.normal);
            let to: V3 = std::array::from_fn(|k| camera.place[k] - at[k]);
            let facing = normal.iter().zip(to).map(|(a, b)| a * b).sum::<f64>()
                / to.iter().map(|v| v * v).sum::<f64>().sqrt();
            if facing < 0.25 {
                return None;
            }
            let xy = camera.project(at)?;
            if !(0.0..camera.size[0]).contains(&xy[0]) || !(0.0..camera.size[1]).contains(&xy[1]) {
                return None;
            }
            // Subpixel measurement error and an LED-sized blob, not perfect integer pixels.
            Some(Spot {
                x: (xy[0] + 0.08 * (xy[1] * 0.1).sin()) as f32,
                y: (xy[1] + 0.08 * (xy[0] * 0.1).cos()) as f32,
                area: 30,
            })
        })
        .collect()
}

fn sample(hand: Hand, view: usize, yaw: f64) -> (Quat, V3, Vec<Spot>) {
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    let position = [if hand == Hand::Left { -0.25 } else { 0.25 }, 0.04, 0.42];
    for pitch_step in -24..=24 {
        for roll_step in -24..=24 {
            let q = Quat::from_rotation_vector([
                pitch_step as f32 * 0.125,
                0.0,
                roll_step as f32 * 0.125,
            ]);
            let rotation = mul(&mul(&world, &turn_y(yaw)), &from_quat(q));
            let spots = picture(hand, &PSVR2_BOTTOM_FISHEYE[view], &rotation, position);
            if spots.len() >= 8 {
                return (q, position, spots);
            }
        }
    }
    panic!("No realistic visible subset for {hand:?}, view {view}, yaw {yaw}");
}

fn acquire(
    tracker: &mut HandTracker,
    q: Quat,
    view: usize,
    spots: &[Spot],
    frames: usize,
) -> Option<halliday_core::tracking::hands::Fix> {
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    let (left, right) = if view == 0 {
        (spots, &[][..])
    } else {
        (&[][..], spots)
    };
    (0..frames).find_map(|_| tracker.update(&PSVR2_BOTTOM, &world, q, left, right))
}

#[test]
fn both_hands_acquire_unknown_yaw_from_one_fisheye() {
    for hand in [Hand::Left, Hand::Right] {
        for view in 0..2 {
            for yaw in [-2.4, -1.2, 0.8, 2.1] {
                let (q, position, spots) = sample(hand, view, yaw);
                // The image itself is sufficient: the existing known-yaw monocular solver finds it.
                let mut known = HandTracker::new(hand);
                known.set_bottom_fisheyes(true);
                known.set_heading(yaw as f32);
                assert!(
                    acquire(&mut known, q, view, &spots, 8).is_some(),
                    "Known-yaw control must acquire {hand:?}"
                );
                let mut cold = HandTracker::new(hand);
                cold.set_bottom_fisheyes(true);
                let fix = acquire(&mut cold, q, view, &spots, 100)
                    .expect("Unknown yaw must acquire without a stereo match");
                let error = fix
                    .position
                    .iter()
                    .zip(position)
                    .map(|(a, b)| (f64::from(*a) - b).powi(2))
                    .sum::<f64>()
                    .sqrt();
                assert!(
                    error < 0.015,
                    "{hand:?}: wrong position {fix:?}, error {error}"
                );
                assert!(
                    (f64::from(fix.heading) - yaw).abs() < 0.12,
                    "{hand:?}: wrong initial yaw {fix:?}"
                );
            }
        }
    }
}

#[test]
fn monocular_acquisition_rejects_insufficient_spots_and_noise() {
    for (hand, view, yaw) in [(Hand::Left, 0, -1.2), (Hand::Right, 1, 1.5)] {
        let (q, _, spots) = sample(hand, view, yaw);
        let mut tracker = HandTracker::new(hand);
        tracker.set_bottom_fisheyes(true);
        assert!(acquire(&mut tracker, q, view, &spots[..7], 100).is_none());
        let noise: Vec<_> = (0..12)
            .map(|i| Spot {
                x: 60.0 + (i * 137 % 850) as f32,
                y: 70.0 + (i * 89 % 850) as f32,
                area: 30,
            })
            .collect();
        assert!(acquire(&mut tracker, q, view, &noise, 100).is_none());
    }
}

#[test]
fn monocular_acquisition_does_not_accept_the_other_hands_ring() {
    for (hand, other) in [(Hand::Left, Hand::Right), (Hand::Right, Hand::Left)] {
        for view in 0..2 {
            for yaw in [-2.4, -1.2, 0.8, 2.1] {
                let (q, _, spots) = sample(other, view, yaw);
                let mut tracker = HandTracker::new(hand);
                tracker.set_bottom_fisheyes(true);
                assert!(
                    acquire(&mut tracker, q, view, &spots, 100).is_none(),
                    "{hand:?} must not copy {other:?} position"
                );
            }
        }
    }
}

#[test]
fn cold_tracker_does_not_duplicate_the_other_hands_stereo_ring() {
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    for (hand, other) in [(Hand::Left, Hand::Right), (Hand::Right, Hand::Left)] {
        for yaw in [-2.4, -1.2, 0.8, 2.1] {
            let (q, position, _) = sample(other, 0, yaw);
            let rotation = mul(&mul(&world, &turn_y(yaw)), &from_quat(q));
            let images: [Vec<Spot>; 2] = std::array::from_fn(|view| {
                picture(other, &PSVR2_BOTTOM_FISHEYE[view], &rotation, position)
            });
            let mut tracker = HandTracker::new(hand);
            tracker.set_bottom_fisheyes(true);
            for _ in 0..100 {
                assert!(
                    tracker
                        .update(&PSVR2_BOTTOM, &world, q, &images[0], &images[1])
                        .is_none(),
                    "{hand:?} must not duplicate visible {other:?} stereo ring at yaw {yaw}"
                );
            }
        }
    }
}

#[test]
fn acquired_monocular_hands_follow_ordinary_motion_without_rescanning() {
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    for (hand, view, yaw) in [(Hand::Left, 0, -1.2), (Hand::Right, 1, 1.5)] {
        let (q, position, spots) = sample(hand, view, yaw);
        let mut tracker = HandTracker::new(hand);
        tracker.set_bottom_fisheyes(true);
        let mut cold_times = Vec::new();
        let mut acquired = false;
        for _ in 0..100 {
            let started = std::time::Instant::now();
            let found = acquire(&mut tracker, q, view, &spots, 1);
            cold_times.push(started.elapsed().as_secs_f64() * 1000.0);
            if found.is_some() {
                acquired = true;
                break;
            }
        }
        assert!(acquired);
        let rotation = mul(&mul(&world, &turn_y(yaw)), &from_quat(q));
        let mut follow_times = Vec::new();
        for frame in 0..100 {
            let moved = [
                position[0] + 0.025 * (frame as f64 * 0.1).sin(),
                position[1],
                position[2],
            ];
            let spots = picture(hand, &PSVR2_BOTTOM_FISHEYE[view], &rotation, moved);
            let started = std::time::Instant::now();
            let fix = acquire(&mut tracker, q, view, &spots, 1)
                .expect("Acquired hand should keep following normal motion");
            follow_times.push(started.elapsed().as_secs_f64() * 1000.0);
            let error = fix
                .position
                .iter()
                .zip(moved)
                .map(|(a, b)| (f64::from(*a) - b).powi(2))
                .sum::<f64>()
                .sqrt();
            assert!(error < 0.015, "{hand:?}: following position error {error}");
        }
        cold_times.sort_by(f64::total_cmp);
        follow_times.sort_by(f64::total_cmp);
        println!(
            "{hand:?}: cold frames={} median={:.3}ms p95={:.3}ms; follow median={:.3}ms p95={:.3}ms",
            cold_times.len(),
            cold_times[cold_times.len() / 2],
            cold_times[(cold_times.len() * 95 / 100).min(cold_times.len() - 1)],
            follow_times[50],
            follow_times[95]
        );
    }
}
