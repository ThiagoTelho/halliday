import Foundation

/// Device-independent output policy. Its owner serializes calls; tests supply a fake clock/sink.
/// Generation numbers bind queued work to one physical connection, never a later reconnect.
struct SenseHapticScheduler: Sendable {
    struct Output: Equatable, Sendable {
        var hand: Int
        var generation: UInt64
        var amplitude: Float
        var frequencyHz: Float
    }
    private struct Playing: Sendable {
        var amplitude: Float
        var frequencyHz: Float
        var until: UInt64
        var resend: UInt64
    }
    private struct Connection: Sendable {
        var generation: UInt64
        var bluetooth: Bool
        var counter: UInt8 = 0
        var playing: Playing? = nil
    }
    private var connections: [Connection?] = [nil, nil]
    static let resendNanoseconds: UInt64 = 2_000_000_000

    static func valid(amplitude: Float, frequencyHz: Float, durationNanoseconds: UInt64) -> Bool {
        amplitude.isFinite && (0...1).contains(amplitude) && frequencyHz.isFinite && frequencyHz >= 0 &&
            durationNanoseconds <= UInt64(Int64.max)
    }

    mutating func connect(hand: Int, generation: UInt64, bluetooth: Bool) {
        guard connections.indices.contains(hand) else { return }
        connections[hand] = Connection(generation: generation, bluetooth: bluetooth)
    }

    mutating func disconnect(hand: Int, generation: UInt64) {
        guard connections.indices.contains(hand), connections[hand]?.generation == generation else { return }
        connections[hand] = nil
    }

    /// Both LEDs and vibration allocate their report sequence here, at actual submission time.
    mutating func nextReport(hand: Int, generation: UInt64) -> (sequence: UInt8, counter: UInt8)? {
        guard connections.indices.contains(hand), var connection = connections[hand], connection.generation == generation else { return nil }
        let counter = connection.counter
        connection.counter &+= 1
        connections[hand] = connection
        return (counter & 0x0F, counter)
    }

    mutating func play(hand: Int, generation: UInt64, amplitude: Float, frequencyHz: Float,
                       durationNanoseconds: UInt64, requestedAt: UInt64, now: UInt64) -> [Output] {
        guard connections.indices.contains(hand), var connection = connections[hand], connection.generation == generation,
              connection.bluetooth, Self.valid(amplitude: amplitude, frequencyHz: frequencyHz, durationNanoseconds: durationNanoseconds) else { return [] }
        if amplitude == 0 || durationNanoseconds == 0 { return stop(hand: hand, generation: generation, force: true) }
        let (until, overflow) = requestedAt.addingReportingOverflow(durationNanoseconds)
        // Queueing or a slow HID write must not turn a short expired pulse into a late pulse.
        guard !overflow, until > now else { return [] }
        connection.playing = Playing(amplitude: amplitude, frequencyHz: frequencyHz, until: until,
                                     resend: now.addingClamped(Self.resendNanoseconds))
        connections[hand] = connection
        return [Output(hand: hand, generation: generation, amplitude: amplitude, frequencyHz: frequencyHz)]
    }

    mutating func stop(hand: Int, generation: UInt64, force: Bool = false) -> [Output] {
        guard connections.indices.contains(hand), var connection = connections[hand], connection.generation == generation,
              connection.bluetooth else { return [] }
        guard force || connection.playing != nil else { return [] }
        connection.playing = nil
        connections[hand] = connection
        return [Output(hand: hand, generation: generation, amplitude: 0, frequencyHz: 0)]
    }

    mutating func stopAll(force: Bool = false) -> [Output] {
        var output: [Output] = []
        for hand in connections.indices {
            if let generation = connections[hand]?.generation { output += stop(hand: hand, generation: generation, force: force) }
        }
        return output
    }

    mutating func advance(now: UInt64) -> [Output] {
        var output: [Output] = []
        for hand in connections.indices {
            guard var connection = connections[hand], var playing = connection.playing else { continue }
            if now >= playing.until {
                connection.playing = nil
                output.append(Output(hand: hand, generation: connection.generation, amplitude: 0, frequencyHz: 0))
            } else if now >= playing.resend {
                playing.resend = now.addingClamped(Self.resendNanoseconds)
                connection.playing = playing
                output.append(Output(hand: hand, generation: connection.generation,
                                     amplitude: playing.amplitude, frequencyHz: playing.frequencyHz))
            }
            connections[hand] = connection
        }
        return output
    }

    var nextDeadline: UInt64? {
        connections.compactMap { $0?.playing }.map { min($0.until, $0.resend) }.min()
    }
}

private extension UInt64 {
    func addingClamped(_ value: UInt64) -> UInt64 {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? .max : result
    }
}
