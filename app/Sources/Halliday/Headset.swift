// Swift wrapper around the Rust core's session API (core/halliday-core/include/halliday_core.h).

import CHallidayCore
import Foundation
import simd

/// Host clock shared with the core: the clock of `CACurrentMediaTime()` and display links, in ns.
func hostTimeNs() -> Int64 { halliday_host_time_ns() }

enum LinkState: Int32, CustomStringConvertible {
    case searching = 0, connected, fullSpeedLink, replaying, ended, error

    var description: String {
        switch self {
        case .searching: "searching for the headset"
        case .connected: "connected"
        case .fullSpeedLink: "USB 2 link: connect the adapter to a USB 3 port"
        case .replaying: "replaying a recording"
        case .ended: "recording ended"
        case .error: "headset found but could not be opened"
        }
    }
}

struct HeadPose {
    var position: SIMD3<Float>
    var orientation: simd_quatf
    var angularVelocity: SIMD3<Float>
    var slamAgeNs: Int64
    var predicted: Bool
}

struct HeadsetStatus {
    var worn: Bool
    var functionButton: Bool
    var ipdMm: Int
}

enum Eye: Int32 { case left = 0, right = 1 }

/// Field of view in radians (left and down negative).
struct Fov { var left, right, up, down: Float }

/// A source of head poses: a real headset over USB or a replayed recording. Thread-safe.
final class Headset: @unchecked Sendable {
    private let session: OpaquePointer

    /// Starts looking for a headset over USB; connects and reconnects in the background.
    init() {
        session = halliday_session_open_usb()
    }

    /// Replays a `.hrec` recording in real time. Nil if the file can't be read.
    init?(replaying url: URL, looping: Bool = true) {
        guard let s = halliday_session_open_replay(url.path, looping) else { return nil }
        session = s
    }

    deinit { halliday_session_close(session) }

    var linkState: LinkState { LinkState(rawValue: halliday_session_link_state(session)) ?? .searching }

    /// Already fetched at connection time; polling this never sends another USB command.
    var hardwareIdentity: String? {
        var bytes = [UInt8](repeating: 0, count: 64)
        guard bytes.withUnsafeMutableBufferPointer({
            halliday_session_headset_identity(session, $0.baseAddress, UInt32($0.count))
        }), let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
        return String(bytes: bytes[..<end], encoding: .utf8)
    }

    /// Head pose predicted for a host time in ns (e.g. a display link's target timestamp × 1e9).
    func predict(atHostNs t: Int64) -> HeadPose? {
        var p = HallidayHeadPose()
        guard halliday_session_predict(session, t, &p) else { return nil }
        return HeadPose(
            position: SIMD3(p.position.0, p.position.1, p.position.2),
            orientation: simd_quatf(ix: p.orientation.0, iy: p.orientation.1, iz: p.orientation.2, r: p.orientation.3),
            angularVelocity: SIMD3(p.angular_velocity.0, p.angular_velocity.1, p.angular_velocity.2),
            slamAgeNs: p.slam_age_ns,
            predicted: p.predicted != 0)
    }

    var status: HeadsetStatus? {
        var s = HallidayHeadsetStatus()
        guard halliday_session_status(session, &s) else { return nil }
        return HeadsetStatus(worn: s.worn != 0, functionButton: s.function_button != 0, ipdMm: Int(s.ipd_mm))
    }

    func recenter(full: Bool = false) { halliday_session_recenter(session, full) }

    /// A bright spot in one tracking camera's picture (a controller's LED, or anything bright).
    struct CameraSpot {
        var x: Float
        var y: Float
        var area: Int
        var peak: Int
    }

    /// One camera's newest frame: when it exposed and the spots in it, brightest first.
    struct CameraView {
        var exposureHostNs: Int64
        var counter: Int
        var frames: Int
        var width: Int
        var height: Int
        var spotCount: Int
        var spots: [CameraSpot]
    }

    /// Switches the headset's tracking cameras: 0 off, 1 the two bottom cameras with a normal
    /// exposure, 4 the controller-tracking mode. The core reads the frames and keeps only each
    /// view's bright spots.
    func setCamera(mode: Int, threshold: Int = 200) {
        halliday_session_set_camera(session, UInt32(mode), UInt8(max(1, min(255, threshold))))
    }

    /// View 0…3 (a frame holds two cameras; mode 4 has two kinds of frame); nil before a frame.
    /// Passthrough: whether the bottom cameras' newest picture is kept (in memory only).
    func setCameraKeep(_ on: Bool) { halliday_session_set_camera_keep(session, on) }

    /// Copies the bottom cameras' newest picture into `buffer` when there is one other than
    /// number `have`: its size, its exposure's time and its number.
    /// `bc4`: the picture is BC4 blocks (camera mode 0x10's two fisheyes), not a byte a pixel.
    func cameraImage(into buffer: inout [UInt8], have: Int) -> (width: Int, height: Int, exposureHostNs: Int64, counter: Int, bc4: Bool)? {
        var info = HallidayCameraView()
        info.counter = UInt32(truncatingIfNeeded: have)
        let capacity = UInt32(buffer.count)
        guard buffer.withUnsafeMutableBufferPointer({ halliday_session_camera_image(session, &info, $0.baseAddress, capacity) }) else { return nil }
        return (Int(info.width), Int(info.height), info.exposure_host_ns, Int(info.counter), info.format == 1)
    }

    func cameraView(_ view: Int) -> CameraView? {
        var info = HallidayCameraView()
        var spots = [HallidayCameraSpot](repeating: HallidayCameraSpot(), count: 48)
        guard halliday_session_camera_view(session, UInt32(view), &info, &spots, UInt32(spots.count)) else { return nil }
        return CameraView(exposureHostNs: info.exposure_host_ns, counter: Int(info.counter), frames: Int(info.frames),
                          width: Int(info.width), height: Int(info.height), spotCount: Int(info.spots),
                          spots: spots.prefix(Int(min(info.spots, 48))).map { CameraSpot(x: $0.x, y: $0.y, area: Int($0.area), peak: Int($0.peak)) })
    }

    @discardableResult
    func setBrightness(_ value: Float) -> Bool { halliday_session_set_brightness(session, value) }

    /// The 8 lens calibration parameters (the fallback until the headset's were read).
    var calibration: [Float] {
        var c = [Float](repeating: 0, count: 8)
        _ = halliday_session_calibration(session, &c)
        return c
    }
}

/// The current headset's optics (its adapter's: HeadsetAdapter.swift).
enum Optics {
    static func fov(_ eye: Eye) -> Fov { Headsets.current.fov(eye) }

    /// Distortion mesh for one eye: vertices with per-channel UVs and a triangle index list.
    static func distortionMesh(calibration: [Float], eye: Eye, cols: UInt32 = 64, rows: UInt32 = 64)
        -> (vertices: [HallidayMeshVertex], indices: [UInt32])?
    {
        Headsets.current.distortionMesh(calibration: calibration, eye: eye, cols: cols, rows: rows)
    }
}
