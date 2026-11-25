import AppKit
import Metal
import QuartzCore
import simd

/// A non-interactive head-space instrument. It owns no input, pose prediction,
/// game cadence or world anchor. Each published texture is immutable so the
/// independent presentation queue may retain it until GPU completion.
@MainActor
final class PerformanceHUD {
    struct Image: @unchecked Sendable {
        let texture: MTLTexture
        /// Head-space plane: left, top, width, height, in metres.
        let rectangle: SIMD4<Float>
        let depth: Float
    }
    static let size = CGSize(width: 768, height: 160)
    static let rectangle = SIMD4<Float>(-0.28, -0.25, 0.56, 0.1166667)
    static let depth: Float = 1
    static let updateInterval = 0.2
    private let device: MTLDevice
    private var lastUpdate = -Double.infinity
    private(set) var image: Image?

    init(device: MTLDevice) { self.device = device }

    /// Clearing is immediate; enabled updates rasterize no more than five times
    /// a second. No shared texture is rewritten while the GPU is sampling it.
    func update(enabled: Bool, snapshot: PerformanceHUDSnapshot, now: Double = CACurrentMediaTime()) {
        guard enabled else { image = nil; lastUpdate = -.infinity; return }
        guard now.isFinite, now >= lastUpdate + Self.updateInterval || now < lastUpdate else { return }
        lastUpdate = now
        guard let bitmap = Self.bitmap(snapshot) else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: Int(Self.size.width), height: Int(Self.size.height), mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        texture.label = "Performance HUD (immutable, display encoded, premultiplied)"
        bitmap.bytes.withUnsafeBytes {
            guard let base = $0.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: bitmap.width * 4)
        }
        image = .init(texture: texture, rectangle: Self.rectangle, depth: Self.depth)
    }

    struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// Also used by the private offscreen visual fixture. CoreGraphics produces
    /// display/sRGB premultiplied bytes, deliberately sampled as Unorm rather
    /// than _srgb to match the compositor's display-encoded scene target.
    static func bitmap(_ snapshot: PerformanceHUDSnapshot) -> Bitmap? {
        let width = Int(size.width), height = Int(size.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let ctx = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            defer { NSGraphicsContext.restoreGraphicsState() }
            ctx.setFillColor(NSColor(calibratedWhite: 0.055, alpha: 0.88).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: width - 2, height: height - 2),
                               cornerWidth: 22, cornerHeight: 22, transform: nil)); ctx.fillPath()
            let columns: [(CGFloat, String, String)] = [
                (24, "GAME FPS", number(snapshot.gameFPS, decimals: 0)),
                (250, "DISPLAY FPS", number(snapshot.displayFPS, decimals: 0)),
                (472, "POSE → DISPLAY", number(snapshot.poseToDisplayMs, decimals: 1) + " ms")]
            for (x, label, value) in columns {
                text(label, x: x, y: 14, size: 18, color: NSColor(white: 0.72, alpha: 1), weight: .medium)
                text(value, x: x, y: 37, size: 34, color: .white, weight: .semibold)
            }
            let rect = CGRect(x: 24, y: 91, width: width - 48, height: 43)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.17).cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); ctx.strokePath()
            let history = Array(snapshot.history.suffix(100))
            let valid = history.compactMap { $0.gameFrameTimeMs }.filter { $0.isFinite && $0 >= 0 }
            let ceiling = max(20, valid.max() ?? 0, history.compactMap { $0.poseToDisplayMs }.filter { $0.isFinite && $0 >= 0 }.max() ?? 0)
            var drawing = false
            if let first = history.first?.time, let last = history.last?.time, last > first {
                ctx.setStrokeColor(NSColor(red: 0.49, green: 0.85, blue: 0.65, alpha: 1).cgColor); ctx.setLineWidth(2.5)
                for sample in history {
                    guard sample.time.isFinite, let fps = sample.gameFrameTimeMs, fps.isFinite, fps >= 0 else {
                        if drawing { ctx.strokePath() }; drawing = false; continue
                    }
                    let point = CGPoint(x: rect.minX + CGFloat((sample.time - first) / (last - first)) * rect.width,
                        y: rect.maxY - CGFloat(min(1, fps / ceiling)) * rect.height)
                    if drawing { ctx.addLine(to: point) } else { ctx.move(to: point); drawing = true }
                }
                if drawing { ctx.strokePath() }
                drawing = false
                ctx.setStrokeColor(NSColor(red: 0.52, green: 0.70, blue: 1, alpha: 1).cgColor)
                for sample in history {
                    guard sample.time.isFinite, let ms = sample.poseToDisplayMs, ms.isFinite, ms >= 0 else {
                        if drawing { ctx.strokePath() }; drawing = false; continue
                    }
                    let point = CGPoint(x: rect.minX + CGFloat((sample.time - first) / (last - first)) * rect.width,
                        y: rect.maxY - CGFloat(min(1, ms / ceiling)) * rect.height)
                    if drawing { ctx.addLine(to: point) } else { ctx.move(to: point); drawing = true }
                }
                if drawing { ctx.strokePath() }
            }
            text("AVG FRAME MS (GREEN) · POSE → DISPLAY (BLUE)", x: 24, y: 140, size: 11, color: NSColor(white: 0.62, alpha: 1), weight: .medium)
            return true
        }
        return success ? .init(width: width, height: height, bytes: bytes) : nil
    }
    private static func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.*f", decimals, value)
    }
    private static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat,
                             color: NSColor, weight: NSFont.Weight) {
        (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}
