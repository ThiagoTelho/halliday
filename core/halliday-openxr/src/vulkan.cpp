// Halliday native Vulkan2 backend. Written from the public Vulkan/OpenXR APIs.
// Client-owned Vulkan objects remain client-owned; runtime images/readback are ours.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include "../../halliday-bridge/include/readback_batch.h"
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

namespace {
template<class T> T proc(PFN_vkGetInstanceProcAddr get, VkInstance instance, const char* name) {
    return reinterpret_cast<T>(get(instance, name));
}
template<class T> T deviceProc(PFN_vkGetDeviceProcAddr get, VkDevice device, const char* name) {
    return reinterpret_cast<T>(get(device, name));
}
void addExtension(std::vector<const char*>& list, const char* name) {
    if (std::none_of(list.begin(), list.end(), [name](const char* s) { return !std::strcmp(s, name); })) list.push_back(name);
}
struct Context {
    PFN_vkGetInstanceProcAddr gipa{}; PFN_vkGetDeviceProcAddr gdpa{};
    VkInstance instance{}; VkPhysicalDevice physical{}; VkDevice device{}; VkQueue queue{};
    VkPhysicalDeviceMemoryProperties memory{};
    VkCommandPool pool{}; VkCommandBuffer commands{}; VkFence fence{};
    VkBuffer buffer{}; VkDeviceMemory bufferMemory{}; VkDeviceSize capacity{};
    bool coherent=false, pending=false, poisoned=false;
    template<class T> T fn(const char* name) { return deviceProc<T>(gdpa, device, name); }
    uint32_t memoryType(uint32_t bits, VkMemoryPropertyFlags flags) {
        for(uint32_t i=0;i<memory.memoryTypeCount;++i)
            if ((bits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&flags)==flags) return i;
        return UINT32_MAX;
    }
    bool finished() {
        if (!pending) return true;
        if (fn<PFN_vkGetFenceStatus>("vkGetFenceStatus")(device,fence)==VK_SUCCESS) { pending=false; return true; }
        return false;
    }
    ~Context() {
        if (buffer) fn<PFN_vkDestroyBuffer>("vkDestroyBuffer")(device,buffer,nullptr);
        if (bufferMemory) fn<PFN_vkFreeMemory>("vkFreeMemory")(device,bufferMemory,nullptr);
        if (fence) fn<PFN_vkDestroyFence>("vkDestroyFence")(device,fence,nullptr);
        if (pool) fn<PFN_vkDestroyCommandPool>("vkDestroyCommandPool")(device,pool,nullptr);
    }
};
struct Image { Context* context; VkImage image{}; VkDeviceMemory memory{}; uint32_t width,height,layers; bool initialized=false; };
}

extern "C" {
int hxvk_create_instance(void* loader, const void* given, const void* allocator, void** output) {
    auto get=reinterpret_cast<PFN_vkGetInstanceProcAddr>(loader);
    const auto* info=static_cast<const VkInstanceCreateInfo*>(given);
    if (!get||!info||!output) return VK_ERROR_INITIALIZATION_FAILED;
    const auto create=proc<PFN_vkCreateInstance>(get,VK_NULL_HANDLE,"vkCreateInstance");
    const auto enumerate=proc<PFN_vkEnumerateInstanceExtensionProperties>(get,VK_NULL_HANDLE,"vkEnumerateInstanceExtensionProperties");
    if (!create||!enumerate) return VK_ERROR_INITIALIZATION_FAILED;
    auto copy=*info; std::vector<const char*> names;
    for(uint32_t i=0;i<info->enabledExtensionCount;++i) names.push_back(info->ppEnabledExtensionNames[i]);
    uint32_t count=0; enumerate(nullptr,&count,nullptr);std::vector<VkExtensionProperties> available(count);
    if(enumerate(nullptr,&count,available.data())!=VK_SUCCESS) return VK_ERROR_INITIALIZATION_FAILED;
    for(const auto& ext:available) if(!std::strcmp(ext.extensionName,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        addExtension(names,VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);copy.flags|=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    copy.enabledExtensionCount=uint32_t(names.size());copy.ppEnabledExtensionNames=names.data();
    VkInstance value=VK_NULL_HANDLE;
    auto result=create(&copy,static_cast<const VkAllocationCallbacks*>(allocator),&value);
    *output=reinterpret_cast<void*>(value);return result;
}
void* hxvk_physical_device(void* loader, void* instance) {
    auto get=reinterpret_cast<PFN_vkGetInstanceProcAddr>(loader);auto vk=static_cast<VkInstance>(instance);
    if(!get||!vk)return nullptr;
    const auto enumerate=proc<PFN_vkEnumeratePhysicalDevices>(get,vk,"vkEnumeratePhysicalDevices");
    const auto families=proc<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(get,vk,"vkGetPhysicalDeviceQueueFamilyProperties");
    if(!enumerate||!families)return nullptr;
    uint32_t count=0;if(enumerate(vk,&count,nullptr)!=VK_SUCCESS||!count)return nullptr;
    std::vector<VkPhysicalDevice> devices(count);if(enumerate(vk,&count,devices.data())!=VK_SUCCESS)return nullptr;
    for(auto physical:devices) {
        uint32_t n=0;families(physical,&n,nullptr);std::vector<VkQueueFamilyProperties> props(n);families(physical,&n,props.data());
        for(const auto& q:props)if(q.queueCount&&(q.queueFlags&VK_QUEUE_GRAPHICS_BIT))return physical;
    }
    return nullptr;
}
int hxvk_create_device(void* loader, void* instance, void* physical, const void* given, const void* allocator, void** output) {
    auto get=reinterpret_cast<PFN_vkGetInstanceProcAddr>(loader);auto vk=static_cast<VkInstance>(instance);
    const auto* info=static_cast<const VkDeviceCreateInfo*>(given);
    if(!get||!vk||!physical||!info||!output)return VK_ERROR_INITIALIZATION_FAILED;
    const auto create=proc<PFN_vkCreateDevice>(get,vk,"vkCreateDevice");
    const auto enumerate=proc<PFN_vkEnumerateDeviceExtensionProperties>(get,vk,"vkEnumerateDeviceExtensionProperties");
    if(!create||!enumerate)return VK_ERROR_INITIALIZATION_FAILED;
    auto copy=*info;std::vector<const char*> names;
    for(uint32_t i=0;i<info->enabledExtensionCount;++i)names.push_back(info->ppEnabledExtensionNames[i]);
    uint32_t count=0;enumerate(static_cast<VkPhysicalDevice>(physical),nullptr,&count,nullptr);
    std::vector<VkExtensionProperties> available(count);
    if(enumerate(static_cast<VkPhysicalDevice>(physical),nullptr,&count,available.data())!=VK_SUCCESS)return VK_ERROR_INITIALIZATION_FAILED;
    for(const auto& ext:available)if(!std::strcmp(ext.extensionName,"VK_KHR_portability_subset"))addExtension(names,"VK_KHR_portability_subset");
    copy.enabledExtensionCount=uint32_t(names.size());copy.ppEnabledExtensionNames=names.data();VkDevice value=VK_NULL_HANDLE;
    auto result=create(static_cast<VkPhysicalDevice>(physical),&copy,static_cast<const VkAllocationCallbacks*>(allocator),&value);
    *output=value;return result;
}
// Copy the logical queue descriptors while the application's create-info is still live.
// Available physical queues are not sufficient: vkGetDeviceQueue may only access queues
// actually requested at VkDevice creation. Triples are family, count, create flags.
uint32_t hxvk_device_queues(const void* given, uint32_t* triples, uint32_t capacity) {
    const auto* info=static_cast<const VkDeviceCreateInfo*>(given);
    if(!info)return 0;
    if(triples && capacity>=info->queueCreateInfoCount) {
        for(uint32_t q=0;q<info->queueCreateInfoCount;++q) {
            triples[q*3]=info->pQueueCreateInfos[q].queueFamilyIndex;
            triples[q*3+1]=info->pQueueCreateInfos[q].queueCount;
            triples[q*3+2]=info->pQueueCreateInfos[q].flags;
        }
    }
    return info->queueCreateInfoCount;
}
void* hxvk_context(void* loader, void* instance, void* physical, void* device, uint32_t family, uint32_t index) {
    auto c=std::make_unique<Context>();c->gipa=reinterpret_cast<PFN_vkGetInstanceProcAddr>(loader);
    c->instance=static_cast<VkInstance>(instance);c->physical=static_cast<VkPhysicalDevice>(physical);c->device=static_cast<VkDevice>(device);
    if(!c->gipa||!instance||!physical||!device)return nullptr;
    c->gdpa=proc<PFN_vkGetDeviceProcAddr>(c->gipa,c->instance,"vkGetDeviceProcAddr");if(!c->gdpa)return nullptr;
    auto families=proc<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(c->gipa,c->instance,"vkGetPhysicalDeviceQueueFamilyProperties");
    auto mem=proc<PFN_vkGetPhysicalDeviceMemoryProperties>(c->gipa,c->instance,"vkGetPhysicalDeviceMemoryProperties");
    if(!families||!mem)return nullptr;
    uint32_t n=0;families(c->physical,&n,nullptr);std::vector<VkQueueFamilyProperties> props(n);families(c->physical,&n,props.data());
    if(family>=n||index>=props[family].queueCount||!(props[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))return nullptr;
    mem(c->physical,&c->memory);c->fn<PFN_vkGetDeviceQueue>("vkGetDeviceQueue")(c->device,family,index,&c->queue);if(!c->queue)return nullptr;
    VkCommandPoolCreateInfo pool{};pool.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;pool.queueFamilyIndex=family;pool.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    if(c->fn<PFN_vkCreateCommandPool>("vkCreateCommandPool")(c->device,&pool,nullptr,&c->pool)!=VK_SUCCESS)return nullptr;
    VkCommandBufferAllocateInfo alloc{};alloc.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;alloc.commandPool=c->pool;alloc.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;alloc.commandBufferCount=1;
    if(c->fn<PFN_vkAllocateCommandBuffers>("vkAllocateCommandBuffers")(c->device,&alloc,&c->commands)!=VK_SUCCESS)return nullptr;
    VkFenceCreateInfo fence{};fence.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if(c->fn<PFN_vkCreateFence>("vkCreateFence")(c->device,&fence,nullptr,&c->fence)!=VK_SUCCESS)return nullptr;
    return c.release();
}
void hxvk_destroy_context(void* context) {
    auto* c=static_cast<Context*>(context);if(!c||!c->finished())return;delete c;
}
void* hxvk_image(void* context, uint64_t format, uint32_t width, uint32_t height, uint32_t layers, uint64_t usage) {
    auto* c=static_cast<Context*>(context);if(!c||c->poisoned)return nullptr;
    auto image=std::make_unique<Image>();image->context=c;image->width=width;image->height=height;image->layers=layers;
    VkImageCreateInfo info{};info.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;info.imageType=VK_IMAGE_TYPE_2D;info.format=VkFormat(format);
    info.extent={width,height,1};info.mipLevels=1;info.arrayLayers=layers;info.samples=VK_SAMPLE_COUNT_1_BIT;
    info.tiling=VK_IMAGE_TILING_OPTIMAL;info.usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if(usage & 4) info.usage |= VK_IMAGE_USAGE_STORAGE_BIT;
    if(usage & 64) info.flags |= VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT;
    if(usage & 128) info.usage |= VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT;
    info.sharingMode=VK_SHARING_MODE_EXCLUSIVE;info.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED;
    if(c->fn<PFN_vkCreateImage>("vkCreateImage")(c->device,&info,nullptr,&image->image)!=VK_SUCCESS)return nullptr;
    VkMemoryRequirements req{};c->fn<PFN_vkGetImageMemoryRequirements>("vkGetImageMemoryRequirements")(c->device,image->image,&req);
    uint32_t type=c->memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if(type==UINT32_MAX)type=c->memoryType(req.memoryTypeBits,0);
    VkMemoryAllocateInfo mem{};mem.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;mem.allocationSize=req.size;mem.memoryTypeIndex=type;
    if(type==UINT32_MAX||c->fn<PFN_vkAllocateMemory>("vkAllocateMemory")(c->device,&mem,nullptr,&image->memory)!=VK_SUCCESS) {
        c->fn<PFN_vkDestroyImage>("vkDestroyImage")(c->device,image->image,nullptr);return nullptr;
    }
    if(c->fn<PFN_vkBindImageMemory>("vkBindImageMemory")(c->device,image->image,image->memory,0)!=VK_SUCCESS) {
        c->fn<PFN_vkDestroyImage>("vkDestroyImage")(c->device,image->image,nullptr);c->fn<PFN_vkFreeMemory>("vkFreeMemory")(c->device,image->memory,nullptr);return nullptr;
    }
    return image.release();
}
uint64_t hxvk_image_handle(void* image) {return uint64_t(reinterpret_cast<uintptr_t>(static_cast<Image*>(image)->image));}
void hxvk_destroy_image(void* image) {
    auto* i=static_cast<Image*>(image);if(!i)return;auto* c=i->context;if(!c->finished())return;
    c->fn<PFN_vkDestroyImage>("vkDestroyImage")(c->device,i->image,nullptr);c->fn<PFN_vkFreeMemory>("vkFreeMemory")(c->device,i->memory,nullptr);delete i;
}
// OpenXR requires COLOR_ATTACHMENT_OPTIMAL after a successful WaitSwapchainImage.
// Queue access is allowed in Acquire (not Wait). Initialize once here and retain that layout
// after every runtime read; the application's later own barriers may freely discard contents.
int hxvk_prepare_image(void* image) {
    auto* i=static_cast<Image*>(image);if(!i)return 1;auto* c=i->context;
    if(c->poisoned||!c->finished())return 1;if(i->initialized)return 0;
    if(c->fn<PFN_vkResetCommandPool>("vkResetCommandPool")(c->device,c->pool,0)!=VK_SUCCESS)return 2;
    if(c->fn<PFN_vkResetFences>("vkResetFences")(c->device,1,&c->fence)!=VK_SUCCESS)return 3;
    VkCommandBufferBeginInfo begin{};begin.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if(c->fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(c->commands,&begin)!=VK_SUCCESS)return 4;
    VkImageMemoryBarrier barrier{};barrier.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout=VK_IMAGE_LAYOUT_UNDEFINED;barrier.newLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
    barrier.image=i->image;barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,i->layers};
    c->fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(c->commands,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,0,nullptr,0,nullptr,1,&barrier);
    if(c->fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(c->commands)!=VK_SUCCESS)return 5;
    VkSubmitInfo submit{};submit.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;submit.commandBufferCount=1;submit.pCommandBuffers=&c->commands;
    if(c->fn<PFN_vkQueueSubmit>("vkQueueSubmit")(c->queue,1,&submit,c->fence)!=VK_SUCCESS)return 6;
    c->pending=true;
    if(c->fn<PFN_vkWaitForFences>("vkWaitForFences")(c->device,1,&c->fence,VK_TRUE,2'000'000'000)!=VK_SUCCESS){c->poisoned=true;return 7;}
    c->pending=false;i->initialized=true;return 0;
}
int hxvk_read_batch(void* context, const HallidayReadbackRequest* reads, uint32_t count) {
    auto* c=static_cast<Context*>(context);
    if(!c||!reads||!count||count>HALLIDAY_MAX_READBACKS||c->poisoned||!c->finished())return 1;
    std::array<VkDeviceSize,HALLIDAY_MAX_READBACKS> offsets{};
    std::array<VkImageMemoryBarrier,HALLIDAY_MAX_READBACKS> barriers{};
    uint32_t barrierCount=0;
    VkDeviceSize bytes=0;
    // Validate the entire frame before changing a GPU resource or any output.
    // Shared images/slices are transitioned once, even if several layers read them.
    for(uint32_t n=0;n<count;++n) {
        const auto& read=reads[n];auto* i=static_cast<Image*>(read.image);
        if(!i||i->context!=c||!read.output||!read.width||!read.height||read.slice>=i->layers||
           uint64_t(read.x)+read.width>i->width||uint64_t(read.y)+read.height>i->height)return 1;
        const VkDeviceSize size=VkDeviceSize(read.width)*read.height*4;
        if(size>SIZE_MAX||bytes>SIZE_MAX-size)return 1;
        offsets[n]=bytes;bytes+=size;
        bool found=false;
        for(uint32_t b=0;b<barrierCount;++b)
            if(barriers[b].image==i->image&&barriers[b].subresourceRange.baseArrayLayer==read.slice)found=true;
        if(found)continue;
        auto& barrier=barriers[barrierCount++];barrier.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        // The application may fill a color image with draws, transfer or compute.
        // Queue ordering plus a memory-write dependency covers all those producers.
        barrier.srcAccessMask=VK_ACCESS_MEMORY_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT;
        barrier.oldLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        barrier.image=i->image;barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,read.slice,1};
    }
    if(bytes>c->capacity) {
        // Prepare replacement storage transactionally: an allocation failure must
        // leave the last valid buffer usable for a later, smaller frame.
        VkBuffer made=VK_NULL_HANDLE;VkDeviceMemory memory=VK_NULL_HANDLE;
        VkBufferCreateInfo buffer{};buffer.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;buffer.size=bytes;buffer.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        if(c->fn<PFN_vkCreateBuffer>("vkCreateBuffer")(c->device,&buffer,nullptr,&made)!=VK_SUCCESS)return 2;
        VkMemoryRequirements req{};c->fn<PFN_vkGetBufferMemoryRequirements>("vkGetBufferMemoryRequirements")(c->device,made,&req);
        uint32_t type=c->memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        const bool coherent=type!=UINT32_MAX;
        if(type==UINT32_MAX)type=c->memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
        VkMemoryAllocateInfo mem{};mem.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;mem.allocationSize=req.size;mem.memoryTypeIndex=type;
        const bool allocated=type!=UINT32_MAX&&c->fn<PFN_vkAllocateMemory>("vkAllocateMemory")(c->device,&mem,nullptr,&memory)==VK_SUCCESS;
        if(!allocated||c->fn<PFN_vkBindBufferMemory>("vkBindBufferMemory")(c->device,made,memory,0)!=VK_SUCCESS) {
            c->fn<PFN_vkDestroyBuffer>("vkDestroyBuffer")(c->device,made,nullptr);
            if(memory)c->fn<PFN_vkFreeMemory>("vkFreeMemory")(c->device,memory,nullptr);
            return allocated?4:3;
        }
        if(c->buffer)c->fn<PFN_vkDestroyBuffer>("vkDestroyBuffer")(c->device,c->buffer,nullptr);
        if(c->bufferMemory)c->fn<PFN_vkFreeMemory>("vkFreeMemory")(c->device,c->bufferMemory,nullptr);
        c->buffer=made;c->bufferMemory=memory;c->capacity=bytes;c->coherent=coherent;
    }
    if(c->fn<PFN_vkResetCommandPool>("vkResetCommandPool")(c->device,c->pool,0)!=VK_SUCCESS)return 5;
    if(c->fn<PFN_vkResetFences>("vkResetFences")(c->device,1,&c->fence)!=VK_SUCCESS)return 6;
    VkCommandBufferBeginInfo begin{};begin.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;begin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if(c->fn<PFN_vkBeginCommandBuffer>("vkBeginCommandBuffer")(c->commands,&begin)!=VK_SUCCESS)return 7;
    c->fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(c->commands,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,barrierCount,barriers.data());
    for(uint32_t n=0;n<count;++n) {
        const auto& read=reads[n];auto* i=static_cast<Image*>(read.image);
        VkBufferImageCopy copy{};copy.bufferOffset=offsets[n];copy.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,read.slice,1};
        copy.imageOffset={int32_t(read.x),int32_t(read.y),0};copy.imageExtent={read.width,read.height,1};
        c->fn<PFN_vkCmdCopyImageToBuffer>("vkCmdCopyImageToBuffer")(c->commands,i->image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,c->buffer,1,&copy);
    }
    for(uint32_t b=0;b<barrierCount;++b) {
        auto& barrier=barriers[b];std::swap(barrier.oldLayout,barrier.newLayout);
        barrier.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;barrier.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    }
    c->fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(c->commands,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,0,nullptr,0,nullptr,barrierCount,barriers.data());
    VkBufferMemoryBarrier visible{};visible.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;visible.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;visible.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
    visible.srcQueueFamilyIndex=visible.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;visible.buffer=c->buffer;visible.offset=0;visible.size=bytes;
    c->fn<PFN_vkCmdPipelineBarrier>("vkCmdPipelineBarrier")(c->commands,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&visible,0,nullptr);
    if(c->fn<PFN_vkEndCommandBuffer>("vkEndCommandBuffer")(c->commands)!=VK_SUCCESS)return 8;
    VkSubmitInfo submit{};submit.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO;submit.commandBufferCount=1;submit.pCommandBuffers=&c->commands;
    if(c->fn<PFN_vkQueueSubmit>("vkQueueSubmit")(c->queue,1,&submit,c->fence)!=VK_SUCCESS)return 9;
    c->pending=true;
    if(c->fn<PFN_vkWaitForFences>("vkWaitForFences")(c->device,1,&c->fence,VK_TRUE,2'000'000'000)!=VK_SUCCESS) {c->poisoned=true;return 10;}
    c->pending=false;void* mapped=nullptr;
    if(c->fn<PFN_vkMapMemory>("vkMapMemory")(c->device,c->bufferMemory,0,VK_WHOLE_SIZE,0,&mapped)!=VK_SUCCESS)return 11;
    if(!c->coherent) {
        VkMappedMemoryRange range{};range.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;range.memory=c->bufferMemory;range.size=VK_WHOLE_SIZE;
        if(c->fn<PFN_vkInvalidateMappedMemoryRanges>("vkInvalidateMappedMemoryRanges")(c->device,1,&range)!=VK_SUCCESS) {c->fn<PFN_vkUnmapMemory>("vkUnmapMemory")(c->device,c->bufferMemory);return 12;}
    }
    for(uint32_t n=0;n<count;++n)
        std::memcpy(reads[n].output,static_cast<const uint8_t*>(mapped)+offsets[n],size_t(reads[n].width)*reads[n].height*4);
    c->fn<PFN_vkUnmapMemory>("vkUnmapMemory")(c->device,c->bufferMemory);return 0;
}
int hxvk_read(void* context, void* image, uint32_t slice, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint8_t* out) {
    const HallidayReadbackRequest read{image,slice,x,y,width,height,out};
    return hxvk_read_batch(context,&read,1);
}
}
