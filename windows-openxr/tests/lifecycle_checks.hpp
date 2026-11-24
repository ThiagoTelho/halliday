// Independent application-observable lifecycle checks, shared by both graphics
// fixtures. No physical headset, installed runtime or registry changes.
#pragma once

namespace lifecycle_checks {
inline XrTime nextSampleTime(XrSession session) {
    XrFrameState frame{XR_TYPE_FRAME_STATE};
    require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame)==XR_SUCCESS,
        "get a fresh display time after changing synthetic host state");
    require(load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr)==XR_SUCCESS,"begin fresh empty fixture frame");
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};end.displayTime=frame.predictedDisplayTime;
    end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end)==XR_SUCCESS,"finish fresh empty fixture frame");
    return frame.predictedDisplayTime;
}
inline std::vector<XrSessionState> states(XrSession session) {
    std::vector<XrSessionState> result;
    XrTime last = 0;
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
        const auto status = load<PFN_xrPollEvent>("xrPollEvent")(gInstance, &event);
        if (status == XR_EVENT_UNAVAILABLE) return result;
        require(status == XR_SUCCESS, "poll lifecycle event without drawing a frame");
        require(event.type != XR_TYPE_EVENT_DATA_EVENTS_LOST, "bounded lifecycle fixture loses no events");
        if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            const auto& changed = reinterpret_cast<const XrEventDataSessionStateChanged&>(event);
            require(changed.session == session && changed.time > last, "ordered session identity and event timestamps");
            last = changed.time; result.push_back(changed.state);
        }
    }
    require(false, "event polling must quiesce without duplicate state events");
    return result;
}
inline void expect(XrSession session, std::initializer_list<XrSessionState> expected, const char* reason) {
    const auto actual = states(session);
    if (actual != std::vector<XrSessionState>(expected)) {
        std::fprintf(stderr, "LIFECYCLE expected:");
        for (const auto state : expected) std::fprintf(stderr, " %d", static_cast<int>(state));
        std::fprintf(stderr, "; received:");
        for (const auto state : actual) std::fprintf(stderr, " %d", static_cast<int>(state));
        std::fprintf(stderr, "\n");
    }
    require(actual == std::vector<XrSessionState>(expected), reason);
}
inline void action(XrSession session, const XrActionsSyncInfo& sync, XrAction pose, XrPath hand, bool focused) {
    require(load<PFN_xrSyncActions>("xrSyncActions")(session, &sync) ==
        (focused ? XR_SUCCESS : XR_SESSION_NOT_FOCUSED), "action focus follows event-only dashboard state");
    XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = pose; get.subactionPath = hand;
    XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE};
    require(load<PFN_xrGetActionStatePose>("xrGetActionStatePose")(session, &get, &state) == XR_SUCCESS &&
        bool(state.isActive) == focused, "pose action activates only with focused session");
}
inline void dashboardAndExit(XrSession session, halliday::Header* header,
                             const XrActionsSyncInfo& sync, XrAction pose, XrPath hand) {
    states(session); // Discard initial startup/profile events, retaining actual state.
    action(session, sync, pose, hand, true);
    for (unsigned cycle = 0; cycle < 3; ++cycle) {
        header->dashboard.store(1);
        expect(session, {XR_SESSION_STATE_VISIBLE}, "dashboard opens via event polling alone");
        expect(session, {}, "unchanged dashboard emits no duplicate visibility event");
        action(session, sync, pose, hand, false);
        header->dashboard.store(0);
        expect(session, {XR_SESSION_STATE_FOCUSED}, "dashboard dismissal restores focus without frame submission");
        expect(session, {}, "unchanged focus emits no duplicate event");
        action(session, sync, pose, hand, true);
    }
    const uint32_t request = header->quitRequests.fetch_add(1) + 1;
    expect(session, {XR_SESSION_STATE_VISIBLE, XR_SESSION_STATE_SYNCHRONIZED, XR_SESSION_STATE_STOPPING},
           "host quit is serviced by event polling without waiting/rendering");
    require(header->quitAcknowledged.load() == request, "owned host quit request is acknowledged exactly");
    action(session, sync, pose, hand, false);
    require(load<PFN_xrRequestExitSession>("xrRequestExitSession")(session) == XR_SUCCESS,
            "repeated exit request is accepted while stopping");
    expect(session, {}, "repeated request does not duplicate STOPPING");
    header->dashboard.store(1); header->dashboard.store(0);
    expect(session, {}, "dashboard cannot revive a stopping session");
    require(load<PFN_xrEndSession>("xrEndSession")(session) == XR_SUCCESS, "application ends stopping session normally");
    expect(session, {XR_SESSION_STATE_IDLE, XR_SESSION_STATE_EXITING}, "normal end reports IDLE then EXITING");
    expect(session, {}, "ended session cannot refocus or emit duplicates");
    std::puts("LIFECYCLE PASS: event-only dashboard round trips, action focus, duplicate suppression, host quit acknowledgement and normal end");
}
inline void hostLoss(const XrSessionCreateInfo& info, halliday::Header* header) {
    XrSession session = XR_NULL_HANDLE;
    // A previous producer can end and a new one start before the host polls.
    // The old image/count must not make the new session appear to have rendered.
    header->latest.store(2); header->clientFrames.store(900); header->reading.store(2);
    require(load<PFN_xrCreateSession>("xrCreateSession")(gInstance, &info, &session) == XR_SUCCESS,
            "create independent session for host-loss lifecycle");
    require(header->latest.load() == 0 && header->clientFrames.load() == 0 && header->reading.load() == 2,
            "new session clears old published image/count without stealing a host GPU read slot");
    const auto* epoch = reinterpret_cast<const std::atomic<uint64_t>*>(
        reinterpret_cast<const uint8_t*>(header) + 61440 + 16);
    require(epoch->load() != 0, "ready recreated session already exposes its independent generation");
    header->reading.store(0);
    expect(session, {XR_SESSION_STATE_IDLE, XR_SESSION_STATE_READY}, "recreated session starts clean");
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(load<PFN_xrBeginSession>("xrBeginSession")(session, &begin) == XR_SUCCESS, "begin host-loss fixture session");
    expect(session, {XR_SESSION_STATE_SYNCHRONIZED, XR_SESSION_STATE_VISIBLE, XR_SESSION_STATE_FOCUSED},
           "live host activates session from event polling without a frame");
    header->alive.store(0);
    expect(session, {XR_SESSION_STATE_VISIBLE, XR_SESSION_STATE_SYNCHRONIZED, XR_SESSION_STATE_STOPPING},
           "lost host reaches STOPPING through ordered event-only transitions");
    header->alive.store(1);
    expect(session, {}, "reappearing host cannot revive a stopping session");
    XrFrameState frame{XR_TYPE_FRAME_STATE};
    require(load<PFN_xrWaitFrame>("xrWaitFrame")(session, nullptr, &frame) == XR_SUCCESS && !frame.shouldRender,
            "stopping session never requests rendering even if host reappears");
    require(load<PFN_xrBeginFrame>("xrBeginFrame")(session, nullptr) == XR_SUCCESS, "finish pending stopping frame safely");
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime = frame.predictedDisplayTime;
    end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    require(load<PFN_xrEndFrame>("xrEndFrame")(session, &end) == XR_SUCCESS, "empty in-flight frame drains during STOPPING");
    expect(session, {}, "stopping frame calls do not restore focus");
    require(load<PFN_xrEndSession>("xrEndSession")(session) == XR_SUCCESS, "end host-loss session normally");
    expect(session, {XR_SESSION_STATE_IDLE, XR_SESSION_STATE_EXITING}, "lost-host cleanup has normal final states");
    require(load<PFN_xrDestroySession>("xrDestroySession")(session) == XR_SUCCESS && !header->initialized.load(),
            "lost-host session releases ownership/resources");
    std::puts("LIFECYCLE PASS: event-only host loss, no resurrection, in-flight drain, normal end/destroy and session recreation");
}
inline void readyHostQuit(const XrSessionCreateInfo& info,halliday::Header* header) {
    XrSession abandoned=XR_NULL_HANDLE,session=XR_NULL_HANDLE;
    require(load<PFN_xrCreateSession>("xrCreateSession")(gInstance,&info,&abandoned)==XR_SUCCESS,"create session with unpolled startup events");
    require(load<PFN_xrDestroySession>("xrDestroySession")(abandoned)==XR_SUCCESS,"destroy unbegun session before polling its events");
    require(load<PFN_xrCreateSession>("xrCreateSession")(gInstance,&info,&session)==XR_SUCCESS&&session!=abandoned,"recreate distinct session");
    expect(session,{XR_SESSION_STATE_IDLE,XR_SESSION_STATE_READY},"recreated startup events never contain an old session");
    const auto frames=header->clientFrames.load();const uint32_t request=header->quitRequests.fetch_add(1)+1;
    expect(session,{XR_SESSION_STATE_IDLE,XR_SESSION_STATE_EXITING},"host quit during READY is serviced by event polling without BeginSession");
    require(header->quitAcknowledged.load()==request&&header->clientFrames.load()==frames,"loading exit acknowledges quit and fabricates no frame");
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};begin.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(load<PFN_xrBeginSession>("xrBeginSession")(session,&begin)==XR_ERROR_SESSION_NOT_READY,"exiting loading session cannot start later");
    require(load<PFN_xrEndSession>("xrEndSession")(session)==XR_ERROR_SESSION_NOT_RUNNING,"unbegun loading session needs no fake EndSession");
    require(load<PFN_xrDestroySession>("xrDestroySession")(session)==XR_SUCCESS&&!header->initialized.load(),"destroy loading session releases producer");
    std::puts("LIFECYCLE PASS: destroy/recreate retires queued startup events; READY host quit ACK without frames or BeginSession");
}
} // namespace lifecycle_checks
