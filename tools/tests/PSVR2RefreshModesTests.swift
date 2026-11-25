import Foundation

@main struct PSVR2RefreshModesTests {
    static func mode(_ id: Int, _ hz: Double, width: Int = 4000, height: Int = 2040,
                     pixelWidth: Int = 4000, pixelHeight: Int = 2040) -> PSVR2RefreshModes.Mode {
        .init(id: id, width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, hz: hz)
    }

    static func main() {
        let full120 = mode(69, 120), full90 = mode(70, 90)
        let hidpi120 = mode(41, 120, width: 2000, height: 1020)
        let hidpi90 = mode(43, 90, width: 2000, height: 1020)
        let modes = [hidpi120, hidpi90, full120, full90]
        precondition(PSVR2RefreshModes.select(90, current: full120, modes: modes) == full90)
        precondition(PSVR2RefreshModes.select(120, current: full90, modes: modes) == full120)
        precondition(PSVR2RefreshModes.select(120, current: full120, modes: modes) == full120)
        precondition(PSVR2RefreshModes.select(90, current: hidpi120, modes: modes) == hidpi90)
        precondition(PSVR2RefreshModes.select(90, current: full120, modes: [hidpi90]) == nil)
        precondition(PSVR2RefreshModes.select(90, current: full120, modes: [mode(3, 90, pixelWidth: 2000)]) == nil)
        precondition(PSVR2RefreshModes.select(90, current: full120, modes: [mode(3, 90, height: 2000)]) == nil)
        precondition(PSVR2RefreshModes.select(60, current: full120, modes: [mode(1, 60)]) == nil)
        precondition(PSVR2RefreshModes.select(144, current: full120, modes: [mode(1, 144)]) == nil)
        precondition(PSVR2RefreshModes.select(90, current: full120, modes: []) == nil)
        for hz in [Double.nan, .infinity, -.infinity, 0, 60, 89.4, 90.6, 119.4, 120.6] {
            precondition(mode(1, hz).rate == nil)
        }
        precondition(mode(1, 89.999).rate == 90 && mode(2, 119.999).rate == 120)
        // Duplicate advertised modes never replace an already selected mode.
        precondition(PSVR2RefreshModes.select(120, current: full120, modes: [mode(1, 120), full120]) == full120)
        print("PASS: PSVR2 advertised90/120 selection, exact logical/pixel geometry, noHiDPI/resolution substitution, unsupported/nonfinite modes, current mode retained; no display changes")
    }
}
