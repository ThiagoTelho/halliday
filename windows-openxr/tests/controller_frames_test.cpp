// CPU-only protocol/basis candidate. No process, graphics, HID or user state.
#include "bridge_layout.hpp"
#include "controller_frames_bridge.hpp"
#include "../../core/halliday-bridge/include/controller_frames.h"
#include "../../core/halliday-bridge/include/frame_timing.h"
#include <array>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
namespace f = halliday::controller_frames;
static void require(bool ok, const char* why) { if (!ok) { std::fprintf(stderr, "FAIL: %s\n", why); std::exit(1); } }
using Q = std::array<float, 4>;
static Q multiply(const Q& a, const Q& b) {
    return {a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1],
            a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0],
            a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3],
            a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2]};
}
static Q rotation(float degrees, size_t axis) {
    constexpr float radians = 3.14159265358979323846f / 180.f;
    const float half = degrees * radians * .5f;
    Q q{0,0,0,std::cos(half)}; q[axis] = std::sin(half); return q;
}
static Q convert(f::FrameKind kind, f::Target target, const Q& q) {
    Q result{}; f::orientation(kind,target,q.data(),result.data()); return result;
}
static void near(const Q& a, const Q& b) {
    float sum = 0, flipped = 0;
    for (size_t i=0;i<4;++i) { sum += (a[i]-b[i])*(a[i]-b[i]); flipped += (a[i]+b[i])*(a[i]+b[i]); }
    require(std::min(sum,flipped)<1e-10f,"orientation matches independent source transform");
}
int main() {
    alignas(64) std::array<uint8_t,65536> memory{};
    auto* h = new(memory.data()) halliday::Header{};
    f::Kinds read{};
    require(!f::read(h,h->stateSeq,0,&read) && read==f::kLegacy,"old host/new reader stays undeclared");
    const auto before = memory;
    f::initialize(h);
    require(!std::memcmp(memory.data(),before.data(),halliday::frame_timing::kOffset+sizeof(halliday::frame_timing::Extension)),
        "initialization does not change v6 fields or timing extension");
    const f::Kinds oneSense{f::FrameKind::SenseAim,f::FrameKind::Legacy};
    require(!f::write(h,h->stateSeq,2,oneSense),"writer must own odd state sequence");
    h->stateSeq.store(1);
    require(f::write(h,h->stateSeq,2,oneSense),"paired host metadata write");
    require(!f::read(h,h->stateSeq,2,&read),"uncommitted outer state rejected");
    h->state.controllers[0].pose.orientation[3] = 1;
    h->stateSeq.store(2);
    require(f::read(h,h->stateSeq,2,&read) && read==oneSense,"left Sense/right mouse are distinct");
    halliday::State typedState{}; uint32_t mask=0;
    require(f::readState(h,&typedState,&mask,&read) && read==oneSense && mask==halliday::motion::kAll,
        "production state+motion+frame wrapper reads the matching declaration");
    halliday::State legacyState{};
    require(halliday::readState(h,&legacyState) && legacyState.controllers[0].pose.orientation[3]==1,
        "new host/old reader sees unchanged v6 pose");
    require(!f::read(h,h->stateSeq,4,&read) && read==f::kLegacy,"stale state marker rejected and output cleared");
    auto* e = f::extension(h); e->sequence.store(3);
    require(!f::read(h,h->stateSeq,2,&read),"odd metadata rejected");
    e->sequence.store(4); e->kinds[1].store(9);
    require(!f::read(h,h->stateSeq,2,&read),"unknown hand kind rejected");
    h->stateSeq.store(3);
    const f::Kinds otherSense{f::FrameKind::Legacy,f::FrameKind::SenseAim};
    require(f::write(h,h->stateSeq,4,otherSense),"real/mouse roles can swap");
    h->stateSeq.store(4);
    require(f::read(h,h->stateSeq,4,&read) && read==otherSense,"right Sense/left mouse pairing");
    h->state.controllers[0].packet=49;
    h->stateSeq.store(6); // A legacy publisher advances the state without HLCF.
    require(f::readState(h,&typedState,&mask,&read) && read==f::kLegacy && typedState.controllers[0].packet==49,
        "fresh untagged pixels/input must not inherit a stale physical-controller declaration");
    h->stateSeq.store(UINT32_MAX);
    require(f::write(h,h->stateSeq,0,f::kLegacy),"state wrap can clear prior Sense tags");
    h->stateSeq.store(0);
    require(f::read(h,h->stateSeq,0,&read) && read==f::kLegacy,"wrapped zero state identity remains exact");
    e->version=99;
    require(!f::read(h,h->stateSeq,0,&read),"unknown capability version is absent");
    for (unsigned hand=0;hand<2;++hand) for(float yaw:{-140.f,-45.f,0.f,45.f,140.f})
      for(float roll:{-180.f,-90.f,0.f,90.f,180.f}) for(float pitch:{-65.f,0.f,65.f}) {
        const auto sensor=multiply(multiply(rotation(yaw,1),rotation(pitch,0)),rotation(roll,2));
        const auto aim=multiply(sensor,rotation(49.8703f,0));
        const auto expected=multiply(sensor,rotation(109.8703f,0));
        near(convert(f::FrameKind::SenseAim,f::Target::OpenXrGrip,aim),expected);
        auto aliased=aim;f::orientation(f::FrameKind::SenseAim,f::Target::OpenXrGrip,aliased.data(),aliased.data());
        near(aliased,expected);
        require(convert(f::FrameKind::SenseAim,f::Target::OpenXrAim,aim)==aim,"AIM stays byte-identical");
        require(convert(f::FrameKind::SenseAim,f::Target::LegacyOpenVr,aim)==aim,"native Alyx/OpenVR reference preserved");
        for(auto target:{f::Target::OpenXrAim,f::Target::OpenXrGrip,f::Target::LegacyOpenVr})
            require(convert(f::FrameKind::Legacy,target,aim)==aim,"old/mouse source is never converted");
        const auto step=rotation(3.f,1);
        near(multiply(step,convert(f::FrameKind::SenseAim,f::Target::OpenXrGrip,aim)),
            convert(f::FrameKind::SenseAim,f::Target::OpenXrGrip,multiply(step,aim)));
    }
    halliday::Pose source{};source.position[0]=.2f;source.position[1]=1.1f;source.position[2]=-.4f;
    source.valid=1;source.orientation[3]=1;source.velocity[0]=.4f;source.angularVelocity[1]=1.4f;source.stamp=73;
    auto converted=source;f::orientation(f::FrameKind::SenseAim,f::Target::OpenXrGrip,source.orientation,converted.orientation);
    require(!std::memcmp(source.position,converted.position,sizeof(source.position)) &&
        !std::memcmp(source.velocity,converted.velocity,sizeof(source.velocity)) &&
        !std::memcmp(source.angularVelocity,converted.angularVelocity,sizeof(source.angularVelocity)) &&
        source.valid==converted.valid && source.stamp==converted.stamp,"origin, world velocities, validity and stamp remain unchanged");
    std::puts("PASS: HLCF32-byte layout; old/new host-reader matrix; state pairing/wrap/rejection; both Sense/mouse hands; source-derived local rotation; OpenVR/AIM preserved; unchanged origin/world velocity");
}
