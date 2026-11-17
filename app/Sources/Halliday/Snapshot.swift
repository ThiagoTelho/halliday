// `halliday --snapshot FILE.png [--yaw DEG] [--pitch DEG] [--no-lens]`: renders one frame offscreen
// at panel resolution and saves it, without a window or any permission. Used to check rendering
// by eye.

import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

@MainActor
func runSnapshot(path: String, arguments: [String]) {
    func value(_ flag: String) -> Float? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? Float(arguments[$0 + 1]) : nil }
    }
    guard let device = MTLCreateSystemDefaultDevice() else { fatal("No Metal device") }
    let renderer: Renderer
    do { renderer = try Renderer(device: device, eyeSize: Headsets.current.renderEyeSize) } catch { fatal("Renderer failed: \(error)") }
    renderer.distortionEnabled = !arguments.contains("--no-lens")
    if let tex = renderer.makeLayerTexture(width: 1600, height: 1000, rgba: TestLayer.rgba(width: 1600, height: 1000)) {
        renderer.layers = [QuadLayer(texture: tex, position: [0, 1.6, -1.0], width: 1.6)]
    }

    let mouse = MouseLook()
    mouse.yaw = (value("--yaw") ?? 0) * .pi / 180
    mouse.pitch = (value("--pitch") ?? 0) * .pi / 180
    saveFrame(renderer: renderer, head: mouse.pose(atHostNs: 0)!, calibration: mouse.calibration, to: path)
}


/// Renders one frame offscreen at panel resolution and writes it as a PNG.
@MainActor
func saveFrame(renderer: Renderer, head: HeadPose, calibration: [Float], to path: String) {
    let device = renderer.device
    let (w, h) = (Int(headsetPanelPixels.width), Int(headsetPanelPixels.height))
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    guard let target = device.makeTexture(descriptor: d) else { fatal("No target texture") }
    renderer.render(head: head, calibration: calibration, into: target, present: nil)

    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                              decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatal("Could not encode \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatal("Could not write \(path)") }
    print("Wrote \(path) (\(w)x\(h))")
}
