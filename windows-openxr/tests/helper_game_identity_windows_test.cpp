// Explicit owned-process CPU fixture. No graphics/runtime/HID or registry use.
#include "helper_game_identity.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace h=halliday::helper_identity;
static void require(bool value,const char* message) {if(!value){std::fprintf(stderr,"FAIL: %s (Win32%lu)\n",message,GetLastError());std::exit(1);}}
static std::string executable() {
    char path[32768]{};const auto count=GetModuleFileNameA(nullptr,path,sizeof(path));
    require(count&&count<sizeof(path),"complete actual executable identity");return std::string(h::basename({path,count}));
}
int main(int argc,char** argv) {
    if(argc==3&&!std::strcmp(argv[1],"--expect")) {
        const auto self=executable();const auto parent=h::verified_parent_name(self);
        const auto actual=parent?*parent:self;
        require(actual==argv[2],"real Win32 helper-parent attribution exactly matches owned parent or safe self fallback");
        std::printf("PASS: child %s -> %s, runtime owner PID remains%lu\n",self.c_str(),actual.c_str(),GetCurrentProcessId());return 0;
    }
    const bool runtime=argc==6&&!std::strcmp(argv[1],"--launch-owned-runtime");
    if(!runtime&&(argc!=4||std::strcmp(argv[1],"--launch-owned-helper"))) {
        std::puts("Compile-only by default. Explicit --launch-owned-helper OWNED_CHILD EXPECTED_NAME runs one bounded CPU child.");return 0;
    }
    const std::string child=argv[2];const auto normalized=h::lower(child);
    require(normalized.find("\\windows-openxr\\build\\tests\\helper-identity-")!=std::string::npos&&
            child.find("..") == std::string::npos&&child.find('"')==std::string::npos,"new owned fixture child path required");
    const std::string expected=argv[runtime?5:3];require(expected==h::basename(expected)&&expected.find('"')==std::string::npos,"bounded expected basename");
    // Distinct creation times are a deliberate guard: a coarse equal timestamp
    // cannot establish that an old parent PID was not already reused.
    Sleep(30);
    std::string command="\""+child+"\" --expect \""+expected+"\"";
    if(runtime) {
        for(unsigned arg=3;arg<5;++arg)require(std::string(argv[arg]).find('"')==std::string::npos&&
            h::lower(argv[arg]).find("\\windows-openxr\\build\\tests\\helper-identity-")!=std::string::npos,
            "runtime and bridge must also be owned fixture paths");
        command="\""+child+"\" \""+argv[3]+"\" \""+argv[4]+"\"";
        SetEnvironmentVariableA("HALLIDAY_EXPECT_CLIENT_NAME",expected.c_str());
        SetEnvironmentVariableA("HALLIDAY_CHECK_PRIOR_STAGING_ONLY","1");
    }
    STARTUPINFOA start{};start.cb=sizeof(start);PROCESS_INFORMATION info{};
    require(CreateProcessA(child.c_str(),command.data(),nullptr,nullptr,TRUE,0,nullptr,nullptr,&start,&info),"create only explicit owned test child");
    h::Handle process(info.hProcess),thread(info.hThread);
    const auto waited=WaitForSingleObject(process.get(),runtime?30'000:10'000);
    if(waited!=WAIT_OBJECT_0){TerminateProcess(process.get(),2);WaitForSingleObject(process.get(),2'000);}
    require(waited==WAIT_OBJECT_0,"owned CPU child exits within bound");
    DWORD status=1;require(GetExitCodeProcess(process.get(),&status)&&status==0,"owned child policy check passed");
    std::printf("PASS: actual parent %s validated with helper identity; no global fallback\n",executable().c_str());return 0;
}
