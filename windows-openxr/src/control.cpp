// Windows OpenXR -> Halliday v6 shared-file transport. MIT, Halliday contributors.
// Uses ordinary D3D11 staging copies, without DXMT-private interfaces or sockets.
#include "runtime.hpp"
#include "control.hpp"
#include "input_sync_timing.hpp"
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include "pose_math.hpp"
#include "readback.hpp"
#include "stereo_readback_order.hpp"
#include "vulkan_backend.hpp"
#include "panel_bridge.hpp"
#include "panel_readback.hpp"
#include "motion_bridge.hpp"
#include "controller_frames_bridge.hpp"
#include "projection_geometry.hpp"
#include "source_timing_bridge.hpp"
#include "helper_game_identity.hpp"
#include "frame_timing.hpp"
#include "d3d11_prior_staging.hpp"
#include "d3d12_prior_staging.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {
// Admission pins the exact mapping/session/devices. Only lifecycle/mapping
// mutations take it exclusively; GPU capture and fresh input are co-readers.
SRWLOCK gLock = SRWLOCK_INIT;
SRWLOCK gInputStateLock = SRWLOCK_INIT;
SRWLOCK gVideoLock = SRWLOCK_INIT;
struct InputStateAccess {
    InputStateAccess(){AcquireSRWLockExclusive(&gInputStateLock);}
    ~InputStateAccess(){ReleaseSRWLockExclusive(&gInputStateLock);}
    InputStateAccess(const InputStateAccess&)=delete;
};
struct InputAccess {
    InputAccess(){AcquireSRWLockShared(&gLock);AcquireSRWLockExclusive(&gInputStateLock);}
    ~InputAccess(){ReleaseSRWLockExclusive(&gInputStateLock);ReleaseSRWLockShared(&gLock);}
    InputAccess(const InputAccess&)=delete;
};
struct VideoAccess {
    VideoAccess(){AcquireSRWLockShared(&gLock);AcquireSRWLockExclusive(&gVideoLock);}
    ~VideoAccess(){ReleaseSRWLockExclusive(&gVideoLock);ReleaseSRWLockShared(&gLock);}
    VideoAccess(const VideoAccess&)=delete;
};
halliday::Header* gHeader = nullptr;
XrSession gSession = XR_NULL_HANDLE;
ID3D11Device* gDevice = nullptr;
ID3D12Device* gDevice12 = nullptr;
ID3D12CommandQueue* gQueue12 = nullptr;
void* gVulkan = nullptr;
std::array<std::vector<uint8_t>,2> gVulkanPixels;
std::vector<std::vector<uint8_t>> gPanelPixels;
std::vector<basalt::ReadbackImage> gPanelImages;
HANDLE gStop = nullptr, gWorker = nullptr;
uint64_t gLastVsync = 0, gWaitedVsync = 0, gLastSeen = 0, gFrame = 0;
uint32_t gQuit = 0;
bool gClosing = false;
bool gPriorCapture = false; // One common staging path for every supported graphics API session.
bool gRegistered = false;
uint64_t gSessionGeneration = 0;
uint64_t gHapticEpoch = 0;
uint32_t gFocusGeneration = 0;
uint32_t gVideoFocusGeneration = 0, gVideoSpaceEpoch = 0;
HallidayTransferStats gStats = [] {
    HallidayTransferStats value{}; value.size = sizeof(value); value.version = HALLIDAY_TRANSFER_STATS_VERSION;
    return value;
}();
halliday::State gSample{};
std::array<halliday::Pose, 64> gGiven{};
size_t gGivenNext = 0;
struct TimedState {
    XrTime time = 0;
    halliday::State state{};
    XrPosef localOrigin{};
    bool haveLocalOrigin = false;
    uint32_t motionMask = halliday::motion::kAll;
    halliday::controller_frames::Kinds controllerFrames = halliday::controller_frames::kLegacy;
};
std::array<TimedState,64> gTimedStates{};
size_t gNextTimedState = 0;
XrTime gNewestSampleTime = 0;

XrPosef gLocalOrigin = basalt::identityPose();
bool gHaveLocalOrigin = false;
uint32_t gLocalSpaceEpoch = 0;

std::wstring moduleFolder() {
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&moduleFolder), &module)) return {};
    wchar_t path[32768]{};
    DWORD count = GetModuleFileNameW(module, path, 32768);
    if (!count || count >= 32768) return {};
    std::wstring result(path, count);
    const auto slash = result.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"." : result.substr(0, slash);
}
// Requires video-exclusive access, or lifecycle-exclusive admission (no readers).
// Retire a whole capture pair before crossing composition or coordinate epochs.
// Failed retirement retains backend-owned resources and forbids synchronous reuse.
bool resetPriorReadbackLocked() {
    basalt::resetD3D11PriorReadback();
    const bool d3d12Ready = basalt::resetD3D12PriorReadback();
    const bool vulkanReady = !gVulkan || basalt::resetVulkanPriorReadback(gVulkan);
    return d3d12Ready && vulkanReady;
}
bool prepareCurrentFrameLocked(const basalt::ControlFrameView views[2], basalt::ReadbackImage images[2]) {
    return gVulkan ? basalt::prepareVulkanFrame(gVulkan,views,images,gVulkanPixels) :
        gDevice12 ? basalt::prepareD3D12Frame(gDevice12,gQueue12,views,images) :
        basalt::prepareD3D11Frame(gDevice,views,images);
}
basalt::PriorStagingResult preparePriorFrameLocked(const basalt::PriorProjectionFrame& submitted,
        basalt::ReadbackImage images[2], basalt::PriorProjectionFrame* captured) {
    return gVulkan ? basalt::prepareVulkanPriorFrame(gVulkan,submitted,images,captured) :
        gDevice12 ? basalt::prepareD3D12PriorFrame(gDevice12,gQueue12,submitted,images,captured) :
        basalt::prepareD3D11PriorFrame(gDevice,submitted,images,captured);
}
void finishCapturedFrameLocked() {
    if (gVulkan) basalt::finishVulkanPriorFrame(gVulkan);
    else if (gDevice12) {
        basalt::finishD3D12PriorFrame();
        basalt::finishD3D12Frame();
    } else basalt::finishD3D11Frame();
}
std::vector<std::wstring> bridgePaths() {
    const wchar_t* variable = GetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH",nullptr,0) ?
        L"HALLIDAY_BRIDGE_PATH" : L"HALLIDAY_BRIDGE";
    const DWORD length = GetEnvironmentVariableW(variable, nullptr, 0);
    if (length) {
        std::wstring path(length, L'\0');
        const DWORD copied = GetEnvironmentVariableW(variable, path.data(), length);
        if (copied && copied < length) { path.resize(copied); return {path}; }
       return {};
    }
    const auto folder = moduleFolder();
    return {folder + L"\\..\\halliday-bridge.shm",
            folder + L"\\..\\..\\halliday-bridge.shm",
            folder + L"\\..\\..\\OpenVR\\halliday-bridge.shm"};
}
bool mapLocked() {
    // Queries can map a host before xrCreateSession. A crashed host leaves its
    // old inode's alive flag set even after a new host replaces the public file.
    // Reopen the current route while idle; an active session remains bound to
    // its original mapping and must observe host loss instead of migrating.
    if (gHeader && gSession != XR_NULL_HANDLE) return true;
    if (gHeader) { UnmapViewOfFile(gHeader); gHeader = nullptr; }
    for (const auto& path : bridgePaths()) {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) continue;
        LARGE_INTEGER bytes{};
        const bool largeEnough = GetFileSizeEx(file, &bytes) &&
            static_cast<uint64_t>(bytes.QuadPart) >= halliday::kFileBytes;
        HANDLE mapping = largeEnough ? CreateFileMappingW(file, nullptr,
            PAGE_READWRITE, 0, 0, nullptr) : nullptr;
        CloseHandle(file);
        if (!mapping) continue;
        auto* header = static_cast<halliday::Header*>(MapViewOfFile(mapping,
            FILE_MAP_ALL_ACCESS, 0, 0, halliday::kFileBytes));
        CloseHandle(mapping);
        if (!header) continue;
        if (header->magic != halliday::kMagic || header->version != halliday::kVersion) {
            std::fprintf(stderr, "Halliday Windows OpenXR: bridge ABI mismatch (need v%u)\n",
                halliday::kVersion);
            UnmapViewOfFile(header); continue;
        }
        gHeader = header;
        gLastVsync = header->vsync.load(); gLastSeen = GetTickCount64();
       return true;
    }
    return false;
}
bool activeLocked(XrSession session) {
    if (gClosing || !gRegistered || !gHeader || session == XR_NULL_HANDLE || session != gSession ||
        !gHeader->alive.load() || gHeader->initialized.load()!=1 || gHeader->clientPid!=GetCurrentProcessId())
       return false;
    if(const auto* extension=halliday::haptics::extension(gHeader);extension&&gHapticEpoch&&
        (extension->ownerPid.load()!=GetCurrentProcessId()||extension->clientEpoch.load()!=gHapticEpoch))return false;
    const uint64_t vsync = gHeader->vsync.load();
    if (vsync != gLastVsync) { gLastVsync = vsync; gLastSeen = GetTickCount64(); }
    gHeader->clientCalls.fetch_add(1, std::memory_order_relaxed);
    return GetTickCount64() - gLastSeen <= 500;
}
void refreshFocusLocked() {
    const uint32_t generation=halliday::focus::generation(halliday::focus::extension(gHeader));
    if(generation==gFocusGeneration)return;
    gFocusGeneration=generation;
    // Input must never retire a transfer concurrently with a GPU capture.
    // The video path independently observes this generation before/after work.
    // The latest boolean may be focused again after a full dashboard cycle.
    // Stop pre-edge mailboxes before a fresh post-edge Apply writes its pulse.
    if(gHeader&&gRegistered)for(uint32_t hand=0;hand<2;++hand)
        halliday::haptics::send(gHeader,GetCurrentProcessId(),gHapticEpoch,hand,0,0,0);
}
bool refreshVideoEpochsLocked() {
    const auto focus=halliday::focus::generation(halliday::focus::extension(gHeader));
    const auto* extension=halliday::haptics::extension(gHeader);
    const auto space=extension?extension->spaceEpoch.load(std::memory_order_acquire):0;
    if(focus==gVideoFocusGeneration&&space==gVideoSpaceEpoch)return true;
    if(!resetPriorReadbackLocked())return false;
    gVideoFocusGeneration=focus;gVideoSpaceEpoch=space;
    return true;
}
basalt::ControlLifecycleSnapshot lifecycleSnapshotLocked(XrSession session) {
    basalt::ControlLifecycleSnapshot result{};
    // Only the session that successfully claimed this exact mapping may
    // consume its quit request. Never acknowledge another producer's host.
    if (gClosing || !gHeader || session == XR_NULL_HANDLE || session != gSession ||
        gHeader->clientPid != GetCurrentProcessId() || !gHeader->initialized.load())
       return result;
    result.active = activeLocked(session);
    refreshFocusLocked();
    result.renderingAllowed = result.active && !gHeader->dashboard.load();
    if (auto* extension = halliday::haptics::extension(gHeader))
        result.spaceEpoch = extension->spaceEpoch.load(std::memory_order_acquire);
    const uint32_t quit = gHeader->quitRequests.load();
    if (quit != gQuit) {
        gQuit = quit;
        gHeader->quitAcknowledged.store(quit);
        result.exitRequested = true;
    }
    return result;
}
XrPosef fromPose(const halliday::Pose& pose) {
    return {{pose.orientation[0], pose.orientation[1], pose.orientation[2], pose.orientation[3]},
            {pose.position[0], pose.position[1], pose.position[2]}};
}
XrTime timeNow();
void referenceOriginLocked(const halliday::State& state) {
    const auto* extension = halliday::haptics::extension(gHeader);
    const uint32_t epoch = extension ? extension->spaceEpoch.load(std::memory_order_acquire) : 0;
    if (epoch != gLocalSpaceEpoch) {
        gLocalSpaceEpoch = epoch;
        // Video retirement is deferred to its own generation checks; fresh
        // input/history updates do not acquire or mutate the staging pipeline.
        gHaveLocalOrigin = false;
        // Keep the bounded samples together with their old LOCAL origins.
        // xrLocateSpace may still request a known pre-recenter frame time;
        // only an in-flight submission, not a historical query, is retired.
        const XrTime changeTime = timeNow();
        for (auto& sample : gTimedStates)
            if (sample.time >= changeTime) sample = {};
        // A future prediction cached before the recenter must be resampled in
        // the new coordinates. Unknown past queries remain untracked.
        gNewestSampleTime = changeTime;
        gGiven = {}; gGivenNext = 0;
    }
    if (gHaveLocalOrigin || !state.head.valid) return;
    const auto head = fromPose(state.head);
    if (!basalt::isPoseWellFormed(head)) return;
    const auto forward = basalt::quaternionRotate(head.orientation, {0,0,-1});
    // Keep the origin level. Pitch and roll remain head motion, not a tilted
    // world. A vertical gaze supplies no horizontal heading; zero is stable.
    const float yaw = forward.x * forward.x + forward.z * forward.z > 1e-8f
        ? std::atan2(-forward.x,-forward.z) : 0;
    gLocalOrigin = {{0,std::sin(yaw * .5f),0,std::cos(yaw * .5f)},head.position};
    gHaveLocalOrigin = true;
}
bool sampleLocked(XrSession session, halliday::State* state, XrTime time = 0,
                  XrPosef* localOrigin = nullptr, bool* haveLocalOrigin = nullptr,uint32_t* motionMask=nullptr,
                  halliday::controller_frames::Kinds* controllerFrames=nullptr) {
    if (!activeLocked(session)) return false;
    // Observe a host recenter before sampling new times. Historical samples
    // retain their own origin rather than mixing an old pose with today's one.
    const auto* extension = halliday::haptics::extension(gHeader);
    const uint32_t epoch = extension ? extension->spaceEpoch.load(std::memory_order_acquire) : 0;
    if (epoch != gLocalSpaceEpoch) {
        halliday::State fresh{};
        if (!halliday::readState(gHeader,&fresh)) return false;
        referenceOriginLocked(fresh);
    }
    if (time > 0) {
        for (const auto& sample : gTimedStates) if (sample.time == time) {
            *state = sample.state;
            if (localOrigin) *localOrigin = sample.localOrigin;
            if (haveLocalOrigin) *haveLocalOrigin = sample.haveLocalOrigin;
            if (motionMask) *motionMask=sample.motionMask;
            if (controllerFrames) *controllerFrames=sample.controllerFrames;
           return true;
        }
        // Unknown older times cannot be assigned today's input under an old
        // timestamp. Cached frame times remain valid until bounded eviction.
        if (time < gNewestSampleTime) return false;
    }
    uint32_t mask=0;
    halliday::controller_frames::Kinds frames=halliday::controller_frames::kLegacy;
    if (!halliday::controller_frames::readState(gHeader,state,&mask,&frames)) return false;
    referenceOriginLocked(*state);
    if (localOrigin) *localOrigin = gLocalOrigin;
    if (haveLocalOrigin) *haveLocalOrigin = gHaveLocalOrigin;
    if(motionMask)*motionMask=mask;
    if(controllerFrames)*controllerFrames=frames;
    if (time > 0) {
        gTimedStates[gNextTimedState++ % gTimedStates.size()] =
            {time, *state, gLocalOrigin, gHaveLocalOrigin,mask,frames};
        gNewestSampleTime=std::max(gNewestSampleTime,time);
    }
    return true;
}
DWORD WINAPI heartbeat(void* parameter) {
    const HANDLE stop = static_cast<HANDLE>(parameter);
    while (WaitForSingleObject(stop, 200) == WAIT_TIMEOUT) {
        AcquireSRWLockShared(&gLock);
        if (gRegistered && gHeader && gSession != XR_NULL_HANDLE) gHeader->heartbeat.fetch_add(1);
        ReleaseSRWLockShared(&gLock);
    }
    return 0;
}
XrTime timeNow() {
    LARGE_INTEGER now{}, frequency{};
    QueryPerformanceCounter(&now); QueryPerformanceFrequency(&frequency);
    return (now.QuadPart / frequency.QuadPart) * 1'000'000'000 +
        (now.QuadPart % frequency.QuadPart) * 1'000'000'000 / frequency.QuadPart;
}
} // namespace

extern "C" uint32_t __cdecl hallidayGetTransferStats(HallidayTransferStats* output,uint32_t size) {
    if (!output || size < sizeof(HallidayTransferStats)) return 0;
    AcquireSRWLockShared(&gLock); AcquireSRWLockShared(&gVideoLock);
    *output = gStats;
    ReleaseSRWLockShared(&gVideoLock); ReleaseSRWLockShared(&gLock);
    return 1;
}

namespace basalt {
HallidayTransferStats& transferStatistics() { return gStats; }

void controlSessionCreated(XrSession session, ID3D11Device* device) {
    AcquireSRWLockExclusive(&gLock);
    if (!mapLocked() || !gHeader->alive.load()) {
        std::fprintf(stderr,"Halliday Windows OpenXR: session creation failed: no live host bridge\n");
        ReleaseSRWLockExclusive(&gLock); return;
    }
    if ((device && FAILED(device->GetDeviceRemovedReason())) || !resetD3D12Readback() || !resetD3D12Panels()) {
        std::fprintf(stderr,"Halliday Windows OpenXR: session creation failed: device lost or previous D3D12 transfers still pending\n");
        ReleaseSRWLockExclusive(&gLock); return;
    }
    // A native PID cannot be diagnosed through Wine OpenProcess. Failure to
    // open it is not proof of death. Claim only an unowned bridge, using the
    // same initialization lease as the native producer before writing PID/name.
    uint32_t unowned = 0;
    if (!gHeader->initialized.compare_exchange_strong(unowned, UINT32_MAX,
            std::memory_order_acq_rel)) {
        const auto* extension=halliday::haptics::extension(gHeader);
        std::fprintf(stderr,"Halliday Windows OpenXR: session creation blocked by producer lease %u (PID %u, epoch %llu, heartbeat %llu)\n",
            unowned,gHeader->clientPid,
            static_cast<unsigned long long>(extension?extension->clientEpoch.load():0),
            static_cast<unsigned long long>(gHeader->heartbeat.load()));
        ReleaseSRWLockExclusive(&gLock); return;
    }
    resetD3D11Readback();
    resetD3D11Panels();
    gStats = {}; gStats.size = sizeof(gStats); gStats.version = HALLIDAY_TRANSFER_STATS_VERSION;
    gStats.sessionGeneration = ++gSessionGeneration; gStats.sessionActive = 1; gStats.activeApi = device ? 11 : 0;
    gClosing = false;
    gSession = session; gDevice = device; if (device) device->AddRef();
    gFrame = 0; gWaitedVsync = 0; gGiven = {}; gGivenNext = 0;
    gTimedStates = {}; gNextTimedState = 0; gNewestSampleTime = 0;
    gHaveLocalOrigin = false; gLocalOrigin = identityPose(); gLocalSpaceEpoch = 0;
    halliday::State initial{};
    if (halliday::readState(gHeader,&initial)) referenceOriginLocked(initial);
    gQuit = gHeader->quitRequests.load();
    gHeader->clientPid = GetCurrentProcessId();
    char executable[32768]{};
    const DWORD executableLength=GetModuleFileNameA(nullptr,executable,sizeof(executable));
    if (!executableLength || executableLength >= sizeof(executable)) executable[0]='\0';
    else executable[executableLength]='\0';
    const char* filename = std::strrchr(executable, '\\');
    gPriorCapture = true;
    std::strncpy(gHeader->appName, filename ? filename + 1 : executable, 63);
    gHeader->appName[63] = '\0';
    // Preserve the helper PID for ownership/lifetime. Only its verified live
    // game parent may supply the application name used by Resume on the host.
    if(const auto game=halliday::helper_identity::verified_parent_name(gHeader->appName)) {
        std::memcpy(gHeader->appName,game->data(),game->size());
        gHeader->appName[game->size()]='\0';
    }
    // The new session starts with no image, even if the previous SDK session
    // ended between two host ticks. Preserve a slot still owned by a host GPU copy.
    gHeader->latest.store(0);
    gHeader->clientFrames.store(0);
    gRegistered = true;
    const uint64_t epoch = static_cast<uint64_t>(timeNow()) ^
        (uint64_t(GetCurrentProcessId()) << 32) ^ gSessionGeneration;
    gHapticEpoch = halliday::haptics::claim(gHeader, GetCurrentProcessId(), epoch ? epoch : 1);
    gFocusGeneration=halliday::focus::generation(halliday::focus::extension(gHeader));
    gVideoFocusGeneration=gFocusGeneration;gVideoSpaceEpoch=gLocalSpaceEpoch;
    // Publish readiness after the image reset and generation are both visible.
    gHeader->initialized.store(1); gHeader->heartbeat.fetch_add(1);
    gStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (gStop) gWorker = CreateThread(nullptr, 0, heartbeat, gStop, 0, nullptr);
    ReleaseSRWLockExclusive(&gLock);
}
void controlSessionCreatedVulkan(XrSession session,void* context) {
    controlSessionCreated(session,nullptr);
    AcquireSRWLockExclusive(&gLock);
    if(gSession==session) { gVulkan=context;gStats.activeApi=2; }
    ReleaseSRWLockExclusive(&gLock);
}
void controlSessionCreated12(XrSession session, ID3D12Device* device, ID3D12CommandQueue* queue) {
    if (!device || !queue || FAILED(device->GetDeviceRemovedReason())) {
        std::fprintf(stderr,"Halliday Windows OpenXR: D3D12 session creation failed: missing binding or device lost\n");
        return;
    }
    controlSessionCreated(session,nullptr);
    AcquireSRWLockExclusive(&gLock);
    if (gSession == session) {
        gDevice12 = device; gQueue12 = queue; device->AddRef(); queue->AddRef(); gStats.activeApi = 12;
    }
    ReleaseSRWLockExclusive(&gLock);
}
void controlSessionEnded(XrSession session) {
    AcquireSRWLockExclusive(&gLock);
    if (gSession != session) { ReleaseSRWLockExclusive(&gLock); return; }
    if (!resetPriorReadbackLocked())
        std::fprintf(stderr,"Halliday Windows OpenXR: retaining pending prior-capture resources until GPU work retires\n");
    gPriorCapture = false;
    const HANDLE stop = gStop, worker = gWorker;
    gStop = gWorker = nullptr;
    if (stop) SetEvent(stop);
    // EndSession reaches EXITING even when a game retains its SDK session
    // object and continues in 2D. Release the public producer now, exactly
    // once; its later DestroySession cannot unregister a newer producer.
    if (gRegistered && gHeader) {
        halliday::haptics::release(gHeader, GetCurrentProcessId(), gHapticEpoch);
        if (gHeader->clientPid == GetCurrentProcessId()) {
            uint32_t owned = 1;
            gHeader->initialized.compare_exchange_strong(owned, 0, std::memory_order_acq_rel);
        }
    }
    gRegistered = false; gHapticEpoch = 0;
    gStats.sessionActive = 0; gStats.activeApi = 0;
    ReleaseSRWLockExclusive(&gLock);
    if (worker) { WaitForSingleObject(worker, INFINITE); CloseHandle(worker); }
    if (stop) CloseHandle(stop);
}
void controlSessionDestroyed(XrSession session) {
    controlSessionEnded(session);
    AcquireSRWLockExclusive(&gLock);
    if (gSession != session) { ReleaseSRWLockExclusive(&gLock); return; }
    gClosing = true; gStats.sessionActive = 0; gStats.activeApi = 0;
    resetD3D11Readback();
    resetD3D11Panels();
    if (!resetD3D12Readback())
        std::fprintf(stderr,"Halliday Windows OpenXR: preserving transfer resources until pending GPU work completes\n");
    if(!resetD3D12Panels())
        std::fprintf(stderr,"Halliday Windows OpenXR: preserving panel resources until pending GPU work completes\n");
    if (gHeader) {
        UnmapViewOfFile(gHeader); gHeader = nullptr;
    }
    gHapticEpoch = 0;
    if (gDevice) gDevice->Release();
    if (gDevice12) gDevice12->Release(); if (gQueue12) gQueue12->Release();
    gDevice12 = nullptr; gQueue12 = nullptr;
    if (gVulkan && !resetVulkanPriorReadback(gVulkan)) abandonVulkanPriorReadback(gVulkan);
    gVulkan = nullptr; gVulkanPixels = {};
    gPanelPixels.clear();gPanelImages.clear();
    gDevice = nullptr; gSession = XR_NULL_HANDLE; gClosing = false;
    ReleaseSRWLockExclusive(&gLock);
}
bool controlActive(XrSession session) {
    InputAccess access; const bool result = activeLocked(session);
    return result;
}
bool controlHostAvailable() {
    AcquireSRWLockShared(&gLock);
    if(gHeader&&gSession!=XR_NULL_HANDLE){const bool ready=gHeader->alive.load()!=0;ReleaseSRWLockShared(&gLock);return ready;}
    ReleaseSRWLockShared(&gLock);
    AcquireSRWLockExclusive(&gLock);
    // Another session may have appeared while upgrading: mapLocked revalidates
    // and keeps its bound mapping rather than migrating an active producer.
    const bool result = mapLocked() && gHeader->alive.load();
    ReleaseSRWLockExclusive(&gLock); return result;
}
void controlCloseIdleMapping() {
    AcquireSRWLockExclusive(&gLock);
    if (gHeader && gSession == XR_NULL_HANDLE) { UnmapViewOfFile(gHeader); gHeader = nullptr; }
    ReleaseSRWLockExclusive(&gLock);
}
bool controlRenderingAllowed(XrSession session) {
    InputAccess access;
    const bool result = activeLocked(session) && !gHeader->dashboard.load();
    return result;
}
ControlLifecycleSnapshot controlLifecycleSnapshot(XrSession session) {
    InputAccess access;
    const auto result = lifecycleSnapshotLocked(session);
    return result;
}
bool controlConfiguredViewSize(uint32_t* width, uint32_t* height) {
    AcquireSRWLockShared(&gLock);
    if(gHeader&&gSession!=XR_NULL_HANDLE){
        const bool ready=gHeader->alive.load()&&halliday::fits(gHeader->eyeWidth,gHeader->eyeHeight);
        if(ready){*width=gHeader->eyeWidth;*height=gHeader->eyeHeight;}
        ReleaseSRWLockShared(&gLock);return ready;
    }
    ReleaseSRWLockShared(&gLock);
    AcquireSRWLockExclusive(&gLock);
    const bool result=mapLocked()&&gHeader->alive.load()&&halliday::fits(gHeader->eyeWidth,gHeader->eyeHeight);
    if(result){*width=gHeader->eyeWidth;*height=gHeader->eyeHeight;}
    ReleaseSRWLockExclusive(&gLock);return result;
}
XrDuration controlDisplayPeriod(XrSession session) {
    InputAccess access;
    XrDuration result = 11'111'111;
    if (activeLocked(session)) {
        const uint64_t measured = gHeader->intervalNs.load();
        if (measured >= 4'000'000 && measured <= 50'000'000) result = measured;
        else if (std::isfinite(gHeader->displayHz) && gHeader->displayHz >= 20 && gHeader->displayHz <= 250)
            result = static_cast<XrDuration>(1e9 / gHeader->displayHz);
    }
    return result;
}
bool controlWaitForFrameBudget(XrSession session) {
    const uint64_t started = GetTickCount64();
    for (;;) {
        ControlLifecycleSnapshot status{};bool ready=false;
        {
            InputAccess access;
            status = lifecycleSnapshotLocked(session);
            if (!status.active) return false;
            const uint64_t vsync = gHeader->vsync.load();
            ready = vsync != gWaitedVsync && halliday::readState(gHeader, &gSample);
            if (ready) gWaitedVsync = vsync;
        }
        if (status.exitRequested) { requestExitSession(session); return false; }
        if (ready) return true;
        if (GetTickCount64() - started >= 250) return false;
        Sleep(1);
    }
}
void controlNotePredictedDisplayTime(XrSession session, XrTime time) {
    InputAccess access;
    halliday::State snapshot{}; (void)sampleLocked(session,&snapshot,time);

}
bool controlHeadPose(XrSession session, XrTime time, uint64_t* stamp, XrPosef* pose) {
    InputAccess access;
    halliday::State state{};
    const bool result = sampleLocked(session, &state, time) && state.head.valid &&
        isPoseWellFormed(fromPose(state.head));
    if (result) {
        if (pose) *pose = fromPose(state.head);
        if (stamp) *stamp = static_cast<uint64_t>(std::max(0.0f, state.head.stamp));
        gGiven[gGivenNext++ % gGiven.size()] = state.head;
    }
    return result;
}
bool controlHeadMotion(XrSession session, XrTime time, XrVector3f* linear, XrVector3f* angular,uint32_t* flags) {
    if (!linear || !angular) return false;
    *linear = {}; *angular = {};
    if(flags)*flags=0;
    InputAccess access;
    halliday::State state{};
    uint32_t mask=0;
    bool result = sampleLocked(session, &state, time,nullptr,nullptr,&mask) && state.head.valid &&
        isPoseWellFormed(fromPose(state.head));
    if (result) {
        uint32_t valid=mask&3;
        for(unsigned axis=0;axis<3;++axis){
            if(!std::isfinite(state.head.velocity[axis]))valid&=~1u;
            if(!std::isfinite(state.head.angularVelocity[axis]))valid&=~2u;
        }
        if(valid&1)*linear = {state.head.velocity[0],state.head.velocity[1],state.head.velocity[2]};
        if(valid&2)*angular = {state.head.angularVelocity[0],state.head.angularVelocity[1],state.head.angularVelocity[2]};
        if(flags)*flags=valid;
    }

    return result;
}
bool controlReferenceOrigin(XrSession session, XrReferenceSpaceType type, XrPosef* pose, XrTime time) {
    if (!pose) return false;
    if (type == XR_REFERENCE_SPACE_TYPE_STAGE) { *pose = identityPose(); return true; }
    if (type != XR_REFERENCE_SPACE_TYPE_LOCAL && type != XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR)
       return false;
    InputAccess access;
    halliday::State state{};
    XrPosef origin{};
    bool haveOrigin = false;
    const bool sampled = sampleLocked(session,&state,time,&origin,&haveOrigin);
    const bool result = sampled && haveOrigin;
    if (result) {
        *pose = origin;
        if (type == XR_REFERENCE_SPACE_TYPE_LOCAL_FLOOR) pose->position.y = 0;
    }

    return result;
}
bool controlViewConfig(XrSession session, float* ipd, XrFovf fov[2]) {
    InputAccess access;
    const bool result = activeLocked(session);
    if (result) {
        *ipd = gHeader->ipd;
        for (unsigned eye = 0; eye < 2; ++eye) {
            const float* t = gHeader->tangents[eye];
            fov[eye] = {std::atan(t[0]), std::atan(t[1]), std::atan(t[2]), std::atan(t[3])};
        }
    }
    return result;
}

bool controlInputSnapshot(XrSession session, ControlInputSnapshot* output, XrTime time) {
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
    const auto syncLockStart=inputSyncSnapshotTimingStart();
#endif
    InputAccess access;
#ifdef HALLIDAY_XR_INPUT_PHASE_DIAGNOSTIC
    inputSyncSnapshotTimingFinish(syncLockStart);
#endif
    refreshFocusLocked();
    *output = {};
    halliday::State state{};
    uint32_t mask=0;
    halliday::controller_frames::Kinds frames=halliday::controller_frames::kLegacy;
    if (!sampleLocked(session, &state, time,nullptr,nullptr,&mask,&frames)) return false;
    constexpr uint64_t profile = 0x0812fd85c84384a6ULL; // frontend's Touch-compatible controls
    // IDs are internal keys inherited from Basalt's action mapper, not network traffic.
    constexpr uint64_t ids[2][12] = {
        {0xb1a13c485685e33cULL,0x521496d23e3e9883ULL,0x6268a669e87cf910ULL,
         0x01f1b9c689804b82ULL,0x0b66bbe3dc2dc49fULL,0x4fa57f59dbae033aULL,
         0xc3d709ed0d794ea1ULL,0xcb7d928706263554ULL,0xdfc8a61273cf2569ULL,
         0x0966df80f4989bfcULL,0xc3d476432e89d9ddULL,0x117d0816b380e1f2ULL},
        {0xc72a0ba6ca52fba7ULL,0x955047466e34669bULL,kAlvrRightSystemClickPathId,
         0xdd5935cc005136f1ULL,0xede7e982d5eedf21ULL,0xe0a7e848dde340b0ULL,
         0xd7c23648f060c6dfULL,0xcee8c338e02e0131ULL,0x00ac9a92f4453d61ULL,
         0xef43fe49dfc87556ULL,0x07aedc78fdf1bf2aULL,0xdd8323caa5e48729ULL}};
    for (unsigned hand = 0; hand < 2; ++hand) {
        const auto& c = state.controllers[hand]; auto& out = output->controllers[hand];
        out.profileActive = c.connected != 0; out.profileId = profile;
        out.poseActive = c.connected && c.pose.valid && isPoseWellFormed(fromPose(c.pose));
        out.poseInLocal = fromPose(c.pose); out.aimPoseInLocal = out.poseInLocal;
        const auto convert = [&](halliday::controller_frames::Target target, XrPosef& pose) {
            float q[4]{};
            halliday::controller_frames::orientation(frames[hand],target,c.pose.orientation,q);
            pose.orientation={q[0],q[1],q[2],q[3]};
        };
        convert(halliday::controller_frames::Target::OpenXrGrip,out.poseInLocal);
        convert(halliday::controller_frames::Target::OpenXrAim,out.aimPoseInLocal);
        out.questTimestampNanoseconds = c.packet;
        out.linearVelocity = {c.pose.velocity[0],c.pose.velocity[1],c.pose.velocity[2]};
        out.angularVelocity = {c.pose.angularVelocity[0],c.pose.angularVelocity[1],c.pose.angularVelocity[2]};
        out.motionFlags=(mask>>((hand+1)*2))&3;
        out.triggerValue=c.axes[1][0];
        const auto held = [&](unsigned bit) { return c.pressed & (uint64_t(1) << bit) ? 1.0f : 0.0f; };
        const auto touch = [&](unsigned bit) { return c.touched & (uint64_t(1) << bit) ? 1.0f : 0.0f; };
        const float values[12] = {held(7),held(1),held(0),std::max(c.axes[2][0],held(2)),
            std::max(c.axes[1][0],held(33)),touch(33),c.axes[0][0],c.axes[0][1],held(32),touch(32),touch(7),touch(1)};
        for (unsigned i = 0; i < 12; ++i) {
            auto& button = output->buttons[output->buttonCount++];
            button = {ids[hand][i],(i == 3 || i == 4 || i == 6 || i == 7) ? 1u : 0u,values[i],timeNow()};
        }
    }
    return true;
}
bool controlSendHaptic(XrSession session, ControlHand hand, uint64_t duration, float frequency, float amplitude) {
    InputAccess access;
    refreshFocusLocked();
    const bool sent = activeLocked(session) && halliday::haptics::send(gHeader, GetCurrentProcessId(),
        gHapticEpoch, static_cast<uint32_t>(hand), duration, frequency, amplitude);

    return sent;
}

XrResult controlFrameReady(int64_t displayTime, uint64_t stamp, const ControlFrameView* views, uint32_t count,
    const ControlFrameQuad* quads,uint32_t quadCount,uint32_t projectionOrder,uint32_t projectionFlags,
    uint32_t frameSpaceEpoch) {
    if ((count!=0&&count!=2)||(count&&!views)||quadCount>halliday::panels::kMaximum||(!quads&&quadCount))return XR_ERROR_LAYER_INVALID;
    if (count && (views[0].rect.extent.width != views[1].rect.extent.width ||
        views[0].rect.extent.height != views[1].rect.extent.height)) return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    const auto width = count ? static_cast<uint32_t>(views[0].rect.extent.width) : 8u;
    const auto height = count ? static_cast<uint32_t>(views[0].rect.extent.height) : 8u;
    if (!halliday::fits(width, height)) return XR_ERROR_SWAPCHAIN_RECT_INVALID;
    timing::Span frameLockTiming(timing::Phase::FrameLock);
    VideoAccess access;
    frameLockTiming.finish();
    bool active=false;
    {InputStateAccess input;active=activeLocked(gSession);}
    if (!active || (!gDevice && !gDevice12 && !gVulkan)) {
        return XR_ERROR_RUNTIME_FAILURE;
    }
    const auto* extension=halliday::haptics::extension(gHeader);
    const uint32_t renderSpaceEpoch = frameSpaceEpoch != UINT32_MAX ? frameSpaceEpoch :
        extension ? extension->spaceEpoch.load() : 0;
    if(!refreshVideoEpochsLocked())return XR_ERROR_RUNTIME_FAILURE;
    const uint32_t renderFocusGeneration=halliday::focus::generation(halliday::focus::extension(gHeader));
    const uint64_t renderProducerEpoch=gHapticEpoch;
    const uint32_t configuredWidth=gHeader->eyeWidth,configuredHeight=gHeader->eyeHeight;
    const auto coordinatesCurrent = [&] {
        // Lifetime admission prevents local teardown; host ownership/layout or
        // focus/recenter can still change while GPU work is in flight.
        const auto* configured=reinterpret_cast<const volatile halliday::Header*>(gHeader);
       return gRegistered&&gHeader->alive.load(std::memory_order_acquire)&&gHeader->initialized.load()==1&&
            configured->clientPid==GetCurrentProcessId()&&
            (!extension||(extension->spaceEpoch.load()==renderSpaceEpoch&&
                (!renderProducerEpoch||(extension->ownerPid.load()==GetCurrentProcessId()&&extension->clientEpoch.load()==renderProducerEpoch))))&&
            halliday::focus::generation(halliday::focus::extension(gHeader))==renderFocusGeneration&&
            configured->eyeWidth==configuredWidth&&configured->eyeHeight==configuredHeight;
    };
    if (!coordinatesCurrent()) {
        resetPriorReadbackLocked();
       return XR_SUCCESS; // Recenter retired the submitted coordinates.
    }
    const bool batchAvailable=halliday::panels::extension(gHeader)!=nullptr;
    const bool requiredCapability=quadCount||(projectionFlags&1u);
    const bool requiredBatch=(requiredCapability||count==0)&&batchAvailable;
    if(requiredCapability&&!batchAvailable){
       return XR_ERROR_LAYER_INVALID;
    }
    halliday::Pose pose{};
    halliday::State state{};
    if (halliday::readState(gHeader, &state)) pose = state.head;
    if(count){
    pose.position[0] = (views[0].pose.position.x + views[1].pose.position.x) * 0.5f;
    pose.position[1] = (views[0].pose.position.y + views[1].pose.position.y) * 0.5f;
    pose.position[2] = (views[0].pose.position.z + views[1].pose.position.z) * 0.5f;
    const auto q = views[0].pose.orientation;
    pose.orientation[0] = q.x; pose.orientation[1] = q.y; pose.orientation[2] = q.z; pose.orientation[3] = q.w;
    pose.valid = 1; pose.stamp = 0;
    }
    // EndFrame may present an older rendered pose at a later display time.
    // Match the supplied pose against actual historical samples, including
    // translation (quaternion-only matching mislabels translation-only motion).
    {
    InputStateAccess input;
    for (size_t n=0;n<gGiven.size();++n) {
        const auto& given=gGiven[(gGivenNext+gGiven.size()-1-n)%gGiven.size()];
        if(!given.valid) continue;
        float distance=0, dot=0;
        for(unsigned k=0;k<3;++k){const float d=given.position[k]-pose.position[k];distance+=d*d;}
        for(unsigned k=0;k<4;++k)dot+=given.orientation[k]*pose.orientation[k];
        if(distance<1e-8f && std::fabs(std::fabs(dot)-1)<1e-5f) {
            pose.stamp=given.stamp;
            if(!stamp || static_cast<uint64_t>(given.stamp)==stamp) break;
        }
    }
    }
    halliday::projection::View projectionViews[2]{};
    const bool fullGeometry=count&&halliday::projection::extension(gHeader)!=nullptr;
    if(count) {
        for(unsigned eye=0;eye<2;++eye) {
            projectionViews[eye]=halliday::projection::fromSubmitted(views[eye].pose,views[eye].fov);
            if(!halliday::projection::valid(projectionViews[eye])) {
               return XR_ERROR_LAYER_INVALID;
            }
        }
        if(!fullGeometry&&!halliday::projection::legacyCompatible(gHeader,projectionViews,pose)) {
           return XR_ERROR_LAYER_INVALID;
        }
    }
    ReadbackImage images[2];
    bool priorWarmup = false;
    timing::Span prepareTiming(timing::Phase::Prepare);
    bool prepared = false;
    PriorProjectionFrame captured{};
    int64_t sourceDisplayTime = count ? displayTime : 0;
    uint32_t sourceClockKind = count ? halliday::frame_timing::kClockXrDisplayTimeNs : 0;
    if (gPriorCapture && priorProjectionEligible(count,quadCount,projectionFlags,fullGeometry)) {
        PriorProjectionFrame submitted{};
        for (unsigned eye = 0; eye < 2; ++eye) {
            submitted.views[eye] = views[eye]; submitted.geometry[eye] = projectionViews[eye];
        }
        submitted.head = pose; submitted.producerEpoch = gHapticEpoch;
        submitted.sourceDisplayTimeNs = sourceDisplayTime;
        submitted.sourceClockKind = sourceClockKind;
        submitted.spaceEpoch = renderSpaceEpoch;
        submitted.focusGeneration = halliday::focus::generation(halliday::focus::extension(gHeader));
        submitted.projectionOrder = projectionOrder; submitted.projectionFlags = projectionFlags;
        submitted.fullGeometry = fullGeometry; submitted.requiredBatch = requiredBatch;
        const auto result = preparePriorFrameLocked(submitted,images,&captured);
        priorWarmup = result == PriorStagingResult::Warmup;
        prepared = result == PriorStagingResult::Ready;
        if (prepared) {
            // Pixels, head pose, eye geometry, image orientation and semantics
            // all come from one older capture. Never tag prior pixels current.
            pose = captured.head; views = captured.views;
            sourceDisplayTime = captured.sourceDisplayTimeNs;
            sourceClockKind = captured.sourceClockKind;
            projectionOrder = captured.projectionOrder; projectionFlags = captured.projectionFlags;
            for (unsigned eye = 0; eye < 2; ++eye) projectionViews[eye] = captured.geometry[eye];
        }
        if (result == PriorStagingResult::Failed)
            prepared = resetPriorReadbackLocked() && prepareCurrentFrameLocked(views,images); // safe current-frame recovery
        if (!coordinatesCurrent() ||
            halliday::focus::generation(halliday::focus::extension(gHeader)) != submitted.focusGeneration) {
            resetPriorReadbackLocked(); prepared = false; priorWarmup = true;
        }
    } else {
        // A quad, empty frame or unsupported geometry must never be combined
        // with a pending projection from another submitted capture.
        prepared = resetPriorReadbackLocked() && (!count || prepareCurrentFrameLocked(views,images));
    }
    prepareTiming.finish();
    if (!coordinatesCurrent()) {
        resetPriorReadbackLocked(); prepared = false; priorWarmup = true;
    }
    if (prepared && count) for (unsigned eye=0;eye<2;++eye) {
        images[eye].flipX=views[eye].fov.angleLeft>views[eye].fov.angleRight;
        images[eye].flipY=views[eye].fov.angleDown>views[eye].fov.angleUp;
    }
    ControlFrameView panelViews[halliday::panels::kMaximum]{};
    for(uint32_t i=0;i<quadCount;++i)panelViews[i]=quads[i].image;
    timing::Span panelsTiming(timing::Phase::Panels);
    const bool panelsReady=prepared&&(!quadCount||(gVulkan ? readVulkanPanels(gVulkan,panelViews,quadCount,gPanelPixels,gPanelImages) :
        gDevice12 ? readD3D12Panels(gDevice12,gQueue12,panelViews,quadCount,gPanelPixels,gPanelImages) :
        readD3D11Panels(gDevice,panelViews,quadCount,gPanelPixels,gPanelImages)));
    panelsTiming.finish();
    timing::FrameInfo timingFrame{};
    const auto byteOrder=stereoReadbackOrder(images,prepared&&count);
    timingFrame.api=gVulkan?2u:gDevice12?12u:11u;
    timingFrame.width=width;timingFrame.height=height;timingFrame.quads=quadCount;
    timingFrame.periodNs=gHeader->intervalNs.load();
    if(prepared&&count)for(unsigned eye=0;eye<2;++eye){
        timingFrame.format[eye]=uint32_t(images[eye].format);timingFrame.pitch[eye]=images[eye].rowPitch;
    }
    timingFrame.swizzleEyes=byteOrder.swizzleEyes;
    timing::describe(timingFrame);
    bool success = false,dropped=priorWarmup,retiredCoordinates=false;
    if (panelsReady) {
        std::vector<halliday::panels::Image> panelPixels;panelPixels.reserve(quadCount);
        for(uint32_t i=0;i<quadCount;++i){const auto& quad=quads[i];const auto& image=gPanelImages[i];halliday::panels::Panel panel{};
            panel.pose.valid=1;panel.pose.position[0]=quad.pose.position.x;panel.pose.position[1]=quad.pose.position.y;panel.pose.position[2]=quad.pose.position.z;
            panel.pose.orientation[0]=quad.pose.orientation.x;panel.pose.orientation[1]=quad.pose.orientation.y;panel.pose.orientation[2]=quad.pose.orientation.z;panel.pose.orientation[3]=quad.pose.orientation.w;
            panel.width=quad.size.width;panel.height=quad.size.height;panel.eyeVisibility=uint32_t(quad.eyeVisibility);
            panel.flags=((quad.layerFlags&XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT)?1u:0u)|
                ((quad.layerFlags&XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT)?2u:0u);
            panel.order=quad.order;panel.colorSpace=image.colorSpace;panel.bgra=1;panel.anchor=quad.headLocked?1u:0u;
            panelPixels.push_back({panel,image.width,image.height,image.pixels,size_t(image.width)*image.height*4});
        }
        std::vector<halliday::panels::Panel> records;
        const uint32_t metadata = halliday::frameTextureMetadata(gVulkan ? 2 : gDevice12 ? 4 : 0,
            count?images[0].colorSpace:1u,count?images[1].colorSpace:1u) |
            (fullGeometry?halliday::kFrameProjectionGeometry:0u) |
            (requiredBatch?halliday::kFrameLayerBatch:0u);
        timing::Span publishTiming(timing::Phase::Publish);
        success = halliday::publish(gHeader,width,height,byteOrder.bgra,pose,gFrame+1,
            [&](size_t eye,uint8_t* pixels) {timing::Span copyTiming(timing::Phase::CpuCopy);if(count)copyReadbackImage(images[eye],byteOrder.bgra,pixels);else std::memset(pixels,0,size_t(width)*height*4);return true;},metadata,
            [&](size_t slot,uint64_t index){
                // The host can recenter while the CPU copies the eye pixels.
                // A retired render packet is dropped, never retagged current.
                if (!coordinatesCurrent()) {retiredCoordinates=true;dropped=true;return false;}
                gHeader->frames[slot].seeThrough=(projectionFlags&1u)?1u:0u;
                // Readback may return the preceding capture. Its submitted
                // display time must stay with those exact pixels and cameras.
                // Old hosts or unavailable times retain ordinary colour only.
                halliday::source_timing::publish(gHeader,slot,index,gHapticEpoch,sourceDisplayTime,sourceClockKind);
                if(fullGeometry&&!halliday::projection::publish(gHeader,slot,index,gHapticEpoch,projectionViews))return false;
                if(!halliday::panels::publishPictures(gHeader,panelPixels,records)){dropped=true;return false;}
               return halliday::panels::publishBatch(gHeader,slot,index,gHapticEpoch,projectionOrder,projectionFlags,records);
            });
    }
    if (count) finishCapturedFrameLocked();
    if (retiredCoordinates) resetPriorReadbackLocked();
    if (success) { ++gFrame; ++gStats.frameTransfers; }
    else if(!dropped) ++gStats.failedTransfers;
    timing::published(success);

    return success||dropped ? XR_SUCCESS : XR_ERROR_RUNTIME_FAILURE;
}
} // namespace basalt
