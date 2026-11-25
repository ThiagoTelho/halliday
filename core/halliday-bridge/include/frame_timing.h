// HLFT v1: optional exact-image producer timing. No cross-clock absolute conversion.
#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
namespace halliday::frame_timing {
constexpr size_t kOffset=64704,kCopiedSlots=3,kPresentRing=16,kRecords=19;
constexpr uint32_t kMagic=0x54464c48,kVersion=1,kValid=1,kFrameSourceTiming=1u<<18;
constexpr uint32_t kClockXrDisplayTimeNs=1,kClockSubmitMonotonicNs=2;
struct Record {std::atomic<uint32_t> sequence,flags;std::atomic<uint64_t> frameIndex,epoch;std::atomic<int64_t> nanoseconds;std::atomic<uint32_t> clockKind,reserved;};
struct Extension {uint32_t magic,version,recordBytes,records;Record entries[kRecords];};
struct Snapshot {uint64_t epoch,frameIndex;int64_t nanoseconds;uint32_t clockKind,reserved;};
static_assert(sizeof(Record)==40&&offsetof(Record,nanoseconds)==24&&offsetof(Record,clockKind)==32);
static_assert(sizeof(Extension)==776&&offsetof(Extension,entries)==16&&kOffset+sizeof(Extension)<=65536);
static_assert(sizeof(Snapshot)==32&&offsetof(Snapshot,nanoseconds)==16&&offsetof(Snapshot,clockKind)==24);
inline bool valid(int64_t ns,uint32_t kind){return ns>0&&(kind==kClockXrDisplayTimeNs||kind==kClockSubmitMonotonicNs);}
inline Extension* extension(void* mapping){if(!mapping)return nullptr;auto* e=reinterpret_cast<Extension*>(static_cast<uint8_t*>(mapping)+kOffset);return e->magic==kMagic&&e->version==kVersion&&e->recordBytes==40&&e->records==kRecords?e:nullptr;}
inline void initialize(void* mapping){auto* e=new(static_cast<uint8_t*>(mapping)+kOffset)Extension{};e->version=kVersion;e->recordBytes=40;e->records=kRecords;e->magic=kMagic;}
inline size_t presentIndex(uint32_t n){return kCopiedSlots+n%kPresentRing;}
inline void clear(void* mapping,size_t i){auto* e=extension(mapping);if(!e||i>=kRecords)return;auto& r=e->entries[i];const auto odd=r.sequence.load(std::memory_order_relaxed)|1u;r.sequence.store(odd,std::memory_order_seq_cst);r.flags.store(0,std::memory_order_relaxed);uint32_t even=odd+1u;if(!even)even=2;r.sequence.store(even,std::memory_order_release);}
// Caller owns and validates the outer image publication/producer lease.
inline bool write(void* mapping,size_t i,uint64_t epoch,uint64_t frameIndex,int64_t ns,uint32_t kind){
 auto* e=extension(mapping);if(!e||i>=kRecords)return false;if(!epoch||!frameIndex||!valid(ns,kind)){clear(mapping,i);return false;}
 auto& r=e->entries[i];const auto odd=r.sequence.load(std::memory_order_relaxed)|1u;r.sequence.store(odd,std::memory_order_seq_cst);r.flags.store(kValid,std::memory_order_relaxed);
 r.frameIndex.store(frameIndex,std::memory_order_relaxed);r.epoch.store(epoch,std::memory_order_relaxed);r.nanoseconds.store(ns,std::memory_order_relaxed);r.clockKind.store(kind,std::memory_order_relaxed);r.reserved.store(0,std::memory_order_relaxed);
 uint32_t even=odd+1u;if(!even)even=2;r.sequence.store(even,std::memory_order_release);return true;
}
inline bool read(void* mapping,size_t i,uint64_t epoch,uint64_t frameIndex,Snapshot* out){
 auto* e=extension(mapping);if(!out)return false;*out={};if(!e||i>=kRecords||!epoch||!frameIndex)return false;auto& r=e->entries[i];
 for(unsigned a=0;a<8;++a){const auto seq=r.sequence.load(std::memory_order_acquire);if(!seq||(seq&1))continue;const auto flags=r.flags.load(std::memory_order_relaxed);
 Snapshot s{r.epoch.load(std::memory_order_relaxed),r.frameIndex.load(std::memory_order_relaxed),r.nanoseconds.load(std::memory_order_relaxed),r.clockKind.load(std::memory_order_relaxed),r.reserved.load(std::memory_order_relaxed)};
 std::atomic_thread_fence(std::memory_order_acquire);if(seq==r.sequence.load(std::memory_order_relaxed)){if(flags!=kValid||s.epoch!=epoch||s.frameIndex!=frameIndex||s.reserved||!valid(s.nanoseconds,s.clockKind))return false;*out=s;return true;}}
 return false;
}
}
