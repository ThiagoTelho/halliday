// CPU-only actual guest-adapter header fixture. No XR loader/device/GPU exists.
#include <openxr/openxr.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <unistd.h>
#include <vector>
#include "native-alyx/frame-bridge/shared_bridge.h"
static void check(XrResult result,const char*) { if(XR_FAILED(result))throw std::runtime_error("mock XR failure"); }
#include "native-alyx/frame-bridge/controllers.h"

namespace tf=halliday::alyx::touch_raw;
static XrPosef poses[2];
static XrVector3f linear[2],angular[2];
static XrSpaceVelocityFlags motionFlags=XR_SPACE_VELOCITY_LINEAR_VALID_BIT|XR_SPACE_VELOCITY_ANGULAR_VALID_BIT;
static XrResult XRAPI_PTR syncActions(XrSession,const XrActionsSyncInfo*) { return XR_SUCCESS; }
static XrResult XRAPI_PTR poseActive(XrSession,const XrActionStateGetInfo*,XrActionStatePose* out) { out->isActive=XR_TRUE;return XR_SUCCESS; }
static XrResult XRAPI_PTR scalar(XrSession,const XrActionStateGetInfo*,XrActionStateFloat* out) { out->isActive=XR_TRUE;out->currentState=.25f;return XR_SUCCESS; }
static XrResult XRAPI_PTR button(XrSession,const XrActionStateGetInfo*,XrActionStateBoolean* out) { out->isActive=XR_TRUE;out->currentState=XR_TRUE;return XR_SUCCESS; }
static XrResult XRAPI_PTR vector2(XrSession,const XrActionStateGetInfo*,XrActionStateVector2f* out) { out->isActive=XR_TRUE;out->currentState={.25f,-.5f};return XR_SUCCESS; }
static XrResult XRAPI_PTR locate(XrSpace space,XrSpace,XrTime,XrSpaceLocation* out) {
    const unsigned h=unsigned(reinterpret_cast<uintptr_t>(space)-1);
    out->pose=poses[h];out->locationFlags=XR_SPACE_LOCATION_POSITION_VALID_BIT|XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
    auto* v=static_cast<XrSpaceVelocity*>(out->next);v->velocityFlags=motionFlags;v->linearVelocity=linear[h];v->angularVelocity=angular[h];return XR_SUCCESS;
}
static XrResult XRAPI_PTR destroy(XrSpace) { return XR_SUCCESS; }
static XrResult XRAPI_PTR destroySet(XrActionSet) { return XR_SUCCESS; }
static XrResult XRAPI_PTR stringPath(XrInstance,const char* name,XrPath* out) {
    *out=std::strcmp(name,"/user/hand/left")==0?1:std::strcmp(name,"/user/hand/right")==0?2:100;return XR_SUCCESS;
}
static XrResult XRAPI_PTR createSet(XrInstance,const XrActionSetCreateInfo*,XrActionSet* out) { *out=reinterpret_cast<XrActionSet>(uintptr_t(10));return XR_SUCCESS; }
static XrResult XRAPI_PTR createAction(XrActionSet,const XrActionCreateInfo*,XrAction* out) { *out=reinterpret_cast<XrAction>(uintptr_t(20));return XR_SUCCESS; }
static XrResult XRAPI_PTR suggest(XrInstance,const XrInteractionProfileSuggestedBinding*) { return XR_SUCCESS; }
static XrResult XRAPI_PTR createSpace(XrSession,const XrActionSpaceCreateInfo* info,XrSpace* out) { *out=reinterpret_cast<XrSpace>(uintptr_t(info->subactionPath));return XR_SUCCESS; }
static XrResult XRAPI_PTR attach(XrSession,const XrSessionActionSetsAttachInfo*) { return XR_SUCCESS; }
static XrResult XRAPI_PTR mockGipa(XrInstance,const char* name,PFN_xrVoidFunction* out) {
#define MOCK(x,f) if(std::strcmp(name,x)==0){*out=reinterpret_cast<PFN_xrVoidFunction>(f);return XR_SUCCESS;}
    MOCK("xrSyncActions",syncActions) MOCK("xrLocateSpace",locate) MOCK("xrGetActionStatePose",poseActive)
    MOCK("xrGetActionStateFloat",scalar) MOCK("xrGetActionStateBoolean",button) MOCK("xrGetActionStateVector2f",vector2)
    MOCK("xrDestroySpace",destroy) MOCK("xrDestroyActionSet",destroySet) MOCK("xrStringToPath",stringPath)
    MOCK("xrCreateActionSet",createSet) MOCK("xrCreateAction",createAction) MOCK("xrSuggestInteractionProfileBindings",suggest)
    MOCK("xrCreateActionSpace",createSpace) MOCK("xrAttachSessionActionSets",attach)
#undef MOCK
    *out=nullptr;return XR_ERROR_FUNCTION_UNSUPPORTED;
}
template<class T> static void configure(T& c) {
    c.sync=syncActions;c.getPose=poseActive;c.getFloat=scalar;c.getBool=button;c.getVector=vector2;c.locate=locate;c.destroySpace=destroy;
    c.hands[0]=1;c.hands[1]=2;c.spaces[0]=reinterpret_cast<XrSpace>(uintptr_t(1));c.spaces[1]=reinterpret_cast<XrSpace>(uintptr_t(2));
}
static unsigned assertions=0;
static void require(bool ok,const char* what) { ++assertions;if(!ok)throw std::runtime_error(what); }
static void near(float a,float b,float epsilon,const char* what) { require(std::abs(a-b)<epsilon,what); }
static void near3(XrVector3f a,XrVector3f b,float epsilon,const char* what) { near(a.x,b.x,epsilon,what);near(a.y,b.y,epsilon,what);near(a.z,b.z,epsilon,what); }
static XrQuaternionf axis(float x,float y,float z,float angle) {
    const float n=std::sqrt(x*x+y*y+z*z),s=std::sin(angle*.5f)/n;return {x*s,y*s,z*s,std::cos(angle*.5f)};
}
static void matrixPose(const float* actual,XrPosef expected,const char* what) {
    float matrix[16];SharedBridge::matrix(expected,matrix);for(unsigned i=0;i<16;++i)near(actual[i],matrix[i],3e-6f,what);
}
static const float* transform(const wire::SharedHands& s,unsigned h) { return h?s.rightTransform:s.leftTransform; }
static void composeMatrices(const float* a,const float* b,float* out) {
    for(unsigned col=0;col<4;++col)for(unsigned row=0;row<4;++row) {
        float value=0;for(unsigned k=0;k<4;++k)value+=a[k*4+row]*b[col*4+k];out[col*4+row]=value;
    }
}
static XrVector3f velocity(const wire::SharedHands& s,unsigned h,bool spin) {
    // Packed SharedHands fields must be copied, never dereferenced as float*.
    XrVector3f out{};const size_t offset=spin?(h?offsetof(wire::SharedHands,rightAngularVelocity):offsetof(wire::SharedHands,leftAngularVelocity)):(h?offsetof(wire::SharedHands,rightVelocity):offsetof(wire::SharedHands,leftVelocity));
    std::memcpy(&out,reinterpret_cast<const char*>(&s)+offset,sizeof(out));return out;
}
static wire::SharedHands sampledOriginal() { NativeControllers c;configure(c);c.publishTouchRaw=false;return c.sample(XR_NULL_HANDLE,1'000'000'000); }
static wire::SharedHands sampledCandidate(bool enabled) { if(enabled)setenv("HALLIDAY_ALYX_TOUCH_RAW_POSE","1",1);else unsetenv("HALLIDAY_ALYX_TOUCH_RAW_POSE");NativeControllers c;configure(c);XrInstanceProperties runtime{XR_TYPE_INSTANCE_PROPERTIES};std::strcpy(runtime.runtimeName,"Halliday");runtime.runtimeVersion=XR_MAKE_VERSION(0,0,1);c.publishTouchRaw=tf::forRuntime(runtime,enabled?"1":"0");return c.sample(XR_NULL_HANDLE,1'000'000'000); }

int main(int argc,char** argv) {
    try {
        if(argc==3&&std::strcmp(argv[1],"--verify-launch")==0) {
            XrInstanceProperties runtime{XR_TYPE_INSTANCE_PROPERTIES};std::strcpy(runtime.runtimeName,"Halliday");runtime.runtimeVersion=XR_MAKE_VERSION(0,0,1);
            const bool raw=std::strcmp(argv[2],"raw")==0;
            const bool mode=tf::forRuntime(runtime,std::getenv("HALLIDAY_ALYX_TOUCH_RAW_POSE"));
            require(mode==raw,"Actual launch environment must reach negotiated runtime contract selector");
            XrPosef expected[2];
            for(unsigned h=0;h<2;++h) {
                expected[h]={axis(1,2,3,.5f+h*.3f),{h?.3f:-.3f,1.2f,-.4f}};
                poses[h]=tf::compose(expected[h],tf::rawToGripComponent(h));linear[h]={.2f,-.1f,.3f};angular[h]={.4f,.5f,-.6f};
            }
            NativeControllers adapter;adapter.init(XR_NULL_HANDLE,XR_NULL_HANDLE,mockGipa,mode);
            const auto output=adapter.sample(XR_NULL_HANDLE,1'000'000'000);
            for(unsigned h=0;h<2;++h)matrixPose(transform(output,h),raw?expected[h]:poses[h],"Actual init+sample honors real launch environment");
            std::printf("PASS actual NativeControllers.init+sample through launch environment: %s\n",raw?"raw":"legacy");return 0;
        }
        XrInstanceProperties runtime{XR_TYPE_INSTANCE_PROPERTIES};
        std::strcpy(runtime.runtimeName,"Halliday");runtime.runtimeVersion=XR_MAKE_VERSION(0,0,1);
        require(tf::forRuntime(runtime,nullptr),"Ordinary launch uses negotiated current Halliday identity");
        require(tf::forRuntime(runtime,"1"),"Explicit native Halliday launch opt-in");
        require(!tf::forRuntime(runtime,"0")&&!tf::forRuntime(runtime,"invalid"),"Explicit opt-out/unknown mode fails closed");
        for(const char* name:{"OtherRuntime","Halliday-extra","Halliday ","", "Unknown"}) {
            std::memset(runtime.runtimeName,0,sizeof(runtime.runtimeName));std::strcpy(runtime.runtimeName,name);
            require(!tf::forRuntime(runtime,"1")&&!tf::forRuntime(runtime,nullptr),"Unknown/legacy runtime name cannot opt in");
        }
        std::strcpy(runtime.runtimeName,"Halliday");runtime.runtimeVersion=XR_MAKE_VERSION(0,0,2);
        require(!tf::forRuntime(runtime,"1"),"Unverified new runtime version fails closed");
        runtime.runtimeVersion=0;require(!tf::forRuntime(runtime,nullptr),"Unverified old version fails closed");
        XrPosef raw[2];
        for(unsigned i=0;i<128;++i) {
            for(unsigned h=0;h<2;++h) {
                raw[h]={axis(.3f+.01f*i,.7f,-.2f+.05f*h,.07f*i+.3f*h),{h?.31f:-.27f,1.1f+.001f*i,-.43f}};
                // Independent reference construction: known raw origin plus its
                // documented model component generates the mock runtime GRIP.
                poses[h]=tf::compose(raw[h],tf::rawToGripComponent(h));linear[h]={.3f,-.2f,.4f};angular[h]={.5f,-.6f,.7f};
            }
            const auto before=sampledOriginal(),off=sampledCandidate(false),after=sampledCandidate(true);
            require(std::memcmp(&before,&off,sizeof(before))==0,"Opt-in off must preserve original adapter byte-for-byte");
            for(unsigned h=0;h<2;++h) {
                matrixPose(transform(before,h),poses[h],"Legacy mode forwards GRIP as raw");
                matrixPose(transform(after,h),raw[h],"Corrected mode must publish documented raw basis");
                // The guest's actual skeleton root is the ordinary Touch open-
                // hand wrist, not an inverse20.6 compensation. Compose that
                // exact local resource transform after the ACTUAL wire matrix.
                const XrPosef wrist{h?XrQuaternionf{-.078608f,.920279f,-.379296f,-.055147f}:XrQuaternionf{-.078608f,-.920279f,.379296f,-.055147f},
                    {h?.034038f:-.034038f,.036503f,.164722f}};
                float wristMatrix[16],worldWrist[16];SharedBridge::matrix(wrist,wristMatrix);
                composeMatrices(transform(after,h),wristMatrix,worldWrist);
                matrixPose(worldWrist,tf::compose(raw[h],wrist),"Guest Touch wrist root must follow corrected raw pose without extra compensation");
                const XrVector3f lever{raw[h].position.x-poses[h].position.x,raw[h].position.y-poses[h].position.y,raw[h].position.z-poses[h].position.z};
                near3(velocity(after,h,false),tf::add(linear[h],tf::cross(angular[h],lever)),3e-6f,"Raw-origin world velocity lever arm");
                near3(velocity(after,h,true),angular[h],1e-7f,"World angular velocity must remain unchanged");
            }
            require(before.leftButtons==after.leftButtons&&before.rightButtons==after.rightButtons&&before.leftTrigger==after.leftTrigger&&before.rightGrip==after.rightGrip,"Buttons and analog input must be unchanged");
        }
        for(unsigned h=0;h<2;++h) {
            const XrPosef grip{{0,0,0,1},{0,0,0}};XrSpaceVelocity v{XR_TYPE_SPACE_VELOCITY};auto rawPose=grip;tf::fromGrip(h,rawPose,v);
            near(rawPose.orientation.x,std::sin(-20.6f*3.14159265358979323846f/360),1e-7f,"Source-derived local angle, not guessed7degrees");
            near(rawPose.position.x,h?.007f:-.007f,1e-7f,"Mirrored raw Touch origin X");
            auto roundTrip=tf::compose(rawPose,tf::rawToGripComponent(h));matrixPose(([&]{static float m[16];SharedBridge::matrix(roundTrip,m);return m;})(),grip,"Raw/model component roundtrip");
        }
        // Independent finite-difference derivative of the rigid origin shift.
        const XrPosef grip{axis(1,2,-3,.7f),{.2f,1.1f,-.4f}};
        const XrVector3f w{.5f,-.6f,.7f},v{.3f,-.2f,.4f};constexpr float dt=.0005f;
        for(unsigned h=0;h<2;++h) {
            auto p=grip;XrSpaceVelocity m{XR_TYPE_SPACE_VELOCITY};m.velocityFlags=3;m.angularVelocity=w;m.linearVelocity=v;tf::fromGrip(h,p,m);
            auto displaced=[&](float t) {XrPosef g{tf::multiply(axis(w.x,w.y,w.z,std::sqrt(w.x*w.x+w.y*w.y+w.z*w.z)*t),grip.orientation),{grip.position.x+v.x*t,grip.position.y+v.y*t,grip.position.z+v.z*t}};return tf::compose(g,tf::inverse(tf::rawToGripComponent(h)));};
            const auto a=displaced(-dt),b=displaced(dt);near3(m.linearVelocity,{(b.position.x-a.position.x)/(2*dt),(b.position.y-a.position.y)/(2*dt),(b.position.z-a.position.z)/(2*dt)},.0002f,"World velocity must match moving raw-origin finite difference");
            auto unknown=grip;XrSpaceVelocity noAngular{XR_TYPE_SPACE_VELOCITY};noAngular.velocityFlags=XR_SPACE_VELOCITY_LINEAR_VALID_BIT;noAngular.linearVelocity=v;tf::fromGrip(h,unknown,noAngular);
            require(!(noAngular.velocityFlags&XR_SPACE_VELOCITY_LINEAR_VALID_BIT),"Cannot invent shifted-origin velocity without angular data");
        }
        std::printf("PASS actual legacy/corrected NativeControllers modes: %u assertions; full Touchraw pose, mirrored origins, world velocity,128both-hand orientations, opt-in-off byte equality. Raw/grip basis20.6deg; no anatomical calibration claim. No XR loader/device/GPU/game/preferences.\n",assertions);
        return 0;
    } catch(const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what());return 1; }
}
