import CoreAudio
import AudioToolbox
import Foundation

/// Experimental process-tap backend: enabled only by an explicit process environment value.
/// ScreenCaptureKit remains the ordinary path; hardware acceptance of the tap is pending.
enum SystemAudioCaptureBackend: String, Sendable {
    case screenCaptureKit = "screencapturekit"
    case coreAudio = "coreaudio"

    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        environment["HALLIDAY_AUDIO_CAPTURE_BACKEND"] == "coreaudio" ? .coreAudio : .screenCaptureKit
    }
}

enum SystemAudioTapError: LocalizedError {
    case unavailable, ownProcessMissing, format, api(String, OSStatus)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Core Audio taps require macOS 14.2 or later"
        case .ownProcessMissing: "Couldn't exclude Halliday from the system audio tap"
        case .format: "The audio tap is not 48 kHz stereo packed Float32"
        case .api(let name, let status): "\(name) failed (\(status))"
        }
    }
}

/// The HAL's actual ASBD and buffer sizes are checked; no assumed sample rate or
/// implicit conversion is used. Both Float32 layouts feed the existing bounded FIFO.
enum SystemAudioTapSamples {
    enum Result: Equatable { case copied, ignored, unsupported }
    static func accepts(_ f: AudioStreamBasicDescription) -> Bool {
        let planar = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bytes: UInt32 = planar ? 4 : 8
        return f.mSampleRate.isFinite && f.mSampleRate == 48_000 &&
            f.mFormatID == kAudioFormatLinearPCM && f.mChannelsPerFrame == 2 &&
            f.mBitsPerChannel == 32 && f.mFramesPerPacket == 1 &&
            f.mBytesPerFrame == bytes && f.mBytesPerPacket == bytes &&
            f.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ==
                (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) &&
            f.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger |
                kAudioFormatFlagIsAlignedHigh) == 0
    }

    static func append(_ list: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription,
                       to buffer: SystemAudioBuffer, nowNs: UInt64, inputNs: UInt64? = nil) -> Result {
        guard accepts(format) else { return .unsupported }
        if let inputNs {
            // Device timestamps may lead the callback by an I/O quantum. Match
            // the bounded SCK clock tolerance instead of dropping valid future
            // device timestamps; queued audio is still capped by the FIFO.
            guard inputNs <= nowNs ? nowNs - inputNs <= 200_000_000 : inputNs - nowNs <= 500_000_000 else { return .ignored }
        }
        // Check the fixed-size header before constructing its variable-length view.
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard list.pointee.mNumberBuffers == (planar ? 2 : 1) else { return .unsupported }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bytes = Int(buffers[0].mDataByteSize)
        if bytes == 0 { return .ignored }
        let stride = planar ? 4 : 8
        guard bytes % stride == 0, bytes / stride <= 48_000 else { return .unsupported }
        let frames = bytes / stride
        if planar {
            guard buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                  Int(buffers[1].mDataByteSize) == bytes,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return .unsupported }
            buffer.append(frames: frames, nowNs: nowNs) { n, channel in channel == 0 ? left[n] : right[n] }
        } else {
            guard buffers[0].mNumberChannels == 2,
                  let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return .unsupported }
            buffer.append(frames: frames, nowNs: nowNs) { n, channel in data[n * 2 + channel] }
        }
        return .copied
    }

    /// Construct outside MainActor: HAL calls this block on its own I/O thread.
    nonisolated static func callback(format: AudioStreamBasicDescription, buffer: SystemAudioBuffer,
                                     fault: SystemAudioTapFault) -> AudioDeviceIOBlock {
        return { _, input, inputTime, _, _ in
            let now = DispatchTime.now().uptimeNanoseconds
            let stamp = inputTime.pointee
            let inputNs = stamp.mFlags.contains(.hostTimeValid) ? AudioConvertHostTimeToNanos(stamp.mHostTime) : nil
            if append(input, format: format, to: buffer, nowNs: now, inputNs: inputNs) == .unsupported {
                fault.report("The Core Audio tap changed its audio format")
            }
        }
    }
}

final class SystemAudioTapFault: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false
    private let handler: @Sendable (String) -> Void
    init(_ handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
    func report(_ message: String) {
        lock.lock(); let first = !reported; reported = true; lock.unlock()
        if first { handler(message) }
    }
}

/// Injectable HAL operations let tests exercise production unwind/cancellation
/// without creating a tap, an aggregate device, or touching recording permission.
@MainActor protocol SystemAudioTapDriver: AnyObject {
    func ownProcess() throws -> AudioObjectID
    func makeTap(excluding process: AudioObjectID, uid: UUID) throws -> AudioObjectID
    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription
    func makeAggregate(tapUID: UUID) throws -> AudioObjectID
    func inputFormat(_ aggregate: AudioObjectID) throws -> AudioStreamBasicDescription
    func installIO(_ aggregate: AudioObjectID, tap: AudioObjectID, format: AudioStreamBasicDescription,
                   buffer: SystemAudioBuffer, fault: SystemAudioTapFault) throws
    func start(_ aggregate: AudioObjectID) throws
    func stop(_ aggregate: AudioObjectID)
    func removeIO(_ aggregate: AudioObjectID, tap: AudioObjectID)
    func destroyAggregate(_ aggregate: AudioObjectID)
    func destroyTap(_ tap: AudioObjectID)
}

@MainActor final class SystemAudioTap {
    private let driver: any SystemAudioTapDriver
    private var tap: AudioObjectID = 0, aggregate: AudioObjectID = 0
    private var ioInstalled = false, startAttempted = false, stopped = false
    private(set) var isRunning = false

    init(driver: any SystemAudioTapDriver = SystemAudioHALTapDriver()) { self.driver = driver }

    func start(buffer: SystemAudioBuffer, failure: @escaping @Sendable (String) -> Void,
               active: () -> Bool = { !Task.isCancelled }) throws {
        guard #available(macOS 14.2, *) else { throw SystemAudioTapError.unavailable }
        func check() throws { if stopped || !active() { throw CancellationError() } }
        do {
            try check()
            let own = try driver.ownProcess()
            guard own != kAudioObjectUnknown else { throw SystemAudioTapError.ownProcessMissing }
            try check()
            let uid = UUID()
            tap = try driver.makeTap(excluding: own, uid: uid)
            guard tap != kAudioObjectUnknown else { throw SystemAudioTapError.api("Create audio tap", -1) }
            try check()
            guard SystemAudioTapSamples.accepts(try driver.tapFormat(tap)) else { throw SystemAudioTapError.format }
            aggregate = try driver.makeAggregate(tapUID: uid)
            guard aggregate != kAudioObjectUnknown else { throw SystemAudioTapError.api("Create tap input", -1) }
            try check()
            let format = try driver.inputFormat(aggregate)
            guard SystemAudioTapSamples.accepts(format) else { throw SystemAudioTapError.format }
            let fault = SystemAudioTapFault(failure)
            // installIO may partially register before throwing: removeIO is idempotent.
            ioInstalled = true
            try driver.installIO(aggregate, tap: tap, format: format, buffer: buffer, fault: fault)
            try check()
            startAttempted = true
            try driver.start(aggregate)
            try check()
            isRunning = true
        } catch { stop(); throw error }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; isRunning = false
        if startAttempted { driver.stop(aggregate); startAttempted = false }
        if ioInstalled { driver.removeIO(aggregate, tap: tap); ioInstalled = false }
        if aggregate != 0 { driver.destroyAggregate(aggregate); aggregate = 0 }
        if tap != 0 { driver.destroyTap(tap); tap = 0 }
    }
}

@MainActor final class SystemAudioHALTapDriver: SystemAudioTapDriver {
    private var io: AudioDeviceIOProcID?
    private var formatChanged: AudioObjectPropertyListenerBlock?
    private let notifications = DispatchQueue(label: "halliday.system-audio-tap-format")

    func ownProcess() throws -> AudioObjectID {
        var pid = getpid(), result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = withUnsafePointer(to: &pid) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), $0, &size, &result)
        }
        try Self.check(status, "Find own audio process")
        return result
    }

    func makeTap(excluding process: AudioObjectID, uid: UUID) throws -> AudioObjectID {
        guard #available(macOS 14.2, *) else { throw SystemAudioTapError.unavailable }
        let description = Self.description(excluding: process, uid: uid)
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        if status != noErr {
            if id != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(id) }
            try Self.check(status, "Create system audio tap")
        }
        return id
    }

    static func description(excluding process: AudioObjectID, uid: UUID) -> CATapDescription {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        description.name = "Halliday system audio"
        description.uuid = uid
        description.isPrivate = true
        description.muteBehavior = .unmuted
        return description
    }

    func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        try Self.format(tap, selector: kAudioTapPropertyFormat, scope: kAudioObjectPropertyScopeGlobal)
    }

    static func aggregateDescription(tapUID: UUID) -> [String: Any] {
        // Tap-only, process-private input: no microphone, physical subdevice,
        // output stream, default-device change, or persistent aggregate device.
        [kAudioAggregateDeviceNameKey: "Halliday system audio input",
         kAudioAggregateDeviceUIDKey: "halliday.audio.\(UUID().uuidString)",
         kAudioAggregateDeviceIsPrivateKey: true,
         kAudioAggregateDeviceIsStackedKey: false,
         // HAL documents true as waiting for the first tapped process to make
         // sound. A quiet game must not hold the main actor in AudioDeviceStart.
         kAudioAggregateDeviceTapAutoStartKey: false,
         kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID.uuidString,
                                           kAudioSubTapDriftCompensationKey: true]]]
    }
    func makeAggregate(tapUID: UUID) throws -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(Self.aggregateDescription(tapUID: tapUID) as CFDictionary, &id)
        if status != noErr {
            if id != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(id) }
            try Self.check(status, "Create private audio input")
        }
        return id
    }
    func inputFormat(_ aggregate: AudioObjectID) throws -> AudioStreamBasicDescription {
        try Self.format(aggregate, selector: kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
    }
    func installIO(_ aggregate: AudioObjectID, tap: AudioObjectID, format: AudioStreamBasicDescription,
                   buffer: SystemAudioBuffer, fault: SystemAudioTapFault) throws {
        let callback = SystemAudioTapSamples.callback(format: format, buffer: buffer, fault: fault)
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&io, aggregate, nil, callback), "Create audio tap callback")
        guard io != nil else { throw SystemAudioTapError.api("Create audio tap callback", -1) }
        let changed = Self.changeCallback(fault)
        var address = Self.address(kAudioTapPropertyFormat)
        try Self.check(AudioObjectAddPropertyListenerBlock(tap, &address, notifications, changed), "Watch audio tap format")
        formatChanged = changed
    }
    nonisolated private static func changeCallback(_ fault: SystemAudioTapFault) -> AudioObjectPropertyListenerBlock {
        { _, _ in fault.report("The Core Audio tap format changed") }
    }
    func start(_ aggregate: AudioObjectID) throws {
        try Self.check(AudioDeviceStart(aggregate, io), "Start system audio tap")
    }
    func stop(_ aggregate: AudioObjectID) { if let io { AudioDeviceStop(aggregate, io) } }
    func removeIO(_ aggregate: AudioObjectID, tap: AudioObjectID) {
        if let changed = formatChanged {
            var address = Self.address(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(tap, &address, notifications, changed)
            formatChanged = nil
        }
        if let io { AudioDeviceDestroyIOProcID(aggregate, io); self.io = nil }
    }
    func destroyAggregate(_ aggregate: AudioObjectID) { AudioHardwareDestroyAggregateDevice(aggregate) }
    func destroyTap(_ tap: AudioObjectID) {
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func format(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        var address = address(selector, scope: scope), result = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result), "Read audio tap format")
        guard size == MemoryLayout<AudioStreamBasicDescription>.size else { throw SystemAudioTapError.format }
        return result
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw SystemAudioTapError.api(operation, status) }
    }
}
