#include "frame_timing.hpp"
#include <windows.h>
#include <cassert>
#include <cstdio>
using namespace basalt::timing;
int main(int argc,char**) {
    timingTestEnabled=argc>1;
    bool expectedEnabled=timingTestEnabled;
#if defined(HALLIDAY_XR_TIMING_DIAGNOSTIC_DEFAULT) && HALLIDAY_XR_TIMING_DIAGNOSTIC_DEFAULT
    expectedEnabled=true;
#endif
    for(unsigned i=0;i<120;++i){
        {Call wait(false);Span budget(Phase::WaitHost);}
        {Call frame(true);FrameInfo info{};info.api=11;info.width=1824;info.height=1856;
         info.format[0]=info.format[1]=28;info.periodNs=8333333;describe(info);
         {Span prepare(Phase::Prepare);{Span submit(Phase::CopySubmit);}{Span map(Phase::MapLeft);}}
         {Span publish(Phase::Publish);{Span copy(Phase::CpuCopy);}{Span copy(Phase::CpuCopy);}}
         published(true);}
        if(i<119)assert(timingTestWriteCalls==0); // No per-frame I/O.
    }
    if(!expectedEnabled){
        assert(timingTestQpcCalls==0&&timingTestOpenCalls==0&&timingTestWriteCalls==0);
        std::puts("Frame timing disabled PASS: zero QPC/file calls");
    }else{
        assert(timingTestOpenCalls==1&&timingTestWriteCalls==1);
        assert(timingTestPath==(timingTestEnabled?L"private-test.jsonl":L"Z:\\private\\tmp\\halliday-xr-timing-dirt.jsonl"));
        assert(timingTestOutput.find("\"end_calls\":120")!=std::string::npos);
        assert(timingTestOutput.find("\"published\":120")!=std::string::npos);
        assert(timingTestOutput.find("\"width\":1824")!=std::string::npos);
        assert(timingTestOutput.find("\"publish_overhead\"")!=std::string::npos);
        std::puts(timingTestOutput.c_str());
        std::puts("Frame timing enabled PASS: one aggregate/120 frames");
    }
}
