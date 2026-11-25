// One selection across independently loaded OpenXR and OpenVR router modules.
#pragma once
#ifndef _WIN32
#error process_choice.hpp requires Windows
#endif
#include <windows.h>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace halliday::router {
namespace choice_detail {
struct Shared { uint32_t magic, version, backend, reserved; };
static_assert(sizeof(Shared)==16);
struct State { HANDLE mutex=nullptr, mapping=nullptr; Shared* shared=nullptr; };
inline State* createState() {
    FILETIME created{},ended{},kernel{},user{};
    if (!GetProcessTimes(GetCurrentProcess(),&created,&ended,&kernel,&user))
        throw std::runtime_error("process creation time unavailable");
    const uint64_t start=(static_cast<uint64_t>(created.dwHighDateTime)<<32)|created.dwLowDateTime;
    const auto name=L"Local\\HallidayRuntimeChoice-v1-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(start);
    auto* state=new State;
    state->mutex=CreateMutexW(nullptr,FALSE,(name+L"-mutex").c_str());
    if (!state->mutex) { delete state; throw std::runtime_error("runtime choice mutex unavailable"); }
    state->mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,sizeof(Shared),(name+L"-choice").c_str());
    if(state->mapping)state->shared=static_cast<Shared*>(MapViewOfFile(state->mapping,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(Shared)));
    if(!state->shared){if(state->mapping)CloseHandle(state->mapping);CloseHandle(state->mutex);delete state;throw std::runtime_error("runtime choice mapping unavailable");}
    // Intentionally retained until process exit. Router modules pin themselves;
    // a second DLL sees this same mapping, without environment inheritance.
    return state;
}
} // namespace choice_detail
inline bool pinProcessChoice(bool proposedHalliday) {
    static choice_detail::State* state=choice_detail::createState();
    const auto wait=WaitForSingleObject(state->mutex,5000);
    if(wait!=WAIT_OBJECT_0&&wait!=WAIT_ABANDONED)throw std::runtime_error("runtime choice lock timed out");
    struct Unlock { HANDLE mutex; ~Unlock(){ReleaseMutex(mutex);} } unlock{state->mutex};
    auto& shared=*state->shared;
    constexpr uint32_t magic=0x43524c48; // HLRC
    if(shared.magic==0&&shared.version==0&&shared.backend==0&&shared.reserved==0){
        shared.version=1;shared.backend=proposedHalliday?1:2;shared.reserved=0;
        MemoryBarrier();InterlockedExchange(reinterpret_cast<volatile LONG*>(&shared.magic),magic);
    }
    if(shared.magic!=magic||shared.version!=1||(shared.backend!=1&&shared.backend!=2)||shared.reserved!=0)
        throw std::runtime_error("runtime choice mapping is invalid");
    return shared.backend==1;
}
} // namespace halliday::router
