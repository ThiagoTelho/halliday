// Who uses the GPU, by process (ROADMAP 1.13): the share of the GPU's time each program had since
// the last look, read from IOKit (each GPU client's `AppUsage` / `accumulatedGPUTime`, under the
// GPU's IOAccelerator, with the process that made it in `IOUserClientCreator`): what Activity
// Monitor's GPU column shows.
//
// Why: the `[stat]` line's `gpu=` is how long Halliday's frames take on the GPU's clock, from
// their start to their end, which also counts the time the GPU spends on other programs' work in
// between. A frame that takes 17 ms with nothing more drawn is often waiting: this says on whom
// (the WebKit process drawing a page, WindowServer, another app). Appended to each `[stat]` line
// as `gpu-share=`; the look itself is taken on a queue of its own, never on the main thread.

import Foundation
import IOKit

final class GPUShare: @unchecked Sendable {
    static let shared = GPUShare()

    private let queue = DispatchQueue(label: "halliday.gpu-share", qos: .utility)
    private let lock = NSLock()
    private var before: [String: UInt64] = [:]
    private var beforeAt: UInt64 = 0
    private var latest = ""

    /// The shares from the last look (the biggest few, 2 % or more), and a new look started.
    func take() -> String {
        lock.lock()
        let s = latest
        lock.unlock()
        queue.async { self.look() }
        return s
    }

    private func look() {
        let now = DispatchTime.now().uptimeNanoseconds
        let totals = Self.read()
        lock.lock()
        defer { lock.unlock() }
        if beforeAt > 0, now > beforeAt {
            let span = Double(now - beforeAt)
            let shares = totals.compactMap { name, ns -> (String, Double)? in
                guard let was = before[name], ns >= was else { return nil }
                return (name, Double(ns - was) / span * 100)
            }
            .filter { $0.1 >= 2 }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            latest = shares.map { String(format: "%@ %.0f%%", $0.0, $0.1) }.joined(separator: ", ")
        }
        before = totals
        beforeAt = now
    }

    /// Each process's GPU time so far, in nanoseconds, by name (several processes of one name,
    /// such as WebKit's, add up).
    private static func read() -> [String: UInt64] {
        var totals: [String: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return totals }
        defer { IOObjectRelease(accelerators) }
        while case let gpu = IOIteratorNext(accelerators), gpu != 0 {
            defer { IOObjectRelease(gpu) }
            var clients: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(gpu, kIOServicePlane, &clients) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(clients) }
            while case let client = IOIteratorNext(clients), client != 0 {
                defer { IOObjectRelease(client) }
                guard let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]],
                      let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String else { continue }
                // "pid 397, WindowServer"
                let name = creator.split(separator: ",", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? creator
                let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                totals[name, default: 0] += ns
            }
        }
        return totals
    }
}
