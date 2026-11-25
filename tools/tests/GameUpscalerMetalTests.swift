import Foundation
@preconcurrency import Metal

struct UpscalerCheckFailure: Error { let message: String }

@main
struct GameUpscalerMetalTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UpscalerCheckFailure(message: message) }
    }

    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw UpscalerCheckFailure(message: "A real Metal device is required")
        }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let upscaler = try GameUpscaler(device: device, resourceFolder: resources)

        func texture(eyeWidth: Int, height: Int, left: SIMD4<UInt8>, right: SIMD4<UInt8>,
                     gradient: Bool = false, srgb: Bool = false) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
                width: 2 * eyeWidth, height: height, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .pixelFormatView]
            guard let result = device.makeTexture(descriptor: descriptor) else {
                throw UpscalerCheckFailure(message: "Input texture allocation failed")
            }
            var bytes = [UInt8](repeating: 0, count: 2 * eyeWidth * height * 4)
            for y in 0..<height {
                for x in 0..<(2 * eyeWidth) {
                    var color = x < eyeWidth ? left : right
                    if gradient {
                        let stripe = (x % eyeWidth + y) % 7 < 3
                        color = SIMD4(stripe ? 240 : 12, UInt8((x * 17 + y * 31) % 256), stripe ? 20 : 220, 255)
                    }
                    let offset = (y * 2 * eyeWidth + x) * 4
                    for component in 0..<4 { bytes[offset + component] = color[component] }
                }
            }
            bytes.withUnsafeBytes { p in
                result.replace(region: MTLRegionMake2D(0, 0, 2 * eyeWidth, height), mipmapLevel: 0,
                               withBytes: p.baseAddress!, bytesPerRow: 2 * eyeWidth * 4)
            }
            return result
        }

        func run(_ source: MTLTexture, width: Int = 128, height: Int = 128,
                 strength: Float = 0.5, colour: SIMD2<UInt32> = .zero) throws -> (MTLTexture, [UInt8]) {
            guard let command = queue.makeCommandBuffer(),
                  let output = upscaler.encode(source: source, targetWidth: width, targetHeight: height,
                    sharpness: strength, colourSpaces: colour, commandBuffer: command) else {
                throw UpscalerCheckFailure(message: "Production encode rejected the test input")
            }
            let rowBytes = (output.width * 4 + 255) & ~255
            guard let memory = device.makeBuffer(length: rowBytes * output.height, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else {
                throw UpscalerCheckFailure(message: "Readback allocation failed")
            }
            blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: output.width, height: output.height, depth: 1),
                      to: memory, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                      destinationBytesPerImage: rowBytes * output.height)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            var bytes: [UInt8] = []; bytes.reserveCapacity(output.width * output.height * 4)
            let pointer = memory.contents().assumingMemoryBound(to: UInt8.self)
            for y in 0..<output.height {
                bytes.append(contentsOf: UnsafeBufferPointer(start: pointer.advanced(by: y * rowBytes), count: output.width * 4))
            }
            return (output, bytes)
        }

        var cases = 0
        for grey: UInt8 in [0, 1, 32, 128, 254, 255] {
            let input = try texture(eyeWidth: 80, height: 80,
                                    left: SIMD4(grey, grey, grey, 255), right: SIMD4(grey, grey, grey, 255))
            for sharpness: Float in [0, 0.5, 1] {
                let (_, bytes) = try run(input, strength: sharpness)
                try require(stride(from: 0, to: bytes.count, by: 4).allSatisfy { i in
                    abs(Int(bytes[i]) - Int(grey)) <= 2 && abs(Int(bytes[i + 1]) - Int(grey)) <= 2 &&
                    abs(Int(bytes[i + 2]) - Int(grey)) <= 2 && bytes[i + 3] == 255
                }, "Uniform \(grey) changed or black/white degenerated, strength \(sharpness)")
                cases += 1
            }
        }
        let eyes = try texture(eyeWidth: 80, height: 80,
                              left: SIMD4(255, 0, 0, 255), right: SIMD4(0, 0, 255, 255))
        for sharpness: Float in [0, 0.5, 1] {
            let (_, bytes) = try run(eyes, strength: sharpness)
            for y in 0..<128 {
                for x in 0..<256 {
                    let i = (y * 256 + x) * 4
                    try require(x < 128 ? (bytes[i] >= 253 && bytes[i + 2] <= 2) :
                                (bytes[i] <= 2 && bytes[i + 2] >= 253), "Stereo eye crossed at \(x),\(y)")
                }
            }
            cases += 1
        }
        let mixed = try texture(eyeWidth: 80, height: 80,
                               left: SIMD4(128, 128, 128, 255), right: SIMD4(188, 188, 188, 255))
        let (_, mixedBytes) = try run(mixed, colour: SIMD2(1, 2))
        try require(stride(from: 0, to: mixedBytes.count, by: 4).allSatisfy {
            abs(Int(mixedBytes[$0]) - 188) <= 2
        }, "Linear/sRGB eyes were not normalized exactly once")
        cases += 1
        let srgbInput = try texture(eyeWidth: 80, height: 80,
                                   left: SIMD4(128, 128, 128, 255), right: SIMD4(128, 128, 128, 255), srgb: true)
        let (_, encodedBytes) = try run(srgbInput, colour: SIMD2(2, 2))
        try require(stride(from: 0, to: encodedBytes.count, by: 4).allSatisfy {
            abs(Int(encodedBytes[$0]) - 128) <= 2
        }, "sRGB texture format was decoded a second time before FSR")
        cases += 1

        let identity = try texture(eyeWidth: 128, height: 128,
                                  left: SIMD4(128, 128, 128, 255), right: SIMD4(188, 188, 188, 255))
        let (returned, identityBytes) = try run(identity, strength: 0, colour: SIMD2(1, 2))
        try require(returned === identity && identityBytes[0] == 128,
                    "Same-size zero sharpening must bypass processing and retain source metadata")
        cases += 1
        let (downscale, _) = try run(identity, width: 100, height: 100)
        try require(downscale === identity, "A higher-resolution producer must not be silently downscaled")
        cases += 1
        let pattern = try texture(eyeWidth: 80, height: 80,
                                 left: SIMD4(0, 0, 0, 255), right: SIMD4(0, 0, 0, 255), gradient: true)
        let (_, patternBytes) = try run(pattern, strength: 1)
        try require(patternBytes.contains(240) && patternBytes.contains(12) &&
                    stride(from: 3, to: patternBytes.count, by: 4).allSatisfy { patternBytes[$0] == 255 },
                    "Edge reconstruction lost image range or opacity")
        cases += 1

        // Three queued frames reuse the actual bank in FIFO submission order.
        var queued: [MTLCommandBuffer] = []
        for _ in 0..<3 {
            guard let command = queue.makeCommandBuffer(),
                  upscaler.encode(source: pattern, targetWidth: 128, targetHeight: 128,
                                  sharpness: 0.5, commandBuffer: command) != nil else {
                throw UpscalerCheckFailure(message: "Queued encode failed")
            }
            command.commit(); queued.append(command)
        }
        queued.last!.waitUntilCompleted()
        try require(queued.allSatisfy { $0.status == .completed && $0.error == nil }, "Queued GPU processing failed")
        cases += 1
        print("PASS: \(cases) real Metal cases: flat/black/white, stereo boundary, transfers, exact bypass, larger source, edges and three queued frames")

        var timings: [[String: Any]] = []
        for percent in [80, 100] {
            let width = percent == 80 ? 1600 : 2016, height = percent == 80 ? 1632 : 2048
            let source = try texture(eyeWidth: width, height: height,
                                     left: SIMD4(128, 128, 128, 255), right: SIMD4(188, 188, 188, 255))
            var commands: [MTLCommandBuffer] = []
            // The first command warms allocations and is excluded from timing.
            for _ in 0..<21 {
                guard let command = queue.makeCommandBuffer(),
                      upscaler.encode(source: source, targetWidth: 2016, targetHeight: 2048,
                                      sharpness: 0.5, commandBuffer: command) != nil else {
                    throw UpscalerCheckFailure(message: "Benchmark encode failed")
                }
                command.commit(); commands.append(command)
            }
            commands.last!.waitUntilCompleted()
            try require(commands.allSatisfy { $0.error == nil }, "Benchmark GPU command failed")
            let values = commands.dropFirst().map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }.sorted()
            let row: [String: Any] = ["render_percent": percent, "input_per_eye": [width, height],
                                     "output_per_eye": [2016, 2048], "gpu_ms_median": values[values.count / 2],
                                     "gpu_ms_p95": values[Int(Double(values.count - 1) * 0.95)], "frames": values.count]
            timings.append(row)
            print("FSR\(percent)% \(width)×\(height) → 2016×2048/eye: \(row["gpu_ms_median"]!) ms median, \(row["gpu_ms_p95"]!) ms p95")
        }
        if CommandLine.arguments.count > 2 {
            let data = try JSONSerialization.data(withJSONObject: ["passed": true, "metal_cases": cases,
                "scope": "Actual isolated Metal FSR processing; no game, video encoder or physical headset benchmark",
                "device": device.name, "timings": timings], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
    }
}
