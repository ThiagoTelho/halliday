// Updates, through Sparkle (https://sparkle-project.org, MIT; tools/fetch-sparkle.sh), and only if
// the person asks for them: setup asks once whether to check automatically (off until they say
// yes; the Ready step), and the companion's Overview has the switch and "Check for updates" at
// any time. A check asks GitHub for the latest release's `appcast.xml` (Info.plist `SUFeedURL`);
// Sparkle's system profile is off (`SUEnableSystemProfiling`), so nothing about the Mac goes with
// it. An update must carry Sparkle's EdDSA signature (`SUPublicEDKey`) and Halliday's own
// Developer ID signature to be installed, and nothing is installed without the person's yes.
//
// Sparkle shows its window where Halliday's active window is: in VR, the headset's display,
// where nobody can see it. So a scheduled check that finds an update while the headset is in use
// leaves the showing to Halliday (`standardUserDriverShouldHandleShowingScheduledUpdate`): a notice
// in the headset and the companion's Overview say an update is ready, and "Install…" there brings
// the companion forward on the Mac's screen first, as permission requests do.

import AppKit
import Sparkle

@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = Updates()

    /// A newer version found by a scheduled check while the headset was in use (shown by Halliday).
    @Published private(set) var waiting: String?
    @Published private(set) var automatic = false
    private var controller: SPUStandardUpdaterController?

    /// True while the headset is connected, where Sparkle's window would not be seen (AppDelegate).
    var onHeadset: (() -> Bool)?
    /// Brings the companion forward on the Mac's screen (AppDelegate; the same as for permissions).
    var bringForward: (() -> Void)?
    /// A notice in the headset (AppDelegate).
    var notify: ((String) -> Void)?

    /// Starts Sparkle, except in test runs (nothing is checked then; it only checks by itself when
    /// automatic checks are on, and Info.plist's `SUEnableAutomaticChecks` keeps them off at first).
    func start(testRun: Bool) {
        guard controller == nil, !testRun else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        automatic = controller?.updater.automaticallyChecksForUpdates ?? false
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Whether Halliday checks GitHub for a newer release once a day by itself.
    func setAutomatic(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
        automatic = on
        log("[updates] automatic checks \(on ? "on" : "off")")
    }

    /// The person asked: Sparkle's own window, on the Mac's screen.
    func checkNow() {
        guard let controller else { return }
        bringForward?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            controller.checkForUpdates(nil)
            log("[updates] checking, as asked")
        }
    }

    // MARK: Sparkle's user driver

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !(onHeadset?() ?? false) }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let found = update.displayVersionString
        MainActor.assumeIsolated {
            guard !handleShowingUpdate else { return }
            waiting = found
            log("[updates] Halliday \(found) is available (said in the headset)")
            notify?("Halliday \(found) is available: install it from the companion on your Mac")
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { waiting = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { waiting = nil }
    }
}
