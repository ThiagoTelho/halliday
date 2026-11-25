// Panel readback never reuses projection staging resources. Ordinary projection
// frames do not enter these pools or copy their pixels through another vector.
#include "panel_readback.hpp"
#include "vulkan_backend.hpp"
#include "panel_bridge.hpp"
#include <array>
#include <algorithm>

namespace {
struct Staging {
    ID3D11Texture2D* texture=nullptr;
    uint32_t width=0,height=0;
    DXGI_FORMAT format=DXGI_FORMAT_UNKNOWN;
};
struct Pool11 {
    ID3D11Device* device=nullptr;
    ID3D11DeviceContext* context=nullptr;
    std::array<Staging,halliday::panels::kMaximum> slots{};
} pool;
void release(Staging& slot) {
    if(slot.texture){slot.texture->Release();--basalt::transferStatistics().liveStagingTextures;}
    slot={};
}
bool extent(const basalt::ControlFrameView& view,uint32_t width,uint32_t height,uint32_t layers) {
    return view.rect.offset.x>=0&&view.rect.offset.y>=0&&view.rect.extent.width>0&&view.rect.extent.height>0&&
        uint64_t(view.rect.offset.x)+uint32_t(view.rect.extent.width)<=width&&
        uint64_t(view.rect.offset.y)+uint32_t(view.rect.extent.height)<=height&&view.imageArrayIndex<layers&&
        uint64_t(view.rect.extent.width)*view.rect.extent.height*4<=halliday::panels::kPictureBytes;
}
}
namespace basalt {
void resetD3D11Panels() {
    for(auto& slot:pool.slots)release(slot);
    if(pool.context)pool.context->Release();if(pool.device)pool.device->Release();pool={};
}
bool readD3D11Panels(ID3D11Device* device,const ControlFrameView* views,uint32_t count,
                    std::vector<std::vector<uint8_t>>& pixels,std::vector<ReadbackImage>& images) {
    if(count>halliday::panels::kMaximum||(!views&&count)||!device||FAILED(device->GetDeviceRemovedReason()))return false;
    if(pool.device!=device){resetD3D11Panels();pool.device=device;device->AddRef();device->GetImmediateContext(&pool.context);}
    if(!pool.context)return false;
    pixels.resize(count);images.resize(count);
    std::array<ID3D11Texture2D*,halliday::panels::kMaximum> sources{};
    struct Cleanup {decltype(sources)& values;~Cleanup(){for(auto* value:values)if(value)value->Release();}} cleanup{sources};
    std::array<D3D11_TEXTURE2D_DESC,halliday::panels::kMaximum> descriptors{};
    for(uint32_t i=0;i<count;++i){
        sources[i]=retainSwapchainTexture(views[i]);if(!sources[i])return false;
        auto& desc=descriptors[i];sources[i]->GetDesc(&desc);
        if(desc.SampleDesc.Count!=1||!extent(views[i],desc.Width,desc.Height,desc.ArraySize))return false;
        auto& slot=pool.slots[i];const auto w=uint32_t(views[i].rect.extent.width),h=uint32_t(views[i].rect.extent.height);
        if(!slot.texture||slot.width!=w||slot.height!=h||slot.format!=desc.Format){
            D3D11_TEXTURE2D_DESC made{};made.Width=w;made.Height=h;made.MipLevels=made.ArraySize=made.SampleDesc.Count=1;
            made.Format=desc.Format;made.Usage=D3D11_USAGE_STAGING;made.CPUAccessFlags=D3D11_CPU_ACCESS_READ;
            ID3D11Texture2D* texture=nullptr;if(FAILED(device->CreateTexture2D(&made,nullptr,&texture)))return false;
            release(slot);slot={texture,w,h,desc.Format};++transferStatistics().stagingTextureCreates;++transferStatistics().liveStagingTextures;
        }
    }
    for(uint32_t i=0;i<count;++i){const auto& view=views[i];const auto& r=view.rect;
        const D3D11_BOX box{UINT(r.offset.x),UINT(r.offset.y),0,UINT(r.offset.x+r.extent.width),UINT(r.offset.y+r.extent.height),1};
        pool.context->CopySubresourceRegion(pool.slots[i].texture,0,0,0,0,sources[i],
            D3D11CalcSubresource(0,view.imageArrayIndex,descriptors[i].MipLevels),&box);++transferStatistics().copyCommands;
    }
    for(uint32_t i=0;i<count;++i){auto& slot=pool.slots[i];D3D11_MAPPED_SUBRESOURCE mapped{};++transferStatistics().mapCalls;
        pixels[i].resize(size_t(slot.width)*slot.height*4);
        if(FAILED(pool.context->Map(slot.texture,0,D3D11_MAP_READ,0,&mapped)))return false;
        const ReadbackImage source{static_cast<const uint8_t*>(mapped.pData),slot.width,slot.height,mapped.RowPitch,slot.format,swapchainColourSpace(views[i])};
        copyReadbackImage(source,true,pixels[i].data());pool.context->Unmap(slot.texture,0);
        images[i]={pixels[i].data(),slot.width,slot.height,slot.width*4,DXGI_FORMAT_B8G8R8A8_UNORM,source.colorSpace};
    }
    return true;
}
bool readVulkanPanels(void* context,const ControlFrameView* views,uint32_t count,
                     std::vector<std::vector<uint8_t>>& pixels,std::vector<ReadbackImage>& images) {
    if(!context||count>halliday::panels::kMaximum||(!views&&count))return false;
    pixels.resize(count);images.resize(count);
    if(!count)return true;
    std::array<VulkanSource,halliday::panels::kMaximum> sources;
    std::array<HallidayReadbackRequest,halliday::panels::kMaximum> reads{};
    for(uint32_t i=0;i<count;++i){
        const auto& view=views[i];auto& source=sources[i];source=swapchainVulkanImage(view);if(!source.image)return false;
        const auto& r=view.rect;
        if(r.offset.x<0||r.offset.y<0||r.extent.width<=0||r.extent.height<=0||
           uint64_t(r.extent.width)*r.extent.height*4>halliday::panels::kPictureBytes)return false;
        pixels[i].resize(size_t(r.extent.width)*r.extent.height*4);
        reads[i]={source.image.get(),view.imageArrayIndex,uint32_t(r.offset.x),uint32_t(r.offset.y),
                  uint32_t(r.extent.width),uint32_t(r.extent.height),pixels[i].data()};
    }
    if(hxvk_read_batch(context,reads.data(),count))return false;
    for(uint32_t i=0;i<count;++i){
        const auto& source=sources[i];const auto& read=reads[i];
        const bool bgra=source.format==VK_FORMAT_B8G8R8A8_UNORM||source.format==VK_FORMAT_B8G8R8A8_SRGB;
        if(!bgra)for(size_t p=0;p<pixels[i].size();p+=4)std::swap(pixels[i][p],pixels[i][p+2]);
        images[i]={pixels[i].data(),read.width,read.height,read.width*4,
                   DXGI_FORMAT_B8G8R8A8_UNORM,swapchainColourSpace(views[i])};
    }
    return true;
}
}
