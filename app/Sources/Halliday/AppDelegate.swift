// App shell: picks the output (headset display or preview window), owns the pose sources, the
// Mac windows in VR and the mouse, and handles keys.
//
// Two states:
// - Halliday: the mouse is locked to Halliday (the Mac's cursor stays still and hidden; mouse motion
//   only moves the VR pointer), right-drag looks around, W/A/S/D/Q/E walk. The mouse starts free:
//   a click inside the scene captures it; Control twice or switching apps releases it. Keys:
//   1 mouse · 2 replay · 3 headset (USB) · M window picker · B browser · O video · R recenter · D lens · L test layer ·
//   Esc quit.
// - Interacting (after clicking a VR window): the real mouse goes to the window under the pointer
//   (see MouseOwner) and its app gets the keyboard. Control twice, Option+Esc or a click on empty
//   space returns to Halliday.

import AudioToolbox
import CoreAudio
import AppKit
import CHallidayCore
import Metal
import simd

/// Size of the headset's display as macOS reports it (the current headset's: HeadsetAdapter.swift).
var headsetPanelPixels: CGSize { Headsets.current.panelPixels }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MouseOwnerDelegate {
    private var window: NSWindow?
    private var view: HeadsetView?
    private var renderer: Renderer?
    /// A VR game under Wine, through Halliday's OpenVR runtime (nil if the runtime isn't in the app).
    private var game: GameBridge?
    private var gameImageReconfiguration: DispatchWorkItem?
    /// A game is showing its frames (the mouse turns the head, clicks are its controller's).
    /// A game under Wine is presenting (its frames fill the view; W/A/S/D walk whatever the mode).
    /// A game presents and has the input (Halliday isn't up over it).
    var gameActive: Bool { game?.isPresenting == true && !gameAway }
    /// Halliday is up over a running game (design board 14): Esc toggles it.
    private var gameAway = false
    private var gameBar: GameBar?
    private var games: GamesPanel?
    private var gamesOpen = false
    private var lastGamesRefresh = 0.0
    private var lastAwayTick = 0.0
    private let mouse = MouseLook()
    private var replay: TrackedSource?
    private var usb: TrackedSource?
    private var testLayer: QuadLayer?
    private var windowManager: WindowManager?
    private let mouseOwner = MouseOwner()
    /// The PS VR2 Sense controllers (SenseControllers.swift): the one in use aims Halliday's
    /// pointer, its trigger clicks, its grip right-clicks and its stick scrolls.
    /// Hold PS to recenter; a tap in a game opens or closes Halliday's dashboard.
    private let sense = SenseControllers()
    private var senseHand = SenseControllers.Hand.right
    private var senseButtons: [SenseControllers.Hand: SenseControllers.Buttons] = [:]
    private var senseSeeded: Set<SenseControllers.Hand> = []
    /// When a controller last moved or was pressed: it has the pointer until the mouse moves.
    private var senseActivity: CFTimeInterval = 0
    /// What turns a controller's sensor axes into where it points, per hand: a tilt about its
    /// own x (the sensor sits tilted in the grip) and a heading about y (no compass).
    /// The original 42° mount correction remains until the user deliberately
    /// calibrates from the game panel; controller button taps never retune it.
    private var senseTilt: [SenseControllers.Hand: Float] = {
        let saved = SenseAimDefaults.load(from: .standard)
        return [.left: saved.left, .right: saved.right]
    }()
    private var senseHeading: [SenseControllers.Hand: Float] = [:]
    /// True while a controller, not the mouse, has the pointer: the saber then leaves from the hand.
    private var senseHasPointer = false

    /// A controller's orientation when the frame being drawn is seen: carried forward from its
    /// newest report (they come 60 times a second over Bluetooth, and a frame takes about 30 ms
    /// to reach the eyes) by its own angular velocity. Unpredicted, the pointer trailed the hand.
    private func sensePredicted(_ state: SenseControllers.State) -> simd_quatf {
        let ahead = min(0.08, state.age + Float((view?.lookaheadMs ?? 30) / 1000))
        let turn = state.angularVelocity * ahead
        let angle = simd_length(turn)
        guard angle > 1e-5 else { return state.orientation }
        return state.orientation * simd_quatf(angle: angle, axis: turn / angle)
    }

    private func senseAim(_ hand: SenseControllers.Hand, _ orientation: simd_quatf) -> simd_quatf {
        seenLean(hand) * simd_quatf(angle: senseHeading[hand] ?? 0, axis: [0, 1, 0]) * orientation * simd_quatf(angle: senseTilt[hand] ?? SenseAimDefaults.tilt, axis: [1, 0, 0])
    }

    /// The lean the cameras see between a controller's IMU and the room (`HallidayHandFix.tilt`),
    /// as a turn in the room: with it, the pointer's pitch and roll are the controller's as the
    /// cameras see it, not only its heading. Most of it is the IMU's own error while the hand
    /// moves (its accelerometer, pulling "up" towards gravity, is pulled aside too), which its
    /// filter undoes within a second or so: so it is taken while the controller is seen, and
    /// fades out over 0.3 s once it is not.
    private func seenLean(_ hand: SenseControllers.Hand) -> simd_quatf {
        guard let lean = leanSeen[hand] else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let since = Float(max(0, CACurrentMediaTime() - lean.time - 0.1))
        let v = lean.turn * exp(-since / 0.3)
        let angle = simd_length(v)
        return angle > 1e-5 ? simd_quatf(angle: angle, axis: v / angle) : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }

    /// The controller points where the head looks, the user says: its heading, and with `tilt`
    /// its tilt too, are set to make that so.
    private func calibrateSense(_ hand: SenseControllers.Hand, _ orientation: simd_quatf, head: HeadPose, tilt: Bool) {
        let look = Self.angles(of: head.orientation.act(SIMD3<Float>(0, 0, -1)))
        if tilt {
            // A deliberate new calibration replaces the previous manual offset,
            // even when the cameras have no recent heading for this hand.
            headingOffset[hand] = nil
            // The tilt whose aim is as high as the head looks (a scan: roll makes it no formula).
            var best: (tilt: Float, off: Float) = (0, .infinity)
            let leaned = seenLean(hand) * orientation
            for step in -180...180 {
                let t = Float(step) * 0.5 * .pi / 180
                let aim = (leaned * simd_quatf(angle: t, axis: [1, 0, 0])).act(SIMD3<Float>(0, 0, -1))
                let off = abs(asin(max(-1, min(1, aim.y))) - look.pitch)
                if off < best.off { best = (t, off) }
            }
            senseTilt[hand] = best.tilt
            UserDefaults.standard.set(best.tilt, forKey: "senseTilt.\(hand.name)")
            log(String(format: "[sense] %@ controller: tilt %.1f°", hand.name, best.tilt * 180 / .pi))
        }
        senseHeading[hand] = 0
        let aim = Self.angles(of: senseAim(hand, orientation).act(SIMD3<Float>(0, 0, -1)))
        senseHeading[hand] = look.yaw - aim.yaw
        // With the cameras following the heading (`--hands`), what the user just set is kept as
        // an offset from what they see, so it holds while the gyro drifts.
        // (Only when the user asks: a controller that merely connects starts from the cameras'.)
        if tilt, let seen = seenHeading[hand], let place = handPlaces[hand], CACurrentMediaTime() - place.time < 3 {
            headingOffset[hand] = look.yaw - aim.yaw - seen
        }
    }
    private var picker: WindowPicker?
    /// The dock (Night Glass bottom menu); placed in front on the first frame and on recenter.
    private var dock: Dock?
    private var dockNeedsPlacement = true
    // The dock and the keyboard stay at a fixed distance from the user: their offset from the head
    // when placed, which they glide back to when the user has moved away from it (lazy follow).
    private var dockOffset: SIMD3<Float>?
    private var keyboardOffset: SIMD3<Float>?
    private var following: Set<ObjectIdentifier> = []
    private var lastFollowTime = CACurrentMediaTime()
    private var lastMode = Settings.shared.mode
    /// Free places for the window being dragged (arc layout), and which one it is over.
    private var dropSlots: [(slot: WindowManager.DropSlot, panel: SlotPanel)] = []
    private var dropSlotsShown = false
    private var dropSlotsPending = false
    /// Home: shown while nothing is open (design board 10).
    private var realTime: NSObjectProtocol?
    private var home: HomePanel?
    private var homeOffset: SIMD3<Float>?
    private var homeWasShown = false
    /// Each browser window's tabs, toolbar and address bar, above its page (by window number).
    private var browserBars: [Int: BrowserBar] = [:]
    /// The bar being typed in, else the current browser's.
    private var browserBar: BrowserBar? {
        browserBars.values.first { $0.isEditing } ?? browser.flatMap { browserBars[$0.window.windowNumber] }
    }
    /// A browser window's own settings panel, beside it, while open.
    private var browserSettings: (panel: BrowserSettings, window: Int)?
    /// The arc that appears at a window's corner to resize it, and where it is now.
    private var resizeHandle: ResizeHandle?
    private var resizeTarget: (window: CGWindowID, corner: ResizeHandle.Corner)?
    /// Quick settings, above the dock while open.
    private var quickSettings: QuickSettings?
    private var quickSettingsOpen = false
    /// Short messages to the user in VR.
    private var notice: NoticePanel?
    private var noticeUntil = 0.0
    /// The file browser (videos on the Mac), while open.
    private var fileBrowser: FileBrowser?
    private var fileBrowserOpen = false
    /// The video player's controls, while a video is open.
    private var videoControls: VideoControls?
    /// The player's view drawer, above its bar while the bar's "View" is on.
    private var videoView: VideoViewPanel?
    /// The picture at the place on the seek bar under the pointer.
    private var scrubPreview: ScrubPreview?
    private var subtitles: SubtitlePanel?
    // The app's own cursor (a text beam, a hand…) shown at the pointer while a window is in use.
    private var cursorLayer: QuadLayer?
    private var cursorKey = ""
    private var cursorHot = CGPoint.zero
    private var cursorSize = CGSize.zero
    private var cursorIsArrow = true
    private var lastCursorCheck = 0.0
    // Built-in apps (ROADMAP W13): Photos and Notes; Files is the file browser listing everything.
    private var photos: PhotoViewer?
    private var photoControls: PhotoControls?
    private var photoControlsNeedPlacement = false
    private var notes: NotesPanel?
    private var notesOpen = false
    private var clock: ClockPanel?
    private var clockOpen = false
    /// First launch in the headset: the panel that hands setup to the Mac (SetupPanel.swift).
    private var setupPanel: SetupPanel?
    private var setupPanelOpen = false
    private var setupPanelPlaced = false
    private var controls: ControlsPanel?
    private var controlsOpen = false
    private var music: MusicPanel?
    private var musicOpen = false {
        didSet { if !musicOpen { music?.stop() } }
    }
    /// The screens of the video player and of Photos (drawn with the windows' layers).
    private var videoScreen: QuadLayer?
    private var photoScreen: QuadLayer?
    private func updateScreens() { windowManager?.contentLayers = [videoScreen, photoScreen].compactMap { $0 } }
    private var videoControlsNeedPlacement = false
    private var lastVideoControlsRefresh = 0.0
    /// While a video plays, the controls and the dock step aside after a few seconds without the
    /// pointer moving, and come back when it moves.
    private var lastPointerActivity = CACurrentMediaTime()
    /// A video's controls and the dock were put away from a controller, until it or the mouse
    /// brings them back; `chromeShown`: whether they were up in the last frame.
    private var chromeDismissed = false
    /// Passthrough was switched on by a video keyed for it: it goes off with the video.
    private var passthroughForVideo = false
    private var chromeDismissedAt = 0.0
    /// Puts a video's controls and the dock away (the bar's button, or a controller's cross):
    /// a trigger, cross again or the mouse brings them back.
    private func dismissChrome() {
        chromeDismissed = true
        chromeDismissedAt = CACurrentMediaTime()
    }
    private var chromeShown = true
    private var lastStickTime = CACurrentMediaTime()
    private var lastPointerDirection = SIMD3<Float>(0, 0, -1)
    /// Seated mode: the arc of panels is re-anchored around the head on the next frame (launch, recenter).
    private var anchorNeeded = true
    /// The next anchoring happens in room-scale mode too (the user asked to recenter).
    private var anchorForced = false
    /// When the recenter button went down (hold-to-recenter), and whether this hold already fired.
    private var recenterHoldStart: Double?
    private var recenterHoldFired = false
    static let recenterHoldSeconds = 0.8
    /// The virtual keyboard, while open (the dock gives it its place).
    private var keyboard: KeyboardPanel?
    private var keyboardOpen = false
    /// The full Settings panel, while open.
    private var settingsPanel: SettingsPanel?
    private var settingsOpen = false
    /// A window being resized by its bar's grip: where the pointer met the window's plane when it
    /// began (in the plane's own coordinates, meters), the size it had, and when it was last applied.
    private var resizing: (window: CGWindowID, origin: SIMD3<Float>, orientation: simd_quatf, start: SIMD2<Float>,
                           size: CGSize, metersPerPoint: Float, lastApplied: Double)?
    /// The place the user stands in.
    private var environments: Environments?
    private var appliedEnvironment: String?
    /// The app launcher, while open.
    private var launcher: AppLauncher?
    private var launcherOpen = false
    private var focusWasEngaged = false
    /// When the handle of a window's bar was last clicked without dragging (twice = back to the arc).
    private var lastHandleClick: (window: CGWindowID, time: Double)?
    private var dragStartPointer = SIMD3<Float>(0, 0, -1)
    private var dragMoved = false
    /// The browser window is being moved into VR (asynchronous).
    private var browserOpening = false
    /// The bar under each window in VR (grab handle, close), by window.
    private var panelBars: [CGWindowID: PanelBar] = [:]
    /// A window being dragged by its bar: the offset between the pointer and the window's center
    /// (as angles from the head), its distance, and its scale per meter of distance.
    private var drag: (window: CGWindowID, yaw: Float, pitch: Float, distance: Float, scale: Float)?
    private var lastDockClock = 0.0
    /// The pointer's button is down on Halliday's own UI or the scene (the saber shows it pressed).
    private var pointerDown = false
    /// Halliday's browser windows. Several can be open; `browser` is the current one: the one last
    /// used, or the one whose page is in VR.
    private var browsers: [BrowserWindow] = []
    private var currentBrowser: Int?
    var browser: BrowserWindow? { browsers.first { $0.window.windowNumber == currentBrowser } ?? browsers.last }
    static let maxBrowsers = 4

    private func browser(forWindow id: CGWindowID) -> BrowserWindow? { browsers.first { CGWindowID($0.window.windowNumber) == id } }
    private var video: VideoPlayer?
    private var lastIdlePosePush = CACurrentMediaTime()
    /// Head rotations sent to the WebXR page, by id: a captured frame's stamp says which one it used.
    private var nextPoseID: UInt16 = 1
    private var sentPoses: [UInt16: HeadPose] = [:]
    private var lastStampedID: UInt16?
    /// WebXR presentation statistics since the last [stat] line.
    private var xrFrames = 0, xrMissedStamps = 0, xrLagTotal = 0
    /// When the frame each pose was sent to the page in was to be seen, and from that how long
    /// after it the page's frame drawn with the pose is seen (seconds, smoothed).
    private var sentTargets: [UInt16: Double] = [:]
    private var xrLead = 0.0
    /// `--app-prediction`: apps and pages get the head predicted for when their frame is seen,
    /// not the head of the frame it is sent in. Off: it showed nothing to the user, and a
    /// prediction that far carries a vibration of the head into the pose.
    private static let predictsForApps = CommandLine.arguments.contains("--app-prediction")
    /// The head `lead` seconds after this frame is seen, as the tracker predicts it (the
    /// simulator's and a recording's heads are given as they are).
    private func headAhead(_ head: HeadPose, by lead: Double) -> HeadPose {
        guard lead > 0.001, let source = view?.source as? TrackedSource else { return head }
        return source.pose(atHostNs: Int64((HeadsetView.frameTarget + lead) * 1e9)) ?? head
    }
    /// Head pose of the frame being shown, for pointer hit tests between frames.
    private var lastHead: HeadPose?
    private var lastFrameRefresh = CACurrentMediaTime()
    private let replayPath: String?
    /// The Mac's cursor is frozen (and hidden over the preview); only mouse deltas move the pointer.
    private var pointerLocked = false
    /// The user captured the mouse for VR (by clicking in the scene) and hasn't released it. Only
    /// then is the lock re-applied when Halliday becomes active again.
    private var pointerEngaged = false
    /// Halliday's output is the headset's display (its window is the borderless `HeadsetWindow`).
    private var onHeadset = false
    private var lastControlTap: CFTimeInterval = 0
    private var flagsMonitor: Any?
    /// `--test-headset`'s display.
    private var testHeadset: VirtualDisplay?
    /// The headset display's rate (90 without one), told to games.
    private var headsetHz: Float = 90

    init(replayPath: String?) {
        self.replayPath = replayPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A VR runtime must never be slowed down by App Nap: its window on the Mac is often hidden
        // (the headset is the output), and its timers and frames must keep their pace.
        realTime = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Rendering VR")
        guard let device = MTLCreateSystemDefaultDevice() else { fatal("No Metal device") }
        // Debug: --test-headset HZ makes an invisible display the headset's size at HZ and drives
        // it as the headset (its full path: both eyes, lens warp, its rate), for measurements
        // without the headset.
        let launchArgs = CommandLine.arguments
        // Debug: --test-headset-at SECONDS HZ makes that display only SECONDS after launch, as a
        // headset plugged in while Halliday runs (`lookForHeadset`).
        if let i = launchArgs.firstIndex(of: "--test-headset-at"), i + 2 < launchArgs.count,
           let delay = Double(launchArgs[i + 1]), let hz = Double(launchArgs[i + 2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.testHeadset = VirtualDisplay(name: "Halliday Test Headset", size: headsetPanelPixels, hiDPI: false, refreshRate: hz, serial: 3)
                log("[display] test headset plugged in (\(Int(hz)) Hz)")
            }
        }
        if let i = launchArgs.firstIndex(of: "--test-headset"), i + 1 < launchArgs.count, let hz = Double(launchArgs[i + 1]) {
            testHeadset = VirtualDisplay(name: "Halliday Test Headset", size: headsetPanelPixels, hiDPI: false, refreshRate: hz, serial: 3)
            let end = Date().addingTimeInterval(4)
            while Date() < end, !NSScreen.screens.contains(where: { $0.convertRectToBacking($0.frame).size == headsetPanelPixels }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            log("[display] test headset display at \(Int(testHeadset?.actualRefreshRate ?? 0)) Hz")
        }
        // Debug: --ignore-headset-at-launch starts on the Mac's screen even with the headset
        // there, as if it were plugged in afterwards (`lookForHeadset` takes it on later).
        let headsetScreen = launchArgs.contains("--ignore-headset-at-launch") || launchArgs.contains("--ignore-headset") ? nil : NSScreen.screens.first { screen in
            screen.convertRectToBacking(screen.frame).size == headsetPanelPixels
        }
        headsetHz = headsetScreen.map { Float($0.maximumFramesPerSecond) } ?? 90
        LateLatch.displayHz = headsetHz
        let renderer: Renderer
        do {
            // On the headset, render above panel resolution (the lenses magnify the center).
            renderer = try Renderer(device: device, eyeSize: headsetScreen != nil ? Headsets.current.renderEyeSize : 1280)
        } catch {
            fatal("Renderer failed: \(error)")
        }
        self.renderer = renderer
        windowManager = WindowManager(renderer: renderer)
        startGameBridge(renderer)
        if !CommandLine.arguments.contains("--no-sense") { sense.start() }
        // Windows a previous run left on its (now gone) virtual display go back to their place.
        windowManager?.ledger.restoreLeftovers()
        if let wm = windowManager {
            let picker = WindowPicker(renderer: renderer, manager: wm)
            picker.onClose = { [weak self] in self?.lastDockClock = 0 }
            picker.onNotice = { [weak self] text in self?.notify(text) }
            self.picker = picker
            wm.onNotice = { [weak self] text in
                // What couldn't be done reads as a warning; what merely happened, as information.
                let problem = ["can't", "couldn't", "isn't", "At most", "has no"].contains { text.contains($0) }
                self?.notify(text, kind: problem ? .warning : .info)
            }
            wm.onFull = { [weak self, weak wm] in
                self?.notify("\(wm?.maxWindows ?? 8) windows fit in VR", kind: .warning, action: ("Choose one to send back", { [weak self] in
                    if self?.picker?.isOpen != true { self?.handleKey("m") }
                }))
            }
            picker.onOpenApps = { [weak self] in if self?.launcherOpen != true { self?.toggleLauncher() } }
            wm.onActivatedAnotherApp = { [weak self] in self?.takeFocusBack() }
            wm.onWindowLeft = { [weak self] id in
                // A browser's window went away by itself: forget that browser.
                guard let self, let b = browser(forWindow: id) else { return }
                b.endXR()
                b.window.orderOut(nil)
                browsers.removeAll { $0 === b }
                lastDockClock = 0
            }
        }
        ClockModel.shared.onTimerDone = { [weak self] in
            Sounds.play(.chime)
            self?.notify("The timer is done", symbol: "timer", action: ("Again", { ClockModel.shared.toggleTimer() }))
        }
        notice = NoticePanel(renderer: renderer)
        notice?.onDone = { [weak self] in self?.noticeUntil = 0 }
        let dock = Dock(renderer: renderer)
        dock.onActivate = { [weak self] id in
            switch id {
            case "apps": self?.toggleLauncher()
            case "keyboard": self?.toggleKeyboard()
            case "windows": self?.handleKey("m")
            case "browser": self?.handleKey("b")
            case "videos": self?.handleKey("o")
            case "recenter": self?.handleKey("r")
            case "settings": self?.toggleQuickSettings()
            case "clock": self?.openClock()
            default: break
            }
        }
        self.dock = dock
        windowManager?.uiLayers = [dock.layer]
        renderer.showReferenceBoxes = CommandLine.arguments.contains("--reference-boxes")
        environments = Environments(renderer: renderer)
        environments?.onNotice = { [weak self] text in self?.notify(text) }
        // Debug: --environment ID shows that place for this run (grid, dusk, terrace, focus, image:<file>).
        if let i = CommandLine.arguments.firstIndex(of: "--environment"), i + 1 < CommandLine.arguments.count {
            appliedEnvironment = CommandLine.arguments[i + 1]
            environments?.apply(CommandLine.arguments[i + 1])
        }
        Settings.shared.onChange = { [weak self] in self?.applySettings() }
        applySettings()
        video = try? VideoPlayer(renderer: renderer)
        applyVolume()
        video?.onScreenChange = { [weak self] layer in
            self?.videoScreen = layer
            self?.updateScreens()
        }
        // Photos: a picture on a screen or around the viewer, in theater mode like a video.
        let photos = PhotoViewer(renderer: renderer)
        self.photos = photos
        photos.onScreenChange = { [weak self] layer in
            self?.photoScreen = layer
            self?.updateScreens()
        }
        photos.onNotice = { [weak self] text in self?.notify(text, kind: .warning) }
        photos.onChange = { [weak self] in self?.photoControls?.setNeedsDisplay() }
        photos.onOpenChange = { [weak self] open in
            guard let self else { return }
            renderer.fadeScene()
            if open { video?.close() }
            windowManager?.windowsHidden = open || video?.isOpen == true
            if open, let photos = self.photos {
                picker?.close()
                let controls = PhotoControls(renderer: dock.renderer, viewer: photos)
                controls.onRecenter = { [weak self] in self?.handleKey("r") }
                photoControls = controls
                photoControlsNeedPlacement = true
            } else if !open {
                photoControls = nil
            }
            lastDockClock = 0
        }
        video?.onNotice = { [weak self] text, problem in
            self?.notify(text, kind: problem ? .warning : .progress, seconds: problem ? nil : 60)
        }
        video?.onSubtitle = { [weak self] text in self?.subtitles?.text = text }
        // At a video's end: the next one of its folder is a click away.
        video?.onEnded = { [weak self] url in
            guard let self, let next = VideoPlayer.next(after: url) else { return }
            self.notify("Next: \(next.deletingPathExtension().lastPathComponent)", symbol: "forward.end.fill",
                        action: ("Play", { [weak self] in self?.playNextVideo() }), seconds: 15)
        }
        // Theater mode while a video is open; the window picker closes too.
        video?.onOpenChange = { [weak self] open in
            guard let self else { return }
if !open, passthroughForVideo {
                // The room was on for a video made for passthrough: it goes with the video
                // (left on, it stayed behind everything after the video closed).
                passthroughForVideo = false
                if passthrough { togglePassthrough() }
            }
                        renderer.fadeScene()
            if open { self.photos?.close() }
            windowManager?.windowsHidden = open || self.photos?.isOpen == true
            if open, notice?.kind == .progress { noticeUntil = 0 } // "Preparing…" is over
            if open {
                picker?.close()
                if let dock = self.dock, let video = self.video {
                    let controls = VideoControls(renderer: dock.renderer, video: video)
                    controls.onRecenter = { [weak self] in self?.handleKey("r") }
                    controls.onCycle = { [weak self] what in self?.handleKey(what == "projection" ? "f" : "g") }
                    controls.onInfo = { [weak self] text in self?.notify(text) }
                    controls.onHide = { [weak self] in self?.dismissChrome() }
                    // A video keyed for passthrough wants the room behind it, and an ordinary
                    // one doesn't: the cameras follow the choice (on the headset).
                    controls.onBackdrop = { [weak self] in
                        guard let self, self.usb?.headset != nil, let video = self.video, video.keyed != self.passthrough else { return }
                        self.togglePassthrough()
                        self.passthroughForVideo = self.passthrough
                    }
                    subtitles = SubtitlePanel(renderer: dock.renderer)
                    videoControls = controls
                    let drawer = VideoViewPanel(renderer: dock.renderer, video: video)
                    drawer.onChoose = { [weak controls] id in controls?.choose(id) }
                    videoView = drawer
                    scrubPreview = ScrubPreview(renderer: dock.renderer)
                    controls.onNext = { [weak self] in self?.playNextVideo() }
                    controls.onBackdrop?() // a file that says it is made for passthrough
                    videoControlsNeedPlacement = true
                    lastPointerActivity = CACurrentMediaTime()
                    chromeDismissed = false
                }
            } else {
                videoControls = nil
                videoView = nil
                scrubPreview = nil
                subtitles = nil
            }
            lastDockClock = 0
        }
        windowManager?.onFrameCaptured = { [weak self] pixels, bounds, texture, window, content in
            self?.presentWebXRFrame(pixels, bounds: bounds, texture: texture, window: window, content: content)
        }
        mouseOwner.delegate = self
        installMainMenu()

        if let tex = renderer.makeLayerTexture(width: 1600, height: 1000, rgba: TestLayer.rgba(width: 1600, height: 1000)) {
            let layer = QuadLayer(texture: tex, position: [0, 1.6, -1.0], width: 1.6)
            testLayer = layer // shown with L
        }

        var initial: PoseSource = (replayPath != nil ? replaySource() : nil) ?? mouse
        // On the headset's display, its own tracking; 1 still switches to the mouse.
        if replayPath == nil, headsetScreen != nil {
            usb = TrackedSource(name: "headset", headset: Headsets.current.openSession())
            initial = usb!
        }

        let window: NSWindow
        if let screen = headsetScreen {
            // Borderless, above the menu bar, on the headset's display.
            window = HeadsetWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            onHeadset = true
            headsetWindow = window
            // With `screen:`, AppKit takes the rectangle as relative to that screen: a headset
            // display at (-4000, -744) put the window at (-8000, -1488), on no screen, at 0 Hz.
            // Its frame is set in global coordinates.
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            log("[display] headset display found: \(screen.localizedName)")
        } else {
            // On a monitor: the desktop view (one undistorted view at the window's own resolution).
            // P switches to what the headset would get (both eyes, lens-warped), for debugging.
            renderer.desktopView = !CommandLine.arguments.contains("--headset-view")
            let size = renderer.desktopView ? NSSize(width: 1440, height: 900)
                : NSSize(width: 1200, height: 1200 * headsetPanelPixels.height / headsetPanelPixels.width)
            window = PreviewWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                   backing: .buffered, defer: false)
            if !renderer.desktopView { window.contentAspectRatio = headsetPanelPixels }
            // Follow the user to whatever Space is active when Halliday is brought back. No macOS
            // full screen: that would put Halliday in a Space of its own, and windows of other apps
            // can't be moved from another Space (launching an app then brings nothing in). The
            // green button and ⌃⌘F fill the screen in the current Space instead.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
            if let zoom = window.standardWindowButton(.zoomButton) {
                zoom.target = self
                zoom.action = #selector(toggleFillScreen)
            }
            window.center()
            log("[display] no \(Headsets.current.shortName) display found: preview window on the main screen")
        }
        let view = HeadsetView(frame: window.contentLayoutRect, renderer: renderer, source: initial)
        if let screen = headsetScreen {
            view.headsetDisplay = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        view.onFrame = { [weak self] head in self?.frameTick(head: head) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        if headsetScreen != nil {
            log("[display] Halliday's window on \(window.screen?.localizedName ?? "no screen") at \(window.frame), \(window.screen?.maximumFramesPerSecond ?? 0) Hz")
        }
        window.makeFirstResponder(view)
        self.window = window
        self.view = view
        // A headset plugged in later is taken on when its display appears (a display's mode
        // settles over a moment: looked at a second after macOS says the displays changed).
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { _ = self?.lookForHeadset() } }
        }
        updateTitle()
        log("[keys] video: O file browser (⇧O Mac dialog) · V watch the browser's video in VR · Space play/pause · ←/→ ±10 s · F projection · G stereo · C subtitles · R recenter · X close")
        log("[keys] P preview: desktop view / headset view (both eyes, lens) · , quick settings")
        log("[keys] A apps · M Mac windows · B browser · E files · N notes · K keyboard · , quick settings · . settings · hold R recenter · 1 mouse · 2 replay · 3 headset · D lens · L test layer · Esc close / quit")
        log("[keys] click a VR window to use it; Control twice, Option+Esc or a click on empty space returns to Halliday")
        // Tests (`open -g … --args --no-activate`): stay in the background, so the user's typing in
        // another app never lands in Halliday.
        if !CommandLine.arguments.contains("--no-activate") { NSApp.activate() }
        // Moving windows onto the virtual display must always be the user's explicit choice (M),
        // and Halliday must never come back by itself after a restart or log-in.
        NSApp.disableRelaunchOnLogin()
        window.isRestorable = false

        // Control twice (while Halliday has focus and no window is in use) frees the mouse.
        // The mouse starts free: clicking inside the scene captures it.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.controlKey(event)
            return event
        }

        // The Mac's volume keys set Halliday's master volume while the Mac's output has no
        // volume of its own (the headset's sound over DisplayPort): there the keys do nothing.
        // The companion on the Mac's own screen, in view from the start when Halliday is on the
        // headset (not in test runs, which must not put windows on the user's screen).
        let quiet = ["--no-activate", "--keys-snapshot", "--picker-snapshot", "--test-headset", "--no-companion"]
        let testRun = CommandLine.arguments.contains(where: quiet.contains)
        // macOS's permission prompts appear where Halliday's active window is: the companion,
        // on the Mac's own screen, is put in front before any is asked for (Permissions.swift).
        Permissions.shared.bringAskerForward = { [weak self] in
            guard let self else { return }
            self.setPointerLock(false)
            self.pointerEngaged = false
            self.showCompanion(activating: true)
            if self.onHeadset { self.notify("macOS is asking on your Mac's screen: take off the headset to answer", kind: .warning, seconds: 10) }
        }
        Permissions.shared.askerIsElsewhere = { [weak self] in self.map { $0.onHeadset || $0.desktopMode } ?? false }
        // Updates (opt-in): Sparkle's window would land on the headset's display, so while the headset
        // is connected an update found is said in the headset and installed from the companion.
        Updates.shared.onHeadset = Permissions.shared.askerIsElsewhere
        Updates.shared.bringForward = { [weak self] in
            guard let self else { return }
            self.setPointerLock(false)
            self.pointerEngaged = false
            self.showCompanion(activating: true)
            if self.onHeadset { self.notify("Halliday's updater is on your Mac's screen: take off the headset to answer", kind: .warning, seconds: 10) }
        }
        Updates.shared.notify = { [weak self] text in self?.notify(text, seconds: 8) }
        Updates.shared.start(testRun: CommandLine.arguments.contains(where: ["--no-activate", "--keys-snapshot", "--picker-snapshot", "--test-headset", "--no-companion", "--snapshot", "--setup-snapshot"].contains))
        if onHeadset, !testRun { showCompanion(activating: false) }
        // Setup not done (the first launch): the companion opens on it, and the headset says to
        // take it off and go to the Mac. Otherwise a permission missing is asked for at once, in
        // the companion (with why each is needed), and said in the headset.
        Setup.shared.onFinish = { [weak self] done in
            guard let self, let panel = self.setupPanel, self.setupPanelOpen else { return }
            if done { panel.ready = true } else { self.setupPanelOpen = false }
        }
        // Debug: --setup-panel shows the headset's setup panel (board 16) in any run.
        if CommandLine.arguments.contains("--setup-panel") { openSetupPanel() }
        if !testRun, !Setup.shared.done {
            Setup.shared.start()
            showCompanion(activating: true)
            if onHeadset { openSetupPanel() }
        } else if !testRun, !Permissions.shared.allGranted {
            showCompanion(activating: true)
            if onHeadset {
                notify("Halliday needs \(Permissions.shared.missing.map(\.title).joined(separator: " and ")): take off the headset and allow it on your Mac's screen",
                       kind: .warning, seconds: 12)
            }
        }
        if CommandLine.arguments.contains("--companion") { showCompanion() }
        // Debug: --desktop-mode A[-B] switches to the Mac's screen A seconds in (and back at B).
        if let i = CommandLine.arguments.firstIndex(of: "--desktop-mode"), i + 1 < CommandLine.arguments.count {
            let times = CommandLine.arguments[i + 1].split(separator: "-").compactMap { Double($0) }
            for (k, t) in times.prefix(2).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.setDesktopMode(k == 0) }
            }
        }
        volumeMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.volumeKey(event)
            return event
        }

        // Debug: --keys-snapshot KEYS FILE presses KEYS (e.g. "m" picker, "b" browser) at launch,
        // waits for content to load, saves a frame and quits. --picker-snapshot FILE = "m".
        let args = CommandLine.arguments
        var debugKeys: String?, debugPath: String?
        if let i = args.firstIndex(of: "--keys-snapshot"), i + 2 < args.count {
            debugKeys = args[i + 1]; debugPath = args[i + 2]
        } else if let i = args.firstIndex(of: "--picker-snapshot"), i + 1 < args.count {
            debugKeys = "m"; debugPath = args[i + 1]
        }
        // Debug: --pointer YAW PITCH (degrees, from the view's center) aims the VR pointer.
        if let i = args.firstIndex(of: "--pointer"), i + 2 < args.count, let yaw = Double(args[i + 1]), let pitch = Double(args[i + 2]) {
            let y = Float(yaw * .pi / 180), p = Float(pitch * .pi / 180)
            InputState.shared.aim(SIMD3(-sin(y) * cos(p), sin(p), -cos(y) * cos(p)))
        }
        // Debug: --bring NAME brings every window of apps whose name contains NAME into VR, 3 s after
        // launch (minimized and full-screen ones included), for snapshots.
        if let i = args.firstIndex(of: "--bring"), i + 1 < args.count {
            let name = args[i + 1].lowercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                Task { @MainActor in
                    guard let wm = self?.windowManager, let list = await wm.candidates() else { return }
                    for c in list where c.appName.lowercased().contains(name) && c.state != .inVR {
                        log("[debug] bringing \(c.appName) — \(c.title) (\(c.state))")
                        await wm.bring(c)
                    }
                }
            }
        }
        // Debug: --click X Y (repeatable) clicks at that spot of the view, −1…1 from its center (x right,
        // y up), 3 s after launch and 1.5 s apart; --notice TEXT shows a notice.
        var clickDelay = 3.0
        for (i, a) in args.enumerated() where a == "--click" && i + 2 < args.count {
            guard let x = Double(args[i + 1]), let y = Double(args[i + 2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + clickDelay) { [weak self] in
                guard let self else { return }
                if pointerLocked { InputState.shared.aim(self.desktopDirection(CGPoint(x: x, y: y))) }
                clickedInView(rightButton: false, at: CGPoint(x: x, y: y))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.releasedInView(rightButton: false) }
            }
            clickDelay += 1.5
        }
        if let i = args.firstIndex(of: "--notice"), i + 1 < args.count {
            let text = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.notify(text) }
        }
        // Debug: --launch PATH starts the app at PATH through the launcher's own path, 2 s after launch.
        if let i = args.firstIndex(of: "--launch"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.launch(AppLauncher.App(id: url.path, name: url.deletingPathExtension().lastPathComponent, url: url, symbol: nil))
            }
        }
        // Debug: --close-first closes the first Mac window in VR for real, 10 s after launch.
        if args.contains("--close-first") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if let id = self?.windowManager?.windows.first(where: { $0.own == nil })?.windowID { self?.closePanel(id) }
            }
        }
        // Debug: --address TEXT types TEXT in the browser's address bar, --find TEXT searches the page
        // for it, --resize-test DW DH resizes the first VR window by that many points; 6 s after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
            if let text = value("--address") {
                updateBrowserBar()
                browserBar?.beginEditing()
                browserBar?.insert(text)
            }
            if let text = value("--find") {
                findInPage()
                browserBar?.insert(text)
                browserBar?.commit()
            }
            if let i = args.firstIndex(of: "--resize-test"), i + 2 < args.count, let dw = Double(args[i + 1]), let dh = Double(args[i + 2]),
               let wm = windowManager, let w = wm.windows.first {
                wm.resize(w.windowID, to: CGSize(width: w.frame.width + dw, height: w.frame.height + dh))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wm.settleLayout() }
            }
        }
        // Debug: --browser-settings opens the first browser window's settings panel, 6 s after launch.
        if args.contains("--browser-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if let b = self?.browsers.first { self?.toggleBrowserSettings(for: b) }
            }
        }
        // Debug: --ring F draws the hold-to-recenter ring filled to F (0…1).
        if let i = args.firstIndex(of: "--ring"), i + 1 < args.count, let f = Float(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.renderer?.recenterProgress = f }
        }
        // Debug: --ui-bench times the redraw of every panel, 5 s after launch.
        if args.contains("--ui-bench") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { VRPanel.benchmark() }
        }
        // Debug: --drag-test DX DY drags the first VR window by its bar, moving the pointer by that
        // many mouse points, 5 s after launch (for snapshots).
        if let i = args.firstIndex(of: "--drag-test"), i + 2 < args.count, let dx = Double(args[i + 1]), let dy = Double(args[i + 2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, let id = windowManager?.windows.first?.windowID else { return }
                beginDrag(id)
                InputState.shared.nudge(dx: dx / Double(Settings.shared.pointerSpeed), dy: dy / Double(Settings.shared.pointerSpeed))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.endDrag() }
            }
        }
        // Debug: --yaw DEG and --pitch DEG turn the simulator's head at launch (as in --snapshot).
        if let i = args.firstIndex(of: "--yaw"), i + 1 < args.count, let v = Float(args[i + 1]) { mouse.yaw = v * .pi / 180 }
        if let i = args.firstIndex(of: "--pitch"), i + 1 < args.count, let v = Float(args[i + 1]) { mouse.pitch = v * .pi / 180 }
        // Debug: --look-later YAW PITCH turns it 4 s in, once the dock and Home are placed (to see
        // the dock, which sits below the view, in a --keys-snapshot).
        if let i = args.firstIndex(of: "--look-later"), i + 2 < args.count, let y = Float(args[i + 1]), let p = Float(args[i + 2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.mouse.yaw = y * .pi / 180; self?.mouse.pitch = p * .pi / 180 }
        }
        // Debug: --layout NAME (arc, side, focus, grid) arranges the windows so for this run (not remembered).
        if let i = args.firstIndex(of: "--layout"), i + 1 < args.count, let l = WindowManager.Layout(rawValue: args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.windowManager?.setLayout(l, remember: false) }
        }
        // Debug: --app ID opens one of Halliday's own apps (halliday:clock, halliday:music…) at launch.
        if let i = args.firstIndex(of: "--app"), i + 1 < args.count {
            let id = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.launch(AppLauncher.App(id: id, name: id, url: nil, symbol: nil))
            }
        }
        // Debug: --play-quest PACKAGE starts an installed Quest app 3 s after launch, as Games' Play does.
        if let i = args.firstIndex(of: "--play-quest"), i + 1 < args.count {
            let package = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.playQuestApp(package) }
        }
        // Debug: --photo FILE opens a picture in Photos at launch.
        if let i = args.firstIndex(of: "--photo"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.photos?.open(url, among: [url], head: currentHead)
            }
        }
        if let i = args.firstIndex(of: "--video"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            // Debug: --video-view ZOOM YAW PITCH (a factor, degrees) zooms and tilts it once open.
            var view: (Float, Float, Float)?
            if let j = args.firstIndex(of: "--video-view"), j + 3 < args.count,
               let zoom = Float(args[j + 1]), let yaw = Float(args[j + 2]), let pitch = Float(args[j + 3]) { view = (zoom, yaw, pitch) }
            Task { @MainActor in
                await self.video?.open(url, head: self.currentHead)
                // Debug: --video-backdrop N takes the Nth backdrop for passthrough (1 green … 6).
                if let j = args.firstIndex(of: "--video-backdrop"), j + 1 < args.count, let n = Int(args[j + 1]) {
                    while let v = self.video, v.backdrop.rawValue != n % VideoPlayer.Backdrop.allCases.count { v.cycleBackdrop() }
                    self.videoControls?.onBackdrop?()
                }
                // Debug: --video-drawer opens the player's view drawer.
                if args.contains("--video-drawer") { self.videoControls?.choose("view") }
                guard let view else { return }
                self.video?.zoom(by: view.0 - 1)
                self.video?.tilt(yaw: view.1 * .pi / 180, pitch: view.2 * .pi / 180)
            }
        }
        if let i = args.firstIndex(of: "--keys-later"), i + 1 < args.count {
            let keys = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in for k in keys { self?.handleKey(k) } }
        }
        // Debug: --shots-at "T1,T2,…" PREFIX saves the view at those seconds after launch, as
        // PREFIX-T.png, without quitting (a game's moments: its loading, its overlays, its fade).
        if let i = args.firstIndex(of: "--shots-at"), i + 2 < args.count {
            let prefix = args[i + 2]
            for t in args[i + 1].split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self, let renderer = self.renderer else { return }
                    let head = self.lastHead ?? self.mouse.pose(atHostNs: 0)!
                    saveFrame(renderer: renderer, head: head, calibration: self.mouse.calibration, to: "\(prefix)-\(Int(t)).png")
                }
            }
        }
        if let keys = debugKeys, let path = debugPath {
            for k in keys { handleKey(k) }
            let delay = args.firstIndex(of: "--snapshot-delay").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 6
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let renderer = self.renderer else { return }
                let head = self.lastHead ?? self.mouse.pose(atHostNs: 0)!
                saveFrame(renderer: renderer, head: head, calibration: self.mouse.calibration, to: path)
                NSApp.terminate(nil)
            }
        }
    }

    /// Opening Halliday again (`open`, the Dock) while it runs: make sure its window can be seen.
    /// On the headset the window to see is the companion: a click on Halliday in the Dock brings
    /// it back after its red button closed it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onHeadset { showCompanion() } else { bringPreviewIntoView(front: true) }
        return true
    }

    /// The Dock icon's menu: the companion, also while another app is in front.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Companion", action: #selector(dockShowCompanion), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func dockShowCompanion() { showCompanion() }

    /// If the preview window is minimized, off every real screen or on the invisible virtual
    /// display, put it back in the middle of the main screen. A window the user placed on a visible
    /// monitor is left alone. `front` also brings it to the front and gives it focus (reopen);
    /// otherwise focus is only taken when the window had to be recovered, so activating Halliday
    /// through its browser window doesn't steal the keyboard from it.
    private func bringPreviewIntoView(front: Bool = false) {
        guard let window, window.styleMask.contains(.titled) else { return } // headset output: not a preview
        var recovered = false
        if window.isMiniaturized {
            window.deminiaturize(nil)
            recovered = true
        }
        let virtualID = windowManager?.virtualDisplayID
        let realScreens = NSScreen.screens.filter { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            return id != virtualID
        }
        let visible = realScreens.contains { $0.visibleFrame.intersection(window.frame).width > 200 }
        if !visible, let main = NSScreen.main ?? realScreens.first {
            let f = window.frame, v = main.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2))
            log("[display] brought the Halliday window back onto \(main.localizedName)")
            recovered = true
        }
        if front || recovered { window.makeKeyAndOrderFront(nil) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        bringPreviewIntoView()
        // On the headset nobody can click the scene to capture the mouse (its display can't be
        // seen from the Mac): being the active app is the capture. Control twice, or another app,
        // frees it.
        // (Not when the click that activated Halliday was on the companion: its mouse is the Mac's.)
        if onHeadset, !mouseOwner.isOn, !companionIsFront {
            pointerEngaged = true
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(view)
        }
        // The lock only takes effect while Halliday is the active app, and activation happens a
        // moment after it is requested (e.g. when leaving a window): apply it now, for real.
        if pointerEngaged, !mouseOwner.isOn { setPointerLock(true, force: true) }
    }

    func applicationDidResignActive(_ notification: Notification) {
        // Remembered for `takeFocusBack`: the mouse was captured when another app took the focus.
        focusWasEngaged = pointerEngaged
        setPointerLock(false)
        // Switching to another app (⌘Tab, a click elsewhere) releases the mouse for good; a window
        // interaction in VR activates another app too, but the user is still in VR.
        if !mouseOwner.isOn { pointerEngaged = false }
    }

    /// Locks the mouse to Halliday: the Mac's cursor parks in the middle of the preview and stops
    /// moving, so there is a single cursor (the VR pointer) and no edges or warps to fight.
    /// `force` re-applies the lock even if it is already marked on (macOS drops it while another
    /// app is active).
    private func setPointerLock(_ on: Bool, force: Bool = false) {
        guard force || on != pointerLocked, let view else { return }
        pointerLocked = on
        if on {
            if let center = view.globalCenter {
                view.skipNextDelta = true
                CGWarpMouseCursorPosition(center)
            }
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            CGAssociateMouseAndMouseCursorPosition(1)
            // Never leave the Mac's cursor on the headset's display, where it can't be seen.
            if onHeadset, !mouseOwner.isOn {
                let main = CGDisplayBounds(CGMainDisplayID())
                CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY))
            }
        }
        updateTitle()
    }

    private func controlKey(_ event: NSEvent) {
        guard !mouseOwner.isOn, event.keyCode == 59 || event.keyCode == 62, event.modifierFlags.contains(.control) else { return }
        let now = CACurrentMediaTime()
        if now - lastControlTap < 0.5 {
            lastControlTap = 0
            if pointerLocked {
                pointerEngaged = false
                setPointerLock(false)
                log("[mouse] released: the Mac's cursor is free (click inside the scene to capture it again)")
            }
        } else {
            lastControlTap = now
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        log("[app] quitting: releasing the mouse and putting windows back")
        discardHandTrackingWork()
        gameImageReconfiguration?.cancel()
        gameImageReconfiguration = nil
        // A game in Halliday is asked to quit too (as SteamVR's do): it reads the request from the
        // bridge it still maps after Halliday closes it.
        game?.requestQuit()
        game?.close()
        // A Quest app is Halliday's own child: it doesn't outlive it.
        QuestApps.shared.stop()
        video?.close() // saves where it was
        mouseOwner.stop(reason: "quit")
        sense.stop()
        setPointerLock(false)
        // The Mac windows in VR now, for Home's "bring them back" next time.
        HomePanel.rememberApps((windowManager?.windows ?? []).filter { $0.own == nil }.compactMap { w in
            NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier.map { (bundle: $0, name: w.appName) }
        })
        windowManager?.stopAll() // windows back where they were
        view?.stop()
    }

    private func replaySource() -> TrackedSource? {
        if let r = replay { return r }
        let path: String
        if let p = replayPath {
            path = p
        } else {
            // No recording given: generate a synthetic one in the caches folder.
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Halliday")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("synthetic-look-around.hrec").path
            if !FileManager.default.fileExists(atPath: path) {
                guard halliday_write_synthetic_recording(path, 60) else {
                    log("[replay] could not write a synthetic recording")
                    return nil
                }
            }
        }
        guard let h = Headset(replaying: URL(fileURLWithPath: path), looping: true) else {
            log("[replay] can't read \(path)")
            return nil
        }
        log("[replay] \(path)")
        let r = TrackedSource(name: "replay", headset: h)
        replay = r
        return r
    }

    func handleKey(_ c: Character) {
        guard let view else { return }
        switch c {
        case "1": view.source = mouse
        case "2": if let r = replaySource() { view.source = r }
        case "3":
            if usb == nil { usb = TrackedSource(name: "headset", headset: Headsets.current.openSession()) }
            view.source = usb!
        case "r": recenterUI()
        case "[", "]":
            // Tuning by eye on the headset: how far ahead the head pose is predicted.
            view.lookaheadTrimNs += c == "]" ? 2_000_000 : -2_000_000
            let line = String(format: "Prediction %+d ms (%.0f ms ahead of a frame's start)", Int(view.lookaheadTrimNs / 1_000_000), view.lookaheadMs)
            notify(line)
            log("[display] " + line)
        case "a": toggleLauncher()
        case "t": togglePassthrough()
        case "k": toggleKeyboard()
        case "l":
            if let layer = testLayer, let wm = windowManager, video?.isOpen != true {
                wm.contentLayers = wm.contentLayers.isEmpty ? [layer] : []
            }
        case "m":
            if let picker, picker.isOpen {
                picker.close()
            } else if CGPreflightScreenCaptureAccess(), let picker {
                closeOverlays()
                picker.place(head: currentHead, distance: overlayDistance(WindowPicker.distance), below: WindowPicker.below)
                picker.open()
            } else {
                notify("macOS hasn't let Halliday see the Mac's windows: allow it on the Mac's screen", kind: .warning)
                Permissions.shared.request(.screenRecording)
            }
            lastDockClock = 0
        case "b": toggleBrowser()
        case ",": toggleQuickSettings()
        case "/", "?": if controlsOpen { controlsOpen = false } else { openControls() }
        case ".": toggleSettings()
        case "p":
            // Preview only: desktop view ↔ what the headset gets.
            if let r = renderer, let w = window, w.styleMask.contains(.titled) {
                r.desktopView.toggle()
                let width = w.contentLayoutRect.width
                if r.desktopView {
                    w.contentResizeIncrements = NSSize(width: 1, height: 1) // frees the aspect ratio
                    w.setContentSize(NSSize(width: width, height: width * 10 / 16))
                } else {
                    w.contentAspectRatio = headsetPanelPixels
                    w.setContentSize(NSSize(width: width, height: width * headsetPanelPixels.height / headsetPanelPixels.width))
                }
                log("[display] preview: \(r.desktopView ? "desktop view" : "headset view (both eyes, lens)")")
            }
        case "o": toggleFileBrowser()
        case "O": openVideoFile() // the Mac's own file dialog
        case "v": browser?.watchInVR()
        case " ": video?.togglePlay()
        case "\u{2190}": if photos?.isOpen == true { photos?.step(-1) } else { video?.seek(by: -10) }
        case "\u{2192}": if photos?.isOpen == true { photos?.step(1) } else { video?.seek(by: 10) }
        case "n": toggleNotes()
        case "e": toggleFileBrowser(mode: .files)
        case "f": if let v = video, v.isOpen { v.cycleProjection(head: currentHead) }
        case "g": if let v = video, v.isOpen { v.cycleStereo(head: currentHead) }
        case "c":
            if let v = video, v.isOpen, v.hasSubtitles {
                v.cycleSubtitles()
                notify("Subtitles: \(v.subtitleName)")
            }
        case "x":
            video?.close()
            photos?.close()
        case "\u{1b}" where game?.isPresenting == true && !gameAway:
            setGameAway(true)
        case "\u{1b}":
            if browserBar?.isEditing == true { browserBar?.endEditing() }
            else if settingsOpen { settingsOpen = false }
            else if keyboardOpen { keyboardOpen = false }
            else if launcherOpen { launcherOpen = false }
            else if fileBrowserOpen { fileBrowserOpen = false }
            else if notesOpen { closeNotes() }
            else if clockOpen { clockOpen = false }
            else if controlsOpen { controlsOpen = false }
            else if musicOpen { musicOpen = false }
            else if photos?.isOpen == true { photos?.close() }
            else if browser?.xrActive == true { browser?.endXR() }
            else if picker?.isOpen == true { picker?.close() }
            else if video?.isOpen == true { video?.close() }
            else if gamesOpen { gamesOpen = false }
            // Over a running game, the last Esc goes back to it; Halliday never quits from under it.
            else if game?.isPresenting == true { setGameAway(false) }
            else { NSApp.terminate(nil) }
        default:
            if c == "d", let r = renderer { r.distortionEnabled.toggle() }
        }
        updateTitle()
    }

    /// A click on the preview: on a VR window it starts interacting with that window.
    /// A new capture arrived (of the browser's window, or of the whole virtual display while the
    /// window has no capture of its own yet), covering `bounds`: if an immersive page is presenting,
    /// read the pose stamp of its frame and show the frame as the projection layer, reprojected
    /// from that pose.
    private func presentWebXRFrame(_ pixels: CVPixelBuffer, bounds: CGRect, texture: MTLTexture, window: CGWindowID?, content: CGRect) {
        guard let browser, browser.xrActive, browser.presentedPixels != nil, let renderer, bounds.width > 0 else { return }
        let own = CGWindowID(browser.window.windowNumber)
        // The browser's own capture when it has one (another window may cover it on the display).
        guard window == own || (window == nil && windowManager?.hasOwnPicture(own) != true) else { return }
        // Pixels per point, and where `bounds` starts in the pixels.
        let scale = content.width / bounds.width
        let rect = browser.webViewGlobalFrame
        let origin = CGPoint(x: content.minX + (rect.minX - bounds.minX) * scale, y: content.minY + (rect.minY - bounds.minY) * scale)
        let canvasRect = CGRect(x: origin.x, y: origin.y, width: rect.width * scale, height: rect.height * scale)
        guard let id = Self.readPoseStamp(pixels, canvasRect: canvasRect),
              let pose = sentPoses[id] else {
            xrMissedStamps += 1
            if xrMissedStamps == 90 {
                log("[webxr] no pose stamp found in the page's frames yet (web view \(rect), capture \(CVPixelBufferGetWidth(pixels))×\(CVPixelBufferGetHeight(pixels)) of \(bounds), canvas at \(canvasRect))")
            }
            return
        }
        lastStampedID = id
        xrFrames += 1
        // Seen in the next display frame: how far after the frame its pose was sent in.
        if let sent = sentTargets[id], sent > 0 {
            let gap = HeadsetView.frameTarget - sent + 1.0 / 120
            if gap > 0, gap < 0.3 { xrLead = xrLead == 0 ? gap : xrLead + (gap - xrLead) * 0.05 }
        }
        xrLagTotal += Int(nextPoseID &- id) - 1
        let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
        func tangents(_ eye: Eye) -> SIMD4<Float> {
            let f = Optics.fov(eye)
            return SIMD4(tan(f.left), tan(f.right), tan(f.up), tan(f.down))
        }
        renderer.projection = ProjectionLayer(
            texture: texture,
            uvRect: SIMD4(Float(canvasRect.minX / w), Float(canvasRect.minY / h), Float(canvasRect.width / w), Float(canvasRect.height / h)),
            renderOrientation: pose.orientation,
            renderPosition: pose.position,
            tangents: (tangents(.left), tangents(.right)))
    }

    /// Reads the pose id the WebXR bridge stamped along the top edge of a frame, `stampOffset` squares in: 16 squares
    /// (white = 1), then a white and a black marker square; a square is 1/360 of the canvas width.
    /// `canvasRect` is the canvas's area in capture pixels. Nil if there is no valid stamp.
    /// Squares skipped before the stamp (the window's rounded top-left corner); as in webxr-bridge.js.
    static let stampOffset = 12

    static func readPoseStamp(_ pixels: CVPixelBuffer, canvasRect: CGRect) -> UInt16? {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let square = canvasRect.width / 360
        let y = Int(canvasRect.minY + square / 2)
        guard y >= 0, y < height else { return nil }
        func bit(_ i: Int) -> Bool? {
            let x = Int(canvasRect.minX + (CGFloat(Self.stampOffset + i) + 0.5) * square)
            guard x >= 0, x < width else { return nil }
            let p = base.advanced(by: y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            let brightness = (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
            if brightness > 200 { return true }
            if brightness < 55 { return false }
            return nil // neither clearly white nor black: not a stamp
        }
        guard bit(16) == true, bit(17) == false else { return nil }
        var id: UInt16 = 0
        for i in 0..<16 {
            guard let b = bit(i) else { return nil }
            if b { id |= 1 << UInt16(i) }
        }
        return id
    }

    /// The latest rendered head pose (or a default before the first frame).
    private var currentHead: HeadPose {
        lastHead ?? HeadPose(position: [0, 1.65, 1], orientation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                             angularVelocity: .zero, slamAgeNs: 0, predicted: false)
    }

    /// Asks for a video file (on the Mac's screen: the mouse is unlocked meanwhile) and plays it.
    private func openVideoFile() {
        setPointerLock(false)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = "Choose a video to watch in Halliday"
        panel.begin { [weak self] response in
            guard let self else { return }
            if pointerEngaged { setPointerLock(true, force: true) }
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self.video?.open(url, head: self.currentHead) }
        }
    }

    /// The mouse button went up over the preview (the release of a click that stayed in Halliday).
    func releasedInView(rightButton: Bool) {
        if let game {
            if rightButton { game.grip[0] = false } else { game.trigger[0] = false }
        }
        if !rightButton, let browser, browser.xrActive { browser.select(down: false) }
        guard !rightButton else { return }
        pointerDown = false
        endDrag()
        endResize()
        if let head = lastHead {
            let direction = head.orientation.act(InputState.shared.pointerDirection)
            for panel in panels { panel.release(origin: head.position, direction: direction) }
        }
    }

    /// `--cameras MODE [--camera-threshold N] [--leds [CYCLE_MS]]`, for building controller
    /// tracking (ROADMAP W11 E.2): the headset's tracking cameras on while Halliday runs, the
    /// controllers' LEDs pulsing, and a line a second saying what each camera sees.
    private static let cameraMode: Int? = {
        let a = CommandLine.arguments
        // `--cameras MODE` asks for a mode by hand; otherwise hand tracking's own, mode 3: the
        // bottom pair (views 0 and 1) and the two top cameras (2 and 3) at every exposure.
        if let i = a.firstIndex(of: "--cameras"), i + 1 < a.count {
            let v = a[i + 1]
            return v.hasPrefix("0x") ? Int(v.dropFirst(2), radix: 16) : Int(v)
        }
        return trackHands ? (wideCameras ? 0x10 : 3) : nil
    }()
    /// Camera mode 0x10 for the controllers and passthrough: the bottom cameras' raw fisheye
    /// pictures (about 170° across together, where modes 1 and 3 send rectified crops of 82°),
    /// without the top cameras. Their lens model is the core's `PSVR2_BOTTOM_FISHEYE`. The
    /// default; `--narrow-cameras` goes back to mode 3's four cropped cameras (`--wide-cameras`, the
    /// switch it was behind at first, is still taken and changes nothing).
    private static let wideCameras = !CommandLine.arguments.contains("--narrow-cameras")
    /// The bottom pair's spots are the raw fisheyes' (mode 0x10).
    private static var bottomFisheyes: Bool { cameraMode == 0x10 }
    /// The controllers' places from the headset's cameras, live (ROADMAP W11 E.2, stage 4):
    /// camera mode 3 on, the LEDs pulsing in step, a tracker per controller run at every
    /// exposure, and the saber leaving from the hand that points. A log line a second says how
    /// it goes. On whenever Halliday runs on the headset; `--no-hands` turns it off (`--hands`, the
    /// switch it was behind at first, is still taken and changes nothing).
    private static let trackHands = !CommandLine.arguments.contains("--no-hands")
    private var handTrackingWorker: HandTrackingWorker?
    private var handWorkerEpoch: UInt64 = 0
    private var handTrackingSource: ObjectIdentifier?
    private var lastHandResultExposure: Int64 = 0
    private var handCameraSource: ObjectIdentifier?
    private var handCameraIdentity: String?
    private var handCameraProfile: CameraTrackingCalibration?
    private var handCameraProfilePolled: CFTimeInterval = -.infinity
    private var handFisheyeAlignment = SIMD3<Float>.zero
    /// Where each controller was last seen, in the room, when (`CACurrentMediaTime`: when it was
    /// found, and the exposure's own time in seconds), and how fast it was moving, m/s.
    private var handPlaces: [SenseControllers.Hand: (position: SIMD3<Float>, time: CFTimeInterval, exposed: Double, velocity: SIMD3<Float>)] = [:]
    private var handExposure = -1
    private var handStats: [SenseControllers.Hand: (fixes: Int, sightings: Int, rms: Float)] = [:]
    private var handExposures = 0
    private var ledHands: Set<SenseControllers.Hand> = []

    // The LEDs' pulses in step with the cameras (ROADMAP W11 E.2): each controller's clock is
    // followed against the host's, the cameras' period measured, and several times a second
    // each controller is told when its next pulses fall: on the coming exposures.
    /// A controller's clock: its ticks unwrapped (thirds of a microsecond), and the smallest
    /// (arrival − ticks) seen lately, ns: the report that travelled fastest says the offset best.
    private struct HandClock {
        var lastTicks: UInt32
        var ticks: Int64
        var offsets: [Int64] = []
        var lastReports = -1
    }
    private var handClocks: [SenseControllers.Hand: HandClock] = [:]
    private var exposurePeriod: Double = 1e9 / 60
    private var lastExposure: (counter: Int, ns: Int64)?
    private var ledSyncTime: CFTimeInterval = 0
    /// `--led-offset MS`: where a pulse's middle falls after the exposure's own time.
    /// `--led-sweep`: the offset steps a millisecond every two seconds, around the whole period,
    /// and the log says how much was seen at each: for finding the offset.
    private var ledOffsetMs: Double = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--led-offset").flatMap { $0 + 1 < a.count ? Double(a[$0 + 1]) : nil } ?? AppDelegate.defaultLedOffsetMs
    }()
    /// The middle of the offsets at which the LEDs show (a sweep: every exposure
    /// from −2 to +6.5 ms, none from 8 to 14, with pulses of 2.1 ms).
    private static let defaultLedOffsetMs = 2.3
    private static let ledSweep = CommandLine.arguments.contains("--led-sweep")
    private static let ledFree = CommandLine.arguments.contains("--led-free")
    private var sweepStart: CFTimeInterval = 0
    private var sweepSeen = (exposures: 0, spots: 0, left: 0, right: 0)

    private func syncLEDs(_ headset: Headset) {
        let nowNs = hostTimeNs()
        // Each controller's clock against the host's, from every new report.
        for hand in SenseControllers.Hand.allCases {
            guard let s = sense.state(hand) else { handClocks[hand] = nil; continue }
            var c = handClocks[hand] ?? HandClock(lastTicks: s.deviceTicks, ticks: Int64(s.deviceTicks))
            guard s.reports != c.lastReports else { continue }
            c.lastReports = s.reports
            c.ticks += Int64(Int32(bitPattern: s.deviceTicks &- c.lastTicks))
            c.lastTicks = s.deviceTicks
            c.offsets.append(nowNs - Int64(Double(s.age) * 1e9) - c.ticks * 1000 / 3)
            if c.offsets.count > 240 { c.offsets.removeFirst() }
            handClocks[hand] = c
        }
        // The cameras' period, from the exposures' own times.
        guard let v = headset.cameraView(0), v.exposureHostNs != 0 else { return }
        if let last = lastExposure, v.counter > last.counter, v.counter - last.counter < 30 {
            let period = Double(v.exposureHostNs - last.ns) / Double(v.counter - last.counter)
            if abs(period - 1e9 / 60) < 1e6 { exposurePeriod += (period - exposurePeriod) * 0.02 }
        }
        if lastExposure?.counter != v.counter { lastExposure = (v.counter, v.exposureHostNs) }
        let now = CACurrentMediaTime()
        if Self.ledSweep {
            if sweepStart == 0 { sweepStart = now; ledOffsetMs = 0 }
            if now - sweepStart >= 2 {
                log(String(format: "[hands] sweep: offset %.1f ms: %.1f LED-sized spots an exposure, left %d and right %d fixes in %d exposures",
                           ledOffsetMs, Double(sweepSeen.spots) / Double(max(1, sweepSeen.exposures)), sweepSeen.left, sweepSeen.right, sweepSeen.exposures))
                sweepSeen = (0, 0, 0, 0)
                sweepStart = now
                ledOffsetMs = (ledOffsetMs + 1).truncatingRemainder(dividingBy: 17)
            }
        }
        guard now - ledSyncTime >= 0.1 else { return }
        ledSyncTime = now
        // A pulse at the newest exposure (already past, as Monado gives it), and one every period
        // after it. With a moment still to come, 50 ms ahead, the LEDs never lit at any offset.
        let target = v.exposureHostNs + Int64(ledOffsetMs * 1e6)
        for (hand, c) in handClocks {
            guard let offset = c.offsets.min(), c.offsets.count >= 30 else { continue }
            let ticks = (target - offset) * 3 / 1000
            sense.syncLEDs(hand, position: UInt32(truncatingIfNeeded: ticks), cycleNs: exposurePeriod)
        }
    }

    /// A controller's place for drawing, while it was seen within the last three seconds.
    /// Called once a frame for the hand that points.
    private func handPlace(_ hand: SenseControllers.Hand) -> SIMD3<Float>? {
        // The cameras' fixes fused with the controller's accelerometer, for the moment this
        // frame is seen (`tracking/place.rs`): between fixes, through short losses, and ahead
        // across the 30 to 40 ms a fix is old by the time it is drawn. `--no-hand-fusion`
        // for what was done before (the newest fix carried along its velocity, and eased).
        if Self.fusesHands {
            let seen = HeadsetView.frameTarget > 0 ? HeadsetView.frameTarget : CACurrentMediaTime()
            return sense.place(hand, atNs: Int64(seen * 1e9))?.position
        }
        let now = CACurrentMediaTime()
        guard let p = handPlaces[hand], now - p.time < 3 else { handShown[hand] = nil; return nil }
        // Carried on from the exposure along its motion: a place is 30 to 40 ms old when it is
        // drawn (the hand in VR trailed the real one), and while the cameras lose the controller
        // for a moment it would stand still in the air and then jump. The motion dies away
        // (in 120 ms it has gone two thirds of as far as it will): a hand that was moving
        // drifts on and comes to rest, not farther than 0.12 s of its speed.
        let since = Float(max(0, now - p.exposed))
        let fade: Float = 0.12
        let target = p.position + p.velocity * (fade * (1 - exp(-since / fade)))
        // What is drawn eases to that (25 ms): a controller found again after a gap glides to
        // where it is, and one sighting's noise doesn't shake the saber.
        guard let shown = handShown[hand], simd_distance(shown.position, target) < 0.5 else {
            handShown[hand] = (target, now)
            return target
        }
        let position = simd_mix(shown.position, target, SIMD3(repeating: 1 - exp(-Float(now - shown.time) / 0.025)))
        handShown[hand] = (position, now)
        return position
    }

    /// Pass through the filter's existing room velocity and the measured gyro.
    /// This does not move, predict or recalibrate the hand shown to the game.
    private func gameHandMotion(_ hand: SenseControllers.Hand, state: SenseControllers.State,
                                now: Double) -> GameControllerMotion {
        let seen = HeadsetView.frameTarget > 0 ? HeadsetView.frameTarget : now
        let linear: SIMD3<Float>?
        if Self.fusesHands {
            linear = sense.place(hand, atNs: Int64(seen * 1e9))?.velocity
        } else if let place = handPlaces[hand] {
            // Derivative of the legacy display's existing decaying continuation.
            linear = place.velocity * exp(-Float(max(0, now - place.exposed)) / 0.12)
        } else { linear = nil }
        // Raw Sense gyro is in SENSOR axes. The final mount tilt changes the
        // aim's local axes, so remove that fixed right-hand transform before
        // rotating the gyro into the room. Keep all existing calibration values.
        let mount = simd_quatf(angle: senseTilt[hand] ?? SenseAimDefaults.tilt, axis: [1, 0, 0])
        let sensorInRoom = senseAim(hand, state.orientation) * mount.inverse
        return GameControllerMotion.sample(linearWorld: linear, bodyAngular: state.angularVelocity,
            sensorInRoom: sensorInRoom, reportAge: state.age,
            opticalAge: handPlaces[hand].map { now - $0.exposed }, now: now)
    }
    private var handShown: [SenseControllers.Hand: (position: SIMD3<Float>, time: CFTimeInterval)] = [:]
    private static let fusesHands = !CommandLine.arguments.contains("--no-hand-fusion")
    /// What the cameras add to each controller's own heading, eased, and what an
    /// intentional calibration from the game panel adds to that.
    private var seenHeading: [SenseControllers.Hand: Float] = [:]
    private var headingOffset: [SenseControllers.Hand: Float] = [:]
    /// The cameras' lean for each controller (a rotation vector about the room's x and z), eased,
    /// and when it was last seen: `seenLean`.
    private var leanSeen: [SenseControllers.Hand: (turn: SIMD3<Float>, time: CFTimeInterval)] = [:]

    /// Identity is cached by Headset; only the tiny optional profile file is read here.
    /// Applying another camera geometry retires every old optical result/history.
    private func refreshHandCameraProfile(_ headset: Headset) {
        let source = ObjectIdentifier(headset), now = CACurrentMediaTime()
        let newSource = handCameraSource != source
        guard newSource || now - handCameraProfilePolled >= 1 else { return }
        handCameraProfilePolled = now
        let identity = headset.hardwareIdentity
        let profile = Self.bottomFisheyes ? CameraTrackingProfiles.load(for: identity,
            from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Halliday/camera-tracking-calibration.json")) : nil
        let alignment = profile?.rightFisheyeRotation ?? .zero
        let changed = newSource || identity != handCameraIdentity || profile != handCameraProfile || alignment != handFisheyeAlignment
        handCameraSource = source
        handCameraIdentity = identity
        handCameraProfile = profile
        handFisheyeAlignment = alignment
        if changed {
            discardHandTrackingWork()
            clearOpticalHandHistory()
            log("[hands] camera geometry: \(profile == nil ? "default" : "calibrated")")
        }
    }

    private func clearOpticalHandHistory() {
        for hand in SenseControllers.Hand.allCases {
            // Remove the previous camera correction, retaining the user's own
            // heading/mount offsets until a new optical result is accepted.
            if let seen = seenHeading[hand], let current = senseHeading[hand] {
                senseHeading[hand] = current - seen
            }
            sense.clearOpticalPlace(hand)
        }
        handPlaces.removeAll()
        handShown.removeAll()
        seenHeading.removeAll()
        leanSeen.removeAll()
        handStats.removeAll()
        handExposure = -1
        handExposures = 0
    }

    /// Snapshot one exposure on the display actor; the optical solver never blocks it.
    private func trackHands(_ headset: Headset) {
        refreshHandCameraProfile(headset)
        let source = ObjectIdentifier(headset)
        if handTrackingSource != source {
            if handTrackingWorker != nil { discardHandTrackingWork() }
            handTrackingSource = source
            handExposure = -1
        }
        guard let l = headset.cameraView(0), let r = headset.cameraView(1), l.counter == r.counter else { return }
        if l.counter < handExposure { discardHandTrackingWork() }
        guard l.counter != handExposure, l.exposureHostNs != 0,
              let head = headset.predict(atHostNs: l.exposureHostNs) else { return }
        handExposure = l.counter
        handExposures += 1
        sweepSeen.exposures += 1
        sweepSeen.spots += l.spots.filter { $0.area >= 4 && $0.area <= 400 }.count
        let spots = { (v: Headset.CameraView) in v.spots.map { HandTrackingWorker.Spot(x: $0.x, y: $0.y, area: UInt32($0.area), peak: UInt32($0.peak)) } }
        let (left, right) = (spots(l), spots(r))
        // The top cameras' pictures of the same exposure, when they have arrived.
        let top = [2, 3].map { view in headset.cameraView(view).flatMap { $0.counter == l.counter ? spots($0) : nil } ?? [] }
        let orientations = SenseControllers.Hand.allCases.compactMap { hand -> HandTrackingWorker.HandOrientation? in
            guard let state = sense.state(hand), state.settled else { return nil }
            let q = state.orientation
            return HandTrackingWorker.HandOrientation(index: hand.rawValue, orientation: q.vector)
        }
        guard !orientations.isEmpty else { return }
        if handTrackingWorker == nil {
            handWorkerEpoch &+= 1
            let epoch = handWorkerEpoch
            handTrackingWorker = HandTrackingWorker { [weak self] output in
                Task { @MainActor [weak self] in
                    guard let self, self.handWorkerEpoch == epoch,
                          self.handTrackingWorker?.isCurrent(output) == true else { return }
                    self.applyHandTracking(output)
                }
            }
        }
        handTrackingWorker?.submit(HandTrackingWorker.Frame(counter: l.counter, exposureHostNs: l.exposureHostNs,
            headOrientation: head.orientation.vector, headPosition: head.position, heightLift: usb?.heightLift ?? 0,
            handOrientations: orientations, views: [left, right, top[0], top[1]], fisheyes: Self.bottomFisheyes,
            fisheyeAlignment: handFisheyeAlignment))
    }

    private func discardHandTrackingWork() {
        handWorkerEpoch &+= 1
        handTrackingWorker?.close()
        handTrackingWorker = nil
        lastHandResultExposure = 0
    }

    /// Keep the exposure's original head pose and time; only result delivery changes threads.
    private func applyHandTracking(_ output: HandTrackingWorker.Output) {
        guard let headset = usb?.headset, headset.linkState == .connected,
              handTrackingSource == ObjectIdentifier(headset) else { return }
        let frame = output.frame
        guard frame.fisheyes == Self.bottomFisheyes, frame.fisheyeAlignment == handFisheyeAlignment else { return }
        let age = hostTimeNs() - frame.exposureHostNs
        guard frame.exposureHostNs > lastHandResultExposure, age >= -20_000_000, age <= 250_000_000 else { return }
        lastHandResultExposure = frame.exposureHostNs
        let headOrientation = simd_quatf(vector: frame.headOrientation)
        for fix in output.fixes {
            guard let hand = SenseControllers.Hand(rawValue: fix.index), sense.state(hand)?.settled == true else { continue }
            // From the head's frame at the exposure to the room, at the height Halliday shows.
            var at = frame.headPosition + headOrientation.act(fix.position)
            at.y += frame.heightLift
            let exposed = Double(frame.exposureHostNs) * 1e-9
            var velocity = SIMD3<Float>.zero
            if let before = handPlaces[hand], exposed - before.exposed > 0, exposed - before.exposed < 0.06 {
                // Half the newest step, half what it was: a place is steady to under a millimeter.
                velocity = simd_mix(before.velocity, (at - before.position) / Float(exposed - before.exposed), SIMD3(repeating: 0.5))
            }
            handPlaces[hand] = (at, CACurrentMediaTime(), exposed, velocity)
            sense.placeFix(hand, ns: frame.exposureHostNs, at)
            // The controller has no compass, and its heading drifts (up to 12° a minute): the
            // cameras see where it really points. Eased, and taken the short way round.
            if fix.sightings >= 8 {
                var heading = fix.heading
                if let before = seenHeading[hand] {
                    let step = atan2(sin(heading - before), cos(heading - before))
                    heading = before + step * 0.2
                }
                seenHeading[hand] = heading
                sense.setRoomYaw(hand, heading)
                senseHeading[hand] = heading + (headingOffset[hand] ?? 0)
                // The lean too (solved from eight sightings on, held near its running value).
                let lean = SIMD3<Float>(fix.tilt.x, 0, fix.tilt.y)
                let before = leanSeen[hand].map { CACurrentMediaTime() - $0.time < 0.5 ? $0.turn : .zero } ?? .zero
                leanSeen[hand] = (simd_mix(before, lean, SIMD3(repeating: 0.3)), CACurrentMediaTime())
            }
            let s = handStats[hand] ?? (0, 0, 0)
            handStats[hand] = (s.fixes + 1, s.sightings + Int(fix.sightings), s.rms + fix.rms)
            if hand == .left { sweepSeen.left += 1 } else { sweepSeen.right += 1 }
        }
    }
    private var cameraStarted = false
    private var cameraLogTime: CFTimeInterval = 0
    private var cameraFrames = [Int](repeating: 0, count: 4)
    private var ledsStarted = false
    private var cameraDump: FileHandle?
    private var cameraDumped = [Int](repeating: -1, count: 4)

    // --- Passthrough (ROADMAP W11 E.4): the room through the headset's bottom cameras ---

    /// On: the room shows behind the panels, in Halliday's place and over a game or a video.
    /// The Fn button under the visor switches it, and T.
    private(set) var passthrough = false
    private var passthroughShown: Float = 0
    /// The bottom pair's picture: 1280 × 640 bytes, or mode 0x10's two fisheyes in BC4 (1 MB).
    private var passthroughBuffer = [UInt8](repeating: 0, count: 1024 * 2032 / 2)
    private var passthroughCounter = -1
    private var fnButtonDown = false

    func togglePassthrough() {
        guard usb?.headset != nil else {
            notify("Passthrough needs the headset: it shows the room through its cameras", kind: .warning)
            return
        }
        passthrough.toggle()
        usb?.headset.setCameraKeep(passthrough)
        if !passthrough { passthroughCounter = -1 }
        notify(passthrough ? "Passthrough on · Fn under the visor switches it" : "Passthrough off", symbol: "eye")
        log("[cameras] passthrough \(passthrough ? "on" : "off")")
    }

    /// The headset on a USB 2 path has no tracking (its IMU interface isn't offered at 12 Mb/s),
    /// and the picture then stays fixed to the face: said in the headset, again every 15 s
    /// while it lasts, not only in the log.
    private func updateLinkNotice() {
        guard usb?.headset.linkState == .fullSpeedLink else { linkNoticeAt = 0; return }
        let now = CACurrentMediaTime()
        guard now - linkNoticeAt > 15 else { return }
        linkNoticeAt = now
        notify("No head tracking: the headset is on a USB 2 link. Plug the adapter's USB cable into a USB 3 port (no USB 2 adapter or hub in between).",
               symbol: "cable.connector", kind: .warning, seconds: 12)
    }
    private var linkNoticeAt: CFTimeInterval = 0

    /// Once a frame: the Fn button, and while passthrough is on (or fading out) the cameras'
    /// newest picture to the renderer, with where the cameras looked when they took it.
    private func updatePassthrough() {
        updateLinkNotice()
        updateBrightness()
        guard let renderer else { return }
        if let headset = usb?.headset, headset.linkState == .connected {
            let down = headset.status?.functionButton == true
            if down, !fnButtonDown { togglePassthrough() }
            fnButtonDown = down
            if passthrough, let image = headset.cameraImage(into: &passthroughBuffer, have: passthroughCounter),
               image.exposureHostNs != 0, let head = headset.predict(atHostNs: image.exposureHostNs) {
                passthroughCounter = image.counter
                passthroughBuffer.withUnsafeBytes { renderer.setCameraPicture($0.baseAddress, width: image.width, height: image.height, bc4: image.bc4) }
                // The cameras' frame in the head's: x right, y down, z forward, pitched below
                // the head's forward.
                let (s, c) = (sin(Renderer.cameraPitch), cos(Renderer.cameraPitch))
                let cameraFromHead = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, -c, s), SIMD3(0, -s, -c)])
                renderer.seeFromWorld = cameraFromHead * simd_float3x3(head.orientation.inverse)
            }
        } else if passthrough {
            passthrough = false
        }
        // Eased in and out (a fifth of a second); the picture is dropped once it is out.
        let target: Float = passthrough && passthroughCounter >= 0 ? 1 : 0
        passthroughShown += (target - passthroughShown) * 0.12
        if abs(target - passthroughShown) < 0.004 { passthroughShown = target }
        renderer.seeThrough = passthroughShown
        if !passthrough, passthroughShown == 0, passthroughCounter == -1 { renderer.setCameraPicture(nil, width: 0, height: 0) }
    }

    private func updateCameras() {
        // (Passthrough needs the cameras too: with hand tracking off, mode 1, the bottom pair.)
        guard let headset = usb?.headset, headset.linkState == .connected else {
            if handTrackingWorker != nil { discardHandTrackingWork() }
            if handTrackingSource != nil { clearOpticalHandHistory() }
            handTrackingSource = nil
            handCameraSource = nil
            handCameraIdentity = nil
            handCameraProfile = nil
            handCameraProfilePolled = -.infinity
            handFisheyeAlignment = .zero
            handExposure = -1
            return
        }
        guard let mode = Self.cameraMode ?? (passthrough ? (Self.wideCameras ? 0x10 : 1) : nil) else { return }
        let a = CommandLine.arguments
        if !cameraStarted {
            cameraStarted = true
            let threshold = a.firstIndex(of: "--camera-threshold").flatMap { $0 + 1 < a.count ? Int(a[$0 + 1]) : nil } ?? 200
            headset.setCamera(mode: mode, threshold: threshold)
            log("[cameras] mode \(mode), spots at or above \(threshold)")
        }
        if let i = a.firstIndex(of: "--leds"), !ledsStarted, SenseControllers.Hand.allCases.allSatisfy({ sense.state($0) != nil }) {
            ledsStarted = true
            let cycle = (i + 1 < a.count ? Double(a[i + 1]) : nil) ?? 1000.0 / 60
            log("[cameras] LED pulse every \(String(format: "%.3f", cycle)) ms queued for \(sense.setLEDs(phase: 1, cycle: cycle / 1000)) controller(s)")
        }
        if Self.trackHands {
            // The LEDs are asked for again whenever a controller arrives (or comes back from sleep).
            let connected = Set(SenseControllers.Hand.allCases.filter { sense.state($0) != nil })
            if connected != ledHands {
                handTrackingWorker?.reset()
                lastHandResultExposure = 0
                if !connected.subtracting(ledHands).isEmpty {
                    log("[hands] LED pulse queued for \(sense.setLEDs(phase: 1)) controller(s)")
                }
                ledHands = connected
            }
            if !Self.ledFree { syncLEDs(headset) }
            trackHands(headset)
        }
        // `--camera-dump FILE`: every new frame's spots, with the controllers' orientations and
        // the head's pose, a line of text each, for working the geometry out afterwards.
        if let i = a.firstIndex(of: "--camera-dump"), i + 1 < a.count {
            if cameraDump == nil {
                FileManager.default.createFile(atPath: a[i + 1], contents: nil)
                cameraDump = FileHandle(forWritingAtPath: a[i + 1])
            }
            for view in 0..<4 {
                guard let v = headset.cameraView(view), v.counter != cameraDumped[view] else { continue }
                cameraDumped[view] = v.counter
                var line = "frame \(v.counter) view \(view) t \(v.exposureHostNs) size \(v.width) \(v.height) spots"
                for spot in v.spots.prefix(40) { line += String(format: " %.2f,%.2f,%d,%d", spot.x, spot.y, spot.area, spot.peak) }
                // Each controller's orientation is its newest report's: `…-at` is when that
                // arrived (host ns) and `…-rate` how fast it was turning (rad/s), so the
                // orientation at the exposure can be worked out afterwards.
                let now = hostTimeNs()
                for hand in SenseControllers.Hand.allCases {
                    guard let st = sense.state(hand) else { continue }
                    let q = st.orientation
                    line += String(format: " %@ %.5f,%.5f,%.5f,%.5f", hand.name, q.imag.x, q.imag.y, q.imag.z, q.real)
                    line += " \(hand.name)-at \(now - Int64(Double(st.age) * 1e9))"
                    line += String(format: " %@-rate %.4f,%.4f,%.4f", hand.name, st.angularVelocity.x, st.angularVelocity.y, st.angularVelocity.z)
                }
                // The head where it was at the exposure, not where the frame being drawn has it.
                if let h = headset.predict(atHostNs: v.exposureHostNs) ?? lastHead {
                    line += String(format: " head %.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.5f", h.position.x, h.position.y, h.position.z,
                                   h.orientation.imag.x, h.orientation.imag.y, h.orientation.imag.z, h.orientation.real)
                }
                line += " now \(now)"
                cameraDump?.write((line + "\n").data(using: .utf8)!)
            }
        }
        let now = CACurrentMediaTime()
        guard now - cameraLogTime >= 1 else { return }
        cameraLogTime = now
        var parts: [String] = []
        for view in 0..<4 {
            guard let v = headset.cameraView(view) else { continue }
            let leds = v.spots.filter { $0.area >= 4 && $0.area <= 400 }
            parts.append("view \(view): \(v.frames - cameraFrames[view]) frames, \(v.spotCount) spots (\(leds.count) LED-sized)")
            cameraFrames[view] = v.frames
        }
        log("[cameras] " + (parts.isEmpty ? "no frames yet" : parts.joined(separator: " · ")))
        if Self.trackHands {
            let hands = SenseControllers.Hand.allCases.map { hand -> String in
                guard let s = handStats[hand], s.fixes > 0 else { return "\(hand.name) not seen" }
                let at = handPlaces[hand]?.position ?? .zero
                return String(format: "%@ seen in %d (%.0f LEDs' sightings, %.1f px) at %+.2f %+.2f %+.2f", hand.name, s.fixes,
                              Float(s.sightings) / Float(s.fixes), s.rms / Float(s.fixes), at.x, at.y, at.z)
            }
            log("[hands] \(handExposures) exposures: " + hands.joined(separator: " · "))
            handStats = [:]
            handExposures = 0
        }
    }

    /// The Sense controllers, once per frame: the one in use aims the pointer, and its buttons act.
    /// Its heading starts as the head's and optical tracking refines its pose.
    /// System/menu button taps never recalibrate the sensor-to-pointer alignment.
    private func updateSense(head: HeadPose) {
        let now = CACurrentMediaTime()
        defer { lastStickTime = now }
        senseHasPointer = false
        for hand in SenseControllers.Hand.allCases {
            let slot = hand == .right ? 0 : 1
            guard let state = sense.state(hand), state.settled else {
                senseSeeded.remove(hand)
                senseButtons[hand] = nil
                game?.realHands[slot] = nil
                continue
            }
            if senseSeeded.insert(hand).inserted {
                calibrateSense(hand, state.orientation, head: head, tilt: false)
                notify("\(hand == .left ? "Left" : "Right") controller connected · \(state.batteryPercent)%", symbol: "gamecontroller")
                continue
            }
            let before = senseButtons[hand] ?? []
            let pressed = state.buttons.subtracting(before), released = before.subtracting(state.buttons)
            senseButtons[hand] = state.buttons
            // A game (or a Quest app) has the input: the controller is its hand, where the
            // cameras see it (beside the body until they do), pointing as Halliday's pointer
            // does, and its buttons are the game's. PS held recenters, as R held does
            // (the ring fills). PS is never a game's button or an aim-calibration shortcut.
            if pressed.contains(.ps) { recenterHold(began: true) }
            let tapAction = SenseAimDefaults.tapAction(psReleased: released.contains(.ps),
                recenterFired: recenterHoldFired, gamePresenting: game?.isPresenting == true)
            if released.contains(.ps) { recenterHold(began: false) }
            // PS tapped in a game (or a Quest app) brings Halliday up over it, as Esc does, and
            // tapped again goes back. Create/Options remain the game's menu buttons.
            if tapAction == .toggleGameDashboard {
                setGameAway(!gameAway)
                continue
            }
            if gameActive, let game {
                let forward = head.orientation.act(SIMD3<Float>(0, 0, -1))
                let heading = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
                let guess = head.position + heading.act(SIMD3(hand == .left ? -0.20 : 0.20, -0.30, -0.42))
                // R1 held: a stick pushed up or down raises or lowers the user in the game's
                // world (its floor is not always the room's), and the game doesn't get the sticks.
                let adjusting = sense.state(.right)?.buttons.contains(.grip) == true
                if adjusting, abs(state.stick.y) > 0.25 { game.raise(by: state.stick.y) }
                game.realHands[slot] = GameBridge.RealHand(
                    position: handPlace(hand) ?? guess,
                    orientation: GameControllerAlignment.senseOrientation(senseAim(hand, sensePredicted(state)),
                        pointerMountRadians: senseTilt[hand] ?? SenseAimDefaults.tilt),
                    trigger: state.trigger, triggerPressed: state.buttons.contains(.trigger), grip: state.buttons.contains(.grip),
                    stick: adjusting ? .zero : state.stick, stickClick: state.buttons.contains(.stick), stickTouch: state.buttons.contains(.stickTouch),
                    lower: state.buttons.contains(.lower), upper: state.buttons.contains(.upper), menu: state.buttons.contains(.menu),
                    motion: gameHandMotion(hand, state: state, now: now))
                continue
            }
            game?.realHands[slot] = nil
            // The hand that pulls a trigger or a grip is the hand that points.
            if pressed.contains(.trigger) || pressed.contains(.grip) { senseHand = hand }
            if sense.state(senseHand) == nil { senseHand = hand }
            if !pressed.isEmpty || simd_length(state.angularVelocity) > 0.25 || simd_length(state.stick) > 0.3 {
                if hand == senseHand { senseActivity = now }
            }
            guard hand == senseHand, InputState.shared.sinceMouseMoved > now - senseActivity else { continue }
            // Its aim, as the head sees it.
            senseHasPointer = true
            // What keeps a video's controls and the dock up is the hand's own doing: a button,
            // or the controller turned on purpose. (The pointer's direction is the head's view
            // of the hand, so it moved with every turn of the head and they never hid.)
            // A pull of the trigger or the grip brings them back, never the controller just
            // moving; once up, they stay while the hand moves over them.
            if pressed.contains(.trigger) || pressed.contains(.grip) {
                lastPointerActivity = now
                chromeDismissed = false
            } else if chromeShown, videoControls?.hovered != nil || videoView?.hovered != nil || dock?.hovered != nil, simd_length(state.angularVelocity) > 0.3 {
                lastPointerActivity = now
            }
            // Cross (square on the left hand) puts a video's controls and the dock away, and
            // brings them back.
            if pressed.contains(.lower), video?.isOpen == true {
                if chromeShown { dismissChrome() } else { chromeDismissed = false; lastPointerActivity = now }
            }
            var aim = senseAim(hand, sensePredicted(state)).act(SIMD3<Float>(0, 0, -1))
            // The pointer is a ray from the head; the hand is somewhere else. Where the cameras
            // see the hand, the pointer goes to what the hand's own ray meets (4 m out when it
            // meets nothing): taken from the head, a controller aimed at something near, the
            // dock under the hands, pointed past it, and only far things could be picked.
            if let from = handPlace(hand), let renderer {
                let reach = renderer.nearestHit(origin: from, direction: aim) ?? 4
                let target = from + aim * reach - head.position
                if simd_length(target) > 0.05 { aim = simd_normalize(target) }
            }
            let local = head.orientation.inverse.act(aim)
            InputState.shared.point(yaw: atan2(-local.x, -local.z), pitch: asin(max(-1, min(1, local.y))))
            // On a Mac window in use, the controller does what the mouse does through the tap:
            // the page sees it move, and each press gets its release.
            mouseOwner.controllerMoved()
            if pressed.contains(.trigger) { _ = clickedInView(rightButton: false) }
            if released.contains(.trigger) { releasedInView(rightButton: false); mouseOwner.controllerRelease(rightButton: false) }
            if pressed.contains(.grip) { _ = clickedInView(rightButton: true) }
            if released.contains(.grip) { releasedInView(rightButton: true); mouseOwner.controllerRelease(rightButton: true) }
            // The stick scrolls what the pointer is on: one of Halliday's lists, or a window's page.
            if abs(state.stick.y) > 0.15 || abs(state.stick.x) > 0.15 {
                let onPanel = panels.contains { $0.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) }
                if !onPanel, drag == nil, let video, video.isOpen, renderer?.videoSphere != nil, photos?.isOpen != true {
                    // A video around the viewer: the stick turns where "straight ahead" looks
                    // in it (40° a second at full push), until a recenter.
                    let dt = Float(min(max(now - lastStickTime, 0), 0.05))
                    video.tilt(yaw: state.stick.x * 0.7 * dt, pitch: state.stick.y * 0.7 * dt)
                } else if !onPanel, drag == nil, InputState.shared.hit() != nil {
                    mouseOwner.controllerScroll(dx: Double(state.stick.x) * 14, dy: Double(state.stick.y) * 14)
                } else if abs(state.stick.y) > 0.15 {
                    scrolled(dy: CGFloat(state.stick.y) * 8)
                }
            }
        }
    }

    /// Halliday's own panels that take the pointer, nearest first.
    private var panels: [VRPanel] {
        // Front to back: a pointer on a panel is not on the ones behind it.
        var list: [VRPanel] = []
        if setupPanelOpen, let setupPanel { list.append(setupPanel) }
        if keyboardOpen, let keyboard { list.append(keyboard) }
        if settingsOpen, let settingsPanel { list.append(settingsPanel) }
        if launcherOpen, let launcher { list.append(launcher) }
        if let picker, picker.isOpen { list.append(picker) }
        if fileBrowserOpen, let fileBrowser { list.append(fileBrowser) }
        if notesOpen, let notes { list.append(notes) }
        if clockOpen, let clock { list.append(clock) }
        if controlsOpen, let controls { list.append(controls) }
        if gamesOpen, let games { list.append(games) }
        if gameAway, let gameBar, game?.isPresenting == true { list.append(gameBar) }
        if let home, home.isShown { list.append(home) }
        if musicOpen, let music { list.append(music) }
        if let photoControls, photoControls.isShown { list.append(photoControls) }
        // (A panel on its way out no longer takes the pointer.)
        if let controls = videoControls, controls.isShown, windowManager?.uiLayers.contains(where: { $0 === controls.layer }) == true { list.append(controls) }
        if let drawer = videoView, drawer.isShown, windowManager?.uiLayers.contains(where: { $0 === drawer.layer }) == true { list.append(drawer) }
        if let dock, dock.isShown, windowManager?.uiLayers.contains(where: { $0 === dock.layer }) == true { list.append(dock) }
        if quickSettingsOpen, let quickSettings, quickSettings.isShown { list.insert(quickSettings, at: 0) }
        if let notice, notice.isShown, notice.hasAction, windowManager?.uiLayers.contains(where: { $0 === notice.layer }) == true { list.insert(notice, at: 0) }
        if resizeTarget != nil, let resizeHandle { list.append(resizeHandle) }
        let shown = windowManager?.uiLayers ?? []
        for bar in browserBars.values where shown.contains(where: { $0 === bar.layer }) { list.append(bar) }
        if let open = browserSettings, shown.contains(where: { $0 === open.panel.layer }) { list.append(open.panel) }
        for bar in panelBars.values where windowManager?.uiLayers.contains(where: { $0 === bar.layer }) == true { list.append(bar) }
        return list
    }

    /// A key press while Halliday has the keyboard: the address bar takes it while being edited.
    func typed(_ event: NSEvent) -> Bool {
        if browserBar?.key(event) == true { return true }
        if launcherOpen, let launcher { return launcher.key(event) }
        if notesOpen, let notes { return notes.key(event) }
        return false
    }

    var isEditingAddress: Bool { browserBar?.isEditing == true }

    /// ⌘V while Halliday has the keyboard.
    func pasteIntoAddressBar() { browserBar?.paste() }

    // While a window is in use the event tap owns the mouse; presses on Halliday's panels come from it.

    func panelPress() {
        guard let head = lastHead else { return }
        let direction = head.orientation.act(InputState.shared.pointerDirection)
        guard let panel = panels.first(where: { $0.isOnSurface(origin: head.position, direction: direction) }) else { return }
        pointerDown = true
        _ = panel.press(origin: head.position, direction: direction)
    }

    func panelRelease() { releasedInView(rightButton: false) }

    func pressedWindow(_ id: CGWindowID) { windowManager?.inUse = id }

    func panelScroll(dy: Double) { scrolled(dy: CGFloat(dy)) }

    /// Typing goes to Halliday (address bar, launcher search): the window in use is left.
    private func takeKeyboard() {
        if mouseOwner.isOn {
            mouseOwner.stop(reason: "typing in Halliday")
            mouseOwnershipChanged(false)
        } else {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(view)
        }
    }

    /// The click that ended a window interaction landed outside every window: if it is on one of
    /// Halliday's panels, it is a click on that panel.
    func clickedOutsideWindows() {
        guard let head = lastHead else { return }
        let direction = head.orientation.act(InputState.shared.pointerDirection)
        guard let panel = panels.first(where: { $0.isOnSurface(origin: head.position, direction: direction) }) else { return }
        if panel.press(origin: head.position, direction: direction) { panel.release(origin: head.position, direction: direction) }
    }

    /// The direction (in the head's frame) of a spot of the desktop view, −1…1 from its center.
    private func desktopDirection(_ spot: CGPoint) -> SIMD3<Float> {
        let t = renderer?.desktopTanHalfWidth ?? 1.1
        let aspect = view.map { $0.bounds.width > 0 ? Float($0.bounds.height / $0.bounds.width) : 0.625 } ?? 0.625
        return SIMD3(Float(spot.x) * t, Float(spot.y) * t * aspect, -1)
    }

    // --- Filling the screen ---

    private var frameBeforeFilling: NSRect?

    /// Fills the screen with the preview (or goes back to a window), staying in the current Space.
    @objc func toggleFillScreen() {
        guard let window = window as? PreviewWindow, let screen = window.screen ?? NSScreen.main else { return }
        if let saved = frameBeforeFilling {
            frameBeforeFilling = nil
            window.fillsScreen = false
            NSApp.presentationOptions = []
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            window.styleMask.remove(.fullSizeContentView)
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = false }
            window.setFrame(saved, display: true)
        } else {
            frameBeforeFilling = window.frame
            window.fillsScreen = true
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
            window.setFrame(screen.frame, display: true)
        }
        window.makeFirstResponder(view)
    }

    /// ⌘F: the browser's bar searches the page.
    func findInPage() {
        guard browser != nil else { return }
        updateBrowserBar()
        browserBar?.beginEditing(.find)
    }

    // --- Settings panel ---

    private func toggleSettings() {
        guard let dock else { return }
        if settingsOpen {
            settingsOpen = false
        } else {
            let panel = settingsPanel ?? {
                let p = SettingsPanel(renderer: dock.renderer)
                p.onClose = { [weak self] in self?.settingsOpen = false; self?.lastDockClock = 0 }
                p.onNotice = { [weak self] text in self?.notify(text) }
                p.currentPage = { [weak self] in self?.browser?.displayURL }
                settingsPanel = p
                return p
            }()
            closeOverlays()
            panel.reload()
            panel.place(head: currentHead, distance: overlayDistance(SettingsPanel.distance), below: SettingsPanel.below)
            settingsOpen = true
        }
        lastDockClock = 0
    }

    // --- Virtual keyboard ---

    func toggleKeyboard() {
        guard let dock else { return }
        if keyboardOpen {
            keyboardOpen = false
        } else {
            let panel = keyboard ?? {
                let k = KeyboardPanel(renderer: dock.renderer)
                k.onText = { [weak self] text in self?.keyboardTyped(text) }
                k.onSpecial = { [weak self] key in self?.keyboardPressed(key) }
                k.onHide = { [weak self] in self?.keyboardOpen = false; self?.lastDockClock = 0 }
                keyboard = k
                return k
            }()
            panel.place(head: currentHead, distance: KeyboardPanel.distance, below: KeyboardPanel.below)
            keyboardOffset = panel.layer.position - followPoint(currentHead)
            keyboardOpen = true
        }
        lastDockClock = 0
    }

    /// Text from the virtual keyboard goes to the Halliday field being edited, else to the app of
    /// the window in use.
    private func keyboardTyped(_ text: String) {
        if let bar = browserBar, bar.isEditing {
            bar.insert(text)
        } else if launcherOpen, let launcher {
            launcher.insert(text)
        } else if notesOpen, let notes {
            notes.insert(text)
        } else if mouseOwner.isOn {
            postKey(0, text: text)
        } else {
            notify("Click into a window or a text field first, then type")
        }
    }

    private func keyboardPressed(_ key: KeyboardPanel.Special) {
        if let bar = browserBar, bar.isEditing {
            switch key {
            case .delete: bar.deleteBackward()
            case .enter: bar.commit()
            case .escape: bar.endEditing()
            case .left: bar.moveSelection(-1)
            case .right: bar.moveSelection(1)
            case .tab: break
            }
        } else if launcherOpen, let launcher {
            switch key {
            case .delete: launcher.deleteBackward()
            case .enter: launcher.commit()
            default: break
            }
        } else if notesOpen, let notes {
            switch key {
            case .delete: notes.deleteBackward()
            case .enter: notes.insert("\n")
            case .tab: notes.insert("    ")
            default: break
            }
        } else if mouseOwner.isOn {
            let code: CGKeyCode = switch key {
            case .delete: 51
            case .enter: 36
            case .left: 123
            case .right: 124
            case .tab: 48
            case .escape: 53
            }
            postKey(code, text: nil)
        } else {
            notify("Click into a window or a text field first, then type")
        }
    }

    /// Sends a key press to the app in front (the one whose window is in use), marked as Halliday's
    /// own so the event tap lets it through.
    private func postKey(_ code: CGKeyCode, text: String?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            if let text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: MouseOwner.ownEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // --- Resizing windows ---

    /// Where the pointer meets a plane, in the plane's own x/y (meters).
    private func pointOnPlane(origin: SIMD3<Float>, orientation: simd_quatf) -> SIMD2<Float>? {
        guard let head = lastHead else { return nil }
        let inv = orientation.inverse
        let o = inv.act(head.position - origin), d = inv.act(head.orientation.act(InputState.shared.pointerDirection))
        guard abs(d.z) > 1e-5 else { return nil }
        let t = -o.z / d.z
        guard t > 0 else { return nil }
        let p = o + t * d
        return SIMD2(p.x, p.y)
    }

    /// The resize grip of window `id`'s bar was pressed: dragging right/down makes the real window
    /// larger, left/up smaller, until release.
    private func beginResize(_ id: CGWindowID) {
        guard let wm = windowManager, let w = wm.windows.first(where: { $0.windowID == id }),
              let start = pointOnPlane(origin: w.layer.position, orientation: w.layer.orientation) else { return }
        resizing = (id, w.layer.position, w.layer.orientation, start, w.frame.size, w.layer.width / Float(max(w.frame.width, 1)), 0)
        resizeHandle?.active = true
        wm.raiseOnDisplay(id)
    }

    /// Shows the resize handle at the window corner the pointer is near (or keeps it where it is
    /// while it is pointed at or held), and hides it otherwise.
    private func updateResizeHandle(head: HeadPose) {
        guard let wm = windowManager, let dock else { return }
        if resizeHandle == nil {
            let h = ResizeHandle(renderer: dock.renderer)
            h.onPress = { [weak self] _ in if let t = self?.resizeTarget { self?.beginResize(t.window) } }
            resizeHandle = h
        }
        guard let handle = resizeHandle else { return }
        func place(_ w: MacWindow, _ corner: ResizeHandle.Corner) {
            let distance = wm.nominalDistance(of: w.windowID)
            let half = SIMD2(w.layer.width / 2, w.layer.height / 2)
            // A little outside the corner, so the handle doesn't sit on the window's own controls.
            let out = NightGlass.meters(6, at: distance)
            let offset = SIMD3((corner.isRight ? 1 : -1) * (half.x + out), (corner.isBottom ? -1 : 1) * (half.y + out), 0.002)
            handle.corner = corner
            handle.place(center: w.layer.position + w.layer.orientation.act(offset), orientation: w.layer.orientation, distance: distance)
            handle.layer.travel(with: w.layer)
        }
        // Held, or still under the pointer: it stays at its corner (the window may be changing size).
        if let t = resizeTarget, let w = wm.windows.first(where: { $0.windowID == t.window }), !w.hidden,
           resizing != nil || handle.pressed != nil || handle.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) {
            place(w, t.corner)
            return
        }
        resizeTarget = nil
        guard drag == nil, !wm.windowsHidden, !browsers.contains(where: { $0.xrActive }) else { return }
        var best: (MacWindow, ResizeHandle.Corner, Float)?
        for w in wm.windows where !w.hidden {
            guard let p = pointOnPlane(origin: w.layer.position, orientation: w.layer.orientation) else { continue }
            let distance = wm.nominalDistance(of: w.windowID)
            let half = SIMD2(w.layer.width / 2, w.layer.height / 2)
            // Near a corner: within 34 dmm of it, and not well inside the window (the content there
            // belongs to the app).
            let reach = NightGlass.meters(34, at: distance), inside = NightGlass.meters(12, at: distance)
            if abs(p.x) < half.x - inside, abs(p.y) < half.y - inside { continue }
            // A browser has its bar along the top: its handles are at the bottom corners.
            let corners: [ResizeHandle.Corner] = w.own != nil ? [.bottomLeft, .bottomRight] : ResizeHandle.Corner.allCases
            for c in corners {
                let cornerPoint = SIMD2((c.isRight ? 1 : -1) * half.x, (c.isBottom ? -1 : 1) * half.y)
                let d = simd_distance(p, cornerPoint)
                if d < reach, d < (best?.2 ?? .infinity) { best = (w, c, d) }
            }
        }
        if let (w, corner, _) = best {
            resizeTarget = (w.windowID, corner)
            place(w, corner)
        }
    }

    private func continueResize() {
        guard var r = resizing, let wm = windowManager, let p = pointOnPlane(origin: r.origin, orientation: r.orientation) else { return }
        // Applied about ten times a second: each step is a message to the window's app.
        let now = CACurrentMediaTime()
        guard now - r.lastApplied > 0.1 else { return }
        r.lastApplied = now
        resizing = r
        // The window stays centered where it is, so each edge moves half of what the size gains:
        // twice the pointer's travel keeps the corner under the pointer.
        // The held corner decides which way is "larger".
        let corner = resizeTarget?.corner ?? .bottomRight
        let sx: Float = corner.isRight ? 1 : -1, sy: Float = corner.isBottom ? 1 : -1
        let dw = CGFloat(sx * (p.x - r.start.x) / r.metersPerPoint) * 2, dh = CGFloat(sy * (r.start.y - p.y) / r.metersPerPoint) * 2
        wm.resize(r.window, to: CGSize(width: r.size.width + dw, height: r.size.height + dh))
    }

    private func endResize() {
        guard resizing != nil else { return }
        resizing = nil
        resizeHandle?.active = false
        windowManager?.settleLayout()
    }

    // --- Recenter ---

    /// Brings the whole interface to where the user is looking: the arc of panels, the ones placed
    /// by hand, the dock, video and any open overlay. It moves the interface, not the user.
    func recenterUI() {
        // A running game's world comes back in front of the user too.
        game?.recenter(head: currentHead)
        // The controllers too: each points straight ahead now, as far as Halliday knows.
        for hand in SenseControllers.Hand.allCases {
            if let state = sense.state(hand) { calibrateSense(hand, state.orientation, head: currentHead, tilt: false) }
        }
        dockNeedsPlacement = true
        anchorNeeded = true
        anchorForced = true
        videoControlsNeedPlacement = true
        let head = currentHead
        if let v = video, v.isOpen { v.recenter(head: head) }
        if let p = photos, p.isOpen { p.recenter(head: head) }
        if let p = home, p.isShown {
            p.glide(around: head.position) { p.place(head: head, distance: HomePanel.distance, below: HomePanel.below) }
            homeOffset = p.layer.target.position - followPoint(head)
        }
        photoControlsNeedPlacement = true
        if notesOpen, let p = notes {
            p.glide(around: head.position) { p.place(head: head, distance: overlayDistance(NotesPanel.distance), below: NotesPanel.below) }
        }
        // Open panels glide to the new front with everything else.
        if let picker, picker.isOpen {
            picker.glide(around: head.position) { picker.place(head: head, distance: overlayDistance(WindowPicker.distance), below: WindowPicker.below) }
        }
        if fileBrowserOpen, let p = fileBrowser {
            p.glide(around: head.position) { p.place(head: head, distance: overlayDistance(FileBrowser.distance), below: FileBrowser.below) }
        }
        if launcherOpen, let p = launcher {
            p.glide(around: head.position) { p.place(head: head, distance: overlayDistance(AppLauncher.distance), below: AppLauncher.below) }
        }
        if settingsOpen, let p = settingsPanel {
            p.glide(around: head.position) { p.place(head: head, distance: overlayDistance(SettingsPanel.distance), below: SettingsPanel.below) }
        }
        if keyboardOpen, let p = keyboard {
            p.glide(around: head.position) { p.place(head: head, distance: KeyboardPanel.distance, below: KeyboardPanel.below) }
            keyboardOffset = p.layer.target.position - followPoint(head)
        }
        lastPointerActivity = CACurrentMediaTime()
    }

    /// The recenter button (the R key now, a controller button later) went down or up. Held for
    /// `recenterHoldSeconds`, with a ring filling in the middle of the view, it recenters: it works
    /// when no panel is in sight, and a brush of the button does nothing.
    func recenterHold(began: Bool) {
        recenterHoldStart = began ? CACurrentMediaTime() : nil
        recenterHoldFired = false
        if !began { renderer?.recenterProgress = 0 }
    }

    private func updateRecenterHold() {
        guard let start = recenterHoldStart, !recenterHoldFired else { return }
        let progress = (CACurrentMediaTime() - start) / Self.recenterHoldSeconds
        renderer?.recenterProgress = Float(min(1, max(0.02, progress)))
        if progress >= 1 {
            recenterHoldFired = true
            renderer?.recenterProgress = 0
            recenterUI()
        }
    }

    /// One large panel at a time: opening the launcher, the Windows panel or the file browser closes
    /// the others.
    private func closeOverlays() {
        settingsOpen = false
        launcherOpen = false
        fileBrowserOpen = false
        closeNotes()
        clockOpen = false
        controlsOpen = false
        musicOpen = false
        gamesOpen = false
        picker?.close()
    }

    /// Opens the video after the one playing, in its folder.
    private func playNextVideo() {
        guard let url = video?.url, url.isFileURL, let next = VideoPlayer.next(after: url) else { return }
        Task { @MainActor in await self.video?.open(next, head: self.currentHead) }
    }

    /// What every button and key does (`ControlsGuide`), on the topic for what is going on.
    private func openControls() {
        guard let dock else { return }
        let panel = controls ?? {
            let p = ControlsPanel(renderer: dock.renderer)
            p.onClose = { [weak self] in self?.controlsOpen = false }
            controls = p
            return p
        }()
        let topic = game?.isPresenting == true ? "games" : video?.isOpen == true ? "video" : "controllers"
        closeOverlays()
        panel.show(topic: topic)
        panel.place(head: currentHead, distance: overlayDistance(ControlsPanel.distance), below: ControlsPanel.below)
        controlsOpen = true
    }

    // --- Clock and Music ---

    private func openClock() {
        guard let dock else { return }
        let panel = clock ?? {
            let p = ClockPanel(renderer: dock.renderer)
            p.onClose = { [weak self] in self?.clockOpen = false; self?.lastDockClock = 0 }
            clock = p
            return p
        }()
        closeOverlays()
        panel.place(head: currentHead, distance: overlayDistance(ClockPanel.distance), below: ClockPanel.below)
        panel.setNeedsDisplay()
        clockOpen = true
    }

    /// The headset's side of setup (board 16): no dock or Home until it goes.
    private func openSetupPanel() {
        guard let dock else { return }
        let panel = setupPanel ?? {
            let p = SetupPanel(renderer: dock.renderer)
            p.onLater = { [weak self] in Setup.shared.later(); self?.setupPanelOpen = false }
            p.onStart = { [weak self] in self?.setupPanelOpen = false; self?.recenterUI() }
            setupPanel = p
            return p
        }()
        panel.ready = false
        setupPanelOpen = true
        setupPanelPlaced = false
        log("[setup] the headset's panel: take it off, set up on the Mac")
    }

    private func openMusic() {
        guard let dock else { return }
        let panel = music ?? {
            let p = MusicPanel(renderer: dock.renderer)
            p.onClose = { [weak self] in self?.musicOpen = false; self?.lastDockClock = 0 }
            music = p
            return p
        }()
        closeOverlays()
        panel.place(head: currentHead, distance: overlayDistance(MusicPanel.distance), below: MusicPanel.below)
        panel.start()
        musicOpen = true
    }

    // --- Notes ---

    /// Opens Notes in front of the viewer (on `file`, a text file from Files, if given), or closes it.
    private func toggleNotes(opening file: URL? = nil) {
        guard let dock else { return }
        if notesOpen, file == nil {
            closeNotes()
        } else {
            let panel = notes ?? {
                let p = NotesPanel(renderer: dock.renderer)
                p.onClose = { [weak self] in self?.closeNotes() }
                p.onNotice = { [weak self] text in self?.notify(text) }
                p.onWantsKeyboard = { [weak self] in
                    self?.takeKeyboard()
                    if Settings.shared.keyboardAuto, self?.keyboardOpen == false { self?.toggleKeyboard() }
                }
                notes = p
                return p
            }()
            closeOverlays()
            panel.prepare(opening: file)
            panel.place(head: currentHead, distance: overlayDistance(NotesPanel.distance), below: NotesPanel.below)
            notesOpen = true
            // Notes are written with the keyboard: Halliday takes the keys.
            takeKeyboard()
        }
        lastDockClock = 0
    }

    private func closeNotes() {
        guard notesOpen else { return }
        notes?.save()
        notesOpen = false
        lastDockClock = 0
    }

    /// Opens `url` in its Mac app and brings that app's window into VR.
    private func openWithMac(_ url: URL) {
        guard let wm = windowManager else { return }
        guard CGPreflightScreenCaptureAccess() else {
            notify("macOS hasn't let Halliday see the Mac's windows: allow it on the Mac's screen", kind: .warning)
            Permissions.shared.request(.screenRecording)
            return
        }
        let name = url.lastPathComponent
        notify("Opening \(name)", kind: .progress, seconds: 14)
        Task { @MainActor in
            guard await wm.prepareDisplay() else { return }
            wm.focusVirtualDisplay()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            do {
                let running = try await NSWorkspace.shared.open(url, configuration: config)
                await self.bringWindow(of: running, name: running.localizedName ?? name)
            } catch {
                self.notify("\(name) couldn't be opened: \(error.localizedDescription)", kind: .warning)
                self.takeFocusBack()
            }
        }
    }

    /// After an app was started or asked to open something: waits for a window of it that is not
    /// in VR yet and brings it in, then takes the focus back.
    private func bringWindow(of running: NSRunningApplication, name: String, saysAlreadyHere: Bool = false) async {
        guard let wm = windowManager else { return }
        defer { takeFocusBack() }
        // Its window may take a moment to appear: look for one for a while.
        let pid = running.processIdentifier
        for _ in 0..<24 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let list = await wm.candidates() else { continue }
            let mine = list.filter { $0.window.owningApplication?.processID == pid }
            if mine.contains(where: { $0.state == .inVR }) && !mine.contains(where: { $0.state == .ready }) {
                // A window of an app already in VR: new windows of it join by themselves.
                if saysAlreadyHere { notify("\(name) is already in VR") } else if notice?.kind == .progress { noticeUntil = 0 }
                return
            }
            if let c = mine.first(where: { $0.state == .ready }) ?? mine.first(where: { $0.state != .inVR }) {
                if await wm.bring(c), notice?.kind == .progress { noticeUntil = 0 } // it is here
                return
            }
        }
        notify("\(name) is open but has no window to bring in", kind: .warning)
    }

    // --- App launcher ---

    private func toggleLauncher() {
        guard let dock else { return }
        if launcherOpen {
            launcherOpen = false
        } else {
            let panel = launcher ?? {
                let p = AppLauncher(renderer: dock.renderer)
                p.onClose = { [weak self] in self?.launcherOpen = false; self?.lastDockClock = 0 }
                p.onLaunch = { [weak self] app in self?.launch(app) }
                p.onNotice = { [weak self] text in self?.notify(text, symbol: "pin") }
                launcher = p
                return p
            }()
            closeOverlays()
            panel.prepare()
            panel.place(head: currentHead, distance: overlayDistance(AppLauncher.distance), below: AppLauncher.below)
            launcherOpen = true
            // The launcher is searched with the Mac keyboard: Halliday takes the keys.
            takeKeyboard()
        }
        lastDockClock = 0
    }

    /// Opens one of Halliday's own apps, or starts a Mac app and brings its window into VR.
    private func launch(_ app: AppLauncher.App) {
        closeOverlays()
        lastDockClock = 0
        switch app.id {
        case "halliday:browser": openBrowserWindow()
        case "halliday:videos": toggleFileBrowser(mode: .videos, keepOpen: true)
        case "halliday:files": toggleFileBrowser(mode: .files, keepOpen: true)
        case "halliday:photos":
            // Photos starts in the Pictures folder: a picture chosen there opens in the viewer.
            toggleFileBrowser(mode: .files, keepOpen: true, start: FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first)
        case "halliday:notes": if !notesOpen { toggleNotes() }
        case "halliday:clock": openClock()
        case "halliday:music": openMusic()
        case "halliday:games": openGames()
        case "halliday:windows": if picker?.isOpen != true { handleKey("m") }
        case "halliday:settings": if !settingsOpen { toggleSettings() }
        case "halliday:controls": openControls()
        default:
            guard let url = app.url, let wm = windowManager else { return }
            guard CGPreflightScreenCaptureAccess() else {
                notify("macOS hasn't let Halliday see the Mac's windows: allow it on the Mac's screen", kind: .warning)
                Permissions.shared.request(.screenRecording)
                return
            }
            // A spinner until its window is here (or it turns out it can't come).
            notify("Opening \(app.name)", kind: .progress, seconds: 14)
            Task { @MainActor in await self.openMacApp(url, name: app.name, wm: wm) }
        }
    }

    /// Starts (or activates) the Mac app at `url` and brings its window into VR.
    private func openMacApp(_ url: URL, name: String, wm: WindowManager) async {
        // The app is activated with the virtual display as the active one: a new app opens its
        // window on the active display, so it lands where Halliday can show it, whatever Space the
        // Mac's own screen is in (a full-screen app, Halliday filling the screen). An app that
        // reopens its windows where they were is reached by the activation itself: macOS switches
        // to the Space they are in.
        guard await wm.prepareDisplay() else { return }
        wm.focusVirtualDisplay()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let running: NSRunningApplication
        do {
            running = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        } catch {
            notify("\(name) couldn't be opened: \(error.localizedDescription)", kind: .warning)
            takeFocusBack()
            return
        }
        await bringWindow(of: running, name: name, saysAlreadyHere: true)
    }

    /// Home's "continue" cards.
    private func continueFromHome(_ item: HomePanel.Item) {
        switch item.kind {
        case .video(let url): Task { @MainActor in await self.video?.open(url, head: self.currentHead) }
        case .page(let url): openBrowserWindow(startURL: url)
        case .note(let url): toggleNotes(opening: url)
        case .windows(let apps):
            guard let wm = windowManager else { return }
            guard CGPreflightScreenCaptureAccess() else {
                notify("macOS hasn't let Halliday see the Mac's windows: allow it on the Mac's screen", kind: .warning)
                return
            }
            notify("Bringing back \(item.title)", kind: .progress, seconds: 30)
            // One app at a time: each is activated on the virtual display and its window brought in.
            Task { @MainActor in
                for app in Dictionary(grouping: apps, by: \.bundle).keys.sorted() {
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { continue }
                    let name = apps.first { $0.bundle == app }?.name ?? app
                    await self.openMacApp(url, name: name, wm: wm)
                }
                if self.notice?.kind == .progress { self.noticeUntil = 0 }
            }
        }
    }

    /// After another app was activated on Halliday's behalf (to open it, or to reach its window in
    /// another Space), Halliday becomes the active app again and keeps the mouse if it had it.
    private func takeFocusBack() {
        guard !mouseOwner.isOn else { return }
        let engaged = pointerEngaged || pointerLocked || focusWasEngaged
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
        if engaged {
            pointerEngaged = true
            setPointerLock(true, force: true)
        }
        focusWasEngaged = false
    }

    // --- Notices and overlay panels ---

    private var volumeMonitor: Any?

    /// A media key (`NX_KEYTYPE_SOUND_UP` 0, `_DOWN` 1, `MUTE` 7) going down, repeats included.
    private func volumeKey(_ event: NSEvent) {
        guard event.subtype.rawValue == 8, (event.data1 & 0xFF00) >> 8 == 0xA else { return }
        let key = (event.data1 & 0xFFFF0000) >> 16
        guard [0, 1, 7].contains(key), !Self.outputHasVolume() else { return }
        let settings = Settings.shared
        var level = settings.volume
        switch key {
        case 0: level = playerMuted ? level : min(1, level + 1.0 / 16)
        case 1: level = max(0, level - 1.0 / 16)
        default: playerMuted.toggle()
        }
        if key != 7 { playerMuted = false }
        settings.volume = level // applies it (`applySettings`)
        applyVolume()
        let shown = playerMuted ? "Muted" : "Volume \(Int((level * 100).rounded())) %"
        notify(shown, symbol: playerMuted || level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", seconds: 1.2)
    }
    private var playerMuted = false
    private var appliedVolume = Settings.shared.volume

    /// Halliday's master volume, to everything of its own that plays: a video, a Quest app's
    /// player, the interface sounds (at their own level under it).
    private func applyVolume() {
        // A level set by hand (a slider) ends a mute.
        if Settings.shared.volume != appliedVolume { playerMuted = false }
        appliedVolume = Settings.shared.volume
        let level = playerMuted ? 0 : appliedVolume
        video?.volume = level
        QuestApps.setVolume(level)
        Sounds.volume = Settings.shared.soundVolume * level
        quickSettings?.setNeedsDisplay()
    }

    /// Whether the Mac can set the level of the output in use itself.
    private static func outputHasVolume() -> Bool {
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var which = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &which, 0, nil, &size, &device) == noErr else { return true }
        var volume = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &volume)
    }

    /// Shows a short message in VR for a few seconds (and logs it).
    /// `kind`: information, a warning (something couldn't be done), or progress (a spinner, until
    /// the next notice or `seconds`). `action`: a button on the notice for the way forward.
    func notify(_ text: String, symbol: String? = nil, kind: NoticePanel.Kind = .info,
                action: (title: String, run: () -> Void)? = nil, seconds: Double? = nil) {
        log("[notice] \(text)")
        guard let notice else { return }
        notice.show(text, symbol: symbol, kind: kind, action: action)
        notice.place(head: currentHead, distance: overlayDistance(0.95), below: 13)
        // Long enough to read; longer when there is something to click.
        noticeUntil = CACurrentMediaTime() + (seconds ?? (action != nil ? 8 : 4.5))
        if kind != .progress { Sounds.play(kind == .warning ? .problem : .notice) }
    }

    /// The distance for a panel that must be in front of everything (picker, file browser, notice):
    /// its usual distance, or closer when a window is nearer than that. Panels are sized as angles,
    /// so one placed closer looks the same.
    private func overlayDistance(_ preferred: Float) -> Float {
        guard let wm = windowManager, !wm.windowsHidden else { return preferred }
        let head = currentHead.position
        let nearest = wm.windows.map { simd_distance($0.layer.position, head) }.min() ?? .infinity
        return max(0.5, min(preferred, nearest - 0.25))
    }

    /// A press whose release never reached Halliday (macOS delivered the mouse-up elsewhere, e.g.
    /// when the click changed which window is active) would leave a button held and swallow the
    /// next click: when the button is up and Halliday still thinks it is down, it is released here.
    private func recoverLostRelease() {
        guard !mouseOwner.isOn, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        guard pointerDown || drag != nil || panels.contains(where: { $0.pressed != nil }) else { return }
        if VRPanel.logsPresses { log("[ui] the mouse-up didn't arrive: released by Halliday") }
        releasedInView(rightButton: false)
    }

    // --- File browser ---

    /// Opens the file browser in front of the viewer as Videos or Files (at `start`, if given), or
    /// closes it if it is open in that mode (`keepOpen`: never closes).
    private func toggleFileBrowser(mode: FileBrowser.Mode = .videos, keepOpen: Bool = false, start: URL? = nil) {
        guard let dock else { return }
        if fileBrowserOpen, fileBrowser?.mode == mode, !keepOpen {
            fileBrowserOpen = false
        } else {
            let panel = fileBrowser ?? {
                let p = FileBrowser(renderer: dock.renderer)
                p.onClose = { [weak self] in self?.fileBrowserOpen = false; self?.lastDockClock = 0 }
                p.onOpen = { [weak self] url in
                    guard let self else { return }
                    fileBrowserOpen = false
                    Task { @MainActor in await self.video?.open(url, head: self.currentHead) }
                }
                p.onOpenImage = { [weak self] url, siblings in
                    guard let self else { return }
                    fileBrowserOpen = false
                    photos?.open(url, among: siblings, head: currentHead)
                }
                p.onOpenText = { [weak self] url in self?.toggleNotes(opening: url) }
                p.onOpenOther = { [weak self] url in
                    self?.fileBrowserOpen = false
                    // An Android package is a Quest app to install, not a file for a Mac app.
                    if url.pathExtension.lowercased() == "apk" {
                        // Chosen from Games: back to Games, where it shows once installed.
                        let fromGames = self?.fileBrowser?.mode == .apps
                        self?.installQuestApp(url)
                        if fromGames { self?.openGames() }
                    } else {
                        self?.openWithMac(url)
                    }
                }
                fileBrowser = p
                return p
            }()
            let wasOpen = fileBrowserOpen
            closeOverlays()
            panel.refresh(mode: mode, start: start)
            if !wasOpen { panel.place(head: currentHead, distance: overlayDistance(FileBrowser.distance), below: FileBrowser.below) }
            fileBrowserOpen = true
        }
        lastDockClock = 0
    }

    // --- Settings ---

    private func toggleQuickSettings() {
        guard let dock else { return }
        if quickSettings == nil {
            let panel = QuickSettings(renderer: dock.renderer)
            panel.onRecenter = { [weak self] in self?.handleKey("r") }
            panel.onAllSettings = { [weak self] in
                self?.quickSettingsOpen = false
                self?.toggleSettings()
            }
            quickSettings = panel
        }
        quickSettingsOpen.toggle()
        lastDockClock = 0
    }

    /// Applies the settings that take effect at once (the rest are read where they are used).
    private func applySettings() {
        let s = Settings.shared
        Motion.reduced = s.reduceMotion
        windowManager?.remembersLayouts = s.rememberLayouts
        let ipd = renderer?.ipd ?? 0.064
        for b in browsers { b.configureXR(ipd: ipd, fovLeft: Optics.fov(.left), fovRight: Optics.fov(.right), eyeSize: s.vrPageEye) }
        applyVolume()
        renderer?.baseDimming = s.dimming
        if s.environment != appliedEnvironment, !CommandLine.arguments.contains("--environment") {
            appliedEnvironment = s.environment
            environments?.apply(s.environment)
        }
        InputState.shared.setPointerSpeed(s.pointerSpeed)
        if let wm = windowManager, abs(wm.radius - s.panelDistance) > 0.001 {
            // The arc stays at the same angle below eye level, so panels move straight back.
            let eyes = wm.center.y + WindowManager.arcDrop * wm.radius
            wm.anchor(center: SIMD3(wm.center.x, eyes - WindowManager.arcDrop * s.panelDistance, wm.center.z), yaw: wm.heading,
                      radius: s.panelDistance, carry: false)
        }
        // Seated: no walking in the simulator; the head goes back to its place.
        if s.mode == .seated { anchorNeeded = true }
        // A change of mode brings the interface to where the user is now (after walking around in
        // room-scale, the dock and the windows would otherwise stay where they were left).
        if s.mode != lastMode {
            lastMode = s.mode
            recenterUI()
        }
        scheduleGameImageReconfiguration()
    }

    /// Image dimensions are negotiated at connection. Defer edits during a live game.
    private func scheduleGameImageReconfiguration() {
        gameImageReconfiguration?.cancel()
        gameImageReconfiguration = nil
        guard let game, game.imageRenderPercent != Settings.shared.gameRenderPercent else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.applyGameImageReconfiguration() { self.scheduleGameImageReconfiguration() }
        }
        gameImageReconfiguration = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    private func applyGameImageReconfiguration() -> Bool {
        guard let game, game.imageRenderPercent != Settings.shared.gameRenderPercent else { return true }
        guard game.canReconfigureImage, let renderer else { return false }
        gameImageReconfiguration?.cancel()
        gameImageReconfiguration = nil
        game.onChange = nil
        game.close()
        self.game = nil
        renderer.projection = nil
        startGameBridge(renderer)
        return true
    }

    /// Seated mode: the arc is centered on the user and faces where they face (at launch and on
    /// recenter), carrying hand-placed panels along. Room-scale leaves panels where they are.
    private func anchorIfNeeded(head: HeadPose) {
        guard anchorNeeded else { return }
        anchorNeeded = false
        let forced = anchorForced
        anchorForced = false
        guard Settings.shared.mode == .seated || forced, let wm = windowManager else { return }
        let yaw = Self.angles(of: head.orientation.act(SIMD3<Float>(0, 0, -1))).yaw
        wm.anchor(center: head.position - SIMD3(0, WindowManager.arcDrop * wm.radius, 0), yaw: yaw, radius: wm.radius, carry: true)
    }

    // --- Dragging panels ---

    private static func angles(of v: SIMD3<Float>) -> (yaw: Float, pitch: Float) {
        let d = simd_normalize(v)
        return (atan2(-d.x, -d.z), asin(max(-1, min(1, d.y))))
    }

    /// The handle of window `id`'s bar was pressed: the window follows the saber until release.
    private func beginDrag(_ id: CGWindowID) {
        guard let wm = windowManager, let head = lastHead, let layer = wm.layer(for: id) else { return }
        let toWindow = layer.position - head.position
        let w = Self.angles(of: toWindow)
        let p = Self.angles(of: head.orientation.act(InputState.shared.pointerDirection))
        let distance = simd_length(toWindow)
        let scale = wm.nominalDistance(of: id) / WindowManager.referenceDistance
        drag = (id, w.yaw - p.yaw, w.pitch - p.pitch, distance, scale)
        dragStartPointer = InputState.shared.pointerDirection
        dragMoved = false
        panelBars[id]?.grabbed = true
    }

    /// Each frame while dragging: the window sits on a sphere around the head, facing it.
    private func continueDrag(head: HeadPose, pointer: SIMD3<Float>) {
        guard let d = drag, let wm = windowManager else { return }
        // Until the pointer has really moved, it is a click on the handle, not a drag.
        if !dragMoved {
            guard simd_distance(InputState.shared.pointerDirection, dragStartPointer) > 0.012 else { return }
            dragMoved = true
            dropSlotsPending = true
        }
        // With the mouse, the pointer only reaches about 45° from the view's center: near that
        // limit the view turns, so a panel can be dragged all the way around.
        if view?.source is MouseLook {
            let local = Self.angles(of: InputState.shared.pointerDirection)
            if abs(local.yaw) > 0.62 { mouse.yaw += local.yaw > 0 ? 0.02 : -0.02 }
            if abs(local.pitch) > 0.55 { mouse.pitch = max(-1.2, min(1.2, mouse.pitch + (local.pitch > 0 ? 0.012 : -0.012))) }
        }
        let p = Self.angles(of: pointer)
        let yaw = p.yaw + d.yaw
        // The window and its bar stay above the dock's band.
        let size = wm.layer(for: d.window).map { ($0.width, $0.height) } ?? (1, 1)
        let lowest = wm.lowestPitch(yaw: yaw, width: size.0, height: size.1, distance: d.distance, scale: d.scale)
        let pitch = max(lowest, min(1.2, p.pitch + d.pitch))
        let orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        wm.place(d.window, position: head.position + orientation.act(SIMD3(0, 0, -d.distance)),
                 orientation: orientation, scale: d.scale)
        // The free places it can drop into, once the arc has closed the gap it left.
        if dropSlotsPending, let renderer {
            dropSlotsPending = false
            dropSlots = wm.dropSlots(for: d.window).map { s in
                let p = SlotPanel(renderer: renderer, width: s.width, height: s.height, distance: wm.radius)
                p.place(center: s.position, orientation: s.orientation, distance: wm.radius * SlotPanel.density)
                return (s, p)
            }
            dropSlotsShown = !dropSlots.isEmpty
        }
        // The free place the window is over lights up (within about 10° of it, seen from the eyes).
        if let layer = wm.layer(for: d.window) {
            let toWindow = simd_normalize(layer.position - head.position)
            let near = dropSlots.map { acos(min(1, simd_dot(toWindow, simd_normalize($0.slot.position - head.position)))) }
            let best = near.indices.min { near[$0] < near[$1] }
            for (i, s) in dropSlots.enumerated() { s.panel.lit = i == best && near[i] < 0.18 }
        }
    }

    private func endDrag() {
        guard let d = drag else { return }
        panelBars[d.window]?.grabbed = false
        drag = nil
        // A click on the handle without moving it: twice in a row sends the window back to the arc.
        if !dragMoved {
            let now = CACurrentMediaTime()
            if let last = lastHandleClick, last.window == d.window, now - last.time < 0.5 {
                windowManager?.returnToArc(d.window)
                lastHandleClick = nil
            } else {
                lastHandleClick = (d.window, now)
            }
            return
        }
        dropSlotsShown = false
        // Over a free place: it settles there (in the arc, or above it).
        if let lit = dropSlots.first(where: { $0.panel.lit })?.slot, let wm = windowManager {
            if lit.kind == .above {
                wm.place(d.window, position: lit.position, orientation: lit.orientation, scale: 1)
                wm.rememberPlacement(of: d.window)
            } else {
                wm.joinArc(d.window, at: lit.kind)
            }
            return
        }
        // Dropped on another window, it settles beside it; the arc makes room around it.
        if let head = lastHead { windowManager?.settleDrop(d.window, viewer: head.position) }
        windowManager?.rememberPlacement(of: d.window)
    }

    /// Scrolling while dragging pushes the panel away or pulls it closer.
    func scrolled(dy: CGFloat) {
        if gameActive, let game {
            game.scroll(by: dy, shift: NSEvent.modifierFlags.contains(.shift))
            return
        }
        if drag == nil, launcherOpen, let launcher, let head = lastHead,
           launcher.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) {
            launcher.scroll(by: dy)
            return
        }
        if drag == nil, let picker, picker.isOpen, let head = lastHead,
           picker.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) {
            picker.scroll(by: dy)
            return
        }
        if drag == nil, gamesOpen, let games, let head = lastHead,
           games.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) {
            games.scroll(by: dy)
            return
        }
        if drag == nil, fileBrowserOpen, let fileBrowser, let head = lastHead,
           fileBrowser.isOnSurface(origin: head.position, direction: head.orientation.act(InputState.shared.pointerDirection)) {
            fileBrowser.scroll(by: dy)
            return
        }
        guard var d = drag else { return }
        d.distance = max(0.5, min(5, d.distance * exp(Float(dy) * 0.02)))
        drag = d
        dragMoved = true
    }

    /// The close button of window `id`'s bar: the browser closes, a Mac window goes back to the desktop.
    private func closePanel(_ id: CGWindowID) {
        endDrag()
        if let b = browser(forWindow: id) { closeBrowser(b) } else { windowManager?.closeWindow(id) }
    }

    /// The ↩ button of a Mac window's bar: out of VR, back where it was on the desktop, still open.
    private func sendBackPanel(_ id: CGWindowID) {
        endDrag()
        windowManager?.sendBack(id)
    }

    func blockedClick() { notify("A window's own title-bar buttons aren't used in VR: the bar under the window closes it or sends it back", kind: .warning) }

    /// Keeps the browser's bar above its page: created for the page's width, hidden in theater
    /// mode and while a page is in VR.
    private func updateBrowserBar() {
        guard let wm = windowManager, let dock else { return }
        // A bar above every browser window (not in theater mode or while a page is in VR).
        var browserLayers: [QuadLayer] = []
        let inVR = browsers.contains { $0.xrActive }
        for (number, _) in browserBars where !browsers.contains(where: { $0.window.windowNumber == number }) { browserBars[number] = nil }
        if let open = browserSettings, !browsers.contains(where: { $0.window.windowNumber == open.window }) { browserSettings = nil }
        for b in browsers where !inVR && !wm.windowsHidden {
            let number = b.window.windowNumber, id = CGWindowID(number)
            guard let layer = wm.layer(for: id), wm.windows.first(where: { $0.windowID == id })?.hidden != true else { continue }
            // The page's width as an angle (dmm): its width over its distance, wherever it was dragged.
            let distance = wm.nominalDistance(of: id)
            let width = (CGFloat(layer.width / distance) * 1000).rounded()
            if browserBars[number] == nil || abs(browserBars[number]!.barWidth - width) > 1 {
                let editing = browserBars[number]?.isEditing == true
                let bar = BrowserBar(renderer: dock.renderer, browser: b, width: width)
                // A bar remade for a new width (the window is being resized) is already here: no fade-in.
                if let old = browserBars[number] { bar.layer.presence = old.layer.presence }
                bar.onWantsKeyboard = { [weak self] in
                    self?.currentBrowser = number
                    self?.takeKeyboard()
                    if Settings.shared.keyboardAuto, self?.keyboardOpen == false { self?.toggleKeyboard() }
                }
                bar.onNotice = { [weak self] text in self?.notify(text) }
                bar.onNewWindow = { [weak self] in self?.openBrowserWindow() }
                bar.onSettings = { [weak self, weak b] in if let b { self?.toggleBrowserSettings(for: b) } }
                browserBars[number] = bar
                if editing { bar.beginEditing() }
            }
            guard let bar = browserBars[number] else { continue }
            bar.attach(above: layer, distance: distance, gap: 10)
            // Bars fade out while their window travels to a new place and size, and back in after.
            browserLayers += shown(bar, !layer.isGliding, tier: 0)
            if let open = browserSettings, open.window == number {
                open.panel.attach(rightOf: layer, distance: distance, gap: 14)
                browserLayers.append(open.panel.layer)
            }
        }
        // A bar under every window (not in theater mode or while a page is in VR).
        var bars: [PanelBar] = []
        var barLayers: [QuadLayer] = []
        let ids = Set(wm.windows.map(\.windowID))
        for id in panelBars.keys where !ids.contains(id) { panelBars[id] = nil }
        if !wm.windowsHidden, !inVR {
            // A window that just went off screen (closing) is no longer drawn: neither is its bar.
            for w in wm.windows where !w.hidden {
                let id = w.windowID
                let panel = panelBars[id] ?? {
                    let b = PanelBar(renderer: dock.renderer, canSendBack: w.own == nil)
                    b.onPress = { [weak self] control in if control == "grab" { self?.beginDrag(id) } }
                    b.onActivate = { [weak self] control in
                        if control == "close" { self?.closePanel(id) } else if control == "back" { self?.sendBackPanel(id) }
                    }
                    panelBars[id] = b
                    return b
                }()
                panel.attach(below: w.layer, distance: wm.nominalDistance(of: id), gap: 10)
                bars.append(panel)
                barLayers += shown(panel, !w.layer.isGliding, tier: 0)
            }
        }
        if quickSettingsOpen, let quickSettings {
            quickSettings.attach(above: dock.layer, distance: Dock.distance, gap: -44)
        }
        // Video controls; with the dock they hide while a video plays and the pointer rests.
        var chromeVisible = true
        var controlLayers: [QuadLayer] = []
        if let controls = videoControls, let head = lastHead {
            if videoControlsNeedPlacement {
                controls.glide(around: head.position) { controls.place(head: head, distance: VideoControls.distance, below: VideoControls.below) }
                subtitles?.place(head: head, distance: SubtitlePanel.distance, below: SubtitlePanel.below)
                videoControlsNeedPlacement = false
            }
            let now = CACurrentMediaTime()
            if now - lastVideoControlsRefresh > 0.25 {
                lastVideoControlsRefresh = now
                controls.refresh()
                videoView?.refresh()
            }
            // The view drawer sits on the bar.
            if controls.viewOpen { videoView?.attach(above: controls.layer, distance: VideoControls.distance, gap: 6) }
            // The picture at the pointer's place on the seek bar, above whatever is on top.
            controls.updatePreview()
            if let preview = controls.preview, let panel = scrubPreview {
                panel.show(preview)
                panel.attach(above: controls.viewOpen ? (videoView?.layer ?? controls.layer) : controls.layer, distance: VideoControls.distance, gap: 2)
            }
            // A resting controller points somewhere too, often at the dock under the hands:
            // only the mouse's pointer holds them up by lying on them.
            let busy = pointerDown || quickSettingsOpen || fileBrowserOpen || launcherOpen || settingsOpen || picker?.isOpen == true
                || (!senseHasPointer && (controls.hovered != nil || dock.hovered != nil || videoView?.hovered != nil))
            chromeVisible = !chromeDismissed && (video?.isPlaying != true || busy || now - lastPointerActivity < 4)
            chromeShown = chromeVisible
            // A 3D video under the interface is shown flat and dimmed: its depth fought the
            // panels drawn over it (things of the video nearer than the bar, yet behind it).
            renderer?.videoUnderInterface = chromeVisible
            controlLayers = shown(controls, chromeVisible) + shown(videoView, chromeVisible && controls.viewOpen)
                + shown(scrubPreview, chromeVisible && controls.preview != nil)
                + shown(subtitles, subtitles?.text != nil)
        }
        if let controls = photoControls, let head = lastHead {
            if photoControlsNeedPlacement {
                controls.glide(around: head.position) { controls.place(head: head, distance: PhotoControls.distance, below: PhotoControls.below) }
                photoControlsNeedPlacement = false
            }
            controlLayers += shown(controls, true)
        }
        if keyboardOpen { chromeVisible = false } // the keyboard takes the dock's place
        if setupPanelOpen { chromeVisible = false } // first launch: nothing but the setup panel
        if setupPanelOpen, !setupPanelPlaced, let head = lastHead, let panel = setupPanel {
            panel.place(head: head, distance: SetupPanel.distance, below: SetupPanel.below)
            panel.setNeedsDisplay()
            setupPanelPlaced = true
        }
        // Home, while nothing is open.
        let nothingOpen = wm.windows.isEmpty && !browserOpening && browsers.isEmpty && !launcherOpen && !settingsOpen && !fileBrowserOpen
            && picker?.isOpen != true && !notesOpen && !clockOpen && !controlsOpen && !musicOpen && video?.isOpen != true && photos?.isOpen != true
            && !gamesOpen && game?.isPresenting != true && !setupPanelOpen
        if nothingOpen, !homeWasShown, let head = lastHead {
            let panel = home ?? {
                let p = HomePanel(renderer: dock.renderer)
                p.onLaunch = { [weak self] app in self?.launch(app) }
                p.onAllApps = { [weak self] in if self?.launcherOpen == false { self?.toggleLauncher() } }
                p.onContinue = { [weak self] item in self?.continueFromHome(item) }
                home = p
                return p
            }()
            panel.prepare()
            panel.place(head: head, distance: HomePanel.distance, below: HomePanel.below)
            homeOffset = panel.layer.position - followPoint(head)
            homeWasShown = true
        } else if !nothingOpen {
            homeWasShown = false
        }
        home?.tick()
        // Panels fade in and out: one stays in the scene until it is gone.
        let overlays = shown(keyboard, keyboardOpen, sounds: true) + shown(settingsPanel, settingsOpen, sounds: true)
            + shown(launcher, launcherOpen, sounds: true) + shown(picker, picker?.isOpen == true, sounds: true)
            + shown(fileBrowser, fileBrowserOpen, sounds: true) + shown(notes, notesOpen, sounds: true)
            + shown(clock, clockOpen, sounds: true) + shown(controls, controlsOpen, sounds: true) + shown(music, musicOpen, sounds: true) + shown(home, nothingOpen) + shown(notice, CACurrentMediaTime() < noticeUntil, tier: 3)
            + shown(games, gamesOpen, sounds: true) + shown(gameBar, gameAway && game?.isPresenting == true, sounds: true)
            + shown(setupPanel, setupPanelOpen, sounds: true)
        let layers = shown(dock, chromeVisible) + controlLayers + overlays
            + shown(quickSettings, quickSettingsOpen && chromeVisible, sounds: true)
            + browserLayers + barLayers + shown(resizeHandle, resizeTarget != nil, tier: 0)
            + dropSlots.flatMap { shown($0.panel, dropSlotsShown) }
        if layers.count != wm.uiLayers.count || zip(layers, wm.uiLayers).contains(where: { $0 !== $1 }) { wm.uiLayers = layers }
    }

    /// Tells `panel` whether it is open, and returns its layer for as long as it is to be drawn
    /// (open, or still fading out). `sounds`: it opens and closes with a sound.
    private func shown(_ panel: VRPanel?, _ open: Bool, sounds: Bool = false, tier: Int = 2) -> [QuadLayer] {
        guard let panel else { return [] }
        panel.layer.tier = tier
        if panel.isShown != open {
            panel.isShown = open
            if sounds { Sounds.play(open ? .open : .close) }
        }
        return panel.isVisible ? [panel.layer] : []
    }

    /// Opens or closes the settings panel beside browser `b`.
    private func toggleBrowserSettings(for b: BrowserWindow) {
        guard let dock else { return }
        let number = b.window.windowNumber
        if browserSettings?.window == number {
            browserSettings = nil
            return
        }
        let panel = BrowserSettings(renderer: dock.renderer, browser: b)
        panel.onClose = { [weak self] in self?.browserSettings = nil }
        panel.onNotice = { [weak self] text in self?.notify(text) }
        browserSettings = (panel, number)
    }

    /// Opens Halliday's browser in VR if none is open; nil if it can't be opened.
    func openBrowser() -> BrowserWindow? {
        if browsers.isEmpty { openBrowserWindow() }
        return browser
    }

    /// Closes one browser window.
    private func closeBrowser(_ b: BrowserWindow) {
        b.endXR()
        windowManager?.sendBack(CGWindowID(b.window.windowNumber))
        b.window.orderOut(nil)
        browsers.removeAll { $0 === b }
        lastDockClock = 0
    }

    /// The dock's Browser button and the B key: the first window, or another one.
    private func toggleBrowser() { openBrowserWindow() }

    /// Opens a browser window in VR (several can be open at once).
    private func openBrowserWindow(startURL: URL? = nil) {
        guard let wm = windowManager else { return }
        // Still on its way into VR (the first open also creates the virtual display, which takes a
        // moment): a second click must not open two.
        guard !browserOpening else { return }
        guard browsers.count < Self.maxBrowsers else {
            notify("\(Self.maxBrowsers) browser windows are open: close one first", kind: .warning)
            return
        }
        let args = CommandLine.arguments
        func arg(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        // Debug: --browser-url URL opens a page; --browser-js CODE runs once after it loads (first window).
        let first = browsers.isEmpty
        let b = BrowserWindow(startURL: startURL ?? (first ? arg("--browser-url").flatMap(URL.init(string:)) : nil), runAfterLoad: first ? arg("--browser-js") : nil)
        browsers.append(b)
        currentBrowser = b.window.windowNumber
        // Optics for pages: the headset's per-eye FOV and IPD (sent on every page load).
        let ipd = renderer?.ipd ?? 0.064
        // Entering VR from a page: leave the window interaction, so the mouse looks around and Esc
        // (handled by Halliday) can end the session.
        b.onXRSessionChange = { [weak self, weak b] started in
            // The browser whose page is in VR is the current one.
            if started, let b { self?.currentBrowser = b.window.windowNumber }
            guard let self, started, mouseOwner.isOn else { return }
            mouseOwner.stop(reason: "page entered VR")
            mouseOwnershipChanged(false)
        }
        // "Watch in VR": the page's video moves to the native player, with the page's session.
        b.onWatchInVR = { [weak self, weak b] video in
            guard let self, let b else { return }
            Task { @MainActor in
                let context = await b.requestContext(for: video)
                log("[browser] watch in VR: \(video.src.absoluteString.prefix(120)) (\(video.width)×\(video.height))")
                await self.video?.open(video.src, head: self.currentHead, cookies: context.cookies, headers: context.headers,
                                       nameHint: video.pageTitle, startAt: video.time)
            }
        }
        b.onChange = { [weak self, weak b] in
            guard let self, let b else { return }
            browserBars[b.window.windowNumber]?.refresh()
            if let open = browserSettings, open.window == b.window.windowNumber { open.panel.setNeedsDisplay() }
        }
        b.onFocusAddress = { [weak self, weak b] in
            guard let self, let b else { return }
            currentBrowser = b.window.windowNumber
            // The address bar is typed in Halliday: leave the page and take the keyboard.
            if mouseOwner.isOn {
                mouseOwner.stop(reason: "address bar")
                mouseOwnershipChanged(false)
            } else {
                NSApp.activate()
                window?.makeKeyAndOrderFront(nil)
                window?.makeFirstResponder(view)
            }
            updateBrowserBar()
            browserBar?.beginEditing()
        }
        b.onPageLoad = { [weak b] in
            b?.configureXR(ipd: ipd, fovLeft: Optics.fov(.left), fovRight: Optics.fov(.right), eyeSize: Settings.shared.vrPageEye)
        }
        b.window.orderFront(nil) // on screen so it gets a window number, then moved onto the virtual display
        window?.makeKeyAndOrderFront(nil)
        browserOpening = true
        lastDockClock = 0 // the dock shows it as open right away
        Task { @MainActor in
            if await wm.addOwn(b.window, appName: "Browser", title: "Halliday Browser") == false {
                // The usual reason: no Screen Recording permission (the browser is shown from a
                // capture of its window). Said, and asked for, rather than a bare failure.
                if !CGPreflightScreenCaptureAccess() {
                    notify("The browser needs Screen Recording: allow Halliday on the Mac's screen, then open Halliday again", kind: .warning)
                    Permissions.shared.request(.screenRecording)
                } else {
                    notify("The browser couldn't be brought into VR", kind: .warning)
                }
                b.window.orderOut(nil)
                browsers.removeAll { $0 === b }
            }
            browserOpening = false
            lastDockClock = 0
        }
    }

    /// Returns true if the click went into a VR window (false: empty space, or it only locked the mouse).
    @discardableResult
    func clickedInView(rightButton: Bool, at spot: CGPoint? = nil) -> Bool {
        // A free mouse: the click captures it. In the desktop view the picture is undistorted, so the
        // spot that was clicked is a known direction: the pointer goes there and the click counts,
        // as the user expects. In the headset view the first click only captures.
        if !pointerLocked {
            pointerEngaged = true
            setPointerLock(true)
            log("[mouse] captured for VR (Control twice releases it)")
            guard let spot, renderer?.desktopView == true else { return true }
            InputState.shared.aim(desktopDirection(spot))
        }
        // A game under Wine: the buttons are its right controller's trigger and grip.
        if let game, gameActive {
            if rightButton { game.grip[0] = true } else { game.trigger[0] = true }
            return true
        }
        // In an immersive WebXR page, the mouse button is the VR pointer's select.
        if let browser, browser.xrActive {
            if !rightButton { browser.select(down: true) }
            return true
        }
        // Halliday's own panels take clicks that land on them: the dock, then the window picker.
        if let head = lastHead {
            let direction = head.orientation.act(InputState.shared.pointerDirection)
            if let panel = panels.first(where: { $0.isOnSurface(origin: head.position, direction: direction) }) {
                if let number = browserBars.first(where: { $0.value === panel })?.key { currentBrowser = number }
                if panel !== browserBar, panel !== keyboard { browserBar?.endEditing() }
                if !rightButton {
                    pointerDown = true
                    _ = panel.press(origin: head.position, direction: direction)
                }
                return true
            }
        }
        browserBar?.endEditing()
        guard let hit = InputState.shared.hit() else {
            if !rightButton { pointerDown = true }
            return false
        }
        if browser(forWindow: hit.window.windowID) != nil { currentBrowser = Int(hit.window.windowID) }
        if !rightButton, let blocked = hit.window.blocked,
           blocked.contains(CGPoint(x: hit.screenPoint.x - hit.window.frame.minX, y: hit.screenPoint.y - hit.window.frame.minY)) {
            blockedClick()
            return true
        }
        guard let wm = windowManager, wm.checkInputPermission(), mouseOwner.start() else { return true }
        mouseOwnershipChanged(true)
        mouseOwner.press(hit, rightButton: rightButton)
        windowManager?.inUse = hit.window.windowID
        return true
    }

    /// Halliday's OpenVR runtime for games under Wine (`halliday --install-openvr` points a Wine
    /// prefix at it: main.swift).
    private func startGameBridge(_ renderer: Renderer) {
        game = GameBridge(device: renderer.device, queue: renderer.commandQueue, displayHz: headsetHz)
        GameLibrary.shared.onNotice = { [weak self] text in self?.notify(text, symbol: "gamecontroller") }
        GameLibrary.shared.onChange = { [weak self] in self?.games?.setNeedsDisplay() }
        GameLibrary.shared.refresh()
        game?.onChange = { [weak self] presenting in
            guard let self, let game = self.game else { return }
            let name = GameLibrary.shared.displayName(forExecutable: game.appName)
            if presenting {
                // How to get out, the first three times a game starts (design board 14, moment 1).
                let hints = UserDefaults.standard.integer(forKey: "gameHintsShown")
                if hints < 3 {
                    UserDefaults.standard.set(hints + 1, forKey: "gameHintsShown")
                    self.notify("\(name) is running · PS on a controller, or Esc, brings Halliday up over it", symbol: "gamecontroller", seconds: 5)
                } else {
                    self.notify("\(name) is running in Halliday", symbol: "gamecontroller")
                }
                self.closeOverlays()
            } else {
                self.notify("\(name) stopped")
                if self.gameAway { self.setGameAway(false) }
            }
            if !presenting { self.renderer?.projection = nil }
            // Seated: the walk the game needed ends with it (room-scale keeps where the user went).
            if !presenting, Settings.shared.mode == .seated { self.mouse.position = MouseLook().position }
            if !presenting { self.scheduleGameImageReconfiguration() }
            if presenting { self.scheduleGameKeys() }
        }
    }

    /// `--game-keys SPEC` (debug): presses the emulated controllers' inputs on a schedule once a
    /// game presents, e.g. `space@20-23,space+right@26-27,left-tab@30-30.3,trigger@34-35` (seconds
    /// after the game's first frame; `left-` is the left controller; names: space, tab, left, right,
    /// up, down, trigger, grip; `dashboard` marks Halliday's interface as over the game while held,
    /// `quit` asks the game to quit).
    private func scheduleGameKeys() {
        let args = CommandLine.arguments
        // --game-shots "T1,T2,…" PREFIX: the view saved at those seconds after the game's first
        // frame, as PREFIX-T.png.
        if let i = args.firstIndex(of: "--game-shots"), i + 2 < args.count, !gameShotsScheduled {
            gameShotsScheduled = true
            let prefix = args[i + 2]
            for t in args[i + 1].split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                    guard let self, let renderer = self.renderer else { return }
                    let head = self.lastHead ?? self.mouse.pose(atHostNs: 0)!
                    saveFrame(renderer: renderer, head: head, calibration: self.mouse.calibration, to: "\(prefix)-\(Int(t)).png")
                }
            }
        }
        guard let i = args.firstIndex(of: "--game-keys"), i + 1 < args.count, !gameKeysScheduled else { return }
        gameKeysScheduled = true
        let codes: [String: UInt16] = ["space": 49, "tab": 48, "left": 123, "right": 124, "down": 125, "up": 126]
        for item in args[i + 1].split(separator: ",") {
            let parts = item.split(separator: "@")
            guard parts.count == 2 else { continue }
            let leftHand = parts[0].hasPrefix("left-")
            let names = String(leftHand ? parts[0].dropFirst(5) : parts[0])
            let times = parts[1].split(separator: "-").compactMap { Double($0) }
            guard times.count == 2 else { continue }
            for (at, down) in [(times[0], true), (times[1], false)] {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let game = self?.game else { return }
                    for name in names.split(separator: "+").map(String.init) {
                        switch name {
                        case "trigger": game.trigger[leftHand ? 1 : 0] = down
                        case "grip": game.grip[leftHand ? 1 : 0] = down
                        case "dashboard": game.setDashboard(down) // Halliday's interface over the game
                        case "quit": if down { game.requestQuit() }
                        // Halliday up over the game (Esc), and the bar's Quit game pressed.
                        case "away": self?.setGameAway(down)
                        case "quitask": if down { self?.gameBar?.choose("quit") }
                        // aim:YAW:PITCH:REACH (degrees, meters) places the hand; scroll:N scrolls N points.
                        case _ where name.hasPrefix("aim:"):
                            let v = name.split(separator: ":").dropFirst().compactMap { Float($0) }
                            if down, v.count == 3 {
                                game.setAim(GameBridge.HandAim(yaw: v[0] * .pi / 180, pitch: v[1] * .pi / 180, reach: v[2]), left: leftHand)
                            }
                        case _ where name.hasPrefix("scroll:"):
                            if down, let n = Double(name.dropFirst(7)) { game.scroll(by: n, shift: leftHand) }
                        default:
                            if let code = codes[name] { _ = game.key(code, down: down, shift: leftHand) }
                        }
                    }
                    log("[game] scripted \(down ? "press" : "release"): \(item)")
                }
            }
        }
    }

    private var gameKeysScheduled = false
    private var gameShotsScheduled = false

    /// Halliday comes up over the running game (design board 14, A), or goes back to it. The game
    /// is told and keeps running; the mouse, clicks and keys are Halliday's until it goes back.
    private func setGameAway(_ on: Bool) {
        guard let game, on != gameAway, !on || game.isPresenting else { return }
        gameAway = on
        game.setPaused(on)
        if on {
            let bar = gameBar ?? {
                let p = GameBar(renderer: renderer!)
                p.onBack = { [weak self] in self?.setGameAway(false) }
                p.onRecenter = { [weak self] in self?.recenterUI(); self?.placeGameBar() }
                p.onFloor = { [weak self] step in self?.game?.raise(meters: step) }
                p.floorLift = { [weak self] in self?.game?.floorLift ?? 0 }
                p.onPassthrough = { [weak self] in self?.togglePassthrough() }
                p.batteries = { [weak self] in
                    guard let self else { return nil }
                    let lines = [(SenseControllers.Hand.left, "L"), (.right, "R")].compactMap { hand, letter in
                        self.sense.state(hand).map { "\(letter) \($0.batteryPercent)%\($0.charging ? " ⚡" : "")" }
                    }
                    return lines.isEmpty ? nil : lines.joined(separator: " · ")
                }
                p.onCalibrate = { [weak self] in self?.calibratePointerSoon() }
                p.passthrough = { [weak self] in self?.usb?.headset == nil ? nil : self?.passthrough }
                p.onQuit = { [weak self] in self?.game?.requestQuit() }
                p.onForceQuit = { [weak self] in
                    guard let self, let game = self.game else { return }
                    if !game.forceQuit() { self.notify("Couldn't find the game's process: quit it from GameHub", kind: .warning) }
                }
                gameBar = p
                return p
            }()
            bar.name = GameLibrary.shared.displayName(forExecutable: game.appName)
            bar.startedAt = game.startedAt
            bar.reset()
            placeGameBar()
            dockNeedsPlacement = true
            // The pointer is free again (the mouse no longer turns the head).
            InputState.shared.centerPointer()
        } else {
            closeOverlays()
            settingsOpen = false
            keyboardOpen = false
            launcherOpen = false
        }
        Sounds.play(on ? .open : .close)
    }

    /// Sets where the controllers point without a button on them: a button on a panel is
    /// pressed while pointing at it, not at the middle of the view, so the user is given three
    /// seconds to look ahead and point there.
    private func calibratePointerSoon() {
        notify("Look straight ahead and point the controllers at the middle of your view · setting in 3 seconds", symbol: "scope", seconds: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let head = self.currentHead
            var done = 0
            for hand in SenseControllers.Hand.allCases {
                guard let state = self.sense.state(hand), state.settled else { continue }
                self.calibrateSense(hand, state.orientation, head: head, tilt: true)
                done += 1
            }
            self.notify(done > 0 ? "The controllers point where you look" : "No controller is connected", symbol: "scope")
        }
    }

    /// The headset's brightness as set (`Settings.brightness`), sent when it changes and each
    /// time the headset connects, off the main thread (a USB control transfer).
    private var sentBrightness: Float?
    private func updateBrightness() {
        guard let headset = usb?.headset, headset.linkState == .connected else { sentBrightness = nil; return }
        let wanted = Settings.shared.brightness
        guard wanted != sentBrightness else { return }
        // Full brightness is the headset's own state: nothing is sent until the user asks for less.
        if sentBrightness == nil, wanted >= 1 { sentBrightness = wanted; return }
        sentBrightness = wanted
        DispatchQueue.global(qos: .userInitiated).async { _ = headset.setBrightness(wanted) }
    }

    // --- The companion: Halliday's window on the Mac's own screen (CompanionWindow.swift) ---

    private var companion: CompanionWindow?

    // --- Desktop mode: Halliday on the Mac's own screen while the headset stays connected ---

    /// The headset's window (kept, black, while Halliday shows on the Mac's screen) and the
    /// window on the Mac's screen that desktop mode shows Halliday in.
    private var headsetWindow: NSWindow?
    private var desktopWindow: PreviewWindow?
    private var desktopCloseObserver: NSObjectProtocol?
    /// Halliday shows on the Mac's screen though the headset is there (the companion's switch).
    private(set) var desktopMode = false

    /// Moves Halliday between the headset and a window on the Mac's own screen, without
    /// restarting it: what is open stays open. On the Mac's screen the view is the desktop one
    /// (no lens, the mouse looks around, as without a headset); the headset's display is left
    /// black meanwhile.
    func setDesktopMode(_ on: Bool) {
        guard on != desktopMode, let view, let renderer, let headsetWindow, let screen = headsetWindow.screen ?? NSScreen.screens.first(where: {
            $0.convertRectToBacking($0.frame).size == headsetPanelPixels
        }) else { return }
        desktopMode = on
        setPointerLock(false)
        pointerEngaged = false
        if passthrough { togglePassthrough() }
        if on {
            let window = desktopWindow ?? {
                let w = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                w.isRestorable = false
                w.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
                if let zoom = w.standardWindowButton(.zoomButton) {
                    zoom.target = self
                    zoom.action = #selector(toggleFillScreen)
                }
                // Its red button goes back to the headset: Halliday itself keeps running.
                desktopCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.setDesktopMode(false) }
                }
                if let main = NSScreen.screens.first(where: { $0 != screen }) ?? NSScreen.main {
                    let f = main.visibleFrame
                    w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
                }
                desktopWindow = w
                return w
            }()
            // The view leaves the headset's window (which stays, black) for the Mac's screen,
            // paced by that screen and looked around with the mouse.
            let black = NSView(frame: headsetWindow.contentLayoutRect)
            black.wantsLayer = true
            black.layer?.backgroundColor = NSColor.black.cgColor
            view.headsetDisplay = nil
            headsetWindow.contentView = black
            renderer.desktopView = true
            view.source = mouse
            window.contentView = view
            onHeadset = false
            self.window = window
            // (Test runs stay in the background: `--no-activate`.)
            if CommandLine.arguments.contains("--no-activate") { window.orderFront(nil) } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
            }
            window.makeFirstResponder(view)
            log("[display] desktop mode: Halliday on the Mac's screen, the headset's display left black")
        } else {
            view.headsetDisplay = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            renderer.desktopView = false
            if let usb { view.source = usb }
            headsetWindow.contentView = view
            onHeadset = true
            self.window = headsetWindow
            desktopWindow?.orderOut(nil)
            headsetWindow.setFrame(screen.frame, display: true)
            headsetWindow.makeKeyAndOrderFront(nil)
            headsetWindow.makeFirstResponder(view)
            log("[display] back on the headset")
        }
        // Everything back in front of the new view, once it has drawn a frame from its own head
        // (at once, it was placed for the head of the view just left).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.recenterUI() }
        updateTitle()
        companion?.model.refresh()
    }
    private var shownFramesPerSecond = 0.0
    private var frameFacts = CompanionFrame()
    private var lastFrameFactsAt = 0.0
    private var companionCandidates: [UInt32: WindowManager.Candidate] = [:]
    /// The companion has the Mac's mouse: it is the key window, or the activating click was on it.
    private var companionIsFront: Bool {
        guard let w = companion?.window, w.isVisible else { return false }
        if w.isKeyWindow || NSApp.currentEvent?.window === w { return true }
        // The click that activates Halliday, on the companion.
        let clicking = [.leftMouseDown, .rightMouseDown].contains(NSApp.currentEvent?.type) || NSEvent.pressedMouseButtons != 0
        return clicking && w.frame.contains(NSEvent.mouseLocation)
    }

    // --- A headset connected after launch ---

    private var screensObserver: NSObjectProtocol?

    /// The headset's display, if macOS shows one now.
    private var headsetDisplayNow: NSScreen? {
        NSScreen.screens.first { $0.convertRectToBacking($0.frame).size == headsetPanelPixels }
    }

    /// Looks for the headset (at every change of the Mac's displays, and when the companion's
    /// "Look for the headset" is pressed): one that appeared since Halliday started is taken on at
    /// once, as if it had been there at launch. Returns what was found, for the companion.
    @discardableResult
    func lookForHeadset(asked: Bool = false) -> String {
        if headsetWindow != nil {
            let link = usb?.headset.linkState
            let name = Headsets.current.shortName
            return link == .connected ? "The \(name) is connected." : "The \(name)'s display is here; its USB link: \(link?.description ?? "not open")."
        }
        // Debug: --ignore-headset leaves a connected headset alone for the whole run (screenshots:
        // a virtual display made later, the browser's or a game's, would make it look again).
        if CommandLine.arguments.contains("--ignore-headset") { return "Ignoring the headset (--ignore-headset)." }
        guard let screen = headsetDisplayNow else {
            if asked { log("[display] looked for the headset: no \(Headsets.current.shortName) display") }
            return "No \(Headsets.current.shortName) display found. \(Headsets.current.connectionHelp)"
        }
        guard !CommandLine.arguments.contains("--replay") else { return "Halliday is playing a recording: start it again to use the headset." }
        adoptHeadset(screen)
        return "The \(Headsets.current.shortName) is connected: Halliday is in the headset."
    }

    /// Moves Halliday onto a headset that appeared after launch: its window, its tracking, the
    /// eyes' size and rate, then the view, as `setDesktopMode(false)` does.
    private func adoptHeadset(_ screen: NSScreen) {
        guard headsetWindow == nil, let view, let renderer else { return }
        let w = HeadsetWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        w.setFrame(screen.frame, display: false)
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        headsetWindow = w
        headsetHz = Float(screen.maximumFramesPerSecond)
        LateLatch.displayHz = headsetHz
        renderer.setEyeSize(Headsets.current.renderEyeSize)
        if usb == nil { usb = TrackedSource(name: "headset", headset: Headsets.current.openSession()) }
        let preview = window
        view.headsetDisplay = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        renderer.desktopView = false
        if let usb { view.source = usb }
        setPointerLock(false)
        pointerEngaged = false
        w.contentView = view
        onHeadset = true
        self.window = w
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        // The preview window goes: the companion is Halliday's window on the Mac now.
        preview?.orderOut(nil)
        log("[display] headset display found after launch: \(screen.localizedName), \(Int(headsetHz)) Hz; Halliday moved onto it")
        notify("\(Headsets.current.shortName) connected: Halliday is in the headset")
        if !Setup.shared.done, Setup.shared.showing { openSetupPanel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.recenterUI() }
        updateTitle()
        if !CommandLine.arguments.contains("--no-activate") { showCompanion(activating: false) }
        companion?.model.refresh()
    }

    /// Shows the companion (`activating`: as the key window; without, only put in view).
    func showCompanion(activating: Bool = true) {
        let c = companion ?? {
            let c = CompanionWindow()
            c.onFocus = { [weak self] in
                // Its clicks and typing are the Mac's: the VR pointer lets go of the mouse.
                guard let self, self.onHeadset, !self.mouseOwner.isOn else { return }
                self.pointerEngaged = false
                self.setPointerLock(false)
            }
            let m = c.model
            m.readStatus = { [weak self] in self?.companionStatus() ?? CompanionStatus() }
            m.onRecenter = { [weak self] in self?.recenterUI() }
            m.onPassthrough = { [weak self] in self?.togglePassthrough() }
            m.onInstall = { [weak self] url in self?.installQuestApp(url) }
            m.onRemove = { [weak self] app in
                QuestApps.shared.remove(app)
                log("[quest] removed \(app.name)")
                GameLibrary.shared.refresh()
                self?.companion?.model.refresh()
            }
            m.onPlay = { [weak self] app in self?.playQuestApp(app.package) }
            m.onBackToHeadset = { [weak self] in self?.backToHeadset() }
            m.onDesktopMode = { [weak self] on in self?.setDesktopMode(on) }
            m.onLookForHeadset = { [weak self] in self?.lookForHeadset(asked: true) ?? "" }
            // The app's ordinary quit: a running game is asked to quit, windows go back.
            m.onQuit = { NSApp.terminate(nil) }
            m.readFrame = { [weak self] in self?.frameFacts ?? CompanionFrame() }
            m.readGames = {
                let library = GameLibrary.shared
                let games = library.games.filter { $0.quest == nil }.map { g -> CompanionGame in
                    var status = g.status.label
                    if case .stopped(let why) = g.status { status += ": \(why)" }
                    let setUp: Bool? = switch g.status {
                    case .ready, .stopped: true
                    case .notSetUp, .changed, .update: false
                    case .firstLaunch: nil
                    }
                    return CompanionGame(id: g.appID, name: g.name, status: status, setUp: setUp)
                }
                return (games, library.hasGameHub)
            }
            m.onGame = { [weak self] id, setUp in
                let library = GameLibrary.shared
                guard let game = library.games.first(where: { $0.appID == id }) else { return }
                let done = setUp ? library.setUp(game) : library.undo(game)
                self?.companion?.model.notice = done ? (setUp ? "\(game.name) is set up for Halliday" : "\(game.name) is back as it was")
                    : "Couldn't change \(game.name): start it once from GameHub first"
                library.refresh()
            }
            m.onOpenGameHub = {
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.gamemac.www") ?? URL(fileURLWithPath: "/Applications/GameHub.app")
                NSWorkspace.shared.open(url)
            }
            m.readWindows = { [weak self] in
                guard let self, let wm = self.windowManager, let found = await wm.candidates() else { return [] }
                self.companionCandidates = Dictionary(found.map { (UInt32($0.window.windowID), $0) }, uniquingKeysWith: { a, _ in a })
                return found.map { c in
                    let hint: String? = switch c.state {
                    case .minimized: "minimized"
                    case .fullScreen: "full screen"
                    case .otherSpace: "in another Space: it can't be brought in from there"
                    case .inVR, .ready: nil
                    }
                    return CompanionMacWindow(id: UInt32(c.window.windowID), app: c.appName, title: c.title, inVR: c.state == .inVR, hint: hint)
                }
            }
            m.onWindow = { [weak self] id, bring in
                guard let self, let wm = self.windowManager else { return }
                if !bring {
                    wm.sendBack(CGWindowID(id))
                } else if let c = self.companionCandidates[id], await wm.bring(c) == false {
                    self.companion?.model.notice = "Couldn't bring \(c.appName)'s window into VR"
                }
            }
            m.onPrediction = { [weak self] ms in
                self?.view?.lookaheadTrimNs = Int64(ms) * 1_000_000
                self?.companion?.model.refresh()
            }
            companion = c
            return c
        }()
        c.show(activating: activating)
    }

    /// The mouse and the keyboard back to Halliday in the headset (the companion's button).
    private func backToHeadset() {
        guard onHeadset, !mouseOwner.isOn else { return }
        pointerEngaged = true
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(view)
        setPointerLock(true, force: true)
    }

    private func companionStatus() -> CompanionStatus {
        var s = CompanionStatus()
        s.onHeadset = onHeadset
        s.desktopMode = desktopMode
        s.canSwitchOutput = headsetWindow != nil
        if let headset = usb?.headset {
            switch headset.linkState {
            case .connected: s.headset = onHeadset ? "Connected" : "Connected (no display)"
            case .fullSpeedLink: s.headset = "On a USB 2 link: no tracking"
            case .searching: s.headset = "Looking for it"
            default: s.headset = headset.linkState.description
            }
        }
        s.displayHz = onHeadset ? Int(headsetHz.rounded()) : 0
        s.framesPerSecond = shownFramesPerSecond
        for (hand, name) in [(SenseControllers.Hand.left, "Left"), (.right, "Right")] {
            if let state = sense.state(hand) { s.controllers.append("\(name) · \(state.batteryPercent)%\(state.charging ? ", charging" : "")") }
        }
        if let game, game.isPresenting {
            s.playing = GameLibrary.shared.displayName(forExecutable: game.appName)
        } else if let video, video.isOpen {
            s.playing = video.url?.deletingPathExtension().lastPathComponent ?? "A video"
        } else if browser?.xrActive == true {
            s.playing = "A VR page"
        }
        s.passthrough = usb?.headset == nil ? nil : passthrough
        s.predictionMs = Int((view?.lookaheadTrimNs ?? 0) / 1_000_000)
        return s
    }

    private func placeGameBar() {
        guard let gameBar else { return }
        gameBar.place(head: currentHead, distance: GameBar.distance, below: GameBar.below)
    }

    // --- Games (design board 15) ---

    private func openGames() {
        guard let dock else { return }
        let panel = games ?? {
            let p = GamesPanel(renderer: dock.renderer)
            p.onClose = { [weak self] in self?.gamesOpen = false }
            p.onNotice = { [weak self] text, problem in self?.notify(text, kind: problem ? .warning : .info) }
            p.onPlay = { [weak self] g in self?.play(g) }
            p.onOpenGameHub = { [weak self] in self?.openGameHub() }
            p.onInstall = { [weak self] in self?.toggleFileBrowser(mode: .apps, keepOpen: true) }
            p.onRemove = { [weak self] g in self?.removeQuestApp(g) }
            games = p
            return p
        }()
        closeOverlays()
        panel.prepare()
        panel.place(head: currentHead, distance: overlayDistance(GamesPanel.distance), below: GamesPanel.below)
        gamesOpen = true
    }

    /// Starts a game through GameHub's own launch link (what its desktop shortcuts open).
    private func play(_ g: GameEntry) {
        if let package = g.quest {
            playQuestApp(package)
            return
        }
        applyGameImageReconfiguration()
        guard let url = GameLibrary.playURL(g) else { return }
        log("[games] starting \(g.name) through GameHub")
        notify("Starting \(g.name)", symbol: "gamecontroller", kind: .progress, seconds: 20)
        NSWorkspace.shared.open(url)
    }

    // --- Quest apps (ROADMAP W15.3; `QuestApps.swift`) ---

    /// Installs an APK the user opened (Files) into Halliday's own folder, off the main thread.
    private func installQuestApp(_ apk: URL) {
        notify("Installing \(apk.deletingPathExtension().lastPathComponent)", symbol: "square.and.arrow.down", kind: .progress, seconds: 60)
        Task.detached(priority: .userInitiated) {
            let result = Result { try QuestApps.shared.install(apk) }
            await MainActor.run {
                switch result {
                case .success(let app):
                    log("[quest] installed \(app.name) \(app.version) (\(app.package), \(app.engine))")
                    GameLibrary.shared.refresh()
                    self.notify(app.canStart ? "\(app.name) is installed: it is in Games" : "\(app.name) is installed, but Halliday can't start this kind of app yet",
                                symbol: "gamecontroller")
                case .failure(let error):
                    log("[quest] install failed: \(error)")
                    self.notify("\(error)", symbol: "exclamationmark.triangle")
                }
            }
        }
    }

    /// The web halves of Quest apps that are open, by package (`QuestAppWeb.swift`).
    private var questWebs: [String: QuestAppWeb] = [:]

    /// Opening a Quest app: one whose interface is a web application bundled with it gets that
    /// interface in a browser window (sign-in, catalogue), which starts the player itself; any
    /// other is its player, started at once.
    private func playQuestApp(_ package: String) {
        guard let app = QuestApps.installed().first(where: { $0.package == package }) else { return }
        guard QuestAppWeb.has(app), !CommandLine.arguments.contains("--quest-player-only") else {
            startQuestPlayer(app)
            return
        }
        guard let web = questWebs[package] ?? QuestAppWeb(app: app), let window = openBrowser() else { return }
        questWebs[package] = web
        gamesOpen = false
        web.onLaunch = { [weak self, weak web] session, extras in
            self?.startQuestPlayer(app, session: session, extras: extras) { status in web?.playerEnded(status: status) }
        }
        // A tab of its own, served from the installed package; the one it had is used again.
        if let view = web.webView, let tab = window.tabs.first(where: { $0.webView === view }) {
            window.select(tab)
        } else {
            let tab = window.newTab(private: false, select: true, configuration: web.configuration())
            web.webView = tab.webView
            window.load(web.startURL, in: tab)
        }
        log("[quest] \(app.name): its interface in a browser tab (\(web.startURL.absoluteString))")
    }

    private func startQuestPlayer(_ app: QuestApp, session: URL? = nil, extras: URL? = nil, ended: (@MainActor (Int32) -> Void)? = nil) {
        do {
            try QuestApps.shared.launch(app, session: session, extras: extras) { status in
                Task { @MainActor in
                    ended?(status)
                    let logFile = app.folder.appendingPathComponent("latest.log")
                    log("[quest] \(app.name) ended (status \(status)); its log: \(logFile.path)")
                    // An app that gave up says why in what it printed: shown, and kept on its card.
                    guard status != 0, status != 15 else { return }
                    let why = QuestApps.lastFailure(in: logFile) ?? "It stopped (status \(status)); its log says more."
                    GameLibrary.shared.recordLaunch(exe: app.name, minutes: nil, problem: why)
                    GameLibrary.shared.refresh()
                    self.notify("\(app.name) stopped: \(why)", symbol: "exclamationmark.triangle")
                }
            }
            log("[quest] starting \(app.name) (\(app.package))")
            notify("Starting \(app.name)", symbol: "gamecontroller", kind: .progress, seconds: 20)
        } catch {
            log("[quest] \(app.name) didn't start: \(error)")
            notify("\(error)", symbol: "exclamationmark.triangle")
        }
    }

    private func removeQuestApp(_ g: GameEntry) {
        guard let app = QuestApps.installed().first(where: { $0.package == g.quest }) else { return }
        QuestApps.shared.remove(app)
        log("[quest] removed \(app.name)")
        GameLibrary.shared.refresh()
        notify("\(app.name) was removed", symbol: "trash")
    }

    /// GameHub's window, brought into VR like any Mac app.
    private func openGameHub() {
        gamesOpen = false
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.gamemac.www")
            ?? URL(fileURLWithPath: "/Applications/GameHub.app")
        launch(AppLauncher.App(id: "mac:gamehub", name: "GameHub", url: url, symbol: nil))
    }

    /// A key while a game presents: the emulated controllers' (Space, Tab, arrows; Shift: left hand).
    func gameKey(_ event: NSEvent, down: Bool) -> Bool {
        game?.key(event.keyCode, down: down, shift: event.modifierFlags.contains(.shift)) == true
    }

    private var lastTitleUpdate = CACurrentMediaTime()

    private func frameTick(head: HeadPose) {
        guard let view, let renderer else { return }
        lastHead = head
        updateSense(head: head)
        updateCameras()
        updatePassthrough()
        // The eyes are as far apart as the headset's dial says (it was a fixed 64 mm).
        if view.source.name == "headset", let mm = usb?.headset.status?.ipdMm, (50...80).contains(mm), abs(renderer.ipd * 1000 - Float(mm)) > 0.5 {
            renderer.ipd = Float(mm) / 1000
            log("[display] eye distance from the headset's dial: \(mm) mm")
        }
        // Publish this frame for the input thread (pointer hit tests, watchdog heartbeat).
        let input = InputState.shared
        input.publish(headPosition: head.position, headOrientation: head.orientation, windows: windowManager?.snapshots ?? [],
                      blockers: panels.map(\.snapshot))
        renderer.cursorDirection = head.orientation.act(input.pointerDirection)
        // WebXR pages follow the head: every frame during an immersive session, ~10 Hz otherwise so
        // reference spaces created on entering VR already start from the real pose.
        windowManager?.capturesEveryFrame = browser?.xrActive == true
        if let browser, browser.xrActive || CACurrentMediaTime() - lastIdlePosePush > 0.1 {
            let id = nextPoseID
            nextPoseID = nextPoseID &+ 1 == 0 ? 1 : nextPoseID &+ 1
            // An immersive page gets the head as predicted for when its frame is seen (its
            // frames come back through the web view and a capture, several display frames on).
            let given = browser.xrActive && Self.predictsForApps ? headAhead(head, by: min(xrLead, 0.08)) : head
            sentPoses[id] = given
            sentTargets[id] = HeadsetView.frameTarget
            if sentPoses.count > 512 {
                sentPoses = sentPoses.filter { id &- $0.key < 256 }
                sentTargets = sentTargets.filter { id &- $0.key < 256 }
            }
            if browser.xrActive {
                browser.pushPose(given, id: id, pointer: input.pointerRotation)
            } else {
                // Idle: every browser window keeps a recent pose, so a page entering VR starts right.
                for b in browsers { b.pushPose(head, id: id, pointer: input.pointerRotation) }
                lastIdlePosePush = CACurrentMediaTime()
            }
        }
        // A game: its frames, its overlays over them (Halliday's own panels step aside), its
        // skybox while it loads, its fades.
        // A Quest app (an OpenXR application) draws with the pose as given: it gets the head as
        // predicted for when its frame is seen. (Windows games' runtime predicts by itself.)
        let gameLead = QuestApps.shared.runningPackage != nil && Self.predictsForApps ? min(game?.lead ?? 0, 0.08) : 0
        if let shown = game?.tick(head: head, ahead: headAhead(head, by: gameLead)) {
            renderer.projection = shown.projection
            // Its overlays, and Halliday's notices (the hint at its start, "set up" messages).
            renderer.gameLayers = shown.layers + (notice.map { $0.isVisible ? [$0.layer] : [] } ?? [])
            renderer.gameSkybox = shown.skybox
            renderer.gameFade = shown.fade
            renderer.gameBackgroundFade = shown.backgroundFade
        } else if renderer.gameLayers != nil {
            renderer.gameLayers = nil
            renderer.gameSkybox = nil
            renderer.gameFade = .zero
            renderer.gameBackgroundFade = .zero
        }
        if browser?.xrActive != true, game?.isPresenting != true, renderer.projection != nil { renderer.projection = nil }
        // Halliday over the game: its world dims and blurs in (420 ms) and out.
        let awayTarget: Float = gameAway && game?.isPresenting == true ? 1 : 0
        let awayNow = CACurrentMediaTime()
        if renderer.gameAway != awayTarget {
            let step = Motion.reduced ? 1 : Float(min(0.1, awayNow - lastAwayTick) / Motion.travel)
            renderer.gameAway = awayTarget > renderer.gameAway ? min(awayTarget, renderer.gameAway + step) : max(awayTarget, renderer.gameAway - step)
        }
        lastAwayTick = awayNow
        gameBar?.tick()
        // Games added to GameHub get set up while Halliday runs, if the user asked for that.
        if CACurrentMediaTime() - lastGamesRefresh > (gamesOpen ? 5 : 20) {
            lastGamesRefresh = CACurrentMediaTime()
            if gamesOpen || (GameLibrary.shared.consented && GameLibrary.shared.setsUpNewGames) { GameLibrary.shared.refresh() }
        }
        // Simulator + immersive page or game: the mouse turns the head and the pointer stays centered.
        let turnsHead = (browser?.xrActive == true || gameActive) && view.source is MouseLook
        if turnsHead != view.mouseTurnsHead {
            view.mouseTurnsHead = turnsHead
            if turnsHead { input.centerPointer() }
        }

        let pointerWorld = head.orientation.act(input.pointerDirection)
        if simd_distance(input.pointerDirection, lastPointerDirection) > 0.002 {
            lastPointerDirection = input.pointerDirection
            // The mouse moved (a controller's own activity is counted in `updateSense`).
            // Not in the moment after its own click on the bar's hide button.
            if !senseHasPointer, CACurrentMediaTime() - chromeDismissedAt > 0.7 {
                lastPointerActivity = CACurrentMediaTime()
                chromeDismissed = false
            }
        }
        ClockModel.shared.tick()
        updateRecenterHold()
        windowManager?.gazeYaw = Self.angles(of: head.orientation.act(SIMD3<Float>(0, 0, -1))).yaw
        updateDock(head: head)
        anchorIfNeeded(head: head)
        continueDrag(head: head, pointer: pointerWorld)
        continueResize()
        updateResizeHandle(head: head)
        updateBrowserBar()
        // Only the frontmost panel under the pointer hovers; a held control keeps the pointer.
        var onDock = false
        let shown = panels
        let holder = shown.first { $0.pressed != nil }
        for panel in shown {
            if (holder == nil && !onDock) || panel === holder {
                if panel.hover(origin: head.position, direction: pointerWorld) || panel === holder { onDock = true }
            } else {
                panel.clearHover()
            }
        }
        recoverLostRelease()
        let hitLayer = onDock ? nil : input.hit().flatMap { windowManager?.layer(for: $0.window.windowID) }
        renderer.highlightedLayer = hitLayer.flatMap { l in renderer.layers.firstIndex { $0 === l } }
        // The saber: from just below the chin (until controllers exist) to where the pointer lands.
        let heading = simd_quatf(angle: atan2(-head.orientation.act(SIMD3<Float>(0, 0, -1)).x,
                                             -head.orientation.act(SIMD3<Float>(0, 0, -1)).z), axis: [0, 1, 0])
        // In an immersive page the panels are not shown: the saber points into the page's scene, with
        // its ring at a comfortable distance (the page draws its own ray hits).
        let inPage = (browser?.xrActive == true || gameActive) && renderer.projection != nil
        let landing = inPage ? 2.5 : renderer.nearestHit(origin: head.position, direction: pointerWorld)
        let overTarget = shown.contains { $0.hovered != nil } || hitLayer != nil || resizing != nil
        // With a Sense controller: from about where that hand is (a guess beside the body until
        // the controllers are tracked), and lit along its whole length, as a hand's beam is.
        let side: Float = senseHand == .left ? -1 : 1
        // With `--hands`, from where the cameras saw that controller.
        let seen = senseHasPointer ? handPlace(senseHand) : nil
        renderer.saber = Saber(start: seen ?? head.position + heading.act(senseHasPointer ? SIMD3(side * 0.20, -0.30, -0.42) : SIMD3(0.10, -0.30, -0.12)),
                               end: head.position + pointerWorld * (landing ?? (senseHasPointer ? 4 : 1.6)),
                               landsOnSurface: landing != nil,
                               mode: pointerDown || drag != nil ? .pressed : (overTarget ? .overTarget : .idle),
                               fromHand: senseHasPointer)
        // Watching a video with its controls put away: no beam and no hilt either. They come back
        // with the controls, on a pull of the trigger or the grip (never the controller moving)
        // or the mouse.
        if video?.isOpen == true, !chromeShown, !gameActive { renderer.saber = nil }
        // A hand pointing at one of the game's overlays that takes the mouse: the saber from it.
        if gameActive, let p = game?.pointing {
            renderer.saber = Saber(start: p.from, end: p.to, landsOnSurface: true, mode: p.pressed ? .pressed : .overTarget, fromHand: true)
        }
        updateAppCursor(on: hitLayer, at: head.position + pointerWorld * (landing ?? 1.6))
        // Follow the real windows and their menus/popovers (~15 Hz; only asks the window server).
        if CACurrentMediaTime() - lastFrameRefresh > 1.0 / 15 {
            lastFrameRefresh = CACurrentMediaTime()
            windowManager?.refresh()
        }
        VRPanel.displayAll() // panels that changed this frame are redrawn once, here
        keepCursorOffVirtualDisplay()
        if let line = renderer.stats.report() {
            var xr = ""
            if browser?.xrActive == true {
                let lag = xrFrames > 0 ? Double(xrLagTotal) / Double(xrFrames) : 0
                xr = String(format: " webxr: %d frames, %d without stamp, pose lag %.1f frames (seen %.1f ms after the frame its pose was sent in)", xrFrames, xrMissedStamps, lag, xrLead * 1000)
                xrFrames = 0; xrMissedStamps = 0; xrLagTotal = 0
            }
            // What the frame was made of, for when its cost is asked about: the layers drawn,
            // the captures copied for the GPU since the last line, passthrough, a video.
            if let r = line.range(of: "fps="), let fps = Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." }) { shownFramesPerSecond = fps }
            var made = " layers=\(renderer.layers.count)"
            let captured: (count: Int, megapixels: Double) = windowManager?.takeCaptureStats() ?? (0, 0)
            if captured.count > 0 { made += String(format: " captures=%d (%.0f MP)", captured.count, captured.megapixels) }
            if passthrough { made += " passthrough" }
            if video?.isOpen == true { made += " video" }
            if game?.isPresenting == true { made += " game" }
            // Who had the GPU since the last line (GPUShare.swift): `gpu=` above also counts the
            // time Halliday's frames waited for other programs' work.
            let share = GPUShare.shared.take()
            if !share.isEmpty { made += " gpu-share=\(share)" }
            // The same for the companion's Performance section.
            var facts = CompanionFrame()
            facts.framesPerSecond = shownFramesPerSecond
            if let r = line.range(of: "gpu=") {
                let numbers = line[r.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "/" }.split(separator: "/").compactMap { Double($0) }
                if numbers.count == 2 { (facts.gpuMs, facts.gpuWorstMs) = (numbers[0], numbers[1]) }
            }
            facts.layers = renderer.layers.count
            (facts.captures, facts.captureMegapixels) = (captured.count, captured.megapixels)
            let now = CACurrentMediaTime()
            facts.seconds = lastFrameFactsAt > 0 ? now - lastFrameFactsAt : 5
            lastFrameFactsAt = now
            if passthrough { facts.parts.append("passthrough") }
            if video?.isOpen == true { facts.parts.append("a video") }
            if game?.isPresenting == true { facts.parts.append("a game") }
            if browser?.xrActive == true { facts.parts.append("a VR page") }
            frameFacts = facts
            log("[stat] \(line) source=\(view.source.name) (\(view.source.state))\(xr)\(made)")
        }
        if CACurrentMediaTime() - lastTitleUpdate > 0.5 {
            lastTitleUpdate = CACurrentMediaTime()
            updateTitle()
        }
    }

    /// While a window is in use, the cursor its app asks for (a text beam over text, a hand over a
    /// link) is shown at the pointer in place of the ring, as on the Mac. The arrow stays the ring.
    private func updateAppCursor(on window: QuadLayer?, at point: SIMD3<Float>) {
        guard let renderer, let wm = windowManager else { return }
        let now = CACurrentMediaTime()
        if mouseOwner.isOn, now - lastCursorCheck > 1.0 / 15 {
            lastCursorCheck = now
            if let cursor = NSCursor.currentSystem {
                let arrow = NSCursor.arrow
                cursorIsArrow = cursor.image.size == arrow.image.size && cursor.hotSpot == arrow.hotSpot
                let key = "\(cursor.image.size)|\(cursor.hotSpot)"
                if !cursorIsArrow, key != cursorKey, let texture = Self.texture(of: cursor.image, renderer: renderer) {
                    cursorKey = key
                    cursorHot = cursor.hotSpot
                    cursorSize = cursor.image.size
                    if let layer = cursorLayer { layer.texture = texture } else {
                        let layer = QuadLayer(texture: texture, position: .zero, width: 0.02)
                        layer.tier = 1
                        layer.isPointerMark = true
                        cursorLayer = layer
                    }
                }
            } else {
                cursorIsArrow = true
            }
        }
        let show = mouseOwner.isOn && !cursorIsArrow && window != nil && cursorLayer != nil
        if show, let window, let layer = cursorLayer {
            // On the window's plane, a hair in front, its hot spot at the pointer.
            let m = window.width / Float(max(window.textureWidthOverride ?? Float(window.texture.width) * window.uvRect.z, 1)) * 2 // meters per point
            layer.width = Float(cursorSize.width) * m
            layer.aspect = Float(cursorSize.height / max(cursorSize.width, 1))
            layer.orientation = window.orientation
            let offset = SIMD3(Float(cursorSize.width / 2 - cursorHot.x) * m, -Float(cursorSize.height / 2 - cursorHot.y) * m, 0.003)
            layer.position = point + window.orientation.act(offset)
            renderer.saber?.hidesRing = true
        }
        let layers = show ? [cursorLayer].compactMap { $0 } : []
        if layers.count != wm.overlayLayers.count { wm.overlayLayers = layers }
    }

    /// An image as a texture (2 pixels per point, premultiplied).
    private static func texture(of image: NSImage, renderer: Renderer) -> MTLTexture? {
        let w = Int(ceil(image.size.width * 2)), h = Int(ceil(image.size.height * 2))
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            image.draw(in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return drawn ? renderer.makeLayerTexture(width: w, height: h, rgba: bytes) : nil
    }

    /// Lazy follow: once `panel` is more than 12 cm from where it belongs (`target`, its offset from
    /// the user), it glides there, eased, and stops when it has arrived. Small head movements leave it
    /// where it is. Its orientation is kept (recentering turns it).
    /// What the dock, Home and the keyboard follow: on the headset, a point near the neck, so
    /// turning the head moves nothing (the tracked position is between the eyes, which swing
    /// several centimetres with each turn: the panels glided after every turn); only leaning or walking does. The mouse's head turns in place.
    private func followPoint(_ head: HeadPose) -> SIMD3<Float> {
        guard view?.source.name == "headset" else { return head.position }
        return head.position - head.orientation.act(SIMD3<Float>(0, 0.08, -0.08))
    }

    private func follow(_ panel: VRPanel, to target: SIMD3<Float>, dt: Float) {
        let id = ObjectIdentifier(panel)
        let off = simd_distance(panel.layer.position, target)
        if off > 0.12 { following.insert(id) }
        guard following.contains(id) else { return }
        if off < 0.005 || Motion.reduced {
            panel.layer.position = target
            following.remove(id)
            return
        }
        panel.layer.position += (target - panel.layer.position) * (1 - exp(-dt / 0.18))
    }

    /// Places the dock when needed and keeps what it shows current (it redraws only on changes).
    private func updateDock(head: HeadPose) {
        guard let dock, let view else { return }
        let now0 = CACurrentMediaTime()
        let dt = Float(min(0.1, now0 - lastFollowTime))
        lastFollowTime = now0
        if !dockNeedsPlacement, let offset = dockOffset { follow(dock, to: followPoint(head) + offset, dt: dt) }
        if keyboardOpen, let keyboard, let offset = keyboardOffset { follow(keyboard, to: followPoint(head) + offset, dt: dt) }
        if let home, home.isShown, let offset = homeOffset { follow(home, to: followPoint(head) + offset, dt: dt) }
        if dockNeedsPlacement {
            dock.glide(around: head.position) { dock.place(head: head, distance: Dock.distance, below: Dock.below) }
            dockOffset = dock.layer.target.position - followPoint(head)
            dockNeedsPlacement = false
            // The dock's band of the view: windows and their bars keep out of it.
            let yaw = Self.angles(of: head.orientation.act(SIMD3<Float>(0, 0, -1))).yaw
            windowManager?.reserved = [ReservedZone(yaw: yaw, halfYaw: Dock.zoneHalfYaw, top: Dock.zoneTop)]
        }
        let now = CACurrentMediaTime()
        guard now - lastDockClock > 1 || dock.state.clock.isEmpty else { return }
        lastDockClock = now
        // A running timer shows under the clock.
        let timer = ClockModel.shared
        dock.state = Dock.State(clock: Self.clockFormatter.string(from: Date()),
                                timer: timer.timerRunning ? ClockModel.format(timer.timerLeft) : "",
                                windowsInVR: windowManager?.windows.contains { $0.own == nil } == true || picker?.isOpen == true,
                                browserOpen: !browsers.isEmpty, videoOpen: video?.isOpen == true || photos?.isOpen == true || fileBrowserOpen,
                                settingsOpen: quickSettingsOpen)
        dock.state.appsOpen = launcherOpen
        dock.state.keyboardOpen = keyboardOpen
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// The virtual displays are invisible: outside an interaction, a cursor that wanders onto one
    /// (it sits next to the real displays) is brought back to the main display.
    private func keepCursorOffVirtualDisplay() {
        guard !mouseOwner.isOn, !pointerLocked, let location = CGEvent(source: nil)?.location,
              [windowManager?.virtualDisplayBounds, game?.framesDisplayBounds].contains(where: { $0?.contains(location) == true })
        else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        view?.skipNextDelta = true
        CGWarpMouseCursorPosition(CGPoint(x: main.midX, y: main.midY))
    }

    // --- MouseOwnerDelegate ---

    func look(dx: Double, dy: Double) {
        if !gameAim(dx: Float(dx), dy: Float(dy)) { mouse.look(dx: Float(dx), dy: Float(dy)) }
    }

    /// While a game has the input and ⌥ is held, the mouse moves a hand instead of the head (⌥⇧:
    /// the left one). True if it did.
    func gameAim(dx: Float, dy: Float) -> Bool {
        let flags = NSEvent.modifierFlags
        guard gameActive, flags.contains(.option), let game else { return false }
        game.aim(dx: dx, dy: dy, left: flags.contains(.shift))
        return true
    }

    func mouseOwnershipChanged(_ owned: Bool) {
        // While Halliday owns the mouse, the preview window lets clicks through to the windows
        // behind it (the redirected events land on the real windows' positions).
        window?.ignoresMouseEvents = owned
        view?.pointerFromTap = owned
        // The tap positions the real cursor itself while a window is in use.
        if owned { setPointerLock(false) }
        if !owned {
            // Back to Halliday: take the keyboard back from the window's app too.
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(view)
            pointerEngaged = true
            setPointerLock(true)
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let view, let window, window.styleMask.contains(.titled) else { return }
        let lens = renderer?.desktopView == true ? "desktop view" : (renderer?.distortionEnabled == true ? "lens on" : "lens off")
        let mouseState = mouseOwner.isOn ? "using a window (Control twice to return)"
            : !pointerLocked ? "mouse free · click inside to control VR"
            : (windowManager?.windows.isEmpty != false ? "press M to pick windows · Control twice frees the mouse"
                                                       : "click a window to use it · Control twice frees the mouse")
        window.title = "Halliday — \(view.source.name): \(view.source.state) — \(lens) — \(mouseState)"
    }
}

/// The window on the headset's display. A borderless window refuses the keyboard unless it says
/// otherwise: without it, no key or click reached Halliday.
final class HeadsetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The preview window. It can cover the whole screen, menu bar included, without being a macOS
/// full-screen window (see `AppDelegate.toggleFillScreen`).
final class PreviewWindow: NSWindow {
    var fillsScreen = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        fillsScreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

func log(_ s: String) {
    print(s)
    fflush(stdout)
}

func fatal(_ s: String) -> Never {
    log(s)
    exit(1)
}
