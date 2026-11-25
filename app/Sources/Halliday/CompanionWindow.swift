// The companion: Halliday's window on the Mac's own screen, for what is easier with the headset
// off (ROADMAP W16): what the headset and the controllers are doing, the settings, the apps
// installed from .apk files (installing one, by a file dialog or by dropping it on the window),
// the display and tracking adjustments. It is an ordinary Mac window (SwiftUI in an NSWindow):
// while it is the key window the mouse is the Mac's, not the VR pointer's (`AppDelegate`
// `companionIsFront`), and "Back to the headset" hands it over again.
//
// Everything it sets goes through `Settings.shared`, as the panels in VR do, so the two are
// always in step; what it shows of the running session is asked for twice a second.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the companion shows of the running session.
struct CompanionStatus: Equatable {
    var onHeadset = false
    var headset = "Not connected"
    var displayHz = 0
    var framesPerSecond = 0.0
    var controllers: [String] = []
    var playing: String?
    /// Nil without the headset (no cameras).
    var passthrough: Bool?
    var predictionMs = 0
    /// Halliday shows on the Mac's screen though the headset is connected, and whether there
    /// is a headset to switch to at all.
    var desktopMode = false
    var canSwitchOutput = false
}

/// A Windows VR game of GameHub's, as the companion lists it.
struct CompanionGame: Equatable, Identifiable {
    let id: String
    let name: String
    let status: String
    /// Set up for Halliday (Undo is offered), or still to set up; nil: nothing to do yet.
    let setUp: Bool?
}

/// A window of the Mac, as the companion lists it.
struct CompanionMacWindow: Equatable, Identifiable {
    let id: UInt32
    let app: String
    let title: String
    let inVR: Bool
    /// Why it can't be brought in as it is (minimized, full screen, another Space), if so.
    let hint: String?
}

/// What a frame costs, from the last few seconds (the log's `[stat]` line).
struct CompanionFrame: Equatable {
    var framesPerSecond = 0.0
    var gpuMs = 0.0, gpuWorstMs = 0.0
    var layers = 0
    var captures = 0, captureMegapixels = 0.0, seconds = 0.0
    var parts: [String] = []
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var games: [CompanionGame] = []
    @Published var hasGameHub = false
    @Published var macWindows: [CompanionMacWindow] = []
    @Published var windowsLoading = false
    @Published var frame = CompanionFrame()
    /// The last minutes' GPU time a frame, oldest first (for the chart).
    @Published var frameHistory: [Double] = []

    var readGames: (() -> (games: [CompanionGame], hasGameHub: Bool))?
    var onGame: ((String, Bool) -> Void)?
    var onOpenGameHub: (() -> Void)?
    var readWindows: (() async -> [CompanionMacWindow])?
    var onWindow: ((UInt32, Bool) async -> Void)?
    var readFrame: (() -> CompanionFrame)?

    func refreshWindows() {
        guard !windowsLoading, let readWindows else { return }
        windowsLoading = true
        Task { @MainActor in
            macWindows = await readWindows()
            windowsLoading = false
        }
    }

    func move(_ window: CompanionMacWindow) {
        guard let onWindow else { return }
        Task { @MainActor in
            await onWindow(window.id, !window.inVR)
            refreshWindows()
        }
    }

    @Published var status = CompanionStatus()
    @Published var apps: [QuestApp] = []
    /// Installed extensions; the one waiting for the user's yes; why the last one couldn't be read.
    @Published var extensions: [CompanionExtension] = []
    @Published var pendingExtension: PendingExtension?
    @Published var extensionProblem: String?
    /// A GitHub link being fetched.
    @Published var fetchingExtension = false
    @Published var places: [Environments.Place] = []
    /// Bumped at every refresh, so controls bound to `Settings` follow changes made in VR.
    @Published var tick = 0
    @Published var notice: String?
    /// What the last "Look for the headset" found.
    @Published var headsetSearch: String?

    var readStatus: (() -> CompanionStatus)?
    var onRecenter: (() -> Void)?
    var onPassthrough: (() -> Void)?
    var onInstall: ((URL) -> Void)?
    var onRemove: ((QuestApp) -> Void)?
    var onPlay: ((QuestApp) -> Void)?
    var onBackToHeadset: (() -> Void)?
    var onDesktopMode: ((Bool) -> Void)?
    /// Looks for the headset now; says what was found.
    var onLookForHeadset: (() -> String)?
    var onQuit: (() -> Void)?
    var onPrediction: ((Int) -> Void)?

    func refresh() {
        if let s = readStatus?(), s != status { status = s }
        let installed = QuestApps.installed()
        if installed != apps { apps = installed }
        let ext = Extensions.installed().map(CompanionExtension.init)
        if ext != extensions { extensions = ext }
        let all = Environments.all()
        if all != places { places = all }
        if let g = readGames?() {
            if g.games != games { games = g.games }
            if g.hasGameHub != hasGameHub { hasGameHub = g.hasGameHub }
        }
        if let f = readFrame?(), f != frame {
            frame = f
            if f.gpuMs > 0 { frameHistory = Array((frameHistory + [f.gpuMs]).suffix(60)) }
        }
        tick &+= 1
    }

    func lookForHeadset() {
        headsetSearch = onLookForHeadset?()
        refresh()
    }

    /// A control's binding to one of Halliday's settings.
    func setting<T>(_ path: ReferenceWritableKeyPath<Settings, T>) -> Binding<T> {
        Binding(get: { Settings.shared[keyPath: path] }, set: { [weak self] in
            Settings.shared[keyPath: path] = $0
            self?.tick &+= 1
        })
    }

    func install(_ url: URL) {
        // A link dropped from a browser: an extension on GitHub.
        if !url.isFileURL {
            installFromGitHub(url.absoluteString)
            return
        }
        // An extension: a .hallidayext folder, a .zip, or any folder holding a manifest.json.
        let ext = url.pathExtension.lowercased()
        if ext == "hallidayext" || ext == "zip" || FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) {
            openExtension(url)
            return
        }
        guard ext == "apk" else {
            notice = "\(url.lastPathComponent) is neither an app (.apk) nor an extension"
            return
        }
        notice = "Installing \(url.deletingPathExtension().lastPathComponent)…"
        onInstall?(url)
    }

    func chooseAPK() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose apps made for standalone headsets (.apk files) to install in Halliday"
        panel.prompt = "Install"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { install(url) }
    }
}

@MainActor
final class CompanionWindow: NSObject, NSWindowDelegate {
    let model = CompanionModel()
    let window: NSWindow
    private var timer: Timer?
    /// The companion became the key window: the mouse is the Mac's now.
    var onFocus: (() -> Void)?

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        window.title = "Halliday"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 760, height: 520)
        window.contentView = NSHostingView(rootView: CompanionView(model: model))
        window.delegate = self
        window.setFrameAutosaveName("HallidayCompanion")
    }

    /// Shows it on the Mac's main screen. `activating`: also makes it the key window (the menu's
    /// command); without, it is only put in view (at launch, the headset keeps the mouse).
    func show(activating: Bool) {
        if !window.isVisible, window.frameAutosaveName.isEmpty || UserDefaults.standard.string(forKey: "NSWindow Frame HallidayCompanion") == nil,
           let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        }
        // Never on the headset's display, where it can't be seen.
        if let screen = window.screen, let main = NSScreen.screens.first, screen != main,
           Headsets.supported.contains(where: { $0.isDisplay(screen) }) {
            let f = main.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.midX - window.frame.width / 2, y: f.midY - window.frame.height / 2))
        }
        model.refresh()
        if activating {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
        if timer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.window.isVisible, !self.window.isMiniaturized else { return }
                    self.model.refresh()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { onFocus?() }
}

// MARK: - Views

private enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview", sound = "Sound and display", space = "Space", apps = "Apps", extensions = "Extensions", games = "Windows games",
         windows = "Mac windows", browser = "Browser", tracking = "Tracking", performance = "Performance", controls = "Controls"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "visionpro"
        case .sound: "speaker.wave.2"
        case .space: "square.3.layers.3d"
        case .apps: "gamecontroller"
        case .extensions: "puzzlepiece.extension"
        case .browser: "globe"
        case .tracking: "scope"
        case .games: "desktopcomputer"
        case .windows: "macwindow.on.rectangle"
        case .performance: "speedometer"
        case .controls: "dpad"
        }
    }
}

let companionAccent = Color(red: 0x8A / 255, green: 0xB4 / 255, blue: 1)

private struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    /// Debug: --companion-section NAME opens on that section.
    @State private var section: Section? = {
        let a = CommandLine.arguments
        return a.firstIndex(of: "--companion-section").flatMap { $0 + 1 < a.count ? Section(rawValue: a[$0 + 1]) : nil } ?? .overview
    }()
    @State private var dropping = false
    @State private var quitting = false
    @ObservedObject private var setup = Setup.shared

    init(model: CompanionModel, initialSection: Section? = nil) {
        _model = ObservedObject(wrappedValue: model)
        if let initialSection { _section = State(initialValue: initialSection) }
    }

    var body: some View {
        Group {
            if setup.showing { SetupView(model: model) } else { sections }
        }
        .tint(companionAccent)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                Text(notice)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .task(id: notice) {
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        if model.notice == notice { model.notice = nil }
                    }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14).strokeBorder(companionAccent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(companionAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(Label("Drop to install", systemImage: "square.and.arrow.down").font(.title2.weight(.semibold)))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        // An .apk or an extension dropped anywhere on the window is installed (an extension after
        // the user has seen what it is).
        .onDrop(of: [.fileURL, .url], isTargeted: $dropping) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.install(url) }
                }
            }
            return true
        }
    }

    private var sections: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if model.status.onHeadset {
                        Button { model.onBackToHeadset?() } label: {
                            Label("Back to the headset", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                        }
                        .help("Gives the mouse and the keyboard back to Halliday in the headset (Control twice frees them again)")
                    }
                    Button(role: .destructive) { quitting = true } label: {
                        Label("Quit Halliday", systemImage: "power").frame(maxWidth: .infinity)
                    }
                    .help("Closes Halliday: the headset goes dark and the Mac's windows in VR go back to where they were")
                }
                .controlSize(.large)
                .padding(12)
                .confirmationDialog("Quit Halliday?", isPresented: $quitting) {
                    Button("Quit Halliday", role: .destructive) { model.onQuit?() }
                } message: {
                    Text(model.status.playing.map { "\($0) is playing and will be closed. " } ?? "")
                        + Text("The Mac's windows in VR go back to where they were.")
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch section ?? .overview {
                    case .overview: OverviewPane(model: model)
                    case .sound: SoundPane(model: model)
                    case .space: SpacePane(model: model)
                    case .apps: AppsPane(model: model)
                    case .extensions: ExtensionsPane(model: model)
                    case .browser: BrowserPane(model: model)
                    case .tracking: TrackingPane(model: model)
                    case .games: GamesPane(model: model)
                    case .windows: MacWindowsPane(model: model)
                    case .performance: PerformancePane(model: model)
                    case .controls: ControlsPane()
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle((section ?? .overview).rawValue)
        }
    }
}

extension CompanionSnapshot {
    /// Uses the real companion navigation and controls; no visible window or setup changes.
    static func gameImage(to path: String) {
        render(CompanionView(model: CompanionModel(), initialSection: .sound), to: path,
               size: CGSize(width: 1060, height: 1060))
    }
}

struct CompanionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
        }
    }
}

/// A titled slider with its value at the right.
private struct LevelRow: View {
    let title: String
    let value: String
    @Binding var level: Float
    let range: ClosedRange<Float>
    var step: Float = 0.05
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $level, in: range, step: step)
        }
    }
}

private struct FactRow: View {
    let symbol: String
    let title: String
    let value: String
    var good: Bool?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(good == false ? Color.orange : companionAccent)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct OverviewPane: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var permissions = Permissions.shared
    @ObservedObject var updates = Updates.shared
    var body: some View {
        let s = model.status
        if !Setup.shared.done {
            CompanionCard(title: "Setup") {
                HStack(spacing: 14) {
                    HallidayMark().frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Finish setting up Halliday").font(.headline)
                        Text("Your headset, permissions, your space and the controls: about three minutes.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Continue setup") { Setup.shared.start() }.controlSize(.large).buttonStyle(.borderedProminent)
                }
            }
        } else if !permissions.allGranted { PermissionsCard(title: "Halliday needs your permission") }
        CompanionCard(title: "Headset") {
            FactRow(symbol: "visionpro", title: Headsets.current.shortName, value: s.headset, good: s.onHeadset)
            if s.displayHz > 0 { FactRow(symbol: "display", title: "Display", value: "\(s.displayHz) Hz") }
            if s.framesPerSecond > 0 {
                FactRow(symbol: "speedometer", title: "Frames shown", value: String(format: "%.0f a second", s.framesPerSecond),
                        good: s.displayHz == 0 || s.framesPerSecond > Double(s.displayHz) * 0.93)
            }
            if s.controllers.isEmpty {
                FactRow(symbol: "gamecontroller", title: "Controllers", value: "None connected", good: nil)
            } else {
                ForEach(s.controllers, id: \.self) { FactRow(symbol: "gamecontroller", title: "Controller", value: $0) }
            }
            if !s.onHeadset, !s.desktopMode {
                HStack(spacing: 10) {
                    Button { model.lookForHeadset() } label: { Label("Look for the headset", systemImage: "arrow.clockwise") }
                    Text("Halliday also notices a headset plugged in by itself.").font(.callout).foregroundStyle(.secondary)
                }
                if let found = model.headsetSearch {
                    Text(found).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if s.canSwitchOutput {
            CompanionCard(title: "Where Halliday shows") {
                Picker("Where Halliday shows", selection: Binding(get: { s.desktopMode }, set: { model.onDesktopMode?($0) })) {
                    Label("In the headset", systemImage: "visionpro").tag(false)
                    Label("On this Mac's screen", systemImage: "desktopcomputer").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(s.desktopMode
                     ? "Halliday is in a window on this Mac: click in it and move the mouse to look around. The headset's display is dark. What you had open is still open."
                     : "Halliday is in the headset. Switch to use it from this Mac's screen without putting the headset on; nothing is closed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        CompanionCard(title: "Now") {
            FactRow(symbol: "play.circle", title: "Playing", value: s.playing ?? "Nothing")
            HStack(spacing: 10) {
                Button { model.onRecenter?() } label: { Label("Recenter", systemImage: "scope") }
                if let on = s.passthrough {
                    Button { model.onPassthrough?() } label: { Label(on ? "Passthrough on" : "Passthrough", systemImage: on ? "eye.fill" : "eye") }
                }
            }
            .controlSize(.large)
        }
        CompanionCard(title: "Updates") {
            FactRow(symbol: "app.badge", title: "Halliday", value: "Version \(updates.version)")
            Toggle(isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check for updates automatically")
                    Text("Once a day, from GitHub. Nothing about you or this Mac is sent, and nothing installs without your yes.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if let found = updates.waiting {
                HStack(spacing: 10) {
                    Label("Halliday \(found) is ready to install", systemImage: "arrow.down.circle.fill").foregroundStyle(companionAccent)
                    Spacer()
                    Button("Install…") { updates.checkNow() }.controlSize(.large).buttonStyle(.borderedProminent)
                }
            } else {
                Button { updates.checkNow() } label: { Label("Check for updates", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.large)
            }
        }
        Text("Halliday keeps running in the headset with this window closed: click Halliday in the Dock (or Window > Companion) to open it again. Drop an .apk file anywhere here to install it.")
            .font(.callout).foregroundStyle(.secondary)
    }
}

private struct SoundPane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        let s = Settings.shared
        CompanionCard(title: "Field of view") {
            Toggle("FOV crop", isOn: model.setting(\.gameCropEnabled)).toggleStyle(.switch)
            LevelRow(title: "Horizontal FOV", value: "\(Int((s.gameCropHorizontal * 100).rounded()))%",
                     level: model.setting(\.gameCropHorizontal), range: Settings.gameCropRange, step: 0.01)
                .disabled(!s.gameCropEnabled).accessibilityIdentifier("game.cropHorizontal")
            LevelRow(title: "Vertical FOV", value: "\(Int((s.gameCropVertical * 100).rounded()))%",
                     level: model.setting(\.gameCropVertical), range: Settings.gameCropRange, step: 0.01)
                .disabled(!s.gameCropEnabled).accessibilityIdentifier("game.cropVertical")
            Text("100% keeps the full field. Lower values remove the outer sides and top/bottom at the same pixel density; the inner eye edges are preserved. Restart the game to apply FOV changes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        CompanionCard(title: "Game image") {
            Toggle("FSR 1", isOn: model.setting(\.gameFSREnabled)).toggleStyle(.switch)
            Text("Reconstructs a lower-resolution game image before showing it in the headset.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LevelRow(title: "Game render scale", value: "\(s.gameRenderPercent)%",
                     level: Binding(get: { Float(s.gameRenderPercent) }, set: { model.setting(\.gameRenderPercent).wrappedValue = Int($0.rounded()) }),
                     range: Float(Settings.gameRenderPercentRange.lowerBound)...Float(Settings.gameRenderPercentRange.upperBound), step: 5)
            let geometry = gameImageSettingsGeometry(s)
            Text("\(geometry.renderSize.width)×\(geometry.renderSize.height) → \(geometry.imageTarget.width)×\(geometry.imageTarget.height) per eye")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Text("Lower is faster; higher keeps more detail. Restart the game to apply render scale.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("RCAS sharpening", isOn: model.setting(\.gameSharpeningEnabled)).toggleStyle(.switch)
            LevelRow(title: "Sharpness", value: "\(Int((s.gameSharpness * 100).rounded()))%",
                     level: model.setting(\.gameSharpness), range: Settings.gameSharpnessRange, step: 0.05)
            Text("Sharpening works with FSR on or off. Both switches and sharpness apply immediately.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("At 100% with both switches off, the game image is shown unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        CompanionCard(title: "Sound") {
            LevelRow(title: "Volume", value: s.volume < 0.01 ? "Off" : "\(Int((s.volume * 100).rounded()))%", level: model.setting(\.volume), range: 0...1)
            Text("Videos, apps and Halliday's own sounds all play at this level.").font(.callout).foregroundStyle(.secondary)
            LevelRow(title: "Interface sounds", value: s.soundVolume < 0.01 ? "Off" : "\(Int((s.soundVolume * 100).rounded()))%",
                     level: model.setting(\.soundVolume), range: 0...1, step: 0.1)
        }
        CompanionCard(title: "Display") {
            LevelRow(title: "Headset brightness", value: "\(Int((s.brightness * 100).rounded()))%", level: model.setting(\.brightness),
                     range: Settings.brightnessRange)
            LevelRow(title: "Dimming around the panels", value: "\(Int((s.dimming * 100).rounded()))%", level: model.setting(\.dimming),
                     range: Settings.dimmingRange)
        }
    }
}

private struct SpacePane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        let s = Settings.shared
        CompanionCard(title: "You") {
            Picker("Mode", selection: model.setting(\.mode)) {
                ForEach(Settings.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            LevelRow(title: "Panel distance", value: String(format: "%.1f m", s.panelDistance), level: model.setting(\.panelDistance),
                     range: Settings.panelDistanceRange, step: 0.1)
            LevelRow(title: "Pointer speed", value: String(format: "%.1f×", s.pointerSpeed), level: model.setting(\.pointerSpeed),
                     range: Settings.pointerSpeedRange, step: 0.1)
            Toggle("Reduce motion", isOn: model.setting(\.reduceMotion))
            Toggle("Open the keyboard when a text field is chosen", isOn: model.setting(\.keyboardAuto))
            Toggle("Remember the windows' layout for each set of apps", isOn: model.setting(\.rememberLayouts))
        }
        CompanionCard(title: "Place") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 12)], spacing: 12) {
                ForEach(model.places, id: \.id) { place in
                    let chosen = s.environment == place.id
                    Button { model.setting(\.environment).wrappedValue = place.id } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(colors: [Color(nsColor: place.swatch.0), Color(nsColor: place.swatch.1)], startPoint: .top, endPoint: .bottom))
                                .frame(height: 64)
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chosen ? companionAccent : Color.white.opacity(0.1), lineWidth: chosen ? 2.5 : 1))
                            Text(place.name).font(.callout).foregroundStyle(chosen ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("Open the places folder") { NSWorkspace.shared.open(Environments.folder) }
                .help("2:1 pictures and 3D scenes put here show up as places")
        }
    }
}

private struct AppsPane: View {
    @ObservedObject var model: CompanionModel
    @State private var removing: QuestApp?
    @State private var editing: QuestApp?
    var body: some View {
        CompanionCard(title: "Install") {
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 26)).foregroundStyle(companionAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps made for standalone headsets").font(.headline)
                    Text("Choose .apk files, or drop them on this window. They show in Games in the headset.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose files…") { model.chooseAPK() }.controlSize(.large)
            }
        }
        CompanionCard(title: model.apps.isEmpty ? "Installed" : "Installed · \(model.apps.count)") {
            if model.apps.isEmpty {
                Text("Nothing installed yet.").foregroundStyle(.secondary)
            }
            ForEach(model.apps, id: \.package) { app in
                HStack(spacing: 12) {
                    Image(systemName: "app.fill").font(.system(size: 26)).foregroundStyle(companionAccent.opacity(0.8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(app.canStart ? "Version \(app.version.isEmpty ? "unknown" : app.version) · \(app.engine)" : "Halliday can't start this kind of app yet")
                            .font(.callout).foregroundStyle(app.canStart ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if app.canStart, model.status.onHeadset { Button("Play") { model.onPlay?(app) } }
                    Button("Settings…") { editing = app }
                    Button("Show files") { NSWorkspace.shared.open(app.folder) }
                    Button("Remove", role: .destructive) { removing = app }
                }
                if app != model.apps.last { Divider() }
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "this app")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let app = removing { model.onRemove?(app) }
                removing = nil
            }
        } message: {
            Text("The app and what it saved in Halliday are deleted.")
        }
        Text("Windows VR games come from GameHub: see Windows games.").font(.callout).foregroundStyle(.secondary)
            .sheet(item: Binding(get: { editing.map(EditedApp.init) }, set: { if $0 == nil { editing = nil } })) { edited in
                AppSettingsSheet(app: edited.app) { editing = nil }
            }
    }
}

private struct BrowserPane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        CompanionCard(title: "Pages") {
            Toggle("Pages see an Apple Vision Pro (VR sites offer their VR features)", isOn: model.setting(\.visionIdentity))
            VStack(alignment: .leading, spacing: 4) {
                Text("Home page")
                TextField("Halliday's start page", text: model.setting(\.homePage)).textFieldStyle(.roundedBorder)
            }
        }
        CompanionCard(title: "Pages in VR") {
            Picker("Picture size for each eye", selection: model.setting(\.vrPageEye)) {
                ForEach(Settings.vrPageSizes, id: \.self) { Text("\($0) pixels").tag($0) }
            }
            Text("Larger is sharper and costs the page more: lower it if a VR page stutters.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct TrackingPane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        let ms = model.status.predictionMs
        CompanionCard(title: "Prediction") {
            Stepper(value: Binding(get: { ms }, set: { model.onPrediction?($0) }), in: -10...20, step: 2) {
                HStack {
                    Text("Extra prediction")
                    Spacer()
                    Text(String(format: "%+d ms", ms)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text("How much further ahead than measured Halliday predicts the head. 0 is where things stay put best; change it while nodding quickly and watching a panel. It goes back to 0 when Halliday starts.")
                .font(.callout).foregroundStyle(.secondary)
        }
        CompanionCard(title: "Controllers") {
            Text("To set where a controller points: in the headset, look straight ahead, point it at the middle of your view and press Create or Options. Hold PS to recenter everything.")
                .font(.callout).foregroundStyle(.secondary)
            Button { model.onRecenter?() } label: { Label("Recenter", systemImage: "scope") }
        }
    }
}

// MARK: - Second round: an app's own settings, Windows games, Mac windows, performance, controls

private struct EditedApp: Identifiable {
    let app: QuestApp
    var id: String { app.package }
}

/// An app's `settings.json`: what this one app needs that others don't (see `QuestApp.settings`).
private struct AppSettingsSheet: View {
    let app: QuestApp
    let done: () -> Void
    @State private var text = ""
    @State private var problem: String?
    private var file: URL { app.folder.appendingPathComponent("settings.json") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings for \(app.name)").font(.title3.weight(.semibold))
            Text("Only what this app needs that others don't. \"network\": true or false lets its player use the network or not; \"runner\" holds settings for the player itself, each a name and a value in quotes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12)))
            if let problem { Text(problem).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("Start over") { text = "{\n  \"runner\": {}\n}\n"; problem = nil }
                Spacer()
                Button("Cancel", role: .cancel) { done() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "{\n  \"runner\": {}\n}\n" }
    }

    private func save() {
        guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data), let d = object as? [String: Any] else {
            problem = "This isn't valid: it has to be one { … } with names in quotes."
            return
        }
        if let runner = d["runner"], !(runner is [String: String]) {
            problem = "\"runner\" has to hold names and values that are both in quotes."
            return
        }
        if let network = d["network"], !(network is Bool) {
            problem = "\"network\" has to be true or false."
            return
        }
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            done()
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

private struct GamesPane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        CompanionCard(title: "GameHub") {
            HStack(spacing: 14) {
                Image(systemName: "desktopcomputer").font(.system(size: 26)).foregroundStyle(companionAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.hasGameHub ? "Windows VR games run through GameHub" : "GameHub isn't on this Mac").font(.headline)
                    Text("Halliday becomes a game's VR runtime in place of SteamVR: one small file in the game's own container, put back by Undo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.hasGameHub { Button("Open GameHub") { model.onOpenGameHub?() }.controlSize(.large) }
            }
        }
        CompanionCard(title: model.games.isEmpty ? "Games" : "Games · \(model.games.count)") {
            if model.games.isEmpty {
                Text(model.hasGameHub ? "No SteamVR games in GameHub yet." : "Nothing to show.").foregroundStyle(.secondary)
            }
            ForEach(model.games) { game in
                HStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 20)).foregroundStyle(companionAccent.opacity(0.8)).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.name)
                        Text(game.status).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let setUp = game.setUp {
                        Button(setUp ? "Undo set-up" : "Set up for Halliday") { model.onGame?(game.id, !setUp) }
                    }
                }
                if game != model.games.last { Divider() }
            }
        }
    }
}

private struct MacWindowsPane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        CompanionCard(title: "Windows") {
            HStack {
                Text("Bring a window of the Mac into VR, or send it back to where it was.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.windowsLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refreshWindows() }
            }
            if model.macWindows.isEmpty, !model.windowsLoading {
                Text("No windows found. Halliday needs the Screen Recording permission to list them.").foregroundStyle(.secondary)
            }
            ForEach(model.macWindows) { w in
                HStack(spacing: 12) {
                    Image(systemName: w.inVR ? "visionpro" : "macwindow").foregroundStyle(w.inVR ? companionAccent : Color.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title.isEmpty ? w.app : w.title).lineLimit(1)
                        Text(w.hint.map { "\(w.app) · \($0)" } ?? w.app).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(w.inVR ? "Send back" : "Bring into VR") { model.move(w) }
                }
                if w != model.macWindows.last { Divider() }
            }
        }
        .onAppear { model.refreshWindows() }
        Text("A window that keeps changing (a video, a busy terminal) costs the headset frames: see Performance.").font(.callout).foregroundStyle(.secondary)
    }
}

private struct PerformancePane: View {
    @ObservedObject var model: CompanionModel
    var body: some View {
        let f = model.frame
        let hz = Double(max(model.status.displayHz, 1))
        let budget = model.status.displayHz > 0 ? 1000 / hz : 8.33
        CompanionCard(title: "A frame") {
            if f.gpuMs <= 0 {
                Text("Nothing measured yet: the figures arrive every few seconds while Halliday draws.").foregroundStyle(.secondary)
            } else {
                FactRow(symbol: "speedometer", title: "Frames shown", value: String(format: "%.0f a second", f.framesPerSecond),
                        good: model.status.displayHz == 0 || f.framesPerSecond > hz * 0.93)
                FactRow(symbol: "cpu", title: "GPU time a frame", value: String(format: "%.1f ms (worst %.1f) of %.1f", f.gpuMs, f.gpuWorstMs, budget),
                        good: f.gpuMs < budget * 0.9)
                FrameChart(values: model.frameHistory, budget: budget).frame(height: 90)
                Text("The line is the time the display allows a frame. Above it, every other frame is shown twice and edges double as the head moves.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        CompanionCard(title: "What it is made of") {
            FactRow(symbol: "square.stack.3d.up", title: "Panels and windows drawn", value: "\(f.layers)")
            FactRow(symbol: "macwindow.on.rectangle", title: "Window pictures copied",
                    value: f.captures == 0 ? "None" : String(format: "%.0f a second · %.0f megapixels a second", Double(f.captures) / max(f.seconds, 1), f.captureMegapixels / max(f.seconds, 1)),
                    good: f.captures == 0 ? nil : f.captureMegapixels / max(f.seconds, 1) < 600)
            FactRow(symbol: "sparkles", title: "Also on", value: f.parts.isEmpty ? "Nothing" : f.parts.joined(separator: ", "))
        }
    }
}

/// The last minutes' GPU time a frame as bars, against the display's budget.
private struct FrameChart: View {
    let values: [Double]
    let budget: Double
    var body: some View {
        GeometryReader { geo in
            let top = max(budget * 2, (values.max() ?? 0) * 1.1)
            let barWidth = geo.size.width / 60
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        Rectangle().fill(v > budget ? Color.orange : companionAccent)
                            .frame(width: max(barWidth - 1.5, 1), height: max(2, geo.size.height * v / top))
                            .padding(.trailing, 1.5)
                    }
                }
                Rectangle().fill(Color.white.opacity(0.45)).frame(height: 1)
                    .offset(y: -geo.size.height * budget / top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct ControlsPane: View {
    var body: some View {
        CompanionCard(title: "\(Headsets.current.shortName) and its controllers") {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HeadsetSchematic().frame(width: 300, height: 170)
                    legend([("A", "Cameras", "track the head and see the controllers; the bottom pair is passthrough"),
                            ("B", "Lens dial, on top", "the distance between the lenses (Halliday reads it)"),
                            ("C", "Fn, underneath", "passthrough, and back"),
                            ("D", "Power, underneath", "on and off"),
                            ("E", "Cable", "to Sony's PC adapter")])
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 4) {
                        SenseSchematic(mirrored: true).frame(width: 150, height: 170)
                        SenseSchematic().frame(width: 150, height: 170)
                    }
                    legend([("1", "Trigger", "click; hold to drag"), ("2", "Grip (L1 · R1)", "secondary click"), ("3", "Stick", "scroll"),
                            ("4", "PS", "hold: recenter · tap: aim, or Halliday over a game"), ("5", "Square · Cross", "a video's bar, hide or show"),
                            ("6", "Triangle · Circle", "in games: Y / B"), ("7", "Create · Options", "as a tap of PS")])
                }
            }
            Text("Drawn for orientation, not to scale.").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(ControlsGuide.topics, id: \.id) { topic in
            CompanionCard(title: topic.name) {
                Text(topic.note).font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(topic.entries, id: \.input) { entry in
                        GridRow {
                            Text(entry.input).font(.callout.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                            Text(entry.does)
                        }
                    }
                }
            }
        }
        Text("The same list is in the headset: Apps, then Controls, or the / key.").font(.callout).foregroundStyle(.secondary)
    }

    private func legend(_ rows: [(String, String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            ForEach(rows, id: \.0) { r in
                GridRow {
                    Text(r.0).font(.system(size: 11, weight: .bold)).foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.14))
                        .frame(width: 20, height: 20).background(companionAccent, in: Circle())
                    (Text(r.1).bold() + Text(": " + r.2)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
