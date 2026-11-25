// Calls the official Khronos loader's public API, not runtime negotiation directly.
// The runner temporarily registers the manifest only in a disposable bottle, then restores it.
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "bridge_layout.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <memory>
#include <new>
#include <string>
#include <vector>

static void require(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s (Windows error %lu)\n", message, GetLastError());
        std::exit(1);
    }
}

static void success(XrResult result, const char* message) {
    if (result != XR_SUCCESS) {
        std::fprintf(stderr, "FAIL: %s returned XrResult %d\n", message, static_cast<int>(result));
        std::exit(1);
    }
}

static void fixturePath(const wchar_t* path) {
    std::wstring normalized(path);
    for (auto& c : normalized) { if (c == L'/') c = L'\\'; c = std::towlower(c); }
    require(normalized.find(L"\\windows-openxr\\build\\tests\\") != std::wstring::npos &&
            normalized.find(L"..") == std::wstring::npos,
            "bridge path must be an isolated fixture under windows-openxr/build/tests");
    require(GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES, "fixture path must not already exist");
}

struct SimulatedHost {
    std::wstring path;
    halliday::Header* header = nullptr;
    explicit SimulatedHost(const wchar_t* filePath) : path(filePath) {
        HANDLE file = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                  nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        require(file != INVALID_HANDLE_VALUE, "create a new isolated host fixture");
        LARGE_INTEGER size{}; size.QuadPart = halliday::kFileBytes;
        require(SetFilePointerEx(file, size, nullptr, FILE_BEGIN) && SetEndOfFile(file), "size host fixture");
        HANDLE mapping = CreateFileMappingW(file, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        CloseHandle(file);
        require(mapping != nullptr, "map host fixture");
        void* base = MapViewOfFile(mapping, FILE_MAP_ALL_ACCESS, 0, 0, halliday::kFileBytes);
        CloseHandle(mapping);
        require(base != nullptr, "view host fixture");
        header = new (base) halliday::Header{};
        header->magic = halliday::kMagic; header->version = halliday::kVersion;
        header->eyeWidth = header->eyeHeight = 64; header->displayHz = 90; header->ipd = .064f;
        for (auto& fov : header->tangents) { fov[0] = fov[3] = -1; fov[1] = fov[2] = 1; }
        header->state.head.valid = 1; header->state.head.orientation[3] = 1;
        header->state.head.position[1] = 1.6f;
        header->stateSeq.store(2); header->alive.store(1); header->vsync.store(1);
    }
    ~SimulatedHost() {
        if (header) { header->alive.store(0); UnmapViewOfFile(header); }
        DeleteFileW(path.c_str());
    }
};

int wmain(int argc, wchar_t** argv) {
    require(argc == 3 || (argc == 4 && !std::wcscmp(argv[3], L"--with-host")),
            "usage: openxr-loader-smoke.exe RUNTIME_JSON NEW_BRIDGE_PATH [--with-host]");
    fixturePath(argv[2]);
    require(SetEnvironmentVariableW(L"XR_RUNTIME_JSON", nullptr), "use the disposable bottle's actual runtime registration");
    require(SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH", argv[2]), "isolate runtime from the user's Halliday host");
    require(GetModuleHandleW(L"openxr_loader.dll") != nullptr, "actual openxr_loader.dll is linked");
    wchar_t registered[32768]{}; DWORD bytes = sizeof(registered);
    require(RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Khronos\\OpenXR\\1", L"ActiveRuntime",
                         RRF_RT_REG_SZ, nullptr, registered, &bytes) == ERROR_SUCCESS &&
            !std::wcscmp(registered, argv[1]), "disposable ActiveRuntime matches the test's expected manifest");

    uint32_t count = 0;
    success(xrEnumerateInstanceExtensionProperties(nullptr, 0, &count, nullptr), "loader extension enumeration");
    std::vector<XrExtensionProperties> extensions(count, {XR_TYPE_EXTENSION_PROPERTIES});
    success(xrEnumerateInstanceExtensionProperties(nullptr, count, &count, extensions.data()), "loader extension values");
    bool d3d11 = false;
    for (const auto& extension : extensions) {
        std::printf("extension: %s\n", extension.extensionName);
        if (!std::strcmp(extension.extensionName, XR_KHR_D3D11_ENABLE_EXTENSION_NAME)) d3d11 = true;
    }
    const char* enabled[] = {XR_KHR_D3D11_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(create.applicationInfo.applicationName, "Halliday official-loader smoke");
    create.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    if (d3d11) { create.enabledExtensionCount = 1; create.enabledExtensionNames = enabled; }
    XrInstance instance = XR_NULL_HANDLE;
    success(xrCreateInstance(&create, &instance), "loader creates runtime instance");
    XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
    success(xrGetInstanceProperties(instance, &properties), "loader instance properties");
    require(std::strstr(properties.runtimeName, "Halliday") != nullptr, "loader selected Halliday, not another runtime");
    std::printf("runtime: %s\n", properties.runtimeName);

    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system = XR_NULL_SYSTEM_ID;
    const XrResult absent = xrGetSystem(instance, &systemInfo, &system);
    require(absent == XR_ERROR_FORM_FACTOR_UNAVAILABLE, "missing host reports FORM_FACTOR_UNAVAILABLE through official loader");
    std::puts("PASS: official loader extension/instance/dispatch/manifest path; missing host honestly prevents a session");
    if (argc == 3) {
        success(xrDestroyInstance(instance), "loader destroys instance");
        return 0;
    }

    require(d3d11, "D3D11 must be available for the optional loader session test");
    SimulatedHost host(argv[2]);
    success(xrGetSystem(instance, &systemInfo, &system), "loader finds simulated host");
    PFN_xrVoidFunction function = nullptr;
    success(xrGetInstanceProcAddr(instance, "xrGetD3D11GraphicsRequirementsKHR", &function), "loader graphics requirements dispatch");
    require(function != nullptr, "loader returned extension command");
    XrGraphicsRequirementsD3D11KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
    success(reinterpret_cast<PFN_xrGetD3D11GraphicsRequirementsKHR>(function)(instance, system, &requirements), "D3D11 requirements");
    IDXGIFactory1* factory = nullptr;
    require(SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void**>(&factory))), "create DXGI factory");
    IDXGIAdapter1* adapter = nullptr;
    for (UINT index = 0; factory->EnumAdapters1(index, &adapter) == S_OK; ++index) {
        DXGI_ADAPTER_DESC1 description{}; adapter->GetDesc1(&description);
        if (description.AdapterLuid.HighPart == requirements.adapterLuid.HighPart &&
            description.AdapterLuid.LowPart == requirements.adapterLuid.LowPart) break;
        adapter->Release(); adapter = nullptr;
    }
    factory->Release();
    require(adapter != nullptr, "find runtime's graphics adapter");
    ID3D11Device* device = nullptr; ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    const HRESULT made = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                          &level, 1, D3D11_SDK_VERSION, &device, nullptr, &context);
    adapter->Release();
    require(SUCCEEDED(made), "create D3D11 application device");
    XrGraphicsBindingD3D11KHR binding{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR}; binding.device = device;
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; sessionInfo.next = &binding; sessionInfo.systemId = system;
    XrSession session = XR_NULL_HANDLE;
    success(xrCreateSession(instance, &sessionInfo, &session), "official loader creates D3D11 session");
    uint32_t spaces = 0, formats = 0;
    success(xrEnumerateReferenceSpaces(session, 0, &spaces, nullptr), "loader reference spaces");
    success(xrEnumerateSwapchainFormats(session, 0, &formats, nullptr), "loader swapchain formats");
    require(spaces > 0 && formats > 0, "session exposes reference spaces and texture formats");
    success(xrDestroySession(session), "loader destroys session");
    success(xrDestroyInstance(instance), "loader destroys instance");
    context->Release(); device->Release();
    std::puts("PASS: official Khronos loader created/destroyed a real D3D11-bound session against an isolated simulated host (no physical headset)");
    return 0;
}
