// Quest apps (ROADMAP W15.3): Android packages made for standalone headsets, installed into
// Halliday's own folder and run by Klepton, whose OpenXR goes to Halliday's runtime.
//
// An app is the user's own APK file. Installing unpacks it into
// Application Support/Halliday/Quest/<package>/ (the package, its unpacked files, the app's own
// data); nothing is fetched and nothing outside that folder changes. Playing starts Klepton's
// runner (a separate process, built by `make klepton` and carried in the bundle) on the unpacked
// package with Halliday's OpenXR runtime; from there the app is a game like any other: it shows
// with its first frame, Halliday comes up over it, and it is asked to quit the same way.
//
// What runs: Unity and Unreal apps, and apps whose manifest starts a NativeActivity of their
// own, all through Klepton's general way in (nothing here or in the patch knows an app by its
// name). An app whose interface is a second, web, activity has that part hosted by Halliday
// (`QuestAppWeb.swift`), which tells the player what to play. What one app needs that others
// don't is a setting in its own folder (`settings.json`, see `QuestApp.settings`).

import CHallidayCore
import Foundation

struct QuestApp: Equatable, Sendable {
    let package: String
    let name: String
    let version: String
    /// "Unity", "Unreal", "native" (a NativeActivity of its own) or "unknown".
    let engine: String
    /// The library a NativeActivity runs, when the manifest names one.
    let nativeLibrary: String?
    /// Its folder in Halliday's.
    let folder: URL

    /// Whether there is a way to start it at all.
    var canStart: Bool { ["Unity", "Unreal", "native"].contains(engine) }
    /// Whether it has a web half Halliday can host (a Capacitor application in its package).
    var hasWebInterface: Bool {
        let assets = folder.appendingPathComponent("payload/assets")
        return ["public/index.html", "native-bridge.js", "capacitor.config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: assets.appendingPathComponent($0).path)
        }
    }

    /// What this app needs that others don't, from `settings.json` in its folder (the user's, or
    /// written while finding out why an app misbehaves; a reinstall keeps it):
    /// `"network"`: true or false, whether its player may reach the network itself (without it:
    /// yes for an app with a web interface of its own, which fetches what it plays; no otherwise);
    /// `"runner"`: settings for Klepton's runner, by name (`{"KL_VK_TARGET_VIEWS_AS_ARRAY": "1"}`
    /// for an app whose menus come out as flat sheets, for one), on top of Halliday's own.
    var settings: (network: Bool?, runner: [String: String]) {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("settings.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, [:]) }
        return (d["network"] as? Bool, d["runner"] as? [String: String] ?? [:])
    }
}

enum QuestError: Error, CustomStringConvertible {
    case notAnAPK, unpack(String), noRunner, alreadyRunning

    var description: String {
        switch self {
        case .notAnAPK: "That file isn't an Android app Halliday can read"
        case .unpack(let why): "The app couldn't be unpacked: \(why)"
        case .noRunner: "Quest apps need Klepton's runner, which this build of Halliday doesn't carry (make klepton)"
        case .alreadyRunning: "A Quest app is already running"
        }
    }
}

final class QuestApps: @unchecked Sendable {
    static let shared = QuestApps()

    static let folder = RuntimePaths.support.appendingPathComponent("Quest")

    /// Klepton's runner, Halliday's OpenXR runtime and MoltenVK, side by side in the bundle.
    static var runtimeFolder: URL? {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("quest")
        return folder.flatMap { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("klepton-runner").path) ? $0 : nil }
    }

    private let lock = NSLock()
    private var running: (package: String, process: Process)?

    /// The level the runner plays at, as text it reads again four times a second.
    static let volumeFile = folder.appendingPathComponent("volume")
    static func setVolume(_ level: Float) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? String(format: "%.3f\n", level).write(to: volumeFile, atomically: true, encoding: .utf8)
    }

    /// The apps installed, by name.
    static func installed() -> [QuestApp] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { read($0) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func read(_ folder: URL) -> QuestApp? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("app.json")),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let package = d["package"], let name = d["name"] else { return nil }
        return QuestApp(package: package, name: name, version: d["version"] ?? "", engine: d["engine"] ?? "unknown",
                        nativeLibrary: d["native"].flatMap { $0.isEmpty ? nil : $0 }, folder: folder)
    }

    /// What a binary manifest says, through the core: the summary's lines, and the text document.
    private static func manifest(_ bytes: Data) -> (facts: [String: String], xml: String)? {
        func text(xml: Bool) -> String? {
            bytes.withUnsafeBytes { raw -> String? in
                let p = raw.bindMemory(to: UInt8.self).baseAddress
                let need = halliday_apk_manifest(p, bytes.count, xml, nil, 0)
                guard need >= 0 else { return nil }
                var out = [UInt8](repeating: 0, count: Int(need))
                guard halliday_apk_manifest(p, bytes.count, xml, &out, out.count) == need else { return nil }
                return String(decoding: out, as: UTF8.self)
            }
        }
        guard let summary = text(xml: false), let xml = text(xml: true) else { return nil }
        var facts: [String: String] = [:]
        for line in summary.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { facts[String(parts[0])] = String(parts[1]) }
        }
        return (facts, xml)
    }

    /// A name to show for a package that carries none Halliday can read (the label is in the
    /// package's resource table): the part of its id that isn't a common word.
    static func displayName(package: String, file: URL) -> String {
        let common: Set<String> = ["com", "org", "net", "ai", "io", "app", "apps", "game", "games", "quest", "questapp", "vr", "android", "oculus", "meta"]
        let part = package.split(separator: ".").map(String.init).last { !common.contains($0.lowercased()) }
        let raw = part ?? file.deletingPathExtension().lastPathComponent
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Unpacks an APK into Halliday's folder (replacing an earlier install of the same package,
    /// whose own data is kept). Blocking: call it off the main thread.
    func install(_ apk: URL) throws -> QuestApp {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let staging = Self.folder.appendingPathComponent(".installing-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", apk.path, "-d", payload.path]
        let errors = Pipe()
        unzip.standardError = errors
        unzip.standardOutput = FileHandle.nullDevice
        do { try unzip.run() } catch { throw QuestError.unpack(error.localizedDescription) }
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()
        // (unzip answers 1 for warnings it got past.)
        guard unzip.terminationStatus <= 1 else {
            throw QuestError.unpack(String(decoding: said.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let manifestFile = payload.appendingPathComponent("AndroidManifest.xml")
        guard let bytes = try? Data(contentsOf: manifestFile), let read = Self.manifest(bytes),
              let package = read.facts["package"], !package.isEmpty,
              package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" }) else { throw QuestError.notAnAPK }
        // Klepton reads the manifest as text, and the version from apktool's file.
        try read.xml.write(to: manifestFile, atomically: true, encoding: .utf8)
        let version = read.facts["versionName"] ?? ""
        try "versionInfo:\n  versionCode: \(read.facts["versionCode"] ?? "0")\n  versionName: \(version)\n"
            .write(to: payload.appendingPathComponent("apktool.yml"), atomically: true, encoding: .utf8)
        let libraries = Set((try? fm.contentsOfDirectory(atPath: payload.appendingPathComponent("lib/arm64-v8a").path)) ?? [])
        let native = read.facts["native"] ?? ""
        let engine: String
        if libraries.contains("libunity.so"), libraries.contains("libmain.so") {
            engine = "Unity"
        } else if libraries.contains("libUnreal.so") || libraries.contains("libUE4.so") {
            engine = "Unreal"
        } else if !native.isEmpty, libraries.contains("lib\(native).so") {
            engine = "native"
        } else {
            engine = "unknown"
        }
        let home = Self.folder.appendingPathComponent(package)
        try fm.createDirectory(at: home.appendingPathComponent("userdata"), withIntermediateDirectories: true)
        for old in ["payload", "app.apk"] { try? fm.removeItem(at: home.appendingPathComponent(old)) }
        try fm.moveItem(at: payload, to: home.appendingPathComponent("payload"))
        try fm.copyItem(at: apk, to: home.appendingPathComponent("app.apk"))
        let name = Self.displayName(package: package, file: apk)
        let facts = ["package": package, "name": name, "version": version, "engine": engine, "native": native]
        try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
            .write(to: home.appendingPathComponent("app.json"))
        return QuestApp(package: package, name: name, version: version, engine: engine,
                        nativeLibrary: native.isEmpty ? nil : native, folder: home)
    }

    /// Removes an app and everything it kept.
    func remove(_ app: QuestApp) {
        stop()
        try? FileManager.default.removeItem(at: app.folder)
    }

    var runningPackage: String? { lock.lock(); defer { lock.unlock() }; return running?.package }

    /// Starts an app. `session`: for an app that is told what to play by its other half, the
    /// file holding what it was handed. `ended` is called (on any thread) when its process goes.
    func launch(_ app: QuestApp, session: URL? = nil, extras: URL? = nil, ended: @escaping @Sendable (Int32) -> Void) throws {
        guard let runtime = Self.runtimeFolder else { throw QuestError.noRunner }
        lock.lock()
        let busy = running?.process.isRunning == true
        lock.unlock()
        guard !busy else { throw QuestError.alreadyRunning }
        let fm = FileManager.default
        // Klepton looks for `<name>/` and `<name>.apk` where it is started.
        let alias = "game"
        let work = app.folder.appendingPathComponent("session")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let userdata = app.folder.appendingPathComponent("userdata")
        try fm.createSymbolicLink(at: work.appendingPathComponent(alias), withDestinationURL: app.folder.appendingPathComponent("payload"))
        try fm.createSymbolicLink(at: work.appendingPathComponent("\(alias).apk"), withDestinationURL: app.folder.appendingPathComponent("app.apk"))
        try fm.createSymbolicLink(at: work.appendingPathComponent("sdcard"), withDestinationURL: userdata)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("KL_") && $0.key != "XR_RUNTIME_JSON" }
        env["KL_VIEW"] = "1"
        env["KL_MOLTENVR"] = "1"
        env["KL_GLFB"] = "0"
        env["KL_LIFECYCLE"] = "1"
        env["KL_ELF_TLSDESC"] = "1"
        // An app's own panels (its menus, as OpenXR quad layers) are drawn into its eye
        // pictures by the runner: Halliday's runtime shows projection layers only, and an app
        // that leaves holes in its picture for panels under it showed black there.
        env["KL_MOLTENVR_COMPOSITE_PANELS"] = "1"
        // The app's world starts where the wearer is and faces, with its floor at Halliday's
        // floor (in plain LOCAL the head is at height 0, and an app's floor came out at the
        // eyes' height: a scene stood above the head).
        env["KL_MOLTENVR_LOCAL_FLOOR"] = "1"
        // With `--app-web-log`: the app's own panels as it drew them, saved twice in a run
        // beside its log (`panels/`), for a menu that shows wrong.
        if CommandLine.arguments.contains("--app-web-log") {
            let panels = app.folder.appendingPathComponent("panels")
            try? fm.createDirectory(at: panels, withIntermediateDirectories: true)
            env["KL_MOLTENVR_PANEL_DUMP"] = panels.path
        }
        env["KL_FILES_DIR"] = userdata.path
        env["KL_MVK_DIR"] = runtime.path
        env["KL_APK"] = app.folder.appendingPathComponent("app.apk").path
        env["KL_OPENXR_RUNTIME"] = runtime.appendingPathComponent("libhalliday_openxr.dylib").path
        env["HALLIDAY_APP_NAME"] = app.name
        // Each eye at the headset's own size (2000 × 2040), not the smaller one Windows games
        // are asked for (their frames are copied by the processor; a Quest app's on the GPU).
        // `--quest-eye WxH` asks for another, to compare (an app that scales its own
        // resolution with the load draws fewer frames, or scales further down, at a larger).
        let a = CommandLine.arguments
        env["HALLIDAY_EYE_SIZE"] = a.firstIndex(of: "--quest-eye").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } ?? "\(Headsets.current.appEyeSize.width)x\(Headsets.current.appEyeSize.height)"
        // Klepton's general way in: no table entry, its answers for apps it hasn't met.
        env["KL_UNTESTED"] = "1"
        // A NativeActivity's library, from the manifest (Unity and Unreal are found by theirs).
        if app.engine == "native", let library = app.nativeLibrary { env["KL_NATIVE_ACTIVITY_LIB"] = library }
        // XR_FB_space_warp by name: some players stop without it, and one that gets it is
        // refused its motion-vector swapchain and draws every frame itself.
        env["KL_XR_SPACE_WARP"] = "1"
        // The network, for the player itself: an app with a web interface of its own fetches
        // what it plays; the others stay offline unless their settings say otherwise.
        let settings = app.settings
        if !(settings.network ?? app.hasWebInterface) { env["KL_NET_OFFLINE"] = "1" }
        // What the app's other half handed over (`kl_jni_appsession.c` in the patch).
        if let session { env["KL_APP_SESSION"] = session.path }
        if let extras { env["KL_APP_EXTRAS"] = extras.path }
        // How the player's own Java methods are answered: the app's extensions say, by name and
        // signature, from the runner's fixed set of answers (docs/extensions.md). A line each:
        // method, signature, answer. Only for a player started with a session, as before.
        let java = session == nil ? [] : Extensions.active(for: app.package).flatMap(\.manifest.java)
        if !java.isEmpty {
            let table = app.folder.appendingPathComponent("session-java")
            try java.map { "\($0.method) \($0.signature) \($0.answer)" }.joined(separator: "\n").appending("\n")
                .write(to: table, atomically: true, encoding: .utf8)
            env["KL_APP_JAVA"] = table.path
        }
        // Its sound's level is Halliday's to set, also while it plays (the volume keys).
        Self.setVolume(min(max(UserDefaults.standard.object(forKey: "volume") as? Float ?? 0.5, 0), 1)) // Settings.volume
        env["KL_AUDIO_VOLUME_FILE"] = Self.volumeFile.path
        // This app's own settings last: they may change any of the above.
        for (name, value) in settings.runner where name.hasPrefix("KL_") { env[name] = value }
        let process = Process()
        process.executableURL = runtime.appendingPathComponent("klepton-runner")
        process.arguments = ["game/lib/arm64-v8a"]
        process.currentDirectoryURL = work
        process.environment = env
        // What it says goes to a file beside the app, the newest run only.
        let logFile = app.folder.appendingPathComponent("latest.log")
        fm.createFile(atPath: logFile.path, contents: nil)
        let output = FileHandle(forWritingAtPath: logFile.path)
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] p in
            try? output?.close()
            self?.lock.lock()
            if self?.running?.process === p { self?.running = nil }
            self?.lock.unlock()
            ended(p.terminationStatus)
        }
        try process.run()
        lock.lock()
        running = (app.package, process)
        lock.unlock()
    }

    /// Ends the running app, if any (after Halliday asked it to quit and it didn't).
    func stop() {
        lock.lock()
        let process = running?.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    /// Why an app gave up, from the end of what it printed: the last line that says something
    /// failed, without the logger's prefix.
    static func lastFailure(in log: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            if let r = line.range(of: "failed: ") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
            if let r = line.range(of: "FAIL: ") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    // --- From the command line (`halliday --install-apk FILE`, `--quest-apps`) ---

    static func installCommand(_ path: String) -> Bool {
        do {
            let app = try shared.install(URL(fileURLWithPath: path))
            print("Installed \(app.name) \(app.version) (\(app.package), \(app.engine)) in \(app.folder.path)")
            if !app.canStart { print("Halliday has no way to start this kind of app yet.") }
            return true
        } catch {
            print("\(error)")
            return false
        }
    }

    static func listCommand() {
        let apps = installed()
        if apps.isEmpty { print("No Quest apps installed (halliday --install-apk FILE.apk).") }
        for app in apps {
            print("\(app.name) \(app.version) · \(app.package) · \(app.engine)\(app.canStart ? "" : " · no way to start it yet")")
        }
        print(runtimeFolder == nil ? "Klepton's runner isn't in this build (make klepton)." : "Runner: \(runtimeFolder!.path)")
    }
}
