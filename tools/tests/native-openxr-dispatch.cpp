// API-dispatch regression oracle. No host, graphics device or installed runtime registration.
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <initializer_list>

static unsigned checks = 0, failures = 0;
static void check(bool passed, const char* message) {
    ++checks;
    if (!passed) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); }
}
template<typename T> static T function(PFN_xrGetInstanceProcAddr gipa, XrInstance instance, const char* name) {
    PFN_xrVoidFunction out = nullptr;
    if (gipa(instance, name, &out) != XR_SUCCESS || !out) return nullptr;
    return reinterpret_cast<T>(out);
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 2; }
    const auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(dlsym(library, "xrNegotiateLoaderRuntimeInterface"));
    if (!negotiate) return 2;
    XrNegotiateLoaderInfo loader{XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, XR_LOADER_INFO_STRUCT_VERSION, sizeof(loader), 1, 1, XR_MAKE_VERSION(1,0,0), XR_MAKE_VERSION(1,1,999)};
    XrNegotiateRuntimeRequest request{XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, XR_RUNTIME_INFO_STRUCT_VERSION, sizeof(request)};
    if (negotiate(&loader, &request) != XR_SUCCESS || !request.getInstanceProcAddr) return 2;
    const auto gipa = request.getInstanceProcAddr;
    const auto create = function<PFN_xrCreateInstance>(gipa, XR_NULL_HANDLE, "xrCreateInstance");
    if (!create) return 2;
    const char* extensions[]{"XR_KHR_metal_enable", "XR_KHR_vulkan_enable", "XR_KHR_vulkan_enable2"};
    const char* commands[]{"xrGetMetalGraphicsRequirementsKHR", "xrGetVulkanGraphicsRequirementsKHR", "xrGetVulkanGraphicsRequirements2KHR"};
    XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(info.applicationInfo.applicationName, "Halliday dispatch regression");
    info.applicationInfo.apiVersion = XR_MAKE_VERSION(1,0,0);
    info.enabledExtensionCount = 1;
    for (unsigned i=0; i<3; ++i) {
        XrInstance instance = XR_NULL_HANDLE;
        info.enabledExtensionNames = &extensions[i];
        if (create(&info, &instance) != XR_SUCCESS) return 2;
        XrInstance duplicate = XR_NULL_HANDLE;
        check(create(&info, &duplicate)==XR_ERROR_LIMIT_REACHED && !duplicate, "second live instance must not share process-wide state");
        if (duplicate) {
            const auto destroy = function<PFN_xrDestroyInstance>(gipa, duplicate, "xrDestroyInstance");
            if (destroy) destroy(duplicate);
        }
        for (unsigned j=0; j<3; ++j) {
            PFN_xrVoidFunction out = nullptr;
            const auto result = gipa(instance, commands[j], &out);
            check(i==j ? result==XR_SUCCESS && out : result==XR_ERROR_FUNCTION_UNSUPPORTED && !out,
                  "extension dispatch must match this instance's enabled extension");
        }
        const auto destroy = function<PFN_xrDestroyInstance>(gipa, instance, "xrDestroyInstance");
        check(destroy && destroy(instance)==XR_SUCCESS, "destroy instance");
    }
    info.enabledExtensionCount = 0; info.enabledExtensionNames = nullptr;
    for (const XrVersion version : {XR_MAKE_VERSION(0,0,0), XR_MAKE_VERSION(1,2,0), XR_MAKE_VERSION(2,0,0)}) {
        info.applicationInfo.apiVersion = version;
        XrInstance instance = XR_NULL_HANDLE;
        const auto result = create(&info, &instance);
        check(result==XR_ERROR_API_VERSION_UNSUPPORTED && instance==XR_NULL_HANDLE, "unsupported API version must not create an instance");
        if (instance) {
            const auto destroy = function<PFN_xrDestroyInstance>(gipa, instance, "xrDestroyInstance");
            if (destroy) destroy(instance);
        }
    }
    request.structVersion = 0;
    check(negotiate(&loader, &request)==XR_ERROR_INITIALIZATION_FAILED, "invalid negotiation structure version");
    std::printf("{\"passed\":%s,\"checks\":%u,\"failures\":%u,\"physical_headset\":false}\n", failures ? "false":"true", checks, failures);
    dlclose(library);
    return failures ? 1 : 0;
}
