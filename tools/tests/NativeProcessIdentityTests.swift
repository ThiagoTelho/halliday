import Foundation
import Darwin

@main struct NativeProcessIdentityTests {
    static func main() {
        let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
        guard let identity = NativeProcessIdentity.capture(pid: getpid(), expectedBasename: name) else {
            fatalError("Could not identify the owned native test process")
        }
        precondition(identity.isAlive)
        precondition(NativeProcessIdentity.capture(pid: getpid(), expectedBasename: "another-bridge") == nil)
        precondition(NativeProcessIdentity.capture(pid: -1, expectedBasename: name) == nil)
        let reused = NativeProcessIdentity(pid: identity.pid, executable: identity.executable,
            startedSeconds: identity.startedSeconds + 1, startedMicroseconds: identity.startedMicroseconds)
        precondition(!reused.isAlive)
        print("PASS: native PID, exact executable and process start-time identity; no name-substring fallback")
    }
}
