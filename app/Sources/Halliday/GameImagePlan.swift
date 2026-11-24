import Foundation

/// Full image budget for shared game projection. The panel is 2000×2040;
/// 32-pixel-aligned dimensions fit the bridge's 4096-pixel stereo limit.
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
