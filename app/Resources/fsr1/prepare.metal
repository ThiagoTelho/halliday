#include <metal_stdlib>
using namespace metal;

kernel void prepare_encoded(texture2d<float, access::read> source [[texture(0)]],
                            texture2d<float, access::write> target [[texture(1)]],
                            constant uint2 &colourSpaces [[buffer(0)]],
                            uint2 at [[thread_position_in_grid]]) {
    if (at.x >= source.get_width() || at.y >= source.get_height()) return;
    float4 pixel = source.read(at);
    if (colourSpaces[at.x / (source.get_width() / 2)] == 1) {
        float3 value = clamp(pixel.rgb, float3(0.0), float3(1.0));
        pixel.rgb = select(12.92 * value, 1.055 * pow(value, float3(1.0 / 2.4)) - 0.055,
                           value > float3(0.0031308));
    }
    target.write(pixel, at);
}
