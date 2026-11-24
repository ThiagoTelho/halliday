import Foundation
import Metal
import simd
import Darwin

/// Actual production scene_fs, using actual SceneUniforms extracted at build.
/// The independent oracle projects a homogeneous world point into each camera;
/// it does not reproduce the shader's direction/shift normalization algorithm.
@main struct ProjectionDesktopMetalTests {
    struct Camera {
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var fov: SIMD4<Float>
        var worldFromCamera: simd_float4x4 {
            var m = simd_float4x4(orientation); m.columns.3 = SIMD4(position, 1); return m
        }
    }
    struct TestCase {
        var name: String
        var left: Camera
        var right: Camera
        var custom: Bool
        var requireBehind = false
    }
    static func require(_ value: Bool, _ text: String) {
        if !value { FileHandle.standardError.write(Data("FAIL: \(text)\n".utf8)); exit(1) }
    }
    static func zeroUniforms() -> SceneUniforms {
        let p = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<SceneUniforms>.stride,
                                                alignment: MemoryLayout<SceneUniforms>.alignment)
        defer { p.deallocate() }
        p.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<SceneUniforms>.stride)
        return p.load(as: SceneUniforms.self)
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen_vs")
        descriptor.fragmentFunction = library.makeFunction(name: "scene_fs")
        descriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sample = MTLSamplerDescriptor(); sample.minFilter = .linear; sample.magFilter = .linear
        sample.sAddressMode = .clampToEdge; sample.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: sample)!
        let sourceWidth = 128, sourceHeight = 96, width = 160, height = 104
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 2 * sourceWidth, height: sourceHeight, mipmapped: false)
        textureDescriptor.storageMode = .shared; textureDescriptor.usage = .shaderRead
        let source = device.makeTexture(descriptor: textureDescriptor)!
        // Alpha is zero deliberately: an opaque projection must still show RGB.
        var atlas = [SIMD4<Float>]()
        for y in 0..<sourceHeight { for x in 0..<(2 * sourceWidth) {
            atlas.append(SIMD4(Float(x % sourceWidth) / Float(sourceWidth - 1),
                               Float(y) / Float(sourceHeight - 1), x < sourceWidth ? 0.2 : 0.8, 0))
        } }
        atlas.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 2 * sourceWidth, sourceHeight),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2 * sourceWidth * 16) }
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: width, height: height, mipmapped: false)
        targetDescriptor.storageMode = .shared; targetDescriptor.usage = .renderTarget
        let target = device.makeTexture(descriptor: targetDescriptor)!
        let headPosition = SIMD3<Float>(0.21, 1.7, 0.3)
        let headTurn = simd_quatf(angle: 0.31, axis: [0, 1, 0]) * simd_quatf(angle: -0.12, axis: [1, 0, 0])
        let targetFov = SIMD4<Float>(-1.4, 1.4, 0.9, -0.9), depth: Float = 2
        let opaque = OpenXRComposition(panels: [], projectionIndex: 0, projectionAlphaMode: .opaque)
        func render(_ test: TestCase, disableOther: Bool = false) -> [SIMD4<Float>] {
            var u = zeroUniforms()
            u.tanLRUD = targetFov; u.eyePosition = SIMD4(headPosition, 1)
            u.rotation = simd_float4x4(headTurn); u.params = SIMD4(0, Float(width), 0, 0)
            u.highlight = SIMD4(-1, 1, 0, 0)
            u.projFromWorld = simd_float4x4(test.left.orientation.inverse)
            u.projUV = SIMD4(0, 0, 1, 1); u.projTan = test.left.fov
            u.projFlags = SIMD4(1, 0, 0, 0)
            u.projShift = SIMD4(headPosition - test.left.position, depth)
            u.projTanOther = disableOther ? .zero : test.right.fov
            u.projFromWorldOther = simd_float4x4(test.right.orientation.inverse)
            u.projShiftOther = test.custom ? SIMD4(headPosition - test.right.position, depth) : SIMD4(0, 0, 0, -1)
            let cb = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
            let encoder = cb.makeRenderCommandEncoder(descriptor: pass)!
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentBytes(&u, length: MemoryLayout<SceneUniforms>.stride, index: 0)
            var unused = [SIMD4<Float>](repeating: .zero, count: 64)
            encoder.setFragmentBytes(&unused, length: unused.count * 16, index: 1)
            encoder.setFragmentBytes(&unused, length: unused.count * 16, index: 2)
            encoder.setFragmentTextures([MTLTexture?](repeating: source, count: 71), range: 0..<71)
            OpenXRComposition.bind(opaque, to: encoder, headPosition: headPosition, headOrientation: headTurn, placeholder: source)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
            cb.commit(); cb.waitUntilCompleted(); require(cb.status == .completed, "GPU completion: \(String(describing: cb.error))")
            var result = [SIMD4<Float>](repeating: .zero, count: width * height)
            result.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: width * 16,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
            return result
        }
        func uv(_ camera: Camera, _ point: SIMD4<Float>) -> (SIMD2<Float>?, Bool) {
            let local = camera.worldFromCamera.inverse * point
            guard local.z < -0.0001 else { return (nil, true) }
            let t = SIMD2(local.x, local.y) / -local.z
            let result = SIMD2((t.x - camera.fov.x) / (camera.fov.y - camera.fov.x),
                              (camera.fov.z - t.y) / (camera.fov.z - camera.fov.w))
            return (result.x >= 0 && result.x <= 1 && result.y >= 0 && result.y <= 1 ? result : nil, false)
        }
        func sampleAtlas(_ uv: SIMD2<Float>, eye: Int) -> SIMD3<Float> {
            let x = max(0, min(Float(2 * sourceWidth - 1), (Float(eye) + uv.x) * Float(sourceWidth) - 0.5))
            let y = max(0, min(Float(sourceHeight - 1), uv.y * Float(sourceHeight) - 0.5))
            let x0 = Int(floor(x)), y0 = Int(floor(y)), x1 = min(2 * sourceWidth - 1, x0 + 1), y1 = min(sourceHeight - 1, y0 + 1)
            let a = simd_mix(atlas[y0 * 2 * sourceWidth + x0], atlas[y0 * 2 * sourceWidth + x1], SIMD4(repeating: x - Float(x0)))
            let b = simd_mix(atlas[y1 * 2 * sourceWidth + x0], atlas[y1 * 2 * sourceWidth + x1], SIMD4(repeating: x - Float(x0)))
            let value = simd_mix(a, b, SIMD4(repeating: y - Float(y0)))
            return SIMD3(value.x, value.y, value.z)
        }
        let sourcePosition = headPosition + SIMD3<Float>(0.06, -0.03, -0.1)
        let legacy = TestCase(name: "legacy-common-camera", left: Camera(position: sourcePosition, orientation: headTurn, fov: [-0.4, 0.4, 0.8, -0.8]),
            right: Camera(position: sourcePosition, orientation: headTurn, fov: [-0.4, 1.2, 0.8, -0.8]), custom: false)
        let baseline = render(legacy)
        var cases: [[String: Any]] = []
        let tests = [legacy,
            TestCase(name: "left-outside-right-canted", left: Camera(position: sourcePosition, orientation: headTurn * simd_quatf(angle: 1.05, axis: [0, 1, 0]), fov: [-0.3, 0.3, 0.8, -0.8]),
                right: Camera(position: sourcePosition + SIMD3(0.07, 0.04, -0.06), orientation: headTurn * simd_quatf(angle: -0.23, axis: [0, 1, 0]) * simd_quatf(angle: 0.12, axis: [1, 0, 0]), fov: [-1.2, 1.1, 0.9, -0.8]), custom: true),
            TestCase(name: "left-behind-right-canted", left: Camera(position: sourcePosition, orientation: headTurn * simd_quatf(angle: .pi, axis: [0, 1, 0]), fov: [-0.6, 0.6, 0.8, -0.8]),
                right: Camera(position: sourcePosition + SIMD3(0.09, -0.025, -0.04), orientation: headTurn * simd_quatf(angle: 0.28, axis: [0, 1, 0]) * simd_quatf(angle: -0.09, axis: [1, 0, 0]), fov: [-1.2, 1.1, 0.9, -0.8]), custom: true, requireBehind: true)]
        for test in tests {
            let pixels = render(test), withoutOther = render(test, disableOther: true)
            var maximum: Float = 0, rightCount = 0, behindCount = 0, leftCount = 0
            for y in stride(from: 8, to: height - 8, by: 4) { for x in stride(from: 8, to: width - 8, by: 4) {
                let tx = targetFov.x + (targetFov.y - targetFov.x) * (Float(x) + 0.5) / Float(width)
                let ty = targetFov.z + (targetFov.w - targetFov.z) * (Float(y) + 0.5) / Float(height)
                let point = SIMD4(headPosition + headTurn.act(simd_normalize(SIMD3(tx, ty, -1))) * depth, 1)
                let (leftUV, behind) = uv(test.left, point), (rightUV, _) = uv(test.right, point)
                let expected: SIMD3<Float>
                if let leftUV { expected = sampleAtlas(leftUV, eye: 0); leftCount += 1 }
                else if let rightUV {
                    expected = sampleAtlas(rightUV, eye: 1); rightCount += 1; if behind { behindCount += 1 }
                    let disabled = withoutOther[y * width + x]
                    require(max(abs(disabled.x), max(abs(disabled.y), abs(disabled.z))) < 0.0001,
                            "\(test.name): disabled-other control was not black")
                } else { expected = .zero }
                let actual = pixels[y * width + x]
                let error = max(abs(actual.x - expected.x), max(abs(actual.y - expected.y), abs(actual.z - expected.z)))
                maximum = max(maximum, error)
                // Metal's sampler may quantize bilinear weights near the SBS
                // seam. Bound error to one ordinary 8-bit output step instead
                // of reproducing a particular GPU's interpolation rounding.
                require(error <= 1 / 255, "\(test.name) \(x),\(y): RGB \(actual) expected \(expected), error \(error)")
                require(actual.w == 1, "opaque target alpha")
            } }
            require(rightCount > 20, "\(test.name): oracle did not exercise the right-eye fallback")
            require(!test.requireBehind || behindCount > 20, "no behind-left fallback coverage")
            cases.append(["case": test.name, "passed": true, "right_fallback_pixels": rightCount,
                          "behind_left_pixels": behindCount, "left_pixels": leftCount, "maximum_float_channel_error": maximum])
        }
        require(render(legacy) == baseline, "custom-to-legacy changed ordinary output pixels")
        cases.append(["case": "opaque-zero-alpha-and-custom-to-legacy-bit-identical", "passed": true])
        let report: [String: Any] = ["passed": true, "device": device.name, "cases": cases,
            "scope": "Actual production Shaders.swift scene_fs + extracted real Swift uniform layout; independent homogeneous camera/gradient CPU oracle. Offscreen real Metal only; no headset/game/latency claim."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]));
        print("PASS: actual scene_fs desktop left-outside/behind → independently canted right camera, gradient CPU pixels, opaque zero alpha, disabled-other negative control, custom→legacy bit identity")
    }
}
