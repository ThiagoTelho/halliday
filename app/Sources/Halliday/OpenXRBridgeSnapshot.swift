// Isolated, bounded GameSide → C ABI → GameBridge → Renderer acceptance oracle.
// Runs before AppDelegate, input, headset discovery or permission requests.
import AppKit
import CHallidayCore
import Foundation
import Metal
import simd

@MainActor
func runOpenXRBridgeSnapshot(path: String, arguments: [String]) {
    struct Failure: Error { let message: String }
    func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }
    var producer: Process?
    var game: GameBridge?
    var input: FileHandle?
    defer {
        try? input?.write(contentsOf: Data("quit\n".utf8))
        try? input?.close()
        if let producer, producer.isRunning { producer.terminate(); producer.waitUntilExit() }
        game?.close()
    }
    do {
        try require(Bundle.main.bundleIdentifier?.contains(".openxr-panel-acceptance.") == true &&
            RuntimePaths.folderName.hasPrefix("Halliday OpenXR Panel Acceptance "), "Requires a unique private acceptance bundle/support folder")
        try require(arguments.contains("--copy-frames"), "Acceptance must never create a virtual display or screen capture")
        try require(NativeOpenXRSupport.selectedBackend == .halliday, "Acceptance must use the independent public bridge")
        let settings = Settings.shared
        try require(!settings.gameFSREnabled && !settings.gameSharpeningEnabled &&
            !settings.gameHalfFrameRate && settings.gameRenderPercent == 100, "Use command-line image defaults for the pixel oracle")
        guard let producerPath = value("--panel-producer"), let device = MTLCreateSystemDefaultDevice() else {
            throw Failure(message: "Missing fixture producer or Metal device")
        }
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let renderer = try Renderer(device: device, eyeSize: 128)
        renderer.distortionEnabled = false
        let mouse = MouseLook()
        let physicalHz = value("--panel-display-hz").flatMap(Float.init) ?? 90
        try require([Float(90), 120].contains(physicalHz), "Use a bounded 90 or 120 Hz cadence fixture")
        guard let head = mouse.pose(atHostNs: 0),
              let bridge = GameBridge(device: device, queue: renderer.commandQueue, displayHz: physicalHz) else {
            throw Failure(message: "Could not create isolated game host")
        }
        game = bridge
        _ = bridge.tick(head: head)
        let child = Process(), request = Pipe(), response = Pipe()
        child.executableURL = URL(fileURLWithPath: producerPath)
        child.arguments = [GameBridge.folder.appendingPathComponent("halliday-bridge.shm").path]
        child.standardInput = request; child.standardOutput = response
        try child.run(); producer = child; input = request.fileHandleForWriting
        func readReply() throws -> [String: Any] {
            var bytes = Data()
            while bytes.count < 4096 {
                guard let byte = try response.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else {
                    throw Failure(message: "Fixture producer closed its reply pipe")
                }
                if byte.first == 10 { break }
                bytes.append(byte)
            }
            guard let reply = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                throw Failure(message: "Invalid producer reply")
            }
            return reply
        }
        try require(try readReply()["ready"] as? Bool == true, "Producer did not register")
        func command(_ name: String) throws -> [String: Any] {
            try request.fileHandleForWriting.write(contentsOf: Data((name + "\n").utf8))
            return try readReply()
        }
        func pump() {
            if let done = renderer.commandQueue.makeCommandBuffer() { done.commit(); done.waitUntilCompleted() }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        func frame(after old: UInt64?) throws -> ProjectionLayer {
            let deadline = Date(timeIntervalSinceNow: 2)
            while Date() < deadline {
                if let p = bridge.tick(head: head)?.projection, old == nil || p.imageSequence != old! { pump(); return p }
                pump()
            }
            throw Failure(message: "No new complete bridge frame")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { throw Failure(message: "Offscreen allocation") }
        func render(_ projection: ProjectionLayer) -> [UInt8] {
            renderer.projection = projection; renderer.gameLayers = []; renderer.gameSkybox = nil
            renderer.gameFade = .zero; renderer.gameBackgroundFade = .zero
            renderer.render(head: head, calibration: mouse.calibration, into: target, present: nil)
            var bytes = [UInt8](repeating: 0, count: 256 * 128 * 4)
            target.getBytes(&bytes, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0)
            return bytes
        }
        func display(_ linear: Double) -> Int {
            Int((255 * (linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055)).rounded())
        }
        func pixel(_ bytes: [UInt8], eye: Int, expected: [Int], name: String) throws -> [Int] {
            let at = (64 * 256 + eye * 128 + 64) * 4
            let rgb = [Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at])]
            try require(zip(rgb, expected).allSatisfy { abs($0.0 - $0.1) <= 3 }, "\(name) eye\(eye) got\(rgb), expected\(expected)")
            return rgb
        }
        var rows: [[String: Any]] = []
        var lastSequence: UInt64?
        let a = 128.0 / 255
        for name in ["layered", "premult", "quad-only", "projection", "clear"] {
            let reply = try command(name)
            try require(reply["published"] as? Bool == true, "Publication failed: \(name)")
            let source = try frame(after: lastSequence); lastSequence = source.imageSequence
            let bytes = render(source)
            let left: [Int], right: [Int]
            switch name {
            case "layered", "premult":
                left = [display((1-a)*(1-a)), display(a), display(a*(1-a))]; right = [255,255,0]
                try require(source.composition?.panels.count == 3 && source.composition?.projectionIndex == 1,
                    "Lost declaration order while consuming C ABI")
            case "quad-only": left = [0,255,0]; right = [255,255,0]
                try require(source.composition?.projectionIndex == nil && source.composition?.panels.count == 2, "Quad-only batch lost")
            case "projection": left = [display(10.0/255),display(20.0/255),display(200.0/255)]; right = [0,display(200.0/255),display(200.0/255)]
                try require(source.composition == nil,
                    "Normal projection did not clear old quads")
            default: left = [0,0,0]; right = [0,0,0]
                try require(source.composition?.panels.isEmpty == true && source.composition?.projectionIndex == nil, "Empty frame retained layers")
            }
            let l = try pixel(bytes, eye: 0, expected: left, name: name)
            let r = try pixel(bytes, eye: 1, expected: right, name: name)
            rows.append(["case": name, "passed": true, "left": l, "right": r])
        }
        _ = try command("projection")
        let stable = try frame(after: lastSequence); lastSequence = stable.imageSequence
        let original = render(stable)
        let busy = try command("busy")
        try require(busy["published"] as? Bool == false, "Busy host pixels were overwritten")
        for _ in 0..<3 { _ = bridge.tick(head: head); pump() }
        try require(render(bridge.tick(head: head)?.projection ?? stable) == original, "Busy publication changed complete scene")
        rows.append(["case": "busy-picture-drop", "passed": true])
        _ = try command("stale")
        for _ in 0..<3 { _ = bridge.tick(head: head); pump() }
        guard let retained = bridge.tick(head: head)?.projection else { throw Failure(message: "Stale quad discarded the previous valid frame") }
        try require(retained.imageSequence == stable.imageSequence && render(retained) == original,
            "Stale picture sequence partially replaced a complete host frame")
        rows.append(["case": "stale-picture-retains-complete-frame", "passed": true])
        _ = try command("restart")
        _ = bridge.tick(head: head); pump()
        try require(!bridge.isPresenting, "A new epoch was presented before its first frame")
        _ = try command("projection")
        let restarted = try frame(after: lastSequence)
        let restartedBytes = render(restarted)
        try require(restartedBytes == original && restarted.composition == nil,
            "Same-PID restart kept an old panel or rejected frame one")
        rows.append(["case": "same-pid-new-epoch", "passed": true])
        _ = try command("gradient")
        let gradient = try frame(after: restarted.imageSequence)
        let gradientBytes = render(gradient)
        _ = try command("geometry-default")
        let calibrated = try frame(after: gradient.imageSequence)
        try require(calibrated.eyeViews == nil && render(calibrated) == gradientBytes,
            "Calibrated per-eye metadata changed legacy image sampling")
        rows.append(["case": "calibrated-geometry-bit-identical", "passed": true])
        // Independent CPU ray/texture oracle. The fixture publishes a quantized
        // gradient, so camera changes cannot pass as they could with solid colors.
        func geometryPixels(_ projection: ProjectionLayer, name: String) throws -> Int {
            guard let views = projection.eyeViews else { throw Failure(message: "Missing custom camera: \(name)") }
            let bytes = render(projection)
            var maximumError = 0
            var covered = [0, 0]
            func channel(_ coordinate: Float) -> Double {
                let texel = max(0, min(63, Double(coordinate) * 64 - 0.5))
                let lower = floor(texel), upper = min(63, lower + 1), fraction = texel - lower
                let low = (lower * 255 / 63).rounded(), high = (upper * 255 / 63).rounded()
                return (low * (1 - fraction) + high * fraction) / 255
            }
            for eye in 0..<2 {
                let optical = Optics.fov(eye == 0 ? .left : .right)
                let fov = SIMD4(tan(optical.left), tan(optical.right), tan(optical.up), tan(optical.down))
                let camera = views.view(eye)
                let currentEye = head.position + head.orientation.act(SIMD3<Float>((eye == 0 ? -0.5 : 0.5) * renderer.ipd, 0, 0))
                for y in [24, 64, 104] {
                    for x in [24, 64, 104] {
                        let u = (Float(x) + 0.5) / 128, v = (Float(y) + 0.5) / 128
                        let tx = fov.x + (fov.y - fov.x) * u
                        let ty = fov.z + (fov.w - fov.z) * v
                        let direction = simd_normalize(head.orientation.act(SIMD3(tx, ty, -1)))
                        let shifted = simd_normalize(direction * Renderer.reprojectionDepth + currentEye - camera.position)
                        let ray = camera.orientation.inverse.act(shifted)
                        let uv = SIMD2((ray.x / -ray.z - camera.tangents.x) / (camera.tangents.y - camera.tangents.x),
                            (camera.tangents.z - ray.y / -ray.z) / (camera.tangents.z - camera.tangents.w))
                        let inside = ray.z < -0.0001 && uv.x >= 0 && uv.x <= 1 && uv.y >= 0 && uv.y <= 1
                        let expected = inside ? [display(channel(uv.x)), display(channel(uv.y)), display(Double(eye == 0 ? 160 : 80) / 255)] : [0, 0, 0]
                        if inside { covered[eye] += 1 }
                        let at = (y * 256 + eye * 128 + x) * 4
                        let actual = [Int(bytes[at + 2]), Int(bytes[at + 1]), Int(bytes[at])]
                        let error = zip(actual, expected).map { abs($0.0 - $0.1) }.max() ?? 0
                        maximumError = max(maximumError, error)
                        try require(error <= 4, "\(name) eye\(eye) at\(x),\(y): got\(actual), expected\(expected), uv\(uv)")
                    }
                }
            }
            try require(covered.allSatisfy { $0 >= 3 }, "Geometry oracle did not cover both eyes")
            return maximumError
        }
        var custom = calibrated
        for name in ["geometry-zoom", "geometry-canted", "geometry-shift"] {
            _ = try command(name)
            custom = try frame(after: custom.imageSequence)
            let error = try geometryPixels(custom, name: name)
            rows.append(["case": name, "passed": true, "maximum_channel_error": error])
        }
        let customBytes = render(custom)
        _ = try command("geometry-stale")
        for _ in 0..<3 { _ = bridge.tick(head: head); pump() }
        guard let kept = bridge.tick(head: head)?.projection else { throw Failure(message: "Invalid required geometry discarded the previous frame") }
        try require(kept.imageSequence == custom.imageSequence && render(kept) == customBytes,
            "Invalid required geometry partially replaced a complete frame")
        rows.append(["case": "stale-geometry-retains-complete-frame", "passed": true])
        _ = try command("gradient")
        let restored = try frame(after: custom.imageSequence)
        try require(restored.eyeViews == nil && render(restored) == gradientBytes,
            "Legacy frame inherited stale custom geometry")
        rows.append(["case": "custom-to-legacy-bit-identical", "passed": true])
        let completeBytes = render(restored)
        for name in ["batch-stale", "batch-epoch", "batch-missing", "empty-batch-stale", "alpha-batch-stale"] {
            _ = try command(name)
            for _ in 0..<3 { _ = bridge.tick(head: head); pump() }
            guard let retained = bridge.tick(head: head)?.projection else { throw Failure(message: "\(name) discarded the complete frame") }
            try require(retained.imageSequence == restored.imageSequence && render(retained) == completeBytes,
                "\(name) fell back to a partial/ordinary projection")
            rows.append(["case": name + "-retains-complete-frame", "passed": true])
        }
        _ = try command("batch-legacy")
        let legacy = try frame(after: restored.imageSequence)
        try require(legacy.composition == nil, "Legacy projection inherited old batch state")
        _ = try pixel(render(legacy), eye: 0, expected: [display(10.0/255),display(20.0/255),display(200.0/255)], name: "legacy without optional batch")
        rows.append(["case": "legacy-without-optional-batch", "passed": true])
        // Exercise the same final pointer selection used by frameTick, rather
        // than hiding the beam only inside this offscreen fixture.
        let pointerFree = render(legacy)
        let direction = head.orientation.act(SIMD3<Float>(0, 0, -1))
        let menuPointer = Saber(start: head.position + SIMD3(0.1, -0.1, -0.25),
            end: head.position + SIMD3(0, 0, -1.5), landsOnSurface: true, mode: .overTarget, fromHand: true)
        renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: false, gameOverlay: nil)
        try require(renderer.saber != nil && renderer.cursorDirection != nil && render(legacy) != pointerFree,
            "Menu pointer fixture did not draw a visible beam/ring")
        renderer.projection = nil // Loading still belongs to the game.
        renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: true, gameOverlay: nil)
        try require(renderer.saber == nil && renderer.cursorDirection == nil && render(legacy) == pointerFree,
            "Menu pointer survived entry into a game/loading state")
        rows.append(["case": "game-clears-menu-beam-and-ring-including-loading", "passed": true])
        var overlayImages: [[UInt8]] = []
        for side: Float in [-1, 1] {
            let overlay = Saber(start: head.position + SIMD3(side * 0.2, -0.1, -0.3),
                end: head.position + SIMD3(side * 0.15, 0, -1.5), landsOnSurface: true, mode: .pressed, fromHand: true)
            renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: true, gameOverlay: overlay)
            try require(renderer.cursorDirection == nil && renderer.saber?.start == overlay.start
                && renderer.saber?.end == overlay.end && renderer.saber?.fromHand == true,
                "Explicit game-overlay pointer lost its hand/surface or gained a head ring")
            let image = render(legacy)
            try require(image != pointerFree, "Explicit game-overlay beam disappeared")
            overlayImages.append(image)
        }
        try require(overlayImages[0] != overlayImages[1], "Overlay beam failed to follow the changed hand/surface")
        rows.append(["case": "game-overlay-pointer-follows-both-hands-without-head-ring", "passed": true])
        renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: true, gameOverlay: nil)
        try require(renderer.saber == nil && renderer.cursorDirection == nil && render(legacy) == pointerFree,
            "A departed game overlay left a stale pointer")
        rows.append(["case": "departed-game-overlay-clears-pointer", "passed": true])
        renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: false, gameOverlay: nil)
        try require(renderer.saber?.start == menuPointer.start && renderer.cursorDirection == direction
            && render(legacy) != pointerFree, "Opening the dashboard did not restore its pointer")
        rows.append(["case": "dashboard-restores-menu-pointer", "passed": true])
        for _ in 0..<6 {
            renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: true, gameOverlay: nil)
            try require(renderer.saber == nil && renderer.cursorDirection == nil && render(legacy) == pointerFree,
                "Returning to the game left a menu pointer")
            renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: false, gameOverlay: nil)
            try require(renderer.saber != nil && renderer.cursorDirection != nil, "Repeated dashboard entry lost its pointer")
        }
        renderer.setInterfacePointer(menuPointer, direction: direction, gameActive: true, gameOverlay: nil)
        rows.append(["case": "repeated-game-dashboard-pointer-transitions", "passed": true, "cycles": 6])
        try require(!bridge.framesDisplayRequested,
            "Independent OpenXR unnecessarily entered legacy virtual-display setup")
        rows.append(["case": "independent-skips-legacy-window-display", "passed": true])
        for pressure: Float in [0, 0.25, 0.6, 0.75, 1] {
            for click in [false, true] {
                bridge.realHands = (0..<2).map { _ in GameBridge.RealHand(
                    position: head.position, orientation: head.orientation, trigger: pressure, triggerPressed: click,
                    grip: false, stick: .zero, stickClick: false, stickTouch: false, lower: false, upper: false, menu: false) }
                _ = bridge.tick(head: head)
                let input = try command("input-state")
                guard let values = input["triggers"] as? [Double], let pressed = input["pressed"] as? [Bool],
                      let touched = input["touched"] as? [Bool] else { throw Failure(message: "Missing input observation") }
                try require(values.count == 2 && values.allSatisfy { abs($0 - Double(pressure)) < 0.000001 },
                    "Digital trigger promoted measured travel: \(values), pressure\(pressure), click\(click)")
                try require(pressed == [Bool](repeating: click || pressure > 0.6, count: 2)
                    && touched == [Bool](repeating: click || pressure > 0.02, count: 2),
                    "Analog preservation changed existing click/touch policy")
            }
        }
        rows.append(["case": "both-hand-analog-trigger-preserved-with-click", "passed": true, "input_states": 20])
        _ = try command("projection")
        let freshLiveImage = try frame(after: legacy.imageSequence)
        let liveStart = try command("cadence-state")
        let inode = try FileManager.default.attributesOfItem(atPath: GameBridge.folder.appendingPathComponent("halliday-bridge.shm").path)[.systemFileNumber] as? NSNumber
        let originalFrameTarget = HeadsetView.frameTarget
        defer { HeadsetView.frameTarget = originalFrameTarget }
        var savedLayer = freshLiveImage
        var simulatedTarget = CACurrentMediaTime()
        var phases: [[String: Any]] = []
        for half in [false, true, false, true, false] {
            let priorEpoch = savedLayer.gameCadenceEpoch
            let changed = bridge.halfFrameRate != half
            try require(bridge.setHalfFrameRate(half), "Independent live cadence unexpectedly deferred")
            let immediate = try command("cadence-state")
            let expectedInterval = 1 / Double(physicalHz / (half ? 2 : 1))
            try require(abs((immediate["interval_ns"] as? Double ?? 0) * 1e-9 - expectedInterval) < 1e-8,
                "A waiting runtime did not receive the new cadence immediately")
            let before = try command("cadence-state")
            for _ in 1...6 {
                simulatedTarget += 1 / Double(physicalHz)
                let target = simulatedTarget
                while CACurrentMediaTime() < target { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.0005)) }
                HeadsetView.frameTarget = target
                guard let cached = bridge.tick(head: head)?.projection else { throw Failure(message: "Live cadence discarded the game image") }
                try require(cached.imageSequence == savedLayer.imageSequence && cached.imageTime == savedLayer.imageTime
                    && cached.texture === savedLayer.texture && cached.renderPosition == savedLayer.renderPosition
                    && cached.renderOrientation.vector == savedLayer.renderOrientation.vector,
                    "Live cadence recreated or moved the cached source image")
                try require(cached.gameHalfRate == half && abs(cached.sourceFrameInterval - expectedInterval) < 1e-10,
                    "Cached projection retained its old cadence")
                try require(cached.gameCadenceEpoch == priorEpoch + (changed ? 1 : 0),
                    "Cadence history tag did not change exactly once")
                savedLayer = cached
            }
            let after = try command("cadence-state")
            let wakes = (after["notifications"] as! Int) - (before["notifications"] as! Int)
            let publications = ((after["state_sequence"] as! Int) - (before["state_sequence"] as! Int)) / 2
            try require(wakes == (half ? 3 : 6) && publications == 6,
                "Cadence did not preserve full-rate poses: wakes\(wakes), poses\(publications), half\(half)")
            for key in ["epoch", "mapping", "eye_width", "eye_height", "frames", "reference_epoch"] {
                try require((after[key] as? NSNumber) == (liveStart[key] as? NSNumber), "Live cadence changed \(key)")
            }
            try require((try FileManager.default.attributesOfItem(atPath: GameBridge.folder.appendingPathComponent("halliday-bridge.shm").path)[.systemFileNumber] as? NSNumber) == inode,
                "Live cadence replaced the public bridge file")
            phases.append(["half": half, "game_hz": physicalHz / (half ? 2 : 1), "pose_publications": publications, "game_notifications": wakes])
        }
        rows.append(["case": "live-half-rate-same-client-mapping-image-and-full-rate-poses", "passed": true,
            "physical_hz": physicalHz, "phases": phases])
        let report: [String: Any] = ["passed": true, "scope": "Real GameSide publication → C ABI claims → GameBridge GPU copies → actual Renderer, offscreen synthetic pixels; no headset/game/performance claim",
            "device": device.name, "bundle": Bundle.main.bundleIdentifier ?? "", "support": RuntimePaths.support.path,
            "cases": rows]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("PASS: integrated OpenXR panel bridge/compositor \(rows.count) cases → \(path)")
    } catch {
        try? input?.close()
        if let producer, producer.isRunning { producer.terminate(); producer.waitUntilExit() }
        game?.close()
        FileHandle.standardError.write(Data("Integrated OpenXR panel oracle failed: \(error)\n".utf8))
        exit(1)
    }
}
