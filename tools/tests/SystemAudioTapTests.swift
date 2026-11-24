import AudioToolbox
import CoreAudio
import Foundation

private func fixtureTapFormat(planar: Bool = false) -> AudioStreamBasicDescription {
    let bytes: UInt32 = planar ? 4 : 8
    return AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
            (planar ? kAudioFormatFlagIsNonInterleaved : 0),
        mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
}

@MainActor private final class TapDriverFixture: SystemAudioTapDriver {
    let failure: String?
    var calls: [String] = []
    var liveTap = false, liveAggregate = false, liveIO = false, running = false
    var own: AudioObjectID = 42
    var format = fixtureTapFormat(), aggregateFormat = fixtureTapFormat(planar: true)
    init(failure: String? = nil) { self.failure = failure }
    private func step(_ label: String) throws {
        calls.append(label)
        if failure == label { throw SystemAudioTapError.api(label, -42) }
    }
    func ownProcess() throws -> AudioObjectID { try step("own"); return own }
    func makeTap(excluding process: AudioObjectID, uid: UUID) throws -> AudioObjectID {
        precondition(process == 42)
        try step("tap"); liveTap = true; return 101
    }
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        precondition(tap == 101); try step("tapFormat"); return format
    }
    func makeAggregate(tapUID: UUID) throws -> AudioObjectID {
        precondition(liveTap); try step("aggregate"); liveAggregate = true; return 102
    }
    func inputFormat(_ aggregate: AudioObjectID) throws -> AudioStreamBasicDescription {
        precondition(aggregate == 102); try step("inputFormat"); return aggregateFormat
    }
    func installIO(_ aggregate: AudioObjectID, tap: AudioObjectID, format: AudioStreamBasicDescription,
                   buffer: SystemAudioBuffer, fault: SystemAudioTapFault) throws {
        precondition(liveTap && liveAggregate && aggregate == 102 && tap == 101)
        liveIO = true // Exercise a callback installed before the listener registration fails.
        try step("io")
    }
    func start(_ aggregate: AudioObjectID) throws {
        precondition(liveIO); running = true; try step("start")
    }
    func stop(_ aggregate: AudioObjectID) { precondition(aggregate == 102); calls.append("stop"); running = false }
    func removeIO(_ aggregate: AudioObjectID, tap: AudioObjectID) {
        precondition(!running && liveAggregate && liveTap); calls.append("removeIO"); liveIO = false
    }
    func destroyAggregate(_ aggregate: AudioObjectID) {
        precondition(!running && !liveIO && liveAggregate); calls.append("destroyAggregate"); liveAggregate = false
    }
    func destroyTap(_ tap: AudioObjectID) {
        precondition(!liveAggregate && liveTap); calls.append("destroyTap"); liveTap = false
    }
    var empty: Bool { !liveTap && !liveAggregate && !liveIO && !running }
}

private final class TapFaultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// Formed from MainActor, invoked on another thread: catches inherited-actor
/// traps in the actual HAL callback, not merely the synchronous converter.
private final class TapCallbackFixture: @unchecked Sendable {
    let callback: AudioDeviceIOBlock
    let buffer: SystemAudioBuffer
    let faults = TapFaultCounter()
    init(planar: Bool) {
        buffer = SystemAudioBuffer(capacity: 8)
        let fault = SystemAudioTapFault { [faults] _ in faults.increment() }
        callback = SystemAudioTapSamples.callback(format: fixtureTapFormat(planar: planar), buffer: buffer, fault: fault)
    }
    func run(planar: Bool) {
        precondition(!Thread.isMainThread)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        l.initialize(repeating: 0, count: 8); r.initialize(repeating: -0.25, count: 4)
        defer {
            list.unsafeMutablePointer.deallocate(); l.deinitialize(count: 8); l.deallocate()
            r.deinitialize(count: 4); r.deallocate()
        }
        if planar {
            for n in 0..<4 { l[n] = 0.25 }
            list.unsafeMutablePointer.pointee.mNumberBuffers = 2
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: l)
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 16, mData: r)
        } else {
            for n in 0..<4 { l[2*n] = 0.25; l[2*n+1] = -0.25 }
            list.unsafeMutablePointer.pointee.mNumberBuffers = 1
            list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 32, mData: l)
        }
        var stamp = AudioTimeStamp()
        callback(&stamp, list.unsafeMutablePointer, &stamp, list.unsafeMutablePointer, &stamp)
        precondition(buffer.statistics.receivedFrames == 4 && buffer.statistics.rms == 0.25)
        for n in 0..<8 { l[n] = 99 }; for n in 0..<4 { r[n] = 99 }
        var left = [Float](repeating: 99, count: 4), right = left
        let n = left.withUnsafeMutableBufferPointer { a in right.withUnsafeMutableBufferPointer { b in
            buffer.render(frames: 4, nowNs: DispatchTime.now().uptimeNanoseconds, left: a, right: b)
        } }
        precondition(n == 4 && left == [Float](repeating: 0.25, count: 4) && right == [Float](repeating: -0.25, count: 4))
        let timing = SystemAudioBuffer()
        for ns: UInt64 in [800_000_000, 1_000_000_000, 1_500_000_000] {
            precondition(SystemAudioTapSamples.append(list.unsafeMutablePointer, format: fixtureTapFormat(planar: planar),
                to: timing, nowNs: 1_000_000_000, inputNs: ns) == .copied)
        }
        for ns: UInt64 in [799_999_999, 1_500_000_001, .max] {
            precondition(SystemAudioTapSamples.append(list.unsafeMutablePointer, format: fixtureTapFormat(planar: planar),
                to: timing, nowNs: 1_000_000_000, inputNs: ns) == .ignored)
        }
        precondition(timing.statistics.receivedFrames == 12)
        // Malformed borrowed data never enters the FIFO; one async failure only.
        list[0].mDataByteSize = 1
        callback(&stamp, list.unsafeMutablePointer, &stamp, list.unsafeMutablePointer, &stamp)
        callback(&stamp, list.unsafeMutablePointer, &stamp, list.unsafeMutablePointer, &stamp)
        precondition(faults.count == 1 && buffer.statistics.receivedFrames == 4)
    }
}

enum SystemAudioTapTests {
    @MainActor static func run() throws {
        precondition(SystemAudioCaptureBackend.requested(environment: [:]) == .screenCaptureKit)
        for value in ["", "COREAUDIO", "true", "sck"] {
            precondition(SystemAudioCaptureBackend.requested(environment: ["HALLIDAY_AUDIO_CAPTURE_BACKEND": value]) == .screenCaptureKit)
        }
        precondition(SystemAudioCaptureBackend.requested(environment: ["HALLIDAY_AUDIO_CAPTURE_BACKEND": "coreaudio"]) == .coreAudio)
        for planar in [false, true] {
            let f = fixtureTapFormat(planar: planar)
            precondition(SystemAudioTapSamples.accepts(f))
            var invalid: [AudioStreamBasicDescription] = []
            var x = f; x.mSampleRate = 44_100; invalid.append(x)
            x = f; x.mSampleRate = .nan; invalid.append(x)
            x = f; x.mChannelsPerFrame = 1; invalid.append(x)
            x = f; x.mBitsPerChannel = 16; invalid.append(x)
            x = f; x.mBytesPerFrame += 4; invalid.append(x)
            x = f; x.mBytesPerPacket += 4; invalid.append(x)
            x = f; x.mFramesPerPacket = 2; invalid.append(x)
            x = f; x.mFormatFlags |= kAudioFormatFlagIsBigEndian; invalid.append(x)
            x = f; x.mFormatFlags |= kAudioFormatFlagIsSignedInteger; invalid.append(x)
            x = f; x.mFormatFlags &= ~kAudioFormatFlagIsPacked; invalid.append(x)
            x = f; x.mFormatID = kAudioFormatMPEG4AAC; invalid.append(x)
            precondition(invalid.allSatisfy { !SystemAudioTapSamples.accepts($0) })
            let fixture = TapCallbackFixture(planar: planar), done = DispatchGroup()
            done.enter()
            DispatchQueue.global(qos: .userInitiated).async { fixture.run(planar: planar); done.leave() }
            precondition(done.wait(timeout: .now() + 10) == .success)
        }

        if #available(macOS 14.2, *) {
            // These construct descriptions only: no HAL calls or permission prompts.
            let uid = UUID(), desc = SystemAudioHALTapDriver.description(excluding: 42, uid: uid)
            precondition(desc.isExclusive && desc.isMixdown && !desc.isMono && desc.isPrivate && desc.muteBehavior == .unmuted)
            precondition(desc.processes == [42] && desc.uuid == uid)
            let aggregate = SystemAudioHALTapDriver.aggregateDescription(tapUID: uid)
            precondition(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
            precondition(aggregate[kAudioAggregateDeviceTapAutoStartKey] as? Bool == false)
            precondition(aggregate[kAudioAggregateDeviceSubDeviceListKey] == nil && aggregate[kAudioAggregateDeviceMainSubDeviceKey] == nil)
            let taps = aggregate[kAudioAggregateDeviceTapListKey] as! [[String: Any]]
            precondition(taps.count == 1 && taps[0][kAudioSubTapUIDKey] as? String == uid.uuidString)

            for failure in ["own", "tap", "tapFormat", "aggregate", "inputFormat", "io", "start"] {
                let driver = TapDriverFixture(failure: failure), tap = SystemAudioTap(driver: driver)
                do { try tap.start(buffer: SystemAudioBuffer(), failure: { _ in }); preconditionFailure("Missing expected failure") }
                catch { precondition(driver.empty, "Leaked resources after \(failure): \(driver.calls)") }
                let calls = driver.calls; tap.stop(); precondition(driver.calls == calls)
            }
            for boundary in 1...6 {
                let driver = TapDriverFixture(), tap = SystemAudioTap(driver: driver)
                var checks = 0
                do {
                    try tap.start(buffer: SystemAudioBuffer(), failure: { _ in }, active: { checks += 1; return checks < boundary })
                    preconditionFailure("Cancellation was ignored")
                } catch { precondition(error is CancellationError && driver.empty) }
            }
            for invalidTap in [false, true] {
                let driver = TapDriverFixture(), tap = SystemAudioTap(driver: driver)
                if invalidTap { driver.format.mSampleRate = 44_100 } else { driver.aggregateFormat.mSampleRate = 44_100 }
                do { try tap.start(buffer: SystemAudioBuffer(), failure: { _ in }); preconditionFailure("Accepted wrong actual ASBD") }
                catch { precondition(driver.empty) }
            }
            let missing = TapDriverFixture(); missing.own = 0
            do { try SystemAudioTap(driver: missing).start(buffer: SystemAudioBuffer(), failure: { _ in }); preconditionFailure("Captured own relay") }
            catch { precondition(missing.calls == ["own"] && missing.empty) }
            for _ in 0..<3 { // Fresh route/reconnect uses new resources; repeated stop is harmless.
                let driver = TapDriverFixture(), tap = SystemAudioTap(driver: driver)
                try tap.start(buffer: SystemAudioBuffer(), failure: { _ in })
                precondition(tap.isRunning && driver.running)
                tap.stop(); precondition(!tap.isRunning && driver.empty)
                let calls = driver.calls; tap.stop(); precondition(driver.calls == calls)
            }
        }
        print("PASS: opt-in CoreAudio selection, real HAL callback off-main, planar/interleaved borrowed PCM copy, strict actual ASBD, own-process exclusion/private tap-only descriptions, all startup failure/cancel unwind points, reconnect/idempotent cleanup; no hardware/capture")
    }
}
