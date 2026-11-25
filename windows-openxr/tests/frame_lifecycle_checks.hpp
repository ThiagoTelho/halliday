#pragma once
#include <openxr/openxr.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <future>
namespace frame_lifecycle_checks {
inline void require(bool value,const char* reason){if(!value){std::fprintf(stderr,"FAIL: FRAME %s\n",reason);std::exit(1);}}
template<class T>T load(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,const char* name){
    PFN_xrVoidFunction fn=nullptr;require(gipa(instance,name,&fn)==XR_SUCCESS&&fn,name);return reinterpret_cast<T>(fn);
}
inline void run(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session){
    const auto wait=load<PFN_xrWaitFrame>(gipa,instance,"xrWaitFrame");
    const auto begin=load<PFN_xrBeginFrame>(gipa,instance,"xrBeginFrame");
    const auto end=load<PFN_xrEndFrame>(gipa,instance,"xrEndFrame");
    auto waitNext=[&]{XrFrameState frame{XR_TYPE_FRAME_STATE};require(wait(session,nullptr,&frame)==XR_SUCCESS,"wait next frame");return frame;};
    auto finish=[&](const XrFrameState& frame){XrFrameEndInfo info{XR_TYPE_FRAME_END_INFO};info.displayTime=frame.predictedDisplayTime;
        info.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;require(end(session,&info)==XR_SUCCESS,"end empty owned frame");};
    auto first=waitNext();require(begin(session,nullptr)==XR_SUCCESS,"begin first pipelined frame");
    const auto second=waitNext();require(second.predictedDisplayTime>first.predictedDisplayTime,"pipelined prediction advances");
    require(begin(session,nullptr)==XR_FRAME_DISCARDED,"new Begin discards unfinished older frame");
    require(begin(session,nullptr)==XR_ERROR_CALL_ORDER_INVALID,"Begin cannot reuse consumed wait token");finish(second);
    auto third=waitNext();std::promise<void> entered;auto enteredFuture=entered.get_future();
    auto pending=std::async(std::launch::async,[&]{entered.set_value();XrFrameState frame{XR_TYPE_FRAME_STATE};
        const auto result=wait(session,nullptr,&frame);return std::make_pair(result,frame);});
    enteredFuture.wait();require(pending.wait_for(std::chrono::milliseconds(300))==std::future_status::timeout,
        "next Wait stays blocked until Begin, including past the host budget timeout");
    require(begin(session,nullptr)==XR_SUCCESS,"Begin proceeds while other thread waits");
    require(pending.wait_for(std::chrono::seconds(2))==std::future_status::ready,"next Wait unblocks after Begin");
    auto next=pending.get();require(next.first==XR_SUCCESS&&next.second.predictedDisplayTime>third.predictedDisplayTime,"blocked Wait owns a fresh prediction");
    finish(third);require(begin(session,nullptr)==XR_SUCCESS,"begin pipelined frame after prior End");finish(next.second);
    XrFrameEndInfo invalid{XR_TYPE_FRAME_END_INFO};invalid.displayTime=next.second.predictedDisplayTime;invalid.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    require(end(session,&invalid)==XR_ERROR_CALL_ORDER_INVALID,"End cannot consume another frame twice");
    std::puts("FRAME PASS: pipelined Wait/Begin/End; discarded unfinished frame; blocked next Wait; no duplicate Begin/End");
}
}
