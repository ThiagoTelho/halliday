// MIT. Owned dummy OpenXR runtime for real dyld/dispatch isolation checks.
#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <cstring>
#include <cstdlib>
static unsigned declarations, destroyed;
extern "C" unsigned colour_declarations() { return declarations; }
extern "C" unsigned colour_destroyed() { return destroyed; }
#ifndef OMIT_ENCODED_DECLARATION
extern "C" XrResult halliday_openxr_set_legacy_encoded_swapchain(XrSwapchain chain, uint32_t tag) {
    if (chain != reinterpret_cast<XrSwapchain>(3) || tag != 2) return XR_ERROR_VALIDATION_FAILURE;
    ++declarations;
    return std::getenv("TEST_DECLARATION_FAIL") ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
}
#endif
static XrResult XRAPI_CALL create_instance(const XrInstanceCreateInfo*, XrInstance* output) {
    *output = reinterpret_cast<XrInstance>(1); return XR_SUCCESS;
}
static XrResult XRAPI_CALL destroy_instance(XrInstance) { return XR_SUCCESS; }
static XrResult XRAPI_CALL create_session(XrInstance, const XrSessionCreateInfo*, XrSession* output) {
    *output = reinterpret_cast<XrSession>(2); return XR_SUCCESS;
}
static XrResult XRAPI_CALL destroy_session(XrSession) { return XR_SUCCESS; }
static XrResult XRAPI_CALL create_swapchain(XrSession, const XrSwapchainCreateInfo*, XrSwapchain* output) {
    if (std::getenv("TEST_CREATE_FAIL")) { *output = XR_NULL_HANDLE; return XR_ERROR_LIMIT_REACHED; }
    *output = reinterpret_cast<XrSwapchain>(3); return XR_SUCCESS;
}
static XrResult XRAPI_CALL destroy_swapchain(XrSwapchain) { ++destroyed; return XR_SUCCESS; }
static XrResult XRAPI_CALL get_proc(XrInstance, const char* name, PFN_xrVoidFunction* output) {
    *output = nullptr;
#define ENTRY(n, f) if (!std::strcmp(name, n)) *output = reinterpret_cast<PFN_xrVoidFunction>(f)
    ENTRY("xrCreateInstance", create_instance);
    ENTRY("xrDestroyInstance", destroy_instance);
    ENTRY("xrCreateSession", create_session);
    ENTRY("xrDestroySession", destroy_session);
    ENTRY("xrCreateSwapchain", create_swapchain);
    ENTRY("xrDestroySwapchain", destroy_swapchain);
#undef ENTRY
    return *output ? XR_SUCCESS : XR_ERROR_FUNCTION_UNSUPPORTED;
}
extern "C" XrResult xrNegotiateLoaderRuntimeInterface(const XrNegotiateLoaderInfo*, XrNegotiateRuntimeRequest* request) {
    request->getInstanceProcAddr = get_proc; return XR_SUCCESS;
}
