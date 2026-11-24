#include "projection_bridge.hpp"
#include <sys/mman.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
static void require(bool value,const char* reason){if(!value){std::fprintf(stderr,"FAIL: HLPG %s\n",reason);std::exit(1);}}
int main(){
    using namespace halliday;
    void* memory=mmap(nullptr,kFileBytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    require(memory!=MAP_FAILED,"sparse mapping");auto* header=new(memory)Header{};
    header->magic=kMagic;header->version=kVersion;header->alive.store(1);header->initialized.store(1);header->clientPid=123;
    auto* control=new(reinterpret_cast<uint8_t*>(header)+haptics::kOffset)haptics::Extension{};
    control->magic=haptics::kMagic;control->version=haptics::kVersion;control->clockNs.store(1);
    require(haptics::claim(header,123,101)==101,"claim actual producer epoch");
    require(!projection::extension(header)&&!projection::extension(nullptr),"old host has no optional geometry capability");
    projection::initialize(header);require(projection::extension(header),"fresh host geometry capability");
    projection::View views[2]{};for(auto& view:views){view.orientation[3]=1;view.tangents[0]=-1.2f;view.tangents[1]=.9f;view.tangents[2]=1.1f;view.tangents[3]=-.8f;}
    views[0].position[0]=-.04f;views[1].position[0]=.035f;views[1].tangents[1]=1.3f;
    const auto fill=[](size_t eye,uint8_t* pixels){std::memset(pixels,eye?34:17,8*8*4);return true;};
    Pose pose{};pose.valid=1;pose.orientation[3]=1;
    auto submit=[&](uint64_t index,uint64_t epoch,const projection::View input[2]){
        return publish(header,8,8,true,pose,index,fill,frameTextureMetadata(4,1,2)|kFrameProjectionGeometry,
            [&](size_t slot,uint64_t frame){return projection::publish(header,slot,frame,epoch,input);});};
    require(submit(1,101,views),"geometry published inside reserved frame before latest");
    const size_t first=header->latest.load()-1;projection::Snapshot snapshot{};
    require(projection::read(header,first,1,101,&snapshot)&&!std::memcmp(snapshot.views,views,sizeof(views)),"exact independent stereo geometry");
    require(frameColorSpace(header->frames[first].textureType,0)==1&&frameColorSpace(header->frames[first].textureType,1)==2,
        "required geometry flag preserves API and color bits");
    auto* ext=projection::extension(header);auto& record=ext->records[first];const auto sequence=record.sequence.load();
    record.sequence.store(sequence|1);require(!projection::read(header,first,1,101,&snapshot),"incomplete record rejected");record.sequence.store(sequence);
    require(!projection::read(header,first,2,101,&snapshot)&&!projection::read(header,first,1,102,&snapshot),"wrong frame or epoch rejected");
    record.flags.store(3);require(!projection::read(header,first,1,101,&snapshot),"unknown geometry flags rejected");record.flags.store(projection::kValid);
    header->reading.store(first+1);views[1].position[1]=.25f;
    require(submit(2,101,views)&&header->latest.load()!=first+1,"busy host slot not reused");
    require(projection::read(header,first,1,101,&snapshot)&&snapshot.views[1].position[1]==0,"old reader geometry remains unchanged");
    for(auto& item:ext->records)item.sequence.store(UINT32_MAX-1);
    require(submit(3,101,views),"sequence wrap publication");const size_t latest=header->latest.load()-1;
    require(ext->records[latest].sequence.load()==2&&projection::read(header,latest,3,101,&snapshot),"wrapped complete sequence is nonzero and readable");
    const auto before=header->latest.load();const auto frames=header->clientFrames.load();views[1].tangents[1]=views[1].tangents[0];
    require(!submit(4,101,views)&&header->latest.load()==before&&header->clientFrames.load()==frames,"invalid geometry never replaces a complete frame");
    views[1].tangents[1]=1.3f;require(submit(4,101,views),"recovery after unpublished invalid slot");
    ext->magic=0;const auto retained=header->latest.load();require(!submit(5,101,views)&&header->latest.load()==retained,"required geometry cannot silently fall back on old host");
    require(publish(header,8,8,true,pose,5,fill,frameTextureMetadata(4,1,2)),"legacy unflagged producer remains usable without capability");
    require(!(header->frames[header->latest.load()-1].textureType&kFrameProjectionGeometry),"legacy frame does not require stale geometry");
    ext->magic=projection::kMagic;require(haptics::claim(header,123,102)==102,"replacement producer epoch");
    require(!submit(6,101,views),"stale producer cannot publish geometry under another owner epoch");
    munmap(memory,kFileBytes);std::puts("PASS: HLPG exact stereo publication, required flag, busy/odd/stale/invalid records, wrap, recovery and legacy peers");
}
