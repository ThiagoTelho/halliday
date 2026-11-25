// The view that shows the compositor's output: fullscreen on the headset's display, or a preview
// window on the Mac's monitor. Frames are paced by a display link on the view's own screen, so a
// 60 Hz monitor never drives a 120 Hz headset (GAV's lesson).

import AppKit
import Metal
import QuartzCore
import simd

@MainActor
final class HeadsetView: NSView {
    let renderer: Renderer
    var source: PoseSource
    /// Called once per frame with the head pose about to be rendered (pointer, status, stats).
    var onFrame: ((HeadPose) -> Void)?

    /// Extra lookahead on top of the display link's target time: half of a 120 Hz scanout.
    var scanoutLookaheadNs: Int64 = 4_200_000
    private var link: CADisplayLink?

    init(frame: NSRect, renderer: Renderer, source: PoseSource) {
        self.renderer = renderer
        self.source = source
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = renderer.device
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        l.maximumDrawableCount = Self.drawableCount
        return l
    }

    /// `--drawables N` (2 or 3, 3 by default): how many frames may wait to be shown. Every one
    /// that waits is a refresh more between a frame's pose and the eyes; but with two the
    /// headset ran at 60 frames a second, so it is for experiments only.
    private static let drawableCount: Int = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--drawables"), i + 1 < a.count, let n = Int(a[i + 1]) else { return 3 }
        return min(3, max(2, n))
    }()

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        timer?.cancel()
        if let cvLink { CVDisplayLinkStop(cvLink); self.cvLink = nil; pacer?.stop(); pacer = nil }
        guard window != nil else { return }
        if let hz = Self.pacedRate {
            // `--test-headset HZ`: macOS holds a display link at 60 Hz on a virtual display, so a
            // timer paces the frames at the headset's rate (the display shows what it can).
            let period = 1 / hz
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            t.schedule(deadline: .now(), repeating: period, leeway: .nanoseconds(0))
            t.setEventHandler { [weak self] in self?.frame(target: CACurrentMediaTime() + period) }
            t.resume()
            timer = t
            // The virtual display refreshes at 60 Hz whatever its mode: presenting without waiting
            // for it keeps the timer's pace (and the measurements) free of that wait.
            metalLayer.displaySyncEnabled = false
            log("[display] frames paced at \(Int(hz)) Hz by a timer")
        } else if let id = headsetDisplay {
            startHeadsetLink(id)
        } else {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            // Ask for the screen's full rate: left to choose, macOS drops a ProMotion screen to 60 Hz
            // while a VR page is presenting (WebKit asks for 60 on its side).
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// When the frame being drawn reaches the eyes (host seconds, `CACurrentMediaTime`'s clock).
    static var frameTarget: Double = 0
    /// `--test-headset HZ`'s rate: frames paced by a timer instead of the display link.
    static let pacedRate: Double? = {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--test-headset"), i + 1 < a.count, let hz = Double(a[i + 1]), hz > 0 else { return nil }
        return hz
    }()
    private var timer: DispatchSourceTimer?

    /// The headset's display, when this view is on it: frames are paced by a CVDisplayLink made for
    /// that display. The view's own display link ticked at 60 Hz on the 120 Hz PS VR2; GAV found the same ("may tick from a 60 Hz monitor").
    var headsetDisplay: CGDirectDisplayID?
    private var cvLink: CVDisplayLink?
    /// At most one frame waits for the main thread; it takes the newest output time and aim.
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var queued = false
        private var target = 0.0
        private var aim: Double?
        /// True when no frame was waiting (the caller dispatches one).
        func offer(_ t: Double, aim a: Double?) -> Bool {
            lock.lock(); defer { lock.unlock() }
            target = t
            aim = a
            if queued { return false }
            queued = true
            return true
        }
        func take() -> (target: Double, aim: Double?) {
            lock.lock(); defer { lock.unlock() }
            queued = false
            return (target, aim)
        }
    }

    /// Aims each frame at one refresh of the headset and starts it as late as still gets there.
    ///
    /// Found on the headset: macOS says when each drawable was shown,
    /// and frames started at the display link's call reached the eyes 20 to 24 ms later, not the
    /// 12 the pose was predicted for; panels trailed the head, and no prediction follows a
    /// vibration of the headset across that long. Two things were in it: slack (started 6 ms
    /// later, frames were shown 13 to 14 ms after their start), and a frame queued for good after
    /// any late one, since frames are made exactly as fast as they are shown.
    /// So, once a frame has been shown: the refreshes are that time plus whole periods, and a
    /// thread of its own starts a frame `lead` before each one (the display link's calls come at
    /// a phase of their own; pacing from them dropped every other frame). A frame shown later
    /// than its aim five times running leaves the next one out, which empties the queue.
    private final class Pacer: @unchecked Sendable {
        private let lock = NSLock()
        let period: Double
        private var vsync = 0.0
        private var lastAim = 0.0
        /// How long before its refresh a frame starts. A frame needs its drawing time (5 to 7 ms,
        /// 9 at worst) and then 7.5 ms for the display to show it. A lead that followed the
        /// measured drawing time kept growing on every slow frame and never settled, so it is
        /// fixed, with room for the slow ones.
        private let lead = 0.0172
        private var lateRun = 0
        private var skip = 0
        private var lastSkip = 0.0
        private var waitingOnMain = false
        private var stopped = false
        private var count = 0, late = 0, early = 0, notShown = 0, skipped = 0, dropped = 0, sinceStart = 0.0, drawing = 0.0, waiting = 0.0

        init(period: Double) { self.period = period }

        /// `--pace`: the pacer's own thread starts the frames. Off by default: on the headset
        /// it never held the 13 ms the delay sweep had shown (frames came out a
        /// refresh late at every lead under 23 ms, for a reason not found yet), so the display
        /// link starts the frames and the pacer only measures.
        static let enabled = CommandLine.arguments.contains("--pace")
        /// How long after the link's output time frames are shown, smoothed: the pose is
        /// predicted that much further ahead.
        private var linkDelay = 0.0167
        var delayAfterLink: Double { lock.lock(); defer { lock.unlock() }; return linkDelay }

        /// True while the pacer's own thread starts the frames (the link's calls then do nothing).
        var paces: Bool {
            lock.lock(); defer { lock.unlock() }
            return Self.enabled && vsync > 0 && CACurrentMediaTime() - vsync < 0.5
        }

        /// The next refresh to aim at and when to start its frame; nil while no frame was shown
        /// lately (the display link paces then).
        func next(now: Double) -> (aim: Double, start: Double)? {
            lock.lock(); defer { lock.unlock() }
            guard Self.enabled, vsync > 0, now - vsync < 0.5 else { return nil }
            let earliest = max(now + lead, lastAim + period * 0.5)
            let aim = vsync + ((earliest - vsync) / period).rounded(.up) * period
            lastAim = aim
            return (aim, aim - lead)
        }

        /// False when the frame before is still waiting for the main thread: this one is dropped.
        func offer() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if waitingOnMain { dropped += 1; return false }
            waitingOnMain = true
            return true
        }

        /// A frame starts on the main thread. False once after a late frame: it is left out.
        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            waitingOnMain = false
            guard skip > 0 else { return true }
            skip -= 1
            skipped += 1
            return false
        }

        func drawn(start: Double, at end: Double) {
            lock.lock(); defer { lock.unlock() }
            drawing += end - start
        }

        /// A frame aimed at `aim` and started at `start` was shown at `time`.
        func shown(aim: Double?, linkTarget: Double, start: Double, at time: Double) {
            lock.lock(); defer { lock.unlock() }
            vsync = time
            if aim == nil, time - linkTarget > -0.02, time - linkTarget < 0.1 { linkDelay += (time - linkTarget - linkDelay) * 0.05 }
            count += 1
            sinceStart += time - start
            if let aim {
                if time > aim + period * 0.5 {
                    late += 1
                    lateRun += 1
                    // Late five times running: one frame is waiting in front of every new one.
                    if lateRun >= 5, time - lastSkip > 0.25 { skip = 1; lastSkip = time; lateRun = 0 }
                } else if time < aim - period * 0.5 {
                    early += 1
                    lateRun = 0
                } else {
                    lateRun = 0
                }
            }
            if count == 600 {
                log(String(format: "[display] 600 frames shown %.2f ms after they start (%.2f ms of it waiting for a drawable; drawn in %.2f ms, started %.2f ms before their refresh): %d late, %d early, %d skipped, %d dropped, %d not shown",
                           sinceStart / 600 * 1000, waiting / 600 * 1000, drawing / 600 * 1000, lead * 1000, late, early, skipped, dropped, notShown))
                count = 0; waiting = 0; late = 0; early = 0; notShown = 0; skipped = 0; dropped = 0; sinceStart = 0; drawing = 0
            }
        }

        /// The layer made a frame wait `seconds` for a drawable: its three hold frames waiting to
        /// be shown, and until two frames are left out every frame starts late.
        func blocked(_ seconds: Double, at time: Double) {
            lock.lock(); defer { lock.unlock() }
            if seconds > 0.003, time - lastSkip > 0.25 { skip = 2; lastSkip = time }
        }

        /// A frame left out: the lens thread still had the two before it (the display is behind).
        func leftOut() { lock.lock(); skipped += 1; lock.unlock() }
        /// How long the frame waited for a drawable (every frame in flight held one).
        func waited(_ seconds: Double) { lock.lock(); waiting += seconds; lock.unlock() }
        func miss() { lock.lock(); notShown += 1; lock.unlock() }
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }
    private var pacer: Pacer?
    /// `--lookahead MS`: extra prediction, to try by eye (the panel's own delay isn't known).
    /// The `[` and `]` keys' trim on the prediction, and how far ahead of its start the last frame
    /// was predicted, in ms.
    var lookaheadTrimNs: Int64 = HeadsetView.extraLookaheadNs
    private(set) var lookaheadMs = 0.0
    private static let extraLookaheadNs: Int64 = {
        let a = CommandLine.arguments
        // None, on top of the measured delay and half a scanout. It was 6 ms, found by eye
        // before the late latch; with the panel since measured to start a frame 1.2 ms after it
        // is said to be shown, 0 looked far better: at 6 every pose was predicted past its moment, and what is
        // fixed in space ran ahead of a quick head.
        guard let i = a.firstIndex(of: "--lookahead"), i + 1 < a.count, let ms = Double(a[i + 1]) else { return 0 }
        return Int64(ms * 1e6)
    }()

    private func startHeadsetLink(_ id: CGDirectDisplayID) {
        var out: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(id, &out) == kCVReturnSuccess, let link = out else {
            log("[display] couldn't make a display link for the headset; using the view's")
            headsetDisplay = nil
            viewDidMoveToWindow()
            return
        }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toSeconds = Double(timebase.numer) / Double(timebase.denom) / 1e9
        // Each display clock owns its mailbox. A retired queued callback must
        // never drain, block or render a target belonging to its replacement.
        let pending = Pending()
        let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        let pacer = Pacer(period: period.timeScale > 0 && period.timeValue > 0 ? Double(period.timeValue) / Double(period.timeScale) : 1.0 / 120)
        self.pacer = pacer
        renderer.refreshPeriod = pacer.period
        let ticksPerSecond = Double(timebase.denom) / Double(timebase.numer) * 1e9
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, output, _, _ in
            // Until the pacer has seen frames shown, the link starts them: its output time is about
            // when a frame started now is shown (host time, CACurrentMediaTime's clock).
            guard !pacer.isStopped, !pacer.paces else { return kCVReturnSuccess }
            let target = Double(output.pointee.hostTime) * toSeconds
            if pending.offer(target, aim: nil) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pacer === pacer, !pacer.isStopped else { return }
                    self.frame(target: pending.take().target)
                }
            }
            return kCVReturnSuccess
        }
        let thread = Thread { [weak self] in
            while !pacer.isStopped {
                guard let next = pacer.next(now: CACurrentMediaTime()) else {
                    usleep(2000)
                    continue
                }
                let wait = next.start - CACurrentMediaTime()
                if wait > 0 { mach_wait_until(mach_absolute_time() + UInt64(wait * ticksPerSecond)) }
                guard !pacer.isStopped else { break }
                if pacer.offer() {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.pacer === pacer, !pacer.isStopped else { return }
                        self.frame(target: next.aim, aim: next.aim)
                    }
                }
            }
        }
        thread.name = "halliday.frame-start"
        thread.qualityOfService = .userInteractive
        thread.start()
        CVDisplayLinkStart(link)
        cvLink = link
        // The picture is opaque, and saying so is one of the conditions for macOS to send the
        // frames to the display without compositing them first.
        metalLayer.isOpaque = true
        let rate = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
        let hz = rate.timeValue > 0 ? Double(rate.timeScale) / Double(rate.timeValue) : 0
        log("[display] frames paced by the headset's display link, \(String(format: "%.0f", hz)) Hz")
    }
    // Paced frames' statistics (logged every 600).
    private var pacedFrames = 0
    private var pacedStart = 0.0
    private var mainThreadTime = 0.0
    private var drawableWait = 0.0

    @objc private func step(_ link: CADisplayLink) { frame(target: link.targetTimestamp) }

    private func frame(target targetSeconds: Double, aim: Double? = nil) {
        // Without an aim from the pacer: as long after the link's output time as frames are shown.
        var target = Int64((aim ?? targetSeconds + (pacer?.delayAfterLink ?? 0)) * 1e9) + scanoutLookaheadNs
        let t0 = CACurrentMediaTime()
        if aim != nil, let pacer, !pacer.begin() { return }
        // The headset's orientation is asked for again once the scene is drawn (LateLatch.swift).
        if let tracked = source as? TrackedSource {
            let headset = tracked.headset
            renderer.latePose = { headset.predict(atHostNs: $0).map { ($0.orientation, $0.angularVelocity) } }
        } else {
            renderer.latePose = nil
        }
        let latched = renderer.canLatch
        // Drawn in one piece, the frame waits for a drawable here; latched, the lens thread does.
        let drawable = latched ? nil : metalLayer.nextDrawable()
        if !latched, drawable == nil { return }
        if let pacer {
            pacer.waited(CACurrentMediaTime() - t0)
            if aim != nil { pacer.blocked(CACurrentMediaTime() - t0, at: t0) }
            target += lookaheadTrimNs
            lookaheadMs = Double(target) / 1e6 - t0 * 1000
            renderer.gpuDone = { end in pacer.drawn(start: t0, at: end) }
        }
        var presented: (@Sendable (CAMetalDrawable) -> Void)?
        if let pacer {
            presented = { (drawable: CAMetalDrawable) in
                drawable.addPresentedHandler { (d: MTLDrawable) in
                    if d.presentedTime > 0 {
                        pacer.shown(aim: aim, linkTarget: targetSeconds, start: t0, at: d.presentedTime)
                    } else {
                        pacer.miss()
                    }
                }
            }
        }
        let t1 = CACurrentMediaTime()
        Self.frameTarget = Double(target) / 1e9
        let fallback = HeadPose(position: [0, 1.65, 0], orientation: simd_quatf(angle: 0, axis: [0, 1, 0]),
                                angularVelocity: .zero, slamAgeNs: 0, predicted: false)
        let head = source.pose(atHostNs: target) ?? fallback
        renderer.lateTargetNs = target
        onFrame?(head)
        if let drawable {
            presented?(drawable)
            renderer.render(head: head, calibration: source.calibration, to: drawable)
        } else if !renderer.renderLatched(head: head, calibration: source.calibration, layer: metalLayer, presenting: presented) {
            renderer.gpuDone = nil
            pacer?.leftOut()
        }
        if timer != nil {
            mainThreadTime += CACurrentMediaTime() - t1
            drawableWait += t1 - t0
            pacedFrames += 1
            if pacedFrames == 1 { pacedStart = t0 }
            if pacedFrames == 601 {
                log("[display] paced: 600 frames in \(String(format: "%.2f", t0 - pacedStart)) s, \(String(format: "%.2f", mainThreadTime / 600 * 1000)) ms a frame on the main thread, \(String(format: "%.2f", drawableWait / 600 * 1000)) ms waiting for a drawable")
                pacedFrames = 1; pacedStart = t0; mainThreadTime = 0; drawableWait = 0
            }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.cancel()
        timer = nil
        if let cvLink { CVDisplayLinkStop(cvLink); self.cvLink = nil }
        pacer?.stop()
        pacer = nil
    }

    /// A physical mode change keeps the view, game and renderer, but retires
    /// the old display clock and measurements before pacing the new mode.
    func refreshHeadsetTiming(display id: CGDirectDisplayID, hz: Double) {
        guard headsetDisplay == id, Self.pacedRate == nil, hz.isFinite, hz > 0 else { return }
        scanoutLookaheadNs = Int64(1e9 / (2 * hz))
        let running = cvLink.map { CVDisplayLinkIsRunning($0) } ?? false
        guard !running || pacer == nil || abs((pacer?.period ?? 0) - 1 / hz) > 0.00001 else { return }
        stop()
        startHeadsetLink(id)
        log("[display] restarted headset pacing at \(Int(hz.rounded())) Hz")
    }

    // --- Input ---
    // Without MouseOwner: mouse motion over this view moves the pointer and right-drag looks
    // around. With it, the same arrive through the event tap (see MouseOwner.swift).

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Over this view the Mac's cursor is invisible: the VR pointer is the only cursor, as in the
    /// headset. (Two cursors that don't line up cause misclicks.)
    private static let invisibleCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }()

    /// Controller interaction never hides the desktop cursor.
    var hidesDesktopCursor = false {
        didSet { if oldValue != hidesDesktopCursor { window?.invalidateCursorRects(for: self) } }
    }
    override func resetCursorRects() {
        if hidesDesktopCursor { addCursorRect(bounds, cursor: Self.invisibleCursor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    private func nudgePointer(dx: Double, dy: Double) { InputState.shared.nudge(dx: dx, dy: dy) }

    /// While interacting, the event tap moves the pointer; the redirected cursor passing over this
    /// view must not move it a second time.
    var pointerFromTap = false
    /// The next mouse delta comes from Halliday moving the cursor itself (a warp), not the user.
    var skipNextDelta = false

    /// In an immersive WebXR page with the simulator's mouse source, mouse motion turns the head
    /// (first-person style) and the pointer stays in the middle of the view.
    var mouseTurnsHead = false

    private func userDelta(_ event: NSEvent) {
        if skipNextDelta { skipNextDelta = false; return }
        guard !pointerFromTap else { return }
        if mouseTurnsHead, let mouse = source as? MouseLook {
            // ⌥ while a game has the input: the mouse moves a hand instead.
            if (NSApp.delegate as? AppDelegate)?.gameAim(dx: Float(event.deltaX), dy: Float(event.deltaY)) == true { return }
            mouse.look(dx: Float(event.deltaX), dy: Float(event.deltaY))
        } else {
            nudgePointer(dx: event.deltaX, dy: event.deltaY)
        }
    }

    /// The view's center in global display coordinates (points, origin top-left).
    var globalCenter: CGPoint? {
        guard let window else { return nil }
        let r = window.convertToScreen(convert(bounds, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return CGPoint(x: r.midX, y: top - r.midY)
    }

    override func scrollWheel(with event: NSEvent) {
        if !pointerFromTap { (NSApp.delegate as? AppDelegate)?.scrolled(dy: event.scrollingDeltaY) }
    }

    override func mouseMoved(with event: NSEvent) { userDelta(event) }
    override func mouseDragged(with event: NSEvent) { userDelta(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if !pointerFromTap {
            let p = convert(event.locationInWindow, from: nil)
            // Where in the view, −1…1 from its center (x right, y up).
            let spot = bounds.width > 0 && bounds.height > 0
                ? CGPoint(x: p.x / bounds.width * 2 - 1, y: p.y / bounds.height * 2 - 1) : nil
            (NSApp.delegate as? AppDelegate)?.clickedInView(rightButton: false, at: spot)
        }
    }

    /// True while a right-drag that began on empty space is looking around.
    private var lookingAround = false

    override func rightMouseDown(with event: NSEvent) {
        guard !pointerFromTap else { return }
        // Over a VR window: a right-click into it. On empty space: look around while dragging.
        lookingAround = (NSApp.delegate as? AppDelegate)?.clickedInView(rightButton: true) == false
    }

    override func rightMouseUp(with event: NSEvent) {
        lookingAround = false
        if !pointerFromTap { (NSApp.delegate as? AppDelegate)?.releasedInView(rightButton: true) }
    }

    override func mouseUp(with event: NSEvent) {
        if !pointerFromTap { (NSApp.delegate as? AppDelegate)?.releasedInView(rightButton: false) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if lookingAround { (source as? MouseLook)?.look(dx: Float(event.deltaX), dy: Float(event.deltaY)) }
    }

    /// ⌘V (Edit menu) while Halliday has the keyboard: into the VR address bar, if it is being edited.
    @objc func paste(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.pasteIntoAddressBar() }

    override func keyDown(with event: NSEvent) {
        if (NSApp.delegate as? AppDelegate)?.gameKey(event, down: true) == true { return }
        if (NSApp.delegate as? AppDelegate)?.typed(event) == true { return }
        // R is held, not tapped: recentering runs on a timer (see AppDelegate.recenterHold).
        if event.keyCode == 15, !event.modifierFlags.contains(.command) {
            if !event.isARepeat { (NSApp.delegate as? AppDelegate)?.recenterHold(began: true) }
            return
        }
        // Arrow keys arrive as private-use characters: map them to ← →.
        if event.keyCode == 123 { (NSApp.delegate as? AppDelegate)?.handleKey("\u{2190}"); return }
        if event.keyCode == 124 { (NSApp.delegate as? AppDelegate)?.handleKey("\u{2192}"); return }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        if c == "o", event.modifierFlags.contains(.shift) { (NSApp.delegate as? AppDelegate)?.handleKey("O"); return }
        // Walking in the simulator, in room-scale mode (seated: the user stays in place) and always
        // while a game presents (games are room-scale; their keys take over A, S, D, Q, E).
        let walks = Settings.shared.mode == .roomScale || (NSApp.delegate as? AppDelegate)?.gameActive == true
        if walks, !event.modifierFlags.contains(.command), let mouse = source as? MouseLook, "wasdqe".contains(c) {
            mouse.moveKeys.insert(c)
            return
        }
        (NSApp.delegate as? AppDelegate)?.handleKey(c)
    }

    override func keyUp(with event: NSEvent) {
        if (NSApp.delegate as? AppDelegate)?.gameKey(event, down: false) == true { return }
        if event.keyCode == 15 { (NSApp.delegate as? AppDelegate)?.recenterHold(began: false) }
        guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return }
        (source as? MouseLook)?.moveKeys.remove(c)
    }

    override func resignFirstResponder() -> Bool {
        (source as? MouseLook)?.moveKeys.removeAll()
        return true
    }
}
