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
        func renderBytes(using selected: Renderer? = nil) -> [UInt8] {
            (selected ?? renderer).render(head: head, calibration: mouse.calibration, into: target, present: nil)
            var bytes = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
            target.getBytes(&bytes, bytesPerRow: outputWidth * 4,
                from: MTLRegionMake2D(0, 0, outputWidth, outputHeight), mipmapLevel: 0)
            return bytes
        }
        func sourceProjectionRestored(using selected: Renderer? = nil) -> Bool {
            guard let restored = (selected ?? renderer).projection else { return false }
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

        var surroundingsChecks: [String: Any]?
        if arguments.contains("--game-image-unseen-surroundings") {
            // A fresh renderer commits the fixture before its first frame; an already
            // rendered place would correctly spend several frames fading first.
            let surroundingsRenderer = try Renderer(device: device, eyeSize: outputHeight)
            surroundingsRenderer.distortionEnabled = false
            surroundingsRenderer.projection = original
            let bakesBefore = surroundingsRenderer.environmentBakePasses
            let geometryBefore = surroundingsRenderer.environmentGeometryPasses
            // Real geometry, not a mocked visibility predicate. Packed eight-float vertices
            // match PlaceVertex in the GPU shader; a red triangle would alter a visible room.
            let vertices: [Float] = [-1, 0, -2, 0, 0, 1, 0, 0,
                                      1, 0, -2, 0, 0, 1, 1, 0,
                                      0, 2, -2, 0, 0, 1, 0.5, 1]
            let indices: [UInt32] = [0, 1, 2]
            guard let vb = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride),
                  let ib = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride) else {
                throw CheckFailure.failed("Could not allocate the surroundings fixture")
            }
            let scene = Scene3D(name: "Unseen surroundings oracle", parts: [Scene3D.Part(
                vertices: vb, vertexOffset: 0, indices: ib, indexOffset: 0, indexCount: 3, indexType: .uint32,
                transform: matrix_identity_float4x4, baseColor: SIMD4(1, 0, 0, 1), emission: SIMD3(1, 0, 0), texture: nil)], triangles: 1)
            surroundingsRenderer.setEnvironment(1, texture: nil, scene: scene) // Dusk and a real mesh.
            let hiddenFirst = renderBytes(using: surroundingsRenderer)
            let hiddenSecond = renderBytes(using: surroundingsRenderer)
            try require(hiddenFirst == changed && hiddenSecond == changed,
                        "An unseen Dusk/mesh environment changed immersive pixels")
            try require(surroundingsRenderer.environmentBakePasses == bakesBefore && surroundingsRenderer.environmentGeometryPasses == geometryBefore,
                        "Immersive game encoded unseen environment work")
            try require(sourceProjectionRestored(using: surroundingsRenderer), "Hidden-place test changed the game projection")

            surroundingsRenderer.projection = nil
            surroundingsRenderer.videoSphere = VideoSphere(texture: source, projection: 0, stereo: 1,
                fisheyeFovDeg: 180, orientation: head.orientation)
            _ = renderBytes(using: surroundingsRenderer)
            _ = renderBytes(using: surroundingsRenderer)
            try require(surroundingsRenderer.environmentBakePasses == bakesBefore && surroundingsRenderer.environmentGeometryPasses == geometryBefore,
                        "Surrounding video encoded unseen environment work")
            surroundingsRenderer.videoSphere = nil
            _ = renderBytes(using: surroundingsRenderer)
            _ = renderBytes(using: surroundingsRenderer)
            try require(surroundingsRenderer.environmentBakePasses > bakesBefore && surroundingsRenderer.environmentGeometryPasses > geometryBefore,
                        "Returning home did not resume real environment work")
            surroundingsChecks = ["hidden_projection_pixels_exact": true, "hidden_bakes": 0,
                "hidden_geometry_passes": 0, "video_hidden_work_zero": true,
                "home_bake_resumed": true, "home_geometry_resumed": true,
                "bakes_after_return": surroundingsRenderer.environmentBakePasses - bakesBefore,
                "geometry_after_return": surroundingsRenderer.environmentGeometryPasses - geometryBefore]
        }

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
        var result: [String: Any] = [
            "scope": "Three synthetic frames through the actual Renderer; no game, runtime, headset or video encoder",
            "device": device.name,
            "config": ["fsr": settings.gameFSREnabled, "rcas": settings.gameSharpeningEnabled,
                       "sharpness": settings.gameSharpness, "render_percent_setting": settings.gameRenderPercent,
                       "input_percent": inputPercent, "flip": flipped, "colour_mode": colourName],
            "dimensions": ["input_per_eye": [input.width, input.height],
                           "fsr_target_per_eye": [GameImagePlan.targetWidth, GameImagePlan.targetHeight],
                           "compositor_per_eye": [outputWidth / 2, outputHeight], "output": [outputWidth, outputHeight]],
            "checks": ["cached_replay_exact": true, "new_sequence_updates_image": true,
                       "source_projection_restored": true, "rendered_frame_count": (surroundingsChecks == nil ? 3 : 9),
                       "changed_bytes_new_frame": changedBytes],
            "fingerprints_fnv1a64": ["first": fingerprint(first), "cached": fingerprint(replay), "new_frame": fingerprint(changed)],
            "files": ["first": outputURL.path, "new_frame": changedURL.path]
        ]
        if let surroundingsChecks { result["surroundings_checks"] = surroundingsChecks }
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: jsonURL)
        print("PASS: game-image compositor snapshot; cached replay exact, new frame updated, source projection restored")
        print("Wrote \(outputURL.path), \(changedURL.path), \(jsonURL.path)")
    } catch {
        FileHandle.standardError.write(Data("Game-image snapshot failed: \(error)\n".utf8))
        exit(1)
    }
}
