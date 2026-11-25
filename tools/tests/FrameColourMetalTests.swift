import Foundation
import Metal

struct ColourCheckFailure: Error { let message: String }

@main
struct FrameColourMetalTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw ColourCheckFailure(message: message) }
    }

    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ColourCheckFailure(message: "A real Metal device is required")
        }
        // Compile the complete production shader as well as exercising its shared colour helpers.
        _ = try device.makeLibrary(source: shaderSource, options: nil)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        \(projectionColourShaderFunctions)
        kernel void check_colour(texture2d<float> raw [[texture(0)]], texture2d<float> srgb [[texture(1)]],
            device float4 *out [[buffer(0)]], constant uint2 &modes [[buffer(1)]],
            constant uint &interpolate [[buffer(2)]], constant uint &premultiplied [[buffer(3)]],
            constant uint &eyeEdges [[buffer(4)]],
            uint i [[thread_position_in_grid]]) {
            constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 uv = float2(interpolate ? 0.5 : (float(i) + 0.5) / 256.0, 0.5);
            uint mode = i < 128 ? modes.x : modes.y;
            if (eyeEdges != 0) {
                constexpr float offsets[] = {-0.1, 0.0, 0.1, 0.25};
                uv.x = 0.5 + offsets[i % 4];
                float4 rect = eyeEdges == 2 ? float4(0.0, 1.0, 1.0, -1.0) : float4(0.0, 0.0, 1.0, 1.0);
                uv = projection_clamp_eye_uv(raw, uv, rect, i < 128 ? 0 : 1, mode);
            }
            float4 c = projection_sample(raw, srgb, smp, uv, mode);
            out[i] = float4(projection_display_rgb(c.rgb, c.a, mode, premultiplied != 0), c.a);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check_colour")!)

        func render(format: MTLPixelFormat, bytes: [UInt8], mode: UInt32, rightMode: UInt32? = nil,
                    interpolate: Bool = false, premultiplied: Bool = false,
                    eyeEdges: UInt32 = 0) throws -> [SIMD4<Float>] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 256, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .pixelFormatView]
            guard let texture = device.makeTexture(descriptor: descriptor),
                  let view = texture.makeTextureView(pixelFormat: format == .bgra8Unorm ? .bgra8Unorm_srgb : .rgba8Unorm_srgb),
                  let output = device.makeBuffer(length: 256 * MemoryLayout<SIMD4<Float>>.stride),
                  let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw ColourCheckFailure(message: "Could not create real Metal colour resources")
            }
            bytes.withUnsafeBytes { p in texture.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                                                         withBytes: p.baseAddress!, bytesPerRow: 1024) }
            var modes = SIMD2<UInt32>(mode, rightMode ?? mode)
            var interpolation: UInt32 = interpolate ? 1 : 0, premul: UInt32 = premultiplied ? 1 : 0
            var edges = eyeEdges
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(texture, index: 0); encoder.setTexture(view, index: 1)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&modes, length: 8, index: 1)
            encoder.setBytes(&interpolation, length: 4, index: 2)
            encoder.setBytes(&premul, length: 4, index: 3)
            encoder.setBytes(&edges, length: 4, index: 4)
            encoder.dispatchThreads(MTLSize(width: 256, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: 256))
        }

        func encoded(_ linear: Double) -> Float {
            Float(linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1.0 / 2.4) - 0.055)
        }
        let ramp: [UInt8] = (0..<256).flatMap { i -> [UInt8] in [UInt8(i), UInt8(i), UInt8(i), 255] }
        for format in [MTLPixelFormat.rgba8Unorm, .bgra8Unorm] {
            let legacy = try render(format: format, bytes: ramp, mode: 0)
            let linear = try render(format: format, bytes: ramp, mode: 1)
            let srgb = try render(format: format, bytes: ramp, mode: 2)
            for i in 0..<256 {
                try require(abs(legacy[i].x - Float(i) / 255) < 0.0001, "Legacy bytes changed at \(i)")
                try require(abs(linear[i].x - encoded(Double(i) / 255)) < 0.001,
                            "Linear transfer differs from IEC sRGB at \(i)")
                try require(abs(srgb[i].x - Float(i) / 255) < 0.005,
                            "sRGB is encoded twice or not decoded at \(i)")
                try require(legacy[i].w == 1 && linear[i].w == 1 && srgb[i].w == 1, "Colour conversion changed alpha")
            }
            let edge = (0..<256).flatMap { i -> [UInt8] in let v: UInt8 = i < 128 ? 0 : 255; return [v, v, v, 255] }
            let filtered = try render(format: format, bytes: edge, mode: 2, interpolate: true)
            try require(abs(filtered[0].x - encoded(0.5)) < 0.005,
                        "sRGB interpolation happened in encoded space (expected ~0.735, not 0.5)")
            let transparent = Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 0), count: 256).flatMap { $0 }
            let zero = try render(format: format, bytes: transparent, mode: 1, premultiplied: true)
            try require(zero.allSatisfy { $0 == .zero }, "Transparent colour produced NaNs or a halo")
            let premul = Array(repeating: [UInt8](arrayLiteral: 64, 64, 64, 128), count: 256).flatMap { $0 }
            let half = try render(format: format, bytes: premul, mode: 1, premultiplied: true)
            let expected = encoded(0.5) * Float(128) / 255
            try require(abs(half[0].x - expected) < 0.003 && abs(half[0].w - Float(128) / 255) < 0.001,
                        "Premultiplied alpha was gamma-encoded as opaque RGB")
            let mixed: [UInt8] = (0..<256).flatMap { i -> [UInt8] in
                let grey: UInt8 = i < 128 ? 128 : 188
                return [grey, grey, grey, 255]
            }
            let both = try render(format: format, bytes: mixed, mode: 1, rightMode: 2)
            try require(abs(both[32].x - both[224].x) < 0.006 && both[32].x > 0.73,
                        "Mixed linear/sRGB eyes did not reach the same display colour")
            for edges: UInt32 in [1, 2] {
                let seam = try render(format: format, bytes: mixed, mode: 1, rightMode: 2, eyeEdges: edges)
                try require(seam.allSatisfy { abs($0.x - encoded(128.0 / 255)) < 0.006 },
                            "Sharp/blur coordinates sampled across stereo eyes or lost flipped UV bounds")
            }
            let oldSeam = try render(format: format, bytes: mixed, mode: 0, eyeEdges: 1)
            try require(abs(oldSeam[1].x - Float(158) / 255) < 0.001,
                        "The optional eye clamp changed legacy sampling")
            let coloured = Array(repeating: [UInt8](arrayLiteral: 25, 100, 220, 255), count: 256).flatMap { $0 }
            let ordered = try render(format: format, bytes: coloured, mode: 1)
            let red = format == .bgra8Unorm ? 220 : 25
            let blue = format == .bgra8Unorm ? 25 : 220
            try require(abs(ordered[0].x - encoded(Double(red) / 255)) < 0.001 &&
                        abs(ordered[0].z - encoded(Double(blue) / 255)) < 0.001,
                        "BGRA/RGBA channel order changed during colour conversion")
        }
        print("PASS: actual Metal colour ramp, legacy preservation, linear/sRGB transfer, hardware-linear filtering, stereo seam/blur-tap isolation, flipped UV bounds, RGBA/BGRA and premultiplied alpha; complete compositor shader compiled")
    }
}
