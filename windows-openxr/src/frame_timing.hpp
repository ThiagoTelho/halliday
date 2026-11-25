#pragma once
#include "frame_timing_aggregate.hpp"

namespace basalt::timing {
// Enabled by a nonempty HALLIDAY_XR_TIMING_PATH; normal builds have no default.
// A temporary diagnostic build can explicitly compile its private fallback path.
// No QPC calls, output file, or aggregate locking on the disabled path.
class Call {
public:
    explicit Call(bool endFrame);
    ~Call();
    Call(const Call&)=delete;
    Call& operator=(const Call&)=delete;
private:
    friend class Span;
    friend void describe(const FrameInfo&);
    friend void published(bool);
    Sample sample{};
    Call* previous=nullptr;
    uint64_t start=0;
    bool active=false;
};
class Span {
public:
    explicit Span(Phase phase);
    ~Span();
    void finish();
    Span(const Span&)=delete;
private:
    Call* call=nullptr;
    Phase phase;
    uint64_t start=0;
};
void describe(const FrameInfo& frame);
void published(bool success);
} // namespace basalt::timing
