// CPU-only transport oracle: no graphics API, Wine, device or external files.
#include "source_timing_bridge.hpp"
#include <sys/mman.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <new>

static void require(bool value, const char* message) {
    if (!value) { std::fprintf(stderr,"FAIL: HLFT %s\n",message); std::exit(1); }
}

int main() {
    using namespace halliday;
    namespace timing = halliday::frame_timing;
    void* memory = mmap(nullptr,kFileBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    require(memory != MAP_FAILED,"owned sparse anonymous mapping");
    auto* header = new(memory) Header{};
    header->magic=kMagic; header->version=kVersion; header->clientPid=123;
    header->alive.store(1); header->initialized.store(1);
    auto* owner = new(static_cast<uint8_t*>(memory)+haptics::kOffset) haptics::Extension{};
    owner->magic=haptics::kMagic; owner->version=haptics::kVersion; owner->clockNs.store(1);
    require(haptics::claim(header,123,101)==101,"exact active producer epoch");
    Pose pose{}; pose.valid=1; pose.orientation[3]=1;
    timing::Snapshot snapshot{};
    auto submit = [&](uint64_t index,int64_t sourceTime,uint32_t kind,bool complete=true,uint64_t epoch=101) {
        return publish(header,8,8,false,pose,index,
            [&](size_t eye,uint8_t* pixels) { std::memset(pixels,int(index*7+eye),8*8*4); return complete; },
            frameTextureMetadata(4,1,2),
            [&](size_t slot,uint64_t number) {
                source_timing::publish(header,slot,number,epoch,sourceTime,kind);
                return true; // Timing is optional; valid pixels still publish.
            });
    };
    auto latest = [&] { const auto n=header->latest.load(); require(n&&n<=kSlots,"complete frame slot"); return size_t(n-1); };
    require(submit(1,5'000'000'000LL,timing::kClockXrDisplayTimeNs),"old host keeps complete pixels");
    require(!(header->frames[latest()].textureType&timing::kFrameSourceTiming) &&
            !source_timing::read(header,latest(),1,101,&snapshot),"legacy host has no invented timing");
    timing::initialize(header);
    // Publication indices stay contiguous while one submitted source frame is
    // dropped. Back-to-back completion must preserve the actual source gap.
    const int64_t times[]{5'023'255'813LL,5'046'511'626LL,5'093'023'252LL,5'116'279'065LL};
    for (size_t i=0;i<4;++i) {
        const uint64_t index=i+2;
        require(submit(index,times[i],timing::kClockXrDisplayTimeNs),"bunched complete publication");
        const auto slot=latest();
        require(source_timing::read(header,slot,index,101,&snapshot)&&snapshot.nanoseconds==times[i]&&
                snapshot.clockKind==timing::kClockXrDisplayTimeNs&&snapshot.epoch==101&&snapshot.frameIndex==index,
                "timestamp belongs to exact copied image, not import time, publication count or nominal 60 Hz");
        require(frameColorSpace(header->frames[slot].textureType,0)==1&&frameColorSpace(header->frames[slot].textureType,1)==2,
                "optional bit preserves per-eye colour and graphics API metadata");
        if (i==2) require(times[i]-times[i-1]==46'511'626LL,"missed source frame retains doubled 43 Hz content interval");
    }
    const auto stable=latest(); const auto recordSequence=timing::extension(header)->entries[stable].sequence.load();
    auto& record=timing::extension(header)->entries[stable];
    record.sequence.store(recordSequence|1);
    require(!source_timing::read(header,stable,5,101,&snapshot),"unfinished metadata cannot validate colour");
    record.sequence.store(recordSequence);
    require(!source_timing::read(header,stable,4,101,&snapshot)&&!source_timing::read(header,stable,5,102,&snapshot),
            "metadata frame/owner mismatch rejected");
    record.clockKind.store(99); require(!source_timing::read(header,stable,5,101,&snapshot),"unknown clock rejected");
    record.clockKind.store(timing::kClockXrDisplayTimeNs);
    record.reserved.store(1); require(!source_timing::read(header,stable,5,101,&snapshot),"unknown reserved fields rejected");
    record.reserved.store(0);
    header->reading.store(stable+1);
    require(submit(6,5'139'534'878LL,timing::kClockXrDisplayTimeNs)&&latest()!=stable,
            "busy host slot and timing remain protected together");
    require(source_timing::read(header,stable,5,101,&snapshot)&&snapshot.nanoseconds==times[3],"busy source receipt stays unchanged");
    header->reading.store(0);
    const auto before=header->latest.load();
    require(!submit(7,5'162'790'691LL,timing::kClockXrDisplayTimeNs,false)&&header->latest.load()==before,
            "failed colour publication exposes no new timestamp");
    for (const auto invalid : {int64_t(0),int64_t(-1)}) {
        require(submit(7,invalid,timing::kClockXrDisplayTimeNs),"invalid source time keeps otherwise valid pixels");
        require(!(header->frames[latest()].textureType&timing::kFrameSourceTiming)&&
                !source_timing::read(header,latest(),7,101,&snapshot),"invalid source time is absent rather than nominally fabricated");
    }
    require(submit(8,5'186'046'504LL,99)&&!(header->frames[latest()].textureType&timing::kFrameSourceTiming),
            "unsupported source clock keeps pixels without timing");
    require(submit(9,5'209'302'317LL,timing::kClockSubmitMonotonicNs)&&
            source_timing::read(header,latest(),9,101,&snapshot)&&snapshot.clockKind==timing::kClockSubmitMonotonicNs,
            "distinct monotonic submission clock remains explicitly labelled");
    for(auto& entry:timing::extension(header)->entries) entry.sequence.store(UINT32_MAX-1);
    require(submit(10,5'232'558'130LL,timing::kClockXrDisplayTimeNs)&&
            timing::extension(header)->entries[latest()].sequence.load()==2&&
            source_timing::read(header,latest(),10,101,&snapshot),"wrapped timing seqlock remains complete and readable");
    require(haptics::claim(header,123,102)==102,"replacement source clock domain/owner");
    require(submit(11,5'255'813'943LL,timing::kClockXrDisplayTimeNs,true,101)&&
            !(header->frames[latest()].textureType&timing::kFrameSourceTiming),"stale owner cannot label new colour with old timing");
    require(submit(12,1'000'000'000LL,timing::kClockXrDisplayTimeNs,true,102)&&
            source_timing::read(header,latest(),12,102,&snapshot)&&snapshot.nanoseconds==1'000'000'000LL,
            "new epoch may reset source clock without borrowing prior timing");
    munmap(memory,kFileBytes);
    std::puts("PASS: HLFT exact-image43Hz timing, source gaps/bunched publication, slot/epoch atomicity, optional legacy/invalid clocks, failures and reset");
}
