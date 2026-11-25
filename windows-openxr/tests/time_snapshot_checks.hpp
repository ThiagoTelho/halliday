// Application-observable pose consistency across live input updates. No extra
// prediction: a requested frame time identifies one complete host sample.
#pragma once
namespace time_snapshot_checks {
inline void run(XrSession session,XrSpace stage,XrActionSet set,
                const input_checks::Actions& actions,halliday::Header* header) {
    const auto original=header->state;
    XrActiveActionSet active{set,XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};sync.countActiveActionSets=1;sync.activeActionSets=&active;
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync)==XR_SUCCESS,"sync time-coherence action sources");
    std::array<XrSpace,2> spaces{};
    for(unsigned hand=0;hand<2;++hand){
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};info.action=actions.pose;
        info.subactionPath=actions.hands[hand];info.poseInActionSpace.orientation.w=1;
        require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&spaces[hand])==XR_SUCCESS,"create both timed action spaces");
    }
    const auto view=[&](XrTime time){
        XrViewLocateInfo info{XR_TYPE_VIEW_LOCATE_INFO};info.space=stage;info.displayTime=time;
        info.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        XrViewState state{XR_TYPE_VIEW_STATE};std::array<XrView,2> out{{{XR_TYPE_VIEW},{XR_TYPE_VIEW}}};uint32_t count=0;
        require(load<PFN_xrLocateViews>("xrLocateViews")(session,&info,&state,2,&count,out.data())==XR_SUCCESS&&count==2&&
            (state.viewStateFlags&XR_VIEW_STATE_POSITION_TRACKED_BIT),"locate timed head views");return out;
    };
    const auto hand=[&](unsigned index,XrTime time){
        XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY};XrSpaceLocation out{XR_TYPE_SPACE_LOCATION};out.next=&velocity;
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(spaces[index],stage,time,&out)==XR_SUCCESS&&
            (out.locationFlags&XR_SPACE_LOCATION_POSITION_TRACKED_BIT),"locate timed controller pose");return out.pose;
    };
    const XrTime first=lifecycle_checks::nextSampleTime(session);
    const auto oldViews=view(first);const XrPosef oldHands[2]{hand(0,first),hand(1,first)};
    header->stateSeq.fetch_add(1);
    header->state.head.position[0]+=.4f;
    header->state.head.stamp+=100;
    for(auto& controller:header->state.controllers){controller.pose.position[0]+=.7f;controller.pose.position[1]+=.2f;controller.packet+=100;}
    header->stateSeq.fetch_add(1);
    // Head queried before the update, both hands after it: the same frame time
    // must not combine independently changing portions of the host state.
    const auto again=view(first);
    for(unsigned eye=0;eye<2;++eye)require(std::fabs(again[eye].pose.position.x-oldViews[eye].pose.position.x)<1e-5f,
        "same display time retains original head after newer host packet");
    for(unsigned side=0;side<2;++side){const auto pose=hand(side,first);require(std::fabs(pose.position.x-oldHands[side].position.x)<1e-5f&&
        std::fabs(pose.position.y-oldHands[side].position.y)<1e-5f,"both hands retain same coherent historical state as head");}
    const XrTime second=lifecycle_checks::nextSampleTime(session);
    const auto newer=view(second);
    require(std::fabs(newer[0].pose.position.x-oldViews[0].pose.position.x-.4f)<1e-5f,"new display time observes new head without extra extrapolation");
    for(unsigned side=0;side<2;++side){const auto pose=hand(side,second);require(std::fabs(pose.position.x-oldHands[side].position.x-.7f)<1e-5f&&
        std::fabs(pose.position.y-oldHands[side].position.y-.2f)<1e-5f,"new time observes both new hand positions");}
    require(std::fabs(view(first)[0].pose.position.x-oldViews[0].pose.position.x)<1e-5f,"older exact time remains available after newer wait");
    header->stateSeq.fetch_add(1);header->state.controllers[0].connected=0;header->stateSeq.fetch_add(1);
    const auto historicalAfterDisconnect=hand(0,first);
    require(std::fabs(historicalAfterDisconnect.position.x-oldHands[0].position.x)<1e-5f,
        "newer live disconnect cannot invalidate known historical hand confidence or change synced source identity");
    const XrTime disconnected=lifecycle_checks::nextSampleTime(session);
    XrSpaceLocation disconnectedLocation{XR_TYPE_SPACE_LOCATION};
    require(load<PFN_xrLocateSpace>("xrLocateSpace")(spaces[0],stage,disconnected,&disconnectedLocation)==XR_SUCCESS&&
        disconnectedLocation.locationFlags==0,"new display time observes actual disconnected hand confidence");
    header->stateSeq.fetch_add(1);header->state=original;header->stateSeq.fetch_add(1);
    (void)lifecycle_checks::nextSampleTime(session);
    for(auto space:spaces)require(load<PFN_xrDestroySpace>("xrDestroySpace")(space)==XR_SUCCESS,"destroy timed spaces");
    std::puts("TIME PASS: same-XrTime full head/both-hand state remains coherent across newer host packets; next time advances without extra prediction");
}
}
