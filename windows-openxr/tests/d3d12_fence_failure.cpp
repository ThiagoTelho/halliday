// Software-only fault regression: no graphics device or driver is created.
// Includes the real pool so device-loss/safe-retention decisions are exercised.
#include "../src/d3d12_readback.cpp"
#include <cstdio>
#include <cstdlib>

namespace basalt {
HallidayTransferStats& transferStatistics() { static HallidayTransferStats value{};return value; }
ID3D12Resource* retainSwapchainTexture12(const ControlFrameView&) { return nullptr; }
uint32_t swapchainColourSpace(const ControlFrameView&) { return 0; }
}
struct Fence final : ID3D12Fence {
    uint64_t value=0;unsigned releases=0;
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID,void** out) override {if(out)*out=nullptr;return E_NOINTERFACE;}
    ULONG STDMETHODCALLTYPE AddRef() override {return 1;}
    ULONG STDMETHODCALLTYPE Release() override {++releases;return 1;}
    HRESULT STDMETHODCALLTYPE GetPrivateData(REFGUID,UINT*,void*) override {return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE SetPrivateData(REFGUID,UINT,const void*) override {return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE SetPrivateDataInterface(REFGUID,const IUnknown*) override {return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE SetName(LPCWSTR) override {return S_OK;}
    HRESULT STDMETHODCALLTYPE GetDevice(REFIID,void** out) override {if(out)*out=nullptr;return E_NOINTERFACE;}
    UINT64 STDMETHODCALLTYPE GetCompletedValue() override {return value;}
    HRESULT STDMETHODCALLTYPE SetEventOnCompletion(UINT64,HANDLE) override {return E_NOTIMPL;}
    HRESULT STDMETHODCALLTYPE Signal(UINT64 next) override {value=next;return S_OK;}
};
static void require(bool value,const char* message) {
    if(!value){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}
}
static void pending(Fence& fence,uint64_t expected) {
    pool.fence=&fence;pool.pendingValue=expected;pool.inFlight=true;pool.signalQueued=true;pool.faulted=false;
    basalt::transferStatistics().liveFences=1;
}
int main() {
    Fence fence;
    // A removal sentinel must never be mistaken for an extremely high,
    // successfully completed fence, even without a second device error query.
    fence.value=UINT64_MAX;pending(fence,11);
    require(!waitForFrame(),"UINT64_MAX fence completion rejects readback instead of publishing a success");
    require(pool.faulted&&!pool.inFlight,"removed queue is faulted and its pending lease retired");
    require(basalt::resetD3D12Readback(),"removed/finished pool can be torn down safely");
    require(fence.releases==1,"completed pool releases the fence exactly once");

    fence.value=10;pending(fence,11);
    require(!basalt::resetD3D12Readback(),"unfinished GPU work prevents teardown");
    require(fence.releases==1&&pool.fence==&fence&&pool.inFlight,"pending fence is retained instead of released");
    fence.value=11;
    require(basalt::resetD3D12Readback(),"later completion allows retained resources to be collected");
    require(fence.releases==2&&!pool.fence,"the retained fence is released exactly once after completion");

    fence.value=12;pending(fence,11);
    require(waitForFrame(),"ordinary completed work remains a successful readback");
    require(!pool.faulted,"valid completed fence is not marked as lost");
    require(basalt::resetD3D12Readback()&&fence.releases==3,"normal teardown remains balanced");
    std::puts("PASS: D3D12 fence loss rejects publication; unfinished work retained; later completion and normal teardown balanced");
}
