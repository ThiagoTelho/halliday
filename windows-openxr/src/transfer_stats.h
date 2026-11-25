// Private diagnostics for the isolated transfer tests; not an OpenXR extension.
#ifndef HALLIDAY_TRANSFER_STATS_H
#define HALLIDAY_TRANSFER_STATS_H
#include <stdint.h>

#define HALLIDAY_TRANSFER_STATS_VERSION 1u
typedef struct HallidayTransferStats {
    uint32_t size;
    uint32_t version;
    uint64_t sessionGeneration;
    uint32_t activeApi;       // 0, 2 (Vulkan), 11 or 12
    uint32_t sessionActive;
    uint64_t frameTransfers;
    uint64_t failedTransfers;
    uint64_t copyCommands;
    uint64_t queueSubmissions;
    uint64_t fenceSignals;
    uint64_t fenceWaits;
    uint64_t mapCalls;
    uint64_t stagingTextureCreates;
    uint64_t readbackBufferCreates;
    uint64_t allocatorCreates;
    uint64_t commandListCreates;
    uint64_t fenceCreates;
    uint64_t eventCreates;
    uint64_t liveStagingTextures;
    uint64_t liveReadbackBuffers;
    uint64_t liveCommandAllocators;
    uint64_t liveCommandLists;
    uint64_t liveFences;
    uint64_t liveEvents;
    uint64_t peakFramesInFlight;
} HallidayTransferStats;

#ifdef _WIN32
#ifdef __cplusplus
extern "C" {
#endif
// Returns 1 for a complete snapshot, 0 for null/undersized output.
// Counters reset on a successful session connection; generation increases.
// After destroy, counters remain readable and all safely released live counts
// are zero. A failed GPU submission is kept alive until completion/removal.
uint32_t __cdecl hallidayGetTransferStats(HallidayTransferStats* output,uint32_t size);
#ifdef __cplusplus
}
#endif
#endif
#endif
