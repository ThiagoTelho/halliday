import Foundation
import CHallidayCore

struct GameHapticEvent: Sendable {
    var hand: Int
    var sequence: UInt32 = 0
    var stop: Bool
    var amplitude: Float = 0
    var frequencyHz: Float = 0
    var durationNanoseconds: UInt64 = 0
}

/// Poll independently of rendering: the runtime's default pulse lasts only 10 ms.
/// All output callbacks, focus changes and close are ordered on one short queue.
final class GameHapticFeed: @unchecked Sendable {
    typealias Connected = @Sendable () -> UInt32
    typealias Output = @Sendable (GameHapticEvent) -> Void

    private final class Context: @unchecked Sendable {
        let receiver: OpaquePointer
        let connected: Connected
        let output: Output
        var focused = true
        var closed = false
        var outputEpoch: UInt64 = 0
        var pendingStopHands: [Int]? = nil

        init(receiver: OpaquePointer, connected: @escaping Connected, output: @escaping Output) {
            self.receiver = receiver
            self.connected = connected
            self.output = output
        }

        deinit {
            halliday_bridge_haptics_close(receiver)
        }

        func poll() {
            guard !closed else { return }
            var commands = [HallidayGameHapticCommand](repeating: .init(), count: 4)
            let count = commands.withUnsafeMutableBufferPointer {
                halliday_bridge_haptics_poll(receiver, 0, focused, connected(), $0.baseAddress, 4)
            }
            let epoch = outputEpoch
            for command in commands.prefix(Int(count)) {
                guard !closed, outputEpoch == epoch else { break }
                if command.stop == 0 && !focused { continue }
                output(GameHapticEvent(hand: Int(command.hand), sequence: command.sequence,
                    stop: command.stop != 0, amplitude: command.amplitude,
                    frequencyHz: command.frequency_hz, durationNanoseconds: command.duration_ns))
            }
        }

        func stop() {
            if pendingStopHands == nil {
                outputEpoch &+= 1
                var commands = [HallidayGameHapticCommand](repeating: .init(), count: 2)
                _ = commands.withUnsafeMutableBufferPointer {
                    halliday_bridge_haptics_stop(receiver, $0.baseAddress, 2)
                }
                pendingStopHands = [0, 1]
            }
            // Also cancel a request already accepted by the device's output queue.
            // If an output callback itself closes the feed, its nested stop drains
            // the remaining hand before close returns; the outer call cannot emit late.
            while let hand = pendingStopHands?.first {
                pendingStopHands?.removeFirst()
                output(GameHapticEvent(hand: hand, stop: true))
            }
            pendingStopHands = nil
        }
    }

    private let queue = DispatchQueue(label: "app.halliday.game-haptics", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let context: Context
    private let timer: DispatchSourceTimer

    convenience init?(bridgePath: URL, connected: @escaping Connected, output: @escaping Output) {
        guard let receiver = bridgePath.path.withCString({ halliday_bridge_haptics_open($0) }) else { return nil }
        self.init(receiver: receiver, connected: connected, output: output)
    }

    private init(receiver: OpaquePointer, connected: @escaping Connected, output: @escaping Output) {
        context = Context(receiver: receiver, connected: connected, output: output)
        timer = DispatchSource.makeTimerSource(queue: queue)
        queue.setSpecific(key: queueKey, value: 1)
        let context = context
        timer.setEventHandler { context.poll() }
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.resume()
    }

    /// Call before clearing the native dashboard flag on resume. The receiver's
    /// resume edge is observed before the Windows runtime can issue a fresh pulse.
    func setFocused(_ focused: Bool) {
        serialized {
            guard !context.closed, context.focused != focused else { return }
            context.focused = focused
            if !focused { context.stop() }
            context.poll()
        }
    }

    func close() {
        timer.cancel()
        serialized {
            guard !context.closed else { return }
            context.closed = true
            context.focused = false
            context.stop()
        }
    }

    /// Cancel accepted output while keeping the current focus state. The
    /// Windows proxy gates requests from an exiting session; a later session
    /// can deliver its first pulse without waiting for a UI pause/resume edge.
    func cancelPending() {
        serialized {
            guard !context.closed else { return }
            context.stop()
            context.poll()
        }
    }

    private func serialized(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { body() }
        else { queue.sync(execute: body) }
    }

    deinit { close() }
}
