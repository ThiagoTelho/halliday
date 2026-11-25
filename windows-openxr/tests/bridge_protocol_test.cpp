#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include <sys/mman.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

static void require(bool success, const char* message) {
    if (!success) { std::fprintf(stderr,"FAIL: %s\n",message); std::exit(1); }
}
int main() {
    auto* memory = mmap(nullptr,halliday::kFileBytes,PROT_READ|PROT_WRITE,
        MAP_PRIVATE|MAP_ANON,-1,0);
    require(memory != MAP_FAILED,"allocate sparse test mapping");
    auto* header = new (memory) halliday::Header{};
    header->magic = halliday::kMagic; header->version = halliday::kVersion;
    halliday::State input{}; input.head.valid = 1; input.head.position[1] = 1.7f;
    input.head.orientation[3] = 1; input.head.stamp = 42;
    header->stateSeq.store(1); header->state = input; header->stateSeq.store(2);
    halliday::State output{};
    require(halliday::readState(header,&output),"read stable pose snapshot");
    require(std::memcmp(&input,&output,sizeof(input)) == 0,"pose snapshot preserves all fields");
    header->stateSeq.store(3);
    require(!halliday::readState(header,&output),"reject an in-progress pose snapshot");
    header->stateSeq.store(4);
    require(!halliday::fits(4096,4096) && halliday::fits(2560,2560),"enforce eye slot bounds");
    const auto fill = [](size_t eye,uint8_t* out) { std::memset(out,eye ? 0x22 : 0x11,16*8*4); return true; };
    require(halliday::publish(header,16,8,true,input.head,1,fill),"publish stereo frame");
    const uint32_t first = header->latest.load();
    require(first != 0 && header->clientFrames.load() == 1,"publish frame index atomically");
    const auto& frame = header->frames[first - 1];
    require(!(frame.seq.load() & 1) && frame.width == 16 && frame.height == 8 && frame.pose.stamp == 42,
        "publish complete image metadata with original pose stamp");
    auto* bytes = static_cast<unsigned char*>(memory);
    require(bytes[halliday::imageOffset(first - 1,0)] == 0x11 &&
            bytes[halliday::imageOffset(first - 1,1)] == 0x22,"left/right use separate eye areas");
    header->reading.store(first);
    require(halliday::publish(header,16,8,true,input.head,2,fill),"publish while previous frame is read");
    require(header->latest.load() != first,"never overwrite reader slot");
    const uint32_t latest = header->latest.load();
    require(!halliday::publish(header,16,8,true,input.head,3,[](size_t,uint8_t*) { return false; }),
        "propagate transfer failure");
    require(header->latest.load() == latest && header->clientFrames.load() == 2,
        "failed transfer never replaces a complete frame");
    require(halliday::publish(header,16,8,true,input.head,3,fill),"recover after failed transfer");
    require(header->frames[first - 1].frameIndex == 1,"reader image remains unchanged");
    const uint32_t metadata = halliday::frameTextureMetadata(4,halliday::kColorLinear,halliday::kColorSrgb);
    require(halliday::publish(header,16,8,true,input.head,4,fill,metadata),"publish optional per-eye colour tags");
    const auto tagged = header->frames[header->latest.load()-1].textureType;
    require((tagged & 255) == 4 && halliday::frameColorSpace(tagged,0) == 1 &&
            halliday::frameColorSpace(tagged,1) == 2,"preserve API and distinct eye transfer metadata");
    require(halliday::frameColorSpace(1,0) == 0 && halliday::frameColorSpace(1,1) == 0 &&
            halliday::frameColorSpace(0xffffffff,2) == 0,"legacy and unknown colour metadata is safe");
    header->alive.store(1); header->initialized.store(1); header->clientPid = 123;
    require(!halliday::haptics::claim(header,123,77),"legacy v6 host without haptic extension stays usable and rejects haptics honestly");
    auto* haptics = new (bytes + halliday::haptics::kOffset) halliday::haptics::Extension{};
    haptics->magic = halliday::haptics::kMagic; haptics->version = halliday::haptics::kVersion;
    haptics->clockNs.store(1'000'000'000);
    require(!halliday::haptics::claim(header,999,77),"foreign producer cannot claim a host-owned mailbox");
    haptics->hands[0].seq.store(3);
    require(halliday::haptics::claim(header,123,77) == 77 && haptics->hands[0].seq.load() == 0,
        "new owned epoch recovers an interrupted odd writer");
    require(halliday::haptics::send(header,123,77,0,50'000'000,160,.7f) &&
            halliday::haptics::send(header,123,77,1,20'000'000,0,.4f),"publish each hand independently");
    require(haptics->hands[0].seq.load() == 2 && haptics->hands[1].seq.load() == 2 &&
            haptics->hands[0].epoch.load() == 77 && haptics->hands[0].issuedHostClock.load() == 1'000'000'000 &&
            haptics->hands[0].durationNs.load() == 50'000'000,"haptic fields share exact host clock and generation");
    header->dashboard.store(1);
    require(!halliday::haptics::send(header,123,77,0,50'000'000,160,.7f),"dashboard suppresses independent output");
    header->dashboard.store(0); haptics->hands[1].seq.store(3);
    require(!halliday::haptics::send(header,123,77,1,0,0,0),"a busy mailbox fails in bounded time");
    require(halliday::haptics::claim(header,123,78) == 78,"next session has a new epoch");
    halliday::haptics::release(header,123,77);
    require(haptics->clientEpoch.load() == 78 && !halliday::haptics::send(header,123,77,0,0,0,0),
        "stale client cannot release or write the newer session");
    require(halliday::haptics::send(header,123,78,0,0,0,0),"explicit stop is a real mailbox command");
    halliday::haptics::release(header,123,78);
    require(haptics->clientEpoch.load() == 0 && !halliday::haptics::send(header,123,78,0,0,0,0),
        "teardown invalidates only its owned epoch");
    munmap(memory,halliday::kFileBytes);
    std::puts("PASS: Halliday bridge pose sequence, stereo publication, slot ownership and failure recovery");
}
