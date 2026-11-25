// A paired D3D12 capture retains the same complete projection packet as D3D11.
#pragma once
#include "d3d11_prior_staging.hpp"

namespace basalt {
PriorStagingResult prepareD3D12PriorFrame(ID3D12Device* device,ID3D12CommandQueue* queue,
    const PriorProjectionFrame& frame,ReadbackImage images[2],PriorProjectionFrame* captured);
void finishD3D12PriorFrame();
// A faulted/incomplete queue keeps all GPU-owned objects alive on false.
bool resetD3D12PriorReadback();
} // namespace basalt
