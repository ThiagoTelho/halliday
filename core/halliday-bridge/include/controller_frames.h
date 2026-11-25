// Optional HLCF v1 orientation declaration. Independent implementation, MIT.
// Isolated candidate, not deployed; unknown/old/mouse declarations remain legacy.
#pragma once
#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>

namespace halliday::controller_frames {
constexpr size_t kOffset = 65480;
constexpr uint32_t kMagic = 0x46434c48, kVersion = 1;
enum class FrameKind : uint32_t { Legacy = 0, SenseAim = 1 };
enum class Target { OpenXrAim, OpenXrGrip, LegacyOpenVr };
using Kinds = std::array<FrameKind, 2>;
constexpr Kinds kLegacy{FrameKind::Legacy, FrameKind::Legacy};
struct Extension {
    uint32_t magic, version, bytes, hands;
    std::atomic<uint32_t> sequence, stateSequence;
    std::atomic<uint32_t> kinds[2];
};
static_assert(sizeof(Extension) == 32 && offsetof(Extension, sequence) == 16);
static_assert(offsetof(Extension, stateSequence) == 20 && offsetof(Extension, kinds) == 24);
static_assert(kOffset + sizeof(Extension) == 65512);

inline bool known(uint32_t kind) { return kind <= uint32_t(FrameKind::SenseAim); }
inline Extension* extension(void* mapping) {
    if (!mapping) return nullptr;
    auto* e = reinterpret_cast<Extension*>(static_cast<uint8_t*>(mapping) + kOffset);
    return e->magic == kMagic && e->version == kVersion && e->bytes == 32 && e->hands == 2 ? e : nullptr;
}
inline void initialize(void* mapping) {
    auto* e = new(static_cast<uint8_t*>(mapping) + kOffset) Extension{};
    e->version = kVersion; e->bytes = 32; e->hands = 2; e->magic = kMagic;
}
// The sole host writer must already own the matching odd outer state sequence.
inline bool write(void* mapping, const std::atomic<uint32_t>& outer,
                  uint32_t nextStateSequence, const Kinds& kinds) {
    auto* e = extension(mapping);
    if (!e || (nextStateSequence & 1) || outer.load(std::memory_order_acquire) != nextStateSequence - 1u)
        return false;
    for (auto kind : kinds) if (!known(uint32_t(kind))) return false;
    const uint32_t odd = e->sequence.load(std::memory_order_relaxed) | 1u;
    e->sequence.store(odd, std::memory_order_seq_cst);
    e->stateSequence.store(nextStateSequence, std::memory_order_relaxed);
    for (size_t hand = 0; hand < 2; ++hand) e->kinds[hand].store(uint32_t(kinds[hand]), std::memory_order_relaxed);
    uint32_t even = odd + 1u; if (!even) even = 2;
    e->sequence.store(even, std::memory_order_release);
    return true;
}
inline bool read(void* mapping, const std::atomic<uint32_t>& outer,
                 uint32_t expectedStateSequence, Kinds* out) {
    if (!out) return false;
    *out = kLegacy;
    auto* e = extension(mapping);
    if (!e || (expectedStateSequence & 1)) return false;
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        if (outer.load(std::memory_order_acquire) != expectedStateSequence) return false;
        const uint32_t before = e->sequence.load(std::memory_order_acquire);
        if (!before || (before & 1)) continue;
        const uint32_t identity = e->stateSequence.load(std::memory_order_relaxed);
        const uint32_t kinds[2]{e->kinds[0].load(std::memory_order_relaxed), e->kinds[1].load(std::memory_order_relaxed)};
        std::atomic_thread_fence(std::memory_order_acquire);
        if (before == e->sequence.load(std::memory_order_relaxed) && identity == expectedStateSequence &&
            outer.load(std::memory_order_relaxed) == expectedStateSequence) {
            if (!known(kinds[0]) || !known(kinds[1])) return false;
            *out = {FrameKind(kinds[0]), FrameKind(kinds[1])};
            return true;
        }
    }
    return false;
}
// q is XYZW, mapping local axes into the room. Right multiplication changes
// only the API's local orientation frame. No position/world velocity is read.
inline void orientation(FrameKind source, Target target, const float q[4], float out[4]) {
    const std::array<float, 4> original{q[0], q[1], q[2], q[3]};
    if (source != FrameKind::SenseAim || target != Target::OpenXrGrip) {
        std::memcpy(out, original.data(), sizeof(float) * 4); return;
    }
    // Source-derived Sense AIM -> OpenXR GRIP: Rx(+60 degrees).
    constexpr float s = 0.5f, c = 0.8660254f;
    out[0] = original[0] * c + original[3] * s;
    out[1] = original[1] * c + original[2] * s;
    out[2] = original[2] * c - original[1] * s;
    out[3] = original[3] * c - original[0] * s;
}
} // namespace halliday::controller_frames
