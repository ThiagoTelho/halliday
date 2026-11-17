// Halliday's OpenXR runtime through the Khronos loader, as an app would see it: `make openxr-check`
// (needs reference/openxr-sdk built: tools/fetch-reference.sh, with cmake installed).
#include <stdio.h>
#include <string.h>
#include <openxr/openxr.h>
#define CHECK(x) do { XrResult r_ = (x); printf("%-44s %d\n", #x, r_); if (XR_FAILED(r_)) return 1; } while (0)
int main(void) { setvbuf(stdout, NULL, _IONBF, 0);
    uint32_t n = 0;
    CHECK(xrEnumerateInstanceExtensionProperties(NULL, 0, &n, NULL));
    printf("  extensions: %u\n", n);
    XrInstanceCreateInfo ci = { XR_TYPE_INSTANCE_CREATE_INFO };
    strcpy(ci.applicationInfo.applicationName, "xrreal");
    ci.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    XrInstance inst;
    CHECK(xrCreateInstance(&ci, &inst));
    XrInstanceProperties ip = { XR_TYPE_INSTANCE_PROPERTIES };
    CHECK(xrGetInstanceProperties(inst, &ip));
    printf("  runtime: %s %u.%u.%u\n", ip.runtimeName, XR_VERSION_MAJOR(ip.runtimeVersion), XR_VERSION_MINOR(ip.runtimeVersion), XR_VERSION_PATCH(ip.runtimeVersion));
    XrSystemGetInfo gi = { XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY };
    XrSystemId sys;
    CHECK(xrGetSystem(inst, &gi, &sys));
    XrSystemProperties sp = { XR_TYPE_SYSTEM_PROPERTIES };
    CHECK(xrGetSystemProperties(inst, sys, &sp));
    printf("  system: %s, max %ux%u, %u layers\n", sp.systemName, sp.graphicsProperties.maxSwapchainImageWidth, sp.graphicsProperties.maxSwapchainImageHeight, sp.graphicsProperties.maxLayerCount);
    XrViewConfigurationView v[2] = { { XR_TYPE_VIEW_CONFIGURATION_VIEW }, { XR_TYPE_VIEW_CONFIGURATION_VIEW } };
    CHECK(xrEnumerateViewConfigurationViews(inst, sys, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &n, v));
    printf("  views: %u, %ux%u recommended\n", n, v[0].recommendedImageRectWidth, v[0].recommendedImageRectHeight);
    XrEnvironmentBlendMode modes[4];
    CHECK(xrEnumerateEnvironmentBlendModes(inst, sys, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 4, &n, modes));
    char buf[XR_MAX_RESULT_STRING_SIZE];
    CHECK(xrResultToString(inst, XR_ERROR_FUNCTION_UNSUPPORTED, buf));
    printf("  %s\n", buf);
    XrSessionCreateInfo sc = { XR_TYPE_SESSION_CREATE_INFO, NULL, 0, sys };
    XrSession s;
    printf("%-44s %d (expected: -38, no graphics binding given; tools/openxr-metal-check.m makes a real session)\n", "xrCreateSession", xrCreateSession(inst, &sc, &s));
    CHECK(xrDestroyInstance(inst));
    return 0;
}
