#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <cwchar>
#include <cstdint>
#include <initializer_list>
#include <openxr/openxr_loader_negotiation.h>
#include "../router_config.hpp"
struct Core {
    virtual int Init(int, const char*) = 0;
    virtual void Cleanup() = 0;
    virtual int IsInterfaceVersionValid(const char*) = 0;
    virtual void* GetGenericInterface(const char*, int*) = 0;
    virtual bool BIsHmdPresent() = 0;
    virtual const char* GetEnglishStringForHmdError(int) = 0;
    virtual const char* GetIDForVRInitError(int) = 0;
};
using Factory = void* (__cdecl*)(const char*, int*);
namespace {
HANDLE completed=nullptr;
DWORD WINAPI watchdog(void*) {
    if(WaitForSingleObject(completed,10000)!=WAIT_OBJECT_0){
        std::fprintf(stderr,"FAIL bounded router smoke timed out\n");std::fflush(stderr);
        TerminateProcess(GetCurrentProcess(),124);
    }
    return 0;
}
struct Deadline {
    HANDLE thread;
    Deadline(){completed=CreateEventW(nullptr,TRUE,FALSE,nullptr);thread=CreateThread(nullptr,0,watchdog,nullptr,0,nullptr);}
    ~Deadline(){SetEvent(completed);WaitForSingleObject(thread,1000);CloseHandle(thread);CloseHandle(completed);}
};
void check(bool value, const char* message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s (%lu)\n", message, GetLastError()); ExitProcess(1); }
}
void flipPolicy(const wchar_t* path, bool halliday) {
    FILETIME t{}; GetSystemTimeAsFileTime(&t);
    ULARGE_INTEGER ticks{}; ticks.LowPart=t.dwLowDateTime; ticks.HighPart=t.dwHighDateTime;
    auto now=(ticks.QuadPart-116444736000000000ULL)/10000;
    std::string bytes="{\"version\":1,\"updated_unix_ms\":"+std::to_string(now)+
        ",\"halliday_ready\":true,\"psvr2_worn\":"+(halliday?"true":"false")+",\"external_active\":true}";
    HANDLE file=CreateFileW(path,GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    check(file!=INVALID_HANDLE_VALUE,"write changed fixture policy"); DWORD written=0;
    check(WriteFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)&&written==bytes.size(),"write complete policy");
    CloseHandle(file);
}
void refreshOwnedPolicy(const wchar_t* path) {
    wchar_t offset[40]{};
    if(!GetEnvironmentVariableW(L"HALLIDAY_FAKE_POLICY_OFFSET_MS",offset,40))return;
    HANDLE file=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
    check(file!=INVALID_HANDLE_VALUE,"read owned policy before fresh test");
    char buffer[4096];DWORD got=0;check(ReadFile(file,buffer,sizeof(buffer),&got,nullptr),"read complete fixture policy");CloseHandle(file);
    auto j=halliday::router::parseJson(std::string(buffer,got));
    FILETIME t{};GetSystemTimeAsFileTime(&t);ULARGE_INTEGER ticks{};ticks.LowPart=t.dwLowDateTime;ticks.HighPart=t.dwHighDateTime;
    auto now=static_cast<int64_t>((ticks.QuadPart-116444736000000000ULL)/10000);
    j["updated_unix_ms"]=static_cast<uint64_t>(now+std::wcstoll(offset,nullptr,10));
    auto bytes=j.dump();file=CreateFileW(path,GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    check(file!=INVALID_HANDLE_VALUE,"refresh fixture policy");DWORD written=0;
    check(WriteFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)&&written==bytes.size(),"refresh complete fixture policy");CloseHandle(file);
}
void checkXR(const wchar_t* path,int expected) {
    HMODULE library=LoadLibraryExW(path,nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    check(library!=nullptr,"load independently staged XR router");
    auto negotiate=reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(GetProcAddress(library,"xrNegotiateLoaderRuntimeInterface"));
    check(negotiate!=nullptr,"XR negotiation export");
    XrNegotiateLoaderInfo loader{};loader.structType=XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
    loader.structVersion=XR_LOADER_INFO_STRUCT_VERSION;loader.structSize=sizeof(loader);
    loader.minInterfaceVersion=1;loader.maxInterfaceVersion=XR_CURRENT_LOADER_RUNTIME_VERSION;
    loader.minApiVersion=XR_MAKE_VERSION(1,0,0);loader.maxApiVersion=XR_MAKE_VERSION(1,1,0);
    XrNegotiateRuntimeRequest request{};request.structType=XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
    request.structVersion=XR_RUNTIME_INFO_STRUCT_VERSION;request.structSize=sizeof(request);
    check(negotiate(&loader,&request)==XR_SUCCESS,"cross-API XR negotiation");
    check(XR_VERSION_PATCH(request.runtimeApiVersion)==static_cast<unsigned>(expected==1?77:31),
        "OpenXR and OpenVR must use the same process-pinned backend despite changed policy");
    FreeLibrary(library);
}
}
int wmain(int argc,wchar_t** argv) {
    check(argc==5||argc==6,"usage: openvr-router-smoke ROUTER POLICY expectedBackend(0|1|2) mode(normal|negative|actual|xrfirst) [XRROUTER]");
    Deadline deadline;
    const int expected=static_cast<int>(std::wcstol(argv[3],nullptr,10));
    const bool actual=!std::wcscmp(argv[4],L"actual");
    const bool negative=actual||!std::wcscmp(argv[4],L"negative");
    refreshOwnedPolicy(argv[2]);
    if(argc==6&&!std::wcscmp(argv[4],L"xrfirst")){checkXR(argv[5],expected);flipPolicy(argv[2],expected!=1);}
    if(actual){
        for(HKEY root:{HKEY_LOCAL_MACHINE,HKEY_CURRENT_USER})for(DWORD view:{RRF_SUBKEY_WOW6464KEY,RRF_SUBKEY_WOW6432KEY}){
            DWORD bytes=0;auto status=RegGetValueW(root,L"SOFTWARE\\Khronos\\OpenXR\\1",L"ActiveRuntime",RRF_RT_ANY|view,nullptr,nullptr,&bytes);
            check(status==ERROR_FILE_NOT_FOUND||status==ERROR_PATH_NOT_FOUND,"actual OC negative probe needs absent runtime registration");
        }
        std::wstring absent=std::wstring(argv[2])+L".absent-runtime.json";
        check(GetFileAttributesW(absent.c_str())==INVALID_FILE_ATTRIBUTES,"negative runtime manifest must be absent");
        check(SetEnvironmentVariableW(L"XR_RUNTIME_JSON",absent.c_str()),"isolate environment fallback");
        SetEnvironmentVariableW(L"XR_RUNTIME_JSON_64",absent.c_str());
        SetEnvironmentVariableW(L"XR_ENABLE_API_LAYERS",nullptr);
    }
    HMODULE library=LoadLibraryExW(argv[1],nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    check(library!=nullptr,"load staged OpenVR router");
    auto factory=reinterpret_cast<Factory>(GetProcAddress(library,"VRClientCoreFactory"));
    check(factory!=nullptr,"router factory export"); int error=-1;
    check(factory("IVRClientCore_002",&error)==nullptr&&error==105,"unsupported version fails without backend selection");
    auto* core=static_cast<Core*>(factory("IVRClientCore_003",&error));
    if(expected==0){check(core==nullptr&&error!=0,"invalid config/backend explicitly fails");std::puts("PASS OpenVR expected rejection");return 0;}
    check(core&&error==0,"factory003 returns selected clientcore");
    error=core->Init(1,nullptr);check(negative?error!=0:error==0,"initialization error propagated unchanged");
    const char* english=core->GetEnglishStringForHmdError(error);
    const char* symbol=core->GetIDForVRInitError(error);
    check(english&&*english&&symbol&&*symbol,"both error slots return safe nonempty text");
    if(negative) {
        check(std::strstr(core->GetEnglishStringForHmdError(9001),"9001")!=nullptr,"compatibility error preserves numeric code");
        check(std::strstr(core->GetIDForVRInitError(9001),"9001")!=nullptr,"compatibility symbol preserves numeric code");
    } else {
        check(!std::strcmp(english,"fake backend English")&&!std::strcmp(symbol,"FakeBackendSymbol"),"ordinary provider error strings forwarded unchanged");
    }
    if(!actual){
        check(core->IsInterfaceVersionValid("test")==0,"interface validation forwarded");
        int generic=-1;auto value=core->GetGenericInterface("test",&generic);
        check(reinterpret_cast<uintptr_t>(value)==static_cast<uintptr_t>(expected)&&generic==0,"generic interface forwards exact chosen backend");
        check(core->BIsHmdPresent()==(expected==1),"presence forwarded");
    }
    core->Cleanup();
    flipPolicy(argv[2],expected!=1);
    if(argc==6)checkXR(argv[5],expected);
    FreeLibrary(library);
    library=LoadLibraryExW(argv[1],nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    check(library!=nullptr,"reload pinned router");
    factory=reinterpret_cast<Factory>(GetProcAddress(library,"VRClientCoreFactory"));
    check(factory("IVRClientCore_003",&error)==core&&error==0,"cleanup/policy flip/unload/reload do not switch backend");
    std::printf("PASS OpenVR backend%d %s; stable process pin; safe error paths\n",expected,
        actual ? "actual OC negative Init/Cleanup and safe error descriptions" : "all7 fake methods");
    return 0;
}
