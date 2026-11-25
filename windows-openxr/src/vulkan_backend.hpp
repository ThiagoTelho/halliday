// Independent Windows Vulkan backend. Public OpenXR/Vulkan interfaces only.
#pragma once
#include "runtime.hpp"
#include "readback.hpp"
#include "d3d11_prior_staging.hpp"
#include <array>
#include <vector>
#include <memory>
#include "../../core/halliday-bridge/include/readback_batch.h"

extern "C" {
int hxvk_create_instance(void*, const void*, const void*, void**);
void* hxvk_physical_device(void*, void*);
int hxvk_create_device(void*, void*, void*, const void*, const void*, void**);
void* hxvk_context(void*, void*, void*, void*, uint32_t, uint32_t);
void hxvk_destroy_context(void*);
void hxvk_abandon_context(void*);
void* hxvk_image(void*, uint64_t, uint32_t, uint32_t, uint32_t, uint64_t);
uint64_t hxvk_image_handle(void*);
void hxvk_destroy_image(void*);
int hxvk_prepare_image(void*);
int hxvk_submit_slot(void*, uint32_t, const HallidayReadbackRequest*, uint32_t);
int hxvk_complete_slot(void*, uint32_t, const HallidayReadbackRequest*, uint32_t);
int hxvk_reset_prior(void*);
int hxvk_read(void*, void*, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint8_t*);
}
namespace basalt {
bool isVulkanRuntimeAvailable();
bool isVulkanExtensionEnabled(XrInstance, bool version2 = false);
void resetVulkanInstance(XrInstance);
XrResult XRAPI_CALL getVulkanRequirements(XrInstance, XrSystemId, XrGraphicsRequirementsVulkanKHR*);
XrResult XRAPI_CALL getVulkanRequirements2(XrInstance, XrSystemId, XrGraphicsRequirementsVulkan2KHR*);
XrResult XRAPI_CALL getVulkanInstanceExtensions(XrInstance, XrSystemId, uint32_t, uint32_t*, char*);
XrResult XRAPI_CALL getVulkanDeviceExtensions(XrInstance, XrSystemId, uint32_t, uint32_t*, char*);
XrResult XRAPI_CALL getVulkanGraphicsDevice(XrInstance, XrSystemId, VkInstance, VkPhysicalDevice*);
XrResult XRAPI_CALL getVulkanGraphicsDevice2(XrInstance, const XrVulkanGraphicsDeviceGetInfoKHR*, VkPhysicalDevice*);
XrResult XRAPI_CALL createVulkanInstance(XrInstance, const XrVulkanInstanceCreateInfoKHR*, VkInstance*, VkResult*);
XrResult XRAPI_CALL createVulkanDevice(XrInstance, const XrVulkanDeviceCreateInfoKHR*, VkDevice*, VkResult*);
XrResult makeVulkanContext(XrInstance, const XrGraphicsBindingVulkanKHR&, void**);
void* sessionVulkanContext(XrSession);
void controlSessionCreatedVulkan(XrSession, void*);
struct VulkanSource { std::shared_ptr<void> image; VkFormat format = VK_FORMAT_UNDEFINED; };
VulkanSource swapchainVulkanImage(const ControlFrameView&);
bool prepareVulkanFrame(void*, const ControlFrameView[2], ReadbackImage[2], std::array<std::vector<uint8_t>, 2>&);
PriorStagingResult prepareVulkanPriorFrame(void*, const PriorProjectionFrame&, ReadbackImage[2], PriorProjectionFrame*);
void finishVulkanPriorFrame(void*);
bool resetVulkanPriorReadback(void*);
void abandonVulkanPriorReadback(void*);
}
