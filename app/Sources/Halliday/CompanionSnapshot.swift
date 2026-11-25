// Debug: `halliday --setup-snapshot PREFIX` draws each step of the companion's setup into
// PREFIX-1.png … PREFIX-6.png, offscreen (a window never shown: its AppKit controls draw as they
// really do, which SwiftUI's ImageRenderer can't), and the two controllers with all their parts
// numbered, as the companion's Controls shows them, into PREFIX-controllers.png; then exits.
// For checking the companion's look without opening a window on the user's screen.

import AppKit
import SwiftUI

@MainActor
enum CompanionSnapshot {
    static func render<V: View>(_ view: V, to path: String, size: CGSize = CGSize(width: 1060, height: 680)) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(red: 0.086, green: 0.094, blue: 0.122)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }

    static func setup(prefix: String) {
        let model = CompanionModel()
        model.places = Environments.all()
        for step in Setup.Step.allCases {
            Setup.shared.step = step
            render(SetupView(model: model), to: "\(prefix)-\(step.rawValue + 1).png")
        }
        render(HStack(spacing: 30) {
            SenseSchematic(mirrored: true).frame(width: 300, height: 340)
            SenseSchematic().frame(width: 300, height: 340)
        }, to: "\(prefix)-controllers.png", size: CGSize(width: 700, height: 380))
    }

    /// Inspect the native runtime picker without starting the app, a host or a game.
    static func nativeOpenXR(to path: String) {
        render(nativeOpenXRSnapshotView(), to: path,
               size: CGSize(width: 1060, height: 1100))
    }
}
