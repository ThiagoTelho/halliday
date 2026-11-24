// MIT. Explicit runtime selection for the source-built native frame bridge.
#pragma once
#include <cstdio>
#include <cstdlib>

namespace halliday_alyx_runtime {
inline constexpr char application_name[] = "Halliday native Vulkan bridge";

inline const char* selected_library() {
    const char* path = std::getenv("HALLIDAY_NATIVE_OPENXR_RUNTIME");
    if (!path || path[0] != '/') {
        std::fputs("HALLIDAY_NATIVE_OPENXR_RUNTIME must name an explicit absolute native OpenXR library.\n", stderr);
        return nullptr;
    }
    return path;
}
} // namespace halliday_alyx_runtime
