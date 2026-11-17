// Music (ROADMAP W13.5): what the Mac is playing, with its controls, in a Night Glass panel. It
// talks to Music or Spotify through Apple events, and only to one that is already running (it
// never starts a player). macOS asks once, on the Mac's screen, before Halliday may control each.

import AppKit

/// One player app, and what it is playing.
struct NowPlaying: Equatable {
    var player: String
    var title = ""
    var artist = ""
    var album = ""
    var playing = false
    var position: Double = 0
    var duration: Double = 0
    var artworkURL: String?
}

@MainActor
final class MusicPanel: VRPanel {
    var onClose: (() -> Void)?

    private enum State: Equatable {
        case looking
        case none
        case refused(String)
        case playing(NowPlaying)
    }

    private var state = State.looking
    private var artwork: (url: String, image: CGImage)?
    private var poll: Timer?
    private var busy = false
    /// The player in charge: the one playing, else the last one used.
    private var player: (name: String, bundle: String)?

    private static let players = [(name: "Spotify", bundle: "com.spotify.client"), (name: "Music", bundle: "com.apple.Music")]
    /// Apple events can block: they go out one at a time, off the main thread.
    private nonisolated static let queue = DispatchQueue(label: "halliday.music")

    static let distance: Float = 1.2
    static let below: Float = 6

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 640, height: CGFloat = 300
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    /// Starts following the players (call when the panel opens).
    func start() {
        state = .looking
        setNeedsDisplay()
        refresh()
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "previous": send("previous track")
        case "toggle": send("playpause")
        case "next": send("next track")
        case "permission":
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
        case "retry": start()
        default: break
        }
    }

    // --- Talking to the players ---

    private func running() -> [(name: String, bundle: String)] {
        Self.players.filter { p in NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == p.bundle } }
    }

    private func refresh() {
        guard !busy else { return }
        let candidates = running()
        guard !candidates.isEmpty else {
            if state != .none {
                state = .none
                setNeedsDisplay(fade: true)
            }
            return
        }
        busy = true
        Task.detached(priority: .utility) {
            var found: [NowPlaying] = []
            var refusal: String?
            for p in candidates {
                switch Self.ask(p.name) {
                case .success(let info): if let info { found.append(info) }
                case .failure(let e): if e.refused { refusal = p.name }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                busy = false
                let chosen = found.first { $0.playing } ?? found.first { $0.player == self.player?.name } ?? found.first
                let next: State = chosen.map { .playing($0) } ?? refusal.map { .refused($0) } ?? .none
                if let chosen { player = Self.players.first { $0.name == chosen.player } }
                if next != state {
                    state = next
                    setNeedsDisplay(fade: true)
                }
                loadArtwork()
            }
        }
    }

    /// What `app` is playing (nil: nothing, or stopped). Failure: true when macOS refused the
    /// Apple event (the user said no, or hasn't answered yet).
    nonisolated private static func ask(_ app: String) -> Result<NowPlaying?, AskError> {
        let artwork = app == "Spotify" ? "artwork url of current track" : "\"\""
        let source = """
        tell application "\(app)"
            if player state is stopped then return "stopped"
            set t to current track
            return (name of t) & "\\u{1F}" & (artist of t) & "\\u{1F}" & (album of t) & "\\u{1F}" & (player state as text) & "\\u{1F}" & (player position as text) & "\\u{1F}" & ((duration of t) as text) & "\\u{1F}" & \(artwork)
        end tell
        """
        var error: NSDictionary?
        let result = queue.sync { NSAppleScript(source: source)?.executeAndReturnError(&error) }
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            return .failure(AskError(refused: code == -1743 || code == -1744))
        }
        guard let text = result?.stringValue, text != "stopped" else { return .success(nil) }
        let f = text.components(separatedBy: "\u{1F}")
        guard f.count >= 6 else { return .success(nil) }
        // Spotify gives the duration in milliseconds, Music in seconds.
        var duration = Double(f[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        if app == "Spotify" { duration /= 1000 }
        return .success(NowPlaying(player: app, title: f[0], artist: f[1], album: f[2], playing: f[3] == "playing",
                                   position: Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0, duration: duration,
                                   artworkURL: f.count > 6 && f[6].hasPrefix("http") ? f[6] : nil))
    }

    nonisolated struct AskError: Error { let refused: Bool }

    private func send(_ command: String) {
        guard let app = player?.name ?? running().first?.name else { return }
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            _ = Self.queue.sync { NSAppleScript(source: "tell application \"\(app)\" to \(command)")?.executeAndReturnError(&error) }
            try? await Task.sleep(nanoseconds: 150_000_000)
            await MainActor.run { [weak self] in self?.refresh() }
        }
    }

    private func loadArtwork() {
        guard case .playing(let info) = state, let url = info.artworkURL, artwork?.url != url, let u = URL(string: url), u.scheme == "https" else { return }
        Task.detached(priority: .utility) {
            // An ephemeral session: no cookies, no cache, nothing kept on disk.
            guard let (data, _) = try? await URLSession(configuration: .ephemeral).data(from: u),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) else { return }
            await MainActor.run { [weak self] in
                self?.artwork = (url, image)
                self?.setNeedsDisplay(fade: true)
            }
        }
    }

    // --- Drawing ---

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        iconButton(ctx, "close", "xmark", CGRect(x: g.maxX - 56, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, quiet: true)
        let area = CGRect(x: g.minX + 24, y: g.minY + 24, width: g.width - 48, height: g.height - 48)
        switch state {
        case .looking:
            skeleton(ctx, CGRect(x: area.minX, y: area.minY, width: 200, height: 200), radius: 16)
            skeleton(ctx, CGRect(x: area.minX + 224, y: area.minY + 30, width: 220, height: 14), radius: 7)
            skeleton(ctx, CGRect(x: area.minX + 224, y: area.minY + 60, width: 150, height: 10), radius: 5)
        case .none:
            message(ctx, in: area, symbol: "music.note", title: "Nothing is playing",
                    detail: "Start something in Music or Spotify on the Mac: it shows here, with its controls.")
        case .refused(let app):
            message(ctx, in: area, symbol: "lock", title: "macOS hasn't let Halliday control \(app)",
                    detail: "It asks once, on the Mac's screen. Allow Halliday under Automation, then try again.",
                    action: ("permission", "Open System Settings"), problem: true)
            if hovered == nil { button(ctx, "retry", "Try again", CGRect(x: area.maxX - 120, y: area.maxY - 40, width: 120, height: 40), kind: .quiet) }
        case .playing(let info):
            drawPlaying(ctx, info, in: area)
        }
    }

    private func drawPlaying(_ ctx: CGContext, _ info: NowPlaying, in area: CGRect) {
        let cover = CGRect(x: area.minX, y: area.minY + 2, width: 200, height: 200)
        if let image = artwork?.image, artwork?.url == info.artworkURL {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: cover, cornerWidth: 16, cornerHeight: 16, transform: nil))
            ctx.clip()
            ctx.translateBy(x: cover.minX, y: cover.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: cover.size))
            ctx.restoreGState()
        } else {
            NightGlass.fill(ctx, cover, radius: 16, color: NightGlass.accent.withAlphaComponent(0.16))
            NightGlass.drawSymbol("music.note", in: cover, size: 56, color: NightGlass.accent, weight: .light)
        }
        let x = cover.maxX + 24, w = area.maxX - x - 40
        NightGlass.drawText(info.player.uppercased(), at: CGPoint(x: x, y: area.minY + 4), style: .caption, color: NightGlass.tertiary, weight: .semibold)
        NightGlass.drawText(info.title, at: CGPoint(x: x, y: area.minY + 26), style: .title, width: w)
        NightGlass.drawText(info.artist, at: CGPoint(x: x, y: area.minY + 56), style: .body, color: NightGlass.secondary, width: w)
        NightGlass.drawText(info.album, at: CGPoint(x: x, y: area.minY + 80), style: .label, color: NightGlass.tertiary, width: w)
        // Where in the song: a thin bar and the times.
        let barY = area.minY + 122, barW = area.maxX - x
        NightGlass.fill(ctx, CGRect(x: x, y: barY, width: barW, height: 4), radius: 2, color: NSColor(white: 1, alpha: 0.14))
        let f = info.duration > 0 ? CGFloat(min(1, info.position / info.duration)) : 0
        NightGlass.fill(ctx, CGRect(x: x, y: barY, width: barW * f, height: 4), radius: 2, color: NightGlass.accent)
        NightGlass.drawText(ClockModel.format(info.position.rounded(.down)), at: CGPoint(x: x, y: barY + 10), style: .caption, color: NightGlass.secondary, tabular: true)
        let total = ClockModel.format(info.duration)
        NightGlass.drawText(total, at: CGPoint(x: area.maxX - NightGlass.textSize(total, style: .caption, tabular: true).width, y: barY + 10),
                            style: .caption, color: NightGlass.secondary, tabular: true)
        // Controls.
        let y = area.minY + 156, mid = x + barW / 2
        iconButton(ctx, "previous", "backward.fill", CGRect(x: mid - 104, y: y, width: 52, height: 52), symbolSize: 18)
        iconButton(ctx, "toggle", info.playing ? "pause.fill" : "play.fill", CGRect(x: mid - 30, y: y - 4, width: 60, height: 60), symbolSize: 22, backed: true)
        iconButton(ctx, "next", "forward.fill", CGRect(x: mid + 52, y: y, width: 52, height: 52), symbolSize: 18)
    }
}
