// Execute the real readback implementation with deterministic inert COM slots.
// No GPU/device, external bridge or real runtime is created by this test.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "d3d11_prior_staging.hpp"
#include "projection_geometry.hpp"
#include "stereo_readback_order.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
std::array<void*, 43> deviceTable{};
std::array<void*, 116> contextTable{};
std::array<void*, 11> textureTable{};
struct Base { void** table; ULONG references = 1; };
struct Texture : Base {
    D3D11_TEXTURE2D_DESC desc{};
    uint32_t pitch = 0, tag = 0, eye = 0;
    std::vector<uint8_t> pixels;
    bool mapped = false;
    explicit Texture(const D3D11_TEXTURE2D_DESC& d) : Base{textureTable.data()}, desc(d) {
        pitch = desc.Width * 4 + 12;
        pixels.resize(size_t(pitch) * desc.Height * desc.ArraySize, 0xde);
    }
};
struct Context : Base { Context() : Base{contextTable.data()} {} } context;
struct Device : Base {
    bool removed = false;
    Device() : Base{deviceTable.data()} {}
} device, secondDevice;
struct Event { char kind; uint32_t tag, eye; };
std::vector<Event> events;
Texture* sources[2][3]{};
uint32_t colors[2]{};
unsigned activeMaps = 0, failMapCountdown = 0, failCreateCountdown = 0;

ULONG STDMETHODCALLTYPE addRef(Base* self) { return ++self->references; }
ULONG STDMETHODCALLTYPE release(Base* self) { check(self->references > 1, "device/context ownership"); return --self->references; }
ULONG STDMETHODCALLTYPE releaseTexture(Texture* self) {
    check(self->references != 0, "texture ownership");
    const ULONG left = --self->references;
    if (!left) { check(!self->mapped, "release must unmap first"); delete self; }
    return left;
}
HRESULT STDMETHODCALLTYPE removed(Device* self) { return self->removed ? DXGI_ERROR_DEVICE_REMOVED : S_OK; }
void STDMETHODCALLTYPE immediate(Device*, ID3D11DeviceContext** out) {
    addRef(&context); *out = reinterpret_cast<ID3D11DeviceContext*>(&context);
}
HRESULT STDMETHODCALLTYPE createTexture(Device*, const D3D11_TEXTURE2D_DESC* desc,
                                        const D3D11_SUBRESOURCE_DATA*, ID3D11Texture2D** out) {
    if (failCreateCountdown && !--failCreateCountdown) return E_OUTOFMEMORY;
    check(desc->Usage == D3D11_USAGE_STAGING && desc->CPUAccessFlags == D3D11_CPU_ACCESS_READ &&
          desc->ArraySize == 1 && desc->SampleDesc.Count == 1, "real staging descriptor");
    *out = reinterpret_cast<ID3D11Texture2D*>(new Texture(*desc)); return S_OK;
}
void STDMETHODCALLTYPE getDesc(Texture* self, D3D11_TEXTURE2D_DESC* out) { *out = self->desc; }
void STDMETHODCALLTYPE copy(Context*, Texture* dst, UINT subresource, UINT x, UINT y, UINT z,
                             Texture* src, UINT sourceSubresource, const D3D11_BOX* box) {
    check(!subresource && !x && !y && !z && box && !dst->mapped, "copy destination and lifetime");
    check(sourceSubresource % src->desc.MipLevels == 0, "array slice subresource");
    const unsigned layer = sourceSubresource / src->desc.MipLevels;
    check(layer < src->desc.ArraySize && box->right - box->left == dst->desc.Width &&
          box->bottom - box->top == dst->desc.Height, "cropped source layout");
    for (UINT row = 0; row < dst->desc.Height; ++row)
        std::memcpy(dst->pixels.data() + size_t(row) * dst->pitch,
            src->pixels.data() + (size_t(layer) * src->desc.Height + box->top + row) * src->pitch + box->left * 4,
            dst->desc.Width * 4);
    dst->tag = src->tag; dst->eye = src->eye; events.push_back({'C',src->tag,src->eye});
}
void STDMETHODCALLTYPE flush(Context*) { events.push_back({'F',0,0}); }
HRESULT STDMETHODCALLTYPE map(Context*, Texture* src, UINT subresource, D3D11_MAP mode,
                               UINT flags, D3D11_MAPPED_SUBRESOURCE* out) {
    check(!subresource && mode == D3D11_MAP_READ && !flags && !src->mapped, "map flags and pairing");
    if (failMapCountdown && !--failMapCountdown) return E_FAIL;
    src->mapped = true; ++activeMaps; events.push_back({'M',src->tag,src->eye});
    *out = {src->pixels.data(),src->pitch,UINT(src->pixels.size())}; return S_OK;
}
void STDMETHODCALLTYPE unmap(Context*, Texture* src, UINT subresource) {
    check(!subresource && src->mapped && activeMaps, "balanced unmap");
    src->mapped = false; --activeMaps;
}
template<class F> void slot(void** table, size_t index, F function) { table[index] = reinterpret_cast<void*>(function); }

std::array<uint8_t,4> pixel(unsigned frame, unsigned eye, unsigned x, unsigned y, unsigned layer) {
    return {uint8_t(frame * 19 + eye * 83 + x * 7), uint8_t(1 + y * 37 + frame * 11),
            uint8_t(255 - x * 13 - eye * 17 - layer * 31), uint8_t(128 + frame + x + y)};
}
void fill(Texture* texture, unsigned frame, unsigned eye) {
    texture->tag = frame; texture->eye = eye;
    for (unsigned layer = 0; layer < texture->desc.ArraySize; ++layer)
    for (unsigned y = 0; y < texture->desc.Height; ++y) for (unsigned x = 0; x < texture->desc.Width; ++x) {
        auto value = pixel(frame,eye,x,y,layer);
        if (basalt::readbackIsBgra(texture->desc.Format)) std::swap(value[0],value[2]);
        std::memcpy(texture->pixels.data() + (size_t(layer) * texture->desc.Height + y) * texture->pitch + x * 4,
                    value.data(),4);
    }
}
void makeSources(DXGI_FORMAT left, DXGI_FORMAT right) {
    for (unsigned eye = 0; eye < 2; ++eye) for (unsigned i = 0; i < 3; ++i) {
        if (sources[eye][i]) releaseTexture(sources[eye][i]);
        D3D11_TEXTURE2D_DESC d{}; d.Width = 7; d.Height = 5; d.MipLevels = 1;
        d.ArraySize = 2; d.SampleDesc.Count = 1; d.Format = eye ? right : left;
        sources[eye][i] = new Texture(d);
        colors[eye] = basalt::readbackFormatIsSrgb(d.Format) ? halliday::kColorSrgb : halliday::kColorLinear;
    }
}
basalt::PriorProjectionFrame submitted(unsigned frame, unsigned leftFlip = 0, unsigned rightFlip = 0) {
    basalt::PriorProjectionFrame result{};
    result.producerEpoch = 7; result.spaceEpoch = 11; result.focusGeneration = 2;
    result.fullGeometry = true;
    result.head.valid = 1; result.head.stamp = float(frame);
    result.head.position[0] = frame * .01f; result.head.position[1] = 1.6f;
    result.head.orientation[1] = std::sin(frame * .03f); result.head.orientation[3] = std::cos(frame * .03f);
    for (unsigned eye = 0; eye < 2; ++eye) {
        auto& view = result.views[eye]; const auto flips = (eye ? rightFlip : leftFlip) ^ (frame & 3u);
        view.swapchainId = eye + 10; view.imageIndex = frame % 3; view.imageArrayIndex = eye;
        view.rect = {{1,1},{5,3}};
        view.pose.orientation = {0,result.head.orientation[1],0,result.head.orientation[3]};
        view.pose.position = {result.head.position[0] + (eye ? .032f : -.032f),1.6f,-.2f};
        const float zoom = .004f * frame * (eye+1);
        view.fov = {-.7f+zoom,.8f-zoom,.9f-zoom,-.6f+zoom};
        if (flips & 1) std::swap(view.fov.angleLeft,view.fov.angleRight);
        if (flips & 2) std::swap(view.fov.angleUp,view.fov.angleDown);
        result.geometry[eye] = halliday::projection::fromSubmitted(view.pose,view.fov);
    }
    return result;
}
basalt::PriorStagingResult capture(const basalt::PriorProjectionFrame& frame,
                                  basalt::ReadbackImage images[2], basalt::PriorProjectionFrame* old,
                                  Device* on = &device) {
    for (unsigned eye = 0; eye < 2; ++eye) fill(sources[eye][frame.views[eye].imageIndex],unsigned(frame.head.stamp),eye);
    events.clear();
    return basalt::prepareD3D11PriorFrame(reinterpret_cast<ID3D11Device*>(on),frame,images,old);
}
bool samePacket(const basalt::PriorProjectionFrame& a, const basalt::PriorProjectionFrame& b) {
    if (!basalt::samePriorProjectionLayout(a,b) || std::memcmp(&a.head,&b.head,sizeof(a.head))) return false;
    for (unsigned eye = 0; eye < 2; ++eye) {
        if (a.views[eye].imageIndex != b.views[eye].imageIndex ||
            std::memcmp(&a.views[eye].pose,&b.views[eye].pose,sizeof(XrPosef)) ||
            std::memcmp(&a.views[eye].fov,&b.views[eye].fov,sizeof(XrFovf)) ||
            std::memcmp(&a.geometry[eye],&b.geometry[eye],sizeof(a.geometry[eye]))) return false;
    }
    return true; // Compare all fields, not unspecified C++ structure padding.
}
void verifyPixels(const basalt::ReadbackImage images[2], const basalt::PriorProjectionFrame& frame,
                  halliday::Header* header, uint64_t index) {
    const auto order = basalt::stereoReadbackOrder(images,true);
    const auto metadata = halliday::frameTextureMetadata(0,images[0].colorSpace,images[1].colorSpace) |
                          halliday::kFrameProjectionGeometry;
    header->clientPid = 123; header->initialized.store(1);
    auto* hp = halliday::haptics::extension(header);
    hp->clientEpoch.store(frame.producerEpoch); hp->ownerPid.store(header->clientPid);
    check(halliday::publish(header,5,3,order.bgra,frame.head,index,
        [&](size_t eye,uint8_t* target) {basalt::copyReadbackImage(images[eye],order.bgra,target);return true;},metadata,
        [&](size_t slot,uint64_t sequence) {
            return halliday::projection::publish(header,slot,sequence,frame.producerEpoch,frame.geometry);
        }), "real transport stereo/geometry publication");
    const unsigned slot = header->latest.load() - 1;
    check(std::memcmp(&header->frames[slot].pose,&frame.head,sizeof(frame.head)) == 0,
          "published head/stamp exactly match captured pixels");
    halliday::projection::Snapshot geometry{};
    check(halliday::projection::read(header,slot,index,frame.producerEpoch,&geometry) &&
          std::memcmp(geometry.views,frame.geometry,sizeof(frame.geometry)) == 0,
          "full per-eye pose/FOV shares captured index and epoch");
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& image = images[eye]; const auto& view = frame.views[eye];
        check(image.flipX == (view.fov.angleLeft > view.fov.angleRight) &&
              image.flipY == (view.fov.angleDown > view.fov.angleUp),
              "capture orientation uses the prior raw FOV, never the current camera");
        check(image.colorSpace == colors[eye] && image.rowPitch > image.width * 4,
              "captured color and padded row pitch");
        const auto* data = reinterpret_cast<uint8_t*>(header) + halliday::imageOffset(slot,eye);
        for (unsigned y = 0; y < 3; ++y) for (unsigned x = 0; x < 5; ++x) {
            const auto expected = pixel(unsigned(frame.head.stamp),eye,
                1 + (image.flipX ? 4 - x : x),1 + (image.flipY ? 2 - y : y),view.imageArrayIndex);
            const auto* actual = data + (y * 5 + x) * 4;
            check(actual[order.bgra ? 2 : 0] == expected[0] && actual[1] == expected[1] &&
                  actual[order.bgra ? 0 : 2] == expected[2] && actual[3] == expected[3],
                  "N-1 exact both/mixed order RGB/alpha/flips/crop/array-layer bytes");
        }
        check(halliday::frameColorSpace(header->frames[slot].textureType,eye) == colors[eye],
              "gamma metadata remains independent from byte order");
    }
}
}

namespace basalt {
HallidayTransferStats& transferStatistics() { static HallidayTransferStats stats{}; return stats; }
ID3D11Texture2D* retainSwapchainTexture(const ControlFrameView& view) {
    if (view.swapchainId < 10 || view.swapchainId > 11 || view.imageIndex >= 3) return nullptr;
    auto* texture = sources[view.swapchainId - 10][view.imageIndex];
    if (texture) addRef(texture);
    return reinterpret_cast<ID3D11Texture2D*>(texture);
}
uint32_t swapchainColourSpace(const ControlFrameView& view) { return colors[view.swapchainId - 10]; }
}

int main() { try {
    slot(deviceTable.data(),1,addRef); slot(deviceTable.data(),2,release);
    slot(deviceTable.data(),5,createTexture); slot(deviceTable.data(),39,removed); slot(deviceTable.data(),40,immediate);
    slot(contextTable.data(),1,addRef); slot(contextTable.data(),2,release);
    slot(contextTable.data(),14,map); slot(contextTable.data(),15,unmap);
    slot(contextTable.data(),46,copy); slot(contextTable.data(),111,flush);
    slot(textureTable.data(),1,addRef); slot(textureTable.data(),2,releaseTexture); slot(textureTable.data(),10,getDesc);
    const size_t bytes = halliday::imageOffset(2,1) + 4096;
    auto* memory = static_cast<uint8_t*>(VirtualAlloc(nullptr,bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    check(memory != nullptr,"sparse private transport memory");
    auto* header = new(memory) halliday::Header{};
    auto* hp = new(memory + halliday::haptics::kOffset) halliday::haptics::Extension{};
    hp->magic = halliday::haptics::kMagic; hp->version = halliday::haptics::kVersion;
    halliday::projection::initialize(header);
    unsigned paired = 0; uint64_t transportIndex = 0;
    for (const auto left : {DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB})
    for (const auto right : {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,DXGI_FORMAT_B8G8R8A8_UNORM})
    for (unsigned leftFlip = 0; leftFlip < 4; ++leftFlip) for (unsigned rightFlip = 0; rightFlip < 4; ++rightFlip) {
        basalt::resetD3D11PriorReadback(); makeSources(left,right);
        auto previous = submitted(1,leftFlip,rightFlip);
        for (unsigned frame = 1; frame <= 8; ++frame) {
            const auto current = submitted(frame,leftFlip,rightFlip);
            basalt::PriorProjectionFrame old{}; basalt::ReadbackImage images[2];
            const auto result = capture(current,images,&old);
            check(events.size() >= 3 && events[0].kind == 'C' && events[1].kind == 'C' && events[2].kind == 'F',
                  "both current copies queued and flushed before either prior-eye Map");
            if (frame == 1) check(result == basalt::PriorStagingResult::Warmup && events.size() == 3 && !activeMaps,
                                   "first frame warms atomically without a fabricated image");
            else {
                check(result == basalt::PriorStagingResult::Ready && events.size() == 5 && activeMaps == 2,
                      "both eyes from one previous capture");
                check(events[3].kind == 'M' && events[4].kind == 'M' &&
                      events[3].tag == frame - 1 && events[4].tag == frame - 1,
                      "real Map selects N-1 resources, never just stale metadata on current pixels");
                check(samePacket(old,previous),"complete older packet retained together");
                verifyPixels(images,old,header,++transportIndex); ++paired;
            }
            basalt::finishD3D11Frame(); check(!activeMaps,"finish releases both maps"); previous = current;
        }
    }
    makeSources(DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM);
    auto seed = submitted(20); basalt::PriorProjectionFrame old{}; basalt::ReadbackImage images[2];
    const auto warm = [&](const basalt::PriorProjectionFrame& value) {
        check(capture(value,images,&old) == basalt::PriorStagingResult::Warmup && !activeMaps,"transition retires old stereo pair");
    };
    basalt::resetD3D11PriorReadback(); warm(seed);
    for (unsigned transition = 0; transition < 10; ++transition) {
        auto changed = seed; changed.head.stamp += transition + 1;
        switch (transition) {
            case 0: ++changed.spaceEpoch; break;
            case 1: ++changed.producerEpoch; break;
            case 2: changed.focusGeneration += 2; break;
            case 3: ++changed.views[0].rect.offset.x; break;
            case 4: --changed.views[1].rect.extent.width; break;
            case 5: ++changed.views[0].rect.offset.y; break;
            case 6: changed.views[0].imageArrayIndex = 1; break;
            case 7: ++changed.projectionOrder; break;
            case 8: colors[0] = halliday::kColorSrgb; break;
            case 9: for (auto* s : sources[1]) s->desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; break;
        }
        warm(changed); seed = changed;
    }
    check(capture(seed,images,&old,&secondDevice) == basalt::PriorStagingResult::Warmup,"device replacement retires both resources and metadata");
    basalt::resetD3D11PriorReadback(); warm(seed);
    failMapCountdown = 2;
    check(capture(seed,images,&old) == basalt::PriorStagingResult::Failed && !activeMaps &&
          basalt::transferStatistics().liveStagingTextures == 0,"right Map failure unmaps left and clears entire ring for synchronous retry");
    warm(seed); basalt::resetD3D11PriorReadback(); failCreateCountdown = 3;
    check(capture(seed,images,&old) == basalt::PriorStagingResult::Failed &&
          basalt::transferStatistics().liveStagingTextures == 0,"partial allocation failure clears both pairs");
    warm(seed); basalt::resetD3D11PriorReadback(); warm(seed);
    check(capture(seed,images,&old) == basalt::PriorStagingResult::Ready,"pipeline resumes after reset");
    basalt::finishD3D11Frame(); device.removed = true;
    check(capture(seed,images,&old) == basalt::PriorStagingResult::Failed && !activeMaps,"device loss clears pending capture");
    device.removed = false;
    check(basalt::priorProjectionEligible(2,0,0,true) && !basalt::priorProjectionEligible(0,0,0,true) &&
          !basalt::priorProjectionEligible(2,1,0,true) && !basalt::priorProjectionEligible(2,0,1,true) &&
          !basalt::priorProjectionEligible(2,0,2,true) && !basalt::priorProjectionEligible(2,0,0,false),
          "quads/empty/alpha/legacy geometry must use synchronous fallback");
    basalt::resetD3D11Readback();
    check(!activeMaps && !basalt::transferStatistics().liveStagingTextures &&
          device.references == 1 && secondDevice.references == 1 && context.references == 1,"all resources and device refs balanced");
    for (auto& hand : sources) for (auto*& source : hand) {releaseTexture(source); source = nullptr;}
    VirtualFree(memory,0,MEM_RELEASE);
    std::printf("PASS: %u exact N-1 stereo/pose/animated-fullFOV/color/crop/array/flip transport pairs; warmup, generation/layout/device resets, failures and fallback guards; inert COM only, noGPU\n",paired);
    return 0;
} catch (const std::exception& e) {std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;} }
