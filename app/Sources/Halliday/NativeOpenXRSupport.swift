import Foundation

enum NativeOpenXRSupport {
    typealias Backend = Settings.NativeOpenXRBackend
    static let files = ["libhalliday_openxr.dylib", "libhalliday_alyx_redirect.dylib", "halliday-alyx-bridge"]
    static let independentFiles = files

    static let nativeFrameBridge = "halliday-native-frame-bridge"

    @MainActor static var selectedBackend: Backend { Settings.shared.nativeOpenXRBackend }

    // App-private staging is separate from the original native game installation.
    static var folder: URL { folder(for: .halliday) }
    static var runtime: URL { runtime(for: .halliday) }
    static var bridge: URL { bridge(for: .halliday) }
    static var bundledFolder: URL? { bundledFolder(for: .halliday) }

    static func folder(for backend: Backend, root: URL = GameBridge.folder) -> URL {
        root.appendingPathComponent("NativeOpenXR", isDirectory: true)
    }
    static func runtime(for backend: Backend, root: URL = GameBridge.folder) -> URL {
        folder(for: backend, root: root).appendingPathComponent(files[0])
    }
    static func bridge(for backend: Backend, root: URL = GameBridge.folder) -> URL {
        folder(for: backend, root: root).appendingPathComponent("halliday-alyx-bridge")
    }
    static func bundledFolder(for backend: Backend, resources: URL? = Bundle.main.resourceURL) -> URL? {
        guard let resources else { return nil }
        let source = resources.appendingPathComponent("NativeOpenXR")
        let names = files
        return names.allSatisfy { regularFile(source.appendingPathComponent($0)) } ? source : nil
    }

    /// Stage only Halliday's source-built native runtime and launcher helpers.
    /// Native and Windows runtimes use the same game bridge and coexist.
    static func stage(_ backend: Backend = .halliday, resources: URL? = Bundle.main.resourceURL,
                      root: URL = GameBridge.folder) throws {
        guard let source = bundledFolder(for: backend, resources: resources) else {
            throw LaunchFailure("The \(backend.title) native OpenXR module is not included in this build.")
        }
        let names = files
        var payload = try names.map { name -> (String, Data) in
            let data = try Data(contentsOf: source.appendingPathComponent(name))
            if name.hasSuffix(".dylib"), architectures(in: data) != ["arm64", "x86_64"] {
                throw LaunchFailure("The independent native OpenXR module requires both Apple silicon and Intel libraries.")
            }
            return (name, data)
        }
        let frameBridge = source.appendingPathComponent(nativeFrameBridge)
        let frameBridgeValues = try? frameBridge.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let hasFrameBridge = FileManager.default.fileExists(atPath: frameBridge.path)
            || frameBridgeValues?.isSymbolicLink == true
        if hasFrameBridge {
            guard frameBridgeValues?.isRegularFile == true, frameBridgeValues?.isSymbolicLink != true else {
                throw LaunchFailure("The native Alyx frame bridge is not a regular bundled executable.")
            }
            let data = try Data(contentsOf: frameBridge)
            guard architectures(in: data, fileType: 2) == ["arm64"] else {
                throw LaunchFailure("The native Alyx frame bridge must be an Apple silicon executable.")
            }
            payload.append((nativeFrameBridge, data))
        }
        if backend == .halliday {
            let manifest: [String: Any] = ["file_format_version": "1.0.0",
                "runtime": ["name": "Halliday", "library_path": "./libhalliday_openxr.dylib"]]
            payload.append(("halliday_native_openxr.json", try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])))
        }
        let fm = FileManager.default, targetFolder = folder(for: backend, root: root)
        try fm.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        // Do not retain an older optional executable when staging a legacy bundle.
        let stagedFrameBridge = targetFolder.appendingPathComponent(nativeFrameBridge)
        if !hasFrameBridge, let values = try? stagedFrameBridge.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard values.isDirectory != true || values.isSymbolicLink == true else {
                throw LaunchFailure("The private native Alyx frame bridge path is not a file.")
            }
            try fm.removeItem(at: stagedFrameBridge)
        }
        for (name, data) in payload {
            let target = targetFolder.appendingPathComponent(name)
            if (try? Data(contentsOf: target)) != data { try data.write(to: target, options: .atomic) }
            if name == "halliday-alyx-bridge" || name == nativeFrameBridge { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        }
    }

    /// Both launchers inherit an explicit v6 bridge path, including Preview's private folder.
    /// The independent client obtains its Vulkan loader from the existing native game bridge.
    static func launchEnvironment(_ inherited: [String: String], backend: Backend,
                                  root: URL = GameBridge.folder, displayHz: Float?) throws -> [String: String] {
        var environment = inherited
        environment["HALLIDAY_BRIDGE"] = root.appendingPathComponent("halliday-bridge.shm").path
        if let displayHz {
            guard displayHz.isFinite, (20...240).contains(displayHz) else { throw LaunchFailure("The native game's frame rate is invalid.") }
            environment["HALLIDAY_DISPLAY_HZ"] = String(format: "%.6g", Double(displayHz))
            // The port needs an initial rate; the runtime follows live bridge cadence.
            environment["HALLIDAY_DISPLAY_HZ_INITIAL"] = "1"
        } else {
            throw LaunchFailure("The independent native runtime needs Halliday's current game frame rate.")
        }
        environment.removeValue(forKey: "HALLIDAY_EYE_SIZE")
        return environment
    }

    /// Read the universal dylib's declared and actual slice architectures before staging it.
    /// This prevents a candidate built for only one native engine architecture being selected.
    static func architectures(in data: Data, fileType: UInt32 = 6) -> Set<String> {
        func u32(_ offset: Int, big: Bool = false) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else { return nil }
            return (0..<4).reduce(UInt32(0)) { result, byte in
                result | UInt32(data[offset + byte]) << UInt32(8 * (big ? 3 - byte : byte))
            }
        }
        func u64(_ offset: Int) -> UInt64? {
            guard let high = u32(offset, big: true), let low = u32(offset + 4, big: true) else { return nil }
            return UInt64(high) << 32 | UInt64(low)
        }
        func name(_ cpu: UInt32?) -> String? {
            switch cpu { case 0x0100000c: "arm64"; case 0x01000007: "x86_64"; default: nil }
        }
        func slice(_ offset: Int, length: Int) -> String? {
            guard length >= 32, offset >= 0, offset <= data.count - length,
                  u32(offset) == 0xfeedfacf, u32(offset + 12) == fileType else { return nil }
            return name(u32(offset + 4))
        }
        guard let magic = u32(0, big: true) else { return [] }
        guard magic == 0xcafebabe || magic == 0xcafebabf else {
            return slice(0, length: data.count).map { [$0] } ?? []
        }
        guard let count = u32(4, big: true), count > 0, count <= 16 else { return [] }
        let stride = magic == 0xcafebabe ? 20 : 32
        var result: Set<String> = []
        for i in 0..<Int(count) {
            let entry = 8 + i * stride
            let rawOffset = stride == 20 ? u32(entry + 8, big: true).map(UInt64.init) : u64(entry + 8)
            let rawLength = stride == 20 ? u32(entry + 12, big: true).map(UInt64.init) : u64(entry + 16)
            guard let rawOffset, let rawLength, rawOffset <= UInt64(Int.max), rawLength <= UInt64(Int.max),
                  let architecture = slice(Int(rawOffset), length: Int(rawLength)), architecture == name(u32(entry, big: true)),
                  result.insert(architecture).inserted else { return [] }
        }
        return result
    }
    private static func regularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
