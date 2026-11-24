// Optional HLFC v1 focus generation. Existing v6 headers and HLHP are unchanged.
#pragma once
#include "bridge_layout.hpp"
#include <new>
namespace halliday::focus {
constexpr size_t kOffset=64176;
constexpr uint32_t kMagic=0x43464c48, kVersion=1;
struct Extension {
    uint32_t magic,version;
    std::atomic<uint64_t> state,producerEpoch,requestTags[2];
};
static_assert(sizeof(Extension)==40 && offsetof(Extension,state)==8 &&
    offsetof(Extension,producerEpoch)==16 && offsetof(Extension,requestTags)==24);
static_assert(kOffset+sizeof(Extension)<=kHeaderBytes);
inline Extension* extension(Header* header) {
    if(!header)return nullptr;
    auto* ext=reinterpret_cast<Extension*>(reinterpret_cast<uint8_t*>(header)+kOffset);
    return ext->magic==kMagic&&ext->version==kVersion?ext:nullptr;
}
inline uint32_t generation(const Extension* ext) {return ext?uint32_t(ext->state.load(std::memory_order_acquire)>>32):0;}
inline bool shown(const Extension* ext) {return ext&&(ext->state.load(std::memory_order_acquire)&1);}
inline void initialize(Header* header) {
    auto* ext=new(reinterpret_cast<uint8_t*>(header)+kOffset)Extension{};
    ext->version=kVersion;ext->state.store(uint64_t(1)<<32);ext->magic=kMagic;
}
inline void setDashboard(Header* header,bool shown) {
    header->dashboard.store(shown?1u:0u);
    auto* ext=extension(header);if(!ext)return;
    uint64_t old=ext->state.load();
    while(bool(old&1)!=shown) {
        uint32_t generation=uint32_t(old>>32)+1;if(!generation)generation=1;
        if(ext->state.compare_exchange_weak(old,(uint64_t(generation)<<32)|(shown?1u:0u)))break;
    }
}
inline void claim(Header* header,uint64_t epoch) {
    auto* ext=extension(header);if(!ext)return;
    ext->producerEpoch.store(0,std::memory_order_release);
    for(auto& tag:ext->requestTags)tag.store(0,std::memory_order_release);
    ext->producerEpoch.store(epoch,std::memory_order_release);
}
inline void tag(Extension* ext,uint64_t epoch,uint32_t hand,uint32_t sequence,uint32_t generation) {
    if(ext&&hand<2&&ext->producerEpoch.load(std::memory_order_acquire)==epoch)
        ext->requestTags[hand].store((uint64_t(sequence)<<32)|generation,std::memory_order_relaxed);
}
}
