// Read-only discovery of existing CrossOver bottles and their Windows Steam libraries.
// This file uses Foundation only: discovery never starts Wine, upgrades a bottle, or installs
// anything. Windows paths are resolved through that bottle's drive mappings, including disks
// outside drive_c. Runtime registration and launching are separate, explicit actions.

import Foundation

struct CrossOverInstallation: Equatable, Sendable {
    let applicationURL: URL
    var id: String { applicationURL.path }
    var name: String { applicationURL.deletingPathExtension().lastPathComponent }
    var wineURL: URL { applicationURL.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine") }
}

/// An installed Steam game, before GameLibrary checks which VR API it uses.
struct CrossOverGame: Equatable, Sendable {
    let appID: String
    let name: String
    let folder: URL
    let bottle: URL
    let steamExecutable: URL
    let fullyInstalled: Bool
    /// Changes when Steam replaces its manifest, so an update is scanned again.
    let manifestVersion: String
    /// A manually imported game or VR mod, including OpenXR-only executables.
    var executable: URL? = nil

    var bottleName: String { bottle.lastPathComponent }
    var id: String {
        if let executable { return "crossover:\(bottle.path):exe:\(executable.path)" }
        return "crossover:\(bottle.path):steam:\(appID)"
    }
    var cacheKey: String { "\(id):\(folder.path):\(manifestVersion)" }
}

enum CrossOverLibrary {
    struct Discovery: Sendable {
        var installations: [CrossOverInstallation]
        var bottles: [URL]
        var games: [CrossOverGame]
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         applicationDirectories: [URL]? = nil,
                         additionalBottleRoots: [URL] = []) -> Discovery {
        let apps = installations(in: applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")])
        let prefixes = bottles(in: bottleRoots(home: home) + additionalBottleRoots)
        return Discovery(installations: apps, bottles: prefixes, games: prefixes.flatMap { games(in: $0) })
    }

    static func installations(in directories: [URL]) -> [CrossOverInstallation] {
        let fm = FileManager.default
        var found: [String: CrossOverInstallation] = [:]
        for directory in directories {
            for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                // Do not silently select an unrelated backup copy of an engine.
                guard ["crossover.app", "crossover preview.app"].contains(file.lastPathComponent.lowercased()) else { continue }
                let app = CrossOverInstallation(applicationURL: canonical(file))
                if fm.isExecutableFile(atPath: app.wineURL.path) { found[app.id] = app }
            }
        }
        return found.values.sorted {
            let a = $0.name.lowercased() == "crossover", b = $1.name.lowercased() == "crossover"
            if a != b { return a }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    static func bottleRoots(home: URL) -> [URL] {
        var roots: [URL] = []
        for product in ["CrossOver", "CrossOver Preview"] {
            let support = home.appendingPathComponent("Library/Application Support/\(product)")
            roots.append(support.appendingPathComponent("Bottles"))
            // BottlePath is CrossOver's configurable, colon-separated search path.
            if let text = try? String(contentsOf: support.appendingPathComponent("\(product).conf"), encoding: .utf8) {
                var section = ""
                for raw in text.split(whereSeparator: \.isNewline) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix(";") || line.hasPrefix("#") { continue }
                    if line.hasPrefix("[") { section = line.lowercased(); continue }
                    guard section == "[crossover]" || section == "[environmentvariables]",
                          let equal = line.firstIndex(of: "=") else { continue }
                    let key = line[..<equal].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    guard key.lowercased() == "bottlepath" || key == "CX_BOTTLE_PATH" else { continue }
                    let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    for path in value.split(separator: ":") {
                        let expanded = String(path).replacingOccurrences(of: "${HOME}", with: home.path)
                            .replacingOccurrences(of: "$HOME", with: home.path)
                        let absolute = expanded.hasPrefix("~/") ? home.appendingPathComponent(String(expanded.dropFirst(2))).path : expanded
                        if absolute.hasPrefix("/") { roots.append(URL(fileURLWithPath: absolute)) }
                    }
                }
            }
        }
        return roots
    }

    static func bottles(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var found: [String: URL] = [:]
        for root in roots {
            for child in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
                let prefix = canonical(child)
                guard fm.fileExists(atPath: prefix.appendingPathComponent("cxbottle.conf").path),
                      fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
                      fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/users").path) else { continue }
                found[prefix.path] = prefix
            }
        }
        return found.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    static func games(in prefix: URL) -> [CrossOverGame] {
        let fm = FileManager.default
        let prefix = canonical(prefix)
        var steamFolders: [URL] = []
        for path in ["C:\\Program Files (x86)\\Steam", "C:\\Program Files\\Steam", "C:\\Steam"] {
            if let folder = resolveWindowsPath(path, in: prefix) { steamFolders.append(folder) }
        }
        // Steam can also be installed in a custom location. Read only its own user registry key.
        if let registry = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) {
            var steamSection = false
            for line in registry.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("[") {
                    steamSection = line.lowercased().hasPrefix("[software\\\\valve\\\\steam]")
                    continue
                }
                if steamSection, line.lowercased().hasPrefix("\"steampath\"="),
                   let equal = line.firstIndex(of: "="),
                   let value = ValveKeyValues.quoted(String(line[line.index(after: equal)...])),
                   let folder = resolveWindowsPath(value, in: prefix) { steamFolders.append(folder) }
            }
        }
        var found: [String: CrossOverGame] = [:]
        var seenSteam: Set<String> = []
        for steam in steamFolders {
            guard seenSteam.insert(steam.path).inserted,
                  let executable = resolveComponents(["steam.exe"], from: steam) else { continue }
            var libraries: [URL] = [steam]
            for relative in [["steamapps", "libraryfolders.vdf"], ["config", "libraryfolders.vdf"]] {
                guard let file = resolveComponents(relative, from: steam),
                      let text = try? String(contentsOf: file, encoding: .utf8),
                      let document = ValveKeyValues.parse(text),
                      let entries = document.object("libraryfolders") else { continue }
                for (key, value) in entries where key.allSatisfy(\.isNumber) && !key.isEmpty {
                    // Both old ("1" "D:\\Library") and current nested VDF formats.
                    let path = value.string ?? value.object?.string("path")
                    if let path, let folder = resolveWindowsPath(path, in: prefix) { libraries.append(folder) }
                }
            }
            var seenLibraries: Set<String> = []
            for library in libraries {
                guard seenLibraries.insert(library.path).inserted,
                      let steamapps = resolveComponents(["steamapps"], from: library) else { continue }
                for file in (try? fm.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] {
                    let name = file.lastPathComponent.lowercased()
                    guard name.hasPrefix("appmanifest_"), name.hasSuffix(".acf"),
                          let text = try? String(contentsOf: file, encoding: .utf8),
                          let document = ValveKeyValues.parse(text)?.object("appstate"),
                          let id = document.string("appid"), !id.isEmpty, id.allSatisfy(\.isNumber),
                          let title = document.string("name"), let dir = document.string("installdir"),
                          !dir.isEmpty, !dir.contains("/"), !dir.contains("\\"), dir != ".", dir != "..",
                          let folder = resolveComponents(["common", dir], from: steamapps) else { continue }
                    let attributes = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let version = "\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(attributes?.fileSize ?? 0)"
                    let game = CrossOverGame(appID: id, name: title, folder: folder, bottle: prefix, steamExecutable: executable,
                                             fullyInstalled: document.string("stateflags") == "4", manifestVersion: version)
                    // A stale duplicate manifest must not create two actions for the same bottle/app.
                    if found[game.id] == nil || (!found[game.id]!.fullyInstalled && game.fullyInstalled) { found[game.id] = game }
                }
            }
        }
        return found.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func manualGame(executable: URL, bottle: URL) -> CrossOverGame? {
        let executable = canonical(executable), bottle = canonical(bottle)
        let fm = FileManager.default
        guard executable.pathExtension.lowercased() == "exe",
              (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              fm.fileExists(atPath: bottle.appendingPathComponent("cxbottle.conf").path),
              fm.fileExists(atPath: bottle.appendingPathComponent("system.reg").path),
              fm.fileExists(atPath: bottle.appendingPathComponent("drive_c/users").path) else { return nil }
        return CrossOverGame(appID: "manual", name: executable.deletingPathExtension().lastPathComponent,
                             folder: executable.deletingLastPathComponent(), bottle: bottle, steamExecutable: executable,
                             fullyInstalled: true, manifestVersion: "manual", executable: executable)
    }

    /// Resolves Wine drive mappings and case-insensitive Windows path components without writing.
    static func resolveWindowsPath(_ path: String, in prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let chars = Array(normalized)
        guard chars.count >= 3, chars[0].isASCII, chars[0].isLetter, chars[1] == ":", chars[2] == "/" else { return nil }
        let drive = String(chars[0]).lowercased()
        let mapping = prefix.appendingPathComponent("dosdevices/\(drive):")
        let fm = FileManager.default
        let base: URL
        if fm.fileExists(atPath: mapping.path) {
            base = canonical(mapping)
        } else if drive == "c" {
            base = prefix.appendingPathComponent("drive_c")
        } else { return nil }
        return resolveComponents(normalized.dropFirst(3).split(separator: "/").map(String.init), from: base)
    }

    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }

    static func resolveComponents(_ components: [String], from root: URL) -> URL? {
        let fm = FileManager.default
        var current = root
        guard fm.fileExists(atPath: current.path) else { return nil }
        for component in components where component != "." {
            if component == ".." { current.deleteLastPathComponent(); continue }
            let exact = current.appendingPathComponent(component)
            if fm.fileExists(atPath: exact.path) { current = exact; continue }
            guard let actual = ((try? fm.contentsOfDirectory(atPath: current.path)) ?? []).sorted()
                .first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) else { return nil }
            current.appendPathComponent(actual)
        }
        return canonical(current)
    }
}

/// Valve KeyValues with nested objects, comments, quoted names and Windows-safe escapes.
enum ValveKeyValues {
    indirect enum Value {
        case text(String)
        case dictionary([String: Value])
        var string: String? { if case .text(let value) = self { value } else { nil } }
        var object: [String: Value]? { if case .dictionary(let value) = self { value } else { nil } }
    }

    static func parse(_ text: String) -> [String: Value]? {
        var parser = Parser(characters: Array(text))
        return parser.object(nested: false, depth: 0)
    }

    static func quoted(_ text: String) -> String? {
        var parser = Parser(characters: Array(text))
        return parser.token()
    }

    private struct Parser {
        let characters: [Character]
        var index = 0

        mutating func whitespace() {
            while index < characters.count {
                if characters[index].isWhitespace || characters[index] == "\u{feff}" { index += 1; continue }
                if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count && !characters[index].isNewline { index += 1 }
                    continue
                }
                break
            }
        }

        mutating func token() -> String? {
            whitespace()
            guard index < characters.count, characters[index] != "{", characters[index] != "}" else { return nil }
            var result = ""
            if characters[index] == "\"" {
                index += 1
                while index < characters.count {
                    let char = characters[index]
                    index += 1
                    if char == "\"" { return result }
                    if char == "\\", index < characters.count,
                       characters[index] == "\\" || characters[index] == "\"" {
                        result.append(characters[index]); index += 1
                    } else { result.append(char) }
                }
                return nil
            }
            while index < characters.count && !characters[index].isWhitespace && characters[index] != "{" && characters[index] != "}" {
                result.append(characters[index]); index += 1
            }
            return result.isEmpty ? nil : result
        }

        mutating func object(nested: Bool, depth: Int) -> [String: Value]? {
            guard depth < 64 else { return nil }
            var values: [String: Value] = [:]
            while true {
                whitespace()
                if index == characters.count { return nested ? nil : values }
                if characters[index] == "}" {
                    guard nested else { return nil }
                    index += 1
                    return values
                }
                guard let key = token() else { return nil }
                whitespace()
                if index < characters.count && characters[index] == "{" {
                    index += 1
                    guard let child = object(nested: true, depth: depth + 1) else { return nil }
                    values[key.lowercased()] = .dictionary(child)
                } else {
                    guard let value = token() else { return nil }
                    values[key.lowercased()] = .text(value)
                }
            }
        }
    }
}

extension Dictionary where Key == String, Value == ValveKeyValues.Value {
    func string(_ key: String) -> String? { self[key.lowercased()]?.string }
    func object(_ key: String) -> [String: ValveKeyValues.Value]? { self[key.lowercased()]?.object }
}
