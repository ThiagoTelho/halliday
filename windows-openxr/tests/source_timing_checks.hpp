// Independent read-only HLFT byte-layout oracle for opt-in graphics fixtures.
#pragma once
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include <cstring>
#include <stdexcept>

namespace source_timing_checks {
constexpr size_t offset=64704,recordBytes=40;
inline void require(bool value,const char* message) { if(!value)throw std::runtime_error(message); }
inline void initialize(halliday::Header* header) {
    uint32_t values[]{0x54464c48,1,40,19};
    std::memcpy(reinterpret_cast<uint8_t*>(header)+offset,values,sizeof(values));
}
inline void verify(halliday::Header* header,int64_t submittedDisplayTime) {
    const auto latest=header->latest.load();require(latest&&latest<=halliday::kSlots,"HLFT complete pixel slot");
    const auto& frame=header->frames[latest-1];
    require(frame.textureType&(1u<<18),"HLFT optional bit names available exact-image time");
    const auto* data=reinterpret_cast<const uint8_t*>(header)+offset;
    auto word=[&](size_t at){uint32_t value;std::memcpy(&value,data+at,4);return value;};
    auto wide=[&](size_t at){uint64_t value;std::memcpy(&value,data+at,8);return value;};
    require(word(0)==0x54464c48&&word(4)==1&&word(8)==40&&word(12)==19,"HLFT capability layout");
    const auto at=16+(latest-1)*recordBytes;const auto sequence=word(at);
    require(sequence&&!(sequence&1)&&word(at+4)==1,"HLFT committed record");
    require(wide(at+8)==frame.frameIndex&&wide(at+16)==halliday::haptics::extension(header)->clientEpoch.load(),
            "HLFT exact pixel index and producer epoch");
    int64_t nanoseconds=0;std::memcpy(&nanoseconds,data+at+24,8);
    require(nanoseconds==submittedDisplayTime&&word(at+32)==1&&word(at+36)==0,
            "HLFT retains selected prior/current xrEndFrame display time, not newer pose, completion time or nominal interval");
    require(word(at)==sequence,"HLFT stable snapshot");
}
inline void absent(halliday::Header* header) {
    const auto latest=header->latest.load();require(latest&&latest<=halliday::kSlots,"HLFT empty frame is complete");
    require(!(header->frames[latest-1].textureType&(1u<<18)),"empty frame cannot carry stale projection time");
}
} // namespace source_timing_checks
