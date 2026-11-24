// Complete stereo capture metadata shared by the D3D11/D3D12/Vulkan staging paths.
#pragma once
#include "readback.hpp"
#include "bridge_layout.hpp"
#include "projection_bridge.hpp"

namespace basalt {
struct PriorProjectionFrame {
    ControlFrameView views[2]{};
    halliday::Pose head{};
    halliday::projection::View geometry[2]{};
    uint64_t producerEpoch = 0;
    uint32_t spaceEpoch = 0;
    uint32_t focusGeneration = 0;
    uint32_t projectionOrder = 0, projectionFlags = 0;
    bool fullGeometry = false, requiredBatch = false;
};

inline bool priorProjectionEligible(uint32_t count, uint32_t quads,
                                    uint32_t flags, bool fullGeometry) {
    return count == 2 && !quads && !flags && fullGeometry;
}

// Render poses and FOV may change every frame: their complete old packet stays
// with the old pixels. Image layout, semantic flags or coordinate-generation
// changes retire the whole pair instead of combining different layouts/epochs.
inline bool samePriorProjectionLayout(const PriorProjectionFrame& a,
                                      const PriorProjectionFrame& b) {
    if (a.producerEpoch != b.producerEpoch || a.spaceEpoch != b.spaceEpoch || a.focusGeneration != b.focusGeneration ||
        a.projectionOrder != b.projectionOrder || a.projectionFlags != b.projectionFlags ||
        a.fullGeometry != b.fullGeometry || a.requiredBatch != b.requiredBatch) return false;
    for (unsigned eye = 0; eye < 2; ++eye) {
        const auto& x = a.views[eye]; const auto& y = b.views[eye];
        if (x.swapchainId != y.swapchainId || x.imageArrayIndex != y.imageArrayIndex ||
            x.rect.offset.x != y.rect.offset.x || x.rect.offset.y != y.rect.offset.y ||
            x.rect.extent.width != y.rect.extent.width || x.rect.extent.height != y.rect.extent.height) return false;
    }
    return true;
}

enum class PriorStagingResult { Failed, Warmup, Ready };
PriorStagingResult prepareD3D11PriorFrame(ID3D11Device* device,
    const PriorProjectionFrame& frame, ReadbackImage images[2], PriorProjectionFrame* captured);
void resetD3D11PriorReadback();
} // namespace basalt
