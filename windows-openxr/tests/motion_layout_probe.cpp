#include "motion_bridge.hpp"
#include "halliday_core.h"
#include <cstdio>
#include <cstdlib>
#include <new>
#include <cstring>
#include <initializer_list>
static void require(bool value,const char* why){if(!value){std::fprintf(stderr,"FAIL HLVM: %s\n",why);std::exit(1);}}
int main(){
    using namespace halliday;
    alignas(Header) unsigned char memory[kHeaderBytes]{};auto* header=new(memory)Header{};
    State state{};uint32_t mask=0;
    require(motion::readState(header,&state,&mask)&&mask==motion::kAll,"old host metadata absent");
    auto* ext=new(memory+motion::kOffset)motion::Extension{};ext->version=motion::kVersion;ext->magic=motion::kMagic;
    for(uint32_t bits:{0u,1u,2u,3u,4u,8u,16u,32u,63u,0xffffu}) {
        const auto sequence=header->stateSeq.load()|1;header->stateSeq.store(sequence);
        header->state.head.velocity[0]=float(bits);ext->mask.store(bits);ext->flags.store(motion::kExplicit);
        ext->stateSequence.store(sequence+1);header->stateSeq.store(sequence+1,std::memory_order_release);
        require(motion::readState(header,&state,&mask)&&mask==(bits&63)&&state.head.velocity[0]==float(bits),"exact state/component association");
    }
    ext->stateSequence.fetch_add(2);
    require(motion::readState(header,&state,&mask)&&mask==0,"explicit mismatched metadata fails closed");
    ext->flags.store(0);require(motion::readState(header,&state,&mask)&&mask==63,"legacy producer fallback");
    ext->stateSequence.store(0);ext->flags.store(motion::kExplicit);ext->mask.store(17);header->stateSeq.store(0);
    require(motion::readState(header,&state,&mask)&&mask==17,"complete wrapped state sequence zero");
    header->stateSeq.store(1);require(!motion::readState(header,&state,&mask),"odd state cannot publish a mask");
    std::printf("{\"Extension\":%zu,\"offset\":%zu,\"sequence_offset\":%zu,\"mask_offset\":%zu,\"flags_offset\":%zu,\"head_pose\":%zu,\"head_motion\":%zu,\"linear_offset\":%zu,\"motion_flags_offset\":%zu}\n",
        sizeof(motion::Extension),motion::kOffset,offsetof(motion::Extension,stateSequence),offsetof(motion::Extension,mask),offsetof(motion::Extension,flags),
        sizeof(HallidayHeadPose),sizeof(HallidayHeadPoseMotion),offsetof(HallidayHeadPoseMotion,linear_velocity),offsetof(HallidayHeadPoseMotion,motion_flags));
}
