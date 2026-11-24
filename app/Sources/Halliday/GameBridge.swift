import Foundation
import ImageIO
import Metal
import QuartzCore
import simd
import CHallidayCore
import CoreVideo
import ScreenCaptureKit

/// A VR game running under Wine (GameHub, CrossOver), through Halliday's own OpenVR runtime
/// (ROADMAP W14). The game loads `vrclient_x64.dll` from `OpenVR/bin/` in Halliday's Application
/// Support folder, found through `openvrpaths.vrpath` in its Wine prefix (`install(prefix:)`);
/// the two meet in `OpenVR/halliday-bridge.shm` (core/halliday-bridge): Halliday publishes the
/// head and two emulated controllers every frame and shows the game's frames as the projection
/// layer, the way it shows an immersive WebXR page.
///
/// Simulator controls while a game runs: the mouse turns the head; the left button is the right
/// controller's trigger, the right button its grip; Space its touchpad click, Tab its menu button,
/// the arrow keys touch its touchpad; with Shift, the left controller's.
@MainActor
final class GameBridge {
    /// Halliday's OpenVR runtime folder (what `openvrpaths.vrpath` points at).
    nonisolated static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Halliday/OpenVR")

    /// Full game-image target; a reduced render scale is an explicit user choice.
    static let eyeSize = (width: UInt32(GameImagePlan.targetWidth), height: UInt32(GameImagePlan.targetHeight))
    let imageRenderPercent: Int
    private(set) var halfFrameRate: Bool
    private var frameCadence: GameFrameCadence
    private var cadenceEpoch: UInt64 = 1
    var physicalDisplayHz: Float { frameCadence.physicalHz }
    var supportsLiveDisplayRate: Bool { bridge != nil }
    private static var nextImageSequence: UInt64 = 0

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var bridge: OpaquePointer?
    private var buffer: MTLBuffer?
    private var texture: MTLTexture?
    private var reading = false
    private var lastFrames: UInt64 = 0
    private var lastFrameTime = 0.0
    private var lastFrameIndex: UInt64 = 0
    private var layer: ProjectionLayer?
    private var packet: UInt32 = 0

    /// A game is running in Halliday: from its first frame until it shuts VR down or its process
    /// ends (the runtime's heartbeat stops). It may send no frames for a while (loading).
    private(set) var isPresenting = false
    /// Its frames are arriving (the latest within half a second).
    private(set) var framesArriving = false
    /// The game's executable name, once it connected.
    private(set) var appName = ""
    /// When it started presenting.
    private(set) var startedAt: Date?
    /// The game's process on the Mac (Wine's), once known: from its frames window, or found by its
    /// executable's name (for a force quit).
    private(set) var gameProcessID: pid_t?
    /// Halliday's interface is over the game (design board 14): the game is told, and the mouse,
    /// clicks and keys stay with Halliday.
    private(set) var paused = false
    /// A game that connected (VR_Init) but hasn't shown a frame yet: its executable.
    private var connectedExe: String?
    /// Called when a game starts or stops running.
    var onChange: ((Bool) -> Void)?

    // Frames through a window (GameFrames.swift), when the runtime presents them there.
    private var framesDisplay: GameFramesDisplay?
    private var framesDisplayRequested = false
    private var capture: GameFrameCapture?
    private var captureStarting = false
    private var captureRetry = 0.0
    private var presentState: UInt32 = 0
    private var textureCache: CVMetalTextureCache?
    private var windowFrames = 0
    private var windowGaps = 0
    private var lastNumber: UInt32 = 0
    private var windowStatsStart = 0.0
    /// The display game frames are presented on (the cursor is kept off it).
    var framesDisplayBounds: CGRect? { framesDisplay?.bounds }

    private var lastHeartbeat: UInt64 = 0
    private var lastBeatTime = 0.0
    private var lastTick = 0.0
    private var interval = 1.0 / 90.0
    private var framesAtLastTick: UInt64 = 0
    private var quitAcknowledged: UInt32 = 0

    // The game's overlays, skybox and fades (what SteamVR's compositor would show).
    private var overlayLayers: [Int: QuadLayer] = [:]
    private var overlaySeen: [Int: UInt32] = [:]
    private var overlayFiles: [Int: String] = [:]
    private var overlaysReading: Set<Int> = []
    private var skyboxTexture: MTLTexture?
    private var skyboxSeen: UInt32 = 0
    private var skyboxReading = false
    /// A fade toward a color over some seconds.
    private struct Fade {
        var value = SIMD4<Float>.zero
        var from = SIMD4<Float>.zero
        var target = SIMD4<Float>.zero
        var start = 0.0
        var seconds: Float = 0

        mutating func update(to target: SIMD4<Float>, over seconds: Float, now: Double, name: String) {
            if target != self.target {
                log("[game] \(name) fading to \(target) over \(seconds) s")
                from = value
                self.target = target
                start = now
                self.seconds = seconds
            }
            let x = self.seconds > 0 ? min(1, Float(now - start) / self.seconds) : 1
            value = from + (self.target - from) * x
        }
    }
    private var sceneFade = Fade()
    private var backgroundFade = Fade()
    private var loggedTint = false

    // The emulated controllers' buttons (right, left).
    var trigger = [false, false]
    var grip = [false, false]

    /// Where the game's world sits in Halliday's: its origin on the floor under the user and its
    /// forward the way they face, taken while no game is connected (so a game starts in front
    /// of the user, wherever they stand and look) and again at a recenter. Poses go to the game
    /// in its world and come back (its frames' poses, its overlays) into Halliday's.
    private var originPlace = SIMD3<Float>.zero
    private var originTurn = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var clientConnected = false

    /// Puts the game's world in front of the user again (the recenter button).
    func recenter(head: HeadPose) {
        let forward = head.orientation.act(SIMD3<Float>(0, 0, -1))
        originTurn = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
        originPlace = SIMD3(head.position.x, -floorLift, head.position.z)
    }

    /// How far the user stands above the game's floor beyond their real height (negative:
    /// lower), set by the user with a controller (R1 held, a stick up or down) and remembered:
    /// a game's or a scene's floor is not always where the room's is.
    private(set) var floorLift = UserDefaults.standard.float(forKey: "gameFloorLift")

    /// Raises (or lowers) the user in the game's world, by a stick's push for one frame.
    func raise(by stick: Float) {
        floorLift = max(-2, min(2, floorLift + stick * 0.6 * Float(min(interval, 0.05))))
        originPlace.y = -floorLift
        UserDefaults.standard.set(floorLift, forKey: "gameFloorLift")
    }

    /// The same by a step in meters (the bar over the game).
    func raise(meters: Float) {
        floorLift = max(-2, min(2, floorLift + meters))
        originPlace.y = -floorLift
        UserDefaults.standard.set(floorLift, forKey: "gameFloorLift")
    }

    /// A hand that holds a Sense controller: where it is and points, and what it presses.
    struct RealHand {
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var trigger: Float
        /// Digital contact stays separate from analog travel.
        var triggerPressed = false
        var grip: Bool
        var stick: SIMD2<Float>
        var stickClick: Bool
        var stickTouch: Bool
        /// Cross or square (a Touch controller's A or X), circle or triangle (B or Y), and
        /// Options or Create (menu).
        var lower: Bool
        var upper: Bool
        var menu: Bool
        var motion: GameControllerMotion = .stationary
    }
    /// Right, left (as `trigger`), set every frame by the app while a controller is held and a
    /// game has the input; nil: the hand the mouse and keyboard stand in for.
    var realHands: [RealHand?] = [nil, nil]

    /// A hand the mouse placed (⌥ moves the right, ⌥⇧ the left): where it points from the
    /// shoulder, turned with the body, and how far it reaches. Nil: it follows the gaze.
    struct HandAim: Equatable {
        var yaw: Float
        var pitch: Float
        var reach: Float
    }
    /// Right, left (as `trigger`).
    private(set) var aims: [HandAim?] = [nil, nil]
    private var headPitch: Float = 0
    private var loggedAim = false

    /// Where a hand points at one of the game's overlays that takes the mouse (for the saber).
    struct Pointing {
        var from: SIMD3<Float>
        var to: SIMD3<Float>
        var pressed: Bool
    }
    private(set) var pointing: Pointing?
    /// Scroll so far over the game's overlays, hundredths of a notch.
    private var scrollTotal: Int32 = 0
    private var pointerPublished = false
    private var heldKeys: Set<UInt16> = []
    private var shiftHeld = false
    /// Keys logged once each (diagnostics).
    private var loggedKeys: Set<UInt16> = []

    /// `displayHz`: the headset display's rate, told to games (90 without one).
    init?(device: MTLDevice, queue: MTLCommandQueue, displayHz: Float = 90) {
        self.device = device
        self.queue = queue
        imageRenderPercent = Settings.shared.gameRenderPercent
        halfFrameRate = Settings.shared.gameHalfFrameRate
        frameCadence = GameFrameCadence(physicalHz: displayHz, halfFrameRate: halfFrameRate)
        interval = 1 / Double(frameCadence.physicalHz)
        guard Self.installRuntime() else { return nil }
        func tangents(_ eye: Eye) -> (Float, Float, Float, Float) {
            let f = Optics.fov(eye)
            return (tan(f.left), tan(f.right), tan(f.up), tan(f.down))
        }
        let l = tangents(.left), r = tangents(.right)
        let render = GameImagePlan.renderSize(percent: imageRenderPercent)
        var config = HallidayBridgeConfig(eye_width: UInt32(render.width), eye_height: UInt32(render.height),
                                          display_hz: frameCadence.gameHz, ipd: 0.063,
                                          tangents: ((l.0, l.1, l.2, l.3), (r.0, r.1, r.2, r.3)))
        // The runtime appends to its log in every game process: start it afresh with Halliday,
        // after noting the games that tried to start while Halliday wasn't running.
        let runtimeLog = Self.folder.appendingPathComponent("vrclient.log")
        for missed in GameLibrary.readMissedLaunches(log: runtimeLog) {
            GameLibrary.shared.recordLaunch(exe: missed.exe, minutes: nil,
                                            problem: "It started while Halliday wasn't open. Open Halliday first, then start the game.",
                                            at: missed.at)
        }
        try? FileManager.default.removeItem(at: runtimeLog)
        let path = Self.folder.appendingPathComponent("halliday-bridge.shm").path
        guard let b = halliday_bridge_open(path, &config), let base = halliday_bridge_base(b) else {
            log("[game] couldn't create the bridge file in \(Self.folder.path)")
            return nil
        }
        bridge = b
        buffer = device.makeBuffer(bytesNoCopy: base, length: Int(halliday_bridge_file_size()), options: .storageModeShared, deallocator: nil)
        log("[game] OpenVR runtime ready in \(Self.folder.path) (a game finds it through openvrpaths.vrpath in its Wine prefix)")
    }

    func close() {
        stopCapture()
        if let b = bridge { halliday_bridge_close(b) }
        bridge = nil
    }

    /// Changes only the game's wake cadence. The public mapping, client/session,
    /// physical display, poses and image dimensions keep their existing lifetimes.
    @discardableResult
    func setHalfFrameRate(_ enabled: Bool) -> Bool {
        guard enabled != halfFrameRate else { return true }
        guard let bridge else { return false }
        frameCadence.setHalfFrameRate(enabled)
        halfFrameRate = enabled
        publishCadence(bridge: bridge)
        log("[game] live render cadence \(frameCadence.gameHz) Hz; display and pose publication stay \(frameCadence.physicalHz) Hz")
        return true
    }

    /// Call only after the physical display confirms its new mode. Images,
    /// mapping and game session retain their existing lifetimes.
    @discardableResult
    func setPhysicalDisplayHz(_ hz: Float) -> Bool {
        guard hz.isFinite, (20...240).contains(hz) else { return false }
        guard supportsLiveDisplayRate, let bridge else { return false }
        guard abs(frameCadence.physicalHz - hz) > 0.01 else { return true }
        frameCadence.setPhysicalHz(hz)
        interval = 1 / Double(hz)
        publishCadence(bridge: bridge)
        log("[game] live physical display \(frameCadence.physicalHz) Hz; game cadence \(frameCadence.gameHz) Hz")
        return true
    }

    private func publishCadence(bridge: OpaquePointer) {
        cadenceEpoch &+= 1
        if cadenceEpoch == 0 { cadenceEpoch = 1 }
        layer?.gameHalfRate = halfFrameRate
        layer?.sourceFrameInterval = frameCadence.gameInterval
        layer?.gameCadenceEpoch = cadenceEpoch
        // Publish before the next notification, not after a waiter has woken.
        // This does not manufacture a display tick or increment missed frames.
        halliday_bridge_frame_shown(bridge, UInt64(frameCadence.gameInterval * 1e9), false)
    }

    /// Never replace a mapping while a client, capture or GPU read still uses it.
    var canReconfigureImage: Bool {
        guard !isPresenting, connectedExe == nil, !reading, !captureStarting,
              overlaysReading.isEmpty, !skyboxReading else { return false }
        if let bridge {
            var client = HallidayBridgeClient()
            halliday_bridge_client(bridge, &client)
            if client.initialized != 0, lastBeatTime == 0 || CACurrentMediaTime() - lastBeatTime < 2 { return false }
        }
        return true
    }

    /// Puts the DLL from the app's bundle at `OpenVR/bin/` (OpenVR 1.0 loaders) and
    /// `OpenVR/bin/win64/` (later ones), replacing an older copy.
    static func installRuntime() -> Bool {
        guard let dll = Bundle.main.url(forResource: "vrclient_x64", withExtension: "dll"),
              let data = try? Data(contentsOf: dll) else {
            log("[game] no vrclient_x64.dll in the app (make vrclient): games can't use Halliday")
            return false
        }
        let fm = FileManager.default
        for sub in ["bin", "bin/win64"] {
            let dir = folder.appendingPathComponent(sub)
            let target = dir.appendingPathComponent("vrclient_x64.dll")
            if (try? Data(contentsOf: target)) == data { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            } catch {
                log("[game] couldn't install the runtime in \(dir.path): \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// GameHub's Wine prefixes: one "virtual container" per game setup, whose `drive_c` is the
    /// writable layer GameHub mounts over its base container when a game runs.
    static var gameHubPrefixes: [URL] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gamemac.www/wine-engine/containers/virtual_containers")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("drive_c/users").path) }
    }

    /// `halliday --install-openvr PREFIX|gamehub`: installs the runtime and points the prefix (or
    /// every GameHub container) at it. Prints what it did; false on failure.
    static func installCommand(_ target: String) -> Bool {
        guard installRuntime() else { return false }
        let prefixes = target == "gamehub" ? gameHubPrefixes : [URL(fileURLWithPath: (target as NSString).expandingTildeInPath)]
        if prefixes.isEmpty {
            print("No GameHub containers yet: launch the game once from GameHub first.")
            return false
        }
        var ok = true
        for prefix in prefixes {
            do {
                for file in try install(prefix: prefix) { print("Wrote \(file.path)") }
            } catch {
                print("Couldn't install into \(prefix.path): \(error.localizedDescription)")
                ok = false
            }
        }
        if ok { print("Halliday is the OpenVR runtime there. Start Halliday, then the game.") }
        return ok
    }

    /// Points a Wine prefix's OpenVR at Halliday: writes `openvrpaths.vrpath` in every user's
    /// `AppData/Local/openvr` (keeping a copy of one that was there). Returns the files written.
    static func install(prefix: URL) throws -> [URL] {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users")
        let names = try fm.contentsOfDirectory(atPath: users.path).filter { $0 != "Public" && !$0.hasPrefix(".") }
        let z = prefix.appendingPathComponent("dosdevices/z:")
        if (try? fm.destinationOfSymbolicLink(atPath: z.path)) != "/" {
            log("[game] warning: \(z.path) doesn't point at / : the game may not reach Halliday's folder")
        }
        let json: [String: Any] = [
            "jsonid": "vrpathreg", "version": 1,
            "runtime": [windowsPath(folder)],
            "config": [windowsPath(folder.appendingPathComponent("config"))],
            "log": [windowsPath(folder.appendingPathComponent("logs"))],
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fm.createDirectory(at: folder.appendingPathComponent("config"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
        var written: [URL] = []
        for name in names {
            let dir = users.appendingPathComponent(name).appendingPathComponent("AppData/Local/openvr")
            let file = dir.appendingPathComponent("openvrpaths.vrpath")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let backup = dir.appendingPathComponent("openvrpaths.vrpath.before-halliday")
            if fm.fileExists(atPath: file.path), !fm.fileExists(atPath: backup.path),
               let old = try? Data(contentsOf: file), !String(decoding: old, as: UTF8.self).contains("Halliday") {
                try fm.copyItem(at: file, to: backup)
            }
            try data.write(to: file, options: .atomic)
            written.append(file)
        }
        return written
    }

    /// A Mac folder as Windows programs in a Wine prefix see it (through `Z:`, which is `/`).
    nonisolated static func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }

    /// Undoes `install(prefix:)`: puts back the file kept from before, or removes Halliday's.
    static func uninstall(prefix: URL) throws {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users")
        for name in try fm.contentsOfDirectory(atPath: users.path) where name != "Public" && !name.hasPrefix(".") {
            let dir = users.appendingPathComponent(name).appendingPathComponent("AppData/Local/openvr")
            let file = dir.appendingPathComponent("openvrpaths.vrpath")
            let backup = dir.appendingPathComponent("openvrpaths.vrpath.before-halliday")
            if fm.fileExists(atPath: backup.path) {
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                try fm.moveItem(at: backup, to: file)
            } else if let data = try? Data(contentsOf: file), String(decoding: data, as: UTF8.self).contains("Halliday") {
                try fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Every frame

    /// What a running game shows this display frame.
    struct View {
        /// Its newest frame (nil while it sends none, or asked for the compositor's place).
        var projection: ProjectionLayer?
        /// Its overlays, in the room or following the head or a hand.
        var layers: [QuadLayer]
        /// The skybox it set for its loads, shown when no frame is.
        var skybox: VideoSphere?
        /// Its fades, premultiplied colors: over its frames, and over the place shown instead
        /// (skybox, grid). Overlays aren't faded.
        var fade: SIMD4<Float>
        var backgroundFade: SIMD4<Float>
    }

    /// Publishes the head and controllers, and takes the game's newest frame and what it shows
    /// besides. Nil while no game runs.
    /// `ahead`: the head as it is expected `lead` after this frame is seen, when the frame the
    /// game draws with it will be: published instead of `head` (a game that predicts nothing
    /// itself drew for a head 20 to 40 ms old, and its picture had to be moved that far).
    func tick(head: HeadPose, ahead: HeadPose? = nil) -> View? {
        guard let b = bridge else { return nil }
        let now = CACurrentMediaTime()
        let displayTarget = HeadsetView.frameTarget
        let target = displayTarget > 0 && abs(displayTarget - now) < 0.25 ? displayTarget : now
        let notifyGame = frameCadence.shouldNotify(at: target)
        if lastTick > 0 {
            let dt = now - lastTick
            if dt > 0.002, dt < 0.1 { interval += (dt - interval) * 0.05 }
        }
        lastTick = now
        // A late callback must not change the negotiated game cadence. Publish
        // timing before waking a game; poses and controllers still update every tick.
        let gameInterval = frameCadence.gameInterval
        halliday_bridge_frame_shown(b, UInt64(gameInterval * 1e9), false)
        if !clientConnected { recenter(head: head) }
        let toGame = originTurn.inverse
        var state = HallidayBridgeState()
        let given = ahead ?? head
        state.head = Self.pose(toGame.act(given.position - originPlace), toGame * given.orientation,
            angular: GameControllerMotion.angularInGame(body: given.angularVelocity,
                bodyOrientation: given.orientation, originTurn: originTurn))
        // Numbered, so a frame's pose tells when it was published (`poseAges`).
        stamp = stamp >= 0xFF_FFFF ? 1 : stamp + 1
        state.head.stamp = Float(stamp)
        stampTimes[Int(stamp) % stampTimes.count] = now
        stampTargets[Int(stamp) % stampTargets.count] = HeadsetView.frameTarget
        let heading = simd_quatf(angle: atan2(-head.orientation.act(SIMD3<Float>(0, 0, -1)).x,
                                             -head.orientation.act(SIMD3<Float>(0, 0, -1)).z), axis: [0, 1, 0])
        packet &+= 1
        var hands: [(position: SIMD3<Float>, orientation: simd_quatf)] = [(head.position, head.orientation), (head.position, head.orientation)]
        let gaze = head.orientation.act(SIMD3<Float>(0, 0, -1))
        headPitch = asin(max(-1, min(1, gaze.y)))
        for (i, side) in [(1, Float(1)), (0, Float(-1))] { // right is index 1 in the bridge
            let hand = i == 1 ? 0 : 1 // our arrays: 0 right, 1 left
            var c = HallidayBridgeController()
            let at: SIMD3<Float>, turn: simd_quatf
            if let real = realHands[hand] {
                at = real.position
                turn = real.orientation
            } else if let aim = aims[hand] {
                // Placed by the mouse: from the shoulder, turned with the body.
                turn = heading * simd_quatf(angle: aim.yaw, axis: [0, 1, 0]) * simd_quatf(angle: aim.pitch, axis: [1, 0, 0])
                at = head.position + heading.act(SIMD3(0.18 * side, -0.3, 0)) + turn.act(SIMD3(0, 0, -aim.reach))
            } else {
                // In front of the body, aimed where the head looks (the mouse turns both).
                turn = head.orientation
                at = head.position + heading.act(SIMD3(0.18 * side, -0.32, -0.32))
            }
            hands[i] = (at, turn)
            let motion = realHands[hand]?.motion.inGame(originTurn: originTurn, now: now)
            c.pose = Self.pose(toGame.act(at - originPlace), toGame * turn,
                angular: motion?.angular ?? .zero, linear: motion?.linear ?? .zero)
            c.connected = 1
            c.packet = packet
            var pressed: UInt64 = 0, touched: UInt64 = 0
            func bit(_ b: UInt32) -> UInt64 { 1 << UInt64(b) }
            if trigger[hand] { pressed |= bit(33); touched |= bit(33) }
            if grip[hand] { pressed |= bit(2) }
            let keys = keysFor(hand)
            if keys.contains(49) { pressed |= bit(32); touched |= bit(32) }   // Space: touchpad click
            if keys.contains(48) { pressed |= bit(1) }                         // Tab: menu
            var pad = SIMD2<Float>.zero
            if keys.contains(126) { pad.y += 1 }
            if keys.contains(125) { pad.y -= 1 }
            if keys.contains(123) { pad.x -= 1 }
            if keys.contains(124) { pad.x += 1 }
            if pad != .zero { touched |= bit(32); pad = simd_normalize(pad) } // the pad's edge (d-pad directions)
            c.pressed = pressed
            c.touched = touched
            c.axes.0 = (pad.x, pad.y)
            c.axes.1 = (trigger[hand] ? 1 : 0, 0)
            if let real = realHands[hand] {
                // A Sense controller as the bridge's buttons (OpenVR's ids): the stick is the
                // touchpad (axis 0), the grip also axis 2; circle and triangle the menu button
                // (1), cross and square A (7), Options and Create the system button (0).
                // Halliday's OpenXR runtime reads the same as a Touch controller's parts.
                pressed = 0
                touched = 0
                if real.triggerPressed || real.trigger > 0.6 { pressed |= bit(33) }
                if real.triggerPressed || real.trigger > 0.02 { touched |= bit(33) }
                if real.grip { pressed |= bit(2) }
                if real.stickClick { pressed |= bit(32) }
                if real.stickTouch || simd_length(real.stick) > 0.1 { touched |= bit(32) }
                if real.upper { pressed |= bit(1) }
                if real.lower { pressed |= bit(7) }
                if real.menu { pressed |= bit(0) }
                c.pressed = pressed
                c.touched = touched
                c.axes.0 = (real.stick.x, real.stick.y)
                c.axes.1 = (real.trigger, 0)
                c.axes.2 = (real.grip ? 1 : 0, 0)
            }
            if i == 1 { state.controllers.1 = c } else { state.controllers.0 = c }
        }
        halliday_bridge_publish_frame(b, &state, notifyGame)

        var client = HallidayBridgeClient()
        halliday_bridge_client(b, &client)
        // (An OpenXR application has no VR_Init: it is here from its first frame, and until
        // then the head stays at its world's origin, which is where its LOCAL space begins.)
        clientConnected = client.initialized != 0 || isPresenting
        if client.heartbeat != lastHeartbeat {
            lastHeartbeat = client.heartbeat
            lastBeatTime = now
            prepareFramesDisplay(b)
        }
        // Only while it beats: a game that crashed or was killed never shut VR down, and its
        // `initialized` stays set (it was taken for a new launch that stopped at once, again and
        // again, and a game that had played was recorded as "stopped at launch").
        if client.initialized != 0, connectedExe == nil, !isPresenting, lastHeartbeat != 0, now - lastBeatTime < 2 {
            connectedExe = withUnsafeBytes(of: client.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        if client.frames != lastFrames {
            lastFrames = client.frames
            lastFrameTime = now
            if !isPresenting {
                isPresenting = true
                connectedExe = nil
                startedAt = Date()
                appName = withUnsafeBytes(of: client.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                log("[game] \(appName) (process \(client.pid)) is presenting")
                onChange?(true)
            }
        }
        // It connected and stopped without a frame: why, from the runtime's log.
        if let exe = connectedExe, !isPresenting, client.initialized == 0 || (lastHeartbeat != 0 && now - lastBeatTime > 2) {
            connectedExe = nil
            log("[game] \(exe) stopped before its first frame")
            GameLibrary.shared.recordLaunch(exe: exe, minutes: nil, problem: Self.lastRuntimeProblem()
                ?? "It connected to Halliday and stopped before its first frame.")
        }
        if client.quit_acknowledged != quitAcknowledged {
            quitAcknowledged = client.quit_acknowledged
            log("[game] \(appName) acknowledged the quit request")
        }
        framesArriving = now - lastFrameTime < 0.5
        if isPresenting {
            // Still running: its heartbeat beats (an older runtime has none: its frames count) and
            // it hasn't shut VR down.
            let beating = lastHeartbeat != 0 && now - lastBeatTime < 2
            let alive = beating ? client.initialized != 0 || framesArriving : now - lastFrameTime < 1
            if !alive {
                if let startedAt {
                    GameLibrary.shared.recordLaunch(exe: appName, minutes: Int(Date().timeIntervalSince(startedAt) / 60), problem: nil)
                }
                isPresenting = false
                aims = [nil, nil]
                pointing = nil
                startedAt = nil
                gameProcessID = nil
                setPaused(false)
                layer = nil
                lastFrameIndex = 0
                stopCapture()
                clearScene()
                log("[game] \(appName) stopped")
                onChange?(false)
            }
        }
        // Intentional half-rate repeats are not missed game frames. Compare the producer only
        // at game deadlines, while pose/input publication and reprojection continue every tick.
        let late = notifyGame && isPresenting && framesArriving && client.frames == framesAtLastTick
        if notifyGame { framesAtLastTick = client.frames }
        if late { halliday_bridge_frame_shown(b, UInt64(gameInterval * 1e9), true) }
        guard isPresenting else { return nil }
        takeWindowFrame(b, now: now, pid: client.pid)
        if !reading { takeFrame(b) }

        var scene = HallidayBridgeScene()
        var overlays = [HallidayBridgeOverlay](repeating: HallidayBridgeOverlay(), count: Int(HALLIDAY_BRIDGE_OVERLAYS))
        let fresh = overlays.withUnsafeMutableBufferPointer { halliday_bridge_scene(b, &scene, $0.baseAddress) }
        if fresh { lastScene = (scene, overlays) }
        let (sc, ov) = lastScene ?? (scene, [])
        updateFade(sc, now: now)
        let layers = overlayLayersFor(ov, b: b, head: (head.position, head.orientation), hands: hands)
        point(at: ov, b: b, hands: hands)
        let sky = skybox(sc, b: b)
        // The compositor's own place instead of the game's frames: asked for (FadeGrid), the game
        // suspended its rendering, or no frame is coming.
        let showFrames = framesArriving && sc.grid == 0 && sc.suspended == 0
        let reason = showFrames ? "its frames" : !framesArriving ? "no frames coming (loading?)" : sc.grid != 0 ? "the grid it asked for" : "its rendering suspended"
        if reason != lastShown {
            lastShown = reason
            log("[game] showing \(reason)\(showFrames || sc.skybox == 0 ? "" : ", with its skybox")")
        }
        return View(projection: showFrames ? layer : nil, layers: layers, skybox: showFrames ? nil : sky,
                    fade: sceneFade.value, backgroundFade: backgroundFade.value)
    }

    private var lastScene: (HallidayBridgeScene, [HallidayBridgeOverlay])?
    private var lastShown = ""

    /// Asks the game to quit (OpenVR's `VREvent_Quit`).
    func requestQuit() {
        guard let b = bridge, isPresenting else { return }
        log("[game] asking \(appName) to quit")
        halliday_bridge_request_quit(b)
    }

    /// Halliday's own interface is over the game (it should pause) or not.
    func setDashboard(_ shown: Bool) {
        guard let b = bridge else { return }
        halliday_bridge_set_dashboard(b, shown)
    }

    /// Halliday comes up over the game, or goes back to it: the game is told (dashboard and input
    /// focus events), and its controllers let go of everything held.
    func setPaused(_ on: Bool) {
        guard paused != on else { return }
        paused = on
        setDashboard(on)
        trigger = [false, false]
        grip = [false, false]
        heldKeys = []
        log("[game] Halliday \(on ? "is up over" : "went back to") \(appName)")
    }

    /// Ends the game's process at once (the user chose Force quit). False if it isn't known.
    func forceQuit() -> Bool {
        let pids = gameProcessID.map { [$0] } ?? Self.processes(running: appName)
        guard !pids.isEmpty else {
            log("[game] force quit: no process found for \(appName)")
            return false
        }
        for pid in pids {
            log("[game] force quitting \(appName) (Mac process \(pid))")
            kill(pid, SIGKILL)
        }
        return true
    }

    /// The Mac processes whose command line names `exe` (Wine runs a game as a process of its
    /// own, its arguments naming the executable). Not Halliday, not Wine's server.
    private static func processes(running exe: String) -> [pid_t] {
        guard !exe.isEmpty else { return [] }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        let own = ProcessInfo.processInfo.processIdentifier
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = pid_t(parts[0]), pid != own else { return nil }
            let command = parts[1].lowercased()
            guard command.contains(exe.lowercased()), !command.contains("wineserver"), !command.contains("halliday") else { return nil }
            return pid
        }
    }

    /// The runtime log's last line about something failing, for the user.
    private static func lastRuntimeProblem() -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("vrclient.log"), encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").last { l in
            ["failed", "isn't supported", "doesn't", "couldn't", "can't"].contains { l.contains($0) }
        }
        return line.map { "It stopped before its first frame. The runtime said: " + $0.replacingOccurrences(of: "[halliday-vrclient] ", with: "") }
    }

    private func clearScene() {
        overlayLayers = [:]
        overlaySeen = [:]
        overlayFiles = [:]
        skyboxTexture = nil
        skyboxSeen = 0
        sceneFade = Fade()
        backgroundFade = Fade()
        lastScene = nil
        lastShown = ""
    }

    private func updateFade(_ scene: HallidayBridgeScene, now: Double) {
        let f = scene.fade_color, b = scene.background_color
        sceneFade.update(to: SIMD4(f.0, f.1, f.2, f.3), over: scene.fade_seconds, now: now, name: "the scene")
        backgroundFade.update(to: SIMD4(b.0, b.1, b.2, b.3), over: scene.background_seconds, now: now, name: "the background")
    }

    /// The overlays as layers: their pictures copied on the GPU when they change.
    private func overlayLayersFor(_ overlays: [HallidayBridgeOverlay], b: OpaquePointer,
                                  head: (SIMD3<Float>, simd_quatf),
                                  hands: [(position: SIMD3<Float>, orientation: simd_quatf)]) -> [QuadLayer] {
        var out: [QuadLayer] = []
        for (i, o) in overlays.enumerated() {
            guard o.used != 0 else {
                overlayLayers[i] = nil
                overlaySeen[i] = nil
                overlayFiles[i] = nil
                continue
            }
            updatePicture(i, o, b: b)
            guard o.visible != 0, let layer = overlayLayers[i] else { continue }
            // Pose: the overlay's matrix, in the room or after its device's pose.
            let m = o.transform
            let rotation = simd_float3x3(rows: [SIMD3(m.0.0, m.0.1, m.0.2), SIMD3(m.1.0, m.1.1, m.1.2), SIMD3(m.2.0, m.2.1, m.2.2)])
            var q = simd_quatf(rotation)
            var p = SIMD3(m.0.3, m.1.3, m.2.3)
            if o.relative != 0 {
                let device = o.device == 0 ? head : (o.device == 1 ? (hands[0].position, hands[0].orientation) : (hands[1].position, hands[1].orientation))
                p = device.0 + device.1.act(p)
                q = device.1 * q
            } else {
                p = originPlace + originTurn.act(p)
                q = originTurn * q
            }
            layer.position = p
            layer.orientation = q
            layer.width = o.width_m
            let bounds = SIMD4(o.bounds.0, o.bounds.1, o.bounds.2, o.bounds.3)
            layer.uvRect = SIMD4(bounds.x, bounds.y, bounds.z - bounds.x, bounds.w - bounds.y)
            let pw = Float(layer.texture.width) * abs(bounds.z - bounds.x)
            let ph = Float(layer.texture.height) * abs(bounds.w - bounds.y)
            layer.aspect = pw > 0 ? ph / pw / max(o.texel_aspect, 0.01) : nil
            layer.opacity = o.alpha
            layer.tier = Int(min(o.sort_order, 1000))
            if !loggedTint, o.color.0 < 0.99 || o.color.1 < 0.99 || o.color.2 < 0.99 {
                loggedTint = true
                log("[game] an overlay asks for a tint (\(o.color)): not applied yet")
            }
            out.append(layer)
        }
        return out
    }

    /// Takes overlay `i`'s new picture, if it has one (from the bridge, or a file).
    private func updatePicture(_ i: Int, _ o: HallidayBridgeOverlay, b: OpaquePointer) {
        let file = withUnsafeBytes(of: o.file) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !file.isEmpty {
            guard overlayFiles[i] != file else { return }
            overlayFiles[i] = file
            if let texture = Self.texture(fromFile: file, device: device) {
                setOverlayTexture(i, texture)
                log("[game] overlay \(i) shows \((file as NSString).lastPathComponent)")
            } else {
                log("[game] overlay \(i): couldn't read \(file)")
            }
            return
        }
        guard !overlaysReading.contains(i), let buffer else { return }
        var pic = HallidayBridgePicture()
        guard halliday_bridge_claim_picture(b, Int32(i), overlaySeen[i] ?? 0, &pic) else { return }
        overlaySeen[i] = pic.seq
        let w = Int(pic.width), h = Int(pic.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        d.usage = [.shaderRead]
        d.storageMode = .private
        guard let texture = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else {
            halliday_bridge_release_picture(b, Int32(i))
            return
        }
        blit.copy(from: buffer, sourceOffset: Int(pic.offset), sourceBytesPerRow: w * 4, sourceBytesPerImage: w * 4 * h,
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin())
        if texture.mipmapLevelCount > 1 { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        overlaysReading.insert(i)
        let address = Int(bitPattern: b)
        cb.addCompletedHandler { [weak self] _ in
            halliday_bridge_release_picture(OpaquePointer(bitPattern: address), Int32(i))
            Task { @MainActor in self?.overlaysReading.remove(i) }
        }
        cb.commit()
        // The renderer draws on the same queue, after this copy.
        setOverlayTexture(i, texture)
    }

    private func setOverlayTexture(_ i: Int, _ texture: MTLTexture) {
        if let layer = overlayLayers[i] {
            layer.texture = texture
        } else {
            let layer = QuadLayer(texture: texture, position: [0, 1.6, -2], width: 1)
            layer.appear()
            overlayLayers[i] = layer
        }
    }

    /// The skybox, as a picture around the viewer (equirectangular; a stereo pair top/bottom).
    private func skybox(_ scene: HallidayBridgeScene, b: OpaquePointer) -> VideoSphere? {
        guard scene.skybox != 0 else { return nil }
        if !skyboxReading, let buffer {
            var pic = HallidayBridgePicture()
            if halliday_bridge_claim_picture(b, -1, skyboxSeen, &pic) {
                skyboxSeen = pic.seq
                let w = Int(pic.width), h = Int(pic.height)
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
                d.usage = [.shaderRead]
                d.storageMode = .private
                if let texture = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                    blit.copy(from: buffer, sourceOffset: Int(pic.offset), sourceBytesPerRow: w * 4, sourceBytesPerImage: w * 4 * h,
                              sourceSize: MTLSize(width: w, height: h, depth: 1), to: texture, destinationSlice: 0,
                              destinationLevel: 0, destinationOrigin: MTLOrigin())
                    blit.endEncoding()
                    skyboxReading = true
                    let address = Int(bitPattern: b)
                    cb.addCompletedHandler { [weak self] _ in
                        halliday_bridge_release_picture(OpaquePointer(bitPattern: address), -1)
                        Task { @MainActor in self?.skyboxReading = false }
                    }
                    cb.commit()
                    skyboxTexture = texture // drawn after this copy (same queue)
                    log("[game] skybox \(w)×\(h)")
                } else {
                    halliday_bridge_release_picture(b, -1)
                }
            }
        }
        guard let skyboxTexture else { return nil }
        return VideoSphere(texture: skyboxTexture, projection: 0, stereo: scene.skybox == 2 ? 2 : 0,
                           fisheyeFovDeg: 0, orientation: simd_quatf(angle: 0, axis: [0, 1, 0]))
    }

    /// A picture file as a premultiplied RGBA texture (an overlay's `SetOverlayFromFile`).
    private static func texture(fromFile path: String, device: MTLDevice) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = min(image.width, 4096), h = min(image.height, 4096)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
        return texture
    }

    private func keysFor(_ hand: Int) -> Set<UInt16> { (hand == 1) == shiftHeld ? heldKeys : [] }

    private static func pose(_ p: SIMD3<Float>, _ q: simd_quatf, angular: SIMD3<Float>, linear: SIMD3<Float> = .zero) -> HallidayBridgePose {
        var pose = HallidayBridgePose()
        pose.position = (p.x, p.y, p.z)
        pose.valid = 1
        pose.orientation = (q.imag.x, q.imag.y, q.imag.z, q.real)
        pose.angular_velocity = (angular.x, angular.y, angular.z)
        pose.velocity = (linear.x, linear.y, linear.z)
        return pose
    }

    /// Copies the newest frame into the side-by-side texture on the GPU (no CPU copy: the bridge's
    /// memory is wrapped as a Metal buffer), and releases the slot when the copy is done.
    private func takeFrame(_ b: OpaquePointer) {
        var f = HallidayBridgeFrame()
        guard halliday_bridge_begin_read(b, &f) else { return }
        // Older than the one shown: the window brought it already (or a game that started again
        // counts from 1: `lastFrameIndex` is reset when a game stops).
        guard f.frame_index > lastFrameIndex, let buffer else { halliday_bridge_end_read(b); return }
        lastFrameIndex = f.frame_index
        let w = Int(f.width), h = Int(f.height)
        // Each eye's part of its image, in pixels; rows counted from the first row in memory.
        let bounds = [f.bounds.0, f.bounds.1]
        func region(_ e: Int) -> (x: Int, y: Int, w: Int, h: Int) {
            let bd = bounds[e]
            let x0 = Int((min(bd.0, bd.2) * Float(w)).rounded()), x1 = Int((max(bd.0, bd.2) * Float(w)).rounded())
            let r0 = Int((min(bd.1, bd.3) * Float(h)).rounded()), r1 = Int((max(bd.1, bd.3) * Float(h)).rounded())
            return (max(0, x0), max(0, r0), max(1, min(w, x1) - max(0, x0)), max(1, min(h, r1) - max(0, r0)))
        }
        let regions = [region(0), region(1)]
        let ew = min(regions[0].w, regions[1].w), eh = min(regions[0].h, regions[1].h)
        // Direct3D's BGRA formats keep their byte order: the texture's format reads them right.
        let format: MTLPixelFormat = f.bgra != 0 ? .bgra8Unorm : .rgba8Unorm
        if texture?.width != ew * 2 || texture?.height != eh || texture?.pixelFormat != format {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: ew * 2, height: eh, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
            log("[game] frames of \(w)×\(h) (\(f.bottom_up != 0 ? "OpenGL" : "Direct3D 11"), \(f.bgra != 0 ? "BGRA" : "RGBA")), each eye shown \(ew)×\(eh)")
        }
        guard let texture, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            halliday_bridge_end_read(b)
            return
        }
        reading = true
        let offsets = [Int(f.offsets.0), Int(f.offsets.1)]
        for e in 0..<2 {
            let r = regions[e]
            blit.copy(from: buffer, sourceOffset: offsets[e] + (r.y * w + r.x) * 4, sourceBytesPerRow: w * 4,
                      sourceBytesPerImage: w * 4 * eh, sourceSize: MTLSize(width: ew, height: eh, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: e * ew, y: 0, z: 0))
        }
        blit.endEncoding()
        let address = Int(bitPattern: b) // the bridge outlives the copy: closed only at quit
        cb.addCompletedHandler { [weak self] _ in
            halliday_bridge_end_read(OpaquePointer(bitPattern: address))
            Task { @MainActor in self?.reading = false }
        }
        cb.commit()
        // OpenGL rows run bottom-up, Direct3D's top-down; bounds with v min > v max ask for a flip.
        let flipped = (f.bottom_up != 0) == (bounds[0].1 <= bounds[0].3)
        layer = projectionLayer(texture: texture, flipped: flipped, pose: f.pose)
        layer?.seeThrough = f.see_through != 0
    }

    // MARK: - Frames through a window

    /// Once a game's runtime is loaded: the display for its frames window, then where the window
    /// goes, for the runtime. Without Screen Recording permission the runtime copies its frames.
    private func prepareFramesDisplay(_ b: OpaquePointer) {
        guard !framesDisplayRequested else { return }
        framesDisplayRequested = true
        // --copy-frames: the old way only (to compare the two).
        if CommandLine.arguments.contains("--copy-frames") {
            log("[game] --copy-frames: the game's frames are copied, not captured from a window")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            log("[game] no Screen Recording permission: the game's frames are copied (slower) instead of captured from a window")
            return
        }
        let address = Int(bitPattern: b)
        Task { @MainActor [weak self] in
            guard let display = await GameFramesDisplay.make() else {
                log("[game] couldn't make the display for game frames: they are copied instead")
                return
            }
            guard let self, self.bridge != nil else { return }
            self.framesDisplay = display
            let origin = display.bounds.origin
            halliday_bridge_set_present(OpaquePointer(bitPattern: address), true, Int32(origin.x), Int32(origin.y))
        }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
    }

    /// Follows the runtime's window (capture it while it presents, again when the stream stops,
    /// at its new size when it changes) and shows its newest frame when it is newer than the one
    /// shown.
    private func takeWindowFrame(_ b: OpaquePointer, now: Double, pid: UInt32) {
        var status = HallidayBridgePresent()
        halliday_bridge_present_status(b, &status)
        if status.state != presentState {
            presentState = status.state
            log("[game] frames window: \(["off", "starting", "on", "failed: copied instead"][min(Int(status.state), 3)])")
        }
        guard status.state == 1 || status.state == 2, status.width > 0, status.height > 0 else {
            if capture != nil { stopCapture() }
            return
        }
        if let error = capture?.stopped {
            log("[game] frames capture stopped (\(error)): capturing again")
            stopCapture()
            captureRetry = now + 0.3
        }
        guard let capture else {
            guard !captureStarting, now >= captureRetry else { return }
            captureStarting = true
            let (w, h) = (Int(status.width), Int(status.height))
            Task { @MainActor [weak self] in
                defer { self?.captureStarting = false }
                guard let window = await GameFrameCapture.findWindow(pid: pid) else {
                    self?.captureRetry = CACurrentMediaTime() + 0.5
                    return
                }
                let c = GameFrameCapture()
                do {
                    try await c.start(window: window, width: w, height: h)
                    guard let self, self.isPresenting else { c.stop(); return }
                    self.capture = c
                    if let pid = window.owningApplication?.processID { self.gameProcessID = pid }
                    log("[game] capturing the frames window \(window.windowID) (\(w)×\(h))")
                } catch {
                    log("[game] couldn't capture the frames window: \(error.localizedDescription)")
                    self?.captureRetry = CACurrentMediaTime() + 1
                }
            }
            return
        }
        capture.resize(width: Int(status.width), height: Int(status.height))
        guard let f = capture.take() else { return }
        halliday_bridge_present_seen(b, f.number)
        if lastNumber != 0, f.number &- lastNumber > 1, f.number &- lastNumber < 1000 { windowGaps += Int(f.number &- lastNumber) - 1 }
        lastNumber = f.number
        windowFrames += 1
        if windowStatsStart == 0 { windowStatsStart = now }
        if windowFrames % 600 == 0 {
            let c = capture.takeCounts()
            log("[game] window frames: 600 shown in \(String(format: "%.1f", now - windowStatsStart)) s; the capture delivered \(c.delivered), missed \(c.missed), \(c.unreadable) unreadable; \(max(0, windowGaps - c.missed)) replaced by a newer one before a display frame")
            windowStatsStart = now
            windowGaps = 0
        }
        var rec = HallidayBridgePresentFrame()
        guard f.width == Int(status.width), f.height == Int(status.height),
              halliday_bridge_present_frame(b, f.number, &rec), rec.frame_index > lastFrameIndex else { return }
        let band = Int(HALLIDAY_BRIDGE_PRESENT_BAND)
        let ew = Int(rec.eye_width), eh = Int(rec.eye_height)
        guard ew * 2 <= f.width, eh + band <= f.height else { return }
        if textureCache == nil {
            var c: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
            textureCache = c
        }
        var cvTex: CVMetalTexture?
        guard let cache = textureCache,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, f.pixels, nil, .bgra8Unorm, f.width, f.height, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let source = CVMetalTextureGetTexture(cvTex) else { return }
        if texture?.width != ew * 2 || texture?.height != eh || texture?.pixelFormat != .bgra8Unorm {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: ew * 2, height: eh, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
            log("[game] frames through the window (\(rec.texture_type == 1 ? "OpenGL" : "Direct3D 11")), each eye \(ew)×\(eh)")
        }
        guard let texture, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: band, z: 0),
                  sourceSize: MTLSize(width: ew * 2, height: eh, depth: 1), to: texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        // The capture's pool reuses the buffer: kept until the copy is done.
        let keep = KeepAlive([f.pixels, cvTex])
        cb.addCompletedHandler { _ in keep.release() }
        cb.commit() // the renderer draws on the same queue, after this copy
        lastFrameIndex = rec.frame_index
        lastFrameTime = now
        layer = projectionLayer(texture: texture, flipped: rec.flipped != 0, pose: rec.pose)
    }

    // How old a frame's pose is when the frame reaches the eyes: Halliday published the pose, the
    // game rendered with it (predicted ahead), and the frame is shown at the next display frame.
    private var stamp: UInt32 = 0
    private var stampTimes = [Double](repeating: 0, count: 4096)
    private var poseAges: [Double] = []
    /// When the frame each pose was published in was to be seen, and from that how long after
    /// it the game's frame drawn with the pose is seen (seconds, smoothed; whole display
    /// frames): how far ahead a pose for the game has to be predicted.
    private var stampTargets = [Double](repeating: 0, count: 4096)
    private(set) var lead: Double = 0
    private var poseAgesSince = CACurrentMediaTime()

    private func notePoseAge(_ p: HallidayBridgePose) {
        let s = UInt32(p.stamp)
        guard s != 0, stamp &- s < UInt32(stampTimes.count) else { return }
        let age = HeadsetView.frameTarget - stampTimes[Int(s) % stampTimes.count]
        guard age > 0, age < 1 else { return }
        let gap = HeadsetView.frameTarget - stampTargets[Int(s) % stampTargets.count]
        if gap > 0, gap < 0.2 { lead = lead == 0 ? gap : lead + (gap - lead) * 0.05 }
        poseAges.append(age)
        if poseAges.count == 600 {
            let sorted = poseAges.sorted()
            func ms(_ q: Double) -> String { String(format: "%.1f", sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] * 1000) }
            let now = CACurrentMediaTime()
            let rate = 600 / max(now - poseAgesSince, 0.001)
            poseAgesSince = now
            log("[game] pose to eyes, 600 frames: median \(ms(0.5)) ms, 95 % \(ms(0.95)) ms, max \(ms(0.999)) ms (display \(String(format: "%.0f", 1 / max(interval, 0.001))) Hz); the game's frames \(String(format: "%.0f", rate)) a second, seen \(String(format: "%.1f", lead * 1000)) ms after the frame their pose was published in")
            poseAges.removeAll(keepingCapacity: true)
        }
    }

    private func projectionLayer(texture: MTLTexture, flipped: Bool, pose p: HallidayBridgePose) -> ProjectionLayer {
        notePoseAge(p)
        Self.nextImageSequence &+= 1
        func tangents(_ eye: Eye) -> SIMD4<Float> {
            let fov = Optics.fov(eye)
            return SIMD4(tan(fov.left), tan(fov.right), tan(fov.up), tan(fov.down))
        }
        return ProjectionLayer(texture: texture,
                               uvRect: flipped ? SIMD4(0, 1, 1, -1) : SIMD4(0, 0, 1, 1),
                               renderOrientation: originTurn * simd_quatf(ix: p.orientation.0, iy: p.orientation.1, iz: p.orientation.2, r: p.orientation.3),
                               renderPosition: originPlace + originTurn.act(SIMD3(p.position.0, p.position.1, p.position.2)),
                               tangents: (tangents(.left), tangents(.right)),
                               gameImage: true, imageSequence: Self.nextImageSequence,
                               gameHalfRate: halfFrameRate, sourceFrameInterval: frameCadence.gameInterval,
                               gameCadenceEpoch: cadenceEpoch)
    }

    // MARK: - Pointing at the game's overlays

    /// Finds where a hand's ray meets an overlay that takes the mouse (the right hand first) and
    /// publishes it; the runtime turns that into the game's mouse events. Also publishes each
    /// overlay's height as shown, for the game's own intersection tests.
    private func point(at overlays: [HallidayBridgeOverlay], b: OpaquePointer,
                       hands: [(position: SIMD3<Float>, orientation: simd_quatf)]) {
        var best: (overlay: Int, hand: Int, u: Float, v: Float, point: SIMD3<Float>)?
        for (i, o) in overlays.enumerated() {
            guard let layer = overlayLayers[i] else { continue }
            let height = layer.width * (layer.aspect ?? Float(layer.texture.height) / Float(max(1, layer.texture.width)))
            halliday_bridge_set_overlay_height(b, UInt32(i), height)
            guard o.used != 0, o.visible != 0, o.input != 0 else { continue }
            for hand in [0, 1] where best == nil || best!.hand == hand { // ours: 0 right, 1 left
                let h = hands[hand == 0 ? 1 : 0]
                let d = h.orientation.act(SIMD3<Float>(0, 0, -1))
                let n = layer.orientation.act(SIMD3<Float>(0, 0, 1))
                let facing = simd_dot(d, n)
                guard abs(facing) > 1e-5 else { continue }
                let t = simd_dot(layer.position - h.position, n) / facing
                guard t > 0 else { continue }
                let hit = h.position + d * t
                let local = layer.orientation.inverse.act(hit - layer.position)
                guard abs(local.x) <= layer.width / 2, abs(local.y) <= height / 2 else { continue }
                // Nearest along that hand's ray.
                if let b = best, b.hand == hand, simd_distance(b.point, h.position) < t { continue }
                best = (i, hand, local.x / layer.width + 0.5, 0.5 - local.y / height, hit)
            }
        }
        if let best {
            let h = hands[best.hand == 0 ? 1 : 0]
            pointing = Pointing(from: h.position, to: best.point, pressed: trigger[best.hand])
            halliday_bridge_set_pointer(b, UInt32(best.overlay + 1), best.hand == 0 ? 2 : 1, trigger[best.hand] && !paused ? 1 : 0,
                                        best.u, best.v, scrollTotal)
            pointerPublished = true
        } else if pointerPublished || pointing != nil {
            pointing = nil
            pointerPublished = false
            halliday_bridge_set_pointer(b, 0, 0, 0, 0, 0, scrollTotal)
        }
    }

    /// The scroll wheel while a game has the input: over an overlay that takes the mouse it
    /// scrolls that; otherwise it moves the hand nearer or farther (the right one, ⇧ the left).
    func scroll(by dy: CGFloat, shift: Bool) {
        guard isPresenting, !paused else { return }
        if pointing != nil {
            scrollTotal &+= Int32(max(-1000, min(1000, dy * 10)))
            return
        }
        let hand = shift ? 1 : 0
        var aim = aims[hand] ?? startAim()
        aim.reach = max(0.12, min(0.8, aim.reach + Float(dy) * 0.004))
        aims[hand] = aim
    }

    /// Moves a hand by a mouse delta (points): it leaves the gaze and stays where it is put.
    func aim(dx: Float, dy: Float, left: Bool) {
        guard isPresenting, !paused else { return }
        let hand = left ? 1 : 0
        var aim = aims[hand] ?? startAim()
        aim.yaw = max(-1.75, min(1.75, aim.yaw - dx * 0.004))
        aim.pitch = max(-1.45, min(1.45, aim.pitch - dy * 0.004))
        aims[hand] = aim
        if !loggedAim {
            loggedAim = true
            log("[game] a hand moved by the mouse (⌥: right, ⌥⇧: left; H brings both back)")
        }
    }

    /// Places a hand (scripted tests: `--game-keys aim:YAW:PITCH:REACH@A-B`).
    func setAim(_ aim: HandAim, left: Bool) { aims[left ? 1 : 0] = aim }

    /// Both hands follow the gaze again.
    func resetHands() { aims = [nil, nil] }

    private func startAim() -> HandAim { HandAim(yaw: 0, pitch: headPitch, reach: 0.4) }

    // MARK: - Simulator input

    /// A key while a game presents: true if it was the game's. `keyCode` as NSEvent's.
    func key(_ keyCode: UInt16, down: Bool, shift: Bool) -> Bool {
        guard isPresenting, !paused else { return false }
        if keyCode == 4 { // H: both hands back to following the gaze
            if down { resetHands() }
            return true
        }
        guard [48, 49, 123, 124, 125, 126].contains(keyCode) else { return false }
        shiftHeld = shift
        if down, !heldKeys.contains(keyCode), loggedKeys.insert(keyCode).inserted {
            let what = [48: "Tab: menu", 49: "Space: touchpad click", 123: "←: touchpad left", 124: "→: touchpad right",
                        125: "↓: touchpad down", 126: "↑: touchpad up"][keyCode] ?? "?"
            log("[game] key \(what), \(shift ? "left" : "right") controller")
        }
        if down { heldKeys.insert(keyCode) } else { heldKeys.remove(keyCode) }
        return true
    }
}
