// Halliday — VR environment for macOS.
//
//   halliday                    compositor: on the headset display, or a preview window
//   halliday --replay FILE      start with a replayed recording as the pose source
//   halliday --snapshot FILE.png [--yaw DEG] [--pitch DEG] [--no-lens]
//                               render one frame offscreen to a PNG (no window, no permissions)
//   halliday --game-spacewarp-render-snapshot FILE.png
//                               verify synthetic Spacewarp through the compositor, then exit
//   halliday --game-image-ui-snapshot PREFIX
//                               save Mac and headset image settings offscreen, then exit
//   halliday --game-image-render-snapshot FILE.png
//                               save a synthetic game frame through the real renderer, then exit
//   halliday --probe [--replay FILE]
//                               command-line check of the core (displays, USB, poses)
//   halliday --install-openvr PREFIX|gamehub
//   halliday --configure-windows-vr PREFIX --backend automatic --crossover APP
//   halliday --undo-windows-vr PREFIX --crossover APP
//   halliday --list-crossover    list installed CrossOver versions, bottles and Steam games; read-only
//   halliday --launch-native-alyx FOLDER   open an existing native Alyx in this runtime
//   halliday --check-extension FOLDER [--call Plugin.method JSON ...] | --install-extension FOLDER
//                               for extension authors (ExtensionCheck.swift), then exit
//   halliday --sense-probe [SECONDS] [--leds PHASE]   what the Sense controllers send (no window); 6 lights their tracking LEDs
//                               make Halliday the OpenVR runtime of a Wine prefix (or of every
//                               GameHub container), then exit

import AppKit
import CHallidayCore

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--openxr-panel-bridge-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { runOpenXRBridgeSnapshot(path: arguments[i + 1], arguments: arguments) }
    exit(0)
}
if let i = arguments.firstIndex(of: "--native-openxr-ui-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        CompanionSnapshot.nativeOpenXR(to: arguments[i + 1])
    }
    exit(0)
}
if let i = arguments.firstIndex(of: "--game-spacewarp-render-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { runGameSpacewarpRenderSnapshot(path: arguments[i + 1], arguments: arguments) }
    exit(0)
}
if let i = arguments.firstIndex(of: "--game-image-ui-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { runGameImageUISnapshot(prefix: arguments[i + 1]) }
    exit(0)
}
if let i = arguments.firstIndex(of: "--game-image-render-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { runGameImageRenderSnapshot(path: arguments[i + 1], arguments: arguments) }
    exit(0)
}
if arguments.contains("--list-crossover") {
    let discovery = CrossOverLibrary.discover()
    let result: [String: Any] = [
        "applications": discovery.installations.map { ["name": $0.name, "path": $0.applicationURL.path] },
        "bottles": discovery.bottles.map(\.path),
        "games": discovery.games.map { ["id": $0.id, "appID": $0.appID, "name": $0.name,
            "bottle": $0.bottle.path, "folder": $0.folder.path, "steam": $0.steamExecutable.path] }
    ]
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    exit(0)
}
let replayArgument: String? = arguments.firstIndex(of: "--replay").flatMap { i in
    i + 1 < arguments.count ? arguments[i + 1] : nil
}

if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated { runSnapshot(path: arguments[i + 1], arguments: arguments) }
    exit(0)
}

if let i = arguments.firstIndex(of: "--install-openvr"), i + 1 < arguments.count {
    let ok = MainActor.assumeIsolated { GameBridge.installCommand(arguments[i + 1]) }
    exit(ok ? 0 : 1)
}

if let at = arguments.firstIndex(of: "--configure-windows-vr") ?? arguments.firstIndex(of: "--undo-windows-vr"), at + 1 < arguments.count {
    let ok = MainActor.assumeIsolated { () -> Bool in
        do {
            guard let appAt = arguments.firstIndex(of: "--crossover"), appAt + 1 < arguments.count else {
                throw LaunchFailure("Choose the CrossOver application with --crossover APP.")
            }
            let installation = CrossOverInstallation(applicationURL: URL(fileURLWithPath: arguments[appAt + 1]))
            let prefix = URL(fileURLWithPath: arguments[at + 1], isDirectory: true)
            let undo = arguments[at] == "--undo-windows-vr"
            let backendAt = arguments.firstIndex(of: "--backend")
            let raw = backendAt.flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "automatic"
            guard let backend = WindowsOpenXRSupport.Backend(rawValue: raw) else { throw LaunchFailure("Unknown Windows VR backend.") }
            guard GameBridge.installRuntime() else { throw LaunchFailure("The OpenVR runtime is not included in this build.") }
            try WindowsOpenXRSupport.configure(prefix: prefix, installation: installation, enabled: !undo, backend: backend)
            if undo {
                try OpenVRRegistration.uninstall(prefix: prefix, runtime: GameBridge.folder)
            } else {
                let runtime = backend == .automatic
                    ? OpenVRRegistration.automaticRuntimeRoot(prefix: prefix, baseRuntime: GameBridge.folder) : GameBridge.folder
                _ = try OpenVRRegistration.install(prefix: prefix, runtime: runtime)
                // Match the explicit successful setup, so a later UI Play cannot silently
                // undo it using an older selector value. Undo remains per-bottle.
                WindowsOpenXRSupport.enabled = true
                WindowsOpenXRSupport.backend = backend
            }
            print(undo ? "Restored the bottle's previous OpenXR and OpenVR settings." : "Configured OpenXR and OpenVR for \(backend.title). Launch games normally from Steam or CrossOver.")
            return true
        } catch { print(error.localizedDescription); return false }
    }
    exit(ok ? 0 : 1)
}

// `--install-apk FILE.apk`: a Quest app unpacked into Halliday's folder (ROADMAP W15.3);
// `--quest-apps` lists the ones installed. Both exit.
if let i = arguments.firstIndex(of: "--install-apk"), i + 1 < arguments.count {
    exit(QuestApps.installCommand(arguments[i + 1]) ? 0 : 1)
}
if arguments.contains("--quest-apps") {
    QuestApps.listCommand()
    exit(0)
}

// `--check-extension FOLDER [--call Plugin.method JSON ...]` and `--install-extension FOLDER|ZIP`,
// for extension authors (ExtensionCheck.swift, docs/extensions.md). Both exit.
if let i = arguments.firstIndex(of: "--check-extension"), i + 1 < arguments.count {
    let ok = MainActor.assumeIsolated { ExtensionCheck.run(arguments[i + 1], arguments: Array(arguments[(i + 2)...])) }
    exit(ok ? 0 : 1)
}
if let i = arguments.firstIndex(of: "--setup-snapshot"), i + 1 < arguments.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        CompanionSnapshot.setup(prefix: arguments[i + 1])
    }
    exit(0)
}
if let i = arguments.firstIndex(of: "--install-extension"), i + 1 < arguments.count {
    exit(MainActor.assumeIsolated { ExtensionCheck.install(arguments[i + 1]) } ? 0 : 1)
}

if let i = arguments.firstIndex(of: "--sense-probe") {
    let leds = arguments.firstIndex(of: "--leds").flatMap { $0 + 1 < arguments.count ? UInt8(arguments[$0 + 1]) : nil }
    let cycle = arguments.firstIndex(of: "--led-cycle-ms").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 1000.0 / 60
    SenseControllers.probe(seconds: i + 1 < arguments.count ? Double(arguments[i + 1]) ?? 10 : 10, ledPhase: leds, ledCycle: cycle / 1000)
    exit(0)
}

if arguments.contains("--probe") {
    runProbe(replayPath: replayArgument)
    exit(0)
}

// Launched from Finder or `open`: there is no terminal, so log to a file (`make open` tails it).
if isatty(STDOUT_FILENO) == 0 {
    let logPath = RuntimePaths.log.path
    // The run before is kept beside it: a session worth reading is often followed by a restart
    // (or a test run) before anyone reads it.
    let previous = RuntimePaths.log.deletingPathExtension().appendingPathExtension("previous.log").path
    try? FileManager.default.removeItem(atPath: previous)
    try? FileManager.default.moveItem(atPath: logPath, toPath: previous)
    freopen(logPath, "w", stdout)
    freopen(logPath, "a", stderr)
}

print("Halliday (core \(String(cString: halliday_core_version())))")
print("[permissions] screen recording: \(CGPreflightScreenCaptureAccess() ? "yes" : "no") · accessibility: \(AXIsProcessTrusted() ? "yes" : "no")")
// Killed (kill, Ctrl+C, logout): quit normally, so windows in VR go back to their place.
let terminationSignals: [DispatchSourceSignal] = [SIGTERM, SIGINT, SIGHUP].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}

let app = NSApplication.shared
let delegate = AppDelegate(replayPath: replayArgument)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
