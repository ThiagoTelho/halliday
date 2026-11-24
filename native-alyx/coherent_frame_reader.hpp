#pragma once
#include <cstddef>
#include <cstdint>
#include <vector>

namespace halliday::alyx {

enum class ReadResult : unsigned {
    unavailable, empty, duplicate, stale, invalid, overwritten,
    accepted_current, accepted_superseded, rejected_superseded
};
struct ReadAudit {
    ReadResult result = ReadResult::unavailable;
    unsigned attempts = 0, overwrittenAttempts = 0;
    uint32_t candidateSequence = 0, sequenceAfter = 0;
    uint32_t slotBefore = 0, slotAfter = 0;
};

// The producer invalidates a reused slot's sequence before writing any pixels,
// then release-publishes a new, nonzero sequence after pixels and metadata. The
// copied slot's unchanged sequence proves coherence. A newer *other* slot does
// not invalidate an already coherent copy. No reader ownership ABI is added.
//
// Access supplies acquire reads of mode/latest/sequence, ordinary copies of
// frame/pixels/projection, and an acquire fence after those copies. A failed
// attempt never changes the caller's previously accepted frame or pixels.
template<class Frame, class Projection, class Access>
bool readCoherentFrame(Access& source, uint32_t previousSequence,
                       Frame& frame, Projection& projection,
                       std::vector<uint8_t>& pixels,
                       std::vector<uint8_t>& scratch, size_t maximumBytes,
                       ReadAudit* audit = nullptr) {
    ReadAudit local;
    for (unsigned attempt = 0; attempt != 2; ++attempt) {
        local.attempts = attempt + 1;
        if (source.mode() != 2) {
            local.result = ReadResult::unavailable;
            break;
        }
        const auto slot = source.latest() & 1u;
        local.slotBefore = slot;
        const uint32_t initial = source.sequence(slot);
        local.candidateSequence = initial;
        if (!initial || initial == previousSequence) {
            local.result = initial ? ReadResult::duplicate : ReadResult::empty;
            break;
        }
        // Match the original !=serial admission. This ABI has no producer
        // generation, so a lower serial might be a legitimate producer reset.
        Frame candidate{};
        source.copyFrame(slot, candidate);
        if (candidate.sequenceNumber != initial) {
            ++local.overwrittenAttempts;
            local.result = ReadResult::overwritten;
            continue;
        }
        if (!candidate.width || candidate.width % 2 || !candidate.height ||
            (candidate.format != 28 && candidate.format != 87) ||
            size_t(candidate.width) > maximumBytes / 4 / candidate.height) {
            local.result = ReadResult::invalid;
            break;
        }
        const size_t bytes = size_t(candidate.width) * candidate.height * 4;
        scratch.resize(bytes);
        source.copyPixels(slot, scratch.data(), bytes);
        Projection candidateProjection{};
        source.copyProjection(slot, candidateProjection);
        source.acquireFence();
        local.sequenceAfter = source.sequence(slot);
        local.slotAfter = source.latest() & 1u;
        if (local.sequenceAfter != initial) {
            ++local.overwrittenAttempts;
            local.result = ReadResult::overwritten;
            continue;
        }
        // Metadata shares the producer's invalidate/publish transaction.
        pixels.swap(scratch);
        frame = candidate;
        projection = candidateProjection;
        local.result = slot == local.slotAfter ? ReadResult::accepted_current
                                               : ReadResult::accepted_superseded;
        if (audit) *audit = local;
        return true;
    }
    if (audit) *audit = local;
    return false;
}
} // namespace halliday::alyx
