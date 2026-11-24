// Synthetic, bounded verification through the actual compositor. No AppDelegate, runtime,
// headset, permissions or persistent settings changes. Source rates here are test clocks,
// never a game-performance measurement.
import Foundation
import QuartzCore
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd
import Darwin

@MainActor
func runGameSpacewarpRenderSnapshot(path: String, arguments: [String]) {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    do {
        let settings = Settings.shared
        try require(settings.gameSpacewarpEnabled && settings.effectiveGameHalfFrameRate, "Enable Spacewarp and half rate with command-line UserDefaults overrides")
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(description: "No Metal device") }
        let full = arguments.contains("--game-spacewarp-full")
        let ew = full ? GameImagePlan.targetWidth : 512
        let eh = full ? GameImagePlan.targetHeight : 512
        let width = ew * 2, ow = 1024, oh = 512, step = max(8, min(32, ew / 32))
        let interval = 1.0 / 60.0
        let output = URL(fileURLWithPath: path), base = output.deletingPathExtension()
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        func png(_ bytes: [UInt8], _ url: URL) throws {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw Failure(description: "Could not encode output PNG") }
            CGImageDestinationAddImage(destination, image, nil)
            try require(CGImageDestinationFinalize(destination), "Could not save output PNG")
        }
        func exact(_ actual: [UInt8], _ expected: [UInt8], name: String) throws {
            guard actual != expected else { return }
            var count = 0, minX = ow, minY = oh, maxX = -1, maxY = -1
            for y in 0..<oh { for x in 0..<ow {
                let a = (y * ow + x) * 4
                if (0..<4).contains(where: { actual[a + $0] != expected[a + $0] }) {
                    count += 1; minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            } }
            let prefix = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-" + name)
            try png(actual, prefix.appendingPathExtension("actual.png"))
            try png(expected, prefix.appendingPathExtension("expected.png"))
            throw Failure(description: "\(name) changed \(count) pixels, bounds [\(minX),\(minY)]–[\(maxX),\(maxY)]; actual/expected PNGs saved")
        }
        let sourceDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: eh, mipmapped: false)
        sourceDescription.storageMode = .shared
        sourceDescription.usage = [.shaderRead, .pixelFormatView]
        guard let source = device.makeTexture(descriptor: sourceDescription),
              let sourceSRGB = source.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else {
            throw Failure(description: "Could not allocate source texture")
        }
        let outputDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ow, height: oh, mipmapped: false)
        outputDescription.storageMode = .shared; outputDescription.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: outputDescription) else { throw Failure(description: "Could not allocate output texture") }
        let renderer = try Renderer(device: device, eyeSize: oh)
        let baseline = try Renderer(device: device, eyeSize: oh)
        renderer.distortionEnabled = false; baseline.distortionEnabled = false
        let mouse = MouseLook()
        guard let head = mouse.pose(atHostNs: 0) else { throw Failure(description: "No synthetic head pose") }
        func tangents(_ eye: Eye) -> SIMD4<Float> {
            let f = Optics.fov(eye)
            return SIMD4(tan(f.left), tan(f.right), tan(f.up), tan(f.down))
        }
        var original = ProjectionLayer(texture: source, uvRect: SIMD4(0, 0, 1, 1), renderOrientation: head.orientation,
            renderPosition: head.position, tangents: (tangents(.left), tangents(.right)), srgbTexture: sourceSRGB,
            colourSpaces: .zero, gameImage: true, imageSequence: 1, imageTime: CACurrentMediaTime(),
            gameHalfRate: true, sourceFrameInterval: interval)
        func checkRestored(_ r: Renderer, _ wanted: ProjectionLayer?) throws {
            guard let wanted else { try require(r.projection == nil, "Nil source was not restored"); return }
            guard let p = r.projection else { throw Failure(description: "Source projection vanished") }
            try require(p.texture === wanted.texture && p.srgbTexture === wanted.srgbTexture && p.colourSpaces == wanted.colourSpaces &&
                p.uvRect == wanted.uvRect && p.renderOrientation.vector == wanted.renderOrientation.vector && p.renderPosition == wanted.renderPosition &&
                p.tangents.left == wanted.tangents.left && p.tangents.right == wanted.tangents.right && p.seeThrough == wanted.seeThrough &&
                p.gameImage == wanted.gameImage && p.imageSequence == wanted.imageSequence && p.imageTime == wanted.imageTime &&
                p.gameHalfRate == wanted.gameHalfRate && p.sourceFrameInterval == wanted.sourceFrameInterval &&
                p.gameCadenceEpoch == wanted.gameCadenceEpoch, "Compositor changed source projection metadata")
        }
        func render(_ r: Renderer, projection: ProjectionLayer?, at time: Double) throws -> [UInt8] {
            r.projection = projection
            r.lateTargetNs = Int64(time * 1e9)
            r.render(head: head, calibration: mouse.calibration, into: target, present: nil)
            try checkRestored(r, projection)
            var bytes = [UInt8](repeating: 0, count: ow * oh * 4)
            target.getBytes(&bytes, bytesPerRow: ow * 4, from: MTLRegionMake2D(0, 0, ow, oh), mipmapLevel: 0)
            return bytes
        }
        func reference(_ projection: ProjectionLayer, at time: Double) throws -> [UInt8] {
            var disabled = projection
            // A separate compositor with the same FSR/RCAS settings and an ineligible
            // Spacewarp projection is the off baseline; no UserDefaults writes are needed.
            disabled.gameHalfRate = false
            return try render(baseline, projection: disabled, at: time)
        }
        func pattern(_ revision: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 255, count: width * eh * 4)
            for y in 0..<eh { for x in 0..<width {
                let eye = x / ew, u = x % ew
                let shift = revision * step * (eye == 0 ? 1 : -1)
                let p = (u - shift + ew * 4) % ew
                let noise = ((p &* 73) ^ (y &* 151) ^ ((p / 11 + y / 7) &* 29)) & 63
                let a = (y * width + x) * 4
                let marker = p > ew / 4 && p < ew * 3 / 4 && y > eh / 4 && y < eh * 3 / 4
                bytes[a] = UInt8(marker ? (eye == 0 ? 210 + noise / 2 : 28 + noise / 4) : 20 + noise)
                bytes[a + 1] = UInt8(marker ? 190 + noise : 20 + noise)
                bytes[a + 2] = UInt8(marker ? (eye == 0 ? 28 + noise / 4 : 210 + noise / 2) : 20 + noise)
            } }
            return bytes
        }
        // CPU pattern generation must not consume the synthetic presentation window.
        let patterns = [pattern(0), pattern(1)]
        func upload(_ revision: Int) {
            let bytes = patterns[revision]
            bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, width, eh), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        }
        func centroids(_ bytes: [UInt8]) throws -> [Double] {
            var result: [Double] = []
            for eye in 0...1 {
                var total = 0.0, moment = 0.0
                for y in 0..<oh { for u in 0..<(ow / 2) {
                    let a = (y * ow + eye * ow / 2 + u) * 4
                    let b = Int(bytes[a]), g = Int(bytes[a + 1]), r = Int(bytes[a + 2])
                    if g > 140 && (eye == 0 ? r - b > 60 : b - r > 60) {
                        let weight = Double(g); total += weight; moment += Double(u) * weight
                    }
                } }
                try require(total > Double(ow * oh / 200), "Eye \(eye) lost its distinct moving marker")
                result.append(moment / total)
            }
            return result
        }
        renderer.prepareSpacewarpIfEnabled()
        let deadline = Date().addingTimeInterval(30)
        while !renderer.spacewarpPrepared {
            if let failure = renderer.spacewarpFailure { throw Failure(description: "AMD preparation failed: \(failure)") }
            try require(Date() < deadline, "AMD preparation exceeded 30 seconds")
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // Bounded warmup for driver pipeline compilation and optional FSR/RCAS. These
        // calls are outside the measured correctness window and are reported separately.
        let warmTime = CACurrentMediaTime()
        original.imageTime = warmTime
        upload(0)
        _ = try reference(original, at: warmTime)
        _ = try render(renderer, projection: original, at: warmTime)
        upload(1); original.imageSequence = 2; original.imageTime += interval
        let warmTarget = CACurrentMediaTime()
        _ = try render(renderer, projection: original, at: warmTarget)
        _ = try render(renderer, projection: original, at: warmTarget + interval / 2)
        // Keep the scene opaque and present while resetting eligibility. Rendering nil
        // would trigger the compositor's intentional game/environment scene fade.
        var ineligible = original; ineligible.gameHalfRate = false
        _ = try render(renderer, projection: ineligible, at: CACurrentMediaTime())
        let warmSource = renderer.spacewarpSourceFrames, warmGenerated = renderer.spacewarpGeneratedFrames

        let firstTarget = CACurrentMediaTime()
        upload(0); original.imageSequence = 10; original.imageTime = firstTarget
        let reference1 = try reference(original, at: firstTarget)
        let real1 = try render(renderer, projection: original, at: firstTarget)
        try exact(real1, reference1, name: "first-real")
        upload(1); original.imageSequence = 11; original.imageTime = firstTarget + interval
        let secondTarget = firstTarget + interval
        let reference2 = try reference(original, at: secondTarget)
        let real2 = try render(renderer, projection: original, at: secondTarget)
        try exact(real2, reference2, name: "second-real")
        try require(real1 != real2, "Source animation failed")
        let generated = try render(renderer, projection: original, at: secondTarget + interval / 2)
        let observedSource = renderer.spacewarpSourceFrames - warmSource
        let observedGenerated = renderer.spacewarpGeneratedFrames - warmGenerated
        try require(observedSource == 2 && observedGenerated == 1, "Actual compositor did not prepare2/source and generate1/repeat")
        try require(generated != real2, "Generated output is just the repeated real frame")
        let center1 = try centroids(real1), center2 = try centroids(real2), centerGenerated = try centroids(generated)
        for eye in 0...1 {
            let direction = eye == 0 ? 1.0 : -1.0
            let realMove = (center2[eye] - center1[eye]) * direction
            let extraMove = (centerGenerated[eye] - center2[eye]) * direction
            try require(realMove > 1 && extraMove > max(0.15, realMove * 0.05), "Generated marker moved in the wrong direction or not at all in eye \(eye)")
        }
        // An ineligible projection must remove temporal history. Keep the next source
        // timestamp contiguous, so cadence validation alone cannot clear stale history.
        ineligible = original; ineligible.gameHalfRate = false
        _ = try render(renderer, projection: ineligible, at: CACurrentMediaTime())
        let resetGenerated = renderer.spacewarpGeneratedFrames
        let resetTarget = CACurrentMediaTime()
        original.imageSequence = 20; original.imageTime += interval
        _ = try render(renderer, projection: original, at: resetTarget)
        let resetRepeat = try render(renderer, projection: original, at: resetTarget + interval / 2)
        try require(renderer.spacewarpGeneratedFrames == resetGenerated, "Projection reset reused old motion history")
        try exact(resetRepeat, reference2, name: "reset-repeat")

        // Replay cadence edits on a cached real image: no sequence, timestamp,
        // texture or pose update may be invented to make the reset succeed.
        func primeCached(_ sequence: UInt64) throws -> (ProjectionLayer, [UInt8]) {
            var layer = original
            layer.gameHalfRate = false
            _ = try render(renderer, projection: layer, at: CACurrentMediaTime())
            layer.gameHalfRate = true
            layer.sourceFrameInterval = interval
            layer.gameCadenceEpoch = sequence
            layer.imageSequence = sequence
            layer.imageTime = CACurrentMediaTime()
            upload(0)
            _ = try render(renderer, projection: layer, at: CACurrentMediaTime())
            layer.imageSequence += 1
            layer.imageTime += interval
            upload(1)
            let expected = try reference(layer, at: CACurrentMediaTime())
            let target = CACurrentMediaTime()
            _ = try render(renderer, projection: layer, at: target)
            let before = renderer.spacewarpGeneratedFrames
            _ = try render(renderer, projection: layer, at: target + interval / 2)
            try require(renderer.spacewarpGeneratedFrames == before + 1, "Live reset test was not primed with generated history")
            return (layer, expected)
        }
        func cachedReset(_ layer: ProjectionLayer, expected: [UInt8], name: String) throws {
            let prepared = renderer.spacewarpSourceFrames
            let generated = renderer.spacewarpGeneratedFrames
            let target = CACurrentMediaTime()
            let first = try render(renderer, projection: layer, at: target)
            let repeated = try render(renderer, projection: layer, at: target + layer.sourceFrameInterval / 2)
            try require(renderer.spacewarpSourceFrames == prepared + 1, "\(name): same cached source was not re-primed exactly once")
            try require(renderer.spacewarpGeneratedFrames == generated, "\(name): stale prediction survived the cadence edit")
            try exact(first, expected, name: name + "-first-real")
            try exact(repeated, expected, name: name + "-repeat-real")
        }
        var (intervalEdit, intervalReal) = try primeCached(100)
        // Smaller than the scheduler's jitter tolerance: the renderer must
        // still invalidate the GPU history on the actual metadata change.
        intervalEdit.sourceFrameInterval *= 1.02
        try cachedReset(intervalEdit, expected: intervalReal, name: "cached-interval-change")

        var (hiddenToggle, hiddenReal) = try primeCached(200)
        hiddenToggle.gameCadenceEpoch += 2 // off→on happened between render calls.
        try cachedReset(hiddenToggle, expected: hiddenReal, name: "cached-hidden-off-on")

        var (visibleToggle, visibleReal) = try primeCached(300)
        visibleToggle.gameHalfRate = false
        visibleToggle.gameCadenceEpoch += 1
        let beforeOff = renderer.spacewarpGeneratedFrames
        let off = try render(renderer, projection: visibleToggle, at: CACurrentMediaTime())
        try require(renderer.spacewarpGeneratedFrames == beforeOff, "Live half-off generated a frame")
        try exact(off, visibleReal, name: "cached-half-off-real")
        visibleToggle.gameHalfRate = true
        visibleToggle.gameCadenceEpoch += 1
        try cachedReset(visibleToggle, expected: visibleReal, name: "cached-visible-off-on")

        let realURL = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-real.png")
        try png(generated, output); try png(real2, realURL)
        let report: [String: Any] = [
            "scope": "Synthetic GPU compositor correctness only; no game FPS, latency or hardware validation",
            "device": device.name,
            "config": ["fsr": settings.gameFSREnabled, "rcas": settings.gameSharpeningEnabled, "spacewarp": settings.gameSpacewarpEnabled,
                       "input_per_eye": [ew, eh], "output_per_eye": [ow / 2, oh], "source_interval_seconds": interval],
            "checks": ["real_sources_pixel_identical": true, "generated_differs": true, "per_eye_direction": true,
                       "source_projection_restored": true, "ineligible_projection_discards_history": true,
                       "same_cached_sequence_interval_change_discards_history": true,
                       "hidden_half_off_on_epoch_discards_history": true,
                       "half_off_and_reenable_keep_real_pixels": true],
            "measured_window_counters": ["source": observedSource, "generated": observedGenerated],
            "warmup_counters": ["source": warmSource, "generated": warmGenerated],
            "marker_centroids": ["real1": center1, "real2": center2, "generated": centerGenerated],
            "files": ["generated": output.path, "real": realURL.path]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: base.appendingPathExtension("json"))
        print("PASS: actual AMD compositor generation,2real/1generated, exact real sources, restored projection; cached cadence edits and visible/hidden half-rate toggles reset history")
    } catch {
        FileHandle.standardError.write(Data("Spacewarp compositor snapshot failed: \(error)\n".utf8)); exit(1)
    }
}
