import Foundation

@MainActor
final class NativeAlyxLauncher {
    private var process: Process?
    private var logHandle: FileHandle?
    // Retain the slot until the termination callback has finished its cleanup.
    var isRunning: Bool { process != nil }

    func launch(_ installation: NativeAlyxInstallation, backend: NativeOpenXRSupport.Backend = NativeOpenXRSupport.selectedBackend,
                displayHz: Float? = nil, arguments: [String] = [],
                onStopped: @escaping @MainActor (String?) -> Void) throws {
        guard !isRunning else { throw LaunchFailure("A native Alyx session is already running. Close it before starting another.") }
        var environment = try NativeOpenXRSupport.launchEnvironment(ProcessInfo.processInfo.environment,
            backend: backend, displayHz: displayHz)
        let workspace = RuntimePaths.support.appendingPathComponent("NativeAlyx").appendingPathComponent(installation.kind.rawValue)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let log = workspace.appendingPathComponent("launch.log")
        try Data().write(to: log, options: .atomic)
        let handle = try FileHandle(forWritingTo: log)
        environment["HALLIDAY_NATIVE_ALYX_LOG"] = log.path
        if installation.kind == .verantyx {
            environment["HALLIDAY_NATIVE_ALYX_OWNER_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        }
        let command: NativeAlyxLaunchCommand
        do {
            let steamProbe: URL?
            if installation.kind == .verantyx {
                guard let resources = Bundle.main.resourceURL else {
                    throw NativeAlyxFailure("Halliday's native Steam readiness helper is unavailable.")
                }
                steamProbe = resources.appendingPathComponent("NativeAlyx/halliday-steam-ready")
            } else { steamProbe = nil }
            command = try NativeAlyxSupport.prepare(installation: installation, runtime: NativeOpenXRSupport.runtime(for: backend),
                workspace: workspace, bridgeOverride: NativeOpenXRSupport.bridge(for: backend),
                steamReadinessProbe: steamProbe,
                arguments: arguments, inheritedEnvironment: environment)
        } catch { try? handle.close(); throw error }
        let child = Process()
        child.executableURL = command.executable
        child.arguments = command.arguments
        child.currentDirectoryURL = command.workingDirectory
        child.environment = command.environment
        child.standardOutput = handle
        child.standardError = handle
        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                try? self?.logHandle?.close()
                self?.logHandle = nil
                self?.process = nil
                command.removePreparedScript()
                onStopped(status == 0 ? nil : status == 70
                    ? "Alyx could not connect to native Steam. Open Steam for Mac, sign in or select offline mode, then retry."
                    : "Native Alyx exited with code \(status). Its launch log is saved in Halliday's support folder.")
            }
        }
        do { try child.run() }
        catch { try? handle.close(); command.removePreparedScript(); throw error }
        process = child
        logHandle = handle
    }
}
