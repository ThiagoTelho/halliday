// Optional transfer metadata for game frames. Legacy producers retain their original handling.
enum FrameColourSpace: UInt32 {
    case legacy = 0, linear = 1, srgb = 2
}

// Shared with the offscreen Metal check, so tests exercise the compositor's actual functions.
let projectionColourShaderFunctions = """
static float3 projection_linear_to_display(float3 value) {
    float3 v = clamp(value, float3(0.0), float3(1.0));
    return select(12.92 * v, 1.055 * pow(v, float3(1.0 / 2.4)) - 0.055,
                  v > float3(0.0031308));
}

static float2 projection_clamp_eye_uv(texture2d<float> tex, float2 uv, float4 rect,
                                      uint eye, uint colour) {
    if (colour == 0) return uv; // Preserve the existing untagged sampling path.
    float2 a = rect.xy + rect.zw * float2(float(eye) * 0.5, 0.0);
    float2 b = rect.xy + rect.zw * float2(float(eye + 1) * 0.5, 1.0);
    float2 halfTexel = 0.5 / float2(tex.get_width(), tex.get_height());
    float2 centre = (a + b) * 0.5;
    return clamp(uv, min(min(a, b) + halfTexel, centre),
                     max(max(a, b) - halfTexel, centre));
}

static float4 projection_sample(texture2d<float> raw, texture2d<float> srgb,
                                sampler smp, float2 uv, uint colour) {
    // The sRGB view decodes before filtering; converting a filtered encoded value is incorrect.
    return colour == 2 ? srgb.sample(smp, uv, level(0.0)) : raw.sample(smp, uv, level(0.0));
}

static float3 projection_display_rgb(float3 rgb, float alpha, uint colour, bool premultiplied) {
    if (colour == 0) return rgb;
    // Halliday's existing scene/output is display encoded. Explicit game colours enter that
    // domain once; old OpenVR, capture and native producers are left unchanged.
    if (premultiplied) {
        if (alpha <= 0.000001) return float3(0.0);
        return projection_linear_to_display(rgb / alpha) * alpha;
    }
    return projection_linear_to_display(rgb);
}
"""
