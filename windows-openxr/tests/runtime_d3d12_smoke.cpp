// Real D3D12 application-queue rendering into the Windows OpenXR/Halliday bridge.
// Uses a NEW isolated synthetic host; never opens a game or changes a registry value.
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include "bridge_layout.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cwctype>
#include <new>
#include <string>
#include <vector>

static void require(bool valid, const char* message) {
    if (!valid) {
        std::fprintf(stderr,"FAIL: %s (Windows error %lu)\n",message,GetLastError());
        std::exit(1);
    }
}
static PFN_xrGetInstanceProcAddr gGipa = nullptr;
static XrInstance gInstance = XR_NULL_HANDLE;
template <typename Function> static Function load(const char* name) {
    PFN_xrVoidFunction function = nullptr;
    require(gGipa(gInstance,name,&function) == XR_SUCCESS && function,name);
    return reinterpret_cast<Function>(function);
}
#include "lifecycle_checks.hpp"
#include "input_checks.hpp"
#include <array>
#include "reference_origin_checks.hpp"
#include "time_snapshot_checks.hpp"
#include "quad_checks.hpp"
#include "projection_checks.hpp"

// Identify the actual mapped graphics provider. A friendly backend label, Vulkan adapter
// enumeration, or the presence of d3d12core alone does not distinguish Apple Metal from Wine.
static void fingerprintD3D12() {
    const auto* base = reinterpret_cast<const uint8_t*>(GetModuleHandleW(L"d3d12.dll"));
    require(base != nullptr,"D3D12 provider module is loaded");
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    require(dos->e_magic == IMAGE_DOS_SIGNATURE,"D3D12 provider has PE DOS header");
    const auto* pe = reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    require(pe->Signature == IMAGE_NT_SIGNATURE && pe->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC,
        "D3D12 provider has a 64-bit PE header");
    const IMAGE_SECTION_HEADER* text = nullptr;
    const auto* sections = IMAGE_FIRST_SECTION(pe);
    for (unsigned i = 0; i < pe->FileHeader.NumberOfSections; ++i)
        if (!std::memcmp(sections[i].Name,".text\0",6)) { text = &sections[i]; break; }
    require(text != nullptr && text->VirtualAddress+text->Misc.VirtualSize <= pe->OptionalHeader.SizeOfImage,
        "D3D12 provider text section is bounded");
    std::vector<uint8_t> code(base+text->VirtualAddress,base+text->VirtualAddress+text->Misc.VirtualSize);
    const uint64_t delta = reinterpret_cast<uintptr_t>(base)-pe->OptionalHeader.ImageBase;
    const auto& relocations = pe->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
    size_t offset = 0;
    while (relocations.VirtualAddress && offset+sizeof(IMAGE_BASE_RELOCATION) <= relocations.Size) {
        const auto* block = reinterpret_cast<const IMAGE_BASE_RELOCATION*>(base+relocations.VirtualAddress+offset);
        require(block->SizeOfBlock >= sizeof(*block) && offset+block->SizeOfBlock <= relocations.Size,
            "D3D12 provider relocation block is bounded");
        const auto* fixups = reinterpret_cast<const uint16_t*>(block+1);
        const size_t count = (block->SizeOfBlock-sizeof(*block))/sizeof(uint16_t);
        for (size_t i = 0; i < count; ++i) {
            const unsigned type = fixups[i] >> 12;
            const size_t rva = block->VirtualAddress+(fixups[i]&0xfff);
            if (rva < text->VirtualAddress) continue;
            const size_t at = rva-text->VirtualAddress;
            if (type == IMAGE_REL_BASED_DIR64 && at+8 <= code.size()) {
                uint64_t value; std::memcpy(&value,code.data()+at,8); value -= delta;
                std::memcpy(code.data()+at,&value,8);
            } else if (type == IMAGE_REL_BASED_HIGHLOW && at+4 <= code.size()) {
                uint32_t value; std::memcpy(&value,code.data()+at,4); value -= static_cast<uint32_t>(delta);
                std::memcpy(code.data()+at,&value,4);
            }
        }
        offset += block->SizeOfBlock;
    }
    uint64_t hash = 14695981039346656037ULL;
    for (uint8_t byte : code) { hash ^= byte; hash *= 1099511628211ULL; }
    std::printf("PROVIDER d3d12.dll stamp=%08lx image=%08lx text_bytes=%08lx text_fnv64=%016llx\n",
        pe->FileHeader.TimeDateStamp,pe->OptionalHeader.SizeOfImage,text->Misc.VirtualSize,
        static_cast<unsigned long long>(hash));
    std::fflush(stdout);
}

struct Fixture {
    std::wstring path;
    halliday::Header* header = nullptr;
    HANDLE stop = nullptr, worker = nullptr;
    static DWORD WINAPI pulse(void* context) {
        auto* self = static_cast<Fixture*>(context);
        while (WaitForSingleObject(self->stop,11) == WAIT_TIMEOUT) self->header->vsync.fetch_add(1);
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
            auto& controller = header->state.controllers[hand];
            controller.connected = controller.pose.valid = 1;
            controller.pose.orientation[3] = 1;
            controller.pose.position[0] = hand ? .2f : -.2f;
            controller.pose.position[1] = 1.2f; controller.pose.position[2] = -.4f;
            controller.axes[1][0] = hand ? .25f : .75f;
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

int wmain(int argc, wchar_t** argv) {
    const bool useLoader = argc == 4 && !std::wcscmp(argv[1],L"--loader");
    require(useLoader || argc == 3,"usage: runtime_d3d12_smoke.exe [--loader] DLL_PATH NEW_BRIDGE_PATH");
    const wchar_t* modulePath = argv[useLoader ? 2 : 1];
    const wchar_t* fixturePath = argv[useLoader ? 3 : 2];
    HMODULE runtime = LoadLibraryW(modulePath); require(runtime != nullptr,"load Windows OpenXR module");
    if (useLoader) {
        gGipa = reinterpret_cast<PFN_xrGetInstanceProcAddr>(GetProcAddress(runtime,"xrGetInstanceProcAddr"));
        require(gGipa != nullptr,"actual Khronos loader exports xrGetInstanceProcAddr");
    } else {
        auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(
            GetProcAddress(runtime,"xrNegotiateLoaderRuntimeInterface"));
        require(negotiate != nullptr,"unmangled runtime negotiation export");
        XrNegotiateLoaderInfo loader{}; loader.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
        loader.structVersion = XR_LOADER_INFO_STRUCT_VERSION; loader.structSize = sizeof(loader);
        loader.minInterfaceVersion = loader.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
        loader.minApiVersion = XR_MAKE_VERSION(1,0,0); loader.maxApiVersion = XR_MAKE_VERSION(1,1,0);
        XrNegotiateRuntimeRequest request{}; request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
        request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION; request.structSize = sizeof(request);
        require(negotiate(&loader,&request) == XR_SUCCESS && request.getInstanceProcAddr,"negotiate OpenXR runtime");
        gGipa = request.getInstanceProcAddr;
    }
    auto enumerate = load<PFN_xrEnumerateInstanceExtensionProperties>("xrEnumerateInstanceExtensionProperties");
    uint32_t extensionCount = 0;
    require(enumerate(nullptr,0,&extensionCount,nullptr) == XR_SUCCESS,"count graphics extensions");
    std::vector<XrExtensionProperties> extensions(extensionCount,{XR_TYPE_EXTENSION_PROPERTIES});
    require(enumerate(nullptr,extensionCount,&extensionCount,extensions.data()) == XR_SUCCESS,"read graphics extensions");
    bool available = false;
    for (const auto& extension : extensions)
        if (!std::strcmp(extension.extensionName,XR_KHR_D3D12_ENABLE_EXTENSION_NAME)) available = true;
    require(available,"D3D12 extension passes its actual device/copy/readback capability probe");
    const char* enabled[] = {XR_KHR_D3D12_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(create.applicationInfo.applicationName,"Halliday isolated D3D12 smoke");
    create.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,0);
    create.enabledExtensionCount = 1; create.enabledExtensionNames = enabled;
    require(load<PFN_xrCreateInstance>("xrCreateInstance")(&create,&gInstance) == XR_SUCCESS,"create D3D12 OpenXR instance");
    XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
    require(load<PFN_xrGetInstanceProperties>("xrGetInstanceProperties")(gInstance,&properties) == XR_SUCCESS &&
        std::strstr(properties.runtimeName,"Halliday") != nullptr,"the selected runtime is Halliday");
    Fixture fixture(fixturePath);
    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO}; systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = 0;
    require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance,&systemInfo,&system) == XR_SUCCESS,"get Halliday stereo system");
    XrGraphicsRequirementsD3D12KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR};
    require(load<PFN_xrGetD3D12GraphicsRequirementsKHR>("xrGetD3D12GraphicsRequirementsKHR")(
        gInstance,system,&requirements) == XR_SUCCESS,"get D3D12 adapter requirements");

    IDXGIFactory1* factory = nullptr;
    require(SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1),reinterpret_cast<void**>(&factory))),"create DXGI factory");
    IDXGIAdapter1* adapter = nullptr;
    for (UINT i = 0; factory->EnumAdapters1(i,&adapter) == S_OK; ++i) {
        DXGI_ADAPTER_DESC1 description{}; adapter->GetDesc1(&description);
        if (description.AdapterLuid.LowPart == requirements.adapterLuid.LowPart &&
            description.AdapterLuid.HighPart == requirements.adapterLuid.HighPart) break;
        adapter->Release(); adapter = nullptr;
    }
    factory->Release(); require(adapter != nullptr,"find the runtime's required adapter");
    ID3D12Device* device = nullptr;
    const HRESULT made = D3D12CreateDevice(adapter,requirements.minFeatureLevel,
        __uuidof(ID3D12Device),reinterpret_cast<void**>(&device));
    adapter->Release(); require(SUCCEEDED(made),"create application's real D3D12 device");
    fingerprintD3D12();
    D3D12_COMMAND_QUEUE_DESC queueDescription{}; queueDescription.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    ID3D12CommandQueue* queue = nullptr;
    require(SUCCEEDED(device->CreateCommandQueue(&queueDescription,__uuidof(ID3D12CommandQueue),
        reinterpret_cast<void**>(&queue))),"create application's direct command queue");
    ID3D12CommandAllocator* allocator = nullptr;
    require(SUCCEEDED(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
        __uuidof(ID3D12CommandAllocator),reinterpret_cast<void**>(&allocator))),"create application command allocator");
    ID3D12GraphicsCommandList* commands = nullptr;
    require(SUCCEEDED(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator,nullptr,
        __uuidof(ID3D12GraphicsCommandList),reinterpret_cast<void**>(&commands))),"create application command list");
    require(SUCCEEDED(commands->Close()),"close initial command list");
    D3D12_DESCRIPTOR_HEAP_DESC heapDescription{}; heapDescription.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    heapDescription.NumDescriptors = 2;
    ID3D12DescriptorHeap* targets = nullptr;
    require(SUCCEEDED(device->CreateDescriptorHeap(&heapDescription,__uuidof(ID3D12DescriptorHeap),
        reinterpret_cast<void**>(&targets))),"create eye render-target descriptors");
    ID3D12Fence* appFence = nullptr;
    require(SUCCEEDED(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,__uuidof(ID3D12Fence),
        reinterpret_cast<void**>(&appFence))),"create application completion fence");
    HANDLE appReady = CreateEventW(nullptr,FALSE,FALSE,nullptr); require(appReady != nullptr,"create application fence event");

    XrGraphicsBindingD3D12KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D12_KHR};
    binding.device = device; binding.queue = queue;
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; sessionInfo.next = &binding; sessionInfo.systemId = system;
    auto createSession = load<PFN_xrCreateSession>("xrCreateSession");
    XrSession session = XR_NULL_HANDLE;
    D3D12_COMMAND_QUEUE_DESC computeDescription{}; computeDescription.Type = D3D12_COMMAND_LIST_TYPE_COMPUTE;
    ID3D12CommandQueue* compute = nullptr;
    require(SUCCEEDED(device->CreateCommandQueue(&computeDescription,__uuidof(ID3D12CommandQueue),
        reinterpret_cast<void**>(&compute))),"create non-direct queue for negative binding validation");
    binding.queue = compute;
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_GRAPHICS_DEVICE_INVALID && session == XR_NULL_HANDLE,
        "reject a compute-only queue even with a valid device and live host");
    binding.queue = queue;
    compute->Release();
    fixture.header->alive.store(0);
    const XrResult unavailable = createSession(gInstance,&sessionInfo,&session);
    if (unavailable != XR_ERROR_RUNTIME_FAILURE)
        std::fprintf(stderr,"D3D12 unavailable-host session result: %d (expected %d)\n",unavailable,XR_ERROR_RUNTIME_FAILURE);
    require(unavailable == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE,
        "unavailable host honestly fails D3D12 session creation");
    fixture.header->alive.store(1);
    fixture.header->clientPid = 999999; fixture.header->initialized.store(1);
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE &&
        fixture.header->initialized.load() == 1 && fixture.header->clientPid == 999999,
        "unknown foreign PID is not proof of death and cannot be evicted through Wine");
    fixture.header->initialized.store(UINT32_MAX);
    require(createSession(gInstance,&sessionInfo,&session) == XR_ERROR_RUNTIME_FAILURE && session == XR_NULL_HANDLE &&
        fixture.header->initialized.load() == UINT32_MAX,"native initialization lease stays busy without PID/name mutation");
    fixture.header->initialized.store(0);
    require(createSession(gInstance,&sessionInfo,&session) == XR_SUCCESS,"bind real D3D12 device and application queue");
    const auto pathFor = [](const char* text) {
        XrPath path = XR_NULL_PATH;
        require(load<PFN_xrStringToPath>("xrStringToPath")(gInstance,text,&path) == XR_SUCCESS,"create action path");
        return path;
    };
    XrPath hands[2]{pathFor("/user/hand/left"),pathFor("/user/hand/right")};
    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    std::strcpy(setInfo.actionSetName,"d3d12smoke"); std::strcpy(setInfo.localizedActionSetName,"D3D12 smoke");
    XrActionSet actionSet = XR_NULL_HANDLE;
    require(load<PFN_xrCreateActionSet>("xrCreateActionSet")(gInstance,&setInfo,&actionSet) == XR_SUCCESS,"create action set");
    XrActionCreateInfo actionInfo{XR_TYPE_ACTION_CREATE_INFO};
    actionInfo.countSubactionPaths = 2; actionInfo.subactionPaths = hands; actionInfo.actionType = XR_ACTION_TYPE_POSE_INPUT;
    std::strcpy(actionInfo.actionName,"grip_pose"); std::strcpy(actionInfo.localizedActionName,"Grip pose");
    XrAction grip = XR_NULL_HANDLE;
    require(load<PFN_xrCreateAction>("xrCreateAction")(actionSet,&actionInfo,&grip) == XR_SUCCESS,"create both-hand pose action");
    const auto extra = input_checks::create(actionSet);
    input_checks::rejectWrongType(extra);
    std::vector<XrActionSuggestedBinding> bindings{{grip,pathFor("/user/hand/left/input/grip/pose")},
                                       {grip,pathFor("/user/hand/right/input/grip/pose")}};
    input_checks::append(extra,bindings,false);
    input_checks::incrementalParents(extra,bindings);
    input_checks::suggestSimple(extra); // Touch first, Simple second.
    XrSessionActionSetsAttachInfo attach{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
    attach.countActionSets = 1; attach.actionSets = &actionSet;
    require(load<PFN_xrAttachSessionActionSets>("xrAttachSessionActionSets")(session,&attach) == XR_SUCCESS,"attach hand action set");
    XrSpace handSpaces[2]{XR_NULL_HANDLE,XR_NULL_HANDLE};
    for (unsigned hand = 0; hand < 2; ++hand) {
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO}; info.action = grip; info.subactionPath = hands[hand];
        info.poseInActionSpace.orientation.w = 1;
        require(load<PFN_xrCreateActionSpace>("xrCreateActionSpace")(session,&info,&handSpaces[hand]) == XR_SUCCESS,"create controller action space");
    }
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(load<PFN_xrBeginSession>("xrBeginSession")(session,&begin) == XR_SUCCESS,"begin D3D12 stereo session");
    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_STAGE; spaceInfo.poseInReferenceSpace.orientation.w = 1;
    XrSpace stage = XR_NULL_HANDLE;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&spaceInfo,&stage) == XR_SUCCESS,"create stage space");
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    XrSpace local = XR_NULL_HANDLE;
    require(load<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&spaceInfo,&local) == XR_SUCCESS,"create LOCAL D3D12 projection space");
    XrSwapchainCreateInfo chainInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    chainInfo.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT|XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT|XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
    chainInfo.format = DXGI_FORMAT_R8G8B8A8_UNORM_SRGB; chainInfo.sampleCount = chainInfo.faceCount = chainInfo.mipCount = 1;
    chainInfo.width = 80; chainInfo.height = 72; chainInfo.arraySize = 2;
    XrSwapchain chain = XR_NULL_HANDLE;
    require(load<PFN_xrCreateSwapchain>("xrCreateSwapchain")(session,&chainInfo,&chain) == XR_SUCCESS,"create real D3D12 array swapchain");
    uint32_t imageCount = 0;
    auto enumerateImages = load<PFN_xrEnumerateSwapchainImages>("xrEnumerateSwapchainImages");
    require(enumerateImages(chain,0,&imageCount,nullptr) == XR_SUCCESS && imageCount == 3,"three D3D12 swapchain images");
    std::vector<XrSwapchainImageD3D12KHR> images(imageCount,{XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR});
    require(enumerateImages(chain,imageCount,&imageCount,reinterpret_cast<XrSwapchainImageBaseHeader*>(images.data())) == XR_SUCCESS,
        "enumerate application's D3D12 resources");
    require(images[0].texture->GetDesc().Format == DXGI_FORMAT_R8G8B8A8_TYPELESS,"mutable RGBA D3D12 images have genuinely typeless storage");

    XrTime lastDisplayTime = 0;
    XrCompositionLayerProjectionView lastProjected[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    int64_t priorProjectionDisplayTime=0;
    for (unsigned pass = 0; pass < 3; ++pass) {
        fixture.header->stateSeq.fetch_add(1);
        fixture.header->state.head.position[1] = 1.6f + .1f * pass;
        fixture.header->state.head.stamp = 42.f + pass;
        fixture.header->stateSeq.fetch_add(1);
        XrFrameState frame{XR_TYPE_FRAME_STATE};
        require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame) == XR_SUCCESS && frame.shouldRender,"wait for D3D12 host frame");
        lastDisplayTime = frame.predictedDisplayTime;
        require(frame.predictedDisplayPeriod > 11'000'000 && frame.predictedDisplayPeriod < 11'200'000,"host display timing reaches D3D12 session");
        require(load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr) == XR_SUCCESS,"begin D3D12 frame");
        XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO}; locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        locate.displayTime = frame.predictedDisplayTime; locate.space = local;
        XrViewState viewState{XR_TYPE_VIEW_STATE}; XrView views[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}};
        uint32_t viewCount = 0;
        require(load<PFN_xrLocateViews>("xrLocateViews")(session,&locate,&viewState,2,&viewCount,views) == XR_SUCCESS && viewCount == 2,
            "locate D3D12 stereo views");
        require((viewState.viewStateFlags & XR_VIEW_STATE_POSITION_TRACKED_BIT) &&
            std::abs(views[0].pose.position.y-.1f*pass) < .0001f &&
            std::abs(views[1].pose.position.x-views[0].pose.position.x-.064f) < .0001f,"head pose and IPD remain correct");
        uint32_t image = 0;
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        if (pass == 0) {
            acquire.type = XR_TYPE_FRAME_WAIT_INFO;
            require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,&acquire,&image) == XR_ERROR_VALIDATION_FAILURE && image == UINT32_MAX,
                "invalid non-null acquire structure does not advance D3D12 image state");
            require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,nullptr,nullptr) == XR_ERROR_VALIDATION_FAILURE,"null D3D12 output index remains invalid");
            acquire.type = XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO;
        }
        require(load<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chain,pass % 2 ? &acquire : nullptr,&image) == XR_SUCCESS && image == pass,
            "D3D12 optional NULL/typed acquire info preserves FIFO image state");
        XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = XR_INFINITE_DURATION;
        require(load<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(chain,nullptr) == XR_ERROR_VALIDATION_FAILURE,"D3D12 wait info remains required");
        require(load<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(chain,&wait) == XR_SUCCESS,"wait for D3D12 resource");
        require(image < imageCount && images[image].texture != nullptr,"runtime returns a real D3D12 resource");
        require(SUCCEEDED(allocator->Reset()) && SUCCEEDED(commands->Reset(allocator,nullptr)),"reset application command storage");
        D3D12_CPU_DESCRIPTOR_HANDLE target = targets->GetCPUDescriptorHandleForHeapStart();
        const UINT step = device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        for (unsigned eye = 0; eye < 2; ++eye) {
            D3D12_RENDER_TARGET_VIEW_DESC description{};
            description.Format = (eye+pass)&1 ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
            description.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2DARRAY;
            description.Texture2DArray.ArraySize = 1; description.Texture2DArray.FirstArraySlice = eye;
            device->CreateRenderTargetView(images[image].texture,&description,target);
            const float blue[4]{0,0,1,1}, red[4]{1,0,0,1}, green[4]{0,1,0,1};
            const D3D12_RECT crop{8,4,72,68};
            commands->ClearRenderTargetView(target,blue,0,nullptr);
            commands->ClearRenderTargetView(target,((eye+pass)&1) ? green : red,1,&crop);
            target.ptr += step;
        }
        require(SUCCEEDED(commands->Close()),"close eye rendering commands");
        ID3D12CommandList* submitted[]{commands}; queue->ExecuteCommandLists(1,submitted);
        // Do not CPU-wait here: the runtime must order its copies after these app-queue clears.
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        if (pass == 0) {
            release.type = XR_TYPE_FRAME_WAIT_INFO;
            require(load<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(chain,&release) == XR_ERROR_VALIDATION_FAILURE,
                "invalid non-null release structure does not advance D3D12 image state");
            release.type = XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO;
        }
        require(load<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(chain,pass % 2 ? &release : nullptr) == XR_SUCCESS,
            "D3D12 optional NULL/typed release info preserves submitted image");
        XrCompositionLayerProjectionView projected[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
        for (unsigned eye = 0; eye < 2; ++eye) {
            projected[eye].pose = views[eye].pose; projected[eye].fov = views[eye].fov;
            projected[eye].subImage.swapchain = chain; projected[eye].subImage.imageArrayIndex = eye;
            projected[eye].subImage.imageRect = {{8,4},{64,64}};
            if(pass) {
                projected[eye].pose.position.x+=eye?.013f:-.013f;
                projected[eye].pose.position.y+=eye?-.007f:.007f;
                projected[eye].pose.position.z+=eye?-.011f:.011f;
                projected[eye].fov={eye?-.53f:-.61f,eye?.69f:.74f,eye?.62f:.71f,eye?-.72f:-.57f};
                if(eye)projected[eye].pose.orientation={0,std::sin(.09f),0,std::cos(.09f)};
                if(pass==2&&eye==0)std::swap(projected[eye].fov.angleLeft,projected[eye].fov.angleRight);
                if(pass==2&&eye==1)std::swap(projected[eye].fov.angleUp,projected[eye].fov.angleDown);
            }
        }
        XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        projection.space = local; projection.viewCount = 2; projection.views = projected;
        const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime = frame.predictedDisplayTime;
        end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE; end.layerCount = 1; end.layers = layers;
        if(pass==0) {
            projection_checks::oldPeerD3D(gGipa,gInstance,session,fixture.header,projection,frame);
            end.displayTime=frame.predictedDisplayTime;lastDisplayTime=frame.predictedDisplayTime;
        }
        const auto before = fixture.header->clientFrames.load();
        const int64_t submittedDisplayTime=end.displayTime;
        const auto latest = fixture.header->latest.load();
        require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_SUCCESS,
            "submit D3D12 projection with changing pose/FOV");
        if (!pass) {
            require(fixture.header->clientFrames.load()==before&&fixture.header->latest.load()==latest,
                "first D3D12 projection warms without a fabricated publication");
        } else {
            require(fixture.header->clientFrames.load()==before+1,
                "changing D3D12 FOV does not starve prior capture");
            XrCompositionLayerProjectionView priorWorld[2]{lastProjected[0],lastProjected[1]};
            for(auto& view:priorWorld)view.pose.position.y+=1.6f;
            projection_checks::verify(fixture.header,priorWorld);
            source_timing_checks::verify(fixture.header,priorProjectionDisplayTime);
            const auto oldSlot=fixture.header->latest.load();const auto& old=fixture.header->frames[oldSlot-1];
            require(old.width==64&&old.height==64&&old.pose.stamp==41.f+pass&&old.bgra==0&&
                std::abs(old.pose.position[1]-(1.6f+.1f*(pass-1)))<.0001f,
                "earlier D3D12 pose/layout remain paired while current pose/FOV animate");
            for(unsigned eye=0;eye<2;++eye) {
                const auto* pixels=reinterpret_cast<const uint8_t*>(fixture.header)+halliday::imageOffset(oldSlot-1,eye);
                const bool green=((eye+pass-1)&1)!=0;
                for(size_t pixel=0;pixel<64*64;++pixel)
                    require(pixels[pixel*4]==(green?0:255)&&pixels[pixel*4+1]==(green?255:0)&&
                        pixels[pixel*4+2]==0&&pixels[pixel*4+3]==255,
                        "every prior D3D12 pixel retains the earlier full camera geometry");
            }
        }
        require(load<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame) == XR_SUCCESS &&
            load<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr) == XR_SUCCESS,
            "begin next D3D12 capture of the same rendered image");
        end.displayTime=frame.predictedDisplayTime;lastDisplayTime=frame.predictedDisplayTime;
        priorProjectionDisplayTime=end.displayTime;
        require(load<PFN_xrEndFrame>("xrEndFrame")(session,&end) == XR_SUCCESS &&
            fixture.header->clientFrames.load() == before+(pass?2u:1u),
            "publish exactly the preceding D3D12 image and complete projection packet");
        source_timing_checks::verify(fixture.header,submittedDisplayTime);
        XrCompositionLayerProjectionView world[2]{projected[0],projected[1]};
        for(auto& view:world)view.pose.position.y+=1.6f;
        projection_checks::verify(fixture.header,world);
        const uint32_t slot = fixture.header->latest.load(); require(slot > 0,"host receives D3D12 frame");
        const auto& received = fixture.header->frames[slot-1];
        require(halliday::frameColorSpace(received.textureType,0) == 2 && halliday::frameColorSpace(received.textureType,1) == 2,
            "mutable storage keeps requested sRGB compositor transfer tags");
        const bool expectedBgra = chainInfo.format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
        require(received.width == 64 && received.height == 64 && received.pose.stamp == 42.f+pass && received.bgra == unsigned(expectedBgra) &&
            std::abs(received.pose.position[1]-(1.6f+.1f*pass)) < .0001f,"crop and current drawn pose reach the host");
        const auto* base = reinterpret_cast<const uint8_t*>(fixture.header);
        for (unsigned eye = 0; eye < 2; ++eye) {
            const auto* pixels = base + halliday::imageOffset(slot-1,eye);
            const bool green = ((eye+pass)&1) != 0;
            for (size_t pixel = 0; pixel < 64*64; ++pixel)
                require(pixels[pixel*4+(expectedBgra?0:2)] == 0 && pixels[pixel*4+1] == (green ? 255 : 0) &&
                    pixels[pixel*4+(expectedBgra?2:0)] == (green ? 0 : 255) && pixels[pixel*4+3] == 255,
                    "exact current D3D12 native-order eye pixels, crop offsets and array identities");
        }
        std::copy(std::begin(projected),std::end(projected),std::begin(lastProjected));
        require(SUCCEEDED(device->GetDeviceRemovedReason()),"D3D12 device remains healthy");
        require(SUCCEEDED(queue->Signal(appFence,pass+1)),"signal application's completion fence");
        if (appFence->GetCompletedValue() < pass+1) {
            require(SUCCEEDED(appFence->SetEventOnCompletion(pass+1,appReady)) &&
                WaitForSingleObject(appReady,3000) == WAIT_OBJECT_0,"finish app commands before allocator reuse");
        }
    }

    require(fixture.header->clientFrames.load() == 6,"initial warmup, animated-FOV prior frames/drains and old-host compatibility publish exactly");
    std::puts("CHECK PASS: D3D12 raw HLPG default/custom/canted/mirrored cameras, exact LOCAL-to-world poses and pixels");
    XrCompositionLayerProjection lastProjection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    lastProjection.space=local;lastProjection.viewCount=2;lastProjection.views=lastProjected;
    quad_checks::run(gGipa,gInstance,session,fixture.header,lastProjection,lastProjected[0].subImage,lastProjected[1].subImage,
        std::array<uint8_t,4>{0,0,255,255},std::array<uint8_t,4>{0,255,0,255});

    XrActiveActionSet active{actionSet,XR_NULL_PATH};
    XrActionsSyncInfo sync{XR_TYPE_ACTIONS_SYNC_INFO}; sync.countActiveActionSets = 1; sync.activeActionSets = &active;
    require(load<PFN_xrSyncActions>("xrSyncActions")(session,&sync) == XR_SUCCESS,"sync both controller actions");
    for (unsigned hand = 0; hand < 2; ++hand) {
        XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
        require(load<PFN_xrLocateSpace>("xrLocateSpace")(handSpaces[hand],stage,lastDisplayTime,&location) == XR_SUCCESS &&
            (location.locationFlags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) &&
            std::abs(location.pose.position.x-(hand ? .2f : -.2f)) < .0001f &&
            std::abs(location.pose.position.y-1.2f) < .0001f,"both controller identities and poses remain correct");
    }
    time_snapshot_checks::run(session,stage,actionSet,extra,fixture.header);
    reference_origin_checks::run(session,stage,lastDisplayTime,fixture.header,actionSet,extra);
    input_checks::run(session,actionSet,extra,stage,lastDisplayTime,fixture.header);
    lifecycle_checks::dashboardAndExit(session,fixture.header,sync,grip,hands[0]);
    require(load<PFN_xrDestroySwapchain>("xrDestroySwapchain")(chain) == XR_SUCCESS,"destroy D3D12 swapchain");
    for (XrSpace hand : handSpaces)
        require(load<PFN_xrDestroySpace>("xrDestroySpace")(hand) == XR_SUCCESS,"destroy controller space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(stage) == XR_SUCCESS,"destroy stage space");
    require(load<PFN_xrDestroySpace>("xrDestroySpace")(local) == XR_SUCCESS,"destroy LOCAL D3D12 projection space");
    require(load<PFN_xrDestroySession>("xrDestroySession")(session) == XR_SUCCESS && !fixture.header->initialized.load(),
        "D3D12 session cleanup releases bridge ownership");
    lifecycle_checks::hostLoss(sessionInfo,fixture.header);
    lifecycle_checks::readyHostQuit(sessionInfo,fixture.header);
    input_checks::simpleOnly(sessionInfo,fixture.header);
    require(load<PFN_xrDestroyInstance>("xrDestroyInstance")(gInstance) == XR_SUCCESS,"destroy D3D12 instance");
    CloseHandle(appReady); appFence->Release(); targets->Release(); commands->Release(); allocator->Release();
    queue->Release(); device->Release(); FreeLibrary(runtime);
    if (useLoader)
        std::puts("PASS: actual Khronos loader + real D3D12 app-queue rendering, three swapchain frames, exact cropped stereo pixels, current head/IPD/both-hand poses, clean teardown (no headset)");
    else
        std::puts("PASS: real D3D12 app-queue rendering, three swapchain frames, exact cropped stereo pixels, current head/IPD/both-hand poses, clean teardown (no headset)");
    return 0;
}
