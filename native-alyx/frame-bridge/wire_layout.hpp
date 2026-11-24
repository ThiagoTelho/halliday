// Copyright (c) 2026 Ag3497120. SPDX-License-Identifier: MIT
// VeRantyx 0.3.2 shared-memory ABI only; no OpenVR runtime implementation.
#pragma once
#include <cstddef>
#include <cstdint>

namespace wire {
#pragma pack(push, 1)
struct alignas(8) SharedFrame {
    uint32_t sequenceNumber;
    uint32_t width;          // both eyes side by side
    uint32_t height;
    uint32_t format;         // DXGI code: 28 = RGBA8, 87 = BGRA8
    float renderHeadTransform[16];
    double visionTimestamp;
};
struct alignas(8) SharedHands {
    float headTransform[16];
    float leftTransform[16];
    float rightTransform[16];
    uint8_t leftTracked;
    uint8_t rightTracked;
    uint8_t leftTrigger;
    uint8_t rightTrigger;
    uint32_t rightButtons;
    uint32_t leftButtons;
    float rightStickX;
    float rightStickY;
    float leftStickX;
    float leftStickY;
    float rightVelocity[3];
    float leftVelocity[3];
    double visionTimestamp;
    float leftTangents[4];
    float rightTangents[4];
    uint8_t leftGrip;
    uint8_t rightGrip;
    uint8_t headTracked;
    float leftAngularVelocity[3];
    float rightAngularVelocity[3];
    uint8_t velocityValid;
};
#pragma pack(pop)
struct DoubleBufferHeader {
    volatile int32_t latestReadyIndex;
    volatile int32_t pendingTextureHandle;
    volatile int32_t captureRequestSequence;
    volatile int32_t captureAckSequence;
    volatile int32_t captureSourceMode;
    volatile int32_t poseSequence;
    uint32_t padding[10];
};
static_assert(sizeof(SharedFrame) == 88, "SharedFrame layout");
static_assert(alignof(SharedFrame) == 8, "frame sequence is naturally aligned in both shared slots");
static_assert(sizeof(SharedHands) == 312, "SharedHands layout");
static_assert(alignof(SharedHands) == 8, "shared pose matrices have aligned float elements");
static_assert(offsetof(SharedHands, visionTimestamp) == 244 && offsetof(SharedHands, leftTangents) == 252 &&
              offsetof(SharedHands, leftAngularVelocity) == 287 && offsetof(SharedHands, velocityValid) == 311, "MacEncoder pose offsets");
static_assert(sizeof(DoubleBufferHeader) == 64, "DoubleBufferHeader layout");
constexpr size_t kMaxPixelBytes = 4096ull * 4096ull * 8ull;
constexpr size_t kFrameBlockSize = sizeof(SharedFrame) + kMaxPixelBytes;
constexpr size_t kHandsOffset = sizeof(DoubleBufferHeader) + kFrameBlockSize * 2;
struct FrameProjection { uint32_t sequence; float tangents[8]; };
constexpr size_t kProjectionOffset = kHandsOffset + sizeof(SharedHands);
constexpr size_t kSharedMapSize = kHandsOffset + sizeof(SharedHands) + 1024;
// MoltenVR retains the existing projection ABI at +312..383.
// Optional upstream metadata follows it instead of overlapping those matrices.
struct SharedExtras { uint32_t ipdMagic; float ipdMeters; };
struct SharedHaptic { uint32_t sequence; float durationSeconds, frequency, amplitude; };
constexpr size_t kExtrasOffset = kHandsOffset + 384;
constexpr size_t kHapticsOffset = kHandsOffset + 400;
static_assert(kProjectionOffset + 2*sizeof(FrameProjection) <= kExtrasOffset, "projection metadata must not overlap optional IPD or haptics");
constexpr uint32_t kIpdMagic = 0x44504956; // "VIPD"
static_assert(sizeof(SharedHaptic) == 16 && kHapticsOffset + 2 * sizeof(SharedHaptic) <= kSharedMapSize, "ALVR tail layout");

// Button bits in SharedHands::{left,right}Buttons (left ones shifted by 8).
enum : uint32_t { kBtnPrimary = 1, kBtnSecondary = 2, kBtnStickClick = 4, kBtnStickTouch = 8, kBtnMenu = 16, kBtnTriggerTouch = 32, kBtnPrimaryTouch = 64, kBtnSecondaryTouch = 128, kBtnThumbrestTouch = 256 };

} // namespace wire
