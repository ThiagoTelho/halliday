// Independent reusable readback pools for OpenXR UI images. Called under the control video lock or exclusive lifecycle admission.
#pragma once
#include "readback.hpp"
#include <vector>

namespace basalt {
bool readD3D11Panels(ID3D11Device*,const ControlFrameView*,uint32_t,
                    std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&);
void resetD3D11Panels();
bool readD3D12Panels(ID3D12Device*,ID3D12CommandQueue*,const ControlFrameView*,uint32_t,
                    std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&);
bool resetD3D12Panels();
bool readVulkanPanels(void*,const ControlFrameView*,uint32_t,
                     std::vector<std::vector<uint8_t>>&,std::vector<ReadbackImage>&);
}
