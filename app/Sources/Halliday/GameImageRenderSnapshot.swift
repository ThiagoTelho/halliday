// Bounded, synthetic game-image verification through the real compositor. This
// entry point runs before the application, runtimes or headset sessions start.
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
import Darwin

@MainActor
func runGameImageRenderSnapshot(path: String, arguments: [String]) {
    enum CheckFailure: Error, CustomStringConvertible {
        case failed(String)
        var description: String {
            switch self { case .failed(let message): return message }
        }
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    func fingerprint(_ bytes: [UInt8]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    do {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CheckFailure.failed("No Metal device") }
        let inputPercent = Settings.validGameRenderPercent(Int(value("--game-image-input-percent") ?? "80") ?? 80)
        let input = GameImagePlan.renderSize(percent: inputPercent)
        let flipped = arguments.contains("--game-image-flip")
        let colourName = value("--game-image-colour-mode") ?? "legacy"
        let colourSpaces: SIMD2<UInt32>
        switch colourName {
        case "legacy", "0": colourSpaces = .zero
        case "linear", "1": colourSpaces = SIMD2(repeating: 1)
        case "srgb", "2": colourSpaces = SIMD2(repeating: 2)
        case "mixed": colourSpaces = SIMD2(1, 2)
        default: throw CheckFailure.failed("Unknown --game-image-colour-mode: \(colourName)")
        }
        let width = input.width * 2, height = input.height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .pixelFormatView]
        guard let source = device.makeTexture(descriptor: descriptor),
              let sourceSRGB = source.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
            throw CheckFailure.failed("Could not allocate the synthetic game source")
        }

        // Fine stripes, a checkerboard, slanted edges and gradients expose both
        // EASU and RCAS. Distinct eye colours also expose stereo-seam mistakes.
        func pattern(revision: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let eye = x / input.width, u = x % input.width
                    let gradient = u * 96 / max(1, input.width - 1)
                    let grid = ((u / 7 + y / 7) & 1) * 48
                    let stripe = ((u + y / 2) % 11 < 3) ? 60 : 0
                    var r = eye == 0 ? 76 + gradient : 24 + grid
                    var g = 32 + grid + stripe
                    var b = eye == 0 ? 24 + grid : 76 + gradient
                    if abs(u - y * input.width / max(1, height)) < 3 { r = 242; g = 230; b = 64 }
                    if y < height / 12 { r = eye == 0 ? 220 : 28; g = 36; b = eye == 0 ? 28 : 220 }
                    if revision > 0, u > input.width / 4, u < input.width * 3 / 4,
                       y > height / 3, y < height * 2 / 3 {
                        r = 40 + grid; g = 220 - stripe; b = eye == 0 ? 220 : 40
                    }
                    let at = (y * width + x) * 4
                    bytes[at] = UInt8(r); bytes[at + 1] = UInt8(g); bytes[at + 2] = UInt8(b)
                }
            }
            return bytes
        }
        func upload(_ bytes: [UInt8]) {
            bytes.withUnsafeBytes { raw in
                source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                               withBytes: raw.baseAddress!, bytesPerRow: width * 4)
            }
        }
        upload(pattern(revision: 0))

        // A small undistorted stereo output keeps the test bounded while the
        // actual game-image pass still processes its normal 2016×2048 target.
        let outputWidth = 2048, outputHeight = 1024
        let renderer = try Renderer(device: device, eyeSize: outputHeight)
        renderer.distortionEnabled = false
        let mouse = MouseLook()
        guard let head = mouse.pose(atHostNs: 0) else { throw CheckFailure.failed("No synthetic head pose") }
        func tangents(_ eye: Eye) -> SIMD4<Float> {
            let fov = Optics.fov(eye)
            return SIMD4(tan(fov.left), tan(fov.right), tan(fov.up), tan(fov.down))
        }
        var original = ProjectionLayer(texture: source,
            uvRect: flipped ? SIMD4(0, 1, 1, -1) : SIMD4(0, 0, 1, 1),
            renderOrientation: head.orientation, renderPosition: head.position,
            tangents: (tangents(.left), tangents(.right)), srgbTexture: sourceSRGB,
            colourSpaces: colourSpaces, gameImage: true, imageSequence: 1)
        renderer.projection = original
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: outputWidth, height: outputHeight, mipmapped: false)
        targetDescriptor.storageMode = .shared
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: targetDescriptor) else {
            throw CheckFailure.failed("Could not allocate the offscreen output")
        }
        func renderBytes() -> [UInt8] {
            renderer.render(head: head, calibration: mouse.calibration, into: target, present: nil)
            var bytes = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
            target.getBytes(&bytes, bytesPerRow: outputWidth * 4,
                from: MTLRegionMake2D(0, 0, outputWidth, outputHeight), mipmapLevel: 0)
            return bytes
        }
        func sourceProjectionRestored() -> Bool {
            guard let restored = renderer.projection else { return false }
            return restored.texture === source && restored.srgbTexture === sourceSRGB
                && restored.colourSpaces == original.colourSpaces && restored.uvRect == original.uvRect
                && restored.renderOrientation.vector == original.renderOrientation.vector
                && restored.renderPosition == original.renderPosition
                && restored.tangents.left == original.tangents.left && restored.tangents.right == original.tangents.right
                && !restored.seeThrough && restored.gameImage && restored.imageSequence == original.imageSequence
        }
        let first = renderBytes()
        try require(sourceProjectionRestored(), "The renderer did not restore the original source projection")
        let replay = renderBytes()
        try require(first == replay, "A repeated game frame changed its output bytes")
        try require(sourceProjectionRestored(), "Cached replay changed the source projection")
        upload(pattern(revision: 1)) // The previous offscreen render waited for completion.
        original.imageSequence = 2
        renderer.projection = original
        let changed = renderBytes()
        try require(first != changed, "A new image sequence did not update the rendered game image")
        try require(sourceProjectionRestored(), "The new game frame changed the source projection metadata")

        let outputURL = URL(fileURLWithPath: path)
        let baseURL = outputURL.deletingPathExtension()
        let changedURL = baseURL.deletingLastPathComponent().appendingPathComponent(baseURL.lastPathComponent + "-new-frame.png")
        let jsonURL = outputURL.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        func writePNG(_ bytes: [UInt8], to url: URL) throws {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: outputWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL,
                    UTType.png.identifier as CFString, 1, nil) else {
                throw CheckFailure.failed("Could not encode \(url.path)")
            }
            CGImageDestinationAddImage(destination, image, nil)
            try require(CGImageDestinationFinalize(destination), "Could not save \(url.path)")
        }
        try writePNG(first, to: outputURL)
        try writePNG(changed, to: changedURL)
        let settings = Settings.shared
        let changedBytes = zip(first, changed).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        let result: [String: Any] = [
            "scope": "Three synthetic frames through the actual Renderer; no game, runtime, headset or video encoder",
            "device": device.name,
            "config": ["fsr": settings.gameFSREnabled, "rcas": settings.gameSharpeningEnabled,
                       "sharpness": settings.gameSharpness, "render_percent_setting": settings.gameRenderPercent,
                       "input_percent": inputPercent, "flip": flipped, "colour_mode": colourName],
            "dimensions": ["input_per_eye": [input.width, input.height],
                           "fsr_target_per_eye": [GameImagePlan.targetWidth, GameImagePlan.targetHeight],
                           "compositor_per_eye": [outputWidth / 2, outputHeight], "output": [outputWidth, outputHeight]],
            "checks": ["cached_replay_exact": true, "new_sequence_updates_image": true,
                       "source_projection_restored": true, "rendered_frame_count": 3,
                       "changed_bytes_new_frame": changedBytes],
            "fingerprints_fnv1a64": ["first": fingerprint(first), "cached": fingerprint(replay), "new_frame": fingerprint(changed)],
            "files": ["first": outputURL.path, "new_frame": changedURL.path]
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL)
        print("PASS: game-image compositor snapshot; cached replay exact, new frame updated, source projection restored")
        print("Wrote \(outputURL.path), \(changedURL.path), \(jsonURL.path)")
    } catch {
        FileHandle.standardError.write(Data("Game-image snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}
