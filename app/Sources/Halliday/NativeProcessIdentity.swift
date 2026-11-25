import Foundation
import Darwin

/// A native client PID is an OS identity, rather than a Windows process number
/// or a name search. Include start time so a recycled PID cannot target a new process.
struct NativeProcessIdentity: Equatable {
    let pid: pid_t
    let executable: String
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    static func capture(pid: pid_t, expectedBasename: String) -> Self? {
        guard pid > 0, !expectedBasename.isEmpty else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard URL(fileURLWithPath: executable).lastPathComponent == expectedBasename else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Self(pid: pid, executable: executable,
                    startedSeconds: info.pbi_start_tvsec, startedMicroseconds: info.pbi_start_tvusec)
    }

    var isAlive: Bool {
        Self.capture(pid: pid, expectedBasename: URL(fileURLWithPath: executable).lastPathComponent) == self
    }
}
