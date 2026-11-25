// Extensions (docs/extensions.md): folders of JavaScript and JSON the user installs to adapt
// Halliday to one app, so that what only one app needs never goes into Halliday's own code.
//
// This file is the store: an extension's manifest and the checks it must pass, installing (from
// a `.hallidayext` folder or a `.zip` of one), listing, switching on and off, removing, and
// finding the extensions for an app. `ExtensionHost.swift` runs one.
//
// Writing an extension: docs/extensions.md (also in Halliday's bundle, shown by the companion),
// and the example in `extensions/example/`. `halliday --check-extension FOLDER` checks one.
//
// Installed extensions live in ~/Library/Application Support/Halliday/Extensions/<id>/; the
// ones switched off are listed in UserDefaults (`disabledExtensions`).

import Foundation

/// What an extension says of itself, checked.
struct ExtensionManifest: Sendable {
    /// How the runner answers one Java method of the player's activity.
    struct JavaAnswer: Sendable, Equatable {
        let method: String
        let signature: String
        let answer: String
    }

    let id: String
    let name: String
    let version: String
    let author: String
    let description: String
    /// The API version it was written for.
    let api: Int
    /// Quest packages: exact names, or a prefix ending in `.*`.
    let apps: [String]
    /// The page's plugins it answers, with their methods, in the manifest's order.
    let plugins: [(name: String, methods: [String])]
    /// Hosts its downloads may reach: exact, `*.domain` for any subdomain, or `*` for any host.
    let network: [String]
    let java: [JavaAnswer]
    /// Its script, a file inside its folder.
    let main: String

    /// The API this Halliday offers (docs/extensions.md, "The `halliday` API").
    static let apiVersion = 1
    /// The runner's answers (`kl_jni_appsession.c` in tools/klepton-halliday.patch).
    static let answers: Set<String> = ["session", "end", "ignore", "false", "true", "zero", "empty"]
    /// Plugins Halliday answers itself (QuestAppWeb.swift): no extension takes them over.
    static let reservedPlugins: Set<String> = ["Device", "NetworkInfo", "Filesystem", "CapacitorHttp", "HallidayLog"]

    var anyHost: Bool { network.contains("*") }

    /// Whether it adapts the app with this package.
    func applies(to package: String) -> Bool {
        apps.contains { $0.hasSuffix(".*") ? package.hasPrefix(String($0.dropLast())) : $0 == package }
    }

    /// Whether its downloads may reach `host`.
    func allows(host: String) -> Bool {
        let host = host.lowercased()
        return network.contains { pattern in
            if pattern == "*" { return true }
            if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst())) }
            return host == pattern
        }
    }

    /// Reads `manifest.json` in `folder` and checks it: every problem found, at once.
    static func read(from folder: URL) throws -> ExtensionManifest {
        let file = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file) else { throw ExtensionError.invalid(["There is no manifest.json in the folder."]) }
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ExtensionError.invalid(["manifest.json isn't a JSON object."])
        }
        var problems: [String] = []
        func text(_ key: String, required: Bool = true, max: Int = 200) -> String {
            let value = (o[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if required, value.isEmpty { problems.append("\"\(key)\" is missing.") }
            if value.count > max { problems.append("\"\(key)\" is longer than \(max) characters.") }
            return value
        }
        let identifier = #"^[A-Za-z_][A-Za-z0-9_]*$"#
        func matches(_ s: String, _ pattern: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

        let id = text("id", max: 100)
        if !id.isEmpty, !matches(id, #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#) {
            problems.append("\"id\" must be reverse-DNS, like org.example.my-adapter.")
        }
        let name = text("name", max: 80)
        let version = text("version", max: 40)
        let author = text("author", required: false, max: 80)
        let description = text("description", required: false, max: 400)
        let api = o["halliday"] as? Int ?? 0
        if api < 1 { problems.append("\"halliday\" (the API version, 1) is missing.") }
        if api > apiVersion { problems.append("It needs a newer Halliday (API \(api); this one has \(apiVersion)).") }

        let apps = o["apps"] as? [String] ?? []
        if apps.isEmpty { problems.append("\"apps\" names no app.") }
        for a in apps where !matches(a, #"^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)*(\.\*)?$"#) {
            problems.append("\"\(a)\" in \"apps\" isn't a package name (or a prefix ending in .*).")
        }

        var plugins: [(String, [String])] = []
        if let p = o["plugins"] as? [String: Any] {
            // In the manifest's order, as written (a dictionary has none): the keys sorted.
            for key in p.keys.sorted() {
                guard matches(key, identifier) else { problems.append("\"\(key)\" isn't a plugin name."); continue }
                if reservedPlugins.contains(key) { problems.append("\(key) is answered by Halliday itself."); continue }
                let methods = p[key] as? [String] ?? []
                if methods.isEmpty { problems.append("\(key) has no methods.") }
                for m in methods where !matches(m, identifier) { problems.append("\"\(m)\" of \(key) isn't a method name.") }
                plugins.append((key, methods))
            }
        } else if o["plugins"] != nil {
            problems.append("\"plugins\" must be an object: each plugin's name and its methods.")
        }

        let network = (o["network"] as? [String] ?? []).map { $0.lowercased() }
        for h in network where !(h == "*" || matches(h, #"^(\*\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"#)) {
            problems.append("\"\(h)\" in \"network\" isn't a host (or *.domain, or *).")
        }

        var java: [JavaAnswer] = []
        let runner = o["runner"] as? [String: Any]
        for entry in runner?["java"] as? [[String: Any]] ?? [] {
            let method = entry["method"] as? String ?? "", signature = entry["signature"] as? String ?? "", answer = entry["answer"] as? String ?? ""
            if !matches(method, identifier) { problems.append("\"\(method)\" in runner.java isn't a method name."); continue }
            if !matches(signature, #"^\([\[A-Za-z0-9_/;$]*\)[\[A-Za-z0-9_/;$]+$"#) { problems.append("The signature of \(method) isn't a JNI signature, like (I)V."); continue }
            if !answers.contains(answer) { problems.append("\"\(answer)\" for \(method) isn't one of the runner's answers (\(answers.sorted().joined(separator: ", ")))."); continue }
            java.append(JavaAnswer(method: method, signature: signature, answer: answer))
        }

        let main = text("main", required: false, max: 200).isEmpty ? "main.js" : text("main", required: false, max: 200)
        let script = folder.appendingPathComponent(main).standardizedFileURL
        if !script.path.hasPrefix(folder.standardizedFileURL.path + "/") {
            problems.append("\"main\" must be a file inside the extension's folder.")
        } else if !FileManager.default.fileExists(atPath: script.path) {
            problems.append("Its script, \(main), isn't in the folder.")
        }
        if plugins.isEmpty, java.isEmpty { problems.append("It answers nothing: no \"plugins\" and no \"runner\".") }
        // Plain files only, and not too many: a symbolic link could point anywhere on the Mac.
        var count = 0, bytes: Int64 = 0
        let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey])
        while let item = walk?.nextObject() as? URL {
            let v = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if v?.isSymbolicLink == true { problems.append("It holds a symbolic link (\(item.lastPathComponent)): extensions are plain files."); break }
            count += 1
            bytes += Int64(v?.fileSize ?? 0)
        }
        if count > 2000 || bytes > 50 * 1024 * 1024 { problems.append("It is too large for an extension (\(count) files, \(bytes / 1_048_576) MB).") }

        guard problems.isEmpty else { throw ExtensionError.invalid(problems) }
        return ExtensionManifest(id: id, name: name, version: version, author: author, description: description, api: api,
                                 apps: apps, plugins: plugins, network: network, java: java, main: main)
    }
}

enum ExtensionError: Error, CustomStringConvertible {
    case invalid([String])
    case notAnExtension
    case failed(String)

    var description: String {
        switch self {
        case .invalid(let problems): problems.joined(separator: "\n")
        case .notAnExtension: "That isn't an extension: a .hallidayext folder, or a .zip of one, with a manifest.json."
        case .failed(let why): why
        }
    }
}

/// An installed extension.
struct InstalledExtension: Sendable, Identifiable {
    let manifest: ExtensionManifest
    let folder: URL
    var enabled: Bool
    /// Where it was installed from, when that was a GitHub link.
    var source: GitHubSource? = nil
    var id: String { manifest.id }
}

enum Extensions {
    static var folder: URL {
        RuntimePaths.support.appendingPathComponent("Extensions", isDirectory: true)
    }

    private static let disabledKey = "disabledExtensions"

    private static var disabled: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    /// The installed extensions, by name. One whose manifest no longer passes is left out (and logged).
    static func installed() -> [InstalledExtension] {
        let fm = FileManager.default
        let off = disabled
        // Debug (`--sample-extensions`): only the bundled example, for screenshots (the user's own
        // extensions name the apps they are for).
        let folders = CommandLine.arguments.contains("--sample-extensions")
            ? [Bundle.main.resourceURL?.appendingPathComponent("extension-example", isDirectory: true)].compactMap { $0 }
            : (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { url -> InstalledExtension? in
            guard url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            do {
                let m = try ExtensionManifest.read(from: url)
                let source = (try? Data(contentsOf: url.appendingPathComponent(sourceFile))).flatMap { try? JSONDecoder().decode(GitHubSource.self, from: $0) }
                return InstalledExtension(manifest: m, folder: url, enabled: !off.contains(m.id), source: source)
            } catch {
                log("[extensions] \(url.lastPathComponent) left out: \(error)")
                return nil
            }
        }.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    /// The extensions switched on for the app with this package.
    static func active(for package: String) -> [InstalledExtension] {
        installed().filter { $0.enabled && $0.manifest.applies(to: package) }
    }

    /// The extension in a `.hallidayext` folder, or in a `.zip` of one (unpacked into a temporary
    /// folder), read and checked, ready for `install`. `folder` is where it was read from.
    static func open(_ url: URL) throws -> (manifest: ExtensionManifest, folder: URL) {
        var source = url
        if url.pathExtension.lowercased() == "zip" {
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-extension-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, out.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ExtensionError.failed("The .zip couldn't be unpacked.") }
            source = try root(in: out)
        }
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              FileManager.default.fileExists(atPath: source.appendingPathComponent("manifest.json").path) else {
            throw ExtensionError.notAnExtension
        }
        return (try ExtensionManifest.read(from: source), source)
    }

    /// The folder holding manifest.json in an unpacked archive: its top, or one folder down.
    private static func root(in folder: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) { return folder }
        let inside = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let one = inside.first(where: { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__MACOSX")
                                           && fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
            return one
        }
        throw ExtensionError.notAnExtension
    }

    /// Where an installed extension came from (a GitHub link), kept beside its files.
    static let sourceFile = ".halliday-source.json"

    /// Copies a checked extension in, replacing one with the same id. Switched on. `github`: the
    /// link it was fetched from, if it was.
    @discardableResult
    static func install(from source: URL, github: GitHubSource? = nil) throws -> InstalledExtension {
        let manifest = try ExtensionManifest.read(from: source)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(manifest.id, isDirectory: true)
        let staging = folder.appendingPathComponent(".\(manifest.id).installing", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: staging, to: target)
        if let github, let data = try? JSONEncoder().encode(github) {
            try? data.write(to: target.appendingPathComponent(sourceFile))
        }
        setEnabled(manifest.id, true)
        log("[extensions] installed \(manifest.id) \(manifest.version) (\(manifest.name))\(github.map { " from \($0.display)" } ?? "")")
        return InstalledExtension(manifest: manifest, folder: target, enabled: true, source: github)
    }

    static func setEnabled(_ id: String, _ on: Bool) {
        var off = disabled
        if on { off.remove(id) } else { off.insert(id) }
        UserDefaults.standard.set(off.sorted(), forKey: disabledKey)
    }

    static func remove(_ id: String) throws {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return }
        try FileManager.default.removeItem(at: folder.appendingPathComponent(id, isDirectory: true))
        setEnabled(id, true)
        log("[extensions] removed \(id)")
    }
}
