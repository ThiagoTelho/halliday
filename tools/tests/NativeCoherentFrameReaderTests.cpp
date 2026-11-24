#include "../../native-alyx/coherent_frame_reader.hpp"
#include "../../native-alyx/frame-bridge/wire_layout.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstring>
#include <functional>
#include <limits>

struct Frame { uint32_t sequenceNumber=0,width=4,height=2,format=87; uint64_t pose=0; };
struct Projection { uint32_t sequence=0; std::array<float,8> tangents{}; };
struct Source {
    uint32_t selected=0, sourceMode=2;
    std::array<Frame,2> frames{};
    std::array<Projection,2> projections{};
    std::array<std::array<uint8_t,32>,2> bytes{};
    std::function<void(Source&,unsigned)> duringCopy;
    unsigned copies=0;
    Source() { publish(0,7,0x71);publish(1,8,0x82);selected=0; }
    void publish(unsigned slot,uint32_t seq,uint8_t colour) {
        frames[slot]={seq,4,2,87,seq*100ull};
        projections[slot].sequence=seq;
        projections[slot].tangents.fill(float(seq));
        bytes[slot].fill(colour);
    }
    uint32_t mode() const {return sourceMode;}
    uint32_t latest() const {return selected;}
    uint32_t sequence(unsigned slot) const {return frames[slot].sequenceNumber;}
    void copyFrame(unsigned slot,Frame& out) {out=frames[slot];}
    void copyPixels(unsigned slot,uint8_t* out,size_t size) {
        assert(size<=32);std::memcpy(out,bytes[slot].data(),size);
        ++copies;if(duringCopy)duringCopy(*this,slot);
    }
    void copyProjection(unsigned slot,Projection& out) {out=projections[slot];}
    void acquireFence() {}
};
int main() {
    using namespace halliday::alyx;
    unsigned checks=0;
    auto check=[&](Source& source,uint32_t previous, bool expected,ReadResult reason,uint32_t sequence,uint8_t colour,uint32_t width=4,uint32_t height=2) {
        Frame frame{99,4,2,87,9900};Projection projection{};projection.sequence=99;
        std::vector<uint8_t> pixels(32,0xaa),scratch;
        ReadAudit audit;
        assert(readCoherentFrame(source,previous,frame,projection,pixels,scratch,128,&audit)==expected);
        assert(audit.result==reason);
        if(expected){assert(frame.sequenceNumber==sequence);assert(frame.pose==sequence*100ull);assert(frame.width==width&&frame.height==height);assert(projection.sequence==sequence);for(auto t:projection.tangents)assert(t==float(sequence));for(auto b:pixels)assert(b==colour);}
        else {assert(frame.sequenceNumber==99);assert(projection.sequence==99);for(auto b:pixels)assert(b==0xaa);}
        ++checks;return audit;
    };
    {Source s;check(s,6,true,ReadResult::accepted_current,7,0x71);}
    // Previously rejected solely because another complete slot became newer.
    {Source s;s.duringCopy=[](auto& s,unsigned){s.selected=1;};check(s,6,true,ReadResult::accepted_superseded,7,0x71);assert(s.copies==1);}
    {Source s;s.duringCopy=[](auto& s,unsigned){s.frames[1].width=2;s.frames[1].height=1;s.selected=1;};check(s,6,true,ReadResult::accepted_superseded,7,0x71);}
    // A genuinely overwritten copy must be discarded; retry the new slot once.
    {Source s;s.duringCopy=[](auto& s,unsigned slot){if(s.copies==1){s.frames[slot].sequenceNumber=0;s.selected=1;}};auto a=check(s,6,true,ReadResult::accepted_current,8,0x82);assert(a.attempts==2&&a.overwrittenAttempts==1);}
    {Source s;s.duringCopy=[](auto& s,unsigned slot){s.frames[slot].sequenceNumber=0;s.selected^=1;};auto a=check(s,6,false,ReadResult::overwritten,0,0);assert(a.attempts==2&&s.copies==2);}
    {Source s;check(s,7,false,ReadResult::duplicate,0,0);assert(s.copies==0);}
    // No generation exists in this ABI: preserve a legitimate producer reset.
    {Source s;check(s,8,true,ReadResult::accepted_current,7,0x71);}
    {Source s;s.frames[0].sequenceNumber=0;check(s,6,false,ReadResult::empty,0,0);}
    {Source s;s.sourceMode=0;check(s,6,false,ReadResult::unavailable,0,0);}
    {Source s;s.frames[0].width=3;check(s,6,false,ReadResult::invalid,0,0);}
    {Source s;s.frames[0].height=0;check(s,6,false,ReadResult::invalid,0,0);}
    {Source s;s.frames[0].width=std::numeric_limits<uint32_t>::max()-1;s.frames[0].height=std::numeric_limits<uint32_t>::max();check(s,6,false,ReadResult::invalid,0,0);}
    {Source s;s.frames[0].format=99;check(s,6,false,ReadResult::invalid,0,0);}
    {Source s;s.frames[0].sequenceNumber=1;s.frames[0].pose=100;s.projections[0].sequence=1;s.projections[0].tangents.fill(1);check(s,std::numeric_limits<uint32_t>::max(),true,ReadResult::accepted_current,1,0x71);}
    {Source s;s.frames[0].format=28;for(unsigned i=0;i<32;++i)s.bytes[0][i]=uint8_t(i*7);Frame f;Projection p;std::vector<uint8_t> pixels,scratch;assert(readCoherentFrame(s,6,f,p,pixels,scratch,128));assert(f.format==28);assert(pixels.size()==32&&!memcmp(pixels.data(),s.bytes[0].data(),32));++checks;}
    std::printf("PASS %u coherent guest-frame reader cases\n",checks);
}
