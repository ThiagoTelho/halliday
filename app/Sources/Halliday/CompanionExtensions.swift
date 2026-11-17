// The companion's Extensions section (docs/extensions.md): the extensions installed, each with
// its switch, its files and Remove; installing one (Install..., or a folder or .zip dropped on the
// window), always through a sheet that says what it is, whom it is from, which apps it adapts and
// which hosts it may reach, before anything is copied; and the guide to writing one, rendered
// from the copy of docs/extensions.md in Halliday's bundle, with the example to start from.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An installed extension, as the companion lists it.
struct CompanionExtension: Equatable, Identifiable {
    let id: String
    let name: String
    let version: String
    let author: String
    let description: String
    let apps: [String]
    let reaches: String
    let anyHost: Bool
    let enabled: Bool
    let folder: URL
    /// "github.com/OWNER/REPO…" when it was installed from a link.
    let source: String?

    init(_ x: InstalledExtension) {
        let m = x.manifest
        id = m.id
        name = m.name
        version = m.version
        author = m.author
        description = m.description
        apps = m.apps
        reaches = Self.reaches(m)
        anyHost = m.anyHost
        enabled = x.enabled
        folder = x.folder
        source = x.source?.display
    }

    static func reaches(_ m: ExtensionManifest) -> String {
        m.network.isEmpty ? "No network" : m.anyHost ? "Any host" : m.network.joined(separator: ", ")
    }
}

/// An extension read and checked, waiting for the user's yes.
struct PendingExtension: Identifiable {
    let manifest: ExtensionManifest
    let folder: URL
    var id: String { manifest.id }
    /// The one it would replace (same id), if installed.
    let replacing: String?
    /// The GitHub link it was fetched from, and the temporary folder to delete afterwards.
    var source: GitHubSource? = nil
    var temporary: URL? = nil
}

extension CompanionModel {
    func chooseExtension() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "hallidayext") ?? .folder]
        panel.message = "Choose an extension: a .hallidayext folder, or a .zip of one"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openExtension(url)
    }

    /// Reads and checks an extension, then asks (`pendingExtension`); nothing is copied yet.
    /// `source`/`temporary`: it was fetched from GitHub into that temporary folder.
    func openExtension(_ url: URL, source: GitHubSource? = nil, temporary: URL? = nil) {
        do {
            let (manifest, folder) = try Extensions.open(url)
            let current = Extensions.installed().first { $0.id == manifest.id }
            pendingExtension = PendingExtension(manifest: manifest, folder: folder,
                                                replacing: current.map { "\($0.manifest.name) \($0.manifest.version)" },
                                                source: source, temporary: temporary)
        } catch {
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            extensionProblem = "\(source?.display ?? url.lastPathComponent) can't be installed:\n\n\(error)"
        }
    }

    /// An extension from a GitHub link: fetched once (ExtensionFromGitHub.swift), then the same
    /// sheet as for a folder on the Mac.
    func installFromGitHub(_ link: String) {
        guard let source = GitHubSource.parse(link) else {
            extensionProblem = "That isn't a GitHub repository's address. Use https://github.com/OWNER/REPO, or https://github.com/OWNER/REPO/tree/BRANCH/FOLDER for an extension in a folder of it."
            return
        }
        guard !fetchingExtension else { return }
        fetchingExtension = true
        Task { @MainActor in
            defer { fetchingExtension = false }
            do {
                let fetched = try await ExtensionFromGitHub.fetch(source)
                openExtension(fetched.folder, source: source, temporary: fetched.temporary)
            } catch {
                extensionProblem = "\(source.display) can't be installed:\n\n\(error)"
            }
        }
    }

    /// The sheet was dismissed without installing.
    func cancelExtension() {
        if let t = pendingExtension?.temporary { try? FileManager.default.removeItem(at: t) }
        pendingExtension = nil
    }

    func confirmExtension() {
        guard let p = pendingExtension else { return }
        pendingExtension = nil
        defer { if let t = p.temporary { try? FileManager.default.removeItem(at: t) } }
        do {
            try Extensions.install(from: p.folder, github: p.source)
            notice = "\(p.manifest.name) is installed: it applies the next time its app is opened"
        } catch {
            extensionProblem = "\(p.manifest.name) couldn't be installed:\n\n\(error)"
        }
        refresh()
    }

    func setExtension(_ x: CompanionExtension, enabled: Bool) {
        Extensions.setEnabled(x.id, enabled)
        notice = "\(x.name) is \(enabled ? "on" : "off"): it changes the next time its app is opened"
        refresh()
    }

    func removeExtension(_ x: CompanionExtension) {
        do {
            try Extensions.remove(x.id)
            notice = "\(x.name) is removed"
        } catch {
            extensionProblem = "\(x.name) couldn't be removed: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Saves a copy of the example extension (from Halliday's bundle) where the user chooses.
    func saveExample() {
        guard let example = Bundle.main.resourceURL?.appendingPathComponent("extension-example"),
              FileManager.default.fileExists(atPath: example.path) else {
            extensionProblem = "This build of Halliday doesn't carry the example (it is in extensions/example in Halliday's source)."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Example.hallidayext"
        panel.message = "Where to save the example extension, to start yours from"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: example, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            extensionProblem = "The example couldn't be saved: \(error.localizedDescription)"
        }
    }
}

struct ExtensionsPane: View {
    @ObservedObject var model: CompanionModel
    @State private var removing: CompanionExtension?
    @State private var guide = false
    @State private var link = ""

    private func get() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.installFromGitHub(text)
    }

    var body: some View {
        CompanionCard(title: "Install") {
            HStack(spacing: 14) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundStyle(companionAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Extensions adapt Halliday to an app").font(.headline)
                    Text("Choose a .hallidayext folder or a .zip of one, or drop it on this window. You see what it is before it is installed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Install…") { model.chooseExtension() }.controlSize(.large)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Or from GitHub").font(.headline)
                HStack(spacing: 10) {
                    TextField("https://github.com/OWNER/REPO", text: $link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { get() }
                        .disabled(model.fetchingExtension)
                    if model.fetchingExtension {
                        ProgressView().controlSize(.small)
                        Text("Fetching…").foregroundStyle(.secondary)
                    } else {
                        Button("Get") { get() }.disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text("The repository's link, or its folder's (…/tree/BRANCH/FOLDER). Halliday fetches it once from GitHub, and you see what it is before it is installed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        CompanionCard(title: model.extensions.isEmpty ? "Installed" : "Installed · \(model.extensions.count)") {
            if model.extensions.isEmpty {
                Text("No extensions installed.").foregroundStyle(.secondary)
            }
            ForEach(model.extensions) { x in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 24))
                        .foregroundStyle(x.enabled ? companionAccent.opacity(0.85) : Color.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(x.name)
                            Text(x.version).font(.callout).foregroundStyle(.secondary)
                        }
                        Text((x.author.isEmpty ? "" : "by \(x.author) · ") + "for \(x.apps.joined(separator: ", "))")
                            .font(.callout).foregroundStyle(.secondary)
                        Label("Reaches: \(x.reaches)", systemImage: x.anyHost ? "exclamationmark.triangle" : "network")
                            .font(.callout).foregroundStyle(x.anyHost ? Color.orange : Color.secondary)
                        if let source = x.source {
                            Label("From \(source)", systemImage: "link").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        HStack(spacing: 10) {
                            Button("Show files") { NSWorkspace.shared.open(x.folder) }
                            Button("Remove", role: .destructive) { removing = x }
                        }
                        .padding(.top, 4)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { x.enabled }, set: { model.setExtension(x, enabled: $0) }))
                        .toggleStyle(.switch).labelsHidden()
                        .help(x.enabled ? "On: it answers its app the next time the app is opened" : "Off: kept, but not used")
                }
                if x != model.extensions.last { Divider() }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this extension")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let x = removing { model.removeExtension(x) }
                removing = nil
            }
        } message: {
            Text("Its files are deleted. The app it adapts stays installed.")
        }
        CompanionCard(title: "Making an extension") {
            Text("An extension is a folder with a manifest.json and a script. The script answers an app's own calls through a small, sealed set of Halliday's functions: it can't reach the rest of your Mac, and it can only download from the hosts its manifest lists.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Read the guide") { guide = true }
                Button("Save the example…") { model.saveExample() }
            }
            Text("Check one from a terminal: halliday --check-extension FOLDER").font(.callout.monospaced()).foregroundStyle(.secondary)
        }
        .sheet(item: $model.pendingExtension) { p in
            InstallExtensionSheet(pending: p, install: { model.confirmExtension() }, cancel: { model.cancelExtension() })
        }
        .sheet(isPresented: $guide) { ExtensionGuide { guide = false } }
        .alert("Not installed", isPresented: Binding(get: { model.extensionProblem != nil }, set: { if !$0 { model.extensionProblem = nil } })) {
            Button("OK") { model.extensionProblem = nil }
        } message: {
            Text(model.extensionProblem ?? "")
        }
    }
}

/// What an extension is, before it is installed.
private struct InstallExtensionSheet: View {
    let pending: PendingExtension
    let install: () -> Void
    let cancel: () -> Void

    var body: some View {
        let m = pending.manifest
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 34)).foregroundStyle(companionAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(m.name)?").font(.title3.weight(.semibold))
                    Text("Version \(m.version)" + (m.author.isEmpty ? "" : " · by \(m.author), as the extension says"))
                        .foregroundStyle(.secondary)
                }
            }
            if !m.description.isEmpty { Text(m.description).fixedSize(horizontal: false, vertical: true) }
            VStack(alignment: .leading, spacing: 8) {
                Fact(symbol: "app.badge", title: "Adapts", value: m.apps.joined(separator: ", "))
                Fact(symbol: "square.stack.3d.up", title: "Answers", value: m.plugins.map(\.name).joined(separator: ", ").ifEmpty("Only the player"))
                Fact(symbol: m.anyHost ? "exclamationmark.triangle" : "network", title: "May download from",
                     value: CompanionExtension.reaches(m), warn: m.anyHost)
                if let s = pending.source { Fact(symbol: "link", title: "From", value: s.display) }
                if let r = pending.replacing { Fact(symbol: "arrow.triangle.2.circlepath", title: "Replaces", value: r) }
            }
            .padding(14)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            Text(m.anyHost
                 ? "Extensions are code from their authors, not Halliday's. This one may download from any host while its app is open. Install only extensions you trust."
                 : "Extensions are code from their authors, not Halliday's. Install only extensions you trust.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(pending.replacing == nil ? "Install" : "Replace", action: install).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private struct Fact: View {
        let symbol: String, title: String, value: String
        var warn = false
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(warn ? Color.orange : companionAccent)
                Text(title).frame(width: 130, alignment: .leading).foregroundStyle(.secondary)
                Text(value).foregroundStyle(warn ? Color.orange : Color.primary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

/// The guide, docs/extensions.md, as Halliday's bundle carries it.
private struct ExtensionGuide: View {
    let close: () -> Void
    private let blocks = MarkdownBlock.parse(
        Bundle.main.resourceURL.flatMap { try? String(contentsOf: $0.appendingPathComponent("extensions.md"), encoding: .utf8) }
            ?? "# Extensions\n\nThe guide isn't in this build of Halliday: it is docs/extensions.md in Halliday's source.")

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks.indices, id: \.self) { i in blocks[i].view }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 640)
    }
}

/// Enough of Markdown for the guide: headings, paragraphs, lists, code blocks and tables, with
/// inline emphasis, code and links.
private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String)
    case code(String)
    case table([[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var lines = text.components(separatedBy: "\n")[...]
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        while let line = lines.popFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                flush()
                var code: [String] = []
                while let l = lines.popFirst(), !l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(l) }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if t.hasPrefix("#") {
                flush()
                let level = t.prefix { $0 == "#" }.count
                blocks.append(.heading(level, String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if t.hasPrefix("|") {
                flush()
                var rows: [[String]] = []
                var row: Substring? = Substring(t)
                while let r = row {
                    let cells = r.trimmingCharacters(in: .whitespaces).dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { rows.append(cells) }
                    if let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") { row = Substring(lines.popFirst()!) } else { row = nil }
                }
                blocks.append(.table(rows))
            } else if t.hasPrefix("- ") {
                flush()
                var item = String(t.dropFirst(2))
                while let next = lines.first, next.hasPrefix("  "), !next.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                    item += " " + lines.popFirst()!.trimmingCharacters(in: .whitespaces)
                }
                blocks.append(.bullet(item))
            } else if t.isEmpty {
                flush()
            } else {
                paragraph.append(t)
            }
        }
        flush()
        return blocks
    }

    private static func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
    }

    @ViewBuilder var view: some View {
        switch self {
        case .heading(let level, let text):
            Self.inline(text).font(level == 1 ? .largeTitle.weight(.bold) : level == 2 ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .padding(.top, level == 1 ? 0 : 10)
        case .paragraph(let text):
            Self.inline(text).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Self.inline(text).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code).font(.system(.callout, design: .monospaced)).padding(12)
            }
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow {
                        ForEach(rows[r].indices, id: \.self) { c in
                            Self.inline(rows[r][c]).font(r == 0 ? .callout.weight(.semibold) : .callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: c == 0 ? 220 : .infinity, alignment: .leading)
                        }
                    }
                    if r == 0 { Divider() }
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
