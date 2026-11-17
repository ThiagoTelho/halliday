// An invisible display that hosts the Mac windows shown in VR.
//
// Windows brought into VR are moved here: off the user's desktop, never covered by Halliday's
// preview or each other, so redirected mouse input always reaches them, and the real cursor
// disappears from the user's screen while they use a window in VR. Removing the display (on quit,
// or if Halliday crashes) makes macOS move any windows left on it back to a real display.
//
// Uses the private CGVirtualDisplay API (CVirtualDisplay module); keep every use of it in this file.

import CVirtualDisplay
import CoreGraphics
import Foundation

@MainActor
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    /// Size in points; the backing store is twice that when Retina (`hiDPI`).
    let size: CGSize

    /// `serial` tells Halliday's displays apart (the windows display is 1, the one for game
    /// frames 2).
    init?(name: String = "Halliday Windows", size: CGSize = CGSize(width: 2880, height: 1620),
          hiDPI: Bool = true, refreshRate: Double = VirtualDisplay.refreshRate, serial: UInt32 = 1) {
        let d = CGVirtualDisplayDescriptor()
        d.name = name
        let scale: CGFloat = hiDPI ? 2 : 1
        d.maxPixelsWide = UInt32(size.width * scale)
        d.maxPixelsHigh = UInt32(size.height * scale)
        // ~110 points per inch, like a desktop monitor, so apps pick normal sizes.
        d.sizeInMillimeters = CGSize(width: size.width / 110 * 25.4, height: size.height / 110 * 25.4)
        d.vendorID = 0x4841 // "HA"
        d.productID = 0x4C4C // "LL"
        d.serialNum = serial
        d.queue = DispatchQueue.main
        guard let display = CGVirtualDisplay(descriptor: d) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // 120 Hz by default, so windows and VR pages on it can run at the headset's rate (a page
        // asks for its own rate; the default is 60, which Halliday's reprojection fills in).
        settings.modes = [CGVirtualDisplayMode(width: UInt32(size.width), height: UInt32(size.height), refreshRate: refreshRate)]
        guard display.apply(settings) else { return nil }
        self.display = display
        displayID = display.displayID
        self.size = size
    }

    static let refreshRate: Double = 120

    /// The refresh rate macOS runs the display at (0 if unknown).
    var actualRefreshRate: Double { CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0 }

    /// The display's rectangle in global display coordinates (points, origin top-left of the main
    /// display). Valid once macOS has added the display, shortly after creation.
    var bounds: CGRect { CGDisplayBounds(displayID) }

    /// True once macOS lists the display as active.
    var isOnline: Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.contains(displayID)
    }

    /// Waits (up to `timeout`) for macOS to bring the display online.
    func waitUntilOnline(timeout: Double = 3) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if isOnline, bounds.width > 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
