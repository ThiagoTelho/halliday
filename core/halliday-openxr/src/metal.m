// The Metal side of Halliday's OpenXR runtime (XR_KHR_metal_enable): the swapchains' textures,
// made on the application's own device, and a way to read one back for the bridge. Kept in
// Objective-C: a dozen messages, not worth a binding crate. Objects cross to Rust as retained
// pointers and come back through hx_release.
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>
#include "../../halliday-bridge/include/readback_batch.h"

void *hx_default_device(void) {
    return (__bridge_retained void *)MTLCreateSystemDefaultDevice();
}

// The device a command queue belongs to.
void *hx_queue_device(void *queue) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    return (__bridge_retained void *)q.device;
}

void *hx_retain(void *object) {
    return (__bridge_retained void *)(__bridge id)object;
}

void hx_release(void *object) {
    if (object) (void)(__bridge_transfer id)object;
}

// A swapchain image: something the application draws into and the runtime reads.
void *hx_texture(void *device, uint64_t format, uint32_t width, uint32_t height, uint32_t layers, uint32_t samples, uint64_t usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)format
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    // XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT permits compute shader writes.
    if (usage & 4u) d.usage |= MTLTextureUsageShaderWrite;
    d.storageMode = MTLStorageModePrivate;
    if (layers > 1) {
        d.textureType = MTLTextureType2DArray;
        d.arrayLength = layers;
    }
    if (samples > 1) {
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = samples;
    }
    return (__bridge_retained void *)[(__bridge id<MTLDevice>)device newTextureWithDescriptor:d];
}

void *hx_buffer(void *device, uint64_t bytes) {
    return (__bridge_retained void *)[(__bridge id<MTLDevice>)device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
}

// All requested rectangles are blitted before the single completion wait.
// The application's drawing and this readback share its command queue; no
// asynchronous stale frame or additional prediction is introduced.
int hx_read_batch(void *queue, void *scratch, const HallidayReadbackRequest *reads, uint32_t count) {
    @autoreleasepool {
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)scratch;
        if (!q || !b || !reads || !count || count > HALLIDAY_MAX_READBACKS || b.device != q.device) return 1;
        NSUInteger offsets[HALLIDAY_MAX_READBACKS] = {0};
        uint64_t bytes = 0;
        // Validate every source/output before encoding or touching any output.
        for (uint32_t n = 0; n < count; ++n) {
            const HallidayReadbackRequest *read = &reads[n];
            id<MTLTexture> t = (__bridge id<MTLTexture>)read->image;
            if (!t || !read->output || !read->width || !read->height ||
                t.device != q.device || t.sampleCount != 1 ||
                (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DArray) ||
                read->slice >= t.arrayLength ||
                (uint64_t)read->x + read->width > t.width || (uint64_t)read->y + read->height > t.height) return 1;
            const uint64_t size = (uint64_t)read->width * read->height * 4;
            if (size > NSUIntegerMax || bytes > NSUIntegerMax - size) return 1;
            offsets[n] = (NSUInteger)bytes; bytes += size;
        }
        if (b.length < bytes) return 1;
        id<MTLCommandBuffer> commands = [q commandBuffer];
        if (!commands) return 2;
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        if (!blit) return 2;
        for (uint32_t n = 0; n < count; ++n) {
            const HallidayReadbackRequest *read = &reads[n];
            id<MTLTexture> t = (__bridge id<MTLTexture>)read->image;
            [blit copyFromTexture:t sourceSlice:read->slice sourceLevel:0
                    sourceOrigin:MTLOriginMake(read->x, read->y, 0)
                      sourceSize:MTLSizeMake(read->width, read->height, 1)
                        toBuffer:b destinationOffset:offsets[n]
           destinationBytesPerRow:(NSUInteger)read->width * 4
         destinationBytesPerImage:(NSUInteger)read->width * read->height * 4];
        }
        [blit endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted) return 2;
        for (uint32_t n = 0; n < count; ++n)
            memcpy(reads[n].output, (const uint8_t *)b.contents + offsets[n],
                   (size_t)reads[n].width * reads[n].height * 4);
        return 0;
    }
}

// Kept as a single-rectangle compatibility wrapper for isolated callers.
int hx_read(void *queue, void *texture, uint32_t slice, uint32_t x, uint32_t y, uint32_t width, uint32_t height,
            void *scratch, uint8_t *out) {
    const HallidayReadbackRequest read = {texture, slice, x, y, width, height, out};
    return hx_read_batch(queue, scratch, &read, 1);
}
