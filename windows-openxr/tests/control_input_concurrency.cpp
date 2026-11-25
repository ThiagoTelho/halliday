// Includes the actual control implementation. Backends below are inert CPU
// callbacks: one explicit event simulates an unfinished GPU readback. All bridge
// files live in the disposable test bottle's private Temp and are deleted.
#ifndef HALLIDAY_CONTROL_SOURCE
#define HALLIDAY_CONTROL_SOURCE "../src/control.cpp"
#endif
#include HALLIDAY_CONTROL_SOURCE
#include <atomic>
#include <new>
#include <cstdlib>

namespace fake {
HANDLE entered=CreateEventW(nullptr,TRUE,FALSE,nullptr),release=CreateEventW(nullptr,TRUE,FALSE,nullptr);
std::atomic<bool> gpu{false};std::atomic<unsigned> resets{0},unsafeResets{0};
uint8_t pixels[8*8*4]{};
void require(bool test,const char* text){if(!test){std::fprintf(stderr,"FAIL %s\n",text);std::abort();}}
bool prepare(basalt::ReadbackImage images[2]){gpu.store(true);SetEvent(entered);require(WaitForSingleObject(release,4000)==WAIT_OBJECT_0,"release fake GPU within bound");gpu.store(false);for(unsigned i=0;i<2;++i)images[i]={pixels,8,8,8*4,DXGI_FORMAT_R8G8B8A8_UNORM,1,false,false};return true;}
void resetGate(){ResetEvent(entered);ResetEvent(release);gpu=false;}
}
namespace basalt {
// Inert fixture supplies the same finite/unit-pose contract; spatial API
// integration remains covered by the existing public runtime GPU fixtures.
bool isPoseWellFormed(const XrPosef& pose){
 const auto& q=pose.orientation;
 if(!std::isfinite(q.x)||!std::isfinite(q.y)||!std::isfinite(q.z)||!std::isfinite(q.w)||!std::isfinite(pose.position.x)||!std::isfinite(pose.position.y)||!std::isfinite(pose.position.z))return false;
 const double norm=std::sqrt(double(q.x)*q.x+double(q.y)*q.y+double(q.z)*q.z+double(q.w)*q.w);return norm>=.99&&norm<=1.01;
}
XrResult XRAPI_CALL requestExitSession(XrSession){return XR_SUCCESS;}
bool prepareD3D11Frame(ID3D11Device*,const ControlFrameView[2],ReadbackImage[2]){return false;}
void finishD3D11Frame(){}void resetD3D11Readback(){}
bool prepareD3D12Frame(ID3D12Device*,ID3D12CommandQueue*,const ControlFrameView[2],ReadbackImage[2]){return false;}
void finishD3D12Frame(){}bool resetD3D12Readback(){return true;}
PriorStagingResult prepareD3D11PriorFrame(ID3D11Device*,const PriorProjectionFrame&,ReadbackImage[2],PriorProjectionFrame*){return PriorStagingResult::Failed;}
void resetD3D11PriorReadback(){}
PriorStagingResult prepareD3D12PriorFrame(ID3D12Device*,ID3D12CommandQueue*,const PriorProjectionFrame&,ReadbackImage[2],PriorProjectionFrame*){return PriorStagingResult::Failed;}
void finishD3D12PriorFrame(){}bool resetD3D12PriorReadback(){return true;}
bool prepareVulkanFrame(void*,const ControlFrameView[2],ReadbackImage images[2],std::array<std::vector<uint8_t>,2>&){return fake::prepare(images);}
PriorStagingResult prepareVulkanPriorFrame(void*,const PriorProjectionFrame& frame,ReadbackImage images[2],PriorProjectionFrame* captured){*captured=frame;return fake::prepare(images)?PriorStagingResult::Ready:PriorStagingResult::Failed;}
void finishVulkanPriorFrame(void*){}
bool resetVulkanPriorReadback(void*){++fake::resets;if(fake::gpu.load())++fake::unsafeResets;return true;}
void abandonVulkanPriorReadback(void*){}
void resetD3D11Panels(){}bool resetD3D12Panels(){return true;}
bool readD3D11Panels(ID3D11Device*,const ControlFrameView*,uint32_t,std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&){return false;}
bool readD3D12Panels(ID3D12Device*,ID3D12CommandQueue*,const ControlFrameView*,uint32_t,std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&){return false;}
bool readVulkanPanels(void*,const ControlFrameView*,uint32_t,std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&){return false;}
void copyReadbackImage(const ReadbackImage& image,bool,uint8_t* out){for(uint32_t row=0;row<image.height;++row)std::memcpy(out+row*image.width*4,image.pixels+row*image.rowPitch,image.width*4);}
}
namespace basalt::timing {
Span::Span(Phase value):phase(value),start(0){}Span::~Span(){}void Span::finish(){}
void describe(const FrameInfo&){}void published(bool){}
}
namespace {
struct Host {
 wchar_t path[MAX_PATH]{};HANDLE file=INVALID_HANDLE_VALUE,mapping=nullptr;halliday::Header* header=nullptr;XrSession session{};bool destroyed=false;
 Host(uintptr_t id=0x12340):session(reinterpret_cast<XrSession>(id)){
  wchar_t temp[MAX_PATH]{};fake::require(GetTempPathW(MAX_PATH,temp)&&GetTempFileNameW(temp,L"hcc",0,path),"private temporary bridge path");
  file=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_TEMPORARY,nullptr);fake::require(file!=INVALID_HANDLE_VALUE,"private bridge file");
  LARGE_INTEGER length{};length.QuadPart=halliday::kFileBytes;fake::require(SetFilePointerEx(file,length,nullptr,FILE_BEGIN)&&SetEndOfFile(file),"sparse bridge extent");
  mapping=CreateFileMappingW(file,nullptr,PAGE_READWRITE,0,0,nullptr);fake::require(mapping!=nullptr,"private mapping");header=static_cast<halliday::Header*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,halliday::kFileBytes));fake::require(header!=nullptr,"host mapping");new(header)halliday::Header{};
  header->magic=halliday::kMagic;header->version=halliday::kVersion;header->eyeWidth=header->eyeHeight=8;header->ipd=.064f;header->displayHz=120;header->intervalNs.store(8333333);header->alive.store(1);header->vsync.store(1);
  for(auto& t:header->tangents){t[0]=-1;t[1]=1;t[2]=1;t[3]=-1;}
  auto* ext=new(reinterpret_cast<uint8_t*>(header)+halliday::haptics::kOffset)halliday::haptics::Extension{};ext->magic=halliday::haptics::kMagic;ext->version=1;ext->clockNs.store(1000);ext->spaceEpoch.store(1);
  halliday::focus::initialize(header);halliday::projection::initialize(header);
  update(.125f,7,0);
  fake::require(SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH",path),"scope route to private fixture");
  basalt::controlSessionCreatedVulkan(session,reinterpret_cast<void*>(0x44));fake::require(basalt::controlActive(session),"actual create binds private mapping");
 }
 void update(float trigger,uint64_t packet,float x){
  auto state=header->state;state.head.valid=1;state.head.orientation[3]=1;state.head.position[0]=x;state.head.position[1]=1.6f;state.head.stamp=float(packet);
  for(auto& c:state.controllers){c.connected=1;c.packet=packet;c.axes[1][0]=trigger;c.pose=state.head;}
  header->stateSeq.fetch_or(1);std::memcpy(&header->state,&state,sizeof(state));header->stateSeq.fetch_add(1);header->vsync.fetch_add(1);
 }
 void destroy(){if(!destroyed){basalt::controlSessionDestroyed(session);destroyed=true;}}
 ~Host(){destroy();if(header)UnmapViewOfFile(header);if(mapping)CloseHandle(mapping);if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);DeleteFileW(path);SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH",nullptr);}
};
struct Frame {
 basalt::ControlFrameView views[2]{};XrResult result=XR_ERROR_RUNTIME_FAILURE;HANDLE thread=nullptr;
 Frame(){for(unsigned eye=0;eye<2;++eye){views[eye].swapchainId=eye+1;views[eye].rect.extent={8,8};views[eye].pose={{0,0,0,1},{eye?.032f:-.032f,1.6f,0}};views[eye].fov={-.785398163f,.785398163f,.785398163f,-.785398163f};}}
 void start(){fake::resetGate();thread=CreateThread(nullptr,0,[](void* p)->DWORD{auto& f=*static_cast<Frame*>(p);f.result=basalt::controlFrameReady(0,7,f.views,2,nullptr,0,0,0,1);return 0;},this,0,nullptr);fake::require(thread&&WaitForSingleObject(fake::entered,2000)==WAIT_OBJECT_0,"actual frame enters fake GPU");}
 void finish(){SetEvent(fake::release);fake::require(WaitForSingleObject(thread,2000)==WAIT_OBJECT_0,"frame joins");CloseHandle(thread);thread=nullptr;}
};
struct Input {
 XrSession session;basalt::ControlInputSnapshot snapshot{};bool result=false,rendering=false;uint32_t width=0,height=0;HANDLE done=CreateEventW(nullptr,TRUE,FALSE,nullptr),thread=nullptr;
 explicit Input(XrSession s):session(s){}
 void start(){thread=CreateThread(nullptr,0,[](void* p)->DWORD{auto& in=*static_cast<Input*>(p);in.result=basalt::controlInputSnapshot(in.session,&in.snapshot);in.rendering=basalt::controlRenderingAllowed(in.session);basalt::controlConfiguredViewSize(&in.width,&in.height);SetEvent(in.done);return 0;},this,0,nullptr);fake::require(thread!=nullptr,"input thread");}
 void finish(){fake::require(WaitForSingleObject(thread,2000)==WAIT_OBJECT_0,"input joins");CloseHandle(thread);thread=nullptr;}
 ~Input(){CloseHandle(done);}
};
enum Mutation {None,Space,Focus,Layout,Owner,HostDead};
void freshCase(Mutation mutation,bool prior,bool oldExpectedBlocked=false){
 Host host;AcquireSRWLockExclusive(&gLock);gPriorCapture=prior;ReleaseSRWLockExclusive(&gLock);
 XrPosef oldPose{};uint64_t oldStamp=0;const XrTime historical=timeNow();fake::require(basalt::controlHeadPose(host.session,historical,&oldStamp,&oldPose)&&oldStamp==7,"cache exact pre-capture pose");
 Frame frame;frame.start();const unsigned beforeReset=fake::resets.load();host.update(.75f,8,2);
 if(mutation==Space)halliday::haptics::extension(host.header)->spaceEpoch.fetch_add(1);
 if(mutation==Focus){halliday::focus::setDashboard(host.header,true);halliday::focus::setDashboard(host.header,false);}
 if(mutation==Layout)host.header->eyeWidth=10;
 if(mutation==Owner)halliday::haptics::extension(host.header)->clientEpoch.fetch_add(1);
 if(mutation==HostDead)host.header->alive.store(0);
 Input input(host.session);input.start();const bool freshBeforeGpu=WaitForSingleObject(input.done,250)==WAIT_OBJECT_0;
 if(oldExpectedBlocked)fake::require(!freshBeforeGpu,"original source must demonstrate input blocked by GPU");
 else {
  fake::require(freshBeforeGpu,"fresh input must finish while actual frame still GPU-blocked");
  if(mutation==Owner||mutation==HostDead)fake::require(!input.result,"lost owner/dead host fails input closed");
  else fake::require(input.result&&input.snapshot.controllers[0].questTimestampNanoseconds==8&&input.snapshot.controllers[0].triggerValue==.75f&&input.snapshot.controllers[1].profileActive,"input reads new live packet, both hands and pressure");
  fake::require(fake::gpu.load()&&fake::resets.load()==beforeReset&&fake::unsafeResets.load()==0,"input never resets in-flight GPU staging");
  if(mutation==Layout)fake::require(input.width==10,"live configuration reader is independent of GPU");
  if(mutation==Space){XrPosef historicalOrigin{};fake::require(basalt::controlReferenceOrigin(host.session,XR_REFERENCE_SPACE_TYPE_LOCAL,&historicalOrigin,historical)&&historicalOrigin.position.x==0,"historical pre-recenter origin retained");basalt::ControlInputSnapshot historicalInput{};fake::require(basalt::controlInputSnapshot(host.session,&historicalInput,historical)&&historicalInput.controllers[0].questTimestampNanoseconds==7,"known historical packet remains exact");}
 }
 frame.finish();input.finish();fake::require(fake::unsafeResets.load()==0,"no concurrent backend reset");
 if(!oldExpectedBlocked){fake::require(frame.result==XR_SUCCESS,"retired frame is an orderly drop");if(mutation==None){fake::require(host.header->latest.load()!=0,"unchanged packet published");const auto& published=host.header->frames[host.header->latest.load()-1];fake::require(published.pose.stamp==7&&published.pose.position[0]==0,"new input never retags older rendered pose");}else fake::require(host.header->latest.load()==0,"focus/space/layout/owner/death retires captured pixels");}
 std::printf("CASE mutation=%d prior=%d input_before_gpu=%d PASS\n",int(mutation),prior,freshBeforeGpu);
}
void shutdownCase(){
 Host old;Frame frame;frame.start();HANDLE done=CreateEventW(nullptr,TRUE,FALSE,nullptr);struct Args{Host* host;HANDLE done;} args{&old,done};HANDLE thread=CreateThread(nullptr,0,[](void* p)->DWORD{auto& a=*static_cast<Args*>(p);a.host->destroy();SetEvent(a.done);return 0;},&args,0,nullptr);
 fake::require(thread&&WaitForSingleObject(done,40)==WAIT_TIMEOUT,"destroy waits for pinned GPU capture");fake::require(gHeader!=nullptr&&fake::gpu.load(),"mapping/device lifetime retained during destroy wait");frame.finish();fake::require(WaitForSingleObject(thread,2000)==WAIT_OBJECT_0,"destroy completes after capture release");CloseHandle(thread);CloseHandle(done);fake::require(gHeader==nullptr&&gSession==XR_NULL_HANDLE,"old mapping/session retired");basalt::ControlInputSnapshot stale{};fake::require(!basalt::controlInputSnapshot(old.session,&stale),"closed session cannot read unmapped input");
 {Host replacement(0x56780);replacement.update(.375f,777,5);basalt::ControlInputSnapshot current{};fake::require(basalt::controlInputSnapshot(replacement.session,&current)&&current.controllers[1].questTimestampNanoseconds==777,"reconnected session reads new mapping only");fake::require(!basalt::controlInputSnapshot(old.session,&stale),"old session cannot read replacement mapping");}
 std::puts("CASE shutdown/reconnect/mapping-lifetime PASS");
}
}
int main(int argc,char**){
 if(argc>1){freshCase(None,false,true);std::puts("ORIGINAL blocked-input repro PASS");}
 else {for(bool prior:{false,true})for(auto mutation:{None,Space,Focus,Layout,Owner,HostDead})freshCase(mutation,prior);shutdownCase();std::puts("CONTROL actual-source fresh-input/lifetime/epochs12cases PASS");}
 CloseHandle(fake::entered);CloseHandle(fake::release);
}
