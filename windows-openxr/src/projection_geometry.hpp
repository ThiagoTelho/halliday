// Own public-API geometry conversion. Pixels are already canonicalized for
// legal reversed OpenXR FOV bounds by the .14 readback path.
#pragma once
#include "projection_bridge.hpp"
#include "pose_math.hpp"
#include <algorithm>
#include <cmath>

namespace halliday::projection {
inline View fromSubmitted(const XrPosef& world,const XrFovf& fov) {
    return {{world.position.x,world.position.y,world.position.z},
            {world.orientation.x,world.orientation.y,world.orientation.z,world.orientation.w},
            {std::tan(std::min(fov.angleLeft,fov.angleRight)),std::tan(std::max(fov.angleLeft,fov.angleRight)),
             std::tan(std::max(fov.angleUp,fov.angleDown)),std::tan(std::min(fov.angleUp,fov.angleDown))}};
}
inline bool closeFloat(float a,float b) {return std::fabs(a-b)<=1e-5f*std::max({1.0f,std::fabs(a),std::fabs(b)});}
inline bool legacyCompatible(const Header* header,const View views[2],const Pose& head) {
    XrPosef centre{{head.orientation[0],head.orientation[1],head.orientation[2],head.orientation[3]},
                  {head.position[0],head.position[1],head.position[2]}};
    for(unsigned eye=0;eye<2;++eye) {
        auto offset=basalt::identityPose();offset.position.x=(eye?.5f:-.5f)*header->ipd;
        const auto expected=basalt::poseCompose(centre,offset);
        const float p[]{expected.position.x,expected.position.y,expected.position.z};
        const float q[]{expected.orientation.x,expected.orientation.y,expected.orientation.z,expected.orientation.w};
        bool same=true,opposite=true;
        for(unsigned k=0;k<3;++k)if(!closeFloat(views[eye].position[k],p[k]))return false;
        for(unsigned k=0;k<4;++k) {
            same=same&&closeFloat(views[eye].orientation[k],q[k]);
            opposite=opposite&&closeFloat(views[eye].orientation[k],-q[k]);
            if(!closeFloat(views[eye].tangents[k],header->tangents[eye][k]))return false;
        }
        if(!same&&!opposite)return false;
    }
    return true;
}
}
