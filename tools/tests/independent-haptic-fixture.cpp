#include "haptic_bridge.hpp"
#include <unistd.h>
extern "C" uint64_t fixture_haptic_claim(void* base, uint64_t epoch) {
    auto* h = static_cast<halliday::Header*>(base);
    h->clientPid = static_cast<uint32_t>(getpid());
    h->initialized.store(1); h->heartbeat.fetch_add(1);
    return halliday::haptics::claim(h, h->clientPid, epoch);
}
extern "C" bool fixture_haptic_send(void* base, uint64_t epoch, uint32_t hand, uint64_t duration, float frequency, float amplitude) {
    auto* h = static_cast<halliday::Header*>(base);
    return halliday::haptics::send(h, h->clientPid, epoch, hand, duration, frequency, amplitude);
}
extern "C" void fixture_haptic_end(void* base, uint64_t epoch) {
    auto* h = static_cast<halliday::Header*>(base);
    halliday::haptics::release(h, h->clientPid, epoch);
}
