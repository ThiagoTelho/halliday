#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstring>
#include <cstdint>
#ifndef FAKE_ID
#define FAKE_ID 1
#endif
namespace {
struct Core {
    virtual int Init(int, const char*) { return GetEnvironmentVariableW(L"HALLIDAY_FAKE_VR_INIT_FAIL", nullptr, 0) ? 124 : 0; }
    virtual void Cleanup() {}
    virtual int IsInterfaceVersionValid(const char* name) { return name && !std::strcmp(name, "test") ? 0 : 106; }
    virtual void* GetGenericInterface(const char*, int* error) {
        if (error) *error = 0;
        return reinterpret_cast<void*>(static_cast<uintptr_t>(FAKE_ID));
    }
    virtual bool BIsHmdPresent() { return FAKE_ID == 1; }
    virtual const char* GetEnglishStringForHmdError(int) {
        if (GetEnvironmentVariableW(L"HALLIDAY_FAKE_VR_BAD_ERRORS", nullptr, 0)) Sleep(INFINITE);
        return "fake backend English";
    }
    virtual const char* GetIDForVRInitError(int) {
        if (GetEnvironmentVariableW(L"HALLIDAY_FAKE_VR_BAD_ERRORS", nullptr, 0)) Sleep(INFINITE);
        return "FakeBackendSymbol";
    }
} core;
}
extern "C" __declspec(dllexport) void* __cdecl VRClientCoreFactory(const char* name, int* error) {
    if (GetEnvironmentVariableW(L"HALLIDAY_FAKE_VR_BAD_FACTORY", nullptr, 0)) {
        if (error) *error = 108; return nullptr;
    }
    const bool ok = name && !std::strcmp(name, "IVRClientCore_003");
    if (error) *error = ok ? 0 : 105;
    return ok ? &core : nullptr;
}
