#include "pose_math.hpp"
#include <cmath>
#include <initializer_list>
#include <cstdio>
#include <stdexcept>

namespace {
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
bool near(float a, float b) { return std::abs(a - b) < 0.00002f; }
bool near(const XrVector3f& a, const XrVector3f& b) {
    return near(a.x, b.x) && near(a.y, b.y) && near(a.z, b.z);
}
XrQuaternionf rotation(float x, float y, float z, float angle) {
    const float length = std::sqrt(x * x + y * y + z * z);
    const float scale = std::sin(angle * .5f) / length;
    return {x * scale, y * scale, z * scale, std::cos(angle * .5f)};
}
// Independent matrix form provides a control for the quaternion-vector helper.
XrVector3f matrixRotate(const XrQuaternionf& q, const XrVector3f& v) {
    return {
        (1 - 2 * q.y * q.y - 2 * q.z * q.z) * v.x +
            (2 * q.x * q.y - 2 * q.z * q.w) * v.y +
            (2 * q.x * q.z + 2 * q.y * q.w) * v.z,
        (2 * q.x * q.y + 2 * q.z * q.w) * v.x +
            (1 - 2 * q.x * q.x - 2 * q.z * q.z) * v.y +
            (2 * q.y * q.z - 2 * q.x * q.w) * v.z,
        (2 * q.x * q.z - 2 * q.y * q.w) * v.x +
            (2 * q.y * q.z + 2 * q.x * q.w) * v.y +
            (1 - 2 * q.x * q.x - 2 * q.y * q.y) * v.z,
    };
}
}

int main() {
    try {
        const auto quarter = rotation(0, 1, 0, 1.57079632679f);
        check(near(basalt::quaternionRotate(quarter, {0, 0, -1}), {-1, 0, 0}),
              "OpenXR forward/yaw convention changed");
        for (int hand : {-1, 1}) for (int index = 0; index < 64; ++index) {
            const auto q = rotation(1 + index % 3, -2, hand * .7f, index * .103f);
            const XrPosef tracked{q, {hand * .3f, 1.2f, -.45f}};
            const XrPosef local{rotation(1, 0, 0, -.2f), {hand * .012f, -.03f, .04f}};
            const auto combined = basalt::poseCompose(tracked, local);
            const auto rotated = matrixRotate(q, local.position);
            const XrVector3f expected{tracked.position.x + rotated.x,
                                     tracked.position.y + rotated.y,
                                     tracked.position.z + rotated.z};
            check(near(combined.position, expected), "local offset was not rotated exactly once");
            const auto recovered = basalt::poseCompose(basalt::poseInvert(tracked), combined);
            check(near(recovered.position, local.position), "inverse lost a controller-local origin");
            const XrVector3f forward{0, 0, -1};
            check(near(basalt::quaternionRotate(recovered.orientation, forward),
                       matrixRotate(local.orientation, forward)), "inverse changed local orientation");
            const XrQuaternionf opposite{-q.x, -q.y, -q.z, -q.w};
            check(near(basalt::quaternionRotate(q, forward),
                       basalt::quaternionRotate(opposite, forward)), "quaternion sign changed a pose");
        }
        std::puts("PASS: OpenXR axes, both hands, rotated local offsets, inverse transforms and quaternion signs");
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what()); return 1;
    }
}
