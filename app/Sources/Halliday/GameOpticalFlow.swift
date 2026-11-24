import Foundation
@preconcurrency import Metal

/// AMD Optical Flow 1.1.2 from FidelityFX SDK v1.1.4, independently for both eyes.
/// Input is opaque, display-encoded, unflipped full-rectangle SBS. No game depth
/// or motion vectors are required. All GPU work remains in the supplied buffer.
final class GameOpticalFlow: @unchecked Sendable {
    enum Failure: Error { case resources(String), allocation, kernel(String) }
    struct Result {
        /// SBS RG32Float grid: forward previous→current displacement. +X right,
        /// +Y down, in analysis pixels (not UV units or grid texels).
        let motion: MTLTexture
        /// 2×1 R32Uint: AMD scene-change/history flag, one pixel per eye.
        let sceneChange: MTLTexture
        let analysisSizePerEye: SIMD2<Int>
        let vectorScaleToSource: SIMD2<Float>
        let blockSize = 8
    }
    private struct Constants {
        var resolution: SIMD2<Int32>
        var level: UInt32 = 0
        var levelCount: UInt32 = 7
        // Explicit image pairs already have valid history, unlike SDK startup.
        var frameIndex: UInt32 = 6
        var transfer: UInt32 = 0
        var luminance = SIMD2<Float>(0, 1)
    }
    private struct EyeBank {
        let previous: MTLTexture, current: MTLTexture
        let previousLuma: [MTLTexture], currentLuma: [MTLTexture]
        let search: [MTLTexture], filtered: [MTLTexture]
        let histogram: MTLTexture, previousHistogram: MTLTexture, scdTemp: MTLTexture, scd: MTLTexture
    }
    private let device: MTLDevice
    private let divisor: Int
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()
    private var queue: MTLCommandQueue?
    private var size = SIMD2<Int>.zero
    private var banks: [EyeBank] = []
    private var output: MTLTexture?
    private var scenes: MTLTexture?

    init(device: MTLDevice, resourceFolder: URL? = nil, analysisDivisor: Int = 2) throws {
        self.device = device
        divisor = max(1, analysisDivisor)
        guard let folder = resourceFolder ?? Bundle.main.resourceURL?.appendingPathComponent("amd-optical-flow") else {
            throw Failure.resources("amd-optical-flow")
        }
        let files = ["prepare_luma", "compute_luminance_pyramid", "generate_scd_histogram", "compute_scd_divergence",
                     "compute_optical_flow_advanced_v5", "filter_optical_flow_v5", "scale_optical_flow_advanced_v5", "adapter"]
        guard #available(macOS 15, *) else { throw Failure.resources("AMD flow needs Metal 3.2 texture coherence") }
        let options = MTLCompileOptions(); options.languageVersion = .version3_2
        for file in files {
            let source = try String(contentsOf: folder.appendingPathComponent(file + ".metal"), encoding: .utf8)
            let library = try device.makeLibrary(source: source, options: options)
            let entries = file == "adapter" ? ["extract_eye", "clear_uint", "clear_float", "clear_flow", "export_flow"] : ["CS"]
            for entry in entries {
                guard let function = library.makeFunction(name: entry) else { throw Failure.kernel(file + ":" + entry) }
                pipelines[file == "adapter" ? entry : file] = try device.makeComputePipelineState(function: function)
            }
        }
    }

    /// Encode and submit calls in FIFO order on one queue, with all consumers
    /// encoded after this work. The ordered queue safely reuses the texture bank.
    func encode(previous: MTLTexture, current: MTLTexture, commandBuffer: MTLCommandBuffer) -> Result? {
        guard previous.textureType == .type2D, current.textureType == .type2D,
              previous.width == current.width, previous.height == current.height,
              current.width % 2 == 0, current.width >= 256, current.height >= 128,
              current.width <= 8192, current.height <= 4096,
              [.rgba8Unorm, .bgra8Unorm, .rgba16Float].contains(current.pixelFormat),
              [.rgba8Unorm, .bgra8Unorm, .rgba16Float].contains(previous.pixelFormat) else { return nil }
        let wanted = SIMD2(max(64, current.width / 2 / divisor), max(64, current.height / divisor))
        lock.lock(); defer { lock.unlock() }
        if let queue, queue !== commandBuffer.commandQueue { return nil }
        queue = commandBuffer.commandQueue
        if wanted != size {
            do { try allocate(wanted) } catch { return nil }
        }
        guard let output, let scenes else { return nil }
        for eye in 0..<2 {
            let b = banks[eye]
            var constants = Constants(resolution: SIMD2(Int32(size.x), Int32(size.y)))
            guard dispatch("extract_eye", textures: [previous, b.previous], eye: eye,
                           groups: groups(size.x, size.y, 8, 8), threads: MTLSize(width: 8, height: 8, depth: 1), cb: commandBuffer),
                  dispatch("extract_eye", textures: [current, b.current], eye: eye,
                           groups: groups(size.x, size.y, 8, 8), threads: MTLSize(width: 8, height: 8, depth: 1), cb: commandBuffer) else { return nil }
            // Pair mode reconstructs history from the caller's exact previous
            // image, including any camera-rotation compensation it already has.
            for (name, target) in [("clear_uint", b.histogram), ("clear_float", b.previousHistogram),
                                   ("clear_uint", b.scdTemp), ("clear_uint", b.scd), ("clear_flow", b.search[6])] {
                guard dispatch(name, textures: [target], groups: groups(target.width, target.height, 8, 8),
                               threads: MTLSize(width: 8, height: 8, depth: 1), cb: commandBuffer) else { return nil }
            }
            for (image, luma, isPrevious) in [(b.previous, b.previousLuma, true), (b.current, b.currentLuma, false)] {
                guard dispatch("prepare_luma", textures: [image, luma[0]], constants: constants,
                               groups: groups(size.x, size.y, 32, 32), threads: MTLSize(width: 16, height: 16, depth: 1), cb: commandBuffer),
                      dispatch("compute_luminance_pyramid", textures: luma,
                               groups: groups(size.x, size.y, 64, 64), threads: MTLSize(width: 256, height: 1, depth: 1), cb: commandBuffer),
                      dispatch("generate_scd_histogram", textures: [luma[0], b.histogram], constants: constants,
                               groups: MTLSize(width: max(1, ((size.x / 4) / 3 + 31) / 32), height: 16, depth: 9),
                               threads: MTLSize(width: 32, height: 8, depth: 1), cb: commandBuffer),
                      dispatch("compute_scd_divergence", textures: [b.histogram, b.previousHistogram, b.scdTemp, b.scd],
                               groups: MTLSize(width: 9, height: 3, depth: 1), threads: MTLSize(width: 256, height: 1, depth: 1), cb: commandBuffer) else { return nil }
                if isPrevious {
                    guard dispatch("clear_uint", textures: [b.scd], groups: MTLSize(width: 1, height: 1, depth: 1),
                                   threads: MTLSize(width: 8, height: 8, depth: 1), cb: commandBuffer) else { return nil }
                }
            }
            for level in stride(from: 6, through: 0, by: -1) {
                constants.level = UInt32(level)
                let w = max(1, size.x >> level), h = max(1, size.y >> level)
                guard dispatch("compute_optical_flow_advanced_v5", textures: [b.currentLuma[level], b.previousLuma[level], b.search[level], b.scd],
                               constants: constants, groups: MTLSize(width: ((w + 3) / 4 * 16 + 63) / 64, height: (h + 15) / 16, depth: 1),
                               threads: MTLSize(width: 64, height: 1, depth: 1), cb: commandBuffer),
                      dispatch("filter_optical_flow_v5", textures: [b.search[level], b.filtered[level]],
                               groups: groups(b.filtered[level].width, b.filtered[level].height, 16, 4),
                               threads: MTLSize(width: 16, height: 4, depth: 1), cb: commandBuffer) else { return nil }
                if level > 0 {
                    guard dispatch("scale_optical_flow_advanced_v5", textures: [b.currentLuma[level], b.previousLuma[level], b.filtered[level], b.search[level - 1], b.scd],
                                   constants: constants, groups: groups(b.search[level - 1].width, b.search[level - 1].height, 4, 4),
                                   threads: MTLSize(width: 4, height: 4, depth: 4), cb: commandBuffer) else { return nil }
                }
            }
            guard dispatch("export_flow", textures: [b.filtered[0], b.scd, output, scenes], eye: eye,
                           groups: groups(b.filtered[0].width, b.filtered[0].height, 8, 8),
                           threads: MTLSize(width: 8, height: 8, depth: 1), cb: commandBuffer) else { return nil }
        }
        return Result(motion: output, sceneChange: scenes, analysisSizePerEye: size,
                      vectorScaleToSource: SIMD2(Float(current.width / 2) / Float(size.x), Float(current.height) / Float(size.y)))
    }

    private func allocate(_ wanted: SIMD2<Int>) throws {
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
            guard let t = device.makeTexture(descriptor: d) else { throw Failure.allocation }
            return t
        }
        var made: [EyeBank] = []
        for _ in 0..<2 {
            let prev = try texture(.rgba8Unorm, wanted.x, wanted.y), curr = try texture(.rgba8Unorm, wanted.x, wanted.y)
            var prevL: [MTLTexture] = [], currL: [MTLTexture] = [], search: [MTLTexture] = [], filtered: [MTLTexture] = []
            let gw = (wanted.x + 7) / 8, gh = (wanted.y + 7) / 8
            for level in 0..<7 {
                prevL.append(try texture(.r32Uint, wanted.x >> level, wanted.y >> level))
                currL.append(try texture(.r32Uint, wanted.x >> level, wanted.y >> level))
                let shift = 1 << level
                search.append(try texture(.rg32Sint, (gw + shift - 1) / shift, (gh + shift - 1) / shift))
                filtered.append(try texture(.rg32Sint, (gw + shift - 1) / shift, (gh + shift - 1) / shift))
            }
            made.append(EyeBank(previous: prev, current: curr, previousLuma: prevL, currentLuma: currL, search: search, filtered: filtered,
                                histogram: try texture(.r32Uint, 2304, 1), previousHistogram: try texture(.r32Float, 2304, 1),
                                scdTemp: try texture(.r32Uint, 3, 1), scd: try texture(.r32Uint, 3, 1)))
        }
        let out = try texture(.rg32Float, (wanted.x + 7) / 8 * 2, (wanted.y + 7) / 8)
        let scd = try texture(.r32Uint, 2, 1)
        size = wanted; banks = made; output = out; scenes = scd
    }

    private func groups(_ w: Int, _ h: Int, _ x: Int, _ y: Int) -> MTLSize {
        MTLSize(width: (w + x - 1) / x, height: (h + y - 1) / y, depth: 1)
    }
    private func dispatch(_ name: String, textures: [MTLTexture], constants: Constants? = nil, eye: Int? = nil,
                          groups: MTLSize, threads: MTLSize, cb: MTLCommandBuffer) -> Bool {
        guard let pipeline = pipelines[name], let e = cb.makeComputeCommandEncoder() else { return false }
        e.label = "AMD Optical Flow · " + name
        e.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { e.setTexture(texture, index: index) }
        if var constants { e.setBytes(&constants, length: MemoryLayout<Constants>.stride, index: 0) }
        if var eye = eye.map(UInt32.init) { e.setBytes(&eye, length: MemoryLayout<UInt32>.stride, index: 0) }
        e.dispatchThreadgroups(groups, threadsPerThreadgroup: threads); e.endEncoding()
        return true
    }
}
