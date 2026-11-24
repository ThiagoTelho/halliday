import Foundation
import Metal
import Darwin

@main struct GameOpticalFlowMetalTests {
    static func main() {
        do { try run() }
        catch { fail("\(error)") }
    }
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
    }
    static func require(_ condition: Bool, _ message: String = "Failed GPU check") {
        if !condition { fail(message) }
    }
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("Metal unavailable") }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let flow = try GameOpticalFlow(device: device, resourceFolder: resources, analysisDivisor: 1)
        func source(_ eyeWidth: Int, _ height: Int, _ shifts: [SIMD2<Int>], cut: Bool = false, object: Bool = false) -> MTLTexture {
            let width = eyeWidth * 2
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared; d.usage = .shaderRead
            let t = device.makeTexture(descriptor: d)!
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            func noise(_ x: Int, _ y: Int, _ eye: Int) -> UInt8 {
                var h = UInt32(truncatingIfNeeded: x &* 19_349_663 ^ y &* 73_856_093 ^ eye &* 83_492_791)
                h = (h ^ (h >> 13)) &* 1_274_126_177
                return UInt8(32 + ((h ^ (h >> 16)) % 192))
            }
            for y in 0..<height { for x in 0..<width {
                let eye = x / eyeWidth, local = x % eyeWidth
                let shift = shifts[eye]
                let u = (local - shift.x + eyeWidth) % eyeWidth, v = (y - shift.y + height) % height
                var value = noise(u / 2, v / 2, eye)
                if object {
                    let inside = u >= eyeWidth / 3 && u < eyeWidth * 2 / 3 && v >= height / 3 && v < height * 2 / 3
                    value = inside ? noise(u, v, eye) : 80
                }
                if cut { value = eye == 0 ? 0 : 255 }
                let at = (y * width + x) * 4
                bytes[at] = value; bytes[at + 1] = value; bytes[at + 2] = value
            }}
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
            return t
        }
        func read(_ texture: MTLTexture, _ cb: MTLCommandBuffer, bytesPerPixel: Int) -> MTLBuffer {
            let row = (texture.width * bytesPerPixel + 255) & ~255
            let buffer = device.makeBuffer(length: row * texture.height, options: .storageModeShared)!
            let b = cb.makeBlitCommandEncoder()!
            b.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                   to: buffer, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row * texture.height)
            b.endEncoding(); return buffer
        }
        func measure(_ shifts: [SIMD2<Int>], cut: Bool = false, object: Bool = false, anchorStrip: Bool = false) throws -> ([SIMD2<Float>], [UInt32], Double) {
            let previous = source(512, 512, [.zero, .zero], object: object)
            let current = source(512, 512, shifts, cut: cut, object: object)
            let cb = queue.makeCommandBuffer()!
            guard let result = flow.encode(previous: previous, current: current, commandBuffer: cb) else { fail("AMD encode failed") }
            let data = read(result.motion, cb, bytesPerPixel: 8), scd = read(result.sceneChange, cb, bytesPerPixel: 4)
            cb.commit(); cb.waitUntilCompleted()
            require(cb.status == .completed, "GPU failed: \(String(describing: cb.error))")
            let gw = result.motion.width / 2, gh = result.motion.height
            let row = ((result.motion.width * 8 + 255) & ~255) / 4
            let pixels = data.contents().assumingMemoryBound(to: Float.self)
            var medians: [SIMD2<Float>] = []
            for eye in 0..<2 {
                var xs: [Float] = [], ys: [Float] = []
                var area = object ? (gw / 3 + 2, gw * 2 / 3 - 2, gh / 3 + 2, gh * 2 / 3 - 2) : (gw / 4, gw * 3 / 4, gh / 4, gh * 3 / 4)
                if anchorStrip {
                    // These current-object blocks were empty background at the
                    // same coordinates in the previous image: sign alone cannot
                    // pass this check if vectors are indexed in the old frame.
                    area.0 = shifts[eye].x > 0 ? (512 * 2 / 3 + 8) / 8 : (512 / 3 - 24) / 8
                    area.1 = area.0 + 2
                }
                for y in area.2..<area.3 { for x in area.0..<area.1 {
                    let i = y * row + (eye * gw + x) * 2
                    require(pixels[i].isFinite && pixels[i + 1].isFinite)
                    xs.append(pixels[i]); ys.append(pixels[i + 1])
                }}
                xs.sort(); ys.sort(); medians.append(SIMD2(xs[xs.count / 2], ys[ys.count / 2]))
            }
            let flags = scd.contents().assumingMemoryBound(to: UInt32.self)
            return (medians, [flags[0], flags[1]], (cb.gpuEndTime - cb.gpuStartTime) * 1000)
        }
        var cases: [[String: Any]] = []
        for shifts in [[SIMD2<Int>.zero, .zero], [SIMD2(6, 0), SIMD2(-6, 0)], [SIMD2(0, 4), SIMD2(0, -4)]] {
            let (vectors, flags, ms) = try measure(shifts)
            print("SHIFT \(shifts) FLOW \(vectors) SCD \(flags) GPU \(ms)ms")
            for eye in 0..<2 {
                require(flags[eye] == 0, "Ordinary translation was classified as a scene cut")
                require(abs(vectors[eye].x - Float(shifts[eye].x)) <= 1 && abs(vectors[eye].y - Float(shifts[eye].y)) <= 1,
                             "AMD vector sign/units/stereo isolation incorrect")
            }
            cases.append(["shifts": shifts.map { [$0.x, $0.y] }, "median_flow": vectors.map { [$0.x, $0.y] }, "scene_change": flags, "gpu_ms": ms])
        }
        let objectShift = [SIMD2(8, 0), SIMD2(-8, 0)]
        let (objectFlow, objectFlags, objectMS) = try measure(objectShift, object: true)
        print("OBJECT FLOW \(objectFlow) SCD \(objectFlags)")
        for eye in 0..<2 {
            require(objectFlags[eye] == 0 && abs(objectFlow[eye].x - Float(objectShift[eye].x)) <= 1,
                         "Moving object flow is not indexed in current-object blocks")
        }
        cases.append(["object_shifts": objectShift.map { [$0.x, $0.y] }, "median_flow": objectFlow.map { [$0.x, $0.y] }, "gpu_ms": objectMS])
        let anchored = [SIMD2(32, 0), SIMD2(-32, 0)]
        let (anchorFlow, anchorFlags, _) = try measure(anchored, object: true, anchorStrip: true)
        print("CURRENT-ONLY STRIP FLOW \(anchorFlow) SCD \(anchorFlags)")
        for eye in 0..<2 {
            require(anchorFlags[eye] == 0 && abs(anchorFlow[eye].x - Float(anchored[eye].x)) <= 1,
                    "Flow is not indexed in the current-only moving-object strip")
        }
        let (_, cutFlags, _) = try measure([.zero, .zero], cut: true)
        require(cutFlags == [1, 1], "AMD scene cut did not suppress generation")

        // Each consumer copy is queued immediately after its computation. A
        // later pair may reuse the bank only after that consumer on this queue.
        var queued: [(MTLCommandBuffer, MTLBuffer, Int, Int, Int)] = []
        for step in 1...3 {
            let p = source(512, 512, [.zero, .zero])
            let c = source(512, 512, [SIMD2(step * 2, 0), SIMD2(-step * 2, 0)])
            let cb = queue.makeCommandBuffer()!
            guard let result = flow.encode(previous: p, current: c, commandBuffer: cb) else { fail("Queued AMD encode failed") }
            let copied = read(result.motion, cb, bytesPerPixel: 8)
            queued.append((cb, copied, result.motion.width, result.motion.height, step * 2))
            cb.commit()
        }
        queued.last!.0.waitUntilCompleted()
        for (cb, copied, width, height, expected) in queued {
            require(cb.status == .completed, "Queued bank reuse caused a GPU error")
            let pixels = copied.contents().assumingMemoryBound(to: Float.self)
            let row = ((width * 8 + 255) & ~255) / 4, gw = width / 2
            for eye in 0..<2 {
                var xs: [Float] = []
                for y in height / 4..<height * 3 / 4 { for x in gw / 4..<gw * 3 / 4 {
                    xs.append(pixels[y * row + (eye * gw + x) * 2])
                }}
                xs.sort(); require(abs(xs[xs.count / 2] - Float(eye == 0 ? expected : -expected)) <= 1,
                                   "A queued pair consumed another pair's optical flow")
            }
        }
        let wrongQueue = device.makeCommandQueue()!
        require(flow.encode(previous: source(512, 512, [.zero, .zero]), current: source(512, 512, [.zero, .zero]),
                            commandBuffer: wrongQueue.makeCommandBuffer()!) == nil, "Cross-queue bank reuse must fail closed")

        // Bounded real-size cost, no encoder/headset/game. Production divisor2.
        let full = try GameOpticalFlow(device: device, resourceFolder: resources)
        let p = source(2016, 2048, [.zero, .zero]), c = source(2016, 2048, [SIMD2(8, 0), SIMD2(-8, 0)])
        var timings: [Double] = []
        for i in 0..<9 {
            let cb = queue.makeCommandBuffer()!
            guard let result = full.encode(previous: p, current: c, commandBuffer: cb) else { fail("Full-size AMD encode failed") }
            let checkFlow = i == 0 ? read(result.motion, cb, bytesPerPixel: 8) : nil
            let checkCut = i == 0 ? read(result.sceneChange, cb, bytesPerPixel: 4) : nil
            cb.commit(); cb.waitUntilCompleted()
            require(cb.status == .completed, "Full-size AMD GPU failure")
            if let checkFlow, let checkCut {
                let floats = checkFlow.contents().assumingMemoryBound(to: Float.self)
                let gw = result.motion.width / 2, gh = result.motion.height
                let row = ((result.motion.width * 8 + 255) & ~255) / 4
                for y in 0..<gh { for x in 0..<result.motion.width {
                    require(floats[y * row + x * 2].isFinite && floats[y * row + x * 2 + 1].isFinite,
                            "Partial pyramid/edge blocks produced non-finite motion")
                }}
                for eye in 0..<2 {
                    var xs: [Float] = []
                    for y in gh / 4..<gh * 3 / 4 { for x in gw / 4..<gw * 3 / 4 {
                        xs.append(floats[y * row + (eye * gw + x) * 2])
                    }}
                    xs.sort(); require(abs(xs[xs.count / 2] - (eye == 0 ? 4 : -4)) <= 1,
                                       "Non-power-of-two pyramid sign/scale failed")
                }
                let flags = checkCut.contents().assumingMemoryBound(to: UInt32.self)
                require(flags[0] == 0 && flags[1] == 0)
            }
            if i > 0 { timings.append((cb.gpuEndTime - cb.gpuStartTime) * 1000) }
        }
        timings.sort()
        let median = (timings[3] + timings[4]) / 2
        let result: [String: Any] = ["passed": true, "device": device.name,
            "scope": "Actual AMD Optical Flow Metal compute; no game, headset, synthesis or encoder",
            "cases": cases, "scene_cut_flags": cutFlags, "current_only_strip_flow": anchorFlow.map { [$0.x, $0.y] },
            "queued_pairs_verified": 3, "cross_queue_rejected": true, "partial_edge_blocks_finite": true,
            "benchmark": ["input_per_eye": [2016, 2048], "analysis_per_eye": [1008, 1024], "gpu_ms": timings, "samples": timings.count, "median_ms": median]]
        if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("PASS: genuine AMD Metal zero/XY/object motion, signs/units/current anchoring, stereo separation, scene cuts; full-size median \(median)ms")
    }
}
