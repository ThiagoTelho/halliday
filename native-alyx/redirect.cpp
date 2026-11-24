// Select only the owned Alyx bridge's explicitly requested native runtime.
// The historical public guest request remains a compatibility alias, not a
// fallback or a dependency on that provider's installed runtime.
#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include "encoded_colour.hpp"

static void* halliday_alyx_dlopen(const char* file, int flags) {
    const char* selected = std::getenv("HALLIDAY_NATIVE_OPENXR_RUNTIME");
    const char* home = std::getenv("HOME");
    if (file && selected && *selected) {
        const bool direct = std::strcmp(selected, file) == 0;
        const bool legacy_request = home && *home && std::string(home) +
            "/Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib" == file;
        if (direct || legacy_request) {
            void* handle = dlopen(selected, flags);
            if (handle) {
                // Optional private opt-in exists only in our independent runtime.
                // Stock/adapted runtimes retain their original dispatch and bytes.
                const auto declare = reinterpret_cast<halliday_alyx_colour::DeclareTransfer>(
                    dlsym(handle, "halliday_openxr_set_legacy_encoded_swapchain"));
                const auto negotiate = reinterpret_cast<PFN_xrNegotiateLoaderRuntimeInterface>(
                    dlsym(handle, "xrNegotiateLoaderRuntimeInterface"));
                if (declare && negotiate) {
                    halliday_alyx_colour::declare_transfer.store(declare);
                    halliday_alyx_colour::negotiate_real.store(negotiate);
                    halliday_alyx_colour::selected_handle.store(handle);
                }
            }
            return handle;
        }
    }
    return dlopen(file, flags);
}

static void* halliday_alyx_dlsym(void* handle, const char* name) {
    if (handle && handle == halliday_alyx_colour::selected_handle.load() && name &&
        !std::strcmp(name, "xrNegotiateLoaderRuntimeInterface")) {
        return reinterpret_cast<void*>(halliday_alyx_colour::negotiate);
    }
    return dlsym(handle, name);
}

__attribute__((used)) static struct {
    const void* replacement;
    const void* original;
} halliday_alyx_interpose __attribute__((section("__DATA,__interpose"))) = {
    reinterpret_cast<const void*>(&halliday_alyx_dlopen),
    reinterpret_cast<const void*>(&dlopen)
};

__attribute__((used)) static struct {
    const void* replacement;
    const void* original;
} halliday_alyx_symbol_interpose __attribute__((section("__DATA,__interpose"))) = {
    reinterpret_cast<const void*>(&halliday_alyx_dlsym),
    reinterpret_cast<const void*>(&dlsym)
};
