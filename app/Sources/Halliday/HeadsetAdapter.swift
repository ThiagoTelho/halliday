// Headsets as adapters: everything Halliday knows about one model of headset, in one place, so
// that another model can be added beside it without touching the rest of the app.
//
// An adapter says how to recognise the headset's display, its optics (field of view, the lens
// correction's mesh, how its panel lights), the eye sizes to draw and to ask apps for, its
// cameras for passthrough, how to open its tracking, and the words the interface uses for it
// (its name, what to check when it isn't found, what it needs). The rest of Halliday asks
// `Headsets.current`; `headsetPanelPixels`, `Optics` and the renderer's camera numbers forward
// to it.
//
// Adding a headset:
//   1. its driver in the core (as `core/halliday-core/src/psvr2/` is the PS VR2's: protocol,
//      USB, lens model) with a session the C API exposes, as `HallidaySession` is;
//   2. an adapter here: a type conforming to `HeadsetAdapter`, added to `Headsets.supported`;
//   3. if its controllers aren't PS VR2 Sense controllers, their driver (as
//      `SenseControllers.swift` and the core's `sense.rs` are the Sense's), and its passthrough
//      cameras' numbers in `cameras` (nil when it has none).
// Onboarding lists `Headsets.supported`; the choice is kept in UserDefaults (`headset`).

import AppKit
import CHallidayCore

/// A passthrough camera pair's numbers, as the scene shader uses them (`see_through`,
/// `see_through_fisheyes`).
struct PassthroughCameras: Sendable {
    /// The rectified pair: focal length and centres in pixels of its picture, and how far below
    /// the head's forward it looks (radians).
    let focal: Float
    let centre: (left: Float, right: Float, y: Float)
    let pitch: Float
    /// The raw fisheyes (a wider mode): per camera, the turn from the rectified pair's frame (as
    /// rows), the focal length, centre and first lens term (in pixels), and the second term.
    let fisheyes: [(rows: [SIMD3<Float>], lens: SIMD4<Float>, k2: Float)]
}

protocol HeadsetAdapter: Sendable {
    /// Stable identifier, kept in the user's settings.
    var id: String { get }
    /// "PlayStation VR2": in onboarding and settings.
    var name: String { get }
    /// "PS VR2": in the interface's shorter places.
    var shortName: String { get }
    /// "Sense controllers".
    var controllersName: String { get }

    /// The display macOS shows for it, both eyes together, in pixels.
    var panelPixels: CGSize { get }
    /// Whether `screen` is this headset's display.
    func isDisplay(_ screen: NSScreen) -> Bool
    /// Each eye's size Halliday draws its scene at, before the lens correction.
    var renderEyeSize: Int { get }
    /// Each eye's size an app drawing for this headset is asked for (Quest apps).
    var appEyeSize: (width: Int, height: Int) { get }

    /// Each eye's field of view (radians from the eye's axis).
    func fov(_ eye: Eye) -> Fov
    /// The lens correction's mesh for one eye, from the headset's own calibration.
    func distortionMesh(calibration: [Float], eye: Eye, cols: UInt32, rows: UInt32) -> (vertices: [HallidayMeshVertex], indices: [UInt32])?
    /// The part of a refresh over which the panel lights its rows, top to bottom (0: all at once).
    var scanFraction: Float { get }

    /// Its tracking and the rest of its link (buttons, cameras, brightness): a session of its
    /// driver in the core.
    func openSession() -> Headset
    /// Its passthrough cameras, if it has any.
    var cameras: PassthroughCameras? { get }

    /// What to check when its display isn't found.
    var connectionHelp: String { get }
    /// What it needs, in onboarding and the README's words.
    var requirements: [String] { get }
}

extension HeadsetAdapter {
    func isDisplay(_ screen: NSScreen) -> Bool { screen.convertRectToBacking(screen.frame).size == panelPixels }
}

/// The PlayStation VR2, through Sony's PC adapter. Its driver is the core's `psvr2/` (protocol,
/// USB, lens model ported from Monado) with the session in `session.rs`; its controllers are
/// `SenseControllers.swift` with the core's `sense.rs`.
struct PSVR2: HeadsetAdapter {
    let id = "psvr2"
    let name = "PlayStation VR2"
    let shortName = "PS VR2"
    let controllersName = "Sense controllers"

    /// The panel pair as macOS reports it through Sony's PC adapter.
    let panelPixels = CGSize(width: 4000, height: 2040)
    /// Above panel resolution: the lenses magnify the centre.
    let renderEyeSize = 2304
    /// The panel's own size an eye.
    let appEyeSize = (width: 2000, height: 2040)

    func fov(_ eye: Eye) -> Fov {
        var f = [Float](repeating: 0, count: 4)
        halliday_eye_fov(eye.rawValue, &f)
        return Fov(left: f[0], right: f[1], up: f[2], down: f[3])
    }

    func distortionMesh(calibration: [Float], eye: Eye, cols: UInt32, rows: UInt32) -> (vertices: [HallidayMeshVertex], indices: [UInt32])? {
        let nv = Int((cols + 1) * (rows + 1)), ni = Int(cols * rows * 6)
        var vertices = [HallidayMeshVertex](repeating: HallidayMeshVertex(), count: nv)
        var indices = [UInt32](repeating: 0, count: ni)
        let ok = calibration.withUnsafeBufferPointer { cal in
            halliday_distortion_mesh(cal.baseAddress, eye.rawValue, cols, rows, &vertices, UInt32(nv), &indices, UInt32(ni))
        }
        return ok ? (vertices, indices) : nil
    }

    /// The panel lights 2040 of a refresh's 2200 rows' worth of time (Monado's number, as GAV
    /// uses it).
    let scanFraction: Float = 2040.0 / 2200.0

    func openSession() -> Headset { Headset() }

    /// The bottom cameras: `PSVR2_BOTTOM` and `PSVR2_BOTTOM_FISHEYE` in the core's
    /// `tracking/stereo.rs` (keep in step). The pair's numbers are in pixels of a 640 × 640
    /// picture (fitted, good to about 3 %), the fisheyes' in pixels of a 1000 × 1016 one.
    let cameras: PassthroughCameras? = PassthroughCameras(
        focal: 365.4,
        centre: (313.6, 313.0, 320.5),
        pitch: 0.269,
        fisheyes: [
            ([SIMD3(0.96214, 0.07084, 0.26317), SIMD3(0.00227, 0.96352, -0.26764), SIMD3(-0.27253, 0.25811, 0.92688)],
             SIMD4(394.59, 493.88, 516.70, 0.04338), -0.01803),
            ([SIMD3(0.96313, -0.07527, -0.25828), SIMD3(0.00323, 0.96323, -0.26867), SIMD3(0.26901, 0.25793, 0.92796)],
             SIMD4(398.65, 509.23, 511.17, 0.02762), -0.01672),
        ])

    let connectionHelp = "Check that Sony's PC adapter is plugged in and powered, its DisplayPort cable is in a USB-C port of the Mac, its USB cable in a USB 3 port, and the headset is on."

    let requirements = [
        "Sony's PlayStation VR2 PC adapter (the headset doesn't power up plugged straight into the Mac)",
        "A USB 3 port for the adapter's USB cable, and a USB-C port with DisplayPort for its video",
        "Optional: the PS VR2 Sense controllers, paired with the Mac over Bluetooth",
    ]
}

enum Headsets {
    /// Every headset Halliday can drive, in the order onboarding lists them.
    static let supported: [any HeadsetAdapter] = [PSVR2()]

    /// The headset the user chose (onboarding), or the first.
    static var current: any HeadsetAdapter {
        let chosen = UserDefaults.standard.string(forKey: "headset")
        return supported.first { $0.id == chosen } ?? supported[0]
    }

    static func choose(_ id: String) {
        guard supported.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: "headset")
    }

    /// Whichever supported headset's display `screen` is.
    static func adapter(for screen: NSScreen) -> (any HeadsetAdapter)? {
        ([current] + supported).first { $0.isDisplay(screen) }
    }
}
