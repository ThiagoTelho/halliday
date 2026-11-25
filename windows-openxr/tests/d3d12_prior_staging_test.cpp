// Real paired readback implementation, deterministic inert COM, no GPU/device.
#include "d3d12_prior_staging.hpp"
#include "projection_geometry.hpp"
#include "stereo_readback_order.hpp"
#include <array>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace {
void check(bool value,const char* message) {if(!value)throw std::runtime_error(message);}
enum Kind {DeviceKind,QueueKind,ResourceKind,AllocatorKind,CommandsKind,FenceKind};
std::array<void*,44> deviceTable{};
std::array<void*,19> queueTable{};
std::array<void*,15> resourceTable{};
std::array<void*,9> allocatorTable{};
std::array<void*,60> commandsTable{};
std::array<void*,11> fenceTable{};
struct Base {void** table;ULONG references=1;Kind kind;Base(void** t,Kind k):table(t),kind(k){}};
struct Fence:Base {
    uint64_t completed=0,signaled=0;
    Fence():Base(fenceTable.data(),FenceKind){}
}* activeFence=nullptr;
struct Device:Base {bool lost=false;Device():Base(deviceTable.data(),DeviceKind){}} device,otherDevice;
struct Queue:Base {Queue():Base(queueTable.data(),QueueKind){}} queue,otherQueue;
struct Resource:Base {
    D3D12_RESOURCE_DESC desc{};
    std::vector<uint8_t> bytes;
    uint32_t pitch=0,tag=0,eye=0;
    uint64_t pending=0;
    bool mapped=false;
    D3D12_RESOURCE_STATES state=D3D12_RESOURCE_STATE_RENDER_TARGET;
    explicit Resource(const D3D12_RESOURCE_DESC& d):Base(resourceTable.data(),ResourceKind),desc(d) {
        pitch=UINT(desc.Width)*4+12;
        bytes.resize(desc.Dimension==D3D12_RESOURCE_DIMENSION_BUFFER?size_t(desc.Width):size_t(pitch)*desc.Height*desc.DepthOrArraySize,0xcd);
    }
};
struct Allocator:Base {uint64_t pending=0;Allocator():Base(allocatorTable.data(),AllocatorKind){}};
struct Copy {Resource *to,*from;D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint;UINT subresource;D3D12_BOX box;};
struct Commands:Base {
    Allocator* allocator=nullptr;
    std::vector<Copy> copies;
    Commands():Base(commandsTable.data(),CommandsKind){}
};
struct Event {char kind;uint32_t tag,eye;};
std::vector<Event> events;
Resource* sources[2][3]{};
uint32_t colors[2]{};
unsigned activeMaps=0,failMap=0,failCreate=0,liveObjects=0;
bool signalFailure=false,fenceSentinel=false;
ULONG STDMETHODCALLTYPE addRef(Base* self) {return ++self->references;}
ULONG STDMETHODCALLTYPE release(Base* self) {
    check(self->references>0,"balanced COM references");
    const ULONG left=--self->references;
    if (self->kind==ResourceKind) {
        auto* r=static_cast<Resource*>(self);
        if (left<=1 && r->pending) {
            check(device.lost||fenceSentinel||(activeFence&&activeFence->completed>=r->pending),"source/readback retained until fence completion");
            r->pending=0;
        }
        if (!left) {check(!r->mapped,"release after unmap");delete r;--liveObjects;}
    } else if (self->kind==DeviceKind||self->kind==QueueKind) {
        check(left>=1,"fixture device and queue keep owner reference");
    } else if (!left) {
        if(self->kind==AllocatorKind)delete static_cast<Allocator*>(self);
        if(self->kind==CommandsKind)delete static_cast<Commands*>(self);
        if(self->kind==FenceKind){check(activeFence==self,"one active mock fence");activeFence=nullptr;delete static_cast<Fence*>(self);}
        --liveObjects;
    }
    return left;
}
HRESULT STDMETHODCALLTYPE removed(Device* self){return self->lost?DXGI_ERROR_DEVICE_REMOVED:S_OK;}
HRESULT STDMETHODCALLTYPE createFence(Device*,UINT64,D3D12_FENCE_FLAGS,REFIID,void** out){
    check(!activeFence,"old fence retired before new pool");activeFence=new Fence;++liveObjects;*out=activeFence;return S_OK;
}
HRESULT STDMETHODCALLTYPE createAllocator(Device*,D3D12_COMMAND_LIST_TYPE type,REFIID,void** out){
    check(type==D3D12_COMMAND_LIST_TYPE_DIRECT,"direct allocator");*out=new Allocator;++liveObjects;return S_OK;
}
HRESULT STDMETHODCALLTYPE createCommands(Device*,UINT,D3D12_COMMAND_LIST_TYPE type,ID3D12CommandAllocator* allocator,ID3D12PipelineState*,REFIID,void** out){
    check(type==D3D12_COMMAND_LIST_TYPE_DIRECT,"direct commands");auto* c=new Commands;c->allocator=reinterpret_cast<Allocator*>(allocator);++liveObjects;*out=c;return S_OK;
}
HRESULT STDMETHODCALLTYPE createResource(Device*,const D3D12_HEAP_PROPERTIES* heap,D3D12_HEAP_FLAGS,const D3D12_RESOURCE_DESC* desc,D3D12_RESOURCE_STATES state,const D3D12_CLEAR_VALUE*,REFIID,void** out){
    if(failCreate&&!--failCreate)return E_OUTOFMEMORY;
    check(heap->Type==D3D12_HEAP_TYPE_READBACK&&desc->Dimension==D3D12_RESOURCE_DIMENSION_BUFFER&&state==D3D12_RESOURCE_STATE_COPY_DEST,"real readback heap/descriptor");
    auto* resource=new Resource(*desc);resource->state=state;++liveObjects;*out=resource;return S_OK;
}
void STDMETHODCALLTYPE footprints(Device*,const D3D12_RESOURCE_DESC* desc,UINT first,UINT count,UINT64 offset,D3D12_PLACED_SUBRESOURCE_FOOTPRINT* footprint,UINT* rows,UINT64* rowBytes,UINT64* bytes){
    check(first==0&&count==1&&offset==0&&desc->DepthOrArraySize==1,"cropped footprint request");
    *footprint={};footprint->Footprint={desc->Format,UINT(desc->Width),desc->Height,1,UINT((desc->Width*4+255)&~UINT64(255))};
    *rows=desc->Height;*rowBytes=desc->Width*4;*bytes=UINT64(footprint->Footprint.RowPitch)*desc->Height;
}
// MS x64 C++ methods place `this` before the hidden large-struct return pointer.
// A free function returning the struct would use the reverse argument order.
D3D12_RESOURCE_DESC* STDMETHODCALLTYPE resourceDesc(Resource* self,D3D12_RESOURCE_DESC* result){*result=self->desc;return result;}
HRESULT STDMETHODCALLTYPE allocatorReset(Allocator* self){check(!self->pending||device.lost||fenceSentinel||(activeFence&&activeFence->completed>=self->pending),"allocator not reset before completion");self->pending=0;return S_OK;}
HRESULT STDMETHODCALLTYPE commandsClose(Commands*){return S_OK;}
HRESULT STDMETHODCALLTYPE commandsReset(Commands* self,ID3D12CommandAllocator* allocator,ID3D12PipelineState*){self->allocator=reinterpret_cast<Allocator*>(allocator);self->copies.clear();return S_OK;}
void STDMETHODCALLTYPE barriers(Commands*,UINT count,const D3D12_RESOURCE_BARRIER* barriers){
    check(count==1&&barriers->Type==D3D12_RESOURCE_BARRIER_TYPE_TRANSITION,"one exact resource barrier");
    auto* resource=reinterpret_cast<Resource*>(barriers->Transition.pResource);
    check(resource->state==barriers->Transition.StateBefore,"expected application render-target resource state");
    check(barriers->Transition.Subresource<resource->desc.DepthOrArraySize*resource->desc.MipLevels,"barrier array slice");
    resource->state=barriers->Transition.StateAfter;
}
void STDMETHODCALLTYPE copy(Commands* self,const D3D12_TEXTURE_COPY_LOCATION* to,UINT x,UINT y,UINT z,const D3D12_TEXTURE_COPY_LOCATION* from,const D3D12_BOX* box){
    check(!x&&!y&&!z&&box&&to->Type==D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT&&from->Type==D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX,"texture region/footprint copy");
    auto* src=reinterpret_cast<Resource*>(from->pResource);auto* dst=reinterpret_cast<Resource*>(to->pResource);
    check(src->state==D3D12_RESOURCE_STATE_COPY_SOURCE&&!dst->mapped,"copy source state and unmapped destination");
    self->copies.push_back({dst,src,to->PlacedFootprint,from->SubresourceIndex,*box});events.push_back({'C',src->tag,src->eye});
}
void STDMETHODCALLTYPE execute(Queue*,UINT count,ID3D12CommandList* const* lists){
    check(count==1&&activeFence,"one batched list for both eyes");auto* c=reinterpret_cast<Commands*>(lists[0]);
    check(c->copies.size()==2,"atomic two-eye submission");const uint64_t pending=activeFence->signaled+1;
    c->allocator->pending=pending;
    for(const auto& copy:c->copies){
        auto* src=copy.from;auto* dst=copy.to;const auto& fp=copy.footprint;
        check(src->state==D3D12_RESOURCE_STATE_RENDER_TARGET,"source state restored before command submission");
        const UINT layer=copy.subresource/src->desc.MipLevels;
        check(copy.subresource%src->desc.MipLevels==0&&layer<src->desc.DepthOrArraySize,"array source layer");
        for(UINT row=0;row<fp.Footprint.Height;++row)
            std::memcpy(dst->bytes.data()+fp.Offset+size_t(row)*fp.Footprint.RowPitch,
                src->bytes.data()+(size_t(layer)*src->desc.Height+copy.box.top+row)*src->pitch+copy.box.left*4,fp.Footprint.Width*4);
        dst->tag=src->tag;dst->eye=src->eye;dst->pending=pending;src->pending=pending;
    }
    events.push_back({'X',c->copies[0].from->tag,0});
}
HRESULT STDMETHODCALLTYPE signalFence(Queue*,ID3D12Fence* fence,UINT64 value){
    if(signalFailure)return E_FAIL;
    auto* f=reinterpret_cast<Fence*>(fence);check(f==activeFence&&value>f->signaled,"monotonic queue fence");
    f->signaled=value;f->completed=value-1;events.push_back({'S',UINT(value),0});return S_OK;
}
UINT64 STDMETHODCALLTYPE completed(Fence* self){return fenceSentinel?UINT64_MAX:self->completed;}
HRESULT STDMETHODCALLTYPE completionEvent(Fence* self,UINT64 value,HANDLE event){
    // Only transitions/error cleanup need to advance the simulated GPU. The
    // steady pipeline already sees N-1 complete while current N remains pending.
    check(value<=self->signaled,"cannot wait for unsignaled work");self->completed=value;SetEvent(event);events.push_back({'W',UINT(value),0});return S_OK;
}
HRESULT STDMETHODCALLTYPE map(Resource* self,UINT subresource,const D3D12_RANGE* range,void** out){
    check(subresource==0&&range&&range->End<=self->bytes.size()&&!self->mapped,"map range and lifetime");
    check(activeFence&&self->pending<=activeFence->completed,"map only a completed capture, not the current GPU frame");
    if(failMap&&!--failMap)return E_FAIL;
    self->mapped=true;++activeMaps;*out=self->bytes.data();events.push_back({'M',self->tag,self->eye});return S_OK;
}
void STDMETHODCALLTYPE unmap(Resource* self,UINT subresource,const D3D12_RANGE* written){
    check(!subresource&&written&&!written->Begin&&!written->End&&self->mapped&&activeMaps,"read-only balanced unmap");self->mapped=false;--activeMaps;
}
template<class F>void slot(void** table,size_t index,F function){table[index]=reinterpret_cast<void*>(function);}
std::array<uint8_t,4> pixel(unsigned frame,unsigned eye,unsigned x,unsigned y,unsigned layer){
    return {uint8_t(frame*19+eye*83+x*7),uint8_t(1+y*37+frame*11),uint8_t(255-x*13-eye*17-layer*31),uint8_t(128+frame+x+y)};
}
void fill(Resource* resource,unsigned frame,unsigned eye){
    resource->tag=frame;resource->eye=eye;
    for(unsigned layer=0;layer<resource->desc.DepthOrArraySize;++layer)for(unsigned y=0;y<resource->desc.Height;++y)for(unsigned x=0;x<resource->desc.Width;++x){
        auto p=pixel(frame,eye,x,y,layer);if(basalt::readbackIsBgra(resource->desc.Format))std::swap(p[0],p[2]);
        std::memcpy(resource->bytes.data()+(size_t(layer)*resource->desc.Height+y)*resource->pitch+x*4,p.data(),4);
    }
}
void makeSources(DXGI_FORMAT left,DXGI_FORMAT right){
    for(unsigned eye=0;eye<2;++eye)for(unsigned index=0;index<3;++index){
        if(sources[eye][index])release(sources[eye][index]);
        D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;desc.Width=7;desc.Height=5;
        desc.DepthOrArraySize=2;desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Format=eye?right:left;
        sources[eye][index]=new Resource(desc);++liveObjects;
        colors[eye]=basalt::readbackFormatIsSrgb(desc.Format)?halliday::kColorSrgb:halliday::kColorLinear;
    }
}
basalt::PriorProjectionFrame submitted(unsigned frame,unsigned leftFlip=0,unsigned rightFlip=0){
    basalt::PriorProjectionFrame result{};result.producerEpoch=7;result.spaceEpoch=11;result.focusGeneration=2;result.fullGeometry=true;
    result.sourceDisplayTimeNs=5'000'000'000LL+frame*23'255'813LL;result.sourceClockKind=1;
    result.head.valid=1;result.head.stamp=float(frame);result.head.position[0]=frame*.01f;result.head.position[1]=1.6f;result.head.orientation[3]=1;
    for(unsigned eye=0;eye<2;++eye){
        auto& view=result.views[eye];view.swapchainId=eye+10;view.imageIndex=frame%3;view.imageArrayIndex=eye;view.rect={{1,1},{5,3}};
        view.pose.orientation={0,0,0,1};view.pose.position={result.head.position[0]+(eye?.032f:-.032f),1.6f,-.2f};const float zoom=.004f*frame*(eye+1);view.fov={-.7f+zoom,.8f-zoom,.9f-zoom,-.6f+zoom};
        const unsigned flips=(eye?rightFlip:leftFlip)^(frame&3u);if(flips&1)std::swap(view.fov.angleLeft,view.fov.angleRight);if(flips&2)std::swap(view.fov.angleUp,view.fov.angleDown);
        result.geometry[eye]=halliday::projection::fromSubmitted(view.pose,view.fov);
    }
    return result;
}
basalt::PriorStagingResult capture(const basalt::PriorProjectionFrame& frame,basalt::ReadbackImage images[2],basalt::PriorProjectionFrame* old,Device* d=&device,Queue* q=&queue){
    for(unsigned eye=0;eye<2;++eye)fill(sources[eye][frame.views[eye].imageIndex],unsigned(frame.head.stamp),eye);
    events.clear();return basalt::prepareD3D12PriorFrame(reinterpret_cast<ID3D12Device*>(d),reinterpret_cast<ID3D12CommandQueue*>(q),frame,images,old);
}
void verify(const basalt::ReadbackImage images[2],const basalt::PriorProjectionFrame& got,const basalt::PriorProjectionFrame& expected){
    check(basalt::samePriorProjectionLayout(got,expected)&&!std::memcmp(&got.head,&expected.head,sizeof(got.head)),"prior head and complete semantic packet retained");
    check(got.sourceDisplayTimeNs==expected.sourceDisplayTimeNs&&got.sourceClockKind==expected.sourceClockKind,
          "prior source timestamp retains actual 43 Hz spacing, never current completion time or nominal cadence");
    const auto order=basalt::stereoReadbackOrder(images,true);
    for(unsigned eye=0;eye<2;++eye){
        check(!std::memcmp(&got.views[eye].pose,&expected.views[eye].pose,sizeof(XrPosef))&&
            !std::memcmp(&got.views[eye].fov,&expected.views[eye].fov,sizeof(XrFovf))&&
            !std::memcmp(&got.geometry[eye],&expected.geometry[eye],sizeof(got.geometry[eye]))&&got.views[eye].imageIndex==expected.views[eye].imageIndex,"prior eye pose, full geometry and image index retained");
        const auto& image=images[eye];
        check(image.flipX==(expected.views[eye].fov.angleLeft>expected.views[eye].fov.angleRight)&&
            image.flipY==(expected.views[eye].fov.angleDown>expected.views[eye].fov.angleUp),"prior raw FOV owns both image flips");
        check(image.width==5&&image.height==3&&image.rowPitch==256&&image.colorSpace==colors[eye],"row padding, crop and gamma metadata");
        std::vector<uint8_t> output(5*3*4);basalt::copyReadbackImage(image,order.bgra,output.data());
        for(unsigned y=0;y<3;++y)for(unsigned x=0;x<5;++x){
            const auto value=pixel(unsigned(expected.head.stamp),eye,1+(image.flipX?4-x:x),1+(image.flipY?2-y:y),expected.views[eye].imageArrayIndex);
            const auto* actual=output.data()+(y*5+x)*4;
            check(actual[order.bgra?2:0]==value[0]&&actual[1]==value[1]&&actual[order.bgra?0:2]==value[2]&&actual[3]==value[3],"exact N-1 RGB/alpha/crop/array/flip/mixed-order bytes");
        }
    }
}
}
namespace basalt {
HallidayTransferStats& transferStatistics(){static HallidayTransferStats result{};return result;}
ID3D12Resource* retainSwapchainTexture12(const ControlFrameView& view){
    if(view.swapchainId<10||view.swapchainId>11||view.imageIndex>=3)return nullptr;
    auto* resource=sources[view.swapchainId-10][view.imageIndex];if(resource)addRef(resource);return reinterpret_cast<ID3D12Resource*>(resource);
}
ID3D11Texture2D* retainSwapchainTexture(const ControlFrameView&){return nullptr;}
uint32_t swapchainColourSpace(const ControlFrameView& view){return colors[view.swapchainId-10];}
}
LONG WINAPI crash(EXCEPTION_POINTERS* failure){
    std::fprintf(stderr,"FAIL: inert COM exception %08lx at %p\n",failure->ExceptionRecord->ExceptionCode,failure->ExceptionRecord->ExceptionAddress);
    ExitProcess(202);return EXCEPTION_EXECUTE_HANDLER;
}
int main(){SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX);SetUnhandledExceptionFilter(crash);try{
    for(auto* table:{deviceTable.data(),queueTable.data(),resourceTable.data(),allocatorTable.data(),commandsTable.data(),fenceTable.data()}){slot(table,1,addRef);slot(table,2,release);}
    slot(deviceTable.data(),9,createAllocator);slot(deviceTable.data(),12,createCommands);slot(deviceTable.data(),27,createResource);slot(deviceTable.data(),36,createFence);slot(deviceTable.data(),37,removed);slot(deviceTable.data(),38,footprints);
    slot(queueTable.data(),10,execute);slot(queueTable.data(),14,signalFence);
    slot(resourceTable.data(),8,map);slot(resourceTable.data(),9,unmap);slot(resourceTable.data(),10,resourceDesc);
    slot(allocatorTable.data(),8,allocatorReset);slot(commandsTable.data(),9,commandsClose);slot(commandsTable.data(),10,commandsReset);slot(commandsTable.data(),16,copy);slot(commandsTable.data(),26,barriers);
    slot(fenceTable.data(),8,completed);slot(fenceTable.data(),9,completionEvent);
    unsigned pairs=0;
    for(auto left:{DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB})for(auto right:{DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,DXGI_FORMAT_B8G8R8A8_UNORM})
    for(unsigned lf=0;lf<4;++lf)for(unsigned rf=0;rf<4;++rf){
        check(basalt::resetD3D12Readback(),"reset before format/layout case");makeSources(left,right);auto previous=submitted(1,lf,rf);
        for(unsigned frame=1;frame<=8;++frame){
            const auto current=submitted(frame,lf,rf);basalt::ReadbackImage images[2];basalt::PriorProjectionFrame old{};
            const auto result=capture(current,images,&old);
            check(events.size()>=4&&events[0].kind=='C'&&events[1].kind=='C'&&events[2].kind=='X'&&events[3].kind=='S',"both current copies submitted before prior mapping");
            if(frame==1)check(result==basalt::PriorStagingResult::Warmup&&!activeMaps&&!images[0].pixels&&!images[1].pixels,"warmup publishes no fabricated image");
            else{
                check(result==basalt::PriorStagingResult::Ready&&activeMaps==2,"one complete prior stereo capture");
                check(events.size()==6&&events[4].kind=='M'&&events[5].kind=='M'&&events[4].tag==frame-1&&events[5].tag==frame-1,"prior map never waits/maps current pixels");
                check(activeFence->completed<activeFence->signaled,"current GPU fence remains unfinished when End can return");verify(images,old,previous);++pairs;
            }
            basalt::finishD3D12PriorFrame();check(!activeMaps,"finish balances both maps");previous=current;
        }
    }
    check(basalt::resetD3D12Readback(),"reset main pairs");makeSources(DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM);
    auto seed=submitted(20);basalt::ReadbackImage images[2];basalt::PriorProjectionFrame old{};
    const auto warm=[&](const basalt::PriorProjectionFrame& f){check(capture(f,images,&old)==basalt::PriorStagingResult::Warmup&&!activeMaps,"generation/layout transition drops the old pair");};
    warm(seed);
    for(unsigned change=0;change<11;++change){auto next=seed;next.head.stamp+=change+1;
        switch(change){case 0:++next.spaceEpoch;break;case 1:++next.producerEpoch;break;case 2:next.focusGeneration+=2;break;
        case 3:++next.views[0].rect.offset.x;break;case 4:--next.views[1].rect.extent.width;break;case 5:++next.views[0].rect.offset.y;break;
        case 6:next.views[0].imageArrayIndex=1;break;case 7:++next.projectionOrder;break;case 8:colors[0]=halliday::kColorSrgb;break;
        case 9:for(auto* s:sources[1])s->desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;break;
        case 10:next.sourceClockKind=2;break;}warm(next);seed=next;
    }
    check(capture(seed,images,&old,&device,&otherQueue)==basalt::PriorStagingResult::Warmup,"queue replacement drops old pair");
    check(capture(seed,images,&old,&otherDevice,&otherQueue)==basalt::PriorStagingResult::Warmup,"device replacement drops old pair");
    check(basalt::resetD3D12Readback(),"reset transition tests");warm(seed);failMap=2;
    check(capture(seed,images,&old)==basalt::PriorStagingResult::Failed&&!activeMaps&&!images[0].pixels&&!images[1].pixels&&!basalt::transferStatistics().liveReadbackBuffers,"partial Map failure retires whole ring safely");
    failCreate=3;check(capture(seed,images,&old)==basalt::PriorStagingResult::Failed&&!basalt::transferStatistics().liveReadbackBuffers,"allocation failure before any submission");
    warm(seed);device.lost=true;check(capture(seed,images,&old)==basalt::PriorStagingResult::Failed&&!basalt::transferStatistics().liveReadbackBuffers,"device loss rejects source publication");device.lost=false;
    warm(seed);fenceSentinel=true;check(capture(seed,images,&old)==basalt::PriorStagingResult::Failed&&!activeMaps,"removal sentinel cannot publish success");fenceSentinel=false;
    signalFailure=true;check(capture(seed,images,&old)==basalt::PriorStagingResult::Failed,"failed queue Signal rejects publication");
    check(basalt::transferStatistics().liveReadbackBuffers==4&&!basalt::resetD3D12PriorReadback(),"unfenced GPU work retains all objects");
    signalFailure=false;check(!basalt::resetD3D12PriorReadback(),"recovery fence keeps resources until actual completion");
    activeFence->completed=activeFence->signaled;check(basalt::resetD3D12PriorReadback()&&!basalt::transferStatistics().liveReadbackBuffers,"later completion releases retained pool");
    warm(seed);check(basalt::prepareD3D12Frame(reinterpret_cast<ID3D12Device*>(&device),reinterpret_cast<ID3D12CommandQueue*>(&queue),seed.views,images),"synchronous fallback drains queued prior pair");
    check(basalt::transferStatistics().liveReadbackBuffers==2,"sync fallback owns only its current pair");basalt::finishD3D12Frame();warm(seed);
    check(basalt::transferStatistics().liveReadbackBuffers==4,"prior resume retires unused sync buffers and warms anew");
    check(basalt::resetD3D12Readback(),"final reset");for(auto& hand:sources)for(auto*& source:hand){release(source);source=nullptr;}
    const auto& stats=basalt::transferStatistics();check(!activeMaps&&!liveObjects&&!stats.liveReadbackBuffers&&!stats.liveCommandAllocators&&!stats.liveCommandLists&&!stats.liveFences&&!stats.liveEvents&&device.references==1&&otherDevice.references==1&&queue.references==1&&otherQueue.references==1,"all resource/device/queue lifetimes balanced");
    std::printf("PASS: %u exact D3D12 N-1 pairs; current fence stays pending, animated full FOV/metadata/color/layout/flips, lifetime/error/reset/sync fallback; inert COM, no GPU\n",pairs);return 0;
}catch(const std::exception& error){std::fprintf(stderr,"FAIL: %s\n",error.what());return 1;}}
