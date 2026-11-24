import CoreGraphics
import Foundation

/// Only advertised modes of the connected Sony panel are eligible. Refresh
/// changes preserve both the desktop bounds and the physical pixel geometry.
enum PSVR2RefreshModes {
    struct Mode: Equatable {
        let id: Int
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let hz: Double

        var rate: Int? {
            guard hz.isFinite else { return nil }
            return [90, 120].first { abs(hz - Double($0)) < 0.5 }
        }

        func hasSameGeometry(as other: Mode) -> Bool {
            width == other.width && height == other.height
                && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
        }
    }

    enum Failure: LocalizedError {
        case unavailable, unsupported(Int), rejected(CGError)
        var errorDescription: String? {
            switch self {
            case .unavailable: "The PS VR2 display is not available."
            case .unsupported(let hz): "The connected PS VR2 does not offer \(hz) Hz at its current resolution."
            case .rejected: "macOS could not change the PS VR2 refresh rate."
            }
        }
    }

    static func select(_ hz: Int, current: Mode, modes: [Mode]) -> Mode? {
        guard [90, 120].contains(hz) else { return nil }
        let candidates = modes.filter { $0.rate == hz && $0.hasSameGeometry(as: current) }
        return candidates.first { $0.id == current.id } ?? candidates.first
    }

    static func rates(for display: CGDirectDisplayID) -> [Int] {
        guard let current = currentMode(for: display) else { return [] }
        let modes = displayModes(for: display).map(describe)
        return [90, 120].filter { select($0, current: current, modes: modes) != nil }
    }

    static func currentRate(for display: CGDirectDisplayID) -> Int? {
        currentMode(for: display)?.rate
    }

    /// macOS can deliver the screen-change notification after this call returns.
    /// The caller confirms currentRate before publishing the new game cadence.
    static func request(_ hz: Int, for display: CGDirectDisplayID) throws {
        guard let current = currentMode(for: display) else { throw Failure.unavailable }
        let modes = displayModes(for: display)
        guard let selected = select(hz, current: current, modes: modes.map(describe)),
              let mode = modes.first(where: { Int($0.ioDisplayModeID) == selected.id }) else {
            throw Failure.unsupported(hz)
        }
        guard current.id != selected.id else { return }
        let result = CGDisplaySetDisplayMode(display, mode, nil)
        guard result == .success else { throw Failure.rejected(result) }
    }

    private static func currentMode(for display: CGDirectDisplayID) -> Mode? {
        // Sony's EDID vendor, plus the panel-pair geometry. A Mac display or a
        // virtual test display with the same dimensions must never be changed.
        guard CGDisplayIsOnline(display) != 0, CGDisplayIsBuiltin(display) == 0,
              CGDisplayIsInMirrorSet(display) == 0, CGDisplayVendorNumber(display) == 0x4dd9,
              let mode = CGDisplayCopyDisplayMode(display),
              mode.pixelWidth == 4000, mode.pixelHeight == 2040 else { return nil }
        return describe(mode)
    }

    private static func displayModes(for display: CGDirectDisplayID) -> [CGDisplayMode] {
        (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
    }

    private static func describe(_ mode: CGDisplayMode) -> Mode {
        Mode(id: Int(mode.ioDisplayModeID), width: mode.width, height: mode.height,
             pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, hz: mode.refreshRate)
    }
}
