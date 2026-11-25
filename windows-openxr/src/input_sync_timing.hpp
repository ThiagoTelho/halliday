#pragma once
#include <cstdint>
namespace halliday::input_timing {
constexpr uint32_t kMagic=0x48534954,kVersion=1;
enum Phase:uint32_t {kValidation,kSnapshot,kSnapshotLockWait,kFocus,kInputLockWait,kSelection,kPriority,kStateUpdate,kTotal,kCount};
constexpr const char* kNames[kCount]={"validation","snapshot_total","snapshot_control_lock_wait","focus","input_lock_wait","selection_and_profiles","binding_priorities","state_updates","total"};
struct Counter {uint64_t count{},sum{},minimum{},maximum{};};
struct Snapshot {uint32_t magic{kMagic},version{kVersion};uint64_t frequency{},start{},deadline{},generation{},completed{},clipped{};Counter phases[kCount]{};};
}
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
namespace basalt {
uint64_t inputSyncSnapshotTimingStart();
void inputSyncSnapshotTimingFinish(uint64_t start);
}
#endif
