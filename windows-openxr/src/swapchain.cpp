// Derived from BasaltVR c104bc0b489384745157bc42e357f08d17e41638 (MIT).
// Copyright (c) 2026 BasaltVR contributors. See LICENSE-BasaltVR.
#include "runtime.hpp"
#include "vulkan_backend.hpp"

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>

#include <array>
#include <cstdint>

#include "control.hpp"

namespace {

constexpr uintptr_t kFirstSwapchainHandle = static_cast<uintptr_t>(0x30000);
constexpr uintptr_t kSwapchainHandleStride = static_cast<uintptr_t>(0x10);
constexpr uint32_t kSwapchainImageCount = 3;
constexpr uint32_t kMaxArraySize = 2;
// Two separate projection eye textures plus one texture per supported quad.
constexpr size_t kMaxSwapchains = 10;

constexpr std::array<DXGI_FORMAT, 4> kSupportedFormats = {
    // Runtime order is preference order. The native CoreVideo handoff can
    // wrap BGRA IOSurfaces directly, while CVPixelBuffer rejects DXMT's RGBA
    // IOSurfaces. Do not advertise formats the compositor cannot deliver.
    DXGI_FORMAT_B8G8R8A8_UNORM,
    DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
    DXGI_FORMAT_R8G8B8A8_UNORM,
    DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
};

enum class ImageState {
    Available,
    Acquired,
    Waited,
};

struct SwapchainRecord {
    XrSwapchain handle = XR_NULL_HANDLE;
    XrSession session = XR_NULL_HANDLE;
    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    std::array<ID3D12Resource*, kSwapchainImageCount> textures12{};
    std::array<std::shared_ptr<void>, kSwapchainImageCount> vkImages{};
    VkFormat vkFormat = VK_FORMAT_UNDEFINED;
    std::array<ImageState, kSwapchainImageCount> imageStates{};
    // Wait and release apply to the oldest acquired image (OpenXR FIFO), so
    // each acquire is stamped with a monotonically increasing sequence.
    std::array<uint64_t, kSwapchainImageCount> acquireSequence{};
    uint64_t nextAcquireSequence = 1;
    uint32_t nextAcquireIndex = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t arraySize = 0;
    uint32_t colorSpace = 0;
    bool everReleased = false;
    uint32_t lastReleasedIndex = 0;
    uint32_t imageCount = kSwapchainImageCount;
    bool staticImage = false;
    bool staticAcquired = false;
};

SRWLOCK gSwapchainLock = SRWLOCK_INIT;
uintptr_t gNextSwapchainHandle = kFirstSwapchainHandle;
std::array<SwapchainRecord, kMaxSwapchains> gSwapchains{};

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

// UE4 titles create their eye textures as B8G8R8A8_TYPELESS and rely on their
// own resource views for the sRGB/linear interpretation, then hand that format
// straight to xrCreateSwapchain. Back the request with the typed BGRA format
// the compositor can export instead of rejecting the swapchain.
DXGI_FORMAT normalizeFormat(int64_t format) {
    if (format == static_cast<int64_t>(DXGI_FORMAT_B8G8R8A8_TYPELESS)) {
        return DXGI_FORMAT_B8G8R8A8_UNORM;
    }
    if (format == static_cast<int64_t>(DXGI_FORMAT_R8G8B8A8_TYPELESS)) {
        return DXGI_FORMAT_R8G8B8A8_UNORM;
    }
    return static_cast<DXGI_FORMAT>(format);
}

DXGI_FORMAT storageFormat(const XrSwapchainCreateInfo& info) {
    const auto typed = normalizeFormat(info.format);
    if ((info.usageFlags & XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT) ||
        info.format == DXGI_FORMAT_B8G8R8A8_TYPELESS || info.format == DXGI_FORMAT_R8G8B8A8_TYPELESS) {
        return typed == DXGI_FORMAT_B8G8R8A8_UNORM || typed == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB
            ? DXGI_FORMAT_B8G8R8A8_TYPELESS : DXGI_FORMAT_R8G8B8A8_TYPELESS;
    }
    return typed;
}

bool isSupportedFormat(int64_t format) {
    // The public identifier is 64-bit. Validate it before narrowing to the
    // graphics API enum, or unsupported high bits silently alias a real format.
    if (format == DXGI_FORMAT_B8G8R8A8_TYPELESS || format == DXGI_FORMAT_R8G8B8A8_TYPELESS)
        return true;
    for (DXGI_FORMAT supported : kSupportedFormats) {
        if (format == static_cast<int64_t>(supported)) {
            return true;
        }
    }
    return false;
}

UINT bindFlagsForUsage(XrSwapchainUsageFlags usageFlags) {
    UINT bindFlags = 0;
    if ((usageFlags & XR_SWAPCHAIN_USAGE_SAMPLED_BIT) != 0) {
        bindFlags |= D3D11_BIND_SHADER_RESOURCE;
    }
    if ((usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) != 0) {
        bindFlags |= D3D11_BIND_RENDER_TARGET;
    }
    if ((usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT) != 0) {
        bindFlags |= D3D11_BIND_UNORDERED_ACCESS;
    }
    return bindFlags;
}

template <typename T>
void releaseTextures(std::array<T*, kSwapchainImageCount>& textures) {
    for (T*& texture : textures) {
        release(texture);
    }
}


SwapchainRecord* findSwapchainLocked(XrSwapchain swapchain) {
    for (SwapchainRecord& record : gSwapchains) {
        if (record.handle == swapchain) {
            return &record;
        }
    }
    return nullptr;
}

// Returns kSwapchainImageCount when no image is in the requested state.
uint32_t oldestImageInStateLocked(const SwapchainRecord& record, ImageState state) {
    uint32_t oldest = kSwapchainImageCount;
    for (uint32_t index = 0; index < record.imageCount; ++index) {
        if (record.imageStates[index] == state &&
            (oldest == kSwapchainImageCount ||
             record.acquireSequence[index] < record.acquireSequence[oldest])) {
            oldest = index;
        }
    }
    return oldest;
}

}  // namespace

namespace basalt {

XrResult XRAPI_CALL enumerateSwapchainFormats(
    XrSession session,
    uint32_t formatCapacityInput,
    uint32_t* formatCountOutput,
    int64_t* formats) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (formatCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    *formatCountOutput = static_cast<uint32_t>(kSupportedFormats.size());
    if (formatCapacityInput == 0) {
        return XR_SUCCESS;
    }
    if (formats == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (formatCapacityInput < kSupportedFormats.size()) {
        return XR_ERROR_SIZE_INSUFFICIENT;
    }
    const std::array<int64_t,4> vulkanFormats{VK_FORMAT_B8G8R8A8_UNORM,VK_FORMAT_B8G8R8A8_SRGB,VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_R8G8B8A8_SRGB};
    const bool vulkan = sessionVulkanContext(session) != nullptr;
    for (size_t index = 0; index < kSupportedFormats.size(); ++index) {
        formats[index] = vulkan ? vulkanFormats[index] : static_cast<int64_t>(kSupportedFormats[index]);
    }
    return XR_SUCCESS;
}

XrResult XRAPI_CALL createSwapchain(
    XrSession session,
    const XrSwapchainCreateInfo* createInfo,
    XrSwapchain* swapchain) {
    if (!isValidSession(session)) {
        return XR_ERROR_HANDLE_INVALID;
    }
    if (swapchain == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *swapchain = XR_NULL_HANDLE;
    if (createInfo == nullptr || createInfo->type != XR_TYPE_SWAPCHAIN_CREATE_INFO ||
        (createInfo->createFlags & ~(XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT |
            XR_SWAPCHAIN_CREATE_PROTECTED_CONTENT_BIT)) != 0 ||
        createInfo->width == 0 || createInfo->height == 0 ||
        createInfo->width > basalt::kMaxSwapchainWidth ||
        createInfo->height > basalt::kMaxSwapchainHeight ||
        createInfo->arraySize == 0 || createInfo->arraySize > kMaxArraySize ||
        createInfo->faceCount != 1 || createInfo->mipCount != 1 ||
        createInfo->sampleCount != 1) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    // This CPU-readable transport cannot provide protected GPU memory.
    if (createInfo->createFlags & XR_SWAPCHAIN_CREATE_PROTECTED_CONTENT_BIT)
        return XR_ERROR_FEATURE_UNSUPPORTED;
    constexpr XrSwapchainUsageFlags supportedUsage = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
        XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT |
        XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT | XR_SWAPCHAIN_USAGE_MUTABLE_FORMAT_BIT;
    // Input attachments need an extension/graphics contract we do not expose;
    // depth is not transported. Never discard either request silently.
    if (createInfo->usageFlags & ~supportedUsage) return XR_ERROR_FEATURE_UNSUPPORTED;
    const bool staticImage = (createInfo->createFlags & XR_SWAPCHAIN_CREATE_STATIC_IMAGE_BIT) != 0;
    const uint32_t imageCount = staticImage ? 1u : kSwapchainImageCount;
    void* vulkan = sessionVulkanContext(session);
    const bool vkSupported = createInfo->format==VK_FORMAT_R8G8B8A8_UNORM||createInfo->format==VK_FORMAT_R8G8B8A8_SRGB||
        createInfo->format==VK_FORMAT_B8G8R8A8_UNORM||createInfo->format==VK_FORMAT_B8G8R8A8_SRGB;
    if (vulkan ? !vkSupported : !isSupportedFormat(createInfo->format)) {
        return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    }
    ID3D12Device* device12 = vulkan ? nullptr : retainSessionDevice12(session);
    ID3D11Device* device = device12 || vulkan ? nullptr : retainSessionDevice(session);
    if (!device && !device12 && !vulkan) return XR_ERROR_HANDLE_INVALID;
    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    std::array<ID3D12Resource*, kSwapchainImageCount> textures12{};
    std::array<std::shared_ptr<void>,kSwapchainImageCount> vkImages{};
    HRESULT result = S_OK;
    if (vulkan) {
        for (uint32_t index = 0; index < imageCount; ++index) {
            auto& image = vkImages[index];
            image = std::shared_ptr<void>(hxvk_image(vulkan,createInfo->format,createInfo->width,createInfo->height,
                createInfo->arraySize,createInfo->usageFlags),hxvk_destroy_image);
            if (!image) { result=E_FAIL; break; }
        }
    } else if (device12) {
        if (createInfo->usageFlags && !(createInfo->usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT)) {
            device12->Release(); return XR_ERROR_FEATURE_UNSUPPORTED;
        }
        D3D12_HEAP_PROPERTIES heap{}; heap.Type = D3D12_HEAP_TYPE_DEFAULT;
        heap.CreationNodeMask = heap.VisibleNodeMask = 1;
        D3D12_RESOURCE_DESC desc{}; desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = createInfo->width; desc.Height = createInfo->height;
        desc.DepthOrArraySize = static_cast<UINT16>(createInfo->arraySize); desc.MipLevels = 1;
        desc.Format = storageFormat(*createInfo); desc.SampleDesc.Count = 1;
        desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if (createInfo->usageFlags & XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT)
            desc.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        if (!(createInfo->usageFlags & XR_SWAPCHAIN_USAGE_SAMPLED_BIT))
            desc.Flags |= D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;
        for (uint32_t index = 0; index < imageCount; ++index) {
            auto*& texture = textures12[index];
            result = device12->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,
                D3D12_RESOURCE_STATE_RENDER_TARGET,nullptr,IID_PPV_ARGS(&texture));
            if (FAILED(result)) break;
        }
        device12->Release();
    } else {
        D3D11_TEXTURE2D_DESC description{};
        description.Width = createInfo->width; description.Height = createInfo->height;
        description.MipLevels = 1; description.ArraySize = createInfo->arraySize;
        description.Format = storageFormat(*createInfo); description.SampleDesc.Count = 1;
        description.Usage = D3D11_USAGE_DEFAULT; description.BindFlags = bindFlagsForUsage(createInfo->usageFlags);
        for (uint32_t index = 0; index < imageCount; ++index) {
            auto*& texture = textures[index];
            result = device->CreateTexture2D(&description,nullptr,&texture);
            if (FAILED(result)) break;
        }
        device->Release();
    }
    if (FAILED(result)) { releaseTextures(textures); releaseTextures(textures12); return XR_ERROR_RUNTIME_FAILURE; }

    AcquireSRWLockExclusive(&gSwapchainLock);
    if (!isValidSession(session)) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        releaseTextures(textures);
        releaseTextures(textures12);
        return XR_ERROR_HANDLE_INVALID;
    }
    SwapchainRecord* available = nullptr;
    for (SwapchainRecord& record : gSwapchains) {
        if (record.handle == XR_NULL_HANDLE) {
            available = &record;
            break;
        }
    }
    if (available == nullptr ||
        gNextSwapchainHandle > UINTPTR_MAX - kSwapchainHandleStride) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        releaseTextures(textures);
        releaseTextures(textures12);
        return XR_ERROR_LIMIT_REACHED;
    }

    available->handle = reinterpret_cast<XrSwapchain>(gNextSwapchainHandle);
    gNextSwapchainHandle += kSwapchainHandleStride;
    available->session = session;
    available->textures = textures;
    available->textures12 = textures12;
    available->vkImages = std::move(vkImages);
    available->vkFormat = vulkan ? VkFormat(createInfo->format) : VK_FORMAT_UNDEFINED;
    available->imageStates.fill(ImageState::Available);
    available->nextAcquireIndex = 0;
    available->width = createInfo->width;
    available->height = createInfo->height;
    available->arraySize = createInfo->arraySize;
    // Preserve a legacy typeless request: its application's RTV may choose
    // either encoding, so normalizing the resource must not invent linearity.
    available->colorSpace = createInfo->format == DXGI_FORMAT_B8G8R8A8_TYPELESS || createInfo->format == DXGI_FORMAT_R8G8B8A8_TYPELESS ? 0 :
        (createInfo->format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB ||
         createInfo->format == DXGI_FORMAT_B8G8R8A8_UNORM_SRGB ? 2 : 1);
    if (vulkan) available->colorSpace = createInfo->format==VK_FORMAT_B8G8R8A8_SRGB||createInfo->format==VK_FORMAT_R8G8B8A8_SRGB ? 2 : 1;
    available->everReleased = false;
    available->lastReleasedIndex = 0;
    available->imageCount = imageCount;
    available->staticImage = staticImage;
    available->staticAcquired = false;
    *swapchain = available->handle;
    ReleaseSRWLockExclusive(&gSwapchainLock);

    return XR_SUCCESS;
}

XrResult XRAPI_CALL destroySwapchain(XrSwapchain swapchain) {
    if (swapchain == XR_NULL_HANDLE) {
        return XR_ERROR_HANDLE_INVALID;
    }

    std::array<ID3D11Texture2D*, kSwapchainImageCount> textures{};
    std::array<ID3D12Resource*, kSwapchainImageCount> textures12{};
    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    textures = record->textures;
    textures12 = record->textures12;
    record->textures.fill(nullptr);
    record->textures12.fill(nullptr);
    *record = {};
    ReleaseSRWLockExclusive(&gSwapchainLock);
    releaseTextures(textures);
    releaseTextures(textures12);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL enumerateSwapchainImages(
    XrSwapchain swapchain,
    uint32_t imageCapacityInput,
    uint32_t* imageCountOutput,
    XrSwapchainImageBaseHeader* images) {
    if (imageCountOutput == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    *imageCountOutput = record->imageCount;
    if (imageCapacityInput == 0) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_SUCCESS;
    }
    if (images == nullptr) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_VALIDATION_FAILURE;
    }
    if (imageCapacityInput < record->imageCount) {
        ReleaseSRWLockShared(&gSwapchainLock);
        return XR_ERROR_SIZE_INSUFFICIENT;
    }

    if (record->vkImages[0]) {
        auto* out = reinterpret_cast<XrSwapchainImageVulkanKHR*>(images);
        for(uint32_t i=0;i<record->imageCount;++i) if(out[i].type!=XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR) {
            ReleaseSRWLockShared(&gSwapchainLock); return XR_ERROR_VALIDATION_FAILURE;
        }
        for(uint32_t i=0;i<record->imageCount;++i) out[i].image=VkImage(hxvk_image_handle(record->vkImages[i].get()));
    } else if (record->textures12[0]) {
        auto* out = reinterpret_cast<XrSwapchainImageD3D12KHR*>(images);
        for (uint32_t index = 0; index < record->imageCount; ++index) {
            if (out[index].type != XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR) {
                ReleaseSRWLockShared(&gSwapchainLock); return XR_ERROR_VALIDATION_FAILURE;
            }
        }
        for (uint32_t index = 0; index < record->imageCount; ++index) out[index].texture = record->textures12[index];
    } else {
        auto* out = reinterpret_cast<XrSwapchainImageD3D11KHR*>(images);
        for (uint32_t index = 0; index < record->imageCount; ++index) {
            if (out[index].type != XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR) {
                ReleaseSRWLockShared(&gSwapchainLock); return XR_ERROR_VALIDATION_FAILURE;
            }
        }
        for (uint32_t index = 0; index < record->imageCount; ++index) out[index].texture = record->textures[index];
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return XR_SUCCESS;
}

XrResult XRAPI_CALL acquireSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageAcquireInfo* acquireInfo,
    uint32_t* index) {
    if (index == nullptr) {
        return XR_ERROR_VALIDATION_FAILURE;
    }
    *index = UINT32_MAX;
    if (acquireInfo != nullptr && acquireInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    if (record->staticImage && record->staticAcquired) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_CALL_ORDER_INVALID;
    }
    for (uint32_t offset = 0; offset < record->imageCount; ++offset) {
        const uint32_t candidate =
            (record->nextAcquireIndex + offset) % record->imageCount;
        if (record->imageStates[candidate] == ImageState::Available) {
            // Queue access is permitted in Acquire, never in WaitSwapchainImage.
            if (record->vkImages[candidate] && hxvk_prepare_image(record->vkImages[candidate].get())) {
                ReleaseSRWLockExclusive(&gSwapchainLock); return XR_ERROR_RUNTIME_FAILURE;
            }
            record->imageStates[candidate] = ImageState::Acquired;
            record->staticAcquired = record->staticImage;
            record->acquireSequence[candidate] = record->nextAcquireSequence++;
            record->nextAcquireIndex = (candidate + 1) % record->imageCount;
            *index = candidate;
            ReleaseSRWLockExclusive(&gSwapchainLock);
            return XR_SUCCESS;
        }
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

XrResult XRAPI_CALL waitSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageWaitInfo* waitInfo) {
    if (waitInfo == nullptr || waitInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    // An app can acquire ahead, but it must finish its current writable image
    // before waiting on the next FIFO image (OpenXR rendering lifecycle).
    if (oldestImageInStateLocked(*record, ImageState::Waited) < kSwapchainImageCount) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_CALL_ORDER_INVALID;
    }
    const uint32_t index = oldestImageInStateLocked(*record, ImageState::Acquired);
    if (index < kSwapchainImageCount) {
        record->imageStates[index] = ImageState::Waited;
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_SUCCESS;
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

XrResult XRAPI_CALL releaseSwapchainImage(
    XrSwapchain swapchain,
    const XrSwapchainImageReleaseInfo* releaseInfo) {
    if (releaseInfo != nullptr && releaseInfo->type != XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO) {
        return XR_ERROR_VALIDATION_FAILURE;
    }

    AcquireSRWLockExclusive(&gSwapchainLock);
    SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (swapchain == XR_NULL_HANDLE || record == nullptr) {
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_ERROR_HANDLE_INVALID;
    }
    const uint32_t index = oldestImageInStateLocked(*record, ImageState::Waited);
    if (index < kSwapchainImageCount) {
        record->imageStates[index] = ImageState::Available;
        record->everReleased = true;
        record->lastReleasedIndex = index;
        ReleaseSRWLockExclusive(&gSwapchainLock);
        return XR_SUCCESS;
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    return XR_ERROR_CALL_ORDER_INVALID;
}

bool getSwapchainSubmitState(
    XrSwapchain swapchain,
    XrSession* session,
    uint32_t* width,
    uint32_t* height,
    uint32_t* arraySize,
    bool* hasReleasedImage,
    uint32_t* lastReleasedIndex) {
    if (swapchain == XR_NULL_HANDLE) {
        return false;
    }
    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    if (record != nullptr) {
        if (session != nullptr) {
            *session = record->session;
        }
        if (width != nullptr) {
            *width = record->width;
        }
        if (height != nullptr) {
            *height = record->height;
        }
        if (arraySize != nullptr) {
            *arraySize = record->arraySize;
        }
        if (hasReleasedImage != nullptr) {
            *hasReleasedImage = record->everReleased;
        }
        if (lastReleasedIndex != nullptr) {
            *lastReleasedIndex = record->lastReleasedIndex;
        }
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return record != nullptr;
}

ID3D11Texture2D* retainSwapchainTexture(const ControlFrameView& view) {
    const auto swapchain = reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(view.swapchainId));
    AcquireSRWLockShared(&gSwapchainLock);
    const SwapchainRecord* record = findSwapchainLocked(swapchain);
    ID3D11Texture2D* texture = nullptr;
    if (record && view.imageIndex < kSwapchainImageCount && view.imageArrayIndex < record->arraySize) {
        texture = record->textures[view.imageIndex];
        if (texture) texture->AddRef();
    }
    ReleaseSRWLockShared(&gSwapchainLock);
    return texture;
}

uint32_t swapchainColourSpace(const ControlFrameView& view) {
    const auto swapchain = reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(view.swapchainId));
    AcquireSRWLockShared(&gSwapchainLock);
    const auto* record = findSwapchainLocked(swapchain);
    const uint32_t result = record ? record->colorSpace : 0;
    ReleaseSRWLockShared(&gSwapchainLock); return result;
}

ID3D12Resource* retainSwapchainTexture12(const ControlFrameView& view) {
    const auto swapchain = reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(view.swapchainId));
    AcquireSRWLockShared(&gSwapchainLock);
    const auto* record = findSwapchainLocked(swapchain);
    ID3D12Resource* texture = nullptr;
    if (record && view.imageIndex < kSwapchainImageCount && view.imageArrayIndex < record->arraySize) {
        texture = record->textures12[view.imageIndex]; if (texture) texture->AddRef();
    }
    ReleaseSRWLockShared(&gSwapchainLock); return texture;
}

VulkanSource swapchainVulkanImage(const ControlFrameView& view) {
    AcquireSRWLockShared(&gSwapchainLock);
    const auto* record=findSwapchainLocked(reinterpret_cast<XrSwapchain>(static_cast<uintptr_t>(view.swapchainId)));
    VulkanSource result{};
    if(record && view.imageIndex<kSwapchainImageCount && view.imageArrayIndex<record->arraySize)
        result={record->vkImages[view.imageIndex],record->vkFormat};
    ReleaseSRWLockShared(&gSwapchainLock);return result;
}

void invalidateSwapchainForSession(XrSession session) {
    std::array<SwapchainRecord,kMaxSwapchains> removed{}; size_t count = 0;
    AcquireSRWLockExclusive(&gSwapchainLock);
    for (auto& record : gSwapchains) if (record.session == session) {
        removed[count++] = record; record = {};
    }
    ReleaseSRWLockExclusive(&gSwapchainLock);
    for (size_t index = 0; index < count; ++index) {
        releaseTextures(removed[index].textures); releaseTextures(removed[index].textures12);
    }
}

} // namespace basalt
