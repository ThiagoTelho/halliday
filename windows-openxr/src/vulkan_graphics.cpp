// Independent OpenXR Vulkan1/Vulkan2 front end. Runtime-created images use
// the application's device and queue; no Wine/provider patch is required.
#include "vulkan_backend.hpp"
#include <algorithm>
#include <cstring>
#include <string>
#include <unordered_map>

namespace {
SRWLOCK lock = SRWLOCK_INIT;
XrInstance requirements1 = XR_NULL_HANDLE, requirements2 = XR_NULL_HANDLE;
struct DeviceSelection { VkInstance instance{}; VkPhysicalDevice physical{}; PFN_vkGetInstanceProcAddr gipa{}; };
std::vector<DeviceSelection> selections;
struct CreatedDevice { VkDevice device{}; VkInstance instance{}; VkPhysicalDevice physical{}; std::vector<VkDeviceQueueCreateInfo> queues; };
std::vector<CreatedDevice> createdDevices;
struct PriorVulkanPair {
    basalt::PriorProjectionFrame frame{};
    std::array<basalt::VulkanSource,2> sources{};
    std::array<std::vector<uint8_t>,2> pixels{};
    std::array<HallidayReadbackRequest,2> reads{};
    uint32_t colors[2]{};
    bool valid=false;
};
struct PriorVulkanState { PriorVulkanPair pairs[2]; unsigned write=0; };
// Serialized by the same control lock as the synchronous capture path.
std::unordered_map<void*,PriorVulkanState> priorVulkan;
PFN_vkGetInstanceProcAddr loader() {
    static const auto gipa = [] {
        HMODULE module = LoadLibraryW(L"vulkan-1.dll");
        return module ? reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(module, "vkGetInstanceProcAddr")) : nullptr;
    }();
    return gipa;
}
XrResult validate(XrInstance instance, XrSystemId system, bool v2) {
    if (!basalt::isValidInstance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!basalt::isVulkanExtensionEnabled(instance, v2)) return XR_ERROR_FUNCTION_UNSUPPORTED;
    return system == basalt::kSystemId ? XR_SUCCESS : XR_ERROR_SYSTEM_INVALID;
}
XrResult requirement(XrInstance instance, XrSystemId system, XrGraphicsRequirementsVulkanKHR* out, bool v2) {
    const auto result = validate(instance, system, v2); if (XR_FAILED(result)) return result;
    if (!out || out->type != XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR) return XR_ERROR_VALIDATION_FAILURE;
    out->minApiVersionSupported = XR_MAKE_VERSION(1, 0, 0);
    out->maxApiVersionSupported = XR_MAKE_VERSION(1, 1, 0);
    AcquireSRWLockExclusive(&lock); (v2 ? requirements2 : requirements1) = instance; ReleaseSRWLockExclusive(&lock);
    return XR_SUCCESS;
}
void select(VkInstance instance, VkPhysicalDevice physical, PFN_vkGetInstanceProcAddr gipa) {
    for (auto& value : selections) if (value.instance == instance) { value = {instance,physical,gipa}; return; }
    selections.push_back({instance,physical,gipa});
}
XrResult extensions(XrInstance instance, XrSystemId system, uint32_t capacity, uint32_t* count, char* output) {
    const auto result = validate(instance, system, false); if (XR_FAILED(result)) return result;
    if (!count) return XR_ERROR_VALIDATION_FAILURE;
    // The Windows loader translates Vulkan to the installed Mac provider. The
    // runtime requires no additional provider-specific Vulkan extensions.
    *count = 1;
    if (!capacity) return XR_SUCCESS;
    if (!output) return XR_ERROR_VALIDATION_FAILURE;
    output[0] = '\0'; return XR_SUCCESS;
}
}
namespace basalt {
bool isVulkanRuntimeAvailable() { return loader() != nullptr; }
void resetVulkanInstance(XrInstance instance) {
    AcquireSRWLockExclusive(&lock);
    if (requirements1 == instance) requirements1 = XR_NULL_HANDLE;
    if (requirements2 == instance) requirements2 = XR_NULL_HANDLE;
    selections.clear(); createdDevices.clear(); ReleaseSRWLockExclusive(&lock);
}
XrResult XRAPI_CALL getVulkanRequirements(XrInstance i, XrSystemId s, XrGraphicsRequirementsVulkanKHR* r) { return requirement(i,s,r,false); }
XrResult XRAPI_CALL getVulkanRequirements2(XrInstance i, XrSystemId s, XrGraphicsRequirementsVulkan2KHR* r) { return requirement(i,s,r,true); }
XrResult XRAPI_CALL getVulkanInstanceExtensions(XrInstance i, XrSystemId s, uint32_t c, uint32_t* n, char* o) { return extensions(i,s,c,n,o); }
XrResult XRAPI_CALL getVulkanDeviceExtensions(XrInstance i, XrSystemId s, uint32_t c, uint32_t* n, char* o) { return extensions(i,s,c,n,o); }
XrResult XRAPI_CALL getVulkanGraphicsDevice(XrInstance i, XrSystemId system, VkInstance instance, VkPhysicalDevice* output) {
    const auto result=validate(i,system,false); if(XR_FAILED(result))return result;
    if(!output||!instance)return XR_ERROR_VALIDATION_FAILURE; *output=VK_NULL_HANDLE;
    auto gipa=loader(); if(!gipa)return XR_ERROR_RUNTIME_FAILURE;
    const auto physical=static_cast<VkPhysicalDevice>(hxvk_physical_device(reinterpret_cast<void*>(gipa),instance));
    if(!physical)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    AcquireSRWLockExclusive(&lock); select(instance,physical,gipa); ReleaseSRWLockExclusive(&lock);
    *output=physical; return XR_SUCCESS;
}
XrResult XRAPI_CALL getVulkanGraphicsDevice2(XrInstance i, const XrVulkanGraphicsDeviceGetInfoKHR* info, VkPhysicalDevice* output) {
    if(!info||info->type!=XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR)return XR_ERROR_VALIDATION_FAILURE;
    const auto result=validate(i,info->systemId,true); if(XR_FAILED(result))return result;
    if(!output||!info->vulkanInstance)return XR_ERROR_VALIDATION_FAILURE; *output=VK_NULL_HANDLE;
    AcquireSRWLockShared(&lock); PFN_vkGetInstanceProcAddr gipa=loader();
    for(const auto& selection:selections)if(selection.instance==info->vulkanInstance)gipa=selection.gipa;
    ReleaseSRWLockShared(&lock);
    const auto physical=static_cast<VkPhysicalDevice>(hxvk_physical_device(reinterpret_cast<void*>(gipa),info->vulkanInstance));
    if(!physical)return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    AcquireSRWLockExclusive(&lock); select(info->vulkanInstance,physical,gipa); ReleaseSRWLockExclusive(&lock);
    *output=physical; return XR_SUCCESS;
}
XrResult XRAPI_CALL createVulkanInstance(XrInstance i,const XrVulkanInstanceCreateInfoKHR* info,VkInstance* output,VkResult* result) {
    if(!info||info->type!=XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR||info->createFlags||!output||!result||
        !info->pfnGetInstanceProcAddr||!info->vulkanCreateInfo||info->vulkanCreateInfo->sType!=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;
    *output=VK_NULL_HANDLE;*result=VK_ERROR_INITIALIZATION_FAILED;
    const auto valid=validate(i,info->systemId,true);if(XR_FAILED(valid))return valid;
    void* raw=nullptr; *result=VkResult(hxvk_create_instance(reinterpret_cast<void*>(info->pfnGetInstanceProcAddr),info->vulkanCreateInfo,info->vulkanAllocator,&raw));
    *output=static_cast<VkInstance>(raw);
    if(*result==VK_SUCCESS){AcquireSRWLockExclusive(&lock);select(*output,VK_NULL_HANDLE,info->pfnGetInstanceProcAddr);ReleaseSRWLockExclusive(&lock);}
    return XR_SUCCESS;
}
XrResult XRAPI_CALL createVulkanDevice(XrInstance i,const XrVulkanDeviceCreateInfoKHR* info,VkDevice* output,VkResult* result) {
    if(!info||info->type!=XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR||info->createFlags||!output||!result||
        !info->pfnGetInstanceProcAddr||!info->vulkanCreateInfo||info->vulkanCreateInfo->sType!=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO)return XR_ERROR_VALIDATION_FAILURE;
    *output=VK_NULL_HANDLE;*result=VK_ERROR_INITIALIZATION_FAILED;
    const auto valid=validate(i,info->systemId,true);if(XR_FAILED(valid))return valid;
    AcquireSRWLockExclusive(&lock);
    DeviceSelection selected{};for(const auto& s:selections)if(s.physical==info->vulkanPhysicalDevice)selected=s;
    if(!selected.instance){ReleaseSRWLockExclusive(&lock);return XR_ERROR_GRAPHICS_DEVICE_INVALID;}
    selected.gipa=info->pfnGetInstanceProcAddr;
    void* raw=nullptr;*result=VkResult(hxvk_create_device(reinterpret_cast<void*>(selected.gipa),selected.instance,selected.physical,info->vulkanCreateInfo,info->vulkanAllocator,&raw));
    *output=static_cast<VkDevice>(raw);
    if(*result==VK_SUCCESS){
        CreatedDevice device{*output,selected.instance,selected.physical,{}};
        for(uint32_t q=0;q<info->vulkanCreateInfo->queueCreateInfoCount;++q){auto queue=info->vulkanCreateInfo->pQueueCreateInfos[q];queue.pQueuePriorities=nullptr;queue.pNext=nullptr;device.queues.push_back(queue);}
        createdDevices.push_back(std::move(device));
    }
    ReleaseSRWLockExclusive(&lock);return XR_SUCCESS;
}
XrResult makeVulkanContext(XrInstance i,const XrGraphicsBindingVulkanKHR& binding,void** output) {
    *output=nullptr;
    if(!isVulkanExtensionEnabled(i)&&!isVulkanExtensionEnabled(i,true))return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    AcquireSRWLockShared(&lock);
    const bool legacy=isVulkanExtensionEnabled(i)&&requirements1==i;
    if(!legacy&&requirements2!=i){ReleaseSRWLockShared(&lock);return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;}
    DeviceSelection selected{};for(const auto& s:selections)if(s.instance==binding.instance&&s.physical==binding.physicalDevice)selected=s;
    bool queueAllowed=legacy;
    for(const auto& device:createdDevices)if(device.device==binding.device&&device.instance==binding.instance&&device.physical==binding.physicalDevice){
        queueAllowed=false;for(const auto& queue:device.queues)if(queue.queueFamilyIndex==binding.queueFamilyIndex&&binding.queueIndex<queue.queueCount&&!queue.flags)queueAllowed=true;
        break;
    }
    if(!selected.gipa||!binding.device||!queueAllowed){ReleaseSRWLockShared(&lock);return XR_ERROR_GRAPHICS_DEVICE_INVALID;}
    *output=hxvk_context(reinterpret_cast<void*>(selected.gipa),binding.instance,binding.physicalDevice,binding.device,binding.queueFamilyIndex,binding.queueIndex);
    ReleaseSRWLockShared(&lock);return *output?XR_SUCCESS:XR_ERROR_GRAPHICS_DEVICE_INVALID;
}
bool prepareVulkanFrame(void* context,const ControlFrameView views[2],ReadbackImage images[2],std::array<std::vector<uint8_t>,2>& pixels){
    std::array<VulkanSource,2> sources;
    std::array<HallidayReadbackRequest,2> reads{};
    for(unsigned eye=0;eye<2;++eye){
        auto& source=sources[eye];source=swapchainVulkanImage(views[eye]);if(!source.image)return false;
        const auto& r=views[eye].rect;
        if(r.offset.x<0||r.offset.y<0||r.extent.width<=0||r.extent.height<=0)return false;
        const auto w=uint32_t(r.extent.width),h=uint32_t(r.extent.height);
        pixels[eye].resize(size_t(w)*h*4);
        reads[eye]={source.image.get(),views[eye].imageArrayIndex,uint32_t(r.offset.x),uint32_t(r.offset.y),w,h,pixels[eye].data()};
    }
    if(hxvk_read_batch(context,reads.data(),2))return false;
    for(unsigned eye=0;eye<2;++eye){
        const auto& source=sources[eye];const auto w=reads[eye].width,h=reads[eye].height;
        const bool bgra=source.format==VK_FORMAT_B8G8R8A8_UNORM||source.format==VK_FORMAT_B8G8R8A8_SRGB;
        images[eye]={pixels[eye].data(),w,h,w*4,bgra?DXGI_FORMAT_B8G8R8A8_UNORM:DXGI_FORMAT_R8G8B8A8_UNORM,swapchainColourSpace(views[eye])};
    }
    return true;
}
bool resetVulkanPriorReadback(void* context) {
    if(!context)return true;
    // Keep source-image references and transfer buffers alive on a queue error.
    if(hxvk_reset_prior(context))return false;
    priorVulkan.erase(context);return true;
}
void abandonVulkanPriorReadback(void* context) {
    if(!context)return;
    hxvk_abandon_context(context);
    priorVulkan.erase(context);
}
void finishVulkanPriorFrame(void*) {
    // Host bytes are owned by the paired vectors; GPU memory is already unmapped.
}
PriorStagingResult prepareVulkanPriorFrame(void* context,const PriorProjectionFrame& frame,
                                         ReadbackImage images[2],PriorProjectionFrame* captured) {
    if(!context||!images||!captured)return PriorStagingResult::Failed;
    const auto old=priorVulkan.find(context);
    if(old!=priorVulkan.end()) {
        const auto& pending=old->second.pairs[1-old->second.write];
        if(pending.valid&&!samePriorProjectionLayout(pending.frame,frame)&&!resetVulkanPriorReadback(context))
            return PriorStagingResult::Failed;
    }
    auto& state=priorVulkan[context];
    // Prepare transactionally. A poisoned/unfinished slot must retain its old
    // image references and host bytes until reset can prove GPU retirement.
    PriorVulkanPair next;
    auto& previousWrite=state.pairs[state.write];
    std::array<bool,2> reusePixels{};
    for(unsigned eye=0;eye<2;++eye) {
        const auto& view=frame.views[eye];const auto& r=view.rect;
        if(r.offset.x<0||r.offset.y<0||r.extent.width<=0||r.extent.height<=0||
           uint32_t(r.extent.width)>kMaxViewWidth||uint32_t(r.extent.height)>kMaxViewHeight) {
            resetVulkanPriorReadback(context);return PriorStagingResult::Failed;
        }
        next.sources[eye]=swapchainVulkanImage(view);
        if(!next.sources[eye].image){resetVulkanPriorReadback(context);return PriorStagingResult::Failed;}
        const auto w=uint32_t(r.extent.width),h=uint32_t(r.extent.height);
        const size_t bytes=size_t(w)*h*4;
        reusePixels[eye]=previousWrite.pixels[eye].size()==bytes;
        if(!reusePixels[eye])next.pixels[eye].resize(bytes);
        // Submit only borrows this output pointer; CPU bytes are written by
        // complete_slot later. Keep old ownership untouched until acceptance.
        auto* output=reusePixels[eye]?previousWrite.pixels[eye].data():next.pixels[eye].data();
        next.reads[eye]={next.sources[eye].image.get(),view.imageArrayIndex,uint32_t(r.offset.x),uint32_t(r.offset.y),w,h,output};
        next.colors[eye]=swapchainColourSpace(view);
    }
    if(hxvk_submit_slot(context,state.write+1,next.reads.data(),2)) {
        resetVulkanPriorReadback(context);return PriorStagingResult::Failed;
    }
    transferStatistics().copyCommands+=2;
    transferStatistics().peakFramesInFlight=std::max<uint64_t>(transferStatistics().peakFramesInFlight,2);
    next.frame=frame;next.valid=true;
    for(unsigned eye=0;eye<2;++eye)if(reusePixels[eye])next.pixels[eye].swap(previousWrite.pixels[eye]);
    state.pairs[state.write]=std::move(next);state.write=1-state.write;
    auto& read=state.pairs[state.write];
    if(!read.valid)return PriorStagingResult::Warmup;
    if(hxvk_complete_slot(context,state.write+1,read.reads.data(),2)) {
        resetVulkanPriorReadback(context);return PriorStagingResult::Failed;
    }
    for(unsigned eye=0;eye<2;++eye) {
        const auto& r=read.reads[eye];const auto f=read.sources[eye].format;
        const bool bgra=f==VK_FORMAT_B8G8R8A8_UNORM||f==VK_FORMAT_B8G8R8A8_SRGB;
        images[eye]={read.pixels[eye].data(),r.width,r.height,r.width*4,
                     bgra?DXGI_FORMAT_B8G8R8A8_UNORM:DXGI_FORMAT_R8G8B8A8_UNORM,read.colors[eye]};
    }
    *captured=read.frame;return PriorStagingResult::Ready;
}
}
