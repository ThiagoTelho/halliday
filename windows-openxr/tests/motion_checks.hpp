#pragma once
#include "motion_bridge.hpp"
#include <array>
namespace motion_checks {
inline void run(XrSession session,XrAction action,const XrPath hands[2],XrSpace stage,halliday::Header* header) {
    const auto original=header->state;
    auto* metadata=reinterpret_cast<halliday::motion::Extension*>(reinterpret_cast<uint8_t*>(header)+halliday::motion::kOffset);
    metadata->version=halliday::motion::kVersion;metadata->magic=halliday::motion::kMagic;
    std::array<XrSpace,2> sources{};XrSpace offset=XR_NULL_HANDLE,view=XR_NULL_HANDLE;
    XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};info.action=action;info.poseInActionSpace.orientation.w=1;
    for(unsigned hand=0;hand<2;++hand){info.subactionPath=hands[hand];
        require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&sources[hand])==XR_SUCCESS,"create validity hand space");}
    info.subactionPath=hands[0];info.poseInActionSpace.position.x=.1f;
    require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&offset)==XR_SUCCESS,"create validity offset hand space");
    XrReferenceSpaceCreateInfo reference{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};reference.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_VIEW;reference.poseInReferenceSpace.orientation.w=1;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&reference,&view)==XR_SUCCESS,"create validity moving VIEW");
    const auto publish=[&](uint32_t bits,bool mismatch=false,bool legacy=false){
        const auto odd=header->stateSeq.load()|1;header->stateSeq.store(odd);
        header->state=original;header->state.head.valid=1;
        header->state.head.velocity[0]=.4f;header->state.head.angularVelocity[1]=.3f;
        for(unsigned hand=0;hand<2;++hand){auto& c=header->state.controllers[hand];c.connected=c.pose.valid=1;
            c.pose.velocity[0]=hand?-.7f:1.1f;c.pose.angularVelocity[2]=hand?-.2f:2.f;}
        metadata->mask.store(bits);metadata->flags.store(legacy?0:halliday::motion::kExplicit);
        metadata->stateSequence.store(odd+1+(mismatch?2:0));header->stateSeq.store(odd+1,std::memory_order_release);
        return lifecycle_checks::nextSampleTime(session);
    };
    const auto locate=[&](XrSpace source,XrSpace base,XrTime time){
        XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY};XrSpaceLocation result{XR_TYPE_SPACE_LOCATION};result.next=&velocity;
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(source,base,time,&result)==XR_SUCCESS&&
            (result.locationFlags&XR_SPACE_LOCATION_POSITION_VALID_BIT),"unknown motion preserves valid pose");return velocity;
    };
    constexpr auto linear=XR_SPACE_VELOCITY_LINEAR_VALID_BIT,angular=XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
    XrTime last=0;
    for(uint32_t bits:{0u,1u,2u,3u,4u,8u,12u,16u,32u,48u,63u}){
        last=publish(bits);
        const XrSpace devices[]{view,sources[0],sources[1]};
        for(unsigned device=0;device<3;++device){const auto mask=(bits>>(device*2))&3;
            const XrSpaceVelocityFlags expected=((mask&1)?linear:0)|((mask&2)?angular:0);
            const auto actual=locate(devices[device],stage,last);
            if(actual.velocityFlags!=expected)std::fprintf(stderr,"MOTION device%u mask%u expected%llu actual%llu\n",device,bits,(unsigned long long)expected,(unsigned long long)actual.velocityFlags);
            require(actual.velocityFlags==expected,"component validity is independent for head and each hand");}
        const auto lever=locate(offset,stage,last);
        require(bool(lever.velocityFlags&linear)==((bits&12)==12),"offset point additionally needs angular motion");
        const auto relative=locate(sources[0],view,last);
        require(bool(relative.velocityFlags&linear)==((bits&7)==7)&&bool(relative.velocityFlags&angular)==((bits&10)==10),
            "relative motion respects moving VIEW base dependencies");
        const auto own=locate(offset,sources[0],last);
        require(own.velocityFlags==(linear|angular)&&own.linearVelocity.x==0&&own.angularVelocity.z==0,
            "same rigid entity has known zero relative velocity without measured components");
    }
    (void)publish(0);
    require(locate(sources[0],stage,last).velocityFlags==(linear|angular),"cached timestamp retains its original validity mask");
    require(locate(sources[0],stage,publish(63,true)).velocityFlags==0,"mismatched explicit state tag cannot become legacy validity");
    require(locate(sources[0],stage,publish(0,false,true)).velocityFlags==(linear|angular),"legacy producer preserves original all-known contract");
    header->stateSeq.fetch_add(1);header->state=original;metadata->flags.store(0);header->stateSeq.fetch_add(1);
    (void)lifecycle_checks::nextSampleTime(session);
    for(auto source:sources)require(load<PFN_xrDestroySpace>("xrDestroySpace")(source)==XR_SUCCESS,"destroy validity hand space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(offset)==XR_SUCCESS&&load<PFN_xrDestroySpace>("xrDestroySpace")(view)==XR_SUCCESS,"destroy validity offset/view spaces");
    std::puts("MOTION PASS: explicit head/left/right component validity, moving/offset bases, same-entity zero, historical coherence, mismatched tags and legacy fallback");
}
}
