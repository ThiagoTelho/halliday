// Reusable, one-frame-at-a-time transfer pools. Call under the control video lock or exclusive lifecycle admission.
#pragma once
#include "control.hpp"
#include "transfer_stats.h"

namespace basalt {
inline bool readbackIsBgra(DXGI_FORMAT format) {
    return format == DXGI_FORMAT_B8G8R8A8_UNORM || format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ||
        format == DXGI_FORMAT_B8G8R8A8_TYPELESS;
}
struct ReadbackImage {
    const uint8_t* pixels = nullptr;
    uint32_t width = 0,height = 0,rowPitch = 0;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    uint32_t colorSpace = 0; // requested OpenXR format: legacy/linear/sRGB
    bool flipX = false,flipY = false; // projection FOV's legal reversed bounds
};

HallidayTransferStats& transferStatistics();
bool prepareD3D11Frame(ID3D11Device* device,const ControlFrameView views[2],ReadbackImage images[2]);
void finishD3D11Frame();
void resetD3D11Readback();

bool prepareD3D12Frame(ID3D12Device* device,ID3D12CommandQueue* queue,
                      const ControlFrameView views[2],ReadbackImage images[2]);
void finishD3D12Frame();
// False means a failed queue still owns GPU work. Keep its objects alive and
// refuse another session until the fence finishes or the device is removed.
bool resetD3D12Readback();

void copyReadbackImage(const ReadbackImage& image,bool outputBgra,uint8_t* destination);
inline bool readbackFormatIsSrgb(DXGI_FORMAT format) {
    return format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB || format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
}
} // namespace basalt
