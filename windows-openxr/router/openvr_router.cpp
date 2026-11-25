#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "router_config.hpp"
#include "process_choice.hpp"
#include <cstring>
#include <cstdio>
#include <memory>

namespace {
using namespace halliday::router;
struct Core {
    virtual int Init(int, const char*) = 0;
    virtual void Cleanup() = 0;
    virtual int IsInterfaceVersionValid(const char*) = 0;
    virtual void* GetGenericInterface(const char*, int*) = 0;
    virtual bool BIsHmdPresent() = 0;
    virtual const char* GetEnglishStringForHmdError(int) = 0;
    virtual const char* GetIDForVRInitError(int) = 0;
};
using Factory = void* (__cdecl*)(const char*, int*);
// Optional compatibility shim for a provider with broken error-description
// stubs. Ordinary registered providers receive their unmodified ClientCore.
struct SafeErrorCore final : Core {
    Core* backend = nullptr;
    int Init(int app, const char* info) override { return backend->Init(app, info); }
    void Cleanup() override { backend->Cleanup(); }
    int IsInterfaceVersionValid(const char* name) override { return backend->IsInterfaceVersionValid(name); }
    void* GetGenericInterface(const char* name, int* error) override { return backend->GetGenericInterface(name, error); }
    bool BIsHmdPresent() override { return backend->BIsHmdPresent(); }
    const char* GetEnglishStringForHmdError(int error) override {
        switch (error) {
        case 0: return "No error";
        case 105: return "The selected OpenVR runtime does not support this interface.";
        case 108: return "The selected OpenVR headset was not found.";
        case 124: return "The selected OpenVR runtime could not initialize its OpenXR backend.";
        default: {
            thread_local char text[144];
            std::snprintf(text, sizeof(text), "The selected OpenVR runtime reported initialization error %d.", error);
            return text;
        }
        }
    }
    const char* GetIDForVRInitError(int error) override {
        switch (error) {
        case 0: return "VRInitError_None";
        case 105: return "VRInitError_Init_InterfaceNotFound";
        case 108: return "VRInitError_Init_HmdNotFound";
        case 124: return "VRInitError_Init_Internal";
        default: {
            thread_local char text[80];
            std::snprintf(text, sizeof(text), "VRInitError_SelectedOpenVRBackend_%d", error);
            return text;
        }
        }
    }
};
HMODULE selfModule = nullptr;
SRWLOCK selectionLock = SRWLOCK_INIT;
bool pinned = false;
Core* selectedCore = nullptr;
SafeErrorCore safeErrorCore;
int selectionError = 108;
thread_local bool selecting = false;

std::wstring wide(const std::string& text) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (n <= 0) throw std::runtime_error("invalid UTF-8 path");
    std::wstring result(n, L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), n) != n)
        throw std::runtime_error("UTF-8 conversion failed");
    return result;
}
std::wstring modulePath(HMODULE module) {
    std::wstring path(32768, L'\0');
    auto n = GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size()));
    if (!n || n >= path.size()) throw std::runtime_error("module path unavailable");
    path.resize(n); return path;
}
std::wstring parent(std::wstring path) {
    while (!path.empty() && (path.back() == L'\\' || path.back() == L'/')) path.pop_back();
    auto slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) throw std::runtime_error("path has no parent");
    return path.substr(0, slash + 1);
}
std::wstring leaf(std::wstring path) {
    while (!path.empty() && (path.back() == L'\\' || path.back() == L'/')) path.pop_back();
    auto slash = path.find_last_of(L"\\/");
    return path.substr(slash == std::wstring::npos ? 0 : slash + 1);
}
std::wstring configPath(const std::wstring& library) {
    auto directory = parent(library);
    if (!_wcsicmp(leaf(directory).c_str(), L"win64")) directory = parent(directory);
    if (_wcsicmp(leaf(directory).c_str(), L"bin")) throw std::runtime_error("router is not in an OpenVR bin directory");
    directory = parent(directory);
    if (_wcsicmp(leaf(directory).c_str(), L"OpenVR")) throw std::runtime_error("router is not in the owned OpenVR runtime");
    return parent(directory) + L"halliday-openxr-router.json";
}
std::wstring fullPath(const std::wstring& path) {
    auto size = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (!size || size > 32768) throw std::runtime_error("invalid absolute path");
    std::wstring result(size, L'\0');
    auto n = GetFullPathNameW(path.c_str(), size, result.data(), nullptr);
    if (!n || n >= size) throw std::runtime_error("path resolution failed");
    result.resize(n); return result;
}
struct Closer { void operator()(void* p) const { if (p && p != INVALID_HANDLE_VALUE) CloseHandle(p); } };
using File = std::unique_ptr<void, Closer>;
std::string readFile(const std::wstring& path, size_t limit) {
    File file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    LARGE_INTEGER length{};
    if (file.get() == INVALID_HANDLE_VALUE || GetFileType(file.get()) != FILE_TYPE_DISK ||
        !GetFileSizeEx(file.get(), &length) || length.QuadPart < 0 || static_cast<uint64_t>(length.QuadPart) > limit)
        throw std::runtime_error("unavailable or oversized routing JSON");
    std::string result(limit + 1, '\0'); size_t used = 0;
    while (used < result.size()) {
        DWORD got = 0;
        if (!ReadFile(file.get(), result.data() + used, static_cast<DWORD>(result.size() - used), &got, nullptr))
            throw std::runtime_error("routing JSON read failed");
        if (!got) break;
        used += got;
    }
    if (used > limit) throw std::runtime_error("routing JSON grew beyond limit");
    result.resize(used); return result;
}
uint64_t unixMs() {
    FILETIME time{}; GetSystemTimeAsFileTime(&time);
    ULARGE_INTEGER ticks{}; ticks.LowPart = time.dwLowDateTime; ticks.HighPart = time.dwHighDateTime;
    constexpr uint64_t epoch = 116444736000000000ULL;
    return ticks.QuadPart >= epoch ? (ticks.QuadPart - epoch) / 10000 : 0;
}
void diagnostic(const char* text) {
    wchar_t path[32768]; DWORD n = GetEnvironmentVariableW(L"HALLIDAY_OPENVR_ROUTER_LOG", path, 32768);
    if (!n || n >= 32768) return;
    File file(CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.get() == INVALID_HANDLE_VALUE) return;
    std::string line = "Halliday OpenVR router: "; line += text; line += "\r\n";
    DWORD written = 0; WriteFile(file.get(), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}
void selectBackend() {
    pinned = true;
    try {
        HMODULE retained = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(&selfModule), &retained)) throw std::runtime_error("router self-pin failed");
        const auto own = fullPath(modulePath(selfModule));
        const auto config = parseConfig(readFile(configPath(own), kConfigBytes));
        if (config.hallidayOpenVRLibrary.empty()) throw std::runtime_error("Halliday OpenVR backend path is missing");
        const bool externalConfigured = !config.externalManifest.empty() || !config.externalOpenVRLibrary.empty();
        bool proposed = !externalConfigured;
        try { proposed = chooseHalliday(parsePolicy(readFile(wide(config.policyFile), kPolicyBytes)), unixMs(), externalConfigured); }
        catch (...) { /* An original provider retains its route without a live host policy. */ }
        const bool halliday = pinProcessChoice(proposed);
        if (!halliday && config.externalOpenVRLibrary.empty()) throw std::runtime_error("selected external OpenVR route is not configured");
        const auto path = fullPath(wide(halliday ? config.hallidayOpenVRLibrary : config.externalOpenVRLibrary));
        if (!_wcsicmp(own.c_str(), path.c_str())) throw std::runtime_error("router cannot select itself");
        HMODULE library = LoadLibraryExW(path.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!library) throw std::runtime_error("selected OpenVR backend could not load");
        if (GetProcAddress(library, "hallidayOpenVRRouterMarker") || GetProcAddress(library, "hallidayOpenXRRouterMarker"))
            throw std::runtime_error("selected backend is another router");
        auto factory = reinterpret_cast<Factory>(GetProcAddress(library, "VRClientCoreFactory"));
        if (!factory) throw std::runtime_error("selected backend has no VRClientCoreFactory");
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
            reinterpret_cast<LPCWSTR>(factory), &retained)) throw std::runtime_error("backend pin failed");
        int error = 108;
        auto* core = static_cast<Core*>(factory("IVRClientCore_003", &error));
        if (!core || error) { selectionError = error ? error : 108; throw std::runtime_error("selected backend rejected ClientCore003"); }
        if (!halliday && config.externalSafeErrorStrings) { safeErrorCore.backend = core; selectedCore = &safeErrorCore; }
        else selectedCore = core;
        selectionError = 0;
        diagnostic(halliday ? "selected Halliday (process-pinned)" : "selected original external OpenVR runtime (process-pinned)");
    } catch (const std::exception& error) { diagnostic(error.what()); }
    catch (...) { diagnostic("OpenVR backend selection failed"); }
}
} // namespace

extern "C" __declspec(dllexport) uint32_t __cdecl hallidayOpenVRRouterMarker() { return 1; }
extern "C" __declspec(dllexport) void* __cdecl VRClientCoreFactory(const char* name, int* error) {
    if (!name || std::strcmp(name, "IVRClientCore_003")) { if (error) *error = 105; return nullptr; }
    // A misconfigured backend that tries to reload this same runtime must fail
    // explicitly rather than reenter selectionLock and hang the process.
    if (selecting) { if (error) *error = 108; return nullptr; }
    struct Selecting { Selecting() { selecting = true; } ~Selecting() { selecting = false; } } active;
    AcquireSRWLockExclusive(&selectionLock);
    if (!pinned) selectBackend();
    auto* result = selectedCore; const int status = selectionError;
    ReleaseSRWLockExclusive(&selectionLock);
    if (error) *error = status;
    return result;
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { selfModule = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
