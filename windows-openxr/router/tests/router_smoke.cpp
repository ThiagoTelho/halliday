#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <openxr/openxr_loader_negotiation.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <iostream>
#include <cstring>
#include "../process_choice.hpp"

void check(bool ok, const char* message) { if(!ok) throw std::runtime_error(message); }
std::wstring path(const wchar_t* folder,const wchar_t* name) {return std::wstring(folder)+L"\\"+name;}
void write(const std::wstring& path,const std::string& text) {
    auto file=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    check(file!=INVALID_HANDLE_VALUE,"open test policy"); DWORD count=0;
    bool ok=WriteFile(file,text.data(),static_cast<DWORD>(text.size()),&count,nullptr);CloseHandle(file);
    check(ok&&count==text.size(),"write test policy");
}
uint64_t nowMs(){FILETIME t;GetSystemTimeAsFileTime(&t);ULARGE_INTEGER v;v.LowPart=t.dwLowDateTime;v.HighPart=t.dwHighDateTime;return(v.QuadPart-116444736000000000ULL)/10000;}
void policy(const std::wstring& file,const std::wstring& mode) {
    if(mode==L"missing"){DeleteFileW(file.c_str());return;}
    if(mode==L"malformed"){write(file,"{broken");return;}
    if(mode==L"duplicate"){write(file,"{\"version\":1,\"version\":1}");return;}
    if(mode==L"oversize"){write(file,std::string(4097,' '));return;}
    auto time=nowMs();if(mode==L"stale")time-=60000;if(mode==L"future")time+=60000;
    bool ready=mode!=L"notready",worn=mode!=L"unworn"&&mode!=L"no-external",external=mode!=L"no-external";
    write(file,"{\"version\":1,\"updated_unix_ms\":"+std::to_string(time)+",\"halliday_ready\":"+(ready?"true":"false")+",\"psvr2_worn\":"+(worn?"true":"false")+",\"external_active\":"+(external?"true":"false")+"}");
}
int wmain(int argc,wchar_t** argv) {
 try {
    if(argc==2&&std::wstring(argv[1])==L"--child-choice"){check(!halliday::router::pinProcessChoice(false),"child inherited parent choice");std::cout<<"PASS: fresh child process choice\n";return 0;}
    check(argc==5,"usage: router-smoke folder policy-mode expected failure-mode");
    const auto routerPath=path(argv[1],L"halliday_openxr_router.dll"),policyPath=path(argv[1],L"policy.json");
    const std::wstring mode=argv[2],failure=argv[4];const int expected=_wtoi(argv[3]);
    policy(policyPath,mode);
    if(failure==L"negotiate")SetEnvironmentVariableW(L"HALLIDAY_FAKE_NEGOTIATE_FAIL",L"1");
    if(failure==L"prepin-halliday")check(halliday::router::pinProcessChoice(true),"reserve Halliday from other router");
    if(failure==L"prepin-external")check(!halliday::router::pinProcessChoice(false),"reserve external from other router");
    auto module=LoadLibraryW(routerPath.c_str());check(module!=nullptr,"load router");
    auto negotiate=reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(GetProcAddress(module,"xrNegotiateLoaderRuntimeInterface"));check(negotiate!=nullptr,"router export");
    check(negotiate(nullptr,nullptr)==XR_ERROR_INITIALIZATION_FAILED,"null negotiation");
    XrNegotiateLoaderInfo loader{XR_LOADER_INTERFACE_STRUCT_LOADER_INFO,1,sizeof(loader),1,1,XR_MAKE_VERSION(1,0,0),XR_MAKE_VERSION(1,1,999)};
    XrNegotiateRuntimeRequest request{XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST,1,sizeof(request),0,0,nullptr};
    if(failure==L"concurrent"){
      struct Thread {PFN_xrNegotiateLoaderRuntimeInterface call;const XrNegotiateLoaderInfo* loader;HANDLE gate;XrNegotiateRuntimeRequest result;XrResult status;};
      HANDLE gate=CreateEventW(nullptr,TRUE,FALSE,nullptr);check(gate!=nullptr,"thread gate");
      Thread values[8];HANDLE threads[8];
      for(int i=0;i<8;++i){values[i]={negotiate,&loader,gate,request,XR_ERROR_RUNTIME_FAILURE};
        threads[i]=CreateThread(nullptr,0,[](void* data)->DWORD{auto& t=*static_cast<Thread*>(data);WaitForSingleObject(t.gate,INFINITE);t.status=t.call(t.loader,&t.result);return 0;},&values[i],0,nullptr);check(threads[i]!=nullptr,"create concurrent caller");}
      SetEvent(gate);check(WaitForMultipleObjects(8,threads,TRUE,10000)==WAIT_OBJECT_0,"concurrent negotiation completion");
      for(int i=0;i<8;++i){CloseHandle(threads[i]);check(values[i].status==XR_SUCCESS&&XR_VERSION_MINOR(values[i].result.runtimeApiVersion)==(expected==1?1:0),"concurrent backend selection mismatch");}CloseHandle(gate);
    }
    auto result=negotiate(&loader,&request);
    auto h=GetModuleHandleW(L"fake_halliday.dll"),m=GetModuleHandleW(L"fake_external.dll");
    if(failure==L"selection"){
       check(result==XR_ERROR_INITIALIZATION_FAILED,"selected target failure must fail");
       check(!(h&&m),"both backends loaded after selection failure");
       check(!m,"failed Halliday selection fell back to external");
       policy(policyPath,L"unworn");check(negotiate(&loader,&request)==result,"selection error was not pinned");
       std::cout<<"PASS: selected failure does not load fallback and remains process-pinned\n";return 0;
    }
    check(expected==1?(h&&!m):(m&&!h),"exactly selected backend must be loaded");
    auto selected=expected==1?h:m;
    if(failure==L"negotiate"){
       check(result==XR_ERROR_RUNTIME_UNAVAILABLE,"backend negotiation error changed");
       policy(policyPath,expected==1?L"unworn":L"fresh");
       SetEnvironmentVariableW(L"HALLIDAY_FAKE_NEGOTIATE_FAIL",nullptr);
       result=negotiate(&loader,&request);
    }
    check(result==XR_SUCCESS,"forward negotiation");
    auto pointers=reinterpret_cast<bool(__cdecl*)(const XrNegotiateLoaderInfo*,XrNegotiateRuntimeRequest*)>(GetProcAddress(selected,"fakePointersMatch"));
    check(pointers&&pointers(&loader,&request),"negotiation structures changed");
    auto expectedGipaAddress=GetProcAddress(selected,"fakeGetInstanceProcAddr");
    PFN_xrGetInstanceProcAddr expectedGipa=nullptr;
    static_assert(sizeof(expectedGipa)==sizeof(expectedGipaAddress));
    std::memcpy(&expectedGipa,&expectedGipaAddress,sizeof(expectedGipa));
    check(request.getInstanceProcAddr==expectedGipa,"backend GIPA was wrapped");
    check(XR_VERSION_MINOR(request.runtimeApiVersion)==(expected==1?1:0),"negotiated API changed");
    auto alias=reinterpret_cast<unsigned(__cdecl*)()>(GetProcAddress(selected,"fakeAliasCalls"));
    if(failure==L"alias")check(alias&&alias()==1,"manifest negotiation remap ignored");
    PFN_xrVoidFunction raw=nullptr;check(request.getInstanceProcAddr(XR_NULL_HANDLE,"xrCreateInstance",&raw)==XR_SUCCESS,"get backend create");
    auto create=reinterpret_cast<PFN_xrCreateInstance>(raw);XrInstance instance=XR_NULL_HANDLE;
    if(failure==L"create"){
      SetEnvironmentVariableW(L"HALLIDAY_FAKE_CREATE_FAIL",L"1");check(create(nullptr,&instance)==XR_ERROR_RUNTIME_FAILURE,"backend create failure changed");
      SetEnvironmentVariableW(L"HALLIDAY_FAKE_CREATE_FAIL",nullptr);
    }
    check(create(nullptr,&instance)==XR_SUCCESS&&reinterpret_cast<uintptr_t>(instance)==static_cast<uintptr_t>(expected),"selected create path changed");
    // Even policy changes and caller unload/reload cannot move this process to the other runtime.
    policy(policyPath,expected==1?L"unworn":L"fresh");
    FreeLibrary(module);module=LoadLibraryW(routerPath.c_str());check(module!=nullptr,"reload pinned router");
    negotiate=reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(GetProcAddress(module,"xrNegotiateLoaderRuntimeInterface"));
    request.runtimeApiVersion=0;check(negotiate(&loader,&request)==XR_SUCCESS,"repeat negotiation");
    check(XR_VERSION_MINOR(request.runtimeApiVersion)==(expected==1?1:0),"policy change switched pinned runtime");
    check(!(GetModuleHandleW(L"fake_halliday.dll")&&GetModuleHandleW(L"fake_external.dll")),"second runtime loaded later");
    if(failure==L"child"){
      wchar_t own[32768];check(GetModuleFileNameW(nullptr,own,32768)>0,"own EXE path");
      std::wstring command=L"\""+std::wstring(own)+L"\" --child-choice";
      STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION process{};
      check(CreateProcessW(own,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process),"start child choice check");
      auto status=WaitForSingleObject(process.hProcess,10000);DWORD code=999;GetExitCodeProcess(process.hProcess,&code);CloseHandle(process.hThread);CloseHandle(process.hProcess);
      check(status==WAIT_OBJECT_0&&code==0,"child inherited parent pinned backend");
    }
    std::cout<<"PASS: backend="<<expected<<" exact negotiation/GIPA/create, policy and module lifetime pinning\n";
 }catch(const std::exception&e){std::cerr<<"FAIL: "<<e.what()<<" Win32="<<GetLastError()<<'\n';return 1;}
}
