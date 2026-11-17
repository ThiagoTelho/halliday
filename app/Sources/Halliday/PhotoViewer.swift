// Photos (ROADMAP W13.2): images of the Mac in VR. An ordinary picture hangs on a large screen in
// front of the viewer; a 360° picture (2:1, equirectangular) surrounds them. Opened from Files;
// the other images of the same folder are one step away (previous / next).
//
// Images are decoded off the main thread at no more than the size the headset can show, and drawn
// through the same paths as video: a `QuadLayer` screen, or `Renderer.videoSphere`.

import AppKit
import ImageIO
import Metal
import simd

@MainActor
final class PhotoViewer {
    private let renderer: Renderer
    private var items: [URL] = []
    private(set) var index = 0
    private var texture: MTLTexture?
    private var pixelSize = CGSize.zero
    private var screen: QuadLayer?
    /// The picture surrounds the viewer (360°) instead of hanging on a screen.
    private(set) var surround = false
    private(set) var isOpen = false
    private(set) var loading = false
    private var loadToken = 0
    private var yaw = simd_quatf(angle: 0, axis: [0, 1, 0])
    private var headPosition = SIMD3<Float>(0, 1.6, 0)

    /// Called when the screen layer appears or disappears (the owner manages layer lists).
    var onScreenChange: ((QuadLayer?) -> Void)?
    /// Called when the viewer opens (true) or closes (false).
    var onOpenChange: ((Bool) -> Void)?
    /// Called when what the controls show changes (another picture, loaded, 360° on or off).
    var onChange: (() -> Void)?
    var onNotice: ((String) -> Void)?

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    var name: String { items.indices.contains(index) ? items[index].deletingPathExtension().lastPathComponent : "" }
    var count: Int { items.count }
    /// True if the picture has the shape of a 360° one (so the choice is offered).
    var canSurround: Bool { pixelSize.height > 0 && abs(pixelSize.width / pixelSize.height - 2) < 0.02 }

    /// Shows `url`; `siblings` are the images of its folder, in order, for previous / next.
    func open(_ url: URL, among siblings: [URL], head: HeadPose) {
        items = siblings.contains(url) ? siblings : [url]
        index = items.firstIndex(of: url) ?? 0
        place(head: head)
        if !isOpen {
            isOpen = true
            onOpenChange?(true)
        }
        load(decideSurround: true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        loadToken += 1
        texture = nil
        renderer.videoSphere = nil
        renderer.environmentDimming = 0
        if screen != nil {
            screen = nil
            onScreenChange?(nil)
        }
        onOpenChange?(false)
    }

    func step(_ by: Int) {
        guard items.count > 1 else { return }
        index = (index + by + items.count) % items.count
        load(decideSurround: true)
    }

    func toggleSurround() {
        guard canSurround else { return }
        surround.toggle()
        present()
        onChange?()
    }

    /// Re-centers the picture on where the head looks now (yaw only).
    func recenter(head: HeadPose) {
        place(head: head)
        present()
    }

    private func place(head: HeadPose) {
        let fwd = head.orientation.act(SIMD3<Float>(0, 0, -1))
        yaw = simd_quatf(angle: atan2(-fwd.x, -fwd.z), axis: [0, 1, 0])
        headPosition = head.position
    }

    private func load(decideSurround: Bool) {
        guard items.indices.contains(index) else { return }
        let url = items[index]
        loadToken += 1
        let token = loadToken
        loading = true
        onChange?()
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decode(url)
            await MainActor.run { [weak self] in
                guard let self, token == loadToken, isOpen else {
                    decoded?.bytes.deallocate()
                    return
                }
                loading = false
                guard let decoded, let t = renderer.updateLayerTexture(nil, width: decoded.width, height: decoded.height, bytes: decoded.bytes) else {
                    decoded?.bytes.deallocate()
                    onNotice?("\(url.lastPathComponent) couldn't be opened as a picture")
                    onChange?()
                    return
                }
                decoded.bytes.deallocate()
                texture = t
                pixelSize = CGSize(width: decoded.width, height: decoded.height)
                // A 2:1 picture at least 3000 pixels wide is taken for a 360° one (the button undoes it).
                if decideSurround { surround = canSurround && decoded.width >= 3000 }
                present()
                onChange?()
            }
        }
    }

    private func present() {
        guard isOpen, let texture else { return }
        if surround {
            if screen != nil {
                screen = nil
                onScreenChange?(nil)
            }
            renderer.environmentDimming = 0
            renderer.videoSphere = VideoSphere(texture: texture, projection: 0, stereo: 0, fisheyeFovDeg: 180, orientation: yaw)
        } else {
            renderer.videoSphere = nil
            renderer.environmentDimming = 0.6
            // A screen up to 3.2 m wide and 2 m tall, 3 m away at eye height.
            let aspect = Float(pixelSize.width / max(pixelSize.height, 1))
            let width = min(3.2, 2.0 * aspect)
            let layer = screen ?? QuadLayer(texture: texture, position: .zero, width: width)
            layer.texture = texture
            layer.width = width
            layer.aspect = 1 / aspect
            layer.cornerPixels = Float(pixelSize.width) * 0.008
            layer.castsShadow = true
            layer.orientation = yaw
            layer.position = headPosition + yaw.act(SIMD3(0, 0.05, -3))
            if screen == nil {
                layer.appear()
                screen = layer
                onScreenChange?(layer)
            }
        }
    }

    /// The image as RGBA bytes, upright, at most 8192 pixels on its longer side.
    private nonisolated static func decode(_ url: URL) -> (width: Int, height: Int, bytes: UnsafeMutableRawPointer)? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 8192, kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
        guard let ctx = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            bytes.deallocate()
            return nil
        }
        // Transparent pictures sit on black.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, bytes)
    }
}

/// The picture viewer's bar: previous, next, the picture's name and place in its folder, screen or
/// 360°, recenter, close. Night Glass, below the picture.
@MainActor
final class PhotoControls: VRPanel {
    private weak var viewer: PhotoViewer?
    var onRecenter: (() -> Void)?

    static let distance: Float = 1.1
    static let below: Float = 20

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 620, height: CGFloat = 72
    private var bar: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer, viewer: PhotoViewer) {
        self.viewer = viewer
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in
            guard let self, let viewer = self.viewer else { return }
            switch id {
            case "previous": viewer.step(-1)
            case "next": viewer.step(1)
            case "surround": viewer.toggleSurround()
            case "recenter": onRecenter?()
            case "close": viewer.close()
            default: break
            }
        }
        setNeedsDisplay()
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, bar, radius: bar.height / 2)
    }

    override func draw(in ctx: CGContext) {
        guard let viewer else { return }
        let b = bar, y = b.midY - 22
        var x = b.minX + 14
        let several = viewer.count > 1
        iconButton(ctx, "previous", "chevron.left", CGRect(x: x, y: y, width: 44, height: 44), enabled: several)
        x += 48
        iconButton(ctx, "next", "chevron.right", CGRect(x: x, y: y, width: 44, height: 44), enabled: several)
        x += 56
        var end = b.maxX - 14
        iconButton(ctx, "close", "xmark", CGRect(x: end - 44, y: y, width: 44, height: 44), symbolSize: 14, quiet: true)
        end -= 48
        iconButton(ctx, "recenter", "scope", CGRect(x: end - 44, y: y, width: 44, height: 44), symbolSize: 14, quiet: true)
        end -= 52
        if viewer.canSurround {
            let label = viewer.surround ? "On a screen" : "360°"
            let w = NightGlass.textSize(label, style: .label, weight: .medium).width + 32
            button(ctx, "surround", label, CGRect(x: end - w, y: y + 2, width: w, height: 40))
            end -= w + 10
        }
        // Name and place in the folder (or a spinner while the picture is on its way).
        let width = end - x - 6
        if viewer.loading { spinner(ctx, center: CGPoint(x: x + 9, y: b.midY), radius: 7) }
        let textX = viewer.loading ? x + 26 : x
        NightGlass.drawText(viewer.name, at: CGPoint(x: textX, y: b.midY - 19), style: .label, weight: .medium, width: width - (textX - x))
        NightGlass.drawText("\(viewer.index + 1) of \(viewer.count)", at: CGPoint(x: textX, y: b.midY + 2), style: .caption,
                            color: NightGlass.secondary, tabular: true)
    }
}
