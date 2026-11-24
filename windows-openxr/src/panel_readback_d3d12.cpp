// Independent persistent D3D12 panel readback. A separate pool keeps panel
// sizes from reallocating or invalidating projection-eye staging resources.
// One ordered command list/fence covers up to eight panel rectangles.
#include "readback.hpp"
#include <algorithm>
#include <array>
#include <new>
#include <vector>

namespace basalt { bool resetD3D12Panels(); }
namespace {
constexpr uint32_t kPanels = 8;
struct Buffer {
    ID3D12Resource* resource = nullptr;
    uint64_t capacity = 0, bytes = 0;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    uint32_t width = 0, height = 0;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
};
struct Pool {
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    ID3D12CommandAllocator* allocator = nullptr;
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Fence* fence = nullptr;
    HANDLE event = nullptr;
    std::array<Buffer,kPanels> buffers{};
    std::array<ID3D12Resource*,kPanels> pendingSources{};
    uint64_t nextValue = 0, pendingValue = 0;
    bool inFlight = false, signalQueued = false, faulted = false;
} pool;
struct Source {
    ID3D12Resource* value = nullptr;
    ~Source() { if(value) value->Release(); }
    ID3D12Resource* take() { auto* p=value; value=nullptr; return p; }
};
bool removed() { return pool.device && FAILED(pool.device->GetDeviceRemovedReason()); }
void releaseSources() {
    for(auto*& source:pool.pendingSources) if(source) { source->Release();source=nullptr; }
}
bool completed() {
    if(!pool.inFlight) return true;
    if(removed()) { pool.inFlight=false;releaseSources();return true; }
    if(!pool.signalQueued || !pool.fence) return false;
    const auto value=pool.fence->GetCompletedValue();
    if(value==UINT64_MAX) pool.faulted=true; // Device removal is not a successful frame.
    if(value==UINT64_MAX || value>=pool.pendingValue) {
        pool.inFlight=false;releaseSources();return true;
    }
    return false;
}
bool waitForBatch() {
    const auto start=GetTickCount64();bool eventReady=false;
    if(pool.event) {
        ResetEvent(pool.event);
        eventReady=SUCCEEDED(pool.fence->SetEventOnCompletion(pool.pendingValue,pool.event));
    }
    while(!completed()) {
        if(GetTickCount64()-start>=5000) { pool.faulted=true;return false; }
        if(eventReady) {
            if(WaitForSingleObject(pool.event,10)==WAIT_FAILED) eventReady=false;
        } else Sleep(1);
    }
    return !removed() && !pool.faulted;
}
bool ensurePool(ID3D12Device* device,ID3D12CommandQueue* queue) {
    if(pool.device==device && pool.queue==queue) return !pool.faulted;
    if(!basalt::resetD3D12Panels()) return false;
    pool.device=device;pool.queue=queue;device->AddRef();queue->AddRef();
    HRESULT result=device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&pool.allocator));
    if(SUCCEEDED(result)) {
        result=device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,pool.allocator,nullptr,IID_PPV_ARGS(&pool.commands));
        if(SUCCEEDED(result)) result=pool.commands->Close();
    }
    if(SUCCEEDED(result)) result=device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&pool.fence));
    if(SUCCEEDED(result)) { pool.event=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!pool.event) result=E_OUTOFMEMORY; }
    pool.faulted=FAILED(result);return !pool.faulted;
}
bool ensureBuffer(ID3D12Device* device,Buffer& output,const D3D12_RESOURCE_DESC& source,uint32_t width,uint32_t height) {
    auto rectangle=source;rectangle.Width=width;rectangle.Height=height;
    rectangle.DepthOrArraySize=rectangle.MipLevels=1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT rows=0;UINT64 rowBytes=0,bytes=0;
    device->GetCopyableFootprints(&rectangle,0,1,0,&footprint,&rows,&rowBytes,&bytes);
    if(!bytes || rows!=height || rowBytes!=uint64_t(width)*4) return false;
    if(!output.resource || output.capacity<bytes) {
        D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_READBACK;heap.CreationNodeMask=heap.VisibleNodeMask=1;
        D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=bytes;
        desc.Height=desc.DepthOrArraySize=desc.MipLevels=desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ID3D12Resource* created=nullptr;
        if(FAILED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,D3D12_RESOURCE_STATE_COPY_DEST,
            nullptr,IID_PPV_ARGS(&created)))) return false;
        if(output.resource) output.resource->Release();output.resource=created;output.capacity=bytes;
    }
    output.bytes=bytes;output.footprint=footprint;output.width=width;output.height=height;output.format=source.Format;
    return true;
}
}
namespace basalt {
bool resetD3D12Panels() {
    if(!completed()) {
        // A failed Signal after Execute does not prove the copy was cancelled.
        // Obtain a new ordered completion point, or retain every GPU resource.
        if(!pool.signalQueued && pool.fence && pool.queue && !removed() && pool.nextValue<UINT64_MAX-1) {
            pool.pendingValue=++pool.nextValue;
            if(SUCCEEDED(pool.queue->Signal(pool.fence,pool.pendingValue))) pool.signalQueued=true;
        }
        if(!completed()) { pool.faulted=true;return false; }
    }
    releaseSources();
    for(auto& buffer:pool.buffers) if(buffer.resource) buffer.resource->Release();
    if(pool.commands) pool.commands->Release();if(pool.allocator) pool.allocator->Release();
    if(pool.fence) pool.fence->Release();if(pool.event) CloseHandle(pool.event);
    if(pool.queue) pool.queue->Release();if(pool.device) pool.device->Release();
    pool={};return true;
}
bool readD3D12Panels(ID3D12Device* device,ID3D12CommandQueue* queue,const ControlFrameView* views,uint32_t count,
                    std::vector<std::vector<uint8_t>>& pixels,std::vector<ReadbackImage>& images) {
    images.clear();
    if(!count) { pixels.clear();return true; }
    if(count>kPanels || !views || !device || !queue || FAILED(device->GetDeviceRemovedReason()) ||
        queue->GetDesc().Type!=D3D12_COMMAND_LIST_TYPE_DIRECT || !ensurePool(device,queue) || !completed() ||
        pool.nextValue>=UINT64_MAX-1) return false;
    std::array<Source,kPanels> sources;std::array<D3D12_RESOURCE_DESC,kPanels> descriptions{};
    for(uint32_t i=0;i<count;++i) {
        sources[i].value=retainSwapchainTexture12(views[i]);if(!sources[i].value) return false;
        const auto& desc=descriptions[i]=sources[i].value->GetDesc();const auto& rect=views[i].rect;
        const bool supported=desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM||desc.Format==DXGI_FORMAT_B8G8R8A8_UNORM_SRGB||
            desc.Format==DXGI_FORMAT_B8G8R8A8_TYPELESS||desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM||
            desc.Format==DXGI_FORMAT_R8G8B8A8_UNORM_SRGB||desc.Format==DXGI_FORMAT_R8G8B8A8_TYPELESS;
        if(!supported || desc.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || !desc.MipLevels || desc.SampleDesc.Count!=1 ||
            views[i].imageArrayIndex>=desc.DepthOrArraySize || rect.offset.x<0 || rect.offset.y<0 ||
            rect.extent.width<=0 || rect.extent.height<=0 || uint64_t(rect.offset.x)+uint32_t(rect.extent.width)>desc.Width ||
            uint64_t(rect.offset.y)+uint32_t(rect.extent.height)>desc.Height ||
            !ensureBuffer(device,pool.buffers[i],desc,rect.extent.width,rect.extent.height)) return false;
    }
    // Allocate owned output before starting GPU work; Map results never escape.
    try {
        pixels.resize(count);images.resize(count);
        for(uint32_t i=0;i<count;++i) pixels[i].resize(size_t(pool.buffers[i].width)*pool.buffers[i].height*4);
    } catch(const std::bad_alloc&) { images.clear();return false; }
    if(FAILED(pool.allocator->Reset()) || FAILED(pool.commands->Reset(pool.allocator,nullptr))) { pool.faulted=true;images.clear();return false; }
    for(uint32_t i=0;i<count;++i) {
        const auto& view=views[i];const auto& desc=descriptions[i];const UINT subresource=view.imageArrayIndex*desc.MipLevels;
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={sources[i].value,subresource,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE};
        pool.commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION from{};from.pResource=sources[i].value;from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=subresource;
        D3D12_TEXTURE_COPY_LOCATION to{};to.pResource=pool.buffers[i].resource;to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=pool.buffers[i].footprint;
        const D3D12_BOX box{UINT(view.rect.offset.x),UINT(view.rect.offset.y),0,
            UINT(view.rect.offset.x+view.rect.extent.width),UINT(view.rect.offset.y+view.rect.extent.height),1};
        pool.commands->CopyTextureRegion(&to,0,0,0,&from,&box);
        std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);pool.commands->ResourceBarrier(1,&barrier);
    }
    if(FAILED(pool.commands->Close())) { pool.faulted=true;images.clear();return false; }
    for(uint32_t i=0;i<count;++i) pool.pendingSources[i]=sources[i].take();
    pool.pendingValue=++pool.nextValue;pool.signalQueued=false;pool.inFlight=true;
    ID3D12CommandList* commands[]{pool.commands};queue->ExecuteCommandLists(1,commands);
    if(FAILED(queue->Signal(pool.fence,pool.pendingValue))) { pool.faulted=true;images.clear();return false; }
    pool.signalQueued=true;
    if(!waitForBatch()) { images.clear();return false; }
    for(uint32_t i=0;i<count;++i) {
        const auto& buffer=pool.buffers[i];const D3D12_RANGE range{0,SIZE_T(buffer.bytes)};void* mapped=nullptr;
        if(FAILED(buffer.resource->Map(0,&range,&mapped))) { images.clear();return false; }
        const ReadbackImage input{static_cast<const uint8_t*>(mapped)+buffer.footprint.Offset,buffer.width,buffer.height,
            buffer.footprint.Footprint.RowPitch,buffer.format,swapchainColourSpace(views[i])};
        copyReadbackImage(input,true,pixels[i].data());
        const D3D12_RANGE written{0,0};buffer.resource->Unmap(0,&written);
        images[i]={pixels[i].data(),buffer.width,buffer.height,buffer.width*4,DXGI_FORMAT_B8G8R8A8_UNORM,input.colorSpace};
    }
    return true;
}
}
