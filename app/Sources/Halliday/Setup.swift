// Setup: the first-time onboarding, in the companion on the Mac's screen (design canvas board 17;
// board 16 is its panel in the headset, `SetupPanel`). Six steps: Welcome, Headset (the
// adapters Halliday has: HeadsetAdapter.swift), Permissions (each with why and what never
// happens with it: Permissions.swift), Your space (seated or room-scale, the place), Controls
// (the ones used most, with the drawing of board 18) and Ready (a checklist).
//
// Nothing is required: a step skipped keeps its default, and Ready lists what is left. The step
// is remembered, so the relaunch Screen Recording needs comes back to it. Until setup is done,
// the companion opens on it at launch and Overview offers to finish it.

import AppKit
import SwiftUI

@MainActor
final class Setup: ObservableObject {
    static let shared = Setup()

    enum Step: Int, CaseIterable {
        case welcome, headset, permissions, space, controls, ready
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .headset: "Headset"
            case .permissions: "Permissions"
            case .space: "Your space"
            case .controls: "Controls"
            case .ready: "Ready"
            }
        }
    }

    private let defaults = UserDefaults.standard
    @Published var step: Step { didSet { defaults.set(step.rawValue, forKey: "setupStep") } }
    @Published private(set) var done: Bool
    /// The companion shows setup instead of its sections.
    @Published var showing: Bool
    /// Called when setup ends (Done) or is put off (Set up later), for the headset's panel.
    var onFinish: ((_ done: Bool) -> Void)?

    init() {
        done = defaults.bool(forKey: "setupDone") || CommandLine.arguments.contains("--setup-done")
        step = Step(rawValue: defaults.integer(forKey: "setupStep")) ?? .welcome
        showing = false
    }

    /// Opens setup in the companion (at launch while it isn't done, or from Overview).
    func start() {
        showing = true
    }

    func next() {
        if let n = Step(rawValue: step.rawValue + 1) { step = n } else { finish() }
    }

    func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }

    func finish() {
        done = true
        defaults.set(true, forKey: "setupDone")
        showing = false
        step = .welcome
        log("[setup] done")
        onFinish?(true)
    }

    /// "Set up later": the companion goes back to its sections; setup stays offered.
    func later() {
        showing = false
        log("[setup] put off")
        onFinish?(false)
    }
}

// MARK: - The view

struct SetupView: View {
    @ObservedObject var setup = Setup.shared
    @ObservedObject var model: CompanionModel
    @ObservedObject var permissions = Permissions.shared
    @ObservedObject var updates = Updates.shared

    var body: some View {
        HStack(spacing: 0) {
            // The steps.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Setup.Step.allCases, id: \.rawValue) { s in
                    let on = s == setup.step, past = s.rawValue < setup.step.rawValue
                    Button { setup.step = s } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(on ? companionAccent : (past ? companionAccent.opacity(0.24) : Color.white.opacity(0.08)))
                                Text(past ? "✓" : "\(s.rawValue + 1)").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(on ? Color(red: 0.05, green: 0.08, blue: 0.14) : (past ? Color(red: 0.79, green: 0.86, blue: 1) : .secondary))
                            }
                            .frame(width: 22, height: 22)
                            Text(s.title).font(.system(size: 14, weight: .medium)).foregroundStyle(on ? .primary : .secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 40)
                        .background(on ? companionAccent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("You can leave and come back: setup stays here until it's done.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12).fixedSize(horizontal: false, vertical: true)
                Button("Set up later") { setup.later() }.buttonStyle(.link).padding(.horizontal, 12).padding(.top, 6)
            }
            .padding(.vertical, 16).padding(.horizontal, 12)
            .frame(width: 230)
            .background(Color.white.opacity(0.03))
            .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1) }

            // The step, and Back / Continue.
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch setup.step {
                        case .welcome: welcome
                        case .headset: headset
                        case .permissions: permissionsStep
                        case .space: space
                        case .controls: controls
                        case .ready: ready
                        }
                    }
                    .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    if setup.step == .welcome {
                        Text("Halliday makes no account and sends nothing anywhere.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Button("Back") { setup.back() }.buttonStyle(SetupQuietStyle())
                    }
                    Spacer()
                    Button(setup.step == .welcome ? "Get started" : (setup.step == .ready ? "Done" : "Continue")) { setup.next() }
                        .buttonStyle(SetupPrimaryStyle()).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 40).frame(height: 72)
            }
        }
        .tint(companionAccent)
        .onAppear { permissions.read(); permissions.watch(true) }
        .onDisappear { permissions.watch(false) }
    }

    // MARK: Steps

    private func heading(_ title: String, _ lead: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 28, weight: .semibold)).tracking(-0.4)
            Text(lead).font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            HallidayMark().frame(width: 120, height: 120).padding(.top, 20)
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Halliday").font(.system(size: 34, weight: .semibold)).tracking(-0.6)
                Text("Your Mac around you, the web in VR, and your games, in a headset. Setup takes about three minutes. Keep the headset off until the last step.")
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                promise("macwindow", "Your Mac, in VR", "Bring in any app's windows, side by side.")
                promise("checkmark.shield", "Yours only", "No account. What you do in VR stays on this Mac.")
                promise("clock", "Three minutes", "Headset, permissions, your space, the controls.")
            }
            .frame(maxWidth: 680)
        }
    }

    private func promise(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(companionAccent)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
    }

    private var headset: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Which headset will you use?", "Halliday drives the headset itself, from this Mac. Pick yours; it doesn't need to be plugged in yet.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(Headsets.supported, id: \.id) { h in
                    let chosen = Headsets.current.id == h.id
                    Button { Headsets.choose(h.id); model.refresh() } label: {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 14) {
                                HeadsetSchematic(compact: true).frame(width: 96, height: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.name).font(.system(size: 17, weight: .semibold))
                                    if chosen, model.status.onHeadset {
                                        Label("Connected · \(model.status.displayHz) Hz", systemImage: "checkmark").font(.callout).foregroundStyle(companionAccent)
                                    } else {
                                        Text("Not connected yet: that's fine").font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("IT NEEDS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
                                ForEach(h.requirements, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(chosen ? companionAccent.opacity(0.08) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(chosen ? companionAccent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("More headsets later").font(.headline).foregroundStyle(.secondary)
                    Text("Halliday's headset support is built so others can be added. For now, the \(Headsets.supported.map(\.name).joined(separator: ", ")).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("Two permissions, and why", "macOS asks you to allow these in its own window, which opens on this screen. Halliday works without them, but your Mac's windows and the browser can't appear in VR.")
            PermissionsCard(title: "Permissions")
            Text("Screen Recording takes effect once Halliday reopens: use Reopen Halliday after allowing it, and setup comes back to this step.")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var space: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Your space", "How you'll use Halliday, and the place you'll stand in. Both change any time from quick settings.")
            HStack(spacing: 14) {
                ForEach(Settings.Mode.allCases, id: \.self) { mode in
                    let on = Settings.shared.mode == mode
                    Button { model.setting(\.mode).wrappedValue = mode } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: mode == .seated ? "figure.seated.side" : "figure.walk").font(.system(size: 24)).foregroundStyle(companionAccent)
                            Text(mode.label).font(.system(size: 16, weight: .semibold))
                            Text(mode == .seated ? "At your desk. Windows stay in front of you; walking is off." : "Standing, with room to step around. Clear the space first.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(on ? companionAccent.opacity(0.08) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? companionAccent : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .id(model.tick)
            VStack(alignment: .leading, spacing: 10) {
                Text("YOUR PLACE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(0.6)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                    ForEach(model.places, id: \.id) { place in
                        let chosen = Settings.shared.environment == place.id
                        Button { model.setting(\.environment).wrappedValue = place.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(LinearGradient(colors: [Color(nsColor: place.swatch.0), Color(nsColor: place.swatch.1)], startPoint: .top, endPoint: .bottom))
                                    .frame(height: 64)
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(chosen ? companionAccent : .clear, lineWidth: 2))
                                Text(place.name).font(.callout).foregroundStyle(chosen ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id(model.tick)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("The controls you'll use most", "The rest is in Controls, in VR (the / key) and here, whenever you need it.")
            HStack(alignment: .center, spacing: 28) {
                SenseSchematic(numbered: [1, 2, 3, 4]).frame(width: 220, height: 250)
                VStack(alignment: .leading, spacing: 14) {
                    callout("1", "Trigger", "click what the pointer is on; hold to drag.")
                    callout("2", "Grip", "the secondary click, as the mouse's right button.")
                    callout("3", "Stick", "scroll the list or page under the pointer.")
                    callout("4", "PS", "hold to bring everything back in front of you; tap over a game for Halliday's menu.")
                    callout("Fn", "Fn, under the visor", "see your room through the headset's cameras, and back.", quiet: true)
                }
            }
        }
    }

    private func callout(_ n: String, _ part: String, _ does: String, quiet: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n).font(.system(size: 12, weight: .bold))
                .foregroundStyle(quiet ? Color.primary : Color(red: 0.05, green: 0.08, blue: 0.14))
                .frame(width: 24, height: 24).background(quiet ? Color.white.opacity(0.14) : companionAccent, in: Circle())
            (Text(part).bold() + Text(": " + does)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("You're ready", "Put the headset on. Halliday is already waiting in it; this window stays here as the companion.")
            VStack(spacing: 0) {
                checkRow(Headsets.current.name, ok: model.status.onHeadset, okText: "Connected", todo: "Not connected: plug it in and switch it on; Halliday finds it by itself.")
                Divider()
                checkRow(Permissions.Kind.allCases.map(\.title).joined(separator: " · "), ok: permissions.allGranted, okText: "Allowed",
                         todo: "\(permissions.missing.map(\.title).joined(separator: " and ")) not allowed yet: see Permissions.")
                Divider()
                checkRow("\(Settings.shared.mode.label) · \(model.places.first { $0.id == Settings.shared.environment }?.name ?? "your place")", ok: true, okText: "Set", todo: "")
                Divider()
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Headsets.current.controllersName.prefix(1).uppercased() + Headsets.current.controllersName.dropFirst())
                        if model.status.controllers.isEmpty {
                            Text("Not paired yet: hold Create and PS on each until its light blinks, then pair it in Bluetooth settings.")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if model.status.controllers.isEmpty {
                        Button("Open Bluetooth settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                        }
                    } else {
                        Label("Connected", systemImage: "checkmark").foregroundStyle(companionAccent)
                    }
                }
                .padding(.vertical, 12)
                Divider()
                // Updates: asked here once, off unless the person turns them on (Updates.swift).
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Check for updates automatically")
                        Text("Once a day Halliday asks GitHub whether a newer release is out. Nothing about you or this Mac is sent, and nothing installs without your yes.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { updates.automatic }, set: { updates.setAutomatic($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 18).padding(.vertical, 4)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)))
        }
    }

    private func checkRow(_ title: String, ok: Bool, okText: String, todo: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if !ok { Text(todo).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            if ok { Label(okText, systemImage: "checkmark").foregroundStyle(companionAccent) } else { Image(systemName: "circle.dotted").foregroundStyle(.orange) }
        }
        .padding(.vertical, 12)
    }
}

/// Setup's main button: the accent, filled (board 17).
struct SetupPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(red: 0.05, green: 0.08, blue: 0.14))
            .padding(.horizontal, 20).frame(height: 40)
            .background(companionAccent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

struct SetupQuietStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 20).frame(height: 40)
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
    }
}

// MARK: - Drawings (design canvas board 18: original line drawings, for orientation)

/// Halliday's mark: the app's own icon (AppIcon.icns in the bundle, rendered from
/// AppIcon.icon), so onboarding shows exactly what the Dock and Finder show. The icon has
/// macOS's usual margin around its tile: give it a frame a fifth larger than the tile.
struct HallidayMark: View {
    private static let icon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        ?? NSApp.applicationIconImage
    var body: some View {
        Image(nsImage: Self.icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            .accessibilityLabel("Halliday")
    }
}

/// A Sense controller (the right; `mirrored` for the left) seen from above as it is held,
/// after photographs of the real one: the hoop, a wide band all around, with the handle
/// running through it from the head, which sits on the band's near side and holds the stick,
/// two face buttons, Options and PS; the trigger is under the head's front edge and the grip
/// on the handle. Parts numbered as the legend: 1 trigger, 2 grip, 3 stick, 4 PS,
/// 5 face button below, 6 face button above, 7 Create/Options.
struct SenseSchematic: View {
    var numbered: [Int] = [1, 2, 3, 4, 5, 6, 7]
    var mirrored = false

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 220, size.height / 250)
            var t = CGAffineTransform(translationX: (size.width - 220 * k) / 2, y: (size.height - 250 * k) / 2).scaledBy(x: k, y: k)
            if mirrored { t = t.translatedBy(x: 220, y: 0).scaledBy(x: -1, y: 1) }
            let line = Color(red: 0.95, green: 0.95, blue: 0.97), dim = Color(red: 0.62, green: 0.64, blue: 0.70)
            let plastic = Color(red: 0.30, green: 0.31, blue: 0.35), inside = Color(red: 0.16, green: 0.165, blue: 0.18)
            let black = Color(red: 0.10, green: 0.11, blue: 0.14)
            func p(_ build: (inout Path) -> Void) -> Path { var path = Path(); build(&path); return path.applying(t) }
            let outer = CGRect(x: 20, y: 56, width: 190, height: 182), inner = CGRect(x: 44, y: 86, width: 154, height: 140)

            // Inside the hoop, its dark inner wall, the far edge of which shows below.
            ctx.fill(Path(ellipseIn: inner).applying(t), with: .color(inside))
            let wall = p {
                $0.move(to: CGPoint(x: 48, y: 168))
                $0.addCurve(to: CGPoint(x: 194, y: 168), control1: CGPoint(x: 62, y: 222), control2: CGPoint(x: 180, y: 222))
            }
            ctx.stroke(wall, with: .color(dim.opacity(0.5)), lineWidth: 1.4 * k)

            // The handle, from under the head down through the hoop to its far side.
            let handle = p {
                $0.move(to: CGPoint(x: 58, y: 66))
                $0.addCurve(to: CGPoint(x: 70, y: 224), control1: CGPoint(x: 48, y: 128), control2: CGPoint(x: 56, y: 186))
                $0.addLine(to: CGPoint(x: 98, y: 222))
                $0.addCurve(to: CGPoint(x: 104, y: 66), control1: CGPoint(x: 92, y: 184), control2: CGPoint(x: 110, y: 124))
                $0.closeSubpath()
            }
            ctx.fill(handle, with: .color(black))
            ctx.stroke(handle, with: .color(line), lineWidth: 2 * k)
            // The grip, on the handle where the middle finger rests.
            let grip = p { $0.move(to: CGPoint(x: 53, y: 140)); $0.addCurve(to: CGPoint(x: 58, y: 186), control1: CGPoint(x: 51, y: 156), control2: CGPoint(x: 53, y: 172)) }
            ctx.stroke(grip, with: .color(companionAccent), style: StrokeStyle(lineWidth: 5 * k, lineCap: .round))

            // The hoop: a wide band of white plastic, its near side seen broadest, over the handle.
            var band = Path(ellipseIn: outer); band.addEllipse(in: inner)
            ctx.fill(band.applying(t), with: .color(plastic), style: FillStyle(eoFill: true))
            ctx.stroke(Path(ellipseIn: outer).applying(t), with: .color(line), lineWidth: 2 * k)
            ctx.stroke(Path(ellipseIn: inner).applying(t), with: .color(line), lineWidth: 2 * k)

            // The trigger, peeking out under the head's front edge.
            ctx.fill(Path(roundedRect: CGRect(x: 54, y: 13, width: 48, height: 14), cornerRadius: 7).applying(t), with: .color(companionAccent))

            // The head, sitting on the band's near side.
            let headRect = CGRect(x: 26, y: 22, width: 104, height: 58)
            let turn = CGAffineTransform(translationX: headRect.midX, y: headRect.midY).rotated(by: -8 * .pi / 180).translatedBy(x: -headRect.midX, y: -headRect.midY)
            let head = Path(roundedRect: headRect, cornerRadius: 26).applying(turn).applying(t)
            ctx.fill(head, with: .color(black))
            ctx.stroke(head, with: .color(line), lineWidth: 2 * k)
            // The stick, two face buttons, Options, PS.
            let stick = Path(ellipseIn: CGRect(x: 73, y: 37, width: 22, height: 22)).applying(t)
            ctx.fill(stick, with: .color(.white.opacity(0.14)))
            ctx.stroke(stick, with: .color(line), lineWidth: 2 * k)
            ctx.stroke(Path(ellipseIn: CGRect(x: 79, y: 43, width: 10, height: 10)).applying(t), with: .color(dim), lineWidth: 1.2 * k)
            for c in [CGPoint(x: 49, y: 42), CGPoint(x: 55, y: 61)] {
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)).applying(t), with: .color(line), lineWidth: 1.8 * k)
            }
            ctx.fill(Path(roundedRect: CGRect(x: 110, y: 34, width: 5, height: 12), cornerRadius: 2.5).applying(t), with: .color(line))
            ctx.fill(Path(ellipseIn: CGRect(x: 100, y: 61, width: 9, height: 9)).applying(t), with: .color(line))

            // Markers with a leader to their part (in the drawing's own, unmirrored coordinates).
            let parts: [Int: (part: CGPoint, label: CGPoint)] = [
                1: (CGPoint(x: 60, y: 18), CGPoint(x: 20, y: 12)),
                2: (CGPoint(x: 54, y: 163), CGPoint(x: 12, y: 178)),
                3: (CGPoint(x: 90, y: 42), CGPoint(x: 150, y: 12)),
                4: (CGPoint(x: 104, y: 66), CGPoint(x: 152, y: 130)),
                5: (CGPoint(x: 53, y: 65), CGPoint(x: 12, y: 92)),
                6: (CGPoint(x: 45, y: 39), CGPoint(x: 12, y: 46)),
                7: (CGPoint(x: 113, y: 40), CGPoint(x: 182, y: 40)),
            ]
            for n in numbered {
                guard let m = parts[n] else { continue }
                let a = m.part.applying(t), c = m.label.applying(t)
                var leader = Path(); leader.move(to: a); leader.addLine(to: c)
                ctx.stroke(leader, with: .color(companionAccent.opacity(0.7)), lineWidth: 1.2 * k)
                ctx.fill(Path(ellipseIn: CGRect(x: a.x - 2.5 * k, y: a.y - 2.5 * k, width: 5 * k, height: 5 * k)), with: .color(companionAccent))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 11 * k, y: c.y - 11 * k, width: 22 * k, height: 22 * k)), with: .color(companionAccent))
                ctx.draw(Text("\(n)").font(.system(size: 12 * k, weight: .bold)).foregroundColor(Color(red: 0.05, green: 0.08, blue: 0.14)), at: c)
            }
        }
        .accessibilityLabel(mirrored ? "The left Sense controller, its parts numbered" : "A Sense controller, its parts numbered")
    }
}

/// The headset from the front, parts marked A to E as the legend: A cameras, B lens dial,
/// C Fn, D power, E cable. `compact`: the outline only, for a card.
struct HeadsetSchematic: View {
    var compact = false

    var body: some View {
        Canvas { ctx, size in
            let k = min(size.width / 640, size.height / 360)
            let t = CGAffineTransform(scaleX: k, y: k).translatedBy(x: (size.width / k - 640) / 2, y: 0)
            let line = Color(red: 0.95, green: 0.95, blue: 0.97), dim = Color(red: 0.62, green: 0.64, blue: 0.70)
            var band = Path()
            band.move(to: CGPoint(x: 86, y: 196))
            band.addCurve(to: CGPoint(x: 554, y: 196), control1: CGPoint(x: 70, y: 70), control2: CGPoint(x: 570, y: 70))
            ctx.stroke(band.applying(t), with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 30 * k, lineCap: .round))
            ctx.stroke(band.applying(t), with: .color(dim), style: StrokeStyle(lineWidth: (compact ? 6 : 2) * k, lineCap: .round))
            let visor = Path(roundedRect: CGRect(x: 130, y: 138, width: 380, height: 170), cornerRadius: 72).applying(t)
            ctx.fill(visor, with: .color(.white.opacity(0.06)))
            ctx.stroke(visor, with: .color(line), lineWidth: (compact ? 8 : 2.5) * k)
            for (x, y) in [(182.0, 176.0), (458.0, 176.0), (196.0, 276.0), (444.0, 276.0)] {
                let cam = Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)).applying(t)
                if compact { ctx.fill(cam, with: .color(line)) } else { ctx.stroke(cam, with: .color(line), lineWidth: 2 * k) }
            }
            guard !compact else { return }
            ctx.stroke(Path(roundedRect: CGRect(x: 392, y: 128, width: 62, height: 14), cornerRadius: 7).applying(t), with: .color(line), lineWidth: 2 * k)
            ctx.stroke(Path(roundedRect: CGRect(x: 236, y: 304, width: 34, height: 12), cornerRadius: 6).applying(t), with: .color(line), lineWidth: 2 * k)
            ctx.stroke(Path(roundedRect: CGRect(x: 292, y: 304, width: 22, height: 12), cornerRadius: 6).applying(t), with: .color(line), lineWidth: 2 * k)
            var cable = Path()
            cable.move(to: CGPoint(x: 130, y: 250))
            cable.addCurve(to: CGPoint(x: 104, y: 352), control1: CGPoint(x: 96, y: 280), control2: CGPoint(x: 92, y: 320))
            ctx.stroke(cable.applying(t), with: .color(dim), style: StrokeStyle(lineWidth: 4 * k, lineCap: .round))
            for (letter, c) in [("A", CGPoint(x: 530, y: 112)), ("B", CGPoint(x: 423, y: 84)), ("C", CGPoint(x: 230, y: 346)), ("D", CGPoint(x: 324, y: 346)), ("E", CGPoint(x: 52, y: 330))] {
                let p = c.applying(t)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 13 * k, y: p.y - 13 * k, width: 26 * k, height: 26 * k)), with: .color(companionAccent))
                ctx.draw(Text(letter).font(.system(size: 13 * k, weight: .bold)).foregroundColor(Color(red: 0.05, green: 0.08, blue: 0.14)), at: p)
            }
        }
        .accessibilityLabel("The headset from the front")
    }
}
