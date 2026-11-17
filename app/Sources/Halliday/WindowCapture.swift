// Captures a display or a window with ScreenCaptureKit and keeps the latest frame for the
// compositor. Every VR window has a stream of its own (its picture is right even when another
// window covers it on the virtual display), and one more stream captures the whole virtual
// display: menus, popovers and dialogs the apps open there are regions of it, and so is a window
// until its own stream delivers.
//
// Frames arrive on a capture queue as IOSurface-backed pixel buffers. The renderer picks up the
// newest one each frame and copies it into a mipmapped texture (so text stays clean when the
// window is far away), keeping the source alive until the GPU is done with it.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit

final class CaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    /// Where the content is in the latest frame, in pixels (a window's stream; nil: all of it).
    private var latestContent: CGRect?
    private var configuration: SCStreamConfiguration?
    private var sequence = 0
    private var taken = 0
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "halliday.capture")
    private(set) var stoppedWithError: String?

    init(name: String) {
        self.name = name
    }

    /// Starts capturing `filter` into frames of `width` × `height` pixels. `singleWindow`: the
    /// filter is one window (captured without its shadow).
    @MainActor
    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int32 = 120, singleWindow: Bool = false) async throws {
        let config = SCStreamConfiguration()
        if singleWindow { config.ignoreShadowsSingleWindow = true }
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.queueDepth = 4
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        configuration = config
    }

    /// Changes the size of the frames (the captured window changed size).
    @MainActor
    func resize(width: Int, height: Int) {
        guard let stream, let config = configuration, config.width != width || config.height != height else { return }
        config.width = width
        config.height = height
        let name = name
        stream.updateConfiguration(config) { error in
            if let error { log("[capture] \(name): couldn't resize to \(width)×\(height): \(error.localizedDescription)") }
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
        // Nothing in the picture changed: the frame isn't passed on (copying and mipmapping it on
        // the GPU was most of what windows in VR cost).
        // (An unchanged frame comes with one empty rectangle, not with none.)
        if let dirty = info?[.dirtyRects] as? [NSDictionary],
           dirty.allSatisfy({ CGRect(dictionaryRepresentation: $0).map { $0.width <= 0 || $0.height <= 0 } ?? true }) { return }

        // The part of the frame the content covers: its rectangle in points times the display's scale.
        var content: CGRect?
        if let dict = info?[.contentRect] as? NSDictionary, let r = CGRect(dictionaryRepresentation: dict),
           let scale = info?[.scaleFactor] as? CGFloat, r.width > 0, r.height > 0 {
            content = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
        }
        lock.lock(); defer { lock.unlock() }
        latest = pixels
        latestContent = content
        sequence += 1
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); defer { lock.unlock() }
        stoppedWithError = error.localizedDescription
    }

    /// The newest frame, if it arrived since the last call.
    func takeNewFrame() -> CVPixelBuffer? { takeNewFrameAndContent()?.pixels }

    /// The newest frame and where its content is (pixels), if it arrived since the last call.
    func takeNewFrameAndContent() -> (pixels: CVPixelBuffer, content: CGRect?)? {
        lock.lock(); defer { lock.unlock() }
        guard sequence != taken, let p = latest else { return nil }
        taken = sequence
        return (p, latestContent)
    }
}

/// Turns captured pixel buffers into a mipmapped texture for a layer.
@MainActor
final class CapturedTexture {
    private let device: MTLDevice
    private let cache: CVMetalTextureCache
    private(set) var texture: MTLTexture?

    init?(device: MTLDevice) {
        var c: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }
        self.device = device
        cache = c
    }

    /// Encodes a copy of `pixels` into the layer texture (recreated on size change) and its mips.
    /// Returns false if the frame couldn't be wrapped.
    func encodeUpdate(from pixels: CVPixelBuffer, into cb: MTLCommandBuffer) -> Bool {
        guard let blit = cb.makeBlitCommandEncoder() else { return false }
        defer { blit.endEncoding() }
        return encodeUpdate(from: pixels, into: cb, blit: blit)
    }

    /// The same, in a blit pass the caller opened (and ends): the copies of all the windows' new
    /// frames go in one pass (a pass of its own per window cost several milliseconds of GPU time
    /// with eight windows).
    func encodeUpdate(from pixels: CVPixelBuffer, into cb: MTLCommandBuffer, blit: MTLBlitCommandEncoder) -> Bool {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let source = CVMetalTextureGetTexture(cvTex) else { return false }
        if texture?.width != w || texture?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead]
            d.storageMode = .private
            texture = device.makeTexture(descriptor: d)
        }
        guard let texture else { return false }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.generateMipmaps(for: texture)
        // The capture pool may reuse the buffer: keep it (and its Metal wrapper) until the GPU is done.
        let keep = KeepAlive([pixels, cvTex])
        cb.addCompletedHandler { _ in keep.release() }
        return true
    }
}

/// Holds objects until a GPU completion handler runs.
final class KeepAlive: @unchecked Sendable {
    private var objects: [Any]
    init(_ objects: [Any]) { self.objects = objects }
    func release() { objects.removeAll() }
}
