// MIT. Fault paths are exercised without GPU submission or forced driver errors.
// Real GPU transfer pixels/submission counts have separate Vulkan fixtures.
#include "../../core/halliday-openxr/src/vulkan.cpp"
#include <cstdio>
#include <cstdlib>
#include <cstddef>

static_assert(sizeof(HallidayReadbackRequest)==40);
static_assert(offsetof(HallidayReadbackRequest,output)==32);
static void require(bool value,const char* message) {
    if(!value){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}
}
namespace fake {
static unsigned creates=0,allocations=0,binds=0,destroys=0,frees=0,resets=0;
static bool failAllocation=true;
static VKAPI_ATTR VkResult VKAPI_CALL create(VkDevice,const VkBufferCreateInfo*,const VkAllocationCallbacks*,VkBuffer* out) {
    ++creates;*out=VkBuffer(3);return VK_SUCCESS;
}
static VKAPI_ATTR void VKAPI_CALL requirements(VkDevice,VkBuffer,VkMemoryRequirements* out) {
    *out={256,4,1};
}
static VKAPI_ATTR VkResult VKAPI_CALL allocate(VkDevice,const VkMemoryAllocateInfo*,const VkAllocationCallbacks*,VkDeviceMemory* out) {
    ++allocations;if(failAllocation)return VK_ERROR_OUT_OF_DEVICE_MEMORY;
    *out=VkDeviceMemory(4);return VK_SUCCESS;
}
static VKAPI_ATTR VkResult VKAPI_CALL bind(VkDevice,VkBuffer,VkDeviceMemory,VkDeviceSize) {
    ++binds;return VK_ERROR_OUT_OF_DEVICE_MEMORY;
}
static VKAPI_ATTR void VKAPI_CALL destroy(VkDevice,VkBuffer value,const VkAllocationCallbacks*) {
    require(value==VkBuffer(3),"a failed growth destroys only the new buffer");++destroys;
}
static VKAPI_ATTR void VKAPI_CALL free(VkDevice,VkDeviceMemory value,const VkAllocationCallbacks*) {
    require(value==VkDeviceMemory(4),"a failed bind frees only the new memory");++frees;
}
static VKAPI_ATTR VkResult VKAPI_CALL status(VkDevice,VkFence) { return VK_NOT_READY; }
static VKAPI_ATTR VkResult VKAPI_CALL reset(VkDevice,VkCommandPool,VkCommandPoolResetFlags) { ++resets;return VK_SUCCESS; }
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL get(VkDevice,const char* name) {
#define FN(n,f) if(!std::strcmp(name,n))return reinterpret_cast<PFN_vkVoidFunction>(f)
    FN("vkCreateBuffer",create);FN("vkGetBufferMemoryRequirements",requirements);
    FN("vkAllocateMemory",allocate);FN("vkBindBufferMemory",bind);
    FN("vkDestroyBuffer",destroy);FN("vkFreeMemory",free);
    FN("vkGetFenceStatus",status);FN("vkResetCommandPool",reset);
#undef FN
    std::fprintf(stderr,"unexpected Vulkan operation: %s\n",name);std::exit(1);
}
}
int main() {
    Context context{};context.gdpa=&fake::get;
    context.memory.memoryTypeCount=1;
    context.memory.memoryTypes[0].propertyFlags=VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    Image image{&context,VkImage(8),VK_NULL_HANDLE,8,8,2,true};
    std::array<uint8_t,256> first,second;first.fill(0x5a);second.fill(0x6b);
    HallidayReadbackRequest reads[]{
        {&image,0,0,0,1,1,first.data()},
        {&image,2,0,0,1,1,second.data()},
    };
    require(hxvk_read_batch(&context,reads,2)!=0,"invalid last slice rejects the whole batch");
    require(fake::creates==0&&fake::resets==0,"invalid input never starts GPU work");
    require(first[0]==0x5a&&second[0]==0x6b,"invalid batch leaves both outputs untouched");
    reads[1].slice=1;reads[1].width=0;
    require(hxvk_read_batch(&context,reads,2)!=0,"zero-width rectangle rejects before GPU work");
    require(hxvk_read_batch(&context,reads,11)!=0,"over-budget read count rejects before reading the array");

    context.buffer=VkBuffer(1);context.bufferMemory=VkDeviceMemory(2);context.capacity=16;
    reads[0].width=reads[0].height=8;
    require(hxvk_read_batch(&context,reads,1)==3,"allocation failure is reported");
    require(context.buffer==VkBuffer(1)&&context.bufferMemory==VkDeviceMemory(2)&&context.capacity==16,
            "failed buffer growth preserves the valid prior pool");
    require(fake::destroys==1&&fake::frees==0&&fake::resets==0,"failed allocation cleans new storage before GPU work");
    fake::failAllocation=false;
    require(hxvk_read_batch(&context,reads,1)==4,"bind failure is reported");
    require(context.buffer==VkBuffer(1)&&context.bufferMemory==VkDeviceMemory(2)&&context.capacity==16,
            "failed memory bind preserves the valid prior pool");
    require(fake::destroys==2&&fake::frees==1&&fake::resets==0,"failed bind releases only newly allocated objects");

    // Reproduce an unfinished timed-out transfer without timing out real hardware.
    context.pending=true;context.fence=VkFence(9);reads[0].width=reads[0].height=1;
    require(hxvk_read_batch(&context,reads,1)!=0,"pending GPU work cannot be overwritten by another transfer");
    require(hxvk_prepare_image(&image)!=0,"Acquire cannot reset the command pool of a pending copy");
    require(fake::resets==0,"in-flight command storage is never reset");
    require(first[0]==0x5a&&second[0]==0x6b,"all rejected/faulted reads preserve caller output");
    // Fake handles are sentinels, not owned driver objects.
    context.buffer=VK_NULL_HANDLE;context.bufferMemory=VK_NULL_HANDLE;context.fence=VK_NULL_HANDLE;context.pending=false;
    std::puts("PASS: Vulkan batch ABI, all-or-nothing validation, allocation/bind rollback, and pending-work protection");
}
