// A game's frames through a window (ROADMAP W14.9, docs/research/zero-copy-frames.md).
//
// Halliday's OpenVR runtime, inside the game, presents each frame to a borderless window titled
// "Halliday frames <pid>" on a display Halliday made for it (`GameFramesDisplay`): both eyes side
// by side below a band of eight rows that holds the frame's number. This captures that window with
// ScreenCaptureKit; each frame arrives as an IOSurface-backed pixel buffer, and its number (read
// from the band here, on the capture queue) finds the frame's pose in the bridge. Nothing is
// copied on the CPU, and the game's thread spends tens of microseconds on a frame instead of
// milliseconds of reading back.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// The display the frames window lives on: invisible like the windows display, at 1× (Wine's
/// OpenGL draws at the window's size in points) and 240 Hz (a game at 120 frames a second
/// presents twice per refresh at 120 Hz, and ScreenCaptureKit would lose every other frame).
@MainActor
final class GameFramesDisplay {
    private let display: VirtualDisplay
    var bounds: CGRect { display.bounds }

    private init(_ display: VirtualDisplay) { self.display = display }

    /// Creates the display and waits for macOS to bring it online; nil if it can't.
    static func make() async -> GameFramesDisplay? {
        guard let d = VirtualDisplay(name: "Halliday Games", size: CGSize(width: 1920, height: 1080),
                                     hiDPI: false, refreshRate: 240, serial: 2) else { return nil }
        guard await d.waitUntilOnline() else { return nil }
        log("[game] display for game frames \(d.displayID) at \(d.bounds), \(Int(d.actualRefreshRate)) Hz")
        return GameFramesDisplay(d)
    }
}

/// Captures one game's frames window.
final class GameFrameCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Captured {
        let pixels: CVPixelBuffer
        let number: UInt32
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private var latest: Captured?
    private var sequence = 0
    private var taken = 0
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "halliday.game-frames", qos: .userInteractive)
    private(set) var size: (width: Int, height: Int) = (0, 0)
    /// Frames delivered, ones whose band couldn't be read, and numbers the capture never delivered.
    private(set) var delivered = 0
    private(set) var unreadable = 0
    private(set) var missed = 0
    private var lastNumber: UInt32 = 0
    private var stoppedError: String?

    /// The stream stopped (ScreenCaptureKit stops when the window goes away, for a moment when
    /// it is resized): make a new capture.
    var stopped: String? {
        lock.lock(); defer { lock.unlock() }
        return stoppedError
    }

    static let title = "Halliday frames "

    /// Finds the game's window (by its title, which carries the game's Windows process id).
    static func findWindow(pid: UInt32) async -> SCWindow? {
        let title = Self.title + String(pid)
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        return content.windows.first { $0.title == title }
    }

    @MainActor
    func start(window: SCWindow, width: Int, height: Int) async throws {
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        config.queueDepth = 5
        config.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        configuration = config
        size = (width, height)
    }

    /// The window changed size (the game changed its eye size).
    @MainActor
    func resize(width: Int, height: Int) {
        guard let stream, let config = configuration, size != (width, height) else { return }
        size = (width, height)
        config.width = width
        config.height = height
        stream.updateConfiguration(config) { error in
            if let error { log("[game] couldn't resize the frames capture to \(width)×\(height): \(error.localizedDescription)") }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        if let raw = info?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        let number = Self.readBand(pixels)
        lock.lock(); defer { lock.unlock() }
        delivered += 1
        guard let number else { unreadable += 1; return }
        let step = number &- lastNumber
        if lastNumber != 0, step > 1, step < 1000 { missed += Int(step) - 1 }
        lastNumber = number
        latest = Captured(pixels: pixels, number: number, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        sequence += 1
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); defer { lock.unlock() }
        stoppedError = error.localizedDescription
    }

    /// The counts since the last call: delivered, unreadable, missed.
    func takeCounts() -> (delivered: Int, unreadable: Int, missed: Int) {
        lock.lock(); defer { lock.unlock() }
        defer { (delivered, unreadable, missed) = (0, 0, 0) }
        return (delivered, unreadable, missed)
    }

    /// The newest frame, if one arrived since the last call.
    func take() -> Captured? {
        lock.lock(); defer { lock.unlock() }
        guard sequence != taken, let f = latest else { return nil }
        taken = sequence
        return f
    }

    /// The number in the band (halliday-bridge `read_band`: 32 squares of 8 × 8 from the left,
    /// bit 0 first, white for 1), or nil if the band isn't clean black and white.
    static func readBand(_ pixels: CVPixelBuffer) -> UInt32? {
        let band = 8
        guard CVPixelBufferGetWidth(pixels) >= 32 * band, CVPixelBufferGetHeight(pixels) > band,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row = (band / 2) * CVPixelBufferGetBytesPerRow(pixels)
        var n: UInt32 = 0
        for bit in 0..<32 {
            let g = base[row + (bit * band + band / 2) * 4 + 1] // BGRA: green
            if g > 200 { n |= 1 << UInt32(bit) } else if g > 55 { return nil }
        }
        return n
    }
}
