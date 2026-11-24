import Darwin
import Foundation

/// A measured relative rotation of the tracking cameras, never a controller pose offset.
struct CameraTrackingCalibration: Equatable, Sendable {
    var headsetID: String
    /// Right raw-camera-local rotation vector, radians; left-multiplies its generic extrinsic.
    var rightFisheyeRotation: SIMD3<Float>
}

enum CameraTrackingProfiles {
    private struct Profile: Decodable {
        var version: Int
        var headset_id: String
        var camera_mode: Int
        var right_fisheye_rotation_radians: [Double]
    }

    /// A missing, unrelated or malformed profile keeps the generic calibration. Only raw
    /// bottom fisheyes (mode16) accept this correction; rectified camera modes are unchanged.
    static func load(for headsetID: String?, from url: URL) -> CameraTrackingCalibration? {
        guard let headsetID, validIdentity(headsetID), let data = boundedRegularFile(url),
              let profile = try? JSONDecoder().decode(Profile.self, from: data),
              profile.version == 1, profile.camera_mode == 16, profile.headset_id == headsetID,
              profile.right_fisheye_rotation_radians.count == 3 else { return nil }
        let r = profile.right_fisheye_rotation_radians
        guard r.allSatisfy(\.isFinite), r.reduce(0, { $0 + $1 * $1 }) <= pow(5 * .pi / 180, 2)
        else { return nil }
        return CameraTrackingCalibration(headsetID: headsetID,
            rightFisheyeRotation: SIMD3(Float(r[0]), Float(r[1]), Float(r[2])))
    }

    private static func validIdentity(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 16 && id.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    private static func boundedRegularFile(_ url: URL) -> Data? {
        let limit = 16 * 1024
        // Never follow a leaf symlink or block on a pipe. Read at most limit+1 bytes even if
        // a file changes during reload, without mapping mutable memory into the decoder.
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit else { return nil }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        var count = 0
        while count < bytes.count {
            let received = bytes.withUnsafeMutableBytes {
                read(fd, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if received < 0 { if errno == EINTR { continue }; return nil }
            if received == 0 { break }
            count += received
        }
        guard count <= limit else { return nil }
        return Data(bytes.prefix(count))
    }
}
