import Foundation

/// A fixed-size stereo buffer. The capture callback copies borrowed samples;
/// the audio render callback never waits for the producer or allocates memory.
final class SystemAudioBuffer: @unchecked Sendable {
    struct Statistics: Equatable, Sendable {
        var receivedFrames: UInt64 = 0
        var renderedFrames: UInt64 = 0
        var droppedFrames: UInt64 = 0
        /// Latest accepted input block, before the output volume; no audio retained here.
        var rms: Double = 0
    }
    private let lock = NSLock()
    private let capacity: Int
    private let staleAfterNs: UInt64
    private var left: [Float]
    private var right: [Float]
    private var first = 0
    private var count = 0
    private var lastWrite: UInt64?
    private var closed = false
    private var totals = Statistics()

    init(capacity: Int = 2_880, staleAfterNs: UInt64 = 200_000_000) {
        precondition(capacity > 0 && capacity <= 48_000)
        self.capacity = capacity
        self.staleAfterNs = staleAfterNs
        left = [Float](repeating: 0, count: capacity)
        right = left
    }

    var statistics: Statistics { lock.lock(); defer { lock.unlock() }; return totals }

    func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        discard()
    }

    private func discard() {
        // Called with the lock already held by close/render/append only.
        totals.droppedFrames &+= UInt64(count)
        count = 0
        first = 0
        lastWrite = nil
        totals.rms = 0
    }

    func append(frames: Int, nowNs: UInt64, sample: (Int, Int) -> Float) {
        guard frames > 0, frames <= 48_000 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if let lastWrite, nowNs < lastWrite || nowNs - lastWrite > staleAfterNs { discard() }
        totals.receivedFrames &+= UInt64(frames)
        let accepted = min(frames, capacity), skip = frames - accepted
        let displaced = max(0, count + accepted - capacity)
        first = (first + displaced) % capacity
        count -= displaced
        totals.droppedFrames &+= UInt64(skip + displaced)
        var sum = 0.0
        for n in 0..<accepted {
            let l = sample(skip + n, 0), r = sample(skip + n, 1)
            let a = l.isFinite ? l : 0, b = r.isFinite ? r : 0
            let at = (first + count + n) % capacity
            left[at] = a; right[at] = b
            sum += Double(a) * Double(a) + Double(b) * Double(b)
        }
        count += accepted
        lastWrite = nowNs
        totals.rms = sqrt(sum / Double(accepted * 2))
    }

    /// Buffers are always initialized, including starvation, closed and contended states.
    /// Return only frames actually taken from the captured stream, not padded silence.
    func render(frames: Int, nowNs: UInt64,
                left outLeft: UnsafeMutableBufferPointer<Float>,
                right outRight: UnsafeMutableBufferPointer<Float>) -> Int {
        guard frames >= 0, outLeft.count >= frames, outRight.count >= frames else { return 0 }
        for n in 0..<frames { outLeft[n] = 0; outRight[n] = 0 }
        guard lock.try() else { return 0 }
        defer { lock.unlock() }
        guard !closed, let lastWrite else { return 0 }
        guard nowNs >= lastWrite, nowNs - lastWrite <= staleAfterNs else { discard(); return 0 }
        let taken = min(frames, count)
        for n in 0..<taken {
            let at = (first + n) % capacity
            outLeft[n] = left[at]; outRight[n] = right[at]
        }
        first = (first + taken) % capacity
        count -= taken
        totals.renderedFrames &+= UInt64(taken)
        return taken
    }
}

struct SystemAudioDevice: Equatable, Sendable {
    let id: UInt32
    let uid: String
    let name: String
    let displayPort: Bool
    let outputChannels: Int
    let sampleRate: Double

    var isPSVR2Output: Bool {
        name.filter { !$0.isWhitespace }.uppercased() == "PSVR2" && displayPort &&
            outputChannels >= 2 && sampleRate.isFinite && sampleRate > 0
    }
}
