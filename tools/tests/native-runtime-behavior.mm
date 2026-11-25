// MIT. Public OpenXR caller and our existing public host C APIs; no encoder or app.
#define XR_NO_PROTOTYPES
#define XR_USE_TIMESPEC
#define XR_USE_GRAPHICS_API_METAL
#import <Metal/Metal.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include "halliday_core.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <future>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <vector>
namespace fs=std::filesystem;
static void check(bool v,const char* s){if(!v)throw std::runtime_error(s);}
static void success(XrResult r,const char* s){if(XR_FAILED(r))throw std::runtime_error(std::string(s)+" result="+std::to_string(r));}
static uint64_t now(){static mach_timebase_info_data_t b=[](){mach_timebase_info_data_t x{};mach_timebase_info(&x);return x;}();return uint64_t(((__uint128_t)mach_absolute_time()*b.numer)/b.denom);}
static PFN_xrGetInstanceProcAddr gipa{};static XrInstance instance{};
static double predictionLead(XrTime value){return (value-int64_t(now()))/1e6;}
template<class T>static T xr(const char* n){PFN_xrVoidFunction f{};success(gipa(instance,n,&f),n);check(f,n);return reinterpret_cast<T>(f);}
struct Host {
 fs::path dir;HallidayGameBridge* independent{};
 std::mutex lock;HallidayBridgeState state{};std::atomic<bool> done{false};std::atomic<double> hz{72};std::thread worker;
 Host(const char* root):dir(root){
  check(dir.string().find("/build/validation/")!=std::string::npos,"private owned validation path");
  check(!fs::exists(dir),"host directory must be new");fs::create_directory(dir);
  HallidayBridgeConfig c{};c.eye_width=c.eye_height=512;c.display_hz=72;c.ipd=.064f;
  const float t[2][4]={{-.9f,1.1f,1.f,-1.05f},{-1.1f,.9f,1.f,-1.05f}};memcpy(c.tangents,t,sizeof(t));
  state.head.valid=1;state.head.position[0]=.2f;state.head.position[1]=1.6f;state.head.position[2]=-.1f;state.head.orientation[1]=std::sin(.2f);state.head.orientation[3]=std::cos(.2f);
  for(unsigned h=0;h<2;++h){auto& p=state.controllers[h].pose;p=state.head;p.position[0]=h?.3f:-.3f;p.position[1]=1.1f;state.controllers[h].connected=1;}
  independent=halliday_bridge_open((dir/"bridge.shm").c_str(),&c);check(independent,"create isolated host");setenv("HALLIDAY_BRIDGE",(dir/"bridge.shm").c_str(),1);
  publish();worker=std::thread([this]{auto next=std::chrono::steady_clock::now();while(!done.load()){
   publish();next+=std::chrono::nanoseconds(uint64_t(1e9/hz.load()));auto current=std::chrono::steady_clock::now();if(next<current)next=current;std::this_thread::sleep_until(next);}});
 }
 void publish(){std::lock_guard<std::mutex> l(lock);state.head.stamp=float((now()/1000000)%10000000);halliday_bridge_publish_frame_with_motion(independent,&state,true,63);halliday_bridge_frame_shown(independent,uint64_t(1e9/hz.load()),false);}
 void rate(double value){hz.store(value);std::this_thread::sleep_for(std::chrono::milliseconds(45));}
 void dashboard(bool shown){halliday_bridge_set_dashboard(independent,shown);}
 void validity(bool valid){{std::lock_guard<std::mutex> l(lock);state.head.valid=valid;}publish();}
 void rebase(){ {std::lock_guard<std::mutex> l(lock);state.head.position[0]+=.7f;state.head.position[2]-=.4f;for(auto& h:state.controllers){h.pose.position[0]+=.7f;h.pose.position[2]-=.4f;}}publish();halliday_bridge_reference_changed(independent);}
 ~Host(){done.store(true);if(worker.joinable())worker.join();if(independent)halliday_bridge_close(independent);}
};
static std::vector<XrSessionState> states(XrSession session,const char* phase){std::vector<XrSessionState> result;for(unsigned i=0;i<64;++i){XrEventDataBuffer b{XR_TYPE_EVENT_DATA_BUFFER};const auto r=xr<PFN_xrPollEvent>("xrPollEvent")(instance,&b);if(r==XR_EVENT_UNAVAILABLE)break;success(r,"poll");if(b.type==XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED){auto& e=*reinterpret_cast<XrEventDataSessionStateChanged*>(&b);result.push_back(e.state);printf("EVENT {\"kind\":\"state\",\"phase\":\"%s\",\"state\":%d,\"same_session\":%s}\n",phase,e.state,e.session==session?"true":"false");}else if(b.type==XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING){auto& e=*reinterpret_cast<XrEventDataReferenceSpaceChangePending*>(&b);printf("EVENT {\"kind\":\"reference\",\"phase\":\"%s\",\"space_type\":%d,\"valid\":%u,\"time\":%lld}\n",phase,e.referenceSpaceType,e.poseValid,(long long)e.changeTime);}}return result;}
static XrSpace space(XrSession session,XrReferenceSpaceType kind){XrReferenceSpaceCreateInfo i{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};i.referenceSpaceType=kind;i.poseInReferenceSpace.orientation.w=1;XrSpace out{};success(xr<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&i,&out),"create reference");return out;}
static XrFrameState wait(XrSession session){XrFrameState f{XR_TYPE_FRAME_STATE};success(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&f),"wait frame");return f;}
static void finish(XrSession s,const XrFrameState& f){success(xr<PFN_xrBeginFrame>("xrBeginFrame")(s,nullptr),"begin frame");XrFrameEndInfo e{XR_TYPE_FRAME_END_INFO};e.displayTime=f.predictedDisplayTime;e.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;success(xr<PFN_xrEndFrame>("xrEndFrame")(s,&e),"end empty frame");}
static void snapshot(XrSession s,XrSpace stage,XrSpace local,const XrFrameState& f,const char* phase){
 XrViewLocateInfo i{XR_TYPE_VIEW_LOCATE_INFO};i.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;i.displayTime=f.predictedDisplayTime;i.space=stage;XrViewState vs{XR_TYPE_VIEW_STATE};XrView v[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}};uint32_t n=0;success(xr<PFN_xrLocateViews>("xrLocateViews")(s,&i,&vs,2,&n,v),"locate views");
 XrSpaceLocation l{XR_TYPE_SPACE_LOCATION};success(xr<PFN_xrLocateSpace>("xrLocateSpace")(local,stage,f.predictedDisplayTime,&l),"locate local");
 printf("EVENT {\"kind\":\"snapshot\",\"phase\":\"%s\",\"should_render\":%u,\"view_flags\":%llu,\"period_ns\":%lld,\"time\":%lld,\"eye0\":[%.8f,%.8f,%.8f],\"local_position\":[%.8f,%.8f,%.8f],\"local_orientation\":[%.8f,%.8f,%.8f,%.8f],\"local_flags\":%llu}\n",phase,f.shouldRender,(unsigned long long)vs.viewStateFlags,(long long)f.predictedDisplayPeriod,(long long)f.predictedDisplayTime,v[0].pose.position.x,v[0].pose.position.y,v[0].pose.position.z,l.pose.position.x,l.pose.position.y,l.pose.position.z,l.pose.orientation.x,l.pose.orientation.y,l.pose.orientation.z,l.pose.orientation.w,(unsigned long long)l.locationFlags);
}
static void pacing(XrSession s,unsigned samples,const char* phase,double requested){std::vector<double> durations,leads;XrDuration period=0;XrTime previous=0;unsigned backwards=0,should=0;auto last=std::chrono::steady_clock::now();for(unsigned i=0;i<samples+3;++i){auto f=wait(s);auto called=std::chrono::steady_clock::now();if(i>=3){durations.push_back(std::chrono::duration<double,std::milli>(called-last).count());leads.push_back(predictionLead(f.predictedDisplayTime));should+=f.shouldRender!=0;if(f.predictedDisplayTime<=previous)++backwards;}previous=f.predictedDisplayTime;period=f.predictedDisplayPeriod;last=called;finish(s,f);}double sum=0;for(auto v:durations)sum+=v;std::sort(durations.begin(),durations.end());std::sort(leads.begin(),leads.end());printf("EVENT {\"kind\":\"pacing\",\"phase\":\"%s\",\"host_hz\":%.1f,\"samples\":%u,\"mean_ms\":%.6f,\"median_ms\":%.6f,\"p95_ms\":%.6f,\"observed_fps\":%.6f,\"reported_period_ns\":%lld,\"prediction_lead_ms_median\":%.6f,\"nonincreasing_times\":%u,\"should_render_count\":%u}\n",phase,requested,samples,sum/samples,durations[samples/2],durations[samples*95/100],samples*1000/sum,(long long)period,leads[samples/2],backwards,should);}
int main(int argc,char** argv){@autoreleasepool{try{
 setvbuf(stdout,nullptr,_IONBF,0);check(argc==3,"usage: native-behavior RUNTIME OWN_NEW_DIR");Host host(argv[2]);
 void* module=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);check(module,"load source-built runtime");auto negotiate=reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(dlsym(module,"xrNegotiateLoaderRuntimeInterface"));check(negotiate,"negotiation export");XrNegotiateLoaderInfo l{XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,1,sizeof(l),1,1,XR_MAKE_VERSION(1,0,0),XR_MAKE_VERSION(1,1,0)};XrNegotiateRuntimeRequest q{XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST,1,sizeof(q)};success(negotiate(&l,&q),"negotiate");gipa=q.getInstanceProcAddr;
 const char* ext[]={"XR_KHR_metal_enable"};XrInstanceCreateInfo c{XR_TYPE_INSTANCE_CREATE_INFO};strcpy(c.applicationInfo.applicationName,"halliday-native-behavior");c.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);c.enabledExtensionCount=1;c.enabledExtensionNames=ext;success(xr<PFN_xrCreateInstance>("xrCreateInstance")(&c,&instance),"create instance");XrInstanceProperties p{XR_TYPE_INSTANCE_PROPERTIES};success(xr<PFN_xrGetInstanceProperties>("xrGetInstanceProperties")(instance,&p),"properties");printf("EVENT {\"kind\":\"identity\",\"name\":\"%s\"}\n",p.runtimeName);
 XrSystemGetInfo get{XR_TYPE_SYSTEM_GET_INFO};get.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;XrSystemId system{};success(xr<PFN_xrGetSystem>("xrGetSystem")(instance,&get,&system),"system");XrGraphicsRequirementsMetalKHR req{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};success(xr<PFN_xrGetMetalGraphicsRequirementsKHR>("xrGetMetalGraphicsRequirementsKHR")(instance,system,&req),"Metal requirements");id<MTLDevice> device=MTLCreateSystemDefaultDevice();id<MTLCommandQueue> queue=[device newCommandQueue];check(device&&queue,"small Metal device/queue");XrGraphicsBindingMetalKHR b{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};b.commandQueue=(__bridge void*)queue;XrSessionCreateInfo sc{XR_TYPE_SESSION_CREATE_INFO};sc.systemId=system;sc.next=&b;XrSession session{};success(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sc,&session),"session");states(session,"created");XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};bi.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;success(xr<PFN_xrBeginSession>("xrBeginSession")(session,&bi),"begin session");states(session,"started");auto stage=space(session,XR_REFERENCE_SPACE_TYPE_STAGE),local=space(session,XR_REFERENCE_SPACE_TYPE_LOCAL);
 auto initial=wait(session);snapshot(session,stage,local,initial,"baseline");finish(session,initial);pacing(session,24,"baseline72",72);
 host.dashboard(true);states(session,"dashboard-on");auto f=wait(session);snapshot(session,stage,local,f,"dashboard-on");finish(session,f);host.dashboard(false);states(session,"dashboard-off");
 host.validity(false);std::this_thread::sleep_for(std::chrono::milliseconds(20));states(session,"head-invalid");f=wait(session);snapshot(session,stage,local,f,"head-invalid");finish(session,f);host.validity(true);std::this_thread::sleep_for(std::chrono::milliseconds(20));states(session,"head-restored");f=wait(session);snapshot(session,stage,local,f,"head-restored");finish(session,f);
 host.rate(60);pacing(session,24,"rate60",60);host.rate(120);pacing(session,24,"rate120",120);
 host.rebase();states(session,"host-reference-change");f=wait(session);snapshot(session,stage,local,f,"after-reference-change");finish(session,f);
 // Legal pipeline: the next Wait may run elsewhere but must await preceding Begin.
 auto first=wait(session);auto worker=std::async(std::launch::async,[&]{return wait(session);});bool early=worker.wait_for(std::chrono::milliseconds(80))==std::future_status::ready;success(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr),"consume first wait");check(worker.wait_for(std::chrono::seconds(1))==std::future_status::ready,"second wait unblocks independently of End");auto second=worker.get();auto discarded=xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr);printf("EVENT {\"kind\":\"pipeline\",\"returned_before_preceding_begin\":%s,\"second_begin_result\":%d,\"first_time\":%lld,\"second_time\":%lld}\n",early?"true":"false",discarded,(long long)first.predictedDisplayTime,(long long)second.predictedDisplayTime);success(discarded,"second begin");XrFrameEndInfo e{XR_TYPE_FRAME_END_INFO};e.displayTime=second.predictedDisplayTime;e.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;success(xr<PFN_xrEndFrame>("xrEndFrame")(session,&e),"finish pipeline");
 success(xr<PFN_xrDestroySpace>("xrDestroySpace")(local),"destroy local");success(xr<PFN_xrDestroySpace>("xrDestroySpace")(stage),"destroy stage");success(xr<PFN_xrDestroySession>("xrDestroySession")(session),"destroy own session");success(xr<PFN_xrDestroyInstance>("xrDestroyInstance")(instance),"destroy own instance");dlclose(module);puts("PASS direct native behavior observation");return 0;
 }catch(const std::exception& e){fprintf(stderr,"FAIL %s\n",e.what());return 1;}}}
