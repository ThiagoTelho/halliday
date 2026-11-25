// Halliday contributors, MIT. A bounded GPU-copy capability check, not a
// shared-handle or frame-rate test. Device creation alone is insufficient.
#pragma once
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <cstdint>
#include <cstring>
#include <memory>

namespace halliday {
namespace capability {
template<class T> void release(T*& value) { if (value) { value->Release(); value = nullptr; } }
struct Probe {
    IDXGIFactory1* factory = nullptr;
    IDXGIAdapter1* adapter = nullptr;
    ID3D12Device* device = nullptr;
    ID3D12CommandQueue* queue = nullptr;
    ID3D12CommandAllocator* allocator = nullptr;
    ID3D12GraphicsCommandList* commands = nullptr;
    ID3D12Fence* fence = nullptr;
    ID3D12Resource *upload = nullptr, *texture = nullptr, *readback = nullptr;
    HANDLE event = nullptr;
    bool submitted = false, signaled = false;
    ~Probe() {
        release(readback); release(texture); release(upload); release(commands);
        release(allocator); release(fence); release(queue); release(device);
        release(adapter); release(factory);
        if (event) CloseHandle(event);
    }
    bool safeToRelease() const {
        return !submitted || (device && FAILED(device->GetDeviceRemovedReason())) ||
            (signaled && fence && fence->GetCompletedValue() >= 1);
    }
};
} // namespace capability

inline HRESULT probeD3D12Readback(LUID* luid) {
    if (!luid) return E_POINTER;
    auto p = std::make_unique<capability::Probe>();
    auto fail = [&](HRESULT status) {
        // A timed-out/failed queue may still own these resources. This one-time
        // capability result is cached for the process; retain that bounded set
        // until process cleanup rather than free memory underneath the GPU.
        if (!p->safeToRelease()) (void)p.release();
        return status;
    };
    HRESULT status = CreateDXGIFactory1(IID_PPV_ARGS(&p->factory));
    if (SUCCEEDED(status)) status = p->factory->EnumAdapters1(0, &p->adapter);
    if (SUCCEEDED(status)) status = D3D12CreateDevice(p->adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&p->device));
    D3D12_COMMAND_QUEUE_DESC queue{}; queue.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    if (SUCCEEDED(status)) status = p->device->CreateCommandQueue(&queue, IID_PPV_ARGS(&p->queue));
    if (SUCCEEDED(status)) status = p->device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&p->allocator));
    if (SUCCEEDED(status)) status = p->device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, p->allocator,
                                                               nullptr, IID_PPV_ARGS(&p->commands));
    if (SUCCEEDED(status)) status = p->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&p->fence));
    if (FAILED(status)) return fail(status);
    p->event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!p->event) return fail(HRESULT_FROM_WIN32(GetLastError()));

    constexpr UINT width = 2, height = 2;
    constexpr uint32_t pixels[] = {0xff030201, 0xff060504, 0xff090807, 0xff0c0b0a};
    D3D12_RESOURCE_DESC description{};
    description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    description.Width = width; description.Height = height;
    description.DepthOrArraySize = description.MipLevels = description.SampleDesc.Count = 1;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0; UINT64 rowBytes = 0, total = 0;
    p->device->GetCopyableFootprints(&description, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
    if (rows != height || rowBytes != width * 4 || footprint.Footprint.RowPitch < rowBytes ||
        total < (height - 1) * footprint.Footprint.RowPitch + rowBytes || total > 1024 * 1024)
        return fail(E_FAIL);
    D3D12_HEAP_PROPERTIES heap{}; heap.CreationNodeMask = heap.VisibleNodeMask = 1;
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    status = p->device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &description,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&p->texture));
    D3D12_RESOURCE_DESC buffer{};
    buffer.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; buffer.Width = total;
    buffer.Height = buffer.DepthOrArraySize = buffer.MipLevels = buffer.SampleDesc.Count = 1;
    buffer.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    if (SUCCEEDED(status)) status = p->device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer,
        D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&p->upload));
    heap.Type = D3D12_HEAP_TYPE_READBACK;
    if (SUCCEEDED(status)) status = p->device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer,
        D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&p->readback));
    if (FAILED(status)) return fail(status);
    void* mapped = nullptr;
    const D3D12_RANGE noReads{0, 0};
    status = p->upload->Map(0, &noReads, &mapped);
    if (FAILED(status)) return fail(status);
    if (!mapped) { p->upload->Unmap(0, &noReads); return fail(E_FAIL); }
    for (UINT y = 0; y < height; ++y)
        std::memcpy(static_cast<uint8_t*>(mapped) + footprint.Offset + y * footprint.Footprint.RowPitch,
                    pixels + y * width, width * 4);
    const D3D12_RANGE written{0, static_cast<SIZE_T>(total)};
    p->upload->Unmap(0, &written);

    D3D12_TEXTURE_COPY_LOCATION src{}, dst{};
    src.pResource = p->upload; src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; src.PlacedFootprint = footprint;
    dst.pResource = p->texture; dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    p->commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    D3D12_RESOURCE_BARRIER barrier{}; barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = p->texture;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    p->commands->ResourceBarrier(1, &barrier);
    src.pResource = p->texture; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.pResource = p->readback; dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; dst.PlacedFootprint = footprint;
    p->commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET;
    p->commands->ResourceBarrier(1, &barrier);
    status = p->commands->Close();
    if (FAILED(status)) return fail(status);
    ID3D12CommandList* lists[] = {p->commands};
    p->queue->ExecuteCommandLists(1, lists); p->submitted = true;
    status = p->queue->Signal(p->fence, 1);
    if (FAILED(status)) return fail(status);
    p->signaled = true;
    bool eventReady = SUCCEEDED(p->fence->SetEventOnCompletion(1, p->event));
    const ULONGLONG started = GetTickCount64();
    while (p->fence->GetCompletedValue() < 1) {
        if (FAILED(p->device->GetDeviceRemovedReason())) return fail(DXGI_ERROR_DEVICE_REMOVED);
        if (GetTickCount64() - started >= 5000) return fail(HRESULT_FROM_WIN32(WAIT_TIMEOUT));
        if (eventReady) {
            if (WaitForSingleObject(p->event, 10) == WAIT_FAILED) eventReady = false;
        } else Sleep(1);
    }
    if (FAILED(p->device->GetDeviceRemovedReason()) || p->fence->GetCompletedValue() == UINT64_MAX)
        return fail(DXGI_ERROR_DEVICE_REMOVED);
    const D3D12_RANGE readRange{0, static_cast<SIZE_T>(total)};
    status = p->readback->Map(0, &readRange, &mapped);
    if (FAILED(status)) return fail(status);
    if (!mapped) { p->readback->Unmap(0, &noReads); return fail(E_FAIL); }
    for (UINT y = 0; y < height; ++y) {
        const auto* actual = static_cast<const uint8_t*>(mapped) + footprint.Offset + y * footprint.Footprint.RowPitch;
        if (std::memcmp(actual, pixels + y * width, width * 4) != 0) status = E_FAIL;
    }
    p->readback->Unmap(0, &noReads);
    if (SUCCEEDED(status)) *luid = p->device->GetAdapterLuid();
    return status;
}
} // namespace halliday
