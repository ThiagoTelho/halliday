use super::*;

#[test]
fn synchronized_null_and_explicit_sources_share_the_exact_entity_for_both_hands() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let hands = [path("/user/hand/left"), path("/user/hand/right")];
    let grip = action(set, xr::ActionType::POSE_INPUT, &hands);
    let other_grip = action(set, xr::ActionType::POSE_INPUT, &hands);
    let aim = action(set, xr::ActionType::POSE_INPUT, &hands);
    assert_eq!(
        bind(&[
            (grip, "/user/hand/left/input/grip/pose"),
            (grip, "/user/hand/right/input/grip/pose"),
            (other_grip, "/user/hand/left/input/grip/pose"),
            (other_grip, "/user/hand/right/input/grip/pose"),
            (aim, "/user/hand/left/input/aim/pose"),
            (aim, "/user/hand/right/input/aim/pose")
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    let a = xr::Posef {
        position: vector([1., 2., 3.]),
        ..IDENTITY
    };
    let b = xr::Posef {
        orientation: xr::Quaternionf {
            x: 0.,
            y: 0.5f32.sqrt(),
            z: 0.,
            w: 0.5f32.sqrt(),
        },
        position: vector([-1., 5., 2.]),
    };
    let aggregate = space(grip, xr::Path::NULL, a).unwrap();
    let bases = hands.map(|hand| space(grip, hand, b).unwrap());
    let aliases = hands.map(|hand| space(other_grip, hand, a).unwrap());
    let aims = hands.map(|hand| space(aim, hand, a).unwrap());
    f.state(|s| {
        s.head.valid = 0;
        for c in &mut s.controllers {
            c.pose.valid = 0;
        }
    });
    let relative = |target, base, time| {
        let mut velocity: xr::SpaceVelocity = unsafe { std::mem::zeroed() };
        velocity.ty = xr::SpaceVelocity::TYPE;
        let mut out = xr::SpaceLocation {
            ty: xr::SpaceLocation::TYPE,
            next: (&mut velocity as *mut xr::SpaceVelocity).cast(),
            location_flags: xr::SpaceLocationFlags::EMPTY,
            pose: IDENTITY,
        };
        assert_eq!(
            unsafe { locate_space(target, base, xr::Time::from_nanos(time), &mut out) },
            xr::Result::SUCCESS
        );
        (out, velocity)
    };
    for hand in 0..2 {
        assert_eq!(sync(&[(set, hands[hand])]), xr::Result::SUCCESS);
        for target in [aggregate, aliases[hand]] {
            let (out, velocity) = relative(target, bases[hand], 10 + hand as i64);
            assert!(out.location_flags.contains(
                xr::SpaceLocationFlags::POSITION_TRACKED | xr::SpaceLocationFlags::POSITION_VALID
            ));
            assert!((out.pose.position.x + 1.).abs() < 1e-5);
            assert!((out.pose.position.y + 3.).abs() < 1e-5);
            assert!((out.pose.position.z - 2.).abs() < 1e-5);
            assert!((out.pose.orientation.y + 0.5f32.sqrt()).abs() < 1e-5);
            assert!((out.pose.orientation.w - 0.5f32.sqrt()).abs() < 1e-5);
            assert_eq!(
                velocity.velocity_flags,
                xr::SpaceVelocityFlags::LINEAR_VALID | xr::SpaceVelocityFlags::ANGULAR_VALID
            );
            assert_eq!(velocity.linear_velocity.x, 0.);
            assert_eq!(velocity.angular_velocity.z, 0.);
        }
        for (target, base) in [(aggregate, bases[1 - hand]), (aims[hand], bases[hand])] {
            let (out, velocity) = relative(target, base, 10 + hand as i64);
            assert!(
                out.location_flags.is_empty(),
                "a different hand or aim/grip identity must not cancel"
            );
            assert!(velocity.velocity_flags.is_empty());
        }
    }
    assert_eq!(sync(&[]), xr::Result::SUCCESS);
    let (out, velocity) = relative(aliases[1], bases[1], 12);
    assert!(out.location_flags.is_empty());
    assert!(
        velocity.velocity_flags.is_empty(),
        "inactive unrelated actions cannot be conflated as two missing sources"
    );
    assert!(
        relative(aggregate, bases[1], 12)
            .0
            .location_flags
            .is_empty(),
        "inactive NULL selection cannot invent the explicit hand identity"
    );
}

#[test]
fn common_reference_entity_has_tracked_relative_position_without_a_head_sample() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    f.state(|s| s.head.valid = 0);
    let a = xr::Posef {
        position: vector([1., 2., 3.]),
        ..IDENTITY
    };
    let b = xr::Posef {
        orientation: xr::Quaternionf {
            x: 0.,
            y: 0.5f32.sqrt(),
            z: 0.,
            w: 0.5f32.sqrt(),
        },
        position: vector([-1., 5., 2.]),
    };
    for kind in [SpaceKind::View, SpaceKind::Local, SpaceKind::Stage] {
        let mut source = xr::Space::NULL;
        let mut base = xr::Space::NULL;
        assert_eq!(
            new_space(session(), kind, a, &mut source),
            xr::Result::SUCCESS
        );
        assert_eq!(
            new_space(session(), kind, b, &mut base),
            xr::Result::SUCCESS
        );
        let mut motion: xr::SpaceVelocity = unsafe { std::mem::zeroed() };
        motion.ty = xr::SpaceVelocity::TYPE;
        let mut out = xr::SpaceLocation {
            ty: xr::SpaceLocation::TYPE,
            next: (&mut motion as *mut xr::SpaceVelocity).cast(),
            location_flags: xr::SpaceLocationFlags::EMPTY,
            pose: IDENTITY,
        };
        assert_eq!(
            unsafe { locate_space(source, base, xr::Time::from_nanos(1), &mut out) },
            xr::Result::SUCCESS
        );
        let required = xr::SpaceLocationFlags::POSITION_VALID
            | xr::SpaceLocationFlags::POSITION_TRACKED
            | xr::SpaceLocationFlags::ORIENTATION_VALID;
        assert!(out.location_flags.contains(required));
        // Independent coordinate oracle: inverse 90-degree Y rotation of
        // ([1,2,3]-[-1,5,2]) is [-1,-3,2]. No tracked world pose is involved.
        assert!((out.pose.position.x + 1.).abs() < 1e-5);
        assert!((out.pose.position.y + 3.).abs() < 1e-5);
        assert!((out.pose.position.z - 2.).abs() < 1e-5);
        assert_eq!(
            motion.velocity_flags,
            xr::SpaceVelocityFlags::LINEAR_VALID | xr::SpaceVelocityFlags::ANGULAR_VALID
        );
        assert_eq!(motion.linear_velocity.x, 0.);
        assert_eq!(motion.angular_velocity.z, 0.);
        assert_eq!(unsafe { destroy_space(source) }, xr::Result::SUCCESS);
        assert_eq!(unsafe { destroy_space(base) }, xr::Result::SUCCESS);
    }
}

#[test]
fn creating_an_unattached_pose_space_is_valid_after_another_set_is_attached() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _f = Fixture::new();
    let main = set();
    let unused = set();
    let left = path("/user/hand/left");
    let attached = action(main, xr::ActionType::POSE_INPUT, &[left]);
    let lazy = action(unused, xr::ActionType::POSE_INPUT, &[left]);
    assert_eq!(
        bind(&[
            (attached, "/user/hand/left/input/grip/pose"),
            (lazy, "/user/hand/left/input/grip/pose")
        ]),
        xr::Result::SUCCESS
    );
    attach(main);
    events();
    assert_eq!(sync(&[(main, xr::Path::NULL)]), xr::Result::SUCCESS);
    // Frameworks can create their spaces independently of which sets a session
    // uses. The space is valid but not locatable without its set being attached.
    let offset = xr::Posef {
        position: vector([0.1, -0.05, 0.02]),
        ..IDENTITY
    };
    let lazy_space =
        space(lazy, left, offset).expect("unattached actions can own valid session spaces");
    assert!(locate(lazy_space).location_flags.is_empty());
    assert_eq!(
        pose(lazy, left),
        Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED)
    );
    assert_eq!(unsafe { destroy_action(lazy) }, xr::Result::SUCCESS);
    assert!(
        locate(lazy_space).location_flags.is_empty(),
        "resource lifetime does not activate an unattached action"
    );
    assert_eq!(unsafe { destroy_space(lazy_space) }, xr::Result::SUCCESS);
    assert_eq!(
        unsafe { destroy_space(lazy_space) },
        xr::Result::ERROR_HANDLE_INVALID
    );
    assert_eq!(
        pose(attached, left),
        Ok(true),
        "creating/destroying an unused set's spaces preserves the active hand"
    );
}

#[test]
fn current_profile_and_change_events_advance_only_at_the_input_sync_boundary() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let left = path("/user/hand/left");
    let right = path("/user/hand/right");
    let input = action(set, xr::ActionType::BOOLEAN_INPUT, &[left, right]);
    assert_eq!(
        bind(&[
            (input, "/user/hand/left/input/x/click"),
            (input, "/user/hand/right/input/a/click")
        ]),
        xr::Result::SUCCESS
    );
    let expected = path("/interaction_profiles/oculus/touch_controller");
    let profile = |hand| {
        let mut state = xr::InteractionProfileState {
            ty: xr::InteractionProfileState::TYPE,
            next: std::ptr::null_mut(),
            interaction_profile: xr::Path::NULL,
        };
        assert_eq!(
            unsafe { get_current_interaction_profile(session(), hand, &mut state) },
            xr::Result::SUCCESS
        );
        state.interaction_profile
    };
    attach(set);
    events();
    assert_eq!(
        profile(left),
        expected,
        "anticipated profile is established at attachment"
    );
    f.state(|s| s.controllers[0].connected = 0);
    assert_eq!(
        profile(left),
        expected,
        "live disconnect before the first sync cannot silently change the announced profile"
    );
    assert!(events().is_empty());
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(profile(left), xr::Path::NULL);
    assert_eq!(profile(right), expected);
    assert_eq!(events(), vec![Seen::Profile]);
    f.state(|s| {
        s.controllers[0].connected = 1;
        s.controllers[1].connected = 0;
    });
    assert_eq!(profile(left), xr::Path::NULL);
    assert_eq!(profile(right), expected);
    assert!(
        events().is_empty(),
        "new hardware connection state is not a profile notification until synchronization"
    );
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(profile(left), expected);
    assert_eq!(profile(right), xr::Path::NULL);
    assert_eq!(
        events(),
        vec![Seen::Profile],
        "one input-sync transition announces both changed hands"
    );
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert!(
        events().is_empty(),
        "repeated synchronization does not duplicate the profile event"
    );
}

fn scalar(action: xr::Action) -> xr::ActionStateFloat {
    let info = xr::ActionStateGetInfo {
        ty: xr::ActionStateGetInfo::TYPE,
        next: std::ptr::null(),
        action,
        subaction_path: xr::Path::NULL,
    };
    let mut value: xr::ActionStateFloat = unsafe { std::mem::zeroed() };
    value.ty = xr::ActionStateFloat::TYPE;
    assert_eq!(
        unsafe { get_action_state_float(session(), &info, &mut value) },
        xr::Result::SUCCESS
    );
    value
}

fn stick(action: xr::Action) -> xr::ActionStateVector2f {
    let info = xr::ActionStateGetInfo {
        ty: xr::ActionStateGetInfo::TYPE,
        next: std::ptr::null(),
        action,
        subaction_path: xr::Path::NULL,
    };
    let mut value: xr::ActionStateVector2f = unsafe { std::mem::zeroed() };
    value.ty = xr::ActionStateVector2f::TYPE;
    assert_eq!(
        unsafe { get_action_state_vector2f(session(), &info, &mut value) },
        xr::Result::SUCCESS
    );
    value
}

#[test]
fn action_resources_priority_and_immutability_survive_pre_session_destruction_and_session_reuse() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _first_host = Fixture::new();
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    let left = path("/user/hand/left");
    let low = set_with_priority(0);
    let high = set_with_priority(10);
    let lower = action(low, xr::ActionType::BOOLEAN_INPUT, &[left]);
    let destroyed = action(high, xr::ActionType::BOOLEAN_INPUT, &[left]);
    assert_eq!(
        bind(&[
            (lower, "/user/hand/left/input/trigger/value"),
            (destroyed, "/user/hand/left/input/trigger/value")
        ]),
        xr::Result::SUCCESS
    );
    assert_eq!(unsafe { destroy_action(destroyed) }, xr::Result::SUCCESS);
    assert!(
        with(|r| r.actions.contains_key(&destroyed.into_raw())),
        "destroying before any session still preserves instance-owned source resources"
    );
    let sets = [low, high];
    let attach_both = || {
        let info = xr::SessionActionSetsAttachInfo {
            ty: xr::SessionActionSetsAttachInfo::TYPE,
            next: std::ptr::null(),
            count_action_sets: 2,
            action_sets: sets.as_ptr(),
        };
        assert_eq!(
            unsafe { attach_session_action_sets(session(), &info) },
            xr::Result::SUCCESS
        );
        events();
    };
    let second = Fixture::new_preserving_actions(true);
    attach_both();
    second.state(|s| s.controllers[0].pressed = BIT_TRIGGER);
    assert_eq!(
        sync(&[(low, xr::Path::NULL), (high, xr::Path::NULL)]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        boolean(lower, left).is_active,
        xr::FALSE,
        "destroyed high-priority action still captures its physical source on the first session"
    );
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    let mut create: xr::ActionCreateInfo = unsafe { std::mem::zeroed() };
    create.ty = xr::ActionCreateInfo::TYPE;
    create.action_type = xr::ActionType::BOOLEAN_INPUT;
    create.action_name[0] = b'n' as _;
    create.localized_action_name[0] = b'N' as _;
    let mut result = xr::Action::NULL;
    assert_eq!(
        unsafe { create_action(low, &create, &mut result) },
        xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED,
        "a previously attached live set stays immutable after its old session is gone"
    );
    assert_eq!(
        bind(&[(lower, "/user/hand/left/input/x/click")]),
        xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED,
        "session teardown cannot allow replacement bindings for a frozen action set"
    );
    let third = Fixture::new_preserving_actions(true);
    attach_both();
    third.state(|s| s.controllers[0].pressed = BIT_TRIGGER);
    assert_eq!(
        sync(&[(low, xr::Path::NULL), (high, xr::Path::NULL)]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        boolean(lower, left).is_active,
        xr::FALSE,
        "the instance-owned destroyed binding still captures the source after session recreation"
    );
    assert_eq!(sync(&[(low, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(boolean(lower, left).current_state, xr::TRUE);
    instance_destroyed(1);
    assert!(with(|r| r.actions.is_empty()
        && r.action_sets.is_empty()
        && r.bindings.is_empty()
        && r.paths.is_empty()
        && r.suggested_profiles.is_empty()
        && r.selected_profiles == [None; 2]));
    let next_left = path("/user/hand/left");
    assert_ne!(
        left, next_left,
        "a new instance cannot accidentally accept a stale XrPath"
    );
    let mut count = 0;
    assert_eq!(
        unsafe {
            path_to_string(
                xr::Instance::NULL,
                left,
                0,
                &mut count,
                std::ptr::null_mut(),
            )
        },
        xr::Result::ERROR_PATH_INVALID
    );
    let next_set = set();
    let next_action = action(next_set, xr::ActionType::BOOLEAN_INPUT, &[next_left]);
    let binding = xr::ActionSuggestedBinding {
        action: next_action,
        binding: path("/user/hand/left/input/select/click"),
    };
    let simple = path("/interaction_profiles/khr/simple_controller");
    let info = xr::InteractionProfileSuggestedBinding {
        ty: xr::InteractionProfileSuggestedBinding::TYPE,
        next: std::ptr::null(),
        interaction_profile: simple,
        count_suggested_bindings: 1,
        suggested_bindings: &binding,
    };
    assert_eq!(
        unsafe { suggest_interaction_profile_bindings(xr::Instance::NULL, &info) },
        xr::Result::SUCCESS
    );
    assert_eq!(
        with(|r| r.suggested_profiles.get(&simple.into_raw()).map(|p| p.rank)),
        Some(1),
        "the previous instance's preferred profile cannot suppress a fresh lower-ranked profile"
    );
}

#[test]
fn aggregate_input_source_handover_does_not_fabricate_changes_and_caches_complete_vectors() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let hands = [path("/user/hand/left"), path("/user/hand/right")];
    let button = action(set, xr::ActionType::BOOLEAN_INPUT, &hands);
    let axis = action(set, xr::ActionType::FLOAT_INPUT, &hands);
    let vector = action(set, xr::ActionType::VECTOR2F_INPUT, &hands);
    assert_eq!(
        bind(&[
            (button, "/user/hand/left/input/trigger/value"),
            (button, "/user/hand/right/input/trigger/value"),
            (axis, "/user/hand/left/input/thumbstick/x"),
            (axis, "/user/hand/right/input/thumbstick/x"),
            (vector, "/user/hand/left/input/thumbstick"),
            (vector, "/user/hand/right/input/thumbstick"),
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    let publish = |triggers: [f32; 2], sticks: [[f32; 2]; 2]| {
        f.state(|s| {
            for hand in 0..2 {
                s.controllers[hand].axes[1][0] = triggers[hand];
                s.controllers[hand].axes[0] = sticks[hand];
            }
        })
    };
    publish([1., 0.], [[-0.8, 0.], [0.4, 0.9]]);
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    let a = boolean(button, xr::Path::NULL);
    let b = scalar(axis);
    let c = stick(vector);
    assert_eq!(a.current_state, xr::TRUE);
    assert_eq!(b.current_state, -0.8);
    assert_eq!(
        [c.current_state.x, c.current_state.y],
        [0.4, 0.9],
        "vector aggregation selects a complete source vector rather than mixing axes"
    );
    assert_eq!(a.changed_since_last_sync, xr::FALSE);
    assert_eq!(b.changed_since_last_sync, xr::FALSE);
    publish([0., 1.], [[0.4, 0.9], [-0.8, 0.]]);
    assert_eq!(
        scalar(axis).current_state,
        -0.8,
        "hardware updates are invisible until SyncActions"
    );
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    let aa = boolean(button, xr::Path::NULL);
    let bb = scalar(axis);
    let cc = stick(vector);
    assert_eq!(aa.current_state, a.current_state);
    assert_eq!(bb.current_state, b.current_state);
    assert_eq!(
        [cc.current_state.x, cc.current_state.y],
        [c.current_state.x, c.current_state.y]
    );
    assert_eq!(aa.changed_since_last_sync, xr::FALSE);
    assert_eq!(bb.changed_since_last_sync, xr::FALSE);
    assert_eq!(cc.changed_since_last_sync, xr::FALSE);
    assert_eq!(aa.last_change_time, a.last_change_time);
    assert_eq!(bb.last_change_time, b.last_change_time);
    assert_eq!(cc.last_change_time, c.last_change_time);
    publish([0., 0.], [[0.3, 0.], [0.2, 0.2]]);
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(
        boolean(button, xr::Path::NULL).changed_since_last_sync,
        xr::TRUE
    );
    assert_eq!(scalar(axis).current_state, 0.3);
    assert_eq!(scalar(axis).changed_since_last_sync, xr::TRUE);
    assert_eq!(
        [stick(vector).current_state.x, stick(vector).current_state.y],
        [0.3, 0.]
    );
    assert_eq!(stick(vector).changed_since_last_sync, xr::TRUE);
    f._host.set_dashboard(true);
    events();
    assert_eq!(
        sync(&[(set, xr::Path::NULL)]),
        xr::Result::SESSION_NOT_FOCUSED
    );
    let inactive = scalar(axis);
    assert_eq!(inactive.is_active, xr::FALSE);
    assert_eq!(inactive.current_state, 0.);
    assert_eq!(inactive.changed_since_last_sync, xr::FALSE);
    assert_eq!(inactive.last_change_time.as_nanos(), 0);
    publish([1., 0.], [[-0.8, 0.], [0.4, 0.9]]);
    f._host.set_dashboard(false);
    events();
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(
        boolean(button, xr::Path::NULL).changed_since_last_sync,
        xr::FALSE
    );
    assert_eq!(scalar(axis).changed_since_last_sync, xr::FALSE);
    assert_eq!(stick(vector).changed_since_last_sync, xr::FALSE);
    assert_eq!(sync(&[]), xr::Result::SUCCESS);
    assert_eq!(stick(vector).is_active, xr::FALSE);
    assert_eq!(stick(vector).last_change_time.as_nanos(), 0);
}
