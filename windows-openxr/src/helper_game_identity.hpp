// Read-only Win32 parent attribution, with no global/macOS parent-name guess.
#pragma once
#include "helper_game_identity_policy.hpp"
#include <windows.h>
#include <tlhelp32.h>
#include <array>
#include <optional>

namespace halliday::helper_identity {
class Handle {
    HANDLE value_;
public:
    explicit Handle(HANDLE value):value_(value){}
    ~Handle(){if(value_&&value_!=INVALID_HANDLE_VALUE)CloseHandle(value_);}
    Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;
    HANDLE get()const{return value_;}
    explicit operator bool()const{return value_&&value_!=INVALID_HANDLE_VALUE;}
};
inline uint64_t creation(HANDLE process) {
    FILETIME created{},exited{},kernel{},user{};
    if(!GetProcessTimes(process,&created,&exited,&kernel,&user))return 0;
    return (uint64_t(created.dwHighDateTime)<<32)|created.dwLowDateTime;
}
inline std::optional<DWORD> parent_id(DWORD child) {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0));
    if(!snapshot)return std::nullopt;
    PROCESSENTRY32W item{};item.dwSize=sizeof(item);
    if(!Process32FirstW(snapshot.get(),&item))return std::nullopt;
    do {if(item.th32ProcessID==child)return item.th32ParentProcessID;}while(Process32NextW(snapshot.get(),&item));
    return std::nullopt;
}
inline std::optional<std::string> verified_parent_name(std::string_view childName) {
    if(!helper(childName))return std::nullopt;
    Evidence evidence{};evidence.childPid=GetCurrentProcessId();
    evidence.childCreated=creation(GetCurrentProcess());
    const auto parent=parent_id(evidence.childPid);
    if(!parent||!*parent||*parent==evidence.childPid)return std::nullopt;
    evidence.parentPid=*parent;
    Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,*parent));
    if(!process||GetProcessId(process.get())!=*parent)return std::nullopt;
    evidence.parentCreated=creation(process.get());
    DWORD childSession=0,parentSession=0;
    if(!ProcessIdToSessionId(evidence.childPid,&childSession)||
       !ProcessIdToSessionId(evidence.parentPid,&parentSession))return std::nullopt;
    evidence.childSession=childSession;evidence.parentSession=parentSession;
    std::array<wchar_t,32768> path{};DWORD count=DWORD(path.size());
    if(!QueryFullProcessImageNameW(process.get(),0,path.data(),&count)||!count||count>=path.size())return std::nullopt;
    const auto wide=std::wstring_view(path.data(),count);
    const auto slash=wide.find_last_of(L"\\/");const auto filename=slash==std::wstring_view::npos?wide:wide.substr(slash+1);
    if(filename.empty()||filename.size()>63)return std::nullopt;
    std::array<char,64> utf8{};
    const int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,filename.data(),int(filename.size()),
                                      utf8.data(),int(utf8.size()-1),nullptr,nullptr);
    if(bytes<=0||size_t(bytes)>=utf8.size())return std::nullopt;
    const std::string name(utf8.data(),size_t(bytes));
    const auto confirmed=parent_id(evidence.childPid);if(!confirmed)return std::nullopt;
    evidence.confirmedParentPid=*confirmed;
    evidence.parentAlive=WaitForSingleObject(process.get(),0)==WAIT_TIMEOUT;
    evidence.complete=true;
    return verified(childName,name,evidence)?std::optional<std::string>(name):std::nullopt;
}
} // namespace halliday::helper_identity
