// Portable CPU-only identity policy; no process, graphics or user state touched.
#include "helper_game_identity_policy.hpp"
#include <cstdio>
#include <cstdlib>
#include <array>
namespace h=halliday::helper_identity;
static void require(bool value,const char* message) {if(!value){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}}
int main() {
    h::Evidence valid{17,29,29,2'000,1'000,1,1,true,true};
    for(const auto child:{"OpenXRHelper32.exe","openxrhelper64.EXE","Z:\\game\\OpenXRHelper64.exe"})
        require(h::verified(child,"bms.exe",valid),"exact helper may expose proven live parent game name");
    for(const auto child:{"bms.exe","eurotrucks2.exe","re8.exe","OpenXRHelper64.exe.old","OtherHelper.exe",""})
        require(!h::verified(child,"bms.exe",valid),"ordinary/nonmatching executables retain own name");
    for(const auto name:{"steam.exe","SteamWebHelper.exe","vrhelper.exe","OpenXRHelper32.exe","OpenXRHelper64.exe",
            "game-launcher.exe","RockstarLauncher.exe","EADesktop.exe","UbisoftConnect.exe","GalaxyClient.exe",
            "services.exe","cmd.exe","powershell.exe","conhost.exe","wineboot.exe","winedevice.exe","start.exe",
            "Z:\\game\\bms.exe","../bms.exe","bms","bms.dll",".exe",""})
        require(!h::verified("OpenXRHelper64.exe",name,valid),"launcher/helper/path/invalid parent never substitutes for game");
    for(const auto name:{"bms.exe","BMS.EXE","eurotrucks2.exe","re8.exe","Game With Spaces.exe"})
        require(h::verified("OpenXRHelper64.exe",name,valid),"unlisted actual games are supported without per-game allowlist");
    require(!h::eligible_parent(std::string(64,'x')+".exe"),"overlong identity cannot be truncated into another executable name");
    require(!h::eligible_parent(std::string("bad\0.exe",8))&&!h::eligible_parent("bad\n.exe"),"control/NUL data rejected");
    for(unsigned change=0;change<11;++change) {
        auto bad=valid;
        switch(change) {case 0:bad.childPid=0;break;case 1:bad.parentPid=0;break;
            case 2:bad.parentPid=bad.childPid;bad.confirmedParentPid=bad.childPid;break;
            case 3:++bad.confirmedParentPid;break;case 4:bad.childCreated=0;break;case 5:bad.parentCreated=0;break;
            case 6:bad.parentCreated=bad.childCreated+1;break;case 7:bad.parentCreated=bad.childCreated;break;
            case 8:++bad.parentSession;break;case 9:bad.complete=false;break;case 10:bad.parentAlive=false;break;}
        require(!h::verified("OpenXRHelper64.exe","bms.exe",bad),"missing, stale/reused, ambiguous or dead process identity fails closed");
    }
    require(h::basename("Z:\\Steam Library\\bms.exe")=="bms.exe"&&h::basename("/game/bms.exe")=="bms.exe","bounded queried path resolves only its final component");
    std::puts("PASS: helper parent metadata policy; ordinary apps unchanged, generic games, launcher/helper rejection, PID/creation/session/live guards");
}
