// Public Halliday v6 reserved-header haptic extension. MIT.
// Independent producers share the host's clock; no Windows/Unix clock conversion.
#pragma once
#include "bridge_layout.hpp"
#include "focus_bridge.hpp"
#include <cmath>

namespace halliday::haptics {
constexpr size_t kOffset = 61440;
constexpr uint32_t kMagic = 0x50484c48; // HLHP, little endian
constexpr uint32_t kVersion = 1;
struct Mailbox {
    std::atomic<uint32_t> seq, amplitudeBits, frequencyBits;
    uint32_t pad;
    std::atomic<uint64_t> durationNs, issuedHostClock, epoch;
};
struct Extension {
    uint32_t magic, version;
    std::atomic<uint64_t> clockNs, clientEpoch;
    std::atomic<uint32_t> ownerPid;
    std::atomic<uint32_t> spaceEpoch;
    Mailbox hands[2];
};
static_assert(sizeof(Mailbox) == 40 && sizeof(Extension) == 112);
static_assert(offsetof(Extension, clockNs) == 8 && offsetof(Extension, clientEpoch) == 16);
static_assert(offsetof(Extension, ownerPid) == 24 && offsetof(Extension, hands) == 32);
static_assert(offsetof(Mailbox, durationNs) == 16 && offsetof(Mailbox, issuedHostClock) == 24 && offsetof(Mailbox, epoch) == 32);
static_assert(kOffset + sizeof(Extension) <= kHeaderBytes);

inline Extension* extension(Header* header) {
    if (!header) return nullptr;
    auto* ext = reinterpret_cast<Extension*>(reinterpret_cast<uint8_t*>(header) + kOffset);
    return ext->magic == kMagic && ext->version == kVersion ? ext : nullptr;
}

inline uint64_t claim(Header* header, uint32_t pid, uint64_t epoch) {
    auto* ext = extension(header);
    if (!ext || !pid || !epoch || header->clientPid != pid || !header->initialized.load() ||
        !header->alive.load() || !ext->clockNs.load(std::memory_order_acquire)) return 0;
    ext->clientEpoch.store(0, std::memory_order_release);
    ext->ownerPid.store(pid, std::memory_order_release);
    // The single owned producer has changed. Recover an interrupted odd write
    // without replaying its contents under the new generation.
    for (auto& mailbox : ext->hands) mailbox.seq.store(0, std::memory_order_release);
    ext->clientEpoch.store(epoch, std::memory_order_release);
    focus::claim(header,epoch);
    return epoch;
}

inline void release(Header* header, uint32_t pid, uint64_t epoch) {
    auto* ext = extension(header);
    if (!ext || !epoch || ext->ownerPid.load(std::memory_order_acquire) != pid) return;
    ext->clientEpoch.compare_exchange_strong(epoch, 0, std::memory_order_acq_rel);
}

inline bool send(Header* header, uint32_t pid, uint64_t epoch, uint32_t hand,
                 uint64_t durationNs, float frequency, float amplitude) {
    auto* ext = extension(header);
    auto* focus = halliday::focus::extension(header);
    const uint32_t focusGeneration = halliday::focus::generation(focus);
    const bool stopping = durationNs == 0 || amplitude == 0;
    if (!ext || !epoch || hand > 1 || !std::isfinite(frequency) || frequency < 0 ||
        !std::isfinite(amplitude) || amplitude < 0 || amplitude > 1 ||
        !header->alive.load() || (!stopping && (header->dashboard.load() || halliday::focus::shown(focus))) || !header->initialized.load() ||
        header->clientPid != pid || ext->ownerPid.load(std::memory_order_acquire) != pid ||
        ext->clientEpoch.load(std::memory_order_acquire) != epoch) return false;
    const uint64_t now = ext->clockNs.load(std::memory_order_acquire);
    if (!now) return false;
    auto& mailbox = ext->hands[hand];
    uint32_t seq = mailbox.seq.load(std::memory_order_acquire);
    bool acquired = false;
    for (unsigned attempt = 0; attempt < 32; ++attempt) {
        if (!(seq & 1) && mailbox.seq.compare_exchange_weak(seq, seq + 1, std::memory_order_acq_rel)) {
            acquired = true; break;
        }
        seq = mailbox.seq.load(std::memory_order_acquire);
    }
    if (!acquired) return false;
    uint32_t ampBits = 0, freqBits = 0;
    std::memcpy(&ampBits, &amplitude, sizeof(ampBits));
    std::memcpy(&freqBits, &frequency, sizeof(freqBits));
    mailbox.amplitudeBits.store(ampBits, std::memory_order_relaxed);
    mailbox.frequencyBits.store(freqBits, std::memory_order_relaxed);
    mailbox.durationNs.store(durationNs, std::memory_order_relaxed);
    mailbox.issuedHostClock.store(now, std::memory_order_relaxed);
    mailbox.epoch.store(epoch, std::memory_order_relaxed);
    halliday::focus::tag(focus,epoch,hand,seq+2,focusGeneration);
    mailbox.seq.store(seq + 2, std::memory_order_release);
    return true;
}
} // namespace halliday::haptics
