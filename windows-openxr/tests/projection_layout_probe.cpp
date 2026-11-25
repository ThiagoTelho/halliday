#include "projection_bridge.hpp"
#include "halliday_core.h"
#include <cstdio>
int main(){
    using namespace halliday::projection;
    std::printf("{\"View\":%zu,\"Record\":%zu,\"Extension\":%zu,\"Snapshot\":%zu,"
        "\"offset\":%zu,\"views_offset\":%zu,\"records_offset\":%zu,\"orientation_offset\":%zu,"
        "\"tangents_offset\":%zu,\"required_frame_flag\":%u,\"c_view\":%zu,\"c_geometry\":%zu}\n",
        sizeof(View),sizeof(Record),sizeof(Extension),sizeof(Snapshot),kOffset,offsetof(Record,views),
        offsetof(Extension,records),offsetof(View,orientation),offsetof(View,tangents),
        halliday::kFrameProjectionGeometry,sizeof(HallidayBridgeProjectionView),sizeof(HallidayBridgeProjectionGeometry));
}
