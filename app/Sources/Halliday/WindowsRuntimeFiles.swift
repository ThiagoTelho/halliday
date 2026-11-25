import Foundation

/// Read-only validation of Windows OpenXR modules through an existing Wine drive map.
/// Never loads a library, starts Wine or changes the bottle.
enum WindowsRuntimeFiles {
    private struct WindowsPath {
        let drive: String
        let components: [String]
    }
    private struct Manifest: Decodable {
        struct Runtime: Decodable { let library_path: String }
        let runtime: Runtime
    }

    /// Resolves library_path relative to the manifest's Windows directory, not
    /// the game's working directory. Only absolute drive paths are accepted for
    /// manifests; UNC and drive-relative paths have no unambiguous local mapping.
    static func library(prefix: URL, manifestPath: String) -> URL? {
        guard prefix.isFileURL, let manifest = absolute(manifestPath),
              let file = resolve(manifest, prefix: prefix),
              let data = boundedFile(file, maximum: 16 * 1024),
              let decoded = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        let text = decoded.runtime.library_path
        let target: WindowsPath
        if let path = absolute(text) { target = path }
        else {
            // A leading slash, colon or UNC prefix is not a relative DLL path.
            guard !text.isEmpty, !text.hasPrefix("\\"), !text.hasPrefix("/"),
                  !text.contains(":"), let parts = components(text, after: Array(manifest.components.dropLast()))
            else { return nil }
            target = WindowsPath(drive: manifest.drive, components: parts)
        }
        guard let library = resolve(target, prefix: prefix), isWindowsDLL(library) else { return nil }
        return library
    }

    /// Resolve only a registered x64 OpenVR provider, not a game-local loader or
    /// an inferred sibling of an unrelated OpenXR library.
    static func openVRLibrary(prefix: URL, runtimePath: String) -> URL? {
        guard prefix.isFileURL, let runtime = absolute(runtimePath) else { return nil }
        for suffix in [["bin", "win64", "vrclient_x64.dll"], ["bin", "vrclient_x64.dll"]] {
            let path = WindowsPath(drive: runtime.drive, components: runtime.components + suffix)
            if let library = resolve(path, prefix: prefix), isWindowsDLL(library) { return library }
        }
        return nil
    }

    static func isWithin(_ file: URL, directory: URL) -> Bool {
        let candidate = file.standardizedFileURL.resolvingSymlinksInPath().path
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// A bounded header check only, not executable loading or a full PE verifier.
    /// Require AMD64, the DLL/executable characteristics and a PE32+ optional
    /// header. Mach-O, 32-bit PE and an EXE renamed to .dll are not valid routes.
    static func isWindowsDLL(_ url: URL) -> Bool {
        guard let opened = openRegular(url) else { return false }
        let (fd, size) = opened
        defer { close(fd) }
        guard let dos = read(fd, offset: 0, count: 64), dos[0] == 0x4d, dos[1] == 0x5a else { return false }
        let offset = UInt64(u32(dos, 0x3c))
        guard offset >= 64, offset <= size, size - offset >= 24,
              let coff = read(fd, offset: offset, count: 24),
              Array(coff.prefix(4)) == [0x50, 0x45, 0, 0], u16(coff, 4) == 0x8664,
              u16(coff, 6) > 0, u16(coff, 22) & 0x2002 == 0x2002
        else { return false }
        let optionalSize = UInt64(u16(coff, 20))
        let headerEnd = offset + 24 + optionalSize
        let sectionEnd = headerEnd + UInt64(u16(coff, 6)) * 40
        guard optionalSize >= 112, headerEnd <= size, sectionEnd <= size,
              let optional = read(fd, offset: offset + 24, count: 112), u16(optional, 0) == 0x20b,
              UInt64(u32(optional, 60)) >= sectionEnd, UInt64(u32(optional, 60)) <= size,
              u32(optional, 56) >= u32(optional, 60), u32(optional, 56) > 0
        else { return false }
        return true
    }

    private static func absolute(_ text: String) -> WindowsPath? {
        let bytes = Array(text.utf8)
        guard bytes.count >= 3, bytes.count <= 32_767,
              (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]), bytes[1] == 58,
              bytes[2] == 92 || bytes[2] == 47,
              let parts = components(String(text.dropFirst(3)), after: []) else { return nil }
        return WindowsPath(drive: String(UnicodeScalar(bytes[0])).lowercased(), components: parts)
    }

    private static func components(_ text: String, after base: [String]) -> [String]? {
        guard !text.utf8.contains(where: { $0 < 32 }), !text.contains(":") else { return nil }
        var result = base
        for part in text.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !result.isEmpty { result.removeLast() }; continue }
            result.append(String(part))
        }
        return result
    }

    private static func resolve(_ path: WindowsPath, prefix: URL) -> URL? {
        let fm = FileManager.default
        let mapping = prefix.appendingPathComponent("dosdevices/\(path.drive):")
        var directory = ObjCBool(false)
        let base: URL
        var entry = stat()
        let mapExists = lstat(mapping.path, &entry) == 0
        let mapMissing = !mapExists && errno == ENOENT
        if mapExists {
            guard fm.fileExists(atPath: mapping.path, isDirectory: &directory), directory.boolValue else { return nil }
            base = mapping.resolvingSymlinksInPath()
        } else if mapMissing, path.drive == "c" {
            // Wine's conventional C: root is usable when no explicit map exists.
            let fallback = prefix.appendingPathComponent("drive_c")
            guard fm.fileExists(atPath: fallback.path, isDirectory: &directory), directory.boolValue else { return nil }
            base = fallback.resolvingSymlinksInPath()
        } else { return nil }
        var current = base
        // Windows .. was already normalized and clamped before touching host
        // paths, so it can never walk above the selected drive mapping.
        for name in path.components {
            let exact = current.appendingPathComponent(name)
            if fm.fileExists(atPath: exact.path) { current = exact; continue }
            guard let names = try? fm.contentsOfDirectory(atPath: current.path),
                  let actual = names.sorted().first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { return nil }
            current.appendPathComponent(actual)
        }
        return current.resolvingSymlinksInPath()
    }

    private static func openRegular(_ url: URL) -> (Int32, UInt64)? {
        guard url.isFileURL else { return nil }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(fd); return nil
        }
        return (fd, UInt64(info.st_size))
    }

    static func boundedFile(_ url: URL, maximum: Int) -> Data? {
        guard let opened = openRegular(url) else { return nil }
        let (fd, size) = opened
        defer { close(fd) }
        guard size > 0, size <= maximum,
              let bytes = read(fd, offset: 0, count: Int(size)),
              let end = read(fd, offset: size, count: 1, allowEOF: true), end.isEmpty else { return nil }
        return Data(bytes)
    }

    private static func read(_ fd: Int32, offset: UInt64, count: Int, allowEOF: Bool = false) -> [UInt8]? {
        guard offset <= UInt64(Int64.max), count >= 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let received = bytes.withUnsafeMutableBytes {
                pread(fd, $0.baseAddress!.advanced(by: total), count - total, off_t(offset) + off_t(total))
            }
            if received < 0 { if errno == EINTR { continue }; return nil }
            if received == 0 { return allowEOF ? Array(bytes.prefix(total)) : nil }
            total += received
        }
        return bytes
    }
    private static func u16(_ b: [UInt8], _ p: Int) -> UInt16 { UInt16(b[p]) | UInt16(b[p + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
        UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
    }
}
