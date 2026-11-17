// The Metal side of Halliday's OpenXR runtime (XR_KHR_metal_enable): the swapchains' textures,
// made on the application's own device, and a way to read one back for the bridge. Kept in
// Objective-C: a dozen messages, not worth a binding crate. Objects cross to Rust as retained
// pointers and come back through hx_release.
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>

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
void *hx_texture(void *device, uint64_t format, uint32_t width, uint32_t height, uint32_t layers, uint32_t samples) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)format
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
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

// Copies a rectangle of a texture's slice into `out`, 4 bytes a pixel, rows top-down, after
// everything already committed on `queue` (the application's own drawing) has run: the copy is
// one more command buffer on that queue, waited for. `scratch` is a shared buffer of at least
// width * height * 4 bytes. Returns 0 when it worked.
int hx_read(void *queue, void *texture, uint32_t slice, uint32_t x, uint32_t y, uint32_t width, uint32_t height,
            void *scratch, uint8_t *out) {
    @autoreleasepool {
        id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
        id<MTLTexture> t = (__bridge id<MTLTexture>)texture;
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)scratch;
        if (!q || !t || !b || x + width > t.width || y + height > t.height || b.length < (uint64_t)width * height * 4) return 1;
        id<MTLCommandBuffer> commands = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromTexture:t
                  sourceSlice:slice
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(x, y, 0)
                   sourceSize:MTLSizeMake(width, height, 1)
                     toBuffer:b
            destinationOffset:0
       destinationBytesPerRow:width * 4
     destinationBytesPerImage:(NSUInteger)width * height * 4];
        [blit endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        if (commands.status != MTLCommandBufferStatusCompleted) return 2;
        memcpy(out, b.contents, (size_t)width * height * 4);
        return 0;
    }
}
