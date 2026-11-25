// Exact CPU copy/transport checks; no graphics device is ever created.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "bridge_layout.hpp"
#include "stereo_readback_order.hpp"
#include <array>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

// Inert dependencies of the actual d3d11_readback.cpp implementation. These
// would fail if the CPU-only test accidentally entered the GPU preparation path.
namespace basalt {
HallidayTransferStats& transferStatistics() { static HallidayTransferStats stats{}; return stats; }
ID3D11Texture2D* retainSwapchainTexture(const ControlFrameView&) { throw std::runtime_error("GPU path forbidden"); }
uint32_t swapchainColourSpace(const ControlFrameView&) { throw std::runtime_error("GPU path forbidden"); }
}

namespace {
void check(bool ok, const char* text) { if (!ok) throw std::runtime_error(text); }
struct Format { DXGI_FORMAT format; bool bgra; uint32_t colour; };
constexpr Format formats[] = {
    {DXGI_FORMAT_R8G8B8A8_UNORM, false, halliday::kColorLinear},
    {DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, false, halliday::kColorSrgb},
    {DXGI_FORMAT_R8G8B8A8_TYPELESS, false, halliday::kColorLegacy},
    {DXGI_FORMAT_B8G8R8A8_UNORM, true, halliday::kColorLinear},
    {DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, true, halliday::kColorSrgb},
    {DXGI_FORMAT_B8G8R8A8_TYPELESS, true, halliday::kColorLegacy},
};
constexpr unsigned width = 5, height = 3, guardBytes = 16;
std::array<uint8_t, 4> rgba(unsigned eye, unsigned x, unsigned y) {
    constexpr uint8_t boundary[] = {0, 1, 127, 128, 254, 255};
    return {boundary[(eye*3+x+y*2)%6], boundary[(eye+x*2+y+1)%6],
            boundary[(eye*2+x+y+3)%6], boundary[(x+y*3+eye+2)%6]};
}
void verify(const uint8_t* pixels, unsigned eye, bool outputBgra, unsigned flips) {
    for (unsigned y=0;y<height;++y) for (unsigned x=0;x<width;++x) {
        const auto expected = rgba(eye, (flips&1)?width-1-x:x, (flips&2)?height-1-y:y);
        const auto* actual = pixels+(y*width+x)*4;
        check(actual[outputBgra?2:0]==expected[0] && actual[1]==expected[1] &&
              actual[outputBgra?0:2]==expected[2] && actual[3]==expected[3],
              "exact RGB/alpha/gamma-boundary bytes and independent flip oracle");
    }
    for (unsigned k=0;k<guardBytes;++k)
        check(pixels[width*height*4+k]==0xa5, "copy must not overwrite output guard");
}
}

int main() { try {
    // Sparse committed virtual address space: only the header and two tiny eye
    // payloads are touched. It follows the real fixed-offset transport ABI.
    const size_t bytes = halliday::imageOffset(0,1)+4096;
    auto* base = static_cast<uint8_t*>(VirtualAlloc(nullptr,bytes,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
    check(base!=nullptr,"private transport virtual memory");
    auto* header = new(base) halliday::Header{};
    header->magic=halliday::kMagic; header->version=halliday::kVersion;
    unsigned cases=0;
    for (const auto& left:formats) for (const auto& right:formats)
    for (const unsigned padding:{0u,7u,44u})
    for (unsigned leftFlip=0;leftFlip<4;++leftFlip) for (unsigned rightFlip=0;rightFlip<4;++rightFlip) {
        const Format pair[2]{left,right}; const unsigned flips[2]{leftFlip,rightFlip};
        std::vector<uint8_t> source[2]; basalt::ReadbackImage images[2];
        for (unsigned eye=0;eye<2;++eye) {
            const unsigned pitch=width*4+padding+eye*4;
            source[eye].assign(pitch*height,0xde);
            for (unsigned y=0;y<height;++y) for (unsigned x=0;x<width;++x) {
                auto value=rgba(eye,x,y); if (pair[eye].bgra) std::swap(value[0],value[2]);
                std::memcpy(source[eye].data()+y*pitch+x*4,value.data(),4);
            }
            images[eye]={source[eye].data(),width,height,pitch,pair[eye].format,pair[eye].colour,
                         (flips[eye]&1)!=0,(flips[eye]&2)!=0};
        }
        const auto order=basalt::stereoReadbackOrder(images,true);
        check(order.bgra==left.bgra,"first eye native byte order");
        check(order.swizzleEyes==unsigned(left.bgra!=right.bgra),"only a mixed-order second eye swizzles");
        for (unsigned eye=0;eye<2;++eye) {
            const auto unchanged=source[eye];
            std::vector<uint8_t> copied(width*height*4+guardBytes,0xa5);
            basalt::copyReadbackImage(images[eye],order.bgra,copied.data());
            verify(copied.data(),eye,order.bgra,flips[eye]);
            check(source[eye]==unchanged,"source pixels/padding remain unchanged");
            std::memset(base+halliday::imageOffset(0,eye),0xa5,width*height*4+guardBytes);
        }
        header->latest.store(0); header->reading.store(0);
        halliday::Pose pose{}; pose.valid=1; pose.orientation[3]=1;
        const auto metadata=halliday::frameTextureMetadata(4,left.colour,right.colour);
        check(halliday::publish(header,width,height,order.bgra,pose,++cases,
            [&](size_t eye,uint8_t* pixels) {basalt::copyReadbackImage(images[eye],order.bgra,pixels);return true;},metadata),
            "publish actual fixed-offset stereo frame");
        check(header->latest.load()==1,"published first transport slot");
        const auto& frame=header->frames[0];
        check(frame.bgra==unsigned(left.bgra) && frame.width==width && frame.height==height,
              "transport byte-order flag and geometry");
        check(halliday::frameColorSpace(frame.textureType,0)==left.colour &&
              halliday::frameColorSpace(frame.textureType,1)==right.colour && (frame.textureType&255)==4,
              "per-eye linear/sRGB/legacy and graphics API metadata unchanged");
        for (unsigned eye=0;eye<2;++eye) verify(base+halliday::imageOffset(0,eye),eye,frame.bgra!=0,flips[eye]);
    }
    const auto empty=basalt::stereoReadbackOrder(nullptr,false);
    check(empty.bgra && empty.swizzleEyes==0,"zero-layer black-frame convention retained without reading images");
    VirtualFree(base,0,MEM_RELEASE);
    std::printf("PASS: %u exact stereo cases: RGBA/BGRA/typeless/sRGB, both and mixed eyes, padded rows, independentXYflips, alpha/gamma-boundary bytes, transport flags and per-eye color metadata; noGPU\n",cases);
    return 0;
} catch(const std::exception& error) {std::fprintf(stderr,"FAIL: %s\n",error.what());return 1;} }
