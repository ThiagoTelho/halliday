import Metal
import simd

/// OpenXR declaration order, separate from Halliday's own room panels. These
/// textures remain at their submitted resolution; only the projection goes
/// through game upscaling, sharpening and frame synthesis.
struct OpenXRComposition {
    static let maximumPanels = 8
    enum AlphaMode: UInt32 { case opaque, premultiplied, straight }
    enum EyeVisibility: UInt32 { case both, left, right }

    struct Panel {
        var texture: MTLTexture
        var srgbTexture: MTLTexture? = nil
        var uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var size: SIMD2<Float>
        var eyeVisibility: EyeVisibility = .both
        var alphaMode: AlphaMode = .premultiplied
        var colourSpace: UInt32 = 1
        /// True means the pose above is VIEW-local, otherwise Halliday world.
        var headLocked = false
    }

    var panels: [Panel]
    /// Insert the projection before this panel index; nil means quads only.
    var projectionIndex: Int?
    var projectionAlphaMode: AlphaMode = .opaque

    struct Header {
        var values: SIMD4<UInt32> // count, projection index, alpha mode, enabled
    }
    struct Plane {
        var planeFromWorld: simd_float4x4
        var size: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var flags: SIMD4<UInt32> // eye, alpha mode, colour, valid
    }

    /// Small geometry/texture bindings only; no pixel readback, resampling pass,
    /// GPU wait, or ordering against unrelated Halliday interface panels.
    static func bind(_ composition: Self?, to encoder: MTLRenderCommandEncoder,
                     headPosition: SIMD3<Float>, headOrientation: simd_quatf,
                     placeholder: MTLTexture) {
        let usable = composition.map {
            $0.panels.count <= maximumPanels &&
                ($0.projectionIndex == nil || (0...$0.panels.count).contains($0.projectionIndex!))
        } ?? false
        let composition = usable ? composition : nil
        var header = Header(values: SIMD4(UInt32(composition?.panels.count ?? 0),
            composition?.projectionIndex.map(UInt32.init) ?? UInt32.max,
            composition?.projectionAlphaMode.rawValue ?? 0, composition == nil ? 0 : 1))
        var planes: [Plane] = []
        var raw = [MTLTexture?](repeating: placeholder, count: maximumPanels)
        var srgb = raw
        let worldFromHead = pose(position: headPosition, orientation: headOrientation)
        for (i, panel) in (composition?.panels ?? []).enumerated() {
            var worldFromPlane = pose(position: panel.position, orientation: panel.orientation)
            if panel.headLocked { worldFromPlane = worldFromHead * worldFromPlane }
            let q = panel.orientation.vector
            let valid = panel.size.x.isFinite && panel.size.y.isFinite && panel.size.x > 0 && panel.size.y > 0 &&
                panel.position.x.isFinite && panel.position.y.isFinite && panel.position.z.isFinite &&
                q.x.isFinite && q.y.isFinite && q.z.isFinite && q.w.isFinite &&
                simd_length_squared(q).isFinite && simd_length_squared(q) > 1e-8
            let view = panel.srgbTexture ?? srgbView(panel.texture)
            raw[i] = panel.texture; srgb[i] = view ?? panel.texture
            planes.append(Plane(planeFromWorld: worldFromPlane.inverse,
                size: SIMD4(panel.size.x, panel.size.y, 0, 0), uvRect: panel.uvRect,
                flags: SIMD4(panel.eyeVisibility.rawValue, panel.alphaMode.rawValue,
                             panel.colourSpace, valid && (panel.colourSpace != 2 || view != nil) ? 1 : 0)))
        }
        if planes.isEmpty {
            planes = [Plane(planeFromWorld: matrix_identity_float4x4, size: .zero,
                            uvRect: .zero, flags: .zero)]
        }
        encoder.setFragmentBytes(&header, length: MemoryLayout<Header>.stride, index: 3)
        encoder.setFragmentBytes(&planes, length: MemoryLayout<Plane>.stride * planes.count, index: 4)
        encoder.setFragmentTextures(raw, range: 55..<(55 + maximumPanels))
        encoder.setFragmentTextures(srgb, range: (55 + maximumPanels)..<(55 + maximumPanels * 2))
    }

    private static func pose(position: SIMD3<Float>, orientation: simd_quatf) -> simd_float4x4 {
        var matrix = simd_float4x4(orientation)
        matrix.columns.3 = SIMD4(position, 1)
        return matrix
    }

    private static func srgbView(_ texture: MTLTexture) -> MTLTexture? {
        if texture.pixelFormat == .rgba8Unorm_srgb || texture.pixelFormat == .bgra8Unorm_srgb { return texture }
        guard texture.usage.contains(.pixelFormatView) else { return nil }
        let format: MTLPixelFormat
        switch texture.pixelFormat {
        case .rgba8Unorm: format = .rgba8Unorm_srgb
        case .bgra8Unorm: format = .bgra8Unorm_srgb
        default: return nil
        }
        return texture.makeTextureView(pixelFormat: format)
    }
}

/// Shared by the real scene shader and tiny offscreen pixel-oracle tests.
let openXRCompositionShaderFunctions = """
#define OPENXR_MAX_PANELS 8
struct OpenXRCompositionHeader { uint4 values; };
struct OpenXRCompositionPlane { float4x4 planeFromWorld; float4 size; float4 uvRect; uint4 flags; };

static float3 openxr_to_linear(float3 v) {
    v = max(v, float3(0.0));
    return select(v / 12.92, pow((v + 0.055) / 1.055, float3(2.4)), v > float3(0.04045));
}
static float4 openxr_premult(float4 c, uint alpha, uint colour) {
    c.a = clamp(c.a, 0.0, 1.0);
    if (colour == 0) {
        if (alpha == 1) c.rgb = c.a > 0.000001 ? openxr_to_linear(c.rgb / c.a) * c.a : float3(0.0);
        else c.rgb = openxr_to_linear(c.rgb);
    }
    if (alpha == 0) c.a = 1.0;
    else if (alpha == 2) c.rgb *= c.a;
    return c;
}
static float4 openxr_over(float4 source, float4 below) { return source + below * (1.0 - source.a); }

static float4 openxr_compose(float3 origin, float3 direction, uint eye,
    float4 projectionDisplay, bool projectionCovered, bool projectionPremultiplied,
    constant OpenXRCompositionHeader &header, constant OpenXRCompositionPlane *planes,
    array<texture2d<float>, OPENXR_MAX_PANELS> raw,
    array<texture2d<float>, OPENXR_MAX_PANELS> srgb, sampler smp) {
    float4 result = float4(0.0);
    // The legacy scene projection is display encoded at this point. Undo only
    // that conversion; explicitly tagged source textures were decoded before
    // filtering. Blend all OpenXR layers together in linear premultiplied light.
    float alpha = clamp(projectionDisplay.a, 0.0, 1.0);
    float3 straight = projectionPremultiplied
        ? (alpha > 0.000001 ? projectionDisplay.rgb / alpha : float3(0.0)) : projectionDisplay.rgb;
    float4 projection = float4(openxr_to_linear(straight), alpha);
    if (header.values.z == 0) projection.a = 1.0;
    else projection.rgb *= alpha;
    uint count = min(header.values.x, uint(OPENXR_MAX_PANELS));
    for (uint i = 0; i <= count; i++) {
        if (i == header.values.y && projectionCovered) result = openxr_over(projection, result);
        if (i == count) break;
        constant OpenXRCompositionPlane &p = planes[i];
        if (p.flags.w == 0 || (p.flags.x == 1 && eye != 0) || (p.flags.x == 2 && eye != 1)) continue;
        float3 o = (p.planeFromWorld * float4(origin, 1.0)).xyz;
        float3 d = (p.planeFromWorld * float4(direction, 0.0)).xyz;
        // A quad's visible front has +Z normal, exactly as an OpenXR quad does.
        if (d.z >= -0.000001) continue;
        float t = -o.z / d.z;
        if (t <= 0.0) continue;
        float2 at = o.xy + t * d.xy;
        if (any(abs(at) > p.size.xy * 0.5)) continue;
        float2 local = float2(at.x / p.size.x + 0.5, 0.5 - at.y / p.size.y);
        float2 uv = p.uvRect.xy + local * p.uvRect.zw;
        float2 a = p.uvRect.xy, b = a + p.uvRect.zw;
        float2 halfTexel = 0.5 / float2(raw[i].get_width(), raw[i].get_height());
        float2 centre = (a + b) * 0.5;
        uv = clamp(uv, min(min(a,b) + halfTexel, centre), max(max(a,b) - halfTexel, centre));
        float4 c = p.flags.z == 2 ? srgb[i].sample(smp, uv, level(0.0)) : raw[i].sample(smp, uv, level(0.0));
        result = openxr_over(openxr_premult(c, p.flags.y, p.flags.z), result);
    }
    // Halliday's room/interface scene stays in its existing display-encoded
    // domain. Return premultiplied display colour, without changing native UI.
    result.rgb = result.a > 0.000001 ? projection_linear_to_display(result.rgb / result.a) * result.a : float3(0.0);
    return result;
}
"""
