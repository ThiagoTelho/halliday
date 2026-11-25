#pragma once
// Separate sessions may be created/destroyed concurrently on a live instance.
// Park only the fixture DLL's real heartbeat join to expose the ownership gap.
#include "instance_teardown_checks.hpp"
namespace session_teardown_checks {
inline void run(HMODULE runtime,PFN_xrGetInstanceProcAddr get,XrInstance instance,
                const XrSessionCreateInfo& info) {
    using namespace instance_teardown_checks;
    const auto create=function<PFN_xrCreateSession>(get,instance,"xrCreateSession");
    const auto destroy=function<PFN_xrDestroySession>(get,instance,"xrDestroySession");
    XrSession original=XR_NULL_HANDLE;
    check(create(instance,&info,&original)==XR_SUCCESS,"session teardown: create old real worker");
    entered=CreateEventW(nullptr,TRUE,FALSE,nullptr);releaseJoin=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    check(entered&&releaseJoin,"session teardown: synchronization events");
    struct Request {PFN_xrDestroySession destroy;XrSession session;XrResult result=XR_ERROR_RUNTIME_FAILURE;};
    Request request{destroy,original};XrResult during=XR_ERROR_RUNTIME_FAILURE;XrSession duplicate=XR_NULL_HANDLE;
    {
        ImportPatch patch(runtime);
        HANDLE thread=CreateThread(nullptr,0,[](void* data)->DWORD {
            auto& item=*static_cast<Request*>(data);destroyingThread.store(GetCurrentThreadId());
            item.result=item.destroy(item.session);return 0;
        },&request,0,nullptr);
        check(thread!=nullptr,"session teardown: start real destruction");
        const bool parked=WaitForSingleObject(entered,3000)==WAIT_OBJECT_0;
        if(parked)during=create(instance,&info,&duplicate);
        SetEvent(releaseJoin);
        const DWORD stopped=WaitForSingleObject(thread,5000);CloseHandle(thread);
        check(parked&&stopped==WAIT_OBJECT_0,"session teardown: real worker join was parked then finished");
        if(duplicate)destroy(duplicate);
        check(request.result==XR_SUCCESS,"session teardown: original destruction succeeded");
        std::printf("SESSION TEARDOWN: concurrent create result=%d session=%p\n",during,reinterpret_cast<void*>(duplicate));
        check(during==XR_ERROR_LIMIT_REACHED&&!duplicate,
              "new session cannot enter global control/resources during old cleanup");
        XrSession replacement=XR_NULL_HANDLE;
        check(create(instance,&info,&replacement)==XR_SUCCESS&&replacement!=original,
              "session teardown: fresh session recovers after completed cleanup");
        check(destroy(original)==XR_ERROR_HANDLE_INVALID,
              "session teardown: old handle cannot destroy replacement");
        check(destroy(replacement)==XR_SUCCESS,"session teardown: destroy recovered replacement");
    }
    CloseHandle(entered);CloseHandle(releaseJoin);entered=releaseJoin=nullptr;
    std::puts("SESSION PASS: concurrent creation blocked through real heartbeat cleanup; fresh session recovers");
}
}
