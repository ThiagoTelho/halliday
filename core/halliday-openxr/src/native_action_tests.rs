use super::*;
use halliday_core::game_bridge::GameBridge as Host;

struct Fixture {
    _host: Host,
    path: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        Self::new_preserving_actions(false)
    }
    fn new_preserving_actions(preserve: bool) -> Self {
        let path = std::env::temp_dir().join(format!(
            "halliday-native-actions-{}-{}.shm",
            std::process::id(),
            halliday_core::time::host_time_ns()
        ));
        let config = Config {
            eye_width: 64,
            eye_height: 64,
            display_hz: 120.0,
            ipd: 0.064,
            tangents: [[-1.0, 1.0, 1.0, -1.0]; 2],
        };
        let host = Host::create(&path, config).unwrap();
        let mut state = bridge::State::default();
        state.head = bridge::Pose {
            position: [0.0, 1.6, 0.0],
            orientation: [0.0, 0.0, 0.0, 1.0],
            valid: 1,
            ..Default::default()
        };
        for hand in 0..2 {
            state.controllers[hand] = bridge::Controller {
                connected: 1,
                pose: bridge::Pose {
                    position: [if hand == 0 { -0.3 } else { 0.3 }, 1.0, -0.4],
                    orientation: [0.0, 0.0, 0.0, 1.0],
                    valid: 1,
                    ..Default::default()
                },
                ..Default::default()
            };
        }
        host.publish(&state);
        let side = GameSide::view(&path).unwrap();
        assert!(side.register_client_as("native action fixture"));
        let haptic_epoch = side.begin_haptics();
        with(|r| {
            let retained = if preserve {
                drop_session(r);
                Some(std::mem::take(r))
            } else {
                None
            };
            *r = Runtime {
                next_handle: 0x1000,
                session: Some(Session {
                    handle: 0x200,
                    instance: 1,
                    queue: std::ptr::null_mut(),
                    device: std::ptr::null_mut(),
                    vulkan: std::ptr::null_mut(),
                    readback: Default::default(),
                    panel_readback: Default::default(),
                    scratch: std::ptr::null_mut(),
                    scratch_bytes: 0,
                    side,
                    config,
                    display_period_override: None,
                    state: xr::SessionState::FOCUSED,
                    running: true,
                    spaces: HashMap::from([(
                        0x300,
                        Space {
                            kind: SpaceKind::Stage,
                            offset: IDENTITY,
                        },
                    )]),
                    swapchains: HashMap::new(),
                    newest: Some(state),
                    newest_motion: bridge::motion::ALL,
                    newest_controller_frames: bridge::controller_frames::LEGACY,
                    pose_samples: Default::default(),
                    pose_epoch_start: 0,
                    pose_latest_time: 0,
                    given: VecDeque::new(),
                    local: Some(IDENTITY),
                    synced: Default::default(),
                    synced_before: Default::default(),
                    profile_connected: None,
                    attached_sets: None,
                    active_sets: HashMap::new(),
                    pose_sources: HashMap::new(),
                    readings: HashMap::new(),
                    waited: false,
                    begun: false,
                    display_time: 1234,
                    quit_requests: 0,
                    haptic_epoch,
                    haptic_actions: [None; 2],
                    focus_generation: 0,
                    space_epoch: 0,
                    wait_space_epoch: 0,
                    frame_space_epoch: 0,
                    heartbeat: None,
                    registered: true,
                    last_host_tick: 1,
                    last_host_progress: Instant::now(),
                    frames: 0,
                }),
                ..Default::default()
            };
            if let Some(retained) = retained {
                r.actions = retained.actions;
                r.action_sets = retained.action_sets;
                r.bindings = retained.bindings;
                r.paths = retained.paths;
                r.suggested_profiles = retained.suggested_profiles;
                r.selected_profiles = retained.selected_profiles;
                r.next_handle = retained.next_handle;
            }
        });
        Self { _host: host, path }
    }
    fn state(&self, f: impl FnOnce(&mut bridge::State)) {
        let state = with(|r| {
            let state = r.session.as_mut().unwrap().newest.as_mut().unwrap();
            f(state);
            *state
        });
        self._host.publish(&state);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        with(|r| {
            drop_session(r);
            r.actions.clear();
            r.bindings.clear();
        });
        let _ = std::fs::remove_file(&self.path);
    }
}
fn session() -> xr::Session {
    xr::Session::from_raw(0x200)
}
fn path(text: &str) -> xr::Path {
    let c = std::ffi::CString::new(text).unwrap();
    let mut out = xr::Path::NULL;
    assert_eq!(
        unsafe { string_to_path(xr::Instance::NULL, c.as_ptr(), &mut out) },
        xr::Result::SUCCESS
    );
    out
}
fn set() -> xr::ActionSet {
    set_with_priority(0)
}
fn set_with_priority(priority: u32) -> xr::ActionSet {
    let mut info: xr::ActionSetCreateInfo = unsafe { std::mem::zeroed() };
    info.ty = xr::ActionSetCreateInfo::TYPE;
    info.priority = priority;
    info.action_set_name[0] = b'a' as _;
    info.localized_action_set_name[0] = b'A' as _;
    let mut out = xr::ActionSet::NULL;
    assert_eq!(
        unsafe { create_action_set(xr::Instance::NULL, &info, &mut out) },
        xr::Result::SUCCESS
    );
    out
}
fn action(set: xr::ActionSet, kind: xr::ActionType, paths: &[xr::Path]) -> xr::Action {
    let mut info: xr::ActionCreateInfo = unsafe { std::mem::zeroed() };
    info.ty = xr::ActionCreateInfo::TYPE;
    info.action_type = kind;
    info.action_name[0] = b'a' as _;
    info.localized_action_name[0] = b'A' as _;
    info.count_subaction_paths = paths.len() as u32;
    info.subaction_paths = paths.as_ptr();
    let mut out = xr::Action::NULL;
    assert_eq!(
        unsafe { create_action(set, &info, &mut out) },
        xr::Result::SUCCESS
    );
    out
}
fn space(
    action: xr::Action,
    subaction: xr::Path,
    offset: xr::Posef,
) -> Result<xr::Space, xr::Result> {
    let info = xr::ActionSpaceCreateInfo {
        ty: xr::ActionSpaceCreateInfo::TYPE,
        next: std::ptr::null(),
        action,
        subaction_path: subaction,
        pose_in_action_space: offset,
    };
    let mut out = xr::Space::NULL;
    let result = unsafe { create_action_space(session(), &info, &mut out) };
    if result == xr::Result::SUCCESS {
        Ok(out)
    } else {
        Err(result)
    }
}
fn pose(action: xr::Action, subaction: xr::Path) -> Result<bool, xr::Result> {
    let info = xr::ActionStateGetInfo {
        ty: xr::ActionStateGetInfo::TYPE,
        next: std::ptr::null(),
        action,
        subaction_path: subaction,
    };
    let mut out = xr::ActionStatePose {
        ty: xr::ActionStatePose::TYPE,
        next: std::ptr::null_mut(),
        is_active: xr::TRUE,
    };
    let result = unsafe { get_action_state_pose(session(), &info, &mut out) };
    if result == xr::Result::SUCCESS {
        Ok(out.is_active == xr::TRUE)
    } else {
        Err(result)
    }
}
fn locate_at(space: xr::Space, time: i64) -> xr::SpaceLocation {
    let mut out = xr::SpaceLocation {
        ty: xr::SpaceLocation::TYPE,
        next: std::ptr::null_mut(),
        location_flags: xr::SpaceLocationFlags::EMPTY,
        pose: IDENTITY,
    };
    assert_eq!(
        unsafe {
            locate_space(
                space,
                xr::Space::from_raw(0x300),
                xr::Time::from_nanos(time),
                &mut out,
            )
        },
        xr::Result::SUCCESS
    );
    out
}
fn locate(space: xr::Space) -> xr::SpaceLocation {
    locate_at(space, halliday_core::time::host_time_ns())
}
fn views_at(time: i64, base: xr::Space) -> ([xr::View; 2], xr::ViewStateFlags) {
    let info = xr::ViewLocateInfo {
        ty: xr::ViewLocateInfo::TYPE,
        next: std::ptr::null(),
        view_configuration_type: xr::ViewConfigurationType::PRIMARY_STEREO,
        display_time: xr::Time::from_nanos(time),
        space: base,
    };
    let mut views: [xr::View; 2] = unsafe { std::mem::zeroed() };
    let mut state: xr::ViewState = unsafe { std::mem::zeroed() };
    let mut count = 0;
    assert_eq!(
        unsafe {
            locate_views(
                session(),
                &info,
                &mut state,
                2,
                &mut count,
                views.as_mut_ptr(),
            )
        },
        xr::Result::SUCCESS
    );
    assert_eq!(count, 2);
    (views, state.view_state_flags)
}
fn sync(active: &[(xr::ActionSet, xr::Path)]) -> xr::Result {
    let sets = active
        .iter()
        .map(|&(action_set, subaction_path)| xr::ActiveActionSet {
            action_set,
            subaction_path,
        })
        .collect::<Vec<_>>();
    let info = xr::ActionsSyncInfo {
        ty: xr::ActionsSyncInfo::TYPE,
        next: std::ptr::null(),
        count_active_action_sets: sets.len() as u32,
        active_action_sets: sets.as_ptr(),
    };
    unsafe { sync_actions(session(), &info) }
}
fn near(actual: xr::Posef, expected: xr::Posef) {
    let p = actual.position;
    let e = expected.position;
    assert!(
        (p.x - e.x).abs() < 1e-6 && (p.y - e.y).abs() < 1e-6 && (p.z - e.z).abs() < 1e-6,
        "position differs"
    );
    let q = actual.orientation;
    let e = expected.orientation;
    assert!(
        (q.x - e.x).abs() < 1e-6
            && (q.y - e.y).abs() < 1e-6
            && (q.z - e.z).abs() < 1e-6
            && (q.w - e.w).abs() < 1e-6,
        "orientation differs"
    );
}

#[test]
fn native_pose_actions_preserve_bindings_sources_confidence_and_public_offsets() {
    let _runtime = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let left = path("/user/hand/left");
    let right = path("/user/hand/right");
    let null = xr::Path::NULL;
    let main = set();
    let other = set();
    let grip = action(main, xr::ActionType::POSE_INPUT, &[]);
    let aim = action(main, xr::ActionType::POSE_INPUT, &[left]);
    let both = action(main, xr::ActionType::POSE_INPUT, &[left, right]);
    let scalar = action(main, xr::ActionType::BOOLEAN_INPUT, &[left]);
    let unattached = action(other, xr::ActionType::POSE_INPUT, &[left]);
    let bindings = [
        (grip, "/user/hand/left/input/grip/pose"),
        (aim, "/user/hand/left/input/aim/pose"),
        (both, "/user/hand/left/input/grip/pose"),
        (both, "/user/hand/right/input/aim/pose"),
        (scalar, "/user/hand/left/input/trigger/click"),
        (unattached, "/user/hand/left/input/grip/pose"),
    ]
    .map(|(action, p)| xr::ActionSuggestedBinding {
        action,
        binding: path(p),
    });
    let info = xr::InteractionProfileSuggestedBinding {
        ty: xr::InteractionProfileSuggestedBinding::TYPE,
        next: std::ptr::null(),
        interaction_profile: path("/interaction_profiles/oculus/touch_controller"),
        count_suggested_bindings: bindings.len() as u32,
        suggested_bindings: bindings.as_ptr(),
    };
    assert_eq!(
        unsafe { suggest_interaction_profile_bindings(xr::Instance::NULL, &info) },
        xr::Result::SUCCESS
    );
    let grip_space = space(grip, null, IDENTITY).unwrap();
    let aim_space = space(aim, null, IDENTITY).unwrap();
    let both_space = space(both, null, IDENTITY).unwrap();
    let right_space = space(both, right, IDENTITY).unwrap();
    assert_eq!(
        pose(grip, null),
        Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED)
    );
    assert_eq!(
        space(scalar, left, IDENTITY),
        Err(xr::Result::ERROR_ACTION_TYPE_MISMATCH)
    );
    assert_eq!(
        space(aim, right, IDENTITY),
        Err(xr::Result::ERROR_PATH_UNSUPPORTED)
    );
    assert_eq!(
        space(aim, xr::Path::from_raw(99999), IDENTITY),
        Err(xr::Result::ERROR_PATH_INVALID)
    );
    let attach = xr::SessionActionSetsAttachInfo {
        ty: xr::SessionActionSetsAttachInfo::TYPE,
        next: std::ptr::null(),
        count_action_sets: 1,
        action_sets: &main,
    };
    assert_eq!(
        unsafe { attach_session_action_sets(session(), &attach) },
        xr::Result::SUCCESS
    );
    assert_eq!(
        unsafe { attach_session_action_sets(session(), &attach) },
        xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED
    );
    let unattached_space = space(unattached, left, IDENTITY).unwrap();
    assert!(locate(unattached_space).location_flags.is_empty(),
        "a valid session space for an unattached action remains unlocatable");
    assert_eq!(pose(grip, null), Ok(false));
    assert!(locate(grip_space).location_flags.is_empty());
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert_eq!(pose(grip, null), Ok(true));
    assert_eq!(pose(both, null), Ok(true));
    assert_eq!(pose(both, right), Ok(true));
    assert_eq!(
        pose(scalar, left),
        Err(xr::Result::ERROR_ACTION_TYPE_MISMATCH)
    );
    assert_eq!(
        pose(unattached, left),
        Err(xr::Result::ERROR_ACTIONSET_NOT_ATTACHED)
    );
    with(|r| {
        let p = &r.session.as_ref().unwrap().pose_sources[&both.into_raw()];
        assert_eq!(p.selected, Some(0));
        assert_eq!(p.kinds, [Some(Part::GripPose), Some(Part::AimPose)]);
    });
    let left_pose =
        with(|r| from_bridge(&r.session.as_ref().unwrap().newest.unwrap().controllers[0].pose));
    near(locate(grip_space).pose, left_pose);
    near(locate(aim_space).pose, left_pose);
    near(locate(both_space).pose, left_pose);
    assert!(locate(right_space).pose.position.x > 0.2);

    // Tracking confidence is separate from connection/action activity. No invented
    // orientation-only confidence bits can be inferred from the legacy boolean.
    f.state(|s| s.controllers[0].pose.valid = 0);
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert_eq!(pose(grip, null), Ok(true));
    assert!(locate(grip_space).location_flags.is_empty());
    f.state(|s| {
        s.controllers[0].pose.valid = 1;
        s.head.valid = 0;
    });
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert_eq!(pose(grip, null), Ok(true));
    assert!(
        locate(grip_space)
            .location_flags
            .contains(xr::SpaceLocationFlags::POSITION_TRACKED),
        "independently tracked controller in STAGE does not depend on head confidence"
    );
    f.state(|s| s.head.valid = 1);

    // A NULL multi-bound source stays left until the next sync sees it disconnected,
    // then remains right when left reconnects. It never flips sources during Locate.
    f.state(|s| s.controllers[0].connected = 0);
    assert!(locate(both_space).location_flags.is_empty());
    assert_eq!(pose(both, null), Ok(true));
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert_eq!(pose(grip, null), Ok(false));
    assert!(locate(both_space).pose.position.x > 0.2);
    f.state(|s| s.controllers[0].connected = 1);
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert!(locate(both_space).pose.position.x > 0.2);
    f.state(|s| s.controllers[1].connected = 0);
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert!(locate(both_space).pose.position.x < -0.2);
    f.state(|s| s.controllers[1].connected = 1);

    // Both hands retain exact canonical origins under noncommuting wrist rotations.
    // The application's own poseInActionSpace is composed exactly once.
    let half = 0.35f32;
    let offset = xr::Posef {
        orientation: xr::Quaternionf {
            x: half.sin(),
            y: 0.0,
            z: 0.0,
            w: half.cos(),
        },
        position: xr::Vector3f {
            x: 0.03,
            y: 0.04,
            z: -0.05,
        },
    };
    for (hand, subaction, identity_space) in [(0, left, grip_space), (1, right, right_space)] {
        let offset_space = space(both, subaction, offset).unwrap();
        for angle in [-1.2f32, 0.0, 1.1] {
            f.state(|s| {
                s.controllers[hand].pose.orientation =
                    [0.0, 0.0, (angle * 0.5).sin(), (angle * 0.5).cos()]
            });
            assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
            let canonical = with(|r| {
                from_bridge(&r.session.as_ref().unwrap().newest.unwrap().controllers[hand].pose)
            });
            near(locate(identity_space).pose, canonical);
            near(locate(offset_space).pose, compose(canonical, offset));
        }
    }
    let mut invalid = IDENTITY;
    invalid.orientation.w = 0.5;
    assert_eq!(
        space(both, left, invalid),
        Err(xr::Result::ERROR_POSE_INVALID)
    );
    assert_eq!(sync(&[(main, right)]), xr::Result::SUCCESS);
    assert_eq!(pose(both, left), Ok(false));
    assert_eq!(pose(both, null), Ok(true));
    assert_eq!(sync(&[]), xr::Result::SUCCESS);
    assert_eq!(pose(both, null), Ok(false));
    assert!(locate(both_space).location_flags.is_empty());
    assert_eq!(
        sync(&[(other, null)]),
        xr::Result::ERROR_ACTIONSET_NOT_ATTACHED
    );
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    f._host.set_dashboard(true);
    assert_eq!(pose(both, null), Ok(false));
    assert_eq!(sync(&[(main, null)]), xr::Result::SESSION_NOT_FOCUSED);
    f._host.set_dashboard(false);
    assert_eq!(sync(&[(main, null)]), xr::Result::SUCCESS);
    assert_eq!(pose(both, null), Ok(true));
    assert_eq!(
        unsafe { apply_haptic_feedback(session(), std::ptr::null(), std::ptr::null()) },
        xr::Result::ERROR_VALIDATION_FAILURE
    );
    assert_eq!(
        unsafe { stop_haptic_feedback(session(), std::ptr::null()) },
        xr::Result::ERROR_VALIDATION_FAILURE
    );
    assert_eq!(unsafe { destroy_action(grip) }, xr::Result::SUCCESS);
    assert!(
        locate(grip_space)
            .location_flags
            .contains(xr::SpaceLocationFlags::POSITION_TRACKED),
        "existing action space retains the attached action resource after public handle destruction"
    );
    assert_eq!(pose(grip, null), Err(xr::Result::ERROR_HANDLE_INVALID));
    assert_eq!(unsafe { destroy_action_set(main) }, xr::Result::SUCCESS);
    assert!(
        locate(both_space)
            .location_flags
            .contains(xr::SpaceLocationFlags::POSITION_TRACKED),
        "destroying the action-set handle does not free session-owned action spaces"
    );
    assert_eq!(sync(&[]), xr::Result::SUCCESS);
    assert!(locate(both_space).location_flags.is_empty());
}

#[test]
fn pose_binding_classification_and_stable_selection() {
    assert_eq!(
        part("/user/hand/left/input/grip/pose"),
        Some((0, Part::GripPose))
    );
    assert_eq!(
        part("/user/hand/right/input/aim/pose"),
        Some((1, Part::AimPose))
    );
    assert_eq!(choose_pose_source(None, [true, true]), Some(0));
    assert_eq!(choose_pose_source(Some(1), [true, true]), Some(1));
    assert_eq!(choose_pose_source(Some(1), [true, false]), Some(0));
    assert_eq!(choose_pose_source(Some(0), [false, false]), None);
}

fn bind(entries: &[(xr::Action, &str)]) -> xr::Result {
    let bindings = entries
        .iter()
        .map(|(action, p)| xr::ActionSuggestedBinding {
            action: *action,
            binding: path(p),
        })
        .collect::<Vec<_>>();
    let info = xr::InteractionProfileSuggestedBinding {
        ty: xr::InteractionProfileSuggestedBinding::TYPE,
        next: std::ptr::null(),
        interaction_profile: path("/interaction_profiles/oculus/touch_controller"),
        count_suggested_bindings: bindings.len() as u32,
        suggested_bindings: bindings.as_ptr(),
    };
    unsafe { suggest_interaction_profile_bindings(xr::Instance::NULL, &info) }
}
fn attach(set: xr::ActionSet) {
    let info = xr::SessionActionSetsAttachInfo {
        ty: xr::SessionActionSetsAttachInfo::TYPE,
        next: std::ptr::null(),
        count_action_sets: 1,
        action_sets: &set,
    };
    assert_eq!(
        unsafe { attach_session_action_sets(session(), &info) },
        xr::Result::SUCCESS
    );
}
fn boolean(action: xr::Action, hand: xr::Path) -> xr::ActionStateBoolean {
    let info = xr::ActionStateGetInfo {
        ty: xr::ActionStateGetInfo::TYPE,
        next: std::ptr::null(),
        action,
        subaction_path: hand,
    };
    let mut out = xr::ActionStateBoolean {
        ty: xr::ActionStateBoolean::TYPE,
        next: std::ptr::null_mut(),
        current_state: xr::FALSE,
        changed_since_last_sync: xr::FALSE,
        last_change_time: xr::Time::from_nanos(0),
        is_active: xr::FALSE,
    };
    assert_eq!(
        unsafe { get_action_state_boolean(session(), &info, &mut out) },
        xr::Result::SUCCESS
    );
    out
}
#[derive(Debug, PartialEq)]
enum Seen {
    State(xr::SessionState),
    Reference(xr::ReferenceSpaceType, bool),
    Profile,
}
fn events() -> Vec<Seen> {
    let mut result = Vec::new();
    loop {
        let mut buffer: xr::EventDataBuffer = unsafe { std::mem::zeroed() };
        let status = unsafe { poll(1, &mut buffer) };
        if status == xr::Result::EVENT_UNAVAILABLE {
            break;
        }
        assert_eq!(status, xr::Result::SUCCESS);
        match buffer.ty {
            xr::StructureType::EVENT_DATA_SESSION_STATE_CHANGED => result.push(Seen::State(
                unsafe { *(&buffer as *const _ as *const xr::EventDataSessionStateChanged) }.state,
            )),
            xr::StructureType::EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING => {
                let event = unsafe {
                    &*(&buffer as *const _ as *const xr::EventDataReferenceSpaceChangePending)
                };
                assert!(event.change_time.as_nanos() > 0);
                result.push(Seen::Reference(
                    event.reference_space_type,
                    event.pose_valid == xr::TRUE,
                ));
            }
            xr::StructureType::EVENT_DATA_INTERACTION_PROFILE_CHANGED => result.push(Seen::Profile),
            ty => panic!("unexpected event {ty:?}"),
        }
    }
    result
}
#[test]
fn event_only_dashboard_quit_host_loss_and_shutdown_are_live() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    for _ in 0..3 {
        f._host.set_dashboard(true);
        assert_eq!(events(), vec![Seen::State(xr::SessionState::VISIBLE)]);
        assert!(events().is_empty());
        f._host.set_dashboard(false);
        assert_eq!(events(), vec![Seen::State(xr::SessionState::FOCUSED)]);
    }
    f._host.request_quit();
    assert_eq!(
        events(),
        vec![
            Seen::State(xr::SessionState::VISIBLE),
            Seen::State(xr::SessionState::SYNCHRONIZED),
            Seen::State(xr::SessionState::STOPPING)
        ]
    );
    assert!(events().is_empty());
    assert_eq!(f._host.client().quit_acknowledged, 1);
    let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
    frame.ty = xr::FrameState::TYPE;
    assert_eq!(
        unsafe { wait_frame(session(), std::ptr::null(), &mut frame) },
        xr::Result::SUCCESS
    );
    assert_eq!(frame.should_render, xr::FALSE);
    assert_eq!(
        unsafe { begin_frame(session(), std::ptr::null()) },
        xr::Result::SUCCESS
    );
    let end = xr::FrameEndInfo {
        ty: xr::FrameEndInfo::TYPE,
        next: std::ptr::null(),
        display_time: frame.predicted_display_time,
        environment_blend_mode: xr::EnvironmentBlendMode::OPAQUE,
        layer_count: 0,
        layers: std::ptr::null(),
    };
    assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    assert_eq!(unsafe { end_session(session()) }, xr::Result::SUCCESS);
    assert_eq!(
        events(),
        vec![
            Seen::State(xr::SessionState::IDLE),
            Seen::State(xr::SessionState::EXITING)
        ]
    );
    assert!(
        !f._host.client().initialized,
        "XR end releases registration even if a 2D guest continues"
    );
    f._host.set_dashboard(true);
    f._host.set_dashboard(false);
    assert!(events().is_empty());
    let next = GameSide::view(&f.path).unwrap();
    assert!(next.register_client_as("next independent client"));
    let next_epoch = next.begin_haptics();
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    assert!(
        f._host.client().initialized,
        "late destroy cannot unregister the next client"
    );
    assert_eq!(
        unsafe { bridge::haptics::extension(f._host.base().cast()) }
            .client_epoch
            .load(std::sync::atomic::Ordering::SeqCst),
        next_epoch
    );
    next.end_haptics(next_epoch);
    next.unregister_client();
    drop(next);
    drop(f);
    let f = Fixture::new();
    let header = f._host.base().cast::<bridge::Header>();
    unsafe {
        (*header)
            .halliday_alive
            .store(0, std::sync::atomic::Ordering::SeqCst)
    };
    assert!(events().contains(&Seen::State(xr::SessionState::STOPPING)));
    unsafe {
        (*header)
            .halliday_alive
            .store(1, std::sync::atomic::Ordering::SeqCst)
    };
    assert!(events().is_empty());
}
#[test]
fn repeated_bindings_live_input_and_cached_changes_match_sync_contract() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let left = path("/user/hand/left");
    let input = action(set, xr::ActionType::BOOLEAN_INPUT, &[left]);
    assert_eq!(
        bind(&[(input, "/user/hand/left/input/x/click")]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        bind(&[
            (input, "/user/hand/left/input/trigger/click"),
            (input, "/user/hand/left/input/x/click")
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    assert_eq!(events(), vec![Seen::Profile]);
    assert_eq!(
        bind(&[(input, "/user/hand/left/input/x/click")]),
        xr::Result::ERROR_ACTIONSETS_ALREADY_ATTACHED
    );
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(boolean(input, left).current_state, xr::FALSE);
    let mut state = with(|r| r.session.as_ref().unwrap().newest.unwrap());
    state.controllers[0].pressed = BIT_A;
    // No xrWaitFrame: input must still read the live sample at the next sync.
    f._host.publish(&state);
    assert_eq!(boolean(input, left).current_state, xr::FALSE);
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    let pressed = boolean(input, left);
    assert_eq!(pressed.current_state, xr::TRUE);
    assert_eq!(pressed.changed_since_last_sync, xr::TRUE);
    let again = boolean(input, left);
    assert_eq!(again.last_change_time, pressed.last_change_time);
    assert_eq!(again.changed_since_last_sync, xr::TRUE);
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    let unchanged = boolean(input, left);
    assert_eq!(unchanged.changed_since_last_sync, xr::FALSE);
    assert_eq!(unchanged.last_change_time, pressed.last_change_time);
    assert!(
        with(|r| r.session.as_mut().unwrap().side.poll_frame().is_some()),
        "input sync did not consume the display notification"
    );
    let info = xr::BoundSourcesForActionEnumerateInfo {
        ty: xr::BoundSourcesForActionEnumerateInfo::TYPE,
        next: std::ptr::null(),
        action: input,
    };
    let mut count = 0;
    assert_eq!(
        unsafe {
            enumerate_bound_sources_for_action(
                session(),
                &info,
                0,
                &mut count,
                std::ptr::null_mut(),
            )
        },
        xr::Result::SUCCESS
    );
    assert_eq!(count, 2);
    let source = path("/user/hand/left/input/x/click");
    let info = xr::InputSourceLocalizedNameGetInfo {
        ty: xr::InputSourceLocalizedNameGetInfo::TYPE,
        next: std::ptr::null(),
        source_path: source,
        which_components: xr::InputSourceLocalizedNameFlags::USER_PATH
            | xr::InputSourceLocalizedNameFlags::COMPONENT,
    };
    assert_eq!(
        unsafe {
            get_input_source_localized_name(session(), &info, 0, &mut count, std::ptr::null_mut())
        },
        xr::Result::SUCCESS
    );
    let mut name = vec![0i8; count as usize];
    assert_eq!(
        unsafe {
            get_input_source_localized_name(session(), &info, count, &mut count, name.as_mut_ptr())
        },
        xr::Result::SUCCESS
    );
    assert_eq!(
        unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
            .to_str()
            .unwrap(),
        "Left hand / Primary button"
    );
    f._host.set_dashboard(true);
    let inactive = boolean(input, left);
    assert_eq!(inactive.is_active, xr::FALSE);
    assert_eq!(inactive.changed_since_last_sync, xr::FALSE);
    assert_eq!(inactive.last_change_time.as_nanos(), 0);
}
#[test]
fn haptics_route_both_bound_hands_without_sync_and_cancel_on_focus_and_session_destroy() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let left = path("/user/hand/left");
    let right = path("/user/hand/right");
    let output = action(set, xr::ActionType::VIBRATION_OUTPUT, &[left, right]);
    let wrong = action(set, xr::ActionType::BOOLEAN_INPUT, &[left]);
    assert_eq!(
        bind(&[
            (output, "/user/hand/left/output/haptic"),
            (output, "/user/hand/right/output/haptic")
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    let mut info = xr::HapticActionInfo {
        ty: xr::HapticActionInfo::TYPE,
        next: std::ptr::null(),
        action: output,
        subaction_path: xr::Path::NULL,
    };
    let mut vibration = xr::HapticVibration {
        ty: xr::HapticVibration::TYPE,
        next: std::ptr::null(),
        duration: xr::Duration::MIN_HAPTIC,
        frequency: 0.0,
        amplitude: 0.7,
    };
    let apply = |info: &xr::HapticActionInfo, vibration: &xr::HapticVibration| unsafe {
        apply_haptic_feedback(
            session(),
            info,
            (vibration as *const xr::HapticVibration).cast(),
        )
    };
    assert_eq!(apply(&info, &vibration), xr::Result::SUCCESS);
    let ext = unsafe { bridge::haptics::extension(f._host.base().cast()) };
    for hand in 0..2 {
        let r = ext.read(hand).unwrap();
        assert_eq!(r.duration_ns, 10_000_000);
        assert_eq!(r.amplitude, 0.7);
        assert_ne!(r.epoch, 0);
    }
    info.subaction_path = left;
    vibration.duration = xr::Duration::INFINITE;
    assert_eq!(apply(&info, &vibration), xr::Result::SUCCESS);
    assert_eq!(ext.read(0).unwrap().duration_ns, i64::MAX as u64);
    info.action = wrong;
    assert_eq!(
        apply(&info, &vibration),
        xr::Result::ERROR_ACTION_TYPE_MISMATCH
    );
    info.action = output;
    vibration.amplitude = f32::NAN;
    assert_eq!(
        apply(&info, &vibration),
        xr::Result::ERROR_VALIDATION_FAILURE
    );
    vibration.amplitude = 0.7;
    f._host.set_dashboard(true);
    events();
    for hand in 0..2 {
        assert_eq!(ext.read(hand).unwrap().amplitude, 0.0);
    }
    assert_eq!(apply(&info, &vibration), xr::Result::SESSION_NOT_FOCUSED);
    f._host.set_dashboard(false);
    events();
    info.subaction_path = left;
    assert_eq!(apply(&info, &vibration), xr::Result::SUCCESS);
    info.subaction_path = right;
    assert_eq!(apply(&info, &vibration), xr::Result::SUCCESS);
    assert_eq!(
        unsafe { stop_haptic_feedback(session(), &info) },
        xr::Result::SUCCESS
    );
    assert_eq!(ext.read(1).unwrap().amplitude, 0.0);
    assert_eq!(ext.read(0).unwrap().duration_ns, i64::MAX as u64,
        "stopping the right subaction must preserve this action's active left-hand vibration");
    assert_eq!(ext.read(0).unwrap().amplitude, 0.7);
    assert_eq!(apply(&info, &vibration), xr::Result::SUCCESS);
    assert_eq!(unsafe { destroy_action(output) }, xr::Result::SUCCESS);
    assert_eq!(
        ext.read(1).unwrap().amplitude,
        0.7,
        "destroying a public handle preserves its session-owned output request"
    );
    assert_eq!(apply(&info, &vibration), xr::Result::ERROR_HANDLE_INVALID);
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    assert_eq!(
        ext.client_epoch.load(std::sync::atomic::Ordering::SeqCst),
        0
    );
}
#[test]
fn explicit_recenter_emits_reference_changes_once_and_discards_old_frame() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    with(|r| r.session.as_mut().unwrap().waited = true);
    assert_eq!(
        unsafe { begin_frame(session(), std::ptr::null()) },
        xr::Result::SUCCESS
    );
    f.state(|s| s.head.position = [1.0, 1.7, -2.0]);
    let ext = unsafe { bridge::haptics::extension(f._host.base().cast()) };
    ext.space_epoch
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(
        events(),
        vec![
            Seen::Reference(xr::ReferenceSpaceType::LOCAL, false),
            Seen::Reference(xr::ReferenceSpaceType::STAGE, false)
        ]
    );
    assert!(events().is_empty());
    let end = xr::FrameEndInfo {
        ty: xr::FrameEndInfo::TYPE,
        next: std::ptr::null(),
        display_time: xr::Time::from_nanos(1234),
        environment_blend_mode: xr::EnvironmentBlendMode::OPAQUE,
        layer_count: 0,
        layers: std::ptr::null(),
    };
    assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    assert!(with(|r| r.session.as_ref().unwrap().local.is_none()));
    let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { wait_frame(session(), std::ptr::null(), &mut frame) },
        xr::Result::SUCCESS
    );
    assert!(with(|r| r
        .session
        .as_ref()
        .unwrap()
        .local
        .unwrap()
        .position
        .x
        == 1.0));
    f.state(|s| s.head.position = [3.0, 1.7, 0.0]);
    assert!(events().is_empty());
    assert!(
        with(|r| r.session.as_ref().unwrap().local.unwrap().position.x == 1.0),
        "ordinary motion never recenters local"
    );
}

#[test]
fn velocity_uses_offset_lever_arm_and_known_relative_spaces_survive_tracking_loss() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let left = path("/user/hand/left");
    let pose_action = action(set, xr::ActionType::POSE_INPUT, &[left]);
    assert_eq!(
        bind(&[(pose_action, "/user/hand/left/input/grip/pose")]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    f.state(|s| {
        s.controllers[0].pose.velocity = [0.0; 3];
        s.controllers[0].pose.angular_velocity = [0.0, 0.0, 2.0];
    });
    let mut offset = IDENTITY;
    offset.position.x = 0.1;
    let source = space(pose_action, left, offset).unwrap();
    let origin = space(pose_action, left, IDENTITY).unwrap();
    let mut velocity: xr::SpaceVelocity = unsafe { std::mem::zeroed() };
    velocity.ty = xr::SpaceVelocity::TYPE;
    let mut output = xr::SpaceLocation {
        ty: xr::SpaceLocation::TYPE,
        next: (&mut velocity as *mut xr::SpaceVelocity).cast(),
        location_flags: xr::SpaceLocationFlags::EMPTY,
        pose: IDENTITY,
    };
    assert_eq!(
        unsafe {
            locate_space(
                source,
                xr::Space::from_raw(0x300),
                xr::Time::from_nanos(1),
                &mut output,
            )
        },
        xr::Result::SUCCESS
    );
    assert!(
        velocity
            .velocity_flags
            .contains(xr::SpaceVelocityFlags::LINEAR_VALID)
    );
    assert!((velocity.linear_velocity.y - 0.2).abs() < 1e-6);
    assert_eq!(velocity.angular_velocity.z, 2.0);
    f.state(|s| {
        s.controllers[0].pose.valid = 0;
        s.head.valid = 0;
    });
    assert_eq!(
        unsafe { locate_space(source, origin, xr::Time::from_nanos(2), &mut output) },
        xr::Result::SUCCESS
    );
    assert!(
        output
            .location_flags
            .contains(xr::SpaceLocationFlags::POSITION_VALID)
    );
    assert!(output.location_flags.contains(xr::SpaceLocationFlags::POSITION_TRACKED),
        "the exact common-entity relative transform is tracked despite missing absolute tracking");
    assert!(
        !output
            .location_flags
            .contains(xr::SpaceLocationFlags::ORIENTATION_TRACKED)
    );
    assert_eq!(velocity.linear_velocity.x, 0.0);
    assert_eq!(velocity.linear_velocity.y, 0.0);
    assert_eq!(velocity.angular_velocity.z, 0.0);
    assert!((output.pose.position.x - 0.1).abs() < 1e-6);
}

#[test]
fn stalled_host_is_detected_without_tracking_confidence_heuristics() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    f.state(|state| {
        state.head.valid = 0;
        state.controllers[0].pose.valid = 0;
    });
    assert!(
        events().is_empty(),
        "tracking loss does not imply host loss"
    );
    with(|r| {
        let s = r.session.as_mut().unwrap();
        s.last_host_tick = s.side.host_tick();
        s.last_host_progress = Instant::now() - Duration::from_secs(3);
    });
    assert!(events().contains(&Seen::State(xr::SessionState::STOPPING)));
    f.state(|state| state.head.valid = 1);
    assert!(
        events().is_empty(),
        "new ticks do not revive a stopping session"
    );
}

#[test]
fn heartbeat_keeps_loading_client_alive_and_joins_before_release() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let before = f._host.client().heartbeat;
    let worker = Heartbeat::start(&f.path).unwrap();
    let start = Instant::now();
    while f._host.client().heartbeat == before && start.elapsed() < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(f._host.client().heartbeat > before);
    drop(worker);
    let stopped = f._host.client().heartbeat;
    std::thread::sleep(Duration::from_millis(230));
    assert_eq!(f._host.client().heartbeat, stopped);
}

#[test]
fn controller_frames_public_actions_keep_grip_aim_offsets_motion_and_historical_tags_together() {
    use bridge::controller_frames::FrameKind;
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let hands = [path("/user/hand/left"),path("/user/hand/right")];
    let grip = action(set,xr::ActionType::POSE_INPUT,&hands);
    let aim = action(set,xr::ActionType::POSE_INPUT,&hands);
    assert_eq!(bind(&[(grip,"/user/hand/left/input/grip/pose"),
        (grip,"/user/hand/right/input/grip/pose"),(aim,"/user/hand/left/input/aim/pose"),
        (aim,"/user/hand/right/input/aim/pose")]),xr::Result::SUCCESS);
    attach(set); events();
    f.state(|s| for c in &mut s.controllers {
        c.pose.velocity=[0.3,0.4,0.5]; c.pose.angular_velocity=[0.,2.,0.];
    });
    let state = with(|r| r.session.as_ref().unwrap().newest.unwrap());
    f._host.publish_frame_with_controller_frames(&state,false,63,[FrameKind::SenseAim;2]);
    assert_eq!(sync(&[(set,xr::Path::NULL)]),xr::Result::SUCCESS);
    let grips=hands.map(|h|space(grip,h,IDENTITY).unwrap());
    let aims=hands.map(|h|space(aim,h,IDENTITY).unwrap());
    let offset=xr::Posef{position:vector([0.,0.,-0.1]),..IDENTITY};
    let offsets=hands.map(|h|space(grip,h,offset).unwrap());
    let mut frame:xr::FrameState=unsafe{std::mem::zeroed()};
    assert_eq!(unsafe{wait_frame(session(),std::ptr::null(),&mut frame)},xr::Result::SUCCESS);
    let time=frame.predicted_display_time.as_nanos();
    let grip_rotation=xr::Quaternionf{x:0.5,y:0.,z:0.,w:0.8660254};
    let stage=xr::Space::from_raw(0x300);
    for hand in 0..2 {
        let source=from_bridge(&state.controllers[hand].pose);
        let expected=xr::Posef{orientation:grip_rotation,..source};
        near(locate_at(grips[hand],time).pose,expected);
        near(locate_at(aims[hand],time).pose,source);
        near(locate_at(offsets[hand],time).pose,compose(expected,offset));
        let mut velocity:xr::SpaceVelocity=unsafe{std::mem::zeroed()};
        velocity.ty=xr::SpaceVelocity::TYPE;
        let mut out=xr::SpaceLocation{ty:xr::SpaceLocation::TYPE,
            next:(&mut velocity as *mut xr::SpaceVelocity).cast(),
            location_flags:xr::SpaceLocationFlags::EMPTY,pose:IDENTITY};
        assert_eq!(unsafe{locate_space(grips[hand],aims[hand],xr::Time::from_nanos(time),&mut out)},xr::Result::SUCCESS);
        near(out.pose,xr::Posef{orientation:grip_rotation,..IDENTITY});
        assert!(near_vector(velocity.linear_velocity,[0.;3]));
        assert!(near_vector(velocity.angular_velocity,[0.;3]));
        assert_eq!(unsafe{locate_space(offsets[hand],stage,xr::Time::from_nanos(time),&mut out)},xr::Result::SUCCESS);
        assert!(near_vector(velocity.linear_velocity,[0.2,0.4,0.5]));
        assert!(near_vector(velocity.angular_velocity,[0.,2.,0.]));
    }
    // An old API/mouse publication resets tags for new samples. Cached old
    // display-time samples must retain their own type, pose and velocity.
    f._host.publish_frame_with_motion(&state,false,63);
    for hand in 0..2 {
        near(locate_at(grips[hand],time+1).pose,from_bridge(&state.controllers[hand].pose));
        assert!((locate_at(grips[hand],time).pose.orientation.x-0.5).abs()<1e-6);
    }
}

fn near_vector(actual:xr::Vector3f,expected:[f32;3])->bool {
    [actual.x,actual.y,actual.z].into_iter().zip(expected).all(|(a,b)|(a-b).abs()<1e-6)
}

#[test]
fn same_display_time_keeps_head_both_hands_and_velocity_in_one_snapshot() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let hands = [path("/user/hand/left"), path("/user/hand/right")];
    let action = action(set, xr::ActionType::POSE_INPUT, &hands);
    assert_eq!(
        bind(&[
            (action, "/user/hand/left/input/grip/pose"),
            (action, "/user/hand/right/input/grip/pose")
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    let spaces = hands.map(|hand| space(action, hand, IDENTITY).unwrap());
    let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
    assert_eq!(
        unsafe { wait_frame(session(), std::ptr::null(), &mut frame) },
        xr::Result::SUCCESS
    );
    let time = frame.predicted_display_time.as_nanos();
    let stage = xr::Space::from_raw(0x300);
    let (initial_views, _) = views_at(time, stage);
    let initial_left = locate_at(spaces[0], time);
    let initial_right = locate_at(spaces[1], time);
    f.state(|s| {
        s.head.position = [2.0, 1.8, -0.5];
        s.controllers[0].pose.position = [-0.6, 1.3, -0.8];
        s.controllers[1].pose.position = [0.8, 1.4, -0.9];
        s.controllers[0].pose.velocity = [3.0, 0.0, 0.0];
        s.controllers[1].pose.velocity = [4.0, 0.0, 0.0];
    });
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    near(locate_at(spaces[0], time).pose, initial_left.pose);
    near(locate_at(spaces[1], time).pose, initial_right.pose);
    let (repeated_views, _) = views_at(time, stage);
    for eye in 0..2 {
        near(repeated_views[eye].pose, initial_views[eye].pose);
    }
    let mut velocity: xr::SpaceVelocity = unsafe { std::mem::zeroed() };
    velocity.ty = xr::SpaceVelocity::TYPE;
    let mut out: xr::SpaceLocation = unsafe { std::mem::zeroed() };
    out.next = (&mut velocity as *mut xr::SpaceVelocity).cast();
    assert_eq!(
        unsafe { locate_space(spaces[0], stage, xr::Time::from_nanos(time), &mut out) },
        xr::Result::SUCCESS
    );
    assert_eq!(
        velocity.linear_velocity.x, 0.0,
        "velocity is from the same old sample as the pose"
    );
    let (new_views, _) = views_at(time + 1, stage);
    assert!((new_views[0].pose.position.x + new_views[1].pose.position.x - 4.0).abs() < 1e-6);
    assert_eq!(locate_at(spaces[0], time + 1).pose.position.x, -0.6);
    assert_eq!(locate_at(spaces[1], time + 1).pose.position.x, 0.8);
    assert_eq!(
        unsafe { locate_space(spaces[0], stage, xr::Time::from_nanos(time + 1), &mut out) },
        xr::Result::SUCCESS
    );
    assert_eq!(velocity.linear_velocity.x, 3.0);
    f.state(|s| {
        s.head.valid = 0;
        s.controllers[0].pose.valid = 0;
        s.controllers[1].pose.valid = 0;
    });
    assert!(locate_at(spaces[0], time + 2).location_flags.is_empty());
    assert!(views_at(time + 2, stage).1.is_empty());
    assert!(
        locate_at(spaces[0], time)
            .location_flags
            .contains(xr::SpaceLocationFlags::POSITION_TRACKED),
        "known historical tracking remains attached to its original time"
    );
    let header = f._host.base().cast::<bridge::Header>();
    unsafe {
        (*header)
            .halliday_alive
            .store(0, std::sync::atomic::Ordering::SeqCst);
    }
    assert!(
        locate_at(spaces[0], time).location_flags.is_empty(),
        "a stopped host cannot revive tracking from history"
    );
}

#[test]
fn pose_history_obeys_reference_change_time_and_stays_bounded() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let mut view = xr::Space::NULL;
    let mut local = xr::Space::NULL;
    assert_eq!(
        new_space(session(), SpaceKind::View, IDENTITY, &mut view),
        xr::Result::SUCCESS
    );
    assert_eq!(
        new_space(session(), SpaceKind::Local, IDENTITY, &mut local),
        xr::Result::SUCCESS
    );
    let old_time = halliday_core::time::host_time_ns() - 1;
    let future_time = old_time + 1_000_000_000;
    let (_, old_flags) = views_at(old_time, local);
    let (future_before, _) = views_at(future_time, local);
    assert!(old_flags.contains(xr::ViewStateFlags::POSITION_TRACKED));
    f.state(|s| s.head.position = [2.0, 1.8, -0.5]);
    let ext = unsafe { bridge::haptics::extension(f._host.base().cast()) };
    ext.space_epoch
        .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    assert_eq!(events().len(), 2);
    let (old_after, old_flags) = views_at(old_time, local);
    assert!((old_after[0].pose.position.y - 1.6).abs() < 1e-6);
    assert!(old_flags.contains(xr::ViewStateFlags::POSITION_TRACKED));
    let (future_after, _) = views_at(future_time, local);
    assert!(
        (future_before[0].pose.position.y - future_after[0].pose.position.y).abs() > 1.0,
        "a cached future sample in old coordinates is invalidated by recenter"
    );
    assert!((future_after[0].pose.position.y).abs() < 1e-6);
    assert!(
        views_at(old_time - 1, local).1.is_empty(),
        "unknown pre-change coordinates are not reconstructed from new poses"
    );
    for n in 0..POSE_SAMPLES + 10 {
        views_at(future_time + 1 + n as i64, xr::Space::from_raw(0x300));
    }
    assert_eq!(
        with(|r| r.session.as_ref().unwrap().pose_samples.len()),
        POSE_SAMPLES
    );
    assert!(
        views_at(old_time, xr::Space::from_raw(0x300)).1.is_empty(),
        "evicted historical time cannot receive a current valid pose"
    );
    for n in 0..POSE_SAMPLES + 3 {
        views_at(old_time - n as i64, local);
    }
    assert_eq!(
        with(|r| r.session.as_ref().unwrap().pose_samples.len()),
        POSE_SAMPLES,
        "unknown historical queries do not evict useful recent snapshots"
    );
}

#[test]
fn invalid_quad_layers_fail_before_any_gpu_read_or_publication() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    with(|r| {
        r.session.as_mut().unwrap().swapchains.insert(
            0x800,
            Swapchain {
                width: 3000,
                height: 3000,
                layers: 1,
                vulkan: false,
                bgra: false,
                transfer: bridge::FRAME_COLOR_SRGB,
                textures: vec![std::ptr::null_mut()],
                next: 0,
                acquired: Default::default(),
                waited: false,
                static_image: false,
                static_acquired: false,
                released: Some(0),
            },
        );
    });
    let mut quad: xr::CompositionLayerQuad = unsafe { std::mem::zeroed() };
    quad.ty = xr::CompositionLayerQuad::TYPE;
    quad.space = xr::Space::from_raw(0x300);
    quad.pose = IDENTITY;
    quad.size = xr::Extent2Df {
        width: 1.0,
        height: 1.0,
    };
    quad.eye_visibility = xr::EyeVisibility::BOTH;
    quad.sub_image.swapchain = xr::Swapchain::from_raw(0x800);
    quad.sub_image.image_rect.extent = xr::Extent2Di {
        width: 8,
        height: 8,
    };
    let submit = |layers: &[*const xr::CompositionLayerBaseHeader], expected| {
        with(|r| r.session.as_mut().unwrap().begun = true);
        let info = xr::FrameEndInfo {
            ty: xr::FrameEndInfo::TYPE,
            next: std::ptr::null(),
            display_time: xr::Time::from_nanos(1234),
            environment_blend_mode: xr::EnvironmentBlendMode::OPAQUE,
            layer_count: layers.len() as u32,
            layers: layers.as_ptr(),
        };
        assert_eq!(unsafe { end_frame(session(), &info) }, expected);
        assert_eq!(
            f._host.client().frames,
            0,
            "bad metadata never publishes a picture"
        );
    };
    let invalid = |changed: xr::CompositionLayerQuad, expected| {
        submit(
            &[(&changed as *const xr::CompositionLayerQuad).cast()],
            expected,
        );
    };
    let mut bad = quad;
    bad.size.width = 0.0;
    invalid(bad, xr::Result::ERROR_LAYER_INVALID);
    bad = quad;
    bad.pose.orientation.w = 0.0;
    invalid(bad, xr::Result::ERROR_POSE_INVALID);
    bad = quad;
    bad.eye_visibility = xr::EyeVisibility::from_raw(99);
    invalid(bad, xr::Result::ERROR_LAYER_INVALID);
    bad = quad;
    bad.sub_image.image_rect.offset.x = -1;
    invalid(bad, xr::Result::ERROR_SWAPCHAIN_RECT_INVALID);
    bad = quad;
    bad.sub_image.image_rect.extent.width = i32::MAX;
    invalid(bad, xr::Result::ERROR_SWAPCHAIN_RECT_INVALID);
    bad = quad;
    bad.sub_image.swapchain = xr::Swapchain::NULL;
    invalid(bad, xr::Result::ERROR_HANDLE_INVALID);
    bad = quad;
    bad.sub_image.image_rect.extent = xr::Extent2Di {
        width: 2050,
        height: 2050,
    };
    invalid(bad, xr::Result::ERROR_LIMIT_REACHED);
    bad = quad;
    bad.next = (&quad as *const xr::CompositionLayerQuad).cast();
    invalid(bad, xr::Result::ERROR_LAYER_INVALID);
    bad = quad;
    bad.layer_flags = xr::CompositionLayerFlags::from_raw(1 << 63);
    invalid(bad, xr::Result::ERROR_LAYER_INVALID);
    submit(
        &[std::ptr::null(); 10],
        xr::Result::ERROR_LAYER_LIMIT_EXCEEDED,
    );
    let mut projection: xr::CompositionLayerProjection = unsafe { std::mem::zeroed() };
    projection.ty = xr::CompositionLayerProjection::TYPE;
    projection.space = quad.space;
    projection.view_count = 2;
    let views: [xr::CompositionLayerProjectionView; 2] = unsafe { std::mem::zeroed() };
    projection.views = views.as_ptr();
    let pointer = (&projection as *const xr::CompositionLayerProjection).cast();
    submit(&[pointer, pointer], xr::Result::ERROR_LAYER_LIMIT_EXCEEDED);
    unsafe {
        // A legacy v6 host has no optional panel extension. Reject explicitly
        // instead of silently dropping every advertised quad forever.
        f._host
            .base()
            .add(bridge::panels::OFFSET)
            .cast::<u32>()
            .write(0);
    }
    invalid(quad, xr::Result::ERROR_FEATURE_UNSUPPORTED);
}

#[path = "native_swapchain_tests.rs"]
mod swapchain_lifecycle;

#[test]
fn native_action_priority_captures_only_competing_source_and_selected_hand() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let hands = [path("/user/hand/left"), path("/user/hand/right")];
    let low = set_with_priority(0);
    let high = set_with_priority(10);
    let equal = set_with_priority(10);
    let lower_trigger = action(low, xr::ActionType::BOOLEAN_INPUT, &hands);
    let lower_squeeze = action(low, xr::ActionType::BOOLEAN_INPUT, &hands);
    let lower_pose = action(low, xr::ActionType::POSE_INPUT, &hands);
    let higher_trigger = action(high, xr::ActionType::BOOLEAN_INPUT, &hands);
    let higher_pose = action(high, xr::ActionType::POSE_INPUT, &hands);
    let equal_trigger = action(equal, xr::ActionType::BOOLEAN_INPUT, &hands);
    assert_eq!(
        bind(&[
            (lower_trigger, "/user/hand/left/input/trigger/value"),
            (lower_trigger, "/user/hand/right/input/trigger/value"),
            (lower_squeeze, "/user/hand/left/input/squeeze/value"),
            (lower_pose, "/user/hand/left/input/grip/pose"),
            (lower_pose, "/user/hand/right/input/grip/pose"),
            (higher_trigger, "/user/hand/left/input/trigger/touch"),
            (higher_pose, "/user/hand/left/input/grip/pose"),
            (equal_trigger, "/user/hand/left/input/trigger/click"),
        ]),
        xr::Result::SUCCESS
    );
    let sets = [low, high, equal];
    let attach_info = xr::SessionActionSetsAttachInfo {
        ty: xr::SessionActionSetsAttachInfo::TYPE,
        next: std::ptr::null(),
        count_action_sets: sets.len() as u32,
        action_sets: sets.as_ptr(),
    };
    assert_eq!(
        unsafe { attach_session_action_sets(session(), &attach_info) },
        xr::Result::SUCCESS
    );
    events();
    f.state(|s| {
        for c in &mut s.controllers {
            c.pressed = BIT_TRIGGER | BIT_GRIP;
            c.touched = BIT_TRIGGER;
        }
    });
    let lower_left_space = space(lower_pose, hands[0], IDENTITY).unwrap();
    let retained_higher_space = space(higher_pose, hands[0], IDENTITY).unwrap();
    assert_eq!(
        sync(&[(low, xr::Path::NULL), (high, hands[0])]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        boolean(lower_trigger, hands[0]).is_active,
        xr::FALSE,
        "higher-priority touch component captures the lower trigger source"
    );
    assert_eq!(
        boolean(lower_trigger, hands[1]).is_active,
        xr::TRUE,
        "left-hand capture cannot suppress the right hand"
    );
    assert_eq!(
        boolean(lower_squeeze, hands[0]).is_active,
        xr::TRUE,
        "capture affects only the competing source, not the controller"
    );
    assert_eq!(pose(lower_pose, hands[0]), Ok(false));
    assert!(locate(lower_left_space).location_flags.is_empty());
    assert_eq!(pose(lower_pose, hands[1]), Ok(true));
    assert_eq!(unsafe { destroy_action(higher_pose) }, xr::Result::SUCCESS);
    assert_eq!(
        pose(higher_pose, hands[0]),
        Err(xr::Result::ERROR_HANDLE_INVALID)
    );
    assert_eq!(
        space(higher_pose, hands[0], IDENTITY),
        Err(xr::Result::ERROR_HANDLE_INVALID)
    );
    assert_eq!(
        unsafe { destroy_action(higher_pose) },
        xr::Result::ERROR_HANDLE_INVALID
    );
    assert_eq!(
        sync(&[(low, xr::Path::NULL), (high, hands[0]), (equal, hands[0])]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        pose(lower_pose, hands[0]),
        Ok(false),
        "destroyed public action still participates in its attached set's physical-source priority"
    );
    f.state(|s| s.controllers[0].pose.position[0] -= 0.1);
    assert!(
        (locate(retained_higher_space).pose.position.x + 0.4).abs() < 1e-6,
        "the existing action space keeps locating fresh motion after handle destruction"
    );
    assert_eq!(boolean(higher_trigger, hands[0]).is_active, xr::TRUE);
    assert_eq!(
        boolean(equal_trigger, hands[0]).is_active,
        xr::TRUE,
        "equal-priority bindings remain active together"
    );
    assert_eq!(
        sync(&[(low, xr::Path::NULL), (high, hands[1])]),
        xr::Result::SUCCESS
    );
    assert_eq!(
        boolean(lower_trigger, hands[0]).is_active,
        xr::TRUE,
        "an active high-priority set with no binding on the selected hand cannot capture left input"
    );
    assert_eq!(pose(lower_pose, hands[0]), Ok(true));
    assert_eq!(sync(&[(low, xr::Path::NULL)]), xr::Result::SUCCESS);
    assert_eq!(
        boolean(lower_trigger, hands[0]).current_state,
        xr::TRUE,
        "deactivating the capturing set restores the unchanged held input"
    );
    assert_eq!(boolean(higher_trigger, hands[0]).is_active, xr::FALSE);
    assert!(with(|r| r.actions.contains_key(&higher_pose.into_raw())));
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    assert!(
        with(|r| r.actions.contains_key(&higher_pose.into_raw())),
        "destroyed public action resources remain available to their instance across session reuse"
    );
}

#[test]
fn native_sync_rejects_undeclared_subaction_without_changing_synced_input() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let left = path("/user/hand/left");
    let right = path("/user/hand/right");
    let trigger = action(set, xr::ActionType::BOOLEAN_INPUT, &[left]);
    assert_eq!(
        bind(&[(trigger, "/user/hand/left/input/trigger/click")]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    f.state(|s| s.controllers[0].pressed = BIT_TRIGGER);
    assert_eq!(sync(&[(set, left)]), xr::Result::SUCCESS);
    assert_eq!(sync(&[(set, right)]), xr::Result::ERROR_PATH_UNSUPPORTED);
    assert_eq!(
        boolean(trigger, left).is_active,
        xr::TRUE,
        "failed sync leaves the prior coherent input state intact"
    );
    assert_eq!(boolean(trigger, left).current_state, xr::TRUE);
}

#[test]
fn native_moving_view_and_both_hand_offsets_preserve_rigid_motion_and_confidence() {
    let _lock = crate::TEST_RUNTIME_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let set = set();
    let hands = [path("/user/hand/left"), path("/user/hand/right")];
    let action = action(set, xr::ActionType::POSE_INPUT, &hands);
    assert_eq!(
        bind(&[
            (action, "/user/hand/left/input/grip/pose"),
            (action, "/user/hand/right/input/grip/pose")
        ]),
        xr::Result::SUCCESS
    );
    attach(set);
    events();
    assert_eq!(sync(&[(set, xr::Path::NULL)]), xr::Result::SUCCESS);
    f.state(|s| {
        s.head.position = [2.0, 1.8, -3.0];
        s.head.orientation = [0.0, 0.5f32.sqrt(), 0.0, 0.5f32.sqrt()];
        s.head.velocity = [1.0, 2.0, 3.0];
        s.head.angular_velocity = [0.0, 2.0, 0.0];
        for (hand, c) in s.controllers.iter_mut().enumerate() {
            let x = if hand == 0 { -0.2 } else { 0.2 };
            c.pose.position = [2.0 + x, 1.5, -3.4];
            c.pose.orientation = [(0.3f32).sin(), 0.0, 0.0, (0.3f32).cos()];
            c.pose.velocity = [0.2, 2.0, 3.0 - 2.0 * x];
            c.pose.angular_velocity = [0.0, 2.0, 0.0];
        }
    });
    let base_offset = xr::Posef {
        orientation: xr::Quaternionf {
            x: (0.35f32).sin(),
            y: 0.0,
            z: 0.0,
            w: (0.35f32).cos(),
        },
        position: vector([0.05, 0.03, -0.04]),
    };
    let target_offset = xr::Posef {
        orientation: xr::Quaternionf {
            x: 0.0,
            y: 0.0,
            z: (0.2f32).sin(),
            w: (0.2f32).cos(),
        },
        position: vector([0.1, -0.02, 0.06]),
    };
    let mut view = xr::Space::NULL;
    assert_eq!(
        new_space(session(), SpaceKind::View, base_offset, &mut view),
        xr::Result::SUCCESS
    );
    let targets = hands.map(|hand| space(action, hand, target_offset).unwrap());
    for (hand, target) in targets.into_iter().enumerate() {
        let mut velocity = xr::SpaceVelocity {
            ty: xr::SpaceVelocity::TYPE,
            ..unsafe { std::mem::zeroed() }
        };
        let mut out = xr::SpaceLocation {
            ty: xr::SpaceLocation::TYPE,
            next: (&mut velocity as *mut xr::SpaceVelocity).cast(),
            location_flags: xr::SpaceLocationFlags::EMPTY,
            pose: IDENTITY,
        };
        assert_eq!(
            unsafe { locate_space(target, view, xr::Time::from_nanos(10), &mut out) },
            xr::Result::SUCCESS
        );
        assert!(
            out.location_flags
                .contains(xr::SpaceLocationFlags::POSITION_TRACKED)
        );
        assert_eq!(
            velocity.velocity_flags,
            xr::SpaceVelocityFlags::LINEAR_VALID | xr::SpaceVelocityFlags::ANGULAR_VALID
        );
        for v in [
            velocity.linear_velocity.x,
            velocity.linear_velocity.y,
            velocity.linear_velocity.z,
            velocity.angular_velocity.x,
            velocity.angular_velocity.y,
            velocity.angular_velocity.z,
        ] {
            assert!(
                v.abs() < 1e-5,
                "common rigid motion with distinct offset origins has zero relative velocity, hand {hand}: {v}"
            );
        }
        let expected = with(|r| {
            let state = r.session.as_ref().unwrap().newest.unwrap();
            compose(
                inverse(compose(from_bridge(&state.head), base_offset)),
                compose(from_bridge(&state.controllers[hand].pose), target_offset),
            )
        });
        near(out.pose, expected);
    }
    f.state(|s| s.head.valid = 0);
    for target in targets {
        assert!(
            locate_at(target, 11)
                .location_flags
                .contains(xr::SpaceLocationFlags::POSITION_TRACKED)
        );
        let mut out = xr::SpaceLocation {
            ty: xr::SpaceLocation::TYPE,
            next: std::ptr::null_mut(),
            location_flags: xr::SpaceLocationFlags::EMPTY,
            pose: IDENTITY,
        };
        assert_eq!(
            unsafe { locate_space(target, view, xr::Time::from_nanos(11), &mut out) },
            xr::Result::SUCCESS
        );
        assert!(
            out.location_flags.is_empty(),
            "moving VIEW needs head confidence even when STAGE hand tracking remains valid"
        );
    }
}

#[path = "native_input_audit_tests.rs"]
mod input_contract;

#[path = "native_profile_tests.rs"]
mod profile_contract;

#[path = "native_motion_tests.rs"]
mod motion_contract;

#[path = "native_lifecycle_audit_tests.rs"]
mod lifecycle_audit;

#[path = "native_projection_tests.rs"]
mod projection_contract;

#[path = "native_graphics_contract_tests.rs"]
mod graphics_contract;
