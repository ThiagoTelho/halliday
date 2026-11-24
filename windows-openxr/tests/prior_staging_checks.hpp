// Public OpenXR + actual D3D11 acceptance for the common capture path.
// Used only by HALLIDAY_CHECK_PRIOR_STAGING_ONLY in the disposable fixture.
#pragma once
#include <array>
#include <vector>
namespace prior_staging_checks {
inline std::array<uint8_t,4> pixel(unsigned frame,unsigned eye,unsigned x,unsigned y) {
    return {uint8_t(frame*23+x*3+eye*71),uint8_t(y*17+frame*5),
            uint8_t(255-x*7-frame*11-eye*13),uint8_t(128+x+y+frame)};
}
inline void run(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session,XrSpace stage,
                ID3D11DeviceContext* context,halliday::Header* header) {
    auto command=[&](const char* name){PFN_xrVoidFunction fn{};
        require(gipa(instance,name,&fn)==XR_SUCCESS&&fn,name);return fn;};
    const auto create=reinterpret_cast<PFN_xrCreateSwapchain>(command("xrCreateSwapchain"));
    const auto enumerate=reinterpret_cast<PFN_xrEnumerateSwapchainImages>(command("xrEnumerateSwapchainImages"));
    const auto acquire=reinterpret_cast<PFN_xrAcquireSwapchainImage>(command("xrAcquireSwapchainImage"));
    const auto waitImage=reinterpret_cast<PFN_xrWaitSwapchainImage>(command("xrWaitSwapchainImage"));
    const auto release=reinterpret_cast<PFN_xrReleaseSwapchainImage>(command("xrReleaseSwapchainImage"));
    const auto wait=reinterpret_cast<PFN_xrWaitFrame>(command("xrWaitFrame"));
    const auto begin=reinterpret_cast<PFN_xrBeginFrame>(command("xrBeginFrame"));
    const auto end=reinterpret_cast<PFN_xrEndFrame>(command("xrEndFrame"));
    const auto locate=reinterpret_cast<PFN_xrLocateViews>(command("xrLocateViews"));
    XrSwapchain chains[2]{};
    std::vector<XrSwapchainImageD3D11KHR> images[2];
    for(unsigned eye=0;eye<2;++eye) {
        XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        ci.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
        ci.format=eye?DXGI_FORMAT_B8G8R8A8_UNORM:DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
        ci.sampleCount=ci.faceCount=ci.mipCount=1;ci.width=80;ci.height=72;ci.arraySize=2;
        require(create(session,&ci,&chains[eye])==XR_SUCCESS,"create automatic mixed RGBA/BGRA stereo source");
        uint32_t count=0;require(enumerate(chains[eye],0,&count,nullptr)==XR_SUCCESS&&count==3,"automatic three source images");
        images[eye].assign(count,{XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR});
        require(enumerate(chains[eye],count,&count,reinterpret_cast<XrSwapchainImageBaseHeader*>(images[eye].data()))==XR_SUCCESS,
                "automatic actual D3D11 source texture handles");
    }
    struct Expected {XrCompositionLayerProjectionView views[2];unsigned number,width;};
    std::vector<Expected> expected;
    std::vector<uint8_t> source(80*72*4);
    unsigned publications=0,warmups=0;
    for(unsigned number=0;number<24;++number) {
        if(number==8)halliday::haptics::extension(header)->spaceEpoch.fetch_add(1);
        if(number==18) {halliday::focus::setDashboard(header,true);halliday::focus::setDashboard(header,false);}
        header->stateSeq.fetch_or(1);
        auto& head=header->state.head;
        head.position[0]=float(number)*.013f;head.position[1]=1.6f;head.position[2]=-.1f;
        head.orientation[0]=head.orientation[2]=0;head.orientation[1]=std::sin(number*.017f);
        head.orientation[3]=std::cos(number*.017f);head.stamp=100.0f+number;
        header->stateSeq.store((header->stateSeq.load()|1u)+1u);
        XrFrameState fs{XR_TYPE_FRAME_STATE};
        require(wait(session,nullptr,&fs)==XR_SUCCESS&&fs.shouldRender&&begin(session,nullptr)==XR_SUCCESS,"automatic active frame");
        XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};li.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        li.space=stage;li.displayTime=fs.predictedDisplayTime;
        XrViewState vs{XR_TYPE_VIEW_STATE};XrView views[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}};uint32_t viewCount=0;
        require(locate(session,&li,&vs,2,&viewCount,views)==XR_SUCCESS&&viewCount==2,"automatic historical rendered pose");
        Expected current{};current.number=number;current.width=number>=20?60:64;
        for(unsigned eye=0;eye<2;++eye) {
            uint32_t index=0;require(acquire(chains[eye],nullptr,&index)==XR_SUCCESS,"automatic acquire");
            XrSwapchainImageWaitInfo wi{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};wi.timeout=XR_INFINITE_DURATION;
            require(waitImage(chains[eye],&wi)==XR_SUCCESS,"automatic wait image");
            for(unsigned y=0;y<72;++y)for(unsigned x=0;x<80;++x) {
                auto value=pixel(number,eye,x,y);if(eye)std::swap(value[0],value[2]);
                std::memcpy(source.data()+(y*80+x)*4,value.data(),4);
            }
            context->UpdateSubresource(images[eye][index].texture,D3D11CalcSubresource(0,eye,1),nullptr,source.data(),80*4,80*72*4);
            require(release(chains[eye],nullptr)==XR_SUCCESS,"automatic release rendered image");
            auto& v=current.views[eye];v.type=XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
            v.pose=views[eye].pose;v.fov=views[eye].fov;
            const float zoom=.002f*number*(eye+1);
            v.fov.angleLeft+=zoom;v.fov.angleRight-=zoom;
            v.fov.angleUp-=zoom*.5f;v.fov.angleDown+=zoom*.5f;
            if(number>=4&&eye==0)std::swap(v.fov.angleLeft,v.fov.angleRight);
            if(number>=4&&eye==1)std::swap(v.fov.angleUp,v.fov.angleDown);
            v.subImage={chains[eye],{{8,4},{int32_t(current.width),64}},eye};
        }
        expected.push_back(current);
        XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        projection.space=stage;projection.viewCount=2;projection.views=current.views;
        XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};quad.space=stage;
        quad.eyeVisibility=XR_EYE_VISIBILITY_BOTH;quad.pose.orientation.w=1;quad.pose.position={0,1.5f,-1};
        quad.size={.5f,.5f};quad.subImage=current.views[0].subImage;
        const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection),
            reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad)};
        XrFrameEndInfo ei{XR_TYPE_FRAME_END_INFO};ei.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        ei.displayTime=fs.predictedDisplayTime;ei.layerCount=number==15?0:number==12?2:1;ei.layers=layers;
        const auto before=header->clientFrames.load();const auto oldLatest=header->latest.load();
        require(end(session,&ei)==XR_SUCCESS,"automatic complete stereo/layer submission");
        const bool warm=(number==0||number==8||number==13||number==16||number==18||number==20);
        if(warm) {
            require(header->clientFrames.load()==before&&header->latest.load()==oldLatest,"warmup/reset publishes no invented or stale frame");
            ++warmups;continue;
        }
        require(header->clientFrames.load()==before+1,"one atomic complete pair per publication");++publications;
        const auto slot=header->latest.load();require(slot>0&&slot<=3,"automatic complete transport slot");
        const auto& frame=header->frames[slot-1];
        if(number==15) {require(frame.width==8&&frame.height==8&&!(frame.textureType&(1u<<16)),"empty-frame synchronous retirement");continue;}
        const auto& prior=expected[number==12?number:number-1];
        require(frame.width==prior.width&&frame.height==64&&!frame.bgra&&frame.pose.stamp==100.0f+prior.number,
                "exact selected current/prior head stamp/layout, including synchronous quad fallback");
        projection_checks::verify(header,prior.views);
        require(halliday::frameColorSpace(frame.textureType,0)==2&&halliday::frameColorSpace(frame.textureType,1)==1,
                "mixed native RGBA/BGRA preserves independent gamma tags");
        for(unsigned eye=0;eye<2;++eye) {
            const auto* pixels=reinterpret_cast<const uint8_t*>(header)+halliday::imageOffset(slot-1,eye);
            const bool flipX=prior.views[eye].fov.angleLeft>prior.views[eye].fov.angleRight;
            const bool flipY=prior.views[eye].fov.angleDown>prior.views[eye].fov.angleUp;
            for(unsigned y=0;y<64;++y)for(unsigned x=0;x<prior.width;++x) {
                const auto wanted=pixel(prior.number,eye,8+(flipX?prior.width-1-x:x),4+(flipY?63-y:y));
                require(std::memcmp(pixels+(y*prior.width+x)*4,wanted.data(),4)==0,
                        "actual GPU capture bytes match the exact older per-eye pose/FOV/crop frame");
            }
        }
        if(number==12)require(frame.textureType&(1u<<17),"quad transition uses current layer batch, never old projection pixels");
    }
    for(auto chain:chains)require(reinterpret_cast<PFN_xrDestroySwapchain>(command("xrDestroySwapchain"))(chain)==XR_SUCCESS,"destroy automatic source chain");
    std::printf("CHECK PASS: selected %s actual D3D11 %u publications, %u warmup/resets; exact bytes+head+continuously-animated-fullFOV/color, mixed orders, mirrors, recenter/focus/layout and quad/empty recovery\n",
        "PRIOR",publications,warmups);
}
} // namespace prior_staging_checks
