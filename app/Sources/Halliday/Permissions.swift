// The macOS permissions Halliday needs, why, and asking for them (the companion's Permissions
// card at launch, and onboarding): each with what it is for and what Halliday never does with
// it, its state read again every second while shown, and the way to grant it.
//
// Screen Recording only applies after Halliday is opened again (macOS's rule), hence "Reopen".
//
// Every request goes through `request`: macOS shows its prompt (and System Settings opens)
// where Halliday's active window is, which in VR is the headset's display, where nobody can
// answer it. So the companion is brought forward on the Mac's own screen and made the active
// window first (`bringAskerForward`, set by AppDelegate, which also says so in the headset),
// and macOS is asked a moment later. Never call CGRequestScreenCaptureAccess or
// AXIsProcessTrustedWithOptions with a prompt anywhere else.
// Folders macOS guards (Desktop, Documents, Downloads, iCloud Drive, other disks) are asked for
// the first time a program reads one, and the read waits for the answer: on the headset that
// question sat unseen on its display and every folder after it waited too. macOS can't be asked
// beforehand whether it will ask, so a read of such a place starts at once and `watchRead`
// looks again 0.3 s later: an allowed folder has answered by then; one still waiting is
// waiting for the question, which is moved to the Mac's screen through Accessibility, and the
// companion brought forward as above.
// Automation (Music or Spotify) is not here: macOS asks for it the first time the Music panel is
// used, which is when it can be explained.

import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum Kind: String, CaseIterable, Identifiable {
        case screenRecording, accessibility
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }
        var symbol: String {
            switch self {
            case .screenRecording: "rectangle.dashed.badge.record"
            case .accessibility: "hand.point.up.left"
            }
        }
        /// What it is for.
        var why: String {
            switch self {
            case .screenRecording:
                "To show your Mac's windows, Halliday's browser and your games inside the headset, Halliday captures their pictures."
            case .accessibility:
                "To move the windows you bring into VR onto Halliday's own display, put them back when you are done, and send them your clicks and typing."
            }
        }
        /// What Halliday never does with it.
        var never: String {
            switch self {
            case .screenRecording:
                "The pictures go only to the headset: they are never saved, recorded or sent anywhere."
            case .accessibility:
                "Halliday reads nothing from your windows and types nothing you didn't type."
            }
        }
        /// System Settings' page for it.
        var settingsURL: URL {
            URL(string: self == .screenRecording
                ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }

    @Published private(set) var granted: Set<Kind> = []
    /// Asked for in this run: Screen Recording granted since then needs Halliday reopened.
    @Published private(set) var asked: Set<Kind> = []
    private var timer: Timer?
    /// Brings the companion forward on the Mac's own screen as the active window (AppDelegate).
    var bringAskerForward: (() -> Void)?
    private var lastAsked: [Kind: Double] = [:]

    /// True while the headset is connected (on it, or in desktop mode beside it: a question once
    /// went to its display then too), where macOS's questions may not be seen (AppDelegate).
    var askerIsElsewhere: (() -> Bool)?

    /// The guarded place a file or folder is in (Desktop, Documents, Downloads, iCloud Drive, a
    /// disk under /Volumes), or nil when macOS doesn't ask for it.
    nonisolated static func guardedPlace(of url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for name in ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"] {
            let root = home + "/" + name
            if path == root || path.hasPrefix(root + "/") { return URL(fileURLWithPath: root) }
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return URL(fileURLWithPath: "/Volumes/" + parts[1]) }
        return nil
    }

    private static let openedKey = "openedGuardedPlaces"

    /// Called as a read of `url` starts; `pending` says whether it is still going. A guarded
    /// place not read before, with the headset connected, still reading 0.3 s later: macOS is
    /// asking, so its question goes to the Mac's screen and the companion comes forward.
    func watchRead(of url: URL, pending: @escaping () -> Bool) {
        guard let place = Self.guardedPlace(of: url),
              !(UserDefaults.standard.stringArray(forKey: Self.openedKey) ?? []).contains(place.path),
              askerIsElsewhere?() == true else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, pending() else { return }
            log("[permissions] a guarded folder is waiting for macOS's question: moving it to the Mac's screen")
            self.bringAskerForward?()
            Self.moveQuestionsToMac()
        }
    }

    /// macOS's questions (UserNotificationCenter's windows) that aren't on the Mac's own screen,
    /// moved to its middle through Accessibility; looked for a few times over two seconds, as
    /// the window may come a moment after the read began. Off the main thread (other apps).
    static func moveQuestionsToMac() {
        let screens = NSScreen.screens
        guard let primary = screens.first, let mac = screens.first(where: { !Headsets.current.isDisplay($0) }) else { return }
        // Accessibility's coordinates: origin at the top left of the primary screen, y down.
        let target = CGRect(x: mac.frame.minX, y: primary.frame.maxY - mac.frame.maxY, width: mac.frame.width, height: mac.frame.height)
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.UserNotificationCenter").map(\.processIdentifier)
        guard !pids.isEmpty else { log("[permissions] no question window to move"); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0
            for attempt in 0..<8 {
                for pid in pids {
                    let app = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(app, AXWindow.timeout)
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                          let windows = value as? [AXUIElement] else { continue }
                    for w in windows {
                        let window = AXWindow(element: w)
                        guard let f = window.frame, !target.contains(CGPoint(x: f.midX, y: f.midY)) else { continue }
                        let to = CGRect(x: target.midX - f.width / 2, y: target.midY - f.height / 2, width: f.width, height: f.height)
                        if window.setFrame(to) { moved += 1 }
                    }
                }
                if moved > 0 || attempt == 7 { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            log("[permissions] question windows moved to the Mac's screen: \(moved)")
        }
    }

    /// A guarded place was read (or refused): macOS has its answer and won't ask again.
    func opened(_ url: URL) {
        guard let place = Self.guardedPlace(of: url) else { return }
        var list = UserDefaults.standard.stringArray(forKey: Self.openedKey) ?? []
        if !list.contains(place.path) { list.append(place.path); UserDefaults.standard.set(list, forKey: Self.openedKey) }
    }

    var missing: [Kind] { Kind.allCases.filter { !granted.contains($0) } }
    var allGranted: Bool { missing.isEmpty }

    init() { read() }

    func read() {
        var now: Set<Kind> = []
        if CGPreflightScreenCaptureAccess() { now.insert(.screenRecording) }
        if AXIsProcessTrusted() { now.insert(.accessibility) }
        if now != granted { granted = now }
    }

    /// Reads them again every second while something shows them.
    func watch(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.read() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// macOS's own request, then its Settings page (macOS asks only once; after that, Settings is
    /// the only way), with the companion in front on the Mac's screen first so the prompt and
    /// Settings appear there. Asked again within 20 s: nothing (a VR action that keeps failing
    /// must not keep pulling the companion forward).
    func request(_ kind: Kind) {
        read()
        guard !granted.contains(kind) else { return }
        let now = CACurrentMediaTime()
        if let last = lastAsked[kind], now - last < 20 { return }
        lastAsked[kind] = now
        asked.insert(kind)
        bringAskerForward?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            switch kind {
            case .screenRecording:
                if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(kind.settingsURL) }
            case .accessibility:
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(kind.settingsURL) }
            }
            log("[permissions] asked for \(kind.title), on the Mac's screen")
        }
    }

    /// Opens Halliday again (a new copy, then this one quits): Screen Recording applies then.
    func reopen() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// The permissions, each with why, what never happens with it, and its button. Used by the
/// companion's Overview (while one is missing) and by onboarding.
struct PermissionsCard: View {
    @ObservedObject var permissions = Permissions.shared
    var title = "Permissions"

    var body: some View {
        CompanionCard(title: title) {
            ForEach(Permissions.Kind.allCases) { kind in
                let ok = permissions.granted.contains(kind)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: kind.symbol).font(.system(size: 20)).frame(width: 26)
                        .foregroundStyle(ok ? companionAccent : Color.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(kind.title).font(.headline)
                            if ok {
                                Label("Allowed", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(companionAccent)
                            }
                        }
                        Text(kind.why).fixedSize(horizontal: false, vertical: true)
                        Text(kind.never).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if !ok, kind == .screenRecording, permissions.asked.contains(kind) {
                            Text("Switched Halliday on in System Settings? macOS applies it once Halliday is opened again.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if !ok {
                        VStack(alignment: .trailing, spacing: 6) {
                            Button("Allow…") { permissions.request(kind) }.controlSize(.large)
                            if kind == .screenRecording, permissions.asked.contains(kind) {
                                Button("Reopen Halliday") { permissions.reopen() }
                            }
                        }
                    }
                }
                if kind != Permissions.Kind.allCases.last { Divider() }
            }
        }
        .onAppear { permissions.read(); permissions.watch(true) }
        .onDisappear { permissions.watch(false) }
    }
}
