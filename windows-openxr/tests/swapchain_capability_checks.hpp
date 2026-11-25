// Public OpenXR capability boundaries. These calls are deliberately tiny and
// reject unsupported requests before allocating a graphics object.
#pragma once
#include <openxr/openxr.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace swapchain_capability_checks {
inline void check(bool ok,const char* message) {
    if(!ok){std::fprintf(stderr,"FAIL: SWAPCHAIN CAPABILITY %s\n",message);std::exit(1);}
}
inline void run(PFN_xrCreateSwapchain create,PFN_xrDestroySwapchain destroy,
                XrSession session,int64_t supportedFormat) {
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format=supportedFormat;info.sampleCount=info.width=info.height=info.faceCount=info.arraySize=info.mipCount=1;
    auto reject=[&](XrResult expected,const char* message) {
        XrSwapchain chain=reinterpret_cast<XrSwapchain>(uintptr_t(0x1234));
        const auto result=create(session,&info,&chain);
        if(result==XR_SUCCESS)destroy(chain); // Keep an old-version failure harmless.
        check(result==expected&&chain==XR_NULL_HANDLE,message);
    };
    // The API format is int64_t: narrowing it to DXGI/VkFormat first can turn
    // unsupported identifiers into apparently supported textures.
    info.format=supportedFormat+(int64_t(1)<<32);
    reject(XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED,"64-bit format must not alias its low32 bits");
    info.format=supportedFormat;
    info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|(uint64_t(1)<<48);
    reject(XR_ERROR_FEATURE_UNSUPPORTED,"unknown usage is not silently discarded");
    info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_INPUT_ATTACHMENT_BIT_KHR;
    reject(XR_ERROR_FEATURE_UNSUPPORTED,"unadvertised input-attachment usage is rejected");
    info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    reject(XR_ERROR_FEATURE_UNSUPPORTED,"unsupported depth usage is a feature error, not a format error");
    // Core permits usageFlags=0. It asks for no additional binding guarantees.
    info.usageFlags=0;XrSwapchain chain=XR_NULL_HANDLE;
    check(create(session,&info,&chain)==XR_SUCCESS&&chain!=XR_NULL_HANDLE,"zero usage flags are legal");
    check(destroy(chain)==XR_SUCCESS,"zero-usage resource cleans up");
    std::puts("SWAPCHAIN CAPABILITY PASS: full64-bit format identity, explicit unsupported usage, legal zero usage, recovery");
}
}
