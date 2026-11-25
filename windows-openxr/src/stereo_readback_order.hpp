#pragma once
#include "readback.hpp"

namespace basalt {
struct StereoReadbackOrder {
    bool bgra = true; // Retain the legacy zero-layer black-frame convention.
    uint32_t swizzleEyes = 0;
};

// One transport frame carries one byte-order flag. Preserve the first eye's
// native order; only a differently ordered second eye needs an R/B exchange.
inline StereoReadbackOrder stereoReadbackOrder(const ReadbackImage* images, bool hasProjection) {
    StereoReadbackOrder result;
    if (hasProjection) {
        result.bgra = readbackIsBgra(images[0].format);
        for (unsigned eye = 0; eye < 2; ++eye)
            result.swizzleEyes += readbackIsBgra(images[eye].format) != result.bgra;
    }
    return result;
}
} // namespace basalt
