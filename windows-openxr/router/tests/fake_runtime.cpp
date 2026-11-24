#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <openxr/openxr_loader_negotiation.h>
#include <cstring>
#include <atomic>
#ifndef FAKE_ID
#define FAKE_ID 1
#endif
namespace {
std::atomic<const XrNegotiateLoaderInfo*> lastLoader{nullptr};
std::atomic<XrNegotiateRuntimeRequest*> lastRuntime{nullptr};
std::atomic<unsigned> aliasCalls{0};
XrResult XRAPI_CALL create(const XrInstanceCreateInfo*, XrInstance* instance) {
    if (GetEnvironmentVariableW(L"HALLIDAY_FAKE_CREATE_FAIL", nullptr, 0)) return XR_ERROR_RUNTIME_FAILURE;
    *instance = reinterpret_cast<XrInstance>(static_cast<uintptr_t>(FAKE_ID)); return XR_SUCCESS;
}
}
extern "C" __declspec(dllexport) XrResult XRAPI_CALL fakeGetInstanceProcAddr(XrInstance, const char* name, PFN_xrVoidFunction* out) {
    if (!std::strcmp(name, "xrCreateInstance")) { *out=reinterpret_cast<PFN_xrVoidFunction>(&create); return XR_SUCCESS; }
    *out=nullptr; return XR_ERROR_FUNCTION_UNSUPPORTED;
}
extern "C" __declspec(dllexport) XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo* loader, XrNegotiateRuntimeRequest* runtime) {
    lastLoader=loader; lastRuntime=runtime;
    if (GetEnvironmentVariableW(L"HALLIDAY_FAKE_NEGOTIATE_FAIL",nullptr,0)) return XR_ERROR_RUNTIME_UNAVAILABLE;
    runtime->runtimeInterfaceVersion=1;
    runtime->runtimeApiVersion=XR_MAKE_VERSION(1, FAKE_ID == 1 ? 1 : 0, FAKE_ID == 1 ? 77 : 31);
    runtime->getInstanceProcAddr=&fakeGetInstanceProcAddr; return XR_SUCCESS;
}
extern "C" __declspec(dllexport) XrResult XRAPI_CALL testNegotiate(const XrNegotiateLoaderInfo* loader, XrNegotiateRuntimeRequest* runtime) {
    ++aliasCalls; return xrNegotiateLoaderRuntimeInterface(loader,runtime);
}
extern "C" __declspec(dllexport) bool __cdecl fakePointersMatch(const XrNegotiateLoaderInfo* loader, XrNegotiateRuntimeRequest* runtime) {
    return loader==lastLoader.load() && runtime==lastRuntime.load();
}
extern "C" __declspec(dllexport) unsigned __cdecl fakeAliasCalls() { return aliasCalls.load(); }
