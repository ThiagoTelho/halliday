// A small OpenXR application for Halliday's runtime (ROADMAP W15, 15.1): a Metal session that
// draws a pattern fixed to the room, both eyes, for a number of frames. It loads the runtime the
// way Klepton's MoltenVR fork loads its own: the library opened directly and negotiated with,
// no Khronos loader in between.
//
//   openxr-metal-check RUNTIME.dylib [FRAMES]
//
// Halliday (or `halliday-probe game-host`) must be running: the frames go to it.
#define XR_USE_GRAPHICS_API_METAL
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>

static PFN_xrGetInstanceProcAddr get;
static XrInstance instance;

static void check(XrResult r, const char *what) {
    if (XR_FAILED(r)) {
        fprintf(stderr, "openxr-metal-check: %s failed (%d)\n", what, r);
        exit(1);
    }
}

static PFN_xrVoidFunction fn(const char *name) {
    PFN_xrVoidFunction f = NULL;
    check(get(instance, name, &f), name);
    return f;
}
#define XR(name) ((PFN_##name)fn(#name))

// Each pixel's direction in the room, from the eye's field of view and orientation: the horizon,
// a line every 15 degrees, the sky lighter than the ground, red towards +x and blue towards -z.
static NSString *const shader = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Eye { float4 tangents; float4 orientation; };\n"
    "struct V { float4 position [[position]]; float2 uv; };\n"
    "vertex V vertex_main(uint i [[vertex_id]]) {\n"
    "  float2 p = float2((i << 1) & 2, i & 2);\n"
    "  return { float4(p * 2 - 1, 0, 1), float2(p.x, 1 - p.y) };\n"
    "}\n"
    "fragment float4 fragment_main(V in [[stage_in]], constant Eye &eye [[buffer(0)]]) {\n"
    "  float3 d = normalize(float3(mix(eye.tangents.x, eye.tangents.y, in.uv.x), mix(eye.tangents.z, eye.tangents.w, in.uv.y), -1));\n"
    "  float3 u = eye.orientation.xyz;\n"
    "  float3 w = d + 2 * cross(u, cross(u, d) + eye.orientation.w * d);\n"
    "  float yaw = 57.29578 * atan2(w.x, -w.z), pitch = 57.29578 * asin(clamp(w.y, -1.0, 1.0));\n"
    "  float3 c = w.y > 0 ? float3(0.25, 0.35, 0.55) : float3(0.22, 0.18, 0.14);\n"
    "  c += 0.25 * float3(max(w.x, 0.0), 0, max(-w.z, 0.0));\n"
    "  float2 cell = abs(fract(float2(yaw, pitch) / 15 + 0.5) - 0.5) * 15;\n"
    "  if (min(cell.x, cell.y) < 0.25) c = float3(0.9);\n"
    "  if (abs(pitch) < 0.4) c = float3(1.0, 0.8, 0.2);\n"
    "  return float4(c, 1);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: openxr-metal-check RUNTIME.dylib [FRAMES]\n");
            return 2;
        }
        int frames = argc > 2 ? atoi(argv[2]) : 120;
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) {
            fprintf(stderr, "openxr-metal-check: %s\n", dlerror());
            return 1;
        }
        PFN_xrNegotiateLoaderRuntimeInterface negotiate =
            (PFN_xrNegotiateLoaderRuntimeInterface)dlsym(library, "xrNegotiateLoaderRuntimeInterface");
        XrNegotiateLoaderInfo loader = {XR_LOADER_INTERFACE_STRUCT_LOADER_INFO, 1, sizeof(loader), 1, 1,
                                        XR_MAKE_VERSION(1, 0, 0), XR_MAKE_VERSION(1, 1, 0)};
        XrNegotiateRuntimeRequest request = {XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST, 1, sizeof(request)};
        check(negotiate(&loader, &request), "the negotiation");
        get = request.getInstanceProcAddr;

        // The extension, the instance, the headset.
        PFN_xrEnumerateInstanceExtensionProperties extensions = NULL;
        check(get(XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", (PFN_xrVoidFunction *)&extensions), "extensions");
        uint32_t n = 0;
        check(extensions(NULL, 0, &n, NULL), "the extension count");
        XrExtensionProperties properties[8];
        for (uint32_t i = 0; i < 8; i++) properties[i] = (XrExtensionProperties){XR_TYPE_EXTENSION_PROPERTIES};
        check(extensions(NULL, n < 8 ? n : 8, &n, properties), "the extensions");
        bool metal = false;
        for (uint32_t i = 0; i < n && i < 8; i++) metal |= !strcmp(properties[i].extensionName, "XR_KHR_metal_enable");
        if (!metal) {
            fprintf(stderr, "openxr-metal-check: the runtime has no XR_KHR_metal_enable\n");
            return 1;
        }
        PFN_xrCreateInstance createInstance = NULL;
        check(get(XR_NULL_HANDLE, "xrCreateInstance", (PFN_xrVoidFunction *)&createInstance), "xrCreateInstance");
        const char *enabled[] = {"XR_KHR_metal_enable"};
        XrInstanceCreateInfo ci = {XR_TYPE_INSTANCE_CREATE_INFO};
        strcpy(ci.applicationInfo.applicationName, "openxr-metal-check");
        ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
        ci.enabledExtensionCount = 1;
        ci.enabledExtensionNames = enabled;
        check(createInstance(&ci, &instance), "the instance");
        XrSystemGetInfo si = {XR_TYPE_SYSTEM_GET_INFO, NULL, XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY};
        XrSystemId system;
        check(XR(xrGetSystem)(instance, &si, &system), "the headset");
        XrGraphicsRequirementsMetalKHR requirements = {XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
        check(XR(xrGetMetalGraphicsRequirementsKHR)(instance, system, &requirements), "Metal's requirements");
        id<MTLDevice> device = (__bridge id<MTLDevice>)requirements.metalDevice ?: MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];

        // The session, its spaces and one swapchain per eye.
        XrGraphicsBindingMetalKHR binding = {XR_TYPE_GRAPHICS_BINDING_METAL_KHR, NULL, (__bridge void *)queue};
        XrSessionCreateInfo sci = {XR_TYPE_SESSION_CREATE_INFO, &binding, 0, system};
        XrSession session;
        check(XR(xrCreateSession)(instance, &sci, &session), "the session (is Halliday running?)");
        XrReferenceSpaceCreateInfo ri = {XR_TYPE_REFERENCE_SPACE_CREATE_INFO, NULL, XR_REFERENCE_SPACE_TYPE_STAGE, {{0, 0, 0, 1}, {0, 0, 0}}};
        XrSpace stage, local, head;
        check(XR(xrCreateReferenceSpace)(session, &ri, &stage), "the stage space");
        ri.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
        check(XR(xrCreateReferenceSpace)(session, &ri, &local), "the local space");
        ri.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
        check(XR(xrCreateReferenceSpace)(session, &ri, &head), "the view space");
        XrViewConfigurationView sizes[2] = {{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
        check(XR(xrEnumerateViewConfigurationViews)(instance, system, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, 2, &n, sizes), "the views' sizes");
        int64_t formats[8];
        check(XR(xrEnumerateSwapchainFormats)(session, 8, &n, formats), "the formats");
        XrSwapchain chains[2];
        XrSwapchainImageMetalKHR images[2][8];
        for (int eye = 0; eye < 2; eye++) {
            XrSwapchainCreateInfo si2 = {XR_TYPE_SWAPCHAIN_CREATE_INFO};
            si2.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
            si2.format = formats[0];
            si2.sampleCount = si2.faceCount = si2.arraySize = si2.mipCount = 1;
            si2.width = sizes[eye].recommendedImageRectWidth;
            si2.height = sizes[eye].recommendedImageRectHeight;
            check(XR(xrCreateSwapchain)(session, &si2, &chains[eye]), "a swapchain");
            for (int i = 0; i < 8; i++) images[eye][i] = (XrSwapchainImageMetalKHR){XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
            check(XR(xrEnumerateSwapchainImages)(chains[eye], 8, &n, (XrSwapchainImageBaseHeader *)images[eye]), "its images");
        }
        printf("session: %u x %u per eye, Metal format %lld, %u images a swapchain\n", sizes[0].recommendedImageRectWidth,
               sizes[0].recommendedImageRectHeight, formats[0], n);

        NSError *error = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:shader options:nil error:&error];
        if (!lib) {
            fprintf(stderr, "openxr-metal-check: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vertex_main"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fragment_main"];
        pd.colorAttachments[0].pixelFormat = (MTLPixelFormat)formats[0];
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];

        // The frame loop: begin when the runtime says the session is ready, stop when it says so.
        bool running = false, done = false;
        int shown = 0;
        XrPosef first = {{0, 0, 0, 1}, {0, 0, 0}}, last = first;
        while (!done) {
            XrEventDataBuffer event = {XR_TYPE_EVENT_DATA_BUFFER};
            while (XR(xrPollEvent)(instance, &event) == XR_SUCCESS) {
                if (event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
                    XrSessionState state = ((XrEventDataSessionStateChanged *)&event)->state;
                    if (state == XR_SESSION_STATE_READY) {
                        XrSessionBeginInfo bi = {XR_TYPE_SESSION_BEGIN_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO};
                        check(XR(xrBeginSession)(session, &bi), "beginning the session");
                        running = true;
                    } else if (state == XR_SESSION_STATE_STOPPING) {
                        check(XR(xrEndSession)(session), "ending the session");
                        running = false;
                    } else if (state == XR_SESSION_STATE_EXITING) {
                        done = true;
                    }
                }
                event = (XrEventDataBuffer){XR_TYPE_EVENT_DATA_BUFFER};
            }
            if (!running) continue;
            XrFrameState frame = {XR_TYPE_FRAME_STATE};
            check(XR(xrWaitFrame)(session, NULL, &frame), "xrWaitFrame");
            check(XR(xrBeginFrame)(session, NULL), "xrBeginFrame");
            XrViewLocateInfo li = {XR_TYPE_VIEW_LOCATE_INFO, NULL, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, frame.predictedDisplayTime, stage};
            XrViewState vs = {XR_TYPE_VIEW_STATE};
            XrView views[2] = {{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
            check(XR(xrLocateViews)(session, &li, &vs, 2, &n, views), "xrLocateViews");
            XrCompositionLayerProjectionView projected[2];
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            for (int eye = 0; eye < 2; eye++) {
                uint32_t index = 0;
                check(XR(xrAcquireSwapchainImage)(chains[eye], NULL, &index), "acquiring an image");
                XrSwapchainImageWaitInfo wi = {XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO, NULL, XR_INFINITE_DURATION};
                check(XR(xrWaitSwapchainImage)(chains[eye], &wi), "waiting for an image");
                MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
                pass.colorAttachments[0].texture = (__bridge id<MTLTexture>)images[eye][index].texture;
                pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> draw = [commands renderCommandEncoderWithDescriptor:pass];
                XrFovf f = views[eye].fov;
                XrQuaternionf q = views[eye].pose.orientation;
                float parameters[8] = {tanf(f.angleLeft), tanf(f.angleRight), tanf(f.angleUp), tanf(f.angleDown), q.x, q.y, q.z, q.w};
                [draw setRenderPipelineState:pipeline];
                [draw setFragmentBytes:parameters length:sizeof(parameters) atIndex:0];
                [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [draw endEncoding];
                projected[eye] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL, views[eye].pose, views[eye].fov,
                    {chains[eye], {{0, 0}, {(int32_t)sizes[eye].recommendedImageRectWidth, (int32_t)sizes[eye].recommendedImageRectHeight}}, 0}};
            }
            [commands commit];
            for (int eye = 0; eye < 2; eye++) check(XR(xrReleaseSwapchainImage)(chains[eye], NULL), "releasing an image");
            XrCompositionLayerProjection layer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, projected};
            const XrCompositionLayerBaseHeader *layers[] = {(XrCompositionLayerBaseHeader *)&layer};
            XrFrameEndInfo end = {XR_TYPE_FRAME_END_INFO, NULL, frame.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 1, layers};
            check(XR(xrEndFrame)(session, &end), "xrEndFrame");
            if (shown == 0) first = views[0].pose;
            last = views[0].pose;
            if (++shown == frames) check(XR(xrRequestExitSession)(session), "asking to stop");
        }
        XrSpaceLocation where = {XR_TYPE_SPACE_LOCATION};
        check(XR(xrLocateSpace)(head, local, 0, &where), "the head in the local space");
        printf("%d frames shown; the left eye at %.2f %.2f %.2f in the stage space (first %.2f %.2f %.2f); the head %.2f %.2f %.2f from where the session began\n",
               shown, last.position.x, last.position.y, last.position.z, first.position.x, first.position.y, first.position.z,
               where.pose.position.x, where.pose.position.y, where.pose.position.z);
        check(XR(xrDestroySession)(session), "destroying the session");
        check(XR(xrDestroyInstance)(instance), "destroying the instance");
        return 0;
    }
}
