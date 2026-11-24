//! CPU regressions for joint controller identity. No images, hardware, device
//! identity, room position, or wall-clock time are captured by these tests.
use halliday_core::math::Quat;
use halliday_core::sense::Hand;
use halliday_core::tracking::hands::{Fix, Frame, HandTracker, PairedHandTracker, Spot, parse_dump};
use halliday_core::tracking::leds::sense_leds;
use halliday_core::tracking::stereo::{PSVR2_BOTTOM, PSVR2_BOTTOM_PLACE, apply, from_quat, mul};

const ALIGNMENT: [f64; 3] = [
    -0.004112071331861413,
    0.003328861353291489,
    -0.01492005963837453,
];

fn distance(a: [f32; 3], b: [f32; 3]) -> f32 {
    (0..3).map(|i| (a[i] - b[i]).powi(2)).sum::<f32>().sqrt()
}

fn spots(hand: Hand, orientation: Quat, position: [f32; 3]) -> [Vec<Spot>; 2] {
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    let rotation = mul(&world, &from_quat(orientation));
    let cameras = PSVR2_BOTTOM.cameras();
    let mut out = [Vec::new(), Vec::new()];
    for led in sense_leds(hand) {
        let p = apply(&rotation, led.position);
        let normal = apply(&rotation, led.normal);
        let at = std::array::from_fn(|i| p[i] + f64::from(position[i]));
        for eye in 0..2 {
            let toward = std::array::from_fn::<_, 3, _>(|i| at[i] - cameras[eye].place[i]);
            let facing = -(0..3).map(|i| normal[i] * toward[i]).sum::<f64>()
                / toward.iter().map(|x| x * x).sum::<f64>().sqrt();
            if facing <= 0.3 { continue; }
            if let Some([x, y]) = cameras[eye].project(at)
                && (0.0..640.0).contains(&x) && (0.0..640.0).contains(&y)
            {
                out[eye].push(Spot { x: x as f32, y: y as f32, area: 30 });
            }
        }
    }
    out
}

fn orientations() -> [Quat; 2] {
    std::array::from_fn(|i| {
        let hand = [Hand::Left, Hand::Right][i];
        // Choose by visible LED count, independently of the estimator under test.
        // Exact geometry plus two camera views provides known positional truth.
        for x in [-0.8, -0.4, 0.0, 0.2] {
            for y in [-0.8, -0.4, 0.0, 0.4, 0.8] {
                for z in [-0.4, 0.0, 0.4] {
                    let q = Quat::from_rotation_vector([x, y, z]);
                    let p = if i == 0 { [-0.14, 0.0, 0.55] } else { [0.14, 0.0, 0.55] };
                    let v = spots(hand, q, p);
                    if v.iter().all(|eye| eye.len() >= 8) { return q; }
                }
            }
        }
        panic!("No well-observed synthetic orientation for {hand:?}")
    })
}

fn frame(number: u64, q: [Quat; 2], positions: [Option<[f32; 3]>; 2]) -> Frame {
    let mut pictures = [Vec::new(), Vec::new()];
    for hand in 0..2 {
        if let Some(position) = positions[hand] {
            let image = spots([Hand::Left, Hand::Right][hand], q[hand], position);
            for eye in 0..2 { pictures[eye].extend_from_slice(&image[eye]); }
        }
    }
    // Alternating input order must not become controller identity.
    if number % 2 == 0 { for eye in &mut pictures { eye.reverse(); } }
    let t = 1_000_000_000 + number * 16_666_667;
    Frame {
        counter: number, t_ns: t,
        left: std::mem::take(&mut pictures[0]), right: std::mem::take(&mut pictures[1]),
        top: [Vec::new(), Vec::new()], hands: q.map(Some), hands_at: [Some(t); 2],
        head: Some(Quat::IDENTITY), head_position: Some([0.0; 3]),
    }
}

fn assert_position(fix: &Fix, expected: [f32; 3], tolerance: f32, context: &str) {
    assert!(distance(fix.position, expected) < tolerance,
        "{context}: expected{expected:?}, actual{fix:?}");
}

#[test]
fn recorded_normal_left_only_normal_retains_both_real_hands() {
    let capture = parse_dump(include_str!("fixtures/sense_fisheye_alignment.txt"));
    let mut tracker = PairedHandTracker::new();
    tracker.set_bottom_fisheyes(true);
    assert!(tracker.set_bottom_fisheye_alignment(ALIGNMENT));
    let phases = [
        1_353_585_370..2_357_257_162,
        2_467_341_662..7_470_531_245,
        7_523_847_620..8_529_437_120,
    ];
    let mut exposures = [0usize; 3];
    let mut seen = [[0usize; 2]; 3];
    let mut paired_ns = Vec::new();
    for f in &capture {
        let started = std::time::Instant::now();
        let fixes = tracker.update_frame(f);
        paired_ns.push(started.elapsed().as_nanos());
        if let Some(phase) = phases.iter().position(|p| p.contains(&f.t_ns)) {
            exposures[phase] += 1;
            for hand in 0..2 { seen[phase][hand] += usize::from(fixes[hand].is_some()); }
            if let [Some(left), Some(right)] = fixes {
                assert!(distance(left.position, right.position) > 0.04,
                    "Recorded separated controllers collapsed at frame{}: {fixes:?}", f.counter);
            }
        }
    }
    assert_eq!(exposures, [60, 300, 48], "Recorded physical phases changed");
    // Coverage guards prove the repair does not consist of suppressing a hand.
    assert!(seen[0].iter().all(|n| *n >= 54), "Normal coverage regressed: {seen:?}");
    assert!(seen[1][0] >= 285 && seen[1][1] == 0, "Left-only ownership/coverage: {seen:?}");
    assert!(seen[2].iter().all(|n| *n >= 40), "Restored both-hand coverage: {seen:?}");
    eprintln!("recorded exposures={exposures:?} accepted={seen:?}");
    let mut legacy = [HandTracker::new(Hand::Left), HandTracker::new(Hand::Right)];
    for hand in &mut legacy {
        hand.set_bottom_fisheyes(true);
        assert!(hand.set_bottom_fisheye_alignment(ALIGNMENT));
    }
    let mut baseline_ns = Vec::new();
    for f in &capture {
        let world = PSVR2_BOTTOM.camera_from_world(f.head.unwrap());
        let started = std::time::Instant::now();
        for hand in 0..2 {
            legacy[hand].update(&PSVR2_BOTTOM, &world, f.hands[hand].unwrap(), &f.left, &f.right);
        }
        baseline_ns.push(started.elapsed().as_nanos());
    }
    for (name, mut ns) in [("paired", paired_ns), ("independent_baseline", baseline_ns)] {
        ns.sort_unstable();
        let total = ns.iter().sum::<u128>();
        eprintln!("CPU_REPLAY name={name} exposures={} median_us={:.3} p95_us={:.3} max_us={:.3} total_ms={:.3} scope=wall_time_of_CPU_update_no_hardware_no_game",
            ns.len(), ns[ns.len()/2] as f64 / 1000.0,
            ns[(ns.len()-1)*95/100] as f64 / 1000.0, ns[ns.len()-1] as f64 / 1000.0, total as f64 / 1e6);
    }
}

#[test]
fn right_only_after_both_are_primed_cannot_become_left_then_left_reacquires() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let mut seen = [0usize; 2];
    let left = [-0.14, 0.0, 0.55];
    let right = [0.14, 0.0, 0.55];
    for i in 0..20 {
        let fixes = tracker.update_frame(&frame(i, q, [Some(left), Some(right)]));
        for hand in 0..2 { seen[hand] += usize::from(fixes[hand].is_some()); }
    }
    assert!(seen.iter().all(|n| *n >= 15), "Both controllers must actually acquire: {seen:?}");
    let mut right_seen = 0;
    for i in 20..65 {
        let fixes = tracker.update_frame(&frame(i, q, [None, Some(right)]));
        assert!(fixes[0].is_none(), "A right-only scene became the left hand at{i}: {fixes:?}");
        if let Some(fix) = fixes[1] { right_seen += 1; assert_position(&fix, right, 0.015, "right-only"); }
    }
    assert!(right_seen >= 40, "Rejecting left must preserve actual right coverage: {right_seen}");
    let returned = [-0.20, 0.05, 0.63];
    let mut left_seen = 0;
    for i in 65..90 {
        let fixes = tracker.update_frame(&frame(i, q, [Some(returned), Some(right)]));
        if let Some(fix) = fixes[0] { left_seen += 1; assert_position(&fix, returned, 0.02, "left reacquisition"); }
        if let Some(fix) = fixes[1] { assert_position(&fix, right, 0.015, "right during left reacquisition"); }
    }
    assert!(left_seen >= 18, "Actual left did not reacquire promptly: {left_seen}");
}

#[test]
fn crossing_and_projection_overlap_do_not_swap_controller_identity() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let mut before = [0; 2];
    let mut after = [0; 2];
    for i in 0..100 {
        let blend = ((i as f32 - 20.0) / 60.0).clamp(0.0, 1.0);
        let left = [-0.18 + 0.36 * blend, -0.025, 0.52];
        let right = [0.18 - 0.36 * blend, 0.025, 0.60];
        let fixes = tracker.update_frame(&frame(i, q, [Some(left), Some(right)]));
        for (hand, actual) in fixes.into_iter().enumerate() {
            if let Some(fix) = actual {
                assert_position(&fix, [left, right][hand], 0.035, "crossing known distinct controllers");
                if i < 20 { before[hand] += 1; }
                if i >= 80 { after[hand] += 1; }
            }
        }
    }
    assert!(before.iter().all(|n| *n >= 15), "Pre-crossing acquisition failed: {before:?}");
    assert!(after.iter().all(|n| *n >= 15), "Crossing lost a hand permanently: {after:?}");
}

#[test]
fn true_fast_continuous_motion_is_not_rejected_as_identity_innovation() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let mut fast_seen = 0;
    let mut right_seen = 0;
    for i in 0u64..84 {
        // 0.05m per 1/60s = 3m/s; position remains inside the real field of view.
        // Triangular reversals exercise bounded acceleration without teleporting.
        let step = (i.saturating_sub(20) % 12) as f32;
        let x = if step <= 6.0 { -0.20 + step * 0.05 } else { 0.10 - (step - 6.0) * 0.05 };
        let left = [x, -0.03, 0.55];
        let right = [0.22, 0.03, 0.63];
        let fixes = tracker.update_frame(&frame(i, q, [Some(left), Some(right)]));
        if i >= 24 {
            if let Some(fix) = fixes[0] { fast_seen += 1; assert_position(&fix, left, 0.035, "3m/s left swing"); }
            if let Some(fix) = fixes[1] { right_seen += 1; assert_position(&fix, right, 0.02, "right during fast left swing"); }
        }
    }
    assert!(fast_seen >= 42, "Real fast left motion was mostly rejected: {fast_seen}/60");
    assert!(right_seen >= 54, "Fast left motion destabilized stationary right: {right_seen}/60");
}

#[test]
fn one_frame_bad_location_does_not_poison_the_next_real_fix() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let normal = [[-0.14, 0.0, 0.55], [0.14, 0.0, 0.55]];
    for i in 0..20 { tracker.update_frame(&frame(i, q, normal.map(Some))); }
    let bad = [-0.14, 0.18, 0.55];
    let rejected_before = tracker.diagnostics().temporal_rejections[0];
    let outlier = tracker.update_frame(&frame(20, q, [Some(bad), Some(normal[1])]));
    assert!(outlier[0].is_none(), "One discontinuous frame was published: {outlier:?}");
    assert!(tracker.diagnostics().temporal_rejections[0] > rejected_before,
        "The outlier must reach the temporal gate, not merely fail optical geometry");
    let restored = tracker.update_frame(&frame(21, q, normal.map(Some)));
    assert_position(&restored[0].expect("Good left must recover immediately after one outlier"), normal[0], 0.02, "post-outlier left");
    assert_position(&restored[1].expect("Right must survive left outlier"), normal[1], 0.02, "post-outlier right");
}

#[test]
fn genuine_large_relocation_confirms_on_second_consistent_exposure() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let normal = [[-0.14, 0.0, 0.55], [0.14, 0.0, 0.55]];
    for i in 0..20 { tracker.update_frame(&frame(i, q, normal.map(Some))); }
    let moved = [-0.14, 0.18, 0.55];
    let first = tracker.update_frame(&frame(20, q, [Some(moved), Some(normal[1])]));
    assert!(first[0].is_none(), "Large new location requires corroboration");
    let second = tracker.update_frame(&frame(21, q, [Some(moved), Some(normal[1])]));
    assert_position(&second[0].expect("Two consistent real exposures must confirm relocation"), moved, 0.02, "confirmed relocation");
    assert_position(&second[1].expect("Right must remain tracked during relocation"), normal[1], 0.02, "right during relocation");
}

#[test]
fn head_translation_and_rotation_do_not_look_like_controller_teleports() {
    let q = orientations();
    let mut tracker = PairedHandTracker::new();
    let positions = [[-0.10, 0.0, 0.70], [0.15, 0.0, 0.70]];
    for i in 0..20 { tracker.update_frame(&frame(i, q, positions.map(Some))); }
    // A small camera gap allows a rapid but plausible head move. The actual
    // hands remain at their exact previous world positions throughout it.
    let head = Quat::from_rotation_vector([0.04, -0.18, 0.02]);
    let translation = [0.14, 0.01, 0.0];
    let camera_positions = positions.map(|p| {
        let fixed_world = PSVR2_BOTTOM.in_head(PSVR2_BOTTOM_PLACE, p.map(f64::from)).map(|x| x as f32);
        let relative = std::array::from_fn(|i| fixed_world[i] - translation[i]);
        let local = head.conjugate().rotate(relative).map(f64::from);
        apply(&PSVR2_BOTTOM.camera_from_head(), std::array::from_fn(|i| local[i] - PSVR2_BOTTOM_PLACE[i])).map(|x| x as f32)
    });
    let camera_q = q.map(|orientation| head.conjugate() * orientation);
    let mut moved = frame(24, camera_q, camera_positions.map(Some));
    moved.head = Some(head); moved.head_position = Some(translation); moved.hands = q.map(Some);
    let before = tracker.diagnostics().temporal_rejections;
    let fixes = tracker.update_frame(&moved);
    for hand in 0..2 {
        assert_position(&fixes[hand].expect("Known fixed-world hand must survive head motion"), camera_positions[hand], 0.02, "head motion");
    }
    assert_eq!(tracker.diagnostics().temporal_rejections, before,
        "Camera movement must not trigger controller innovation rejection");
}

#[test]
fn a_weak_plausible_left_fit_to_real_right_leds_is_rejected_without_losing_right() {
    // Fixed actual-solver reproducer discovered from a bounded orientation grid.
    // Every observation in the middle phase is generated by the RIGHT model.
    // The independent left tracker nevertheless accepts a plausible 5-sighting
    // ~1.37px fit to those same observations; no policy mock is substituted.
    let q = [Quat::from_rotation_vector([-1.0, 0.0, 0.6]),
             Quat::from_rotation_vector([-0.4, 0.8, 0.4])];
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    let mut legacy = [HandTracker::new(Hand::Left), HandTracker::new(Hand::Right)];
    let mut paired = PairedHandTracker::new();
    let mut primed = [0; 2];
    for i in 0..20 {
        let f = frame(i, q, [Some([0.05, 0.0, 0.55]), Some([0.25, 0.0, 0.55])]);
        let fixes = paired.update_frame(&f);
        for hand in 0..2 {
            primed[hand] += usize::from(fixes[hand].is_some());
            legacy[hand].update(&PSVR2_BOTTOM, &world, q[hand], &f.left, &f.right);
        }
    }
    assert!(primed.iter().all(|n| *n >= 15), "Reproducer did not prime both real controllers");
    let mut before_false_left = 0;
    let mut after_false_left = 0;
    let mut after_right = 0;
    let mut example = None;
    for i in 20..60 {
        let right = [0.25 - 0.02 * ((i - 20).min(10) as f32), 0.0, 0.55];
        let f = frame(i, q, [None, Some(right)]);
        let old_left = legacy[0].update(&PSVR2_BOTTOM, &world, q[0], &f.left, &f.right);
        let old_right = legacy[1].update(&PSVR2_BOTTOM, &world, q[1], &f.left, &f.right);
        if let (Some(wrong), Some(actual)) = (old_left, old_right)
            && actual.sightings >= 12 && actual.rms < 0.05
        {
            before_false_left += 1; example = Some(wrong);
        }
        let fixes = paired.update_frame(&f);
        after_false_left += usize::from(fixes[0].is_some());
        if let Some(actual) = fixes[1] {
            after_right += 1; assert_position(&actual, right, 0.015, "actual right in weak-left reproducer");
        }
    }
    assert!(before_false_left > 0, "Fixture must reproduce the old independent-solver identity failure");
    assert_eq!(after_false_left, 0, "Right-only observations still became left");
    assert!(after_right >= 36, "Repair lost actual right instead of rejecting false left: {after_right}/40");
    let example = example.unwrap();
    assert!(example.sightings >= 5 && example.rms < 2.0, "Wrong-left fit no longer plausible: {example:?}");
    let mut reacquired = 0;
    for i in 60..85 {
        let left = [-0.10, 0.03, 0.60];
        let fixes = paired.update_frame(&frame(i, q, [Some(left), Some([0.05, 0.0, 0.55])]));
        if let Some(actual) = fixes[0] {
            reacquired += 1; assert_position(&actual, left, 0.025, "actual left after false-fit rejection");
        }
    }
    assert!(reacquired >= 18, "False-fit rejection poisoned genuine left reacquisition: {reacquired}/25");
    eprintln!("BEFORE_AFTER actual_solver right_only_exposures40 old_false_left={before_false_left} new_false_left={after_false_left} new_right={after_right} left_returned={reacquired} old_example={example:?}");
}

#[test]
fn relocated_hand_confirms_after_a_real_missing_exposure_for_either_hand() {
    let q = orientations();
    let normal = [[-0.14, 0.0, 0.55], [0.14, 0.0, 0.55]];
    for hand in 0..2 {
        let mut tracker = PairedHandTracker::new();
        for i in 0..20 { tracker.update_frame(&frame(i, q, normal.map(Some))); }
        let mut moved = normal;
        moved[hand][1] += 0.18;
        assert!(tracker.update_frame(&frame(20, q, moved.map(Some)))[hand].is_none(),
            "First discontinuous location must remain provisional");
        let mut hidden = normal.map(Some); hidden[hand] = None;
        assert!(tracker.update_frame(&frame(21, q, hidden))[hand].is_none(),
            "A genuinely missing exposure cannot publish a hand");
        let fixes = tracker.update_frame(&frame(22, q, moved.map(Some)));
        assert_position(&fixes[hand].expect("A second corroborating real exposure33ms later must reacquire"),
            moved[hand], 0.02, "gap-confirmed relocation");
        assert_position(&fixes[1-hand].expect("Other controller must stay tracked"),
            normal[1-hand], 0.02, "other hand through reacquisition");
    }
}

#[test]
fn lost_hand_recovers_from_alternating_real_yaw_scans() {
    let q = orientations();
    let world = PSVR2_BOTTOM.camera_from_world(Quat::IDENTITY);
    let normal = [[-0.14, 0.0, 0.55], [0.14, 0.0, 0.55]];
    let mut paired = PairedHandTracker::new();
    let mut uncommitted = HandTracker::new(Hand::Left);
    for i in 0..20 {
        let f = frame(i, q, normal.map(Some));
        paired.update_frame(&f);
        let own = spots(Hand::Left, q[0], normal[0]);
        uncommitted.update(&PSVR2_BOTTOM, &world, q[0], &own[0], &own[1]);
    }
    // A long optical loss requires renewed heading acquisition. The IMU has no
    // absolute yaw; the returning LED geometry establishes the known correction.
    for i in 20..220 {
        paired.update_frame(&frame(i, q, [None, Some(normal[1])]));
        uncommitted.update(&PSVR2_BOTTOM, &world, q[0], &[], &[]);
    }
    let actual = q;
    let reported = [Quat::from_axis_angle([0.,1.,0.], -90f32.to_radians()) * q[0], q[1]];
    let returned = [-0.20, 0.04, 0.60];
    let mut scan_candidates = Vec::new();
    let mut first_accepted = None;
    for i in 220..236 {
        let mut f = frame(i, actual, [Some(returned), Some(normal[1])]);
        f.hands = reported.map(Some);
        // Probe the actual single-hand optical solver without committing its
        // new heading: this mirrors the transactional first-candidate policy.
        let mut trial = uncommitted.clone();
        let own = spots(Hand::Left, actual[0], returned);
        if let Some(fix) = trial.update(&PSVR2_BOTTOM, &world, reported[0], &own[0], &own[1]) {
            assert_position(&fix, returned, 0.02, "actual yaw-scan candidate");
            scan_candidates.push(i);
        }
        uncommitted.update(&PSVR2_BOTTOM, &world, q[0], &[], &[]);
        let fixes = paired.update_frame(&f);
        if let Some(fix) = fixes[0] {
            assert_position(&fix, returned, 0.02, "actual yaw reacquisition");
            first_accepted.get_or_insert(i);
        }
        assert_position(&fixes[1].expect("Heading reacquisition must preserve right"),normal[1],0.02,"right during yaw scan");
    }
    eprintln!("YAW_SCAN candidates={scan_candidates:?} first_accepted={first_accepted:?}");
    assert!(scan_candidates.len() >= 2, "Known LED geometry must produce real yaw candidates");
    assert_eq!(scan_candidates[1] - scan_candidates[0], 2,
        "Fixture must exercise the real scan/miss/scan schedule");
    assert!(first_accepted.is_some_and(|n| n > scan_candidates[0] && n <= scan_candidates[1]),
        "A new independent exposure must corroborate by the second scan; a strong provisional seed may confirm on the intervening real image");
}

#[test]
fn verified_high_residual_left_reacquires_after_lost_yaw_without_weakening_weak_fits() {
    let capture = parse_dump(include_str!("fixtures/sense_fisheye_alignment.txt"));
    let mut warm = PairedHandTracker::new(); warm.set_bottom_fisheyes(true);
    assert!(warm.set_bottom_fisheye_alignment(ALIGNMENT));
    let mut checked = 0;
    for (index, f) in capture.iter().enumerate() {
        let fixes = warm.update_frame(f);
        if ![300, 395, 430].contains(&index) { continue; }
        let reference = fixes[0].expect("Recorded strong left reference must remain accepted");
        assert!(reference.rms > 1.2 && reference.sightings >= 12,
            "Fixture must expose the actual continuing-versus-scan quality mismatch: {reference:?}");
        let mut test = warm.clone();
        for n in 1..=45 {
            let mut lost = f.clone(); lost.t_ns += n * 16_666_667; lost.counter += n;
            lost.hands[0] = None; test.update_frame(&lost);
        }
        let mut first = None;
        for n in 1..=10 {
            let mut returned = f.clone(); returned.t_ns += (45+n)*16_666_667; returned.counter += 45+n;
            returned.hands[0] = f.hands[0].map(|q| Quat::from_axis_angle([0.,1.,0.],-30f32.to_radians())*q);
            if let Some(fix) = test.update_frame(&returned)[0] {
                assert_position(&fix,reference.position,0.03,"recorded strong-stereo heading recovery");
                first.get_or_insert(n);
            }
        }
        eprintln!("VERIFIED_YAW index={index} reference_rms={} sightings={} first={first:?}",reference.rms,reference.sightings);
        assert!(first.is_some_and(|n| n >= 2 && n <= 6),
            "Strong recorded left must corroborate and recover within3 heading scans, got{first:?}");
        checked += 1;
    }
    assert_eq!(checked,3);
}

#[test]
fn dense_static_stereo_clutter_never_becomes_either_controller() {
    let q = orientations();
    let mut paired = PairedHandTracker::new();
    for i in 0..32 {
        let mut f = frame(i,q,[None,None]);
        for n in 0..48 {
            let row = n/8; let col = n%8;
            let x = 36. + col as f32 * 78.; let y = 48. + row as f32 * 96.;
            f.left.push(Spot{x,y,area:30});
            f.right.push(Spot{x:x-22.-(row%3) as f32*3.,y,area:30});
        }
        assert_eq!(paired.update_frame(&f),[None,None],
            "Dense known non-controller observations produced a hand on exposure{i}");
    }
}

#[test]
fn verified_high_residual_field_cold_start_uses_validated_stereo_without_a_last_pose() {
    let capture=parse_dump(include_str!("fixtures/sense_fisheye_alignment.txt"));
    let mut warm=PairedHandTracker::new();warm.set_bottom_fisheyes(true);
    assert!(warm.set_bottom_fisheye_alignment(ALIGNMENT));
    for(index,f)in capture.iter().enumerate(){
        let reference=warm.update_frame(f)[0];
        if ![300,395,430].contains(&index){continue;}
        let reference=reference.unwrap();assert!(reference.rms>1.2);
        let mut cold=PairedHandTracker::new();cold.set_bottom_fisheyes(true);
        assert!(cold.set_bottom_fisheye_alignment(ALIGNMENT));
        let mut first=None;
        for n in 0..75 {
            let mut input=f.clone();input.t_ns+=n*16_666_667;input.counter+=n;
            input.hands[0]=f.hands[0].map(|q|Quat::from_axis_angle([0.,1.,0.],-30f32.to_radians())*q);
            if let Some(fix)=cold.update_frame(&input)[0]{
                assert_position(&fix,reference.position,0.03,"cold real high-residual field");
                first.get_or_insert(n);
            }
        }
        eprintln!("VERIFIED_COLD index={index} first={first:?}");
        assert!(first.is_some_and(|n|n>0&&n<75),"No-prior recorded left must acquire with independent confirmation");
    }
}

#[test]
fn missing_peer_orientation_cannot_turn_right_leds_into_a_weak_left_hand() {
    let q=[Quat::from_rotation_vector([-1.0,0.0,0.6]),Quat::from_rotation_vector([-0.4,0.8,0.4])];
    let mut paired=PairedHandTracker::new();
    for i in 0..20{paired.update_frame(&frame(i,q,[Some([0.05,0.,0.55]),Some([0.25,0.,0.55]) ]));}
    let(mut wrong,mut strong,mut sightings)=(0,0,Vec::new());
    for i in 20..76{
        let right=[0.25-0.02*((i-20).min(10)as f32),0.,0.55];
        let mut input=frame(i,q,[None,Some(right)]);
        if (i-20)%8<3{input.hands[1]=None;}
        if let Some(fix)=paired.update_frame(&input)[0]{
            wrong+=1;sightings.push(fix.sightings);if fix.sightings>=12{strong+=1;}
        }
    }
    eprintln!("MISSING_PEER exposures56 wrong_left={wrong} high_support_wrong_left={strong} sightings={sightings:?}");
    assert_eq!(strong,0,"Expanded high-observability acquisition cannot steal the right hand during missing right orientation");
    assert_eq!(wrong,0,"Actual baseline37 has17weak false fits; missing peer identity must require the existing8-sighting acquisition support");
}

#[test]
fn real_recorded_left_retains_coverage_when_peer_orientation_is_absent() {
    let capture=parse_dump(include_str!("fixtures/sense_fisheye_alignment.txt"));
    let mut paired=PairedHandTracker::new();paired.set_bottom_fisheyes(true);
    assert!(paired.set_bottom_fisheye_alignment(ALIGNMENT));
    let phases=[1_353_585_370..2_357_257_162,2_467_341_662..7_470_531_245,7_523_847_620..8_529_437_120];
    let mut seen=[0;3];
    for f in &capture {
        let mut unilateral=f.clone();unilateral.hands[1]=None;
        let fixes=paired.update_frame(&unilateral);
        assert!(fixes[1].is_none());
        if let Some(phase)=phases.iter().position(|p|p.contains(&f.t_ns)){seen[phase]+=usize::from(fixes[0].is_some());}
    }
    eprintln!("KNOWN_LEFT_PEER_ABSENT accepted={seen:?}");
    assert!(seen[0]>=54&&seen[1]>=285&&seen[2]>=40,"Missing-peer safety must preserve actual left:{seen:?}");
}

#[test]
fn ordinary_both_orientation_weak_continuation_remains_available() {
    let q=orientations();let normal=[[-0.14,0.,0.55],[0.14,0.,0.55]];
    let mut pair=PairedHandTracker::new();
    for i in 0..20{pair.update_frame(&frame(i,q,normal.map(Some)));}
    let own=spots(Hand::Left,q[0],normal[0]);let peer=spots(Hand::Right,q[1],normal[1]);
    let mut weak_seen=0;
    for i in 20..32 {
        let mut f=frame(i,q,[None,None]);
        f.left=own[0].iter().take(3).copied().chain(peer[0].iter().copied()).collect();
        f.right=own[1].iter().take(2).copied().chain(peer[1].iter().copied()).collect();
        if let Some(fix)=pair.update_frame(&f)[0]{assert_position(&fix,normal[0],0.02,"both-q low visibility");assert!(fix.sightings<8);weak_seen+=1;}
    }
    assert!(weak_seen>=10,"Both-q ordinary low-visibility continuation regressed:{weak_seen}");
}
