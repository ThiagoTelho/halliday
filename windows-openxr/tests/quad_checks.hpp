// API-independent pixel/metadata checks using already rendered, released images.
#pragma once
#include "panel_bridge.hpp"
#include "swapchain_lifecycle_checks.hpp"
#include "frame_lifecycle_checks.hpp"
#include <openxr/openxr.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace quad_checks {
inline void require(bool value,const char* message){if(!value){std::fprintf(stderr,"FAIL: QUAD %s\n",message);std::exit(1);}}
template<class T> T load(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,const char* name){
    PFN_xrVoidFunction function=nullptr;require(gipa(instance,name,&function)==XR_SUCCESS&&function,name);return reinterpret_cast<T>(function);
}
inline halliday::panels::Panel record(const halliday::panels::Batch& batch,size_t index){
    std::array<uint32_t,26> words{};for(size_t i=0;i<words.size();++i)words[i]=batch.panels[index][i].load();
    halliday::panels::Panel result{};std::memcpy(&result,words.data(),sizeof(result));return result;
}
inline void run(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session,halliday::Header* header,
    const XrCompositionLayerProjection& submittedProjection,const XrSwapchainSubImage& source0,
    const XrSwapchainSubImage& source1,const std::array<uint8_t,4>& pixel0,const std::array<uint8_t,4>& pixel1){
    swapchain_lifecycle_checks::run(gipa,instance,session);
    frame_lifecycle_checks::run(gipa,instance,session);
    using namespace halliday::panels;
    if(!extension(header)){auto* ext=new(reinterpret_cast<uint8_t*>(header)+kOffset)Extension{};ext->magic=kMagic;ext->version=kVersion;}
    auto* ext=extension(header);require(ext,"private host optional quad transport initialized");
    const auto createSpace=load<PFN_xrCreateReferenceSpace>(gipa,instance,"xrCreateReferenceSpace");
    const auto wait=load<PFN_xrWaitFrame>(gipa,instance,"xrWaitFrame");
    const auto begin=load<PFN_xrBeginFrame>(gipa,instance,"xrBeginFrame");
    const auto end=load<PFN_xrEndFrame>(gipa,instance,"xrEndFrame");
    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};spaceInfo.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_VIEW;
    spaceInfo.poseInReferenceSpace.orientation.w=1;XrSpace view=XR_NULL_HANDLE;
    require(createSpace(session,&spaceInfo,&view)==XR_SUCCESS,"VIEW anchor space");
    XrCompositionLayerQuad quads[2]{{XR_TYPE_COMPOSITION_LAYER_QUAD},{XR_TYPE_COMPOSITION_LAYER_QUAD}};
    for(unsigned i=0;i<2;++i){auto& q=quads[i];q.space=i?view:submittedProjection.space;q.eyeVisibility=i?XR_EYE_VISIBILITY_RIGHT:XR_EYE_VISIBILITY_LEFT;
        q.layerFlags=i?0:(XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT|XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT);
        q.pose.orientation.w=1;q.pose.position={i?.1f:-.1f,.2f,-.8f};q.size={.4f,.3f};q.subImage=i?source1:source0;
        q.subImage.imageRect.extent={8,8};
    }
    auto projection=submittedProjection;
    projection.layerFlags=XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT|XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
    const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quads[0]),
        reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection),reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quads[1])};
    XrFrameEndInfo ending{XR_TYPE_FRAME_END_INFO};ending.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;ending.layerCount=3;ending.layers=layers;
    auto start=[&]{XrFrameState frame{XR_TYPE_FRAME_STATE};require(wait(session,nullptr,&frame)==XR_SUCCESS&&frame.shouldRender,"quad frame wait");
        require(begin(session,nullptr)==XR_SUCCESS,"quad frame begin");ending.displayTime=frame.predictedDisplayTime;};
    auto batch=[&]() -> Batch& {const auto latest=header->latest.load();require(latest>0&&latest<=halliday::kSlots,"published projection ticket");
        require(header->frames[latest-1].textureType&(1u<<17),"semantic quad/alpha/empty frame requires its exact layer batch");
        auto& b=ext->batches[latest-1];require(!(b.sequence.load()&1)&&b.frameIndex.load()==header->frames[latest-1].frameIndex,"batch tied to exact published slot/frame");
        auto* control=halliday::haptics::extension(header);require(control&&b.epoch.load()==control->clientEpoch.load(),"batch tied to current session epoch");return b;};
    // Exercise real wraparound without billions of frames: zero is reserved
    // for uninitialized metadata and must never become a committed sequence.
    for(auto& pending:ext->batches)pending.sequence.store(UINT32_MAX-1u);
    start();require(end(session,&ending)==XR_SUCCESS,"projection + underlay + overlay accepted");
    auto& b=batch();require(b.count.load()==2&&b.projectionOrder.load()==1&&b.projectionFlags.load()==3,
        "projection and quad declaration order/alpha flags");
    require(b.sequence.load()==2,"layer batch sequence wraps to nonzero committed2");
    require(header->frames[header->latest.load()-1].seeThrough==1,"alpha projection bypasses opaque-only image processing");
    for(unsigned i=0;i<2;++i){const auto p=record(b,i);auto* pic=picture(header,p.pictureIndex);
        require(p.order==(i?2u:0u)&&p.eyeVisibility==(i?2u:1u)&&p.anchor==i&&p.flags==(i?0u:3u),"eye visibility, VIEW/world anchor, alpha flags");
        require(p.colorSpace>0&&p.bgra==1&&pic->width.load()==8&&pic->height.load()==8&&
            p.pictureSequence==pic->sequence.load()&&!(p.pictureSequence&1u),"exact picture sequence/geometry/color metadata");
        const auto* bytes=reinterpret_cast<const uint8_t*>(header)+pictureOffset(p.pictureIndex);const auto& expected=i?pixel1:pixel0;
        for(size_t pixel=0;pixel<64;++pixel)for(size_t channel=0;channel<4;++channel)
            require(bytes[pixel*4+channel]==expected[channel],"exact cropped GPU UI pixels and contiguous BGRA rows");
        if(i)require(std::fabs(p.pose.position[1]-.2f)<.00001f,"VIEW quad retains local pose without head baked in");
    }
    // A peer without HLQP must not silently receive only part of an ordered,
    // transparent or projection-free frame. Each failure leaves its old frame.
    auto rejectMissingBatch=[&](const char* message) {
        start();const auto count=header->clientFrames.load();const auto latest=header->latest.load();
        const uint32_t magic=ext->magic;ext->magic=0;
        const auto result=end(session,&ending);ext->magic=magic;
        require(result==XR_ERROR_LAYER_INVALID&&header->clientFrames.load()==count&&header->latest.load()==latest,message);
        start();require(end(session,&ending)==XR_SUCCESS,"restored layer capability recovers the next frame");
    };
    rejectMissingBatch("quad+projection cannot degrade on an old host");
    const XrCompositionLayerBaseHeader* alphaOnly[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
    ending.layerCount=1;ending.layers=alphaOnly;
    rejectMissingBatch("transparent projection cannot lose alpha metadata on an old host");
    ending.layerCount=0;ending.layers=nullptr;
    start();const uint32_t savedMagic=ext->magic;ext->magic=0;
    const auto oldEmpty=end(session,&ending);ext->magic=savedMagic;
    require(oldEmpty==XR_SUCCESS,"legacy host still accepts a valid empty frame");
    const auto blackSlot=header->latest.load();const auto& black=header->frames[blackSlot-1];
    require(black.width==8&&black.height==8&&!(black.textureType&((1u<<17)|(1u<<16))),"old-host empty frame uses opaque legacy black ticket");
    for(unsigned eye=0;eye<2;++eye){const auto* pixels=reinterpret_cast<const uint8_t*>(header)+halliday::imageOffset(blackSlot-1,eye);
        for(size_t byte=0;byte<8*8*4;++byte)require(pixels[byte]==0,"old-host empty frame contains only black pixels");}
    ending.layerCount=3;ending.layers=layers;start();require(end(session,&ending)==XR_SUCCESS,"complete layers restored after old-peer probes");
    const auto before=header->clientFrames.load();const auto latest=header->latest.load();
    const auto pictureSeq=picture(header,0)->sequence.load();
    std::array<uint8_t,256> saved{};std::memcpy(saved.data(),reinterpret_cast<const uint8_t*>(header)+pictureOffset(0),saved.size());
    picture(header,0)->reading.store(1);start();require(end(session,&ending)==XR_SUCCESS,"busy host UI read drops frame without API failure");
    require(header->clientFrames.load()==before&&header->latest.load()==latest&&picture(header,0)->sequence.load()==pictureSeq&&
        !std::memcmp(saved.data(),reinterpret_cast<const uint8_t*>(header)+pictureOffset(0),saved.size()),"busy UI read preserves complete old frame and pixels");
    picture(header,0)->reading.store(0);start();require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==before+1,"next complete UI frame recovers");
    start();const auto beforeRecenter=header->clientFrames.load();
    auto* control=halliday::haptics::extension(header);require(control,"host reference epoch extension");
    control->spaceEpoch.fetch_add(1);
    require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==beforeRecenter,
        "recenter between BeginFrame/EndFrame retires old projection and quads");
    start();require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==beforeRecenter+1,
        "next WaitFrame/BeginFrame commits fresh reference epoch");
    XrFrameState waitingRecenter{XR_TYPE_FRAME_STATE};require(wait(session,nullptr,&waitingRecenter)==XR_SUCCESS,"wait frame before reference epoch changes");
    const auto beforeWaitRecenter=header->clientFrames.load();control->spaceEpoch.fetch_add(1);
    require(begin(session,nullptr)==XR_SUCCESS,"begin still owns the old WaitFrame reference epoch");ending.displayTime=waitingRecenter.predictedDisplayTime;
    require(end(session,&ending)==XR_SUCCESS&&header->clientFrames.load()==beforeWaitRecenter,
        "recenter between WaitFrame and BeginFrame must retire old-coordinate output");
    start();const auto frameBefore=header->clientFrames.load();const auto size=quads[0].size;quads[0].size.width=0;
    require(end(session,&ending)==XR_ERROR_VALIDATION_FAILURE&&header->clientFrames.load()==frameBefore,"invalid size publishes nothing");
    quads[0].size=size;const auto rect=quads[0].subImage.imageRect;quads[0].subImage.imageRect.offset.x=-1;
    require(end(session,&ending)==XR_ERROR_SWAPCHAIN_RECT_INVALID&&header->clientFrames.load()==frameBefore,"invalid crop publishes nothing");
    quads[0].subImage.imageRect=rect;require(end(session,&ending)==XR_SUCCESS,"corrected UI frame recovers after validation rejection");
    const XrCompositionLayerBaseHeader* only[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quads[1])};
    ending.layerCount=1;ending.layers=only;start();require(end(session,&ending)==XR_SUCCESS,"quad-only frame accepted");
    auto& onlyBatch=batch();require(onlyBatch.count.load()==1&&onlyBatch.projectionOrder.load()==kNone,"quad-only frame has no projection");
    require(!(header->frames[header->latest.load()-1].textureType&(1u<<16)),"quad-only frame does not require projection geometry");
    const auto& ticket=header->frames[header->latest.load()-1];require(ticket.width==8&&ticket.height==8,"quad-only frame uses small neutral ticket");
    XrCompositionLayerQuad eight[8];const XrCompositionLayerBaseHeader* full[8];
    for(unsigned i=0;i<8;++i){eight[i]=quads[i%2];full[i]=reinterpret_cast<const XrCompositionLayerBaseHeader*>(&eight[i]);}
    ending.layerCount=8;ending.layers=full;start();require(end(session,&ending)==XR_SUCCESS,"all eight quad image slots accepted");
    auto& fullBatch=batch();require(fullBatch.count.load()==8&&fullBatch.projectionOrder.load()==kNone,"all eight quad slots published atomically");
    ending.layerCount=0;ending.layers=nullptr;start();require(end(session,&ending)==XR_SUCCESS,"empty frame accepted");
    auto& empty=batch();require(empty.count.load()==0&&empty.projectionOrder.load()==kNone,"empty frame retires previous panels");
    require(load<PFN_xrDestroySpace>(gipa,instance,"xrDestroySpace")(view)==XR_SUCCESS,"destroy quad VIEW space");
    std::puts("CHECK PASS: QUAD exact GPU pixels/order/eyes/alpha/VIEW-world/slot-epoch; busy host read/drop/recover; recenter retires old frame; invalid size/crop; quad-only and empty frame");
}
}
