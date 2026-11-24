import Foundation

/// The user's cadence choice, separate from Auto's current runtime decision.
enum GameHalfFrameRateMode: String, CaseIterable, Identifiable, Sendable {
    case off, on, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .on: "Half"
        case .auto: "Auto"
        }
    }
}
