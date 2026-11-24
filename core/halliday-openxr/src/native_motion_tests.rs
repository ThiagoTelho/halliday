use super::*;

fn velocity_at(source:xr::Space,base:xr::Space,time:i64) -> (xr::SpaceLocation,xr::SpaceVelocity) {
    let mut velocity:xr::SpaceVelocity=unsafe {std::mem::zeroed()};
    velocity.ty=xr::SpaceVelocity::TYPE;
    let mut result=xr::SpaceLocation {ty:xr::SpaceLocation::TYPE,next:(&mut velocity as *mut xr::SpaceVelocity).cast(),location_flags:xr::SpaceLocationFlags::EMPTY,pose:IDENTITY};
    assert_eq!(unsafe {locate_space(source,base,xr::Time::from_nanos(time),&mut result)},xr::Result::SUCCESS);
    result.next=std::ptr::null_mut();
    (result,velocity)
}

#[test]
fn view_count_queries_validate_handles_populate_confidence_and_keep_the_timestamp_snapshot() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let f=Fixture::new();
    let stage=xr::Space::from_raw(0x300);
    let mut info=xr::ViewLocateInfo {ty:xr::ViewLocateInfo::TYPE,next:std::ptr::null(),view_configuration_type:xr::ViewConfigurationType::PRIMARY_STEREO,display_time:xr::Time::from_nanos(42),space:stage};
    let mut output=xr::ViewState {ty:xr::ViewState::TYPE,next:std::ptr::null_mut(),view_state_flags:xr::ViewStateFlags::EMPTY};
    let mut count=0;
    assert_eq!(unsafe {locate_views(xr::Session::NULL,&info,&mut output,0,&mut count,std::ptr::null_mut())},xr::Result::ERROR_HANDLE_INVALID);
    info.space=xr::Space::NULL;
    assert_eq!(unsafe {locate_views(session(),&info,&mut output,0,&mut count,std::ptr::null_mut())},xr::Result::ERROR_HANDLE_INVALID);
    info.space=stage;
    assert_eq!(unsafe {locate_views(session(),&info,&mut output,0,&mut count,std::ptr::null_mut())},xr::Result::SUCCESS);
    assert_eq!(count,2);
    assert!(output.view_state_flags.contains(xr::ViewStateFlags::POSITION_TRACKED));
    f.state(|s|{s.head.position[0]=1.;s.head.valid=0;});
    let (views,flags)=views_at(42,stage);
    assert!(flags.contains(xr::ViewStateFlags::POSITION_TRACKED));
    assert!((views[0].pose.position.x+0.032).abs()<1e-6,"count query seeds the same original head snapshot");
    info.display_time=xr::Time::from_nanos(43);
    assert_eq!(unsafe {locate_views(session(),&info,&mut output,0,&mut count,std::ptr::null_mut())},xr::Result::SUCCESS);
    assert!(output.view_state_flags.is_empty(),"count-only query reports current tracking loss too");
}

#[test]
fn motion_validity_is_independent_per_component_hand_and_cached_timestamp() {
    let _lock=crate::TEST_RUNTIME_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let f=Fixture::new();
    let set=set();let hands=[path("/user/hand/left"),path("/user/hand/right")];
    let action=action(set,xr::ActionType::POSE_INPUT,&hands);
    assert_eq!(bind(&[(action,"/user/hand/left/input/grip/pose"),(action,"/user/hand/right/input/grip/pose")]),xr::Result::SUCCESS);
    attach(set);events();assert_eq!(sync(&[(set,xr::Path::NULL)]),xr::Result::SUCCESS);
    let stage=xr::Space::from_raw(0x300);
    let left=space(action,hands[0],IDENTITY).unwrap();let right=space(action,hands[1],IDENTITY).unwrap();
    let mut offset=IDENTITY;offset.position.x=0.1;
    let lever=space(action,hands[0],offset).unwrap();
    let view=xr::Space::from_raw(0x333);
    with(|r|{r.session.as_mut().unwrap().spaces.insert(view.into_raw(),Space {kind:SpaceKind::View,offset:IDENTITY});});
    f.state(|s|{
        s.head.velocity=[0.4,-0.2,0.3];s.head.angular_velocity=[0.,0.4,0.];
        s.controllers[0].pose.velocity=[1.,2.,3.];s.controllers[0].pose.angular_velocity=[0.,0.,2.];
        s.controllers[1].pose.velocity=[-2.,0.1,0.2];s.controllers[1].pose.angular_velocity=[0.2,0.,0.];
    });
    let state=with(|r|r.session.as_ref().unwrap().newest.unwrap());
    let all=xr::SpaceVelocityFlags::LINEAR_VALID|xr::SpaceVelocityFlags::ANGULAR_VALID;
    let linear=xr::SpaceVelocityFlags::LINEAR_VALID;let angular=xr::SpaceVelocityFlags::ANGULAR_VALID;
    for (index,mask) in [0u32,1,2,3,4,8,12,16,32,48,63].into_iter().enumerate() {
        let time=100+index as i64;
        f._host.publish_frame_with_motion(&state,false,mask);
        for (source,device) in [(view,0),(left,1),(right,2)] {
            let (pose,motion)=velocity_at(source,stage,time);
            assert!(pose.location_flags.contains(xr::SpaceLocationFlags::POSITION_TRACKED),"motion availability never erases pose confidence");
            let bits=(mask>>(device*2))&3;
            let expected=if bits==3 {all}else if bits==1 {linear}else if bits==2 {angular}else {xr::SpaceVelocityFlags::EMPTY};
            assert_eq!(motion.velocity_flags,expected,"device {device} mask {mask}");
        }
        let lever_motion=velocity_at(lever,stage,time).1;
        assert_eq!(lever_motion.velocity_flags.contains(linear),mask&12==12,"offset point needs the controller gyro as well as translation");
        let relative=velocity_at(left,view,time).1;
        assert_eq!(relative.velocity_flags.contains(linear),mask&7==7,"nonzero moving base radius also needs base angular velocity");
        assert_eq!(relative.velocity_flags.contains(angular),mask&10==10);
        let own=velocity_at(lever,left,time).1;
        assert_eq!(own.velocity_flags,all,"same rigid entity has known constant relative offsets even without measured motion");
        assert_eq!(own.linear_velocity.x,0.);assert_eq!(own.angular_velocity.z,0.);
    }
    // The already-known time keeps both its state and component validity.
    f._host.publish_frame_with_motion(&state,false,0);
    assert_eq!(velocity_at(left,stage,110).1.velocity_flags,all);
    assert_eq!(velocity_at(left,stage,111).1.velocity_flags,xr::SpaceVelocityFlags::EMPTY);
    // Legacy callers still intentionally retain the original all-known contract.
    f._host.publish(&state);
    assert_eq!(velocity_at(left,stage,112).1.velocity_flags,all);
}
