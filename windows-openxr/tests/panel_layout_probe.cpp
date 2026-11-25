#include "panel_bridge.hpp"
#include "focus_bridge.hpp"
#include <cstdio>
int main() {
    using namespace halliday::panels;
    std::printf("{\"Panel\":%zu,\"Batch\":%zu,\"Extension\":%zu,\"Picture\":%zu,"
                "\"panel_offset\":%zu,\"picture_metadata_offset\":%zu,"
                "\"width_m\":%zu,\"eye_visibility\":%zu,\"anchor\":%zu,"
                "\"Focus\":%zu,\"focus_offset\":%zu,\"focus_state\":%zu,\"focus_producer\":%zu,\"focus_requests\":%zu}\n",
        sizeof(Panel),sizeof(Batch),sizeof(Extension),sizeof(Picture), kOffset,kPictureMetadataOffset,
        offsetof(Panel,width),offsetof(Panel,eyeVisibility),offsetof(Panel,anchor),
        sizeof(halliday::focus::Extension),halliday::focus::kOffset,offsetof(halliday::focus::Extension,state),
        offsetof(halliday::focus::Extension,producerEpoch),offsetof(halliday::focus::Extension,requestTags));
}
