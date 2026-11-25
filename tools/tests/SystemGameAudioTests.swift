import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

private final class AudioRenderThreadFixture: @unchecked Sendable {
    let callback: AVAudioSourceNodeRenderBlock
    init(buffer: SystemAudioBuffer) { callback = SystemAudioCallbacks.render(buffer: buffer) }
    func run() {
        precondition(!Thread.isMainThread, "Render regression must execute on a real background thread")
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        l.initialize(repeating: 99, count: 4); r.initialize(repeating: 99, count: 4)
        defer {
            list.unsafeMutablePointer.deallocate()
            l.deinitialize(count: 4); r.deinitialize(count: 4); l.deallocate(); r.deallocate()
        }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: l)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: r)
        var silence: ObjCBool = true
        var timestamp = AudioTimeStamp()
        precondition(callback(&silence, &timestamp, 4, list.unsafeMutablePointer) == noErr)
        precondition(!silence.boolValue && Array(UnsafeBufferPointer(start: l, count: 4)) == [0.25, 0.25, 0.25, 0.25])
        precondition(Array(UnsafeBufferPointer(start: r, count: 4)) == [-0.25, -0.25, -0.25, -0.25])
        precondition(callback(&silence, &timestamp, 4, list.unsafeMutablePointer) == noErr)
        precondition(silence.boolValue && l[0] == 0 && r[0] == 0, "Render starvation retained old sound")
        SystemAudioCallbacks.captureStopped(nil)
    }
}

@main struct SystemGameAudioTests {
    @MainActor static func main() throws {
        let capture = SystemAudioCaptureConfiguration.make()
        precondition(capture.capturesAudio && capture.excludesCurrentProcessAudio)
        precondition(capture.sampleRate == 48_000 && capture.channelCount == 2)
        precondition(capture.width == 2 && capture.height == 2 && !capture.showsCursor)
        precondition(capture.minimumFrameInterval == CMTime(value: 1, timescale: 1) && capture.queueDepth == 3)
        if #available(macOS 15, *) { precondition(!capture.captureMicrophone) }
        func take(_ queue: SystemAudioBuffer, frames: Int, now: UInt64) -> (Int, [Float], [Float]) {
            var l = [Float](repeating: 99, count: frames), r = l
            let n = l.withUnsafeMutableBufferPointer { left in
                r.withUnsafeMutableBufferPointer { right in queue.render(frames: frames, nowNs: now, left: left, right: right) }
            }
            return (n, l, r)
        }
        let fifo = SystemAudioBuffer(capacity: 4, staleAfterNs: 200)
        fifo.append(frames: 6, nowNs: 100) { n, c in Float(n + 1) * (c == 0 ? 1 : -1) }
        let overflow = take(fifo, frames: 6, now: 100)
        precondition(overflow.0 == 4 && overflow.1 == [3, 4, 5, 6, 0, 0] && overflow.2 == [-3, -4, -5, -6, 0, 0])
        precondition(fifo.statistics.receivedFrames == 6 && fifo.statistics.renderedFrames == 4 && fifo.statistics.droppedFrames == 2)
        precondition(take(fifo, frames: 3, now: 100).1 == [0, 0, 0], "Starvation reused old audio")
        fifo.append(frames: 3, nowNs: 110) { n, c in Float(n + c + 1) }
        precondition(take(fifo, frames: 2, now: 110).1 == [1, 2])
        fifo.append(frames: 3, nowNs: 120) { n, c in Float(n + c + 4) }
        let wrapped = take(fifo, frames: 4, now: 120)
        precondition(wrapped.1 == [3, 4, 5, 6] && wrapped.2 == [4, 5, 6, 7], "Stereo FIFO wrap failed")
        fifo.append(frames: 2, nowNs: 130) { _, _ in 0.5 }
        precondition(take(fifo, frames: 2, now: 331).0 == 0, "Stalled output played stale samples")
        fifo.append(frames: 1, nowNs: 500) { _, _ in .nan }
        precondition(take(fifo, frames: 1, now: 500).1 == [0], "Nonfinite sample reached output")
        fifo.append(frames: 1, nowNs: 600) { _, _ in .infinity }
        fifo.close()
        let before = fifo.statistics
        fifo.append(frames: 1, nowNs: 610) { _, _ in 1 }
        precondition(take(fifo, frames: 1, now: 610).0 == 0 && fifo.statistics == before, "Late capture resumed a stopped buffer")

        // Invoke the production AVAudioSourceNode block from another thread.
        // This catches Swift6 inherited-MainActor traps which PCM-only tests miss.
        let realtime = SystemAudioBuffer(capacity: 8, staleAfterNs: .max)
        realtime.append(frames: 4, nowNs: DispatchTime.now().uptimeNanoseconds) { _, c in c == 0 ? 0.25 : -0.25 }
        let threadFixture = AudioRenderThreadFixture(buffer: realtime), done = DispatchGroup()
        done.enter()
        DispatchQueue.global(qos: .userInitiated).async { threadFixture.run(); done.leave() }
        precondition(done.wait(timeout: .now() + 10) == .success, "Background render callback stalled")
        precondition(realtime.statistics.renderedFrames == 4)

        let l: [Float] = [0.1, 0.2, 0.3, 0.4], r = l.map { -$0 }
        func sample(planar: Bool, rate: Double = 48_000, channels: UInt32 = 2,
                    timestamp: Double = 100, bytesPerFrame: UInt32? = nil) -> CMSampleBuffer {
            var description: CMAudioFormatDescription?
            var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
                mBytesPerPacket: bytesPerFrame ?? (planar ? 4 : 8), mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame ?? (planar ? 4 : 8),
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            precondition(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &description) == noErr)
            let values = planar ? l + r : zip(l, r).flatMap { [$0, $1] }
            var block: CMBlockBuffer?
            precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: values.count * 4, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block) == noErr)
            values.withUnsafeBytes {
                precondition(CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0,
                    dataLength: $0.count) == noErr)
            }
            var result: CMSampleBuffer?
            precondition(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                dataBuffer: block!, formatDescription: description!, sampleCount: l.count,
                presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 48_000),
                packetDescriptions: nil, sampleBufferOut: &result) == noErr)
            return result!
        }
        for planar in [false, true] {
            let queue = SystemAudioBuffer(capacity: 8)
            let captured = sample(planar: planar)
            let copied = SystemAudioSamples.append(captured, to: queue, nowSeconds: 100, arrivalNs: 1_000)
            precondition(copied == .copied, "Synthetic PCM copy failed: planar=\(planar), result=\(copied), valid=\(captured.isValid), ready=\(CMSampleBufferDataIsReady(captured)), frames=\(CMSampleBufferGetNumSamples(captured))")
            CMSampleBufferInvalidate(captured) // Destination owns its samples after the callback.
            let result = take(queue, frames: 4, now: 1_000)
            precondition(result.0 == 4 && result.1 == l && result.2 == r, "PCM sample copy or channel order failed")
            let rms = sqrt(zip(l, r).reduce(0.0) { $0 + Double($1.0 * $1.0 + $1.1 * $1.1) } / 8)
            precondition(abs(queue.statistics.rms - rms) < 1e-7)
        }
        let dropped = SystemAudioBuffer()
        precondition(SystemAudioSamples.append(sample(planar: true, timestamp: 99), to: dropped, nowSeconds: 100, arrivalNs: 1) == .ignored)
        precondition(SystemAudioSamples.append(sample(planar: true, timestamp: 101), to: dropped, nowSeconds: 100, arrivalNs: 1) == .ignored)
        precondition(SystemAudioSamples.append(sample(planar: true, rate: 44_100), to: dropped, nowSeconds: 100, arrivalNs: 1) == .unsupported)
        precondition(SystemAudioSamples.append(sample(planar: true, bytesPerFrame: 8), to: dropped, nowSeconds: 100, arrivalNs: 1) == .unsupported,
                     "Padded planar PCM must not be read as packed samples")
        precondition(SystemAudioSamples.append(sample(planar: false, bytesPerFrame: 16), to: dropped, nowSeconds: 100, arrivalNs: 1) == .unsupported,
                     "Padded stereo PCM must not be read as packed samples")
        precondition(dropped.statistics.receivedFrames == 0)

        let correct = SystemAudioDevice(id: 1, uid: "display", name: "PS VR2", displayPort: true, outputChannels: 2, sampleRate: 48_000)
        precondition(correct.isPSVR2Output)
        for device in [
            SystemAudioDevice(id: 2, uid: "mic", name: "PS VR2 Audio Mic", displayPort: false, outputChannels: 0, sampleRate: 48_000),
            SystemAudioDevice(id: 3, uid: "other", name: "MacBook Pro Speakers", displayPort: true, outputChannels: 2, sampleRate: 48_000),
            SystemAudioDevice(id: 4, uid: "virtual", name: "PS VR2", displayPort: false, outputChannels: 2, sampleRate: 48_000),
            SystemAudioDevice(id: 5, uid: "dead", name: "PS VR2", displayPort: true, outputChannels: 2, sampleRate: 0)
        ] { precondition(!device.isPSVR2Output, "Wrong/microphone output selected") }
        // The inactive facade must not enumerate devices, request permission,
        // create an engine, capture content or emit sound during this test.
        let facade = SystemGameAudio()
        facade.setState(enabled: false, gameActive: true, psvrConnected: true, volume: .nan)
        facade.setState(enabled: true, gameActive: false, psvrConnected: true, volume: 1)
        facade.setState(enabled: true, gameActive: true, psvrConnected: false, volume: 1)
        facade.stop()
        precondition(facade.status == .inactive && facade.statistics.receivedFrames == 0)
        print("PASS: actual production render/stop callbacks off-main with Swift6, bounded stereo FIFO/overflow/wrap/stale/starvation/stop, finite samples, actual CMSampleBuffer planar+interleaved copy/RMS, timestamp/format guards, DisplayPort-only PSVR2 selection, inactive facade without capture/playback")
    }
}
