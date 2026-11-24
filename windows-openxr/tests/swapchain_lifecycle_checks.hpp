// Real graphics allocation + OpenXR image lifecycle checks, API-independent.
#pragma once
#include <openxr/openxr.h>
#include <array>
#include <cstdio>
#include <cstdlib>
#include "swapchain_capability_checks.hpp"

namespace swapchain_lifecycle_checks {
inline void require(bool value,const char* message) {
    if (!value) { std::fprintf(stderr,"FAIL: SWAPCHAIN %s\n",message); std::exit(1); }
}
template<class T> T load(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,const char* name) {
    PFN_xrVoidFunction function=nullptr;
    require(gipa(instance,name,&function)==XR_SUCCESS&&function,name);
    return reinterpret_cast<T>(function);
}
inline void run(PFN_xrGetInstanceProcAddr gipa,XrInstance instance,XrSession session) {
    const auto create=load<PFN_xrCreateSwapchain>(gipa,instance,"xrCreateSwapchain");
    const auto destroy=load<PFN_xrDestroySwapchain>(gipa,instance,"xrDestroySwapchain");
    const auto images=load<PFN_xrEnumerateSwapchainImages>(gipa,instance,"xrEnumerateSwapchainImages");
    const auto acquire=load<PFN_xrAcquireSwapchainImage>(gipa,instance,"xrAcquireSwapchainImage");
    const auto wait=load<PFN_xrWaitSwapchainImage>(gipa,instance,"xrWaitSwapchainImage");
    const auto release=load<PFN_xrReleaseSwapchainImage>(gipa,instance,"xrReleaseSwapchainImage");
    std::array<int64_t,4> formats{};uint32_t count=0;
    require(load<PFN_xrEnumerateSwapchainFormats>(gipa,instance,"xrEnumerateSwapchainFormats")(
        session,formats.size(),&count,formats.data())==XR_SUCCESS&&count>0,"query native graphics formats");
    swapchain_capability_checks::run(create,destroy,session,formats[0]);
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.createFlags=XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT;
    info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format=formats[0];info.sampleCount=1;info.width=8;info.height=8;
    info.faceCount=1;info.arraySize=1;info.mipCount=1;
    std::array<XrSwapchain,8> cached{};
    XrSwapchainImageWaitInfo waiting{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};waiting.timeout=0;
    for (auto& chain:cached) {
        require(create(session,&info,&chain)==XR_SUCCESS,"eight independent static UI textures coexist with projection");
        require(images(chain,0,&count,nullptr)==XR_SUCCESS&&count==1,"static image allocates exactly one texture");
        uint32_t index=99;
        require(acquire(chain,nullptr,&index)==XR_SUCCESS&&index==0,"static image first acquisition");
        require(acquire(chain,nullptr,&index)==XR_ERROR_CALL_ORDER_INVALID,"static image cannot be acquired twice before release");
        require(release(chain,nullptr)==XR_ERROR_CALL_ORDER_INVALID,"release requires a successful wait");
        require(wait(chain,&waiting)==XR_SUCCESS,"wait on available static image");
        require(wait(chain,&waiting)==XR_ERROR_CALL_ORDER_INVALID,"wait cannot advance without release");
        require(release(chain,nullptr)==XR_SUCCESS,"release static image once");
        require(acquire(chain,nullptr,&index)==XR_ERROR_CALL_ORDER_INVALID,"static image cannot be acquired again after release");
        require(release(chain,nullptr)==XR_ERROR_CALL_ORDER_INVALID,"static release cannot be repeated");
    }
    for (auto chain:cached) require(destroy(chain)==XR_SUCCESS,"destroy cached UI texture");
    XrSwapchain chain=XR_NULL_HANDLE;
    info.createFlags=XR_SWAPCHAIN_CREATE_PROTECTED_CONTENT_BIT;
    require(create(session,&info,&chain)==XR_ERROR_FEATURE_UNSUPPORTED&&chain==XR_NULL_HANDLE,
        "protected CPU-readable content fails explicitly instead of silently losing protection");
    info.createFlags=0;
    require(create(session,&info,&chain)==XR_SUCCESS,"ordinary triple-buffered swapchain remains supported");
    require(images(chain,0,&count,nullptr)==XR_SUCCESS&&count==3,"dynamic swapchain still exposes three images");
    std::array<uint32_t,3> indices{};
    for (auto& index:indices) require(acquire(chain,nullptr,&index)==XR_SUCCESS,"acquire three dynamic images ahead");
    require(indices[0]!=indices[1]&&indices[1]!=indices[2]&&indices[0]!=indices[2],"acquired indices are unique");
    for (unsigned index=0;index<3;++index) {
        require(wait(chain,&waiting)==XR_SUCCESS,"wait oldest outstanding dynamic image");
        require(wait(chain,&waiting)==XR_ERROR_CALL_ORDER_INVALID,"only one dynamic image may be waited before release");
        require(release(chain,nullptr)==XR_SUCCESS,"release FIFO writable image");
    }
    uint32_t index=99;
    require(acquire(chain,nullptr,&index)==XR_SUCCESS&&index==indices[0],"dynamic pool reuses first image after complete FIFO cycle");
    require(wait(chain,&waiting)==XR_SUCCESS&&release(chain,nullptr)==XR_SUCCESS,"dynamic pool remains writable after invalid-call recovery");
    require(destroy(chain)==XR_SUCCESS,"destroy ordinary lifecycle fixture");
    std::puts("SWAPCHAIN PASS: eight static UI textures, one image/one acquisition each; protected rejection; dynamic acquire-ahead FIFO and recovery");
}
}
