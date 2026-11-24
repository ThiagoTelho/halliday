// Direct loader negotiation + real D3D11/bridge test. No registry/bottle edits.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include "bridge_layout.hpp"
#include "instance_teardown_checks.hpp"
#include "session_teardown_checks.hpp"
#include "quad_checks.hpp"
#include <cstdio>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <new>
#include <string>
#include <vector>

static void require(bool value,const char* message) {
    if (!value) { std::fprintf(stderr,"FAIL: %s (Windows error %lu)\n",message,GetLastError()); std::exit(1); }
}
static PFN_xrGetInstanceProcAddr gGipa;
static XrInstance gInstance = XR_NULL_HANDLE;
static void printProvider(const wchar_t* moduleName,const char* label) {
    HMODULE module = GetModuleHandleW(moduleName);
    require(module != nullptr,"graphics provider module is loaded");
    const auto* base = reinterpret_cast<const uint8_t*>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    require(dos->e_magic == IMAGE_DOS_SIGNATURE && nt->Signature == IMAGE_NT_SIGNATURE,"provider has valid PE headers");
    const auto* section = IMAGE_FIRST_SECTION(nt);
    for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i) if (!std::memcmp(section[i].Name,".text",5)) {
        const size_t size = std::min(section[i].Misc.VirtualSize,section[i].SizeOfRawData);
        uint32_t hash = 2166136261u;
        for (size_t byte = 0; byte < size; ++byte) hash = (hash^base[section[i].VirtualAddress+byte])*16777619u;
        std::printf("PROVIDER %s timestamp=%08lx image=%08lx text=%08lx hash=%08x\n",label,
            nt->FileHeader.TimeDateStamp,nt->OptionalHeader.SizeOfImage,section[i].Misc.VirtualSize,hash);
        return;
    }
    require(false,"provider contains executable code");
}
template <typename Function> Function load(const char* name) {
    PFN_xrVoidFunction function = nullptr;
    require(gGipa(gInstance,name,&function) == XR_SUCCESS && function,name);
    return reinterpret_cast<Function>(function);
}
#include "lifecycle_checks.hpp"
#include "input_checks.hpp"
#include <array>
#include "reference_origin_checks.hpp"
#include "time_snapshot_checks.hpp"
#include "projection_checks.hpp"
#include "prior_staging_checks.hpp"
#include "transfer_stats.h"
struct Fixture {
    std::wstring path;
    halliday::Header* header = nullptr;
    HANDLE stop = nullptr, worker = nullptr;
    static DWORD WINAPI pulse(void* context) {
        auto* self = static_cast<Fixture*>(context);
        while (WaitForSingleObject(self->stop,11) == WAIT_TIMEOUT)
            self->header->vsync.fetch_add(1);
        return 0;
    }
    explicit Fixture(const wchar_t* name) : path(name) {
        std::wstring normalized = path;
        for (auto& c : normalized) { if (c == L'/') c = L'\\'; c = std::towlower(c); }
        require(normalized.find(L"\\windows-openxr\\build\\tests\\") != std::wstring::npos &&
            normalized.find(L"..") == std::wstring::npos,"fixture must be inside windows-openxr/build/tests");
        HANDLE file = CreateFileW(path.c_str(),GENERIC_READ|GENERIC_WRITE,
            FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        require(file != INVALID_HANDLE_VALUE,"create NEW isolated bridge fixture (never truncate)");
        LARGE_INTEGER bytes{}; bytes.QuadPart = halliday::kFileBytes;
        require(SetFilePointerEx(file,bytes,nullptr,FILE_BEGIN) && SetEndOfFile(file),"size sparse bridge fixture");
        HANDLE mapping = CreateFileMappingW(file,nullptr,PAGE_READWRITE,0,0,nullptr); CloseHandle(file);
        require(mapping != nullptr,"map fixture");
        void* base = MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,halliday::kFileBytes); CloseHandle(mapping);
        require(base != nullptr,"view fixture");
        header = new (base) halliday::Header{};
        header->magic = halliday::kMagic; header->version = halliday::kVersion;
        header->eyeWidth = header->eyeHeight = 64; header->displayHz = 90; header->ipd = .064f;
        for (auto& fov : header->tangents) { fov[0] = fov[3] = -1; fov[1] = fov[2] = 1; }
        header->state.head.valid = 1; header->state.head.position[1] = 1.6f;
        header->state.head.orientation[3] = 1; header->state.head.stamp = 42;
        for (unsigned hand = 0; hand < 2; ++hand) {
            auto& c = header->state.controllers[hand]; c.connected = c.pose.valid = 1;
            c.pose.orientation[3] = 1; c.pose.position[0] = hand ? .2f : -.2f;
            c.pose.position[1] = 1.2f; c.pose.position[2] = -.4f; c.axes[1][0] = .75f;
        }
        auto* haptics = new (reinterpret_cast<uint8_t*>(header) + halliday::haptics::kOffset) halliday::haptics::Extension{};
        haptics->magic = halliday::haptics::kMagic; haptics->version = halliday::haptics::kVersion;
        haptics->clockNs.store(1'000'000'000);
        halliday::focus::initialize(header);
        projection_checks::initialize(header);
        header->alive.store(1); header->stateSeq.store(2); header->vsync.store(1);
        header->intervalNs.store(11'111'111);
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH",path.c_str());
        stop = CreateEventW(nullptr,TRUE,FALSE,nullptr);
        worker = CreateThread(nullptr,0,pulse,this,0,nullptr);
        require(stop && worker,"start deterministic host frame clock");
    }
    ~Fixture() {
        if (stop) SetEvent(stop);
        if (worker) { WaitForSingleObject(worker,INFINITE); CloseHandle(worker); }
        if (stop) CloseHandle(stop);
        if (header) { header->alive.store(0); UnmapViewOfFile(header); }
        DeleteFileW(path.c_str());
    }
};

int wmain(int argc,wchar_t** argv) {
    require(argc >= 2,"usage: runtime_smoke.exe DLL_PATH [NEW_BRIDGE_PATH]");
    HMODULE runtime = LoadLibraryW(argv[1]); require(runtime != nullptr,"load runtime DLL");
    auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(
        GetProcAddress(runtime,"xrNegotiateLoaderRuntimeInterface"));
    require(negotiate != nullptr,"unmangled runtime negotiation export");
    XrNegotiateLoaderInfo info{}; info.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
    info.structVersion = XR_LOADER_INFO_STRUCT_VERSION; info.structSize = sizeof(info);
    info.minInterfaceVersion = info.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    info.minApiVersion = XR_MAKE_VERSION(1,0,0); info.maxApiVersion = XR_MAKE_VERSION(1,1,0);
    XrNegotiateRuntimeRequest request{}; request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
    request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION; request.structSize = sizeof(request);
    require(negotiate(&info,&request) == XR_SUCCESS && request.getInstanceProcAddr,"negotiate OpenXR 1.0");
    require(negotiate(nullptr,&request) == XR_ERROR_INITIALIZATION_FAILED,"reject invalid loader negotiation");
    gGipa = request.getInstanceProcAddr;
    PFN_xrVoidFunction absent = reinterpret_cast<PFN_xrVoidFunction>(1);
    require(gGipa(XR_NULL_HANDLE,"xrNoSuchCommand",&absent) < 0 && !absent,"reject unknown function and clear output");
    if (argc == 2) { std::puts("PASS: Windows runtime ABI negotiation (graphics/session not tested)"); FreeLibrary(runtime); return 0; }

    printProvider(L"d3d11.dll","d3d11");
    printProvider(L"dxgi.dll","dxgi");
    auto enumerate = load<PFN_xrEnumerateInstanceExtensionProperties>("xrEnumerateInstanceExtensionProperties");
    uint32_t count = 0; require(enumerate(nullptr,0,&count,nullptr) == XR_SUCCESS,"enumerate graphics extensions");
    std::vector<XrExtensionProperties> extensions(count,{XR_TYPE_EXTENSION_PROPERTIES});
    require(enumerate(nullptr,count,&count,extensions.data()) == XR_SUCCESS,"read graphics extensions");
    bool d3d11 = false;
    for (const auto& extension : extensions) {
        if (!std::strcmp(extension.extensionName,XR_KHR_D3D11_ENABLE_EXTENSION_NAME)) d3d11 = true;
    }
    require(d3d11,"D3D11 create/copy/readback capability probe");
    const char* enabled[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(create.applicationInfo.applicationName,"Halliday isolated D3D11 smoke");
    create.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,0);
    create.enabledExtensionCount = 1; create.enabledExtensionNames = enabled;
    auto createInstance = load<PFN_xrCreateInstance>("xrCreateInstance");
    require(createInstance(&create,&gInstance) == XR_SUCCESS,"create OpenXR instance");
    absent = nullptr;
    require(gGipa(gInstance,"xrGetD3D12GraphicsRequirementsKHR",&absent) == XR_ERROR_FUNCTION_UNSUPPORTED && !absent,
        "D3D12 commands stay unavailable when the application enables only D3D11");
    XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
    require(load<PFN_xrGetInstanceProperties>("xrGetInstanceProperties")(gInstance,&properties) == XR_SUCCESS &&
        std::strstr(properties.runtimeName,"Halliday"),"Halliday runtime identity");
    Fixture fixture(argv[2]);
    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO}; systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = 0; require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance,&systemInfo,&system) == XR_SUCCESS,"get stereo system");
    XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
    require(load<PFN_xrGetD3D11GraphicsRequirementsKHR>("xrGetD3D11GraphicsRequirementsKHR")(gInstance,system,&requirements) == XR_SUCCESS,"D3D11 adapter requirements");
    IDXGIFactory1* factory = nullptr;
    require(SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),reinterpret_cast<void**>(&factory))),"DXGI factory");
    IDXGIAdapter1* adapter = nullptr;
    for (UINT index = 0; factory->EnumAdapters1(index,&adapter) == S_OK; ++index) {
        DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc);
        if (desc.AdapterLuid.LowPart == requirements.adapterLuid.LowPart &&
            desc.AdapterLuid.HighPart == requirements.adapterLuid.HighPart) break;
        adapter->Release(); adapter = nullptr;
    }
    factory->Release(); require(adapter != nullptr,"find required DXGI adapter");
    ID3D11Device* device = nullptr; ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    const HRESULT made = D3D11CreateDevice(adapter,D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        &level,1,D3D11_SDK_VERSION,&device,nullptr,&context);
    adapter->Release(); require(SUCCEEDED(made),"create application's D3D11 device");
    XrGraphicsBindingD3D11KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR}; binding.device = device;
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; sessionInfo.next = &binding; sessionInfo.systemId = system;
    auto createSession = load<PFN_xrCreateSession>("xrCreateSession");
    auto destroySession = load<PFN_xrDestroySession>("xrDestroySession");
    XrSession session = XR_NULL_HANDLE;
    fixture.header->alive.store(0);
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE,
        "missing Halliday host fails session creation honestly");
    fixture.header->alive.store(1);
    fixture.header->clientPid = 999999; fixture.header->initialized.store(1);
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE &&
        fixture.header->initialized.load() == 1 && fixture.header->clientPid == 999999,
        "unknown foreign PID is not proof of death and cannot be evicted through Wine");
    fixture.header->initialized.store(UINT32_MAX);
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE &&
        fixture.header->initialized.load() == UINT32_MAX,"native initialization lease stays busy without PID/name mutation");
    fixture.header->initialized.store(0);
    require(createSession(gInstance,&sessionInfo,&session) == XR_SUCCESS,"connect to isolated bridge host");
    if (std::getenv("HALLIDAY_CHECK_INSTANCE_ONLY")) {
        require(destroySession(session)==XR_SUCCESS,"release initial instance-race setup session");
        session_teardown_checks::run(runtime,gGipa,gInstance,sessionInfo);
    instance_teardown_checks::run(runtime,gGipa,gInstance,sessionInfo);
        context->Release();device->Release();FreeLibrary(runtime);
        std::puts("PASS: real D3D11 instance-teardown public-API concurrency regression");
        return 0;
    }
    const auto pathFor = [](const char* name) {
        XrPath path = XR_NULL_PATH;
        require(load<PFN_xrStringToPath>("xrStringToPath")(gInstance,name,&path) == XR_SUCCESS,"create action path");
        return path;
    };
    const XrPath leftHand = pathFor("/user/hand/left");
    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    std::strcpy(setInfo.actionSetName,"smoke"); std::strcpy(setInfo.localizedActionSetName,"Smoke controls");
    XrActionSet actionSet = XR_NULL_HANDLE;
    require(load<PFN_xrCreateActionSet>("xrCreateActionSet")(gInstance,&setInfo,&actionSet) == XR_SUCCESS,"create action set");
    XrActionCreateInfo actionInfo{XR_TYPE_ACTION_CREATE_INFO};
    actionInfo.countSubactionPaths = 1; actionInfo.subactionPaths = &leftHand;
    actionInfo.actionType = XR_ACTION_TYPE_FLOAT_INPUT;
    std::strcpy(actionInfo.actionName,"trigger"); std::strcpy(actionInfo.localizedActionName,"Trigger");
    XrAction trigger = XR_NULL_HANDLE, gripPose = XR_NULL_HANDLE;
    auto createAction = load<PFN_xrCreateAction>("xrCreateAction");
    require(createAction(actionSet,&actionInfo,&trigger) == XR_SUCCESS,"create trigger action");
    actionInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
    std::strcpy(actionInfo.actionName,"grip_pose"); std::strcpy(actionInfo.localizedActionName,"Grip pose");
    require(createAction(actionSet,&actionInfo,&gripPose) == XR_SUCCESS,"create hand pose action");
    const auto extra = input_checks::create(actionSet);
    input_checks::rejectWrongType(extra);
    input_checks::suggestSimple(extra); // Simple first, Touch second.
    std::vector<XrActionSuggestedBinding> bindings = {
        {trigger,pathFor("/user/hand/left/input/trigger/value")},
        {gripPose,pathFor("/user/hand/left/input/grip/pose")}};
    input_checks::append(extra,bindings,false);
    input_checks::incrementalParents(extra,bindings);
    XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
    attach.countActionSets = 1; attach.actionSets = &actionSet;
    require(load<PFN_xrAttachSessionActionSets>("xrAttachSessionActionSets")(session,&attach) == XR_SUCCESS,"attach actions");
    XrActionSpaceCreateInfo actionSpaceInfo{XR_TYPE_ACTION_SPACE_CREATE_INFO};
    actionSpaceInfo.action = gripPose; actionSpaceInfo.subactionPath = leftHand;
    actionSpaceInfo.poseInActionSpace.orientation.w = 1;
    XrSpace handSpace = XR_NULL_HANDLE;
    require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&actionSpaceInfo,&handSpace) == XR_SUCCESS,"create hand action space");
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(load<PFN_xrBeginSession>("xrBeginSession")(session,&begin) == XR_SUCCESS,"begin stereo session");
    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE; spaceInfo.poseInReferenceSpace.orientation.w = 1;
    XrSpace stage = XR_NULL_HANDLE;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&spaceInfo,&stage) == XR_SUCCESS,"create floor space");
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    XrSpace local = XR_NULL_HANDLE;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&spaceInfo,&local) == XR_SUCCESS,"create head-origin LOCAL projection space");
    if (std::getenv("HALLIDAY_CHECK_PRIOR_STAGING_ONLY")) {
        prior_staging_checks::run(gGipa,gInstance,session,stage,context,fixture.header);
        const auto statsFn=reinterpret_cast<uint32_t(__cdecl*)(HallidayTransferStats*,uint32_t)>(GetProcAddress(runtime,"hallidayGetTransferStats"));
        HallidayTransferStats stats{};
        require(statsFn&&statsFn(&stats,sizeof(stats))&&stats.peakFramesInFlight==2u&&!stats.failedTransfers,
            "automatic staging has two in-flight pairs and no failed/stale publications");
        require(load<PFN_xrRequestExitSession>("xrRequestExitSession")(session) == XR_SUCCESS,"request opt-in fixture exit");
        lifecycle_checks::states(session);
        require(load<PFN_xrEndSession>("xrEndSession")(session) == XR_SUCCESS,"end opt-in session");
        for (auto space : {handSpace,stage,local}) require(load<PFN_xrDestroySpace>("xrDestroySpace")(space) == XR_SUCCESS,"release opt-in space");
        require(destroySession(session) == XR_SUCCESS && fixture.header->initialized.load()==0,"release opt-in producer/session");
        require(load<PFN_xrDestroyActionSet>("xrDestroyActionSet")(actionSet) == XR_SUCCESS,"release opt-in actions");
        require(load<PFN_xrDestroyInstance>("xrDestroyInstance")(gInstance) == XR_SUCCESS,"release opt-in instance");
        context->Release();device->Release();FreeLibrary(runtime);
        std::puts("PASS: actual D3D11 automatic prior staging, exact frame pairing and normal cleanup (no headset)");
        return 0;
    }
    if (std::getenv("HALLIDAY_CHECK_INPUT_ONLY")) {
        lifecycle_checks::states(session);
        input_checks::aggregateInputs(session,actionSet,extra,fixture.header);
        input_checks::analogTrigger(session,actionSet,extra,fixture.header);
        input_checks::parentInputs(session,actionSet,extra,stage,fixture.header);
        input_checks::commonReferencePosition(session,fixture.header);
        require(load<PFN_xrRequestExitSession>("xrRequestExitSession")(session) == XR_SUCCESS,"request input-only fixture exit");
        lifecycle_checks::states(session);
        require(load<PFN_xrEndSession>("xrEndSession")(session) == XR_SUCCESS,"end input-only session");
        for (auto space : {handSpace,stage,local})
            require(load<PFN_xrDestroySpace>("xrDestroySpace")(space) == XR_SUCCESS,"release input-only space");
        require(destroySession(session) == XR_SUCCESS,"release input-only session");
        require(load<PFN_xrDestroyActionSet>("xrDestroyActionSet")(actionSet) == XR_SUCCESS,"release input-only action handles");
        require(load<PFN_xrDestroyInstance>("xrDestroyInstance")(gInstance) == XR_SUCCESS,"release input-only instance");
        context->Release();device->Release();FreeLibrary(runtime);
        std::puts("PASS: real D3D11 input-only aggregation contract (graphics pixels not tested)");
        return 0;
    }
    XrSwapchainCreateInfo chainInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    chainInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    chainInfo.format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB; chainInfo.sampleCount = chainInfo.faceCount = chainInfo.mipCount = 1;
    chainInfo.width = 80; chainInfo.height = 72; chainInfo.arraySize = 2;
    XrSwapchain chain = XR_NULL_HANDLE;
    chainInfo.usageFlags |= XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT;
    require(load<PFN_xrCreateSwapchain>("xrCreateSwapchain")(session,&chainInfo,&chain) == XR_SUCCESS,"create mutable D3D11 array swapchain with true typeless backing");
    uint32_t imageCount = 0;
    auto enumerateImages = load<PFN_xrEnumerateSwapchainImages>("xrEnumerateSwapchainImages");
    require(enumerateImages(chain,0,&imageCount,nullptr) == XR_SUCCESS && imageCount == 3,"three real swapchain images");
    std::vector<XrSwapchainImageD3D11KHR> images(imageCount,{XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR});
    require(enumerateImages(chain,imageCount,&imageCount,reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data())) == XR_SUCCESS,"enumerate D3D11 textures");
    D3D11_TEXTURE2D_DESC storage{}; images[0].texture->GetDesc(&storage);
    require(storage.Format == DXGI_FORMAT_B8G8R8A8_TYPELESS,"mutable BGRA images have genuinely typeless storage");
    XrFrameState frame{XR_TYPE_FRAME_STATE};
    require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame) == XR_SUCCESS && frame.shouldRender,"wait on host frame");
    require(frame.predictedDisplayPeriod > 11'000'000 && frame.predictedDisplayPeriod < 11'200'000,"use host 90 Hz period, not fixed 72 Hz");
    require(load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr) == XR_SUCCESS,"begin frame");
    XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO}; locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locate.displayTime = frame.predictedDisplayTime; locate.space = local;
    XrViewState viewState{XR_TYPE_VIEW_STATE}; XrView views[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}};
    uint32_t viewCount = 0;
    require(load<PFN_xrLocateViews>("xrLocateViews")(session,&locate,&viewState,2,&viewCount,views) == XR_SUCCESS && viewCount == 2,
        "locate calibrated stereo views from host pose");
    require((viewState.viewStateFlags & XR_VIEW_STATE_POSITION_TRACKED_BIT) &&
        std::abs(views[0].pose.position.y) < .0001f &&
        std::abs(views[1].pose.position.x - views[0].pose.position.x - .064f) < .0001f,"host head pose and IPD reach OpenXR");
    uint32_t image = 0;
    XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
    acquire.type = XR_TYPE_FRAME_WAIT_INFO;
    require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,&acquire,&image) == XR_ERROR_VALIDATION_FAILURE && image == UINT32_MAX,
        "invalid non-null acquire structure does not advance the image state");
    require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,nullptr,nullptr) == XR_ERROR_VALIDATION_FAILURE,"null output index is still invalid");
    require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,nullptr,&image) == XR_SUCCESS && image == 0,"acquire image with the public optional NULL info pointer");
    XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = XR_INFINITE_DURATION;
    require(load<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(chain,nullptr) == XR_ERROR_VALIDATION_FAILURE,"wait info stays required and failed call leaves image acquired");
    require(load<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(chain,&wait) == XR_SUCCESS,"wait image");
    for (unsigned eye = 0; eye < 2; ++eye) {
        D3D11_RENDER_TARGET_VIEW_DESC desc{}; desc.Format = eye ? DXGI_FORMAT_B8G8R8A8_UNORM_SRGB : DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2DARRAY; desc.Texture2DArray.ArraySize = 1;
        desc.Texture2DArray.FirstArraySlice = eye;
        ID3D11RenderTargetView* target = nullptr;
        require(SUCCEEDED(device->CreateRenderTargetView(images[image].texture,&desc,&target)),"create actual linear and sRGB typed views of mutable BGRA array");
        const float red[4]{1,0,0,1}, green[4]{0,1,0,1};
        context->ClearRenderTargetView(target,eye ? green : red); target->Release();
    }
    XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    release.type = XR_TYPE_FRAME_WAIT_INFO;
    require(load<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(chain,&release) == XR_ERROR_VALIDATION_FAILURE,"invalid non-null release structure leaves image waited");
    require(load<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(chain,nullptr) == XR_SUCCESS,"release rendered image with the public optional NULL info pointer");
    XrCompositionLayerProjectionView projectionViews[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    for (unsigned eye = 0; eye < 2; ++eye) {
        auto& view = projectionViews[eye]; view.pose = views[eye].pose; view.fov = views[eye].fov;
        view.subImage.swapchain = chain; view.subImage.imageArrayIndex = eye; view.subImage.imageRect = {{8,4},{64,64}};
    }
    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    projection.space = local; projection.viewCount = 2; projection.views = projectionViews;
    const XrCompositionLayerBaseHeader* layers[] = {reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime = frame.predictedDisplayTime;
    end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE; end.layerCount = 1; end.layers = layers;
    bool havePriorProjection = false;
    int64_t priorProjectionDisplayTime = 0;
    XrCompositionLayerProjectionView priorProjectionViews[2]{};
    auto submitProjectionPair = [&] {
        const auto before = fixture.header->clientFrames.load();
        const auto latest = fixture.header->latest.load();
        end.displayTime = frame.predictedDisplayTime;
        const int64_t submittedDisplayTime = end.displayTime;
        require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_SUCCESS,
            "submit D3D11 projection with changing pose/FOV");
        if (!havePriorProjection) {
            require(fixture.header->clientFrames.load() == before && fixture.header->latest.load() == latest,
                "first D3D11 projection warms without a fabricated publication");
        } else {
            require(fixture.header->clientFrames.load() == before+1,
                "changing D3D11 FOV does not starve the prior capture");
            XrCompositionLayerProjectionView oldWorld[2]{priorProjectionViews[0],priorProjectionViews[1]};
            for (auto& view:oldWorld) view.pose.position.y+=1.6f;
            projection_checks::verify(fixture.header,oldWorld);
            source_timing_checks::verify(fixture.header,priorProjectionDisplayTime);
            const auto oldSlot=fixture.header->latest.load();const auto& old=fixture.header->frames[oldSlot-1];
            require(old.width==64&&old.height==64&&old.pose.stamp==42&&old.bgra==1,
                "older D3D11 pixels retain their own drawn pose and layout while FOV changes");
            for(unsigned eye=0;eye<2;++eye) {
                const auto* pixels=reinterpret_cast<const uint8_t*>(fixture.header)+halliday::imageOffset(oldSlot-1,eye);
                for(size_t pixel=0;pixel<64*64;++pixel)
                    require(pixels[pixel*4]==0&&pixels[pixel*4+1]==(eye?255:0)&&
                        pixels[pixel*4+2]==(eye?0:255)&&pixels[pixel*4+3]==255,
                        "every earlier D3D11 source pixel stays paired with the earlier FOV");
            }
        }
        require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame) == XR_SUCCESS &&
            load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr) == XR_SUCCESS,
            "begin next D3D11 capture of the same rendered image");
        end.displayTime = frame.predictedDisplayTime;
        const int64_t nextCaptureDisplayTime = end.displayTime;
        require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_SUCCESS &&
            fixture.header->clientFrames.load() == before+(havePriorProjection?2u:1u),
            "publish exactly the preceding D3D11 image and complete projection packet");
        source_timing_checks::verify(fixture.header,submittedDisplayTime);
        priorProjectionDisplayTime = nextCaptureDisplayTime;
        std::copy(std::begin(projectionViews),std::end(projectionViews),std::begin(priorProjectionViews));
        havePriorProjection=true;
    };
    projection_checks::oldPeerD3D(gGipa,gInstance,session,fixture.header,projection,frame);
    submitProjectionPair();
    auto verifyGeometry=[&] {
        XrCompositionLayerProjectionView world[2]{projectionViews[0],projectionViews[1]};
        // The independent LOCAL origin was captured at floor height 1.6 m.
        for(auto& view:world)view.pose.position.y+=1.6f;
        projection_checks::verify(fixture.header,world);
    };
    verifyGeometry();
    const uint32_t slot = fixture.header->latest.load(); require(slot > 0,"native host receives published frame");
    const auto& received = fixture.header->frames[slot-1];
    require(halliday::frameColorSpace(received.textureType,0) == 2 && halliday::frameColorSpace(received.textureType,1) == 2,
        "mutable storage keeps requested sRGB compositor transfer tags");
    const bool expectedBgra = chainInfo.format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
    require(received.width == 64 && received.height == 64 && received.pose.stamp == 42 && received.bgra == unsigned(expectedBgra),
        "frame crop, color order and drawn pose stamp survive transfer");
    require(std::fabs(received.pose.position[1]-1.6f)<.0001f,"LOCAL projection is converted back to the host floor frame exactly once");
    const auto* base = reinterpret_cast<const uint8_t*>(fixture.header);
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto* pixels = base + halliday::imageOffset(slot-1,eye);
        for (size_t pixel = 0; pixel < 64*64; ++pixel)
            require(pixels[pixel*4+(expectedBgra?0:2)] == 0 && pixels[pixel*4+1] == (eye ? 255 : 0) &&
                pixels[pixel*4+(expectedBgra?2:0)] == (eye ? 0 : 255) && pixels[pixel*4+3] == 255,"exact D3D11-rendered eye pixels in native byte order");
    }
    // Solid source colors make this a lossless transfer oracle even for cameras
    // intentionally different from the calibrated LocateViews recommendation.
    for(unsigned phase=0;phase<2;++phase) {
        require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame)==XR_SUCCESS&&
            load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr)==XR_SUCCESS,"begin custom D3D11 geometry frame");
        for(unsigned eye=0;eye<2;++eye) {
            auto& view=projectionViews[eye];view.pose=views[eye].pose;
            view.pose.position.x+=eye?.013f:-.013f;
            view.pose.position.y+=eye?-.007f:.007f;
            view.pose.position.z+=eye?-.011f:.011f;
            view.fov={eye?-.53f:-.61f,eye?.69f:.74f,eye?.62f:.71f,eye?-.72f:-.57f};
            if(eye)view.pose.orientation={0,std::sin(.09f),0,std::cos(.09f)};
            if(phase&&eye==0)std::swap(view.fov.angleLeft,view.fov.angleRight);
            if(phase&&eye==1)std::swap(view.fov.angleUp,view.fov.angleDown);
        }
        submitProjectionPair();
        verifyGeometry();
        const auto customSlot=fixture.header->latest.load();
        require(fixture.header->frames[customSlot-1].bgra==unsigned(expectedBgra),"custom D3D11 camera retains native byte order");
        for(unsigned eye=0;eye<2;++eye) {
            const auto* pixels=base+halliday::imageOffset(customSlot-1,eye);
            for(size_t pixel=0;pixel<64*64;++pixel)
                require(pixels[pixel*4+(expectedBgra?0:2)]==0&&pixels[pixel*4+1]==(eye?255:0)&&pixels[pixel*4+(expectedBgra?2:0)]==(eye?0:255)&&pixels[pixel*4+3]==255,
                    "custom D3D11 geometry preserves every ordinary source pixel");
        }
    }
    require(fixture.header->clientFrames.load()==6,"D3D11 initial warmup, animated-FOV prior frames/drains and old-host compatibility publish exactly");
    std::puts("CHECK PASS: D3D11 raw HLPG default/custom/canted/mirrored cameras, exact LOCAL-to-world poses and pixels");
    XrActiveActionSet activeSet{actionSet,XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO}; sync.countActiveActionSets = 1; sync.activeActionSets = &activeSet;
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,"sync focused Halliday controls");
    XrActionStateGetInfo query{XR_TYPE_ACTION_STATE_GET_INFO}; query.action = trigger; query.subactionPath = leftHand;
    XrActionStateFloat triggerState{XR_TYPE_ACTION_STATE_FLOAT};
    require(load<PFN_xrGetActionStateFloat>("xrGetActionStateFloat")(session,&query,&triggerState) == XR_SUCCESS &&
        triggerState.isActive && std::abs(triggerState.currentState-.75f)<.0001f,"host trigger value reaches OpenXR action");
    XrSpaceLocation handLocation{XR_TYPE_SPACE_LOCATION};
    require(load<PFN_xrLocateSpace>("xrLocateSpace")(handSpace,stage,frame.predictedDisplayTime,&handLocation) == XR_SUCCESS &&
        (handLocation.locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) &&
        std::abs(handLocation.pose.position.x+.2f)<.0001f && std::abs(handLocation.pose.position.y-1.2f)<.0001f,
        "host left-controller pose reaches action space with correct hand identity");
    quad_checks::run(gGipa,gInstance,session,fixture.header,projection,
        projectionViews[0].subImage,projectionViews[1].subImage,
        std::array<uint8_t,4>{0,0,255,255},std::array<uint8_t,4>{0,255,0,255});
    fixture.header->dashboard.store(1);
    require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame) == XR_SUCCESS && !frame.shouldRender,
        "Halliday dashboard pauses game rendering");
    require(load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr) == XR_SUCCESS,"begin dashboard frame");
    XrCompositionLayerBaseHeader quad{};quad.type=XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR;
    const XrCompositionLayerBaseHeader* unsupported[] = {reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad)};
    end.displayTime = frame.predictedDisplayTime; end.layers = unsupported;
    require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_ERROR_LAYER_INVALID,"unsupported extension layer is rejected honestly");
    end.layerCount = 0; end.layers = nullptr;
    require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_SUCCESS,"finish dashboard frame without projection");
    projection_checks::absent(fixture.header);
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SESSION_NOT_FOCUSED,"dashboard takes action focus");
    fixture.header->dashboard.store(0);
    lifecycle_checks::states(session);
    time_snapshot_checks::run(session,stage,actionSet,extra,fixture.header);
    reference_origin_checks::run(session,stage,frame.predictedDisplayTime,fixture.header,actionSet,extra);
    input_checks::run(session,actionSet,extra,stage,frame.predictedDisplayTime,fixture.header);
    lifecycle_checks::dashboardAndExit(session,fixture.header,sync,gripPose,leftHand);
    require(load<PFN_xrDestroySwapchain>("xrDestroySwapchain")(chain) == XR_SUCCESS,"destroy swapchain");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(handSpace) == XR_SUCCESS,"destroy action space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(stage) == XR_SUCCESS,"destroy reference space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(local) == XR_SUCCESS,"destroy LOCAL projection space");
    require(destroySession(session) == XR_SUCCESS && fixture.header->initialized.load() == 0,"session cleanup releases bridge ownership");
    lifecycle_checks::hostLoss(sessionInfo,fixture.header);
    lifecycle_checks::readyHostQuit(sessionInfo,fixture.header);
    input_checks::simpleOnly(sessionInfo,fixture.header);
    fixture.header->alive.store(0);
    require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance,&systemInfo,&system) == XR_ERROR_FORM_FACTOR_UNAVAILABLE,
        "closed host is unavailable");
    const std::wstring restartPath = std::wstring(argv[2]) + L".restart";
    Fixture restarted(restartPath.c_str());
    require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance,&systemInfo,&system) == XR_SUCCESS,
        "a restarted host replaces the cached dead bridge mapping");
    session_teardown_checks::run(runtime,gGipa,gInstance,sessionInfo);
    instance_teardown_checks::run(runtime,gGipa,gInstance,sessionInfo);
    context->Release(); device->Release(); FreeLibrary(runtime);
    std::puts("PASS: real D3D11 stereo pixels, host head/controller poses and actions, dashboard focus, unsupported layers, session cleanup (no headset)");
}
