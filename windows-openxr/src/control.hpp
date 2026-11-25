// Derived from BasaltVR c104bc0b489384745157bc42e357f08d17e41638 (MIT).
// Copyright (c) 2026 BasaltVR contributors. See LICENSE-BasaltVR.
// Halliday shared-file transport used by the adapted Windows frontend.
#pragma once
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <openxr/openxr.h>
#include <cstdint>

namespace basalt {
void controlSessionCreated(XrSession session,ID3D11Device* device);
void controlSessionCreated12(XrSession session,ID3D12Device* device,ID3D12CommandQueue* queue);
void controlSessionDestroyed(XrSession session);
void controlSessionEnded(XrSession session);
bool controlActive(XrSession session);
bool controlHostAvailable();
void controlCloseIdleMapping();
bool controlRenderingAllowed(XrSession session);
struct ControlLifecycleSnapshot {
    bool active = false;
    bool renderingAllowed = false;
    bool exitRequested = false;
    uint32_t spaceEpoch = 0;
};
// Nonblocking host status/quit consumption, for event-only application loops.
ControlLifecycleSnapshot controlLifecycleSnapshot(XrSession session);
bool controlConfiguredViewSize(uint32_t* width,uint32_t* height);
bool controlWaitForFrameBudget(XrSession session);
void controlNotePredictedDisplayTime(XrSession session,XrTime time);
XrDuration controlDisplayPeriod(XrSession session);
bool controlHeadPose(XrSession session,XrTime time,uint64_t* stamp,XrPosef* pose);
bool controlHeadMotion(XrSession session,XrTime time,XrVector3f* linear,XrVector3f* angular,uint32_t* flags=nullptr);
bool controlViewConfig(XrSession session,float* ipd,XrFovf fov[2]);

enum class ControlHand : uint32_t { kLeft = 0,kRight = 1 };
constexpr uint32_t kControlButtonCapacity = 64;
struct ControlControllerState {
    bool poseActive,profileActive;
    // Legacy upstream field names: these now carry Halliday sample stamps.
    uint64_t questTimestampNanoseconds,profileId;
    XrPosef poseInLocal;
    XrPosef aimPoseInLocal;
    XrVector3f linearVelocity,angularVelocity;
    uint32_t motionFlags;
    float triggerValue; // measured pressure, independent of the digital click
};
struct ControlButtonState {
    uint64_t pathId;
    uint32_t valueType;
    float value;
    XrTime lastChangeTime;
};
inline bool controlButtonPressed(uint32_t type,float value) {
    return type == 0 ? value != 0 : value >= .5f;
}
struct ControlInputSnapshot {
    ControlControllerState controllers[2];
    uint32_t buttonCount;
    ControlButtonState buttons[kControlButtonCapacity];
};
// Fresh state is read under shared mapping/session lifetime admission; GPU
// capture never owns the input-cache mutex and cannot stall this snapshot.
bool controlInputSnapshot(XrSession session,ControlInputSnapshot* output,XrTime time = 0);
bool controlSendHaptic(XrSession session,ControlHand hand,uint64_t duration,float frequency,float amplitude);
struct ControlFrameView {
    uint64_t swapchainId;
    uint32_t imageIndex,imageArrayIndex;
    XrRect2Di rect;
    // Pose is transformed from the layer's reference space into Halliday space.
    XrPosef pose;
    XrFovf fov;
};
struct ControlFrameQuad {
    ControlFrameView image;
    XrPosef pose; // VIEW-local if headLocked, otherwise Halliday floor coordinates.
    XrExtent2Df size;
    XrEyeVisibility eyeVisibility;
    XrCompositionLayerFlags layerFlags;
    uint32_t order;
    bool headLocked;
};
ID3D11Texture2D* retainSwapchainTexture(const ControlFrameView& view);
ID3D12Resource* retainSwapchainTexture12(const ControlFrameView& view);
uint32_t swapchainColourSpace(const ControlFrameView& view);
XrResult controlFrameReady(int64_t displayTime,uint64_t stamp,const ControlFrameView* views,uint32_t count,
    const ControlFrameQuad* quads=nullptr,uint32_t quadCount=0,
    uint32_t projectionOrder=0,uint32_t projectionFlags=0,uint32_t frameSpaceEpoch=UINT32_MAX);
bool spacePoseInLocal(XrSession session,XrSpace space,XrTime time,XrPosef* pose);
bool spacePanelOrigin(XrSession session,XrSpace space,XrTime time,XrPosef* pose,bool* headLocked);
// Natural reference-space origin in the bridge's floor-aligned coordinates.
// LOCAL is measured once from the initial head; LOCAL_FLOOR shares its XZ/yaw.
bool controlReferenceOrigin(XrSession session,XrReferenceSpaceType type,XrPosef* pose,XrTime time = 0);
} // namespace basalt
