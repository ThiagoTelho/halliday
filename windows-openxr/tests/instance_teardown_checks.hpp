#pragma once
// Deterministic public-API race oracle. Only the test's own runtime DLL import
// is redirected; no Wine, driver or installed application code is modified.
#include <windows.h>
#include <openxr/openxr.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace instance_teardown_checks {
inline void check(bool value, const char* reason) {
    if (!value) { std::fprintf(stderr,"INSTANCE FAIL: %s\n",reason); std::exit(1); }
}
using Wait = DWORD (WINAPI*)(HANDLE,DWORD);
inline Wait realWait = nullptr;
inline HANDLE entered = nullptr, releaseJoin = nullptr;
inline std::atomic<DWORD> destroyingThread{0};
inline DWORD WINAPI gatedWait(HANDLE handle,DWORD milliseconds) {
    if (milliseconds==INFINITE && GetCurrentThreadId()==destroyingThread.load()) {
        destroyingThread.store(0);
        SetEvent(entered);
        realWait(releaseJoin,5000);
    }
    return realWait(handle,milliseconds);
}
struct ImportPatch {
    ULONG_PTR* slot = nullptr;
    ULONG_PTR previous = 0;
    explicit ImportPatch(HMODULE module) {
        auto* base=reinterpret_cast<BYTE*>(module);
        const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        check(dos->e_magic==IMAGE_DOS_SIGNATURE,"runtime DOS header");
        const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
        check(nt->Signature==IMAGE_NT_SIGNATURE,"runtime NT header");
        const auto directory=nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
        check(directory.VirtualAddress && directory.Size,"runtime import directory");
        auto* descriptor=reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base+directory.VirtualAddress);
        for (; descriptor->Name && !slot; ++descriptor) {
            if (!descriptor->OriginalFirstThunk) continue;
            auto* name=reinterpret_cast<IMAGE_THUNK_DATA64*>(base+descriptor->OriginalFirstThunk);
            auto* address=reinterpret_cast<IMAGE_THUNK_DATA64*>(base+descriptor->FirstThunk);
            for (; name->u1.AddressOfData; ++name,++address) {
                if (IMAGE_SNAP_BY_ORDINAL64(name->u1.Ordinal)) continue;
                const auto* symbol=reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base+name->u1.AddressOfData);
                if (!std::strcmp(reinterpret_cast<const char*>(symbol->Name),"WaitForSingleObject")) {
                    slot=&address->u1.Function; break;
                }
            }
        }
        check(slot!=nullptr,"own runtime imports its heartbeat join");
        previous=*slot; realWait=reinterpret_cast<Wait>(previous);
        write(reinterpret_cast<ULONG_PTR>(gatedWait));
    }
    void write(ULONG_PTR value) {
        DWORD protection=0,ignored=0;
        check(VirtualProtect(slot,sizeof(*slot),PAGE_READWRITE,&protection),"unprotect own test import");
        InterlockedExchangePointer(reinterpret_cast<void* volatile*>(slot),reinterpret_cast<void*>(value));
        check(VirtualProtect(slot,sizeof(*slot),protection,&ignored),"restore own import protection");
    }
    ~ImportPatch() { if (slot) write(previous); }
};
template<typename T> T function(PFN_xrGetInstanceProcAddr get,XrInstance instance,const char* name) {
    PFN_xrVoidFunction out=nullptr;
    check(get(instance,name,&out)==XR_SUCCESS && out,name);
    return reinterpret_cast<T>(out);
}
inline void run(HMODULE runtime,PFN_xrGetInstanceProcAddr get,XrInstance instance,
                const XrSessionCreateInfo& sessionInfo) {
    const auto createSession=function<PFN_xrCreateSession>(get,instance,"xrCreateSession");
    const auto destroy=function<PFN_xrDestroyInstance>(get,instance,"xrDestroyInstance");
    const auto create=function<PFN_xrCreateInstance>(get,instance,"xrCreateInstance");
    XrSession session=XR_NULL_HANDLE;
    check(createSession(instance,&sessionInfo,&session)==XR_SUCCESS,"create session with its real heartbeat worker");
    entered=CreateEventW(nullptr,TRUE,FALSE,nullptr); releaseJoin=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    check(entered && releaseJoin,"test synchronization events");
    struct Request { PFN_xrDestroyInstance destroy; XrInstance instance; XrResult result=XR_ERROR_RUNTIME_FAILURE; } request{destroy,instance};
    XrResult blockedResult=XR_ERROR_RUNTIME_FAILURE; XrInstance duplicate=XR_NULL_HANDLE;
    {
        ImportPatch patch(runtime);
        HANDLE thread=CreateThread(nullptr,0,[](void* data)->DWORD {
            auto& request=*static_cast<Request*>(data);
            destroyingThread.store(GetCurrentThreadId());
            request.result=request.destroy(request.instance);
            return 0;
        },&request,0,nullptr);
        check(thread!=nullptr,"start actual instance teardown");
        const bool parked=WaitForSingleObject(entered,3000)==WAIT_OBJECT_0;
        XrInstanceCreateInfo info{XR_TYPE_INSTANCE_CREATE_INFO};
        std::strcpy(info.applicationInfo.applicationName,"Halliday instance teardown race");
        info.applicationInfo.apiVersion=XR_MAKE_VERSION(1,0,0);
        if (parked) blockedResult=create(&info,&duplicate);
        SetEvent(releaseJoin);
        const DWORD stopped=WaitForSingleObject(thread,5000); CloseHandle(thread);
        check(parked && stopped==WAIT_OBJECT_0,"teardown parked at actual heartbeat join then completed");
        if (duplicate) destroy(duplicate);
        check(request.result==XR_SUCCESS,"original instance cleanup completed");
        check(blockedResult==XR_ERROR_LIMIT_REACHED && !duplicate,
              "new instance cannot enter process-global state during old cleanup");
        XrInstance replacement=XR_NULL_HANDLE;
        check(create(&info,&replacement)==XR_SUCCESS && replacement!=instance,"fresh instance after completed cleanup");
        XrInstanceProperties properties{XR_TYPE_INSTANCE_PROPERTIES};
        check(function<PFN_xrGetInstanceProperties>(get,replacement,"xrGetInstanceProperties")(replacement,&properties)==XR_SUCCESS,
              "old cleanup cannot invalidate replacement resources");
        check(destroy(replacement)==XR_SUCCESS,"destroy replacement instance");
    }
    CloseHandle(entered);CloseHandle(releaseJoin);entered=releaseJoin=nullptr;
    std::puts("INSTANCE PASS: concurrent creation blocked until real heartbeat/session teardown completes; fresh instance recovers");
}
}
