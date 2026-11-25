//! CPU-only controller exposure-orientation history contract.
use halliday_core::math::Quat;
use halliday_core::sense::OrientationHistory;

fn yaw(angle: f32) -> Quat {
    Quat::from_rotation_vector([0.0, angle, 0.0])
}
fn same(actual: Quat, expected: Quat) {
    assert!(
        actual.dot(expected).abs() > 1.0 - 1e-6,
        "actual={actual:?} expected={expected:?}"
    );
}

#[test]
fn current_offset_rebases_raw_device_history_without_timestamp_drift() {
    let mut h = OrientationHistory::new();
    let a = 1_000_000_000;
    assert!(h.push_device_time(a, yaw(0.0)));
    assert!(h.push_device_time(a + 20_000_000, yaw(0.2)));
    let device_query = a + 10_000_000;
    same(
        h.sample_host_time(device_query + 4_000_000_000, 4_000_000_000)
            .unwrap(),
        yaw(0.1),
    );
    // The same device observations must map using the CURRENT offset after a
    // clock estimate changes; old permanently mapped host keys would miss here.
    same(
        h.sample_host_time(device_query + 4_080_000_000, 4_080_000_000)
            .unwrap(),
        yaw(0.1),
    );
    assert!(
        h.sample_host_time(device_query + 4_000_000_000, 4_080_000_000)
            .is_none()
    );
}

#[test]
fn exact_interpolated_and_unbracketed_queries_have_distinct_semantics() {
    let mut h = OrientationHistory::new();
    assert!(h.push_device_time(1_000_000_000, yaw(-0.2)));
    assert!(h.push_device_time(1_020_000_000, yaw(0.2)));
    same(h.sample_host_time(1_000_000_000, 0).unwrap(), yaw(-0.2));
    same(h.sample_host_time(1_010_000_000, 0).unwrap(), yaw(0.0));
    same(h.sample_host_time(1_020_000_000, 0).unwrap(), yaw(0.2));
    assert!(h.sample_host_time(999_999_999, 0).is_none());
    assert!(
        h.sample_host_time(1_020_000_001, 0).is_none(),
        "Never substitute newest orientation after the bracket"
    );
}

#[test]
fn fifty_millisecond_each_side_rule_rejects_large_gaps() {
    let mut h = OrientationHistory::new();
    h.push_device_time(1_000_000_000, yaw(-0.2));
    h.push_device_time(1_100_000_000, yaw(0.2));
    same(h.sample_host_time(1_050_000_000, 0).unwrap(), yaw(0.0));
    assert!(h.sample_host_time(1_049_999_999, 0).is_none());
    assert!(h.sample_host_time(1_050_000_001, 0).is_none());
    // A measured exact endpoint is not an invented estimate across that gap.
    same(h.sample_host_time(1_100_000_000, 0).unwrap(), yaw(0.2));
}

#[test]
fn hemisphere_choice_preserves_short_rotation_and_arbitrary_axis_motion() {
    let mut h = OrientationHistory::new();
    let a = Quat::from_rotation_vector([0.10, -0.20, 0.05]);
    let b = Quat::from_rotation_vector([0.20, -0.10, 0.12]);
    h.push_device_time(1_000_000_000, a);
    h.push_device_time(1_020_000_000, -b);
    let expected = Quat {
        w: (a.w + b.w) * 0.5,
        x: (a.x + b.x) * 0.5,
        y: (a.y + b.y) * 0.5,
        z: (a.z + b.z) * 0.5,
    }
    .normalized();
    same(h.sample_host_time(1_010_000_000, 0).unwrap(), expected);
}

#[test]
fn reconnect_and_device_clock_reset_retire_old_orientation_epoch() {
    let mut h = OrientationHistory::new();
    h.push_device_time(2_000_000_000, yaw(0.0));
    h.push_device_time(2_020_000_000, yaw(0.2));
    h.reset();
    assert!(h.sample_host_time(2_010_000_000, 0).is_none());
    h.push_device_time(3_000_000_000, yaw(0.0));
    h.push_device_time(3_020_000_000, yaw(0.2));
    assert!(
        h.push_device_time(1_000_000_000, yaw(0.6)),
        "Backward device clock starts a new epoch"
    );
    assert!(h.sample_host_time(3_010_000_000, 0).is_none());
    same(h.sample_host_time(1_000_000_000, 0).unwrap(), yaw(0.6));
}

#[test]
fn duplicate_and_invalid_samples_do_not_replace_known_history() {
    let mut h = OrientationHistory::new();
    assert!(h.push_device_time(1_000_000_000, yaw(0.2)));
    assert!(!h.push_device_time(1_000_000_000, yaw(1.0)));
    same(h.sample_host_time(1_000_000_000, 0).unwrap(), yaw(0.2));
    assert!(!h.push_device_time(
        1_010_000_000,
        Quat {
            w: 0.0,
            x: 0.0,
            y: 0.0,
            z: 0.0
        }
    ));
    assert!(!h.push_device_time(
        1_010_000_000,
        Quat {
            w: f32::NAN,
            x: 0.0,
            y: 0.0,
            z: 0.0
        }
    ));
    same(h.sample_host_time(1_000_000_000, 0).unwrap(), yaw(0.2));
}
