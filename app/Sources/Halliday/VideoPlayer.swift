// Native VR video player (ROADMAP W6): 360°/180°/fisheye video around the viewer, or ordinary 2D/3D
// movies on a cinema screen. Decoding is AVFoundation's (hardware HEVC, 8K included); frames stay
// in YUV 4:2:0 and are converted on the GPU (GAV found BGRA output unreliable for 8K). The format is
// guessed by the core (file name, container metadata, frame shape; rules from GAV).

import AVFoundation
import CHallidayCore
import CoreVideo
import Metal
import simd

@MainActor
final class VideoPlayer {
    private let renderer: Renderer
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private(set) var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var target: MTLTexture?
    private var screen: QuadLayer?
    private(set) var url: URL?
    /// Name to detect the format from, when the URL's file name says little (web videos).
    private var nameHint: String?
    private(set) var format = HallidayVideoFormat()
    private var videoSize = CGSize.zero
    /// YUV conversion constants for the current track.
    private var yuv = YUVParams.bt709Video
    /// Called when the cinema screen layer appears or disappears (the owner manages layer lists).
    var onScreenChange: ((QuadLayer?) -> Void)?
    /// Called when a video opens (true) or closes (false).
    var onOpenChange: ((Bool) -> Void)?
    /// The video played to its end (a local file's URL).
    var onEnded: ((URL) -> Void)?
    private var endObserver: NSObjectProtocol?
    /// Called with a message for the user and whether it is a problem.
    var onNotice: ((String, Bool) -> Void)?
    /// Called with the subtitle to show now (nil: none).
    var onSubtitle: ((String?) -> Void)?

    // Audio tracks and subtitles (ROADMAP W6): the file's own, and an .srt file beside it.
    private var item: AVPlayerItem?
    private var audible: AVMediaSelectionGroup?
    private var legible: AVMediaSelectionGroup?
    private var legibleOptions: [AVMediaSelectionOption] = []
    private var legibleReceiver: LegibleReceiver?
    private var externalCues: [SubtitleCue] = []
    private var externalName = ""
    /// 0: off; 1…: the file's subtitle tracks; after them, the .srt beside the file.
    private(set) var subtitleChoice = 0
    private var shownSubtitle: String?

    var hasSubtitles: Bool { !legibleOptions.isEmpty || !externalCues.isEmpty }
    var subtitleName: String {
        if subtitleChoice == 0 { return "Off" }
        if subtitleChoice <= legibleOptions.count { return legibleOptions[subtitleChoice - 1].displayName }
        return externalName
    }
    var audioTrackCount: Int { audible?.options.count ?? 0 }
    var audioTrackName: String {
        guard let audible, let item else { return "" }
        return item.currentMediaSelection.selectedMediaOption(in: audible)?.displayName ?? ""
    }

    /// The next subtitle choice: off, each of the file's tracks, the .srt beside the file.
    func cycleSubtitles() {
        let count = legibleOptions.count + (externalCues.isEmpty ? 0 : 1)
        guard count > 0 else { return }
        subtitleChoice = (subtitleChoice + 1) % (count + 1)
        if let legible { item?.select(subtitleChoice >= 1 && subtitleChoice <= legibleOptions.count ? legibleOptions[subtitleChoice - 1] : nil, in: legible) }
        show(subtitle: nil)
        log("[video] subtitles: \(subtitleName)")
    }

    /// The next audio track.
    func cycleAudio() {
        guard let audible, let item, audible.options.count > 1 else { return }
        let current = item.currentMediaSelection.selectedMediaOption(in: audible).flatMap { audible.options.firstIndex(of: $0) } ?? 0
        item.select(audible.options[(current + 1) % audible.options.count], in: audible)
        log("[video] audio: \(audioTrackName)")
    }

    private func show(subtitle: String?) {
        let text = subtitle.flatMap { $0.isEmpty ? nil : $0 }
        guard text != shownSubtitle else { return }
        shownSubtitle = text
        onSubtitle?(text)
    }

    /// The .srt beside the file: the cue at the current time.
    private func tickSubtitles() {
        guard subtitleChoice > legibleOptions.count, !externalCues.isEmpty else { return }
        let t = time
        show(subtitle: externalCues.first { t >= $0.start && t < $0.end }?.text)
    }

    init(renderer: Renderer) throws {
        self.renderer = renderer
        pipeline = try renderer.makeFullscreenPipeline(fragment: "yuv_fs", format: .rgba8Unorm)
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &textureCache)
        renderer.beforeFrame.append { [weak self] cb in self?.update(cb) }
    }

    var isOpen: Bool { player != nil }
    /// Position and length in seconds (0 while unknown).
    var time: Double { player.map { max(0, $0.currentTime().seconds) }.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    var duration: Double { (player?.currentItem?.duration.seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0 }
    /// The player's level: Halliday's master volume (`AppDelegate.applyVolume` sets it).
    var volume: Float = 0.5 {
        didSet { player?.volume = max(0, min(1, volume)) }
    }

    /// Zoom (0.5 … 2.5, 1 as filmed): a video around the viewer is made larger or smaller
    /// around the middle of the view, a cinema screen wider or narrower.
    static let zoomRange: ClosedRange<Float> = 0.5...2.5
    private(set) var zoom: Float = 1
    func zoom(by step: Float) {
        zoom = min(max(((zoom + step) * 10).rounded() / 10, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if let screen { screen.width = 4 * zoom } else { updateSphere() }
    }

    /// Turns where the viewer's "straight ahead" looks in a video around them (radians: `yaw`
    /// to the right, `pitch` up), so a comfortable head looks at the part worth seeing. A
    /// recenter puts it back on the video's middle.
    func tilt(yaw: Float, pitch: Float) {
        guard format.projection != 3 else { return }
        tiltYaw -= yaw
        tiltPitch = min(max(tiltPitch + pitch, -1.4), 1.4)
        updateSphere()
    }
    private var tiltYaw: Float = 0, tiltPitch: Float = 0

    /// A video made for passthrough has a flat backdrop where the room belongs: which one
    /// this video's is (off for an ordinary video). Only for a video around the viewer.
    enum Backdrop: Int, CaseIterable {
        /// `auto`: whatever flat colour the video's own backdrop is, measured as it plays.
        case off, auto, green, blue, black, grey, maskBelow, maskBeside
        var name: String {
            ["Off", "Automatic", "Green backdrop", "Blue backdrop", "Black backdrop", "Grey backdrop", "Mask in the lower half",
             "Mask in the right half"][rawValue]
        }
        /// As the scene shader takes it (`SceneUniforms.videoKey`; `auto`'s is measured, see `found`).
        var key: SIMD4<Float> {
            [.zero, SIMD4(0, 0, 0, 6), SIMD4(0, 1, 0, 1), SIMD4(0, 0, 1, 1), SIMD4(0, 0, 0, 2), SIMD4(0.5, 0.5, 0.5, 3), SIMD4(0, 0, 0, 4),
             SIMD4(0, 0, 0, 5)][rawValue]
        }
        /// A mask carried in the frame, beside or below the picture, instead of a backdrop colour.
        var isMask: Bool { self == .maskBelow || self == .maskBeside }
    }
    private(set) var backdrop = Backdrop.off
    func cycleBackdrop() {
        backdrop = Backdrop(rawValue: (backdrop.rawValue + 1) % Backdrop.allCases.count) ?? .off
        found = nil
        lastScan = 0
        updateSphere()
        log("[video] passthrough: \(backdrop.name)")
    }
    /// The backdrop found in the video (`Backdrop.auto`): its colour, how near it a pixel is the
    /// room's and from where the video's own, how much brightness counts, and how much of the
    /// picture it covers. Nil until the first look, or when the video has no flat backdrop.
    private(set) var found: (color: SIMD3<Float>, near: Float, far: Float, luma: Float, share: Float)?
    private var lastScan = 0.0
    /// Whether the last look found a backdrop (nil before the first).
    private(set) var foundBackdrop: Bool?

    /// Looks for the video's backdrop in a frame: the one colour that covers a good part of an
    /// eye's picture. A few thousand pixels are read from the decoded frame and gathered by
    /// brightness and hue; the fullest heap is the backdrop when it holds a sixth of them or
    /// more, and its spread says how far from it a pixel may be and still be backdrop (folds,
    /// uneven light, the compression's noise). Called twice a second, eased, so the key follows
    /// the video's light.
    private func scanBackdrop(_ pixels: CVPixelBuffer, params p: YUVParams, tenBit: Bool) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0), let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return }
        let lw = CVPixelBufferGetWidthOfPlane(pixels, 0), lh = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let cw = CVPixelBufferGetWidthOfPlane(pixels, 1), chh = CVPixelBufferGetHeightOfPlane(pixels, 1)
        let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        // One eye's picture (the left, or the upper), and of a fisheye only its disc.
        let eye = CGRect(x: 0, y: 0, width: format.stereo == 1 ? 0.5 : 1, height: format.stereo == 2 ? 0.5 : 1)
        let disc = format.projection == 2
        var samples: [SIMD3<Float>] = [] // brightness, cb, cr of the picture as shown
        samples.reserveCapacity(80 * 80)
        let n = 80
        for j in 0..<n {
            for i in 0..<n {
                let u = (Double(i) + 0.5) / Double(n), v = (Double(j) + 0.5) / Double(n)
                if disc, (u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5) > 0.46 * 0.46 { continue }
                let fx = eye.minX + u * eye.width, fy = eye.minY + v * eye.height
                let lx = min(lw - 1, Int(fx * Double(lw))), ly = min(lh - 1, Int(fy * Double(lh)))
                let cx = min(cw - 1, Int(fx * Double(cw))), cy = min(chh - 1, Int(fy * Double(chh)))
                var y: Float, cb: Float, cr: Float
                if tenBit {
                    y = Float(lumaBase.load(fromByteOffset: ly * lumaRow + lx * 2, as: UInt16.self)) / 65535
                    cb = Float(chromaBase.load(fromByteOffset: cy * chromaRow + cx * 4, as: UInt16.self)) / 65535
                    cr = Float(chromaBase.load(fromByteOffset: cy * chromaRow + cx * 4 + 2, as: UInt16.self)) / 65535
                } else {
                    y = Float(lumaBase.load(fromByteOffset: ly * lumaRow + lx, as: UInt8.self)) / 255
                    cb = Float(chromaBase.load(fromByteOffset: cy * chromaRow + cx * 2, as: UInt8.self)) / 255
                    cr = Float(chromaBase.load(fromByteOffset: cy * chromaRow + cx * 2 + 1, as: UInt8.self)) / 255
                }
                // To the colour the scene shader sees (as `yuv_fs`, without HDR's tone mapping).
                y = (y - p.range.x) * p.range.y
                cb = (cb - 0.5) * p.range.z
                cr = (cr - 0.5) * p.range.z
                let rgb = simd_clamp(SIMD3(y + p.rCoeffs.z * cr, y + p.gCoeffs.y * cb + p.gCoeffs.z * cr, y + p.bCoeffs.y * cb), .zero, .one)
                samples.append(SIMD3(simd_dot(rgb, SIMD3(0.299, 0.587, 0.114)), simd_dot(rgb, SIMD3(-0.169, -0.331, 0.5)),
                                     simd_dot(rgb, SIMD3(0.5, -0.419, -0.081))))
            }
        }
        guard samples.count > 500 else { return }
        // Heaps of 1/12 in brightness and 1/16 in each of the two hue axes.
        var heaps = [Int](repeating: 0, count: 12 * 16 * 16)
        func heap(_ s: SIMD3<Float>) -> Int {
            let a = min(11, max(0, Int(s.x * 12))), b = min(15, max(0, Int((s.y + 0.5) * 16))), c = min(15, max(0, Int((s.z + 0.5) * 16)))
            return (a * 16 + b) * 16 + c
        }
        for s in samples { heaps[heap(s)] += 1 }
        guard let fullest = heaps.indices.max(by: { heaps[$0] < heaps[$1] }) else { return }
        let seed = samples.filter { heap($0) == fullest }
        var center = seed.reduce(SIMD3<Float>.zero, +) / Float(seed.count)
        // A coloured backdrop's shadows are the same hue darker: brightness counts for less.
        let coloured = simd_length(SIMD2(center.y, center.z)) > 0.08
        let lumaWeight: Float = coloured ? 0.12 : 1
        func distance(_ s: SIMD3<Float>) -> Float {
            let d = s - center
            return (d.y * d.y + d.z * d.z + lumaWeight * d.x * d.x).squareRoot()
        }
        // Twice: what lies near the heap's middle, then near that group's own middle.
        var group = seed
        for _ in 0..<2 {
            group = samples.filter { distance($0) < 0.11 }
            guard !group.isEmpty else { break }
            center = group.reduce(SIMD3<Float>.zero, +) / Float(group.count)
        }
        let share = Float(group.count) / Float(samples.count)
        guard share >= 0.16, !group.isEmpty else {
            foundBackdrop = false
            found = nil
            return
        }
        let spread = (group.reduce(Float(0)) { $0 + distance($1) * distance($1) } / Float(group.count)).squareRoot()
        let near = min(0.13, max(0.045, 2.6 * spread + 0.02))
        // Back to a colour: brightness and the two hue axes, as the shader takes them apart.
        let color = simd_clamp(SIMD3(center.x + 1.402 * center.z, center.x - 0.344 * center.y - 0.714 * center.z, center.x + 1.772 * center.y), .zero, .one)
        if let before = found, simd_distance(before.color, color) < 0.2 {
            // The same backdrop, a little changed: followed gently.
            found = (simd_mix(before.color, color, SIMD3(repeating: 0.35)), before.near + (near - before.near) * 0.35,
                     before.near + (near - before.near) * 0.35 + 0.07, lumaWeight, share)
        } else {
            found = (color, near, near + 0.07, lumaWeight, share)
            log(String(format: "[video] passthrough: a backdrop found, colour %.2f %.2f %.2f, over %.0f %% of the picture, spread %.3f",
                       color.x, color.y, color.z, share * 100, spread))
        }
        foundBackdrop = true
    }

    /// Whether the room can show through this video now.
    var keyed: Bool { backdrop != .off && format.projection != 3 }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                     toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    // Resume positions of local files, kept between runs (the 200 most recent).
    private static let resumeKey = "videoResume"

    private func saveResumePosition() {
        guard let url, url.isFileURL, duration > 60 else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: [Double]] ?? [:]
        // Near the start or the end: next time it starts over.
        all[url.path] = time > 15 && time < duration - 15 ? [time, Date().timeIntervalSince1970, duration] : nil
        // (An entry is [position, when it was saved, the video's length]; older ones lack the length.)
        if all.count > 200, let oldest = all.min(by: { ($0.value.dropFirst().first ?? 0) < ($1.value.dropFirst().first ?? 0) }) { all[oldest.key] = nil }
        UserDefaults.standard.set(all, forKey: Self.resumeKey)
    }

    private func resumePosition(for url: URL) -> Double {
        guard url.isFileURL else { return 0 }
        return (UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: [Double]])?[url.path]?.first ?? 0
    }
    var isPlaying: Bool { (player?.rate ?? 0) != 0 }

    /// Where a local video was left and how long it is (0: not kept), for the Videos wall.
    static func resume(for url: URL) -> (position: Double, length: Double)? {
        guard let entry = (UserDefaults.standard.dictionary(forKey: resumeKey) as? [String: [Double]])?[url.path], let position = entry.first else { return nil }
        return (position, entry.count > 2 ? entry[2] : 0)
    }

    /// The videos left unfinished that are still where they were, the last watched first.
    static func unfinished() -> [URL] {
        let all = UserDefaults.standard.dictionary(forKey: resumeKey) as? [String: [Double]] ?? [:]
        return all.sorted { ($0.value.dropFirst().first ?? 0) > ($1.value.dropFirst().first ?? 0) }
            .map { URL(fileURLWithPath: $0.key) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The video after `url` in its folder, by name (nil at the last one).
    nonisolated static func next(after url: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentTypeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        let videos = items.filter {
            let type = try? $0.resourceValues(forKeys: Set(keys)).contentType
            return type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true || $0.pathExtension.lowercased() == "mkv"
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let i = videos.firstIndex(where: { $0.path == url.path }), i + 1 < videos.count else { return nil }
        return videos[i + 1]
    }

    /// A file's format from its name and frame size alone (the wall's badges and one-eye
    /// thumbnails; the player itself also reads the track's metadata).
    nonisolated static func guessFormat(name: String, width: Int, height: Int) -> HallidayVideoFormat {
        var f = HallidayVideoFormat()
        _ = name.withCString { halliday_video_detect($0, nil, nil, false, UInt32(max(0, width)), UInt32(max(0, height)), &f) }
        return f
    }

    /// Opens a file or web video and starts playing it in front of `head`. For web videos, pass the
    /// page's cookies and headers (Referer, User-Agent) and a name to guess the format from (the
    /// page title plus the file name: VR sites put "180", "SBS"… in titles); `startAt` resumes
    /// where the page was.
    func open(_ url: URL, head: HeadPose, cookies: [HTTPCookie] = [], headers: [String: String] = [:],
              nameHint: String? = nil, startAt: Double = 0) async {
        close()
        // Matroska: macOS can't read the container. With ffmpeg on the Mac its streams are repacked
        // into an MP4 (no re-encoding of the picture), once, and that is played.
        var url = url, nameHint = nameHint
        if url.isFileURL, url.pathExtension.lowercased() == "mkv" {
            guard let ffmpeg = Self.ffmpegPath else {
                onNotice?("MKV files need ffmpeg on the Mac (brew install ffmpeg): macOS can't read them itself", true)
                return
            }
            onNotice?("Preparing \(url.lastPathComponent)", false)
            let source = url
            guard let repacked = await Task.detached(priority: .userInitiated, operation: { Self.repack(source, ffmpeg: ffmpeg) }).value else {
                onNotice?("\(url.lastPathComponent) couldn't be prepared for playing", true)
                return
            }
            nameHint = nameHint ?? url.lastPathComponent
            url = repacked
        }
        var options: [String: Any] = [:]
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: url, options: options)
        self.nameHint = nameHint
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                log("[video] \(url.lastPathComponent): no video track")
                return
            }
            let (size, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            let shown = size.applying(transform)
            videoSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            let desc = descriptions.first
            format = detectFormat(url: url, description: desc)
            yuv = YUVParams.from(description: desc)
        } catch {
            log("[video] can't open \(url.lastPathComponent): \(error.localizedDescription)")
            return
        }

        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
            ],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        // Subtitles come to Halliday as text (it draws them in VR), off until asked for.
        audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        legibleOptions = legible?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) } ?? []
        let receiver = LegibleReceiver { [weak self] text in
            guard let self, subtitleChoice >= 1, subtitleChoice <= legibleOptions.count else { return }
            show(subtitle: text)
        }
        let text = AVPlayerItemLegibleOutput()
        text.suppressesPlayerRendering = true
        text.setDelegate(receiver, queue: .main)
        item.add(text)
        legibleReceiver = receiver
        self.item = item
        subtitleChoice = 0
        externalCues = []
        if url.isFileURL {
            let srt = url.deletingPathExtension().appendingPathExtension("srt")
            if let content = (try? String(contentsOf: srt, encoding: .utf8)) ?? (try? String(contentsOf: srt, encoding: .isoLatin1)) {
                externalCues = SubtitleCue.parse(srt: content)
                externalName = srt.lastPathComponent
            }
        }
        let player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let url = self.url, url.isFileURL else { return }
                self.onEnded?(url)
            }
        }
        player.volume = max(0, min(1, volume))
        zoom = 1
        // A file that says it is made for passthrough starts keyed on green, the usual backdrop.
        let said = (nameHint ?? url.lastPathComponent).lowercased()
        // (A file that says "alpha" carries a mask; which half it is in is tried by hand.)
        found = nil
        foundBackdrop = nil
        lastScan = 0
        backdrop = ["passthrough", "pass-through", "greenscreen", "green screen", "chromakey"].contains { said.contains($0) } ? .auto
            : said.contains("alpha") ? .maskBelow : .off
        player.appliesMediaSelectionCriteriaAutomatically = false
        if let legible { item.select(nil, in: legible) }
        self.player = player
        self.output = output
        self.url = url
        onOpenChange?(true)
        place(facing: head)
        let start = startAt > 1 ? startAt : resumePosition(for: url)
        if start > 1 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
        player.play()
        log(String(format: "[video] %@: %.0fx%.0f, %@ %@%@, %d audio, %d subtitles", url.lastPathComponent, videoSize.width, videoSize.height,
                   Self.projectionName(format.projection), Self.stereoName(format.stereo), yuv.isHDR ? ", HDR (tone-mapped)" : "",
                   audioTrackCount, legibleOptions.count + (externalCues.isEmpty ? 0 : 1)))
    }

    func close() {
        let wasOpen = player != nil
        saveResumePosition()
        defer { if wasOpen { onOpenChange?(false) } }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        output = nil
        item = nil
        audible = nil
        legible = nil
        legibleOptions = []
        legibleReceiver = nil
        externalCues = []
        subtitleChoice = 0
        show(subtitle: nil)
        url = nil
        target = nil
        renderer.videoSphere = nil
        renderer.environmentDimming = 0
        if screen != nil {
            screen = nil
            onScreenChange?(nil)
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
    }

    func seek(by seconds: Double) {
        guard let player else { return }
        let t = CMTimeAdd(player.currentTime(), CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: CMTimeMaximum(t, .zero), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Cycles the projection (360 → 180 → fisheye → flat), for files whose format was guessed wrong.
    func cycleProjection(head: HeadPose) {
        format.projection = (format.projection + 1) % 4
        place(facing: head)
        log("[video] projection: \(Self.projectionName(format.projection))")
    }

    /// Cycles the stereo layout (mono → side by side → top/bottom).
    func cycleStereo(head: HeadPose) {
        format.stereo = (format.stereo + 1) % 3
        place(facing: head)
        log("[video] stereo: \(Self.stereoName(format.stereo))")
    }

    /// Re-centers the video on where the head looks now (yaw only).
    func recenter(head: HeadPose) { place(facing: head) }

    // --- Presentation ---

    private func place(facing head: HeadPose) {
        let fwd = head.orientation.act(SIMD3<Float>(0, 0, -1))
        let yaw = simd_quatf(angle: atan2(-fwd.x, -fwd.z), axis: [0, 1, 0])
        if format.projection == 3 {
            // Cinema: a 4 m wide screen 3.5 m away at eye height, surroundings dimmed.
            renderer.videoSphere = nil
            renderer.environmentDimming = 0.75
            let aspect = format.flat_aspect > 0 ? format.flat_aspect : 16 / 9
            let layer = screen ?? QuadLayer(texture: target ?? renderer.placeholderTexture, position: .zero, width: 4)
            layer.width = 4 * zoom
            layer.aspect = 1 / aspect
            layer.stereo = format.stereo
            layer.orientation = yaw
            layer.position = SIMD3(head.position.x, head.position.y, head.position.z) + yaw.act(SIMD3(0, 0, -3.5))
            if screen == nil {
                screen = layer
                onScreenChange?(layer)
            }
        } else {
            renderer.environmentDimming = 0
            if screen != nil {
                screen = nil
                onScreenChange?(nil)
            }
            sphereOrientation = yaw
            tiltYaw = 0
            tiltPitch = 0
            updateSphere()
        }
    }

    private var sphereOrientation = simd_quatf(angle: 0, axis: [0, 1, 0])

    private func updateSphere() {
        guard format.projection != 3, let target else { return }
        renderer.videoSphere = VideoSphere(texture: target, projection: format.projection, stereo: format.stereo,
                                           fisheyeFovDeg: format.fisheye_fov_deg, orientation: sphereOrientation,
                                           tilt: simd_quatf(angle: tiltYaw, axis: [0, 1, 0]) * simd_quatf(angle: tiltPitch, axis: [1, 0, 0]), zoom: zoom,
                                           key: backdrop == .auto ? SIMD4(found?.color ?? .zero, 6) : backdrop.key,
                                           keyFit: backdrop == .auto ? SIMD4(found?.near ?? 0, found?.far ?? 0, found?.luma ?? 1, 0) : .zero)
    }

    /// Converts the newest decoded frame into `target` (called before each rendered frame).
    private func update(_ cb: MTLCommandBuffer) {
        tickSubtitles()
        guard let output, let player, let cache = textureCache else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        _ = player
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let tenBit = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        var lumaRef: CVMetalTexture?, chromaRef: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, tenBit ? .r16Unorm : .r8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(pixels, 0), CVPixelBufferGetHeightOfPlane(pixels, 0), 0, &lumaRef)
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixels, nil, tenBit ? .rg16Unorm : .rg8Unorm,
                                                  CVPixelBufferGetWidthOfPlane(pixels, 1), CVPixelBufferGetHeightOfPlane(pixels, 1), 1, &chromaRef)
        guard let lumaRef, let chromaRef, let luma = CVMetalTextureGetTexture(lumaRef),
              let chroma = CVMetalTextureGetTexture(chromaRef) else { return }

        // The flat screen samples a minified frame: give it mipmaps. The sphere samples level 0.
        let flat = format.projection == 3
        if target?.width != w || target?.height != h || (target?.mipmapLevelCount ?? 1 > 1) != flat {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: flat)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            target = renderer.device.makeTexture(descriptor: d)
        }
        guard let target else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(luma, index: 0)
        enc.setFragmentTexture(chroma, index: 1)
        enc.setFragmentSamplerState(renderer.linearSampler, index: 0)
        var params = CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ? yuv.fullRange : yuv
        enc.setFragmentBytes(&params, length: MemoryLayout<YUVParams>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        if flat, let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }
        // A video keyed by its own backdrop: looked at twice a second.
        if backdrop == .auto, !flat, CACurrentMediaTime() - lastScan > 0.5 {
            lastScan = CACurrentMediaTime()
            scanBackdrop(pixels, params: params, tenBit: tenBit)
        }
        // The decoder pool may reuse the buffer: keep it until the GPU is done.
        let keep = KeepAlive([pixels, lumaRef, chromaRef])
        cb.addCompletedHandler { _ in keep.release() }

        if flat { screen?.texture = target } else { updateSphere() }
    }

    // --- Format ---

    private func detectFormat(url: URL, description: CMFormatDescription?) -> HallidayVideoFormat {
        func ext(_ key: String) -> String? {
            guard let d = description else { return nil }
            return CMFormatDescriptionGetExtension(d, extensionKey: key as CFString) as? String
        }
        let kind = ext("ProjectionKind"), packing = ext("ViewPackingKind")
        let multiview = description.map { CMFormatDescriptionGetExtension($0, extensionKey: "HasLeftStereoEyeView" as CFString) != nil } ?? false
        var f = HallidayVideoFormat()
        let name = [nameHint, url.lastPathComponent].compactMap { $0 }.joined(separator: " ")
        _ = name.withCString { name in
            withOptionalCString(kind) { k in
                withOptionalCString(packing) { p in
                    halliday_video_detect(name, k, p, multiview, UInt32(videoSize.width), UInt32(videoSize.height), &f)
                }
            }
        }
        return f
    }

    // --- Matroska through ffmpeg ---

    private static var ffmpegPath: String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Repacks `source` (an MKV) into an MP4 in the caches folder: the picture is copied as it is,
    /// the sound becomes AAC, and its first text subtitle track is written beside it as .srt. Kept
    /// for the next time the same file is opened. Nil if ffmpeg fails.
    private nonisolated static func repack(_ source: URL, ffmpeg: String) -> URL? {
        let fm = FileManager.default
        let folder = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Halliday/Repacked")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let attributes = try? fm.attributesOfItem(atPath: source.path)
        let stamp = "\((attributes?[.size] as? Int) ?? 0)-\(Int((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let base = folder.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(stamp)")
        let out = base.appendingPathExtension("mp4")
        if fm.fileExists(atPath: out.path) { return out }
        func run(_ arguments: [String]) -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = ["-nostdin", "-y", "-loglevel", "error"] + arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            p.waitUntilExit()
            return p.terminationStatus == 0
        }
        let partial = base.appendingPathExtension("part.mp4")
        let common = ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k"]
        // HEVC must be tagged hvc1 for macOS to play it; the tag is refused for other codecs.
        let done = run(common + ["-tag:v", "hvc1", partial.path]) || run(common + [partial.path])
        guard done, (try? fm.moveItem(at: partial, to: out)) != nil else {
            try? fm.removeItem(at: partial)
            return nil
        }
        _ = run(["-i", source.path, "-map", "0:s:0", base.appendingPathExtension("srt").path])
        return out
    }

    static func projectionName(_ p: Int32) -> String {
        ["360°", "180°", "fisheye", "flat screen"][Int(max(0, min(3, p)))]
    }

    static func stereoName(_ s: Int32) -> String {
        ["mono", "side by side", "top/bottom"][Int(max(0, min(2, s)))]
    }
}

private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString { body($0) }
}

/// YUV → RGB conversion constants (must match `YUVParams` in Shaders.swift).
struct YUVParams {
    var rCoeffs: SIMD4<Float>
    var gCoeffs: SIMD4<Float>
    var bCoeffs: SIMD4<Float>
    /// x: luma offset, y: luma scale, z: chroma scale (video range by default).
    var range: SIMD4<Float>

    static func matrix(kr: Float, kb: Float) -> YUVParams {
        let kg = 1 - kr - kb
        return YUVParams(
            rCoeffs: SIMD4(0, 0, 2 - 2 * kr, 0),
            gCoeffs: SIMD4(0, -(2 - 2 * kb) * kb / kg, -(2 - 2 * kr) * kr / kg, 0),
            bCoeffs: SIMD4(0, 2 - 2 * kb, 0, 0),
            range: SIMD4(16.0 / 255, 255.0 / 219, 255.0 / 224, 0))
    }

    static let bt709Video = matrix(kr: 0.2126, kb: 0.0722)
    static let bt2020Video = matrix(kr: 0.2627, kb: 0.0593)
    static let bt601Video = matrix(kr: 0.299, kb: 0.114)

    var fullRange: YUVParams {
        var p = self
        p.range = SIMD4(0, 1, 1, range.w)
        return p
    }

    /// Picks the matrix from the track's YCbCr matrix tag (BT.709 if untagged), and marks HDR
    /// tracks (PQ or HLG transfer) so the conversion tone-maps them (`range.w`).
    static func from(description: CMFormatDescription?) -> YUVParams {
        guard let d = description else { return bt709Video }
        let m = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
        var p = m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) ? bt2020Video
            : m == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) ? bt601Video : bt709Video
        let transfer = CMFormatDescriptionGetExtension(d, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        if transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { p.range.w = 1 }
        if transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { p.range.w = 2 }
        return p
    }

    /// True for an HDR track.
    var isHDR: Bool { range.w > 0.5 }
}

/// Receives the text of a video's own subtitle tracks from AVFoundation (on the main queue).
private final class LegibleReceiver: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let handler: @MainActor (String) -> Void
    init(_ handler: @escaping @MainActor (String) -> Void) { self.handler = handler }

    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers nativeSamples: [Any], forItemTime itemTime: CMTime) {
        let text = strings.map(\.string).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        MainActor.assumeIsolated { handler(text) }
    }
}

/// One subtitle of an .srt file.
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String

    /// Parses SubRip text: blocks of a number, "00:00:01,000 --> 00:00:04,000" and lines of text.
    static func parse(srt: String) -> [SubtitleCue] {
        func seconds(_ s: Substring) -> Double? {
            let parts = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2].prefix(6)) else { return nil }
            return h * 3600 + m * 60 + sec
        }
        var cues: [SubtitleCue] = []
        let lines = srt.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "").split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            guard let arrow = lines[i].range(of: "-->"), let start = seconds(lines[i][..<arrow.lowerBound]),
                  let end = seconds(lines[i][arrow.upperBound...]) else {
                i += 1
                continue
            }
            i += 1
            var text: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                // Styling tags (<i>, {\an8}) are dropped.
                text.append(lines[i].replacingOccurrences(of: "<[^>]+>|\\{[^}]+\\}", with: "", options: .regularExpression))
                i += 1
            }
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text.joined(separator: "\n"))) }
        }
        return cues
    }
}
