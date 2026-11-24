import Foundation
@preconcurrency import Metal

/// Shader compilation stays off the display actor. Until preparation completes,
/// the compositor continues showing real frames with its ordinary reprojection.
final class GameSpacewarpPreparation: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var value: GameSpacewarp?
    private var problem: String?

    var ready: GameSpacewarp? { lock.lock(); defer { lock.unlock() }; return value }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return problem }

    func start(device: MTLDevice) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                let flow = try GameOpticalFlow(device: device)
                let made = try GameSpacewarp(device: device, flowProvider: { previous, current, commandBuffer in
                    guard let result = flow.encode(previous: previous, current: current,
                                                   commandBuffer: commandBuffer) else { return nil }
                    return GameSpacewarp.Motion(motion: result.motion, sceneChange: result.sceneChange,
                        analysisSizePerEye: result.analysisSizePerEye,
                        vectorScaleToSource: result.vectorScaleToSource, blockSize: result.blockSize)
                })
                lock.lock(); value = made; lock.unlock()
            } catch {
                let message = String(describing: error)
                lock.lock(); problem = message; lock.unlock()
            }
        }
    }
}
