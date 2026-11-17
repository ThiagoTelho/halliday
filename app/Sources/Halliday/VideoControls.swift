// The video player's controls in VR (ROADMAP W11 B.11, W6 6.9), in two levels. The bar, a
// floating Night Glass panel in front of the viewer below the picture, holds what is used every
// minute: the video's name, the seek bar with times, back 10 s, play/pause, forward 10 s, the
// volume (Halliday's master volume), and at the right the view drawer's switch, hide and close.
// The view drawer (`VideoViewPanel`), a second small panel that opens above the bar, holds what is
// set once for a video: zoom, the backdrop of a video made for passthrough, projection and stereo
// layout (for files whose format was guessed wrong), subtitles, audio track, recenter.

import AVFoundation
import AppKit

@MainActor
final class VideoControls: VRPanel {
    private weak var video: VideoPlayer?
    var onRecenter: (() -> Void)?
    /// Called with a line saying what a click chose (which subtitles, which audio track).
    var onInfo: ((String) -> Void)?
    /// Projection and stereo changes need the head pose: the owner does them.
    var onCycle: ((String) -> Void)?
    /// The video's backdrop for passthrough changed: the owner switches the cameras with it.
    var onBackdrop: (() -> Void)?
    /// The bar's hide button: the owner puts the bar and the dock away.
    var onHide: (() -> Void)?
    /// The view drawer is open (the owner shows `VideoViewPanel` above the bar).
    private(set) var viewOpen = false
    /// Plays the next video of the folder (the owner opens it).
    var onNext: (() -> Void)?

    // The picture at the place on the seek bar under the pointer (or held), for `ScrubPreview`.
    private(set) var preview: (time: Double, image: CGImage)?
    private var previewer: AVAssetImageGenerator?
    private var previewerURL: URL?
    private var previewBusy = false
    private var previewWanted: Double?

    /// Call each frame: follows the pointer along the seek bar and asks for the picture there.
    func updatePreview() {
        guard let video, let url = video.url, url.isFileURL, video.duration > 0, hovered == "seek" || pressed == "seek",
              let p = lastPoint, let track = tracks["seek"] else {
            preview = nil
            previewWanted = nil
            return
        }
        let time = Double(max(0, min(1, (p.x - track.minX) / track.width))) * video.duration
        if let preview, abs(preview.time - time) < max(1, video.duration / 300) { return }
        previewWanted = time
        if previewerURL != url {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 520)
            // The nearest picture the file can give quickly, not the exact frame.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
            (previewer, previewerURL) = (generator, url)
        }
        guard !previewBusy, let previewer else { return }
        previewBusy = true
        previewWanted = nil
        let stereo = video.format.stereo, projection = video.format.projection
        // (Only this one request uses the generator at a time: `previewBusy`.)
        nonisolated(unsafe) let generator = previewer
        Task { [weak self] in
            var image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
            if let whole = image {
                // One eye's picture, and of a picture all around the middle of it.
                var part = CGRect(x: 0, y: 0, width: whole.width, height: whole.height)
                if stereo == 1 { part.size.width /= 2 } else if stereo == 2 { part.size.height /= 2 }
                if projection == 0 { part = part.insetBy(dx: part.width * 0.3, dy: part.height * 0.2) }
                if projection == 1 || projection == 2 { part = part.insetBy(dx: part.width * 0.14, dy: part.height * 0.14) }
                image = whole.cropping(to: part.integral) ?? whole
            }
            guard let self else { return }
            self.previewBusy = false
            if let image, self.hovered == "seek" || self.pressed == "seek" { self.preview = (time, image) }
        }
    }

    /// What the bar shows; it redraws only when this changes.
    private struct Model: Equatable {
        var title = ""
        var time = 0, duration = 0
        var playing = false
        var volume: Float = 1
        var viewOpen = false
        /// The view is not as the file gave it (zoomed, keyed): the drawer's switch says so.
        var viewChanged = false
        var hasNext = false
    }

    private var model = Model() {
        didSet { if model != oldValue { setNeedsDisplay() } }
    }
    /// While the seek bar is held: the position it shows (seeking happens as it moves).
    private var scrub: Double?
    private var tracks: [String: CGRect] = [:]

    /// Where the bar sits: closer than the screen, between the picture and the dock.
    static let distance: Float = 1.1
    static let below: Float = 20

    private static let margin: CGFloat = 24
    static let width: CGFloat = 980
    private static let height: CGFloat = 92
    private var glassRect: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer, video: VideoPlayer) {
        self.video = video
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.choose(id) }
        onPress = { [weak self] id in if let p = self?.lastPoint { self?.slide(id, to: p) } }
        onDrag = { [weak self] id, p in self?.slide(id, to: p) }
        refresh()
    }

    /// Re-reads the player's state (call a few times per second).
    func refresh() {
        guard let video else { return }
        if pressed != "seek" { scrub = nil }
        model = Model(title: video.url?.deletingPathExtension().lastPathComponent ?? "", time: Int(scrub ?? video.time),
                      duration: Int(video.duration), playing: video.isPlaying, volume: Settings.shared.volume, viewOpen: viewOpen,
                      viewChanged: abs(video.zoom - 1) > 0.01 || video.backdrop != .off, hasNext: hasNext)
    }

    /// Whether the folder has a video after this one (looked up once per video).
    private var hasNext: Bool {
        guard let url = video?.url, url.isFileURL else { return false }
        if nextKnownFor != url {
            nextKnownFor = url
            nextExists = VideoPlayer.next(after: url) != nil
        }
        return nextExists
    }
    private var nextKnownFor: URL?
    private var nextExists = false

    /// Does what control `id` does (the bar's own controls and the view drawer's).
    func choose(_ id: String) {
        guard let video else { return }
        switch id {
        case "back": video.seek(by: -10)
        case "play": video.togglePlay()
        case "forward": video.seek(by: 10)
        case "next": onNext?()
        case "view": viewOpen.toggle()
        case "zoomOut": video.zoom(by: -0.1)
        case "zoomIn": video.zoom(by: 0.1)
        case "backdrop":
            video.cycleBackdrop()
            onInfo?(video.backdrop == .off ? "Passthrough video: off"
                : video.backdrop == .auto ? "Passthrough video: automatic · finds the backdrop's colour by itself"
                : video.backdrop.isMask ? "Passthrough video: \(video.backdrop.name.lowercased())"
                : "Passthrough video: \(video.backdrop.name.lowercased()) shows the room")
            onBackdrop?()
        case "projection": onCycle?("projection")
        case "stereo": onCycle?("stereo")
        case "recenter": onRecenter?()
        case "subtitles":
            video.cycleSubtitles()
            onInfo?("Subtitles: \(video.subtitleName)")
        case "audio":
            video.cycleAudio()
            onInfo?("Audio: \(video.audioTrackName)")
        case "hide": onHide?()
        case "close": video.close()
        default: break
        }
        refresh()
    }

    private func slide(_ id: String, to p: CGPoint) {
        guard let video, let track = tracks[id] else { return }
        let t = Double(max(0, min(1, (p.x - track.minX) / track.width)))
        if id == "seek", video.duration > 0 {
            scrub = t * video.duration
            video.seek(to: t * video.duration)
        } else if id == "volume" {
            Settings.shared.volume = Float((t * 20).rounded() / 20)
        } else {
            return
        }
        refresh()
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glassRect, radius: NightGlass.panelRadius)
    }

    override func draw(in ctx: CGContext) {
        // One floating capsule (board 20): the lit play button, the title and time over the
        // scrubber, then quiet glass for the rest.
        let g = glassRect
        let midY = g.midY
        var x = g.minX + 18
        iconButton(ctx, "play", model.playing ? "pause.fill" : "play.fill", CGRect(x: x, y: midY - 28, width: 56, height: 56), symbolSize: 21, lit: true)
        x += 56 + 16

        // The right side, from the edge inward: close, hide, View, the volume, next, ±10 s.
        var end = g.maxX - 14
        for (id, symbol) in [("close", "xmark"), ("hide", "chevron.down")] {
            iconButton(ctx, id, symbol, CGRect(x: end - 44, y: midY - 22, width: 44, height: 44), symbolSize: 14, quiet: true)
            end -= 46
        }
        end -= 6
        let viewWidth = NightGlass.textSize("View", style: .label).width + 58
        button(ctx, "view", "View", CGRect(x: end - viewWidth, y: midY - 20, width: viewWidth, height: 40), symbol: model.viewOpen ? "chevron.up" : "slider.horizontal.3",
               kind: model.viewOpen || model.viewChanged ? .main : .plain)
        end -= viewWidth + 14
        tracks["volume"] = slider(ctx, "volume", row: CGRect(x: end - 120, y: midY - 20, width: 120, height: 40), fraction: CGFloat(model.volume))
        NightGlass.drawSymbol(model.volume < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              in: CGRect(x: end - 148, y: midY - 26, width: 28, height: 52), size: 14, color: NightGlass.secondary)
        end -= 156
        if model.hasNext {
            iconButton(ctx, "next", "forward.end.fill", CGRect(x: end - 46, y: midY - 23, width: 46, height: 46), symbolSize: 15)
            end -= 48
        }
        for (id, symbol) in [("forward", "goforward.10"), ("back", "gobackward.10")] {
            iconButton(ctx, id, symbol, CGRect(x: end - 46, y: midY - 23, width: 46, height: 46), symbolSize: 17)
            end -= 48
        }
        end -= 10

        // The middle: the name and the times above, the scrubber below.
        let right = end
        let time = "\(Self.clock(model.time)) · \(model.duration > model.time ? "\(Self.clock(model.duration - model.time)) left" : Self.clock(model.duration))"
        let timeWidth = NightGlass.textSize(time, style: .caption, tabular: true).width
        NightGlass.drawText(model.title, at: CGPoint(x: x, y: g.minY + 16), style: .label, weight: .semibold, width: max(40, right - x - timeWidth - 14))
        NightGlass.drawText(time, at: CGPoint(x: right - timeWidth, y: g.minY + 18), style: .caption, color: NightGlass.secondary, tabular: true)
        let fraction = model.duration > 0 ? CGFloat(model.time) / CGFloat(model.duration) : 0
        tracks["seek"] = slider(ctx, "seek", row: CGRect(x: x - 12, y: g.minY + 38, width: right - x + 24, height: 40), fraction: fraction)
    }
}

/// The player's view drawer: what is set once for a video, in a small panel above the bar.
@MainActor
final class VideoViewPanel: VRPanel {
    private weak var video: VideoPlayer?
    /// A control was clicked: the bar does it (`VideoControls.choose`).
    var onChoose: ((String) -> Void)?

    private struct Model: Equatable {
        var zoom = 100
        var backdrop: VideoPlayer.Backdrop?
        var projection = "", stereo = ""
        var subtitles: String?, audio: String?
    }

    private var model = Model() {
        didSet { if model != oldValue { setNeedsDisplay() } }
    }

    private static let margin: CGFloat = 24
    private static let height: CGFloat = 72
    private var glassRect: CGRect { CGRect(x: Self.margin, y: Self.margin, width: VideoControls.width, height: Self.height) }

    init(renderer: Renderer, video: VideoPlayer) {
        self.video = video
        let size = CGSize(width: VideoControls.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: VideoControls.width, height: Self.height))
        onActivate = { [weak self] id in
            self?.onChoose?(id)
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        guard let video else { return }
        model = Model(zoom: Int((video.zoom * 100).rounded()), backdrop: video.format.projection == 3 ? nil : video.backdrop,
                      projection: VideoPlayer.projectionName(video.format.projection),
                      stereo: ["2D", "3D side by side", "3D top/bottom"][Int(max(0, min(2, video.format.stereo)))],
                      subtitles: video.hasSubtitles ? video.subtitleName : nil, audio: video.audioTrackCount > 1 ? video.audioTrackName : nil)
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glassRect, radius: NightGlass.panelRadius)
    }

    override func draw(in ctx: CGContext) {
        let g = glassRect
        let y = g.minY + 14
        var x = g.minX + 14
        // Zoom: smaller, how much, larger.
        iconButton(ctx, "zoomOut", "minus.magnifyingglass", CGRect(x: x, y: y, width: 44, height: 44), symbolSize: 15)
        let zoom = "\(model.zoom)%"
        let zoomSize = NightGlass.textSize(zoom, style: .label, tabular: true)
        NightGlass.drawText(zoom, at: CGPoint(x: x + 44 + (50 - zoomSize.width) / 2, y: y + 22 - zoomSize.height / 2), style: .label,
                            color: model.zoom == 100 ? NightGlass.secondary : NightGlass.text, tabular: true)
        iconButton(ctx, "zoomIn", "plus.magnifyingglass", CGRect(x: x + 94, y: y, width: 44, height: 44), symbolSize: 15)
        x += 150
        // The format the file is taken to be (each click the next one).
        for (id, label) in [("projection", model.projection), ("stereo", model.stereo)] {
            let w = NightGlass.textSize(label, style: .label).width + 28
            button(ctx, id, label, CGRect(x: x, y: y + 2, width: w, height: 40))
            x += w + 8
        }
        var end = g.maxX - 14
        iconButton(ctx, "recenter", "scope", CGRect(x: end - 44, y: y, width: 44, height: 44), symbolSize: 14)
        end -= 48
        // A video made for passthrough: which backdrop of it is the room's (each click the next).
        if let backdrop = model.backdrop {
            iconButton(ctx, "backdrop", backdrop == .off ? "eye" : "eye.fill", CGRect(x: end - 44, y: y, width: 44, height: 44), symbolSize: 15,
                       tint: backdrop == .off ? nil : NightGlass.accent)
            end -= 48
        }
        // Subtitles and audio track, when the video has a choice (each click takes the next one).
        if let subtitles = model.subtitles {
            iconButton(ctx, "subtitles", subtitles == "Off" ? "captions.bubble" : "captions.bubble.fill", CGRect(x: end - 44, y: y, width: 44, height: 44),
                       symbolSize: 15, tint: subtitles == "Off" ? nil : NightGlass.accent)
            end -= 48
        }
        if model.audio != nil {
            iconButton(ctx, "audio", "waveform", CGRect(x: end - 44, y: y, width: 44, height: 44), symbolSize: 15)
        }
    }
}

/// The picture at the place on the seek bar under the pointer, with its time: a small panel
/// above the bar while the pointer is on the seek bar.
@MainActor
final class ScrubPreview: VRPanel {
    private var shown: (time: Double, image: CGImage)?
    private static let margin: CGFloat = 20
    private static let picture = CGSize(width: 300, height: 190)

    init(renderer: Renderer) {
        // (Its surface is the picture, for `attach`'s geometry; it is never among the panels the
        // pointer is tried against, so it takes no clicks.)
        super.init(renderer: renderer, size: CGSize(width: Self.picture.width + 2 * Self.margin, height: Self.picture.height + 2 * Self.margin),
                   surface: CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: Self.picture))
    }

    func show(_ preview: (time: Double, image: CGImage)) {
        if let shown, shown.time == preview.time { return }
        shown = preview
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        guard let shown else { return }
        let rect = CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: Self.picture)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.clip()
        let image = shown.image
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.saveGState()
        ctx.translateBy(x: rect.midX - w / 2, y: rect.midY + h / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
        // The time, on a chip at the bottom.
        let text = VideoControls.clock(Int(shown.time))
        let size = NightGlass.textSize(text, style: .label, weight: .semibold, tabular: true)
        let chip = CGRect(x: rect.midX - size.width / 2 - 12, y: rect.maxY - 38, width: size.width + 24, height: 28)
        NightGlass.fill(ctx, chip, radius: 14, color: NSColor(white: 0, alpha: 0.62))
        NightGlass.drawText(text, at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), style: .label, color: NightGlass.text,
                            weight: .semibold, tabular: true)
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 16, cornerHeight: 16, transform: nil))
        ctx.setStrokeColor(NightGlass.rim.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }
}

/// A video's subtitles in VR: up to three centered lines, each on a dark strip, in front of the
/// viewer below the middle of the picture. It never takes the pointer.
@MainActor
final class SubtitlePanel: VRPanel {
    static let distance: Float = 1.8
    static let below: Float = 16

    var text: String? {
        didSet { if text != oldValue { setNeedsDisplay() } }
    }

    init(renderer: Renderer) {
        super.init(renderer: renderer, size: CGSize(width: 900, height: 132), surface: .zero)
    }

    override func draw(in ctx: CGContext) {
        guard let text else { return }
        var lines: [String] = []
        for part in text.split(separator: "\n") { lines += NightGlass.wrap(String(part), style: .title, width: size.width - 80) }
        let shown = lines.suffix(3)
        let lineHeight: CGFloat = 38
        var y = size.height - CGFloat(shown.count) * lineHeight - 6
        for line in shown {
            let s = NightGlass.textSize(line, style: .title, weight: .medium)
            NightGlass.fill(ctx, CGRect(x: size.width / 2 - s.width / 2 - 16, y: y, width: s.width + 32, height: lineHeight - 4), radius: 10,
                            color: NSColor(white: 0, alpha: 0.62))
            NightGlass.drawText(line, at: CGPoint(x: size.width / 2 - s.width / 2, y: y + (lineHeight - 4 - s.height) / 2), style: .title, weight: .medium)
            y += lineHeight
        }
    }
}
