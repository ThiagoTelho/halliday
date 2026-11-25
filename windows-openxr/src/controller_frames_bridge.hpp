// Exact host-state declaration, retained with the same cached input sample.
#pragma once
#include "motion_bridge.hpp"
#include "../../core/halliday-bridge/include/controller_frames.h"
namespace halliday::controller_frames {
inline bool readState(Header* header, State* state, uint32_t* mask, Kinds* kinds) {
    if (!header || !state || !kinds) return false;
    *kinds = kLegacy;
    for (unsigned attempt = 0; attempt < 64; ++attempt) {
        uint32_t sequence = 0;
        if (!motion::readState(header,state,mask,&sequence)) return false;
        Kinds declaration = kLegacy;
        read(header,header->stateSeq,sequence,&declaration);
        if (header->stateSeq.load(std::memory_order_acquire) == sequence) {
            *kinds = declaration; return true;
        }
    }
    return false;
}
} // namespace halliday::controller_frames
