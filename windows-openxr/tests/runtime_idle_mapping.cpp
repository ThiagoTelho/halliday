// Direct OpenXR regression for a host replaced between system queries and
// session creation. Owns two private files; never registers a runtime or game.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include "bridge_layout.hpp"
#include "haptic_bridge.hpp"
#include <cstdio>
#include <cstring>
#include <cwctype>
#include <new>
#include <stdexcept>
#include <string>

static void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
static PFN_xrGetInstanceProcAddr gGipa = nullptr;
static XrInstance gInstance = XR_NULL_HANDLE;
template<class F> F load(const char* name) {
    PFN_xrVoidFunction f = nullptr;
    require(gGipa(gInstance, name, &f) == XR_SUCCESS && f, name);
    return reinterpret_cast<F>(f);
}
struct Fixture {
    std::wstring path;
    halliday::Header* header = nullptr;
    Fixture(const std::wstring& filePath, uint32_t width, uint32_t height) : path(filePath) {
        auto normalized = path;
        for (auto& c : normalized) { if (c == L'/') c = L'\\'; c = std::towlower(c); }
        require(normalized.find(L"\\windows-openxr\\build\\tests\\") != std::wstring::npos &&
            normalized.find(L"..") == std::wstring::npos, "owned fixture path required");
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        require(file != INVALID_HANDLE_VALUE, "create NEW private fixture");
        LARGE_INTEGER bytes{}; bytes.QuadPart = halliday::kFileBytes;
        const bool sized = SetFilePointerEx(file, bytes, nullptr, FILE_BEGIN) && SetEndOfFile(file);
        HANDLE mapping = sized ? CreateFileMappingW(file, nullptr, PAGE_READWRITE, 0, 0, nullptr) : nullptr;
        CloseHandle(file);
        if (!mapping) { DeleteFileW(path.c_str()); require(false, "map private fixture"); }
        void* base = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, halliday::kFileBytes);
        CloseHandle(mapping);
        if (!base) { DeleteFileW(path.c_str()); require(false, "view private fixture"); }
        header = new (base) halliday::Header{};
        header->magic = halliday::kMagic; header->version = halliday::kVersion;
        header->eyeWidth = width; header->eyeHeight = height;
        header->displayHz = 90; header->ipd = .064f;
        for (auto& fov : header->tangents) { fov[0] = fov[3] = -1; fov[1] = fov[2] = 1; }
        header->state.head.valid = 1; header->state.head.orientation[3] = 1;
        header->state.head.position[1] = 1.65f;
        auto* haptics = new (reinterpret_cast<uint8_t*>(header) + halliday::haptics::kOffset)
            halliday::haptics::Extension{};
        haptics->magic = halliday::haptics::kMagic; haptics->version = halliday::haptics::kVersion;
        haptics->clockNs.store(1'000'000'000);
        header->alive.store(1); header->stateSeq.store(2); header->vsync.store(1);
        header->intervalNs.store(11'111'111);
    }
    ~Fixture() {
        if (header) { header->alive.store(0); UnmapViewOfFile(header); }
        DeleteFileW(path.c_str());
    }
};
struct SessionGuard {
    XrSession value = XR_NULL_HANDLE;
    ~SessionGuard() { if (value) load<PFN_xrDestroySession>("xrDestroySession")(value); }
};
static void views(XrSystemId system, uint32_t width, uint32_t height) {
    XrViewConfigurationView v[2]{{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
    uint32_t count = 0;
    require(load<PFN_xrEnumerateViewConfigurationViews>("xrEnumerateViewConfigurationViews")(
        gInstance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &count, v) == XR_SUCCESS,
        "read current bridge view configuration");
    require(count == 2 && v[0].recommendedImageRectWidth == width &&
        v[0].recommendedImageRectHeight == height && v[1].recommendedImageRectWidth == width &&
        v[1].recommendedImageRectHeight == height, "view query uses expected bridge mapping");
}
int wmain(int argc, wchar_t** argv) {
    try {
        require(argc == 3, "usage: runtime_idle_mapping.exe RUNTIME_DLL NEW_FIXTURE_BASE");
        Fixture a(std::wstring(argv[2]) + L"-a.shm", 64, 64);
        Fixture b(std::wstring(argv[2]) + L"-b.shm", 96, 80);
        HMODULE runtime = LoadLibraryW(argv[1]); require(runtime, "load explicit runtime");
        auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(
            GetProcAddress(runtime, "xrNegotiateLoaderRuntimeInterface"));
        require(negotiate, "runtime negotiation export");
        XrNegotiateLoaderInfo info{}; info.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
        info.structVersion = XR_LOADER_INFO_STRUCT_VERSION; info.structSize = sizeof(info);
        info.minInterfaceVersion = info.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
        info.minApiVersion = info.maxApiVersion = XR_MAKE_VERSION(1, 0, 0);
        XrNegotiateRuntimeRequest request{}; request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
        request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION; request.structSize = sizeof(request);
        require(negotiate(&info, &request) == XR_SUCCESS, "negotiate runtime"); gGipa = request.getInstanceProcAddr;
        const char* extension = XR_KHR_D3D11_ENABLE_EXTENSION_NAME;
        XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
        std::strcpy(create.applicationInfo.applicationName, "Halliday idle mapping regression");
        create.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        create.enabledExtensionCount = 1; create.enabledExtensionNames = &extension;
        require(load<PFN_xrCreateInstance>("xrCreateInstance")(&create, &gInstance) == XR_SUCCESS, "create instance");
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", a.path.c_str());
        XrSystemGetInfo query{XR_TYPE_SYSTEM_GET_INFO}; query.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
        XrSystemId system = 0;
        require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance, &query, &system) == XR_SUCCESS, "query original live host");
        views(system, 64, 64);
        require(!a.header->initialized.load() && !b.header->initialized.load(), "queries claim no producer");
        XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
        require(load<PFN_xrGetD3D11GraphicsRequirementsKHR>("xrGetD3D11GraphicsRequirementsKHR")(
            gInstance, system, &requirements) == XR_SUCCESS, "graphics requirements");
        IDXGIFactory1* factory = nullptr; IDXGIAdapter1* adapter = nullptr;
        require(SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory))), "DXGI factory");
        for (UINT i = 0; factory->EnumAdapters1(i, &adapter) == S_OK; ++i) {
            DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc);
            if (desc.AdapterLuid.LowPart == requirements.adapterLuid.LowPart &&
                desc.AdapterLuid.HighPart == requirements.adapterLuid.HighPart) break;
            adapter->Release(); adapter = nullptr;
        }
        factory->Release(); require(adapter, "required adapter");
        ID3D11Device* device = nullptr;
        D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
        HRESULT made = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            &level, 1, D3D11_SDK_VERSION, &device, nullptr, nullptr);
        adapter->Release(); require(SUCCEEDED(made), "create application device");
        // Model replacement by selecting another complete file. A deliberately
        // remains alive=1, exactly like a mapped inode left behind by a crash.
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", b.path.c_str());
        XrGraphicsBindingD3D11KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR}; binding.device = device;
        XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; sessionInfo.next = &binding; sessionInfo.systemId = system;
        {
            SessionGuard session;
            XrResult created = load<PFN_xrCreateSession>("xrCreateSession")(gInstance, &sessionInfo, &session.value);
            device->Release();
            require(created == XR_SUCCESS, "create session after idle host replacement");
            require(b.header->initialized.load() == 1 && !a.header->initialized.load(),
                "new session claims current host B instead of stale alive host A");
            SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", a.path.c_str());
            views(system, 96, 80);
            require(b.header->initialized.load() == 1 && !a.header->initialized.load(),
                "active session remains bound to B despite changed route");
        }
        require(!a.header->initialized.load() && !b.header->initialized.load(), "destroy releases current producer");
        views(system, 64, 64);
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", b.path.c_str());
        views(system, 96, 80);
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", (std::wstring(argv[2]) + L"-missing.shm").c_str());
        XrSystemId absent = 0;
        require(load<PFN_xrGetSystem>("xrGetSystem")(gInstance, &query, &absent) == XR_ERROR_FORM_FACTOR_UNAVAILABLE,
            "idle query cannot resurrect cached alive mapping when current path is absent");
        require(load<PFN_xrDestroyInstance>("xrDestroyInstance")(gInstance) == XR_SUCCESS, "destroy instance");
        gInstance = XR_NULL_HANDLE; FreeLibrary(runtime);
        std::puts("PASS: idle system query remaps replacement host, session claims only current mapping, active mapping stays pinned, missing public path stays unavailable");
        return 0;
    } catch (const std::exception& e) { std::fprintf(stderr, "FAIL: %s\n", e.what()); return 1; }
}
