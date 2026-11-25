import Foundation

/// Retained fractions of each eye's *tangent span*, not fractions of its angle.
/// The horizontal removal is entirely temporal: the nasal edge never moves.
/// This is intentionally separate from FSR's render scale.
struct GameCropSettings: Equatable {
    let enabled: Bool
    let horizontal: Float
    let vertical: Float

    init(enabled: Bool = false, horizontal: Float = 0.85, vertical: Float = 0.90) {
        self.enabled = enabled
        self.horizontal = Self.fraction(horizontal, fallback: 0.85)
        self.vertical = Self.fraction(vertical, fallback: 0.90)
    }

    private static func fraction(_ value: Float, fallback: Float) -> Float {
        value.isFinite ? min(1, max(0.5, value)) : fallback
    }
}

/// One immutable camera contract for a bridge generation. Changing it requires
/// a new bridge/game session: a live swapchain cannot silently change its FOV.
/// No shared-memory ABI additions are needed; all clients already negotiate
/// these extents and tangents through the bridge's original configuration.
struct GameViewGeometry: Equatable {
    struct Size: Equatable {
        var width: Int
        var height: Int
    }

    let renderSize: Size
    let imageTarget: Size
    let leftTangents: SIMD4<Float>
    let rightTangents: SIMD4<Float>
    /// Integral source-pixel removal before any optional FSR pass.
    let removedColumns: Int
    let removedRows: Int
    var isCropped: Bool { removedColumns > 0 || removedRows > 0 }

    init(renderSize: Size, imageTarget: Size,
         leftTangents: SIMD4<Float>, rightTangents: SIMD4<Float>,
         crop: GameCropSettings = .init()) {
        func valid(_ t: SIMD4<Float>) -> Bool {
            (0..<4).allSatisfy { t[$0].isFinite }
                && t.x < 0 && t.y > 0 && t.w < 0 && t.z > 0
                && (t.y - t.x).isFinite && (t.z - t.w).isFinite
        }
        // A malformed/new headset calibration must not create a different
        // invalid camera or unexpectedly remove its forward ray.
        let enabled = crop.enabled && valid(leftTangents) && valid(rightTangents)
            && renderSize.width >= 64 && renderSize.height >= 64
        func retained(_ dimension: Int, _ requested: Float) -> Int {
            let aligned = Int((Double(dimension) * Double(requested) / 32).rounded()) * 32
            return min(dimension, max(64, aligned))
        }
        var width = enabled ? retained(renderSize.width, crop.horizontal) : renderSize.width
        let height = enabled ? retained(renderSize.height, crop.vertical) : renderSize.height
        // Keep the optical axis inside both eyes even for unusually nasal-heavy
        // calibrations; never clip the nasal region to satisfy a slider value.
        if enabled {
            let nasalFraction = max(leftTangents.y / (leftTangents.y - leftTangents.x),
                                    -rightTangents.x / (rightTangents.y - rightTangents.x))
            let minimum = Int(ceil(Double(nasalFraction) * Double(renderSize.width) / 32)) * 32
            width = min(renderSize.width, max(width, minimum))
        }
        self.renderSize = Size(width: width, height: height)
        let columns = renderSize.width - width
        let rows = renderSize.height - height
        removedColumns = columns
        removedRows = rows
        let horizontal = Float(width) / Float(max(1, renderSize.width))
        let vertical = Float(height) / Float(max(1, renderSize.height))
        if columns == 0 && rows == 0 {
            // Preserve bit-identical default camera values and image budgets.
            self.leftTangents = leftTangents
            self.rightTangents = rightTangents
            self.imageTarget = imageTarget
        } else {
            func cropped(_ t: SIMD4<Float>, left: Bool) -> SIMD4<Float> {
                var result = t
                if columns > 0 {
                    let span = (t.y - t.x) * horizontal
                    if left { result.x = t.y - span } else { result.y = t.x + span }
                }
                if rows > 0 {
                    let inset = (t.z - t.w) * (1 - vertical) * 0.5
                    result.z = t.z - inset
                    result.w = t.w + inset
                }
                return result
            }
            self.leftTangents = cropped(leftTangents, left: true)
            self.rightTangents = cropped(rightTangents, left: false)
            // Reconstruct only the retained field. Round the output UP, so
            // alignment cannot lower its pixels-per-tangent density. Use the
            // exact retained-pixel ratio: a Float ratio can add 32 pixels to
            // an already exactly aligned 100%-render-scale result.
            func densityTarget(_ output: Int, kept: Int, full: Int) -> Int {
                let (numerator, productOverflow) = output.multipliedReportingOverflow(by: kept)
                let (denominator, denominatorOverflow) = full.multipliedReportingOverflow(by: 32)
                guard output > 0, kept > 0, full > 0, !productOverflow, !denominatorOverflow,
                      denominator > 0 else { return output }
                let blocks = numerator / denominator + (numerator % denominator == 0 ? 0 : 1)
                let (aligned, alignedOverflow) = blocks.multipliedReportingOverflow(by: 32)
                return alignedOverflow ? output : min(output, max(64, aligned))
            }
            self.imageTarget = Size(width: densityTarget(imageTarget.width, kept: width, full: renderSize.width),
                                    height: densityTarget(imageTarget.height, kept: height, full: renderSize.height))
        }
    }
}
