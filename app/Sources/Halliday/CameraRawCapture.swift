import Foundation

/// Explicit, one-shot camera evidence. Ordinary launches neither retain nor copy images.
/// File paths stay outside protected user folders so a permission prompt cannot consume the capture.
@MainActor
final class CameraRawCapture {
    static let seconds = 7.0
    static let hz = 5.0
    static let maxFrames = 40
    static let maxBytes = 64 * 1024 * 1024
    static let bufferBytes = 8 * 1024 * 1024

    struct Frame: Codable, Sendable {
        let counter: Int, exposure_host_ns: Int64, width: Int, height: Int
        let bc4: Bool, byte_count: Int, file: String, mode: Int, detector_threshold: Int
        let host_sample_seconds: Double
        let left_led_phase: Int?, right_led_phase: Int?
    }
    struct Manifest: Codable {
        var format_version = 1
        var layout = "BC4: row-major8byte4x4 blocks; camera0 abovecamera1. Mode16:1024x2032, picture1000columns per camera. Other modes:8bit grayscale. exposure_host_ns matches spotdump t."
        let start_seconds: Double?, end_seconds: Double
        let reason: String, dropped_frames: Int
        let frames: [Frame]
        let errors: [String]
    }
    private final class Writer: @unchecked Sendable {
        let directory: URL
        let queue = DispatchQueue(label: "halliday.camera.raw-evidence", qos: .utility)
        let lock = NSLock()
        var pending = 0
        var failure: String?
        // Writer queue only.
        var frames: [Frame] = []
        var errors: [String] = []
        let report: @Sendable (String) -> Void
        init(directory: URL, report: @escaping @Sendable (String) -> Void) { self.directory = directory; self.report = report }
        var error: String? { lock.lock(); defer { lock.unlock() }; return failure }
        func enqueue(_ frame: Frame, bytes: Data) -> Bool {
            lock.lock()
            guard pending < 2, failure == nil else { lock.unlock(); return false }
            pending += 1; lock.unlock()
            queue.async { [self] in
                defer { lock.lock(); pending -= 1; lock.unlock() }
                let destination = directory.appendingPathComponent(frame.file)
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try bytes.write(to: temporary, options: .withoutOverwriting)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    // The manifest is the commit record; unlisted payloads never count as samples.
                    frames.append(frame)
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    let message = String(describing: error)
                    errors.append(message); lock.lock(); failure = message; lock.unlock()
                    report("[cameras raw] write failed: \(message)")
                }
            }
            return true
        }
        func finish(start: Double?, end: Double, reason: String, dropped: Int) {
            queue.async { [self] in
                let manifest = Manifest(start_seconds: start, end_seconds: end, reason: reason,
                    dropped_frames: dropped, frames: frames, errors: errors)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(manifest)
                    try data.write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
                    report("[cameras raw] complete: \(frames.count) frames, \(reason), \(errors.count) write errors")
                } catch { report("[cameras raw] manifest failed: \(error)") }
            }
        }
    }
    private let writer: Writer
    private let trigger: URL?
    private let report: @Sendable (String) -> Void
    private var triggered = false
    private var started: Double?
    private var triggeredAt: Double?
    private var lastClock: Double?
    private var nextSample = -Double.infinity
    private var triggerCheck = -Double.infinity
    private var count = 0, totalBytes = 0, dropped = 0
    private(set) var lastCounter = -1
    private(set) var finished = false
    var retainsImages: Bool { triggered && !finished }

    static func privatePath(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // Foundation may canonicalize existing /private/tmp files to /tmp,
        // while an as-yet absent trigger keeps its original prefix.
        let path = url.path.hasPrefix("/tmp/") ? "/private" + url.path : url.path
        return path.hasPrefix("/private/tmp/") ? URL(fileURLWithPath: path) : nil
    }
    init?(arguments: [String], report: @escaping @Sendable (String) -> Void) {
        guard let i = arguments.firstIndex(of: "--camera-raw-dump") else { return nil }
        guard i + 1 < arguments.count, let directory = Self.privatePath(arguments[i + 1]) else {
            report("[cameras raw] rejected: output must be under /private/tmp"); return nil
        }
        if let j = arguments.firstIndex(of: "--camera-raw-trigger") {
            guard j + 1 < arguments.count, let path = Self.privatePath(arguments[j + 1]) else {
                report("[cameras raw] rejected: trigger must be under /private/tmp"); return nil
            }
            trigger = path
        } else { trigger = nil }
        self.report = report; writer = Writer(directory: directory, report: report)
        report("[cameras raw] armed: 5Hz7s, waiting for \(trigger == nil ? "first image" : "trigger")")
    }
    func wantsImages(at now: Double) -> Bool {
        guard !finished, now.isFinite else { return false }
        if let lastClock, now < lastClock - 0.000001 { finish(at: now, reason: "clock reset"); return false }
        lastClock = now
        if triggered, started == nil, let triggeredAt, now - triggeredAt >= 2 { finish(at: now, reason: "no first image"); return false }
        if let error = writer.error { finish(at: now, reason: "write failure: \(error)"); return false }
        if let started, now - started >= Self.seconds { finish(at: now, reason: "duration"); return false }
        if !triggered {
            if let trigger {
                guard now >= triggerCheck else { return false }
                triggerCheck = now + 0.1
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: trigger.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          ((attributes[.size] as? NSNumber)?.intValue ?? 1025) <= 1024,
                          Self.privatePath(trigger.path)?.path == trigger.path else { finish(at: now, reason: "invalid trigger"); return false }
                } catch {
                    let fileError = error as NSError
                    if fileError.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(fileError.code) { return false }
                    finish(at: now, reason: "trigger read failure: \(error)"); return false
                }
            }
            triggered = true; triggeredAt = now
        }
        return true
    }
    func shouldSample(at now: Double) -> Bool { retainsImages && now.isFinite && now >= nextSample }
    static func payloadSize(width: Int, height: Int, bc4: Bool) -> Int? {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              !bc4 || (width % 4 == 0 && height % 4 == 0) else { return nil }
        let size = bc4 ? width * height / 2 : width * height
        return size <= bufferBytes ? size : nil
    }
    func record(counter: Int, exposureNs: Int64, width: Int, height: Int, bc4: Bool,
                bytes: [UInt8], mode: Int, threshold: Int, phases: [String: Int], now: Double) {
        guard shouldSample(at: now), counter >= 0, counter != lastCounter else { return }
        guard exposureNs > 0, let size = Self.payloadSize(width: width, height: height, bc4: bc4), bytes.count >= size else {
            finish(at: now, reason: "invalid image"); return
        }
        guard count < Self.maxFrames, totalBytes <= Self.maxBytes - size else { finish(at: now, reason: "limit"); return }
        if started == nil { started = now; report("[cameras raw] started: \(counter), exposure \(exposureNs)") }
        nextSample = now + 1 / Self.hz; lastCounter = counter
        let frame = Frame(counter: counter, exposure_host_ns: exposureNs, width: width, height: height,
            bc4: bc4, byte_count: size, file: "frame-\(counter).\(bc4 ? "bc4" : "gray")",
            mode: mode, detector_threshold: threshold, host_sample_seconds: now,
            left_led_phase: phases["left"], right_led_phase: phases["right"])
        if writer.enqueue(frame, bytes: Data(bytes.prefix(size))) { count += 1; totalBytes += size }
        else { dropped += 1 }
    }
    func finish(at now: Double, reason: String) {
        guard !finished else { return }; finished = true
        writer.finish(start: started, end: now, reason: reason, dropped: dropped)
    }
    /// Tests only; production never waits on disk from the display actor.
    func waitForWrites() { writer.queue.sync {} }
}
