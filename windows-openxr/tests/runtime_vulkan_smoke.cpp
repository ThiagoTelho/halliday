// MIT. Windows adaptation of our public native Vulkan fixture; private owned v6 host.
// Only Vulkan commands draw eye images; the host reads transported image slots.
#define VK_NO_PROTOTYPES
#define XR_NO_PROTOTYPES
#define XR_USE_GRAPHICS_API_VULKAN
#include <vulkan/vulkan.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>
#include "bridge_layout.hpp"
#include <windows.h>
#include "haptic_bridge.hpp"
#include "vulkan_counting_loader.hpp"
#include "projection_checks.hpp"
#include "quad_checks.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

static void check(bool value,const char* reason) { if(!value) throw std::runtime_error(reason); }
static void xrcheck(XrResult value,const char* reason) {
    if(XR_FAILED(value)) throw std::runtime_error(std::string(reason)+": XrResult "+std::to_string(value));
}
static void vkcheck(VkResult value,const char* reason) {
    if(value!=VK_SUCCESS) throw std::runtime_error(std::string(reason)+": VkResult "+std::to_string(value));
}
static PFN_xrGetInstanceProcAddr gipa{};
static XrInstance instance=XR_NULL_HANDLE;
static PFN_vkGetInstanceProcAddr vkgipa{};
static PFN_vkGetDeviceProcAddr vkgdpa{};
template<class T> static T xr(const char* name) {
    PFN_xrVoidFunction function=nullptr;xrcheck(gipa(instance,name,&function),name);
    check(function!=nullptr,name);return reinterpret_cast<T>(function);
}
template<class T> static T vk(VkInstance object,const char* name) {
    const auto function=vkgipa(object,name);check(function!=nullptr,name);return reinterpret_cast<T>(function);
}
template<class T> static T deviceFn(VkDevice object,const char* name) {
    const auto function=vkgdpa(object,name);check(function!=nullptr,name);return reinterpret_cast<T>(function);
}

struct Host {
    std::string path;halliday::Header* header{};std::atomic<bool> stopped{false};std::thread clock;
    explicit Host(const char* name):path(name) {
        std::string normalized=path;for(auto& c:normalized){if(c=='/')c='\\';c=char(std::tolower(c));}
        check(normalized.find("\\windows-openxr\\build\\tests\\")!=std::string::npos && path.find("..") == std::string::npos,"owned new fixture path required");
        HANDLE file=CreateFileA(path.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        check(file!=INVALID_HANDLE_VALUE,"create new sparse host"); LARGE_INTEGER bytes{};bytes.QuadPart=halliday::kFileBytes;
        check(SetFilePointerEx(file,bytes,nullptr,FILE_BEGIN)&&SetEndOfFile(file),"size host");
        HANDLE mapping=CreateFileMappingW(file,nullptr,PAGE_READWRITE,0,0,nullptr);CloseHandle(file);check(mapping,"create host mapping");
        void* base=MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,halliday::kFileBytes);CloseHandle(mapping);check(base,"map host");header=new(base)halliday::Header{};
        header->magic=halliday::kMagic;header->version=halliday::kVersion;header->eyeWidth=header->eyeHeight=64;header->displayHz=90;header->ipd=.064f;
        for(auto& t:header->tangents){t[0]=-.9f;t[1]=1.1f;t[2]=1.05f;t[3]=-.95f;}
        auto* ext=new(reinterpret_cast<uint8_t*>(header)+halliday::haptics::kOffset)halliday::haptics::Extension{};
        ext->magic=halliday::haptics::kMagic;ext->version=halliday::haptics::kVersion;ext->clockNs.store(1'000'000'000);
        halliday::focus::initialize(header);
        projection_checks::initialize(header);
        header->intervalNs.store(11'111'111);header->alive.store(1);publish(pose(1));SetEnvironmentVariableA("HALLIDAY_BRIDGE_PATH",path.c_str());
        clock=std::thread([this]{while(!stopped.load()){header->vsync.fetch_add(1);std::this_thread::sleep_for(std::chrono::milliseconds(5));}});
    }
    ~Host(){stopped.store(true);if(clock.joinable())clock.join();if(header){header->alive.store(0);UnmapViewOfFile(header);}DeleteFileA(path.c_str());}
    static halliday::Pose pose(unsigned serial) {
        halliday::Pose p{};p.valid=1;p.position[0]=.002f*serial;p.position[1]=1.6f+.003f*serial;p.position[2]=-.001f*serial;
        const float yaw=.013f*serial;p.orientation[1]=std::sin(yaw/2);p.orientation[3]=std::cos(yaw/2);p.stamp=float(serial);
        return p;
    }
    void publish(const halliday::Pose& pose) {
        header->stateSeq.fetch_add(1);header->state.head=pose;
        header->stateSeq.fetch_add(1);header->vsync.fetch_add(1);
    }
    void verify(const halliday::Pose& expected,unsigned pattern,bool bgra,bool srgb,uint64_t previousFrame,unsigned flipMode) {
        const uint32_t latest=header->latest.load();check(latest>0&&latest<=halliday::kSlots,"runtime published a real complete frame");
        header->reading.store(latest);const auto& frame=header->frames[latest-1];const auto seq=frame.seq.load();
        check(!(seq&1)&&frame.width==64&&frame.height==64&&!frame.bottomUp&&!frame.shared&&!frame.seeThrough,"transported crop geometry and row direction");
        if(!(frame.frameIndex>previousFrame&&frame.bgra==unsigned(bgra)))
            std::fprintf(stderr,"FRAME IDENTITY got=%llu previous=%llu bgra=%u expected_bgra=%u\n",
                (unsigned long long)frame.frameIndex,(unsigned long long)previousFrame,frame.bgra,unsigned(bgra));
        check(frame.frameIndex>previousFrame&&frame.bgra==unsigned(bgra),"monotonic source sequence and actual byte order");
        check(frame.pose.valid&&frame.pose.stamp==expected.stamp,"rendered older source pose tag survives pipelined newer wait");
        for(unsigned k=0;k<3;++k)check(std::abs(frame.pose.position[k]-expected.position[k])<.00001f,"source position is the rendered pose, not latest input");
        for(unsigned k=0;k<4;++k)check(std::abs(frame.pose.orientation[k]-expected.orientation[k])<.00001f,"source orientation is the rendered pose, not latest input");
        for(unsigned eye=0;eye<2;++eye) {
            check(halliday::frameColorSpace(frame.textureType,eye)==(srgb?halliday::kColorSrgb:halliday::kColorLinear),"per-eye UNORM/sRGB metadata survives transport");
            const auto* pixels=reinterpret_cast<const uint8_t*>(header)+halliday::imageOffset(latest-1,eye);
            for(unsigned y=0;y<64;++y) for(unsigned x=0;x<64;++x) {
                const bool horizontal=(flipMode&(eye?2u:1u))!=0,vertical=(flipMode&(eye?1u:2u))!=0;
                const unsigned sx=horizontal?63-x:x,sy=vertical?63-y:y;
                const auto& c=palette[(pattern+eye*2+(sy>=32?1:0)+(sx>=32?3:0))%6];
                const uint8_t expectedBytes[4]{uint8_t(c[bgra?2:0]*255),uint8_t(c[1]*255),uint8_t(c[bgra?0:2]*255),255};
                for(unsigned k=0;k<4;++k)if(pixels[(y*64+x)*4+k]!=expectedBytes[k]) {
                    std::fprintf(stderr,"PIXEL eye=%u x=%u y=%u channel=%u got=%u expected=%u\n",eye,x,y,k,pixels[(y*64+x)*4+k],expectedBytes[k]);
                    throw std::runtime_error("GPU eye pixels/crop/row orientation mismatch");
                }
            }
        }
        check(frame.seq.load()==seq,"host consumed a stable complete slot");header->reading.store(0);
        std::printf("EVENT {\"event\":\"verified-frame\",\"frame\":%llu,\"pose_tag\":%u,\"pattern\":%u,\"bgra\":%s,\"srgb\":%s}\n",
                    (unsigned long long)frame.frameIndex,unsigned(expected.stamp),pattern,bgra?"true":"false",srgb?"true":"false");
    }
    static constexpr float palette[6][4]{{1,0,0,1},{0,1,0,1},{0,0,1,1},{1,1,0,1},{0,1,1,1},{1,0,1,1}};
};

static std::vector<XrSessionState> events(XrSession session) {
    std::vector<XrSessionState> states;
    for(unsigned n=0;n<32;++n) {
        XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};const auto status=xr<PFN_xrPollEvent>("xrPollEvent")(instance,&event);
        if(status==XR_EVENT_UNAVAILABLE)return states;xrcheck(status,"poll native lifecycle");
        if(event.type==XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {
            const auto* state=reinterpret_cast<XrEventDataSessionStateChanged*>(&event);
            check(state->session==session,"lifecycle session identity");states.push_back(state->state);
        }
    }
    throw std::runtime_error("native event queue did not quiesce");
}

template<class Function> static std::vector<std::string> requiredExtensions(Function call,XrSystemId system) {
    uint32_t bytes=0;xrcheck(call(instance,system,0,&bytes,nullptr),"legacy extension count");
    check(bytes>0&&bytes<65536,"bounded legacy extension string");
    std::vector<char> text(bytes,'\x7f');
    if(bytes>1)check(call(instance,system,bytes-1,&bytes,text.data())==XR_ERROR_SIZE_INSUFFICIENT,
        "legacy extension string rejects insufficient capacity");
    xrcheck(call(instance,system,uint32_t(text.size()),&bytes,text.data()),"legacy extension string");
    check(bytes==text.size()&&text.back()==0,"legacy extension string terminates exactly");
    std::istringstream words(text.data());std::vector<std::string> result;std::string name;
    while(words>>name)result.push_back(name);
    return result;
}

static void run(const char* runtimePath,const char* driverPath,const char* hostPath,bool legacy,bool noHook) {
    Host host(hostPath);
    HMODULE driver=LoadLibraryA(driverPath);check(driver,"load application Vulkan loader");
    vkgipa=reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(driver,"vkGetInstanceProcAddr"));check(vkgipa,"public Vulkan loader entry point");
    vkgipa=vulkan_counting::wrap(vkgipa);
    HMODULE runtime=LoadLibraryA(runtimePath);check(runtime,"load explicit OpenXR DLL");
    const auto negotiate=reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(GetProcAddress(runtime,"xrNegotiateLoaderRuntimeInterface"));check(negotiate,"public loader negotiation export");
    XrNegotiateLoaderInfo loader{};loader.structType=XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;loader.structVersion=XR_LOADER_INFO_STRUCT_VERSION;loader.structSize=sizeof(loader);
    loader.minInterfaceVersion=loader.maxInterfaceVersion=XR_CURRENT_LOADER_RUNTIME_VERSION;
    loader.minApiVersion=XR_MAKE_VERSION(1,0,0);loader.maxApiVersion=XR_MAKE_VERSION(1,1,0);
    XrNegotiateRuntimeRequest request{};request.structType=XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;request.structVersion=XR_RUNTIME_INFO_STRUCT_VERSION;request.structSize=sizeof(request);
    xrcheck(negotiate(&loader,&request),"negotiate native independent runtime");gipa=request.getInstanceProcAddr;check(gipa,"negotiated GIPA");
    uint32_t count=0;const auto enumerate=xr<PFN_xrEnumerateInstanceExtensionProperties>("xrEnumerateInstanceExtensionProperties");
    xrcheck(enumerate(nullptr,0,&count,nullptr),"enumerate extension count");std::vector<XrExtensionProperties> extensions(count,{XR_TYPE_EXTENSION_PROPERTIES});
    xrcheck(enumerate(nullptr,count,&count,extensions.data()),"enumerate extensions");bool advertised=false;
    const char* extensionName=legacy?XR_KHR_VULKAN_ENABLE_EXTENSION_NAME:XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME;
    for(const auto& ext:extensions)if(!std::strcmp(ext.extensionName,extensionName))advertised=true;
    check(advertised,"runtime advertises requested public Vulkan extension");
    const char* enabled[]{extensionName};
    XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};std::strcpy(create.applicationInfo.applicationName,"Halliday independent public Vulkan fixture");
    create.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);create.enabledExtensionCount=1;create.enabledExtensionNames=enabled;
    xrcheck(xr<PFN_xrCreateInstance>("xrCreateInstance")(&create,&instance),"create native instance");
    XrInstanceProperties runtimeInfo{XR_TYPE_INSTANCE_PROPERTIES};xrcheck(xr<PFN_xrGetInstanceProperties>("xrGetInstanceProperties")(instance,&runtimeInfo),"runtime properties");
    std::printf("RUNTIME %s\n",runtimeInfo.runtimeName);
    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};systemInfo.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;XrSystemId system{};
    xrcheck(xr<PFN_xrGetSystem>("xrGetSystem")(instance,&systemInfo,&system),"native public system");
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};app.pApplicationName="Halliday independent test";app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo vkCreate{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};vkCreate.pApplicationInfo=&app;
    VkInstance vi{};VkPhysicalDevice physical{};VkResult status{};
    if(legacy) {
        const auto names=requiredExtensions(xr<PFN_xrGetVulkanInstanceExtensionsKHR>("xrGetVulkanInstanceExtensionsKHR"),system);
        std::vector<const char*> pointers;for(const auto& name:names)pointers.push_back(name.c_str());
        vkCreate.enabledExtensionCount=uint32_t(pointers.size());vkCreate.ppEnabledExtensionNames=pointers.data();
        if(std::find(names.begin(),names.end(),"VK_KHR_portability_enumeration")!=names.end())
            vkCreate.flags|=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
        vkcheck(vk<PFN_vkCreateInstance>(VK_NULL_HANDLE,"vkCreateInstance")(&vkCreate,nullptr,&vi),"application-owned legacy Vulkan instance");
        xrcheck(xr<PFN_xrGetVulkanGraphicsDeviceKHR>("xrGetVulkanGraphicsDeviceKHR")(instance,system,vi,&physical),"legacy runtime physical device");
        std::puts("CHECK PASS: legacy public instance-extension sizing and application-created Vulkan instance");
        if(noHook)std::puts("CHECK PASS: legacy resolves the application's globally loaded Vulkan provider without the early hook");
    } else {
        XrVulkanInstanceCreateInfoKHR instanceCreate{XR_TYPE_VULKAN_INSTANCE_CREATE_INFO_KHR};instanceCreate.systemId=system;
        instanceCreate.pfnGetInstanceProcAddr=vkgipa;instanceCreate.vulkanCreateInfo=&vkCreate;
        xrcheck(xr<PFN_xrCreateVulkanInstanceKHR>("xrCreateVulkanInstanceKHR")(instance,&instanceCreate,&vi,&status),"public runtime Vulkan instance");vkcheck(status,"Vulkan instance");
        XrVulkanGraphicsDeviceGetInfoKHR physicalInfo{XR_TYPE_VULKAN_GRAPHICS_DEVICE_GET_INFO_KHR};physicalInfo.systemId=system;physicalInfo.vulkanInstance=vi;
        xrcheck(xr<PFN_xrGetVulkanGraphicsDevice2KHR>("xrGetVulkanGraphicsDevice2KHR")(instance,&physicalInfo,&physical),"public runtime graphics device");
    }
    VkPhysicalDeviceProperties properties{};vk<PFN_vkGetPhysicalDeviceProperties>(vi,"vkGetPhysicalDeviceProperties")(physical,&properties);
    std::printf("GPU %s vendor=%x api=%u\n",properties.deviceName,properties.vendorID,properties.apiVersion);
    uint32_t families=0;const auto familyProps=vk<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(vi,"vkGetPhysicalDeviceQueueFamilyProperties");
    familyProps(physical,&families,nullptr);std::vector<VkQueueFamilyProperties> queueProperties(families);familyProps(physical,&families,queueProperties.data());
    uint32_t family=0;while(family<families&&!(queueProperties[family].queueFlags&VK_QUEUE_GRAPHICS_BIT))++family;check(family<families,"real graphics queue family");
    float priority=1;VkDeviceQueueCreateInfo queueCreate{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};queueCreate.queueFamilyIndex=family;queueCreate.queueCount=1;queueCreate.pQueuePriorities=&priority;
    VkDeviceCreateInfo deviceCreate{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};deviceCreate.queueCreateInfoCount=1;deviceCreate.pQueueCreateInfos=&queueCreate;
    VkDevice device{};
    if(legacy) {
        const auto names=requiredExtensions(xr<PFN_xrGetVulkanDeviceExtensionsKHR>("xrGetVulkanDeviceExtensionsKHR"),system);
        std::vector<const char*> pointers;for(const auto& name:names)pointers.push_back(name.c_str());
        deviceCreate.enabledExtensionCount=uint32_t(pointers.size());deviceCreate.ppEnabledExtensionNames=pointers.data();
        vkcheck(vk<PFN_vkCreateDevice>(vi,"vkCreateDevice")(physical,&deviceCreate,nullptr,&device),"application-owned legacy Vulkan device with required extensions");
        std::puts("CHECK PASS: legacy public device-extension sizing and application-created Vulkan device");
    } else {
        XrVulkanDeviceCreateInfoKHR xd{XR_TYPE_VULKAN_DEVICE_CREATE_INFO_KHR};xd.systemId=system;xd.pfnGetInstanceProcAddr=vkgipa;xd.vulkanPhysicalDevice=physical;xd.vulkanCreateInfo=&deviceCreate;
        xrcheck(xr<PFN_xrCreateVulkanDeviceKHR>("xrCreateVulkanDeviceKHR")(instance,&xd,&device,&status),"public runtime Vulkan device");vkcheck(status,"Vulkan device");
    }
    vkgdpa=vk<PFN_vkGetDeviceProcAddr>(vi,"vkGetDeviceProcAddr");VkQueue queue{};deviceFn<PFN_vkGetDeviceQueue>(device,"vkGetDeviceQueue")(device,family,0,&queue);
    XrGraphicsBindingVulkanKHR binding{legacy?XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR:XR_TYPE_GRAPHICS_BINDING_VULKAN2_KHR};binding.instance=vi;binding.physicalDevice=physical;binding.device=device;binding.queueFamilyIndex=family;
    XrSessionCreateInfo sessionCreate{XR_TYPE_SESSION_CREATE_INFO};sessionCreate.systemId=system;sessionCreate.next=&binding;XrSession session{};
    check(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session)==XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING && session==XR_NULL_HANDLE,
          "missing graphics requirements fails without creating a session");
    std::puts("CHECK PASS: missing Vulkan graphics requirements fails cleanly with real objects");
    if(legacy) {
        XrGraphicsRequirementsVulkanKHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN_KHR};
        xrcheck(xr<PFN_xrGetVulkanGraphicsRequirementsKHR>("xrGetVulkanGraphicsRequirementsKHR")(instance,system,&requirements),"legacy Vulkan requirements");
    } else {
        XrGraphicsRequirementsVulkan2KHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_VULKAN2_KHR};
        xrcheck(xr<PFN_xrGetVulkanGraphicsRequirements2KHR>("xrGetVulkanGraphicsRequirements2KHR")(instance,system,&requirements),"Vulkan2 requirements");
    }
    binding.queueFamilyIndex=UINT32_MAX;
    check(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session)==XR_ERROR_GRAPHICS_DEVICE_INVALID && session==XR_NULL_HANDLE,
          "invalid queue family fails without touching arbitrary pointers");
    std::puts("CHECK PASS: invalid queue family rejected with valid Vulkan handles");
    binding.queueFamilyIndex=family;
    if(!legacy) {
        binding.queueIndex=1; // Only Vulkan2 exposes created logical queues to the runtime.
        check(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session)==XR_ERROR_GRAPHICS_DEVICE_INVALID && session==XR_NULL_HANDLE,
              "uncreated logical queue rejected before invoking Vulkan queue access");
        std::printf("CHECK PASS: logical queue index1 not created; physical family capacity=%u\n",queueProperties[family].queueCount);
    }
    binding.queueIndex=0;
    xrcheck(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session),"create Vulkan session");
    const auto startup=events(session);check(std::find(startup.begin(),startup.end(),XR_SESSION_STATE_READY)!=startup.end(),"READY before BeginSession");
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};begin.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    xrcheck(xr<PFN_xrBeginSession>("xrBeginSession")(session,&begin),"begin Vulkan session");events(session);
    XrReferenceSpaceCreateInfo stageInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};stageInfo.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_STAGE;stageInfo.poseInReferenceSpace.orientation.w=1;XrSpace stage{};
    xrcheck(xr<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&stageInfo,&stage),"create stage");
    uint32_t nFormats=0;const auto enumerateFormats=xr<PFN_xrEnumerateSwapchainFormats>("xrEnumerateSwapchainFormats");xrcheck(enumerateFormats(session,0,&nFormats,nullptr),"format count");
    std::vector<int64_t> formats(nFormats);xrcheck(enumerateFormats(session,nFormats,&nFormats,formats.data()),"format list");
    VkCommandPool pool{};VkCommandPoolCreateInfo poolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};poolInfo.queueFamilyIndex=family;poolInfo.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    vkcheck(deviceFn<PFN_vkCreateCommandPool>(device,"vkCreateCommandPool")(device,&poolInfo,nullptr,&pool),"app command pool");
    VkCommandBuffer cmd{};VkCommandBufferAllocateInfo commandInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};commandInfo.commandPool=pool;commandInfo.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;commandInfo.commandBufferCount=1;
    vkcheck(deviceFn<PFN_vkAllocateCommandBuffers>(device,"vkAllocateCommandBuffers")(device,&commandInfo,&cmd),"app command buffer");
    VkFence fence{};VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};vkcheck(deviceFn<PFN_vkCreateFence>(device,"vkCreateFence")(device,&fenceInfo,nullptr,&fence),"app submission fence");
    const VkFormat wanted[]{VK_FORMAT_B8G8R8A8_UNORM,VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_B8G8R8A8_SRGB,VK_FORMAT_R8G8B8A8_SRGB};
    unsigned frameNumber=0,warmups=0,verified=0,drains=0,destroyWarmups=0;uint64_t quadFrames=0,legacyFrames=0;
    for(unsigned phase=0;phase<4;++phase) {
        const auto format=wanted[phase];check(std::find(formats.begin(),formats.end(),int64_t(format))!=formats.end(),"all four explicit Vulkan byte formats supported");
        const bool array=(phase%2)==0,bgra=format==VK_FORMAT_B8G8R8A8_UNORM||format==VK_FORMAT_B8G8R8A8_SRGB,srgb=phase>=2;
        XrSwapchain chains[2]{};std::vector<XrSwapchainImageVulkan2KHR> images[2];
        for(unsigned eye=0;eye<(array?1u:2u);++eye) {
            XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};info.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_TRANSFER_DST_BIT;
            info.format=format;info.sampleCount=info.faceCount=info.mipCount=1;info.width=80;info.height=72;info.arraySize=array?2:1;
            xrcheck(xr<PFN_xrCreateSwapchain>("xrCreateSwapchain")(session,&info,&chains[eye]),"create real Vulkan swapchain");
            uint32_t n=0;const auto enumerateImages=xr<PFN_xrEnumerateSwapchainImages>("xrEnumerateSwapchainImages");xrcheck(enumerateImages(chains[eye],0,&n,nullptr),"image count");check(n>0&&n<16,"bounded image pool");
            images[eye].resize(n,{legacy?XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR:XR_TYPE_SWAPCHAIN_IMAGE_VULKAN2_KHR});xrcheck(enumerateImages(chains[eye],n,&n,reinterpret_cast<XrSwapchainImageBaseHeader*>(images[eye].data())),"enumerate actual VkImages");
        }
        VkAttachmentDescription attachment{};attachment.format=format;attachment.samples=VK_SAMPLE_COUNT_1_BIT;attachment.loadOp=VK_ATTACHMENT_LOAD_OP_LOAD;attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
        attachment.initialLayout=attachment.finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkAttachmentReference color{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};VkSubpassDescription subpass{};subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;subpass.colorAttachmentCount=1;subpass.pColorAttachments=&color;
        VkRenderPassCreateInfo renderInfo{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};renderInfo.attachmentCount=1;renderInfo.pAttachments=&attachment;renderInfo.subpassCount=1;renderInfo.pSubpasses=&subpass;VkRenderPass renderPass{};
        vkcheck(deviceFn<PFN_vkCreateRenderPass>(device,"vkCreateRenderPass")(device,&renderInfo,nullptr,&renderPass),"app clear render pass");
        bool reused=false,hasNext=false;std::vector<uint32_t> acquiredIndices[2];
        XrFrameState nextFrame{XR_TYPE_FRAME_STATE};halliday::Pose nextPose{};
        struct Submitted {
            halliday::Pose pose{};unsigned pattern=0,flip=0;
            XrCompositionLayerProjectionView views[2]{};
        } prior;
        // Three independently changing ordinary pictures per optical layout,
        // then one explicit drain input so every ordinary source is observed.
        // Keeping the next WaitFrame token avoids an empty frame resetting the
        // paired capture after every image, which would never test steady PRIOR.
        for(unsigned iteration=0;iteration<16;++iteration) {
            const unsigned pass=iteration/4,repeat=iteration%4;
            const unsigned serial=100+frameNumber,pattern=frameNumber%6;
            const auto rendered=hasNext?nextPose:Host::pose(serial);
            XrFrameState frame{XR_TYPE_FRAME_STATE};
            if(hasNext)frame=nextFrame;
            else {
                host.publish(rendered);
                xrcheck(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame),"wait rendered source frame");
            }
            hasNext=false;check(frame.shouldRender,"synthetic live host requests rendering");
            xrcheck(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr),"begin real frame");
            XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};locate.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;locate.displayTime=frame.predictedDisplayTime;locate.space=stage;
            XrViewState state{XR_TYPE_VIEW_STATE};XrView views[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}};uint32_t n=0;
            xrcheck(xr<PFN_xrLocateViews>("xrLocateViews")(session,&locate,&state,2,&n,views),"locate rendered source views");check(n==2&&(state.viewStateFlags&XR_VIEW_STATE_POSITION_TRACKED_BIT),"tracked stereo views");
            const auto& a=views[0].pose.position;const auto& b=views[1].pose.position;check(std::abs(std::sqrt((a.x-b.x)*(a.x-b.x)+(a.y-b.y)*(a.y-b.y)+(a.z-b.z)*(a.z-b.z))-.064f)<.00001f,"calibrated IPD in rotated stereo views");
            uint32_t indices[2]{};for(unsigned eye=0;eye<(array?1u:2u);++eye) {
                XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};xrcheck(xr<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(chains[eye],&acquire,&indices[eye]),"acquire Vulkan image");
                reused=reused||std::find(acquiredIndices[eye].begin(),acquiredIndices[eye].end(),indices[eye])!=acquiredIndices[eye].end();
                acquiredIndices[eye].push_back(indices[eye]);
                XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};wait.timeout=XR_INFINITE_DURATION;xrcheck(xr<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(chains[eye],&wait),"wait Vulkan image ownership");
            }
            vkcheck(deviceFn<PFN_vkResetCommandPool>(device,"vkResetCommandPool")(device,pool,0),"reset completed app commands");
            vkcheck(deviceFn<PFN_vkResetFences>(device,"vkResetFences")(device,1,&fence),"reset app fence");
            VkCommandBufferBeginInfo commandBegin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};commandBegin.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
            vkcheck(deviceFn<PFN_vkBeginCommandBuffer>(device,"vkBeginCommandBuffer")(cmd,&commandBegin),"begin GPU-only pattern clear");
            std::vector<VkImageView> imageViews;std::vector<VkFramebuffer> framebuffers;
            XrCompositionLayerProjectionView projected[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
            for(unsigned eye=0;eye<2;++eye) {
                const unsigned chainIndex=array?0:eye,slice=array?eye:0;const auto image=images[chainIndex][indices[chainIndex]].image;
                VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};barrier.oldLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;barrier.newLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.srcQueueFamilyIndex=barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;barrier.image=image;barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,slice,1};
                deviceFn<PFN_vkCmdPipelineBarrier>(device,"vkCmdPipelineBarrier")(cmd,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,nullptr,0,nullptr,1,&barrier);
                VkClearColorValue outside{{0,0,1,1}};deviceFn<PFN_vkCmdClearColorImage>(device,"vkCmdClearColorImage")(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,&outside,1,&barrier.subresourceRange);
                barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;barrier.newLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;barrier.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                deviceFn<PFN_vkCmdPipelineBarrier>(device,"vkCmdPipelineBarrier")(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,0,nullptr,0,nullptr,1,&barrier);
                VkImageViewCreateInfo viewInfo{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};viewInfo.image=image;viewInfo.viewType=VK_IMAGE_VIEW_TYPE_2D;viewInfo.format=format;viewInfo.subresourceRange=barrier.subresourceRange;VkImageView view{};
                vkcheck(deviceFn<PFN_vkCreateImageView>(device,"vkCreateImageView")(device,&viewInfo,nullptr,&view),"app per-eye image view");imageViews.push_back(view);
                VkFramebufferCreateInfo fbInfo{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};fbInfo.renderPass=renderPass;fbInfo.attachmentCount=1;fbInfo.pAttachments=&view;fbInfo.width=80;fbInfo.height=72;fbInfo.layers=1;VkFramebuffer fb{};
                vkcheck(deviceFn<PFN_vkCreateFramebuffer>(device,"vkCreateFramebuffer")(device,&fbInfo,nullptr,&fb),"app framebuffer");framebuffers.push_back(fb);
                VkRenderPassBeginInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};rp.renderPass=renderPass;rp.framebuffer=fb;rp.renderArea={{0,0},{80,72}};
                deviceFn<PFN_vkCmdBeginRenderPass>(device,"vkCmdBeginRenderPass")(cmd,&rp,VK_SUBPASS_CONTENTS_INLINE);
                for(unsigned row=0;row<2;++row)for(unsigned column=0;column<2;++column) {
                    VkClearAttachment clear{};clear.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;std::memcpy(clear.clearValue.color.float32,Host::palette[(pattern+eye*2+row+column*3)%6],16);
                    VkClearRect rect{{{int32_t(8+32*column),int32_t(4+32*row)},{32,32}},0,1};deviceFn<PFN_vkCmdClearAttachments>(device,"vkCmdClearAttachments")(cmd,1,&clear,1,&rect);
                }
                deviceFn<PFN_vkCmdEndRenderPass>(device,"vkCmdEndRenderPass")(cmd);
                projected[eye].pose=views[eye].pose;projected[eye].fov=views[eye].fov;projected[eye].subImage.swapchain=chains[chainIndex];projected[eye].subImage.imageArrayIndex=slice;projected[eye].subImage.imageRect={{8,4},{64,64}};
                if(pass) {
                    projected[eye].fov.angleLeft*=eye?.78f:.83f;
                    projected[eye].fov.angleRight*=eye?.91f:.72f;
                    projected[eye].fov.angleUp*=eye?.87f:.76f;
                    projected[eye].fov.angleDown*=eye?.69f:.94f;
                }
                // Optical zoom is frame metadata, not an image-layout reset.
                // Every ordinary/drain submission changes all four angles;
                // an older capture must retain its own exact submitted FOV.
                projected[eye].fov.angleLeft*=1.0f-.011f*repeat;
                projected[eye].fov.angleRight*=1.0f-.013f*repeat;
                projected[eye].fov.angleUp*=1.0f-.009f*repeat;
                projected[eye].fov.angleDown*=1.0f-.015f*repeat;
                if(pass>=2) {
                    projected[eye].pose.position.x+=eye?.01f:-.01f;
                    projected[eye].pose.position.y+=eye?.006f:-.006f;
                    if(eye) {
                        const auto q=projected[eye].pose.orientation;const float a=.07f,c=std::cos(a),sn=std::sin(a);
                        projected[eye].pose.orientation={q.w*sn+q.x*c,q.y*c+q.z*sn,q.z*c-q.y*sn,q.w*c-q.x*sn};
                    }
                }
                if(pass&(eye?2u:1u))std::swap(projected[eye].fov.angleLeft,projected[eye].fov.angleRight);
                if(pass&(eye?1u:2u))std::swap(projected[eye].fov.angleDown,projected[eye].fov.angleUp);
            }
            vkcheck(deviceFn<PFN_vkEndCommandBuffer>(device,"vkEndCommandBuffer")(cmd),"end app clear commands");
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&cmd;vkcheck(deviceFn<PFN_vkQueueSubmit>(device,"vkQueueSubmit")(queue,1,&submit,fence),"submit GPU pattern without CPU wait");
            for(unsigned eye=0;eye<(array?1u:2u);++eye) {XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};xrcheck(xr<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(chains[eye],&release),"release rendered image in COLOR_ATTACHMENT layout");}
            if(frameNumber==0) {
                XrCompositionLayerProjection invalidLayer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};invalidLayer.space=stage;invalidLayer.viewCount=2;invalidLayer.views=projected;
                const XrCompositionLayerBaseHeader* invalidLayers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&invalidLayer)};
                legacyFrames+=projection_checks::oldPeer(gipa,instance,session,host.header,invalidLayer,frame);
                for(unsigned bad=0;bad<10;++bad) {
                    const auto saved=projected[1];
                    if(bad==0)projected[1].subImage.imageRect.offset.x=-1;
                    if(bad==1)projected[1].subImage.imageArrayIndex=2;
                    if(bad==2)projected[1].subImage.imageRect.extent.width=81;
                    if(bad==3)projected[1].subImage.imageRect.extent.width=63;
                    if(bad==4)projected[1].type=XR_TYPE_COMPOSITION_LAYER_QUAD;
                    if(bad==5)projected[1].fov.angleLeft=NAN;
                    if(bad==6)projected[1].fov.angleRight=1.57079633f;
                    if(bad==7)projected[1].fov.angleDown=-1.57079633f;
                    if(bad==8)projected[1].fov.angleUp=2.0f;
                    if(bad==9)projected[1].pose.orientation.w=2.0f;
                    XrFrameEndInfo invalid{XR_TYPE_FRAME_END_INFO};invalid.displayTime=frame.predictedDisplayTime;
                    invalid.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;invalid.layerCount=1;invalid.layers=invalidLayers;
                    const auto before=host.header->clientFrames.load();const auto latest=host.header->latest.load();
                    const auto rejected=xr<PFN_xrEndFrame>("xrEndFrame")(session,&invalid);
                    check(rejected==(bad==9?XR_ERROR_POSE_INVALID:(bad==1||bad>=4)?XR_ERROR_VALIDATION_FAILURE:XR_ERROR_SWAPCHAIN_RECT_INVALID),
                          "malformed crop/array/FOV/type/pose rejects before GPU readback publication");
                    check(host.header->clientFrames.load()==before&&host.header->latest.load()==latest,
                          "failed frame must not publish stale or partial output");
                    projected[1]=saved;
                    xrcheck(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&frame),"recover next frame after malformed submission");
                    xrcheck(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr),"begin valid recovery frame");
                }
                std::puts("CHECK PASS: invalid crop/array/FOV/view type/pose publish nothing; next valid frame recovers");
            }
            // Standard application pipelining: receive a newer pose before
            // submitting the picture drawn from the earlier locateViews.
            auto newer=Host::pose(serial+1);
            if(frameNumber%2) {
                // A translation-only newer pose has exactly the same rotation.
                // Matching history by quaternion alone would mis-tag old colour.
                std::copy(std::begin(rendered.orientation),std::end(rendered.orientation),std::begin(newer.orientation));
            }
            host.publish(newer);XrFrameState future{XR_TYPE_FRAME_STATE};
            xrcheck(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&future),"pipeline newer input before old EndFrame");
            nextFrame=future;nextPose=newer;hasNext=true;
            XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};layer.space=stage;layer.viewCount=2;layer.views=projected;
            const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer)};
            XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};end.displayTime=frame.predictedDisplayTime;end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;end.layerCount=1;end.layers=layers;
            Submitted current{};current.pose=rendered;current.pattern=pattern;current.flip=pass;
            std::copy(std::begin(projected),std::end(projected),std::begin(current.views));
            const uint64_t previous=host.header->clientFrames.load();const auto previousLatest=host.header->latest.load();vulkan_counting::reset();
            xrcheck(xr<PFN_xrEndFrame>("xrEndFrame")(session,&end),"runtime orders app GPU commands and transports stereo crops");
            if(!legacy) {
                check(vulkan_counting::submissions==1&&vulkan_counting::waits<=(repeat?1u:0u),
                      "one paired Vulkan enqueue; first capture never waits for its current GPU fence");
                check(vulkan_counting::copies==2&&vulkan_counting::maximumCopiesPerSubmission==2,
                      "every requested rectangle is copied in the same GPU batch");
            }
            if(!repeat) {
                check(host.header->clientFrames.load()==previous&&host.header->latest.load()==previousLatest,
                      "first opaque capture after warmup/layout/reset publishes no invented or stale stereo");
                ++warmups;
            } else {
                check(host.header->clientFrames.load()==previous+1,"exactly one older complete stereo pair per ordinary EndFrame");
                host.verify(prior.pose,prior.pattern,bgra,srgb,previous,prior.flip);
                projection_checks::verify(host.header,prior.views);++verified;
                if(repeat==3)++drains;
            }
            prior=current;
            // The client may recycle its rendering resources after its own
            // submission completes. This wait is AFTER xrEndFrame and its call
            // counters, so it neither makes the runtime synchronous nor lets a
            // current-fence wait pass as an old-image retirement.
            vkcheck(deviceFn<PFN_vkWaitForFences>(device,"vkWaitForFences")(device,1,&fence,VK_TRUE,10'000'000'000),"client completes app render resources after EndFrame");
            for(auto fb:framebuffers)deviceFn<PFN_vkDestroyFramebuffer>(device,"vkDestroyFramebuffer")(device,fb,nullptr);
            for(auto view:imageViews)deviceFn<PFN_vkDestroyImageView>(device,"vkDestroyImageView")(device,view,nullptr);
            if(repeat==3) {
                xrcheck(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr),"drain pipelined next-frame token");hasNext=false;
                end.displayTime=future.predictedDisplayTime;end.layerCount=0;end.layers=nullptr;
                vulkan_counting::reset();
                xrcheck(xr<PFN_xrEndFrame>("xrEndFrame")(session,&end),"drain empty pipelined frame");
                check(vulkan_counting::submissions==0&&vulkan_counting::copies==0&&vulkan_counting::waits<=2,
                      "empty frame only retires bounded pending fences, without a new GPU copy or submission");
                projection_checks::absent(host.header);
                if(phase==0&&iteration==3){
                    const auto countBefore=host.header->clientFrames.load();
                    const auto& a=Host::palette[pattern%6];const auto& b=Host::palette[(pattern+2)%6];
                    vulkan_counting::reset();
                    quad_checks::run(gipa,instance,session,host.header,layer,projected[0].subImage,projected[1].subImage,
                        std::array<uint8_t,4>{uint8_t(a[2]*255),uint8_t(a[1]*255),uint8_t(a[0]*255),255},
                        std::array<uint8_t,4>{uint8_t(b[2]*255),uint8_t(b[1]*255),uint8_t(b[0]*255),255});
                    if(!legacy)check(vulkan_counting::maximumCopiesPerSubmission==8,
                        "eight quad rectangles share one actual Vulkan submission");
                    quadFrames=host.header->clientFrames.load()-countBefore;
                }
            }
            ++frameNumber;
        }
        check(reused,"real swapchain image pool is reused after completion");
        // Leave one real paired transfer pending when the source chains die.
        // The following phase must start clean rather than return bytes or
        // geometry owned by this destroyed format/array generation.
        XrFrameState dying{XR_TYPE_FRAME_STATE};
        xrcheck(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&dying),"wait pending-chain destruction probe");
        xrcheck(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr),"begin pending-chain destruction probe");
        XrCompositionLayerProjection dyingLayer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
        dyingLayer.space=stage;dyingLayer.viewCount=2;dyingLayer.views=prior.views;
        const XrCompositionLayerBaseHeader* dyingLayers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&dyingLayer)};
        XrFrameEndInfo dyingEnd{XR_TYPE_FRAME_END_INFO};dyingEnd.displayTime=dying.predictedDisplayTime;
        dyingEnd.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;dyingEnd.layerCount=1;dyingEnd.layers=dyingLayers;
        const auto beforeDestroy=host.header->clientFrames.load();
        const auto latestBeforeDestroy=host.header->latest.load();
        xrcheck(xr<PFN_xrEndFrame>("xrEndFrame")(session,&dyingEnd),"enqueue pending image before chain destruction");
        check(host.header->clientFrames.load()==beforeDestroy&&host.header->latest.load()==latestBeforeDestroy,
              "pending chain warmup cannot publish an unverified current image");++destroyWarmups;
        for(auto chain:chains)if(chain)xrcheck(xr<PFN_xrDestroySwapchain>("xrDestroySwapchain")(chain),"destroy completed runtime images");
        check(host.header->clientFrames.load()==beforeDestroy&&host.header->latest.load()==latestBeforeDestroy,
              "destroying pending source images cannot publish stale or partial stereo");
        deviceFn<PFN_vkDestroyRenderPass>(device,"vkDestroyRenderPass")(device,renderPass,nullptr);
    }
    std::puts("CHECK PASS: exact HLPG frame/epoch/view/FOV metadata; asymmetric zoom, canted right camera, independent eye offsets; no geometry bit on retirement");
    std::puts("CHECK PASS: continuously animated per-eye FOV does not stall PRIOR; every older picture retains its exact older four-angle optical geometry");
    std::puts("CHECK PASS: exact per-eye normal/H/V/HV projection flips from legal reversed FOV; quad pixels retain their independent orientation");
    if(!legacy)std::puts("CHECK PASS: actual Vulkan calls confirm one paired enqueue, no current-fence wait on warmup, bounded prior retirement, batched quads and no new GPU copies for empty frames");
    check(warmups==16&&verified==48&&drains==16&&destroyWarmups==4,
          "all ordinary sources survive exact prior verification; layout warmups, drains and pending chain destruction are explicit");
    check(host.header->clientFrames.load()==64+quadFrames+legacyFrames,"forty-eight exact prior stereo publications, sixteen empty retirements and verified quad/legacy frames only");
    xrcheck(xr<PFN_xrDestroySpace>("xrDestroySpace")(stage),"destroy stage");
    xrcheck(xr<PFN_xrRequestExitSession>("xrRequestExitSession")(session),"request orderly session exit");
    const auto stopping=events(session);check(std::find(stopping.begin(),stopping.end(),XR_SESSION_STATE_STOPPING)!=stopping.end(),"STOPPING event before EndSession");
    xrcheck(xr<PFN_xrEndSession>("xrEndSession")(session),"end native session");events(session);
    xrcheck(xr<PFN_xrDestroySession>("xrDestroySession")(session),"destroy runtime-owned Vulkan context");
    // The same application/device can reconnect without inheriting its old
    // image, and an existing session must not revive after host loss.
    xrcheck(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session),"recreate Vulkan session on same device");
    check(host.header->clientFrames.load()==0&&host.header->latest.load()==0,"Vulkan reconnect starts with no stale image/count");
    events(session);xrcheck(xr<PFN_xrBeginSession>("xrBeginSession")(session,&begin),"begin recreated Vulkan session");events(session);
    host.header->alive.store(0);
    const auto lost=events(session);check(std::find(lost.begin(),lost.end(),XR_SESSION_STATE_STOPPING)!=lost.end(),"Vulkan host loss stops via event polling alone");
    host.header->alive.store(1);check(events(session).empty(),"old Vulkan session cannot revive after host returns");
    xrcheck(xr<PFN_xrEndSession>("xrEndSession")(session),"end lost Vulkan session");events(session);
    xrcheck(xr<PFN_xrDestroySession>("xrDestroySession")(session),"destroy lost Vulkan session");
    xrcheck(xr<PFN_xrCreateSession>("xrCreateSession")(instance,&sessionCreate,&session),"reconnect fresh Vulkan session after host returns");
    events(session);xrcheck(xr<PFN_xrBeginSession>("xrBeginSession")(session,&begin),"begin fresh recovered Vulkan session");events(session);
    xrcheck(xr<PFN_xrRequestExitSession>("xrRequestExitSession")(session),"exit recovered Vulkan session");events(session);
    xrcheck(xr<PFN_xrEndSession>("xrEndSession")(session),"end recovered Vulkan session");events(session);
    xrcheck(xr<PFN_xrDestroySession>("xrDestroySession")(session),"destroy recovered Vulkan session");
    std::puts("CHECK PASS: Vulkan session recreation clears stale pictures; event-only host loss cannot revive old session; fresh reconnect succeeds");
    vkcheck(deviceFn<PFN_vkDeviceWaitIdle>(device,"vkDeviceWaitIdle")(device),"client Vulkan device remains usable after runtime teardown");
    deviceFn<PFN_vkDestroyFence>(device,"vkDestroyFence")(device,fence,nullptr);
    deviceFn<PFN_vkDestroyCommandPool>(device,"vkDestroyCommandPool")(device,pool,nullptr);
    deviceFn<PFN_vkDestroyDevice>(device,"vkDestroyDevice")(device,nullptr);vk<PFN_vkDestroyInstance>(vi,"vkDestroyInstance")(vi,nullptr);
    xrcheck(xr<PFN_xrDestroyInstance>("xrDestroyInstance")(instance),"destroy OpenXR instance");instance=XR_NULL_HANDLE;
    FreeLibrary(runtime);FreeLibrary(driver);
    std::printf("PASS: independent Windows public %s runtime; forty-eight changing exact prior stereo/cropped GPU patterns; sixteen warmup/reset and drain cases; array/separate image reuse; four formats/transfer tags; older rotated/translation-only rendered pose; app queue completion; normal teardown\n",legacy?"Vulkan legacy":"Vulkan2");
}
int main(int argc,char** argv) {
    try {
        const bool noHook=argc==5&&!std::strcmp(argv[4],"--legacy-no-hook");
        const bool legacy=noHook||(argc==5&&!std::strcmp(argv[4],"--legacy"));
        check(argc==4||legacy,"usage: native-independent-vulkan-probe RUNTIME DRIVER NEW_BRIDGE [--legacy]");
        run(argv[1],argv[2],argv[3],legacy,noHook);return 0;
    }
    catch(const std::exception& error){std::fprintf(stderr,"FAIL: %s\n",error.what());return 1;}
}
