// Optional HLFT timing travels with one exact reserved v6 image, never its import receipt.
#pragma once
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include "../../core/halliday-bridge/include/frame_timing.h"

namespace halliday::source_timing {
// Called only inside the pixel transport's BeforePublish transaction. Invalid
// or absent timing is optional: clear its per-frame flag and keep valid colour.
inline bool publish(Header* header, size_t slot, uint64_t frameIndex, uint64_t epoch,
                    int64_t nanoseconds, uint32_t clockKind) {
    if (!header || slot >= kSlots) return false;
    const auto* owner = haptics::extension(header);
    auto& frame = header->frames[slot];
    if (!owner || !epoch || !frameIndex || owner->clientEpoch.load() != epoch ||
        owner->ownerPid.load() != header->clientPid || header->initialized.load() != 1 ||
        header->reading.load() == slot + 1 || header->latest.load() == slot + 1 ||
        !(frame.seq.load() & 1) || frame.frameIndex != frameIndex) return false;
    frame.textureType &= ~frame_timing::kFrameSourceTiming;
    if (!frame_timing::write(header, slot, epoch, frameIndex, nanoseconds, clockKind)) return false;
    if (owner->clientEpoch.load() != epoch || header->initialized.load() != 1) {
        frame_timing::clear(header, slot); return false;
    }
    frame.textureType |= frame_timing::kFrameSourceTiming;
    return true;
}
inline bool read(Header* header, size_t slot, uint64_t frameIndex, uint64_t epoch,
                 frame_timing::Snapshot* snapshot) {
    if (snapshot) *snapshot = {};
    return header && slot < kSlots &&
        (header->frames[slot].textureType & frame_timing::kFrameSourceTiming) &&
        frame_timing::read(header, slot, epoch, frameIndex, snapshot);
}
} // namespace halliday::source_timing
