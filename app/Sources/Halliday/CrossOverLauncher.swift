import Foundation

/// Arguments remain separate throughout: bottle names and game paths are never shell commands.
struct CrossOverLaunchCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL

    static func steam(installation: CrossOverInstallation, game: CrossOverGame) throws -> Self {
        let fm = FileManager.default
        guard (try? installation.wineURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.isExecutableFile(atPath: installation.wineURL.path) else {
            throw LaunchFailure("The selected CrossOver application is unavailable. Choose it again in Windows games.")
        }
        let executable = game.executable ?? game.steamExecutable
        guard (try? game.bottle.appendingPathComponent("drive_c").resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw LaunchFailure("This bottle or its game launcher is unavailable.")
        }
        guard game.executable != nil || (!game.appID.isEmpty && game.appID.utf8.allSatisfy({ (48...57).contains($0) })) else {
            throw LaunchFailure("The Steam app identifier is invalid.")
        }
        // Manual imports retain CrossOver's normal native-path conversion.
        if game.executable != nil {
            return Self(executable: installation.wineURL,
                        arguments: ["--bottle", game.bottle.path, "--no-update", "--start", executable.path],
                        workingDirectory: executable.deletingLastPathComponent())
        }
        guard let steamPath = windowsSteamPath(executable, in: game.bottle) else {
            throw LaunchFailure("Steam is outside this bottle's Windows drive mappings.")
        }
        // Keep the native winewrapper/backend selection, but pass literal
        // Windows arguments: otherwise it turns a numeric AppID into a path
        // relative to the game's working directory before Steam receives it.
        // Halliday's Steam entries are VR launches. Let Steam select its native
        // VR variant when present, or its normal variant for a VR mod; Steam
        // keeps applying the user's launch options in either case.
        return Self(executable: installation.wineURL,
                    arguments: ["--bottle", game.bottle.path, "--no-update", "--no-convert", "--start", steamPath,
                                "steam://launch/\(game.appID)/vr"],
                    workingDirectory: executable.deletingLastPathComponent())
    }

    private static func windowsSteamPath(_ executable: URL, in bottle: URL) -> String? {
        func relative(_ path: URL, to root: URL) -> [String]? {
            let parts = path.pathComponents, base = root.pathComponents
            guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
            let remainder = Array(parts.dropFirst(base.count))
            guard remainder.allSatisfy({ !$0.contains("\\") && !$0.contains(":") &&
                $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { return nil }
            return remainder
        }
        func windows(_ drive: String, _ parts: [String]) -> String {
            drive.uppercased() + ":\\" + parts.joined(separator: "\\")
        }
        let file = executable.standardizedFileURL
        let driveC = bottle.appendingPathComponent("drive_c").standardizedFileURL
        if let parts = relative(file, to: driveC) { return windows("C", parts) }
        let resolved = file.resolvingSymlinksInPath()
        if let parts = relative(resolved, to: driveC.resolvingSymlinksInPath()) { return windows("C", parts) }
        let mappings = (try? FileManager.default.contentsOfDirectory(
            at: bottle.appendingPathComponent("dosdevices"), includingPropertiesForKeys: nil)) ?? []
        let candidates: [(drive: String, root: URL)] = mappings.compactMap { mapping in
            let name = Array(mapping.lastPathComponent.utf8)
            guard name.count == 2, name[1] == 58,
                  (65...90).contains(name[0]) || (97...122).contains(name[0]) else { return nil }
            let root = mapping.resolvingSymlinksInPath().standardizedFileURL
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { return nil }
            return (String(UnicodeScalar(name[0])), root)
        }
        for mapping in candidates.sorted(by: {
            if $0.root.pathComponents.count != $1.root.pathComponents.count {
                return $0.root.pathComponents.count > $1.root.pathComponents.count
            }
            return $0.drive < $1.drive
        }) {
            if let parts = relative(resolved, to: mapping.root) { return windows(mapping.drive, parts) }
        }
        return nil
    }

}

struct LaunchFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class CrossOverLauncher {
    private var running: [UUID: Process] = [:]

    func launch(_ game: CrossOverGame, using installation: CrossOverInstallation,
                onFailure: @escaping @MainActor (String) -> Void) throws {
        let command = try CrossOverLaunchCommand.steam(installation: installation, game: game)
        let launchID = UUID()
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.running.removeValue(forKey: launchID)
                if code != 0 { onFailure("CrossOver could not start the game (exit \(code)). Check that its bottle opens in the selected CrossOver version.") }
            }
        }
        try process.run()
        running[launchID] = process
    }
}
