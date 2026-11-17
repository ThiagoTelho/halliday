// Moving, resizing and raising other apps' windows through the Accessibility API.

import AppKit
import ApplicationServices

/// Private but long-stable HIServices call (used by window managers such as yabai and Rectangle)
/// that maps an Accessibility window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Debug (`--ui-log`): log what Accessibility answers.
private let axDebug = CommandLine.arguments.contains("--ui-log")

/// Accessibility calls are messages to another app and block until it answers. Never call these
/// from the input path; keep the timeout short so a busy app can't stall Halliday.
struct AXWindow: @unchecked Sendable {
    let element: AXUIElement

    /// Seconds an Accessibility call may wait for the other app.
    static let timeout: Float = 0.3

    /// The Accessibility element for a window, matched by window id (or, failing that, by frame).
    static func find(pid: pid_t, windowID: CGWindowID, frame: CGRect) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            if axDebug { log("[ax] windows of pid \(pid): error \(result.rawValue)") }
            return nil
        }
        if axDebug {
            let ids = windows.map { w -> CGWindowID in var id: CGWindowID = 0; _ = _AXUIElementGetWindow(w, &id); return id }
            log("[ax] pid \(pid) windows \(ids), looking for \(windowID)")
        }
        for w in windows {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success, id == windowID { return AXWindow(element: w) }
        }
        for w in windows {
            let ax = AXWindow(element: w)
            if let f = ax.frame, abs(f.minX - frame.minX) < 2, abs(f.minY - frame.minY) < 2, abs(f.width - frame.width) < 2 {
                return ax
            }
        }
        return nil
    }

    /// Frame in global display coordinates (points, origin top-left).
    var frame: CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// Moves and resizes the window. Position is set before and after the size, because apps clamp
    /// a resize against the display the window is on at that moment.
    @discardableResult
    func setFrame(_ r: CGRect) -> Bool {
        var p = r.origin, s = r.size
        guard let pos = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return false }
        let a = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        let b = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, size)
        let c = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
        return a == .success && c == .success && (b == .success || b == .attributeUnsupported)
    }

    /// A window of process `pid` with exactly this title.
    static func withTitle(_ title: String, pid: pid_t) -> AXWindow? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            var t: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success, (t as? String) == title {
                return AXWindow(element: w)
            }
        }
        return nil
    }

    /// What keeps windows of process `pid` from being moved as they are, by window id. Blocks up to
    /// the timeout if the app is busy: call it off the main thread.
    static func states(pid: pid_t) -> [CGWindowID: (minimized: Bool, fullScreen: Bool)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [:] }
        var result: [CGWindowID: (minimized: Bool, fullScreen: Bool)] = [:]
        for w in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &id) == .success else { continue }
            let ax = AXWindow(element: w)
            result[id] = (ax.bool(kAXMinimizedAttribute), ax.bool("AXFullScreen"))
        }
        return result
    }

    private func bool(_ attribute: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &v) == .success && (v as? Bool) == true
    }

    @discardableResult
    private func set(_ attribute: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean) == .success
    }

    var isMinimized: Bool { bool(kAXMinimizedAttribute) }
    var isFullScreen: Bool { bool("AXFullScreen") }
    @discardableResult func unminimize() -> Bool { set(kAXMinimizedAttribute, false) }
    @discardableResult func leaveFullScreen() -> Bool { set("AXFullScreen", false) }

    /// True for an ordinary document or app window (not a sheet, dialog, palette or popover).
    var isStandardWindow: Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &v) == .success
            && (v as? String) == (kAXStandardWindowSubrole as String)
    }

    /// Closes the window as its red button would. False if it has no close button to press.
    @discardableResult
    func close() -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success, let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Where the window's green (full screen / zoom) button is, in global display coordinates.
    var fullScreenButtonFrame: CGRect? {
        for attribute in ["AXFullScreenButton", kAXZoomButtonAttribute as String] {
            var button: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &button) == .success, let button else { continue }
            if let f = AXWindow(element: button as! AXUIElement).frame, f.width > 0 { return f }
        }
        return nil
    }

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}
