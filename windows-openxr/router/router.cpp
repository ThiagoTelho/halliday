#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <openxr/openxr_loader_negotiation.h>
#include "router_config.hpp"
#include "process_choice.hpp"
#include <memory>

namespace {
using namespace halliday::router;
HMODULE selfModule = nullptr;
SRWLOCK selectionLock = SRWLOCK_INIT;
bool pinned = false;
HMODULE selectedModule = nullptr; // Retained until process exit: forwarded function pointers stay live.
PFN_xrNegotiateLoaderRuntimeInterface selectedNegotiate = nullptr;
XrResult selectionError = XR_ERROR_INITIALIZATION_FAILED;

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
std::wstring directory(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) throw std::runtime_error("path has no directory");
    return path.substr(0, slash + 1);
}
std::wstring fullPath(const std::wstring& path) {
    auto size = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
    if (!size || size > 32768) throw std::runtime_error("invalid absolute path");
    std::wstring result(size, L'\0');
    auto n = GetFullPathNameW(path.c_str(), size, result.data(), nullptr);
    if (!n || n >= size) throw std::runtime_error("path resolution failed");
    result.resize(n); return result;
}
struct HandleCloser { void operator()(void* p) const { if (p && p != INVALID_HANDLE_VALUE) CloseHandle(p); } };
using File = std::unique_ptr<void, HandleCloser>;
std::string readFile(const std::wstring& path, size_t limit) {
    File file(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                          nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    LARGE_INTEGER length{};
    if (file.get() == INVALID_HANDLE_VALUE || GetFileType(file.get()) != FILE_TYPE_DISK ||
        !GetFileSizeEx(file.get(), &length) || length.QuadPart < 0 || static_cast<uint64_t>(length.QuadPart) > limit)
        throw std::runtime_error("unavailable or oversized JSON file");
    std::string bytes(limit + 1, '\0');
    size_t used = 0;
    while (used < bytes.size()) {
        DWORD got = 0;
        if (!ReadFile(file.get(), bytes.data() + used, static_cast<DWORD>(bytes.size() - used), &got, nullptr))
            throw std::runtime_error("JSON read failed");
        if (!got) break;
        used += got;
    }
    if (used > limit) throw std::runtime_error("JSON grew beyond limit");
    bytes.resize(used); return bytes;
}
uint64_t unixMs() {
    FILETIME time{}; GetSystemTimeAsFileTime(&time);
    ULARGE_INTEGER ticks{}; ticks.LowPart = time.dwLowDateTime; ticks.HighPart = time.dwHighDateTime;
    constexpr uint64_t epoch = 116444736000000000ULL;
    return ticks.QuadPart >= epoch ? (ticks.QuadPart - epoch) / 10000 : 0;
}
void diagnostic(const char* text) {
    // Never create persistent logs unless explicitly requested by a diagnostic launch.
    wchar_t path[32768];
    DWORD n = GetEnvironmentVariableW(L"HALLIDAY_OPENXR_ROUTER_LOG", path, 32768);
    if (!n || n >= 32768) return;
    File file(CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                          nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    if (file.get() == INVALID_HANDLE_VALUE) return;
    std::string line = "Halliday OpenXR router: "; line += text; line += "\r\n";
    DWORD written = 0; WriteFile(file.get(), line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
}
void selectBackend() {
    // Called once under selectionLock. With no original provider configured the
    // independent runtime is always the route, even without a policy heartbeat.
    pinned = true;
    try {
        HMODULE pinnedSelf = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                reinterpret_cast<LPCWSTR>(&selfModule), &pinnedSelf))
            throw std::runtime_error("router module could not be process-pinned");
        auto ownPath = modulePath(selfModule);
        auto config = parseConfig(readFile(directory(ownPath) + L"halliday-openxr-router.json", kConfigBytes));
        const bool externalConfigured = !config.externalManifest.empty() || !config.externalOpenVRLibrary.empty();
        bool halliday = !externalConfigured;
        try {
            const auto policy = parsePolicy(readFile(wide(config.policyFile), kPolicyBytes));
            // Sample freshness after the read, never before potentially delayed I/O.
            halliday = chooseHalliday(policy, unixMs(), externalConfigured);
        }
        catch (...) { /* With an original provider, unavailable policy preserves its route. */ }
        halliday = pinProcessChoice(halliday);
        if (!halliday && config.externalManifest.empty()) throw std::runtime_error("selected external OpenXR route is not configured");
        auto path = fullPath(wide(halliday ? config.hallidayManifest : config.externalManifest));
        auto manifest = parseManifest(readFile(path, kConfigBytes));
        const bool absolute = isAbsolutePath(manifest.library);
        // Reject drive-relative paths such as C:foo.dll. Relative manifest paths are
        // resolved only against the selected manifest's directory, never the game CWD.
        if (!absolute && (manifest.library.find(':') != std::string::npos || manifest.library[0] == '\\' || manifest.library[0] == '/'))
            throw std::runtime_error("invalid relative backend library path");
        auto library = fullPath(absolute ? wide(manifest.library) : directory(path) + wide(manifest.library));
        if (_wcsicmp(library.c_str(), fullPath(ownPath).c_str()) == 0)
            throw std::runtime_error("router cannot select itself");
        diagnostic(halliday ? "selected Halliday (process-pinned)" : "selected original external runtime (process-pinned)");
        selectedModule = LoadLibraryExW(library.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!selectedModule) throw std::runtime_error("selected backend DLL failed to load");
        if (GetProcAddress(selectedModule, "hallidayOpenXRRouterMarker"))
            throw std::runtime_error("backend is another router");
        auto entry = GetProcAddress(selectedModule, manifest.negotiate.c_str());
        if (!entry) throw std::runtime_error("selected backend lacks negotiation export");
        selectedNegotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(entry);
        selectionError = XR_SUCCESS;
    } catch (const std::exception& error) { diagnostic(error.what()); }
    catch (...) { diagnostic("backend selection failed"); }
}
} // namespace

extern "C" __declspec(dllexport) uint32_t __cdecl hallidayOpenXRRouterMarker() { return 1; }
extern "C" __declspec(dllexport) XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(
    const XrNegotiateLoaderInfo* loader, XrNegotiateRuntimeRequest* runtime) {
    if (!loader || !runtime) return XR_ERROR_INITIALIZATION_FAILED;
    AcquireSRWLockExclusive(&selectionLock);
    if (!pinned) selectBackend();
    auto negotiate = selectedNegotiate;
    const auto error = selectionError;
    ReleaseSRWLockExclusive(&selectionLock);
    // The selected backend receives the loader's exact structures and owns all
    // extension/API negotiation. No proxy handles, GIPA wrapping or session switching.
    return negotiate ? negotiate(loader, runtime) : error;
}
BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) { selfModule = module; DisableThreadLibraryCalls(module); }
    return TRUE;
}
