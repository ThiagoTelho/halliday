// Internal C ABI shared by native Metal and native/Windows Vulkan helpers.
// All rectangles in a batch finish in one ordered GPU submission and fence.
#ifndef HALLIDAY_READBACK_BATCH_H
#define HALLIDAY_READBACK_BATCH_H
#include <stdint.h>

#define HALLIDAY_MAX_READBACKS 10u
typedef struct HallidayReadbackRequest {
    void* image;
    uint32_t slice, x, y, width, height;
    uint8_t* output;
} HallidayReadbackRequest;

#ifdef __cplusplus
extern "C" {
#endif
int hxvk_read_batch(void* context, const HallidayReadbackRequest* reads, uint32_t count);
#ifdef __cplusplus
}
#endif
#endif
