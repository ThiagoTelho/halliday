#include "frame_timing.hpp"
#include <windows.h>
#include <cstdio>
#include <cwchar>

namespace basalt::timing {
namespace {
thread_local Call* current=nullptr;
uint64_t tick() { LARGE_INTEGER value{};QueryPerformanceCounter(&value);return uint64_t(value.QuadPart); }
struct Sink {
    HANDLE file=INVALID_HANDLE_VALUE;
    uint64_t frequency=0;
    SRWLOCK lock=SRWLOCK_INIT;
    Aggregate aggregate{};
    Sink() {
        wchar_t path[32768]{};
        auto length=GetEnvironmentVariableW(L"HALLIDAY_XR_TIMING_PATH",path,32768);
#if defined(HALLIDAY_XR_TIMING_DIAGNOSTIC_DEFAULT) && HALLIDAY_XR_TIMING_DIAGNOSTIC_DEFAULT
        // Compiled only into the explicitly selected temporary diagnostic DLL.
        // Normal builds retain their zero-QPC/no-file disabled path.
        if(!length) {
            std::wcscpy(path,L"Z:\\private\\tmp\\halliday-xr-timing-dirt.jsonl");
            length=static_cast<DWORD>(std::wcslen(path));
        }
#endif
        if(!length||length>=32768)return;
        LARGE_INTEGER value{};
        if(!QueryPerformanceFrequency(&value)||value.QuadPart<=0)return;
        file=CreateFileW(path,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,nullptr);
        if(file!=INVALID_HANDLE_VALUE)frequency=uint64_t(value.QuadPart);
    }
    ~Sink() { if(file!=INVALID_HANDLE_VALUE)CloseHandle(file); }
    bool enabled() const {return file!=INVALID_HANDLE_VALUE;}
    void add(const Sample& sample,uint64_t now) {
        AcquireSRWLockExclusive(&lock);
        aggregate.add(sample,now);
        if(aggregate.due(now,frequency)) {
            // Exactly one bounded append per window, never one write per frame.
            char output[8192]{};size_t used=0;
            const auto append=[&](const char* format,auto...args) {
                if(used>=sizeof(output)-1)return;
                const int n=std::snprintf(output+used,sizeof(output)-used,format,args...);
                if(n>0)used=std::min(sizeof(output)-1,used+size_t(n));
            };
            const auto& f=aggregate.frame;
            const double ms=1000.0/double(frequency);
            append("{\"version\":1,\"pid\":%lu,\"window_ms\":%.3f,\"wait_calls\":%llu,\"end_calls\":%llu,\"published\":%llu,",
                GetCurrentProcessId(),double(now-aggregate.firstTick)*ms,
                (unsigned long long)aggregate.waits,(unsigned long long)aggregate.ends,(unsigned long long)aggregate.published);
            append("\"last_frame\":{\"api\":%u,\"width\":%u,\"height\":%u,\"formats\":[%u,%u],\"row_pitches\":[%u,%u],\"quad_count\":%u,\"swizzle_eyes\":%u,\"period_ns\":%llu},\"ms\":{",
                f.api,f.width,f.height,f.format[0],f.format[1],f.pitch[0],f.pitch[1],f.quads,f.swizzleEyes,(unsigned long long)f.periodNs);
            bool first=true;
            for(unsigned i=0;i<phaseCount;++i) {
                const auto& v=aggregate.phases[i];if(!v.count)continue;
                append("%s\"%s\":{\"n\":%llu,\"mean\":%.6f,\"min\":%.6f,\"max\":%.6f}",first?"":",",phaseNames[i],
                    (unsigned long long)v.count,double(v.total)*ms/double(v.count),double(v.minimum)*ms,double(v.maximum)*ms);
                first=false;
            }
            append("%s","}}\n");
            DWORD written=0;WriteFile(file,output,DWORD(used),&written,nullptr);
            aggregate={};
        }
        ReleaseSRWLockExclusive(&lock);
    }
};
Sink& sink(){ static Sink value;return value; }
}
Call::Call(bool endFrame) {
    if(!sink().enabled())return;
    active=true;sample.end=endFrame;previous=current;current=this;start=tick();
}
Call::~Call() {
    if(!active)return;
    const uint64_t now=tick();
    sample.add(sample.end?Phase::EndTotal:Phase::WaitTotal,now-start);
    const auto publishIndex=static_cast<unsigned>(Phase::Publish),copyIndex=static_cast<unsigned>(Phase::CpuCopy);
    if(sample.present[publishIndex])sample.add(Phase::PublishOverhead,
        sample.ticks[publishIndex]>=sample.ticks[copyIndex]?sample.ticks[publishIndex]-sample.ticks[copyIndex]:0);
    current=previous;sink().add(sample,now);
}
Span::Span(Phase value):phase(value) { if(current){call=current;start=tick();} }
Span::~Span(){finish();}
void Span::finish(){if(call){call->sample.add(phase,tick()-start);call=nullptr;}}
void describe(const FrameInfo& frame){if(current){current->sample.frame=frame;current->sample.hasFrame=true;}}
void published(bool success){if(current)current->sample.frame.published=success?1u:0u;}
} // namespace basalt::timing
