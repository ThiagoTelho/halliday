#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <cassert>
static PFN_xrGetInstanceProcAddr gipa;
template<class T> T function(XrInstance instance, const char* name) {
    PFN_xrVoidFunction output{}; assert(gipa(instance, name, &output) == XR_SUCCESS); return reinterpret_cast<T>(output);
}
int main(int argc, char** argv) {
    assert(argc == 5);
    auto runtime = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); assert(runtime);
    auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(dlsym(runtime, "xrNegotiateLoaderRuntimeInterface")); assert(negotiate);
    XrNegotiateRuntimeRequest request{}; assert(negotiate(nullptr, &request) == XR_SUCCESS); gipa = request.getInstanceProcAddr;
    XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO}; std::strncpy(info.applicationInfo.applicationName, argv[2], sizeof(info.applicationInfo.applicationName)-1);
    XrInstance instance{}; assert(function<PFN_xrCreateInstance>(XR_NULL_HANDLE, "xrCreateInstance")(&info, &instance) == XR_SUCCESS);
    XrSessionCreateInfo sessionInfo{XR_TYPE_SESSION_CREATE_INFO}; XrSession session{};
    assert(function<PFN_xrCreateSession>(instance, "xrCreateSession")(instance, &sessionInfo, &session) == XR_SUCCESS);
    XrSwapchainCreateInfo imageInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO}; imageInfo.format = std::atoi(argv[3]); XrSwapchain image{};
    const auto result = function<PFN_xrCreateSwapchain>(instance, "xrCreateSwapchain")(session, &imageInfo, &image);
    const bool fail = std::getenv("TEST_DECLARATION_FAIL"), createFail = std::getenv("TEST_CREATE_FAIL");
    assert(result == (createFail ? XR_ERROR_LIMIT_REACHED : fail ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS));
    assert((image == XR_NULL_HANDLE) == (fail || createFail));
    auto declarations = reinterpret_cast<unsigned(*)()>(dlsym(runtime, "colour_declarations"));
    auto destroyed = reinterpret_cast<unsigned(*)()>(dlsym(runtime, "colour_destroyed")); assert(declarations && destroyed);
    assert(declarations() == unsigned(std::atoi(argv[4])));
    assert(destroyed() == unsigned(fail));
    assert(function<PFN_xrDestroySession>(instance, "xrDestroySession")(session) == XR_SUCCESS);
    assert(function<PFN_xrDestroyInstance>(instance, "xrDestroyInstance")(instance) == XR_SUCCESS);
}
