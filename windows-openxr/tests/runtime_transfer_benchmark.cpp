// Small, paced GPU transfer checks. Measures xrEndFrame only: GPU readback + bridge publication,
// not game rendering, video encoding, a display compositor or motion-to-photon latency.
#include <windows.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "bridge_layout.hpp"
#include "transfer_stats.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <new>
#include <numeric>
#include <string>
#include <vector>

static void check(bool value,const char* reason) {
    if (!value) { std::fprintf(stderr,"FAIL: %s (Windows error %lu)\n",reason,GetLastError()); std::exit(1); }
}
template <typename T> static void drop(T*& value) { if (value) value->Release(); value=nullptr; }
static PFN_xrGetInstanceProcAddr gGipa=nullptr;
static XrInstance gInstance=XR_NULL_HANDLE;
template <typename F> static F xr(const char* name) {
    PFN_xrVoidFunction result=nullptr;
    check(gGipa(gInstance,name,&result)==XR_SUCCESS && result,name);
    return reinterpret_cast<F>(result);
}
static double clockMs() {
    LARGE_INTEGER now{},frequency{}; QueryPerformanceCounter(&now); QueryPerformanceFrequency(&frequency);
    return static_cast<double>(now.QuadPart)*1000.0/static_cast<double>(frequency.QuadPart);
}
static bool closeFloat(float a,float b) { return std::abs(a-b)<.0001f; }
static void printProvider(const wchar_t* moduleName,const char* label) {
    const auto* base=reinterpret_cast<const uint8_t*>(GetModuleHandleW(moduleName));
    check(base!=nullptr,"graphics provider is mapped");
    const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    const auto* pe=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    check(dos->e_magic==IMAGE_DOS_SIGNATURE&&pe->Signature==IMAGE_NT_SIGNATURE,"provider PE headers");
    const auto* sections=IMAGE_FIRST_SECTION(pe);
    for (unsigned i=0;i<pe->FileHeader.NumberOfSections;++i) if (!std::memcmp(sections[i].Name,".text\0",6)) {
        const size_t size=sections[i].Misc.VirtualSize;
        uint64_t hash=14695981039346656037ULL;
        for (size_t at=0;at<size;++at) { hash^=base[sections[i].VirtualAddress+at]; hash*=1099511628211ULL; }
        std::printf("PROVIDER %s stamp=%08lx image=%08lx text_bytes=%08lx text_fnv64=%016llx\n",label,
            pe->FileHeader.TimeDateStamp,pe->OptionalHeader.SizeOfImage,sections[i].Misc.VirtualSize,
            static_cast<unsigned long long>(hash)); std::fflush(stdout); return;
    }
    check(false,"provider text exists");
}

struct Host {
    std::wstring path;
    halliday::Header* header=nullptr;
    HANDLE stop=nullptr,thread=nullptr;
    static DWORD WINAPI pulse(void* value) {
        auto* self=static_cast<Host*>(value);
        double next=clockMs()+1000.0/72;
        while (WaitForSingleObject(self->stop,1)==WAIT_TIMEOUT) {
            const double now=clockMs();
            if (now>=next) {
                self->header->vsync.fetch_add(1);
                do { next+=1000.0/72; } while (next<=now);
            }
        }
        return 0;
    }
    explicit Host(const wchar_t* name):path(name) {
        std::wstring normalized=path;
        for (auto& c:normalized) { if (c==L'/') c=L'\\'; c=std::towlower(c); }
        check(normalized.find(L"\\windows-openxr\\build\\tests\\")!=std::wstring::npos &&
            normalized.find(L"..") == std::wstring::npos,"only an isolated test bridge is accepted");
        HANDLE file=CreateFileW(path.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
            nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        check(file!=INVALID_HANDLE_VALUE,"create NEW bridge fixture; never truncate another host");
        LARGE_INTEGER bytes{}; bytes.QuadPart=halliday::kFileBytes;
        check(SetFilePointerEx(file,bytes,nullptr,FILE_BEGIN)&&SetEndOfFile(file),"size sparse test bridge");
        HANDLE mapping=CreateFileMappingW(file,nullptr,PAGE_READWRITE,0,0,nullptr); CloseHandle(file);
        check(mapping!=nullptr,"create fixture mapping");
        void* memory=MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,halliday::kFileBytes); CloseHandle(mapping);
        check(memory!=nullptr,"map fixture"); header=new(memory)halliday::Header{};
        header->magic=halliday::kMagic; header->version=6;
        header->eyeWidth=header->eyeHeight=512; header->displayHz=72; header->ipd=.064f;
        for (auto& fov:header->tangents) { fov[0]=fov[3]=-1; fov[1]=fov[2]=1; }
        header->state.head.valid=1; header->state.head.position[1]=1.6f; header->state.head.orientation[3]=1;
        header->state.head.stamp=42; header->alive.store(1); header->stateSeq.store(2);
        header->vsync.store(1); header->intervalNs.store(13'888'889);
        SetEnvironmentVariableW(L"HALLIDAY_BRIDGE_PATH",path.c_str());
        stop=CreateEventW(nullptr,TRUE,FALSE,nullptr); thread=CreateThread(nullptr,0,pulse,this,0,nullptr);
        check(stop&&thread,"create nominal 72 Hz host clock");
    }
    void pose(unsigned sequence) {
        header->stateSeq.fetch_add(1);
        header->state.head.position[1]=1.6f+.001f*sequence;
        header->state.head.stamp=42.f+sequence;
        header->stateSeq.fetch_add(1);
    }
    ~Host() {
        if (stop) SetEvent(stop);
        if (thread) { WaitForSingleObject(thread,INFINITE); CloseHandle(thread); }
        if (stop) CloseHandle(stop);
        if (header) { header->alive.store(0); UnmapViewOfFile(header); }
        DeleteFileW(path.c_str());
    }
};

struct App {
    bool api12;
    ID3D11Device* d11=nullptr; ID3D11DeviceContext* c11=nullptr;
    ID3D12Device* d12=nullptr; ID3D12CommandQueue* queue=nullptr;
    ID3D12CommandAllocator* allocator=nullptr; ID3D12GraphicsCommandList* commands=nullptr;
    ID3D12DescriptorHeap* descriptors=nullptr; ID3D12Fence* fence=nullptr;
    HANDLE event=nullptr; uint64_t submitted=0;
    explicit App(bool use12,XrSystemId system):api12(use12) {
        LUID luid{}; D3D_FEATURE_LEVEL level=D3D_FEATURE_LEVEL_11_0;
        if (api12) {
            XrGraphicsRequirementsD3D12KHR r{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D12_KHR};
            check(xr<PFN_xrGetD3D12GraphicsRequirementsKHR>("xrGetD3D12GraphicsRequirementsKHR")(gInstance,system,&r)==XR_SUCCESS,"D3D12 requirements");
            luid=r.adapterLuid; level=r.minFeatureLevel;
        } else {
            XrGraphicsRequirementsD3D11KHR r{XR_TYPE_GRAPHICS_REQUIREMENTS_D3D11_KHR};
            check(xr<PFN_xrGetD3D11GraphicsRequirementsKHR>("xrGetD3D11GraphicsRequirementsKHR")(gInstance,system,&r)==XR_SUCCESS,"D3D11 requirements");
            luid=r.adapterLuid; level=r.minFeatureLevel;
        }
        IDXGIFactory1* factory=nullptr;
        check(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))),"create DXGI factory");
        IDXGIAdapter1* adapter=nullptr;
        for (UINT index=0; factory->EnumAdapters1(index,&adapter)==S_OK; ++index) {
            DXGI_ADAPTER_DESC1 desc{}; adapter->GetDesc1(&desc);
            if (desc.AdapterLuid.LowPart==luid.LowPart && desc.AdapterLuid.HighPart==luid.HighPart) break;
            drop(adapter);
        }
        drop(factory); check(adapter!=nullptr,"find required adapter");
        if (!api12) {
            check(SUCCEEDED(D3D11CreateDevice(adapter,D3D_DRIVER_TYPE_UNKNOWN,nullptr,D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                &level,1,D3D11_SDK_VERSION,&d11,nullptr,&c11)),"create app D3D11 device");
        } else {
            check(SUCCEEDED(D3D12CreateDevice(adapter,level,IID_PPV_ARGS(&d12))),"create app D3D12 device");
            D3D12_COMMAND_QUEUE_DESC q{}; q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
            check(SUCCEEDED(d12->CreateCommandQueue(&q,IID_PPV_ARGS(&queue))),"create app direct queue");
            check(SUCCEEDED(d12->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator))),"create app allocator");
            check(SUCCEEDED(d12->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator,nullptr,IID_PPV_ARGS(&commands)))&&SUCCEEDED(commands->Close()),"create app list");
            D3D12_DESCRIPTOR_HEAP_DESC heap{}; heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV; heap.NumDescriptors=2;
            check(SUCCEEDED(d12->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&descriptors))),"create app RTV descriptors");
            check(SUCCEEDED(d12->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence))),"create app completion fence");
            event=CreateEventW(nullptr,FALSE,FALSE,nullptr); check(event!=nullptr,"create app completion event");
        }
        drop(adapter);
    }
    XrSession session(XrSystemId system) {
        XrGraphicsBindingD3D11KHR b11{XR_TYPE_GRAPHICS_BINDING_D3D11_KHR}; b11.device=d11;
        XrGraphicsBindingD3D12KHR b12{XR_TYPE_GRAPHICS_BINDING_D3D12_KHR}; b12.device=d12; b12.queue=queue;
        XrSessionCreateInfo create{XR_TYPE_SESSION_CREATE_INFO}; create.systemId=system;
        create.next=api12?static_cast<void*>(&b12):static_cast<void*>(&b11);
        XrSession value=XR_NULL_HANDLE;
        check(xr<PFN_xrCreateSession>("xrCreateSession")(gInstance,&create,&value)==XR_SUCCESS,"create real graphics session");
        XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO}; begin.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        check(xr<PFN_xrBeginSession>("xrBeginSession")(value,&begin)==XR_SUCCESS,"begin graphics session");
        return value;
    }
    void beginDraw() {
        if (api12) check(SUCCEEDED(allocator->Reset())&&SUCCEEDED(commands->Reset(allocator,nullptr)),"reset app command storage");
    }
    void clear(unsigned eye,ID3D11Texture2D* t11,ID3D12Resource* t12,unsigned slice,DXGI_FORMAT format,float gray) {
        const float color[]{gray,gray,gray,1};
        if (!api12) {
            D3D11_RENDER_TARGET_VIEW_DESC desc{}; desc.Format=format;
            desc.ViewDimension=D3D11_RTV_DIMENSION_TEXTURE2DARRAY; desc.Texture2DArray.ArraySize=1;
            desc.Texture2DArray.FirstArraySlice=slice;
            ID3D11RenderTargetView* target=nullptr;
            check(SUCCEEDED(d11->CreateRenderTargetView(t11,&desc,&target)),"D3D11 eye RTV");
            c11->ClearRenderTargetView(target,color); drop(target);
        } else {
            D3D12_CPU_DESCRIPTOR_HANDLE handle=descriptors->GetCPUDescriptorHandleForHeapStart();
            handle.ptr+=eye*d12->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
            D3D12_RENDER_TARGET_VIEW_DESC desc{}; desc.Format=format;
            desc.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2DARRAY; desc.Texture2DArray.ArraySize=1;
            desc.Texture2DArray.FirstArraySlice=slice;
            d12->CreateRenderTargetView(t12,&desc,handle); commands->ClearRenderTargetView(handle,color,0,nullptr);
        }
    }
    void execute() {
        if (api12) {
            check(SUCCEEDED(commands->Close()),"close app command list");
            ID3D12CommandList* lists[]{commands}; queue->ExecuteCommandLists(1,lists);
        }
    }
    void finish() {
        if (!api12) return;
        check(SUCCEEDED(queue->Signal(fence,++submitted)),"signal app completion");
        if (fence->GetCompletedValue()<submitted)
            check(SUCCEEDED(fence->SetEventOnCompletion(submitted,event))&&WaitForSingleObject(event,3000)==WAIT_OBJECT_0,"wait before app allocator reuse");
        check(SUCCEEDED(d12->GetDeviceRemovedReason()),"app D3D12 device remains healthy");
    }
    ~App() {
        if (event) CloseHandle(event);
        drop(fence); drop(descriptors); drop(commands); drop(allocator); drop(queue); drop(d12); drop(c11); drop(d11);
    }
};

struct Chain {
    XrSwapchain value=XR_NULL_HANDLE;
    DXGI_FORMAT format=DXGI_FORMAT_B8G8R8A8_UNORM;
    std::vector<XrSwapchainImageD3D11KHR> images11;
    std::vector<XrSwapchainImageD3D12KHR> images12;
    unsigned acquired=0;
    Chain(XrSession session,bool api12,unsigned w,unsigned h,DXGI_FORMAT fmt,unsigned slices):format(fmt) {
        XrSwapchainCreateInfo create{XR_TYPE_SWAPCHAIN_CREATE_INFO};
        create.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
        create.format=fmt; create.width=w+16; create.height=h+8;
        create.arraySize=slices; create.sampleCount=create.faceCount=create.mipCount=1;
        check(xr<PFN_xrCreateSwapchain>("xrCreateSwapchain")(session,&create,&value)==XR_SUCCESS,"create swapchain");
        uint32_t count=0; auto enumerate=xr<PFN_xrEnumerateSwapchainImages>("xrEnumerateSwapchainImages");
        check(enumerate(value,0,&count,nullptr)==XR_SUCCESS&&count==3,"enumerate image count");
        if (api12) {
            images12.resize(count,{XR_TYPE_SWAPCHAIN_IMAGE_D3D12_KHR});
            check(enumerate(value,count,&count,reinterpret_cast<XrSwapchainImageBaseHeader*>(images12.data()))==XR_SUCCESS,"enumerate D3D12 images");
        } else {
            images11.resize(count,{XR_TYPE_SWAPCHAIN_IMAGE_D3D11_KHR});
            check(enumerate(value,count,&count,reinterpret_cast<XrSwapchainImageBaseHeader*>(images11.data()))==XR_SUCCESS,"enumerate D3D11 images");
        }
    }
    void acquire() {
        XrSwapchainImageAcquireInfo a{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        check(xr<PFN_xrAcquireSwapchainImage>("xrAcquireSwapchainImage")(value,&a,&acquired)==XR_SUCCESS,"acquire image");
        XrSwapchainImageWaitInfo w{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; w.timeout=XR_INFINITE_DURATION;
        check(xr<PFN_xrWaitSwapchainImage>("xrWaitSwapchainImage")(value,&w)==XR_SUCCESS,"wait image");
    }
    void release() {
        XrSwapchainImageReleaseInfo r{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        check(xr<PFN_xrReleaseSwapchainImage>("xrReleaseSwapchainImage")(value,&r)==XR_SUCCESS,"release image");
    }
    ~Chain() { if (value) check(xr<PFN_xrDestroySwapchain>("xrDestroySwapchain")(value)==XR_SUCCESS,"destroy swapchain"); }
};

static unsigned sequence=0;
static double frame(App& app,Host& host,XrSession session,XrSpace stage,Chain& left,Chain* right,
                    unsigned width,unsigned height,bool metadata,bool mixed=false) {
    host.pose(++sequence);
    XrFrameState state{XR_TYPE_FRAME_STATE};
    check(xr<PFN_xrWaitFrame>("xrWaitFrame")(session,nullptr,&state)==XR_SUCCESS&&state.shouldRender,"wait renderable host frame");
    check(xr<PFN_xrBeginFrame>("xrBeginFrame")(session,nullptr)==XR_SUCCESS,"begin frame");
    XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO}; locate.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locate.space=stage; locate.displayTime=state.predictedDisplayTime;
    XrView views[2]{{XR_TYPE_VIEW},{XR_TYPE_VIEW}}; XrViewState validity{XR_TYPE_VIEW_STATE}; uint32_t count=0;
    check(xr<PFN_xrLocateViews>("xrLocateViews")(session,&locate,&validity,2,&count,views)==XR_SUCCESS&&count==2,"locate stereo views");
    left.acquire(); if (right) right->acquire(); app.beginDraw();
    for (unsigned eye=0;eye<2;++eye) {
        Chain& chain=(eye&&right)?*right:left;
        const float gray=mixed?.5f:((sequence&1)?.25f:.75f);
        app.clear(eye,app.api12?nullptr:chain.images11[chain.acquired].texture,
            app.api12?chain.images12[chain.acquired].texture:nullptr,right?0:eye,chain.format,gray);
    }
    app.execute(); left.release(); if (right) right->release();
    XrCompositionLayerProjectionView projected[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    for (unsigned eye=0;eye<2;++eye) {
        projected[eye].pose=views[eye].pose; projected[eye].fov=views[eye].fov;
        projected[eye].subImage.swapchain=(eye&&right)?right->value:left.value;
        projected[eye].subImage.imageArrayIndex=right?0:eye; projected[eye].subImage.imageRect={{8,4},{static_cast<int>(width),static_cast<int>(height)}};
    }
    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    projection.space=stage; projection.viewCount=2; projection.views=projected;
    const XrCompositionLayerBaseHeader* layers[]{reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection)};
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO}; end.displayTime=state.predictedDisplayTime;
    end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE; end.layerCount=1; end.layers=layers;
    const auto endFrame=xr<PFN_xrEndFrame>("xrEndFrame");
    const double before=clockMs();
    const XrResult result=endFrame(session,&end);
    const double elapsed=clockMs()-before;
    check(result==XR_SUCCESS,"handoff rendered frame");
    const unsigned slot=host.header->latest.load(); check(slot>0&&slot<=halliday::kSlots,"host received frame");
    const auto& received=host.header->frames[slot-1];
    check(received.width==width&&received.height==height&&closeFloat(received.pose.stamp,42.f+sequence),"current frame size and pose reach host");
    if (metadata) {
        const uint32_t expected=(app.api12?4u:0u)|(1u<<8)|((mixed?2u:1u)<<10);
        check(received.textureType==expected,"source format metadata stays correct for both eyes");
    }
    for (unsigned eye=0;eye<2;++eye) {
        const unsigned expected=mixed?(eye?188:128):((sequence&1)?64:191);
        const auto* pixels=reinterpret_cast<const uint8_t*>(host.header)+halliday::imageOffset(slot-1,eye);
        for (unsigned y:{0u,height/2,height-1}) for (unsigned x:{0u,width/2,width-1}) {
            const auto* pixel=pixels+(static_cast<size_t>(y)*width+x)*4;
            check(std::abs(int(pixel[0])-int(expected))<=1&&std::abs(int(pixel[1])-int(expected))<=1&&
                std::abs(int(pixel[2])-int(expected))<=1&&pixel[3]==255,"GPU midtone bytes survive transfer without CPU gamma conversion");
        }
    }
    app.finish(); return elapsed;
}

using StatsFn=uint32_t(__cdecl*)(HallidayTransferStats*,uint32_t);
static StatsFn gStats=nullptr;
static HallidayTransferStats stats() {
    HallidayTransferStats out{};
    if (gStats) check(gStats(&out,sizeof(out))==1&&out.version==1,"read exact transfer stats ABI");
    return out;
}
// Detailed live/allocation invariants are checked with the runtime's private counter export.
// A baseline without that export reports unavailable counters, never inferred measurements.
static void verifyPlateau(const HallidayTransferStats& before,const HallidayTransferStats& after,bool api12,unsigned frames) {
    check(after.sessionActive&&after.activeApi==(api12?12u:11u),"stats identify the active session API");
    check(after.frameTransfers-before.frameTransfers==frames&&after.failedTransfers==0,"all measured transfers completed");
    check(after.copyCommands-before.copyCommands==2*frames&&after.mapCalls-before.mapCalls==2*frames,"two actual eye copies/maps per stereo frame");
    check(after.stagingTextureCreates==before.stagingTextureCreates&&after.readbackBufferCreates==before.readbackBufferCreates&&
        after.allocatorCreates==before.allocatorCreates&&after.commandListCreates==before.commandListCreates&&
        after.fenceCreates==before.fenceCreates&&after.eventCreates==before.eventCreates,"runtime GPU allocations plateau after warmup");
    check(after.peakFramesInFlight==1,"synchronous transfer never adds another queued frame");
    if (api12) {
        check(after.queueSubmissions-before.queueSubmissions==frames&&after.fenceSignals-before.fenceSignals==frames&&
            after.fenceWaits-before.fenceWaits==frames,"both D3D12 eyes share one submission and one fence wait");
        check(after.liveReadbackBuffers==2&&after.liveCommandAllocators==1&&after.liveCommandLists==1&&
            after.liveFences==1&&after.liveEvents==1,"one persistent D3D12 pool has exactly its expected live resources");
    } else check(after.liveStagingTextures==2,"two persistent D3D11 staging textures");
}
static void verifyIdle(const HallidayTransferStats& current) {
    check(!current.sessionActive&&!current.liveStagingTextures&&!current.liveReadbackBuffers&&
        !current.liveCommandAllocators&&!current.liveCommandLists&&!current.liveFences&&!current.liveEvents,
        "session teardown releases every pooled GPU/OS resource");
}
static void printStats(const HallidayTransferStats& s) {
    if (!gStats) { std::printf("null"); return; }
    std::printf("{\"generation\":%llu,\"frameTransfers\":%llu,\"copyCommands\":%llu,\"queueSubmissions\":%llu,"
        "\"fenceWaits\":%llu,\"stagingTextureCreates\":%llu,\"readbackBufferCreates\":%llu,"
        "\"allocatorCreates\":%llu,\"commandListCreates\":%llu,\"fenceCreates\":%llu,\"eventCreates\":%llu,\"peakFramesInFlight\":%llu,"
        "\"sessionActive\":%u,\"liveStagingTextures\":%llu,\"liveReadbackBuffers\":%llu,\"liveCommandAllocators\":%llu,"
        "\"liveCommandLists\":%llu,\"liveFences\":%llu,\"liveEvents\":%llu}",
        static_cast<unsigned long long>(s.sessionGeneration),static_cast<unsigned long long>(s.frameTransfers),
        static_cast<unsigned long long>(s.copyCommands),static_cast<unsigned long long>(s.queueSubmissions),
        static_cast<unsigned long long>(s.fenceWaits),static_cast<unsigned long long>(s.stagingTextureCreates),
        static_cast<unsigned long long>(s.readbackBufferCreates),static_cast<unsigned long long>(s.allocatorCreates),
        static_cast<unsigned long long>(s.commandListCreates),static_cast<unsigned long long>(s.fenceCreates),
        static_cast<unsigned long long>(s.eventCreates),static_cast<unsigned long long>(s.peakFramesInFlight),s.sessionActive,
        static_cast<unsigned long long>(s.liveStagingTextures),static_cast<unsigned long long>(s.liveReadbackBuffers),
        static_cast<unsigned long long>(s.liveCommandAllocators),static_cast<unsigned long long>(s.liveCommandLists),
        static_cast<unsigned long long>(s.liveFences),static_cast<unsigned long long>(s.liveEvents));
}

static XrSpace makeStage(XrSession session) {
    XrReferenceSpaceCreateInfo info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    info.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_STAGE; info.poseInReferenceSpace.orientation.w=1;
    XrSpace stage=XR_NULL_HANDLE;
    check(xr<PFN_xrCreateReferenceSpace>("xrCreateReferenceSpace")(session,&info,&stage)==XR_SUCCESS,"create stage"); return stage;
}
static HallidayTransferStats measuredPhase(App& app,Host& host,XrSession session,XrSpace stage,unsigned width,unsigned height,bool verify,const char* phase) {
    constexpr unsigned warmup=12, measured=40;
    Chain chain(session,app.api12,width,height,DXGI_FORMAT_B8G8R8A8_UNORM,2);
    for (unsigned i=0;i<warmup;++i) frame(app,host,session,stage,chain,nullptr,width,height,verify);
    const auto before=stats(); std::vector<double> times;
    for (unsigned i=0;i<measured;++i) times.push_back(frame(app,host,session,stage,chain,nullptr,width,height,verify));
    const auto after=stats(); if (verify) verifyPlateau(before,after,app.api12,measured);
    const auto raw=times;
    const double mean=std::accumulate(times.begin(),times.end(),0.0)/times.size(); std::sort(times.begin(),times.end());
    const auto percentile=[&](double p) {
        const double index=(times.size()-1)*p; const size_t lo=static_cast<size_t>(index);
        return times[lo]+(times[std::min(lo+1,times.size()-1)]-times[lo])*(index-lo);
    };
    std::printf("RESULT {\"phase\":\"%s\",\"api\":%u,\"width\":%u,\"height\":%u,\"host_hz\":72,\"warmup\":%u,\"frames\":%u,"
        "\"xrEndFrame_mean_ms\":%.6f,\"xrEndFrame_p50_ms\":%.6f,\"xrEndFrame_p95_ms\":%.6f,\"stats\":",
        phase,app.api12?12:11,width,height,warmup,measured,mean,percentile(.5),percentile(.95));
    printStats(after); std::printf(",\"samples_ms\":[");
    for (size_t i=0;i<raw.size();++i) std::printf("%s%.6f",i?",":"",raw[i]);
    std::puts("]}"); std::fflush(stdout);
    return after;
}

int wmain(int argc,wchar_t** argv) {
    check(argc==5||argc==6,"usage: benchmark LOADER_DLL RUNTIME_DLL NEW_BRIDGE d3d11|d3d12 [--require-stats]");
    const bool api12=!std::wcscmp(argv[4],L"d3d12");
    check(api12||!std::wcscmp(argv[4],L"d3d11"),"choose one graphics API");
    const bool verify=argc==6&&!std::wcscmp(argv[5],L"--require-stats");
    Host host(argv[3]);
    HMODULE loader=LoadLibraryW(argv[1]); check(loader!=nullptr,"load actual Khronos loader");
    gGipa=reinterpret_cast<PFN_xrGetInstanceProcAddr>(GetProcAddress(loader,"xrGetInstanceProcAddr"));
    check(gGipa!=nullptr,"get actual loader dispatch");
    const char* extension=api12?XR_KHR_D3D12_ENABLE_EXTENSION_NAME:XR_KHR_D3D11_ENABLE_EXTENSION_NAME;
    XrInstanceCreateInfo create{XR_TYPE_INSTANCE_CREATE_INFO};
    std::strcpy(create.applicationInfo.applicationName,"Halliday paced transfer check");
    create.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0); create.enabledExtensionCount=1; create.enabledExtensionNames=&extension;
    check(xr<PFN_xrCreateInstance>("xrCreateInstance")(&create,&gInstance)==XR_SUCCESS,"create loader instance");
    HMODULE runtime=GetModuleHandleW(argv[2]); check(runtime!=nullptr,"the expected runtime was selected by the loader");
    gStats=reinterpret_cast<StatsFn>(GetProcAddress(runtime,"hallidayGetTransferStats"));
    check(!verify||gStats,"candidate must expose transfer counters");
    XrSystemGetInfo info{XR_TYPE_SYSTEM_GET_INFO}; info.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system=0; check(xr<PFN_xrGetSystem>("xrGetSystem")(gInstance,&info,&system)==XR_SUCCESS,"get live fixture system");
    App app(api12,system);
    printProvider(api12?L"d3d12.dll":L"d3d11.dll",api12?"d3d12.dll":"d3d11.dll");
    uint64_t generation=0;
    for (unsigned incarnation=0;incarnation<2;++incarnation) {
        const XrSession session=app.session(system); const XrSpace stage=makeStage(session);
        const auto fresh=stats();
        if (verify) { check(fresh.sessionGeneration>generation,"session recreation has a fresh counter generation"); generation=fresh.sessionGeneration; }
        const auto small=measuredPhase(app,host,session,stage,512,512,verify,incarnation?"recreated512":"initial512");
        if (!incarnation) {
            const auto large=measuredPhase(app,host,session,stage,1024,1024,verify,"grown1024");
            const auto shrunk=measuredPhase(app,host,session,stage,512,512,verify,"shrunk512");
            if (verify&&api12) {
                check(large.readbackBufferCreates==small.readbackBufferCreates+2&&shrunk.readbackBufferCreates==large.readbackBufferCreates,
                    "D3D12 buffer growth replaces two buffers and shrinking reuses capacity");
                check(shrunk.allocatorCreates==small.allocatorCreates&&shrunk.commandListCreates==small.commandListCreates&&
                    shrunk.fenceCreates==small.fenceCreates&&shrunk.eventCreates==small.eventCreates,"resizing keeps D3D12 control objects");
            }
            if (verify&&!api12) check(large.stagingTextureCreates==small.stagingTextureCreates+2&&
                shrunk.stagingTextureCreates==large.stagingTextureCreates+2,"D3D11 resize replaces only two typed staging textures");
        }
        if (verify) {
            Chain linear(session,api12,64,64,DXGI_FORMAT_B8G8R8A8_UNORM,1);
            Chain srgb(session,api12,64,64,DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,1);
            frame(app,host,session,stage,linear,&srgb,64,64,true,true);
        }
        check(xr<PFN_xrDestroySpace>("xrDestroySpace")(stage)==XR_SUCCESS,"destroy stage");
        check(xr<PFN_xrDestroySession>("xrDestroySession")(session)==XR_SUCCESS,"destroy session");
        check(!host.header->initialized.load(),"teardown releases fixture ownership"); if (verify) verifyIdle(stats());
        std::printf("TEARDOWN "); printStats(stats()); std::puts(""); std::fflush(stdout);
    }
    check(xr<PFN_xrDestroyInstance>("xrDestroyInstance")(gInstance)==XR_SUCCESS,"destroy instance");
    FreeLibrary(loader);
    std::puts(verify?"PASS: warmed transfer timings, resize/session recreation, GPU bytes, colour metadata and resource invariants (no headset; no encoding)":
        "PASS: warmed baseline transfer timings, resize/session recreation and GPU bytes; private counters unavailable (no headset; no encoding)");
    return 0;
}
