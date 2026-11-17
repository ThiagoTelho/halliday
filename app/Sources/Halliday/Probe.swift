// `halliday --probe`: command-line check of the Rust core through the C ABI.

import CHallidayCore
import CoreGraphics
import Foundation
import simd

func runProbe(replayPath: String?) {
    print("Halliday probe (core \(String(cString: halliday_core_version())))")
    if let path = replayPath {
        guard let headset = Headset(replaying: URL(fileURLWithPath: path), looping: false) else {
            print("Can't read \(path)")
            exit(1)
        }
        print("Lens calibration: \(headset.calibration)")
        watch(headset, seconds: 3, every: 0.25)
        return
    }
    listDisplays()
    let fov = Optics.fov(.left)
    print(String(format: "Left eye FOV: left %.1f° right %.1f° up %.1f° down %.1f°",
                 fov.left * 180 / .pi, fov.right * 180 / .pi, fov.up * 180 / .pi, fov.down * 180 / .pi))
    let headset = Headset()
    if let mesh = Optics.distortionMesh(calibration: headset.calibration, eye: .left) {
        print("Distortion mesh: \(mesh.vertices.count) vertices, \(mesh.indices.count / 3) triangles")
    }
    print("Watching USB for 3 s…")
    watch(headset, seconds: 3, every: 0.5)
}

private func listDisplays() {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &displays, &count)
    print("Displays: \(count)")
    for id in displays {
        guard let mode = CGDisplayCopyDisplayMode(id) else { continue }
        let isHeadset = CGFloat(mode.pixelWidth) == headsetPanelPixels.width && CGFloat(mode.pixelHeight) == headsetPanelPixels.height
        let main = CGDisplayIsMain(id) != 0 ? " main" : ""
        let tag = isHeadset ? "  <- looks like a \(Headsets.current.shortName)" : ""
        print("  #\(id): \(mode.pixelWidth)x\(mode.pixelHeight) @ \(Int(mode.refreshRate)) Hz\(main)\(tag)")
    }
}

private func describe(_ p: HeadPose) -> String {
    let fwd = p.orientation.act(SIMD3<Float>(0, 0, -1))
    let yaw = atan2(-fwd.x, -fwd.z) * 180 / .pi
    let pitch = asin(max(-1, min(1, fwd.y))) * 180 / .pi
    return String(format: "yaw %+6.1f° pitch %+5.1f°  pos (%+.2f %+.2f %+.2f)  slam age %4.1f ms%@",
                  yaw, pitch, p.position.x, p.position.y, p.position.z,
                  Double(p.slamAgeNs) / 1e6, p.predicted ? "" : "  (no IMU)")
}

private func watch(_ headset: Headset, seconds: Double, every interval: Double) {
    let end = Date().addingTimeInterval(seconds)
    var lastState: LinkState?
    while Date() < end {
        let state = headset.linkState
        if state != lastState {
            print("Link: \(state)")
            lastState = state
        }
        if let pose = headset.predict(atHostNs: hostTimeNs() + 20_000_000) {
            print("  \(describe(pose))")
        }
        if state == .ended { break }
        Thread.sleep(forTimeInterval: interval)
    }
}
