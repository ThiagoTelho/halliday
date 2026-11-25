// Pooled D3D12 readback. One command list and one completion wait for BOTH eyes.
// The pool never queues another frame before the preceding one is complete.
// XR_KHR_D3D12_enable requires color images in RENDER_TARGET state at wait/release.
#include "readback.hpp"
#include "frame_timing.hpp"
#include "d3d12_prior_staging.hpp"
#include <algorithm>

namespace {
struct Eye {
    ID3D12Resource* buffer = nullptr;
    uint64_t capacity = 0,bytes = 0;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    uint32_t width = 0,height = 0;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    bool mapped = false;
};
struct Pool {
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    ID3D12CommandAllocator* allocator = nullptr;
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Fence* fence = nullptr;
    HANDLE event = nullptr;
    Eye eyes[2];
    ID3D12Resource* pendingSources[2]{};
    uint64_t nextValue = 0,pendingValue = 0;
    bool inFlight = false,signalQueued = false,faulted = false;
} pool;
struct Source {
    ID3D12Resource* value = nullptr;
    ~Source() { if (value) value->Release(); }
    ID3D12Resource* take() { auto* result = value; value = nullptr; return result; }
};
bool removed() {
    return pool.device && FAILED(pool.device->GetDeviceRemovedReason());
}
void releaseSources() {
    for (auto*& source : pool.pendingSources) if (source) { source->Release(); source = nullptr; }
}
bool completed() {
    if (!pool.inFlight) return true;
    if (removed()) { pool.inFlight = false; releaseSources(); return true; }
    if (!pool.signalQueued || !pool.fence) return false;
    const uint64_t value = pool.fence->GetCompletedValue();
    if (value == UINT64_MAX) pool.faulted = true; // Device removal cannot publish a successful frame.
    if (value == UINT64_MAX || value >= pool.pendingValue) {
        pool.inFlight = false; releaseSources(); return true;
    }
    return false;
}
bool waitForFrame() {
    ++basalt::transferStatistics().fenceWaits;
    const uint64_t start = GetTickCount64();
    bool eventReady = false;
    if (pool.event) {
        ResetEvent(pool.event);
        eventReady = SUCCEEDED(pool.fence->SetEventOnCompletion(pool.pendingValue,pool.event));
    }
    while (!completed()) {
        if (GetTickCount64()-start >= 5000) {
            // Never free/reset resources the GPU may still own. Teardown can
            // collect them after the fence completes or the device is removed.
            pool.faulted = true; return false;
        }
        if (eventReady) {
            if (WaitForSingleObject(pool.event,10) == WAIT_FAILED) eventReady = false;
        } else Sleep(1);
    }
    return !removed() && !pool.faulted;
}
void releaseEye(Eye& eye) {
    if (eye.mapped) { const D3D12_RANGE written{0,0}; eye.buffer->Unmap(0,&written); }
    if (eye.buffer) {
        eye.buffer->Release(); --basalt::transferStatistics().liveReadbackBuffers;
    }
    eye = {};
}
bool ensurePool(ID3D12Device* device,ID3D12CommandQueue* queue) {
    if (pool.device == device && pool.queue == queue) return !pool.faulted;
    if (!basalt::resetD3D12Readback()) return false;
    pool.device = device; pool.queue = queue; device->AddRef(); queue->AddRef();
    auto& stats = basalt::transferStatistics();
    HRESULT status = device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&pool.allocator));
    if (SUCCEEDED(status)) { ++stats.allocatorCreates; ++stats.liveCommandAllocators; }
    if (SUCCEEDED(status)) {
        status = device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,pool.allocator,nullptr,
            IID_PPV_ARGS(&pool.commands));
        if (SUCCEEDED(status)) { ++stats.commandListCreates; ++stats.liveCommandLists; status = pool.commands->Close(); }
    }
    if (SUCCEEDED(status)) {
        status = device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&pool.fence));
        if (SUCCEEDED(status)) { ++stats.fenceCreates; ++stats.liveFences; }
    }
    if (SUCCEEDED(status)) {
        pool.event = CreateEventW(nullptr,FALSE,FALSE,nullptr);
        if (pool.event) { ++stats.eventCreates; ++stats.liveEvents; } else status = E_OUTOFMEMORY;
    }
    pool.faulted = FAILED(status);
    return !pool.faulted;
}
bool ensureEye(ID3D12Device* device,Eye& eye,const D3D12_RESOURCE_DESC& original,
               uint32_t width,uint32_t height) {
    auto rectangle = original;
    rectangle.Width = width; rectangle.Height = height;
    rectangle.DepthOrArraySize = rectangle.MipLevels = 1;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0; UINT64 rowBytes = 0,bytes = 0;
    device->GetCopyableFootprints(&rectangle,0,1,0,&footprint,&rows,&rowBytes,&bytes);
    if (!bytes || rows != height || rowBytes != uint64_t(width)*4) return false;
    if (!eye.buffer || eye.capacity < bytes) {
        D3D12_HEAP_PROPERTIES heap{}; heap.Type = D3D12_HEAP_TYPE_READBACK;
        heap.CreationNodeMask = heap.VisibleNodeMask = 1;
        D3D12_RESOURCE_DESC desc{}; desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = bytes; desc.Height = desc.DepthOrArraySize = desc.MipLevels = desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        ID3D12Resource* buffer = nullptr;
        if (FAILED(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,
            D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&buffer)))) return false;
        releaseEye(eye);
        eye.buffer = buffer; eye.capacity = bytes;
        auto& stats = basalt::transferStatistics(); ++stats.readbackBufferCreates; ++stats.liveReadbackBuffers;
    }
    // Untyped buffers can survive shrinking or equal-size format changes.
    // Only the current footprint/format changes, after previous GPU completion.
    eye.bytes = bytes; eye.footprint = footprint; eye.width = width; eye.height = height; eye.format = original.Format;
    return true;
}
}

namespace basalt {
namespace {
struct PriorPair12 {
    Eye eyes[2];
    ID3D12CommandAllocator* allocator = nullptr;
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Resource* sources[2]{};
    D3D12_RESOURCE_DESC descriptors[2]{};
    uint32_t colorSpaces[2]{};
    PriorProjectionFrame frame{};
    uint64_t fenceValue = 0;
    bool inFlight = false,signalQueued = false,valid = false;
};
struct PriorPool12 {
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    ID3D12Fence* fence = nullptr;
    HANDLE event = nullptr;
    PriorPair12 pairs[2];
    uint64_t nextValue = 0;
    unsigned write = 0;
    bool faulted = false;
} prior12;
bool priorRemoved12() {
    return prior12.device && FAILED(prior12.device->GetDeviceRemovedReason());
}
void releasePriorSources12(PriorPair12& pair) {
    for (auto*& source : pair.sources) if (source) {source->Release();source=nullptr;}
}
bool priorCompleted12(PriorPair12& pair) {
    if (!pair.inFlight) return true;
    if (priorRemoved12()) {pair.inFlight=false;releasePriorSources12(pair);return true;}
    if (!pair.signalQueued || !prior12.fence) return false;
    const uint64_t value=prior12.fence->GetCompletedValue();
    if (value==UINT64_MAX) prior12.faulted=true;
    if (value==UINT64_MAX || value>=pair.fenceValue) {
        pair.inFlight=false;releasePriorSources12(pair);return true;
    }
    return false;
}
bool waitPrior12(PriorPair12& pair) {
    if (priorCompleted12(pair)) return true;
    ++transferStatistics().fenceWaits;
    const uint64_t began=GetTickCount64();
    bool eventReady=false;
    if (prior12.event && prior12.fence && pair.signalQueued) {
        ResetEvent(prior12.event);
        eventReady=SUCCEEDED(prior12.fence->SetEventOnCompletion(pair.fenceValue,prior12.event));
    }
    while (!priorCompleted12(pair)) {
        if (GetTickCount64()-began>=5000) {prior12.faulted=true;return false;}
        if (eventReady) {
            if (WaitForSingleObject(prior12.event,10)==WAIT_FAILED) eventReady=false;
        } else Sleep(1);
    }
    return true;
}
bool sameDescriptor12(const D3D12_RESOURCE_DESC& a,const D3D12_RESOURCE_DESC& b) {
    return a.Dimension==b.Dimension && a.Alignment==b.Alignment && a.Width==b.Width && a.Height==b.Height &&
        a.DepthOrArraySize==b.DepthOrArraySize && a.MipLevels==b.MipLevels && a.Format==b.Format &&
        a.SampleDesc.Count==b.SampleDesc.Count && a.SampleDesc.Quality==b.SampleDesc.Quality &&
        a.Layout==b.Layout && a.Flags==b.Flags;
}
bool createPriorPool12(ID3D12Device* device,ID3D12CommandQueue* queue) {
    prior12.device=device;prior12.queue=queue;device->AddRef();queue->AddRef();
    auto& stats=transferStatistics();
    HRESULT status=device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&prior12.fence));
    if (SUCCEEDED(status)) {++stats.fenceCreates;++stats.liveFences;}
    if (SUCCEEDED(status)) {
        prior12.event=CreateEventW(nullptr,FALSE,FALSE,nullptr);
        if (prior12.event) {++stats.eventCreates;++stats.liveEvents;} else status=E_OUTOFMEMORY;
    }
    for (auto& pair:prior12.pairs) {
        if (FAILED(status)) break;
        status=device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&pair.allocator));
        if (SUCCEEDED(status)) {++stats.allocatorCreates;++stats.liveCommandAllocators;}
        if (SUCCEEDED(status)) {
            status=device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,pair.allocator,nullptr,IID_PPV_ARGS(&pair.commands));
            if (SUCCEEDED(status)) {++stats.commandListCreates;++stats.liveCommandLists;status=pair.commands->Close();}
        }
    }
    prior12.faulted=FAILED(status);
    return !prior12.faulted;
}
}

void finishD3D12PriorFrame() {
    for (auto& pair:prior12.pairs) for (auto& eye:pair.eyes) if (eye.mapped) {
        const D3D12_RANGE written{0,0};eye.buffer->Unmap(0,&written);eye.mapped=false;
    }
}
bool resetD3D12PriorReadback() {
    finishD3D12PriorFrame();
    for (auto& pair:prior12.pairs) {
        if (!priorCompleted12(pair)) {
            // An Execute with failed Signal still owns its sources/allocator.
            // Obtain an ordered completion fence before any release or reuse.
            if (!pair.signalQueued && prior12.fence && prior12.queue && !priorRemoved12() && prior12.nextValue<UINT64_MAX-1) {
                pair.fenceValue=++prior12.nextValue;
                if (SUCCEEDED(prior12.queue->Signal(prior12.fence,pair.fenceValue))) {
                    pair.signalQueued=true;++transferStatistics().fenceSignals;
                }
            }
            if (!priorCompleted12(pair)) {
                // Never double-wait a timed-out/faulted queue, or free objects
                // when an ordered Signal could not be obtained.
                if (prior12.faulted || !pair.signalQueued || !waitPrior12(pair)) return false;
            }
        }
    }
    for (auto& pair:prior12.pairs) {
        releasePriorSources12(pair);
        for (auto& eye:pair.eyes) releaseEye(eye);
        auto& stats=transferStatistics();
        if (pair.commands) {pair.commands->Release();--stats.liveCommandLists;}
        if (pair.allocator) {pair.allocator->Release();--stats.liveCommandAllocators;}
    }
    auto& stats=transferStatistics();
    if (prior12.fence) {prior12.fence->Release();--stats.liveFences;}
    if (prior12.event) {CloseHandle(prior12.event);--stats.liveEvents;}
    if (prior12.queue) prior12.queue->Release();
    if (prior12.device) prior12.device->Release();
    prior12={};return true;
}

PriorStagingResult prepareD3D12PriorFrame(ID3D12Device* device,ID3D12CommandQueue* queue,
    const PriorProjectionFrame& frame,ReadbackImage images[2],PriorProjectionFrame* captured) {
    if (images) {images[0]={};images[1]={};}
    const auto fail=[&]() {resetD3D12PriorReadback();return PriorStagingResult::Failed;};
    if (!device || !queue || !images || !captured || FAILED(device->GetDeviceRemovedReason())) return fail();
    finishD3D12PriorFrame();
    Source sources[2];D3D12_RESOURCE_DESC descriptors[2]{};uint32_t colors[2]{};
    bool compatible=prior12.device==device && prior12.queue==queue && !prior12.faulted;
    const auto& previous=prior12.pairs[1-prior12.write];
    if (previous.valid && !samePriorProjectionLayout(previous.frame,frame)) compatible=false;
    for (unsigned eye=0;eye<2;++eye) {
        const auto& view=frame.views[eye];const auto& rect=view.rect;
        sources[eye].value=retainSwapchainTexture12(view);
        if (!sources[eye].value) return fail();
        descriptors[eye]=sources[eye].value->GetDesc();
        const auto& desc=descriptors[eye];
        if (desc.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || !desc.MipLevels ||
            rect.offset.x<0 || rect.offset.y<0 || rect.extent.width<=0 || rect.extent.height<=0 ||
            uint64_t(rect.offset.x)+uint32_t(rect.extent.width)>desc.Width ||
            uint64_t(rect.offset.y)+uint32_t(rect.extent.height)>desc.Height ||
            view.imageArrayIndex>=desc.DepthOrArraySize || desc.SampleDesc.Count!=1) return fail();
        colors[eye]=swapchainColourSpace(view);
        if (previous.valid && (!sameDescriptor12(previous.descriptors[eye],desc) || previous.colorSpaces[eye]!=colors[eye])) compatible=false;
    }
    if (!compatible && !resetD3D12PriorReadback()) return PriorStagingResult::Failed;
    if (!prior12.device) {
        // Retire a previous synchronous allocation before adding four buffers.
        if (pool.device && !resetD3D12Readback()) return PriorStagingResult::Failed;
        if (!createPriorPool12(device,queue)) return fail();
    }
    if (prior12.nextValue>=UINT64_MAX-1) return fail();
    // Both pairs are fully allocated before any GPU copy, so allocation failure
    // cannot yield a partial eye or a mismatched metadata packet.
    for (auto& pair:prior12.pairs) for (unsigned eye=0;eye<2;++eye)
        if (!ensureEye(device,pair.eyes[eye],descriptors[eye],frame.views[eye].rect.extent.width,frame.views[eye].rect.extent.height)) return fail();
    auto& write=prior12.pairs[prior12.write];
    if (!priorCompleted12(write)) return fail();
    timing::Span copyTiming(timing::Phase::CopySubmit);
    if (FAILED(write.allocator->Reset()) || FAILED(write.commands->Reset(write.allocator,nullptr))) return fail();
    for (unsigned eye=0;eye<2;++eye) {
        const auto& view=frame.views[eye];const UINT subresource=view.imageArrayIndex*descriptors[eye].MipLevels;
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={sources[eye].value,subresource,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE};
        write.commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION from{};from.pResource=sources[eye].value;
        from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;from.SubresourceIndex=subresource;
        D3D12_TEXTURE_COPY_LOCATION to{};to.pResource=write.eyes[eye].buffer;
        to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=write.eyes[eye].footprint;
        const D3D12_BOX box{UINT(view.rect.offset.x),UINT(view.rect.offset.y),0,
            UINT(view.rect.offset.x+view.rect.extent.width),UINT(view.rect.offset.y+view.rect.extent.height),1};
        write.commands->CopyTextureRegion(&to,0,0,0,&from,&box);
        std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);
        write.commands->ResourceBarrier(1,&barrier);
        write.descriptors[eye]=descriptors[eye];write.colorSpaces[eye]=colors[eye];
    }
    if (FAILED(write.commands->Close())) return fail();
    for (unsigned eye=0;eye<2;++eye) write.sources[eye]=sources[eye].take();
    write.fenceValue=++prior12.nextValue;write.signalQueued=false;write.inFlight=true;
    ID3D12CommandList* commands[]={write.commands};queue->ExecuteCommandLists(1,commands);
    auto& stats=transferStatistics();++stats.queueSubmissions;stats.copyCommands+=2;
    stats.peakFramesInFlight=std::max<uint64_t>(stats.peakFramesInFlight,2);
    if (FAILED(queue->Signal(prior12.fence,write.fenceValue))) {prior12.faulted=true;return fail();}
    write.signalQueued=true;++stats.fenceSignals;write.frame=frame;write.valid=true;
    prior12.write=1-prior12.write;copyTiming.finish();
    auto& read=prior12.pairs[prior12.write];
    if (!read.valid) return PriorStagingResult::Warmup;
    bool ready=false;
    {timing::Span waitTiming(timing::Phase::GpuWait);ready=waitPrior12(read);}
    if (!ready || prior12.faulted || priorRemoved12()) return fail();
    for (unsigned eye=0;eye<2;++eye) {
        auto& buffer=read.eyes[eye];const D3D12_RANGE range{0,static_cast<SIZE_T>(buffer.bytes)};
        void* mapped=nullptr;++stats.mapCalls;
        timing::Span mapTiming(eye?timing::Phase::MapRight:timing::Phase::MapLeft);
        const auto result=buffer.buffer->Map(0,&range,&mapped);mapTiming.finish();
        if (FAILED(result)) {images[0]={};images[1]={};return fail();}
        buffer.mapped=true;const auto& fov=read.frame.views[eye].fov;
        images[eye]={static_cast<const uint8_t*>(mapped)+buffer.footprint.Offset,buffer.width,buffer.height,
            buffer.footprint.Footprint.RowPitch,buffer.format,read.colorSpaces[eye],
            fov.angleLeft>fov.angleRight,fov.angleDown>fov.angleUp};
    }
    *captured=read.frame;return PriorStagingResult::Ready;
}

void finishD3D12Frame() {
    finishD3D12PriorFrame();
    for (auto& eye : pool.eyes) if (eye.mapped) {
        const D3D12_RANGE written{0,0}; eye.buffer->Unmap(0,&written); eye.mapped = false;
    }
}
bool resetD3D12Readback() {
    if (!resetD3D12PriorReadback()) return false;
    if (!completed()) {
        // If Signal failed after Execute, obtain an ordered fence before
        // releasing anything. Keep a still-running pool intact on failure.
        if (!pool.signalQueued && pool.fence && pool.queue && !removed() && pool.nextValue < UINT64_MAX-1) {
            pool.pendingValue = ++pool.nextValue;
            if (SUCCEEDED(pool.queue->Signal(pool.fence,pool.pendingValue))) {
                pool.signalQueued = true; ++transferStatistics().fenceSignals;
            }
        }
        if (!completed()) { pool.faulted = true; return false; }
    }
    finishD3D12Frame(); releaseSources();
    for (auto& eye : pool.eyes) releaseEye(eye);
    auto& stats = transferStatistics();
    if (pool.commands) { pool.commands->Release(); --stats.liveCommandLists; }
    if (pool.allocator) { pool.allocator->Release(); --stats.liveCommandAllocators; }
    if (pool.fence) { pool.fence->Release(); --stats.liveFences; }
    if (pool.event) { CloseHandle(pool.event); --stats.liveEvents; }
    if (pool.queue) pool.queue->Release();
    if (pool.device) pool.device->Release();
    pool = {};
    return true;
}
bool prepareD3D12Frame(ID3D12Device* device,ID3D12CommandQueue* queue,
                      const ControlFrameView views[2],ReadbackImage images[2]) {
    // Synchronous/quad/alpha fallback must never leave a prior projection that
    // could later be combined with a different current composition.
    if (!resetD3D12PriorReadback()) return false;
    if (!device || !queue || FAILED(device->GetDeviceRemovedReason()) || !ensurePool(device,queue) ||
        !completed() || pool.nextValue >= UINT64_MAX-1) return false;
    finishD3D12Frame();
    Source sources[2]; D3D12_RESOURCE_DESC originals[2]{};
    for (unsigned eye = 0; eye < 2; ++eye) {
        sources[eye].value = retainSwapchainTexture12(views[eye]);
        if (!sources[eye].value) return false;
        originals[eye] = sources[eye].value->GetDesc();
        const auto& rect = views[eye].rect;
        if (rect.offset.x < 0 || rect.offset.y < 0 || rect.extent.width <= 0 || rect.extent.height <= 0 ||
            uint64_t(rect.offset.x)+uint32_t(rect.extent.width) > originals[eye].Width ||
            uint64_t(rect.offset.y)+uint32_t(rect.extent.height) > originals[eye].Height ||
            views[eye].imageArrayIndex >= originals[eye].DepthOrArraySize || originals[eye].SampleDesc.Count != 1)
            return false;
        if (!ensureEye(device,pool.eyes[eye],originals[eye],rect.extent.width,rect.extent.height)) return false;
    }
    timing::Span copyTiming(timing::Phase::CopySubmit);
    if (FAILED(pool.allocator->Reset()) || FAILED(pool.commands->Reset(pool.allocator,nullptr))) {
        pool.faulted = true; return false;
    }
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& view = views[eye];
        const UINT subresource = view.imageArrayIndex*originals[eye].MipLevels;
        D3D12_RESOURCE_BARRIER barrier{}; barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition = {sources[eye].value,subresource,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE};
        pool.commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION from{}; from.pResource = sources[eye].value;
        from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; from.SubresourceIndex = subresource;
        D3D12_TEXTURE_COPY_LOCATION to{}; to.pResource = pool.eyes[eye].buffer;
        to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; to.PlacedFootprint = pool.eyes[eye].footprint;
        const D3D12_BOX box{static_cast<UINT>(view.rect.offset.x),static_cast<UINT>(view.rect.offset.y),0,
            static_cast<UINT>(view.rect.offset.x+view.rect.extent.width),
            static_cast<UINT>(view.rect.offset.y+view.rect.extent.height),1};
        pool.commands->CopyTextureRegion(&to,0,0,0,&from,&box);
        std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);
        pool.commands->ResourceBarrier(1,&barrier);
    }
    if (FAILED(pool.commands->Close())) { pool.faulted = true; return false; }
    for (unsigned eye = 0; eye < 2; ++eye) pool.pendingSources[eye] = sources[eye].take();
    pool.pendingValue = ++pool.nextValue; pool.signalQueued = false; pool.inFlight = true;
    ID3D12CommandList* lists[] = {pool.commands}; queue->ExecuteCommandLists(1,lists);
    auto& stats = transferStatistics();
    ++stats.queueSubmissions; stats.copyCommands += 2;
    stats.peakFramesInFlight = std::max<uint64_t>(stats.peakFramesInFlight,1);
    if (FAILED(queue->Signal(pool.fence,pool.pendingValue))) { pool.faulted = true; return false; }
    pool.signalQueued = true; ++stats.fenceSignals;
    copyTiming.finish();
    bool ready=false;
    {timing::Span fenceTiming(timing::Phase::GpuWait);ready=waitForFrame();}
    if (!ready) { pool.faulted = true; return false; }
    for (unsigned eye = 0; eye < 2; ++eye) {
        auto& buffer = pool.eyes[eye];
        const D3D12_RANGE readRange{0,static_cast<SIZE_T>(buffer.bytes)};
        void* mapped = nullptr; ++stats.mapCalls;
        timing::Span mapTiming(eye?timing::Phase::MapRight:timing::Phase::MapLeft);
        const auto status=buffer.buffer->Map(0,&readRange,&mapped);mapTiming.finish();
        if (FAILED(status)) { finishD3D12Frame(); return false; }
        buffer.mapped = true;
        images[eye] = {static_cast<const uint8_t*>(mapped)+buffer.footprint.Offset,
            buffer.width,buffer.height,buffer.footprint.Footprint.RowPitch,buffer.format,swapchainColourSpace(views[eye])};
    }
    return true;
}
} // namespace basalt
