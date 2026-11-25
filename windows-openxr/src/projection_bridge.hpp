// HLPG v1: exact canonical per-eye projection geometry in the reserved v6 header.
#pragma once
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include <array>
#include <cmath>
#include <cstring>
#include <new>
namespace halliday::projection {
constexpr size_t kOffset=64256;
constexpr uint32_t kMagic=0x47504c48,kVersion=1,kValid=1;
struct View {float position[3],orientation[4],tangents[4];};
struct Record {
    std::atomic<uint32_t> sequence,flags;
    std::atomic<uint64_t> frameIndex,epoch;
    std::atomic<uint32_t> views[2][11];
};
struct Extension {uint32_t magic,version,recordBytes,slots;Record records[kSlots];};
struct Snapshot {uint64_t epoch,frameIndex;View views[2];};
static_assert(sizeof(View)==44&&sizeof(Record)==112&&sizeof(Extension)==352&&sizeof(Snapshot)==104);
static_assert(offsetof(Record,views)==24&&offsetof(Extension,records)==16&&kOffset+sizeof(Extension)<=kHeaderBytes);
inline bool valid(const View& view) {
    float norm=0;
    for(float value:view.position)if(!std::isfinite(value))return false;
    for(float value:view.orientation){if(!std::isfinite(value))return false;norm+=value*value;}
    for(float value:view.tangents)if(!std::isfinite(value))return false;
    return norm>=.98f&&norm<=1.02f&&view.tangents[1]>view.tangents[0]&&view.tangents[2]>view.tangents[3]&&
        std::isfinite(view.tangents[1]-view.tangents[0])&&std::isfinite(view.tangents[2]-view.tangents[3]);
}
inline Extension* extension(Header* header) {
    if(!header)return nullptr;
    auto* ext=reinterpret_cast<Extension*>(reinterpret_cast<uint8_t*>(header)+kOffset);
    return ext->magic==kMagic&&ext->version==kVersion&&ext->recordBytes==sizeof(Record)&&ext->slots==kSlots?ext:nullptr;
}
inline void initialize(Header* header) {
    auto* ext=new(reinterpret_cast<uint8_t*>(header)+kOffset)Extension{};
    ext->version=kVersion;ext->recordBytes=sizeof(Record);ext->slots=kSlots;ext->magic=kMagic;
}
// Called by BeforePublish while this frame slot is reserved and still odd.
inline bool publish(Header* header,size_t slot,uint64_t frameIndex,uint64_t epoch,const View views[2]) {
    auto* ext=extension(header);auto* control=haptics::extension(header);
    if(!ext||!control||!views||slot>=kSlots||!epoch||!frameIndex||!valid(views[0])||!valid(views[1])||
       control->clientEpoch.load()!=epoch||control->ownerPid.load()!=header->clientPid||header->initialized.load()!=1||
       header->reading.load()==slot+1||header->latest.load()==slot+1||
       !(header->frames[slot].seq.load()&1)||header->frames[slot].frameIndex!=frameIndex)return false;
    auto& record=ext->records[slot];const uint32_t odd=record.sequence.load()|1u;
    record.sequence.store(odd);
    record.flags.store(kValid,std::memory_order_relaxed);record.frameIndex.store(frameIndex,std::memory_order_relaxed);
    record.epoch.store(epoch,std::memory_order_relaxed);
    for(size_t eye=0;eye<2;++eye){std::array<uint32_t,11> words{};std::memcpy(words.data(),&views[eye],sizeof(View));
        for(size_t word=0;word<words.size();++word)record.views[eye][word].store(words[word],std::memory_order_relaxed);}
    uint32_t even=odd+1u;if(!even)even=2;
    record.sequence.store(even,std::memory_order_release);
    return control->clientEpoch.load()==epoch&&header->initialized.load()==1;
}
inline bool read(Header* header,size_t slot,uint64_t frameIndex,uint64_t epoch,Snapshot* out) {
    auto* ext=extension(header);if(!ext||!out||slot>=kSlots||!frameIndex||!epoch)return false;
    auto& record=ext->records[slot];
    for(unsigned attempt=0;attempt<8;++attempt){
        const uint32_t seq=record.sequence.load(std::memory_order_acquire);if(!seq||(seq&1))continue;
        const auto flags=record.flags.load(std::memory_order_relaxed);Snapshot copy{};
        copy.frameIndex=record.frameIndex.load(std::memory_order_relaxed);copy.epoch=record.epoch.load(std::memory_order_relaxed);
        for(size_t eye=0;eye<2;++eye){std::array<uint32_t,11> words{};
            for(size_t word=0;word<words.size();++word)words[word]=record.views[eye][word].load(std::memory_order_relaxed);
            std::memcpy(&copy.views[eye],words.data(),sizeof(View));}
        std::atomic_thread_fence(std::memory_order_acquire);
        if(seq==record.sequence.load(std::memory_order_relaxed)){
            if(flags!=kValid||copy.frameIndex!=frameIndex||copy.epoch!=epoch||!valid(copy.views[0])||!valid(copy.views[1]))return false;
            *out=copy;return true;
        }
    }
    return false;
}
}
