// Halliday shared-file ABI v6. Derived from core/halliday-bridge/src/lib.rs (MIT).
// Only the prefix used by this producer is declared; image offsets remain the
// Rust protocol's fixed offsets, independent of this declaration's size.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace halliday {
constexpr uint32_t kMagic = 0x52424c48;
constexpr uint32_t kVersion = 6;
constexpr size_t kSlots = 3;
constexpr size_t kHeaderBytes = 64 * 1024;
constexpr size_t kEyeBytes = 2560 * 2560 * 4;
constexpr uint32_t kColorLegacy = 0, kColorLinear = 1, kColorSrgb = 2;
constexpr uint32_t kFrameProjectionGeometry = 1u << 16;
constexpr uint32_t kFrameLayerBatch = 1u << 17;
constexpr uint32_t frameTextureMetadata(uint32_t api, uint32_t left, uint32_t right) {
    return (api & 0xff) | ((left & 3) << 8) | ((right & 3) << 10);
}
constexpr uint32_t frameColorSpace(uint32_t metadata, size_t eye) {
    if (eye > 1) return kColorLegacy;
    const auto value = (metadata >> (8 + eye * 2)) & 3;
    return value <= kColorSrgb ? value : kColorLegacy;
}
constexpr size_t kFileBytes = kHeaderBytes + kSlots * 2 * kEyeBytes +
    8 * 2048 * 2048 * 4 + 2048 * 2048 * 4;

struct Pose {
    float position[3]; uint32_t valid;
    float orientation[4];
    float velocity[3]; float pad;
    float angularVelocity[3]; float stamp;
};
struct Controller {
    Pose pose;
    uint64_t pressed, touched;
    float axes[5][2];
    uint32_t connected, packet;
};
struct State { Pose head; Controller controllers[2]; };
struct Frame {
    std::atomic<uint32_t> seq;
    uint32_t width, height, bottomUp;
    float bounds[2][4];
    Pose pose;
    uint64_t frameIndex;
    uint32_t textureType, shared, bgra, seeThrough;
};
struct Header {
    uint32_t magic, version, eyeWidth, eyeHeight;
    float displayHz, ipd, tangents[2][4];
    std::atomic<uint32_t> alive, stateSeq;
    std::atomic<uint64_t> vsync;
    State state;
    std::atomic<uint64_t> clientFrames, clientCalls;
    uint32_t clientPid;
    std::atomic<uint32_t> latest, reading;
    uint32_t pad;
    char appName[64];
    Frame frames[kSlots];
    std::atomic<uint64_t> intervalNs, lateVsyncs;
    std::atomic<uint32_t> quitRequests, dashboard;
    std::atomic<uint64_t> heartbeat;
    std::atomic<uint32_t> initialized, quitAcknowledged, sceneSeq;
    uint32_t pad2;
};

static_assert(sizeof(Pose) == 64 && sizeof(Controller) == 128);
static_assert(sizeof(State) == 320 && sizeof(Frame) == 136);
static_assert(offsetof(Header, state) == 72);
static_assert(offsetof(Header, clientFrames) == 392);
static_assert(offsetof(Header, frames) == 488);
static_assert(offsetof(Header, intervalNs) == 896);
static_assert(offsetof(Header, heartbeat) == 920);
static_assert(offsetof(Header, sceneSeq) == 936);
static_assert(sizeof(Header) == 944);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
static_assert(std::atomic<uint64_t>::is_always_lock_free);

inline bool fits(uint32_t width, uint32_t height) {
    return width > 0 && height > 0 && width <= 4096 && height <= 4096 &&
        uint64_t(width) * height * 4 <= kEyeBytes;
}
inline size_t imageOffset(size_t slot, size_t eye) {
    return kHeaderBytes + (slot * 2 + eye) * kEyeBytes;
}
inline bool readState(const Header* header, State* state) {
    for (unsigned retry = 0; retry < 64; ++retry) {
        const uint32_t before = header->stateSeq.load(std::memory_order_acquire);
        if (before & 1) continue;
        // Match the Rust peer's volatile copy, validated by its sequence lock.
        auto* destination = reinterpret_cast<unsigned char*>(state);
        auto* source = reinterpret_cast<const volatile unsigned char*>(&header->state);
        for (size_t i = 0; i < sizeof(State); ++i) destination[i] = source[i];
        std::atomic_thread_fence(std::memory_order_acquire);
        if (before == header->stateSeq.load(std::memory_order_relaxed)) return true;
    }
    return false;
}
inline size_t freeSlot(const Header* header) {
    const uint32_t latest = header->latest.load();
    const uint32_t reading = header->reading.load();
    for (size_t slot = 0; slot < kSlots; ++slot)
        if (slot + 1 != latest && slot + 1 != reading) return slot;
    return kSlots;
}
// On any fill failure the incomplete slot stays unpublished. The next write
// can safely reuse it, while the previous complete frame remains available.
struct BeforePublish {
    bool operator()(size_t, uint64_t) const { return true; }
};
template <typename Fill, typename Before = BeforePublish>
bool publish(Header* header, uint32_t width, uint32_t height, bool bgra,
             const Pose& pose, uint64_t frameIndex, Fill&& fill, uint32_t textureMetadata = 0,
             Before&& before = Before{}) {
    if (!fits(width, height)) return false;
    const size_t slot = freeSlot(header);
    if (slot == kSlots) return false;
    Frame& frame = header->frames[slot];
    frame.seq.fetch_or(1);
    auto* base = reinterpret_cast<unsigned char*>(header);
    for (size_t eye = 0; eye < 2; ++eye)
        if (!fill(eye, base + imageOffset(slot, eye))) return false;
    frame.width = width; frame.height = height; frame.bottomUp = 0;
    for (auto& bounds : frame.bounds) {
        bounds[0] = bounds[1] = 0; bounds[2] = bounds[3] = 1;
    }
    frame.pose = pose; frame.frameIndex = frameIndex;
    frame.textureType = textureMetadata; frame.shared = 0;
    frame.bgra = bgra ? 1 : 0; frame.seeThrough = 0;
    // Optional metadata is committed to this exact slot before the frame can be observed.
    if (!before(slot, frameIndex)) return false;
    frame.seq.store((frame.seq.load() | 1) + 1);
    header->latest.store(static_cast<uint32_t>(slot + 1));
    header->clientFrames.fetch_add(1);
    header->clientCalls.fetch_add(1, std::memory_order_relaxed);
    return true;
}
} // namespace halliday
