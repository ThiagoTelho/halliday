import AVFoundation
import AudioToolbox
import CoreAudio
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// One system-audio relay, independent of a game's renderer or graphics API.
/// The owner calls setState about twice a second, allowing device/default-route
/// changes to be handled without changing the Mac's default output or microphone.
@MainActor
final class SystemGameAudio {
    enum Status: Equatable, Sendable {
        case inactive, starting, running, directOutput, waitingDevice, permissionRequired
        case failed(String)

        var displayText: String {
            switch self {
            case .inactive: "Game audio is off"
            case .starting: "Connecting game audio"
            case .running: "Mac audio → PS VR2"
            case .directOutput: "PS VR2 is already the Mac audio output"
            case .waitingDevice: "Waiting for PS VR2 audio output"
            case .permissionRequired: "Allow Screen & System Audio Recording for headset audio"
            case .failed(let message): "Headset audio: \(message)"
            }
        }
    }
    typealias Statistics = SystemAudioBuffer.Statistics
    var onStatus: ((Status) -> Void)?
    private(set) var status: Status = .inactive
    var statistics: Statistics { relay?.buffer.statistics ?? savedStatistics }
    /// Actual active input, including an explicit Core Audio → SCK fallback.
    var captureBackend: SystemAudioCaptureBackend? { relay?.captureBackend }

    private struct Key: Equatable {
        let device: SystemAudioDevice
        let defaultOutput: UInt32
    }
    private var key: Key?
    private var failedKey: Key?
    private var relay: SystemAudioRelay?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var volume: Float = 1
    private var savedStatistics = Statistics()

    func setState(enabled: Bool, gameActive: Bool, psvrConnected: Bool, volume: Float) {
        self.volume = volume.isFinite ? min(1, max(0, volume)) : 0
        guard enabled && gameActive && psvrConnected else {
            invalidate(); failedKey = nil; publish(.inactive); return
        }
        let inventory = SystemAudioHardware.inventory()
        guard let device = inventory.devices.filter(\.isPSVR2Output).sorted(by: { $0.id < $1.id }).first,
              let defaultOutput = inventory.defaultOutput else {
            invalidate(); failedKey = nil; publish(.waitingDevice); return
        }
        if defaultOutput == device.id {
            // Relaying a mix already sent directly to the headset would play it twice.
            invalidate(); failedKey = nil; publish(.directOutput); return
        }
        guard SystemAudioCaptureBackend.requested() == .coreAudio || CGPreflightScreenCaptureAccess() else {
            invalidate(); failedKey = nil; publish(.permissionRequired); return
        }
        let desired = Key(device: device, defaultOutput: defaultOutput)
        if key == desired, task != nil || relay?.isRunning == true {
            relay?.setVolume(self.volume); return
        }
        if failedKey == desired { return } // Retry on a deliberate toggle or route change.
        invalidate()
        failedKey = nil
        key = desired
        let token = generation
        let made = SystemAudioRelay { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.invalidate(); self.failedKey = desired; self.publish(.failed(message))
            }
        }
        relay = made
        publish(.starting)
        guard generation == token else { return } // A status callback may synchronously stop us.
        task = Task { @MainActor [weak self] in
            do {
                guard let self else { made.stop(); return }
                try await made.start(device: device.id, volume: self.volume)
                guard !Task.isCancelled, self.generation == token else { made.stop(); return }
                made.setVolume(self.volume)
                self.task = nil
                self.publish(.running)
            } catch {
                made.stop()
                guard let self, self.generation == token else { return }
                self.invalidate()
                if !CGPreflightScreenCaptureAccess() {
                    self.failedKey = nil; self.publish(.permissionRequired)
                } else {
                    self.failedKey = desired; self.publish(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// Invalidate pending asynchronous starts as well as active capture/playback.
    func stop() { invalidate(); failedKey = nil; publish(.inactive) }

    private func invalidate() {
        generation &+= 1
        task?.cancel(); task = nil
        if let relay { savedStatistics = relay.buffer.statistics; relay.stop() }
        relay = nil
        key = nil
    }
    private func publish(_ next: Status) {
        guard next != status else { return }
        status = next
        onStatus?(next)
    }
}

private enum SystemAudioHardware {
    struct Inventory { let devices: [SystemAudioDevice]; let defaultOutput: UInt32? }
    static func inventory() -> Inventory {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let defaultOutput = uint(system, kAudioHardwarePropertyDefaultOutputDevice)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 16 * 1024, size % 4 == 0 else { return Inventory(devices: [], defaultOutput: defaultOutput) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
        guard ids.withUnsafeMutableBytes({ AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }) == noErr
        else { return Inventory(devices: [], defaultOutput: defaultOutput) }
        let devices = ids.compactMap { id -> SystemAudioDevice? in
            guard uint(id, kAudioDevicePropertyDeviceIsAlive) == 1,
                  let name = string(id, kAudioObjectPropertyName),
                  name.filter({ !$0.isWhitespace }).uppercased() == "PSVR2",
                  uint(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeDisplayPort,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
                  let rate = number(id, kAudioDevicePropertyNominalSampleRate)
            else { return nil }
            return SystemAudioDevice(id: id, uid: uid, name: name, displayPort: true,
                outputChannels: channels(id), sampleRate: rate)
        }
        return Inventory(devices: devices, defaultOutput: defaultOutput)
    }
    private static func uint(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var value = 0.0, size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: CFString?, size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard result == noErr, let value else { return nil }
        return value as String
    }
    private static func channels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size <= 64 * 1024 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0, count <= (Int(size) - MemoryLayout<AudioBufferList>.size) / MemoryLayout<AudioBuffer>.size + 1 else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Copies ScreenCaptureKit's borrowed PCM storage before returning its callback.
/// A separate helper lets synthetic CMSampleBuffers exercise the exact conversion.
enum SystemAudioSamples {
    enum Result: Equatable { case ignored, copied, unsupported }
    static func append(_ sample: CMSampleBuffer, to destination: SystemAudioBuffer,
                       nowSeconds: Double, arrivalNs: UInt64) -> Result {
        guard sample.isValid, CMSampleBufferDataIsReady(sample) else { return .ignored }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, frames <= 48_000,
              let description = CMSampleBufferGetFormatDescription(sample),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return .unsupported }
        let format = pointer.pointee
        guard SystemAudioTapSamples.accepts(format) else { return .unsupported }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let age = nowSeconds - pts
        guard pts.isFinite, nowSeconds.isFinite, (-0.5...0.2).contains(age) else { return .ignored }
        do {
            return try sample.withAudioBufferList(flags: .audioBufferListAssure16ByteAlignment) { list, block in
                if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                    guard list.count == 2, list[0].mNumberChannels == 1, list[1].mNumberChannels == 1,
                          Int(list[0].mDataByteSize) >= frames * 4, Int(list[1].mDataByteSize) >= frames * 4,
                          let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                          let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return .unsupported }
                    withExtendedLifetime(block) { destination.append(frames: frames, nowNs: arrivalNs) { n, c in c == 0 ? l[n] : r[n] } }
                } else {
                    guard list.count == 1, list[0].mNumberChannels == 2, Int(list[0].mDataByteSize) >= frames * 8,
                          let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return .unsupported }
                    withExtendedLifetime(block) { destination.append(frames: frames, nowNs: arrivalNs) { n, c in data[n * 2 + c] } }
                }
                return .copied
            }
        } catch { return .unsupported }
    }
}

/// Audio-only capture configuration is deterministic and can be checked without
/// querying displays, recording permission, microphones, or audio devices.
enum SystemAudioCaptureConfiguration {
    static func make() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        if #available(macOS 15, *) { config.captureMicrophone = false }
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3
        return config
    }
}

/// Escaping audio/framework callbacks must be formed outside MainActor. A closure
/// created inside start() otherwise inherits that actor and traps on CoreAudio's
/// real-time thread even when its body touches only the thread-safe PCM buffer.
enum SystemAudioCallbacks {
    nonisolated static func render(buffer pcm: SystemAudioBuffer) -> AVAudioSourceNodeRenderBlock {
        return { isSilence, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for b in buffers { if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) } }
            guard buffers.count == 2, buffers[0].mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                  Int(buffers[0].mDataByteSize) >= Int(frames) * 4,
                  Int(buffers[1].mDataByteSize) >= Int(frames) * 4,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true; return noErr
            }
            let n = pcm.render(frames: Int(frames), nowNs: DispatchTime.now().uptimeNanoseconds,
                left: UnsafeMutableBufferPointer(start: left, count: Int(frames)),
                right: UnsafeMutableBufferPointer(start: right, count: Int(frames)))
            isSilence.pointee = ObjCBool(n == 0)
            return noErr
        }
    }
    nonisolated static func captureStopped(_ error: (any Error)?) { }
}

private final class SystemAudioRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let buffer = SystemAudioBuffer()
    private let failure: @Sendable (String) -> Void
    private let errorLock = NSLock()
    private var reportedError = false
    private let captureQueue = DispatchQueue(label: "halliday.game-system-audio", qos: .userInteractive)
    @MainActor private var stopped = false
    @MainActor private var stream: SCStream?
    @MainActor private var engine: AVAudioEngine?
    @MainActor private var tap: SystemAudioTap?
    @MainActor private var tapFallbackTask: Task<Void, Never>?
    @MainActor private(set) var captureBackend: SystemAudioCaptureBackend?

    init(failure: @escaping @Sendable (String) -> Void) { self.failure = failure }

    @MainActor func start(device: AudioDeviceID, volume: Float) async throws {
        try checkActive()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { throw outputError(-1) }
        let engine = AVAudioEngine()
        self.engine = engine
        guard let output = engine.outputNode.audioUnit else { throw outputError(-1) }
        var selected = device
        let result = AudioUnitSetProperty(output, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard result == noErr else { throw outputError(result) }
        var actual = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(output, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &actual, &size) == noErr, actual == device else { throw outputError(-1) }
        let source = AVAudioSourceNode(format: format, renderBlock: SystemAudioCallbacks.render(buffer: buffer))
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        try checkActive()
        try engine.start()
        // The output engine registers this process with HAL before we look up
        // its process object. Never make a global tap with an empty exclusion.
        if SystemAudioCaptureBackend.requested() == .coreAudio {
            let tap = SystemAudioTap()
            self.tap = tap
            do {
                try tap.start(buffer: buffer, failure: Self.tapFailed(self))
                try checkActive()
                captureBackend = .coreAudio
                print("[game audio input] CoreAudio tap (48 kHz stereo; own process excluded)")
                return
            } catch {
                tap.stop(); self.tap = nil
                try checkActive()
                print("[game audio input] CoreAudio unavailable: \(error.localizedDescription); falling back to ScreenCaptureKit")
            }
        }
        try await startScreenCapture()
    }

    @MainActor private func startScreenCapture() async throws {
        try checkActive()
        guard CGPreflightScreenCaptureAccess() else {
            throw NSError(domain: "HallidayAudio", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Allow Screen & System Audio Recording for headset audio"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try checkActive()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "HallidayAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display is available for system audio"])
        }
        let config = SystemAudioCaptureConfiguration.make()
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        // No video or microphone output is registered; no encoded media is produced.
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        do { try await stream.startCapture() }
        catch {
            try? await stream.stopCapture()
            throw error
        }
        if stopped || Task.isCancelled {
            // stop() may have run while startCapture was suspended. Its early
            // stop request can precede capture's actual start, so close the
            // retained local stream again after that completion.
            try? await stream.stopCapture()
            throw CancellationError()
        }
        try checkActive()
        captureBackend = .screenCaptureKit
        print("[game audio input] ScreenCaptureKit (48 kHz stereo; own process excluded)")
    }
    nonisolated private static func tapFailed(_ relay: SystemAudioRelay) -> @Sendable (String) -> Void {
        { [weak relay] message in
            Task { @MainActor [weak relay] in relay?.fallbackFromTap(message) }
        }
    }
    @MainActor private func fallbackFromTap(_ message: String) {
        guard !stopped, tap != nil, tapFallbackTask == nil else { return }
        tap?.stop(); tap = nil; captureBackend = nil
        print("[game audio input] CoreAudio stopped: \(message); falling back to ScreenCaptureKit")
        tapFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tapFallbackTask = nil }
            do { try await self.startScreenCapture() }
            catch {
                guard !self.stopped, !Task.isCancelled else { return }
                self.report(error.localizedDescription)
            }
        }
    }
    @MainActor func setVolume(_ volume: Float) { engine?.mainMixerNode.outputVolume = volume }
    @MainActor var isRunning: Bool {
        !stopped && engine?.isRunning == true && (stream != nil || tap?.isRunning == true || tapFallbackTask != nil)
    }
    @MainActor private func checkActive() throws {
        if stopped || Task.isCancelled { throw CancellationError() }
    }
    @MainActor func stop() {
        guard !stopped else { return }
        stopped = true
        tapFallbackTask?.cancel(); tapFallbackTask = nil
        tap?.stop(); tap = nil; captureBackend = nil
        buffer.close()
        engine?.stop(); engine = nil
        if let stream {
            self.stream = nil
            try? stream.removeStreamOutput(self, type: .audio)
            stream.stopCapture(completionHandler: SystemAudioCallbacks.captureStopped)
        }
    }
    private func outputError(_ code: OSStatus) -> NSError {
        NSError(domain: "HallidayAudio", code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "Couldn't open the PS VR2 audio output (\(code))"])
    }
    private func report(_ text: String) {
        errorLock.lock()
        let first = !reportedError
        reportedError = true
        errorLock.unlock()
        if first { failure(text) }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { report(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let result = SystemAudioSamples.append(sampleBuffer, to: buffer,
            nowSeconds: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            arrivalNs: DispatchTime.now().uptimeNanoseconds)
        if case .unsupported = result { report("The captured audio format is not supported") }
    }
}
