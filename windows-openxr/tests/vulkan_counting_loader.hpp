// Test-only loader wrapper. Counts actual public queue/fence calls during
// xrEndFrame while forwarding every command to the real GPU implementation.
#pragma once
#include <cstring>
#include <cstdint>

namespace vulkan_counting {
inline PFN_vkGetInstanceProcAddr realInstance{};
inline PFN_vkGetDeviceProcAddr realDevice{};
inline PFN_vkQueueSubmit submitFunction{};
inline PFN_vkWaitForFences waitFunction{};
inline PFN_vkCmdCopyImageToBuffer copyFunction{};
inline uint64_t submissions=0, waits=0, copies=0, pendingCopies=0, maximumCopiesPerSubmission=0;
inline void reset() { submissions=waits=copies=pendingCopies=maximumCopiesPerSubmission=0; }
inline VKAPI_ATTR VkResult VKAPI_CALL submit(VkQueue queue,uint32_t count,const VkSubmitInfo* infos,VkFence fence) {
    ++submissions;
    if(pendingCopies>maximumCopiesPerSubmission)maximumCopiesPerSubmission=pendingCopies;
    pendingCopies=0;return submitFunction(queue,count,infos,fence);
}
inline VKAPI_ATTR VkResult VKAPI_CALL wait(VkDevice device,uint32_t count,const VkFence* fences,VkBool32 all,uint64_t timeout) {
    ++waits;return waitFunction(device,count,fences,all,timeout);
}
inline VKAPI_ATTR void VKAPI_CALL copy(VkCommandBuffer commands,VkImage image,VkImageLayout layout,
                                      VkBuffer buffer,uint32_t count,const VkBufferImageCopy* regions) {
    ++copies;++pendingCopies;copyFunction(commands,image,layout,buffer,count,regions);
}
inline VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL device(VkDevice object,const char* name) {
    const auto function=realDevice(object,name);
    if(!function)return nullptr;
    if(!std::strcmp(name,"vkQueueSubmit")) {
        submitFunction=reinterpret_cast<PFN_vkQueueSubmit>(function);
        return reinterpret_cast<PFN_vkVoidFunction>(&submit);
    }
    if(!std::strcmp(name,"vkWaitForFences")) {
        waitFunction=reinterpret_cast<PFN_vkWaitForFences>(function);
        return reinterpret_cast<PFN_vkVoidFunction>(&wait);
    }
    if(!std::strcmp(name,"vkCmdCopyImageToBuffer")) {
        copyFunction=reinterpret_cast<PFN_vkCmdCopyImageToBuffer>(function);
        return reinterpret_cast<PFN_vkVoidFunction>(&copy);
    }
    return function;
}
inline VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL instance(VkInstance object,const char* name) {
    const auto function=realInstance(object,name);
    if(function&&!std::strcmp(name,"vkGetDeviceProcAddr")) {
        realDevice=reinterpret_cast<PFN_vkGetDeviceProcAddr>(function);
        return reinterpret_cast<PFN_vkVoidFunction>(&device);
    }
    return function;
}
inline PFN_vkGetInstanceProcAddr wrap(PFN_vkGetInstanceProcAddr loader) {
    realInstance=loader;return &instance;
}
}
