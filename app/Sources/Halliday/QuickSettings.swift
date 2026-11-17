// Quick settings (ROADMAP W11 B.5): the Night Glass panel that opens above the dock from its clock.
// Mode, volume, panel distance, environment dimming and recenter.

import AppKit

@MainActor
final class QuickSettings: VRPanel {
    private let settings = Settings.shared
    var onRecenter: (() -> Void)?
    var onAllSettings: (() -> Void)?

    private static let margin: CGFloat = 24 // room for the shadow
    private static let width: CGFloat = 440, height: CGFloat = 534
    private var glassRect: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    /// Slider tracks as drawn, for dragging.
    private var tracks: [String: CGRect] = [:]

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        onPress = { [weak self] id in if let p = self?.lastPoint { self?.slide(id, to: p) } }
        onDrag = { [weak self] id, p in self?.slide(id, to: p) }
        setNeedsDisplay()
    }

    private func activate(_ id: String) {
        if id.hasPrefix("mode:"), let mode = Settings.Mode(rawValue: String(id.dropFirst(5))) {
            settings.mode = mode
        } else if id == "recenter" {
            onRecenter?()
        } else if id == "all" {
            onAllSettings?()
        }
        setNeedsDisplay()
    }

    private func slide(_ id: String, to p: CGPoint) {
        guard let track = tracks[id] else { return }
        let t = Float(max(0, min(1, (p.x - track.minX) / track.width)))
        switch id {
        case "distance":
            let r = Settings.panelDistanceRange
            settings.panelDistance = ((r.lowerBound + t * (r.upperBound - r.lowerBound)) * 10).rounded() / 10
        case "volume":
            settings.volume = (t * 20).rounded() / 20
        case "brightness":
            let r = Settings.brightnessRange
            settings.brightness = ((r.lowerBound + t * (r.upperBound - r.lowerBound)) * 20).rounded() / 20
        case "dimming":
            settings.dimming = (t * Settings.dimmingRange.upperBound * 20).rounded() / 20
        default: return
        }
        setNeedsDisplay()
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glassRect, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glassRect
        let x = g.minX + 20, w = g.width - 40
        var y = g.minY + 20

        // Mode.
        NightGlass.drawText("Mode", at: CGPoint(x: x, y: y), style: .caption, color: NightGlass.secondary)
        y += 24
        y = segmented(ctx, Settings.Mode.allCases.map { ("mode:\($0.rawValue)", $0.label, settings.mode == $0) }, x: x, y: y, width: w) + 14

        // Sliders.
        y = slider(ctx, "volume", title: "Volume", value: settings.volume < 0.01 ? "Off" : "\(Int((settings.volume * 100).rounded()))%",
                   fraction: CGFloat(settings.volume), x: x, y: y, width: w)
        let br = Settings.brightnessRange
        y = slider(ctx, "brightness", title: "Headset brightness", value: "\(Int((settings.brightness * 100).rounded()))%",
                   fraction: CGFloat((settings.brightness - br.lowerBound) / (br.upperBound - br.lowerBound)), x: x, y: y, width: w)
        let dr = Settings.panelDistanceRange
        y = slider(ctx, "distance", title: "Panel distance", value: String(format: "%.1f m", settings.panelDistance),
                   fraction: CGFloat((settings.panelDistance - dr.lowerBound) / (dr.upperBound - dr.lowerBound)), x: x, y: y, width: w)
        y = slider(ctx, "dimming", title: "Environment dimming", value: "\(Int((settings.dimming * 100).rounded()))%",
                   fraction: CGFloat(settings.dimming / Settings.dimmingRange.upperBound), x: x, y: y, width: w)

        // Recenter.
        let button = CGRect(x: x, y: y + 4, width: w, height: 52)
        self.button(ctx, "recenter", "Recenter", button, symbol: "scope")

        // The rest lives in the full Settings panel.
        self.button(ctx, "all", "All settings", CGRect(x: x, y: button.maxY + 8, width: w, height: 40), kind: .quiet)
    }

    /// A titled slider; returns the y below it.
    private func slider(_ ctx: CGContext, _ id: String, title: String, value: String, fraction: CGFloat,
                        x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        NightGlass.drawText(title, at: CGPoint(x: x, y: y), style: .caption, color: NightGlass.secondary)
        let valueSize = NightGlass.textSize(value, style: .caption, tabular: true)
        NightGlass.drawText(value, at: CGPoint(x: x + width - valueSize.width, y: y), style: .caption, tabular: true)
        // The track's hit area is a full 40 dmm tall row.
        let row = CGRect(x: x, y: y + 20, width: width, height: 40)
        tracks[id] = slider(ctx, id, row: row, fraction: fraction)
        return row.maxY + 14
    }
}
