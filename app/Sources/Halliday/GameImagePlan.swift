import Foundation

/// One common image budget for the current OpenVR and OpenXR transports.
/// The panel is 2000×2040; both dimensions also satisfy the native runtime's
/// 32-pixel alignment and the independent bridge's 4096-pixel stereo limit.
enum GameImagePlan {
    static let targetWidth = 2016
    static let targetHeight = 2048

    static func renderSize(percent: Int) -> (width: Int, height: Int) {
        let percent = min(100, max(50, percent))
        func aligned(_ dimension: Int) -> Int {
            max(512, Int((Double(dimension) * Double(percent) / 3200).rounded()) * 32)
        }
        return (aligned(targetWidth), aligned(targetHeight))
    }
}
