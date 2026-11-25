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

#ifdef HALLIDAY_METAL_CHECK_VERIFY
// Optional regression fixture only. Compile as Objective-C++ to reuse the same
// public v6 layout as the independent Windows/Vulkan clients.
#include "bridge_layout.hpp"
#include "../windows-openxr/tests/swapchain_lifecycle_checks.hpp"
#include "../windows-openxr/tests/projection_checks.hpp"
#include <utility>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
// Count the runtime's actual command-buffer requests without adding production counters.
// Application rendering keeps using the original queue; this proxy forwards to that same queue.
@interface HallidayCountingQueue : NSProxy {
    id<MTLCommandQueue> _queue;
    NSUInteger _requests;
}
+ (instancetype)withQueue:(id<MTLCommandQueue>)queue;
- (void)resetCount;
- (NSUInteger)requestCount;
@end
@implementation HallidayCountingQueue
+ (instancetype)withQueue:(id<MTLCommandQueue>)queue {
    HallidayCountingQueue *proxy = [HallidayCountingQueue alloc];
    proxy->_queue = queue;
    return proxy;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector { return [(id)_queue methodSignatureForSelector:selector]; }
- (void)forwardInvocation:(NSInvocation *)invocation { [invocation invokeWithTarget:_queue]; }
- (id<MTLDevice>)device { return [_queue device]; }
- (id<MTLCommandBuffer>)commandBuffer { ++_requests; return [_queue commandBuffer]; }
- (void)resetCount { _requests = 0; }
- (NSUInteger)requestCount { return _requests; }
@end
static void verifyCheck(bool value, const char *reason) {
    if (!value) { fprintf(stderr, "METAL VERIFY FAIL: %s\n", reason); exit(1); }
}
static void verifyPublished(id<MTLBuffer> __strong *references, uint32_t width, uint32_t height,
                            int64_t format, unsigned number, unsigned flipMode,
                            const XrCompositionLayerProjectionView views[2], bool requireGeometry) {
    const char *path = getenv("HALLIDAY_BRIDGE");
    verifyCheck(path && strstr(path, "/build/validation/native-independent-metal/") && !strstr(path, ".."),
                "verification requires an isolated validation host");
    int file = open(path, O_RDONLY); verifyCheck(file >= 0, "open private test host");
    void *mapping = mmap(NULL, halliday::kFileBytes, PROT_READ, MAP_SHARED, file, 0); close(file);
    verifyCheck(mapping != MAP_FAILED, "map private test host");
    const auto *header = static_cast<const halliday::Header *>(mapping);
    verifyCheck(header->magic == halliday::kMagic && header->version == halliday::kVersion, "public bridge ABI");
    const auto latest = header->latest.load();
    verifyCheck(latest > 0 && latest <= halliday::kSlots, "new frame published");
    const auto &frame = header->frames[latest - 1]; const auto sequence = frame.seq.load();
    const bool bgra = format == 80 || format == 81, srgb = format == 81 || format == 71;
    verifyCheck(!(sequence & 1) && frame.width == width && frame.height == height &&
                frame.frameIndex == number && header->clientFrames.load() == number &&
                !frame.bottomUp && !frame.shared && frame.bgra == unsigned(bgra) && frame.pose.valid,
                "complete Metal frame geometry, sequence, byte order and pose");
    if (requireGeometry || (frame.textureType & (1u<<16))) {
        try { projection_checks::verify(const_cast<halliday::Header*>(header),views); }
        catch(const std::exception& error) { verifyCheck(false,error.what()); }
        printf("METAL GEOMETRY VERIFY PASS frame=%u exact_pose_fov=both_eyes\n",number);
    }
    for (unsigned eye = 0; eye < 2; ++eye) {
        verifyCheck(halliday::frameColorSpace(frame.textureType, eye) == (srgb ? halliday::kColorSrgb : halliday::kColorLinear),
                    "Metal UNORM/sRGB transfer metadata");
        const auto *pixels = static_cast<const uint8_t *>(mapping) + halliday::imageOffset(latest - 1, eye);
        const auto *reference = static_cast<const uint8_t *>(references[eye].contents);
        const bool horizontal=(flipMode&(eye?2u:1u))!=0,vertical=(flipMode&(eye?1u:2u))!=0;
        for (uint32_t y=0;y<height;++y)for (uint32_t x=0;x<width;++x) {
            const auto sx=horizontal?width-1-x:x,sy=vertical?height-1-y:y;
            verifyCheck(!memcmp(pixels+(size_t(y)*width+x)*4,reference+(size_t(sy)*width+sx)*4,4),
                        "transported eye pixels equal the exact app-owned GPU reference, including per-eye FOV flips");
        }
    }
    verifyCheck(frame.seq.load() == sequence, "frame remained stable while checked");
    munmap(mapping, halliday::kFileBytes);
    printf("METAL VERIFY PASS frame=%u width=%u height=%u format=%lld\n", number, width, height, (long long)format);
}
struct MetalPanelRecord {
    halliday::Pose pose;
    float width, height;
    uint32_t eye, flags, order, picture, sequence, color, bgra, anchor;
};
static_assert(sizeof(MetalPanelRecord) == 104);
static void verifyMetalPanels(id<MTLBuffer> reference, uint32_t width, uint32_t height, int64_t format, unsigned number) {
    int file = open(getenv("HALLIDAY_BRIDGE"), O_RDONLY); verifyCheck(file >= 0, "open quad verification host");
    void *mapping = mmap(NULL, halliday::kFileBytes, PROT_READ, MAP_SHARED, file, 0); close(file);
    verifyCheck(mapping != MAP_FAILED, "map quad verification host");
    const auto *h = static_cast<const halliday::Header *>(mapping);
    const auto latest = h->latest.load(); verifyCheck(latest && latest <= halliday::kSlots, "quad frame slot");
    verifyCheck(h->frames[latest-1].textureType & (1u<<17), "Metal ordered layers require their exact batch metadata");
    const auto *batch = static_cast<const uint8_t *>(mapping) + 61568 + 16 + (latest - 1) * 864;
    uint32_t count, order; uint64_t epoch, frame;
    memcpy(&count, batch + 4, 4); memcpy(&frame, batch + 8, 8);
    memcpy(&epoch, batch + 16, 8); memcpy(&order, batch + 24, 4);
    verifyCheck(count == 2 && frame == number && epoch && order == 1, "Metal quad batch matches frame and exact layer order");
    for (unsigned i = 0; i < 2; ++i) {
        MetalPanelRecord record; memcpy(&record, batch + 32 + i * sizeof(record), sizeof(record));
        verifyCheck(record.order == i * 2 && record.eye == i + 1 && record.anchor == i &&
                    record.flags == (i ? 0u : 3u), "Metal world/VIEW anchor, eye visibility and alpha flags");
        verifyCheck(record.color == ((format == 81 || format == 71) ? halliday::kColorSrgb : halliday::kColorLinear) &&
                    record.bgra == unsigned(format == 80 || format == 81), "Metal quad transfer and byte order");
        verifyCheck(record.picture < 8 && record.sequence && !(record.sequence & 1), "complete Metal panel pixels");
        const auto *pixels = static_cast<const uint8_t *>(mapping) + halliday::kHeaderBytes +
            halliday::kSlots * 2 * halliday::kEyeBytes + record.picture * 2048 * 2048 * 4;
        for (unsigned row = 0; row < 13; ++row) {
            const auto *expected = static_cast<const uint8_t *>(reference.contents) + ((row + 5) * width + 3) * 4;
            verifyCheck(!memcmp(pixels + row * 17 * 4, expected, 17 * 4),
                        "odd-width Metal quad crop equals the same released image's GPU oracle, without flips or CPU painting");
        }
    }
    munmap(mapping, halliday::kFileBytes);
    printf("METAL QUAD VERIFY PASS frame=%u panels=2 crop=17x13\n", number);
}
#endif

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
    "}\n"
    "kernel void compute_main(texture2d<float,access::write> target [[texture(0)]], constant uint2 &phase [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
    "  if (p.x>=target.get_width() || p.y>=target.get_height()) return;\n"
    "  target.write(float4(float(p.x)/float(target.get_width()),float(p.y)/float(target.get_height()),float(phase.x+phase.y+1)/8.0,1),p);\n"
    "}\n";

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: openxr-metal-check RUNTIME.dylib [FRAMES]\n");
            return 2;
        }
        int frames = argc > 2 ? atoi(argv[2]) : 120;
        const bool computeWrites = getenv("HALLIDAY_METAL_CHECK_COMPUTE") != NULL;
        const bool customGeometry = getenv("HALLIDAY_METAL_CHECK_GEOMETRY") != NULL;
#ifdef HALLIDAY_METAL_CHECK_VERIFY
        const bool verifyQuads = getenv("HALLIDAY_METAL_CHECK_QUADS") != NULL;
        const bool verifyFlips = getenv("HALLIDAY_METAL_CHECK_FLIPS") != NULL;
#endif
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
#ifdef HALLIDAY_METAL_CHECK_VERIFY
        HallidayCountingQueue *runtimeQueue = [HallidayCountingQueue withQueue:queue];
#else
        id<MTLCommandQueue> runtimeQueue = queue;
#endif

        // The session, its spaces and one swapchain per eye.
        XrGraphicsBindingMetalKHR binding = {XR_TYPE_GRAPHICS_BINDING_METAL_KHR, NULL, (__bridge void *)runtimeQueue};
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
            if (computeWrites) si2.usageFlags |= XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT;
            si2.format = formats[0];
            si2.sampleCount = si2.faceCount = si2.arraySize = si2.mipCount = 1;
            si2.width = sizes[eye].recommendedImageRectWidth;
            si2.height = sizes[eye].recommendedImageRectHeight;
            check(XR(xrCreateSwapchain)(session, &si2, &chains[eye]), "a swapchain");
            for (int i = 0; i < 8; i++) images[eye][i] = (XrSwapchainImageMetalKHR){XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR};
            check(XR(xrEnumerateSwapchainImages)(chains[eye], 8, &n, (XrSwapchainImageBaseHeader *)images[eye]), "its images");
            if (computeWrites) for (uint32_t image=0;image<n;++image) {
                id<MTLTexture> texture=(__bridge id<MTLTexture>)images[eye][image].texture;
                if (!(texture.usage & MTLTextureUsageShaderWrite)) {
                    fprintf(stderr,"METAL UAV VERIFY FAIL: UNORDERED_ACCESS lacks ShaderWrite texture usage\n");
                    return 1; // Do not encode an illegal operation into the baseline.
                }
            }
        }
        printf("session: %u x %u per eye, Metal format %lld, %u images a swapchain\n", sizes[0].recommendedImageRectWidth,
               sizes[0].recommendedImageRectHeight, formats[0], n);
#ifdef HALLIDAY_METAL_CHECK_VERIFY
        if (!getenv("HALLIDAY_METAL_CHECK_SKIP_LIFECYCLE")) swapchain_lifecycle_checks::run(get,instance,session);
#endif

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
        id<MTLComputePipelineState> computePipeline = nil;
        if (computeWrites) {
            computePipeline=[device newComputePipelineStateWithFunction:[lib newFunctionWithName:@"compute_main"] error:&error];
            if(!computePipeline) { fprintf(stderr,"compute pipeline: %s\n",error.localizedDescription.UTF8String);return 1; }
        }
#ifdef HALLIDAY_METAL_CHECK_VERIFY
        id<MTLBuffer> references[2];
        for (unsigned eye = 0; eye < 2; ++eye) references[eye] = [device newBufferWithLength:
            (NSUInteger)sizes[eye].recommendedImageRectWidth * sizes[eye].recommendedImageRectHeight * 4 options:MTLResourceStorageModeShared];
#endif

        // The frame loop: begin when the runtime says the session is ready, stop when it says so.
        bool running = false, done = false;
        int shown = 0;
        XrTime lastDisplayTime = 1;
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
            lastDisplayTime = frame.predictedDisplayTime;
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
                XrPosef renderPose = views[eye].pose;
                if(customGeometry && shown) {
                    f.angleLeft*=eye?.78f:.83f; f.angleRight*=eye?.91f:.72f;
                    f.angleUp*=eye?.87f:.76f; f.angleDown*=eye?.69f:.94f;
                    if(shown>=2) {
                        renderPose.position.x+=eye?.01f:-.01f;renderPose.position.y+=eye?.006f:-.006f;
                        if(eye) { const XrQuaternionf q=renderPose.orientation;const float c=cosf(.07f),sn=sinf(.07f);
                            renderPose.orientation=(XrQuaternionf){q.w*sn+q.x*c,q.y*c+q.z*sn,q.z*c-q.y*sn,q.w*c-q.x*sn}; }
                    }
                }
#ifdef HALLIDAY_METAL_CHECK_VERIFY
                if(verifyFlips) {
                    if((shown%4)&(eye?2u:1u))std::swap(f.angleLeft,f.angleRight);
                    if((shown%4)&(eye?1u:2u))std::swap(f.angleDown,f.angleUp);
                }
#endif
                XrQuaternionf q = renderPose.orientation;
                float parameters[8] = {tanf(f.angleLeft), tanf(f.angleRight), tanf(f.angleUp), tanf(f.angleDown), q.x, q.y, q.z, q.w};
                [draw setRenderPipelineState:pipeline];
                [draw setFragmentBytes:parameters length:sizeof(parameters) atIndex:0];
                [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [draw endEncoding];
                if (computeWrites) {
                    id<MTLComputeCommandEncoder> compute=[commands computeCommandEncoder];
                    [compute setComputePipelineState:computePipeline];
                    [compute setTexture:pass.colorAttachments[0].texture atIndex:0];
                    const uint32_t phase[2]={(uint32_t)eye,(uint32_t)shown};
                    [compute setBytes:phase length:sizeof(phase) atIndex:0];
                    [compute dispatchThreads:MTLSizeMake(sizes[eye].recommendedImageRectWidth,sizes[eye].recommendedImageRectHeight,1)
                        threadsPerThreadgroup:MTLSizeMake(8,8,1)];
                    [compute endEncoding];
                }
#ifdef HALLIDAY_METAL_CHECK_VERIFY
                // Capture a GPU oracle while the application owns this image.
                // No CPU wait occurs before xrEndFrame; its readback must order
                // after this app command buffer and make both copies visible.
                id<MTLBlitCommandEncoder> copy = [commands blitCommandEncoder];
                [copy copyFromTexture:pass.colorAttachments[0].texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                    sourceSize:MTLSizeMake(sizes[eye].recommendedImageRectWidth,sizes[eye].recommendedImageRectHeight,1)
                    toBuffer:references[eye] destinationOffset:0 destinationBytesPerRow:sizes[eye].recommendedImageRectWidth*4
                    destinationBytesPerImage:(NSUInteger)sizes[eye].recommendedImageRectWidth*sizes[eye].recommendedImageRectHeight*4];
                [copy endEncoding];
#endif
                projected[eye] = (XrCompositionLayerProjectionView){XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW, NULL, renderPose, f,
                    {chains[eye], {{0, 0}, {(int32_t)sizes[eye].recommendedImageRectWidth, (int32_t)sizes[eye].recommendedImageRectHeight}}, 0}};
            }
            [commands commit];
            for (int eye = 0; eye < 2; eye++) check(XR(xrReleaseSwapchainImage)(chains[eye], NULL), "releasing an image");
            XrCompositionLayerProjection layer = {XR_TYPE_COMPOSITION_LAYER_PROJECTION, NULL, 0, stage, 2, projected};
            const XrCompositionLayerBaseHeader *layers[] = {(XrCompositionLayerBaseHeader *)&layer};
            XrFrameEndInfo end = {XR_TYPE_FRAME_END_INFO, NULL, frame.predictedDisplayTime, XR_ENVIRONMENT_BLEND_MODE_OPAQUE, 1, layers};
#ifdef HALLIDAY_METAL_CHECK_VERIFY
            XrCompositionLayerQuad worldQuad = {XR_TYPE_COMPOSITION_LAYER_QUAD};
            worldQuad.space = stage; worldQuad.eyeVisibility = XR_EYE_VISIBILITY_LEFT;
            worldQuad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT | XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
            worldQuad.pose = (XrPosef){{0, 0, 0, 1}, {0, 1.4f, -1}};
            worldQuad.size = (XrExtent2Df){.5f, .3f}; worldQuad.subImage = projected[0].subImage;
            worldQuad.subImage.imageRect = (XrRect2Di){{3, 5}, {17, 13}};
            XrCompositionLayerQuad headQuad = worldQuad;
            headQuad.space = head; headQuad.eyeVisibility = XR_EYE_VISIBILITY_RIGHT; headQuad.layerFlags = 0;
            const XrCompositionLayerBaseHeader *quadLayers[] = {(XrCompositionLayerBaseHeader *)&worldQuad,
                (XrCompositionLayerBaseHeader *)&layer, (XrCompositionLayerBaseHeader *)&headQuad};
            if (verifyQuads) { end.layerCount = 3; end.layers = quadLayers; }
#endif
#ifdef HALLIDAY_METAL_CHECK_VERIFY
            [runtimeQueue resetCount];
#endif
            check(XR(xrEndFrame)(session, &end), "xrEndFrame");
#ifdef HALLIDAY_METAL_CHECK_VERIFY
            const NSUInteger batches = [runtimeQueue requestCount];
            const char *expectedBatches = getenv("HALLIDAY_METAL_CHECK_BATCH_EXPECTED");
            if (expectedBatches && atoi(expectedBatches) > 0)
                verifyCheck(batches == (NSUInteger)atoi(expectedBatches), "one shared GPU readback command buffer per submitted frame");
            printf("METAL BATCH VERIFY PASS frame=%u command_buffers=%lu\n", shown + 1, (unsigned long)batches);
            verifyCheck(commands.status == MTLCommandBufferStatusCompleted, "runtime completed app queue work before publication");
            verifyPublished(references, sizes[0].recommendedImageRectWidth, sizes[0].recommendedImageRectHeight, formats[0], shown + 1,
                verifyFlips ? shown%4 : 0,projected,customGeometry);
            if(computeWrites)printf("METAL UAV VERIFY PASS frame=%u ShaderWrite=1 compute_pixels=exact\n",shown+1);
            if (verifyQuads) verifyMetalPanels(references[0], sizes[0].recommendedImageRectWidth,
                sizes[0].recommendedImageRectHeight, formats[0], shown + 1);
#endif
            if (shown == 0) first = views[0].pose;
            last = views[0].pose;
            if (++shown == frames) check(XR(xrRequestExitSession)(session), "asking to stop");
        }
        XrSpaceLocation where = {XR_TYPE_SPACE_LOCATION};
        check(XR(xrLocateSpace)(head, local, lastDisplayTime, &where), "the head in the local space");
        printf("%d frames shown; the left eye at %.2f %.2f %.2f in the stage space (first %.2f %.2f %.2f); the head %.2f %.2f %.2f from where the session began\n",
               shown, last.position.x, last.position.y, last.position.z, first.position.x, first.position.y, first.position.z,
               where.pose.position.x, where.pose.position.y, where.pose.position.z);
        check(XR(xrDestroySession)(session), "destroying the session");
        check(XR(xrDestroyInstance)(instance), "destroying the instance");
        return 0;
    }
}
