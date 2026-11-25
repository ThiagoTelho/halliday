// D3D11 frame readback: two cached staging textures, both copies before maps.
#include "readback.hpp"
#include "frame_timing.hpp"
#include "d3d11_prior_staging.hpp"
#include <algorithm>
#include <cstring>

namespace {
struct Eye {
    ID3D11Texture2D* texture = nullptr;
    uint32_t width = 0,height = 0;
    DXGI_FORMAT format = DXGI_FORMAT_UNKNOWN;
    bool mapped = false;
};
struct Pool {
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    Eye eyes[2];
} pool;
struct Source {
    ID3D11Texture2D* texture = nullptr;
    D3D11_TEXTURE2D_DESC desc{};
    ~Source() { if (texture) texture->Release(); }
};
void releaseEye(Eye& eye) {
    if (eye.mapped && pool.context) pool.context->Unmap(eye.texture,0);
    if (eye.texture) {
        eye.texture->Release(); --basalt::transferStatistics().liveStagingTextures;
    }
    eye = {};
}
bool ensureEye(ID3D11Device* device,Eye& eye,uint32_t width,uint32_t height,DXGI_FORMAT format) {
    if (eye.texture && eye.width == width && eye.height == height && eye.format == format) return true;
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = format; desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D* texture = nullptr;
    if (FAILED(device->CreateTexture2D(&desc,nullptr,&texture))) return false;
    releaseEye(eye);
    eye.texture = texture; eye.width = width; eye.height = height; eye.format = format;
    auto& stats = basalt::transferStatistics(); ++stats.stagingTextureCreates; ++stats.liveStagingTextures;
    return true;
}
}

namespace basalt {
namespace {
struct PriorPair {
    Eye eyes[2];
    PriorProjectionFrame frame{};
    D3D11_TEXTURE2D_DESC descriptors[2]{};
    uint32_t colorSpaces[2]{};
    bool valid = false;
};
struct PriorPool {
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    PriorPair pairs[2];
    unsigned write = 0;
} prior;
void finishPrior() {
    if (!prior.device) return;
    for (auto& pair : prior.pairs) for (auto& eye : pair.eyes) if (eye.mapped) {
        prior.context->Unmap(eye.texture, 0); eye.mapped = false;
    }
}
bool sameDescriptor(const D3D11_TEXTURE2D_DESC& a, const D3D11_TEXTURE2D_DESC& b) {
    return a.Width == b.Width && a.Height == b.Height && a.MipLevels == b.MipLevels &&
        a.ArraySize == b.ArraySize && a.Format == b.Format &&
        a.SampleDesc.Count == b.SampleDesc.Count && a.SampleDesc.Quality == b.SampleDesc.Quality;
}
}
void resetD3D11PriorReadback() {
    if (!prior.device) return;
    finishPrior();
    for (auto& pair : prior.pairs) for (auto& eye : pair.eyes) if (eye.texture) {
        eye.texture->Release(); --transferStatistics().liveStagingTextures;
    }
    if (prior.context) prior.context->Release();
    if (prior.device) prior.device->Release();
    prior = {};
}
PriorStagingResult prepareD3D11PriorFrame(ID3D11Device* device,
    const PriorProjectionFrame& frame, ReadbackImage images[2], PriorProjectionFrame* captured) {
    if (!device || !captured || FAILED(device->GetDeviceRemovedReason())) {
        resetD3D11PriorReadback(); return PriorStagingResult::Failed;
    }
    finishPrior();
    Source sources[2];
    uint32_t colors[2]{};
    bool compatible = prior.device == device;
    const auto& previous = prior.pairs[1 - prior.write];
    if (previous.valid && !samePriorProjectionLayout(previous.frame, frame)) compatible = false;
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& view = frame.views[eye]; const auto& rect = view.rect;
        auto& source = sources[eye]; source.texture = retainSwapchainTexture(view);
        if (!source.texture) { resetD3D11PriorReadback(); return PriorStagingResult::Failed; }
        source.texture->GetDesc(&source.desc);
        if (rect.offset.x < 0 || rect.offset.y < 0 || rect.extent.width <= 0 || rect.extent.height <= 0 ||
            uint64_t(rect.offset.x) + uint32_t(rect.extent.width) > source.desc.Width ||
            uint64_t(rect.offset.y) + uint32_t(rect.extent.height) > source.desc.Height ||
            view.imageArrayIndex >= source.desc.ArraySize || source.desc.SampleDesc.Count != 1) {
            resetD3D11PriorReadback(); return PriorStagingResult::Failed;
        }
        colors[eye] = swapchainColourSpace(view);
        if (previous.valid && (!sameDescriptor(previous.descriptors[eye], source.desc) ||
                               previous.colorSpaces[eye] != colors[eye])) compatible = false;
    }
    if (!compatible) resetD3D11PriorReadback();
    if (!prior.device) {
        prior.device = device; device->AddRef(); device->GetImmediateContext(&prior.context);
    }
    if (!prior.context) { resetD3D11PriorReadback(); return PriorStagingResult::Failed; }
    // Allocate both pairs before submitting any copy. Failure leaves no half
    // stereo frame and the caller can retry the ordinary synchronous path.
    for (auto& pair : prior.pairs) for (unsigned eye = 0; eye < 2; ++eye) {
        auto& dst = pair.eyes[eye]; const auto& view = frame.views[eye];
        if (!dst.texture) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = uint32_t(view.rect.extent.width); desc.Height = uint32_t(view.rect.extent.height);
            desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
            desc.Format = sources[eye].desc.Format; desc.Usage = D3D11_USAGE_STAGING;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
            if (FAILED(device->CreateTexture2D(&desc, nullptr, &dst.texture))) {
                resetD3D11PriorReadback(); return PriorStagingResult::Failed;
            }
            dst.width = desc.Width; dst.height = desc.Height; dst.format = desc.Format;
            ++transferStatistics().stagingTextureCreates; ++transferStatistics().liveStagingTextures;
        }
    }
    auto& write = prior.pairs[prior.write];
    timing::Span copyTiming(timing::Phase::CopySubmit);
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& view = frame.views[eye]; const auto& r = view.rect;
        const D3D11_BOX box{UINT(r.offset.x), UINT(r.offset.y), 0,
            UINT(r.offset.x + r.extent.width), UINT(r.offset.y + r.extent.height), 1};
        prior.context->CopySubresourceRegion(write.eyes[eye].texture, 0, 0, 0, 0,
            sources[eye].texture, D3D11CalcSubresource(0, view.imageArrayIndex, sources[eye].desc.MipLevels), &box);
        ++transferStatistics().copyCommands;
        write.descriptors[eye] = sources[eye].desc; write.colorSpaces[eye] = colors[eye];
    }
    // Submit this capture while reading the opposite, older staging pair.
    prior.context->Flush(); copyTiming.finish();
    write.frame = frame; write.valid = true;
    prior.write = 1 - prior.write;
    auto& read = prior.pairs[prior.write];
    transferStatistics().peakFramesInFlight = std::max<uint64_t>(transferStatistics().peakFramesInFlight, 2);
    if (!read.valid) return PriorStagingResult::Warmup;
    for (unsigned eye = 0; eye < 2; ++eye) {
        auto& src = read.eyes[eye]; D3D11_MAPPED_SUBRESOURCE mapped{};
        ++transferStatistics().mapCalls;
        timing::Span mapTiming(eye ? timing::Phase::MapRight : timing::Phase::MapLeft);
        const auto status = prior.context->Map(src.texture, 0, D3D11_MAP_READ, 0, &mapped);
        mapTiming.finish();
        if (FAILED(status)) { resetD3D11PriorReadback(); return PriorStagingResult::Failed; }
        src.mapped = true;
        const auto& fov = read.frame.views[eye].fov;
        images[eye] = {static_cast<const uint8_t*>(mapped.pData), src.width, src.height,
            mapped.RowPitch, src.format, read.colorSpaces[eye],
            fov.angleLeft > fov.angleRight, fov.angleDown > fov.angleUp};
    }
    *captured = read.frame;
    return PriorStagingResult::Ready;
}
void finishD3D11Frame() {
    finishPrior();
    for (auto& eye : pool.eyes) if (eye.mapped) {
        pool.context->Unmap(eye.texture,0); eye.mapped = false;
    }
}
void resetD3D11Readback() {
    resetD3D11PriorReadback();
    finishD3D11Frame();
    for (auto& eye : pool.eyes) releaseEye(eye);
    if (pool.context) pool.context->Release();
    if (pool.device) pool.device->Release();
    pool = {};
}
bool prepareD3D11Frame(ID3D11Device* device,const ControlFrameView views[2],ReadbackImage images[2]) {
    if (!device || FAILED(device->GetDeviceRemovedReason())) return false;
    if (pool.device != device) {
        resetD3D11Readback();
        pool.device = device; device->AddRef(); device->GetImmediateContext(&pool.context);
    }
    if (!pool.context) return false;
    finishD3D11Frame();
    Source sources[2];
    // Validate and prepare both destinations before placing any copy on the GPU.
    for (unsigned eye = 0; eye < 2; ++eye) {
        auto& source = sources[eye]; source.texture = retainSwapchainTexture(views[eye]);
        if (!source.texture) return false;
        source.texture->GetDesc(&source.desc);
        const auto& rect = views[eye].rect;
        if (rect.offset.x < 0 || rect.offset.y < 0 || rect.extent.width <= 0 || rect.extent.height <= 0 ||
            uint64_t(rect.offset.x)+uint32_t(rect.extent.width) > source.desc.Width ||
            uint64_t(rect.offset.y)+uint32_t(rect.extent.height) > source.desc.Height ||
            views[eye].imageArrayIndex >= source.desc.ArraySize || source.desc.SampleDesc.Count != 1)
            return false;
        if (!ensureEye(device,pool.eyes[eye],rect.extent.width,rect.extent.height,source.desc.Format)) return false;
    }
    timing::Span copyTiming(timing::Phase::CopySubmit);
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& view = views[eye];
        const D3D11_BOX box{static_cast<UINT>(view.rect.offset.x),static_cast<UINT>(view.rect.offset.y),0,
            static_cast<UINT>(view.rect.offset.x+view.rect.extent.width),
            static_cast<UINT>(view.rect.offset.y+view.rect.extent.height),1};
        pool.context->CopySubresourceRegion(pool.eyes[eye].texture,0,0,0,0,sources[eye].texture,
            D3D11CalcSubresource(0,view.imageArrayIndex,sources[eye].desc.MipLevels),&box);
        ++transferStatistics().copyCommands;
    }
    copyTiming.finish();
    transferStatistics().peakFramesInFlight = std::max<uint64_t>(transferStatistics().peakFramesInFlight,1);
    // The first Map may wait, but the right-eye copy is already queued too.
    for (unsigned eye = 0; eye < 2; ++eye) {
        D3D11_MAPPED_SUBRESOURCE mapped{};
        ++transferStatistics().mapCalls;
        timing::Span mapTiming(eye?timing::Phase::MapRight:timing::Phase::MapLeft);
        const auto status=pool.context->Map(pool.eyes[eye].texture,0,D3D11_MAP_READ,0,&mapped);
        mapTiming.finish();
        if (FAILED(status)) {
            finishD3D11Frame(); return false;
        }
        pool.eyes[eye].mapped = true;
        images[eye] = {static_cast<const uint8_t*>(mapped.pData),pool.eyes[eye].width,
            pool.eyes[eye].height,mapped.RowPitch,pool.eyes[eye].format,swapchainColourSpace(views[eye])};
    }
    return true;
}
void copyReadbackImage(const ReadbackImage& image,bool outputBgra,uint8_t* destination) {
    const bool sourceBgra = readbackIsBgra(image.format);
    for (uint32_t y = 0; y < image.height; ++y) {
        const auto* source = image.pixels+size_t(image.flipY?image.height-1-y:y)*image.rowPitch;
        auto* target = destination+size_t(y)*image.width*4;
        if (image.flipX) {
            for (uint32_t x = 0; x < image.width; ++x) {
                std::memcpy(target+x*4,source+size_t(image.width-1-x)*4,4);
                if (sourceBgra != outputBgra) std::swap(target[x*4],target[x*4+2]);
            }
            continue;
        }
        std::memcpy(target,source,size_t(image.width)*4);
        if (sourceBgra != outputBgra)
            for (uint32_t x = 0; x < image.width; ++x) std::swap(target[x*4],target[x*4+2]);
    }
}
} // namespace basalt
