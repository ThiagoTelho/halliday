import Foundation

/// Game-frame notifications follow physical display target times, independently of pose updates.
/// A missed compositor callback never turns a nominal 60 Hz game into half of a slower callback
/// rate. Missed deadlines coalesce into one wake; no queue of old game ticks is accumulated.
struct GameFrameCadence {
    private(set) var physicalHz: Float
    private(set) var halfFrameRate: Bool
    var gameHz: Float { physicalHz / (halfFrameRate ? 2 : 1) }
    var gameInterval: Double { 1 / Double(gameHz) }

    private var nextTarget: Double?
    private var lastTarget: Double?
    private var lastNotifiedTarget: Double?

    init(physicalHz: Float, halfFrameRate: Bool) {
        self.physicalHz = physicalHz.isFinite && physicalHz > 0 ? physicalHz : 90
        self.halfFrameRate = halfFrameRate
    }

    /// Keep the display clock and the most recent wake when changing the game's
    /// budget. Repeated settings changes cannot restart a phase or replay a wake.
    @discardableResult
    mutating func setHalfFrameRate(_ half: Bool) -> Bool {
        guard halfFrameRate != half else { return false }
        halfFrameRate = half
        nextTarget = lastNotifiedTarget.map { $0 + gameInterval }
        return true
    }

    /// A verified physical mode change retains the last wake, so changing the
    /// period cannot replay an already delivered display target.
    @discardableResult
    mutating func setPhysicalHz(_ hz: Float) -> Bool {
        guard hz.isFinite, (20...240).contains(hz), abs(physicalHz - hz) > 0.01 else { return false }
        physicalHz = hz
        nextTarget = lastNotifiedTarget.map { $0 + gameInterval }
        return true
    }

    mutating func shouldNotify(at target: Double) -> Bool {
        guard target.isFinite else { return false }
        let epsilon = 1e-6
        if let lastTarget {
            if target < lastTarget - epsilon {
                // A new display-link clock/target: restart a phase, without replaying old ticks.
                nextTarget = nil
                lastNotifiedTarget = nil
            } else if target <= lastTarget + epsilon {
                // A display target can be seen twice, including across a live toggle.
                return false
            }
        }
        lastTarget = target
        if !halfFrameRate {
            lastNotifiedTarget = target
            return true
        }
        guard let nextTarget else {
            self.nextTarget = target + gameInterval
            lastNotifiedTarget = target
            return true
        }
        guard target + epsilon >= nextTarget else { return false }
        let elapsedPeriods = floor(max(0, target - nextTarget + epsilon) / gameInterval) + 1
        self.nextTarget = nextTarget + elapsedPeriods * gameInterval
        lastNotifiedTarget = target
        return true
    }
}
