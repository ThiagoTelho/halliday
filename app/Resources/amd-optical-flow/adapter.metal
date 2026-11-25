// Halliday's image layout adapters. AMD Optical Flow math remains in the seven
// translated shader files; this file only prepares eyes and exports vectors.
#include <metal_stdlib>
using namespace metal;

kernel void extract_eye(texture2d<float> source [[texture(0)]], texture2d<float, access::write> target [[texture(1)]],
                        constant uint& eye [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= target.get_width() || p.y >= target.get_height()) return;
    constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(p) + 0.5) / float2(target.get_width(), target.get_height());
    uv.x = (float(eye) + uv.x) * 0.5;
    float2 lo = float2((float(eye) * float(source.get_width()) * 0.5 + 0.5) / float(source.get_width()), 0.5 / float(source.get_height()));
    float2 hi = float2((float(eye + 1) * float(source.get_width()) * 0.5 - 0.5) / float(source.get_width()), 1.0 - lo.y);
    target.write(source.sample(linear, clamp(uv, lo, hi)), p);
}

kernel void clear_uint(texture2d<uint, access::write> target [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x < target.get_width() && p.y < target.get_height()) target.write(uint4(0), p);
}
kernel void clear_float(texture2d<float, access::write> target [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x < target.get_width() && p.y < target.get_height()) target.write(float4(0.001), p);
}
kernel void clear_flow(texture2d<int, access::write> target [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x < target.get_width() && p.y < target.get_height()) target.write(int4(0), p);
}
kernel void export_flow(texture2d<int> flow [[texture(0)]], texture2d<uint> scd [[texture(1)]],
                        texture2d<float, access::write> output [[texture(2)]], texture2d<uint, access::write> scene [[texture(3)]],
                        constant uint& eye [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= flow.get_width() || p.y >= flow.get_height()) return;
    // AMD vectors describe the lookup from current to previous. Expose the
    // opposite, previous→current image displacement, in analysis pixels.
    float2 forward = -float2(flow.read(p).xy);
    output.write(float4(forward, 0, 0), uint2(eye * flow.get_width() + p.x, p.y));
    if (p.x == 0 && p.y == 0) scene.write(uint4((scd.read(uint2(1, 0)).x & 15u) != 0u), uint2(eye, 0));
}
