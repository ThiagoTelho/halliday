// Read-only test mirror of the public HLPG contract. No production geometry
// writer/reader is reused: submitted values are the oracle for transported data.
#pragma once
#include <openxr/openxr.h>
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <cstring>
#include <new>
#include "haptic_bridge.hpp"
#include "panel_bridge.hpp"
#include "source_timing_checks.hpp"
#ifdef XR_USE_GRAPHICS_API_VULKAN
#include "vulkan_counting_loader.hpp"
#endif

namespace projection_checks {
constexpr size_t offset=64256, recordBytes=112;
inline void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
inline void initialize(halliday::Header* header) {
    auto* words=reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(header)+offset);
    words[0]=0x47504c48;words[1]=1;words[2]=112;words[3]=3;
    auto* panels=new(reinterpret_cast<uint8_t*>(header)+halliday::panels::kOffset)halliday::panels::Extension{};
    panels->magic=halliday::panels::kMagic;panels->version=halliday::panels::kVersion;
    source_timing_checks::initialize(header);
}
inline void verify(halliday::Header* header,const XrCompositionLayerProjectionView source[2]) {
    const uint32_t slot=header->latest.load();require(slot>0&&slot<=3,"HLPG has a complete source frame");
    const auto& frame=header->frames[slot-1];require(frame.textureType&(1u<<16),"custom projection requires exact geometry metadata");
    const auto* bytes=reinterpret_cast<const uint8_t*>(header)+offset;
    auto word=[&](size_t n){uint32_t v;std::memcpy(&v,bytes+n,4);return v;};
    auto wide=[&](size_t n){uint64_t v;std::memcpy(&v,bytes+n,8);return v;};
    require(word(0)==0x47504c48&&word(4)==1&&word(8)==112&&word(12)==3,"HLPG capability record shape");
    const size_t at=16+(slot-1)*recordBytes;const auto sequence=word(at);
    require(sequence&&!(sequence&1)&&word(at+4)==1,"HLPG record fully committed");
    require(wide(at+8)==frame.frameIndex&&wide(at+16)==halliday::haptics::extension(header)->clientEpoch.load(),
            "HLPG matches exact source frame and producer epoch");
    for(unsigned eye=0;eye<2;++eye) {
        std::array<float,11> actual{};std::memcpy(actual.data(),bytes+at+24+eye*44,44);
        const auto& pose=source[eye].pose;const auto& f=source[eye].fov;
        const std::array<float,11> expected{pose.position.x,pose.position.y,pose.position.z,
            pose.orientation.x,pose.orientation.y,pose.orientation.z,pose.orientation.w,
            std::tan(std::min(f.angleLeft,f.angleRight)),std::tan(std::max(f.angleLeft,f.angleRight)),
            std::tan(std::max(f.angleUp,f.angleDown)),std::tan(std::min(f.angleUp,f.angleDown))};
        for(unsigned component=0;component<11;++component)
            require(std::fabs(actual[component]-expected[component])<2e-6f,"HLPG preserves each submitted camera/FOV exactly");
    }
    require(word(at)==sequence,"HLPG remained stable while inspected");
}
inline void absent(halliday::Header* header) {
    const auto slot=header->latest.load();require(slot&&slot<=3,"retirement has complete frame");
    require(!(header->frames[slot-1].textureType&(1u<<16)),"quad-only/empty/legacy frame does not declare projection geometry");
}
#if defined(XR_USE_GRAPHICS_API_D3D11) || defined(XR_USE_GRAPHICS_API_D3D12)
// D3D fixtures use their real released resources for both compatibility paths.
// Unlike the Vulkan counter test this asserts publication, not GPU submissions.
inline void oldPeerD3D(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session,
                      halliday::Header* header,const XrCompositionLayerProjection& original,XrFrameState& frame) {
    auto command=[&](const char* name) {
        PFN_xrVoidFunction fn{};require(gipa(instance,name,&fn)==XR_SUCCESS&&fn,name);return fn;
    };
    const auto wait=reinterpret_cast<PFN_xrWaitFrame>(command("xrWaitFrame"));
    const auto begin=reinterpret_cast<PFN_xrBeginFrame>(command("xrBeginFrame"));
    const auto end=reinterpret_cast<PFN_xrEndFrame>(command("xrEndFrame"));
    auto* magic=reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(header)+offset);
    const uint32_t saved=*magic;*magic=0;
    XrCompositionLayerProjectionView views[2]{original.views[0],original.views[1]};
    auto projection=original;projection.views=views;
    const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
    XrFrameEndInfo ending{XR_TYPE_FRAME_END_INFO};ending.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    ending.displayTime=frame.predictedDisplayTime;ending.layerCount=1;ending.layers=layers;
    const auto before=header->clientFrames.load();
    require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==before+1,"D3D default geometry works with old host");
    absent(header);
    require(!(header->frames[header->latest.load()-1].textureType&(1u<<17)),"ordinary opaque D3D projection keeps legacy layer path");
    require(wait(session,nullptr,&frame)==XR_SUCCESS&&begin(session,nullptr)==XR_SUCCESS,"next D3D old-host frame");
    const auto latest=header->latest.load();const auto index=header->frames[latest-1].frameIndex;
    views[1].fov.angleLeft*=.75f;ending.displayTime=frame.predictedDisplayTime;
    require(end(session,&ending)==XR_ERROR_LAYER_INVALID,"D3D custom geometry rejects without host capability");
    require(header->clientFrames.load()==before+1&&header->latest.load()==latest&&header->frames[latest-1].frameIndex==index,
            "D3D rejected custom geometry preserves last complete frame");
    *magic=saved;
    require(wait(session,nullptr,&frame)==XR_SUCCESS&&begin(session,nullptr)==XR_SUCCESS,"D3D geometry capability restoration recovers");
    std::puts("CHECK PASS: D3D old-host default compatibility; custom geometry rejected without partial publication; recovery");
}
#endif
#ifdef XR_USE_GRAPHICS_API_VULKAN
template<class T> T load(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,const char* name) {
    PFN_xrVoidFunction fn{};require(gipa(instance,name,&fn)==XR_SUCCESS&&fn,name);return reinterpret_cast<T>(fn);
}
// Runs before app-side pipelining introduces another WaitFrame token.
// Default cameras work with an old peer; unrepresentable cameras reject before
// GPU work and leave its last complete frame untouched.
inline uint64_t oldPeer(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session,
                       halliday::Header* header,const XrCompositionLayerProjection& original,XrFrameState& frame) {
    auto* magic=reinterpret_cast<uint32_t*>(reinterpret_cast<uint8_t*>(header)+offset);
    const uint32_t saved=*magic;*magic=0;
    const auto wait=load<PFN_xrWaitFrame>(gipa,instance,"xrWaitFrame");
    const auto begin=load<PFN_xrBeginFrame>(gipa,instance,"xrBeginFrame");
    const auto end=load<PFN_xrEndFrame>(gipa,instance,"xrEndFrame");
    XrCompositionLayerProjectionView views[2]{original.views[0],original.views[1]};
    auto projection=original;projection.views=views;
    const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
    XrFrameEndInfo ending{XR_TYPE_FRAME_END_INFO};ending.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    ending.displayTime=frame.predictedDisplayTime;ending.layerCount=1;ending.layers=layers;
    const auto before=header->clientFrames.load();
    require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==before+1,"default geometry remains usable on old peer");
    absent(header);
    require(!(header->frames[header->latest.load()-1].textureType&(1u<<17)),"ordinary opaque projection keeps legacy layer path");
    require(wait(session,nullptr,&frame)==XR_SUCCESS&&begin(session,nullptr)==XR_SUCCESS,"next frame after old peer default");
    views[1].fov.angleLeft*=0.75f;ending.displayTime=frame.predictedDisplayTime;
    const auto latest=header->latest.load();vulkan_counting::reset();
    require(end(session,&ending)==XR_ERROR_LAYER_INVALID,"custom FOV rejects honestly without host geometry capability");
    require(header->clientFrames.load()==before+1&&header->latest.load()==latest&&vulkan_counting::submissions==0,
            "old-peer custom geometry performs no GPU readback or partial publication");
    *magic=saved;
    require(wait(session,nullptr,&frame)==XR_SUCCESS&&begin(session,nullptr)==XR_SUCCESS,"fresh geometry-capable frame recovers");
    std::puts("CHECK PASS: default old-peer compatibility; custom geometry rejected before GPU work; capability restoration recovers");
    return 1;
}
#endif
}
