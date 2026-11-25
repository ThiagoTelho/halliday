#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <cstdint>
#include <initializer_list>
#include <cwchar>

// Public IVRClientCore_003's seven virtual methods, in Valve's documented order.
// No game, renderer, headset or private runtime object is created by this probe.
struct Core {
    virtual int Init(int applicationType, const char* startup) = 0;
    virtual void Cleanup() = 0;
    virtual int IsInterfaceVersionValid(const char* name) = 0;
    virtual void* GetGenericInterface(const char* name, int* error) = 0;
    virtual bool BIsHmdPresent() = 0;
    virtual const char* GetEnglishStringForHmdError(int error) = 0;
    virtual const char* GetIDForVRInitError(int error) = 0;
};
using Factory = void* (__cdecl*)(const char*, int*);
namespace {
HANDLE completed = nullptr;
DWORD WINAPI watchdog(void*) {
    if (WaitForSingleObject(completed, 8000) != WAIT_OBJECT_0) {
        std::fprintf(stderr, "FAIL: bounded OpenVR probe timed out\n");
        std::fflush(stderr);
        TerminateProcess(GetCurrentProcess(), 124);
    }
    return 0;
}
void check(bool value, const char* message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s (%lu)\n", message, GetLastError()); ExitProcess(1); }
}
}
int wmain(int argc, wchar_t** argv) {
    check(argc == 3 || argc == 4, "usage: openvr-core-probe FULL_OC_DLL ABSENT_XR_MANIFEST [english|symbol|basic]");
    check(GetFileAttributesW(argv[2]) == INVALID_FILE_ATTRIBUTES, "negative OpenXR path must not exist");
    check(SetEnvironmentVariableW(L"XR_RUNTIME_JSON", argv[2]), "isolate OpenXR from actual runtimes");
    SetEnvironmentVariableW(L"XR_RUNTIME_JSON_64", argv[2]);
    SetEnvironmentVariableW(L"XR_ENABLE_API_LAYERS", nullptr);
    // CrossOver may ignore XR_RUNTIME_JSON at a normal Windows integrity level.
    // Never rely on that environment variable alone to isolate a real runtime.
    for (HKEY root : {HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER}) {
        for (DWORD view : {RRF_SUBKEY_WOW6464KEY, RRF_SUBKEY_WOW6432KEY}) {
            DWORD bytes = 0;
            const auto status = RegGetValueW(root, L"SOFTWARE\\Khronos\\OpenXR\\1", L"ActiveRuntime",
                RRF_RT_ANY | view, nullptr, nullptr, &bytes);
            check(status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND,
                "negative probe requires ABSENT disposable ActiveRuntime in both registry views");
        }
    }
    std::puts("REGISTRY_ABSENT PASS (HKLM/HKCU,64/32); no live OpenXR registration"); std::fflush(stdout);
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);
    completed = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    check(completed != nullptr, "create watchdog completion event");
    HANDLE timer = CreateThread(nullptr, 0, watchdog, nullptr, 0, nullptr);
    check(timer != nullptr, "create bounded watchdog");
    HMODULE library = LoadLibraryExW(argv[1], nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    check(library != nullptr, "load exact full OpenComposite library");
    const char* functions[] = {"VRClientCoreFactory", "VR_InitInternal2", "VR_ShutdownInternal",
        "VR_GetGenericInterface", "VR_IsInterfaceVersionValid", "VR_IsHmdPresent",
        "VR_GetVRInitErrorAsEnglishDescription", "VR_GetVRInitErrorAsSymbol"};
    for (auto name : functions) check(GetProcAddress(library, name) != nullptr, name);
    auto factory = reinterpret_cast<Factory>(GetProcAddress(library, "VRClientCoreFactory"));
    int error = -1;
    auto* core = static_cast<Core*>(factory("IVRClientCore_003", &error));
    check(core && error == 0, "actual factory provides public IVRClientCore_003");
    std::printf("FACTORY003 PASS\n"); std::fflush(stdout);
    std::printf("Init with absent OpenXR manifest begins\n"); std::fflush(stdout);
    error = core->Init(1, nullptr);
    std::printf("NEGATIVE_INIT result=%d\n", error); std::fflush(stdout);
    if (error == 0) core->Cleanup();
    check(error != 0, "absent OpenXR runtime must prevent initialization");
    if (argc == 4 && !std::wcscmp(argv[3], L"english")) {
        std::puts("CALL Core.English(negativeInitError)"); std::fflush(stdout);
        check(core->GetEnglishStringForHmdError(error) != nullptr, "English negative error text");
        std::puts("ENGLISH PASS"); std::fflush(stdout);
    } else if (argc == 4 && !std::wcscmp(argv[3], L"symbol")) {
        std::puts("CALL Core.Symbol(negativeInitError)"); std::fflush(stdout);
        check(core->GetIDForVRInitError(error) != nullptr, "Symbolic negative error text");
        std::puts("SYMBOL PASS"); std::fflush(stdout);
    } else if (argc == 4 && !std::wcscmp(argv[3], L"basic")) {
        std::puts("CALL Core.Validate(IVRSystem_022)"); std::fflush(stdout);
        const int supported = core->IsInterfaceVersionValid("IVRSystem_022");
        std::printf("VALIDATE returned %d\n", supported); std::fflush(stdout);
        std::puts("CALL Core.GetGeneric after failed Init"); std::fflush(stdout);
        int genericError = -1;
        check(core->GetGenericInterface("IVRSystem_022", &genericError) == nullptr && genericError != 0,
            "failed Init must not yield a live system");
        std::puts("CALL Core.Present (not a hardware claim)"); std::fflush(stdout);
        const bool present = core->BIsHmdPresent();
        std::printf("PRESENT returned %u\n", present ? 1 : 0); std::fflush(stdout);
        std::puts("CALL Core.Cleanup after failed Init"); std::fflush(stdout);
        core->Cleanup(); std::puts("BASIC SLOTS PASS"); std::fflush(stdout);
    }
    SetEvent(completed); WaitForSingleObject(timer, 1000);
    CloseHandle(timer); CloseHandle(completed);
    std::puts("PASS: actual full OpenComposite factory003 and bounded negative Init; no live OpenXR runtime");
    return 0;
}
