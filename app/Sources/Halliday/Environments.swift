// Environments (ROADMAP W12.D): the place the user stands in. Built-in ones are drawn by the scene
// shader (Shaders.swift, "Environments"): Grid, Dusk, Terrace and Focus. Any 360° image
// (equirectangular, 2:1) put in Halliday's Environments folder is offered too.

import AppKit
import ImageIO
import Metal

@MainActor
final class Environments {
    struct Place: Equatable {
        /// "grid", "dusk", "terrace", "focus", or "image:<file name>".
        let id: String
        let name: String
        let shaderIndex: Int32
        let file: URL?
        /// Two colors that stand for it on its tile.
        let swatch: (NSColor, NSColor)

        static func == (a: Place, b: Place) -> Bool { a.id == b.id }
    }

    static let builtIn = [
        Place(id: "grid", name: "Grid", shaderIndex: 0, file: nil,
              swatch: (NSColor(srgbRed: 0.03, green: 0.03, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.11, green: 0.13, blue: 0.22, alpha: 1))),
        Place(id: "dusk", name: "Dusk", shaderIndex: 1, file: nil,
              swatch: (NSColor(srgbRed: 0.11, green: 0.10, blue: 0.26, alpha: 1), NSColor(srgbRed: 0.98, green: 0.56, blue: 0.30, alpha: 1))),
        Place(id: "terrace", name: "Terrace", shaderIndex: 2, file: nil,
              swatch: (NSColor(srgbRed: 0.01, green: 0.01, blue: 0.03, alpha: 1), NSColor(srgbRed: 0.10, green: 0.55, blue: 0.50, alpha: 1))),
        Place(id: "focus", name: "Focus", shaderIndex: 3, file: nil,
              swatch: (NSColor(srgbRed: 0.012, green: 0.013, blue: 0.018, alpha: 1), NSColor(srgbRed: 0.04, green: 0.042, blue: 0.052, alpha: 1))),
        // Round 4 (design board 13).
        Place(id: "sea", name: "Sea", shaderIndex: 5, file: nil,
              swatch: (NSColor(srgbRed: 0.02, green: 0.03, blue: 0.10, alpha: 1), NSColor(srgbRed: 0.11, green: 0.16, blue: 0.29, alpha: 1))),
        Place(id: "dunes", name: "Dunes", shaderIndex: 6, file: nil,
              swatch: (NSColor(srgbRed: 0.17, green: 0.16, blue: 0.33, alpha: 1), NSColor(srgbRed: 0.94, green: 0.70, blue: 0.48, alpha: 1))),
        Place(id: "forest", name: "Forest", shaderIndex: 7, file: nil,
              swatch: (NSColor(srgbRed: 0.03, green: 0.06, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.12, green: 0.19, blue: 0.16, alpha: 1))),
        Place(id: "snow", name: "Snowfield", shaderIndex: 8, file: nil,
              swatch: (NSColor(srgbRed: 0.02, green: 0.04, blue: 0.09, alpha: 1), NSColor(srgbRed: 0.25, green: 0.83, blue: 0.63, alpha: 1))),
        Place(id: "pavilion", name: "Pavilion", shaderIndex: 10, file: nil,
              swatch: (NSColor(srgbRed: 0.13, green: 0.10, blue: 0.24, alpha: 1), NSColor(srgbRed: 0.95, green: 0.64, blue: 0.43, alpha: 1))),
        Place(id: "space", name: "Deep space", shaderIndex: 9, file: nil,
              swatch: (NSColor(srgbRed: 0.02, green: 0.02, blue: 0.04, alpha: 1), NSColor(srgbRed: 0.35, green: 0.23, blue: 0.48, alpha: 1))),
    ]

    /// Where the user's own 360° images go.
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Halliday/Environments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The built-in places, then the images in the folder (by name).
    static func all() -> [Place] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // 3D scenes: drawn as real geometry (Scene3D) in the dark of Focus.
        let scenes = files.filter { Self.sceneExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Self.scenePlace)
        let images = files.filter { ["jpg", "jpeg", "png", "heic", "tif", "tiff", "exr", "hdr"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                Place(id: "image:\(url.lastPathComponent)", name: url.deletingPathExtension().lastPathComponent, shaderIndex: 4, file: url,
                      swatch: (NSColor(white: 0.25, alpha: 1), NSColor(white: 0.5, alpha: 1)))
            }
        return builtIn + scenes + images
    }

    static let sceneExtensions: Set<String> = ["usdz", "usdc", "usda", "usd", "obj"]

    private static func scenePlace(_ url: URL) -> Place {
        Place(id: "scene:\(url.lastPathComponent)", name: url.deletingPathExtension().lastPathComponent, shaderIndex: 3, file: url,
              swatch: (NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1), NSColor(srgbRed: 0.16, green: 0.20, blue: 0.30, alpha: 1)))
    }

    private let renderer: Renderer
    private var loading = 0
    /// Called with a message when an image can't be used.
    var onNotice: ((String) -> Void)?

    init(renderer: Renderer) {
        self.renderer = renderer
    }

    /// Shows the place with this id (the grid if it no longer exists).
    func apply(_ id: String) {
        // (Debug: "scene:/full/path.usda" shows a scene file from anywhere.)
        let place = Self.all().first { $0.id == id }
            ?? (id.hasPrefix("scene:/") ? Self.scenePlace(URL(fileURLWithPath: String(id.dropFirst(6)))) : nil)
            ?? Self.builtIn[0]
        loading += 1
        guard let file = place.file else {
            renderer.setEnvironment(place.shaderIndex, texture: nil)
            return
        }
        if Self.sceneExtensions.contains(file.pathExtension.lowercased()) {
            // Read off the main thread; the current place stays until the scene is ready.
            let token = loading
            let device = renderer.device
            Task.detached(priority: .userInitiated) {
                let result = Result { try Scene3D.load(file, device: device) }
                await MainActor.run { [weak self] in
                    guard let self, token == self.loading else { return }
                    switch result {
                    case .success(let scene):
                        log("[environment] \(scene.name): \(scene.parts.count) parts, \(scene.triangles) triangles")
                        self.renderer.setEnvironment(place.shaderIndex, texture: nil, scene: scene)
                    case .failure(let error):
                        self.onNotice?("\(place.name) couldn't be used as a place: \(error)")
                    }
                }
            }
            return
        }
        // Images are decoded off the main thread; the current place stays until the image is ready.
        let token = loading
        let device = renderer.device
        Task.detached(priority: .userInitiated) {
            let decoded = Self.decode(file)
            await MainActor.run { [weak self] in
                guard let self, token == self.loading else { return }
                guard let decoded, let texture = self.renderer.updateLayerTexture(nil, width: decoded.width, height: decoded.height, bytes: decoded.bytes) else {
                    self.onNotice?("\(place.name) couldn't be used as an environment (a 2:1 360° image is needed)")
                    return
                }
                _ = device
                decoded.bytes.deallocate()
                self.renderer.setEnvironment(4, texture: texture)
            }
        }
    }

    /// The image as RGBA bytes, at most 6144 pixels wide (enough for the headset: about 17 per
    /// degree across 360°, more than the lenses resolve at the edges; 8K images are scaled down).
    private nonisolated static func decode(_ url: URL) -> (width: Int, height: Int, bytes: UnsafeMutableRawPointer)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let aspect = Double(image.width) / Double(max(image.height, 1))
        guard aspect > 1.9, aspect < 2.1 else { return nil } // equirectangular 360° only
        let width = min(image.width, 6144), height = width / 2
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
        guard let ctx = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            bytes.deallocate()
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, bytes)
    }
}
