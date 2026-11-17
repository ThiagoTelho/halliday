// Clock (ROADMAP W13.5): the time and date, a timer and a stopwatch, in a Night Glass panel. The
// timer keeps running with the panel closed: the dock shows what is left, and when it ends a chime
// plays and a notice says so.

import AppKit

/// The timer and stopwatch, kept while the panel is closed.
@MainActor
final class ClockModel {
    static let shared = ClockModel()

    /// Called when the timer reaches zero.
    var onTimerDone: (() -> Void)?

    // Timer: a length, and either when it ends (running) or what was left (paused).
    private(set) var timerLength: TimeInterval = 5 * 60
    private(set) var timerEnd: Date?
    private var timerLeftWhenPaused: TimeInterval?
    var timerRunning: Bool { timerEnd != nil }
    var timerLeft: TimeInterval {
        if let timerEnd { return max(0, timerEnd.timeIntervalSinceNow) }
        return timerLeftWhenPaused ?? timerLength
    }
    var timerIsSet: Bool { timerRunning || timerLeftWhenPaused != nil }

    func setTimer(minutes: Double) {
        timerLength = minutes * 60
        timerEnd = nil
        timerLeftWhenPaused = nil
    }

    func addMinute() {
        if let end = timerEnd { timerEnd = end.addingTimeInterval(60) }
        else if let left = timerLeftWhenPaused { timerLeftWhenPaused = left + 60 }
        else { timerLength += 60 }
    }

    func toggleTimer() {
        if let end = timerEnd {
            timerLeftWhenPaused = max(0, end.timeIntervalSinceNow)
            timerEnd = nil
        } else {
            timerEnd = Date().addingTimeInterval(timerLeftWhenPaused ?? timerLength)
            timerLeftWhenPaused = nil
        }
    }

    func resetTimer() {
        timerEnd = nil
        timerLeftWhenPaused = nil
    }

    /// Call often (each frame is fine): ends the timer when its time has come.
    func tick() {
        guard let end = timerEnd, end.timeIntervalSinceNow <= 0 else { return }
        timerEnd = nil
        timerLeftWhenPaused = nil
        onTimerDone?()
    }

    // Stopwatch: time gathered before the last start, and when it last started.
    private var stopwatchBefore: TimeInterval = 0
    private var stopwatchStart: Date?
    var stopwatchRunning: Bool { stopwatchStart != nil }
    var stopwatch: TimeInterval { stopwatchBefore + (stopwatchStart.map { -$0.timeIntervalSinceNow } ?? 0) }

    func toggleStopwatch() {
        if let start = stopwatchStart {
            stopwatchBefore += -start.timeIntervalSinceNow
            stopwatchStart = nil
        } else {
            stopwatchStart = Date()
        }
    }

    func resetStopwatch() {
        stopwatchBefore = 0
        stopwatchStart = nil
    }

    static func format(_ t: TimeInterval, tenths: Bool = false) -> String {
        let total = tenths ? t : t.rounded(.up)
        let h = Int(total) / 3600, m = Int(total) % 3600 / 60, s = Int(total) % 60
        let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        return tenths ? base + String(format: ".%d", Int((t * 10).truncatingRemainder(dividingBy: 10))) : base
    }
}

@MainActor
final class ClockPanel: VRPanel {
    private let model = ClockModel.shared
    var onClose: (() -> Void)?
    private var tab = "timer"

    static let distance: Float = 1.2
    static let below: Float = 6

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 560, height: CGFloat = 452
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = NightGlass.dateLocale
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "tab:timer": tab = "timer"
        case "tab:stopwatch": tab = "stopwatch"
        case "timer:toggle": model.toggleTimer()
        case "timer:reset": model.resetTimer()
        case "timer:add": model.addMinute()
        case "stopwatch:toggle": model.toggleStopwatch()
        case "stopwatch:reset": model.resetStopwatch()
        default:
            if id.hasPrefix("preset:"), let m = Double(id.dropFirst(7)) { model.setTimer(minutes: m) }
        }
        setNeedsDisplay(fade: true)
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        let x = g.minX + 28, w = g.width - 56
        // It redraws by itself while showing seconds that change (and once a second for the clock).
        animates = true
        iconButton(ctx, "close", "xmark", CGRect(x: g.maxX - 56, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, quiet: true)

        // The time, large, and the date.
        let now = Date()
        let time = Self.timeFormatter.string(from: now)
        let timeSize = NightGlass.textSize(time, style: .display, weight: .semibold, tabular: true)
        ctx.saveGState()
        // Twice the display size: the clock is the panel's point.
        ctx.translateBy(x: g.midX - timeSize.width, y: g.minY + 34)
        ctx.scaleBy(x: 2, y: 2)
        NightGlass.drawText(time, at: .zero, style: .display, weight: .semibold, tabular: true)
        ctx.restoreGState()
        let date = Self.dateFormatter.string(from: now)
        let dateSize = NightGlass.textSize(date, style: .body)
        NightGlass.drawText(date, at: CGPoint(x: g.midX - dateSize.width / 2, y: g.minY + 34 + timeSize.height * 2 + 2), style: .body, color: NightGlass.secondary)

        var y = g.minY + 172
        y = segmented(ctx, [("tab:timer", "Timer", tab == "timer"), ("tab:stopwatch", "Stopwatch", tab == "stopwatch")], x: x, y: y, width: w) + 10

        if tab == "timer" {
            let left = ClockModel.format(model.timerLeft)
            let size = NightGlass.textSize(left, style: .display, weight: .medium, tabular: true)
            ctx.saveGState()
            ctx.translateBy(x: g.midX - size.width * 0.8, y: y)
            ctx.scaleBy(x: 1.6, y: 1.6)
            NightGlass.drawText(left, at: .zero, style: .display, color: model.timerRunning ? NightGlass.accent : NightGlass.text, weight: .medium, tabular: true)
            ctx.restoreGState()
            y += size.height * 1.6 + 14
            if !model.timerIsSet {
                // Presets: what the timer will run for.
                let presets = [1, 5, 10, 25, 45]
                let chip = (w - CGFloat(presets.count - 1) * 8) / CGFloat(presets.count)
                for (i, m) in presets.enumerated() {
                    let rect = CGRect(x: x + CGFloat(i) * (chip + 8), y: y, width: chip, height: 40)
                    let chosen = abs(model.timerLength - Double(m) * 60) < 1
                    row(ctx, "preset:\(m)", rect, radius: 20, selected: chosen, rest: chosen ? 0 : 0.08)
                    let label = "\(m) min"
                    let s = NightGlass.textSize(label, style: .label)
                    NightGlass.drawText(label, at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2), style: .label,
                                        color: chosen ? NightGlass.accent : NightGlass.text)
                }
            }
            y += 56
            let third = (w - 16) / 3
            button(ctx, "timer:reset", "Reset", CGRect(x: x, y: y, width: third, height: 48), enabled: model.timerIsSet)
            button(ctx, "timer:toggle", model.timerRunning ? "Pause" : (model.timerIsSet ? "Resume" : "Start"),
                   CGRect(x: x + third + 8, y: y, width: third, height: 48), symbol: model.timerRunning ? "pause.fill" : "play.fill", kind: .main)
            button(ctx, "timer:add", "+1 min", CGRect(x: x + 2 * (third + 8), y: y, width: third, height: 48))
        } else {
            let shown = ClockModel.format(model.stopwatch, tenths: true)
            let size = NightGlass.textSize(shown, style: .display, weight: .medium, tabular: true)
            ctx.saveGState()
            ctx.translateBy(x: g.midX - size.width * 0.8, y: y + 20)
            ctx.scaleBy(x: 1.6, y: 1.6)
            NightGlass.drawText(shown, at: .zero, style: .display, color: model.stopwatchRunning ? NightGlass.accent : NightGlass.text, weight: .medium, tabular: true)
            ctx.restoreGState()
            y += size.height * 1.6 + 90
            let half = (w - 8) / 2
            button(ctx, "stopwatch:reset", "Reset", CGRect(x: x, y: y, width: half, height: 48), enabled: model.stopwatch > 0)
            button(ctx, "stopwatch:toggle", model.stopwatchRunning ? "Stop" : (model.stopwatch > 0 ? "Resume" : "Start"),
                   CGRect(x: x + half + 8, y: y, width: half, height: 48), symbol: model.stopwatchRunning ? "pause.fill" : "play.fill", kind: .main)
        }
    }
}
