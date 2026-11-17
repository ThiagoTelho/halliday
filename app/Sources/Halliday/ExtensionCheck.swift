// For extension authors, from a terminal (docs/extensions.md):
//
//   halliday --check-extension FOLDER [--call Plugin.method '{"json":"options"}' ...]
//       checks the manifest, runs main.js against a stand-in app (an empty folder of its own,
//       deleted after), says which declared methods have no answer, and makes the calls given,
//       printing each answer, refusal, event and launch. Nothing is installed; downloads are
//       made only if a call asks for one.
//   halliday --install-extension FOLDER|ZIP|GITHUB-LINK
//       installs it as the companion's Install... does, without the confirmation.
// Both take a GitHub link as well (https://github.com/OWNER/REPO[/tree/REF[/FOLDER]]): fetched
// once, as the companion fetches it (ExtensionFromGitHub.swift).
//
// Both exit: 0 when all is well.

import Foundation

@MainActor
enum ExtensionCheck {
    /// A folder or .zip on the Mac, or a GitHub link fetched into a temporary folder (deleted by
    /// the caller).
    private static func locate(_ path: String) throws -> (url: URL, github: GitHubSource?, temporary: URL?) {
        guard !FileManager.default.fileExists(atPath: path), let source = GitHubSource.parse(path) else {
            return (URL(fileURLWithPath: path), nil, nil)
        }
        print("Fetching \(source.display)…")
        var result: Result<(folder: URL, temporary: URL), Error>?
        Task { @MainActor in
            do { result = .success(try await ExtensionFromGitHub.fetch(source)) } catch { result = .failure(error) }
        }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let fetched = try result!.get()
        return (fetched.folder, source, fetched.temporary)
    }

    static func install(_ path: String) -> Bool {
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let located = try locate(path)
            temporary = located.temporary
            let (manifest, folder) = try Extensions.open(located.url)
            try Extensions.install(from: folder, github: located.github)
            print("Installed \(manifest.name) \(manifest.version) (\(manifest.id)), for \(manifest.apps.joined(separator: ", "))")
            return true
        } catch {
            print("Not installed:\n\(error)")
            return false
        }
    }

    static func run(_ path: String, arguments: [String]) -> Bool {
        let manifest: ExtensionManifest, folder: URL
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            let located = try locate(path)
            temporary = located.temporary
            (manifest, folder) = try Extensions.open(located.url)
        } catch {
            print("✗ \(error)")
            return false
        }
        print("✓ \(manifest.name) \(manifest.version) (\(manifest.id)), API \(manifest.api)")
        print("  for: \(manifest.apps.joined(separator: ", "))")
        print("  reaches: \(manifest.network.isEmpty ? "nothing" : manifest.anyHost ? "any host" : manifest.network.joined(separator: ", "))")
        for j in manifest.java { print("  runner: \(j.method) \(j.signature) → \(j.answer)") }

        let stand = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-extension-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stand) }
        try? FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
        let package = manifest.apps.first.map { $0.hasSuffix(".*") ? String($0.dropLast(2)) + ".app" : $0 } ?? "org.example.app"
        let app = QuestApp(package: package, name: "Stand-in app", version: "1.0", engine: "native", nativeLibrary: nil, folder: stand)
        let files = QuestAppFiles(data: stand.appendingPathComponent("userdata"), origin: "https://localhost")
        let host = ExtensionHost(InstalledExtension(manifest: manifest, folder: folder, enabled: true), app: app, files: files)
        guard host.loaded else {
            print("✗ main.js: \(host.problem ?? "it didn't load")")
            return false
        }
        print("✓ main.js loaded")
        var ok = true
        for (plugin, methods) in manifest.plugins {
            let missing = methods.filter { !["addListener", "removeListener"].contains($0) && !host.answers(plugin, $0) }
            if missing.isEmpty {
                print("✓ \(plugin): every method answered")
            } else {
                print("! \(plugin): no answer for \(missing.joined(separator: ", ")) (the page's calls to them are refused)")
            }
        }

        // The calls asked for, one after the other, each given up to 30 s.
        var pending: String?
        host.resolve = { id, plugin, method, data in
            print("  → \(plugin).\(method) answered \(json(data))")
            if pending == id { pending = nil }
        }
        host.reject = { id, plugin, method, message in
            print("  → \(plugin).\(method) refused: \(message)")
            if pending == id { pending = nil }
            ok = false
        }
        host.emit = { plugin, event, data in print("  ↪ event \(plugin).\(event) \(json(data))") }
        host.onLaunch = { session, extras in
            let s = (try? String(contentsOf: session, encoding: .utf8)) ?? ""
            let e = (try? String(contentsOf: extras, encoding: .utf8)) ?? ""
            print("  ▶ the player would start, with a session of \(s.utf8.count) bytes: \(s.prefix(300))")
            for line in e.split(separator: "\n") { print("    extra \(line)") }
        }
        var i = 0
        while i < arguments.count {
            defer { i += 1 }
            guard arguments[i] == "--call", i + 1 < arguments.count else { continue }
            let name = arguments[i + 1].split(separator: ".", maxSplits: 1).map(String.init)
            let options = i + 2 < arguments.count && !arguments[i + 2].hasPrefix("--")
                ? (try? JSONSerialization.jsonObject(with: Data(arguments[i + 2].utf8))) as? [String: Any] ?? [:] : [:]
            guard name.count == 2 else { print("✗ --call wants Plugin.method"); ok = false; continue }
            let id = UUID().uuidString
            print("• \(name[0]).\(name[1]) \(json(options))")
            pending = id
            host.call(id: id, plugin: name[0], method: name[1], options: options)
            let until = Date().addingTimeInterval(30)
            while pending != nil, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if pending != nil { print("  … no answer in 30 s (it may answer later through call.resolve)"); pending = nil }
        }
        if arguments.contains("--call") { host.playerEnded(status: 0); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return ok
    }

    private static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return "\(o)" }
        let s = String(decoding: d, as: UTF8.self)
        return s.count > 400 ? String(s.prefix(400)) + "…" : s
    }
}
