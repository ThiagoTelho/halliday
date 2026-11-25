// Public action/profile/haptic API checks, shared by the real D3D11/12 clients.
#pragma once
#include "haptic_bridge.hpp"
#include "motion_checks.hpp"

namespace input_checks {
inline XrPath path(const char* text) {
    XrPath result = XR_NULL_PATH;
    require(load<PFN_xrStringToPath>("xrStringToPath")(gInstance,text,&result) == XR_SUCCESS,"create compatibility path");
    return result;
}
struct Actions {
    XrPath hands[2]{};
    XrAction pose = XR_NULL_HANDLE, trigger = XR_NULL_HANDLE, haptic = XR_NULL_HANDLE, otherHaptic = XR_NULL_HANDLE;
    XrAction aggregateButton = XR_NULL_HANDLE, aggregateAxis = XR_NULL_HANDLE, aggregateStick = XR_NULL_HANDLE;
    XrAction parentTrigger = XR_NULL_HANDLE, weaponDial = XR_NULL_HANDLE, parentTriggerFloat = XR_NULL_HANDLE;
    XrAction parentSqueeze = XR_NULL_HANDLE, parentSqueezeFloat = XR_NULL_HANDLE, parentPose = XR_NULL_HANDLE;
    XrAction parentStickClick = XR_NULL_HANDLE, parentStickFloat = XR_NULL_HANDLE;
};
inline Actions create(XrActionSet set) {
    Actions out; out.hands[0] = path("/user/hand/left"); out.hands[1] = path("/user/hand/right");
    XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO}; info.countSubactionPaths = 2; info.subactionPaths = out.hands;
    const auto action = [&](XrActionType kind,const char* name,XrAction& result) {
        info.actionType = kind; std::strcpy(info.actionName,name); std::strcpy(info.localizedActionName,name);
        require(load<PFN_xrCreateAction>("xrCreateAction")(set,&info,&result) == XR_SUCCESS,"create compatibility action");
    };
    action(XR_ACTION_TYPE_POSE_INPUT,"compat_pose",out.pose);
    action(XR_ACTION_TYPE_FLOAT_INPUT,"compat_trigger",out.trigger);
    action(XR_ACTION_TYPE_VIBRATION_OUTPUT,"compat_haptic",out.haptic);
    action(XR_ACTION_TYPE_VIBRATION_OUTPUT,"compat_haptic_other",out.otherHaptic);
    action(XR_ACTION_TYPE_BOOLEAN_INPUT,"compat_aggregate_button",out.aggregateButton);
    action(XR_ACTION_TYPE_FLOAT_INPUT,"compat_aggregate_axis",out.aggregateAxis);
    action(XR_ACTION_TYPE_VECTOR2F_INPUT,"compat_aggregate_stick",out.aggregateStick);
    action(XR_ACTION_TYPE_BOOLEAN_INPUT,"compat_parent_trigger",out.parentTrigger);
    action(XR_ACTION_TYPE_BOOLEAN_INPUT,"weapondial_start",out.weaponDial);
    action(XR_ACTION_TYPE_FLOAT_INPUT,"compat_parent_trigger_float",out.parentTriggerFloat);
    action(XR_ACTION_TYPE_BOOLEAN_INPUT,"compat_parent_squeeze",out.parentSqueeze);
    action(XR_ACTION_TYPE_FLOAT_INPUT,"compat_parent_squeeze_float",out.parentSqueezeFloat);
    action(XR_ACTION_TYPE_POSE_INPUT,"compat_parent_pose",out.parentPose);
    action(XR_ACTION_TYPE_BOOLEAN_INPUT,"compat_parent_stick_click",out.parentStickClick);
    action(XR_ACTION_TYPE_FLOAT_INPUT,"compat_parent_stick_float",out.parentStickFloat);
    return out;
}
inline void append(const Actions& actions,std::vector<XrActionSuggestedBinding>& bindings,bool simple) {
    for (unsigned hand = 0; hand < 2; ++hand) {
        const std::string root = hand ? "/user/hand/right" : "/user/hand/left";
        bindings.push_back({actions.pose,path((root+"/input/grip/pose").c_str())});
        bindings.push_back({actions.trigger,path((root+(simple ? "/input/select/click" : "/input/trigger/value")).c_str())});
        bindings.push_back({actions.haptic,path((root+"/output/haptic").c_str())});
        bindings.push_back({actions.otherHaptic,path((root+"/output/haptic").c_str())});
        if (!simple) {
            bindings.push_back({actions.aggregateButton,path((root+"/input/trigger/value").c_str())});
            bindings.push_back({actions.aggregateAxis,path((root+"/input/thumbstick/x").c_str())});
            bindings.push_back({actions.aggregateStick,path((root+"/input/thumbstick").c_str())});
            for (auto action : {actions.parentTrigger, actions.weaponDial, actions.parentTriggerFloat})
                bindings.push_back({action,path((root+"/input/trigger").c_str())});
            bindings.push_back({actions.parentSqueeze,path((root+"/input/squeeze").c_str())});
            bindings.push_back({actions.parentSqueezeFloat,path((root+"/input/squeeze").c_str())});
            bindings.push_back({actions.parentPose,path((root+"/input/grip").c_str())});
            bindings.push_back({actions.parentStickClick,path((root+"/input/thumbstick").c_str())});
            bindings.push_back({actions.parentStickFloat,path((root+"/input/thumbstick").c_str())});
        } else {
            bindings.push_back({actions.parentTrigger,path((root+"/input/select").c_str())});
            bindings.push_back({actions.parentTriggerFloat,path((root+"/input/select").c_str())});
            bindings.push_back({actions.parentPose,path((root+"/input/grip").c_str())});
        }
    }
}
inline void incrementalParents(const Actions& actions, const std::vector<XrActionSuggestedBinding>& bindings) {
    // REFramework submits a growing list and drops the last candidate if it
    // fails. A rejected parent must leave every earlier accepted binding intact.
    XrInteractionProfileSuggestedBinding info{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    info.interactionProfile = path("/interaction_profiles/oculus/touch_controller");
    info.suggestedBindings = bindings.data();
    for (size_t count = 1; count <= bindings.size(); ++count) {
        info.countSuggestedBindings = static_cast<uint32_t>(count);
        const auto result=load<PFN_xrSuggestInteractionProfileBindings>("xrSuggestInteractionProfileBindings")(gInstance,&info);
        if (result!=XR_SUCCESS) {
            char text[XR_MAX_PATH_LENGTH]{}; uint32_t length=0;
            load<PFN_xrPathToString>("xrPathToString")(gInstance,bindings[count-1].binding,sizeof(text),&length,text);
            std::fprintf(stderr,"PARENT binding=%zu path=%s result=%d\n",count,text,result);
        }
        require(result == XR_SUCCESS,
            "REFramework incremental parent suggestions remain accepted");
    }
    for (const auto* invalid : {"/user/hand/left/input/trigger/click", "/user/hand/right/input/trigger/click",
        "/user/hand/left/input/unknown", "/user/hand/right/input/squeeze/touch", "/user/hand/left/input/trigger/nope"}) {
        auto rejected = bindings; rejected.push_back({actions.weaponDial,path(invalid)});
        info.countSuggestedBindings = static_cast<uint32_t>(rejected.size()); info.suggestedBindings = rejected.data();
        require(load<PFN_xrSuggestInteractionProfileBindings>("xrSuggestInteractionProfileBindings")(gInstance,&info) == XR_ERROR_PATH_UNSUPPORTED,
            "unsupported parent/component rejects transactionally without inventing Touch click/touch inputs");
    }
    auto excessive = bindings;
    while (excessive.size() <= 1024) excessive.push_back(bindings.front());
    info.countSuggestedBindings = static_cast<uint32_t>(excessive.size()); info.suggestedBindings = excessive.data();
    require(load<PFN_xrSuggestInteractionProfileBindings>("xrSuggestInteractionProfileBindings")(gInstance,&info) == XR_ERROR_LIMIT_REACHED,
        "parent resolution preserves transactional suggestion limits");
}

inline void parentInputs(XrSession session,XrActionSet set,const Actions& actions,XrSpace stage,halliday::Header* header) {
    const auto original = header->state;
    XrActiveActionSet active{set,XR_NULL_PATH}; XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
    sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    for (float pressure : {0.f,.25f,.75f,1.f,0.f}) for (unsigned clickMask = 0; clickMask < 4; ++clickMask) {
        header->stateSeq.fetch_add(1);
        for (unsigned hand = 0; hand < 2; ++hand) {
            auto& c = header->state.controllers[hand]; c.connected = 1;
            c.axes[1][0] = hand ? 1-pressure : pressure;
            c.axes[2][0] = hand ? pressure : 1-pressure;
            c.pressed &= ~((uint64_t{1}<<33)|(uint64_t{1}<<32)|(uint64_t{1}<<2));
            if (clickMask & (1u<<hand)) c.pressed |= (uint64_t{1}<<32);
            c.touched |= uint64_t{1}<<32; // A parent must select click, not touch.
        }
        header->stateSeq.fetch_add(1);
        require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,"sync parent-input press/release matrix");
        for (unsigned hand = 0; hand < 2; ++hand) {
            XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.subactionPath = actions.hands[hand];
            const float trigger = hand ? 1-pressure : pressure, squeeze = hand ? pressure : 1-pressure;
            for (const auto action : {actions.parentTrigger, actions.weaponDial, actions.aggregateButton}) {
                get.action = action; XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
                require(load<PFN_xrGetActionStateBoolean>("xrGetActionStateBoolean")(session,&get,&value) == XR_SUCCESS &&
                    value.isActive && bool(value.currentState) == (trigger>=.5f),"both duplicate parent Boolean actions equal explicit trigger/value on each hand");
            }
            get.action = actions.parentSqueeze; XrActionStateBoolean squeezeOut{XR_TYPE_ACTION_STATE_BOOLEAN};
            require(load<PFN_xrGetActionStateBoolean>("xrGetActionStateBoolean")(session,&get,&squeezeOut) == XR_SUCCESS &&
                squeezeOut.isActive && bool(squeezeOut.currentState) == (squeeze>=.5f),"squeeze parent Boolean uses declared value conversion");
            for (auto item : {std::pair<XrAction,float>{actions.parentTriggerFloat,trigger}, {actions.trigger,trigger},
                {actions.parentSqueezeFloat,squeeze}, {actions.parentStickFloat,(clickMask&(1u<<hand))?1.f:0.f}}) {
                get.action = item.first; XrActionStateFloat value{XR_TYPE_ACTION_STATE_FLOAT};
                require(load<PFN_xrGetActionStateFloat>("xrGetActionStateFloat")(session,&get,&value) == XR_SUCCESS && value.isActive &&
                    std::fabs(value.currentState-item.second)<1e-6f,"float parent prefers value or falls back to declared click without altering explicit paths");
            }
            get.action = actions.parentStickClick; XrActionStateBoolean stick{XR_TYPE_ACTION_STATE_BOOLEAN};
            require(load<PFN_xrGetActionStateBoolean>("xrGetActionStateBoolean")(session,&get,&stick) == XR_SUCCESS && stick.isActive &&
                bool(stick.currentState) == bool(clickMask&(1u<<hand)),"Boolean thumbstick parent selects click despite constant touch");
        }
    }
    for (unsigned hand = 0; hand < 2; ++hand) {
        XrBoundSourcesForActionEnumerateInfo bound{XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO}; bound.action = actions.weaponDial;
        XrPath sources[2]{}; uint32_t count = 0;
        require(load<PFN_xrEnumerateBoundSourcesForAction>("xrEnumerateBoundSourcesForAction")(session,&bound,2,&count,sources)==XR_SUCCESS && count==2,
            "parent source atoms survive incremental replacement and rejected suggestions");
        const auto expected = path(hand ? "/user/hand/right/input/trigger" : "/user/hand/left/input/trigger");
        require(sources[0]==expected || sources[1]==expected,"enumerated parent path remains the original application atom");
        XrInputSourceLocalizedNameGetInfo name{XR_TYPE_INPUT_SOURCE_LOCALIZED_NAME_GET_INFO}; name.sourcePath=expected;
        name.whichComponents=XR_INPUT_SOURCE_LOCALIZED_NAME_USER_PATH_BIT|XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT;
        char text[128]{}; uint32_t length=0;
        require(load<PFN_xrGetInputSourceLocalizedName>("xrGetInputSourceLocalizedName")(session,&name,sizeof(text),&length,text)==XR_SUCCESS &&
            std::strstr(text,"Trigger") && std::strstr(text,hand ? "Right" : "Left"),"original parent source has a useful localized name");
        XrSpace spaces[2]{};
        for (unsigned i=0;i<2;++i) {
            XrActionSpaceCreateInfo create{XR_TYPE_ACTION_SPACE_CREATE_INFO}; create.action=i ? actions.parentPose : actions.pose;
            create.subactionPath=actions.hands[hand]; create.poseInActionSpace.orientation.w=1;
            require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&create,&spaces[i])==XR_SUCCESS,"create explicit and parent grip spaces");
        }
        const auto time=lifecycle_checks::nextSampleTime(session); XrSpaceLocation locations[2]{{XR_TYPE_SPACE_LOCATION},{XR_TYPE_SPACE_LOCATION}};
        for (unsigned i=0;i<2;++i) require(load<PFN_xrLocateSpace>("xrLocateSpace")(spaces[i],stage,time,&locations[i])==XR_SUCCESS,"locate parent grip pose");
        require(locations[0].locationFlags==locations[1].locationFlags &&
            std::memcmp(&locations[0].pose,&locations[1].pose,sizeof(XrPosef))==0,"pose parent resolves the exact declared grip/pose geometry");
        for(auto space:spaces)require(load<PFN_xrDestroySpace>("xrDestroySpace")(space)==XR_SUCCESS,"release parent pose check");
    }
    header->stateSeq.fetch_add(1); header->state=original; header->stateSeq.fetch_add(1);
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync)==XR_SUCCESS,"restore parent-input matrix");
    std::puts("PARENT PASS: incremental REFramework bindings, both-hand duplicate Boolean trigger/squeeze, float value/click preference, pose, immutable localized paths and transactional rejection");
}
inline void suggestSimple(const Actions& actions) {
    std::vector<XrActionSuggestedBinding> bindings; append(actions,bindings,true);
    XrInteractionProfileSuggestedBinding info{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    info.interactionProfile = path("/interaction_profiles/khr/simple_controller");
    info.countSuggestedBindings = static_cast<uint32_t>(bindings.size()); info.suggestedBindings = bindings.data();
    require(load<PFN_xrSuggestInteractionProfileBindings>("xrSuggestInteractionProfileBindings")(gInstance,&info) == XR_SUCCESS,
        "retain complete Simple Controller suggestions without erasing Touch");
}
inline void rejectWrongType(const Actions& actions) {
    XrActionSuggestedBinding binding{actions.pose,path("/user/hand/left/input/trigger/value")};
    XrInteractionProfileSuggestedBinding info{XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
    info.interactionProfile = path("/interaction_profiles/oculus/touch_controller");
    info.countSuggestedBindings = 1; info.suggestedBindings = &binding;
    require(load<PFN_xrSuggestInteractionProfileBindings>("xrSuggestInteractionProfileBindings")(gInstance,&info) == XR_ERROR_PATH_UNSUPPORTED,
        "wrong-type binding errors before replacing valid suggestions");
}

inline void aggregateInputs(XrSession session,XrActionSet set,const Actions& actions,halliday::Header* header) {
    const auto original = header->state;
    XrActiveActionSet active{set,XR_NULL_PATH}; XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};
    sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    const auto synchronize = [&] { require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,
        "sync aggregate-input model state"); };
    const auto publish = [&](float left,float right,XrVector2f leftStick,XrVector2f rightStick) {
        header->stateSeq.fetch_add(1);
        const float trigger[2]{left,right}; const XrVector2f sticks[2]{leftStick,rightStick};
        for (unsigned hand = 0; hand < 2; ++hand) {
            auto& c = header->state.controllers[hand];
            c.connected = 1; c.pressed &= ~(uint64_t{1}<<33);
            c.axes[1][0] = trigger[hand]; c.axes[0][0] = sticks[hand].x; c.axes[0][1] = sticks[hand].y;
        }
        header->stateSeq.fetch_add(1);
    };
    const auto boolean = [&] {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = actions.aggregateButton;
        XrActionStateBoolean value{XR_TYPE_ACTION_STATE_BOOLEAN};
        require(load<PFN_xrGetActionStateBoolean>("xrGetActionStateBoolean")(session,&get,&value) == XR_SUCCESS,"read aggregate boolean"); return value;
    };
    const auto scalar = [&] {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = actions.aggregateAxis;
        XrActionStateFloat value{XR_TYPE_ACTION_STATE_FLOAT};
        require(load<PFN_xrGetActionStateFloat>("xrGetActionStateFloat")(session,&get,&value) == XR_SUCCESS,"read aggregate signed scalar"); return value;
    };
    const auto vector = [&] {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = actions.aggregateStick;
        XrActionStateVector2f value{XR_TYPE_ACTION_STATE_VECTOR2F};
        require(load<PFN_xrGetActionStateVector2f>("xrGetActionStateVector2f")(session,&get,&value) == XR_SUCCESS,"read aggregate whole vector"); return value;
    };
    XrActionsSyncInfo none{XR_TYPE_ACTIONS_SYNC_INFO};
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&none) == XR_SUCCESS,"deactivate sources before first model activation");
    publish(1,0,{-.8f,0},{.4f,.9f}); synchronize();
    const auto a = boolean(); const auto b = scalar(); const auto c = vector();
    require(a.isActive && a.currentState && b.isActive && std::fabs(b.currentState+.8f)<1e-6f &&
        c.isActive && std::fabs(c.currentState.x-.4f)<1e-6f && std::fabs(c.currentState.y-.9f)<1e-6f &&
        !a.changedSinceLastSync && !b.changedSinceLastSync && !c.changedSinceLastSync,
        "boolean OR, greatest signed-scalar magnitude and complete-vector selection activate without fabricated changes");
    publish(0,1,{.4f,.9f},{-.8f,0});
    require(boolean().currentState == a.currentState && scalar().currentState == b.currentState &&
        vector().currentState.x == c.currentState.x && vector().currentState.y == c.currentState.y,
        "new hardware state remains invisible until sync");
    synchronize();
    const auto aa = boolean(); const auto bb = scalar(); const auto cc = vector();
    require(aa.currentState && std::fabs(bb.currentState+.8f)<1e-6f &&
        std::fabs(cc.currentState.x-.4f)<1e-6f && std::fabs(cc.currentState.y-.9f)<1e-6f &&
        !aa.changedSinceLastSync && !bb.changedSinceLastSync && !cc.changedSinceLastSync &&
        aa.lastChangeTime == a.lastChangeTime && bb.lastChangeTime == b.lastChangeTime && cc.lastChangeTime == c.lastChangeTime,
        "source handover with the identical aggregate value does not fabricate a value change or event time");
    publish(0,0,{.3f,0},{.2f,.2f}); synchronize();
    require(!boolean().currentState && boolean().changedSinceLastSync &&
        std::fabs(scalar().currentState-.3f)<1e-6f && scalar().changedSinceLastSync &&
        std::fabs(vector().currentState.x-.3f)<1e-6f && vector().currentState.y == 0 && vector().changedSinceLastSync,
        "real aggregate changes are reported for all three value types without mixing vector axes");
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&none) == XR_SUCCESS,"deactivate aggregate sources");
    require(!boolean().isActive && !boolean().currentState && !boolean().changedSinceLastSync && boolean().lastChangeTime == 0 &&
        !scalar().isActive && scalar().currentState == 0 && scalar().lastChangeTime == 0 &&
        !vector().isActive && vector().currentState.x == 0 && vector().currentState.y == 0 && vector().lastChangeTime == 0,
        "inactive actions consistently clear values, change flags and times");
    header->stateSeq.fetch_add(1); header->state = original; header->stateSeq.fetch_add(1); synchronize();
    std::puts("AGGREGATE PASS: boolean OR, signed scalar magnitude, whole-vector selection, coherent cached queries and handover/change/inactive semantics");
}
inline void analogTrigger(XrSession session,XrActionSet set,const Actions& actions,halliday::Header* header) {
    const auto original=header->state;
    XrActiveActionSet active{set,XR_NULL_PATH};XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO};sync.countActiveActionSets=1;sync.activeActionSets=&active;
    const float values[]{0,.25f,.6f,.75f,1};
    for(float value:values)for(unsigned clicks=0;clicks<4;++clicks) {
        header->stateSeq.fetch_add(1);
        for(unsigned hand=0;hand<2;++hand){auto& c=header->state.controllers[hand];c.axes[1][0]=value;c.pressed=(c.pressed&~(uint64_t{1}<<33))|((clicks&(1u<<hand))?(uint64_t{1}<<33):0);}
        header->stateSeq.fetch_add(1);
        require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync)==XR_SUCCESS,"sync measured analog trigger matrix");
        for(int hand=-1;hand<2;++hand) {
            XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO};get.action=actions.trigger;get.subactionPath=hand<0?XR_NULL_PATH:actions.hands[hand];
            XrActionStateFloat out{XR_TYPE_ACTION_STATE_FLOAT};
            require(load<PFN_xrGetActionStateFloat>("xrGetActionStateFloat")(session,&get,&out)==XR_SUCCESS&&out.isActive,"read measured analog trigger");
            if(std::fabs(out.currentState-value)>1e-6f)std::fprintf(stderr,"ANALOG value=%.6f clicks=%u hand=%d actual=%.6f\n",value,clicks,hand,out.currentState);
            require(std::fabs(out.currentState-value)<1e-6f,"trigger/value preserves measured pressure independently of the click bit");
            if(hand>=0){get.action=actions.aggregateButton;XrActionStateBoolean b{XR_TYPE_ACTION_STATE_BOOLEAN};
                require(load<PFN_xrGetActionStateBoolean>("xrGetActionStateBoolean")(session,&get,&b)==XR_SUCCESS&&b.isActive&&
                    bool(b.currentState)==(value>.5f||bool(clicks&(1u<<hand))),"trigger Boolean policy remains unchanged");}
        }
    }
    header->stateSeq.fetch_add(1);header->state=original;header->stateSeq.fetch_add(1);
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync)==XR_SUCCESS,"restore analog matrix input");
    std::puts("ANALOG PASS: both hands and aggregate preserve0/.25/.6/.75/1 pressure with independent click bits; Boolean policy unchanged");
}
inline void commonReferencePosition(XrSession session,halliday::Header* header) {
    const auto original=header->state;
    header->stateSeq.fetch_add(1);header->state.head.valid=0;header->stateSeq.fetch_add(1);
    const auto time=lifecycle_checks::nextSampleTime(session);
    for(const auto kind:{XR_REFERENCE_SPACE_TYPE_VIEW,XR_REFERENCE_SPACE_TYPE_LOCAL,XR_REFERENCE_SPACE_TYPE_STAGE}) {
        XrReferenceSpaceCreateInfo info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};info.referenceSpaceType=kind;
        info.poseInReferenceSpace={{0,0,0,1},{1,2,3}};XrSpace source=XR_NULL_HANDLE,base=XR_NULL_HANDLE;
        require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&info,&source)==XR_SUCCESS,"create common natural entity target");
        info.poseInReferenceSpace={{0,std::sqrt(.5f),0,std::sqrt(.5f)},{-1,5,2}};
        require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&info,&base)==XR_SUCCESS,"create rotated common entity base");
        XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY};XrSpaceLocation out{XR_TYPE_SPACE_LOCATION};out.next=&velocity;
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(source,base,time,&out)==XR_SUCCESS,"locate exact relative offsets without head tracking");
        constexpr auto required=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
        // Independent coordinate oracle: rotate [2,-3,1] by inverse 90deg Y.
        require((out.locationFlags&required)==required&&std::fabs(out.pose.position.x+1)<1e-5&&
            std::fabs(out.pose.position.y+3)<1e-5&&std::fabs(out.pose.position.z-2)<1e-5,
            "relative position is tracked within the same entity despite missing absolute tracking");
        require(velocity.velocityFlags==(XR_SPACE_VELOCITY_LINEAR_VALID_BIT|XR_SPACE_VELOCITY_ANGULAR_VALID_BIT)&&
            velocity.linearVelocity.x==0&&velocity.angularVelocity.z==0,"constant relative transform has known zero motion");
        require(load<PFN_xrDestroySpace>("xrDestroySpace")(source)==XR_SUCCESS&&load<PFN_xrDestroySpace>("xrDestroySpace")(base)==XR_SUCCESS,"destroy common entity spaces");
    }
    header->stateSeq.fetch_add(1);header->state=original;header->stateSeq.fetch_add(1);
    (void)lifecycle_checks::nextSampleTime(session);
    std::puts("RELATIVE PASS: VIEW/LOCAL/STAGE application offsets retain exact tracked relative position and zero motion without absolute head tracking");
}
inline void run(XrSession session,XrActionSet set,const Actions& actions,XrSpace stage,XrTime time,
                halliday::Header* header,bool simple = false) {
    time = lifecycle_checks::nextSampleTime(session);
    const auto original = header->state;
    const auto update = [&](auto edit) {
        header->stateSeq.fetch_add(1); edit(header->state); header->stateSeq.fetch_add(1);
        // A repeated XrTime deliberately returns its original coherent state;
        // changed synthetic input therefore belongs to a fresh display time.
        time = lifecycle_checks::nextSampleTime(session);
    };
    XrActiveActionSet active{set,XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO}; sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    const auto synchronize = [&] {
        lifecycle_checks::states(session);
        require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,"sync compatibility actions");
    };
    synchronize();
    XrInteractionProfileState profile{XR_TYPE_INTERACTION_PROFILE_STATE};
    const XrPath expected = path(simple ? "/interaction_profiles/khr/simple_controller" : "/interaction_profiles/oculus/touch_controller");
    for (XrPath hand : actions.hands)
        require(load<PFN_xrGetCurrentInteractionProfile>("xrGetCurrentInteractionProfile")(session,hand,&profile) == XR_SUCCESS &&
            profile.interactionProfile == expected,"reported profile matches effective mapped input, Touch preferred regardless suggestion order");
    if (!simple) { aggregateInputs(session,set,actions,header); analogTrigger(session,set,actions,header); parentInputs(session,set,actions,stage,header); }
    XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO}; info.action = actions.pose; info.poseInActionSpace.orientation.w = 1;
    XrSpace aggregate = XR_NULL_HANDLE, left = XR_NULL_HANDLE, offsetLeft = XR_NULL_HANDLE;
    require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&aggregate) == XR_SUCCESS,"create NULL-hand action space");
    info.subactionPath = actions.hands[0];
    require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&left) == XR_SUCCESS,"create explicit left action space");
    info.poseInActionSpace.position = {.02f,.03f,-.04f};
    info.poseInActionSpace.orientation = {0,.70710678f,0,.70710678f};
    require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&offsetLeft) == XR_SUCCESS,"create rotated local application offset");
    const auto locate = [&](XrSpace space) {
        XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(space,stage,time,&location) == XR_SUCCESS,"locate compatibility action space");
        return location;
    };
    const auto poseActive = [&](XrPath hand) {
        XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = actions.pose; get.subactionPath = hand;
        XrActionStatePose state{XR_TYPE_ACTION_STATE_POSE};
        require(load<PFN_xrGetActionStatePose>("xrGetActionStatePose")(session,&get,&state) == XR_SUCCESS,"query pose action availability");
        return bool(state.isActive);
    };
    require(locate(aggregate).pose.position.x < 0,"aggregate pose selects deterministic initial left source");
    update([](halliday::State& state) { state.controllers[0].pose.valid = 0; }); synchronize();
    require(poseActive(actions.hands[0]) && locate(left).locationFlags == 0 && locate(aggregate).locationFlags == 0,
        "tracking loss clears spatial flags, preserves connected action and never substitutes another hand");
    XrSpaceLocation relative{XR_TYPE_SPACE_LOCATION};
    require(load<PFN_xrLocateSpace>("xrLocateSpace")(offsetLeft,left,time,&relative) == XR_SUCCESS &&
        relative.locationFlags == (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT) &&
        std::fabs(relative.pose.position.x-.02f)<.00001f && std::fabs(relative.pose.position.y-.03f)<.00001f &&
        std::fabs(relative.pose.position.z+.04f)<.00001f && std::fabs(relative.pose.orientation.y-.70710678f)<.00001f,
        "common-entity relative position remains tracked during absolute tracking loss");
    XrActionStateGetInfo get{XR_TYPE_ACTION_STATE_GET_INFO}; get.action = actions.trigger; get.subactionPath = actions.hands[0];
    XrActionStateFloat trigger{XR_TYPE_ACTION_STATE_FLOAT};
    require(load<PFN_xrGetActionStateFloat>("xrGetActionStateFloat")(session,&get,&trigger) == XR_SUCCESS && trigger.isActive &&
        std::fabs(trigger.currentState-(simple ? 1.0f : .75f)) < .0001f,"button/axis input remains available while only spatial tracking is lost");
    update([](halliday::State& state) { state.controllers[0].connected = 0; }); synchronize();
    require(!poseActive(actions.hands[0]) && locate(aggregate).pose.position.x > 0,"disconnection switches aggregate source at action sync");
    update([](halliday::State& state) { state.controllers[0].connected = state.controllers[0].pose.valid = 1; }); synchronize();
    require(locate(aggregate).pose.position.x > 0,"reconnecting left does not steal the selected right-hand source");
    update([](halliday::State& state) { state.controllers[1].connected = 0; });
    require(locate(aggregate).locationFlags == 0,"live source loss cannot switch hand between action syncs"); synchronize();
    require(locate(aggregate).pose.position.x < 0,"aggregate source changes only at next sync");
    update([](halliday::State& state) { state.controllers[1].connected = 1; state.head.valid = 0; }); synchronize();
    require(poseActive(actions.hands[0]) && (locate(left).locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT),
        "head confidence loss does not invalidate independently tracked hand in a fixed world space");
    update([&](halliday::State& state) { state = original; }); synchronize();
    relative = {XR_TYPE_SPACE_LOCATION};
    require(load<PFN_xrLocateSpace>("xrLocateSpace")(offsetLeft,left,time,&relative) == XR_SUCCESS &&
        (relative.locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT),"known relative offsets regain tracked flags with actual source confidence");

    motion_checks::run(session,actions.pose,actions.hands,stage,header);
    commonReferencePosition(session,header);
    time = lifecycle_checks::nextSampleTime(session);

    auto* extension = halliday::haptics::extension(header);
    require(extension && extension->clientEpoch.load(),"real haptic producer claims host-initialized extension");
    lifecycle_checks::states(session);
    update([](halliday::State& state) { state.head.position[0] += .1f; });
    XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};
    require(load<PFN_xrPollEvent>("xrPollEvent")(gInstance,&event) == XR_EVENT_UNAVAILABLE,"ordinary head movement emits no recenter event");
    extension->spaceEpoch.fetch_add(1);
    bool localChanged = false, stageChanged = false;
    for (unsigned i = 0; i < 8; ++i) {
        event = {XR_TYPE_EVENT_DATA_BUFFER};
        const XrResult status = load<PFN_xrPollEvent>("xrPollEvent")(gInstance,&event);
        if (status == XR_EVENT_UNAVAILABLE) break;
        require(status == XR_SUCCESS && event.type == XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING,"explicit host recenter emits reference-space event");
        const auto& changed = reinterpret_cast<const XrEventDataReferenceSpaceChangePending&>(event);
        require(changed.session == session && changed.changeTime > 0 && !changed.poseValid,"recenter reports unknown transform honestly");
        if (changed.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_LOCAL) { require(!localChanged,"one LOCAL recenter event"); localChanged = true; }
        if (changed.referenceSpaceType == XR_REFERENCE_SPACE_TYPE_STAGE) { require(!stageChanged,"one STAGE recenter event"); stageChanged = true; }
    }
    require(localChanged && stageChanged,"recenter notifies LOCAL and created STAGE once");
    update([&](halliday::State& state) { state = original; });
    XrHapticActionInfo output{XR_TYPE_HAPTIC_ACTION_INFO}; output.action = actions.haptic;
    XrHapticVibration pulse{XR_TYPE_HAPTIC_VIBRATION}; pulse.duration = 50'000'000; pulse.amplitude = .8f; pulse.frequency = 77;
    const auto play = [&] { return load<PFN_xrApplyHapticFeedback>("xrApplyHapticFeedback")(session,&output,reinterpret_cast<const XrHapticBaseHeader*>(&pulse)); };
    const uint32_t before[2]{extension->hands[0].seq.load(),extension->hands[1].seq.load()};
    require(play() == XR_SUCCESS && extension->hands[0].seq.load() == before[0]+2 && extension->hands[1].seq.load() == before[1]+2,
        "NULL haptic output reaches both effective bound hands");
    for (auto& hand : extension->hands)
        require(hand.durationNs.load() == 50'000'000 && hand.epoch.load() == extension->clientEpoch.load() &&
            hand.issuedHostClock.load() == extension->clockNs.load(),"haptic transport carries exact duration/epoch/host timestamp");
    output.subactionPath = actions.hands[1];
    require(load<PFN_xrStopHapticFeedback>("xrStopHapticFeedback")(session,&output) == XR_SUCCESS &&
        extension->hands[1].durationNs.load() == 0 && extension->hands[0].durationNs.load() == 50'000'000,"explicit stop addresses only selected hand");
    output.action = actions.otherHaptic; output.subactionPath = XR_NULL_PATH;
    require(play() == XR_SUCCESS,"new output action replaces the prior event on bound devices");
    const uint32_t replaced[2]{extension->hands[0].seq.load(),extension->hands[1].seq.load()};
    output.action = actions.haptic;
    require(load<PFN_xrStopHapticFeedback>("xrStopHapticFeedback")(session,&output) == XR_SUCCESS &&
        extension->hands[0].seq.load() == replaced[0] && extension->hands[1].seq.load() == replaced[1],
        "stopping a previous action cannot cancel another action's replacement pulse");
    require(play() == XR_SUCCESS,"restart bound output before input action-set deactivation");
    XrActionsSyncInfo none{XR_TYPE_ACTIONS_SYNC_INFO};
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&none) == XR_SUCCESS &&
        extension->hands[0].durationNs.load() == 50'000'000 && extension->hands[1].durationNs.load() == 50'000'000,
        "empty input synchronization never cancels independent output requests");
    const uint32_t inactive[2]{extension->hands[0].seq.load(),extension->hands[1].seq.load()};
    require(play() == XR_SUCCESS && extension->hands[0].seq.load() == inactive[0]+2 && extension->hands[1].seq.load() == inactive[1]+2,
        "attached haptic output remains immediate after empty input synchronization");
    require(load<PFN_xrStopHapticFeedback>("xrStopHapticFeedback")(session,&output) == XR_SUCCESS &&
        extension->hands[0].durationNs.load() == 0 && extension->hands[1].durationNs.load() == 0,"stop remains effective without active input sets");
    synchronize();
    XrActionsSyncInfo inactiveSync{XR_TYPE_ACTIONS_SYNC_INFO};
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&inactiveSync) == XR_SUCCESS,
        "deactivate pose input before checking same-entity offsets");
    relative = {XR_TYPE_SPACE_LOCATION};
    const auto inactiveRelativeStatus = load<PFN_xrLocateSpace>("xrLocateSpace")(offsetLeft,left,time,&relative);
    if (inactiveRelativeStatus != XR_SUCCESS ||
        relative.locationFlags != (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT) ||
        std::fabs(relative.pose.position.x-.02f)>=.00001f || std::fabs(relative.pose.position.y-.03f)>=.00001f ||
        std::fabs(relative.pose.position.z+.04f)>=.00001f) {
        std::fprintf(stderr,"INACTIVE RELATIVE status=%d flags=%llu position=(%.9f,%.9f,%.9f) handles=(%p,%p)\n",
            int(inactiveRelativeStatus),static_cast<unsigned long long>(relative.locationFlags),
            relative.pose.position.x,relative.pose.position.y,relative.pose.position.z,
            reinterpret_cast<void*>(offsetLeft),reinterpret_cast<void*>(left));
    }
    require(inactiveRelativeStatus == XR_SUCCESS &&
        relative.locationFlags == (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_POSITION_TRACKED_BIT) &&
        std::fabs(relative.pose.position.x-.02f)<.00001f && std::fabs(relative.pose.position.y-.03f)<.00001f &&
        std::fabs(relative.pose.position.z+.04f)<.00001f,
        "known offsets within the identical action entity remain valid when its input set is inactive");
    synchronize();
    require(play()==XR_SUCCESS,"start output before an unobserved dashboard round trip");
    halliday::focus::setDashboard(header,true);halliday::focus::setDashboard(header,false);
    lifecycle_checks::expect(session,{},"rapid focus round trip does not fabricate historical state events");
    require(extension->hands[0].durationNs.load()==0&&extension->hands[1].durationNs.load()==0,
        "runtime cancels pre-edge haptics even when the latest dashboard boolean is focused again");
    halliday::focus::setDashboard(header,true);halliday::focus::setDashboard(header,false);
    require(play()==XR_SUCCESS,"post-edge Apply remains immediate before host polls again");
    const auto* focus=halliday::focus::extension(header);
    require(focus&&focus->producerEpoch.load()==extension->clientEpoch.load(),"focus tags belong to current haptic producer epoch");
    for(unsigned hand=0;hand<2;++hand)
        require(extension->hands[hand].durationNs.load()==50'000'000&&focus->requestTags[hand].load()==
            ((uint64_t(extension->hands[hand].seq.load())<<32)|halliday::focus::generation(focus)),
            "fresh haptic generation is tied to the exact complete mailbox sequence");
    require(load<PFN_xrStopHapticFeedback>("xrStopHapticFeedback")(session,&output)==XR_SUCCESS,"finish rapid focus output fixture");
    const uint32_t paused[2]{extension->hands[0].seq.load(),extension->hands[1].seq.load()};
    header->dashboard.store(1);
    require(play() == XR_SESSION_NOT_FOCUSED && extension->hands[0].seq.load() == paused[0] && extension->hands[1].seq.load() == paused[1],
        "dashboard output stays suppressed without changing mailbox");
    header->dashboard.store(0); synchronize();
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(aggregate) == XR_SUCCESS &&
        load<PFN_xrDestroySpace>("xrDestroySpace")(left) == XR_SUCCESS &&
        load<PFN_xrDestroySpace>("xrDestroySpace")(offsetLeft) == XR_SUCCESS,"destroy compatibility spaces");
    std::puts("INPUT PASS: Simple/Touch profile mapping, confidence separation, stable NULL source, head independence and real two-hand haptic mailbox/cancellation");
}
inline void simpleOnly(const XrSessionCreateInfo& sessionInfo,halliday::Header* header) {
    XrSession session = XR_NULL_HANDLE;
    require(load<PFN_xrCreateSession>("xrCreateSession")(gInstance,&sessionInfo,&session) == XR_SUCCESS,"create Simple-only session");
    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    std::strcpy(setInfo.actionSetName,"simple_only"); std::strcpy(setInfo.localizedActionSetName,"Simple-only controls");
    XrActionSet set = XR_NULL_HANDLE;
    require(load<PFN_xrCreateActionSet>("xrCreateActionSet")(gInstance,&setInfo,&set) == XR_SUCCESS,"create Simple-only action set");
    const auto actions = create(set); suggestSimple(actions);
    XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO}; attach.countActionSets = 1; attach.actionSets = &set;
    require(load<PFN_xrAttachSessionActionSets>("xrAttachSessionActionSets")(session,&attach) == XR_SUCCESS,"attach Simple-only controls");
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(load<PFN_xrBeginSession>("xrBeginSession")(session,&begin) == XR_SUCCESS,"begin Simple-only session");
    XrReferenceSpaceCreateInfo space{XR_TYPE_REFERENCE_SPACE_CREATE_INFO}; space.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE; space.poseInReferenceSpace.orientation.w = 1;
    XrSpace stage = XR_NULL_HANDLE; require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&space,&stage) == XR_SUCCESS,"create Simple-only world space");
    lifecycle_checks::states(session);
    auto* extension = halliday::haptics::extension(header);
    XrHapticActionInfo output{XR_TYPE_HAPTIC_ACTION_INFO}; output.action = actions.haptic;
    XrHapticVibration pulse{XR_TYPE_HAPTIC_VIBRATION}; pulse.duration = 50'000'000; pulse.amplitude = .5f;
    require(extension && load<PFN_xrApplyHapticFeedback>("xrApplyHapticFeedback")(session,&output,reinterpret_cast<const XrHapticBaseHeader*>(&pulse)) == XR_SUCCESS &&
        extension->hands[0].seq.load() == 2 && extension->hands[1].seq.load() == 2,
        "attached focused output starts before the first xrSyncActions call");
    require(load<PFN_xrStopHapticFeedback>("xrStopHapticFeedback")(session,&output) == XR_SUCCESS,"stop immediate output before first input synchronization");
    run(session,set,actions,stage,1,header,true);
    require(load<PFN_xrRequestExitSession>("xrRequestExitSession")(session) == XR_SUCCESS,"request normal exit while SDK session object remains alive");
    lifecycle_checks::states(session);
    require(load<PFN_xrEndSession>("xrEndSession")(session) == XR_SUCCESS && !header->initialized.load() &&
        extension->clientEpoch.load() == 0,"EndSession releases public producer and haptics before optional later DestroySession");
    const auto endedHeartbeat = header->heartbeat.load(); Sleep(250);
    require(header->heartbeat.load() == endedHeartbeat,"ended SDK session cannot keep public producer heartbeat alive");
    // A producer in the same Wine process may connect before the old game
    // releases its SDK handle. Old teardown must not clobber its registration.
    header->clientPid = GetCurrentProcessId(); header->initialized.store(1);
    const uint64_t replacementEpoch = 0x123456789ULL; extension->clientEpoch.store(replacementEpoch);
    require(load<PFN_xrDestroySession>("xrDestroySession")(session) == XR_SUCCESS && header->initialized.load() == 1 &&
        extension->clientEpoch.load() == replacementEpoch,"late DestroySession preserves a newer same-PID public producer generation");
    header->initialized.store(0); extension->clientEpoch.store(0);
    std::puts("INPUT PASS: Simple-only clients receive working input instead of discarded suggestions");
}
} // namespace input_checks
