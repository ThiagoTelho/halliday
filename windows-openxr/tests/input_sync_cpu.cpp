// CPU-only differential harness: compile against the preserved pre-change input
// source and the candidate. No D3D device, window, loader, or shared game state.
#ifndef HALLIDAY_INPUT_SOURCE
#define HALLIDAY_INPUT_SOURCE "../src/input.cpp"
#endif
#include HALLIDAY_INPUT_SOURCE
#include <chrono>
#include <cstdlib>
#include "input_sync_manifest.hpp"

namespace fixture {
basalt::ControlInputSnapshot snapshot{};
bool focused=true;
uint64_t events=0,hash=1469598103934665603ULL;
void add(uint64_t v){for(unsigned i=0;i<8;++i){hash^=(v>>(i*8))&255;hash*=1099511628211ULL;}}
void scalar(float f){uint32_t bits;std::memcpy(&bits,&f,4);add(bits);}
XrSession session=reinterpret_cast<XrSession>(0x12340);
}
namespace basalt {
bool isValidSession(XrSession session){return session==fixture::session;}
bool isValidInstance(XrInstance){return true;}
bool isSessionFocused(XrSession){return fixture::focused;}
bool controlInputSnapshot(XrSession,ControlInputSnapshot* out,XrTime){
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
 const auto at=inputSyncSnapshotTimingStart();if(at)Sleep(1); // controlled CPU-only counter plumbing check
#endif
 *out=fixture::snapshot;
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
 inputSyncSnapshotTimingFinish(at);
#endif
 return true;
}
void queueInteractionProfileChanged(XrSession){++fixture::events;}
bool isTopLevelUserPath(XrPath path){return path==1||path==2;}
bool controlSendHaptic(XrSession,ControlHand,uint64_t,float,float){return true;}
bool isKnownPath(XrPath path){return path>0&&path<100000;}
bool pathStringEquals(XrPath path,const char* text){
 return (path==1&&std::strcmp(text,"/user/hand/left")==0)||(path==2&&std::strcmp(text,"/user/hand/right")==0)||
 (path==3&&std::strcmp(text,"/interaction_profiles/oculus/touch_controller")==0)||(path==4&&std::strcmp(text,"/interaction_profiles/khr/simple_controller")==0);
}
}
namespace {
size_t fixtureActions=48;
void setup(bool recorded=false){
 fixtureActions=recorded?std::size(kRecordedActionTypes):48;
 gActions={};gActionSets={};gTouchBindings={};gTouchBindingCount=0;gAttachedSession=fixture::session;gTouchProfilePath=3;gSimpleProfilePath=4;gCurrentInteractionProfiles[0]=gCurrentInteractionProfiles[1]=0;
 for(size_t i=0;i<4;++i){auto& s=gActionSets[i];s.handle=reinterpret_cast<XrActionSet>(0x50000+i*16);s.handleAlive=true;s.attached=true;s.attachedSession=fixture::session;s.priority=i==0?0:i==3?9:5;}
 for(size_t i=0;i<fixtureActions;++i){auto& a=gActions[i];a.handle=reinterpret_cast<XrAction>(0x60000+i*16);a.handleAlive=true;a.actionSet=gActionSets[recorded?kRecordedActionSets[i]:i%4].handle;a.actionType=recorded?kRecordedActionTypes[i]:std::array<XrActionType,5>{XR_ACTION_TYPE_BOOLEAN_INPUT,XR_ACTION_TYPE_FLOAT_INPUT,XR_ACTION_TYPE_VECTOR2F_INPUT,XR_ACTION_TYPE_POSE_INPUT,XR_ACTION_TYPE_VIBRATION_OUTPUT}[i%5];a.subactionPathCount=2;a.subactionPaths[0]=1;a.subactionPaths[1]=2;
  for(unsigned profile=0;profile<2;++profile)for(unsigned hand=0;hand<2;++hand){
   for(const auto& src:kTouchSources){
    if(src.hand!=hand||!bindingCompatible(a.actionType,src.kind))continue;
    if((a.actionType==XR_ACTION_TYPE_BOOLEAN_INPUT||a.actionType==XR_ACTION_TYPE_FLOAT_INPUT)&&src.sourceGroup!=kSourceTrigger)continue;
    if(a.actionType==XR_ACTION_TYPE_VECTOR2F_INPUT&&src.sourceGroup!=kSourceThumbstick)continue;
    if(a.actionType==XR_ACTION_TYPE_POSE_INPUT&&src.kind!=(i%2?BindingKind::kAimPose:BindingKind::kGripPose))continue;
    gTouchBindings[gTouchBindingCount++]={a.handle,XrPath(100+i*10+hand),hand,src.kind,src.inputIdX,src.inputIdY,src.sourceGroup,false,profile?XrPath(4):XrPath(3)};break;
   }
  }
 }
 // Resource semantics: a destroyed public action can retain source ownership
 // through an existing action-space. A future source group uses the exact slow
 // fallback rather than silently dropping its priority competition.
 gActions[3].handleAlive=false;gTouchBindings[7].sourceGroup=99;
}
void physical(unsigned phase,unsigned connected){
 auto& s=fixture::snapshot;s={};
 for(unsigned hand=0;hand<2;++hand){s.controllers[hand].profileActive=(connected&(1u<<hand))!=0;s.controllers[hand].profileId=kQuestTouchProfileId;s.controllers[hand].poseActive=phase%3!=0;s.controllers[hand].triggerValue=float(phase%5)*.25f;}
 for(const auto& src:kTouchSources)for(auto id:{src.inputIdX,src.inputIdY}){
  if(!id)continue;bool exists=false;for(uint32_t j=0;j<s.buttonCount;++j)exists|=s.buttons[j].pathId==id;if(exists)continue;
  const float value=float(int((s.buttonCount+phase)%9)-4)*.25f;
  s.buttons[s.buttonCount++]={id,1,value,XrTime(100000+phase*100)};
 }
}
void hashStates(XrResult result){
 fixture::add(uint64_t(int64_t(result)));fixture::add(fixture::events);
 for(const auto& a:gActions){if(!a.handle)continue;for(const auto& s:a.synced){fixture::add(s.selected);fixture::add(s.selectedHandMask);fixture::add(s.isActive);fixture::add(s.changed);fixture::add(s.booleanValue);fixture::scalar(s.floatValue);fixture::scalar(s.vectorValue.x);fixture::scalar(s.vectorValue.y);fixture::add(s.lastChangeTime);fixture::add(s.poseHand);fixture::add(uint32_t(s.poseKind));}}
 for(size_t i=0;i<gTouchBindingCount;++i){fixture::add(gTouchBindings[i].enabledAfterSync);if(gTouchBindings[i].kind==BindingKind::kHaptic)fixture::add(outputBindingSelectedLocked(fixture::session,gTouchBindings[i],fixture::snapshot));}
}
}
int main(){
 for(unsigned mode=0;mode<2;++mode){
 setup(mode);fixture::hash=1469598103934665603ULL;fixture::events=0;
 for(unsigned phase=0;phase<240;++phase){
  physical(phase,(phase/6)%4);fixture::focused=phase%11!=0;
  XrActiveActionSet active[4]{};unsigned count=phase%13==0?0:4;
  for(unsigned i=0;i<4;++i)active[i]={gActionSets[i].handle,phase%3==0?XrPath(0):phase%3==1?XrPath(1):XrPath(2)};
  // Repeat a physical sample while changing only set selection and filters.
  if(phase%7==0)count=count?2:0;
  XrActionsSyncInfo info{XR_TYPE_ACTIONS_SYNC_INFO};info.countActiveActionSets=count;info.activeActionSets=active;
  const auto result=basalt::syncActions(fixture::session,&info);hashStates(result);
  if (phase%7==0) {
   // Same actual snapshot/packet: change only active sets and hand filters.
   info.countActiveActionSets=phase%2?0:4;
   for(unsigned i=0;i<4;++i)active[i].subactionPath=phase%2?XrPath(1):XrPath(2);
   hashStates(basalt::syncActions(fixture::session,&info));
  }
 }
 std::printf("EQUIVALENCE mode=%u actions=%zu bindings=%zu frames=240 sync_calls=275 hash=%016llx events=%llu\n",mode,fixtureActions,gTouchBindingCount,(unsigned long long)fixture::hash,(unsigned long long)fixture::events);
 }
 for(unsigned connected:{0u,1u,3u}){
  setup(true);physical(4,connected);fixture::focused=true;XrActiveActionSet active[4]{};for(unsigned i=0;i<4;++i)active[i]={gActionSets[i].handle,XR_NULL_PATH};XrActionsSyncInfo info{XR_TYPE_ACTIONS_SYNC_INFO};info.countActiveActionSets=4;info.activeActionSets=active;
  for(unsigned i=0;i<10;++i)basalt::syncActions(fixture::session,&info);
  LARGE_INTEGER begin{},end{},freq{};QueryPerformanceFrequency(&freq);QueryPerformanceCounter(&begin);constexpr unsigned iterations=64;
  for(unsigned i=0;i<iterations;++i)basalt::syncActions(fixture::session,&info);
  QueryPerformanceCounter(&end);const double us=double(end.QuadPart-begin.QuadPart)*1e6/double(freq.QuadPart)/iterations;
  std::printf("TIMING connected=%u iterations=%u mean_sync_us=%.6f\n",connected,iterations,us);
 }
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
 LARGE_INTEGER start{},frequency{};QueryPerformanceCounter(&start);QueryPerformanceFrequency(&frequency);
 if(!hallidayInputTimingReset(uint64_t(start.QuadPart),uint64_t(start.QuadPart+frequency.QuadPart*5)))std::abort();
 if(hallidayInputTimingRead(nullptr,0)||hallidayInputTimingReset(0,0))std::abort();
 XrActiveActionSet active[4]{};for(unsigned i=0;i<4;++i)active[i]={gActionSets[i].handle,XR_NULL_PATH};
 XrActionsSyncInfo info{XR_TYPE_ACTIONS_SYNC_INFO};info.countActiveActionSets=4;info.activeActionSets=active;
 if(basalt::syncActions(fixture::session,&info)!=XR_SUCCESS)std::abort();
 halliday::input_timing::Snapshot snapshot{};
 if(!hallidayInputTimingRead(&snapshot,sizeof(snapshot))||snapshot.completed!=1||snapshot.frequency!=uint64_t(frequency.QuadPart))std::abort();
 for(const auto& counter:snapshot.phases)if(counter.count!=1||counter.sum!=counter.maximum||counter.minimum!=counter.maximum)std::abort();
 if(snapshot.phases[halliday::input_timing::kSnapshotLockWait].sum==0||snapshot.phases[halliday::input_timing::kSnapshot].sum<snapshot.phases[halliday::input_timing::kSnapshotLockWait].sum)std::abort();
 QueryPerformanceCounter(&start);if(!hallidayInputTimingReset(uint64_t(start.QuadPart),uint64_t(start.QuadPart+frequency.QuadPart)))std::abort();
 if(!hallidayInputTimingRead(&snapshot,sizeof(snapshot))||snapshot.completed!=0)std::abort();
 std::puts("PHASE_COUNTER reset/read/invalid-argument/nested-wait/count/generation PASS");
#endif
}
