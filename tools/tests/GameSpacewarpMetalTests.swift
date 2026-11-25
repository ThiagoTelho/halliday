import Foundation
import Metal
import simd
import Darwin

@main struct GameSpacewarpMetalTests {
    final class Fixture: @unchecked Sendable {
        let flow: MTLTexture, cuts: MTLTexture
        let eyeSize: SIMD2<Int>
        var previous: MTLTexture?, current: MTLTexture?
        var calls = 0
        init(device: MTLDevice, eyeSize: SIMD2<Int>, vector: (Int, Int, Int) -> SIMD2<Float>, cuts: [UInt32] = [0, 0]) {
            self.eyeSize = eyeSize
            let gw = (eyeSize.x + 7) / 8, gh = (eyeSize.y + 7) / 8
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 2 * gw, height: gh, mipmapped: false)
            d.storageMode = .shared; d.usage = .shaderRead
            let flowTexture = device.makeTexture(descriptor: d)!
            flow = flowTexture
            var values: [SIMD2<Float>] = []
            for y in 0..<gh { for x in 0..<2 * gw { values.append(vector(x / gw, x % gw, y)) } }
            values.withUnsafeBytes { flowTexture.replace(region: MTLRegionMake2D(0, 0, 2 * gw, gh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2 * gw * 8) }
            let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 2, height: 1, mipmapped: false)
            c.storageMode = .shared; c.usage = .shaderRead
            self.cuts = device.makeTexture(descriptor: c)!
            cuts.withUnsafeBytes { self.cuts.replace(region: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        }
        func encode(_ p: MTLTexture, _ c: MTLTexture, _ cb: MTLCommandBuffer) -> GameSpacewarp.Motion? {
            calls += 1; previous = p; current = c
            return .init(motion: flow, sceneChange: cuts, analysisSizePerEye: eyeSize, vectorScaleToSource: SIMD2(repeating: 1))
        }
    }
    static func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
    static func require(_ condition: Bool, _ message: String) { if !condition { fail(message) } }
    static let tangents = SIMD4<Float>(-1, 1, 1, -1)
    static func descriptor(_ rotation: simd_quatf = simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
                           position: SIMD3<Float> = .zero, flipped: Bool = false,
                           colour: SIMD2<UInt32> = SIMD2(repeating: 2), depth: Float = 2) -> GameSpacewarp.Descriptor {
        .init(orientation: rotation.vector, position: position, tangentsLeft: tangents, tangentsRight: tangents,
              flipped: flipped, colourSpaces: colour, reprojectionDepth: depth)
    }
    static func source(_ device: MTLDevice, _ eyeWidth: Int, _ height: Int, format: MTLPixelFormat = .rgba8Unorm,
                       pixel: (Int, Int, Int) -> SIMD3<UInt8>) -> (MTLTexture, [UInt8]) {
        let width = eyeWidth * 2
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .pixelFormatView]
        let t = device.makeTexture(descriptor: d)!
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let bgra = format == .bgra8Unorm || format == .bgra8Unorm_srgb
        for y in 0..<height { for x in 0..<width {
            let p = pixel(x / eyeWidth, x % eyeWidth, y), i = (y * width + x) * 4
            bytes[i] = bgra ? p.z : p.x; bytes[i + 1] = p.y; bytes[i + 2] = bgra ? p.x : p.z
        } }
        bytes.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return (t, bytes)
    }
    static func read(_ texture: MTLTexture, _ cb: MTLCommandBuffer, _ device: MTLDevice) -> MTLBuffer {
        let row = (texture.width * 4 + 255) & ~255
        let b = device.makeBuffer(length: row * texture.height, options: .storageModeShared)!
        let encoder = cb.makeBlitCommandEncoder()!
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                     sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: b,
                     destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * texture.height)
        encoder.endEncoding(); return b
    }
    static func bytes(_ buffer: MTLBuffer, _ texture: MTLTexture) -> [UInt8] {
        let row = (texture.width * 4 + 255) & ~255
        let p = buffer.contents().assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []; result.reserveCapacity(texture.width * texture.height * 4)
        for y in 0..<texture.height { result.append(contentsOf: UnsafeBufferPointer(start: p + y * row, count: texture.width * 4)) }
        return result
    }
    static func finish(_ cb: MTLCommandBuffer) { cb.commit(); cb.waitUntilCompleted(); require(cb.status == .completed, "Metal error: \(String(describing: cb.error))") }
    static func main() {
        do { try run() } catch { fail("\(error)") }
    }
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("Metal unavailable") }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let size = SIMD2(128, 96)
        func make(_ fixture: Fixture?) throws -> GameSpacewarp {
            var provider: GameSpacewarp.FlowProvider?
            if let fixture { provider = { p, c, cb in fixture.encode(p, c, cb) } }
            return try GameSpacewarp(device: device, resourceFolder: folder, flowProvider: provider)
        }
        func prepare(_ processor: GameSpacewarp, _ source: MTLTexture, _ sequence: UInt64, _ descriptor: GameSpacewarp.Descriptor = descriptor()) {
            let cb = queue.makeCommandBuffer()!
            require(processor.prepare(source: source, sequence: sequence, descriptor: descriptor, commandBuffer: cb), "Real frame was rejected")
            finish(cb)
        }
        func generated(_ processor: GameSpacewarp, alpha: Float = 0.5) -> ([UInt8], Double) {
            let cb = queue.makeCommandBuffer()!
            guard let texture = processor.synthesize(alpha: alpha, commandBuffer: cb) else { fail("Prediction absent") }
            let buffer = read(texture, cb, device); finish(cb)
            return (bytes(buffer, texture), (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        var checks: [String] = []
        let zero = Fixture(device: device, eyeSize: size, vector: { _, _, _ in .zero })
        let processor = try make(zero)
        let (staticSource, staticBytes) = source(device, size.x, size.y) { eye, x, y in SIMD3(UInt8((x * 7 + y * 3) % 255), UInt8(y), UInt8(eye * 180)) }
        prepare(processor, staticSource, 1)
        require(!processor.historyReady, "One real frame must not generate")
        let cb0 = queue.makeCommandBuffer()!
        require(processor.synthesize(alpha: 0.5, commandBuffer: cb0) == nil, "Unprimed flow must fall back")
        prepare(processor, staticSource, 2)
        require(processor.historyReady && zero.calls == 1, "Two real frames should compute flow once")
        require(generated(processor).0 == staticBytes, "Static image must remain bit exact")
        prepare(processor, staticSource, 2)
        require(zero.calls == 1, "Repeated real sequence must not recompute flow")
        require(generated(processor, alpha: 0).0 == staticBytes, "Zero phase must retain real pixels")
        checks.append("static bit identity; real-frame priming; no synthetic feedback; repeated sequence")

        // Current-indexed flow: left object moves +8, right object -8; predict ±4.
        let moving = Fixture(device: device, eyeSize: size) { eye, gx, gy in
            let x = gx * 8, y = gy * 8, begin = eye == 0 ? 40 : 56
            return x >= begin && x < begin + 32 && y >= 32 && y < 64 ? SIMD2(eye == 0 ? 8 : -8, 0) : .zero
        }
        let objects = try make(moving)
        func object(_ current: Bool) -> MTLTexture {
            source(device, size.x, size.y) { eye, x, y in
                let begin = (eye == 0 ? 32 : 64) + (current ? (eye == 0 ? 8 : -8) : 0)
                let inside = x >= begin && x < begin + 32 && y >= 32 && y < 64
                return inside ? (eye == 0 ? SIMD3(240, 40, 20) : SIMD3(20, 240, 40)) : SIMD3(repeating: 20)
            }.0
        }
        prepare(objects, object(false), 10); prepare(objects, object(true), 11)
        let predicted = generated(objects).0
        for eye in 0..<2 {
            var count = 0, sum = 0
            for y in 32..<64 { for x in 0..<size.x {
                let i = (y * size.x * 2 + eye * size.x + x) * 4
                if predicted[i + eye] > 200 { count += 1; sum += x }
            } }
            let expected = Double(eye == 0 ? 44 : 52) + 15.5
            require(count >= 28 * 32 && count <= 36 * 32 && abs(Double(sum) / Double(count) - expected) <= 2.0,
                    "Forward object forecast/edge fill failed in eye \(eye): count \(count), centroid \(Double(sum) / Double(max(1,count))) expected \(expected)")
        }
        checks.append("opposing stereo objects predict forward within two pixels; continuous flow may conservatively shrink an occlusion boundary, without arbitrary background painting")

        let cuts = Fixture(device: device, eyeSize: size, vector: { _, _, _ in SIMD2(30, 20) }, cuts: [1, 1])
        let cutProcessor = try make(cuts)
        prepare(cutProcessor, object(false), 1); prepare(cutProcessor, staticSource, 2)
        require(generated(cutProcessor).0 == staticBytes, "GPU scene cuts must display exact current colour")
        let oneCut = Fixture(device: device, eyeSize: size, vector: { eye,gx,gy in
            let x = gx * 8, y = gy * 8, begin = eye == 0 ? 40 : 56
            return x >= begin && x < begin+32 && y >= 32 && y < 64 ? SIMD2(eye == 0 ? 8 : -8,0) : .zero
        }, cuts:[1,0])
        let perEyeCut = try make(oneCut)
        prepare(perEyeCut,object(false),1); prepare(perEyeCut,object(true),2)
        let separate = generated(perEyeCut).0
        let currentObject = object(true)
        var currentObjectPixels = [UInt8](repeating: 0, count: size.x * size.y * 8)
        currentObject.getBytes(&currentObjectPixels, bytesPerRow: size.x * 8,
                              from: MTLRegionMake2D(0, 0, size.x * 2, size.y), mipmapLevel: 0)
        require(separate == currentObjectPixels, "Cut in one eye must return BOTH current real eyes")
        require(!perEyeCut.currentPredictionGuard!.hasPredictionAfterGPUCompletion,
                "A paired real fallback must not be classified as generated")
        checks.append("one-eye AMD cut suppresses the entire stereo pair without CPU readback")

        // A still eye must not animate from an erroneous/camera-only estimate
        // while the other eye continues predicting genuinely changing content.
        let mixedMotion = Fixture(device:device,eyeSize:size,vector:{ eye,_,_ in SIMD2(eye == 0 ? 8 : -8,0) })
        let mixedProcessor = try make(mixedMotion)
        func mixedSource(_ current:Bool)->MTLTexture {
            source(device,size.x,size.y) { eye,x,y in
                if eye == 0 { return SIMD3(UInt8((x*7+y*3)%255),UInt8(y),0) }
                let begin = current ? 56 : 64
                return x >= begin && x < begin+32 && y >= 32 && y < 64 ? SIMD3(20,240,40) : SIMD3(repeating:20)
            }.0
        }
        prepare(mixedProcessor,mixedSource(false),1); prepare(mixedProcessor,mixedSource(true),2)
        let mixedPrediction = generated(mixedProcessor).0
        for y in 0..<size.y { for x in 0..<size.x {
            let i=(y*size.x*2+x)*4
            for c in 0..<4 { require(mixedPrediction[i+c] == staticBytes[i+c],"Unchanged eye inherited motion from the other eye") }
            if y == 40 {
                let right=(y*size.x*2+size.x+x)*4
                require((mixedPrediction[right+1]>200) == (x>=52 && x<84),"Changing eye stopped its four-pixel forward forecast")
            }
        }}
        checks.append("unchanged real eye stays bit exact despite nonzero flow while changing eye still predicts forward")

        // GPU alignment must remove head motion before AMD sees the image pair.
        let head = Fixture(device: device, eyeSize: size, vector: { _, _, _ in .zero })
        let aligned = try make(head)
        let previousRotation = simd_quatf(angle: 0, axis: SIMD3<Float>(0,1,0))
        let currentRotation = simd_quatf(angle: 15 * .pi / 180, axis: simd_normalize(SIMD3<Float>(0.2,1,0.1)))
        let currentPosition = SIMD3<Float>(0.012, -0.004, 0.006)
        let (previousTexture, previousPixels) = source(device, size.x, size.y) { eye, x, y in
            SIMD3(UInt8(30 + x), UInt8(30 + y), UInt8(60 + eye * 90))
        }
        func samplePrevious(_ eye: Int, _ p: SIMD2<Float>) -> SIMD3<UInt8> {
            let x = p.x - 0.5, y = p.y - 0.5
            let x0 = max(0,min(size.x-1,Int(floor(x)))), x1 = max(0,min(size.x-1,Int(floor(x))+1))
            let y0 = max(0,min(size.y-1,Int(floor(y)))), y1 = max(0,min(size.y-1,Int(floor(y))+1))
            let a = x - floor(x), b = y - floor(y)
            func at(_ xx: Int, _ yy: Int) -> SIMD3<Float> {
                let i = (yy * size.x * 2 + eye * size.x + xx) * 4
                return SIMD3(Float(previousPixels[i]),Float(previousPixels[i+1]),Float(previousPixels[i+2]))
            }
            let v = simd_mix(simd_mix(at(x0,y0), at(x1,y0), SIMD3(repeating:a)), simd_mix(at(x0,y1), at(x1,y1), SIMD3(repeating:a)), SIMD3(repeating:b))
            return SIMD3(UInt8(v.x.rounded()),UInt8(v.y.rounded()),UInt8(v.z.rounded()))
        }
        let (currentTexture, _) = source(device, size.x, size.y) { eye, x, y in
            let uv = SIMD2((Float(x)+0.5)/Float(size.x), (Float(y)+0.5)/Float(size.y))
            let world = simd_normalize(currentRotation.act(SIMD3(uv.x*2-1, 1-uv.y*2, -1)))
            let r = previousRotation.inverse.act(simd_normalize(world*2 + currentPosition))
            let uvPrevious = SIMD2((r.x / -r.z+1)/2, (1-r.y / -r.z)/2)
            return samplePrevious(eye, uvPrevious * SIMD2(Float(size.x),Float(size.y)))
        }
        prepare(aligned, previousTexture, 1)
        let d = descriptor(currentRotation, position: currentPosition)
        let cb = queue.makeCommandBuffer()!
        require(aligned.prepare(source: currentTexture, sequence: 2, descriptor: d, commandBuffer: cb), "Head frame rejected")
        let ap = read(head.previous!, cb, device), cp = read(head.current!, cb, device); finish(cb)
        let aa = bytes(ap, head.previous!), cc = bytes(cp, head.current!)
        var maxError = 0, validPixels = 0
        for i in stride(from: 0, to: aa.count, by: 4) where aa[i+3] == 255 {
            validPixels += 1
            for channel in 0..<3 { maxError = max(maxError, abs(Int(aa[i+channel])-Int(cc[i+channel]))) }
        }
        require(validPixels > size.x * size.y, "Head alignment lost most of both eyes")
        require(maxError <= 1, "Head rotation/position not cancelled before flow: \(maxError) LSB")
        require(aligned.currentDescriptor?.orientation == d.orientation && aligned.currentDescriptor?.position == d.position &&
                aligned.currentDescriptor?.tangentsLeft == d.tangentsLeft, "Prediction must preserve current render pose/FOV")
        checks.append("15-degree combined head rotation plus translation cancelled before flow; max error \(maxError) LSB; current metadata retained")

        // A second independent camera in each eye must be aligned using its
        // own source pose and FOV, rather than the shared head descriptor.
        let beforeEyes = ProjectionEyeViews(
            left: .init(position: [-0.04,0,0.01], orientation: simd_quatf(angle: 0.12, axis: simd_normalize(SIMD3<Float>(0.1,1,0))), tangents: [-1.1,0.9,1.05,-0.95]),
            right: .init(position: [0.04,0.002,-0.01], orientation: simd_quatf(angle: -0.15, axis: simd_normalize(SIMD3<Float>(0.2,1,0.1))), tangents: [-0.8,1.2,0.98,-1.02]))
        let afterEyes = ProjectionEyeViews(
            left: .init(position: beforeEyes.left.position + [0.012,-0.008,0.02],
                orientation: beforeEyes.left.orientation * simd_quatf(angle: 0.17, axis: simd_normalize(SIMD3<Float>(0.4,1,0.2))), tangents: [-0.9,0.85,0.92,-0.88]),
            right: .init(position: beforeEyes.right.position + [-0.006,0.01,-0.015],
                orientation: beforeEyes.right.orientation * simd_quatf(angle: -0.12, axis: simd_normalize(SIMD3<Float>(1,0.3,0.4))), tangents: [-1,1,0.9,-0.95]))
        let stereoFixture = Fixture(device: device, eyeSize: size, vector: { _,_,_ in .zero })
        let stereoAlignment = try make(stereoFixture)
        let (stereoCurrent, _) = source(device, size.x, size.y) { eye, x, y in
            let a = beforeEyes.view(eye), b = afterEyes.view(eye)
            let uv = SIMD2((Float(x)+0.5)/Float(size.x), (Float(y)+0.5)/Float(size.y))
            let ray = simd_normalize(b.orientation.act(SIMD3(
                b.tangents.x + (b.tangents.y-b.tangents.x)*uv.x,
                b.tangents.z + (b.tangents.w-b.tangents.z)*uv.y, -1)))
            let fromPrevious = a.orientation.inverse.act(simd_normalize(ray*2 + b.position-a.position))
            let t = SIMD2(fromPrevious.x / -fromPrevious.z, fromPrevious.y / -fromPrevious.z)
            let oldUV = SIMD2((t.x-a.tangents.x)/(a.tangents.y-a.tangents.x),
                              (a.tangents.z-t.y)/(a.tangents.z-a.tangents.w))
            return samplePrevious(eye, oldUV * SIMD2(Float(size.x),Float(size.y)))
        }
        func eyeDescriptor(_ views: ProjectionEyeViews) -> GameSpacewarp.Descriptor {
            .init(orientation: SIMD4(0,0,0,1), position: .zero, tangentsLeft: tangents,
                  tangentsRight: tangents, flipped: false, colourSpaces: SIMD2(repeating:2), eyeViews: views)
        }
        prepare(stereoAlignment, previousTexture, 1, eyeDescriptor(beforeEyes))
        let stereoCB = queue.makeCommandBuffer()!
        require(stereoAlignment.prepare(source: stereoCurrent, sequence: 2, descriptor: eyeDescriptor(afterEyes), commandBuffer: stereoCB), "Per-eye alignment frame rejected")
        let stereoA = read(stereoFixture.previous!, stereoCB, device), stereoB = read(stereoFixture.current!, stereoCB, device)
        finish(stereoCB)
        let stereoAlignedBytes = bytes(stereoA, stereoFixture.previous!), stereoCurrentBytes = bytes(stereoB, stereoFixture.current!)
        var stereoError = 0, stereoValid = 0
        for i in stride(from: 0, to: stereoAlignedBytes.count, by: 4) where stereoAlignedBytes[i+3] == 255 {
            stereoValid += 1
            for c in 0..<3 { stereoError = max(stereoError, abs(Int(stereoAlignedBytes[i+c])-Int(stereoCurrentBytes[i+c]))) }
        }
        require(stereoValid > size.x*size.y && stereoError <= 1, "Independent eye rotation/translation/zoom not removed before flow: \(stereoError) LSB")
        require(stereoAlignment.currentDescriptor?.eyeViews == afterEyes, "Per-eye descriptor not retained")
        checks.append("independent noncommuting eye rotations, translations and asymmetric zoom align before flow; max error \(stereoError) LSB")

        // Display transfer is canonicalised once, independently for each eye.
        let transfer = Fixture(device: device, eyeSize: size, vector: { _,_,_ in .zero })
        let colours = try make(transfer)
        let (grey, _) = source(device, size.x, size.y, format: .bgra8Unorm_srgb) { _,_,_ in SIMD3(repeating:64) }
        let mixed = descriptor(flipped: true, colour: SIMD2(1,2))
        prepare(colours, grey, 1, mixed); prepare(colours, grey, 2, mixed)
        let encoded = generated(colours).0
        require(abs(Int(encoded[0])-137) <= 1 && encoded[size.x*4] == 64, "Linear/sRGB transfer applied incorrectly")
        let flip = Fixture(device: device, eyeSize: size, vector: { _,_,_ in .zero })
        let flipProcessor = try make(flip)
        prepare(flipProcessor, staticSource, 1, descriptor(flipped:true)); prepare(flipProcessor, staticSource, 2, descriptor(flipped:true))
        let flipped = generated(flipProcessor).0
        require(flipped[1] == UInt8(size.y-1) && flipped[(size.y-1)*size.x*2*4+1] == 0, "Canonical flip wrong")
        checks.append("BGRA sRGB raw view, per-eye linear transfer, canonical vertical flip")

        processor.reset(); require(!processor.historyReady, "Reset retained stale flow")
        prepare(processor, staticSource, 3); require(!processor.historyReady, "Reset must reprime two real frames")
        let otherQueue = device.makeCommandQueue()!, foreign = otherQueue.makeCommandBuffer()!
        require(!processor.prepare(source: staticSource, sequence: 4, descriptor: descriptor(), commandBuffer: foreign), "Cross-queue resources must be rejected")
        let noProvider = try make(nil)
        prepare(noProvider, staticSource, 1); prepare(noProvider, staticSource, 2)
        require(!noProvider.historyReady, "Missing real AMD provider must never synthesize")
        checks.append("reset, unprimed history, cross-queue rejection, absent-provider safe fallback")

        let edges = Fixture(device:device,eyeSize:size,vector:{ eye,_,_ in SIMD2(eye == 0 ? 24 : -24,0) })
        let isolated = try make(edges)
        let (eyeColours,_) = source(device,size.x,size.y) { eye,_,_ in eye == 0 ? SIMD3(240,0,0) : SIMD3(0,240,0) }
        let (nextEyeColours,nextEyeColourBytes) = source(device,size.x,size.y) { eye,_,_ in eye == 0 ? SIMD3(239,0,0) : SIMD3(0,239,0) }
        prepare(isolated,eyeColours,1); prepare(isolated,nextEyeColours,2)
        require(generated(isolated).0 == nextEyeColourBytes,"Warp crossed SBS eye boundary")
        let badFlow = Fixture(device:device,eyeSize:size,vector:{ _,_,_ in SIMD2(.nan,.infinity) })
        let invalidVectors = try make(badFlow)
        let (changedStatic,changedStaticBytes) = source(device,size.x,size.y) { eye,x,y in SIMD3(UInt8((x*7+y*3+1)%255),UInt8(y),UInt8(eye*180)) }
        prepare(invalidVectors,staticSource,1); prepare(invalidVectors,changedStatic,2)
        require(generated(invalidVectors).0 == changedStaticBytes,"Invalid flow produced non-current colour")
        checks.append("SBS seam remains isolated under opposing large flow; nonfinite flow falls back safely")

        // Multiple command buffers may be encoded before they are committed;
        // all bank consumers remain in-order on the same queue.
        let queued = try make(zero)
        prepare(queued,staticSource,1)
        let (second,secondBytes) = source(device,size.x,size.y) { _,_,_ in SIMD3(20,80,180) }
        let (third,thirdBytes) = source(device,size.x,size.y) { _,_,_ in SIMD3(150,40,80) }
        let cb2 = queue.makeCommandBuffer()!, cb3 = queue.makeCommandBuffer()!
        require(queued.prepare(source:second,sequence:2,descriptor:descriptor(),commandBuffer:cb2),"Queued source2 rejected")
        let texture2 = queued.synthesize(alpha:0.5,commandBuffer:cb2)!, buffer2 = read(texture2,cb2,device)
        require(queued.prepare(source:third,sequence:3,descriptor:descriptor(),commandBuffer:cb3),"Queued source3 rejected")
        let texture3 = queued.synthesize(alpha:0.5,commandBuffer:cb3)!, buffer3 = read(texture3,cb3,device)
        cb2.commit(); cb3.commit(); cb3.waitUntilCompleted()
        require(cb2.status == .completed && cb3.status == .completed,"Queued GPU work failed")
        require(bytes(buffer2,texture2) == secondBytes && bytes(buffer3,texture3) == thirdBytes,"Ordered history/output bank reuse corrupted prior frame")
        checks.append("queued command buffers preserve independent real histories and consumed outputs")

        func flags(_ p:GameSpacewarp)->SIMD2<UInt32> { p.currentPredictionGuard!.flagsAfterGPUCompletion }
        func setFlow(_ f:Fixture,_ value:SIMD2<Float>) {
            let gw=f.flow.width,gh=f.flow.height;let data=[SIMD2<Float>](repeating:value,count:gw*gh)
            data.withUnsafeBytes {f.flow.replace(region:MTLRegionMake2D(0,0,gw,gh),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:gw*8)}
        }
        func texturePattern(_ shift:Int,_ permute:Bool=false)->(MTLTexture,[UInt8]) {
            source(device,size.x,size.y) { eye,x,y in
                let xx=(x-shift+size.x*4)%size.x
                let tile=(xx/16 + (permute ? 3:0))%(size.x/16)
                let yy=(y+(permute ? 32:0))%size.y
                let hash=(tile*79 + (yy/8)*37 + eye*31 + (xx%16)*3)%211
                return SIMD3(UInt8(20+hash),UInt8(20+(hash*3)%211),UInt8(20+(hash*7)%211))
            }
        }
        let accurate=Fixture(device:device,eyeSize:size,vector:{_,_,_ in SIMD2(4,0)})
        let continuous=try make(accurate)
        let continuousA=texturePattern(0).0
        prepare(continuous,continuousA,100)
        for i in 1...8 {
            let (t,pixels)=texturePattern(i*4)
            prepare(continuous,t,UInt64(100+i))
            require(flags(continuous) == .zero,"normal4pixel/frame translation falsely classified as a cut: \(flags(continuous))")
            require(generated(continuous).0 != pixels,"continuous source stopped predicting")
        }
        checks.append("8continuous translations retain prediction; low-amplitude static/dither and valid head-alignment regressions remain unchanged")
        let snapFlow=Fixture(device:device,eyeSize:size,vector:{_,_,_ in SIMD2(24,0)})
        let snap=try make(snapFlow)
        prepare(snap,texturePattern(0).0,1)
        let (snapImage,snapPixels)=texturePattern(24)
        prepare(snap,snapImage,2)
        require((flags(snap).x&14) != 0 && (flags(snap).y&14) != 0,"spatial camera snap with unchanged pose/histogram not detected: \(flags(snap))")
        require(generated(snap).0 == snapPixels,"snap pair invented an intermediate instead of exact current source")
        setFlow(snapFlow,SIMD2(4,0));let (afterSnap,afterPixels)=texturePattern(28)
        prepare(snap,afterSnap,3)
        require(flags(snap) == .zero && generated(snap).0 != afterPixels,"fresh real source did not reprime after snap")
        checks.append("same-pose large image snap suppresses both eye intermediates bit-exactly; next continuous pair reprimes without stale motion")
        let rearrangedFlow=Fixture(device:device,eyeSize:size,vector:{_,_,_ in SIMD2(8,0)})
        let rearranged=try make(rearrangedFlow)
        prepare(rearranged,texturePattern(0).0,1)
        let (sceneB,sceneBPixels)=texturePattern(0,true)
        prepare(rearranged,sceneB,2)
        require((flags(rearranged).x&14) != 0 && (flags(rearranged).y&14) != 0,"same-pose spatial scene replacement missed: \(flags(rearranged))")
        require(generated(rearranged).0 == sceneBPixels,"scene replacement smeared")
        checks.append("spatial scene replacement without pose change retains exact new pixels")
        let menuFlow=Fixture(device:device,eyeSize:size,vector:{_,_,_ in SIMD2(12,0)})
        let menu=try make(menuFlow)
        let (background,_)=source(device,size.x,size.y) {_,_,_ in SIMD3(25,40,60)}
        prepare(menu,background,1)
        let (menuImage,menuPixels)=source(device,size.x,size.y) {_,x,y in
            x>=24 && x<88 && y>=16 && y<80 ? SIMD3(220,180,50):SIMD3(25,40,60)
        }
        prepare(menu,menuImage,2)
        require((flags(menu).x&8) != 0 && (flags(menu).y&8) != 0,"new partial opaque UI missed: \(flags(menu))")
        require(generated(menu).0 == menuPixels,"new menu mixed invented and real tiles")
        checks.append("partial opaque UI appearance falls back as a whole pair; no local tiled fallback seams")
        let asymmetricFlow=Fixture(device:device,eyeSize:size,vector:{eye,_,_ in SIMD2(eye == 0 ? 12:8,0)})
        let asymmetric=try make(asymmetricFlow)
        let (asymmetricA,_)=source(device,size.x,size.y) {eye,x,y in
            if eye == 0 {return SIMD3(25,40,60)}
            return x>=32 && x<64 && y>=32 && y<64 ? SIMD3(20,220,60):SIMD3(25,40,60)
        }
        let (asymmetricB,asymmetricPixels)=source(device,size.x,size.y) {eye,x,y in
            if eye == 0 {return x>=24 && x<88 && y>=16 && y<80 ? SIMD3(220,180,50):SIMD3(25,40,60)}
            return x>=40 && x<72 && y>=32 && y<64 ? SIMD3(20,220,60):SIMD3(25,40,60)
        }
        prepare(asymmetric,asymmetricA,1);prepare(asymmetric,asymmetricB,2)
        require((flags(asymmetric).x&8) != 0 && flags(asymmetric).y == 0,"asymmetric source did not isolate its new menu reason: \(flags(asymmetric))")
        require(generated(asymmetric).0 == asymmetricPixels,"one-eye new menu mixed real and predicted stereo phases")
        require(!asymmetric.currentPredictionGuard!.hasPredictionAfterGPUCompletion,"paired real fallback mislabeled as generated")
        checks.append("one-eye-only new menu forces both real eyes; exact per-pair completion ticket reports real output")

        // Cost of composition alone with injected known vectors (not AMD cost).
        let fullSize = SIMD2(2016,2048)
        let fullFlow = Fixture(device: device, eyeSize: fullSize, vector: { eye,_,_ in SIMD2(eye == 0 ? 8 : -8,0) })
        let full = try make(fullFlow)
        let a = source(device,fullSize.x,fullSize.y) { _,x,y in SIMD3(UInt8(x%200),UInt8(y%200),40) }.0
        let movedA = source(device,fullSize.x,fullSize.y) { eye,x,y in SIMD3(UInt8((x+200-(eye == 0 ? 8 : -8))%200),UInt8(y%200),40) }.0
        prepare(full,a,1); prepare(full,movedA,2)
        var times: [Double] = []
        for i in 0..<5 {
            let cb = queue.makeCommandBuffer()!
            require(full.synthesize(alpha:0.5,commandBuffer:cb) != nil,"Full-size composition failed")
            finish(cb); if i>0 { times.append((cb.gpuEndTime-cb.gpuStartTime)*1000) }
        }
        times.sort()
        // Complete path: canonical copies + head alignment + authentic AMD +
        // independent composition, all ordered in one command buffer. This is
        // not an FPS/latency claim for the game or the headset compositor.
        let amd = try GameOpticalFlow(device:device,resourceFolder:folder.deletingLastPathComponent().appendingPathComponent("amd-optical-flow"))
        let real = try GameSpacewarp(device:device,resourceFolder:folder,flowProvider:{ p,c,cb in
            guard let r = amd.encode(previous:p,current:c,commandBuffer:cb) else { return nil }
            return .init(motion:r.motion,sceneChange:r.sceneChange,analysisSizePerEye:r.analysisSizePerEye,
                         vectorScaleToSource:r.vectorScaleToSource,blockSize:r.blockSize)
        })
        func realObject(_ current:Bool)->MTLTexture {
            source(device,512,512) { eye,x,y in
                let shift = eye == 0 ? 16 : -16
                let previousBegin = eye == 0 ? 176 : 272
                let u = x-(current ? shift : 0)
                if u>=previousBegin && u<previousBegin+96 && y>=192 && y<320 {
                    var h=UInt32(truncatingIfNeeded:u &* 19_349_663 ^ y &* 73_856_093 ^ eye &* 83_492_791)
                    h=(h ^ (h>>13)) &* 1_274_126_177
                    return SIMD3(repeating:UInt8(140+((h ^ (h>>16))%100)))
                }
                return SIMD3(repeating:30)
            }.0
        }
        prepare(real,realObject(false),1);prepare(real,realObject(true),2)
        let realPrediction=generated(real).0
        var realObjectCentroids:[Double]=[]
        for eye in 0..<2 {
            var sum=0,count=0
            for y in 200..<312 { for x in 100..<400 {
                if realPrediction[(y*1024+eye*512+x)*4]>100 { sum+=x;count+=1 }
            }}
            let centre=Double(sum)/Double(max(1,count)), expected=Double(eye == 0 ? 200 : 248)+47.5
            require(count>90*112 && count<102*112 && abs(centre-expected)<3,
                    "Authentic AMD→synthesis forecast incorrect in eye\(eye):centroid\(centre),expected\(expected),pixels\(count)")
            realObjectCentroids.append(centre)
        }
        checks.append("authentic AMD→composition moves opposite-eye textured objects forward, centroid within3 pixels of ±8-pixel forecast")
        func pattern(_ shift: Int) -> MTLTexture {
            source(device,fullSize.x,fullSize.y) { eye,x,y in
                let xx = x - (eye == 0 ? shift : -shift)
                var h = UInt32(truncatingIfNeeded:(xx/4) &* 19_349_663 ^ (y/4) &* 73_856_093 ^ eye &* 83_492_791)
                h = (h ^ (h>>13)) &* 1_274_126_177
                return SIMD3(repeating:UInt8(32+((h ^ (h>>16))%192)))
            }.0
        }
        let realPrevious = pattern(0), realCurrent = pattern(8)
        var total:[Double] = [], prepareTimes:[Double] = [], repeatTimes:[Double] = []
        for i in 0..<6 {
            real.reset(); prepare(real,realPrevious,1)
            let cb = queue.makeCommandBuffer()!
            require(real.prepare(source:realCurrent,sequence:2,descriptor:descriptor(),commandBuffer:cb),"Real AMD source rejected")
            require(real.historyReady,"Real AMD did not produce history")
            require(real.synthesize(alpha:0.5,commandBuffer:cb) != nil,"Real AMD synthesis absent")
            finish(cb)
            if i>0 { total.append((cb.gpuEndTime-cb.gpuStartTime)*1000) }
            let repeatCB = queue.makeCommandBuffer()!
            require(real.synthesize(alpha:0.5,commandBuffer:repeatCB) != nil,"Repeated AMD source prediction absent")
            finish(repeatCB)
            if i>0 { repeatTimes.append((repeatCB.gpuEndTime-repeatCB.gpuStartTime)*1000) }
            real.reset(); prepare(real,realPrevious,1)
            let prepCB = queue.makeCommandBuffer()!
            require(real.prepare(source:realCurrent,sequence:2,descriptor:descriptor(),commandBuffer:prepCB),"Real prep failed")
            finish(prepCB)
            if i>0 { prepareTimes.append((prepCB.gpuEndTime-prepCB.gpuStartTime)*1000) }
        }
        total.sort(); prepareTimes.sort(); repeatTimes.sort()
        let smallerSize = SIMD2(1600,1632)
        func smallerPattern(_ shift:Int)->MTLTexture {
            source(device,smallerSize.x,smallerSize.y) { eye,x,y in
                let xx=x-(eye == 0 ? shift : -shift)
                var h=UInt32(truncatingIfNeeded:(xx/4) &* 19_349_663 ^ (y/4) &* 73_856_093 ^ eye &* 83_492_791)
                h=(h ^ (h>>13)) &* 1_274_126_177
                return SIMD3(repeating:UInt8(32+((h ^ (h>>16))%192)))
            }.0
        }
        let smallPrevious=smallerPattern(0), smallCurrent=smallerPattern(8)
        var smallPrepare:[Double]=[],smallRepeat:[Double]=[]
        for i in 0..<6 {
            real.reset(); prepare(real,smallPrevious,1)
            let cb=queue.makeCommandBuffer()!
            require(real.prepare(source:smallCurrent,sequence:2,descriptor:descriptor(),commandBuffer:cb),"Smaller AMD source rejected")
            finish(cb)
            let repeatCB=queue.makeCommandBuffer()!
            require(real.synthesize(alpha:0.5,commandBuffer:repeatCB) != nil,"Smaller prediction absent")
            finish(repeatCB)
            if i>0 { smallPrepare.append((cb.gpuEndTime-cb.gpuStartTime)*1000);smallRepeat.append((repeatCB.gpuEndTime-repeatCB.gpuStartTime)*1000) }
        }
        smallPrepare.sort();smallRepeat.sort()
        checks.append("genuine AMD provider integrated in full-size ordered GPU pipeline; repeated frames reuse motion")
        let report: [String:Any] = ["passed":true,"device":device.name,"checks":checks,
            "scope":"Offscreen Metal composition/geometry checks plus authentic AMD integration; no game, headset, compositor or end-to-end FPS/latency measurement",
            "real_amd_object_centroids":realObjectCentroids,
            "benchmark":["per_eye":[2016,2048],"injected_flow_synthesis_gpu_ms":times,"injected_flow_synthesis_median_ms":times[times.count/2],
                "real_amd_prepare_gpu_ms":prepareTimes,"real_amd_prepare_median_ms":prepareTimes[prepareTimes.count/2],
                "real_amd_prepare_plus_synthesis_gpu_ms":total,"real_amd_prepare_plus_synthesis_median_ms":total[total.count/2],
                "real_amd_repeat_synthesis_gpu_ms":repeatTimes,"real_amd_repeat_synthesis_median_ms":repeatTimes[repeatTimes.count/2]],
            "smaller_benchmark":["per_eye":[1600,1632],"real_amd_prepare_gpu_ms":smallPrepare,"real_amd_prepare_median_ms":smallPrepare[smallPrepare.count/2],
                "real_amd_repeat_synthesis_gpu_ms":smallRepeat,"real_amd_repeat_synthesis_median_ms":smallRepeat[smallRepeat.count/2]]]
        if CommandLine.arguments.count>2 { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2])) }
        for check in checks { print("PASS: \(check)") }
        print("PASS: composition-only GPU median \(times[times.count/2]) ms at2016x2048/eye")
        print("PASS: genuine AMD prepare \(prepareTimes[prepareTimes.count/2]) ms; prepare+predict \(total[total.count/2]) ms; repeat prediction \(repeatTimes[repeatTimes.count/2]) ms")
        print("PASS:1600x1632/eye genuine AMD prepare \(smallPrepare[smallPrepare.count/2]) ms; repeat prediction \(smallRepeat[smallRepeat.count/2]) ms")
    }
}
