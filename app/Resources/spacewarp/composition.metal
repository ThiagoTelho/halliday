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
                            constant AlignConstants &u [[buffer(0)]],
                            device atomic_uint *sourceChange [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (any(p >= u.dimensions.xy)) return;
    uint eye = p.x / u.dimensions.z;
    // Compare real images before camera compensation. In an opaque head-locked
    // UI, camera jitter is not evidence that its unchanged pixels should move.
    if (any(previous.read(p).rgb != current.read(p).rgb) &&
        atomic_load_explicit(sourceChange + eye, memory_order_relaxed) == 0)
        atomic_fetch_or_explicit(sourceChange + eye, 1u, memory_order_relaxed);
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
        if (all(prevUV >= 0) && all(prevUV <= 1))
            colour = float4(eye_sample(previous, prevUV * float2(u.dimensions.zy), eye, u.dimensions.z).rgb, 1);
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
int2 flow_cell(float2 pixel, constant SynthesisConstants &u) {
    return int2(floor(pixel / (u.scaleAlpha.xy * float(u.grid.w))));
}
float error_rgb(float3 a, float3 b) { return max(max(abs(a.x-b.x), abs(a.y-b.y)), abs(a.z-b.z)); }
bool inside_eye(float2 p, constant SynthesisConstants &u) {
    return all(p >= 0.5) && p.x <= float(u.dimensions.z)-0.5 && p.y <= float(u.dimensions.y)-0.5;
}

// Motion belongs to CURRENT blocks. Pull candidates from nearby current blocks
// so a moving foreground can reach beyond its current silhouette. Photometric
// consistency and the head-alignment mask reject unreliable correspondences.
// No depth is invented: overlap favours supported moving colour, and genuinely
// unseen/disoccluded content falls back to nearby stable/current colour.
kernel void spacewarp_extrapolate(texture2d<float, access::sample> current [[texture(0)]],
                                  texture2d<float, access::sample> alignedPrevious [[texture(1)]],
                                  texture2d<float, access::read> flow [[texture(2)]],
                                  texture2d<uint, access::read> sceneChange [[texture(3)]],
                                  texture2d<float, access::write> target [[texture(4)]],
                                  constant SynthesisConstants &u [[buffer(0)]],
                                  device atomic_uint *sourceChange [[buffer(1)]], uint2 p [[thread_position_in_grid]]) {
    if (any(p >= u.dimensions.xy)) return;
    uint eye = p.x / u.dimensions.z;
    float2 at(float(p.x % u.dimensions.z)+0.5, float(p.y)+0.5);
    float3 original = eye_sample(current, at, eye, u.dimensions.z).rgb;
    if (atomic_load_explicit(sourceChange + eye, memory_order_relaxed) == 0 || sceneChange.read(uint2(eye,0)).x != 0) {
        target.write(float4(original,1), p); return;
    }
    int2 cell = flow_cell(at,u);
    float2 candidates[9]; uint count = 0;
    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {
        float2 v = source_flow(flow,cell+int2(x,y),eye,u);
        bool duplicate = false;
        for (uint i=0; i<count; ++i) if (distance(v,candidates[i])<0.5) { duplicate=true; break; }
        if (!duplicate) candidates[count++] = v;
    }
    if (count == 1 && length(candidates[0]) < 0.25) { target.write(float4(original,1),p); return; }
    float3 best = original; float bestScore = -1; float2 largest(0);
    for (uint i=0; i<count; ++i) {
        float2 v = candidates[i]; if (length(v)>length(largest)) largest=v;
        float2 s = at - u.scaleAlpha.z*v;
        if (!inside_eye(s,u) || !inside_eye(s-v,u)) continue;
        float2 actual = source_flow(flow,flow_cell(s,u),eye,u);
        if (distance(actual,v)>max(1.5,0.15*length(v))) continue;
        float4 prior = eye_sample(alignedPrevious,s-v,eye,u.dimensions.z);
        float3 colour = eye_sample(current,s,eye,u.dimensions.z).rgb;
        float error = error_rgb(colour,prior.rgb);
        if (prior.a < 0.99 || error > 0.20) continue;
        float score = min(length(v),32.0) * 0.01 + (1-error)*0.1;
        if (score>bestScore) { bestScore=score; best=colour; }
    }
    if (bestScore<0 && length(largest)>0.25) {
        // A trailing silhouette has no exact inverse sample. Seek a nearby
        // stationary colour away from its motion; otherwise retain current.
        float2 away=-normalize(largest);
        for (uint step=0; step<6; ++step) {
            float2 s = at + away*float(1u<<step);
            if (!inside_eye(s,u)) continue;
            if (length(source_flow(flow,flow_cell(s,u),eye,u))>0.5) continue;
            float4 prior=eye_sample(alignedPrevious,s,eye,u.dimensions.z);
            float3 colour=eye_sample(current,s,eye,u.dimensions.z).rgb;
            if (prior.a>0.99 && error_rgb(colour,prior.rgb)<0.10) { best=colour; break; }
        }
    }
    target.write(float4(best,1),p);
}
