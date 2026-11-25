// Copyright (c) 2026 Halliday contributors. MIT.
// Independent colour-only composition; AMD Optical Flow is a separate MIT stage.
#include <metal_stdlib>
using namespace metal;

struct CanonicalConstants { uint4 dimensions; uint4 flags; };
struct EyeAlignment {
    float4 current0, current1, current2;
    float4 previousInverse0, previousInverse1, previousInverse2;
    float4 shiftDepth;
};
struct AlignConstants {
    float4 previousLeft, previousRight, currentLeft, currentRight;
    EyeAlignment left, right;
    uint4 dimensions;
};
struct SynthesisConstants { uint4 dimensions, grid; float4 scaleAlpha; };

float3 encode_srgb(float3 c) {
    c = saturate(c);
    return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, 12.92 * c, c <= 0.0031308);
}

kernel void spacewarp_canonical(texture2d<float, access::read> source [[texture(0)]],
                                texture2d<float, access::write> target [[texture(1)]],
                                constant CanonicalConstants &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (any(p >= u.dimensions.xy)) return;
    uint eye = p.x / u.dimensions.z;
    uint2 s(p.x, u.flags.x ? u.dimensions.y - 1 - p.y : p.y);
    float3 colour = source.read(s).rgb;
    if ((eye == 0 ? u.flags.y : u.flags.z) == 1) colour = encode_srgb(colour);
    target.write(float4(colour, 1), p);
}

constexpr sampler linear_pixel(coord::pixel, address::clamp_to_edge, filter::linear);

uint source_change_index(uint2 local, uint eye, uint eyeWidth, uint height) {
    uint columns = (eyeWidth + 15u) / 16u, rows = (height + 15u) / 16u;
    return 2u + eye * columns * rows + (local.y / 16u) * columns + local.x / 16u;
}

float4 eye_sample(texture2d<float, access::sample> image, float2 p, uint eye, uint eyeWidth) {
    float2 lo(float(eye * eyeWidth) + 0.5, 0.5);
    float2 hi(float((eye + 1) * eyeWidth) - 0.5, float(image.get_height()) - 0.5);
    return image.sample(linear_pixel, clamp(float2(float(eye * eyeWidth), 0) + p, lo, hi));
}

// Reproject only the PREVIOUS real image into the CURRENT real source camera.
// The radial assumed-depth mapping is identical to scene_fs's latest-head warp.
// Newly uncovered borders use current RGB for flow, but alpha0 masks prediction.
kernel void spacewarp_align(texture2d<float, access::sample> previous [[texture(0)]],
                            texture2d<float, access::read> current [[texture(1)]],
                            texture2d<float, access::write> target [[texture(2)]],
                            texture2d<float, access::sample> previousLinear [[texture(3)]],
                            constant AlignConstants &u [[buffer(0)]],
                            device atomic_uint *sourceChange [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (any(p >= u.dimensions.xy)) return;
    uint eye = p.x / u.dimensions.z;
    // Compare real images before camera compensation. Quantization/dither of
    // at most two encoded levels is not evidence of scene motion. This gate
    // affects displacement eligibility, never the colour of a real frame.
    if (any(abs(previous.read(p).rgb - current.read(p).rgb) > float3(2.0 / 255.0 + 1e-6))) {
        uint tile = source_change_index(uint2(p.x % u.dimensions.z, p.y), eye, u.dimensions.z, u.dimensions.y);
        if (atomic_load_explicit(sourceChange + tile, memory_order_relaxed) == 0)
            atomic_fetch_or_explicit(sourceChange + tile, 1u, memory_order_relaxed);
        if (atomic_load_explicit(sourceChange + eye, memory_order_relaxed) == 0)
            atomic_fetch_or_explicit(sourceChange + eye, 1u, memory_order_relaxed);
    }
    float2 uv = (float2(p.x % u.dimensions.z, p.y) + 0.5) / float2(u.dimensions.zy);
    float4 ct = eye == 0 ? u.currentLeft : u.currentRight;
    float4 pt = eye == 0 ? u.previousLeft : u.previousRight;
    EyeAlignment a = eye == 0 ? u.left : u.right;
    float3x3 worldFromCurrent(a.current0.xyz, a.current1.xyz, a.current2.xyz);
    float3x3 previousFromWorld(a.previousInverse0.xyz, a.previousInverse1.xyz, a.previousInverse2.xyz);
    float3 worldRay = normalize(worldFromCurrent * float3(mix(ct.x, ct.y, uv.x), mix(ct.z, ct.w, uv.y), -1));
    if (a.shiftDepth.w > 0) worldRay = normalize(worldRay * a.shiftDepth.w + a.shiftDepth.xyz);
    float3 r = previousFromWorld * worldRay;
    float4 colour = float4(current.read(p).rgb, 0);
    if (r.z < -1e-4) {
        float2 t = r.xy / -r.z;
        float2 prevUV((t.x - pt.x) / (pt.y - pt.x), (pt.z - t.y) / (pt.z - pt.w));
        if (all(prevUV >= 0) && all(prevUV <= 1)) {
            bool encoded = (u.dimensions.w & (1u << eye)) != 0;
            float3 sample = encoded ? eye_sample(previousLinear, prevUV * float2(u.dimensions.zy), eye, u.dimensions.z).rgb
                                    : eye_sample(previous, prevUV * float2(u.dimensions.zy), eye, u.dimensions.z).rgb;
            colour = float4(encoded ? encode_srgb(sample) : sample, 1);
        }
    }
    target.write(colour, p);
}

float2 source_flow(texture2d<float, access::read> flow, int2 cell, uint eye, constant SynthesisConstants &u) {
    cell = clamp(cell, int2(0), int2(u.grid.xy) - 1);
    float2 v = flow.read(uint2(cell.x + eye * u.grid.x, cell.y)).xy * u.scaleAlpha.xy;
    // Invalid/implausible estimates must never become texture coordinates.
    if (!all(isfinite(v)) || length(v) > max(64.0, float(u.dimensions.z) * 0.25)) return float2(0);
    return v;
}
bool inside_eye(float2 p, constant SynthesisConstants &u) {
    return all(p >= 0.5) && p.x <= float(u.dimensions.z)-0.5 && p.y <= float(u.dimensions.y)-0.5;
}
bool real_source_changed(float2 p, uint eye, constant SynthesisConstants &u,
                         device atomic_uint *sourceChange) {
    if (!inside_eye(p,u)) return false;
    uint2 pixel = uint2(clamp(floor(p), float2(0), float2(u.dimensions.z-1u,u.dimensions.y-1u)));
    uint index = source_change_index(pixel, eye, u.dimensions.z, u.dimensions.y);
    return atomic_load_explicit(sourceChange + index, memory_order_relaxed) != 0;
}

// Continuous sampling of the current-indexed field. One inverse lookup is
// causal: no adjacent block competes to paint its colour over this pixel.
float2 interpolated_flow(texture2d<float, access::read> flow, float2 at,
                         uint eye, constant SynthesisConstants &u) {
    float2 gridPoint = at / (u.scaleAlpha.xy * float(u.grid.w)) - 0.5;
    int2 corner = int2(floor(gridPoint));
    float2 fraction = fract(gridPoint);
    float2 top = mix(source_flow(flow,corner,eye,u),source_flow(flow,corner+int2(1,0),eye,u),fraction.x);
    float2 bottom = mix(source_flow(flow,corner+int2(0,1),eye,u),source_flow(flow,corner+int2(1,1),eye,u),fraction.x);
    return mix(top,bottom,fraction.y);
}

kernel void spacewarp_extrapolate(texture2d<float, access::sample> current [[texture(0)]],
                                  texture2d<float, access::sample> alignedPrevious [[texture(1)]],
                                  texture2d<float, access::read> flow [[texture(2)]],
                                  texture2d<uint, access::read> sceneChange [[texture(3)]],
                                  texture2d<float, access::write> target [[texture(4)]],
                                  texture2d<float, access::sample> currentLinear [[texture(5)]],
                                  constant SynthesisConstants &u [[buffer(0)]],
                                  device atomic_uint *sourceChange [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (any(p >= u.dimensions.xy)) return;
    uint eye = p.x / u.dimensions.z;
    float2 at(float(p.x % u.dimensions.z)+0.5, float(p.y)+0.5);
    float4 original = eye_sample(current,at,eye,u.dimensions.z);
    if (atomic_load_explicit(sourceChange + eye,memory_order_relaxed)==0 || sceneChange.read(uint2(eye,0)).x!=0) {
        target.write(float4(original.rgb,1),p); return;
    }
    float2 velocity = interpolated_flow(flow,at,eye,u);
    float2 source = at-u.scaleAlpha.z*velocity;
    bool supported = real_source_changed(at,eye,u,sourceChange) || real_source_changed(source,eye,u,sourceChange);
    if (!supported || !inside_eye(source,u)) { target.write(float4(original.rgb,1),p); return; }
    bool encoded = (u.dimensions.w & (1u << eye)) != 0;
    float3 sample = encoded ? eye_sample(currentLinear,source,eye,u.dimensions.z).rgb
                            : eye_sample(current,source,eye,u.dimensions.z).rgb;
    target.write(float4(encoded ? encode_srgb(sample) : sample,1),p);
}
