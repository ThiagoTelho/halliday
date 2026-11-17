// Mac windows in VR: picks windows, moves them onto Halliday's virtual display, captures that
// display, and shows each window as a quad layer on an arc around the user.
//
// Each VR window is captured by a stream of its own, so its picture is whole even when windows
// overlap on the virtual display (which is smaller than what eight windows need). The whole
// virtual display is captured too: a window shows its region of it until its own stream delivers,
// and menus, popovers, tooltips, sheets and dialogs that an app opens there are found by polling
// the window list and shown as regions of it, as extra layers in front of their parent window, at
// the matching spot, so they can be seen and clicked in VR.
//
// The real windows are moved onto the virtual display while they are in VR (and back when they
// leave, or after a crash through WindowLedger), so they never overlap the user's desktop,
// Halliday's preview or each other. Input reaches them through MouseOwner, which redirects the real
// mouse to the window under the VR pointer. Moving and input both need the Accessibility permission.

import AppKit
import ApplicationServices
import Metal
import ScreenCaptureKit
import simd

@MainActor
final class MacWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let appName: String
    let title: String
    let layer: QuadLayer
    /// Window frame in global display coordinates (points, origin top-left of the main display).
    var frame: CGRect
    /// Where the window was before Halliday moved it; restored when it leaves VR.
    let originalFrame: CGRect
    let ax: AXWindow?
    /// Set for Halliday's own windows (e.g. the browser): moved directly, never restored.
    let own: NSWindow?
    /// Where the user dragged the window; nil while it sits in the arc.
    var placement: Placement?
    /// For a window about to join the arc: the direction (world yaw) it should appear in (beside the
    /// window that opened it, or where the user is looking).
    var arcHint: Float?
    /// How much the current layout scales the window in VR (1 in the arc; larger in Focus…). The
    /// real window keeps its size.
    var layoutScale: Float = 1
    /// The window's own capture: started when it comes into VR; until its first frame the layer
    /// shows the window's region of the virtual display's capture.
    var stream: CaptureStream?
    var picture: CapturedTexture?
    var hasOwnPicture = false
    /// When its capture was last copied for the GPU (`WindowManager.updateTexture`).
    var lastCapture = 0.0
    /// A capture of its own is being started.
    var captureStarting = false
    /// When it stopped being overlapped by another VR window (its own capture ends a moment later).
    var notOverlappedSince: Double?

    func stopCapture() {
        stream?.stop()
        stream = nil
    }

    /// Not drawn: the window went off screen a moment ago (closed, most likely); it leaves VR for
    /// good once that is confirmed.
    var hidden = false
    /// The window's full-screen button, relative to its top-left corner (with a little margin):
    /// clicks there are stopped, because a full-screen window can't stay in VR.
    var blocked: CGRect?
    /// macOS's "being recorded" badge over the window's title-bar buttons (macOS 26 puts it there
    /// while the window is captured), relative to the window's top-left corner. It is not drawn in
    /// VR, and clicks there are stopped: they would land on the badge.
    var badge: CGRect?
    /// Where clicks are not passed on to the window.
    var blockedArea: CGRect? {
        switch (blocked, badge) {
        case let (b?, g?): b.union(g.insetBy(dx: -3, dy: -3))
        case let (b?, nil): b
        case let (nil, g?): g.insetBy(dx: -3, dy: -3)
        default: nil
        }
    }

    /// Re-reads where the full-screen button is (it keeps its place when the window resizes, but
    /// apps differ in where they put it).
    func updateBlockedArea() {
        guard own == nil, let ax, let f = ax.fullScreenButtonFrame, let origin = ax.frame?.origin else { return }
        blocked = CGRect(x: f.minX - origin.x, y: f.minY - origin.y, width: f.width, height: f.height).insetBy(dx: -3, dy: -4)
    }

    /// A window placed by hand: its pose, and its size relative to a window in the arc (1 today;
    /// kept for resizing panels in VR).
    struct Placement {
        var position: SIMD3<Float>
        var orientation: simd_quatf
        var scale: Float
    }

    init(windowID: CGWindowID, pid: pid_t, appName: String, title: String, layer: QuadLayer, frame: CGRect,
         originalFrame: CGRect, ax: AXWindow?, own: NSWindow? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.title = title
        self.layer = layer
        self.frame = frame
        self.originalFrame = originalFrame
        self.ax = ax
        self.own = own
    }

    /// Moves the real window to `frame` (global display coordinates, origin top-left).
    @discardableResult
    func move(to frame: CGRect) -> Bool {
        if let own {
            own.setFrame(appKitFrame(frame), display: true)
            return true
        }
        return ax?.setFrame(frame) ?? false
    }
}

/// Converts a rectangle in global display coordinates (origin top-left of the main display) to
/// AppKit's screen coordinates (origin bottom-left of the main display).
func appKitFrame(_ r: CGRect) -> NSRect {
    let top = NSScreen.screens.first?.frame.maxY ?? r.maxY
    return NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
}

/// A short-lived window of a VR window's app (menu, popover, tooltip, sheet, dialog) on the
/// virtual display, drawn in front of its parent.
/// The window behind everything on the virtual display (see `WindowManager.backdrop`).
final class BackdropWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let layer: QuadLayer
    var frame: CGRect

    init(windowID: CGWindowID, pid: pid_t, layer: QuadLayer, frame: CGRect) {
        self.windowID = windowID
        self.pid = pid
        self.layer = layer
        self.frame = frame
    }
}

@MainActor
final class WindowManager {
    private let renderer: Renderer
    private(set) var windows: [MacWindow] = []
    private(set) var popups: [PopupWindow] = []
    /// Meters per window point: a 1440-point-wide window is ~1.6 m wide.
    var metersPerPoint: Float = 0.0011
    /// Radius of the arc the windows sit on, around the user's starting position.
    /// Corner radius given to windows in VR, in capture pixels (2 per point): a little more than
    /// macOS's own window corners, so no sliver of the virtual display's wallpaper shows in them.
    static let windowCornerPixels: Float = 36
    static let referenceDistance: Float = 1.4
    var radius: Float = 1.4
    /// Direction the arc faces from its center (yaw; 0 = toward −z).
    private(set) var heading: Float = 0
    var center = SIMD3<Float>(0, 1.6, 1.0)
    /// Created the first time windows are brought in; removed when Halliday quits.
    private var display: VirtualDisplay?
    private var displayStream: CaptureStream?
    private var displayTexture: CapturedTexture?
    /// Where moved windows came from, on disk, so they can be put back even after a crash.
    let ledger = WindowLedger()

    init(renderer: Renderer) {
        self.renderer = renderer
        renderer.beforeFrame.append { [weak self] cb in self?.updateTexture(cb) }
    }

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// A window the user could bring into VR, and what stands in the way.
    struct Candidate {
        enum State: Equatable {
            case inVR
            /// On screen and movable.
            case ready
            /// Can be brought in after being taken out of the Dock / out of full screen.
            case minimized, fullScreen
            /// Halliday can't move windows between Spaces.
            case otherSpace
        }

        let window: SCWindow
        let appName: String
        let title: String
        let state: State
        /// Identity and state, to tell whether a list changed.
        var key: String { "\(window.windowID)|\(state)|\(title)" }
    }

    /// Called with a short message for the user (shown as a notice in VR).
    var onNotice: ((String) -> Void)?
    /// Called when a window can't come in because VR is full (the owner offers the way forward).
    var onFull: (() -> Void)?
    /// Called after another app was activated to reach its window: Halliday takes the focus back.
    var onActivatedAnotherApp: (() -> Void)?
    /// Called when a window left VR by itself (closed, minimized, its app quit).
    var onWindowLeft: ((CGWindowID) -> Void)?

    private func notify(_ message: String) {
        if onNotice == nil { log("[windows] \(message)") }
        onNotice?(message)
    }

    /// The Mac's normal windows (other apps): the ones in VR first, then front to back the ones that
    /// can come in, then the ones that need a step first (minimized, full screen) or can't (another
    /// Space). Nil without Screen Recording permission (asks for it) or if the list can't be read.
    func candidates() async -> [Candidate]? {
        if !CGPreflightScreenCaptureAccess() {
            log("[windows] asking for Screen Recording permission (System Settings → Privacy & Security)")
            Permissions.shared.request(.screenRecording)
            return nil
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            log("[windows] can't list windows: \(error.localizedDescription)")
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let order = frontToBackWindowIDs()
        let inVR = Set(windows.map(\.windowID))
        // Regular apps only (the ones in the Dock): helpers such as AutoFill or the open/save panel
        // service own windows too, but nobody wants to pick those.
        func isRegularApp(_ pid: pid_t?) -> Bool {
            pid.flatMap { NSRunningApplication(processIdentifier: $0) }?.activationPolicy == .regular
        }
        let list = content.windows.filter { w in
            guard w.windowLayer == 0, w.owningApplication?.processID != ownPID else { return false }
            // A game's frames window (GameFrames.swift) is Halliday's, not something to pick.
            if (w.title ?? "").hasPrefix(GameFrameCapture.title) { return false }
            if inVR.contains(w.windowID) { return true }
            guard w.frame.width >= 300, w.frame.height >= 200, isRegularApp(w.owningApplication?.processID) else { return false }
            // Off screen and untitled: usually an invisible leftover, not something to list.
            return w.isOnScreen || !(w.title ?? "").isEmpty
        }
        // Minimized and full-screen state comes from Accessibility, asked per app off the main
        // thread (a busy app may take up to the timeout to answer).
        let pids = Set(list.compactMap { $0.owningApplication?.processID })
        let states = await Task.detached(priority: .userInitiated) {
            var all: [CGWindowID: (minimized: Bool, fullScreen: Bool)] = [:]
            for pid in pids { all.merge(AXWindow.states(pid: pid)) { a, _ in a } }
            return all
        }.value
        return list.compactMap { w -> Candidate? in
            let state: Candidate.State
            if inVR.contains(w.windowID) {
                state = .inVR
            } else if let s = states[w.windowID] {
                state = s.minimized ? .minimized : s.fullScreen ? .fullScreen : w.isOnScreen ? .ready : .otherSpace
            } else if w.isOnScreen {
                state = .ready
            } else if !(w.title ?? "").isEmpty {
                // Not on screen and not in Accessibility's list, which only has the current Space's
                // windows (and minimized ones): a window in another Space.
                state = .otherSpace
            } else {
                return nil // an untitled leftover of the app
            }
            return Candidate(window: w, appName: w.owningApplication?.applicationName ?? "?", title: w.title ?? "", state: state)
        }
        .sorted { a, b in
            func rank(_ c: Candidate) -> Int {
                switch c.state {
                case .inVR: 0
                case .ready: 1
                case .minimized, .fullScreen: 2
                case .otherSpace: 3
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (order[a.window.windowID] ?? .max) < (order[b.window.windowID] ?? .max)
        }
    }

    /// Brings a candidate into VR, first taking it out of the Dock or out of full screen if needed.
    @discardableResult
    func bring(_ c: Candidate) async -> Bool {
        guard let pid = c.window.owningApplication?.processID else { return false }
        known.insert(c.window.windowID) // being brought in by hand: not a window to "follow"
        switch c.state {
        case .inVR: return true
        case .ready: return await bring(c.window)
        case .otherSpace:
            // Halliday can't move a window out of another Space, but activating its app makes macOS
            // switch to the Space it is in; then it can be moved like any other.
            guard checkInputPermission(), let app = NSRunningApplication(processIdentifier: pid) else { return false }
            app.activate()
            defer { onActivatedAnotherApp?() }
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let fresh = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                   let w = fresh.windows.first(where: { $0.windowID == c.window.windowID }), w.isOnScreen,
                   AXWindow.find(pid: pid, windowID: w.windowID, frame: w.frame) != nil {
                    try? await Task.sleep(nanoseconds: 300_000_000) // let the Space change settle
                    return await bring(w)
                }
            }
            notify("\(c.appName) is in another Space and couldn't be reached: switch to it on the Mac, then bring it in")
            return false
        case .minimized, .fullScreen:
            guard checkInputPermission() else { return false }
            // An app in the background can take a moment to answer its first Accessibility call.
            var found: AXWindow?
            for _ in 0..<4 where found == nil {
                found = AXWindow.find(pid: pid, windowID: c.window.windowID, frame: c.window.frame)
                if found == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            guard let ax = found else {
                notify("\(c.appName) can't be reached through Accessibility")
                return false
            }
            if c.state == .minimized { ax.unminimize() } else { ax.leaveFullScreen() }
            // Both animate; the window is ready when it is on screen and no longer in that state.
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !ax.isMinimized, !ax.isFullScreen,
                   let fresh = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
                   let w = fresh.windows.first(where: { $0.windowID == c.window.windowID }), w.isOnScreen {
                    try? await Task.sleep(nanoseconds: 400_000_000) // let the animation settle
                    // A window restored into a Space other than the one in view can't be moved.
                    guard AXWindow.find(pid: pid, windowID: w.windowID, frame: w.frame) != nil else { break }
                    return await bring(w)
                }
            }
            notify(ax.isMinimized || ax.isFullScreen
                ? "\(c.appName) didn't come out of \(c.state == .minimized ? "the Dock" : "full screen")"
                : "\(c.appName) came back in another Space: switch to it on the Mac, then bring it in")
            return false
        }
    }

    /// Most windows in VR at once (each window, its bar, menus and panels are layers; 24 in all).
    let maxWindows = 8

    /// Brings one window into VR: moves it onto the virtual display (rearranging the others there
    /// so nothing overlaps) and adds it to the arc. Returns false, with a log line, if it can't.
    @discardableResult
    func bring(_ w: SCWindow) async -> Bool {
        guard !windows.contains(where: { $0.windowID == w.windowID }) else { return true }
        guard windows.count < maxWindows else {
            if let onFull { onFull() } else { notify("At most \(maxWindows) windows fit in VR: send one back first") }
            return false
        }
        guard let pid = w.owningApplication?.processID else { return false }
        let appName = w.owningApplication?.applicationName ?? "?"
        let title = w.title ?? ""
        guard w.isOnScreen else {
            notify("\(appName) isn't on screen (minimized or in another Space)")
            return false
        }
        guard let area = await windowArea(), await startDisplayCapture() else { return false }
        guard let ax = AXWindow.find(pid: pid, windowID: w.windowID, frame: w.frame) else {
            notify("\(appName) can't be reached through Accessibility")
            return false
        }
        // Where everything goes on the virtual display: the windows already there, then this one.
        let placements = layOut(windows.map(\.frame.size) + [w.frame.size], in: area)
        ledger.record(MovedWindow(pid: pid, bundleID: w.owningApplication?.bundleIdentifier, appName: appName,
                                  windowID: w.windowID, title: title, x: w.frame.minX, y: w.frame.minY,
                                  width: w.frame.width, height: w.frame.height))
        if ax.isFullScreen {
            notify("\(appName) is in full screen: bring it in from the Windows panel")
            return false
        }
        guard let target = placements.last, ax.setFrame(target), let frame = ax.frame,
              display?.bounds.intersects(frame) == true else {
            ax.setFrame(w.frame)
            ledger.remove(windowID: w.windowID)
            notify("\(appName) can't be moved onto Halliday's display")
            return false
        }
        for (existing, place) in zip(windows, placements) where existing.frame != place {
            existing.move(to: place)
        }
        let layer = QuadLayer(texture: displayTexture?.texture ?? renderer.placeholderTexture, position: center,
                              width: Float(frame.width) * metersPerPoint)
        let mw = MacWindow(windowID: w.windowID, pid: pid, appName: appName, title: title, layer: layer,
                           frame: frame, originalFrame: w.frame, ax: ax)
        setRegion(of: layer, to: frame)
        layer.cornerPixels = Self.windowCornerPixels
        mw.layer.appear() // it fades in
        mw.layer.castsShadow = true
        windows.append(mw)
        mw.arcHint = siblingYaw(of: mw) ?? gazeYaw
        restorePlacement(of: mw)
        mw.updateBlockedArea()
        log("[windows] in VR: \(appName) — \(title.isEmpty ? "(untitled)" : title) (\(Int(frame.width))×\(Int(frame.height)))")
        arrange()
        updateLayers()
        return true
    }

    /// Brings one of Halliday's own windows (e.g. the browser) into VR: placed on the virtual
    /// display like the others, but moved directly and never restored (it closes instead).
    @discardableResult
    func addOwn(_ window: NSWindow, appName: String, title: String) async -> Bool {
        let id = CGWindowID(window.windowNumber)
        guard !windows.contains(where: { $0.windowID == id }) else { return true }
        guard windows.count < maxWindows else {
            log("[windows] at most \(maxWindows) windows in VR; send one back first")
            return false
        }
        guard let area = await windowArea(), await startDisplayCapture() else { return false }
        let size = window.frame.size
        let placements = layOut(windows.map(\.frame.size) + [size], in: area)
        guard let frame = placements.last else { return false }
        for (existing, place) in zip(windows, placements) where existing.frame != place {
            existing.move(to: place)
        }
        window.setFrame(appKitFrame(frame), display: true)
        let layer = QuadLayer(texture: displayTexture?.texture ?? renderer.placeholderTexture, position: center,
                              width: Float(frame.width) * metersPerPoint)
        let mw = MacWindow(windowID: id, pid: ProcessInfo.processInfo.processIdentifier, appName: appName, title: title,
                           layer: layer, frame: frame, originalFrame: frame, ax: nil, own: window)
        setRegion(of: layer, to: frame)
        layer.cornerPixels = Self.windowCornerPixels
        mw.layer.appear() // it fades in
        mw.layer.castsShadow = true
        windows.append(mw)
        mw.arcHint = siblingYaw(of: mw) ?? gazeYaw
        restorePlacement(of: mw)
        mw.updateBlockedArea()
        log("[windows] in VR: \(appName) (\(Int(frame.width))×\(Int(frame.height)))")
        arrange()
        updateLayers()
        return true
    }

    /// Sends one window back to where it was on the user's desktop (Halliday's own windows are
    /// just taken out of VR; their owner closes them).
    func sendBack(_ windowID: CGWindowID) {
        guard let i = windows.firstIndex(where: { $0.windowID == windowID }) else { return }
        let w = windows.remove(at: i)
        w.stopCapture()
        known.insert(w.windowID) // sent back on purpose: not followed back into VR
        if w.own == nil { w.ax?.setFrame(w.originalFrame) }
        ledger.remove(windowID: w.windowID)
        popups.removeAll { $0.pid == w.pid && !windows.contains(where: { $0.pid == w.pid }) }
        log("[windows] back on the desktop: \(w.appName) — \(w.title.isEmpty ? "(untitled)" : w.title)")
        arrange()
        updateLayers()
    }

    /// Closes window `windowID` for real, as its red button would (the app may ask to save: its
    /// sheet shows in VR). It leaves VR when macOS reports it gone. False if it can't be closed
    /// this way.
    @discardableResult
    func closeWindow(_ windowID: CGWindowID) -> Bool {
        guard let w = windows.first(where: { $0.windowID == windowID }) else { return false }
        if let own = w.own {
            own.performClose(nil)
            return true
        }
        guard w.ax?.close() == true else {
            notify("\(w.appName) has no close button: use ↩ to send it back to the Mac")
            return false
        }
        return true
    }

    /// Takes every window out of VR and puts it back where it was.
    func stopAll() {
        for w in windows where w.own == nil {
            w.ax?.setFrame(w.originalFrame)
            ledger.remove(windowID: w.windowID)
        }
        for w in windows { w.stopCapture() }
        windows = []
        popups = []
        backdrop?.orderOut(nil)
        backdrop = nil
        displayStream?.stop()
        displayStream = nil
        updateLayers()
    }

    // --- Capture ---

    /// Starts capturing the whole virtual display (once). False if it can't.
    private func startDisplayCapture() async -> Bool {
        if displayStream != nil { return true }
        guard let display else { return false }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log("[windows] can't list displays: \(error.localizedDescription)")
            return false
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.displayID }) else {
            log("[windows] the virtual display isn't available for capture yet")
            return false
        }
        if displayTexture == nil { displayTexture = CapturedTexture(device: renderer.device) }
        let stream = CaptureStream(name: "virtual display")
        do {
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            try await stream.start(filter: filter, width: Int(display.size.width * 2), height: Int(display.size.height * 2))
        } catch {
            log("[windows] can't capture the virtual display: \(error.localizedDescription)")
            return false
        }
        displayStream = stream
        return true
    }

    /// Gives each window a capture of its own only while another VR window overlaps it on the
    /// virtual display (they overlap when they don't fit side by side there): a capture stream per
    /// window costs about a millisecond of GPU time each, mostly the window server's, however few
    /// frames it delivers. The others show their part of the display's capture. A stream ends a
    /// couple of seconds after its window stops being overlapped. Called at each refresh.
    private func updateOwnCaptures() {
        guard !Self.sharedCaptureOnly else { return }
        let now = CACurrentMediaTime()
        for w in windows {
            let overlapped = windows.contains { $0 !== w && !$0.hidden && $0.frame.intersection(w.frame).width > 1 && $0.frame.intersection(w.frame).height > 1 }
            if overlapped {
                w.notOverlappedSince = nil
                if w.stream == nil, !w.captureStarting { startWindowCapture(w) }
            } else if w.stream != nil {
                let since = w.notOverlappedSince ?? now
                w.notOverlappedSince = since
                if now - since > 2 { stopOwnCapture(w) }
            }
        }
    }

    /// Back to the window's part of the display's capture.
    private func stopOwnCapture(_ w: MacWindow) {
        w.stopCapture()
        w.picture = nil
        w.notOverlappedSince = nil
        guard w.hasOwnPicture else { return }
        w.hasOwnPicture = false
        if let texture = displayTexture?.texture { w.layer.texture = texture }
        setRegion(of: w.layer, to: w.frame)
        log("[windows] \(w.appName): shown from the display's capture (nothing overlaps it)")
    }

    /// Starts window `mw`'s own capture (in the background; the window shows its region of the
    /// virtual display until the first frame is here, and keeps doing so if this fails).
    private func startWindowCapture(_ mw: MacWindow) {
        guard !Self.sharedCaptureOnly else { return }
        mw.captureStarting = true
        Task { @MainActor [weak self, weak mw] in
            defer { mw?.captureStarting = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let self, let mw, windows.contains(where: { $0 === mw }), mw.stream == nil,
                  let window = content.windows.first(where: { $0.windowID == mw.windowID }) else { return }
            let stream = CaptureStream(name: mw.appName)
            do {
                // 60 fps: a Mac window's content doesn't need the headset's rate (the view of it is
                // drawn at the headset's rate regardless).
                try await stream.start(filter: SCContentFilter(desktopIndependentWindow: window), width: Int(mw.frame.width * 2),
                                       height: Int(mw.frame.height * 2), fps: 60, singleWindow: true)
            } catch {
                log("[windows] \(mw.appName): no capture of its own (\(error.localizedDescription)); it shows its part of the display")
                return
            }
            guard windows.contains(where: { $0 === mw }) else {
                stream.stop()
                return
            }
            mw.picture = CapturedTexture(device: renderer.device)
            mw.stream = stream
        }
    }

    /// Covers macOS's recording badge in window `w`'s picture (see `MacWindow.badge`): the layer
    /// shows the title bar's own color, taken from just beside it, over that corner.
    private func updatePatch(_ w: MacWindow) {
        guard let b = w.badge, w.frame.width > 0, w.frame.height > 0 else {
            w.layer.patch = .zero
            return
        }
        let r = b.insetBy(dx: -3, dy: -3)
        w.layer.patch = SIMD4(Float(r.minX / w.frame.width), Float(r.minY / w.frame.height),
                              Float(r.width / w.frame.width), Float(r.height / w.frame.height))
    }

    /// Debug (`--shared-capture`): windows only show their region of the virtual display, as before
    /// they had captures of their own (overlapping windows then show each other).
    private static let sharedCaptureOnly = CommandLine.arguments.contains("--shared-capture")

    /// Called with each new capture that may hold an immersive page's frame, after it is copied
    /// for the GPU: the pixels, the rectangle they cover in global display coordinates, the texture
    /// they were copied into, and the window they are a capture of (nil: the whole virtual display).
    /// Lets the WebXR presentation read the pose stamp of a page's frame.
    /// The last argument is where in the pixels the window's content is (a window's capture keeps
    /// its old size for a moment after the window changes size, and fits the content into it).
    var onFrameCaptured: ((CVPixelBuffer, CGRect, MTLTexture, CGWindowID?, CGRect) -> Void)?

    /// An immersive page presents: every capture is taken at once (see `updateTexture`).
    var capturesEveryFrame = false
    private var captureTurn = 0
    private var lastDisplayCapture = 0.0
    private var captureCount = 0, captureMegapixels = 0.0
    /// The captures copied since the last call and their size in megapixels (for the log's
    /// `[stat]` line: what the windows cost the GPU).
    func takeCaptureStats() -> (count: Int, megapixels: Double) {
        defer { captureCount = 0; captureMegapixels = 0 }
        return (captureCount, captureMegapixels)
    }

    /// True once window `id` is shown from its own capture.
    func hasOwnPicture(_ id: CGWindowID) -> Bool { windows.first { $0.windowID == id }?.hasOwnPicture == true }

    /// Copies the newest captured frames into their textures (called before each frame).
    private func updateTexture(_ cb: MTLCommandBuffer) {
        // A capture's copy and its mipmaps cost GPU time by its size (the whole virtual
        // display is 18.7 million pixels), and a window whose content keeps changing sends a
        // frame every refresh: at 120 Hz those copies took the frame over its 8.3 ms and the
        // whole view fell to 60 to 80 frames a second, every edge doubled. A Mac
        // window is refreshed 60 times a second at most, the windows in
        // turn so that their copies don't land in the same frame; an immersive page's frames
        // (`capturesEveryFrame`) are each one the view itself and are never held back.
        let now = CACurrentMediaTime()
        captureTurn &+= 1
        func due(_ last: Double, turn: Int) -> Bool {
            capturesEveryFrame || now - last > 1.0 / 60 - 0.003 && (now - last > 0.03 || (captureTurn &+ turn) % 2 == 0)
        }
        // All the windows' new frames are copied in one blit pass.
        var blit: MTLBlitCommandEncoder?
        for (index, w) in windows.enumerated() {
            guard let stream = w.stream, let target = w.picture, due(w.lastCapture, turn: index),
                  let frame = stream.takeNewFrameAndContent() else { continue }
            w.lastCapture = now
            captureCount += 1
            captureMegapixels += Double(CVPixelBufferGetWidth(frame.pixels) * CVPixelBufferGetHeight(frame.pixels)) / 1e6
            if blit == nil { blit = cb.makeBlitCommandEncoder() }
            guard let blit, target.encodeUpdate(from: frame.pixels, into: cb, blit: blit), let texture = target.texture else { continue }
            if !w.hasOwnPicture {
                w.hasOwnPicture = true
                w.layer.textureWidthOverride = nil
                log("[windows] \(w.appName): shown from its own capture")
            }
            w.layer.texture = texture
            // The stream follows the window's size (it may have changed before the stream delivered).
            w.stream?.resize(width: Int(w.frame.width * 2), height: Int(w.frame.height * 2))
            // The window's content within the frame (all of it, unless the window just changed size).
            let tw = CGFloat(texture.width), th = CGFloat(texture.height)
            let c = (frame.content ?? CGRect(x: 0, y: 0, width: tw, height: th)).intersection(CGRect(x: 0, y: 0, width: tw, height: th))
            w.layer.uvRect = c.isEmpty ? SIMD4(0, 0, 1, 1) : SIMD4(Float(c.minX / tw), Float(c.minY / th), Float(c.width / tw), Float(c.height / th))
            if w.own != nil { onFrameCaptured?(frame.pixels, w.frame, texture, w.windowID, c) }
        }
        blit?.endEncoding() // before the display's copy below, which opens a pass of its own
        // The virtual display's capture is only copied while something shows a region of it (a
        // frame that arrives meanwhile waits: the next popup starts from the newest one).
        guard !popups.isEmpty || windows.contains(where: { !$0.hasOwnPicture }), due(lastDisplayCapture, turn: 1),
              let stream = displayStream, let target = displayTexture, let pixels = stream.takeNewFrame() else { return }
        lastDisplayCapture = now
        captureCount += 1
        captureMegapixels += Double(CVPixelBufferGetWidth(pixels) * CVPixelBufferGetHeight(pixels)) / 1e6
        guard target.encodeUpdate(from: pixels, into: cb), let texture = target.texture else { return }
        if let bounds = display?.bounds {
            onFrameCaptured?(pixels, bounds, texture, nil, CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)))
        }
        for w in windows where !w.hasOwnPicture { w.layer.texture = texture }
        for p in popups { p.layer.texture = texture }
    }

    /// Points window `w`'s layer at its picture: its region of the virtual display's capture, until
    /// it has a capture of its own.
    private func setRegion(of w: MacWindow) {
        if w.hasOwnPicture {
            w.layer.aspect = Float(w.frame.height / w.frame.width)
            w.stream?.resize(width: Int(w.frame.width * 2), height: Int(w.frame.height * 2))
        } else {
            setRegion(of: w.layer, to: w.frame)
        }
    }

    /// Points a layer at the region of the virtual display covered by `frame`.
    private func setRegion(of layer: QuadLayer, to frame: CGRect) {
        guard let b = display?.bounds, b.width > 0, b.height > 0 else { return }
        layer.uvRect = SIMD4(Float((frame.minX - b.minX) / b.width), Float((frame.minY - b.minY) / b.height),
                             Float(frame.width / b.width), Float(frame.height / b.height))
        layer.aspect = Float(frame.height / frame.width)
        layer.textureWidthOverride = Float(frame.width * 2)
    }

    /// Theater mode: while a video plays, the windows (and their popups and panels) leave the scene
    /// and stop taking the pointer; they come back when it closes.
    var windowsHidden = false {
        didSet { if windowsHidden != oldValue { updateLayers() } }
    }

    /// Layers of the scene's content (e.g. a movie screen), drawn with the windows.
    var contentLayers: [QuadLayer] = [] {
        didSet { updateLayers() }
    }

    /// Extra layers drawn in front of everything (e.g. the window picker panel).
    var overlayLayers: [QuadLayer] = [] {
        didSet { updateLayers() }
    }

    /// Halliday's own UI (the dock): always shown, theater mode included, and first in the list so
    /// it is never the one left out when there are more layers than the renderer draws.
    var uiLayers: [QuadLayer] = [] {
        didSet { updateLayers() }
    }

    func updateLayers() {
        renderer.layers = uiLayers + (windowsHidden ? contentLayers
            : contentLayers + windows.filter { !$0.hidden }.map(\.layer) + popups.map(\.layer) + overlayLayers)
    }

    // --- The virtual display's backdrop ---

    /// A dark window of Halliday's own covering the virtual display's desktop, under every other
    /// window: when a window closes, moves or is still appearing, what shows in its place for a
    /// moment is this, not the Mac's wallpaper. Making it the key window also makes the virtual
    /// display the active one, which is where a newly launched app opens its window.
    private var backdrop: BackdropWindow?

    private func makeBackdrop(on bounds: CGRect) {
        let w = BackdropWindow(contentRect: appKitFrame(bounds), styleMask: .borderless, backing: .buffered, defer: false)
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        w.backgroundColor = NSColor(srgbRed: 0.035, green: 0.040, blue: 0.058, alpha: 1)
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.setFrame(appKitFrame(bounds), display: true)
        w.orderFront(nil)
        backdrop = w
    }

    /// Makes the virtual display the active one (see `backdrop`), e.g. right before launching an app.
    func focusVirtualDisplay() {
        guard let backdrop else { return }
        NSApp.activate()
        backdrop.makeKey()
    }

    /// Creates the virtual display if it doesn't exist yet. False if it can't be created.
    func prepareDisplay() async -> Bool { await windowArea() != nil }

    // --- Layout ---

    /// The area of the virtual display windows may use (below its menu bar), creating the display
    /// on first use. Nil if it can't be created.
    private func windowArea() async -> CGRect? {
        if display == nil {
            guard let d = VirtualDisplay() else {
                log("[windows] couldn't create the virtual display")
                return nil
            }
            guard await d.waitUntilOnline() else {
                log("[windows] the virtual display didn't come online")
                return nil
            }
            display = d
            log("[windows] virtual display \(d.displayID) at \(d.bounds), \(Int(d.actualRefreshRate)) Hz")
            makeBackdrop(on: d.bounds)
        }
        guard let b = display?.bounds else { return nil }
        let menuBar: CGFloat = 40, margin: CGFloat = 16
        return CGRect(x: b.minX + margin, y: b.minY + menuBar, width: b.width - 2 * margin, height: b.height - menuBar - margin)
    }

    /// Places windows of the given sizes in rows inside `area` without overlap, shrinking any that
    /// don't fit. Windows that don't fit at all go on top of the last row (rare: 8 windows max).
    private func layOut(_ sizes: [CGSize], in area: CGRect) -> [CGRect] {
        let gap: CGFloat = 16
        var x = area.minX, y = area.minY, rowHeight: CGFloat = 0
        return sizes.map { size in
            let w = min(size.width, area.width), h = min(size.height, area.height)
            if x + w > area.maxX { // next row
                x = area.minX
                y += rowHeight + gap
                rowHeight = 0
            }
            if y + h > area.maxY { y = area.maxY - h }
            let r = CGRect(x: x, y: y, width: w, height: h)
            x += w + gap
            rowHeight = max(rowHeight, h)
            return r
        }
    }

    // --- Placement (ROADMAP W12.E; the geometry is in Placement.swift) ---

    /// How far below eye level the middle of the arc sits, per meter of distance (about 2°).
    static let arcDrop: Float = 0.036
    /// Where the user's eyes are taken to be: the arc's center, raised back to eye level.
    var eye: SIMD3<Float> { center + SIMD3(0, Self.arcDrop * radius, 0) }
    /// Parts of the view kept free of windows and their bars (the dock's band).
    var reserved: [ReservedZone] = [] {
        didSet { if !windows.isEmpty { arrange() } }
    }
    /// Where the user is looking (world yaw): a new window appears there.
    var gazeYaw: Float = 0

    // --- Layouts (design board 11) ---

    /// How the windows that are not placed by hand are arranged.
    enum Layout: String, CaseIterable {
        case arc, side, focus, grid
        var label: String {
            switch self {
            case .arc: "Arc"
            case .side: "Side by side"
            case .focus: "Focus"
            case .grid: "Grid"
            }
        }
    }

    private(set) var layout = Layout.arc
    /// The window last used (clicked into): the large one in Focus and Side by side.
    var inUse: CGWindowID? {
        didSet {
            // The window in use comes forward where it overlaps another at about the same depth
            // (its menus stay in front of it).
            for w in windows { w.layer.sortBias = w.windowID == inUse ? 0.05 : 0 }
            guard inUse != oldValue, layout == .focus || layout == .side, let inUse, !mainWindows.contains(inUse) else { return }
            // After the click that made it the one in use has gone through.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.arrange() }
        }
    }
    /// The large windows of the current layout.
    private var mainWindows: [CGWindowID] = []
    /// Layouts chosen for sets of apps open together (kept between runs).
    private static let layoutsKey = "layoutsBySet"
    private var layoutSet = ""
    /// Remember the chosen layout for the set of apps open now (Settings).
    var remembersLayouts = true

    /// Chooses a layout (from the Windows panel); remembered for the apps open now if asked.
    func setLayout(_ l: Layout, remember: Bool = true) {
        layout = l
        if remember, remembersLayouts, !layoutSet.isEmpty {
            var all = UserDefaults.standard.dictionary(forKey: Self.layoutsKey) as? [String: String] ?? [:]
            all[layoutSet] = l.rawValue
            UserDefaults.standard.set(all, forKey: Self.layoutsKey)
        }
        arrange()
    }

    /// "Bring everything back to the arc": hand-placed windows rejoin it, and the layout is the arc.
    func bringAllToArc() {
        for w in windows where w.placement != nil { forgetPlacement(of: w) }
        setLayout(.arc)
    }

    /// The set of apps in VR changed: its remembered layout, if it has one, comes back.
    private func followLayoutSet() {
        let key = Set(windows.map(placementKey)).sorted().joined(separator: "|")
        guard key != layoutSet else { return }
        layoutSet = key
        if remembersLayouts, let saved = (UserDefaults.standard.dictionary(forKey: Self.layoutsKey) as? [String: String])?[key],
           let l = Layout(rawValue: saved) {
            layout = l
        }
    }

    /// The arc's first row as last laid out: where along the arc it starts and ends (m) and its top
    /// (m above the floor). For the places a dragged window can drop into.
    private(set) var arcRow: (min: Float, max: Float, top: Float)?

    /// Free places for window `windowID` while it is dragged (arc layout only): left and right of
    /// the arc's row, its middle, and above it. Poses on the arc, sized as the window.
    struct DropSlot {
        enum Kind { case left, middle, right, above }
        let kind: Kind
        let position: SIMD3<Float>
        let orientation: simd_quatf
        let width: Float, height: Float
    }

    func dropSlots(for windowID: CGWindowID) -> [DropSlot] {
        guard layout == .arc, let w = windows.first(where: { $0.windowID == windowID }) else { return [] }
        let width = Float(w.frame.width) * metersPerPoint, height = width * Float(w.frame.height / max(w.frame.width, 1))
        let gap: Float = 0.08, bar = NightGlass.meters(ViewGeometry.barRoom, at: Self.referenceDistance)
        func slot(_ kind: DropSlot.Kind, along a: Float, y: Float, nearer: Float = 0) -> DropSlot {
            let yaw = heading - a / radius
            let turn = simd_quatf(angle: yaw, axis: [0, 1, 0])
            let lean = abs(y - eye.y) > 0.3 ? turn * simd_quatf(angle: atan2(y - eye.y, radius), axis: [1, 0, 0]) : turn
            return DropSlot(kind: kind, position: SIMD3(center.x, y, center.z) + turn.act(SIMD3(0, 0, -(radius - nearer))),
                            orientation: lean, width: width, height: height)
        }
        var y = center.y
        if let top = ViewGeometry.floor(yaw: heading, halfYaw: atan(width / 2 / radius), zones: reserved) {
            y += max(0, eye.y + tan(top) * radius + bar - (y - height / 2))
        }
        guard let row = arcRow else { return [slot(.middle, along: 0, y: y)] }
        return [slot(.left, along: row.min - gap - width / 2, y: y), slot(.middle, along: (row.min + row.max) / 2, y: y, nearer: 0.06),
                slot(.right, along: row.max + gap + width / 2, y: y), slot(.above, along: (row.min + row.max) / 2, y: row.top + 0.10 + bar + height / 2)]
    }

    /// A dragged window let go over a free place in the arc: it joins the arc there.
    func joinArc(_ windowID: CGWindowID, at kind: DropSlot.Kind) {
        guard let w = windows.first(where: { $0.windowID == windowID }) else { return }
        forgetPlacement(of: w)
        arcOrder.removeAll { $0 == windowID }
        let others = arcOrder.count
        arcOrder.insert(windowID, at: kind == .left ? 0 : kind == .right ? others : others / 2)
        arrange()
    }

    /// The window rejoins the arc and its remembered place is forgotten.
    private func forgetPlacement(of w: MacWindow) {
        var all = UserDefaults.standard.dictionary(forKey: Self.placementsKey) as? [String: [Double]] ?? [:]
        all[placementKey(w)] = nil
        UserDefaults.standard.set(all, forKey: Self.placementsKey)
        w.placement = nil
    }

    /// Rows (bottom first) and sizes of the windows not placed by hand, for a layout other than the
    /// arc: the large ones in front, the others in a row of small ones above.
    private func layoutRows(_ ordered: [MacWindow]) -> [[MacWindow]] {
        func scale(_ w: MacWindow, toWidth target: Float, maxHeight: Float) {
            let width = Float(w.frame.width) * metersPerPoint, aspect = Float(w.frame.height / max(w.frame.width, 1))
            w.layoutScale = max(0.3, min(2.5, min(target, maxHeight / max(aspect, 0.1)) / max(width, 0.01)))
        }
        let r = radius
        let primary = ordered.first { $0.windowID == inUse } ?? ordered[ordered.count / 2]
        var main: [MacWindow]
        switch layout {
        case .focus:
            main = [primary]
            scale(primary, toWidth: 1.1 * r, maxHeight: 0.62 * r)
        case .side:
            let i = ordered.firstIndex { $0 === primary } ?? 0
            let other = i + 1 < ordered.count ? ordered[i + 1] : (i > 0 ? ordered[i - 1] : nil)
            main = other.map { i + 1 < ordered.count ? [primary, $0] : [$0, primary] } ?? [primary]
            for w in main { scale(w, toWidth: 0.7 * r, maxHeight: 0.6 * r) }
        case .grid:
            for w in ordered { scale(w, toWidth: 0.58 * r, maxHeight: 0.4 * r) }
            mainWindows = ordered.map(\.windowID)
            // Rows of two, the first ones on top.
            return stride(from: 0, to: ordered.count, by: 2).map { Array(ordered[$0..<min($0 + 2, ordered.count)]) }.reversed()
        case .arc:
            return [ordered]
        }
        mainWindows = main.map(\.windowID)
        let small = ordered.filter { w in !main.contains { $0 === w } }
        for w in small { scale(w, toWidth: 0.3 * r, maxHeight: 0.2 * r) }
        return small.isEmpty ? [main] : [main, small]
    }
    /// The arc's windows from left to right, and where each one's middle is along the arc (meters,
    /// right positive).
    private var arcOrder: [CGWindowID] = []
    private var arcSlots: [CGWindowID: Float] = [:]
    /// The widest a row of the arc gets (radians): beyond it, windows go to a row above.
    private static let maxRowSpan: Float = 3.5

    /// Meters under window `w` taken by its bar.
    private func barRoom(_ w: MacWindow) -> Float {
        NightGlass.meters(ViewGeometry.barRoom, at: Self.referenceDistance * (w.placement?.scale ?? 1))
    }

    /// A world direction as a distance along the arc from its middle (meters, right positive).
    private func along(_ yaw: Float) -> Float { -ViewGeometry.wrap(yaw - heading) * radius }

    /// Lays the windows out: hand-placed ones stay where they are; the rest sit side by side on an
    /// arc facing the center, in rows when one row would wrap around the user, leaving room around
    /// hand-placed windows at the arc's distance and keeping clear of the dock's band. A window new
    /// to the arc goes in beside the window that opened it, or where the user is looking.
    func arrange() {
        // Windows whose place changes glide to it (the one being dragged follows the hand: `place`).
        // (Their size too: a layout makes windows larger or smaller.)
        let before = windows.map { (was: $0.layer.target, drawn: $0.layer.rendered, width: $0.layer.renderedWidth) }
        defer {
            for (w, b) in zip(windows, before) { w.layer.settle(was: b.was, drawn: b.drawn, pivot: center, drawnWidth: b.width) }
        }
        let gap: Float = 0.08
        // Hand-placed windows stay; the ones about as far as the arc are in its way.
        var obstacles: [(min: Float, max: Float, bottom: Float, top: Float)] = []
        for w in windows {
            guard let p = w.placement else { continue }
            w.layer.position = p.position
            w.layer.orientation = p.orientation
            w.layer.width = Float(w.frame.width) * metersPerPoint * p.scale
            let v = p.position - center
            let distance = max(simd_length(SIMD2(v.x, v.z)), 0.1)
            guard abs(distance - radius) < 0.35 else { continue }
            let a = along(ViewGeometry.yaw(of: v)), half = w.layer.width / 2 * radius / distance
            obstacles.append((a - half - gap, a + half + gap, p.position.y - w.layer.height / 2 - barRoom(w), p.position.y + w.layer.height / 2))
        }
        followLayoutSet()
        let arc = windows.filter { $0.placement == nil }
        // Left-to-right order: windows that left the arc are forgotten, new ones go in where asked.
        arcOrder.removeAll { id in !arc.contains { $0.windowID == id } }
        for w in arc where !arcOrder.contains(w.windowID) {
            let target = along(w.arcHint ?? ViewGeometry.yaw(of: w.layer.position - center))
            w.arcHint = nil
            arcOrder.insert(w.windowID, at: arcOrder.filter { (arcSlots[$0] ?? 0) < target }.count)
        }
        arcSlots = [:]
        arcRow = nil
        let ordered = arcOrder.compactMap { id in arc.first { $0.windowID == id } }
        guard !ordered.isEmpty else { return }
        // The layout decides each window's size in VR and the rows (bottom first).
        for w in ordered { w.layoutScale = 1 }
        mainWindows = []
        var rows = layout == .arc ? [ordered] : layoutRows(ordered)
        for w in ordered { w.layer.width = Float(w.frame.width) * metersPerPoint * w.layoutScale }
        // Rows: a row too wide to stay in front of the user sends its outermost windows up a row.
        func span(_ row: [MacWindow]) -> Float { row.map(\.layer.width).reduce(0, +) + gap * Float(max(row.count - 1, 0)) }
        while layout == .arc, var row = rows.last, row.count > 1, span(row) > Self.maxRowSpan * radius {
            var left: [MacWindow] = [], right: [MacWindow] = []
            while row.count > 1, span(row) > Self.maxRowSpan * radius {
                if right.count <= left.count { right.insert(row.removeLast(), at: 0) } else { left.append(row.removeFirst()) }
            }
            rows[rows.count - 1] = row
            rows.append(left + right)
        }
        let eyeY = eye.y
        var baseline = center.y
        for (r, row) in rows.enumerated() {
            var x = -span(row) / 2
            var rowTop = -Float.infinity
            for w in row {
                let width = w.layer.width, height = w.layer.height, bar = barRoom(w)
                // The first row keeps clear of hand-placed windows at its height.
                if r == 0 {
                    for _ in 0..<obstacles.count {
                        guard let o = obstacles.first(where: {
                            x < $0.max && x + width > $0.min && center.y - height / 2 - bar < $0.top && center.y + height / 2 > $0.bottom
                        }) else { break }
                        x = o.max
                    }
                }
                let a = x + width / 2
                let yaw = heading - a / radius
                var y = center.y
                if r == 0 {
                    // Above the dock's band, with its bar.
                    if let top = ViewGeometry.floor(yaw: yaw, halfYaw: atan(width / 2 / radius), zones: reserved) {
                        y += max(0, eyeY + tan(top) * radius + bar - (y - height / 2))
                    }
                } else {
                    y = baseline + bar + height / 2
                }
                rowTop = max(rowTop, y + height / 2)
                // Upper rows lean toward the user.
                let turn = simd_quatf(angle: yaw, axis: [0, 1, 0])
                w.layer.orientation = r == 0 ? turn : turn * simd_quatf(angle: atan2(y - eyeY, radius), axis: [1, 0, 0])
                w.layer.position = SIMD3(center.x, y, center.z) + turn.act(SIMD3(0, 0, -radius))
                arcSlots[w.windowID] = a
                x += width + gap
            }
            if r == 0, let first = row.first, let last = row.last, let a = arcSlots[first.windowID], let b = arcSlots[last.windowID] {
                arcRow = (a - first.layer.width / 2, b + last.layer.width / 2, rowTop)
            }
            baseline = rowTop + 0.10
        }
    }

    /// Just to the right of the newest other window of `w`'s app (world yaw), if it has one in VR:
    /// a window an app opens appears beside the one it came from.
    private func siblingYaw(of w: MacWindow) -> Float? {
        guard w.own == nil, let sibling = windows.last(where: { $0 !== w && $0.pid == w.pid }) else { return nil }
        return ViewGeometry.yaw(of: sibling.layer.position - center) - 0.01
    }

    /// The lowest pitch the middle of a window `width` × `height` meters may have when held `distance`
    /// meters away in direction `yaw`, so that it and its bar stay above the dock's band.
    func lowestPitch(yaw: Float, width: Float, height: Float, distance: Float, scale: Float) -> Float {
        guard let top = ViewGeometry.floor(yaw: yaw, halfYaw: atan(width / 2 / distance), zones: reserved) else { return -1.2 }
        let bar = NightGlass.meters(ViewGeometry.barRoom, at: Self.referenceDistance * scale)
        return min(1.0, top + atan((height / 2 + bar) / distance))
    }

    /// A dragged window was let go, seen from `viewer`: if it landed on another hand-placed window
    /// at about the same distance, it settles beside it; then the arc makes room around it.
    func settleDrop(_ windowID: CGWindowID, viewer: SIMD3<Float>) {
        guard let w = windows.first(where: { $0.windowID == windowID }), var p = w.placement else { return }
        let was = w.layer.target, drawn = w.layer.rendered
        var rect = ViewRect(position: p.position, width: w.layer.width, height: w.layer.height + barRoom(w), from: viewer)
        let others = windows.filter { $0 !== w && $0.placement != nil && !$0.hidden }
            .map { ViewRect(position: $0.layer.position, width: $0.layer.width, height: $0.layer.height + barRoom($0), from: viewer) }
        var moved = false
        for _ in 0..<4 {
            guard let o = others.first(where: { $0.overlaps(rect, margin: 0.02) && abs($0.distance - rect.distance) < 0.35 }) else { break }
            let left = o.yaw + o.halfYaw + rect.halfYaw + 0.05, right = o.yaw - o.halfYaw - rect.halfYaw - 0.05
            rect.yaw = abs(ViewGeometry.wrap(left - rect.yaw)) < abs(ViewGeometry.wrap(right - rect.yaw)) ? left : right
            moved = true
        }
        if moved {
            // Its middle keeps its height and distance; only the direction changes.
            let v = p.position - viewer
            let pitch = asin(max(-1, min(1, v.y / max(simd_length(v), 0.05))))
            p.orientation = simd_quatf(angle: rect.yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            p.position = viewer + p.orientation.act(SIMD3(0, 0, -simd_length(v)))
            w.placement = p
        }
        arrange()
        if moved { w.layer.settle(was: was, drawn: drawn, pivot: viewer) }
    }

    /// Puts window `windowID` where the user dragged it.
    func place(_ windowID: CGWindowID, position: SIMD3<Float>, orientation: simd_quatf, scale: Float) {
        guard let w = windows.first(where: { $0.windowID == windowID }) else { return }
        let wasInArc = w.placement == nil
        w.placement = MacWindow.Placement(position: position, orientation: orientation, scale: scale)
        w.layer.position = position
        w.layer.orientation = orientation
        w.layer.width = Float(w.frame.width) * metersPerPoint * scale
        if wasInArc { arrange() } // the others close the gap it left
        w.layer.glide = nil // in the hand: it follows 1:1
    }

    /// Moves the arc: its center, the direction it faces (yaw) and its distance. Windows in the arc
    /// are rearranged; hand-placed ones change distance with it, and `carry` also moves them along
    /// with the change of center and yaw.
    func anchor(center newCenter: SIMD3<Float>, yaw newYaw: Float, radius newRadius: Float, carry: Bool) {
        let turn = simd_quatf(angle: newYaw - heading, axis: [0, 1, 0])
        let grow = newRadius / radius
        for w in windows {
            guard var p = w.placement else { continue }
            // Hand-placed windows follow: turned and moved with the arc when carried, and pushed
            // away or pulled in by the same factor as the arc.
            let offset = (p.position - center) * grow
            p.position = newCenter + (carry ? turn.act(offset) : offset)
            if carry { p.orientation = turn * p.orientation }
            w.placement = p
        }
        center = newCenter
        heading = newYaw
        radius = newRadius // panels keep their size in meters: farther away they look smaller
        arrange()
    }

    // --- Resizing from VR ---

    /// Resizes the real window `windowID` (the app may round or refuse sizes of its own). The
    /// picture in VR follows at the next refresh. Call `settleLayout` when the resize ends.
    func resize(_ windowID: CGWindowID, to size: CGSize) {
        guard let w = windows.first(where: { $0.windowID == windowID }), let area = windowAreaNow() else { return }
        let width = max(360, min(area.width, size.width.rounded())), height = max(240, min(area.height, size.height.rounded()))
        guard abs(width - w.frame.width) >= 2 || abs(height - w.frame.height) >= 2 else { return }
        // It stays inside the virtual display: if it would stick out, it moves up and left.
        let origin = CGPoint(x: max(area.minX, min(w.frame.minX, area.maxX - width)), y: max(area.minY, min(w.frame.minY, area.maxY - height)))
        w.move(to: CGRect(origin: origin, size: CGSize(width: width, height: height)))
    }

    /// Brings window `windowID` in front of the others on the virtual display (while it is being
    /// resized it may overlap its neighbours there).
    func raiseOnDisplay(_ windowID: CGWindowID) {
        guard let w = windows.first(where: { $0.windowID == windowID }) else { return }
        if let own = w.own { own.orderFront(nil) } else { w.ax?.raise() }
    }

    /// Lays the windows out again on the virtual display so none overlaps (after a resize).
    func settleLayout() {
        guard let area = windowAreaNow() else { return }
        let placements = layOut(windows.map(\.frame.size), in: area)
        for (w, place) in zip(windows, placements) where abs(w.frame.minX - place.minX) > 1 || abs(w.frame.minY - place.minY) > 1 {
            w.move(to: place)
        }
    }

    // --- Remembered placements ---
    // Where the user put an app's window is kept between runs, relative to the arc (so it follows
    // recentering): offset and orientation in the arc's frame, and scale. Keyed by app.

    private static let placementsKey = "windowPlacements"

    private func placementKey(_ w: MacWindow) -> String {
        w.own != nil ? "halliday.\(w.appName.lowercased())"
            : NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? w.appName
    }

    /// Saves where window `windowID` was placed by hand.
    func rememberPlacement(of windowID: CGWindowID) {
        guard let w = windows.first(where: { $0.windowID == windowID }), let p = w.placement else { return }
        let toArc = simd_quatf(angle: -heading, axis: [0, 1, 0])
        let offset = toArc.act(p.position - center), q = (toArc * p.orientation).vector
        var all = UserDefaults.standard.dictionary(forKey: Self.placementsKey) as? [String: [Double]] ?? [:]
        all[placementKey(w)] = [offset.x, offset.y, offset.z, q.x, q.y, q.z, q.w, p.scale].map(Double.init)
        UserDefaults.standard.set(all, forKey: Self.placementsKey)
    }

    /// Puts a window that just came into VR where its app's window was last placed, if anywhere.
    /// Only the first window of an app takes the remembered place.
    private func restorePlacement(of w: MacWindow) {
        guard w.placement == nil, !windows.contains(where: { $0 !== w && $0.pid == w.pid && $0.placement != nil }),
              let v = (UserDefaults.standard.dictionary(forKey: Self.placementsKey) as? [String: [Double]])?[placementKey(w)],
              v.count == 8 else { return }
        let fromArc = simd_quatf(angle: heading, axis: [0, 1, 0])
        let f = v.map { Float($0) }
        let position = center + fromArc.act(SIMD3(f[0], f[1], f[2]))
        // A remembered place that another window has taken, or that reaches into the dock's band:
        // the window joins the arc in that direction instead.
        let width = Float(w.frame.width) * metersPerPoint * f[7], height = width * Float(w.frame.height / max(w.frame.width, 1))
        let bar = NightGlass.meters(ViewGeometry.barRoom, at: Self.referenceDistance * f[7])
        let rect = ViewRect(position: position, width: width, height: height + bar, from: eye)
        let taken = windows.contains { o in
            o !== w && o.placement != nil
                && ViewRect(position: o.layer.position, width: o.layer.width, height: o.layer.height + barRoom(o), from: eye).overlaps(rect, margin: 0.02)
        }
        let low = ViewGeometry.floor(yaw: rect.yaw, halfYaw: rect.halfYaw, zones: reserved).map { rect.pitch - rect.halfPitch < $0 - 0.02 } ?? false
        guard !taken, !low else {
            w.arcHint = rect.yaw
            return
        }
        w.placement = MacWindow.Placement(position: position,
                                          orientation: fromArc * simd_quatf(vector: SIMD4(f[3], f[4], f[5], f[6])), scale: f[7])
    }

    /// Sends a hand-placed window back to the arc and forgets its place.
    func returnToArc(_ windowID: CGWindowID) {
        guard let w = windows.first(where: { $0.windowID == windowID }), w.placement != nil else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.placementsKey) as? [String: [Double]] ?? [:]
        all[placementKey(w)] = nil
        UserDefaults.standard.set(all, forKey: Self.placementsKey)
        w.placement = nil
        w.layer.width = Float(w.frame.width) * metersPerPoint
        arrange()
    }

    /// The distance at which Night Glass sizes (dmm) are true for window `windowID`'s own bars: they
    /// are sized for the default panel distance and then keep their size in meters with the window,
    /// so the tab bar always matches the page's width.
    func nominalDistance(of windowID: CGWindowID) -> Float {
        windows.first { $0.windowID == windowID }.map { Self.referenceDistance * ($0.placement?.scale ?? $0.layoutScale) } ?? Self.referenceDistance
    }

    // --- Following the real windows ---

    /// Re-reads where the VR windows are on the virtual display (they may move or resize) and finds
    /// the menus, popovers and dialogs their apps have open there. Call often (~15 Hz): it only
    /// asks the window server.
    func refresh() {
        guard let displayBounds = display?.bounds, !windows.isEmpty || !popups.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let mainIDs = Set(windows.map(\.windowID))
        let pids = Set(windows.map(\.pid))
        var found: [(id: CGWindowID, pid: pid_t, frame: CGRect)] = []
        var seen: Set<CGWindowID> = []
        var normalWindows = 0
        // Apps that just came into VR: the windows they already have stay where they are; only
        // windows they open from now on follow them into VR.
        let fresh = pids.subtracting(followed)
        followed = pids
        for w in info {
            if (w[kCGWindowLayer as String] as? Int) == 0 { normalWindows += 1 }
            if let id = w[kCGWindowNumber as String] as? CGWindowID, let pid = w[kCGWindowOwnerPID as String] as? pid_t,
               fresh.contains(pid) { known.insert(id) }
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            if mainIDs.contains(id) {
                seen.insert(id)
                if let mw = windows.first(where: { $0.windowID == id }), mw.frame != r {
                    mw.frame = r
                    setRegion(of: mw)
                    updatePatch(mw)
                    mw.layer.width = Float(r.width) * metersPerPoint * (mw.placement?.scale ?? mw.layoutScale)
                }
                continue
            }
            guard pids.contains(pid), r.width >= 4, r.height >= 4, (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  Int(id) != backdrop?.windowNumber else { continue }
            // macOS's recording badge: a small window of the app on a VR window's top-left corner.
            if let parent = windows.first(where: { $0.pid == pid && Self.isCaptureBadge(r, on: $0.frame) }) {
                let badge = CGRect(x: r.minX - parent.frame.minX, y: r.minY - parent.frame.minY, width: r.width, height: r.height)
                if parent.badge != badge {
                    if parent.badge == nil { log("[windows] \(parent.appName): macOS's recording badge found at \(badge); covered in VR") }
                    parent.badge = badge
                    updatePatch(parent)
                }
                continue
            }
            // A window the app opened on one of the Mac's own displays after coming into VR (a new
            // document, a dialog): an ordinary window joins the others in VR, a dialog is moved over
            // its app's VR window. Either way it must not be left where the user can't see it.
            if !displayBounds.intersects(r) {
                if (w[kCGWindowLayer as String] as? Int) == 0, r.width >= 200, r.height >= 100, pid != ProcessInfo.processInfo.processIdentifier,
                   known.insert(id).inserted {
                    follow(id: id, pid: pid, frame: r, title: w[kCGWindowName as String] as? String ?? "")
                }
                continue
            }
            // Another window of a VR window's app, on the virtual display: a menu, popover,
            // tooltip, sheet or dialog. (Front-to-back order is kept from the window list.)
            // A new ordinary window of an app that is in VR (a second document, a new browser
            // window) becomes a VR window of its own; anything else is a popup of its parent.
            if (w[kCGWindowLayer as String] as? Int) == 0, r.width >= 360, r.height >= 240, adoptIfStandard(id: id, pid: pid, frame: r,
                                                                                                   title: w[kCGWindowName as String] as? String ?? "") {
                continue
            }
            found.append((id, pid, r))
        }
        dropMissing(seen: seen, listLooksSane: normalWindows > 0)
        updateOwnCaptures()

        var updated: [PopupWindow] = []
        for (rank, f) in found.reversed().enumerated() {
            let popup = popups.first { $0.windowID == f.id }
                ?? PopupWindow(windowID: f.id, pid: f.pid,
                               layer: QuadLayer(texture: displayTexture?.texture ?? renderer.placeholderTexture,
                                                position: center, width: 0.1),
                               frame: f.frame)
            popup.frame = f.frame
            place(popup, rank: rank)
            updated.append(popup)
        }
        let changed = updated.map(\.windowID) != popups.map(\.windowID)
        popups = updated
        if changed { updateLayers() }
    }

    // --- Windows that come and go by themselves ---

    /// Refreshes in a row each VR window has been missing from the on-screen list.
    private var missing: [CGWindowID: Int] = [:]
    /// Windows already judged not to be standard windows (sheets, dialogs…): not asked again.
    private var notStandard: Set<CGWindowID> = []

    /// A VR window that has been off screen for about a second was closed or minimized, or its app
    /// quit: it leaves VR (a stale picture of it would otherwise stay). Skipped while the Mac's
    /// displays are asleep or the window list is empty, which would look the same.
    private func dropMissing(seen: Set<CGWindowID>, listLooksSane: Bool) {
        guard listLooksSane, CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            missing = [:]
            return
        }
        var visibilityChanged = false
        for w in windows {
            if seen.contains(w.windowID) { missing[w.windowID] = nil } else { missing[w.windowID, default: 0] += 1 }
            // A window that is not on screen is not drawn, from the first refresh that misses it:
            // its place on the virtual display would show whatever is behind it.
            let hide = !seen.contains(w.windowID)
            if hide != w.hidden {
                w.hidden = hide
                visibilityChanged = true
            }
        }
        if visibilityChanged { updateLayers() }
        let absent = windows.filter { (missing[$0.windowID] ?? 0) >= 15 }
        guard !absent.isEmpty else { return }
        var left = false
        for w in absent {
            missing[w.windowID] = 0 // looked at again in a second if it stays
            // Off screen is not enough: an app that is hidden, or a Space change, hides windows that
            // are still there. Only a window that no longer exists, or was minimized, leaves VR.
            let exists = (CGWindowListCopyWindowInfo([.optionIncludingWindow], w.windowID) as? [[String: Any]])?.isEmpty == false
            let minimized = exists && w.own == nil && w.ax?.isMinimized == true
            guard !exists || minimized else { continue }
            missing[w.windowID] = nil
            windows.removeAll { $0.windowID == w.windowID }
            w.stopCapture()
            // Minimized: it goes back to where it was on the desktop, for when it is restored.
            if minimized { w.ax?.setFrame(w.originalFrame) }
            ledger.remove(windowID: w.windowID)
            popups.removeAll { p in p.pid == w.pid && !windows.contains { $0.pid == w.pid } }
            if w.own == nil { notify("\(w.appName) left VR: its window was \(minimized ? "minimized" : "closed")") }
            onWindowLeft?(w.windowID)
            left = true
        }
        guard left else { return }
        arrange()
        updateLayers()
    }

    /// Apps with a window in VR whose new windows are followed, and the windows of theirs that are
    /// already known (they existed before, were sent back, or were dealt with).
    private var followed: Set<pid_t> = []
    private var known: Set<CGWindowID> = []

    /// True for the badge macOS puts over a captured window's title-bar buttons (66 × 20 points at
    /// its top-left corner, on macOS 26): small, and right at the corner.
    static func isCaptureBadge(_ r: CGRect, on frame: CGRect) -> Bool {
        r.width <= 100 && r.height <= 32 && abs(r.minX - frame.minX) <= 16 && abs(r.minY - frame.minY) <= 16
    }

    /// A window a VR app opened on one of the Mac's displays: brings it into VR.
    private func follow(id: CGWindowID, pid: pid_t, frame: CGRect, title: String) {
        guard let parent = windows.first(where: { $0.pid == pid }) else { return }
        if adoptIfStandard(id: id, pid: pid, frame: frame, title: title) { return }
        // Not an ordinary window (a dialog, a panel): put it over the app's VR window, where the
        // popup handling shows it.
        guard let ax = AXWindow.find(pid: pid, windowID: id, frame: frame) else { return }
        let target = CGRect(x: parent.frame.midX - frame.width / 2, y: parent.frame.midY - frame.height / 2, width: frame.width, height: frame.height)
        if ax.setFrame(target) { log("[windows] \(parent.appName): a dialog was moved into VR") }
    }

    /// If window `id` (already on the virtual display, of an app in VR) is an ordinary window, makes
    /// it a VR window of its own, next to the others. False if it is not one (a sheet, a dialog).
    private func adoptIfStandard(id: CGWindowID, pid: pid_t, frame: CGRect, title: String) -> Bool {
        guard !notStandard.contains(id), windows.count < maxWindows, let area = windowAreaNow() else { return false }
        guard let ax = AXWindow.find(pid: pid, windowID: id, frame: frame), ax.isStandardWindow else {
            notStandard.insert(id)
            return false
        }
        guard let parent = windows.first(where: { $0.pid == pid }) else { return false }
        let onVirtualDisplay = display?.bounds.intersects(frame) == true
        let placements = layOut(windows.map(\.frame.size) + [frame.size], in: area)
        guard let target = placements.last, ax.setFrame(target), let placed = ax.frame else {
            notStandard.insert(id)
            return false
        }
        // If it leaves VR it goes back to where it opened, or (opened on the virtual display) next to
        // where its app's first window came from.
        let home = onVirtualDisplay ? parent.originalFrame.offsetBy(dx: 30, dy: 30) : frame
        ledger.record(MovedWindow(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, appName: parent.appName,
                                  windowID: id, title: title, x: home.minX, y: home.minY, width: frame.width, height: frame.height))
        let layer = QuadLayer(texture: displayTexture?.texture ?? renderer.placeholderTexture, position: center,
                              width: Float(placed.width) * metersPerPoint)
        let mw = MacWindow(windowID: id, pid: pid, appName: parent.appName, title: title, layer: layer, frame: placed,
                           originalFrame: CGRect(origin: home.origin, size: frame.size), ax: ax)
        setRegion(of: layer, to: placed)
        layer.cornerPixels = Self.windowCornerPixels
        mw.layer.appear() // it fades in
        mw.layer.castsShadow = true
        windows.append(mw)
        mw.arcHint = siblingYaw(of: mw) ?? gazeYaw
        restorePlacement(of: mw)
        mw.updateBlockedArea()
        popups.removeAll { $0.windowID == id }
        notify("\(parent.appName) opened a new window: it joined the others in VR")
        arrange()
        updateLayers()
        return true
    }

    /// The area of the virtual display windows may use, if the display exists.
    private func windowAreaNow() -> CGRect? {
        guard let b = display?.bounds else { return nil }
        let menuBar: CGFloat = 40, margin: CGFloat = 16
        return CGRect(x: b.minX + margin, y: b.minY + menuBar, width: b.width - 2 * margin, height: b.height - menuBar - margin)
    }

    /// Puts a popup's layer on its parent's plane, at the spot matching its position on the
    /// virtual display, slightly in front (higher `rank` = closer to the viewer).
    private func place(_ popup: PopupWindow, rank: Int) {
        let c = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
        let candidates = windows.filter { $0.pid == popup.pid }
        guard let parent = (candidates.isEmpty ? windows : candidates).min(by: {
            hypot($0.frame.midX - c.x, $0.frame.midY - c.y) < hypot($1.frame.midX - c.x, $1.frame.midY - c.y)
        }) else { return }
        // Scaled as its window is (by a placement or the layout), so it stays on the same spot of it.
        let m = metersPerPoint * (parent.placement?.scale ?? parent.layoutScale)
        let offset = SIMD3<Float>(Float(c.x - parent.frame.midX) * m, -Float(c.y - parent.frame.midY) * m,
                                  0.004 + 0.002 * Float(rank))
        popup.layer.sortBias = parent.windowID == inUse ? 0.06 : 0
        popup.layer.orientation = parent.layer.orientation
        popup.layer.position = parent.layer.position + parent.layer.orientation.act(offset)
        popup.layer.width = Float(popup.frame.width) * m
        popup.layer.travel(with: parent.layer)
        setRegion(of: popup.layer, to: popup.frame)
    }

    /// The windows and popups as published to the input thread each frame.
    var snapshots: [WindowSnapshot] {
        if windowsHidden { return [] }
        return windows.map { w in
            WindowSnapshot(windowID: w.windowID, pid: w.pid, frame: w.frame, position: w.layer.position,
                           orientation: w.layer.orientation, width: w.layer.width, height: w.layer.height, isPopup: false,
                           blocked: w.blockedArea)
        } + popups.map { p in
            WindowSnapshot(windowID: p.windowID, pid: p.pid, frame: p.frame, position: p.layer.position,
                           orientation: p.layer.orientation, width: p.layer.width, height: p.layer.height, isPopup: true)
        }
    }

    /// The layer showing window or popup `windowID`.
    func layer(for windowID: CGWindowID) -> QuadLayer? {
        windows.first { $0.windowID == windowID }?.layer ?? popups.first { $0.windowID == windowID }?.layer
    }

    /// True when Halliday may move windows and redirect input; asks for Accessibility if not.
    func checkInputPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            log("[input] grant Accessibility to Halliday (System Settings → Privacy & Security), then retry")
            Permissions.shared.request(.accessibility)
        }
        return trusted
    }

    /// The virtual display's id, while it exists.
    var virtualDisplayID: CGDirectDisplayID? { display?.displayID }

    /// The virtual display's rectangle, while it exists.
    var virtualDisplayBounds: CGRect? { display?.bounds }

    private func frontToBackWindowIDs() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var order: [CGWindowID: Int] = [:]
        for (i, w) in info.enumerated() {
            if let id = w[kCGWindowNumber as String] as? CGWindowID { order[id] = i }
        }
        return order
    }
}
