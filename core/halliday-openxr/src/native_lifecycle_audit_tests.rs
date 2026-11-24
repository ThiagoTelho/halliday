use super::*;

#[test]
fn rapid_dashboard_roundtrip_cancels_old_output_without_fabricating_focus_events() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let f=Fixture::new();let set=set();let left=path("/user/hand/left");
    let output=action(set,xr::ActionType::VIBRATION_OUTPUT,&[left]);
    assert_eq!(bind(&[(output,"/user/hand/left/output/haptic")]),xr::Result::SUCCESS);
    attach(set);events();
    let info=xr::HapticActionInfo {ty:xr::HapticActionInfo::TYPE,next:std::ptr::null(),action:output,subaction_path:left};
    let vibration=xr::HapticVibration {ty:xr::HapticVibration::TYPE,next:std::ptr::null(),duration:xr::Duration::from_nanos(200_000_000),frequency:0.0,amplitude:0.7};
    let play=||unsafe {apply_haptic_feedback(session(),&info,(&vibration as *const xr::HapticVibration).cast())};
    let ext=unsafe {bridge::haptics::extension(f._host.base().cast())};
    assert_eq!(play(),xr::Result::SUCCESS);assert_eq!(ext.read(0).unwrap().amplitude,0.7);
    f._host.set_dashboard(true);f._host.set_dashboard(false);
    assert!(events().is_empty(),"an unobserved round trip does not invent historical focus events");
    assert_eq!(ext.read(0).unwrap().amplitude,0.0);
    f._host.set_dashboard(true);f._host.set_dashboard(false);
    assert_eq!(play(),xr::Result::SUCCESS);
    let request=ext.read(0).unwrap();assert_eq!(request.amplitude,0.7);
    let focus=unsafe {bridge::focus::extension(f._host.base().cast())};
    assert_eq!(focus.matches(request.epoch,0,request.sequence,focus.generation()),Some(true));
}

#[test]
fn queued_session_events_keep_the_transition_timestamp_and_destroy_removes_them() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let _f=Fixture::new();events();
    with(|r|r.change(&[xr::SessionState::VISIBLE,xr::SessionState::FOCUSED]));
    let queued_before=halliday_core::time::host_time_ns();
    std::thread::sleep(Duration::from_millis(3));
    let mut previous=0;
    for state in [xr::SessionState::VISIBLE,xr::SessionState::FOCUSED] {
        let mut buffer:xr::EventDataBuffer=unsafe {std::mem::zeroed()};buffer.ty=xr::EventDataBuffer::TYPE;
        assert_eq!(unsafe {poll(1,&mut buffer)},xr::Result::SUCCESS);
        let event=unsafe {&*(&buffer as *const xr::EventDataBuffer).cast::<xr::EventDataSessionStateChanged>()};
        assert_eq!(event.state,state);let time=event.time.as_nanos();
        assert!(time>previous&&time<=queued_before,"state time describes when queued, not when polled later");previous=time;
    }
    with(|r|r.change(&[xr::SessionState::VISIBLE,xr::SessionState::FOCUSED]));
    assert_eq!(unsafe {destroy_session(session())},xr::Result::SUCCESS);
    assert!(with(|r|r.events.is_empty()),"destroyed session's queued events cannot leak into recreation");
}

#[test]
fn pipelined_frame_discard_and_wait_to_begin_recenter_preserve_frame_ownership() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let f=Fixture::new();let mut frame:xr::FrameState=unsafe {std::mem::zeroed()};
    assert_eq!(unsafe {wait_frame(session(),std::ptr::null(),&mut frame)},xr::Result::SUCCESS);
    assert_eq!(unsafe {begin_frame(session(),std::ptr::null())},xr::Result::SUCCESS);
    f.state(|s|s.head.position[0]+=0.1);
    assert_eq!(unsafe {wait_frame(session(),std::ptr::null(),&mut frame)},xr::Result::SUCCESS);
    assert_eq!(unsafe {begin_frame(session(),std::ptr::null())},xr::Result::FRAME_DISCARDED);
    assert_eq!(unsafe {begin_frame(session(),std::ptr::null())},xr::Result::ERROR_CALL_ORDER_INVALID);
    let mut end=xr::FrameEndInfo {ty:xr::FrameEndInfo::TYPE,next:std::ptr::null(),display_time:frame.predicted_display_time,environment_blend_mode:xr::EnvironmentBlendMode::OPAQUE,layer_count:0,layers:std::ptr::null()};
    assert_eq!(unsafe {end_frame(session(),&end)},xr::Result::SUCCESS);
    assert_eq!(unsafe {end_frame(session(),&end)},xr::Result::ERROR_CALL_ORDER_INVALID);
    f.state(|s|s.head.position[0]+=0.1);
    assert_eq!(unsafe {wait_frame(session(),std::ptr::null(),&mut frame)},xr::Result::SUCCESS);
    let before=f._host.client().frames;
    unsafe {bridge::haptics::extension(f._host.base().cast())}.space_epoch.fetch_add(1,std::sync::atomic::Ordering::SeqCst);
    assert_eq!(unsafe {begin_frame(session(),std::ptr::null())},xr::Result::SUCCESS);
    end.display_time=frame.predicted_display_time;
    assert_eq!(unsafe {end_frame(session(),&end)},xr::Result::SUCCESS);
    assert_eq!(f._host.client().frames,before,"recenter after Wait must retire the old frame even if Begin observes the new epoch");
}

#[test]
fn recoverable_end_error_keeps_the_next_pipelined_wait_and_allows_fresh_frames() {
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let mut first: xr::FrameState = unsafe { std::mem::zeroed() };
    first.ty = xr::FrameState::TYPE;
    assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut first) }, xr::Result::SUCCESS);
    assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
    f.state(|s| s.head.position[0] += 0.1);
    let mut second = first;
    assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut second) }, xr::Result::SUCCESS);
    assert!(second.predicted_display_time.as_nanos() > first.predicted_display_time.as_nanos());
    let frames = f._host.client().frames;
    let mut end = xr::FrameEndInfo {
        ty: xr::FrameEndInfo::TYPE, next: std::ptr::null(),
        display_time: xr::Time::from_nanos(0),
        environment_blend_mode: xr::EnvironmentBlendMode::OPAQUE,
        layer_count: 0, layers: std::ptr::null(),
    };
    assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::ERROR_TIME_INVALID);
    assert_eq!(f._host.client().frames, frames, "rejected frame never publishes");
    with(|r| {
        let s = r.session.as_ref().unwrap();
        assert!(s.waited && !s.begun, "retire only the rejected frame, retaining the next wait token");
        assert_eq!(s.display_time, second.predicted_display_time.as_nanos());
    });
    assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
    end.display_time = second.predicted_display_time;
    assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    f.state(|s| s.head.position[0] += 0.1);
    let mut third = second;
    assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut third) }, xr::Result::SUCCESS);
    assert!(third.predicted_display_time.as_nanos() > second.predicted_display_time.as_nanos());
    assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
    end.display_time = third.predicted_display_time;
    assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
}

#[test]
fn ready_session_host_quit_is_acknowledged_without_begin_and_cannot_reenter() {
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    with(|r| {
        let s = r.session.as_mut().unwrap();
        s.running = false;
        s.state = xr::SessionState::READY;
    });
    assert_eq!(unsafe { request_exit_session(session()) }, xr::Result::ERROR_SESSION_NOT_RUNNING);
    assert!(events().is_empty(), "requesting exit cannot fabricate a running session");
    f._host.request_quit();
    assert_eq!(events(), vec![Seen::State(xr::SessionState::IDLE), Seen::State(xr::SessionState::EXITING)]);
    assert_eq!(f._host.client().quit_acknowledged, 1);
    assert_eq!(f._host.client().frames, 0);
    let begin = xr::SessionBeginInfo {
        ty: xr::SessionBeginInfo::TYPE, next: std::ptr::null(),
        primary_view_configuration_type: xr::ViewConfigurationType::PRIMARY_STEREO,
    };
    assert_eq!(unsafe { begin_session(session(), &begin) }, xr::Result::ERROR_SESSION_NOT_READY);
    assert_eq!(unsafe { end_session(session()) }, xr::Result::ERROR_SESSION_NOT_RUNNING);
    assert!(events().is_empty(), "a loading session cannot restart or refocus after exit");
    assert_eq!(unsafe { destroy_session(session()) }, xr::Result::SUCCESS);
    assert!(!f._host.client().initialized);
}

#[test]
fn live_negotiated_game_period_updates_without_regressing_prediction_times() {
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let mut previous = 0;
    for period in [16_666_666, 8_333_333, 11_111_111] {
        f._host.set_frame_interval(period);
        f.state(|s| s.head.position[0] += 0.01);
        let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
        frame.ty = xr::FrameState::TYPE;
        assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut frame) }, xr::Result::SUCCESS);
        assert_eq!(frame.predicted_display_period.as_nanos(), period as i64,
            "report the negotiated game period, including a half-rate host, rather than stale create-time Hz");
        assert!(frame.predicted_display_time.as_nanos() > previous,
            "a faster cadence must never move the predicted display time backwards");
        previous = frame.predicted_display_time.as_nanos();
        assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
        let end = xr::FrameEndInfo {ty:xr::FrameEndInfo::TYPE, next:std::ptr::null(),
            display_time:frame.predicted_display_time, environment_blend_mode:xr::EnvironmentBlendMode::OPAQUE,
            layer_count:0, layers:std::ptr::null()};
        assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    }
}

#[test]
fn live_period_invalid_measurements_fall_back_and_explicit_hz_override_stays_fixed() {
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let sample = |expected: i64| {
        f.state(|s| s.head.position[0] += 0.01);
        let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
        frame.ty = xr::FrameState::TYPE;
        assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut frame) }, xr::Result::SUCCESS);
        assert_eq!(frame.predicted_display_period.as_nanos(), expected);
        assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
        let end = xr::FrameEndInfo {ty:xr::FrameEndInfo::TYPE, next:std::ptr::null(),
            display_time:frame.predicted_display_time, environment_blend_mode:xr::EnvironmentBlendMode::OPAQUE,
            layer_count:0, layers:std::ptr::null()};
        assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    };
    for invalid in [0, 3_999_999, 50_000_001, u64::MAX] {
        f._host.set_frame_interval(invalid);
        sample(8_333_333); // Fixture config is 120 Hz; bad measured values cannot replace it.
    }
    for valid in [4_000_000, 50_000_000] {
        f._host.set_frame_interval(valid);
        sample(valid as i64); // Inclusive bounds agree with the Windows peer.
    }
    with(|r| r.session.as_mut().unwrap().display_period_override = Some(22_222_222));
    for measured in [8_333_333, 16_666_666, 0] {
        f._host.set_frame_interval(measured);
        sample(22_222_222); // An explicit valid HALLIDAY_DISPLAY_HZ remains authoritative.
    }
}

#[test]
fn launcher_hz_hint_is_only_fallback_while_manual_hz_remains_forced() {
    let _lock = crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let f = Fixture::new();
    let configure = |initial| with(|r| {
        let s = r.session.as_mut().unwrap();
        s.display_period_override = apply_display_hz_hint(&mut s.config, Some("72"), initial);
        assert_eq!(s.config.display_hz, 72.0);
    });
    let sample = |period, expected| {
        f._host.set_frame_interval(period);
        f.state(|s| s.head.position[0] += 0.01);
        let mut frame: xr::FrameState = unsafe { std::mem::zeroed() };
        frame.ty = xr::FrameState::TYPE;
        assert_eq!(unsafe { wait_frame(session(), std::ptr::null(), &mut frame) }, xr::Result::SUCCESS);
        assert_eq!(frame.predicted_display_period.as_nanos(), expected);
        assert_eq!(unsafe { begin_frame(session(), std::ptr::null()) }, xr::Result::SUCCESS);
        let end = xr::FrameEndInfo {ty:xr::FrameEndInfo::TYPE, next:std::ptr::null(),
            display_time:frame.predicted_display_time, environment_blend_mode:xr::EnvironmentBlendMode::OPAQUE,
            layer_count:0, layers:std::ptr::null()};
        assert_eq!(unsafe { end_frame(session(), &end) }, xr::Result::SUCCESS);
    };
    configure(true); // Exactly the helper/initial marker branch used by CreateSession.
    sample(0, 13_888_888);
    sample(16_666_666, 16_666_666);
    sample(8_333_333, 8_333_333);
    configure(false); // Manually set HALLIDAY_DISPLAY_HZ with no initial marker.
    sample(16_666_666, 13_888_888);
    sample(8_333_333, 13_888_888);
    with(|r| {
        let s = r.session.as_mut().unwrap();
        for invalid in [None, Some("0"), Some("NaN"), Some("garbage"), Some("1000")] {
            assert!(apply_display_hz_hint(&mut s.config, invalid, true).is_none());
            assert_eq!(s.config.display_hz, 72.0, "invalid hints do not damage fallback config");
        }
    });
}
