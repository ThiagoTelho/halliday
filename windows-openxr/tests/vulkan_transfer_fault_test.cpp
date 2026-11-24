// Execute actual backend lifetime/fence decisions with inert Vulkan entrypoints.
// No loader, instance, physical device or GPU is created.
#include "../src/vulkan_transfer.cpp"
#include <cstdio>
#include <stdexcept>
#include <string>

namespace {
void check(bool value,const char* message){if(!value)throw std::runtime_error(message);}
VkResult fenceStatus=VK_NOT_READY,waitStatus=VK_TIMEOUT,mapStatus=VK_SUCCESS;
unsigned driverCalls=0,waitCalls=0,mapCalls=0,imageDestroys=0,memoryFrees=0;
bool driverAllowed=true;
std::array<uint8_t,32> mappedBytes{};
void touch(){check(driverAllowed,"no Vulkan API/dispatch after application device may be destroyed");++driverCalls;}
VkResult VKAPI_PTR getFence(VkDevice,VkFence){touch();return fenceStatus;}
VkResult VKAPI_PTR waitFence(VkDevice,uint32_t,const VkFence*,VkBool32,uint64_t){touch();++waitCalls;return waitStatus;}
VkResult VKAPI_PTR mapMemory(VkDevice,VkDeviceMemory,VkDeviceSize,VkDeviceSize,VkMemoryMapFlags,void** out){touch();++mapCalls;if(mapStatus==VK_SUCCESS)*out=mappedBytes.data();return mapStatus;}
void VKAPI_PTR unmapMemory(VkDevice,VkDeviceMemory){touch();}
void VKAPI_PTR destroyImage(VkDevice,VkImage,const VkAllocationCallbacks*){touch();++imageDestroys;}
void VKAPI_PTR freeMemory(VkDevice,VkDeviceMemory,const VkAllocationCallbacks*){touch();++memoryFrees;}
void VKAPI_PTR destroyBuffer(VkDevice,VkBuffer,const VkAllocationCallbacks*){touch();}
void VKAPI_PTR destroyFence(VkDevice,VkFence,const VkAllocationCallbacks*){touch();}
void VKAPI_PTR destroyPool(VkDevice,VkCommandPool,const VkAllocationCallbacks*){touch();}
PFN_vkVoidFunction VKAPI_PTR dispatch(VkDevice,const char* name){
    touch();
    if(!std::strcmp(name,"vkGetFenceStatus"))return reinterpret_cast<PFN_vkVoidFunction>(getFence);
    if(!std::strcmp(name,"vkWaitForFences"))return reinterpret_cast<PFN_vkVoidFunction>(waitFence);
    if(!std::strcmp(name,"vkMapMemory"))return reinterpret_cast<PFN_vkVoidFunction>(mapMemory);
    if(!std::strcmp(name,"vkUnmapMemory"))return reinterpret_cast<PFN_vkVoidFunction>(unmapMemory);
    if(!std::strcmp(name,"vkDestroyImage"))return reinterpret_cast<PFN_vkVoidFunction>(destroyImage);
    if(!std::strcmp(name,"vkFreeMemory"))return reinterpret_cast<PFN_vkVoidFunction>(freeMemory);
    if(!std::strcmp(name,"vkDestroyBuffer"))return reinterpret_cast<PFN_vkVoidFunction>(destroyBuffer);
    if(!std::strcmp(name,"vkDestroyFence"))return reinterpret_cast<PFN_vkVoidFunction>(destroyFence);
    if(!std::strcmp(name,"vkDestroyCommandPool"))return reinterpret_cast<PFN_vkVoidFunction>(destroyPool);
    throw std::runtime_error(std::string("unexpected Vulkan dispatch: ")+name);
}
Context* context(unsigned slot=1){
    auto* c=new Context;c->device=(VkDevice)(uintptr_t)1;c->gdpa=dispatch;
    auto& s=c->slots[slot];s.pending=true;s.fence=(VkFence)(uintptr_t)2;s.pool=(VkCommandPool)(uintptr_t)3;
    s.buffer=(VkBuffer)(uintptr_t)4;s.bufferMemory=(VkDeviceMemory)(uintptr_t)5;s.capacity=32;
    return c;
}
Image* image(Context* c){auto* i=new Image;i->context=c;i->image=(VkImage)(uintptr_t)6;i->memory=(VkDeviceMemory)(uintptr_t)7;return i;}
void reset(){driverAllowed=true;fenceStatus=VK_NOT_READY;waitStatus=VK_TIMEOUT;mapStatus=VK_SUCCESS;driverCalls=waitCalls=mapCalls=imageDestroys=memoryFrees=0;quarantinedContext.store(false);}
void releaseQuarantinedFixture(Context* c){
    // This test's handles are integers, so free only the inert CPU fixture after
    // proving production deliberately quarantines real GPU handles.
    for(auto& slot:c->slots)slot={};for(auto* i:c->deferredImages)delete i;c->deferredImages.clear();delete c;
    quarantinedContext.store(false);driverAllowed=true;
}
}

int main(){try{
    reset();auto* c=context();c->slots[2].pending=true;c->slots[2].fence=(VkFence)(uintptr_t)8;
    fenceStatus=VK_ERROR_DEVICE_LOST;
    check(c->finished(c->slots[1])&&c->deviceLost&&c->poisoned&&!c->slots[2].pending,"fence device loss retires all submissions for cleanup");
    check(hxvk_reset_prior(c)==0&&!waitCalls,"terminal loss cleanup never waits again");
    hxvk_destroy_image(image(c));check(imageDestroys==1,"lost but still owned device can release image objects");hxvk_destroy_context(c);

    reset();c=context();waitStatus=VK_ERROR_DEVICE_LOST;
    check(c->wait(c->slots[1])&&c->deviceLost&&c->poisoned&&!c->slots[1].pending,"wait device loss retires without permitting readback");hxvk_destroy_context(c);

    reset();c=context();
    check(!c->wait(c->slots[1])&&c->poisoned&&c->slots[1].pending&&waitCalls==1,"timeout poisons and retains GPU work");
    check(!c->wait(c->slots[1])&&hxvk_reset_prior(c)!=0&&waitCalls==1,"poisoned unfinished cleanup avoids repeated two-second waits");
    hxvk_destroy_image(image(c));check(c->deferredImages.size()==1&&!imageDestroys,"unfinished image remains owned until safe retirement");
    fenceStatus=VK_SUCCESS;check(hxvk_reset_prior(c)==0&&c->poisoned,"later completion can clean up but never re-enable poisoned capture");
    hxvk_destroy_context(c);check(imageDestroys==1,"deferred image destroyed after actual fence retirement");

    reset();c=context();check(!c->wait(c->slots[1]),"prepare quarantine timeout");auto* i=image(c);
    hxvk_destroy_context(c);check(c->abandoned&&quarantinedContext.load(),"unfinished destroyed session quarantines its app-owned device dependencies");
    driverAllowed=false;const unsigned before=driverCalls;
    hxvk_destroy_image(i);hxvk_destroy_context(c);check(hxvk_reset_prior(c)!=0&&!c->finished(),"abandoned state admits no work or cleanup callbacks");
    check(hxvk_context(nullptr,nullptr,nullptr,nullptr,0,0)==nullptr&&driverCalls==before,"bounded failed session blocks another context without driver calls");
    releaseQuarantinedFixture(c);

    reset();c=context(0);c->poisoned=true;check(hxvk_reset_prior(c)==0,"immediate slot is separate from paired slots");
    hxvk_destroy_context(c);check(c->abandoned,"unfinished immediate/quad slot also quarantines at context destruction");
    driverAllowed=false;const unsigned immediateCalls=driverCalls;hxvk_destroy_context(c);check(driverCalls==immediateCalls,"immediate timeout never calls destroyed app device later");releaseQuarantinedFixture(c);

    reset();c=context();auto& slot=c->slots[1];slot.count=2;slot.bytes=32;slot.coherent=true;
    slot.widths[0]=slot.widths[1]=2;slot.heights[0]=slot.heights[1]=2;slot.offsets[1]=16;
    std::array<uint8_t,16> left{},right{};left.fill(0xcd);right.fill(0xcd);
    HallidayReadbackRequest reads[2]={{nullptr,0,0,0,2,2,left.data()},{nullptr,0,0,0,2,2,right.data()}};
    check(hxvk_complete_slot(c,1,reads,2)!=0&&mapCalls==0&&left[0]==0xcd,"unfinished fence cannot map or publish current pixels");
    fenceStatus=VK_SUCCESS;hxvk_destroy_context(c);

    reset();c=context();auto& ready=c->slots[1];ready.count=2;ready.bytes=32;ready.coherent=true;
    ready.widths[0]=ready.widths[1]=2;ready.heights[0]=ready.heights[1]=2;ready.offsets[1]=16;fenceStatus=VK_SUCCESS;
    for(unsigned index=0;index<mappedBytes.size();++index)mappedBytes[index]=uint8_t(index+1);
    check(hxvk_complete_slot(c,1,reads,2)==0&&mapCalls==1&&left[0]==1&&right[0]==17&&!waitCalls,"completed two-eye buffer copies only after fence success");hxvk_destroy_context(c);

    reset();c=context();auto& lostMap=c->slots[1];lostMap.pending=false;lostMap.count=2;lostMap.widths[0]=lostMap.widths[1]=2;lostMap.heights[0]=lostMap.heights[1]=2;mapStatus=VK_ERROR_DEVICE_LOST;
    check(hxvk_complete_slot(c,1,reads,2)!=0&&c->deviceLost&&c->poisoned,"map device loss poisons permanently and allows resource cleanup");
    check(hxvk_submit_slot(c,1,reads,2)!=0,"lost device cannot submit capture again");hxvk_destroy_context(c);
    std::puts("PASS: Vulkan terminal loss, timeout retention/no-repeat-wait, deferred images, abandoned app-device quarantine, unready/ready pixel guards; CPU-only mock entrypoints");return 0;
}catch(const std::exception& error){std::fprintf(stderr,"FAIL: %s\n",error.what());return 1;}}
