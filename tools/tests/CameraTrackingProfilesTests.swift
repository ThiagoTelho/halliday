import Darwin
import Foundation

@main struct CameraTrackingProfilesTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/halliday-camera-profile-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("calibration.json")
        let id = "TEST-PCB-1234567"
        func write(_ rotation: [Double] = [-0.004112071331861413, 0.003328861353291489, -0.01492005963837453],
                   headsetID: String = "TEST-PCB-1234567", version: Int = 1, mode: Int = 16) throws {
            let value: [String: Any] = ["version": version, "headset_id": headsetID, "camera_mode": mode,
                "right_fisheye_rotation_radians": rotation]
            try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
        }
        precondition(CameraTrackingProfiles.load(for: id, from: file) == nil)
        try write()
        let calibration = CameraTrackingProfiles.load(for: id, from: file)!
        precondition(calibration.headsetID == id)
        precondition(abs(calibration.rightFisheyeRotation.z + 0.0149200596) < 1e-9)
        for other in [nil, "", "OTHER-PCB", "has space", "abcdefghijklmnopq", "bad\0id"] as [String?] {
            precondition(CameraTrackingProfiles.load(for: other, from: file) == nil)
        }
        for mode in [0, 1, 4] { try write(mode: mode); precondition(CameraTrackingProfiles.load(for: id, from: file) == nil) }
        for version in [0, 2] { try write(version: version); precondition(CameraTrackingProfiles.load(for: id, from: file) == nil) }
        for rotation in [[0.0], [0, 0, 0, 0], [0, 0, 0.1], [0.06, 0.06, 0.06], [1e200, 0, 0]] {
            try write(rotation); precondition(CameraTrackingProfiles.load(for: id, from: file) == nil)
        }
        try write([0, 0, 0]); precondition(CameraTrackingProfiles.load(for: id, from: file)!.rightFisheyeRotation == .zero)
        try write([5 * .pi / 180, 0, 0]); precondition(CameraTrackingProfiles.load(for: id, from: file) != nil)
        for text in ["", "{}", "{broken", "{\"version\":true}",
            "{\"version\":1,\"headset_id\":\"\(id)\",\"camera_mode\":16,\"right_fisheye_rotation_radians\":[NaN,0,0]}"] {
            try Data(text.utf8).write(to: file, options: .atomic)
            precondition(CameraTrackingProfiles.load(for: id, from: file) == nil)
        }
        try Data(repeating: 32, count: 16 * 1024 + 1).write(to: file)
        precondition(CameraTrackingProfiles.load(for: id, from: file) == nil)
        try write()
        let link = root.appendingPathComponent("symlink.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        precondition(CameraTrackingProfiles.load(for: id, from: link) == nil)
        precondition(CameraTrackingProfiles.load(for: id, from: root) == nil)
        let pipe = root.appendingPathComponent("pipe")
        precondition(mkfifo(pipe.path, 0o600) == 0)
        precondition(CameraTrackingProfiles.load(for: id, from: pipe) == nil)
        print("PASS: matching PCB only, exact radians, mode/version/identity validation, 5deg bound, malformed/oversize/symlink/pipe rejection, missing/default behavior")
    }
}
