// MIT. Compatibility boundary for the selected, user-owned native Alyx bridge.
// Its byte uploads are encoded SDR despite its Vulkan UNORM swapchain request.
#pragma once
#define XR_NO_PROTOTYPES
#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include "frame-bridge/runtime_selection.hpp"

namespace halliday_alyx_colour {
using DeclareTransfer = XrResult (*)(XrSwapchain, uint32_t);
inline std::atomic<void*> selected_handle{};
inline std::atomic<DeclareTransfer> declare_transfer{};
inline std::atomic<PFN_xrNegotiateLoaderRuntimeInterface> negotiate_real{};
inline std::atomic<PFN_xrGetInstanceProcAddr> gipa_real{};
inline std::mutex lock;
inline std::unordered_set<XrInstance> encoded_instances;
inline std::unordered_map<XrSession, XrInstance> encoded_sessions;

template<class T> T function(XrInstance instance, const char* name) {
    PFN_xrVoidFunction pointer{};
    const auto gipa = gipa_real.load();
    return gipa && XR_SUCCEEDED(gipa(instance, name, &pointer))
        ? reinterpret_cast<T>(pointer) : nullptr;
}

inline XrResult XRAPI_CALL create_instance(const XrInstanceCreateInfo* info, XrInstance* output) {
    const auto original = function<PFN_xrCreateInstance>(XR_NULL_HANDLE, "xrCreateInstance");
    if (!original) return XR_ERROR_FUNCTION_UNSUPPORTED;
    const auto result = original(info, output);
    // Exact source-built or historical public guest identity, bounded to its field.
    // Merely loading the helper cannot alter another OpenXR application's colour.
    constexpr char legacy_identity[] = "MoltenVR native Vulkan probe";
    if (XR_SUCCEEDED(result) && info && output && *output != XR_NULL_HANDLE &&
        (std::memcmp(info->applicationInfo.applicationName, halliday_alyx_runtime::application_name,
                     sizeof(halliday_alyx_runtime::application_name)) == 0 ||
         std::memcmp(info->applicationInfo.applicationName, legacy_identity, sizeof(legacy_identity)) == 0)) {
        std::lock_guard<std::mutex> guard(lock);
        encoded_instances.insert(*output);
    }
    return result;
}

inline XrResult XRAPI_CALL destroy_instance(XrInstance instance) {
    const auto original = function<PFN_xrDestroyInstance>(instance, "xrDestroyInstance");
    if (!original) return XR_ERROR_FUNCTION_UNSUPPORTED;
    const auto result = original(instance);
    if (XR_SUCCEEDED(result)) {
        std::lock_guard<std::mutex> guard(lock);
        encoded_instances.erase(instance);
        for (auto i = encoded_sessions.begin(); i != encoded_sessions.end();) {
            if (i->second == instance) i = encoded_sessions.erase(i); else ++i;
        }
    }
    return result;
}

inline XrResult XRAPI_CALL create_session(XrInstance instance, const XrSessionCreateInfo* info, XrSession* output) {
    const auto original = function<PFN_xrCreateSession>(instance, "xrCreateSession");
    if (!original) return XR_ERROR_FUNCTION_UNSUPPORTED;
    const auto result = original(instance, info, output);
    if (XR_SUCCEEDED(result) && output && *output != XR_NULL_HANDLE) {
        std::lock_guard<std::mutex> guard(lock);
        if (encoded_instances.count(instance)) encoded_sessions[*output] = instance;
    }
    return result;
}

inline XrResult XRAPI_CALL destroy_session(XrSession session) {
    XrInstance instance{};
    {
        std::lock_guard<std::mutex> guard(lock);
        const auto found = encoded_sessions.find(session);
        if (found != encoded_sessions.end()) instance = found->second;
    }
    // This runtime's non-global functions accept its live instance (or null only
    // for globals). Unmarked sessions receive the original function in get_proc.
    if (!instance) return XR_ERROR_HANDLE_INVALID;
    const auto original = function<PFN_xrDestroySession>(instance, "xrDestroySession");
    if (!original) return XR_ERROR_FUNCTION_UNSUPPORTED;
    const auto result = original(session);
    if (XR_SUCCEEDED(result)) {
        std::lock_guard<std::mutex> guard(lock);
        encoded_sessions.erase(session);
    }
    return result;
}

inline XrResult XRAPI_CALL create_swapchain(XrSession session, const XrSwapchainCreateInfo* info, XrSwapchain* output) {
    XrInstance instance{};
    {
        std::lock_guard<std::mutex> guard(lock);
        const auto found = encoded_sessions.find(session);
        if (found != encoded_sessions.end()) instance = found->second;
    }
    if (!instance) return XR_ERROR_HANDLE_INVALID;
    const auto original = function<PFN_xrCreateSwapchain>(instance, "xrCreateSwapchain");
    if (!original) return XR_ERROR_FUNCTION_UNSUPPORTED;
    const auto result = original(session, info, output);
    // Vulkan R8G8B8A8_UNORM=37, B8G8R8A8_UNORM=44. Genuine SRGB requests
    // already carry the correct transfer and need no compatibility declaration.
    if (XR_SUCCEEDED(result) && info && output && *output != XR_NULL_HANDLE &&
        (info->format == 37 || info->format == 44)) {
        const auto declare = declare_transfer.load();
        const auto status = declare ? declare(*output, 2) : XR_ERROR_FUNCTION_UNSUPPORTED;
        if (XR_FAILED(status)) {
            if (const auto destroy = function<PFN_xrDestroySwapchain>(instance, "xrDestroySwapchain")) destroy(*output);
            *output = XR_NULL_HANDLE;
            return status;
        }
    }
    return result;
}

inline XrResult XRAPI_CALL get_proc(XrInstance instance, const char* name, PFN_xrVoidFunction* output) {
    const auto original = gipa_real.load();
    if (!original) return XR_ERROR_INITIALIZATION_FAILED;
    const auto result = original(instance, name, output);
    if (XR_FAILED(result) || !name || !output || !*output) return result;
    if (!std::strcmp(name, "xrCreateInstance")) *output = reinterpret_cast<PFN_xrVoidFunction>(create_instance);
    // All other clients receive the unmodified dispatch table.
    bool encoded;
    { std::lock_guard<std::mutex> guard(lock); encoded = encoded_instances.count(instance); }
    if (encoded) {
        if (!std::strcmp(name, "xrDestroyInstance")) *output = reinterpret_cast<PFN_xrVoidFunction>(destroy_instance);
        if (!std::strcmp(name, "xrCreateSession")) *output = reinterpret_cast<PFN_xrVoidFunction>(create_session);
        if (!std::strcmp(name, "xrDestroySession")) *output = reinterpret_cast<PFN_xrVoidFunction>(destroy_session);
        if (!std::strcmp(name, "xrCreateSwapchain")) *output = reinterpret_cast<PFN_xrVoidFunction>(create_swapchain);
    }
    return result;
}

inline XrResult XRAPI_CALL negotiate(const XrNegotiateLoaderInfo* info, XrNegotiateRuntimeRequest* request) {
    const auto original = negotiate_real.load();
    if (!original) return XR_ERROR_INITIALIZATION_FAILED;
    const auto result = original(info, request);
    if (XR_SUCCEEDED(result) && request && request->getInstanceProcAddr) {
        gipa_real.store(request->getInstanceProcAddr);
        request->getInstanceProcAddr = get_proc;
    }
    return result;
}
} // namespace halliday_alyx_colour
