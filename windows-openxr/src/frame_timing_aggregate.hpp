// Optional diagnostic counters. Tick units are supplied by the caller (QPC in production).
#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <limits>

namespace basalt::timing {
enum class Phase : unsigned {
    WaitTotal, WaitToken, WaitHost, WaitDeadline, EndTotal, FrameLock,
    Prepare, CopySubmit, GpuWait, MapLeft, MapRight, CpuCopy, Publish, PublishOverhead, Panels, Count
};
constexpr unsigned phaseCount = static_cast<unsigned>(Phase::Count);
inline constexpr const char* phaseNames[phaseCount] = {
    "wait_total", "wait_token", "wait_host_budget", "wait_deadline", "end_total", "frame_lock",
    "prepare", "copy_submit", "gpu_fence_wait", "map_left", "map_right", "cpu_copy", "publish", "publish_overhead", "panels"
};
struct Value {
    uint64_t count=0, total=0, maximum=0, minimum=std::numeric_limits<uint64_t>::max();
    void add(uint64_t ticks) { ++count; total+=ticks; maximum=std::max(maximum,ticks); minimum=std::min(minimum,ticks); }
};
struct FrameInfo {
    uint32_t api=0, width=0, height=0, format[2]{}, pitch[2]{}, quads=0;
    uint32_t swizzleEyes=0, published=0;
    uint64_t periodNs=0;
};
struct Sample {
    std::array<uint64_t,phaseCount> ticks{};
    std::array<bool,phaseCount> present{};
    FrameInfo frame{};
    bool end=false, hasFrame=false;
    void add(Phase phase,uint64_t elapsed) { const auto i=static_cast<unsigned>(phase); ticks[i]+=elapsed;present[i]=true; }
};
struct Aggregate {
    std::array<Value,phaseCount> phases{};
    uint64_t waits=0, ends=0, published=0, firstTick=0;
    FrameInfo frame{};
    bool hasFrame=false;
    void add(const Sample& sample,uint64_t now) {
        if(!firstTick) firstTick=now;
        if(sample.end) ++ends; else ++waits;
        for(unsigned i=0;i<phaseCount;++i) if(sample.present[i])phases[i].add(sample.ticks[i]);
        if(sample.hasFrame) {frame=sample.frame;hasFrame=true;published+=sample.frame.published;}
    }
    bool due(uint64_t now,uint64_t frequency) const {
        return ends&&(ends>=120||(firstTick&&now>=firstTick&&now-firstTick>=frequency*2));
    }
};
} // namespace basalt::timing
