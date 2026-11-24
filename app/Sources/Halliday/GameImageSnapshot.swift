// Bounded, offscreen snapshots of the actual Mac and headset settings. This path never starts
// AppDelegate, a game or a headset session, and only navigates between settings tabs.
// Supply ordinary UserDefaults command-line overrides to preview settings without saving them.

import AppKit
import Metal

@MainActor
func runGameImageUISnapshot(prefix: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let parent = URL(fileURLWithPath: prefix).deletingLastPathComponent()
    do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
    catch { fatal("Could not create UI snapshot folder: \(error)") }

    CompanionSnapshot.gameImage(to: "\(prefix)-mac.png")
    guard FileManager.default.fileExists(atPath: "\(prefix)-mac.png") else { fatal("Mac settings snapshot was not written") }
    guard let device = MTLCreateSystemDefaultDevice() else { fatal("No Metal device for settings snapshot") }
    let renderer: Renderer
    do { renderer = try Renderer(device: device, eyeSize: 64) }
    catch { fatal("UI snapshot renderer failed: \(error)") }

    let general = SettingsPanel(renderer: renderer)
    general.refreshState = { ([90, 120], 120, false) }
    drawGameImageSettingsPanel(general, to: "\(prefix)-headset-general.png")
    let gameImage = SettingsPanel(renderer: renderer)
    gameImage.onActivate?("page:gameImage")
    drawGameImageSettingsPanel(gameImage, to: "\(prefix)-headset-game-image.png")
    guard general.controls.contains(where: { $0.id == "game:systemAudio" })
    else { fatal("Game audio control is missing") }
    guard ["display:90", "display:120"].allSatisfy({ id in general.controls.contains(where: { $0.id == id && $0.enabled }) })
    else { fatal("Headset refresh selectors are missing") }

    let expected = Set(["game:fsr", "game:scale", "game:half:off", "game:half:on", "game:half:auto", "game:spacewarp", "game:sharpening", "game:sharpness"])
    guard expected.isSubset(of: Set(gameImage.controls.map(\.id))) else { fatal("Image settings controls are missing") }
    let settings = Settings.shared
    guard ["game:half:off", "game:half:on", "game:half:auto", "game:spacewarp"].allSatisfy({ id in
        gameImage.controls.contains(where: { $0.id == id && $0.enabled })
    })
    else { fatal("Spacewarp and half-frame-rate switch states are inconsistent") }
    for panel in [general, gameImage] {
        for control in panel.controls where !panel.surface.contains(control.rect) {
            fatal("Settings control \(control.id) extends outside the panel: \(control.rect)")
        }
    }
    print("PASS: Mac settings and both headset tabs; image and audio controls within panel; render \(settings.gameRenderPercent)%, half rate \(settings.effectiveGameHalfFrameRate), Spacewarp \(settings.gameSpacewarpEnabled), FSR \(settings.gameFSREnabled), RCAS \(settings.gameSharpeningEnabled), strength \(settings.gameSharpness)")
}

/// Matches VRPanel's flipped CoreGraphics drawing at its native pixels-per-dmm. Avoids GPU
/// texture uploads and frame loops: only the visible background and the panel's content draw.
@MainActor
private func drawGameImageSettingsPanel(_ panel: SettingsPanel, to path: String) {
    let scale = VRPanel.pixelsPerDmm
    let width = Int(panel.size.width * scale), height = Int(panel.size.height * scale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatal("Could not allocate settings bitmap") }
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    panel.drawBackground(in: context)
    panel.draw(in: context)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { fatal("Could not encode settings snapshot") }
    do { try data.write(to: URL(fileURLWithPath: path)) }
    catch { fatal("Could not write settings snapshot: \(error)") }
    print("Wrote \(path) (\(width)x\(height))")
}
