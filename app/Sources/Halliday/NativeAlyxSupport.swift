import Foundation

enum NativeAlyxKind: String, Sendable {
    case verantyx
    case inversa
}

/// Existing, user-owned Linux ARM64 Alyx installations hosted by a native Mac process.
/// Discovery and preparation never replace their launchers, game files or VR libraries.
struct NativeAlyxInstallation: Equatable, Sendable, Identifiable {
    let kind: NativeAlyxKind
    let root: URL
    var launcher: URL { root.appendingPathComponent("start.command") }
    var id: String { "native-alyx:\(kind.rawValue):\(root.path)" }
    var title: String { "Half-Life: Alyx (\(kind == .verantyx ? "VeRantyx" : "Inversa"))" }
    var sourceLabel: String { "Native · \(kind == .verantyx ? "VeRantyx" : "Inversa")" }
}

struct NativeAlyxLaunchCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]
    let scriptURL: URL

    /// Call only after the child has exited; the VeRantyx lock runner reopens this script.
    func removePreparedScript() {
        try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent())
    }
}

struct NativeAlyxFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum NativeAlyxSupport {
    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         additionalRoots: [URL] = []) -> [NativeAlyxInstallation] {
        let steam = home.appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam]
        for name in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
            guard let text = try? String(contentsOf: steam.appendingPathComponent(name), encoding: .utf8),
                  let entries = ValveKeyValues.parse(text)?.object("libraryfolders") else { continue }
            for (key, value) in entries where !key.isEmpty && key.utf8.allSatisfy({ (48...57).contains($0) }) {
                if let path = value.string ?? value.object?.string("path"), path.hasPrefix("/") {
                    libraries.append(URL(fileURLWithPath: path))
                }
            }
        }
        var roots = additionalRoots + [home.appendingPathComponent("Games/Inversa-Alyx"),
                                       home.appendingPathComponent("Verantyx_VR_Drive/alyx_linux")]
        for library in libraries {
            let apps = library.appendingPathComponent("steamapps")
            if let text = try? String(contentsOf: apps.appendingPathComponent("appmanifest_546560.acf"), encoding: .utf8),
               let state = ValveKeyValues.parse(text)?.object("appstate"),
               let name = state.string("installdir"), !name.isEmpty,
               !name.contains("/"), !name.contains("\\"), name != ".", name != ".." {
                roots.append(apps.appendingPathComponent("common").appendingPathComponent(name))
            }
            // A native overlay can remain after Steam's Windows manifest is moved or removed.
            roots.append(apps.appendingPathComponent("common/Half-Life Alyx"))
        }
        var found: [String: NativeAlyxInstallation] = [:]
        for root in roots {
            if let game = installation(at: root) { found[game.id] = game }
        }
        // Upgraded VeRantyx explicitly identifies its old depot. That depot's older launcher
        // remains usable, but is not a third default library entry for the same installation.
        var superseded: Set<String> = []
        for game in found.values where game.kind == .verantyx {
            let receipt = game.root.appendingPathComponent("verantyx/moltenvr-install.json")
            if let data = try? Data(contentsOf: receipt),
               let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let path = document["depot"] as? String, path.hasPrefix("/") {
                let depot = canonical(URL(fileURLWithPath: path)).path
                if depot != game.root.path { superseded.insert(depot) }
            }
        }
        return found.values.filter { $0.kind != .verantyx || !superseded.contains($0.root.path) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func installation(at candidate: URL) -> NativeAlyxInstallation? {
        let root = canonical(candidate), fm = FileManager.default
        guard regularFile(root.appendingPathComponent("start.command")) else { return nil }
        if fm.isExecutableFile(atPath: root.appendingPathComponent("verantyx/alyx_host").path),
           fm.isExecutableFile(atPath: root.appendingPathComponent("verantyx/bridge").path),
           regularFile(root.appendingPathComponent("verantyx/native-game/game/bin/linuxsteamrtarm64/hlvr"))
                || regularFile(root.appendingPathComponent("game/bin/linuxsteamrtarm64/hlvr")) {
            return .init(kind: .verantyx, root: root)
        }
        if fm.isExecutableFile(atPath: root.appendingPathComponent("Inversa/inversa-native").path),
           regularFile(root.appendingPathComponent("Inversa/openvr/bin/linuxarm64/vrclient.so")),
           regularFile(root.appendingPathComponent("alyx/game/bin/linuxsteamrtarm64/hlvr")),
           regularFile(root.appendingPathComponent("moltenvk/libMoltenVK.dylib")) {
            return .init(kind: .inversa, root: root)
        }
        return nil
    }

    /// Creates a private copy of the existing launcher, changing only runtime routing and
    /// its root expression. All user arguments remain separate Process arguments.
    static func prepare(installation: NativeAlyxInstallation, runtime: URL, workspace: URL,
                        bridgeOverride: URL? = nil, steamReadinessProbe: URL? = nil, arguments: [String] = [],
                        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment) throws -> NativeAlyxLaunchCommand {
        guard let current = self.installation(at: installation.root), current == installation else {
            throw NativeAlyxFailure("This native Alyx installation is unavailable. Find its folder again.")
        }
        let runtime = canonical(runtime), workspace = canonical(workspace)
        guard regularFile(runtime) else {
            throw NativeAlyxFailure("Halliday's native OpenXR runtime is unavailable.")
        }
        guard !within(workspace, root: installation.root) else {
            throw NativeAlyxFailure("Halliday's temporary launch folder must be separate from the Alyx installation.")
        }
        var script = try String(contentsOf: installation.launcher, encoding: .utf8)
        let originalBridgeLogger = #"/usr/bin/python3 "$test/bridge_log.py" "$test/bridge-startup.log""#
        var replaceBridgeLogger = false
        switch installation.kind {
        case .verantyx:
            guard let bridgeOverride, regularFile(bridgeOverride),
                  FileManager.default.isExecutableFile(atPath: bridgeOverride.path),
                  !within(canonical(bridgeOverride), root: installation.root) else {
                throw NativeAlyxFailure("Halliday's native Alyx bridge is unavailable.")
            }
            let installExpression = #"install="$(cd "$(dirname "$0")" && pwd)""#
            let gameExpression = #"game="$(cd "$(dirname "$0")" && pwd)""#
            if script.components(separatedBy: "\n").contains(installExpression) {
                try replaceLine(installExpression, with: "install=\(quote(installation.root.path))", in: &script)
            } else {
                try replaceLine(gameExpression, with: "game=\(quote(installation.root.path))", in: &script)
            }
            let invocation = #""$base/bridge""#
            guard script.components(separatedBy: invocation).count == 2 else { throw changedLauncher() }
            var bridgeInvocation = quote(canonical(bridgeOverride).path)
            if let steamReadinessProbe {
                let helper = canonical(steamReadinessProbe)
                guard regularFile(helper), FileManager.default.isExecutableFile(atPath: helper.path) else {
                    throw NativeAlyxFailure("Halliday's native Steam readiness helper is unavailable.")
                }
                let home = inheritedEnvironment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
                let library = inheritedEnvironment["VERANTYX_STEAMCLIENT_DYLIB"] ??
                    home + "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib"
                guard library.hasPrefix("/") else {
                    throw NativeAlyxFailure("The native Steam client library must use an absolute path.")
                }
                // This runs only after the port's locked reentry, before any
                // bridge/game process or shader prewarm starts. A visible Steam
                // process is not yet a ready Steamworks user after a cold start.
                var ownerArgument = ""
                if let owner = inheritedEnvironment["HALLIDAY_NATIVE_ALYX_OWNER_PID"] {
                    guard let pid = Int32(owner), pid > 0 else {
                        throw NativeAlyxFailure("The native Alyx launch owner is invalid.")
                    }
                    ownerArgument = " --owner-pid \(pid)"
                }
                bridgeInvocation = "if ! \(quote(helper.path)) --library \(quote(library))\(ownerArgument); then exit 70; fi\n" + bridgeInvocation
            }
            script = script.replacingOccurrences(of: invocation, with: bridgeInvocation)
            let loggerCount = script.components(separatedBy: originalBridgeLogger).count - 1
            guard loggerCount <= 1 else { throw changedLauncher() }
            replaceBridgeLogger = loggerCount == 1
            for (original, replacement) in [
                ("export VERANTYX_DISPLAY_HZ=72", #"export VERANTYX_DISPLAY_HZ="${HALLIDAY_DISPLAY_HZ:-72}""#),
                ("export VB_FPS=72", #"export VB_FPS="${HALLIDAY_DISPLAY_HZ:-72}""#)
            ] where script.components(separatedBy: "\n").contains(original) {
                try replaceLine(original, with: replacement, in: &script)
            }
        case .inversa:
            try replaceLine(#"base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)""#,
                            with: "base=\(quote(installation.root.path))", in: &script)
            try replaceLine(#"export MVR_OPENXR_RUNTIME="$HOME/Library/Application Support/MoltenVR/bin/libmoltenvr_openxr.dylib""#,
                            with: "export MVR_OPENXR_RUNTIME=\(quote(runtime.path))", in: &script)
            let lines = script.components(separatedBy: "\n")
            let finalExec = lines.filter { $0.hasPrefix(#"exec "$runtime/inversa-native" "#) && $0.hasSuffix(">/dev/null 2>&1") }
            guard finalExec.count == 1, let original = finalExec.first else { throw changedLauncher() }
            let redirected = original.dropLast(">/dev/null 2>&1".count) + #">"${HALLIDAY_NATIVE_ALYX_LOG:-/dev/null}" 2>&1"#
            try replaceLine(original, with: String(redirected), in: &script)
        }
        var environment = inheritedEnvironment
        environment["MVR_OPENXR_RUNTIME"] = runtime.path
        environment["HALLIDAY_NATIVE_OPENXR_RUNTIME"] = runtime.path
        environment["HALLIDAY_NATIVE_ALYX_ROOT"] = installation.root.path
        if installation.kind == .verantyx {
            environment["HALLIDAY_ALYX_ORIGINAL_BRIDGE"] = installation.root.appendingPathComponent("verantyx/bridge").path
            if steamReadinessProbe != nil {
                environment["SteamAppId"] = "546560"
                environment["SteamGameId"] = "546560"
            }
        }
        let folder = workspace.appendingPathComponent("native-alyx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let generated = folder.appendingPathComponent("start.command")
        do {
            if replaceBridgeLogger {
                let logger = folder.appendingPathComponent("bridge-log.py")
                let output = workspace.appendingPathComponent("bridge-startup.log")
                try Data(bridgeLogger.utf8).write(to: logger, options: .withoutOverwriting)
                script = script.replacingOccurrences(of: originalBridgeLogger,
                    with: "/usr/bin/python3 \(quote(logger.path)) \(quote(output.path))")
                environment["HALLIDAY_NATIVE_ALYX_BRIDGE_LOG"] = output.path
            }
            try Data(script.utf8).write(to: generated, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: generated.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return .init(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [generated.path] + arguments,
                     workingDirectory: installation.root, environment: environment, scriptURL: generated)
    }

    /// The port's keyword filter discarded OpenXR's ordinary "API label: -N"
    /// failures. Retain a bounded raw tail in our workspace, and forward numeric
    /// API failures to the existing launch log without changing the user's files.
    private static let bridgeLogger = #"""
    import re, sys
    from collections import deque
    from pathlib import Path
    output = Path(sys.argv[1])
    output.write_bytes(b'')
    lines, size = deque(), 0
    for line in sys.stdin.buffer:
        line = line[-4096:]
        lines.append(line)
        size += len(line)
        while size > 16384:
            size -= len(lines.popleft())
        output.write_bytes(b''.join(lines))
        if re.search(rb': (?:VkResult )?-?[0-9]+\s*$', line):
            print('Native bridge: ' + line.decode('utf-8', errors='replace').rstrip(), flush=True)
    """#

    private static func replaceLine(_ original: String, with replacement: String, in text: inout String) throws {
        var lines = text.components(separatedBy: "\n")
        let matches = lines.indices.filter { lines[$0] == original }
        guard matches.count == 1, let index = matches.first else { throw changedLauncher() }
        lines[index] = replacement
        text = lines.joined(separator: "\n")
    }

    private static func changedLauncher() -> NativeAlyxFailure {
        NativeAlyxFailure("This Alyx launcher has changed. Halliday cannot adapt it safely; its original launcher is still available.")
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    private static func within(_ url: URL, root: URL) -> Bool { url.path == root.path || url.path.hasPrefix(root.path + "/") }
    private static func regularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
