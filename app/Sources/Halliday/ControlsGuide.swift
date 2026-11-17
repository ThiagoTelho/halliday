// What every button and key does, in one place: the Controls panel in VR (the launcher's
// "Controls", or the / key) and the companion's Controls section both show `ControlsGuide`.
// Keep it in step with `AppDelegate.updateSense`, `handleKey` and `HeadsetView.keyDown`: a
// mapping that changes there changes here in the same commit.

import AppKit

enum ControlsGuide {
    struct Entry {
        /// The button or key, as it is named on the controller or the keyboard.
        let input: String
        let does: String
    }

    struct Topic {
        let id: String
        let name: String
        let symbol: String
        let note: String
        let entries: [Entry]
    }

    static let topics: [Topic] = [
        Topic(id: "controllers", name: "Controllers", symbol: "gamecontroller",
              note: "The PS VR2 Sense controllers in Halliday. The hand that last pulled a trigger or a grip has the pointer.",
              entries: [
                Entry(input: "Trigger", does: "Click what the pointer is on; hold to drag"),
                Entry(input: "Grip (R1 / L1)", does: "Secondary click, as the mouse's right button"),
                Entry(input: "Stick", does: "Scroll the list or the page under the pointer"),
                Entry(input: "PS · hold", does: "Recenter: everything comes back in front of you"),
                Entry(input: "PS · tap", does: "Set where the controller points (aim at the middle of your view first)"),
                Entry(input: "Options / Create", does: "The same as a tap of PS"),
                Entry(input: "Fn under the visor", does: "Passthrough: see your room, and back"),
              ]),
        Topic(id: "video", name: "Videos", symbol: "play.rectangle",
              note: "While a video plays. The bar and the dock hide by themselves after a few seconds.",
              entries: [
                Entry(input: "Trigger", does: "Bring the player's bar and the dock back"),
                Entry(input: "Cross / Square", does: "Hide the bar and the dock, or show them"),
                Entry(input: "Stick", does: "Turn where straight ahead looks in a video around you"),
                Entry(input: "PS · hold", does: "Recenter the video, and undo the stick's turn"),
                Entry(input: "Space", does: "Play or pause"),
                Entry(input: "← / →", does: "Back or forward 10 seconds"),
                Entry(input: "F · G · C", does: "Projection · 2D or 3D layout · subtitles"),
                Entry(input: "X", does: "Close the video"),
              ]),
        Topic(id: "games", name: "In a game", symbol: "figure.walk",
              note: "In a Windows VR game or an app made for a standalone headset, the controllers are the game's hands.",
              entries: [
                Entry(input: "PS · tap", does: "Halliday's menu over the game, and back to it"),
                Entry(input: "PS · hold", does: "Recenter the game's world in front of you"),
                Entry(input: "R1 + stick up / down", does: "Raise or lower yourself in the game's world"),
                Entry(input: "Trigger · Grip · Stick", does: "The game's own, as on its headset"),
                Entry(input: "Cross / Square", does: "The game's A / X button"),
                Entry(input: "Circle / Triangle", does: "The game's B / Y button (menu in SteamVR games)"),
                Entry(input: "Options / Create", does: "The game's system button"),
                Entry(input: "Esc", does: "Halliday's menu over the game, from the keyboard"),
                Entry(input: "W A S D · Q E", does: "Walk, and down or up, from the keyboard"),
                Entry(input: "⌥ + mouse", does: "Move the right hand (⌥⇧ the left); the wheel its reach; H brings both back"),
              ]),
        Topic(id: "keyboard", name: "Keyboard", symbol: "keyboard",
              note: "While Halliday has the keyboard. Control twice gives the mouse and keyboard back to the Mac.",
              entries: [
                Entry(input: "A · M · B", does: "Apps · Mac windows · browser"),
                Entry(input: "O · E · N", does: "Videos · files · notes"),
                Entry(input: "K", does: "The keyboard in VR"),
                Entry(input: ", · .", does: "Quick settings · all settings"),
                Entry(input: "/", does: "This list"),
                Entry(input: "T", does: "Passthrough"),
                Entry(input: "R · hold", does: "Recenter"),
                Entry(input: "Esc", does: "Close the panel on top; with nothing open, quit Halliday"),
                Entry(input: "Control twice", does: "Free the mouse for the Mac's own screen"),
                Entry(input: "[ · ]", does: "Predict the head 2 ms less or more far ahead"),
              ]),
    ]
}

/// The Controls panel in VR: the guide's topics as tabs, each a list of inputs and what they do.
@MainActor
final class ControlsPanel: VRPanel {
    var onClose: (() -> Void)?
    private var topic = ControlsGuide.topics[0].id

    static let distance: Float = 1.3
    static let below: Float = 4

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 820, height: CGFloat = 668
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in
            guard let self else { return }
            if id == "close" { onClose?() } else if id.hasPrefix("topic:") { topic = String(id.dropFirst(6)) }
            setNeedsDisplay(fade: true)
        }
    }

    /// Opens on the topic for what the user is doing (a game, a video).
    func show(topic id: String) {
        if ControlsGuide.topics.contains(where: { $0.id == id }) { topic = id }
        setNeedsDisplay()
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 28, w = g.width - 56
        NightGlass.drawText("Controls", at: CGPoint(x: x, y: g.minY + 24), style: .display, weight: .semibold)
        iconButton(ctx, "close", "xmark", CGRect(x: g.maxX - 56, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, quiet: true)
        var y = segmented(ctx, ControlsGuide.topics.map { ("topic:\($0.id)", $0.name, $0.id == topic) }, x: x, y: g.minY + 78, width: w) + 16
        guard let shown = ControlsGuide.topics.first(where: { $0.id == topic }) else { return }
        for line in NightGlass.wrap(shown.note, style: .label, width: w).prefix(2) {
            NightGlass.drawText(line, at: CGPoint(x: x, y: y), style: .label, color: NightGlass.secondary)
            y += 21
        }
        y += 12
        // Each input on a chip of its own, what it does beside it; the chips share a column.
        let chipWidth = (shown.entries.map { NightGlass.textSize($0.input, style: .label, weight: .semibold).width }.max() ?? 0) + 28
        let rowHeight: CGFloat = 42
        for entry in shown.entries {
            let chip = CGRect(x: x, y: y + 4, width: chipWidth, height: rowHeight - 10)
            NightGlass.fill(ctx, chip, radius: 10, color: NSColor(white: 1, alpha: 0.09))
            let size = NightGlass.textSize(entry.input, style: .label, weight: .semibold)
            NightGlass.drawText(entry.input, at: CGPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), style: .label,
                                color: NightGlass.text, weight: .semibold)
            let textHeight = NightGlass.textSize("Ag", style: .body).height
            NightGlass.drawText(entry.does, at: CGPoint(x: chip.maxX + 18, y: chip.midY - textHeight / 2), style: .body,
                                width: g.maxX - 28 - chip.maxX - 18)
            y += rowHeight
        }
    }
}
