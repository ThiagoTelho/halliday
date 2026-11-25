import Foundation
@main struct GameResumeFocusTests {
    static func main() {
        func identity(_ pid: Int32, _ name: String, _ started: UInt64 = 1) -> NativeProcessIdentity {
            .init(pid: pid, executable: "/fixture/" + name, startedSeconds: started, startedMicroseconds: 12)
        }
        func candidate(_ pid: Int32, _ parent: Int32, _ image: String,
                       window: Bool = true, app: Bool = true) -> GameResumeFocus.Candidate {
            .init(identity: identity(pid, GameResumeFocus.basename(image)), parentPID: parent,
                image: image, hasWindow: window, canActivate: app)
        }
        let re8 = GameResumeFocus.Producer(name: "re8.exe", pid: 496, nativePID: nil, lease: "epoch1")
        let game = candidate(43278, 40000, "A:\\Games\\RE8\\re8.exe")
        let steam = candidate(496, 1, "C:\\Steam\\steam.exe") // deliberate Windows/native PID collision
        let helper = candidate(43311, 43278, "A:\\Games\\VR\\OpenXRHelper64.exe", window: false)
        let all = [steam, game, helper]
        let target = GameResumeFocus.select(producer: re8, candidates: all)
        precondition(target?.identity.pid == 43278)
        precondition(!GameResumeFocus.shouldActivate(target, producer: re8, frontmostPID: 43278,
            currentIdentity: game.identity))
        precondition(GameResumeFocus.shouldActivate(target, producer: re8, frontmostPID: 777,
            currentIdentity: game.identity))
        precondition(!GameResumeFocus.shouldActivate(target, producer: re8, frontmostPID: 777,
            currentIdentity: identity(43278, "re8.exe", 2))) // recycled PID
        let replaced = GameResumeFocus.Producer(name: "re8.exe", pid: 496, nativePID: nil, lease: "epoch2")
        precondition(!GameResumeFocus.shouldActivate(target, producer: replaced, frontmostPID: 777,
            currentIdentity: game.identity))
        precondition(GameResumeFocus.select(producer: re8, candidates: [steam]) == nil)
        precondition(GameResumeFocus.select(producer: re8, candidates: [game,
            candidate(55000, 1, "B:\\Other\\re8.exe")]) == nil) // never guess across bottles
        precondition(GameResumeFocus.select(producer: re8, candidates: [
            candidate(43278, 1, "A:\\Games\\re8.exe", window: false)]) == nil)
        precondition(GameResumeFocus.select(producer: re8, candidates: [
            candidate(43278, 1, "A:\\Games\\re8.exe", window: false),
            candidate(55000, 1, "B:\\Other\\re8.exe")]) == nil)
        let bridged = GameResumeFocus.Producer(name: "OpenXRHelper64.exe", pid: 2040,
            nativePID: nil, lease: "epoch3")
        precondition(GameResumeFocus.select(producer: bridged, candidates: all) == nil) // unbound global helper
        let boundHelper = GameResumeFocus.Producer(name: "OpenXRHelper64.exe", pid: 2040,
            nativePID: 43311, lease: "verified-native-helper")
        precondition(GameResumeFocus.select(producer: boundHelper, candidates: all)?.identity.pid == 43278)
        precondition(GameResumeFocus.select(producer: bridged, candidates: [helper, steam]) == nil)
        precondition(GameResumeFocus.select(producer: bridged, candidates: [game, helper,
            candidate(60000, 43278, "B:\\VR\\OpenXRHelper64.exe", window: false)]) == nil)
        let replacementGame = candidate(55000, 1, "B:\\Other\\re8.exe")
        let alternate = GameResumeFocus.Target(producer: re8, identity: replacementGame.identity)
        let sticky = GameResumeFocus.preferRemembered(target, discovered: alternate, producer: re8)
        precondition(sticky == target)
        precondition(!GameResumeFocus.shouldActivate(sticky, producer: re8,
            frontmostPID: 777, currentIdentity: nil)) // dead old owner never selects replacement
        let nextTarget = GameResumeFocus.Target(producer: replaced, identity: replacementGame.identity)
        precondition(GameResumeFocus.preferRemembered(target, discovered: nextTarget,
            producer: replaced) == nextTarget)
        let request = GameResumeFocus.Request(producer: re8, revision: 4, originalFrontmostPID: 777)
        precondition(request.accepts(producer: re8, revision: 4, presenting: true,
            dashboard: false, frontmostPID: 777, targetPID: 43278))
        precondition(!request.accepts(producer: re8, revision: 5, presenting: true,
            dashboard: false, frontmostPID: 777, targetPID: 43278)) // newer menu/resume wins
        precondition(!request.accepts(producer: re8, revision: 4, presenting: true,
            dashboard: true, frontmostPID: 777, targetPID: 43278)) // menu reopened
        precondition(!request.accepts(producer: replaced, revision: 4, presenting: true,
            dashboard: false, frontmostPID: 777, targetPID: 43278)) // different producer
        precondition(!request.accepts(producer: re8, revision: 4, presenting: true,
            dashboard: false, frontmostPID: 888, targetPID: 43278)) // user chose another app
        precondition(!request.accepts(producer: re8, revision: 4, presenting: false,
            dashboard: false, frontmostPID: 777, targetPID: 43278)) // stopped game
        let native = GameResumeFocus.Producer(name: "Alyx", pid: 9000, nativePID: 9000, lease: "native1")
        let alyx = candidate(9000, 1, "/fixture/alyx_host")
        precondition(GameResumeFocus.select(producer: native, candidates: [game, alyx])?.identity.pid == 9000)
        precondition(GameResumeFocus.image(command: "A:\\SteamLibrary\\Black Mesa\\bms.exe -steam")
            == "A:\\SteamLibrary\\Black Mesa\\bms.exe")
        precondition(GameResumeFocus.image(command: "C:\\Wine\\winewrapper.exe --start A:\\Games\\re8.exe")
            == "C:\\Wine\\winewrapper.exe")
        precondition(GameResumeFocus.image(command: "\"A:\\Black Mesa\\bms.exe\" -steam")
            == "A:\\Black Mesa\\bms.exe")
        print("PASS: CPU mocks select a validated native game/window without SCK, rejects Windows-PID collisions, helpers/Steam, missing windows, duplicate games/helpers, stale leases and recycled PIDs; already focused games are no-ops")
    }
}
