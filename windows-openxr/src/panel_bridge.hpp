// Optional independent OpenXR quad transport. Same v6 reserved-header ABI as panels.rs.
#pragma once
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include <array>
#include <vector>
#include <cmath>
#include <cstring>

namespace halliday::panels {
constexpr size_t kOffset = 61568, kPictureMetadataOffset = 4460;
constexpr uint32_t kMagic = 0x50514c48, kVersion = 1, kMaximum = 8, kNone = UINT32_MAX;
constexpr size_t kPictureBytes = 2048 * 2048 * 4;
struct Panel {
    Pose pose;
    float width, height;
    uint32_t eyeVisibility, flags, order, pictureIndex, pictureSequence, colorSpace, bgra, anchor;
};
struct Batch {
    std::atomic<uint32_t> sequence, count;
    std::atomic<uint64_t> frameIndex, epoch;
    std::atomic<uint32_t> projectionOrder, projectionFlags;
    std::atomic<uint32_t> panels[kMaximum][26];
};
struct Extension { uint32_t magic, version, reserved[2]; Batch batches[kSlots]; };
struct Picture { std::atomic<uint32_t> sequence, reading, width, height; };
struct Image { Panel panel{}; uint32_t width=0, height=0; const uint8_t* pixels=nullptr; size_t bytes=0; };
static_assert(sizeof(Panel)==104 && sizeof(Batch)==864 && sizeof(Extension)==2608 && sizeof(Picture)==16);
static_assert(kOffset+sizeof(Extension)<=kHeaderBytes);
inline Extension* extension(Header* header) {
    auto* ext=reinterpret_cast<Extension*>(reinterpret_cast<uint8_t*>(header)+kOffset);
    return ext->magic==kMagic && ext->version==kVersion ? ext : nullptr;
}
inline Picture* picture(Header* header,size_t index) {
    return reinterpret_cast<Picture*>(reinterpret_cast<uint8_t*>(header)+kPictureMetadataOffset)+index;
}
inline size_t pictureOffset(size_t index) { return kHeaderBytes+kSlots*2*kEyeBytes+index*kPictureBytes; }
inline bool valid(const Panel& p) {
    if(!std::isfinite(p.width)||!std::isfinite(p.height)||p.width<=0||p.height<=0||
       p.eyeVisibility>2||(p.flags&~3u)||p.order>kMaximum||p.pictureIndex>=kMaximum||
       p.colorSpace>2||p.bgra>1||p.anchor>1) return false;
    float norm=0;
    for(float v:p.pose.position) if(!std::isfinite(v)) return false;
    for(float v:p.pose.orientation) {if(!std::isfinite(v))return false;norm+=v*v;}
    return norm>=.98f&&norm<=1.02f;
}
// All inputs are validated before reserving, and every reservation precedes any
// pixel write. A busy host read leaves the complete old frame untouched.
inline bool publishPictures(Header* header,const std::vector<Image>& images,std::vector<Panel>& records) {
    if(images.size()>kMaximum || (!images.empty()&&!extension(header))) return false;
    uint32_t orders=0;
    for(size_t i=0;i<images.size();++i) {
        auto p=images[i].panel;p.pictureIndex=static_cast<uint32_t>(i);
        const auto& image=images[i];
        if(!valid(p)||!image.width||!image.height||image.width>4096||image.height>4096||
           uint64_t(image.width)*image.height*4>kPictureBytes||
           image.bytes!=size_t(image.width)*image.height*4||!image.pixels||
           (orders&(1u<<p.order))) return false;
        orders|=1u<<p.order;
    }
    std::array<uint32_t,kMaximum> old{};
    for(size_t i=0;i<images.size();++i) {
        auto* p=picture(header,i);old[i]=p->sequence.load();p->sequence.store(old[i]|1u);
        if(p->reading.load()) {
            for(size_t j=0;j<=i;++j) picture(header,j)->sequence.store(old[j]);
            return false;
        }
    }
    records.clear(); records.reserve(images.size());
    for(size_t i=0;i<images.size();++i) {
        const auto& image=images[i];auto* p=picture(header,i);
        p->width.store(image.width,std::memory_order_relaxed);p->height.store(image.height,std::memory_order_relaxed);
        std::memcpy(reinterpret_cast<uint8_t*>(header)+pictureOffset(i),image.pixels,image.bytes);
        uint32_t sequence=(old[i]|1u)+1u;if(!sequence)sequence=2;
        p->sequence.store(sequence,std::memory_order_release);
        auto panel=image.panel;panel.pictureIndex=static_cast<uint32_t>(i);panel.pictureSequence=sequence;
        records.push_back(panel);
    }
    return true;
}
// Called from inside frame publication, before latest becomes visible.
inline bool publishBatch(Header* header,size_t slot,uint64_t frameIndex,uint64_t epoch,
                         uint32_t projectionOrder,uint32_t projectionFlags,const std::vector<Panel>& records) {
    auto* ext=extension(header);auto* control=haptics::extension(header);
    if(!ext) return records.empty(); // Backward-compatible projection-only peer.
    if(slot>=kSlots||!epoch||!frameIndex||!control||control->clientEpoch.load()!=epoch||
       header->initialized.load()!=1||control->ownerPid.load()!=header->clientPid||
       records.size()>kMaximum||(projectionFlags&~3u)||
       (projectionOrder!=kNone&&projectionOrder>kMaximum)) return false;
    uint32_t orders=projectionOrder==kNone?0:1u<<projectionOrder;
    uint32_t pictures=0;
    for(const auto& p:records) {
        if(!valid(p)||!p.pictureSequence||(p.pictureSequence&1u)||(orders&(1u<<p.order))||
           (pictures&(1u<<p.pictureIndex)))return false;
        orders|=1u<<p.order;pictures|=1u<<p.pictureIndex;
    }
    auto& batch=ext->batches[slot];const uint32_t odd=batch.sequence.load()|1u;
    batch.sequence.store(odd);
    batch.count.store(static_cast<uint32_t>(records.size()),std::memory_order_relaxed);
    batch.frameIndex.store(frameIndex,std::memory_order_relaxed);batch.epoch.store(epoch,std::memory_order_relaxed);
    batch.projectionOrder.store(projectionOrder,std::memory_order_relaxed);
    batch.projectionFlags.store(projectionFlags,std::memory_order_relaxed);
    for(size_t i=0;i<records.size();++i) {
        std::array<uint32_t,26> words{};std::memcpy(words.data(),&records[i],sizeof(Panel));
        for(size_t j=0;j<words.size();++j)batch.panels[i][j].store(words[j],std::memory_order_relaxed);
    }
    const uint32_t committed=odd+1u;
    batch.sequence.store(committed?committed:2u,std::memory_order_release);
    return true;
}
} // namespace halliday::panels
