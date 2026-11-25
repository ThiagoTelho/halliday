// Small deterministic Win32 substitute for the actual timing implementation's CPU-only test.
#pragma once
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <string>
using DWORD=unsigned long;
using HANDLE=void*;
struct LARGE_INTEGER {int64_t QuadPart=0;};
struct SRWLOCK {std::mutex value;};
#define SRWLOCK_INIT {}
#define INVALID_HANDLE_VALUE reinterpret_cast<HANDLE>(intptr_t(-1))
constexpr DWORD FILE_APPEND_DATA=4,FILE_SHARE_READ=1,FILE_SHARE_WRITE=2,OPEN_ALWAYS=4,FILE_ATTRIBUTE_NORMAL=128;
inline bool timingTestEnabled=false;
inline uint64_t timingTestQpcCalls=0,timingTestOpenCalls=0,timingTestWriteCalls=0,timingTestTicks=100;
inline std::string timingTestOutput;
inline std::wstring timingTestPath;
inline bool QueryPerformanceCounter(LARGE_INTEGER* value){++timingTestQpcCalls;value->QuadPart=int64_t(++timingTestTicks);return true;}
inline bool QueryPerformanceFrequency(LARGE_INTEGER* value){value->QuadPart=1000000;return true;}
inline DWORD GetEnvironmentVariableW(const wchar_t*,wchar_t* output,DWORD size){
    if(!timingTestEnabled)return 0;
    const wchar_t path[]=L"private-test.jsonl";if(size<sizeof(path)/sizeof(wchar_t))return 99999;
    std::wcscpy(output,path);return DWORD(std::wcslen(path));
}
inline HANDLE CreateFileW(const wchar_t* path,DWORD,DWORD,void*,DWORD,DWORD,void*){++timingTestOpenCalls;timingTestPath=path;return reinterpret_cast<HANDLE>(intptr_t(1));}
inline bool CloseHandle(HANDLE){return true;}
inline DWORD GetCurrentProcessId(){return 42;}
inline void AcquireSRWLockExclusive(SRWLOCK* value){value->value.lock();}
inline void ReleaseSRWLockExclusive(SRWLOCK* value){value->value.unlock();}
inline bool WriteFile(HANDLE,const void* data,DWORD size,DWORD* written,void*){
    ++timingTestWriteCalls;timingTestOutput.append(static_cast<const char*>(data),size);*written=size;return true;
}
