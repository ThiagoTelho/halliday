use super::*;

fn suggest(profile:&str,entries:&[(xr::Action,&str)]) -> xr::Result {
    let entries:Vec<_>=entries.iter().map(|&(action,binding)|xr::ActionSuggestedBinding{action,binding:path(binding)}).collect();
    let info=xr::InteractionProfileSuggestedBinding {ty:xr::InteractionProfileSuggestedBinding::TYPE,next:std::ptr::null(),interaction_profile:path(profile),count_suggested_bindings:entries.len() as u32,suggested_bindings:entries.as_ptr()};
    unsafe{suggest_interaction_profile_bindings(xr::Instance::NULL,&info)}
}
fn profile(hand:xr::Path) -> xr::Path {
    let mut state=xr::InteractionProfileState{ty:xr::InteractionProfileState::TYPE,next:std::ptr::null_mut(),interaction_profile:xr::Path::NULL};
    assert_eq!(unsafe{get_current_interaction_profile(session(),hand,&mut state)},xr::Result::SUCCESS);state.interaction_profile
}

#[test]
fn measured_trigger_pressure_is_not_promoted_to_one_by_the_click_bit() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());let f=Fixture::new();
    let set=set();let hands=[path("/user/hand/left"),path("/user/hand/right")];
    let pressure=action(set,xr::ActionType::FLOAT_INPUT,&hands);let button=action(set,xr::ActionType::BOOLEAN_INPUT,&hands);
    assert_eq!(bind(&[(pressure,"/user/hand/left/input/trigger/value"),(pressure,"/user/hand/right/input/trigger/value"),
        (button,"/user/hand/left/input/trigger/value"),(button,"/user/hand/right/input/trigger/value")]),xr::Result::SUCCESS);
    attach(set);events();
    for value in [0.,0.25,0.6,0.75,1.] {for clicks in 0..4 {
        f.state(|s|for hand in 0..2 {s.controllers[hand].axes[1][0]=value;s.controllers[hand].pressed=if clicks&(1<<hand)!=0 {BIT_TRIGGER}else{0};});
        assert_eq!(sync(&[(set,xr::Path::NULL)]),xr::Result::SUCCESS);
        for requested in [xr::Path::NULL,hands[0],hands[1]] {
            let info=xr::ActionStateGetInfo{ty:xr::ActionStateGetInfo::TYPE,next:std::ptr::null(),action:pressure,subaction_path:requested};
            let mut out:xr::ActionStateFloat=unsafe{std::mem::zeroed()};out.ty=xr::ActionStateFloat::TYPE;
            assert_eq!(unsafe{get_action_state_float(session(),&info,&mut out)},xr::Result::SUCCESS);
            assert_eq!(out.is_active,xr::TRUE);assert_eq!(out.current_state,value,"pressure={value} clicks={clicks} must remain analog");
        }
        for hand in 0..2 {assert_eq!(boolean(button,hands[hand]).current_state,xr::Bool32::from(value>0.5||clicks&(1<<hand)!=0),"Boolean policy unchanged");}
    }}
}

#[test]
fn each_hand_selects_a_profile_with_attached_bindings_without_discarding_the_other_profile() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());let f=Fixture::new();
    let set=set();let left=path("/user/hand/left");let right=path("/user/hand/right");
    let a=action(set,xr::ActionType::BOOLEAN_INPUT,&[left]);let b=action(set,xr::ActionType::BOOLEAN_INPUT,&[right]);
    let simple="/interaction_profiles/khr/simple_controller";let touch="/interaction_profiles/oculus/touch_controller";
    assert_eq!(suggest(touch,&[(a,"/user/hand/left/input/x/click"),(b,"/user/hand/right/input/a/click")]),xr::Result::SUCCESS);
    assert_eq!(suggest(simple,&[(a,"/user/hand/left/input/select/click")]),xr::Result::SUCCESS);
    // Replacing Touch must remove only its old left binding, retaining the
    // independently supplied Simple fallback rather than a stale Touch path.
    assert_eq!(suggest(touch,&[(b,"/user/hand/right/input/a/click")]),xr::Result::SUCCESS);
    let unused=super::set();let excluded=action(unused,xr::ActionType::BOOLEAN_INPUT,&[left]);
    assert_eq!(suggest("/interaction_profiles/valve/index_controller",&[(excluded,"/user/hand/left/input/trigger/value")]),xr::Result::SUCCESS);
    f.state(|s|{s.controllers[0].pressed=BIT_TRIGGER;s.controllers[1].pressed=BIT_A;});
    attach(set);events();assert_eq!(sync(&[(set,xr::Path::NULL)]),xr::Result::SUCCESS);
    assert_eq!(profile(left),path(simple));assert_eq!(profile(right),path(touch));
    assert_eq!(boolean(a,left).current_state,xr::TRUE);assert_eq!(boolean(b,right).current_state,xr::TRUE);
    assert_eq!(boolean(a,left).is_active,xr::TRUE);assert_eq!(boolean(b,right).is_active,xr::TRUE);
}

#[test]
fn a_new_simple_only_session_does_not_reuse_the_old_touch_sessions_bindings() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());let _first=Fixture::new();
    let left=path("/user/hand/left");let first=set();let old=action(first,xr::ActionType::BOOLEAN_INPUT,&[left]);
    assert_eq!(bind(&[(old,"/user/hand/left/input/x/click")]),xr::Result::SUCCESS);
    attach(first);events();assert_eq!(sync(&[(first,xr::Path::NULL)]),xr::Result::SUCCESS);
    assert_eq!(unsafe{destroy_session(session())},xr::Result::SUCCESS);
    let second=set();let new=action(second,xr::ActionType::BOOLEAN_INPUT,&[left]);
    assert_eq!(suggest("/interaction_profiles/khr/simple_controller",&[(new,"/user/hand/left/input/select/click")]),xr::Result::SUCCESS);
    let f=Fixture::new_preserving_actions(true);f.state(|s|s.controllers[0].pressed=BIT_TRIGGER);
    attach(second);events();assert_eq!(sync(&[(second,xr::Path::NULL)]),xr::Result::SUCCESS);
    assert_eq!(profile(left),path("/interaction_profiles/khr/simple_controller"));
    assert_eq!(boolean(new,left).is_active,xr::TRUE);assert_eq!(boolean(new,left).current_state,xr::TRUE);
    instance_destroyed(1);
    assert!(with(|r|r.suggested_profiles.is_empty()&&r.bindings.is_empty()&&r.selected_profiles==[None;2]),
        "instance teardown retires the retained profile suggestions and their derived bindings");
}

#[test]
fn unsupported_suggestions_fail_without_erasing_the_previous_profile_bindings() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());let f=Fixture::new();
    let set=set();let left=path("/user/hand/left");let a=action(set,xr::ActionType::BOOLEAN_INPUT,&[left]);
    assert_eq!(bind(&[(a,"/user/hand/left/input/x/click")]),xr::Result::SUCCESS);
    assert_eq!(bind(&[(a,"/user/hand/left/input/not_a_real_input/click")]),xr::Result::ERROR_PATH_UNSUPPORTED);
    f.state(|s|s.controllers[0].pressed=BIT_A);attach(set);events();
    assert_eq!(sync(&[(set,xr::Path::NULL)]),xr::Result::SUCCESS);
    assert_eq!(boolean(a,left).is_active,xr::TRUE);assert_eq!(boolean(a,left).current_state,xr::TRUE);
}
