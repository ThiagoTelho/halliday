#include "bridge_layout.hpp"
#include <cstring>

extern "C" bool halliday_colour_fixture_publish(void* mapping, uint32_t metadata, uint64_t index) {
    auto* header = static_cast<halliday::Header*>(mapping);
    halliday::Pose pose{}; pose.valid = 1; pose.orientation[3] = 1;
    return halliday::publish(header,4,2,true,pose,index,
        [](size_t eye,uint8_t* pixels) { std::memset(pixels,eye ? 188 : 128,4*2*4); return true; },metadata);
}
