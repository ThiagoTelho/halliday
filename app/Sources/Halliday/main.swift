// Halliday — VR environment for macOS.
//
//   halliday                    compositor: on the headset display, or a preview window
//   halliday --replay FILE      start with a replayed recording as the pose source
//   halliday --snapshot FILE.png [--yaw DEG] [--pitch DEG] [--no-lens]
//                               render one frame offscreen to a PNG (no window, no permissions)
//   halliday --probe [--replay FILE]
//                               command-line check of the core (displays, USB, poses)
//   halliday --install-openvr PREFIX|gamehub
//   halliday --check-extension FOLDER [--call Plugin.method JSON ...] | --install-extension FOLDER
//                               for extension authors (ExtensionCheck.swift), then exit
//   halliday --sense-probe [SECONDS] [--leds PHASE]   what the Sense controllers send (no window); 6 lights their tracking LEDs
//                               make Halliday the OpenVR runtime of a Wine prefix (or of every
//                               GameHub container), then exit

import AppKit
import CHallidayCore

let arguments = CommandLine.arguments
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
    let logPath = NSHomeDirectory() + "/Library/Logs/Halliday.log"
    // The run before is kept beside it: a session worth reading is often followed by a restart
    // (or a test run) before anyone reads it.
    let previous = NSHomeDirectory() + "/Library/Logs/Halliday.previous.log"
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
