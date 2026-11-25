import Foundation

@main struct GameViewGeometryTests {
    static func main() throws {
        let left = SIMD4<Float>(-1.88, 0.95, 1.33, -1.22)
        let right = SIMD4<Float>(-0.95, 1.88, 1.27, -1.33)
        let target = GameViewGeometry.Size(width: 2016, height: 2048)
        func make(_ percent: Int, _ crop: GameCropSettings) -> GameViewGeometry {
            let size = GameImagePlan.renderSize(percent: percent)
            return .init(renderSize: .init(width: size.width, height: size.height), imageTarget: target,
                         leftTangents: left, rightTangents: right, crop: crop)
        }
        func close(_ a: Float, _ b: Float, _ why: String) {
            precondition(abs(a - b) < 0.000004, "\(why): \(a), \(b)")
        }
        func ray(_ t: SIMD4<Float>, _ u: Float, _ v: Float) -> SIMD2<Float> {
            SIMD2(t.x + (t.y - t.x) * u, t.z + (t.w - t.z) * v)
        }
        // Repeat the saved rays under head motion: camera rotation must not
        // turn a crop into a scale/zoom or an eye swap. This oracle uses Double
        // matrices independently of the crop implementation.
        func world(_ tangent: SIMD2<Float>, _ angle: Double) -> SIMD3<Double> {
            let x = Double(tangent.x), y = Double(tangent.y)
            return SIMD3(cos(angle) * x - sin(angle), y, -sin(angle) * x - cos(angle))
        }
        var comparedRays = 0
        for percent in stride(from: 50, through: 100, by: 5) {
            let full = make(percent, .init())
            precondition(!full.isCropped && full.imageTarget == target)
            for index in 0..<4 {
                precondition(full.leftTangents[index].bitPattern == left[index].bitPattern)
                precondition(full.rightTangents[index].bitPattern == right[index].bitPattern)
            }
            for horizontal: Float in [0.5, 0.7, 0.85, 1] {
                for vertical: Float in [0.5, 0.9, 1] {
                    let crop = make(percent, .init(enabled: true, horizontal: horizontal, vertical: vertical))
                    let width = crop.renderSize.width, height = crop.renderSize.height
                    precondition(width % 32 == 0 && height % 32 == 0 && width >= 64 && height >= 64)
                    precondition(width <= full.renderSize.width && height <= full.renderSize.height)
                    precondition(crop.imageTarget.width <= target.width && crop.imageTarget.height <= target.height)
                    for eye in 0..<2 {
                        let before = eye == 0 ? left : right
                        let after = eye == 0 ? crop.leftTangents : crop.rightTangents
                        precondition((eye == 0 ? after.y : after.x).bitPattern == (eye == 0 ? before.y : before.x).bitPattern,
                                     "The nasal boundary is never cropped")
                        close((before.y - before.x) / Float(full.renderSize.width),
                              (after.y - after.x) / Float(width), "horizontal density")
                        close((before.z - before.w) / Float(full.renderSize.height),
                              (after.z - after.w) / Float(height), "vertical density")
                        for y in stride(from: 0, to: height, by: max(1, height / 11)) {
                            for x in stride(from: 0, to: width, by: max(1, width / 13)) {
                                let sourceX = x + (eye == 0 ? crop.removedColumns : 0)
                                let sourceY = y + crop.removedRows / 2
                                let expected = ray(before, (Float(sourceX) + 0.5) / Float(full.renderSize.width),
                                                   (Float(sourceY) + 0.5) / Float(full.renderSize.height))
                                let actual = ray(after, (Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
                                close(actual.x, expected.x, "retained pixel horizontal ray")
                                close(actual.y, expected.y, "retained pixel vertical ray")
                                for angle in [-0.8, 0, 0.37] {
                                    let a = world(actual, angle), b = world(expected, angle)
                                    precondition((0..<3).allSatisfy { abs(a[$0] - b[$0]) < 0.000005 })
                                    comparedRays += 1
                                }
                            }
                        }
                        // The final compositor's inverse FOV map leaves missing
                        // outer/top/bottom rays outside [0,1], rather than clamping
                        // and stretching them across the retained image.
                        if crop.removedColumns > 0 {
                            let outer = eye == 0 ? before.x : before.y
                            let u = (outer - after.x) / (after.y - after.x)
                            precondition(eye == 0 ? u < 0 : u > 1)
                        }
                        if crop.removedRows > 0 {
                            precondition((after.z - before.z) / (after.z - after.w) < 0)
                            precondition((after.z - before.w) / (after.z - after.w) > 1)
                        }
                    }
                }
            }
        }
        let cropped = make(100, .init(enabled: true))
        precondition(cropped.renderSize == .init(width: 1728, height: 1856))
        precondition(cropped.imageTarget == cropped.renderSize)
        let ratio = Double(cropped.renderSize.width * cropped.renderSize.height) / Double(target.width * target.height)
        precondition(abs(ratio - 0.7767857142857143) < 1e-12)
        precondition(GameCropSettings(horizontal: .nan, vertical: .infinity) == .init())
        precondition(GameCropSettings(horizontal: -1, vertical: 5) == .init(horizontal: 0.5, vertical: 1))
        let invalid = GameViewGeometry(renderSize: target, imageTarget: target,
            leftTangents: SIMD4(.nan, 1, 1, -1), rightTangents: right, crop: .init(enabled: true))
        precondition(!invalid.isCropped && invalid.renderSize == target)

        // Machine-readable values feed the independent C++ ABI reader.
        if CommandLine.arguments.count == 2 {
            let row: [String: Any] = ["full_width": target.width, "full_height": target.height,
                "width": cropped.renderSize.width, "height": cropped.renderSize.height,
                "tangents": [cropped.leftTangents, cropped.rightTangents].map { t in (0..<4).map { t[$0] } }]
            try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS: \(comparedRays) replayed rays, both eyes, preserved density/nasal edges, aligned budgets, black crop bounds, bit-identical defaults")
    }
}
