#include "frame_timing_aggregate.hpp"
#include <cassert>
#include <cstdio>
using namespace basalt::timing;
int main() {
    Aggregate value{};Sample wait{};wait.add(Phase::WaitHost,0);wait.add(Phase::WaitDeadline,12);
    value.add(wait,100);
    assert(value.waits==1&&!value.due(2100,1000)); // No EndFrame, no output.
    Sample frame{};frame.end=true;frame.hasFrame=true;frame.frame={};
    frame.frame.api=11;frame.frame.width=1824;frame.frame.height=1856;frame.frame.format[0]=28;
    frame.frame.published=1;frame.add(Phase::MapLeft,30);frame.add(Phase::MapRight,2);
    frame.add(Phase::CpuCopy,4);frame.add(Phase::CpuCopy,6);frame.add(Phase::EndTotal,50);
    value.add(frame,101);
    assert(value.ends==1&&value.published==1&&value.frame.width==1824);
    assert(value.phases[unsigned(Phase::CpuCopy)].count==1&&value.phases[unsigned(Phase::CpuCopy)].total==10);
    assert(value.phases[unsigned(Phase::WaitHost)].minimum==0); // Zero is a measured value.
    assert(!value.due(2099,1000)&&value.due(2100,1000));
    for(unsigned n=1;n<120;++n)value.add(frame,102+n);
    assert(value.ends==120&&value.due(300,1000));
    assert(value.phases[unsigned(Phase::MapLeft)].minimum==30&&value.phases[unsigned(Phase::MapLeft)].maximum==30);
    value={};assert(!value.ends&&!value.hasFrame&&!value.due(9999999,1000));
    std::puts("Frame timing aggregation PASS");
}
