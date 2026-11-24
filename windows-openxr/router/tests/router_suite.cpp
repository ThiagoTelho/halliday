#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include "../router_config.hpp"
#include <iostream>
#include <vector>

using halliday::router::Json;
std::wstring wide(const std::string& s){int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),nullptr,0);if(n<=0)throw std::runtime_error("invalid UTF-8");std::wstring w(n,0);MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,s.data(),static_cast<int>(s.size()),w.data(),n);return w;}
std::wstring quote(const std::wstring& text){std::wstring out=L"\"";size_t slashes=0;for(auto c:text){if(c==L'\\'){++slashes;continue;}if(c==L'\"'){out.append(2*slashes+1,L'\\');out+=c;}else{out.append(slashes,L'\\');out+=c;}slashes=0;}out.append(2*slashes,L'\\');return out+L"\"";}
int wmain(int argc,wchar_t**argv){try{
 if(argc!=2)throw std::runtime_error("suite requires owned fixture JSON");
 HANDLE file=CreateFileW(argv[1],GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
 if(file==INVALID_HANDLE_VALUE)throw std::runtime_error("suite fixture unavailable");
 auto length=GetFileSize(file,nullptr);if(length>128*1024){CloseHandle(file);throw std::runtime_error("suite fixture oversized");}
 std::string bytes(length,0);DWORD read=0;bool ok=ReadFile(file,bytes.data(),length,&read,nullptr);CloseHandle(file);if(!ok||read!=length)throw std::runtime_error("suite read");
 auto fixture=halliday::router::parseJson(bytes);auto exe=wide(fixture.at("program").get<std::string>());unsigned failures=0;
 for(const auto&item:fixture.at("cases")){
  auto folder=wide(item.at("folder").get<std::string>());auto log=folder+L"\\result.log";
  SECURITY_ATTRIBUTES sa{sizeof(sa),nullptr,TRUE};HANDLE output=CreateFileW(log.c_str(),GENERIC_WRITE,FILE_SHARE_READ,&sa,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
  HANDLE input=CreateFileW(L"NUL",GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE,&sa,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(output==INVALID_HANDLE_VALUE||input==INVALID_HANDLE_VALUE)throw std::runtime_error("suite log");
  std::wstring command=quote(exe)+L" "+quote(folder)+L" "+quote(wide(item.at("mode").get<std::string>()))+L" "+std::to_wstring(item.at("expected").get<int>())+L" "+quote(wide(item.at("failure").get<std::string>()));
  STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESTDHANDLES;startup.hStdInput=input;startup.hStdOutput=output;startup.hStdError=output;PROCESS_INFORMATION process{};
  DWORD code=998;
  if(CreateProcessW(exe.c_str(),command.data(),nullptr,nullptr,TRUE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process)){
   if(WaitForSingleObject(process.hProcess,30000)!=WAIT_OBJECT_0){TerminateProcess(process.hProcess,124);WaitForSingleObject(process.hProcess,5000);}
   GetExitCodeProcess(process.hProcess,&code);CloseHandle(process.hThread);CloseHandle(process.hProcess);
  }
  CloseHandle(input);CloseHandle(output);if(code)++failures;
  std::cout<<"CASE "<<(code?"FAIL ":"PASS ")<<item.at("name").get<std::string>()<<" exit="<<code<<'\n'<<std::flush;
 }
 return failures?1:0;
}catch(const std::exception&e){std::cerr<<"FAIL: "<<e.what()<<'\n';return 1;}}
