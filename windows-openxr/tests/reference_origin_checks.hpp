// Regression for floor transport versus leveled, initial-head OpenXR LOCAL.
#pragma once
namespace reference_origin_checks {
inline void run(XrSession session,XrSpace stage,XrTime time,halliday::Header* header,XrActionSet set,const input_checks::Actions& actions) {
    time = lifecycle_checks::nextSampleTime(session);
    lifecycle_checks::states(session);
    XrActiveActionSet active{set,XR_NULL_PATH}; XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
    sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,"activate both hand actions for reference-origin checks");
    const auto original = header->state;
    auto* extension = halliday::haptics::extension(header);
    require(extension != nullptr,"origin fixture has explicit recenter epoch");
    // This suite follows real GPU/quad checks, which may have recentered at
    // their last animated pose. Establish a known measured origin for this
    // independent regression rather than assuming their original session pose.
    header->stateSeq.fetch_add(1);
    header->state.head.position[0] = header->state.head.position[2] = 0;
    header->state.head.position[1] = 1.6f;
    header->state.head.orientation[0] = header->state.head.orientation[1] = header->state.head.orientation[2] = 0;
    header->state.head.orientation[3] = 1;
    header->state.head.valid = 1;
    header->stateSeq.fetch_add(1);
    extension->spaceEpoch.fetch_add(1);
    time = lifecycle_checks::nextSampleTime(session);
    const auto update = [&](auto edit) {
        header->stateSeq.fetch_add(1); edit(header->state); header->stateSeq.fetch_add(1);
        time = lifecycle_checks::nextSampleTime(session);
    };
    const auto create = [&](XrReferenceSpaceType kind) {
        XrReferenceSpaceCreateInfo info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        info.referenceSpaceType = kind; info.poseInReferenceSpace.orientation.w = 1;
        XrSpace out = XR_NULL_HANDLE;
        require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&info,&out) == XR_SUCCESS,"create origin regression space");
        return out;
    };
    const XrSpace local = create(XR_REFERENCE_SPACE_TYPE_LOCAL);
    const XrSpace floor = create(XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR);
    const auto locate = [&](XrSpace target,XrSpace base,XrTime requested = 0) {
        XrSpaceLocation out{XR_TYPE_SPACE_LOCATION};
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(target,base,requested ? requested : time,&out) == XR_SUCCESS &&
            (out.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT),"locate fixed natural reference origin");
        return out.pose;
    };
    const auto views = [&](XrSpace base,XrTime requested = 0) {
        XrViewLocateInfo info{XR_TYPE_VIEW_LOCATE_INFO}; info.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        info.displayTime = requested ? requested : time; info.space = base;
        XrViewState state{XR_TYPE_VIEW_STATE}; std::array<XrView,2> out{{{XR_TYPE_VIEW},{XR_TYPE_VIEW}}}; uint32_t count = 0;
        require(load<PFN_xrLocateViews>("xrLocateViews")(session,&info,&state,2,&count,out.data()) == XR_SUCCESS &&
            count == 2 && (state.viewStateFlags & XR_VIEW_STATE_POSITION_TRACKED_BIT),"locate views in independent natural reference spaces");
        return out;
    };
    const auto close = [](float a,float b) { return std::fabs(a-b) < .0001f; };
    const auto before = locate(local,stage);
    const XrTime beforeTime = time;
    const auto beforeViews = views(local);
    require(close(before.position.y,1.6f),"LOCAL anchor uses measured initial session height rather than floor or later head height");
    update([](halliday::State& state) { state.head.position[0] += .2f; state.head.position[1] += .1f; });
    const auto moved = locate(local,stage);
    require(close(moved.position.x,before.position.x) && close(moved.position.y,before.position.y),"ordinary head motion cannot move the LOCAL anchor");
    update([](halliday::State& state) { state.head.valid = 0; });
    const auto lost = locate(local,stage);
    require(close(lost.position.y,before.position.y),"fixed LOCAL anchor survives a temporary head-tracking gap");
    update([](halliday::State& state) {
        state.head.valid = 1; state.head.position[0] = 2; state.head.position[1] = 1.8f; state.head.position[2] = -3;
        state.head.orientation[0] = state.head.orientation[2] = 0;
        state.head.orientation[1] = state.head.orientation[3] = .70710678f;
    });
    const XrTime futureTime = time + 1'000'000'000;
    const auto futureBefore = views(local,futureTime);
    // Display times are predicted ahead; let the old requested time become
    // historical before changing the reference origin.
    Sleep(40);
    extension->spaceEpoch.fetch_add(1);
    time = lifecycle_checks::nextSampleTime(session);
    const auto centered = views(local), floorViews = views(floor);
    require(close((centered[0].pose.position.x+centered[1].pose.position.x)*.5f,0) &&
        close(centered[0].pose.position.y,0) && close(centered[0].pose.position.z,0) &&
        close(centered[0].pose.orientation.y,0) && close(centered[0].pose.orientation.w,1),
        "explicit recenter measures full initial XYZ and leveled yaw, without a guessed controller/head offset");
    const auto anchored = locate(local,stage), floorAnchor = locate(floor,stage);
    require(close(anchored.position.x,2) && close(anchored.position.y,1.8f) && close(anchored.position.z,-3) &&
        close(anchored.orientation.y,.70710678f) && close(floorAnchor.position.x,2) && close(floorAnchor.position.y,0) &&
        close(floorAnchor.position.z,-3) && close(floorAnchor.orientation.y,anchored.orientation.y) &&
        close(floorViews[0].pose.position.y,1.8f),"LOCAL_FLOOR shares LOCAL XZ/yaw while STAGE preserves the host floor");
    const auto historical = locate(local,stage,beforeTime);
    const auto historicalViews = views(local,beforeTime);
    require(close(historical.position.x,before.position.x) && close(historical.position.y,before.position.y) &&
        close(historical.position.z,before.position.z) && close(historical.orientation.w,before.orientation.w),
        "known pre-recenter XrTime retains its measured historical LOCAL origin");
    for (unsigned eye = 0; eye < 2; ++eye) {
        require(close(historicalViews[eye].pose.position.x,beforeViews[eye].pose.position.x) &&
            close(historicalViews[eye].pose.position.y,beforeViews[eye].pose.position.y) &&
            close(historicalViews[eye].pose.position.z,beforeViews[eye].pose.position.z) &&
            close(historicalViews[eye].pose.orientation.w,beforeViews[eye].pose.orientation.w),
            "historical eyes cannot combine old head state with the new recentered LOCAL origin");
    }
    const auto futureAfter = views(local,futureTime);
    require(!close(futureAfter[0].pose.position.y,futureBefore[0].pose.position.y) &&
        close(futureAfter[0].pose.position.y,0),
        "a cached future prediction in old reference coordinates is retired by recenter");
    // Return the fixture to the normal display-time range after the deliberately
    // far-future cache probe, without relying on wall-clock advancement.
    extension->spaceEpoch.fetch_add(1);
    time = lifecycle_checks::nextSampleTime(session);
    update([](halliday::State& state) {
        for (unsigned hand = 0; hand < 2; ++hand) {
            auto& c = state.controllers[hand];
            c.pose.position[0] = 2 + (hand ? .2f : -.2f);
            c.pose.position[1] = 1.5f; c.pose.position[2] = -3.4f;
            c.pose.velocity[0] = 1; c.pose.velocity[1] = 2; c.pose.velocity[2] = 3;
            c.pose.angularVelocity[0] = 4; c.pose.angularVelocity[1] = 5; c.pose.angularVelocity[2] = 6;
        }
    });
    for (unsigned hand = 0; hand < 2; ++hand) {
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO}; info.action = actions.pose;
        info.subactionPath = actions.hands[hand]; info.poseInActionSpace.orientation.w = 1;
        XrSpace grip = XR_NULL_HANDLE;
        require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&grip) == XR_SUCCESS,"create both-hand LOCAL origin check");
        XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY}; XrSpaceLocation location{XR_TYPE_SPACE_LOCATION}; location.next = &velocity;
        const auto status = load<PFN_xrLocateSpace>("xrLocateSpace")(grip,local,time,&location);
        require(status == XR_SUCCESS &&
            (location.locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) && close(location.pose.position.x,.4f) &&
            close(location.pose.position.y,-.3f) && close(location.pose.position.z,hand ? .2f : -.2f) &&
            close(location.pose.orientation.y,-.70710678f),"both grip poses use the identical measured LOCAL position/yaw transform");
        require(velocity.velocityFlags == (XR_SPACE_VELOCITY_LINEAR_VALID_BIT|XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) &&
            close(velocity.linearVelocity.x,-3) && close(velocity.linearVelocity.y,2) && close(velocity.linearVelocity.z,1) &&
            close(velocity.angularVelocity.x,-6) && close(velocity.angularVelocity.y,5) && close(velocity.angularVelocity.z,4),
            "linear and angular velocities rotate into the same leveled LOCAL basis");
        require(load<PFN_xrDestroySpace>("xrDestroySpace")(grip) == XR_SUCCESS,"destroy hand origin check");
    }
    const XrSpace view = create(XR_REFERENCE_SPACE_TYPE_VIEW);
    XrReferenceSpaceCreateInfo movingViewInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    movingViewInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    movingViewInfo.poseInReferenceSpace.position = {.05f,.03f,-.04f};
    movingViewInfo.poseInReferenceSpace.orientation = {.70710678f,0,0,.70710678f};
    XrSpace offsetView = XR_NULL_HANDLE;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&movingViewInfo,&offsetView) == XR_SUCCESS,
        "create moving VIEW with noncommuting public orientation and translation offsets");
    update([](halliday::State& state) {
        const auto& p = state.head.position;
        state.head.velocity[0] = 1; state.head.velocity[1] = 2; state.head.velocity[2] = 3;
        state.head.angularVelocity[0] = state.head.angularVelocity[2] = 0; state.head.angularVelocity[1] = 2;
        for (auto& c : state.controllers) {
            std::copy(std::begin(state.head.orientation),std::end(state.head.orientation),c.pose.orientation);
            // Same rigid motion as the head, at a different physical origin.
            const float rx = c.pose.position[0]-p[0], rz = c.pose.position[2]-p[2];
            c.pose.velocity[0] = 1 + 2*rz; c.pose.velocity[1] = 2; c.pose.velocity[2] = 3 - 2*rx;
            c.pose.angularVelocity[0] = c.pose.angularVelocity[2] = 0; c.pose.angularVelocity[1] = 2;
        }
    });
    const auto checkMotion = [&](XrSpace target,XrSpace base,const XrVector3f& expectedLinear,const XrVector3f& expectedAngular) {
        XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY}; XrSpaceLocation out{XR_TYPE_SPACE_LOCATION}; out.next = &velocity;
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(target,base,time,&out) == XR_SUCCESS &&
            (out.locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT),"locate moving target and base coherently");
        require(velocity.velocityFlags == (XR_SPACE_VELOCITY_LINEAR_VALID_BIT|XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) &&
            close(velocity.linearVelocity.x,expectedLinear.x) && close(velocity.linearVelocity.y,expectedLinear.y) &&
            close(velocity.linearVelocity.z,expectedLinear.z) && close(velocity.angularVelocity.x,expectedAngular.x) &&
            close(velocity.angularVelocity.y,expectedAngular.y) && close(velocity.angularVelocity.z,expectedAngular.z),
            "space velocity includes target/base lever arms and rotating-base motion in the base basis");
    };
    checkMotion(view,stage,{1,2,3},{0,2,0});
    std::array<XrSpace,2> offsetHands{};
    for (unsigned hand = 0; hand < 2; ++hand) {
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO}; info.action = actions.pose;
        info.subactionPath = actions.hands[hand]; info.poseInActionSpace.orientation.w = 1; info.poseInActionSpace.position.x = .1f;
        info.poseInActionSpace.orientation = {0,0,.70710678f,.70710678f};
        require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&offsetHands[hand]) == XR_SUCCESS,"create offset hand for moving-base velocity check");
        checkMotion(offsetHands[hand],view,{0,0,0},{0,0,0});
        checkMotion(offsetHands[hand],offsetView,{0,0,0},{0,0,0});
        const auto transformed = locate(offsetHands[hand],offsetView);
        require(close(transformed.position.x,.45f) && close(transformed.position.y,hand ? .24f : -.16f) &&
            close(transformed.position.z,.33f) && close(transformed.orientation.x,-.5f) &&
            close(transformed.orientation.y,.5f) && close(transformed.orientation.z,.5f) && close(transformed.orientation.w,.5f),
            "both source and moving-base offsets compose exactly once in correct noncommuting order for both hands");
    }
    checkMotion(offsetHands[0],offsetHands[1],{0,0,0},{0,0,0});
    for (auto hand : offsetHands) require(load<PFN_xrDestroySpace>("xrDestroySpace")(hand) == XR_SUCCESS,"destroy moving-base hand space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(offsetView) == XR_SUCCESS,"destroy offset moving VIEW space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(view) == XR_SUCCESS,"destroy moving VIEW space");
    update([&](halliday::State& state) { state = original; }); extension->spaceEpoch.fetch_add(1);
    (void)views(local); // establish the restored measured origin before later checks
    lifecycle_checks::states(session);
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(local) == XR_SUCCESS &&
        load<PFN_xrDestroySpace>("xrDestroySpace")(floor) == XR_SUCCESS,"release origin regression spaces");
    std::puts("ORIGIN PASS: measured LOCAL/LOCAL_FLOOR/STAGE; historical recenter coherence; both-hand/head velocities and moving-base lever arms");
}
} // namespace reference_origin_checks
