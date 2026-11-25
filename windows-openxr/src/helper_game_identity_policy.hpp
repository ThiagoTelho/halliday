// A helper's proven parent may name the game; its PID/epoch still own the runtime.
#pragma once
#include <cstdint>
#include <initializer_list>
#include <string>
#include <string_view>

namespace halliday::helper_identity {
inline std::string_view basename(std::string_view path) {
    const auto at=path.find_last_of("\\/");return at==std::string_view::npos?path:path.substr(at+1);
}
inline std::string lower(std::string_view text) {
    std::string value(text);
    for(char& c:value)if(c>='A'&&c<='Z')c=char(c-'A'+'a');return value;
}
inline bool helper(std::string_view name) {
    const auto value=lower(basename(name));return value=="openxrhelper32.exe"||value=="openxrhelper64.exe";
}
inline bool eligible_parent(std::string_view name) {
    if(name.empty()||name.size()>63||basename(name)!=name)return false;
    for(unsigned char c:name)if(c<32||c==127)return false;
    const auto value=lower(name);
    if(value.size()<5||value.substr(value.size()-4)!=".exe"||value.find("helper")!=std::string::npos||
       value.find("steam")!=std::string::npos||value.find("launcher")!=std::string::npos)return false;
    for(const auto denied:{"services.exe","svchost.exe","explorer.exe","wineboot.exe","winedevice.exe",
            "winemenubuilder.exe","start.exe","rundll32.exe","cmd.exe","powershell.exe","pwsh.exe",
            "conhost.exe","werfault.exe","crossover.exe","cxrun.exe","cxstart.exe","galaxyclient.exe",
            "eadesktop.exe","ubisoftconnect.exe","uplay.exe","battle.net.exe"})if(value==denied)return false;
    return true;
}
struct Evidence {
    uint32_t childPid=0,parentPid=0,confirmedParentPid=0;
    uint64_t childCreated=0,parentCreated=0;
    uint32_t childSession=0,parentSession=0;
    bool complete=false,parentAlive=false;
};
inline bool verified(std::string_view child,std::string_view parent,const Evidence& e) {
    return helper(child)&&eligible_parent(parent)&&e.complete&&e.parentAlive&&e.childPid&&e.parentPid&&
        e.parentPid!=e.childPid&&e.parentPid==e.confirmedParentPid&&e.childCreated&&e.parentCreated&&
        e.parentCreated<e.childCreated&&e.childSession==e.parentSession;
}
} // namespace halliday::helper_identity
