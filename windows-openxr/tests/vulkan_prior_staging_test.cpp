// Actual paired Vulkan metadata/pixel staging, inert callbacks only. Every
// graphics/context creation entry point aborts; no loader/device is requested.
#include "vulkan_backend.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
void require(bool value,const char* text) { if(!value)throw std::runtime_error(text); }
struct Image { std::vector<uint8_t> bytes; explicit Image(unsigned tag):bytes(8*8*4,uint8_t(tag)){} };
std::array<std::shared_ptr<Image>,2> sources;
struct Pending { std::array<std::vector<uint8_t>,2> bytes; bool valid=false; } pending[3];
unsigned submits=0,completions=0,resets=0;
bool failComplete=false;
void forbidden() { std::fputs("FAIL: CPU fixture attempted graphics creation\n",stderr);std::abort(); }
}
extern "C" {
int hxvk_create_instance(void*,const void*,const void*,void**) { forbidden();return -1; }
void* hxvk_physical_device(void*,void*) { forbidden();return nullptr; }
int hxvk_create_device(void*,void*,void*,const void*,const void*,void**) { forbidden();return -1; }
void* hxvk_context(void*,void*,void*,void*,uint32_t,uint32_t) { forbidden();return nullptr; }
int hxvk_read_batch(void*,const HallidayReadbackRequest*,uint32_t) { forbidden();return -1; }
int hxvk_submit_slot(void*,uint32_t slot,const HallidayReadbackRequest* reads,uint32_t count) {
    require(slot>=1&&slot<=2&&count==2&&!pending[slot].valid,"one owned stereo enqueue per slot");
    for(unsigned eye=0;eye<2;++eye) {
        require(reads[eye].width==8&&reads[eye].height==8&&reads[eye].output,"exact two-eye read rectangle");
        pending[slot].bytes[eye]=static_cast<Image*>(reads[eye].image)->bytes;
    }
    pending[slot].valid=true;++submits;return 0;
}
int hxvk_complete_slot(void*,uint32_t slot,const HallidayReadbackRequest* reads,uint32_t count) {
    require(slot>=1&&slot<=2&&count==2&&pending[slot].valid,"completion selects a previously submitted whole pair");
    if(failComplete)return -1;
    for(unsigned eye=0;eye<2;++eye)std::memcpy(reads[eye].output,pending[slot].bytes[eye].data(),8*8*4);
    pending[slot]={};++completions;return 0;
}
int hxvk_reset_prior(void*) { pending[1]={};pending[2]={};++resets;return 0; }
void hxvk_abandon_context(void*) { forbidden(); }
}
namespace basalt {
bool isValidInstance(XrInstance) { return false; }
bool isVulkanExtensionEnabled(XrInstance,bool) { return false; }
VulkanSource swapchainVulkanImage(const ControlFrameView& view) {
    require(view.swapchainId>=1&&view.swapchainId<=2,"fixture source handle");
    return {sources[view.swapchainId-1],VK_FORMAT_R8G8B8A8_UNORM};
}
uint32_t swapchainColourSpace(const ControlFrameView&) { return halliday::kColorLinear; }
HallidayTransferStats& transferStatistics() { static HallidayTransferStats stats{};return stats; }
}
int main() { try {
    void* context=reinterpret_cast<void*>(uintptr_t(0x41));
    auto frame=[&](unsigned tag,uint64_t epoch=7,uint32_t clock=1) {
        basalt::PriorProjectionFrame value{};value.producerEpoch=epoch;value.spaceEpoch=11;
        value.focusGeneration=2;value.fullGeometry=true;value.head.stamp=float(tag);
        value.sourceDisplayTimeNs=5'000'000'000LL+int64_t(tag)*23'255'813LL;value.sourceClockKind=clock;
        for(unsigned eye=0;eye<2;++eye) {
            sources[eye]=std::make_shared<Image>(tag*7+eye);
            value.views[eye].swapchainId=eye+1;value.views[eye].rect={{0,0},{8,8}};
        }
        return value;
    };
    const unsigned tags[]{0,1,3,4,8};basalt::PriorProjectionFrame previous{};
    for(unsigned i=0;i<5;++i) {
        const auto current=frame(tags[i]);basalt::PriorProjectionFrame captured{};basalt::ReadbackImage pixels[2];
        const auto result=basalt::prepareVulkanPriorFrame(context,current,pixels,&captured);
        if(!i)require(result==basalt::PriorStagingResult::Warmup&&completions==0,"first source stays pending, no fabricated completion");
        else {
            require(result==basalt::PriorStagingResult::Ready,"older paired capture becomes ready");
            require(captured.sourceDisplayTimeNs==previous.sourceDisplayTimeNs&&captured.sourceClockKind==previous.sourceClockKind&&
                    captured.producerEpoch==previous.producerEpoch&&captured.head.stamp==previous.head.stamp,
                    "older43Hz source timestamp, gap and epoch stay with its exact pixels despite bunched completion");
            for(unsigned eye=0;eye<2;++eye)for(unsigned byte=0;byte<8*8*4;++byte)
                require(pixels[eye].pixels[byte]==uint8_t(tags[i-1]*7+eye),"actual previous CPU pixels accompany previous time");
        }
        previous=current;
    }
    basalt::PriorProjectionFrame captured{};basalt::ReadbackImage pixels[2];
    auto next=frame(10,8);
    require(basalt::prepareVulkanPriorFrame(context,next,pixels,&captured)==basalt::PriorStagingResult::Warmup,
            "replacement producer retires old timing and pixels together");
    next=frame(11,8,2);
    require(basalt::prepareVulkanPriorFrame(context,next,pixels,&captured)==basalt::PriorStagingResult::Warmup,
            "source clock-kind change cannot join different clock domains");
    next=frame(12,8,2);failComplete=true;
    require(basalt::prepareVulkanPriorFrame(context,next,pixels,&captured)==basalt::PriorStagingResult::Failed,
            "failed completion exposes neither pending image nor timing");
    failComplete=false;next=frame(13,8,2);
    require(basalt::prepareVulkanPriorFrame(context,next,pixels,&captured)==basalt::PriorStagingResult::Warmup,
            "failure resets prior packet before recovery");
    require(basalt::resetVulkanPriorReadback(context)&&!pending[1].valid&&!pending[2].valid,
            "owned pending packets retire at final reset");
    require(submits==9&&completions==4&&resets>=4,"bounded expected two-slot lifecycle");
    std::puts("PASS: inert Vulkan N-1 pixels+43Hz timestamps, source gaps/bunched completion, epoch/clock/reset/failure");return 0;
} catch(const std::exception& error) {std::fprintf(stderr,"FAIL: %s\n",error.what());return 1;} }
