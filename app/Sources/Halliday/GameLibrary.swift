// The VR games Halliday can run, and whether each is set up for it (ROADMAP W14.8, design board 15).
//
// GameHub keeps its Steam library in a folder of its own (`steam-library-registry.v1.json`), one
// `appmanifest_<id>.acf` per installed game, and binds a game to a Wine "virtual container" the
// first time it starts (`gamehub/game_container_store.json`). A game is a VR game when its folder
// holds `openvr_api.dll` (found once, then remembered). Its state comes from its container's
// `openvrpaths.vrpath`, which says which OpenVR runtime the game loads (`GameBridge.install`).
//
// Nothing is written before the user says yes (the first-time screen); what was there before is
// kept beside the file and put back by Undo. Halliday remembers in UserDefaults that the user said
// yes, whether games added later are set up too, the containers it set up, which games are VR games,
// and each game's last launch (when, how long, or why it stopped).

import Foundation

/// One VR game in GameHub.
struct GameEntry: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// Set up, runtime current.
        case ready
        /// It tried and stopped (the reason, for the user).
        case stopped(String)
        /// Its container still points at another runtime (or none).
        case notSetUp
        /// No container yet: GameHub makes it at the game's first start.
        case firstLaunch
        /// Halliday had set it up, and another app changed the file since.
        case changed
        /// It points at a Halliday runtime folder that isn't this one.
        case update

        var label: String {
            switch self {
            case .ready: "Ready"
            case .stopped: "Stopped at launch"
            case .notSetUp: "Not set up"
            case .firstLaunch: "First launch"
            case .changed: "Changed by another app"
            case .update: "Runtime out of date"
            }
        }

        /// Problems first, then games to set up, then ready ones.
        var rank: Int {
            switch self {
            case .stopped: 0
            case .changed, .update: 1
            case .notSetUp: 2
            case .firstLaunch: 3
            case .ready: 4
            }
        }
    }

    let appID: String
    let name: String
    /// The game's executables (file names), to tell which game the runtime connected from.
    let executables: [String]
    /// Its Wine prefix (GameHub's virtual container), once it has one.
    let container: URL?
    var status: Status
    /// Its last launch in Halliday: when, and for how long.
    var lastPlayed: Date?
    var lastMinutes: Int?
    /// A Quest app installed in Halliday (its package), not a GameHub game: `QuestApps` runs it.
    var quest: String? = nil
}

/// What happened the last time a game started, kept per executable.
struct GameLaunch: Codable {
    var at: Date
    /// Minutes it ran in Halliday (nil: it never showed a frame).
    var minutes: Int?
    /// Why it stopped before its first frame, for the user.
    var problem: String?
}

@MainActor
final class GameLibrary {
    static let shared = GameLibrary()
    nonisolated static let sample = CommandLine.arguments.contains("--sample-games")

    private(set) var games: [GameEntry] = []
    /// GameHub is installed (its data folder exists).
    private(set) var hasGameHub = false
    private(set) var loaded = false
    private var loading = false
    /// Called after every refresh (on the main actor).
    var onChange: (() -> Void)?
    /// Called with a message when games were set up on their own (games added later).
    var onNotice: ((String) -> Void)?

    nonisolated static let gameHub = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.gamemac.www")

    // --- What the user chose, and what Halliday remembers ---

    private let defaults = UserDefaults.standard
    /// The user said yes on the first-time screen (or set up a game by hand).
    var consented: Bool {
        get { defaults.bool(forKey: "gamesConsented") }
        set { defaults.set(newValue, forKey: "gamesConsented") }
    }
    /// Games that get a container later are set up as soon as it appears (while Halliday runs).
    var setsUpNewGames: Bool {
        get { defaults.object(forKey: "gamesSetUpNew") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "gamesSetUpNew") }
    }
    /// Containers Halliday set up (to tell "changed by another app" from "never set up").
    private var setUpContainers: Set<String> {
        get { Set(defaults.stringArray(forKey: "gamesSetUpContainers") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "gamesSetUpContainers") }
    }
    /// Containers seen so far (a new one is a game added later).
    private var seenContainers: Set<String> {
        get { Set(defaults.stringArray(forKey: "gamesSeenContainers") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "gamesSeenContainers") }
    }
    /// Per Steam app id: its executables if it is a VR game, [] if it isn't.
    private var vrScan: [String: [String]] {
        get { defaults.dictionary(forKey: "gamesVRScan") as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: "gamesVRScan") }
    }

    private var launches: [String: GameLaunch] {
        get {
            guard let data = defaults.data(forKey: "gamesLaunches") else { return [:] }
            return (try? JSONDecoder().decode([String: GameLaunch].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "gamesLaunches") }
    }

    /// Records a launch of the game whose executable is `exe`.
    func recordLaunch(exe: String, minutes: Int?, problem: String?, at: Date = Date()) {
        var all = launches
        all[exe.lowercased()] = GameLaunch(at: at, minutes: minutes, problem: problem)
        launches = all
        refresh()
    }

    /// The game a running executable belongs to.
    func game(forExecutable exe: String) -> GameEntry? {
        let e = exe.lowercased()
        return games.first { $0.executables.contains { $0.lowercased() == e } }
    }

    /// A game's name for the user: its library name, or its executable without ".exe".
    func displayName(forExecutable exe: String) -> String {
        game(forExecutable: exe)?.name ?? (exe.lowercased().hasSuffix(".exe") ? String(exe.dropLast(4)) : exe)
    }

    // --- Reading GameHub ---

    /// Reads the library again, off the main thread; `onChange` follows.
    func refresh() {
        // Debug (`--sample-games`): example games instead of the user's library, for screenshots.
        // They have no container, so no action writes anything.
        if Self.sample {
            let now = Date()
            games = [GameEntry(appID: "sample1", name: "Summit Flight", executables: [], container: nil, status: .ready,
                               lastPlayed: now.addingTimeInterval(-3 * 3600), lastMinutes: 42),
                     GameEntry(appID: "sample2", name: "Tinker Workshop", executables: [], container: nil, status: .ready,
                               lastPlayed: now.addingTimeInterval(-26 * 3600), lastMinutes: 18),
                     GameEntry(appID: "sample3", name: "Harbor Lights", executables: [], container: nil, status: .notSetUp),
                     GameEntry(appID: "sample4", name: "Orbital Garden", executables: [], container: nil, status: .firstLaunch),
                     GameEntry(appID: "quest:app.example.paperplanets", name: "Paper Planets", executables: [], container: nil, status: .ready,
                               lastPlayed: now.addingTimeInterval(-50 * 3600), lastMinutes: 25, quest: "app.example.paperplanets")]
            hasGameHub = true
            loaded = true
            onChange?()
            return
        }
        guard !loading else { return }
        loading = true
        let scan = vrScan, setUp = setUpContainers, history = launches
        Task.detached(priority: .utility) {
            let result = Self.read(scan: scan, setUp: setUp, history: history)
            await MainActor.run {
                self.loading = false
                self.loaded = true
                self.hasGameHub = result.hasGameHub
                if result.scan != scan { self.vrScan = result.scan }
                self.apply(result.games)
            }
        }
    }

    private func apply(_ list: [GameEntry]) {
        games = list
        // Games added later: set up as their container appears, if the user asked for that.
        let containers = Set(list.compactMap { $0.container?.lastPathComponent })
        let new = containers.subtracting(seenContainers)
        if !new.isEmpty {
            let first = seenContainers.isEmpty
            seenContainers = seenContainers.union(new)
            if !first, consented, setsUpNewGames {
                for g in list where g.status == .notSetUp && new.contains(g.container?.lastPathComponent ?? "") {
                    if setUp(g) { onNotice?("\(g.name) is ready to play in Halliday") }
                }
            }
        }
        onChange?()
    }

    private struct ReadResult: Sendable {
        var games: [GameEntry]
        var scan: [String: [String]]
        var hasGameHub: Bool
    }

    nonisolated private static func read(scan: [String: [String]], setUp: Set<String>, history: [String: GameLaunch]) -> ReadResult {
        let fm = FileManager.default
        let root = gameHub
        // Without GameHub there are still the Quest apps installed in Halliday itself.
        guard fm.fileExists(atPath: root.path) else { return ReadResult(games: questGames(history: history), scan: scan, hasGameHub: false) }
        var scan = scan
        // The Steam libraries GameHub uses.
        var libraries: [URL] = []
        if let data = try? Data(contentsOf: root.appendingPathComponent("steam-client/steam-library-registry.v1.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["libraries"] as? [[String: Any]] {
            libraries = list.compactMap { ($0["canonicalRoot"] as? String).map { URL(fileURLWithPath: $0) } }
        }
        // Containers by Steam app id.
        var containers: [String: URL] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("gamehub/game_container_store.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let bindings = json["bindings"] as? [[String: Any]] {
            for b in bindings {
                guard let id = b["platform_app_id"] as? String, let vc = b["virtual_container_id"] as? String else { continue }
                let prefix = root.appendingPathComponent("wine-engine/containers/virtual_containers/\(vc)")
                if fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/users").path) { containers[id] = prefix }
            }
        }
        var games: [GameEntry] = []
        for library in libraries {
            let steamapps = library.appendingPathComponent("steamapps")
            let manifests = (try? fm.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in manifests where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let id = value("appid", in: text), let name = value("name", in: text),
                      let dir = value("installdir", in: text) else { continue }
                let folder = steamapps.appendingPathComponent("common").appendingPathComponent(dir)
                let exes: [String]
                if let known = scan[id] {
                    exes = known
                } else {
                    exes = vrExecutables(in: folder)
                    // Remembered once the game is fully installed (Steam's StateFlags 4), not while
                    // it downloads.
                    if value("StateFlags", in: text) == "4" { scan[id] = exes }
                }
                guard !exes.isEmpty else { continue }
                let container = containers[id]
                var entry = GameEntry(appID: id, name: name, executables: exes, container: container,
                                      status: status(container: container, setUp: setUp))
                // Its latest launch, from any of its executables.
                if let last = exes.compactMap({ history[$0.lowercased()] }).max(by: { $0.at < $1.at }) {
                    if let minutes = last.minutes {
                        entry.lastPlayed = last.at
                        entry.lastMinutes = minutes
                    } else if let problem = last.problem, entry.status == .ready {
                        entry.status = .stopped(problem)
                    }
                }
                games.append(entry)
            }
        }
        games += questGames(history: history)
        games.sort { a, b in
            if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
            if a.lastPlayed != b.lastPlayed { return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast) }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return ReadResult(games: games, scan: scan, hasGameHub: true)
    }

    /// The Quest apps installed in Halliday, as games: ready when there is a way to start them.
    nonisolated static func questGames(history: [String: GameLaunch]) -> [GameEntry] {
        QuestApps.installed().map { app in
            let status: GameEntry.Status = app.canStart
                ? .ready
                : .stopped("Halliday has no way to start this kind of app yet (\(app.engine) engine).")
            var entry = GameEntry(appID: "quest:\(app.package)", name: app.name, executables: [app.name], container: nil, status: status)
            entry.quest = app.package
            if let last = history[app.name.lowercased()] {
                if let minutes = last.minutes {
                    entry.lastPlayed = last.at
                    entry.lastMinutes = minutes
                } else if let problem = last.problem, entry.status == .ready {
                    entry.status = .stopped(problem)
                }
            }
            return entry
        }
    }

    /// A quoted value of a Valve KeyValues file (`"key"  "value"`), the first one.
    nonisolated private static func value(_ key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).filter { !$0.allSatisfy(\.isWhitespace) }
            if parts.count >= 2, parts[0].lowercased() == key { return String(parts[1]) }
        }
        return nil
    }

    /// The executables of a game folder that ships `openvr_api.dll` (a VR game); [] otherwise.
    /// Looks a few folders deep (Unity keeps it in `…_Data/Plugins/x86_64`).
    nonisolated private static func vrExecutables(in folder: URL) -> [String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var vr = false, exes: [String] = []
        var seen = 0
        while let url = walker.nextObject() as? URL {
            seen += 1
            if walker.level > 5 { walker.skipDescendants(); continue }
            if seen > 60_000 { break }
            let name = url.lastPathComponent.lowercased()
            if name == "openvr_api.dll" { vr = true }
            if name.hasSuffix(".exe"), walker.level <= 3, !name.contains("unitycrashhandler"), !name.contains("setup"),
               !name.contains("redist"), !name.hasPrefix("vc_") { exes.append(url.lastPathComponent) }
        }
        return vr ? exes : []
    }

    /// A container's state from its `openvrpaths.vrpath` files (one per Windows user).
    nonisolated private static func status(container: URL?, setUp: Set<String>) -> GameEntry.Status {
        guard let container else { return .firstLaunch }
        let fm = FileManager.default
        let users = container.appendingPathComponent("drive_c/users")
        let names = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" && !$0.hasPrefix(".") }
        let ours = GameBridge.windowsPath(GameBridge.folder)
        var anyOurs = false, allOurs = !names.isEmpty, otherHalliday = false
        for name in names {
            let file = users.appendingPathComponent(name).appendingPathComponent("AppData/Local/openvr/openvrpaths.vrpath")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let runtime = (json["runtime"] as? [String])?.first else { allOurs = false; continue }
            if runtime == ours { anyOurs = true } else {
                allOurs = false
                if runtime.contains("Halliday") { otherHalliday = true }
            }
        }
        if allOurs { return .ready }
        if otherHalliday { return .update }
        if anyOurs || setUp.contains(container.lastPathComponent) { return .changed }
        return .notSetUp
    }

    // --- Actions ---

    /// Points the game's container at Halliday (Set up, Repair, Update). False on failure.
    @discardableResult
    func setUp(_ game: GameEntry) -> Bool {
        guard let container = game.container, GameBridge.installRuntime() else { return false }
        do {
            _ = try GameBridge.install(prefix: container)
            consented = true
            setUpContainers = setUpContainers.union([container.lastPathComponent])
            log("[games] set up \(game.name) (container \(container.lastPathComponent))")
            refresh()
            return true
        } catch {
            log("[games] couldn't set up \(game.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Puts back what the container had before Halliday (or removes Halliday's file).
    @discardableResult
    func undo(_ game: GameEntry) -> Bool {
        guard let container = game.container else { return false }
        do {
            try GameBridge.uninstall(prefix: container)
            setUpContainers = setUpContainers.subtracting([container.lastPathComponent])
            log("[games] undid the set-up of \(game.name)")
            refresh()
            return true
        } catch {
            log("[games] couldn't undo \(game.name): \(error.localizedDescription)")
            return false
        }
    }

    /// Every game that has a container and isn't set up (the first-time screen's "Set up all").
    func setUpAll() -> Int {
        if Self.sample { return 0 }
        consented = true
        return games.filter { $0.container != nil && $0.status != .ready }.reduce(0) { $0 + (setUp($1) ? 1 : 0) }
    }

    /// GameHub's link that starts a Steam game (the one its desktop shortcuts use).
    static func playURL(_ game: GameEntry) -> URL? { sample ? nil : URL(string: "gamehub://launch/steam/\(game.appID)") }

    // --- What the runtime said while Halliday wasn't running ---

    /// Reads the runtime's log, before Halliday clears it at start: a game that started while
    /// Halliday wasn't running says so ("X.exe: started while Halliday isn't running").
    static func readMissedLaunches(log url: URL) -> [(exe: String, at: Date)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let at = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
        var found: [String: Date] = [:]
        for line in text.split(separator: "\n") where line.contains(": started while Halliday isn't running") {
            let body = line.replacingOccurrences(of: "[halliday-vrclient] ", with: "")
            if let exe = body.components(separatedBy: ": started while").first, !exe.isEmpty { found[exe] = at }
        }
        return found.map { ($0.key, $0.value) }
    }
}
