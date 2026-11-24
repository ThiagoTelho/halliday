// Clean-room coordinate composition from the public Touch render-model frame.
// Numeric contract/provenance: adjacent SOURCE.json. No OpenComposite code.
#pragma once
#include <openxr/openxr.h>
#include <cmath>
#include <cstring>

namespace halliday::alyx::touch_raw {
// The existing frame bridge already queried these properties from the selected
// negotiated runtime. Never infer this capability from a library filename.
inline bool forRuntime(const XrInstanceProperties& runtime,const char* requested) {
    return std::memcmp(runtime.runtimeName,"Halliday",sizeof("Halliday"))==0
        && runtime.runtimeVersion==XR_MAKE_VERSION(0,0,1)
        && (!requested || std::strcmp(requested,"1")==0);
}
inline XrQuaternionf multiply(XrQuaternionf a, XrQuaternionf b) {
    return {a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,
            a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
            a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w,
            a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z};
}
inline XrVector3f add(XrVector3f a, XrVector3f b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
inline XrVector3f cross(XrVector3f a, XrVector3f b) {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};
}
inline XrVector3f rotate(XrQuaternionf q, XrVector3f v) {
    const auto p=multiply(multiply(q,{v.x,v.y,v.z,0}),{-q.x,-q.y,-q.z,q.w});
    return {p.x,p.y,p.z};
}
inline XrPosef rawToGripComponent(unsigned hand) {
    constexpr float halfAngle=20.6f*3.14159265358979323846f/360.f;
    return {{std::sin(halfAngle),0,0,std::cos(halfAngle)},
            {hand==0?0.007f:-0.007f,-0.00182941f,0.1019482f}};
}
inline XrPosef compose(XrPosef parent, XrPosef child) {
    return {multiply(parent.orientation,child.orientation),
            add(parent.position,rotate(parent.orientation,child.position))};
}
inline XrPosef inverse(XrPosef pose) {
    const XrQuaternionf rotation{-pose.orientation.x,-pose.orientation.y,-pose.orientation.z,pose.orientation.w};
    return {rotation,rotate(rotation,{-pose.position.x,-pose.position.y,-pose.position.z})};
}
// Raw is the advertised Touch device frame. OpenXR GRIP remains unchanged at
// the runtime; only this OpenVR guest boundary composes its inverse component.
inline void fromGrip(unsigned hand, XrPosef& pose, XrSpaceVelocity& motion) {
    const auto before=pose;
    pose=compose(before,inverse(rawToGripComponent(hand)));
    if (motion.velocityFlags & XR_SPACE_VELOCITY_LINEAR_VALID_BIT) {
        if (motion.velocityFlags & XR_SPACE_VELOCITY_ANGULAR_VALID_BIT) {
            const XrVector3f lever{pose.position.x-before.position.x,
                                  pose.position.y-before.position.y,
                                  pose.position.z-before.position.z};
            motion.linearVelocity=add(motion.linearVelocity,cross(motion.angularVelocity,lever));
        } else {
            // Velocity at another origin needs angular motion. The existing
            // caller may derive raw-origin finite differences on a later sample.
            motion.velocityFlags &= ~XR_SPACE_VELOCITY_LINEAR_VALID_BIT;
        }
    }
}
} // namespace halliday::alyx::touch_raw
