// Derived from BasaltVR c104bc0b489384745157bc42e357f08d17e41638 (MIT).
// Copyright (c) 2026 BasaltVR contributors. See LICENSE-BasaltVR.
#include "runtime.hpp"
#include "control.hpp"
#include "vulkan_backend.hpp"

#include <windows.h>

#include <openxr/openxr_reflection.h>

#include <cstdio>
#include <cstring>

namespace {

constexpr uintptr_t kFirstInstanceHandle = static_cast<uintptr_t>(0x10000);
constexpr uintptr_t kInstanceHandleStride = static_cast<uintptr_t>(0x10);

SRWLOCK gInstanceLock = SRWLOCK_INIT;
uintptr_t gNextInstanceHandle = kFirstInstanceHandle;
XrInstance gLiveInstance = XR_NULL_HANDLE;
bool gInstanceDestroying = false;
bool gD3D11ExtensionEnabled = false;
bool gD3D12ExtensionEnabled = false;
bool gVulkan1Enabled = false, gVulkan2Enabled = false;

XrResult XRAPI_CALL basaltEnumerateInstanceExtensionProperties(
    const char* layerName,
    uint32_t propertyCapacityInput,
    uint32_t* propertyCountOutput,
    XrExtensionProperties* properties) {
    if (propertyCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (layerName != nullptr) {
        return XR_ERROR_API_LAYER_NOT_PRESENT;
    }

    const char* names[4]{}; uint32_t versions[4]{}; uint32_t count = 0;
    if (basalt::isD3D11RuntimeAvailable()) {
        names[count] = XR_KHR_D3D11_ENABLE_EXTENSION_NAME; versions[count++] = XR_KHR_D3D11_enable_SPEC_VERSION;
    }
    if (basalt::isD3D12RuntimeAvailable()) {
        names[count] = XR_KHR_D3D12_ENABLE_EXTENSION_NAME; versions[count++] = XR_KHR_D3D12_enable_SPEC_VERSION;
    }
    if (basalt::isVulkanRuntimeAvailable()) {
        names[count] = XR_KHR_VULKAN_ENABLE_EXTENSION_NAME; versions[count++] = XR_KHR_vulkan_enable_SPEC_VERSION;
        names[count] = XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME; versions[count++] = XR_KHR_vulkan_enable2_SPEC_VERSION;
    }
    *propertyCountOutput = count;
    if (!propertyCapacityInput) return XR_SUCCESS;
    if (!properties) return XR_ERROR_VALIDATION_FAILURE;
    if (propertyCapacityInput < count) return XR_ERROR_SIZE_INSUFFICIENT;
    for (uint32_t index = 0; index < count; ++index) {
        if (properties[index].type != XR_TYPE_EXTENSION_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
        std::strncpy(properties[index].extensionName,names[index],XR_MAX_EXTENSION_NAME_SIZE-1);
        properties[index].extensionName[XR_MAX_EXTENSION_NAME_SIZE-1] = '\0';
        properties[index].extensionVersion = versions[index];
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltEnumerateApiLayerProperties(
    uint32_t propertyCapacityInput,
    uint32_t* propertyCountOutput,
    XrApiLayerProperties* properties) {
    if (propertyCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *propertyCountOutput = 0;
    if (propertyCapacityInput > 0 && properties == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltCreateInstance(
    const XrInstanceCreateInfo* createInfo,
    XrInstance* instance) {
    if (instance == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *instance = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_INSTANCE_CREATE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (createInfo->createFlags != 0 ||
        (createInfo->enabledApiLayerCount != 0 && createInfo->enabledApiLayerNames == nullptr) ||
        (createInfo->enabledExtensionCount != 0 && createInfo->enabledExtensionNames == nullptr)) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->applicationInfo.applicationName[0] == '\0' ||
        std::memchr(createInfo->applicationInfo.applicationName, '\0', XR_MAX_APPLICATION_NAME_SIZE) == nullptr ||
        std::memchr(createInfo->applicationInfo.engineName, '\0', XR_MAX_ENGINE_NAME_SIZE) == nullptr) {
        std::fprintf(stderr, "Halliday Windows OpenXR: xrCreateInstance rejected an invalid application or engine name\n");
        return XR_ERROR_NAME_INVALID;
    }

    const XrVersion requestedVersion = createInfo->applicationInfo.apiVersion;
    if (requestedVersion < XR_MAKE_VERSION(1, 0, 0) ||
        requestedVersion >= XR_MAKE_VERSION(1, 1, 0)) {
        std::fprintf(
            stderr,
            "Halliday Windows OpenXR: unsupported application API version %u.%u.%u (runtime supports OpenXR 1.0)\n",
            XR_VERSION_MAJOR(requestedVersion),
            XR_VERSION_MINOR(requestedVersion),
            XR_VERSION_PATCH(requestedVersion));
        return XR_ERROR_API_VERSION_UNSUPPORTED;
    }
    bool enableD3D11 = false, enableD3D12 = false, enableVulkan1 = false, enableVulkan2 = false;
    for (uint32_t index = 0; index < createInfo->enabledExtensionCount; ++index) {
        const char* extensionName = createInfo->enabledExtensionNames[index];
        if (extensionName == nullptr) {
            std::fprintf(stderr, "Halliday Windows OpenXR: null enabled extension name at index %u\n", index);
            return XR_ERROR_VALIDATION_FAILURE;
        }
        if (!std::strcmp(extensionName,XR_KHR_D3D11_ENABLE_EXTENSION_NAME) && basalt::isD3D11RuntimeAvailable())
            enableD3D11 = true;
        else if (!std::strcmp(extensionName,XR_KHR_D3D12_ENABLE_EXTENSION_NAME) && basalt::isD3D12RuntimeAvailable())
            enableD3D12 = true;
        else if (!std::strcmp(extensionName,XR_KHR_VULKAN_ENABLE_EXTENSION_NAME) && basalt::isVulkanRuntimeAvailable()) enableVulkan1 = true;
        else if (!std::strcmp(extensionName,XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME) && basalt::isVulkanRuntimeAvailable()) enableVulkan2 = true;
        else return XR_ERROR_EXTENSION_NOT_PRESENT;
    }

    AcquireSRWLockExclusive(&gInstanceLock);
    if (gLiveInstance != XR_NULL_HANDLE) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    if (gNextInstanceHandle > UINTPTR_MAX - kInstanceHandleStride) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    gLiveInstance = reinterpret_cast<XrInstance>(gNextInstanceHandle);
    gD3D11ExtensionEnabled = enableD3D11;
    gD3D12ExtensionEnabled = enableD3D12;
    gVulkan1Enabled = enableVulkan1; gVulkan2Enabled = enableVulkan2;
    gNextInstanceHandle += kInstanceHandleStride;
    *instance = gLiveInstance;
    ReleaseSRWLockExclusive(&gInstanceLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltDestroyInstance(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gInstanceLock);
    if (instance != gLiveInstance || gInstanceDestroying) {
        ReleaseSRWLockExclusive(&gInstanceLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    // Keep the instance slot occupied through global session/input teardown.
    // Otherwise another thread can create fresh resources which this cleanup
    // then clears or unmaps. Do not hold the instance lock across worker joins.
    gInstanceDestroying = true;
    gD3D11ExtensionEnabled = false;
    gD3D12ExtensionEnabled = false;
    gVulkan1Enabled = gVulkan2Enabled = false;
    ReleaseSRWLockExclusive(&gInstanceLock);
    basalt::invalidateSessionForInstance(instance);
    basalt::resetVulkanInstance(instance);
    basalt::controlCloseIdleMapping();
    basalt::invalidateInputForInstance(instance);
    basalt::invalidatePathsForInstance(instance);
    AcquireSRWLockExclusive(&gInstanceLock);
    gLiveInstance = XR_NULL_HANDLE;
    gInstanceDestroying = false;
    ReleaseSRWLockExclusive(&gInstanceLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltResultToString(
    XrInstance instance,
    XrResult value,
    char buffer[XR_MAX_RESULT_STRING_SIZE]) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (buffer == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char* known = nullptr;
#define BASALT_RESULT_ENTRY(name, unused_value) \
    if (known == nullptr && value == name) {    \
        known = #name;                          \
    }
    XR_LIST_ENUM_XrResult(BASALT_RESULT_ENTRY)
#undef BASALT_RESULT_ENTRY
    if (known != nullptr) {
        std::strncpy(buffer, known, XR_MAX_RESULT_STRING_SIZE - 1);
        buffer[XR_MAX_RESULT_STRING_SIZE - 1] = '\0';
    } else {
        std::snprintf(
            buffer,
            XR_MAX_RESULT_STRING_SIZE,
            XR_FAILED(value) ? "XR_UNKNOWN_FAILURE_VALUE_%d" : "XR_UNKNOWN_SUCCESS_VALUE_%d",
            static_cast<int>(value));
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltStructureTypeToString(
    XrInstance instance,
    XrStructureType value,
    char buffer[XR_MAX_STRUCTURE_NAME_SIZE]) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (buffer == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    const char* known = nullptr;
#define BASALT_STRUCTURE_ENTRY(name, unused_value) \
    if (known == nullptr && value == name) {       \
        known = #name;                             \
    }
    XR_LIST_ENUM_XrStructureType(BASALT_STRUCTURE_ENTRY)
#undef BASALT_STRUCTURE_ENTRY
    if (known != nullptr) {
        std::strncpy(buffer, known, XR_MAX_STRUCTURE_NAME_SIZE - 1);
        buffer[XR_MAX_STRUCTURE_NAME_SIZE - 1] = '\0';
    } else {
        std::snprintf(
            buffer,
            XR_MAX_STRUCTURE_NAME_SIZE,
            "XR_UNKNOWN_STRUCTURE_TYPE_%d",
            static_cast<int>(value));
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL basaltGetInstanceProperties(
    XrInstance instance,
    XrInstanceProperties* instanceProperties) {
    if (!basalt::isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (instanceProperties == nullptr ||
        instanceProperties->type != XR_TYPE_INSTANCE_PROPERTIES) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    instanceProperties->runtimeVersion = basalt::kRuntimeVersion;
    std::strncpy(
        instanceProperties->runtimeName,
        "Halliday Windows OpenXR",
        XR_MAX_RUNTIME_NAME_SIZE - 1);
    instanceProperties->runtimeName[XR_MAX_RUNTIME_NAME_SIZE - 1] = '\0';
    return XR_SUCCESS;
}

template <typename Function>
PFN_xrVoidFunction asVoidFunction(Function function) {
    return reinterpret_cast<PFN_xrVoidFunction>(function);
}

}  // namespace

namespace basalt {

bool isValidInstance(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gInstanceLock);
    const bool valid = instance == gLiveInstance && !gInstanceDestroying;
    ReleaseSRWLockShared(&gInstanceLock);
    return valid;
}

bool isD3D11ExtensionEnabled(XrInstance instance) {
    if (instance == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gInstanceLock);
    const bool enabled = instance == gLiveInstance && gD3D11ExtensionEnabled;
    ReleaseSRWLockShared(&gInstanceLock);
    return enabled;
}

bool isD3D12ExtensionEnabled(XrInstance instance) {
    AcquireSRWLockShared(&gInstanceLock);
    const bool result = instance != XR_NULL_HANDLE && instance == gLiveInstance && gD3D12ExtensionEnabled;
    ReleaseSRWLockShared(&gInstanceLock); return result;
}

bool isVulkanExtensionEnabled(XrInstance instance, bool version2) {
    AcquireSRWLockShared(&gInstanceLock);
    const bool result = instance != XR_NULL_HANDLE && instance == gLiveInstance && (version2 ? gVulkan2Enabled : gVulkan1Enabled);
    ReleaseSRWLockShared(&gInstanceLock); return result;
}

XrResult XRAPI_CALL getInstanceProcAddr(
    XrInstance instance,
    const char* name,
    PFN_xrVoidFunction* function) {
    if (function == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *function = nullptr;
    if (name == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (std::strcmp(name, "xrGetInstanceProcAddr") == 0) {
        *function = asVoidFunction(getInstanceProcAddr);
    } else if (std::strcmp(name, "xrEnumerateInstanceExtensionProperties") == 0) {
        *function = asVoidFunction(basaltEnumerateInstanceExtensionProperties);
    } else if (std::strcmp(name, "xrEnumerateApiLayerProperties") == 0) {
        *function = asVoidFunction(basaltEnumerateApiLayerProperties);
    } else if (std::strcmp(name, "xrCreateInstance") == 0) {
        *function = asVoidFunction(basaltCreateInstance);
    } else if (std::strcmp(name, "xrDestroyInstance") == 0) {
        *function = asVoidFunction(basaltDestroyInstance);
    } else if (std::strcmp(name, "xrGetInstanceProperties") == 0) {
        *function = asVoidFunction(basaltGetInstanceProperties);
    } else if (std::strcmp(name, "xrResultToString") == 0) {
        *function = asVoidFunction(basaltResultToString);
    } else if (std::strcmp(name, "xrStructureTypeToString") == 0) {
        *function = asVoidFunction(basaltStructureTypeToString);
    } else if (std::strcmp(name, "xrStringToPath") == 0) {
        *function = asVoidFunction(stringToPath);
    } else if (std::strcmp(name, "xrPathToString") == 0) {
        *function = asVoidFunction(pathToString);
    } else if (std::strcmp(name, "xrCreateActionSet") == 0) {
        *function = asVoidFunction(createActionSet);
    } else if (std::strcmp(name, "xrDestroyActionSet") == 0) {
        *function = asVoidFunction(destroyActionSet);
    } else if (std::strcmp(name, "xrCreateAction") == 0) {
        *function = asVoidFunction(createAction);
    } else if (std::strcmp(name, "xrDestroyAction") == 0) {
        *function = asVoidFunction(destroyAction);
    } else if (std::strcmp(name, "xrSuggestInteractionProfileBindings") == 0) {
        *function = asVoidFunction(suggestInteractionProfileBindings);
    } else if (std::strcmp(name, "xrAttachSessionActionSets") == 0) {
        *function = asVoidFunction(attachSessionActionSets);
    } else if (std::strcmp(name, "xrGetCurrentInteractionProfile") == 0) {
        *function = asVoidFunction(getCurrentInteractionProfile);
    } else if (std::strcmp(name, "xrSyncActions") == 0) {
        *function = asVoidFunction(syncActions);
    } else if (std::strcmp(name, "xrGetActionStateBoolean") == 0) {
        *function = asVoidFunction(getActionStateBoolean);
    } else if (std::strcmp(name, "xrGetActionStateFloat") == 0) {
        *function = asVoidFunction(getActionStateFloat);
    } else if (std::strcmp(name, "xrGetActionStateVector2f") == 0) {
        *function = asVoidFunction(getActionStateVector2f);
    } else if (std::strcmp(name, "xrGetActionStatePose") == 0) {
        *function = asVoidFunction(getActionStatePose);
    } else if (std::strcmp(name, "xrEnumerateBoundSourcesForAction") == 0) {
        *function = asVoidFunction(enumerateBoundSourcesForAction);
    } else if (std::strcmp(name, "xrGetInputSourceLocalizedName") == 0) {
        *function = asVoidFunction(getInputSourceLocalizedName);
    } else if (std::strcmp(name, "xrApplyHapticFeedback") == 0) {
        *function = asVoidFunction(applyHapticFeedback);
    } else if (std::strcmp(name, "xrStopHapticFeedback") == 0) {
        *function = asVoidFunction(stopHapticFeedback);
    } else if (std::strcmp(name, "xrCreateActionSpace") == 0) {
        *function = asVoidFunction(createActionSpace);
    } else if (std::strcmp(name, "xrLocateSpace") == 0) {
        *function = asVoidFunction(locateSpace);
    } else if (std::strcmp(name, "xrLocateViews") == 0) {
        *function = asVoidFunction(locateViews);
    } else if (std::strcmp(name, "xrGetReferenceSpaceBoundsRect") == 0) {
        *function = asVoidFunction(getReferenceSpaceBoundsRect);
    } else if (std::strcmp(name, "xrGetSystem") == 0) {
        *function = asVoidFunction(getSystem);
    } else if (std::strcmp(name, "xrGetSystemProperties") == 0) {
        *function = asVoidFunction(getSystemProperties);
    } else if (std::strcmp(name, "xrEnumerateEnvironmentBlendModes") == 0) {
        *function = asVoidFunction(enumerateEnvironmentBlendModes);
    } else if (std::strcmp(name, "xrEnumerateViewConfigurations") == 0) {
        *function = asVoidFunction(enumerateViewConfigurations);
    } else if (std::strcmp(name, "xrGetViewConfigurationProperties") == 0) {
        *function = asVoidFunction(getViewConfigurationProperties);
    } else if (std::strcmp(name, "xrEnumerateViewConfigurationViews") == 0) {
        *function = asVoidFunction(enumerateViewConfigurationViews);
    } else if (std::strcmp(name, "xrGetD3D11GraphicsRequirementsKHR") == 0 &&
               isD3D11ExtensionEnabled(instance)) {
        *function = asVoidFunction(getD3D11GraphicsRequirements);
    } else if (std::strcmp(name,"xrGetD3D12GraphicsRequirementsKHR") == 0 && isD3D12ExtensionEnabled(instance)) {
        *function = asVoidFunction(getD3D12GraphicsRequirements);
    } else if (isVulkanExtensionEnabled(instance) && std::strcmp(name,"xrGetVulkanGraphicsRequirementsKHR") == 0) {
        *function = asVoidFunction(getVulkanRequirements);
    } else if (isVulkanExtensionEnabled(instance) && std::strcmp(name,"xrGetVulkanInstanceExtensionsKHR") == 0) {
        *function = asVoidFunction(getVulkanInstanceExtensions);
    } else if (isVulkanExtensionEnabled(instance) && std::strcmp(name,"xrGetVulkanDeviceExtensionsKHR") == 0) {
        *function = asVoidFunction(getVulkanDeviceExtensions);
    } else if (isVulkanExtensionEnabled(instance) && std::strcmp(name,"xrGetVulkanGraphicsDeviceKHR") == 0) {
        *function = asVoidFunction(getVulkanGraphicsDevice);
    } else if (isVulkanExtensionEnabled(instance,true) && std::strcmp(name,"xrGetVulkanGraphicsRequirements2KHR") == 0) {
        *function = asVoidFunction(getVulkanRequirements2);
    } else if (isVulkanExtensionEnabled(instance,true) && std::strcmp(name,"xrCreateVulkanInstanceKHR") == 0) {
        *function = asVoidFunction(createVulkanInstance);
    } else if (isVulkanExtensionEnabled(instance,true) && std::strcmp(name,"xrGetVulkanGraphicsDevice2KHR") == 0) {
        *function = asVoidFunction(getVulkanGraphicsDevice2);
    } else if (isVulkanExtensionEnabled(instance,true) && std::strcmp(name,"xrCreateVulkanDeviceKHR") == 0) {
        *function = asVoidFunction(createVulkanDevice);
    } else if (std::strcmp(name, "xrCreateSession") == 0) {
        *function = asVoidFunction(createSession);
    } else if (std::strcmp(name, "xrDestroySession") == 0) {
        *function = asVoidFunction(destroySession);
    } else if (std::strcmp(name, "xrPollEvent") == 0) {
        *function = asVoidFunction(pollEvent);
    } else if (std::strcmp(name, "xrBeginSession") == 0) {
        *function = asVoidFunction(beginSession);
    } else if (std::strcmp(name, "xrEndSession") == 0) {
        *function = asVoidFunction(endSession);
    } else if (std::strcmp(name, "xrRequestExitSession") == 0) {
        *function = asVoidFunction(requestExitSession);
    } else if (std::strcmp(name, "xrWaitFrame") == 0) {
        *function = asVoidFunction(waitFrame);
    } else if (std::strcmp(name, "xrBeginFrame") == 0) {
        *function = asVoidFunction(beginFrame);
    } else if (std::strcmp(name, "xrEndFrame") == 0) {
        *function = asVoidFunction(endFrame);
    } else if (std::strcmp(name, "xrEnumerateReferenceSpaces") == 0) {
        *function = asVoidFunction(enumerateReferenceSpaces);
    } else if (std::strcmp(name, "xrCreateReferenceSpace") == 0) {
        *function = asVoidFunction(createReferenceSpace);
    } else if (std::strcmp(name, "xrDestroySpace") == 0) {
        *function = asVoidFunction(destroySpace);
    } else if (std::strcmp(name, "xrEnumerateSwapchainFormats") == 0) {
        *function = asVoidFunction(enumerateSwapchainFormats);
    } else if (std::strcmp(name, "xrCreateSwapchain") == 0) {
        *function = asVoidFunction(createSwapchain);
    } else if (std::strcmp(name, "xrDestroySwapchain") == 0) {
        *function = asVoidFunction(destroySwapchain);
    } else if (std::strcmp(name, "xrEnumerateSwapchainImages") == 0) {
        *function = asVoidFunction(enumerateSwapchainImages);
    } else if (std::strcmp(name, "xrAcquireSwapchainImage") == 0) {
        *function = asVoidFunction(acquireSwapchainImage);
    } else if (std::strcmp(name, "xrWaitSwapchainImage") == 0) {
        *function = asVoidFunction(waitSwapchainImage);
    } else if (std::strcmp(name, "xrReleaseSwapchainImage") == 0) {
        *function = asVoidFunction(releaseSwapchainImage);
    }

    const bool globalCommand = std::strcmp(name, "xrEnumerateInstanceExtensionProperties") == 0 ||
                               std::strcmp(name, "xrEnumerateApiLayerProperties") == 0 ||
                               std::strcmp(name, "xrCreateInstance") == 0;
    if (instance == XR_NULL_HANDLE && !globalCommand) {
        *function = nullptr;
        return XR_ERROR_HANDLE_INVALID;
    }
    if (instance != XR_NULL_HANDLE && !isValidInstance(instance)) {
        *function = nullptr;
        return XR_ERROR_HANDLE_INVALID;
    }
    if (*function == nullptr) {
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    return XR_SUCCESS;
}

}  // namespace basalt
