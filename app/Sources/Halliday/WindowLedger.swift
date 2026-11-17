// Remembers, on disk, where each window was before Halliday moved it onto the virtual display, so
// windows go back to their place even if Halliday crashes or is killed.
//
// An entry is written *before* a window is moved and removed once it is back. On launch, any
// leftover entries (from a run that didn't end cleanly) are restored.

import AppKit
import ApplicationServices

struct MovedWindow: Codable, Equatable {
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let windowID: CGWindowID
    let title: String
    let x, y, width, height: Double

    var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

@MainActor
final class WindowLedger {
    let url: URL
    private(set) var entries: [MovedWindow] = []

    init(url: URL = WindowLedger.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([MovedWindow].self, from: data) {
            entries = saved
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halliday/moved-windows.json")
    }

    func record(_ entry: MovedWindow) {
        entries.removeAll { $0.windowID == entry.windowID }
        entries.append(entry)
        save()
    }

    func remove(windowID: CGWindowID) {
        let before = entries.count
        entries.removeAll { $0.windowID == windowID }
        if entries.count != before { save() }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            log("[windows] can't save \(url.path): \(error.localizedDescription)")
        }
    }

    /// Puts back windows left on the virtual display by a run that didn't end cleanly.
    /// Entries that can't be matched any more (app quit, window closed) are dropped.
    func restoreLeftovers() {
        guard !entries.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            log("[windows] \(entries.count) window(s) from the last run need restoring; grant Accessibility first")
            return
        }
        log("[windows] restoring \(entries.count) window(s) left over from the last run")
        for e in entries {
            if let ax = find(e) {
                ax.setFrame(e.frame)
                log("[windows] restored \(e.appName) — \(e.title.isEmpty ? "(untitled)" : e.title)")
            } else {
                log("[windows] couldn't find \(e.appName) — \(e.title) any more (app quit or window closed)")
            }
        }
        entries = []
        save()
    }

    /// The window for an entry: same process and window id, or else (app relaunched) the same app
    /// and title.
    private func find(_ e: MovedWindow) -> AXWindow? {
        if let app = NSRunningApplication(processIdentifier: e.pid), app.bundleIdentifier == e.bundleID,
           let ax = AXWindow.find(pid: e.pid, windowID: e.windowID, frame: e.frame) {
            return ax
        }
        guard let bundleID = e.bundleID, !e.title.isEmpty else { return nil }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            if let ax = AXWindow.withTitle(e.title, pid: app.processIdentifier) { return ax }
        }
        return nil
    }
}
