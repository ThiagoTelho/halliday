// Derived from BasaltVR c104bc0b489384745157bc42e357f08d17e41638 (MIT).
// Copyright (c) 2026 BasaltVR contributors. See LICENSE-BasaltVR.
#include "runtime.hpp"

#include "control.hpp"
#include "vulkan_backend.hpp"
#include "d3d12_probe.hpp"

#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstring>
#include <cstdio>

namespace {

constexpr uintptr_t kFirstSessionHandle = static_cast<uintptr_t>(0x20000);
constexpr uintptr_t kSessionHandleStride = static_cast<uintptr_t>(0x10);
constexpr D3D_FEATURE_LEVEL kMinimumFeatureLevel = D3D_FEATURE_LEVEL_11_0;

SRWLOCK gGraphicsLock = SRWLOCK_INIT;
XrInstance gRequirementsInstance = XR_NULL_HANDLE;
LUID gRequiredAdapterLuid{};
uintptr_t gNextSessionHandle = kFirstSessionHandle;
XrSession gLiveSession = XR_NULL_HANDLE;
bool gSessionDestroying = false;
XrInstance gSessionInstance = XR_NULL_HANDLE;
ID3D11Device* gSessionDevice = nullptr;
ID3D12Device* gSessionDevice12 = nullptr;
ID3D12CommandQueue* gSessionQueue12 = nullptr;
void* gSessionVulkan = nullptr;
XrInstance gRequirementsInstance12 = XR_NULL_HANDLE;
INIT_ONCE gCapabilityOnce12 = INIT_ONCE_STATIC_INIT;
bool gD3D12RuntimeAvailable = false;
LUID gCapabilityAdapterLuid12{};

INIT_ONCE gCapabilityOnce = INIT_ONCE_STATIC_INIT;
bool gD3D11RuntimeAvailable = false;
LUID gCapabilityAdapterLuid{};

bool luidEqual(const LUID& left, const LUID& right) {
    return left.LowPart == right.LowPart && left.HighPart == right.HighPart;
}

BOOL CALLBACK initializeCapability12(PINIT_ONCE, PVOID, PVOID*) {
    LUID adapter{};
    if (SUCCEEDED(halliday::probeD3D12Readback(&adapter))) {
        gCapabilityAdapterLuid12 = adapter;
        gD3D12RuntimeAvailable = true;
    }
    return TRUE;
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

HRESULT probeD3D11Readback(LUID* luid) {
    constexpr uint32_t kWidth = 2;
    constexpr uint32_t kHeight = 2;
    constexpr uint32_t kPixels[kWidth * kHeight] = {
        0xff030201,
        0xff060504,
        0xff090807,
        0xff0c0b0a,
    };

    IDXGIFactory1* factory = nullptr;
    HRESULT result = CreateDXGIFactory1(
        __uuidof(IDXGIFactory1),
        reinterpret_cast<void**>(&factory));
    if (FAILED(result)) {
        return result;
    }

    IDXGIAdapter1* adapter = nullptr;
    result = factory->EnumAdapters1(0, &adapter);
    factory->Release();
    if (FAILED(result)) {
        return result;
    }

    DXGI_ADAPTER_DESC1 description{};
    result = adapter->GetDesc1(&description);
    if (FAILED(result)) {
        release(adapter);
        return result;
    }

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL selectedFeatureLevel{};
    const D3D_FEATURE_LEVEL featureLevels[] = {kMinimumFeatureLevel};
    result = D3D11CreateDevice(
        adapter,
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        featureLevels,
        1,
        D3D11_SDK_VERSION,
        &device,
        &selectedFeatureLevel,
        &context);
    release(adapter);
    if (FAILED(result) || selectedFeatureLevel < kMinimumFeatureLevel) {
        release(context);
        release(device);
        return FAILED(result) ? result : E_FAIL;
    }

    D3D11_TEXTURE2D_DESC sharedDescription{};
    sharedDescription.Width = kWidth;
    sharedDescription.Height = kHeight;
    sharedDescription.MipLevels = 1;
    sharedDescription.ArraySize = 1;
    sharedDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sharedDescription.SampleDesc.Count = 1;
    sharedDescription.Usage = D3D11_USAGE_DEFAULT;
    sharedDescription.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    sharedDescription.MiscFlags = 0;

    D3D11_SUBRESOURCE_DATA initialData{};
    initialData.pSysMem = kPixels;
    initialData.SysMemPitch = kWidth * sizeof(uint32_t);

    ID3D11Texture2D* sharedTexture = nullptr;
    result = device->CreateTexture2D(&sharedDescription, &initialData, &sharedTexture);
    ID3D11Texture2D* stagingTexture = nullptr;

    if (SUCCEEDED(result)) {
        D3D11_TEXTURE2D_DESC stagingDescription = sharedDescription;
        stagingDescription.Usage = D3D11_USAGE_STAGING;
        stagingDescription.BindFlags = 0;
        stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        stagingDescription.MiscFlags = 0;
        result = device->CreateTexture2D(&stagingDescription, nullptr, &stagingTexture);
    }
    if (SUCCEEDED(result)) {
        context->CopyResource(stagingTexture, sharedTexture);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        result = context->Map(stagingTexture, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(result)) {
            for (uint32_t row = 0; row < kHeight; ++row) {
                const auto* actual = static_cast<const uint8_t*>(mapped.pData) + row * mapped.RowPitch;
                const auto* expected = reinterpret_cast<const uint8_t*>(kPixels) +
                                       row * kWidth * sizeof(uint32_t);
                if (std::memcmp(actual, expected, kWidth * sizeof(uint32_t)) != 0) {
                    result = E_FAIL;
                    break;
                }
            }
            context->Unmap(stagingTexture, 0);
        }
    }

    release(stagingTexture);
    release(sharedTexture);
    release(context);
    release(device);

    if (SUCCEEDED(result)) {
        *luid = description.AdapterLuid;
    }
    return result;
}

BOOL CALLBACK initializeCapability(PINIT_ONCE, PVOID, PVOID*) {
    LUID adapterLuid{};
    if (SUCCEEDED(probeD3D11Readback(&adapterLuid))) {
        gCapabilityAdapterLuid = adapterLuid;
        gD3D11RuntimeAvailable = true;
    }
    return TRUE;
}

HRESULT deviceAdapterLuid(ID3D11Device* device, LUID* luid) {
    if (device == nullptr || luid == nullptr) {
        return E_POINTER;
    }

    IDXGIDevice* dxgiDevice = nullptr;
    HRESULT result = device->QueryInterface(
        __uuidof(IDXGIDevice),
        reinterpret_cast<void**>(&dxgiDevice));
    if (FAILED(result)) {
        return result;
    }

    IDXGIAdapter* adapter = nullptr;
    result = dxgiDevice->GetAdapter(&adapter);
    dxgiDevice->Release();
    if (FAILED(result)) {
        return result;
    }

    DXGI_ADAPTER_DESC description{};
    result = adapter->GetDesc(&description);
    adapter->Release();
    if (SUCCEEDED(result)) {
        *luid = description.AdapterLuid;
    }
    return result;
}

const XrGraphicsBindingD3D11KHR* findD3D11Binding(const void* next) {
    const auto* structure = static_cast<const XrBaseInStructure*>(next);
    while (structure != nullptr) {
        if (structure->type == XR_TYPE_GRAPHICS_BINDING_D3D11_KHR) {
            return reinterpret_cast<const XrGraphicsBindingD3D11KHR*>(structure);
        }
        structure = structure->next;
    }
    return nullptr;
}

}  // namespace

namespace basalt {

bool isD3D11RuntimeAvailable() {
    InitOnceExecuteOnce(&gCapabilityOnce, initializeCapability, nullptr, nullptr);
    return gD3D11RuntimeAvailable;
}

bool isD3D12RuntimeAvailable() {
    InitOnceExecuteOnce(&gCapabilityOnce12,initializeCapability12,nullptr,nullptr);
    return gD3D12RuntimeAvailable;
}

XrResult XRAPI_CALL getD3D12GraphicsRequirements(XrInstance instance,XrSystemId systemId,
                                              XrGraphicsRequirementsD3D12KHR* out) {
    if (!isValidInstance(instance)) return XR_ERROR_HANDLE_INVALID;
    if (!isD3D12ExtensionEnabled(instance)) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (systemId != kSystemId) return XR_ERROR_SYSTEM_INVALID;
    if (!out || out->type != XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR) return XR_ERROR_VALIDATION_FAILURE;
    if (!isD3D12RuntimeAvailable()) return XR_ERROR_RUNTIME_FAILURE;
    out->adapterLuid = gCapabilityAdapterLuid12; out->minFeatureLevel = D3D_FEATURE_LEVEL_11_0;
    AcquireSRWLockExclusive(&gGraphicsLock); gRequirementsInstance12 = instance;
    ReleaseSRWLockExclusive(&gGraphicsLock); return XR_SUCCESS;
}

static XrResult createSession12(XrInstance instance,const XrGraphicsBindingD3D12KHR* binding,XrSession* session) {
    if (!isD3D12ExtensionEnabled(instance)) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    AcquireSRWLockShared(&gGraphicsLock);
    const bool queried = gRequirementsInstance12 == instance;
    ReleaseSRWLockShared(&gGraphicsLock);
    if (!queried) return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    if (!binding->device || !binding->queue) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    const auto actualLuid = binding->device->GetAdapterLuid();
    if (binding->queue->GetDesc().Type != D3D12_COMMAND_LIST_TYPE_DIRECT ||
        !luidEqual(actualLuid,gCapabilityAdapterLuid12)) {
        std::fprintf(stderr,"Halliday Windows OpenXR: D3D12 binding mismatch (queue type %u, adapter %08x:%08lx, required %08x:%08lx)\n",
            static_cast<unsigned>(binding->queue->GetDesc().Type),static_cast<unsigned>(actualLuid.HighPart),
            actualLuid.LowPart,static_cast<unsigned>(gCapabilityAdapterLuid12.HighPart),gCapabilityAdapterLuid12.LowPart);
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    ID3D12Device* queueDevice = nullptr;
    const HRESULT status = binding->queue->GetDevice(IID_PPV_ARGS(&queueDevice));
    if (FAILED(status)) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    IUnknown* deviceIdentity = nullptr; IUnknown* queueIdentity = nullptr;
    binding->device->QueryInterface(IID_PPV_ARGS(&deviceIdentity));
    queueDevice->QueryInterface(IID_PPV_ARGS(&queueIdentity));
    // The same ID3D12Device pointer is already an identity proof. Some Wine
    // backends expose a distinct IUnknown wrapper when queried through a queue.
    const bool matches = queueDevice == binding->device ||
        (deviceIdentity && deviceIdentity == queueIdentity);
    const auto* queueDeviceAddress = queueDevice;
    release(deviceIdentity); release(queueIdentity); release(queueDevice);
    if (!matches) {
        std::fprintf(stderr,"Halliday Windows OpenXR: D3D12 queue belongs to a different device (%p versus %p)\n",
            static_cast<const void*>(queueDeviceAddress),static_cast<void*>(binding->device));
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    AcquireSRWLockExclusive(&gGraphicsLock);
    if (gLiveSession != XR_NULL_HANDLE || gNextSessionHandle > UINTPTR_MAX-kSessionHandleStride) {
        ReleaseSRWLockExclusive(&gGraphicsLock); return XR_ERROR_LIMIT_REACHED;
    }
    gLiveSession = reinterpret_cast<XrSession>(gNextSessionHandle); gNextSessionHandle += kSessionHandleStride;
    gSessionInstance = instance; gSessionDevice12 = binding->device; gSessionQueue12 = binding->queue;
    binding->device->AddRef(); binding->queue->AddRef(); *session = gLiveSession;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    initializeSessionLifecycle(instance,*session);
    controlSessionCreated12(*session,binding->device,binding->queue);
    if (!controlActive(*session)) {
        destroySession(*session); *session = XR_NULL_HANDLE; return XR_ERROR_RUNTIME_FAILURE;
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL getD3D11GraphicsRequirements(
    XrInstance instance,
    XrSystemId systemId,
    XrGraphicsRequirementsD3D11KHR* graphicsRequirements) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (!isD3D11ExtensionEnabled(instance)) {
        return XR_ERROR_FUNCTION_UNSUPPORTED;
    }
    if (systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    if (graphicsRequirements == nullptr ||
        graphicsRequirements->type != XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    if (!isD3D11RuntimeAvailable()) {
        return XR_ERROR_RUNTIME_FAILURE;
    }

    graphicsRequirements->adapterLuid = gCapabilityAdapterLuid;
    graphicsRequirements->minFeatureLevel = kMinimumFeatureLevel;

    AcquireSRWLockExclusive(&gGraphicsLock);
    gRequirementsInstance = instance;
    gRequiredAdapterLuid = gCapabilityAdapterLuid;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createSession(
    XrInstance instance,
    const XrSessionCreateInfo* createInfo,
    XrSession* session) {
    if (!isValidInstance(instance)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (session == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *session = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_SESSION_CREATE_INFO ||
        createInfo->createFlags != 0) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (createInfo->systemId != kSystemId) {
        return XR_ERROR_SYSTEM_INVALID;
    }
    for (auto* next = static_cast<const XrBaseInStructure*>(createInfo->next); next; next = next->next) {
        if (next->type == XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR) {
            void* context = nullptr;
            XrResult result = makeVulkanContext(instance,*reinterpret_cast<const XrGraphicsBindingVulkanKHR*>(next),&context);
            if (XR_FAILED(result)) return result;
            AcquireSRWLockExclusive(&gGraphicsLock);
            if (gLiveSession || gNextSessionHandle > UINTPTR_MAX-kSessionHandleStride) {
                ReleaseSRWLockExclusive(&gGraphicsLock); hxvk_destroy_context(context); return XR_ERROR_LIMIT_REACHED;
            }
            gLiveSession = reinterpret_cast<XrSession>(gNextSessionHandle); gNextSessionHandle += kSessionHandleStride;
            gSessionInstance = instance; gSessionVulkan = context; *session = gLiveSession;
            ReleaseSRWLockExclusive(&gGraphicsLock);
            initializeSessionLifecycle(instance,*session); controlSessionCreatedVulkan(*session,context);
            if (!controlActive(*session)) { destroySession(*session); *session=XR_NULL_HANDLE; return XR_ERROR_RUNTIME_FAILURE; }
            return XR_SUCCESS;
        }
        if (next->type == XR_TYPE_GRAPHICS_BINDING_D3D12_KHR)
            return createSession12(instance,reinterpret_cast<const XrGraphicsBindingD3D12KHR*>(next),session);
    }
    if (!isD3D11ExtensionEnabled(instance)) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }

    AcquireSRWLockShared(&gGraphicsLock);
    const bool requirementsQueried = gRequirementsInstance == instance;
    const LUID requiredAdapterLuid = gRequiredAdapterLuid;
    ReleaseSRWLockShared(&gGraphicsLock);
    if (!requirementsQueried) {
        return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    }

    const XrGraphicsBindingD3D11KHR* binding = findD3D11Binding(createInfo->next);
    if (binding == nullptr || binding->device == nullptr) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    if (binding->device->GetFeatureLevel() < kMinimumFeatureLevel) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }
    LUID deviceLuid{};
    if (FAILED(deviceAdapterLuid(binding->device, &deviceLuid)) ||
        !luidEqual(deviceLuid, requiredAdapterLuid)) {
        return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    }

    AcquireSRWLockExclusive(&gGraphicsLock);
    if (gLiveSession != XR_NULL_HANDLE) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    if (gNextSessionHandle > UINTPTR_MAX - kSessionHandleStride) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_LIMIT_REACHED;
    }
    gLiveSession = reinterpret_cast<XrSession>(gNextSessionHandle);
    gNextSessionHandle += kSessionHandleStride;
    gSessionInstance = instance;
    binding->device->AddRef();
    gSessionDevice = binding->device;
    *session = gLiveSession;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    initializeSessionLifecycle(instance, *session);
    controlSessionCreated(*session, binding->device);
    if (!controlActive(*session)) {
        destroySession(*session);
        *session = XR_NULL_HANDLE;
        return XR_ERROR_RUNTIME_FAILURE;
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroySession(XrSession session) {
    if (session == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    AcquireSRWLockExclusive(&gGraphicsLock);
    if (session != gLiveSession || gSessionDestroying) {
        ReleaseSRWLockExclusive(&gGraphicsLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    ID3D11Device* device = gSessionDevice;
    ID3D12Device* device12 = gSessionDevice12;
    ID3D12CommandQueue* queue12 = gSessionQueue12;
    void* vulkan = gSessionVulkan; gSessionVulkan = nullptr;
    // A different thread may create another session on the same live instance.
    // Keep this slot occupied until global control/transfer cleanup and the
    // heartbeat join finish; otherwise creation can overwrite those resources.
    gSessionDestroying = true;
    gSessionDevice = nullptr;
    gSessionDevice12 = nullptr; gSessionQueue12 = nullptr;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    controlSessionDestroyed(session);
    invalidateSessionLifecycle(session);
    invalidateSpacesForSession(session);
    invalidateSwapchainForSession(session);
    invalidateInputForSession(session);
    release(device);
    release(device12); release(queue12);
    hxvk_destroy_context(vulkan);
    AcquireSRWLockExclusive(&gGraphicsLock);
    gLiveSession = XR_NULL_HANDLE;
    gSessionInstance = XR_NULL_HANDLE;
    gSessionDestroying = false;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    return XR_SUCCESS;
}

bool isValidSession(XrSession session) {
    if (session == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gGraphicsLock);
    const bool valid = session == gLiveSession && !gSessionDestroying;
    ReleaseSRWLockShared(&gGraphicsLock);
    return valid;
}

ID3D11Device* retainSessionDevice(XrSession session) {
    AcquireSRWLockShared(&gGraphicsLock);
    ID3D11Device* device = nullptr;
    if (session == gLiveSession && !gSessionDestroying && gSessionDevice != nullptr) {
        gSessionDevice->AddRef();
        device = gSessionDevice;
    }
    ReleaseSRWLockShared(&gGraphicsLock);
    return device;
}

ID3D12Device* retainSessionDevice12(XrSession session) {
    AcquireSRWLockShared(&gGraphicsLock);
    ID3D12Device* device = session == gLiveSession && !gSessionDestroying ? gSessionDevice12 : nullptr;
    if (device) device->AddRef();
    ReleaseSRWLockShared(&gGraphicsLock); return device;
}

void* sessionVulkanContext(XrSession session) {
    AcquireSRWLockShared(&gGraphicsLock);
    void* context = session == gLiveSession && !gSessionDestroying ? gSessionVulkan : nullptr;
    ReleaseSRWLockShared(&gGraphicsLock); return context;
}

void invalidateSessionForInstance(XrInstance instance) {
    XrSession session = XR_NULL_HANDLE;
    ID3D11Device* device = nullptr;
    ID3D12Device* device12 = nullptr; ID3D12CommandQueue* queue12 = nullptr;
    void* vulkan = nullptr;
    AcquireSRWLockExclusive(&gGraphicsLock);
    if (gSessionInstance == instance && !gSessionDestroying) {
        session = gLiveSession;
        device = gSessionDevice;
        device12 = gSessionDevice12; queue12 = gSessionQueue12;
        vulkan = gSessionVulkan; gSessionVulkan = nullptr;
        gSessionDestroying = true;
        gSessionDevice = nullptr;
        gSessionDevice12 = nullptr; gSessionQueue12 = nullptr;
    }
    if (gRequirementsInstance == instance) {
        gRequirementsInstance = XR_NULL_HANDLE;
        gRequiredAdapterLuid = {};
    }
    if (gRequirementsInstance12 == instance) gRequirementsInstance12 = XR_NULL_HANDLE;
    ReleaseSRWLockExclusive(&gGraphicsLock);
    if (session != XR_NULL_HANDLE) {
        controlSessionDestroyed(session);
        invalidateSessionLifecycle(session);
        invalidateSpacesForSession(session);
        invalidateSwapchainForSession(session);
        invalidateInputForSession(session);
    }
    release(device);
    release(device12); release(queue12);
    hxvk_destroy_context(vulkan);
    if (session != XR_NULL_HANDLE) {
        AcquireSRWLockExclusive(&gGraphicsLock);
        gLiveSession = XR_NULL_HANDLE;
        gSessionInstance = XR_NULL_HANDLE;
        gSessionDestroying = false;
        ReleaseSRWLockExclusive(&gGraphicsLock);
    }
}

}  // namespace basalt
