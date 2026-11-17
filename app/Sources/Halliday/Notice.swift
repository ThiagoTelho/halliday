// Notices in VR (ROADMAP W12 A.5, design board 8): a short Night Glass message above the dock when
// something happened by itself ("Safari left VR: its window was closed"), when something the user
// asked for can't be done as it is (with a button for the way forward, when there is one), or
// while something is on its way ("Opening Notes", with a spinner). They replace failures that
// only reached the log.

import AppKit

@MainActor
final class NoticePanel: VRPanel {
    enum Kind {
        /// Something happened.
        case info
        /// Something couldn't be done, or a limit was reached.
        case warning
        /// Something is on its way.
        case progress
    }

    private var text = ""
    private var symbol = "info.circle"
    private(set) var kind = Kind.info
    private var action: (title: String, run: () -> Void)?
    /// It has a button: the notice takes the pointer.
    var hasAction: Bool { action != nil }
    /// Called when the notice's button was used (the notice then goes away).
    var onDone: (() -> Void)?

    private static let margin: CGFloat = 40 // room for the shadow
    private static let width: CGFloat = 760, height: CGFloat = 54

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        // No surface unless it has a button: a notice doesn't take the pointer.
        super.init(renderer: renderer, size: size, surface: .zero)
        onActivate = { [weak self] id in
            guard id == "action", let self else { return }
            let run = action?.run
            onDone?()
            run?()
        }
    }

    func show(_ text: String, symbol: String? = nil, kind: Kind = .info, action: (title: String, run: () -> Void)? = nil) {
        self.text = text
        self.kind = kind
        self.symbol = symbol ?? (kind == .warning ? "exclamationmark.triangle" : "info.circle")
        self.action = action
        setNeedsDisplay()
    }

    override func draw(in ctx: CGContext) {
        let textSize = NightGlass.textSize(text, style: .label, weight: .medium)
        let buttonWidth = action.map { NightGlass.textSize($0.title, style: .label, weight: .medium).width + 36 } ?? 0
        let tail: CGFloat = action == nil ? 22 : buttonWidth + 14
        let width = min(Self.width, 50 + textSize.width + tail)
        let pill = CGRect(x: size.width / 2 - width / 2, y: Self.margin, width: width, height: Self.height)
        NightGlass.fill(ctx, pill, radius: Self.height / 2, color: NightGlass.solidGlass.withAlphaComponent(0.86))
        ctx.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: pill.height / 2 - 0.5, cornerHeight: pill.height / 2 - 0.5, transform: nil))
        ctx.setStrokeColor(NightGlass.hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        declareGlass(pill, radius: pill.height / 2)
        extraSurface = action == nil ? nil : pill
        NightGlass.topLight(ctx, pill, radius: pill.height / 2, alpha: 0.22)
        // A round, lit icon by kind (board 20): amber for a warning, blue otherwise.
        let icon = CGRect(x: pill.minX + 9, y: pill.minY + 9, width: pill.height - 18, height: pill.height - 18)
        if kind == .progress {
            spinner(ctx, center: CGPoint(x: icon.midX, y: icon.midY), radius: 8)
        } else {
            let colors = kind == .warning
                ? (NSColor(srgbRed: 0xFF / 255, green: 0xC8 / 255, blue: 0x70 / 255, alpha: 1), NSColor(srgbRed: 0xE0 / 255, green: 0x88 / 255, blue: 0x2A / 255, alpha: 1))
                : (NightGlass.litTop, NightGlass.litBottom)
            NightGlass.drawAppTile(ctx, icon, radius: icon.height / 2, colors: colors, symbol: symbol.replacingOccurrences(of: ".circle", with: ""), symbolSize: 14)
        }
        NightGlass.drawText(text, at: CGPoint(x: pill.minX + 50, y: pill.midY - textSize.height / 2), style: .label,
                            weight: .medium, width: pill.width - 50 - tail)
        if let action {
            button(ctx, "action", action.title, CGRect(x: pill.maxX - buttonWidth - 7, y: pill.minY + 7, width: buttonWidth, height: pill.height - 14))
        }
    }
}
