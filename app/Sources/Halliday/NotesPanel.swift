// Notes (ROADMAP W13.4): a plain text pad in VR. Notes are text files in Application
// Support/Halliday/Notes (a text file opened from Files is edited where it is). Typed with the
// Mac's keyboard or the virtual one; saved by itself a moment after every change.
//
// Editing is at the end of the text: type, Return, Delete, paste. (A caret that moves through the
// text comes with real text editing, later.)

import AppKit

@MainActor
final class NotesPanel: VRPanel {
    var onClose: (() -> Void)?
    var onNotice: ((String) -> Void)?
    /// Called when the text area is clicked: the owner gives Halliday the keyboard.
    var onWantsKeyboard: (() -> Void)?

    private struct Note {
        var url: URL
        var title: String
    }

    private var notes: [Note] = []
    private var current: URL?
    private var text = ""
    private var dirty = false
    private var saveTimer: Timer?
    /// The text broken into lines for the page's width (redone when the text changes).
    private var lines: [String] = []

    static let distance: Float = 1.2
    static let below: Float = 4

    private static let margin: CGFloat = 24
    private static let width: CGFloat = 960, height: CGFloat = 600
    private static let sidebar: CGFloat = 240
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }
    private var page: CGRect { CGRect(x: glass.minX + Self.sidebar + 16, y: glass.minY + 68, width: glass.width - Self.sidebar - 32, height: glass.height - 68 - 44) }

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Halliday/Notes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(renderer: Renderer) {
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size, surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
    }

    /// Re-reads the notes; opens the most recent one (or `file`, a text file from elsewhere).
    func prepare(opening file: URL? = nil) {
        save()
        reloadList()
        if let file {
            open(file)
        } else if current == nil || !FileManager.default.fileExists(atPath: current!.path) {
            if let first = notes.first { open(first.url) } else { newNote() }
        }
        setNeedsDisplay()
    }

    private func reloadList() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = files.filter { $0.pathExtension == "txt" }.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        notes = dated.sorted { $0.1 > $1.1 }.map { Note(url: $0.0, title: Self.title(of: (try? String(contentsOf: $0.0, encoding: .utf8)) ?? "")) }
    }

    private static func title(of text: String) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "New note" : first
    }

    private func open(_ url: URL) {
        save()
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 400_000,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            onNotice?("\(url.lastPathComponent) can't be edited here (not plain text, or too long)")
            return
        }
        current = url
        text = content
        dirty = false
        rewrap()
        setNeedsDisplay()
    }

    private func newNote() {
        save()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.folder.appendingPathComponent("Note \(stamp.string(from: Date())).txt")
        try? "".write(to: url, atomically: true, encoding: .utf8)
        current = url
        text = ""
        dirty = false
        rewrap()
        reloadList()
        setNeedsDisplay()
    }

    /// Writes the note if it changed (also called when the panel closes).
    func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard dirty, let current else { return }
        dirty = false
        do {
            try text.write(to: current, atomically: true, encoding: .utf8)
        } catch {
            onNotice?("The note couldn't be saved: \(error.localizedDescription)")
        }
        if let i = notes.firstIndex(where: { $0.url == current }) { notes[i].title = Self.title(of: text) }
        setNeedsDisplay()
    }

    private func changed() {
        dirty = true
        rewrap()
        setNeedsDisplay()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    // --- Typing ---

    func insert(_ s: String) {
        guard current != nil else { return }
        text += s
        changed()
    }

    func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()
        changed()
    }

    /// A key press while Notes has the keyboard. Returns true if the key was used.
    func key(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) {
                insert(s)
                return true
            }
            return false
        }
        switch event.keyCode {
        case 53: return false // Esc closes (handled by the owner)
        case 36, 76: insert("\n")
        case 51: deleteBackward()
        case 48: insert("    ")
        default:
            guard let chars = event.characters, !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) })
            else { return true }
            insert(chars)
        }
        return true
    }

    private func activate(_ id: String) {
        switch id {
        case "close": onClose?()
        case "new": newNote(); onWantsKeyboard?()
        case "page": onWantsKeyboard?()
        case "trash":
            guard let url = current else { return }
            saveTimer?.invalidate()
            dirty = false
            // To the Mac's Trash, where it can be taken back from.
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                onNotice?("The note is in the Mac's Trash")
            } catch {
                onNotice?("The note couldn't be moved to the Trash: \(error.localizedDescription)")
                return
            }
            current = nil
            prepare()
        default:
            if id.hasPrefix("note:"), let i = Int(id.dropFirst(5)), notes.indices.contains(i) { open(notes[i].url) }
        }
    }

    // --- Drawing ---

    private static let lineHeight: CGFloat = 24

    /// Breaks the text into lines that fit the page (at spaces; a word longer than a line is cut).
    private func rewrap() {
        let width = page.width - 40
        var out: [String] = []
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                var word = String(word)
                let candidate = line.isEmpty ? word : line + " " + word
                if NightGlass.textSize(candidate, style: .body).width <= width {
                    line = candidate
                    continue
                }
                if !line.isEmpty { out.append(line) }
                while NightGlass.textSize(word, style: .body).width > width, word.count > 1 {
                    var cut = word.count - 1
                    while cut > 1, NightGlass.textSize(String(word.prefix(cut)), style: .body).width > width { cut -= max(1, cut / 8) }
                    out.append(String(word.prefix(cut)))
                    word = String(word.dropFirst(cut))
                }
                line = word
            }
            out.append(line)
        }
        lines = out
    }

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass
        NightGlass.drawText("Notes", at: CGPoint(x: g.minX + 24, y: g.minY + 20), style: .title)
        button(ctx, "new", "New note", CGRect(x: g.minX + 14, y: g.minY + 62, width: Self.sidebar - 28, height: 44), symbol: "square.and.pencil")
        var y = g.minY + 118
        for (i, note) in notes.prefix(9).enumerated() {
            let rect = CGRect(x: g.minX + 12, y: y, width: Self.sidebar - 24, height: 44)
            let isCurrent = note.url == current
            row(ctx, "note:\(i)", rect, radius: 22, rest: isCurrent ? 0.13 : 0)
            let h = NightGlass.textSize("Ag", style: .label).height
            NightGlass.drawText(isCurrent ? Self.title(of: text) : note.title, at: CGPoint(x: rect.minX + 16, y: rect.midY - h / 2), style: .label,
                                color: isCurrent ? NightGlass.text : NightGlass.secondary, weight: isCurrent ? .medium : .regular, width: rect.width - 30)
            y += 48
        }
        ctx.setFillColor(NightGlass.hairline.cgColor)
        ctx.fill(CGRect(x: g.minX + Self.sidebar, y: g.minY + 16, width: 1, height: g.height - 32))

        // Header: the note's name, trash, close.
        let right = g.maxX - 16
        let name = current.map { $0.deletingLastPathComponent().path == Self.folder.path ? Self.title(of: text) : $0.lastPathComponent } ?? ""
        let titleHeight = NightGlass.textSize("Ag", style: .title).height
        NightGlass.drawText(name, at: CGPoint(x: page.minX + 4, y: g.minY + 36 - titleHeight / 2), style: .title, width: page.width - 120)
        iconButton(ctx, "close", "xmark", CGRect(x: right - 40, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, quiet: true)
        iconButton(ctx, "trash", "trash", CGRect(x: right - 88, y: g.minY + 16, width: 40, height: 40), symbolSize: 14, enabled: current != nil, quiet: true)

        // The page: the end of the text, where typing goes.
        let p = page
        control("page", p)
        NightGlass.fill(ctx, p, radius: 18, color: NSColor(white: 0, alpha: hovered == "page" ? 0.34 : 0.28))
        let visible = Int((p.height - 32) / Self.lineHeight)
        let shown = lines.suffix(visible)
        var lineY = p.minY + 16
        var caret = CGPoint(x: p.minX + 20, y: lineY)
        for line in shown {
            let size = NightGlass.drawText(line, at: CGPoint(x: p.minX + 20, y: lineY), style: .body)
            caret = CGPoint(x: p.minX + 20 + (line.isEmpty ? 0 : size.width) + 1, y: lineY)
            lineY += Self.lineHeight
        }
        if text.isEmpty {
            NightGlass.drawText("Write here: the Mac's keyboard, or the keyboard in the dock", at: CGPoint(x: p.minX + 26, y: p.minY + 16), style: .body,
                                color: NightGlass.tertiary)
        }
        if caretOn(for: text) { NightGlass.fill(ctx, CGRect(x: caret.x, y: caret.y + 1, width: 1.5, height: 20), radius: 0.75, color: NightGlass.accent) }
        if lines.count > visible {
            NightGlass.drawText("\(lines.count - visible) lines above", at: CGPoint(x: p.minX + 4, y: p.maxY + 12), style: .caption, color: NightGlass.tertiary, tabular: true)
        }
        let state = dirty ? "Saving…" : "Saved"
        let stateSize = NightGlass.textSize(state, style: .caption)
        NightGlass.drawText(state, at: CGPoint(x: p.maxX - stateSize.width - 4, y: p.maxY + 12), style: .caption, color: NightGlass.tertiary)
    }
}
