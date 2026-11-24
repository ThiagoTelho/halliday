// While the user interacts with a VR window (from clicking it until leaving), Halliday takes over
// the real mouse through a system event tap:
//
// - Mouse motion moves the VR pointer.
// - Over a VR window, each real event is redirected to the matching point on the real window and
//   passed on, so the app gets genuine mouse input (hover, clicks, drags, scrolling, activation)
//   and, once active, the keyboard too.
// - Over empty space, events are swallowed; a click there ends the interaction.
// - Right-click over a window is a real right-click (context menus); right-drag on empty space
//   looks around (mouse pose source).
// - Leave from anywhere: Control twice, Option+Esc, or a click on empty space.
//
// Safety rules, because every mouse and keyboard event on the Mac waits for this tap while it is on:
// - The tap runs on its own thread and only does math on InputState. It never waits for the main
//   thread (rendering) or for other apps (Accessibility calls run on a background queue with a
//   short timeout).
// - A watchdog turns the tap off if Halliday's frames stop for more than a second, or if macOS
//   disables the tap for being slow. Input then goes straight back to normal.
// - Leaving puts the real cursor back on the main display, never on the invisible virtual one.

import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics

@MainActor
protocol MouseOwnerDelegate: AnyObject {
    /// Looks around by raw mouse deltas (right-drag).
    func look(dx: Double, dy: Double)
    /// Ownership ended (from the tap thread: Control twice, Option+Esc, empty-space click, watchdog).
    func mouseOwnershipChanged(_ owned: Bool)
    /// The interaction ended with a click outside every window (called after the above).
    func clickedOutsideWindows()
    /// While a window is in use, the button went down / up on one of Halliday's own panels (a
    /// window's bar, the dock…): the panel takes it and the window stays in use.
    func panelPress()
    func panelRelease()
    /// The button went down on a window (it is the one in use now).
    func pressedWindow(_ id: CGWindowID)
    /// Scrolling while a panel is held (distance of a dragged window).
    func panelScroll(dy: Double)
    /// A click on a window's full-screen button was stopped.
    func blockedClick()
}

final class MouseOwner: @unchecked Sendable {
    /// Only touched on the main thread.
    nonisolated(unsafe) weak var delegate: MouseOwnerDelegate?

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var thread: Thread?
    private var on = false
    /// The window a left button press went to; drags and the release stay with it.
    private var pressedWindow: CGWindowID?
    /// Same for the right button (context menus).
    private var pressedRightWindow: CGWindowID?
    /// The left button is down on one of Halliday's panels.
    private var panelPressed = false
    /// A press held back while its window is raised.
    private var pendingDown = false
    private var lastControlTap: CFTimeInterval = 0
    private let axQueue = DispatchQueue(label: "halliday.ax", qos: .userInitiated)

    /// Marks events Halliday posts itself, so the tap lets them through untouched.
    static let ownEventMarker: Int64 = 0x4841_4C4C // "HALL"

    var isOn: Bool {
        lock.lock(); defer { lock.unlock() }
        return on
    }

    /// The visible Mac display, even when the physical headset is macOS's main
    /// display. Safe on the event-tap thread: only CoreGraphics display queries.
    static var desktopParkingPoint: CGPoint {
        let main = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        func headset(_ id: CGDirectDisplayID) -> Bool {
            guard CGDisplayVendorNumber(id) == 0x4dd9, let mode = CGDisplayCopyDisplayMode(id) else { return false }
            return mode.pixelWidth == 4000 && mode.pixelHeight == 2040
        }
        let display = !headset(main) ? main
            : (displays.first { CGDisplayIsBuiltin($0) != 0 }
                ?? displays.first { !headset($0) } ?? main)
        let b = CGDisplayBounds(display)
        return CGPoint(x: b.midX, y: b.midY)
    }

    private var parkPoint: CGPoint { Self.desktopParkingPoint }

    /// Starts owning the mouse. Needs the Accessibility permission.
    func start() -> Bool {
        guard ensureTap() else { return false }
        lock.lock()
        on = true
        pressedWindow = nil
        pendingDown = false
        lastControlTap = 0
        let tap = self.tap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("[mouse] interacting with windows (Control twice, Option+Esc or a click on empty space leaves)")
        return true
    }

    /// Stops owning the mouse and puts the cursor back on the main display. Safe from any thread.
    func stop(reason: String) {
        lock.lock()
        guard on else { lock.unlock(); return }
        on = false
        pressedWindow = nil
        let tap = self.tap
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        CGWarpMouseCursorPosition(parkPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        log("[mouse] back to Halliday (\(reason))")
    }

    /// Stops and tells the delegate (used from the tap thread).
    private func leave(reason: String) {
        stop(reason: reason)
        let byClick = reason == "click on empty space"
        Task { @MainActor [weak self] in
            self?.delegate?.mouseOwnershipChanged(false)
            if byClick { self?.delegate?.clickedOutsideWindows() }
        }
    }

    /// Starts an interaction with a press that arrived outside the tap (the click on the preview
    /// that began it). The physical release then comes through the tap.
    func press(_ hit: PointerHit, rightButton: Bool = false) {
        lock.lock()
        if rightButton { pressedRightWindow = hit.window.windowID } else { pressedWindow = hit.window.windowID }
        pendingDown = true
        lock.unlock()
        let frontmost = isFrontmost(hit)
        if !frontmost { raise(hit.window) }
        // Wait a moment even when nothing covers the window: the preview window has just been told
        // to let clicks through, and the window server applies that asynchronously.
        let delay = frontmost ? 0.05 : 0.15
        log("[mouse] press → window \(hit.window.windowID) at \(Int(hit.screenPoint.x)),\(Int(hit.screenPoint.y))\(frontmost ? "" : " (raised first)")")
        let down = CGEvent(mouseEventSource: nil, mouseType: rightButton ? .rightMouseDown : .leftMouseDown,
                           mouseCursorPosition: hit.screenPoint, mouseButton: rightButton ? .right : .left)
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        repost(down, after: delay) { [weak self] in self?.setPendingDown(false) }
    }

    // --- A controller instead of the mouse ---
    // A Sense controller has no mouse events of its own: what the mouse does through the tap
    // (the release after a press, moving over a page, the wheel) is posted here for it, marked
    // as Halliday's own so the tap lets it through as it is. Called on the main thread.

    private var controllerPoint: CGPoint?

    /// The trigger (or the grip, for the right button) was let go: the release of the press
    /// `press` posted, where the pointer is now.
    func controllerRelease(rightButton: Bool) {
        lock.lock()
        let pressed = rightButton ? pressedRightWindow : pressedWindow
        let pending = pendingDown
        if rightButton { pressedRightWindow = nil } else { pressedWindow = nil }
        lock.unlock()
        guard let id = pressed else { return }
        let input = InputState.shared
        let at = input.hit()?.screenPoint ?? controllerPoint ?? point(onWindow: id, input: input)
        let up = CGEvent(mouseEventSource: nil, mouseType: rightButton ? .rightMouseUp : .leftMouseUp,
                         mouseCursorPosition: at, mouseButton: rightButton ? .right : .left)
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        // (After the press, which is held back a moment while its window comes to the front.)
        repost(up, after: pending ? 0.25 : 0.02)
    }

    /// The controller's pointer, once a frame while a window is in use: the page under it sees
    /// the mouse move (its hover, its cursor), or a drag while the trigger is held.
    func controllerMoved() {
        guard isOn, let hit = InputState.shared.hit() else { return }
        if let last = controllerPoint, abs(last.x - hit.screenPoint.x) < 0.5, abs(last.y - hit.screenPoint.y) < 0.5 { return }
        controllerPoint = hit.screenPoint
        lock.lock(); let held = pressedWindow != nil, pending = pendingDown; lock.unlock()
        guard !pending else { return }
        let move = CGEvent(mouseEventSource: nil, mouseType: held ? .leftMouseDragged : .mouseMoved,
                           mouseCursorPosition: hit.screenPoint, mouseButton: .left)
        repost(move, after: 0)
    }

    /// The stick over a window: its page scrolls (points, up and right positive).
    func controllerScroll(dx: Double, dy: Double) {
        guard let hit = InputState.shared.hit(),
              let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: Int32(dy.rounded()), wheel2: Int32((-dx).rounded()), wheel3: 0) else { return }
        scroll.location = hit.screenPoint
        repost(scroll, after: 0)
    }

    // --- Tap thread ---

    /// Creates the tap (disabled) on its own thread, once.
    private func ensureTap() -> Bool {
        lock.lock()
        if tap != nil { lock.unlock(); return true }
        lock.unlock()
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                    .rightMouseDown, .rightMouseUp, .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: mouseOwnerCallback, userInfo: refcon)
        else {
            log("[mouse] can't install the event tap (Accessibility permission?)")
            return false
        }
        CGEvent.tapEnable(tap: tap, enable: false)
        lock.lock()
        self.tap = tap
        lock.unlock()

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in self.runInputLoop(ready: ready) }
        thread.name = "halliday.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        lock.lock()
        self.thread = thread
        lock.unlock()
        return true
    }

    /// Body of the input thread: services the tap and runs the watchdog. Never returns.
    private func runInputLoop(ready: DispatchSemaphore) {
        lock.lock(); let tap = self.tap; lock.unlock()
        if let tap {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        // Watchdog: every 0.25 s, leave if Halliday's frames have stopped.
        let watchdog = Timer(timeInterval: 0.25, repeats: true) { [self] _ in
            guard isOn else { return }
            let silence = InputState.shared.mainThreadSilence
            if silence > 1.0 { leave(reason: String(format: "watchdog: no frames for %.1f s", silence)) }
        }
        RunLoop.current.add(watchdog, forMode: .common)
        ready.signal()
        CFRunLoopRun()
    }

    private func setPendingDown(_ v: Bool) {
        lock.lock(); pendingDown = v; lock.unlock()
    }

    private func repost(_ event: CGEvent?, after delay: Double, then: (@Sendable () -> Void)? = nil) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.ownEventMarker)
        let box = EventBox(event)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + delay) {
            box.event.post(tap: .cgSessionEventTap)
            then?()
        }
    }

    /// Returns the event to pass on (possibly modified), or nil to swallow it. Runs on the tap
    /// thread: plain math on InputState only, nothing that can block.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .tapDisabledByTimeout {
            // macOS turned the tap off because it was slow: don't fight it, leave cleanly.
            leave(reason: "macOS disabled the event tap (timeout)")
            return event
        }
        if type == .tapDisabledByUserInput {
            // Sent when the tap is switched off, including by Halliday itself (it is created
            // disabled). Only matters if it is off while an interaction is supposed to be on.
            lock.lock(); let tap = self.tap; lock.unlock()
            if isOn, let tap, !CGEvent.tapIsEnabled(tap: tap) { leave(reason: "macOS disabled the event tap") }
            return event
        }
        guard isOn else { return event }
        if event.getIntegerValueField(.eventSourceUserData) == Self.ownEventMarker { return event }
        let input = InputState.shared

        switch type {
        case .flagsChanged:
            // Control pressed twice within 0.5 s leaves. Detected from the key itself (left or
            // right Control going down), not from remembered state, which goes stale.
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            let isControlKey = key == 59 || key == 62
            let pressed = event.flags.contains(.maskControl)
            guard isControlKey, pressed else { return event }
            let now = CACurrentMediaTime()
            lock.lock()
            let double = now - lastControlTap < 0.5
            lastControlTap = double ? 0 : now
            lock.unlock()
            if double { leave(reason: "Control twice") }
            return event
        case .keyDown:
            lock.lock(); lastControlTap = 0; lock.unlock()
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, event.flags.contains(.maskAlternate) {
                leave(reason: "Option+Esc")
                return nil
            }
            return event
        case .mouseMoved, .leftMouseDragged:
            input.nudge(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            lock.lock(); let pressed = pressedWindow; lock.unlock()
            if type == .leftMouseDragged, let id = pressed {
                // A drag follows the pointer onto other windows too (drag and drop between
                // windows); off every window it waits at the last point it had.
                if let hit = input.hit() {
                    if hit.window.windowID != id {
                        // Held over another window for a moment: that window comes to the front on
                        // the virtual display, so the drop lands on it.
                        let now = CACurrentMediaTime()
                        if dragOver != hit.window.windowID {
                            dragOver = hit.window.windowID
                            dragOverSince = now
                        } else if now - dragOverSince > 0.5, now - lastScrollCheck > 0.3 {
                            lastScrollCheck = now
                            if !isFrontmost(hit) { raise(hit.window) }
                        }
                    } else {
                        dragOver = nil
                    }
                    lastDragPoint = hit.screenPoint
                }
                event.location = lastDragPoint ?? point(onWindow: id, input: input)
                return event
            }
            guard let hit = input.hit() else { return nil }
            event.location = hit.screenPoint
            return event
        case .leftMouseDown:
            guard let hit = input.hit() else {
                // On one of Halliday's panels (a window's bar, the dock): the panel gets the press
                // and the drag that follows, without leaving the window that is in use. Only math
                // here; the panel itself is handled on the main thread, which is not waited for.
                if input.isOnPanel() {
                    lock.lock(); panelPressed = true; lock.unlock()
                    Task { @MainActor [weak self] in self?.delegate?.panelPress() }
                    return nil
                }
                leave(reason: "click on empty space")
                return nil
            }
            // The window's full-screen button: a full-screen window can't stay in VR, so the click
            // is not passed on (the bar under the window has the buttons that work here).
            if let blocked = hit.window.blocked,
               blocked.contains(CGPoint(x: hit.screenPoint.x - hit.window.frame.minX, y: hit.screenPoint.y - hit.window.frame.minY)) {
                Task { @MainActor [weak self] in self?.delegate?.blockedClick() }
                return nil
            }
            lock.lock(); pressedWindow = hit.window.windowID; lock.unlock()
            event.location = hit.screenPoint
            lastDragPoint = hit.screenPoint
            let id = hit.window.windowID
            if !hit.window.isPopup { Task { @MainActor [weak self] in self?.delegate?.pressedWindow(id) } }
            dragOver = nil
            if !isFrontmost(hit) {
                // Another window covers this point: raise ours (in the background), then click.
                raise(hit.window)
                setPendingDown(true)
                repost(event.copy(), after: 0.15) { [weak self] in self?.setPendingDown(false) }
                return nil
            }
            return event
        case .leftMouseUp:
            lock.lock()
            let pressed = pressedWindow, pending = pendingDown, onPanel = panelPressed
            pressedWindow = nil
            panelPressed = false
            lock.unlock()
            if onPanel {
                Task { @MainActor [weak self] in self?.delegate?.panelRelease() }
                return nil
            }
            guard let id = pressed else { return nil }
            // The release lands where the drag was (on another window, for a drop).
            event.location = input.hit()?.screenPoint ?? lastDragPoint ?? point(onWindow: id, input: input)
            lastDragPoint = nil
            dragOver = nil
            if pending {
                // Released before the held-back press went out: send the release after it.
                repost(event.copy(), after: 0.25)
                return nil
            }
            return event
        case .rightMouseDown:
            // Over a window: a real right-click (context menu). On empty space: starts looking around.
            guard let hit = input.hit() else { return nil }
            lock.lock(); pressedRightWindow = hit.window.windowID; lock.unlock()
            event.location = hit.screenPoint
            if !isFrontmost(hit) {
                raise(hit.window)
                setPendingDown(true)
                repost(event.copy(), after: 0.15) { [weak self] in self?.setPendingDown(false) }
                return nil
            }
            return event
        case .rightMouseDragged:
            lock.lock(); let pressedRight = pressedRightWindow; lock.unlock()
            if let id = pressedRight {
                input.nudge(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
                event.location = point(onWindow: id, input: input)
                return event
            }
            let dx = event.getDoubleValueField(.mouseEventDeltaX), dy = event.getDoubleValueField(.mouseEventDeltaY)
            Task { @MainActor [weak self] in self?.delegate?.look(dx: dx, dy: dy) }
            return nil
        case .rightMouseUp:
            lock.lock()
            let pressedRight = pressedRightWindow, pending = pendingDown
            pressedRightWindow = nil
            lock.unlock()
            guard let id = pressedRight else { return nil }
            event.location = point(onWindow: id, input: input)
            if pending {
                repost(event.copy(), after: 0.25)
                return nil
            }
            return event
        case .scrollWheel:
            lock.lock(); let holdingPanel = panelPressed; lock.unlock()
            if holdingPanel || input.isOnPanel() {
                let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
                Task { @MainActor [weak self] in self?.delegate?.panelScroll(dy: dy) }
                return nil
            }
            guard let hit = input.hit() else { return nil }
            event.location = hit.screenPoint
            // Windows may overlap on the virtual display: the one scrolled in VR comes to the front
            // there (checked a few times a second at most; it asks the window server).
            let now = CACurrentMediaTime()
            if now - lastScrollCheck > 0.3 {
                lastScrollCheck = now
                if !isFrontmost(hit) { raise(hit.window) }
            }
            return event
        default:
            return event
        }
    }

    /// The pointer's point on a window, or its center when the pointer has left it (drags).
    private func point(onWindow id: CGWindowID, input: InputState) -> CGPoint {
        if let hit = input.hit(), hit.window.windowID == id { return hit.screenPoint }
        guard let w = input.window(id) else { return parkPoint }
        return CGPoint(x: w.frame.midX, y: w.frame.midY)
    }

    /// A drag in progress: where it last was on a window, and the other window it is held over
    /// (tap thread only).
    nonisolated(unsafe) private var lastDragPoint: CGPoint?
    nonisolated(unsafe) private var dragOver: CGWindowID?
    nonisolated(unsafe) private var dragOverSince = 0.0

    /// When a scroll last checked whether its window is in front (tap thread only).
    nonisolated(unsafe) private var lastScrollCheck = 0.0

    /// True if no other normal window covers the hit point on the real desktop. Asks only the
    /// window server, never another app, so it can't hang.
    private func isFrontmost(_ hit: PointerHit) -> Bool {
        // Menus and popovers sit above normal windows; raising their parent would close them.
        if hit.window.isPopup { return true }
        let p = hit.screenPoint
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for w in info {
            // Of Halliday's own windows only the ones in VR count (its browsers): they share the
            // virtual display with the Mac's windows and may cover them.
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != ownPID
                    || (w[kCGWindowNumber as String] as? CGWindowID).flatMap({ InputState.shared.window($0) }) != nil,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
            return (w[kCGWindowNumber as String] as? CGWindowID) == hit.window.windowID
        }
        return true
    }

    /// Activates the window's app and raises the window, on a background queue: Accessibility
    /// calls go to the other app and can stall if it is busy.
    private func raise(_ w: WindowSnapshot) {
        // Halliday's own windows (the browser): Accessibility on our own process runs AppKit right
        // here, off the main thread, which AppKit aborts on. Raise them directly on the main
        // thread instead (queued: the tap thread never waits for it).
        if w.pid == ProcessInfo.processInfo.processIdentifier {
            let number = Int(w.windowID)
            DispatchQueue.main.async {
                NSApp.activate()
                NSApp.windows.first { $0.windowNumber == number }?.makeKeyAndOrderFront(nil)
            }
            return
        }
        axQueue.async {
            NSRunningApplication(processIdentifier: w.pid)?.activate()
            AXWindow.find(pid: w.pid, windowID: w.windowID, frame: w.frame)?.raise()
        }
    }
}

/// Carries a CGEvent across threads (it is immutable once handed over).
private final class EventBox: @unchecked Sendable {
    let event: CGEvent
    init(_ event: CGEvent) { self.event = event }
}

private func mouseOwnerCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<MouseOwner>.fromOpaque(refcon).takeUnretainedValue()
    return owner.handle(type, event).map { Unmanaged.passUnretained($0) }
}
