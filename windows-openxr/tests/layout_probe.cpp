#include "bridge_layout.hpp"
#include <cstdio>
int main() {
    using halliday::Header;
    std::printf("{\"Pose\":%zu,\"Controller\":%zu,\"State\":%zu,\"Frame\":%zu,"
        "\"state\":%zu,\"client_frames\":%zu,\"frames\":%zu,"
        "\"frame_interval_ns\":%zu,\"client_heartbeat\":%zu,\"scene_seq\":%zu}\n",
        sizeof(halliday::Pose),sizeof(halliday::Controller),sizeof(halliday::State),sizeof(halliday::Frame),
        offsetof(Header,state),offsetof(Header,clientFrames),offsetof(Header,frames),
        offsetof(Header,intervalNs),offsetof(Header,heartbeat),offsetof(Header,sceneSeq));
}
