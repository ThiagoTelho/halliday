import Foundation
@preconcurrency import Metal

/// Opaque side-by-side game frames, before reprojection and lens distortion.
/// The caller retains the projection's pose/FOV/UV orientation. A newly processed
/// texture is display encoded; an identity return retains the original metadata.
final class GameUpscaler: @unchecked Sendable {
    enum Failure: Error { case missingResource(String), missingKernel(String), resourceAllocation }

    private struct Uniforms {
        var con0 = SIMD4<UInt32>.zero
        var con1 = SIMD4<UInt32>.zero
        var con2 = SIMD4<UInt32>.zero
        var con3 = SIMD4<UInt32>.zero
        var sizes = SIMD4<UInt32>.zero
        var unused = SIMD4<UInt32>.zero
    }

    private let device: MTLDevice
    private let easu: MTLComputePipelineState
    private let rcas: MTLComputePipelineState
    private let prepare: MTLComputePipelineState
    private let sampler: MTLSamplerState
    private let lock = NSLock()
    private var commandQueue: MTLCommandQueue?
    private var prepared: MTLTexture?
    private var intermediate: MTLTexture?
    private var output: MTLTexture?

    init(device: MTLDevice, resourceFolder: URL? = nil) throws {
        self.device = device
        guard let folder = resourceFolder ?? Bundle.main.resourceURL?.appendingPathComponent("fsr1") else {
            throw Failure.missingResource("fsr1")
        }
        func pipeline(_ file: String, _ entry: String) throws -> MTLComputePipelineState {
            let url = folder.appendingPathComponent(file)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw Failure.missingResource(url.path)
            }
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: entry) else { throw Failure.missingKernel(entry) }
            return try device.makeComputePipelineState(function: function)
        }
        easu = try pipeline("easu.metal", "main0")
        rcas = try pipeline("rcas.metal", "main0")
        prepare = try pipeline("prepare.metal", "prepare_encoded")
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear; descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge; descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw Failure.resourceAllocation }
        self.sampler = sampler
    }

    /// `targetWidth` is per eye. All calls must be encoded and submitted in order
    /// on one command queue, with the projection sampled in the same command buffer.
    /// This lets ordered GPU work reuse a texture bank without CPU waits or copies,
    /// including when three frame command buffers are in flight. Metal retains old
    /// textures when a changed size causes the bank to be replaced.
    func encode(source: MTLTexture, targetWidth: Int, targetHeight: Int, sharpness: Float,
                colourSpaces: SIMD2<UInt32> = .zero,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard source.textureType == .type2D, source.width % 2 == 0,
              source.width >= 4, source.height >= 2,
              targetWidth >= 2, targetWidth <= 8192,
              targetHeight >= 2, targetHeight <= 8192,
              colourSpaces.x <= 2, colourSpaces.y <= 2 else { return nil }
        let sourceWidth = source.width / 2
        // FSR1 is an upscaler. Preserve a higher-resolution producer's frame.
        guard targetWidth >= sourceWidth, targetHeight >= source.height else { return source }
        let strength = sharpness.isFinite ? min(1, max(0, sharpness)) : 0
        let upscale = targetWidth != sourceWidth || targetHeight != source.height
        if !upscale && strength == 0 { return source }

        lock.lock(); defer { lock.unlock() }
        if let queue = commandQueue, queue !== commandBuffer.commandQueue { return nil }
        commandQueue = commandBuffer.commandQueue

        var input = source
        switch source.pixelFormat {
        case .rgba8Unorm_srgb:
            guard let raw = source.makeTextureView(pixelFormat: .rgba8Unorm) else { return nil }
            input = raw
        case .bgra8Unorm_srgb:
            guard let raw = source.makeTextureView(pixelFormat: .bgra8Unorm) else { return nil }
            input = raw
        case .rgba8Unorm, .bgra8Unorm, .rgba16Float, .rgba32Float:
            break
        default: return nil
        }

        func texture(_ existing: inout MTLTexture?, width: Int, height: Int, label: String) -> MTLTexture? {
            if let existing, existing.width == width, existing.height == height { return existing }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            let made = device.makeTexture(descriptor: descriptor)
            made?.label = label
            existing = made
            return made
        }
        guard let result = texture(&output, width: 2 * targetWidth, height: targetHeight,
                                   label: "Game FSR1 output") else { return nil }
        guard result !== input else { return nil } // Never run a neighbourhood filter in place.
        var expanded: MTLTexture?
        if upscale && strength > 0 {
            expanded = texture(&intermediate, width: 2 * targetWidth, height: targetHeight,
                               label: "Game FSR1 EASU")
            guard expanded != nil else { return nil }
        }
        if colourSpaces.x == 1 || colourSpaces.y == 1 {
            guard let encoded = texture(&prepared, width: source.width, height: source.height,
                                        label: "Game FSR1 display-encoded input"),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
            var modes = colourSpaces
            encoder.label = "Game FSR1 colour preparation"
            encoder.setComputePipelineState(prepare)
            encoder.setTexture(input, index: 0); encoder.setTexture(encoded, index: 1)
            encoder.setBytes(&modes, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            dispatch(encoder, width: source.width, height: source.height)
            input = encoded
        }
        var parameters = Uniforms()
        parameters.sizes = SIMD4(UInt32(sourceWidth), UInt32(source.height), UInt32(targetWidth), UInt32(targetHeight))
        if upscale {
            let w = Float(sourceWidth), h = Float(source.height)
            let scale = SIMD2(w / Float(targetWidth), h / Float(targetHeight))
            func bits(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> SIMD4<UInt32> {
                SIMD4(a.bitPattern, b.bitPattern, c.bitPattern, d.bitPattern)
            }
            parameters.con0 = bits(scale.x, scale.y, 0.5 * scale.x - 0.5, 0.5 * scale.y - 0.5)
            parameters.con1 = bits(1 / w, 1 / h, 1 / w, -1 / h)
            parameters.con2 = bits(-1 / w, 2 / h, 1 / w, 2 / h)
            parameters.con3 = bits(0, 4 / h, 0, 0)
            guard encode(easu, input: input, output: expanded ?? result, parameters: &parameters,
                         commandBuffer: commandBuffer) else { return nil }
            input = expanded ?? result
        }
        if strength > 0 {
            // AMD's FsrRcasCon stores exp2(-stops). A normalized strength directly
            // supplies that factor; zero bypasses the sharpening pass entirely.
            parameters.con0 = SIMD4(strength.bitPattern, 0, 0, 0)
            guard encode(rcas, input: input, output: result, parameters: &parameters,
                         commandBuffer: commandBuffer) else { return nil }
        }
        return result
    }

    private func encode(_ pipeline: MTLComputePipelineState, input: MTLTexture, output: MTLTexture,
                        parameters: inout Uniforms, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.label = pipeline === easu ? "Game FSR1 EASU" : "Game FSR1 RCAS"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0); encoder.setTexture(output, index: 1)
        encoder.setBytes(&parameters, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setSamplerState(sampler, index: 0)
        dispatch(encoder, width: output.width, height: output.height)
        return true
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }
}
