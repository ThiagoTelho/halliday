// Optional per-component velocity validity, tied to one exact v6 state sequence.
#pragma once
#include "bridge_layout.hpp"
namespace halliday::motion {
constexpr size_t kOffset=64640;
constexpr uint32_t kMagic=0x4d564c48,kVersion=1,kAll=0x3f,kExplicit=1;
struct Extension {
    uint32_t magic,version;
    std::atomic<uint32_t> stateSequence,mask,flags;
    uint32_t reserved[3];
};
static_assert(sizeof(Extension)==32 && offsetof(Extension,stateSequence)==8 && offsetof(Extension,mask)==12);
static_assert(kOffset+sizeof(Extension)<=kHeaderBytes);
inline uint32_t mask(const Header* header,uint32_t sequence) {
    const auto* ext=reinterpret_cast<const Extension*>(reinterpret_cast<const uint8_t*>(header)+kOffset);
    if(ext->magic!=kMagic||ext->version!=kVersion||!(ext->flags.load(std::memory_order_relaxed)&kExplicit))return kAll;
    return ext->stateSequence.load(std::memory_order_relaxed)==sequence?ext->mask.load(std::memory_order_relaxed)&kAll:0;
}
inline bool readState(const Header* header,State* state,uint32_t* validity,uint32_t* sequence=nullptr) {
    for(unsigned retry=0;retry<64;++retry) {
        const auto before=header->stateSeq.load(std::memory_order_acquire);if(before&1)continue;
        auto* dst=reinterpret_cast<uint8_t*>(state);
        const auto* src=reinterpret_cast<const volatile uint8_t*>(&header->state);
        for(size_t i=0;i<sizeof(State);++i)dst[i]=src[i];
        const auto bits=mask(header,before);
        std::atomic_thread_fence(std::memory_order_acquire);
        if(before==header->stateSeq.load(std::memory_order_relaxed)){if(validity)*validity=bits;if(sequence)*sequence=before;return true;}
    }
    return false;
}
}
