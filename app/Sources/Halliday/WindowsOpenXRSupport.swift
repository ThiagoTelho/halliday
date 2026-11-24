import Foundation

enum WindowsOpenXRSupport {
    enum Backend: String, CaseIterable, Identifiable, Sendable {
        case automatic = "automatic"
        case halliday = "halliday"
        case external = "external"
        var id: String { rawValue }
        var title: String {
            switch self { case .automatic: "Automatic headset"; case .halliday: "Halliday"; case .external: "Original runtime" }
        }
        var folderName: String {
            switch self { case .automatic: "AutoOpenXR"; case .halliday: "WindowsOpenXR"; case .external: "" }
        }
        var resourceName: String {
            switch self { case .automatic: "AutomaticOpenXR"; case .halliday: "WindowsOpenXR"; case .external: "" }
        }
        var manifestName: String {
            switch self { case .automatic: "halliday_openxr_router.json"; case .halliday: "halliday_openxr.json"; case .external: "" }
        }
        var files: [String] {
            switch self {
            case .automatic: ["halliday_openxr_router.dll", "halliday_openxr_router.json", "vrclient_x64.dll", "LICENSE-nlohmann-json"]
            case .halliday: ["halliday_openxr.dll", "halliday_openxr.json", "halliday-xr-registry.exe"]
            case .external: [] // An installed provider is referenced, never copied into Halliday.
            }
        }
    }

    @MainActor static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "gamesWindowsOpenXRPreview") }
        set { UserDefaults.standard.set(newValue, forKey: "gamesWindowsOpenXRPreview") }
    }

    @MainActor static var backend: Backend {
        get {
            if let saved = Backend(rawValue: UserDefaults.standard.string(forKey: "gamesWindowsOpenXRBackend") ?? "") { return saved }
            return .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gamesWindowsOpenXRBackend") }
    }

    static func folder(for backend: Backend) -> URL {
        GameBridge.folder.appendingPathComponent(backend.folderName)
    }

    static func automaticFolder(prefix: URL) -> URL {
        OpenVRRegistration.automaticRuntimeRoot(prefix: prefix, baseRuntime: GameBridge.folder).deletingLastPathComponent()
    }

    static func bundledFolder(for backend: Backend) -> URL? {
        guard let first = backend.files.first, let resources = Bundle.main.resourceURL else { return nil }
        let folder = resources.appendingPathComponent(backend.resourceName)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(first).path) ? folder : nil
    }

    static var bundledFolder: URL? {
        bundledFolder(for: .halliday)
    }

    /// Only Halliday-owned runtime files are staged here; no Wine process or registry changes.
    static func stage(_ backend: Backend) throws {
        if backend == .external { return }
        guard let source = bundledFolder(for: backend) else {
            throw LaunchFailure("The \(backend.title) OpenXR module is not included in this build.")
        }
        let fm = FileManager.default, target = folder(for: backend)
        let payload = try backend.files.map { name -> (String, Data) in
            let bytes = try Data(contentsOf: source.appendingPathComponent(name))
            return (name, bytes)
        }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for (name, bytes) in payload {
            let file = target.appendingPathComponent(name)
            if (try? Data(contentsOf: file)) != bytes { try bytes.write(to: file, options: .atomic) }
        }
    }

    /// Updates only owned payloads. Existing registrations keep pointing at these stable
    /// paths, including when a game is started directly from Steam after an app update.
    static func refreshStagedRuntimes() throws {
        try stage(.halliday)
        guard bundledFolder(for: .automatic) != nil else { return }
        try stage(.automatic)
        let fm = FileManager.default
        for target in (try? fm.contentsOfDirectory(at: folder(for: .automatic), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
            let key = target.lastPathComponent
            guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let attributes = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  fm.fileExists(atPath: target.appendingPathComponent("halliday-openxr-router.json").path) else { continue }
            try stageAutomaticPayload(in: target)
        }
    }

    /// Optional provider-owned connected:true telemetry. A valid original DLL,
    /// running process or stale file alone never selects an external headset.
    static func externalIsActive(now: Date) -> Bool {
        let fm = FileManager.default
        let root = folder(for: .automatic)
        for target in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? [] {
            let key = target.lastPathComponent
            guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let attributes = try? target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  let bytes = WindowsRuntimeFiles.boundedFile(target.appendingPathComponent("halliday-openxr-router.json"), maximum: 16 * 1024),
                  let config = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let original = (config["external_manifest"] ?? config["molten_manifest"]) as? String,
                  let url = ExternalVRActivity.statusURL(originalManifest: original, configuredPath: config["external_activity_file"] as? String)
            else { continue }
            if ExternalVRActivity(statsURL: url).isAvailable(now: now) { return true }
        }
        return false
    }

    private static func stageAutomaticPayload(in target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in Backend.automatic.files where name != "vrclient_x64.dll" {
            let bytes = try Data(contentsOf: folder(for: .automatic).appendingPathComponent(name))
            let file = target.appendingPathComponent(name)
            if (try? Data(contentsOf: file)) != bytes { try bytes.write(to: file, options: .atomic) }
        }
        let router = try Data(contentsOf: folder(for: .automatic).appendingPathComponent("vrclient_x64.dll"))
        for layout in ["OpenVR/bin", "OpenVR/bin/win64"] {
            let directory = target.appendingPathComponent(layout)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("vrclient_x64.dll")
            if (try? Data(contentsOf: file)) != router { try router.write(to: file, options: .atomic) }
        }
    }

    /// Called off the main actor, and only for an explicit Play/Undo action in this bottle.
    static func configure(prefix: URL, installation: CrossOverInstallation, enabled: Bool, backend: Backend = .automatic) throws {
        let fm = FileManager.default
        let target = folder(for: .halliday)
        if bundledFolder != nil { try stage(.halliday) }
        let helper = target.appendingPathComponent("halliday-xr-registry.exe")
        if !enabled || backend == .external {
            guard fm.fileExists(atPath: helper.path) else {
                if WineOpenXRRegistration.hasSetupReceipt(prefix: prefix) {
                    throw LaunchFailure("The registry helper is unavailable; the original OpenXR runtime has not been restored.")
                }
                return
            }
            try WineOpenXRRegistration.uninstall(prefix: prefix, installation: installation, helperURL: helper,
                                                 manifestURL: target.appendingPathComponent(Backend.halliday.manifestName))
            return
        }
        if enabled { try stage(backend) }
        var manifest = folder(for: backend).appendingPathComponent(backend.manifestName)
        guard fm.fileExists(atPath: helper.path), !enabled || fm.fileExists(atPath: manifest.path) else {
            throw LaunchFailure("The Windows OpenXR preview is not bundled in this build.")
        }
        if enabled {
            if backend == .automatic {
                let access = try WineOpenXRRegistration.registryAccess(prefix: prefix, installation: installation, helperURL: helper)
                let original = WineOpenXRRegistration.registryString(try WineOpenXRRegistration.originalRuntime(prefix: prefix, access: access))
                manifest = try prepareAutomatic(prefix: prefix, originalManifest: original)
            }
            try WineOpenXRRegistration.install(prefix: prefix, installation: installation, helperURL: helper, manifestURL: manifest)
        } else {
            try WineOpenXRRegistration.uninstall(prefix: prefix, installation: installation, helperURL: helper, manifestURL: manifest)
        }
    }

    /// Each bottle keeps its own optional original route. The broker reads only the selected
    /// backend and pins it for the process; it never rewrites a game's files or launch options.
    private static func prepareAutomatic(prefix: URL, originalManifest: String?) throws -> URL {
        let target = automaticFolder(prefix: prefix)
        try stageAutomaticPayload(in: target)
        var config: [String: Any] = ["version": 1,
            "halliday_manifest": OpenVRRegistration.windowsPath(folder(for: .halliday).appendingPathComponent(Backend.halliday.manifestName)),
            "policy_file": OpenVRRegistration.windowsPath(GameBridge.folder.appendingPathComponent("runtime-policy.json")),
            "halliday_openvr_library": OpenVRRegistration.windowsPath(GameBridge.folder.appendingPathComponent("bin/win64/vrclient_x64.dll"))]
        // File validity only establishes a provider route, never a connected headset.
        // Keep the original manifest in place, preserving its own dependency lookup.
        if let originalManifest, let library = WindowsRuntimeFiles.library(prefix: prefix, manifestPath: originalManifest),
           !WindowsRuntimeFiles.isWithin(library, directory: GameBridge.folder) {
            config["external_manifest"] = originalManifest
            // Unknown providers can opt in to the same small connected-heartbeat
            // contract through an absolute local status-file preference.
            let configured = UserDefaults.standard.string(forKey: "gamesExternalVRStatusFile")
            if let status = ExternalVRActivity.statusURL(originalManifest: originalManifest, configuredPath: configured) {
                config["external_activity_file"] = status.path
            }
        }
        let originalPaths = try OpenVRRegistration.originalRuntimePaths(prefix: prefix, runtime: GameBridge.folder)
        if let library = originalPaths.lazy.compactMap({ WindowsRuntimeFiles.openVRLibrary(prefix: prefix, runtimePath: $0) })
            .first(where: { !WindowsRuntimeFiles.isWithin($0, directory: GameBridge.folder) }) {
            config["external_openvr_library"] = OpenVRRegistration.windowsPath(library)
        }
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: target.appendingPathComponent("halliday-openxr-router.json"), options: .atomic)
        return target.appendingPathComponent(Backend.automatic.manifestName)
    }

}
