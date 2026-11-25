import Foundation
import Metal
import simd

@main struct GameSpacewarpStaticMetalTests {
    static func fail(_ message:String)->Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1)
    }
    static func require(_ condition:Bool,_ message:String="GPU regression failed") {
        if !condition { fail(message) }
    }
    static func main() {
        do { try run() } catch { fail(String(describing:error)) }
    }
    static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("No Metal device") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let flow = try GameOpticalFlow(device: device, resourceFolder: root.appendingPathComponent("amd-optical-flow"))
        let provider: GameSpacewarp.FlowProvider = { previous, current, cb in
            guard let r = flow.encode(previous: previous, current: current, commandBuffer: cb) else { return nil }
            return .init(motion: r.motion, sceneChange: r.sceneChange, analysisSizePerEye: r.analysisSizePerEye,
                         vectorScaleToSource: r.vectorScaleToSource, blockSize: r.blockSize)
        }
        let tangents = SIMD4<Float>(-1, 1, 1, -1)
        let descriptor = GameSpacewarp.Descriptor(orientation: [0, 0, 0, 1], position: .zero,
            tangentsLeft: tangents, tangentsRight: tangents, flipped: false, colourSpaces: .zero)
        var results: [[String: Any]] = []
        for (eyeWidth, height, pattern, jitter, partial) in [
            (512,512,0,false,false), (512,512,1,false,false), (512,512,2,false,false),
            (2016,2048,1,false,false), (512,512,1,true,false), (2016,2048,1,true,false),
            (512,512,1,true,true), (512,512,2,true,true), (2016,2048,1,true,true)] {
            let width = eyeWidth * 2
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            d.storageMode = .shared; d.usage = .shaderRead
            let source = device.makeTexture(descriptor: d)!
            var expected = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height { for x in 0..<width {
                let eye = x / eyeWidth, local = x % eyeWidth
                let value: Int
                if pattern == 0 { value = 96 }
                else if pattern == 1 {
                    let panel = local > eyeWidth/5 && local < eyeWidth*4/5 && y > height/4 && y < height*3/4
                    let line = y % 29 < 2 || local % 37 < 2
                    value = panel ? (line ? 230 : 60) : 24
                } else { value = (local * 13 + y * 7 + ((local/16 + y/16) % 2) * 80) % 230 }
                let at = (y * width + x) * 4
                expected[at] = UInt8(value); expected[at+1] = UInt8((value + eye*17) % 255); expected[at+2] = UInt8((value + eye*31) % 255)
            }}
            expected.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width*4) }
            let processor = try GameSpacewarp(device: device, resourceFolder: root.appendingPathComponent("spacewarp"), flowProvider: provider)
            var maximumChanged = 0, maximumError = 0, maximumExactDifference = 0
            var samples: [[Int]] = [], gpu: [Double] = []
            for sequence in 1...10 {
                if partial {
                    // A tiny animated indicator must not make the rest of an
                    // otherwise static opaque menu acquire invented motion.
                    for eye in 0..<2 { for y in 16..<24 { for x in 16..<24 {
                        let at = (y * width + eye * eyeWidth + x) * 4
                        expected[at] = sequence % 2 == 0 ? 80 : 180
                        expected[at+1] = sequence % 2 == 0 ? 180 : 80
                        expected[at+2] = 90
                    }}}
                    expected.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel:0,
                        withBytes:$0.baseAddress!, bytesPerRow:width*4) }
                }
                let cb = queue.makeCommandBuffer()!
                let yaw: Float = jitter ? (sequence % 2 == 0 ? 0.05 : -0.05) * .pi / 180 : 0
                let camera = jitter ? GameSpacewarp.Descriptor(orientation: simd_quatf(angle: yaw,axis:[0,1,0]).vector, position: .zero,
                    tangentsLeft:tangents,tangentsRight:tangents,flipped:false,colourSpaces:.zero) : descriptor
                require(processor.prepare(source: source, sequence: UInt64(sequence), descriptor: camera, commandBuffer: cb))
                let output = processor.synthesize(alpha: 0.5, commandBuffer: cb)
                let row = (width*4 + 255) & ~255
                let copy = output.map { texture -> MTLBuffer in
                    let b = device.makeBuffer(length: row*height, options: .storageModeShared)!
                    let blit = cb.makeBlitCommandEncoder()!
                    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: width,height: height,depth:1),
                              to: b, destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row*height)
                    blit.endEncoding(); return b
                }
                cb.commit(); cb.waitUntilCompleted()
                require(cb.status == .completed, "GPU command failed")
                gpu.append((cb.gpuEndTime-cb.gpuStartTime)*1000)
                guard let copy else { continue }
                let actual = copy.contents().assumingMemoryBound(to: UInt8.self)
                var changed = 0, exact = 0, error = 0
                for y in 0..<height { for x in 0..<width {
                    if partial && x % eyeWidth < 96 && y < 96 { continue }
                    var e = 0
                    for c in 0..<3 { e = max(e,abs(Int(actual[y*row+x*4+c])-Int(expected[(y*width+x)*4+c]))) }
                    if e > 0 { exact += 1 }
                    if e > 1 {
                        changed += 1
                        if samples.count < 12 { samples.append([sequence,x,y,e]) }
                    }
                    error = max(error,e)
                }}
                maximumChanged=max(maximumChanged,changed); maximumExactDifference=max(maximumExactDifference,exact); maximumError=max(maximumError,error)
            }
            let result: [String:Any] = ["eye_width":eyeWidth,"height":height,"pattern":pattern,"frames":10,"head_locked_menu_camera_yaw_jitter_deg":jitter ? 0.05 : 0,
                "changed_pixels_over_one_level_max":maximumChanged,"changed_pixels_any_max":maximumExactDifference,
                "max_rgb_error":maximumError,"pixel_count":width*height,"sample_artifacts":samples,"gpu_ms":gpu,
                "animated_indicator":partial,"background_exclusion_top_left_per_eye":partial ? [96,96] : [0,0],
                "scope":partial ? "Head-locked menu/background with an animated8x8 indicator; exact background outside96x96 region in each eye, genuine AMD and production synthesis" : jitter ? "Unchanged head-locked menu pixels with tracked camera yaw oscillating by +/-0.05 degrees; genuine AMD plus production synthesis" : "Unchanged real source pixels and camera; genuine production AMD Optical Flow plus production synthesis, not fixture vectors"]
            results.append(result)
            print("STATIC \(eyeWidth)x\(height) pattern\(pattern) jitter\(jitter) indicator\(partial): changed>1=\(maximumChanged), maxRGB=\(maximumError)")
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted,.sortedKeys]).write(to: destination)
        require(results.allSatisfy { ($0["max_rgb_error"] as? Int) == 0 },
                "Static source regions must remain bit exact, including head-locked menus with tracking jitter and a small animated indicator")
    }
}
