// Standalone Foundation fixtures. No installed application, bottle, Steam account or headset is used.
import Foundation

@main
struct CrossOverLibraryTests {
    enum Failure: Error { case check(String) }
    static var fm: FileManager { FileManager.default }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }

    static func write(_ text: String, to file: URL) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    static func makeBottle(_ prefix: URL) throws {
        try write("bottle settings must remain untouched", to: prefix.appendingPathComponent("cxbottle.conf"))
        try write("registry must remain untouched", to: prefix.appendingPathComponent("system.reg"))
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users/crossover"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
    }

    static func tree(_ root: URL) throws -> [String: Data] {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [:] }
        var result: [String: Data] = [:]
        while let file = walker.nextObject() as? URL {
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let key = String(file.path.dropFirst(root.path.count))
            if properties.isSymbolicLink == true {
                result[key] = Data(try fm.destinationOfSymbolicLink(atPath: file.path).utf8)
                walker.skipDescendants()
            } else if properties.isRegularFile == true { result[key] = try Data(contentsOf: file) }
        }
        return result
    }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("halliday-crossover-fixtures-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Realistic VDF strings: escaped slash and quote, unescaped Windows slash, nesting and comments.
        let values = ValveKeyValues.parse(#"""
        // ignored "misleading" { contents }
        "LibraryFolders" {
            "0" { "path" "C:\\Program Files (x86)\\Steam" }
            "1" "D:\new\tree"
            "label" "A \"quoted\" title"
        }
        "Empty" { }
        """#)
        try require(values?.object("libraryfolders")?.object("0")?.string("path") == #"C:\Program Files (x86)\Steam"#, "VDF escaped Windows path")
        try require(values?.object("libraryfolders")?.string("1") == #"D:\new\tree"#, "VDF preserves unknown Windows escapes")
        try require(values?.object("libraryfolders")?.string("label") == "A \"quoted\" title", "VDF escaped quotes")
        try require(ValveKeyValues.parse("\"root\" { \"key\" \"unfinished\"") == nil, "Incomplete VDF must not produce partial records")
        try require(ValveKeyValues.parse("}") == nil, "Unmatched braces rejected")

        let home = root.appendingPathComponent("home")
        let appDirectory = root.appendingPathComponent("Applications")
        for name in ["CrossOver.app", "CrossOver Preview.app", "CrossOver Preview backup.app"] {
            let wine = appDirectory.appendingPathComponent("\(name)/Contents/SharedSupport/CrossOver/bin/wine")
            try write("fixture only; never execute", to: wine)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        }

        let support = home.appendingPathComponent("Library/Application Support/CrossOver")
        let bottleRoot = support.appendingPathComponent("Bottles")
        let prefix = bottleRoot.appendingPathComponent("Steam")
        try makeBottle(prefix)
        try fm.createSymbolicLink(atPath: bottleRoot.appendingPathComponent("Steam alias").path, withDestinationPath: prefix.path)
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        try write("Steam fixture", to: steam.appendingPathComponent("Steam.EXE"))
        let external = root.appendingPathComponent("External volume")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/a:").path, withDestinationPath: external.path)
        try write(#"""
        "libraryfolders" {
            "0" { "path" "c:\\program files (x86)\\steam" }
            "1" { "path" "A:\\steamlibrary" }
            "2" { "path" "M:\\Disconnected" }
        }
        """#, to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let library = external.appendingPathComponent("SteamLibrary/SteamApps")
        let gameFolder = library.appendingPathComponent("Common/Sample Game")
        try write("an existing game", to: gameFolder.appendingPathComponent("Game.EXE"))
        try write("existing VR mod must survive discovery", to: gameFolder.appendingPathComponent("dxgi.dll"))
        try write("VR loader", to: gameFolder.appendingPathComponent("Data/Plugins/x86_64/OpenVR_API.DLL"))
        try write(#"""
        "AppState" {
            "appid" "42"
            "name" "Sample \"VR\" Game"
            "installdir" "sample GAME"
            "StateFlags" "4"
        }
        """#, to: library.appendingPathComponent("AppManifest_42.ACF"))
        try write("\"AppState\" {", to: library.appendingPathComponent("appmanifest_broken.acf"))
        try write(#"""
        "AppState" { "appid" "9;invalid" "name" "Invalid" "installdir" "Sample Game" }
        """#, to: library.appendingPathComponent("appmanifest_invalid.acf"))
        try write(#"""
        "AppState" { "appid" "43" "name" "Outside" "installdir" "../Sample Game" }
        """#, to: library.appendingPathComponent("appmanifest_traversal.acf"))

        // A second bottle uses the old VDF format and a custom Steam installation from its registry.
        let customRoot = root.appendingPathComponent("Custom bottles")
        let custom = customRoot.appendingPathComponent("Second Steam")
        try makeBottle(custom)
        try write(#"""
        [Software\\Valve\\Steam]
        "SteamPath"="C:\\Custom Steam"
        [Software\\Unrelated]
        "SteamPath"="C:\\Wrong"
        """#, to: custom.appendingPathComponent("user.reg"))
        let customSteam = custom.appendingPathComponent("drive_c/Custom Steam")
        try write("custom steam", to: customSteam.appendingPathComponent("steam.exe"))
        try fm.createSymbolicLink(atPath: custom.appendingPathComponent("dosdevices/a:").path, withDestinationPath: external.path)
        try write(#"""
        "LibraryFolders" { "1" "A:\\SteamLibrary" }
        """#, to: customSteam.appendingPathComponent("config/libraryfolders.vdf"))
        try write("[CrossOver]\n\"BottlePath\" = \"\(customRoot.path)\"\n", to: support.appendingPathComponent("CrossOver.conf"))

        let before = try tree(root)
        let discovery = CrossOverLibrary.discover(home: home, applicationDirectories: [appDirectory], additionalBottleRoots: [bottleRoot, customRoot])
        try require(discovery.installations.count == 2, "Stable and Preview found, backup ignored")
        try require(discovery.installations.first?.name == "CrossOver", "Stable is deterministic initial engine")
        try require(discovery.bottles.count == 2, "Canonical prefixes deduplicate aliases and repeated roots")
        try require(discovery.games.count == 2, "Both external-library Steam manifests discovered, invalid records skipped")
        try require(Set(discovery.games.map(\.id)).count == 2, "Same app id in two bottles has two identities")
        try require(discovery.games.allSatisfy { $0.appID == "42" && $0.name == "Sample \"VR\" Game" && $0.fullyInstalled }, "Manifest parsed without losing quoted name")
        try require(discovery.games.allSatisfy { fm.fileExists(atPath: $0.folder.appendingPathComponent("Game.EXE").path) }, "Case-insensitive library and game folder paths resolve")
        try require(CrossOverLibrary.resolveWindowsPath(#"M:\Offline"#, in: prefix) == nil, "Unmapped or offline drives skipped")
        try require(CrossOverLibrary.resolveWindowsPath(#"C:relative"#, in: prefix) == nil, "Drive-relative paths are not guessed")
        try require(CrossOverLibrary.resolveWindowsPath(#"a:\SteamLibrary\steamapps\COMMON\sample game\game.exe"#, in: prefix) != nil, "Windows path casing works to executable level")

        let manual = CrossOverLibrary.manualGame(executable: gameFolder.appendingPathComponent("Game.EXE"), bottle: prefix)
        let manualOtherBottle = CrossOverLibrary.manualGame(executable: gameFolder.appendingPathComponent("Game.EXE"), bottle: custom)
        try require(manual?.executable != nil && manual?.id != manualOtherBottle?.id, "Manual games preserve bottle identity without requiring a VR DLL")
        try require(CrossOverLibrary.manualGame(executable: gameFolder.appendingPathComponent("dxgi.dll"), bottle: prefix) == nil, "Manual import only accepts an existing executable")
        let after = try tree(root)
        try require(before == after, "Discovery and manual descriptor creation must leave all bottle, Steam and mod bytes unchanged")
        print("CrossOver library fixtures passed: VDF, external drives, case handling, custom Steam, aliases, identity, manual imports and read-only discovery")
    }
}
