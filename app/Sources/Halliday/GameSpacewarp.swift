import Foundation
@preconcurrency import Metal
import simd

/// Causal colour-only extrapolation. The current real frame remains the source
/// pose; the compositor applies its ordinary latest-head reprojection afterwards.
/// Encode and submit on one ordered queue. No GPU readback or waits occur here.
final class GameSpacewarp: @unchecked Sendable {
    enum Failure: Error { case resources, kernel(String), allocation }

    struct Descriptor {
        let orientation: SIMD4<Float> // quaternion xyzw, world from head
        let position: SIMD3<Float>
        let tangentsLeft: SIMD4<Float> // left, right, up, down
        let tangentsRight: SIMD4<Float>
        let flipped: Bool
        let colourSpaces: SIMD2<UInt32> // 0 legacy display, 1 linear, 2 sRGB
        let reprojectionDepth: Float
        let eyeViews: ProjectionEyeViews?

        init(orientation: SIMD4<Float>, position: SIMD3<Float>, tangentsLeft: SIMD4<Float>,
             tangentsRight: SIMD4<Float>, flipped: Bool, colourSpaces: SIMD2<UInt32>,
             reprojectionDepth: Float = 2, eyeViews: ProjectionEyeViews? = nil) {
            self.orientation = orientation; self.position = position
            self.tangentsLeft = eyeViews?.left.tangents ?? tangentsLeft
            self.tangentsRight = eyeViews?.right.tangents ?? tangentsRight
            self.flipped = flipped; self.colourSpaces = colourSpaces
            self.reprojectionDepth = reprojectionDepth
            self.eyeViews = eyeViews
        }
    }

    /// Full SBS motion grid, with independent eye halves. Vectors are forward
    /// previous→current, indexed in CURRENT blocks, +X right and +Y down.
    struct Motion {
        let motion: MTLTexture
        let sceneChange: MTLTexture // two R32Uint pixels, one cut flag per eye
        let analysisSizePerEye: SIMD2<Int>
        let vectorScaleToSource: SIMD2<Float>
        let blockSize: Int

        init(motion: MTLTexture, sceneChange: MTLTexture, analysisSizePerEye: SIMD2<Int>,
             vectorScaleToSource: SIMD2<Float>, blockSize: Int = 8) {
            self.motion = motion; self.sceneChange = sceneChange
            self.analysisSizePerEye = analysisSizePerEye
            self.vectorScaleToSource = vectorScaleToSource; self.blockSize = blockSize
        }
    }

    typealias FlowProvider = @Sendable (MTLTexture, MTLTexture, MTLCommandBuffer) -> Motion?

    struct PredictionGuard: @unchecked Sendable {
        let sequence: UInt64
        fileprivate let result: MTLBuffer
        /// Only read after completion of the ordered command buffer consuming
        /// this prediction. Each pair owns its result; no reused readback slot.
        var flagsAfterGPUCompletion: SIMD2<UInt32> {
            let p = result.contents().assumingMemoryBound(to: UInt32.self)
            return SIMD2(p[0], p[1])
        }
        var hasPredictionAfterGPUCompletion: Bool {
            let f = flagsAfterGPUCompletion; return f.x == 0 && f.y == 0
        }
    }
    private struct GuardConstants {
        var dimensions: SIMD4<UInt32>, grid: SIMD4<UInt32>
        var scaleResidualMotion: SIMD4<Float>, coverage: SIMD4<Float>
    }
    private struct CanonicalConstants {
        var dimensions: SIMD4<UInt32>
        var flags: SIMD4<UInt32>
    }
    private struct EyeAlignment {
        var current0: SIMD4<Float>, current1: SIMD4<Float>, current2: SIMD4<Float>
        var previousInverse0: SIMD4<Float>, previousInverse1: SIMD4<Float>, previousInverse2: SIMD4<Float>
        var shiftDepth: SIMD4<Float>
    }
    private struct AlignConstants {
        var previousLeft: SIMD4<Float>, previousRight: SIMD4<Float>
        var currentLeft: SIMD4<Float>, currentRight: SIMD4<Float>
        var left: EyeAlignment, right: EyeAlignment
        var dimensions: SIMD4<UInt32>
    }
    private struct SynthesisConstants {
        var dimensions: SIMD4<UInt32>
        var grid: SIMD4<UInt32>
        var scaleAlpha: SIMD4<Float>
    }
    private struct Bank {
        let histories: [MTLTexture]
        let aligned: MTLTexture
        let output: MTLTexture
        let sourceChange: MTLBuffer
        let guardTiles: MTLTexture, guardEyeCuts: MTLTexture, guardCuts: MTLTexture
    }

    private let device: MTLDevice
    private let provider: FlowProvider?
    private let canonicalPipeline: MTLComputePipelineState
    private let alignmentPipeline: MTLComputePipelineState
    private let synthesisPipeline: MTLComputePipelineState
    private let guardTilesPipeline: MTLComputePipelineState, guardReducePipeline: MTLComputePipelineState, guardPairPipeline: MTLComputePipelineState
    private let lock = NSLock()
    private var queue: MTLCommandQueue?
    private var bank: Bank?
    private var index = 0
    private var sequence: UInt64?
    private var descriptor: Descriptor?
    private var motion: Motion?
    private var guardTicket: PredictionGuard?
    var currentPredictionGuard: PredictionGuard? { lock.lock(); defer { lock.unlock() }; return guardTicket }

    var historyReady: Bool { lock.lock(); defer { lock.unlock() }; return motion != nil }
    var currentDescriptor: Descriptor? { lock.lock(); defer { lock.unlock() }; return descriptor }

    /// A nil provider only primes history, for safe fallback and isolated tests.
    /// The production loader explicitly supplies genuine AMD Optical Flow.
    init(device: MTLDevice, resourceFolder: URL? = nil, flowProvider: FlowProvider? = nil) throws {
        self.device = device; provider = flowProvider
        guard let folder = resourceFolder ?? Bundle.main.resourceURL?.appendingPathComponent("spacewarp") else { throw Failure.resources }
        let source = try String(contentsOf: folder.appendingPathComponent("composition.metal"), encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { throw Failure.kernel(name) }
            return try device.makeComputePipelineState(function: fn)
        }
        canonicalPipeline = try pipeline("spacewarp_canonical")
        alignmentPipeline = try pipeline("spacewarp_align")
        synthesisPipeline = try pipeline("spacewarp_extrapolate")
        let guardLibrary = try device.makeLibrary(source: String(contentsOf: folder.appendingPathComponent("discontinuity.metal"), encoding: .utf8), options: nil)
        guard let tileFunction = guardLibrary.makeFunction(name: "spacewarp_guard_tiles"),
              let reduceFunction = guardLibrary.makeFunction(name: "spacewarp_guard_reduce"),
              let pairFunction = guardLibrary.makeFunction(name: "spacewarp_guard_pair") else { throw Failure.kernel("discontinuity guard") }
        guardTilesPipeline = try device.makeComputePipelineState(function: tileFunction)
        guardReducePipeline = try device.makeComputePipelineState(function: reduceFunction)
        guardPairPipeline = try device.makeComputePipelineState(function: pairFunction)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        clearHistory()
    }

    /// True means the real frame was accepted (including the first prime).
    /// Only real new sequences enter history. Synthetic images never feed back.
    func prepare(source: MTLTexture, sequence next: UInt64, descriptor nextDescriptor: Descriptor,
                 commandBuffer cb: MTLCommandBuffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard valid(nextDescriptor), source.textureType == .type2D, source.width >= 4,
              source.width % 2 == 0, source.height >= 2,
              let raw = rawView(source), sameQueue(cb) else { clearHistory(); return false }
        if sequence == next { return descriptor != nil }
        if bank?.output.width != source.width || bank?.output.height != source.height {
            do { bank = try allocate(width: source.width, height: source.height) }
            catch { clearHistory(); return false }
            clearHistory()
        }
        if let descriptor, descriptor.colourSpaces != nextDescriptor.colourSpaces ||
            descriptor.reprojectionDepth != nextDescriptor.reprojectionDepth { clearHistory() }
        guard let bank else { return false }
        let previousDescriptor = descriptor
        let previous = bank.histories[index]
        if previousDescriptor != nil { index = 1 - index }
        let current = bank.histories[index]
        var canonical = CanonicalConstants(dimensions: dimensions(current),
            flags: SIMD4(nextDescriptor.flipped ? 1 : 0, nextDescriptor.colourSpaces.x, nextDescriptor.colourSpaces.y, 0))
        guard encode(canonicalPipeline, textures: [raw, current], constants: &canonical, into: cb) else {
            clearHistory(); return false
        }
        // Advance real history even when flow cannot be produced; never retain
        // metadata for an image slot that has already been overwritten.
        descriptor = nextDescriptor; sequence = next; motion = nil; guardTicket = nil
        guard let previousDescriptor, let provider else { return true }
        func alignment(_ eye: Int) -> EyeAlignment {
            let currentEye = nextDescriptor.eyeViews?.view(eye)
            let previousEye = previousDescriptor.eyeViews?.view(eye)
            let currentRotation = simd_float3x3(simd_quatf(vector: simd_normalize(currentEye?.orientation.vector ?? nextDescriptor.orientation)))
            let previousInverse = simd_float3x3(simd_quatf(vector: simd_normalize(previousEye?.orientation.vector ?? previousDescriptor.orientation))).transpose
            return EyeAlignment(current0: SIMD4(currentRotation.columns.0, 0), current1: SIMD4(currentRotation.columns.1, 0), current2: SIMD4(currentRotation.columns.2, 0),
                previousInverse0: SIMD4(previousInverse.columns.0, 0), previousInverse1: SIMD4(previousInverse.columns.1, 0), previousInverse2: SIMD4(previousInverse.columns.2, 0),
                shiftDepth: SIMD4((currentEye?.position ?? nextDescriptor.position) - (previousEye?.position ?? previousDescriptor.position), nextDescriptor.reprojectionDepth))
        }
        var align = AlignConstants(previousLeft: previousDescriptor.tangentsLeft, previousRight: previousDescriptor.tangentsRight,
            currentLeft: nextDescriptor.tangentsLeft, currentRight: nextDescriptor.tangentsRight,
            left: alignment(0), right: alignment(1),
            dimensions: dimensions(current))
        // A head-locked menu can have identical real pixels while the tracked
        // camera moves. Alignment alone must not invent animation in it.
        guard let clear = cb.makeBlitCommandEncoder() else { return true }
        clear.fill(buffer: bank.sourceChange, range: 0..<bank.sourceChange.length, value: 0)
        clear.endEncoding()
        guard let previousLinear = previous.makeTextureView(pixelFormat: .rgba8Unorm_srgb),
              encode(alignmentPipeline, textures: [previous, current, bank.aligned, previousLinear], constants: &align,
                     outputIndex: 2,
                     sourceChange: bank.sourceChange, into: cb),
              let made = provider(bank.aligned, current, cb), valid(made, source: current) else { return true }
        guard let guarded = encodeGuard(current: current, previous: bank.aligned, rawPrevious: previous, motion: made,
                                        sequence: next, bank: bank, cb: cb) else { return true }
        motion = guarded
        return true
    }

    /// No look-ahead: extrapolate at most half of the last real source interval.
    /// GPU cut flags and invalid flow fall back to the current colour per eye.
    func synthesize(alpha: Float, commandBuffer cb: MTLCommandBuffer) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard alpha.isFinite, alpha >= 0, alpha <= 0.5001, sameQueue(cb),
              let bank, let motion, descriptor != nil else { return nil }
        let current = bank.histories[index]
        if alpha == 0 { return current }
        var constants = SynthesisConstants(dimensions: dimensions(current),
            grid: SIMD4(UInt32(motion.motion.width / 2), UInt32(motion.motion.height),
                        UInt32(motion.analysisSizePerEye.x), UInt32(motion.blockSize)),
            scaleAlpha: SIMD4(motion.vectorScaleToSource.x, motion.vectorScaleToSource.y, min(0.5, alpha), 0))
        guard let currentLinear = current.makeTextureView(pixelFormat: .rgba8Unorm_srgb),
              encode(synthesisPipeline, textures: [current, bank.aligned, motion.motion, motion.sceneChange, bank.output, currentLinear],
                     constants: &constants, outputIndex: 4, sourceChange: bank.sourceChange, into: cb) else { return nil }
        return bank.output
    }

    private func clearHistory() { sequence = nil; descriptor = nil; motion = nil; guardTicket = nil; index = 0 }
    private func encodeGuard(current: MTLTexture, previous: MTLTexture, rawPrevious: MTLTexture, motion: Motion,
                             sequence: UInt64, bank: Bank, cb: MTLCommandBuffer) -> Motion? {
        var constants = GuardConstants(dimensions: dimensions(current),
            grid: SIMD4(UInt32(motion.motion.width/2),UInt32(motion.motion.height),UInt32(motion.analysisSizePerEye.x),UInt32(motion.blockSize)),
            scaleResidualMotion: SIMD4(motion.vectorScaleToSource.x,motion.vectorScaleToSource.y,0.16,0.08),
            coverage: SIMD4(0.60,0.70,0.65,0))
        guard encode(guardTilesPipeline,textures:[current,previous,motion.motion,bank.guardTiles,rawPrevious],constants:&constants,outputIndex:3,
                     sourceChange:bank.sourceChange,into:cb), let reduce = cb.makeComputeCommandEncoder() else { return nil }
        reduce.label = "Spacewarp pair discontinuity reduction"
        reduce.setComputePipelineState(guardReducePipeline)
        for (i,t) in [bank.guardTiles,motion.sceneChange,bank.guardEyeCuts].enumerated() { reduce.setTexture(t,index:i) }
        reduce.setBytes(&constants,length:MemoryLayout<GuardConstants>.stride,index:0)
        reduce.dispatchThreadgroups(MTLSize(width:2,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:256,height:1,depth:1))
        reduce.endEncoding()
        guard let pair=cb.makeComputeCommandEncoder() else{return nil}
        pair.setComputePipelineState(guardPairPipeline);pair.setTexture(bank.guardEyeCuts,index:0);pair.setTexture(bank.guardCuts,index:1)
        pair.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));pair.endEncoding()
        // Diagnostic/classification delivery never blocks source presentation.
        // The synthesis kernel consumes guardCuts directly on the GPU.
        guard let result = device.makeBuffer(length:256,options:.storageModeShared),let blit=cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from:bank.guardEyeCuts,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(),sourceSize:MTLSize(width:2,height:1,depth:1),
                  to:result,destinationOffset:0,destinationBytesPerRow:256,destinationBytesPerImage:256)
        blit.endEncoding(); guardTicket = PredictionGuard(sequence:sequence,result:result)
        return Motion(motion:motion.motion,sceneChange:bank.guardCuts,analysisSizePerEye:motion.analysisSizePerEye,
                      vectorScaleToSource:motion.vectorScaleToSource,blockSize:motion.blockSize)
    }
    private func sameQueue(_ cb: MTLCommandBuffer) -> Bool {
        if let queue, queue !== cb.commandQueue { return false }
        queue = cb.commandQueue; return true
    }
    private func dimensions(_ texture: MTLTexture) -> SIMD4<UInt32> {
        SIMD4(UInt32(texture.width), UInt32(texture.height), UInt32(texture.width / 2),
              ((descriptor?.colourSpaces.x ?? 0) > 0 ? 1 : 0) | ((descriptor?.colourSpaces.y ?? 0) > 0 ? 2 : 0))
    }
    private func valid(_ d: Descriptor) -> Bool {
        func finite(_ v: SIMD4<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite }
        func fov(_ v: SIMD4<Float>) -> Bool { finite(v) && v.y > v.x && v.z > v.w }
        return (d.eyeViews?.isValid ?? true) && finite(d.orientation) && simd_length_squared(d.orientation) > 0.1 &&
            d.position.x.isFinite && d.position.y.isFinite && d.position.z.isFinite &&
            fov(d.tangentsLeft) && fov(d.tangentsRight) && d.colourSpaces.x <= 2 && d.colourSpaces.y <= 2 &&
            d.reprojectionDepth.isFinite && d.reprojectionDepth >= 0
    }
    private func valid(_ m: Motion, source: MTLTexture) -> Bool {
        m.motion.pixelFormat == .rg32Float && m.motion.width % 2 == 0 && m.motion.width >= 2 && m.motion.height > 0 &&
            m.sceneChange.pixelFormat == .r32Uint && m.sceneChange.width >= 2 && m.sceneChange.height >= 1 &&
            m.analysisSizePerEye.x > 0 && m.analysisSizePerEye.y > 0 && m.blockSize > 0 &&
            m.vectorScaleToSource.x.isFinite && m.vectorScaleToSource.y.isFinite &&
            abs(m.vectorScaleToSource.x * Float(m.analysisSizePerEye.x) - Float(source.width / 2)) < 0.01 &&
            abs(m.vectorScaleToSource.y * Float(m.analysisSizePerEye.y) - Float(source.height)) < 0.01 &&
            m.motion.width / 2 == (m.analysisSizePerEye.x + m.blockSize - 1) / m.blockSize &&
            m.motion.height == (m.analysisSizePerEye.y + m.blockSize - 1) / m.blockSize
    }
    private func rawView(_ source: MTLTexture) -> MTLTexture? {
        switch source.pixelFormat {
        case .rgba8Unorm, .bgra8Unorm, .rgba16Float, .rgba32Float: return source
        case .rgba8Unorm_srgb: return source.makeTextureView(pixelFormat: .rgba8Unorm)
        case .bgra8Unorm_srgb: return source.makeTextureView(pixelFormat: .bgra8Unorm)
        default: return nil
        }
    }
    private func allocate(width: Int, height: Int) throws -> Bank {
        func texture(_ name: String) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            guard let t = device.makeTexture(descriptor: d) else { throw Failure.allocation }
            t.label = name; return t
        }
        // The two eye flags are followed by independent 16x16-pixel source
        // change maps. A small animated indicator must not enable spurious
        // motion in an otherwise unchanged head-locked menu/background.
        let columns = (width / 2 + 15) / 16, rows = (height + 15) / 16
        let changeBytes = (2 + 2 * columns * rows) * MemoryLayout<UInt32>.stride
        guard let sourceChange = device.makeBuffer(length: changeBytes, options: .storageModePrivate) else { throw Failure.allocation }
        sourceChange.label = "Spacewarp real source changes per eye and tile"
        func uintTexture(_ width: Int, _ height: Int) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Uint,width:width,height:height,mipmapped:false)
            d.storageMode = .private; d.usage=[.shaderRead,.shaderWrite]
            guard let t=device.makeTexture(descriptor:d) else { throw Failure.allocation }; return t
        }
        return try Bank(histories: [texture("Spacewarp real A"), texture("Spacewarp real B")],
                        aligned: texture("Spacewarp head-aligned previous"), output: texture("Spacewarp predicted"),
                        sourceChange: sourceChange,guardTiles:uintTexture(columns*2,rows),guardEyeCuts:uintTexture(2,1),guardCuts:uintTexture(2,1))
    }
    private func encode<T: BitwiseCopyable>(_ pipeline: MTLComputePipelineState, textures: [MTLTexture], constants: inout T,
                           outputIndex: Int? = nil, sourceChange: MTLBuffer? = nil, into cb: MTLCommandBuffer) -> Bool {
        let output = outputIndex ?? textures.count - 1
        guard textures.indices.contains(output), let encoder = cb.makeComputeCommandEncoder() else { return false }
        let target = textures[output]
        encoder.label = "Spacewarp " + pipeline.label.orEmpty
        encoder.setComputePipelineState(pipeline)
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        encoder.setBytes(&constants, length: MemoryLayout<T>.stride, index: 0)
        if let sourceChange { encoder.setBuffer(sourceChange, offset: 0, index: 1) }
        let w = min(16, pipeline.threadExecutionWidth)
        let h = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / w))
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding(); return true
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "compute" }
}
