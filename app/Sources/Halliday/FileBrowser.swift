// The file browser in VR (ROADMAP W11 B.12, W13.3): a Night Glass panel listing the Mac's folders.
// As "Videos" it lists folders and their videos, to open one in the player without leaving VR; as
// "Files" it lists everything: videos open in the player, pictures in Photos, plain text in Notes,
// and anything else in its Mac app, whose window is brought into VR. Places on the left (Movies,
// Downloads, Desktop, Documents, Home, mounted volumes), the current folder on the right with
// thumbnails. It only reads folders; macOS asks for consent the first time some of them are opened.

import AVFoundation
import AppKit
import UniformTypeIdentifiers

@MainActor
final class FileBrowser: VRPanel {
    /// Called with a video the user picked.
    var onOpen: ((URL) -> Void)?
    /// Called with a picture the user picked, and the pictures of its folder in order.
    var onOpenImage: ((URL, [URL]) -> Void)?
    /// Called with a plain text file the user picked.
    var onOpenText: ((URL) -> Void)?
    /// Called with any other file: it opens in its Mac app.
    var onOpenOther: ((URL) -> Void)?
    var onClose: (() -> Void)?

    /// What the panel lists: videos only, or every file.
    enum Mode {
        /// Videos and folders; every file; or folders and Android app files (`.apk`), to
        /// choose one to install (from Games).
        case videos, files, apps
        var folderKey: String { ["fileBrowserFolder", "filesFolder", "appsFolder"][self == .videos ? 0 : self == .files ? 1 : 2] }
    }

    private(set) var mode = Mode.videos

    private enum Kind {
        case folder, video, image, text, other
    }

    private struct Entry: Equatable {
        let url: URL
        let name: String
        let kind: Kind
        let size: Int64
        var isFolder: Bool { kind == .folder }
    }

    private struct Place {
        let name: String, symbol: String, url: URL
    }

    private var places: [Place] = []
    private(set) var folder: URL
    private var entries: [Entry] = []
    private var loading = false
    private var failed = false
    /// Still loading after `stallAfter` seconds: the disk isn't answering (an external disk
    /// gone quiet, or macOS waiting for an answer to its access prompt), said instead of a
    /// placeholder shown for ever. The read goes on, and its result still replaces this.
    private var stalled = false
    private static let stallAfter: TimeInterval = 5
    /// First visible row.
    private var scroll = 0
    private var scrollRemainder: CGFloat = 0
    private var thumbnails: [URL: CGImage] = [:]
    /// What the Videos wall shows of a video besides its picture.
    private struct Facts {
        var length: Double
        /// "180°", "360° · 3D"… (nil for a flat 2D film).
        var badge: String?
        /// The frame's size in pixels, both eyes ("3840 × 1920"; empty if unknown).
        var frame = ""
    }
    private var facts: [URL: Facts] = [:]
    /// A few pictures from along a video, shown in turn while the pointer is on its tile.
    private var previews: [URL: [CGImage]] = [:]
    private var previewsRequested: Set<URL> = []
    /// A folder's first videos' pictures, for its tile, and how many videos it holds.
    private var folderPictures: [URL: [CGImage]] = [:]
    private var folderCounts: [URL: Int] = [:]
    private var foldersRequested: Set<URL> = []

    /// One eye's picture out of a video's frame, and of a picture all around the middle of it:
    /// what tells one video from another on a tile. Also what the name and shape say it is.
    private nonisolated static func tilePicture(_ image: CGImage, name: String) -> (image: CGImage, badge: String?) {
        let format = VideoPlayer.guessFormat(name: name, width: image.width, height: image.height)
        var part = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if format.stereo == 1 { part.size.width /= 2 } else if format.stereo == 2 { part.size.height /= 2 }
        if format.projection == 0 { part = part.insetBy(dx: part.width * 0.3, dy: part.height * 0.2) }
        if format.projection == 1 || format.projection == 2 { part = part.insetBy(dx: part.width * 0.14, dy: part.height * 0.14) }
        var badge: String?
        if format.projection != 3 { badge = ["360°", "180°", "Fisheye"][Int(max(0, min(2, format.projection)))] }
        if format.stereo != 0 { badge = badge.map { "\($0) · 3D" } ?? "3D" }
        return (image.cropping(to: part.integral) ?? image, badge)
    }
    /// The Videos wall's "Continue watching": the videos left unfinished, not a folder.
    private static let unfinished = URL(fileURLWithPath: "/.halliday/continue-watching")
    private var showsUnfinished: Bool { folder == Self.unfinished }
    /// Debug: --videos-folder PATH opens Videos there for this run, and nothing is remembered.
    private static let forcedFolder: URL? = CommandLine.arguments.firstIndex(of: "--videos-folder").flatMap {
        $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil
    }
    // The wall: three tiles across, two rows in view.
    private static let wallColumns = 3, wallRows = 2
    private static let tileGap: CGFloat = 18, tileText: CGFloat = 58
    private var isWall: Bool { mode == .videos }
    /// How many entries are in view, and how many make one step of the scroll.
    private var perPage: Int { isWall ? Self.wallColumns * Self.wallRows : Self.visibleRows }
    private var perStep: Int { isWall ? Self.wallColumns : 1 }
    private var steps: Int { isWall ? (entries.count + Self.wallColumns - 1) / Self.wallColumns : entries.count }
    private var stepsInView: Int { isWall ? Self.wallRows : Self.visibleRows }
    private var inView: ArraySlice<Entry> { entries.dropFirst(scroll * perStep).prefix(perPage) }
    private var thumbnailsRequested: Set<URL> = []
    private var loadGeneration = 0

    /// Debug (`--panel-state loading|empty|error`): shows that moment of the panel, whatever the folder holds.
    private static let forcedState: String? = CommandLine.arguments.firstIndex(of: "--panel-state").flatMap {
        $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
    }

    static let distance: Float = 1.3
    static let below: Float = 4

    // Layout (dmm).
    private static let margin: CGFloat = 24
    private static let width: CGFloat = 1120, height: CGFloat = 680
    private static let sidebar: CGFloat = 220, header: CGFloat = 64, row: CGFloat = 64
    private static var visibleRows: Int { Int((height - header - 12) / row) }
    private var glass: CGRect { CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height) }

    init(renderer: Renderer) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? home
        if let last = UserDefaults.standard.string(forKey: "fileBrowserFolder"), FileManager.default.fileExists(atPath: last) {
            folder = URL(fileURLWithPath: last)
        }
        let size = CGSize(width: Self.width + 2 * Self.margin, height: Self.height + 2 * Self.margin)
        super.init(renderer: renderer, size: size,
                   surface: CGRect(x: Self.margin, y: Self.margin, width: Self.width, height: Self.height))
        onActivate = { [weak self] id in self?.activate(id) }
        reloadPlaces()
        load(folder)
    }

    /// Re-reads the places (volumes come and go) and the current folder, as `mode` (each mode
    /// remembers its own folder), or showing `start` if given.
    func refresh(mode: Mode, start: URL? = nil) {
        if let start, mode == .files {
            self.mode = mode
            folder = start
            thumbnailsRequested = []
        } else if mode != self.mode {
            self.mode = mode
            let key = mode.folderKey
            let fallback = mode == .files ? nil
                : FileManager.default.urls(for: mode == .videos ? .moviesDirectory : .downloadsDirectory, in: .userDomainMask).first
            folder = UserDefaults.standard.string(forKey: key).flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
                ?? fallback ?? FileManager.default.homeDirectoryForCurrentUser
            thumbnailsRequested = []
        }
        if mode == .videos, let forced = Self.forcedFolder { folder = forced }
        reloadPlaces()
        load(folder)
    }

    private func reloadPlaces() {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        var list: [Place] = []
        if mode == .videos, !VideoPlayer.unfinished().isEmpty {
            list.append(Place(name: "Continue watching", symbol: "play.circle", url: Self.unfinished))
        }
        if let u = dir(.moviesDirectory) { list.append(Place(name: "Movies", symbol: "film", url: u)) }
        if let u = dir(.downloadsDirectory) { list.append(Place(name: "Downloads", symbol: "arrow.down.circle", url: u)) }
        if let u = dir(.desktopDirectory) { list.append(Place(name: "Desktop", symbol: "menubar.dock.rectangle", url: u)) }
        if let u = dir(.documentDirectory) { list.append(Place(name: "Documents", symbol: "doc", url: u)) }
        list.append(Place(name: "Home", symbol: "house", url: fm.homeDirectoryForCurrentUser))
        let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeIsInternalKey], options: [.skipHiddenVolumes]) ?? []
        // With `--videos-folder` (screenshots) the disks are left out: their names are the user's.
        for v in volumes where v.path != "/" && Self.forcedFolder == nil {
            let name = (try? v.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? v.lastPathComponent
            list.append(Place(name: name, symbol: "externaldrive", url: v))
        }
        places = Array(list.prefix(8))
    }

    private func load(_ url: URL) {
        folder = url
        if url != Self.unfinished, Self.forcedFolder == nil || mode != .videos { UserDefaults.standard.set(url.path, forKey: mode.folderKey) }
        scroll = 0
        snap("scroll")
        loading = true
        failed = false
        stalled = false
        entries = []
        loadGeneration += 1
        let generation = loadGeneration
        let mode = mode
        setNeedsDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallAfter) { [weak self] in
            guard let self, generation == self.loadGeneration, self.loading else { return }
            self.stalled = true
            log("[files] a folder on \(url.path.hasPrefix("/Volumes/") ? "another disk" : "this Mac's disk") hasn't answered in \(Int(Self.stallAfter)) s")
            self.setNeedsDisplay()
        }
        // (The unfinished videos are read here: their list is in the preferences, not on disk.)
        let unfinished = url == Self.unfinished ? VideoPlayer.unfinished().map { Entry(url: $0, name: $0.lastPathComponent, kind: .video, size: 0) } : nil
        if unfinished == nil {
            Permissions.shared.watchRead(of: url) { [weak self] in self.map { generation == $0.loadGeneration && $0.loading } ?? false }
        }
        Task.detached(priority: .userInitiated) {
            let result = unfinished ?? Self.read(url, mode: mode)
            await MainActor.run { [weak self] in
                if unfinished == nil { Permissions.shared.opened(url) }
                guard let self, generation == self.loadGeneration else { return }
                if self.stalled { log("[files] the folder answered after all") }
                self.loading = false
                self.stalled = false
                self.failed = result == nil
                self.entries = result ?? []
                self.setNeedsDisplay()
                self.requestThumbnails()
            }
        }
    }

    /// Folders first, then videos (or, with `everything`, all files), by name. Nil if the folder
    /// can't be read (no permission, gone).
    private nonisolated static func read(_ url: URL, mode: Mode) -> [Entry]? {
        let everything = mode == .files
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return nil }
        var list: [Entry] = []
        for item in items {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            let type = v.contentType
            if v.isDirectory == true, v.isPackage != true {
                list.append(Entry(url: item, name: item.lastPathComponent, kind: .folder, size: 0))
            } else if mode == .apps {
                if item.pathExtension.lowercased() == "apk" {
                    list.append(Entry(url: item, name: item.lastPathComponent, kind: .other, size: Int64(v.fileSize ?? 0)))
                }
            } else if let type, type.conforms(to: .movie) || type.conforms(to: .video) || item.pathExtension.lowercased() == "mkv" {
                list.append(Entry(url: item, name: item.lastPathComponent, kind: .video, size: Int64(v.fileSize ?? 0)))
            } else if everything {
                let kind: Kind = type?.conforms(to: .image) == true ? .image
                    : (type?.conforms(to: .plainText) == true || ["txt", "md", "log"].contains(item.pathExtension.lowercased())) ? .text : .other
                list.append(Entry(url: item, name: item.lastPathComponent, kind: kind, size: Int64(v.fileSize ?? 0)))
            }
        }
        return list.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Thumbnails for the rows on screen, one at a time.
    private func requestThumbnails() {
        requestFolderPictures()
        let wanted = inView.filter { ($0.kind == .video || $0.kind == .image) && !thumbnailsRequested.contains($0.url) }
        guard !wanted.isEmpty else { return }
        for e in wanted { thumbnailsRequested.insert(e.url) }
        // Pictures: a small version read by ImageIO, off the main thread.
        let pictures = wanted.filter { $0.kind == .image }.map(\.url)
        if !pictures.isEmpty {
            Task.detached(priority: .utility) { [weak self] in
                for url in pictures {
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                    kCGImageSourceThumbnailMaxPixelSize: 192]
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        thumbnails[url] = image
                        if inView.contains(where: { $0.url == url }) { setNeedsDisplay() }
                    }
                }
            }
        }
        let urls = wanted.filter { $0.kind == .video }.map(\.url)
        Task { [weak self] in
            for url in urls {
                let asset = AVURLAsset(url: url)
                let length = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite ? $0 : nil } ?? 0
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                // Large enough for a tile of the wall after one eye is cut out of a 3D frame.
                generator.maximumSize = CGSize(width: 1100, height: 620)
                generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
                guard var image = try? await generator.image(at: CMTime(seconds: length > 0 ? min(10, length / 2) : 10, preferredTimescale: 600)).image
                else { continue }
                let badge: String?
                (image, badge) = Self.tilePicture(image, name: url.lastPathComponent)
                var frame = ""
                if let track = try? await asset.loadTracks(withMediaType: .video).first, let size = try? await track.load(.naturalSize), size.width > 0 {
                    frame = "\(Int(size.width)) × \(Int(size.height))"
                }
                guard let self else { return }
                self.thumbnails[url] = image
                self.facts[url] = Facts(length: length, badge: badge, frame: frame)
                if self.inView.contains(where: { $0.url == url }) { self.setNeedsDisplay() }
            }
        }
    }

    /// Three pictures from along a video (a quarter, a half, three quarters in), for the tile
    /// under the pointer.
    private func requestPreviews(_ url: URL) {
        guard previewsRequested.insert(url).inserted else { return }
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let length = try? await asset.load(.duration).seconds, length.isFinite, length > 8 else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1100, height: 620)
            // Near enough is good enough, and far quicker than the exact frame.
            generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
            var pictures: [CGImage] = []
            for part in [0.25, 0.5, 0.75] {
                guard let image = try? await generator.image(at: CMTime(seconds: length * part, preferredTimescale: 600)).image else { continue }
                pictures.append(Self.tilePicture(image, name: url.lastPathComponent).image)
            }
            guard let self, !pictures.isEmpty else { return }
            self.previews[url] = pictures
            if self.inView.contains(where: { $0.url == url }) { self.setNeedsDisplay() }
        }
    }

    /// The first four videos of the folders in view, for their tiles.
    private func requestFolderPictures() {
        guard isWall else { return }
        for folder in inView.filter(\.isFolder).map(\.url) where foldersRequested.insert(folder).inserted {
            Task { [weak self] in
                let videos = await Task.detached(priority: .utility) { (Self.read(folder, mode: .videos) ?? []).filter { $0.kind == .video }.map(\.url) }.value
                var pictures: [CGImage] = []
                for url in videos.prefix(4) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 560, height: 320)
                    generator.requestedTimeToleranceBefore = CMTime(seconds: 5, preferredTimescale: 600)
                    generator.requestedTimeToleranceAfter = CMTime(seconds: 5, preferredTimescale: 600)
                    // Ten seconds in, or the start of a video shorter than that.
                    var image = try? await generator.image(at: CMTime(seconds: 10, preferredTimescale: 600)).image
                    if image == nil { image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image }
                    guard let image else { continue }
                    pictures.append(Self.tilePicture(image, name: url.lastPathComponent).image)
                }
                guard let self else { return }
                self.folderCounts[folder] = videos.count
                self.folderPictures[folder] = pictures
                if self.inView.contains(where: { $0.url == folder }) { self.setNeedsDisplay() }
            }
        }
    }

    /// Scrolls the list (mouse wheel or stick); `dy` in points, positive = content moves down.
    func scroll(by dy: CGFloat) {
        scrollRemainder -= dy
        let rows = Int(scrollRemainder / 24)
        guard rows != 0 else { return }
        scrollRemainder -= CGFloat(rows) * 24
        setScroll(scroll + rows)
    }

    private func setScroll(_ value: Int) {
        let clamped = max(0, min(max(0, steps - stepsInView), value))
        guard clamped != scroll else { return }
        scroll = clamped
        setNeedsDisplay()
        requestThumbnails()
    }

    private func activate(_ id: String) {
        if id.hasPrefix("place:"), let i = Int(id.dropFirst(6)), places.indices.contains(i) {
            load(places[i].url)
        } else if id.hasPrefix("row:"), let i = Int(id.dropFirst(4)), entries.indices.contains(i) {
            let e = entries[i]
            switch e.kind {
            case .folder: load(e.url)
            case .video: onOpen?(e.url)
            case .image: onOpenImage?(e.url, entries.filter { $0.kind == .image }.map(\.url))
            case .text: onOpenText?(e.url)
            case .other: onOpenOther?(e.url)
            }
        } else {
            switch id {
            case "up": if folder.path != "/", !showsUnfinished { load(folder.deletingLastPathComponent()) }
            case "close": onClose?()
            case "retry": load(folder)
            case "elsewhere":
                let fm = FileManager.default
                let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
                if let other = folder.path == downloads?.path ? fm.urls(for: .moviesDirectory, in: .userDomainMask).first : downloads { load(other) }
            case "pageup": setScroll(scroll - max(1, stepsInView - (isWall ? 0 : 1))); setNeedsDisplay(fade: true)
            case "pagedown": setScroll(scroll + max(1, stepsInView - (isWall ? 0 : 1))); setNeedsDisplay(fade: true)
            default: break
            }
        }
    }

    // --- Drawing ---

    override func drawBackground(in ctx: CGContext) {
        drawGlass(ctx, glass, radius: NightGlass.panelRadius, solid: true)
    }

    override func draw(in ctx: CGContext) {
        let g = glass

        // Places.
        var y = g.minY + 20
        NightGlass.drawText(mode == .videos ? "Videos" : mode == .files ? "Files" : "Install an app", at: CGPoint(x: g.minX + 24, y: y), style: .title)
        y += 44
        for (i, place) in places.enumerated() {
            let id = "place:\(i)"
            let rect = CGRect(x: g.minX + 12, y: y, width: Self.sidebar - 20, height: 44)
            let current = folder.path == place.url.path
            row(ctx, id, rect, radius: 22, rest: current ? 0.13 : 0)
            let color = current ? NightGlass.text : NightGlass.secondary
            NightGlass.drawSymbol(place.symbol, in: CGRect(x: rect.minX + 10, y: rect.minY, width: 24, height: 44), size: 14, color: color, weight: .medium)
            let h = NightGlass.textSize("Ag", style: .label).height
            NightGlass.drawText(place.name, at: CGPoint(x: rect.minX + 42, y: rect.midY - h / 2), style: .label, color: color,
                                weight: current ? .medium : .regular, width: rect.width - 52)
            y += 48
        }
        ctx.setFillColor(NightGlass.hairline.cgColor)
        ctx.fill(CGRect(x: g.minX + Self.sidebar, y: g.minY + 16, width: 1, height: g.height - 32))

        // Header: up, folder name, close.
        let left = g.minX + Self.sidebar + 16, right = g.maxX - 16
        let headerMid = g.minY + Self.header / 2 + 4
        iconButton(ctx, "up", "chevron.left", CGRect(x: left, y: headerMid - 20, width: 40, height: 40), enabled: folder.path != "/" && !showsUnfinished)
        let title = showsUnfinished ? "Continue watching" : folder.path == "/" ? "Macintosh HD" : folder.lastPathComponent
        let titleHeight = NightGlass.textSize("Ag", style: .title).height
        NightGlass.drawText(title, at: CGPoint(x: left + 50, y: headerMid - titleHeight / 2), style: .title, width: right - left - 200)
        iconButton(ctx, "close", "xmark", CGRect(x: right - 40, y: headerMid - 20, width: 40, height: 40), symbolSize: 14, quiet: true)
        let pages = steps > stepsInView
        if pages {
            iconButton(ctx, "pagedown", "chevron.down", CGRect(x: right - 88, y: headerMid - 20, width: 40, height: 40),
                       enabled: scroll + stepsInView < steps)
            iconButton(ctx, "pageup", "chevron.up", CGRect(x: right - 132, y: headerMid - 20, width: 40, height: 40), enabled: scroll > 0)
        }

        // List.
        let listTop = g.minY + Self.header + 8
        let area = CGRect(x: left, y: listTop, width: right - left, height: g.maxY - listTop - 16)
        let loading = loading || Self.forcedState == "loading", failed = failed || Self.forcedState == "error"
        let entries = Self.forcedState == "empty" ? [] : entries
        if loading, stalled {
            let other = folder.path.hasPrefix("/Volumes/")
            message(ctx, in: area, symbol: "exclamationmark.triangle", title: other ? "This disk isn't answering" : "This folder isn't answering",
                    detail: other ? "macOS may be asking on the Mac's screen whether Halliday can open it. If not, eject the disk and connect it again, or choose another place."
                        : "macOS may be asking on the Mac's screen whether Halliday can open it. Allow it there, or choose another place.",
                    action: ("retry", "Try again"), problem: true)
            return
        }
        if loading {
            skeletonRows(ctx, in: area, rowHeight: Self.row, thumbnail: CGSize(width: 86, height: Self.row - 16))
            return
        }
        if failed {
            let name = folder.path == "/" ? "this disk" : folder.lastPathComponent
            message(ctx, in: area, symbol: "lock", title: "macOS hasn't let Halliday open \(name)",
                    detail: "It asks once, on the Mac's screen. Allow it there, then try again.", action: ("retry", "Try again"), problem: true)
            return
        }
        if entries.isEmpty, showsUnfinished {
            message(ctx, in: area, symbol: "play.circle", title: "Nothing left unfinished",
                    detail: "A video you stop partway shows here, ready to go on from where you left it.")
            return
        }
        if entries.isEmpty {
            // The way out: the other place videos usually are.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            let elsewhere = folder.path == downloads?.path ? "Movies" : "Downloads"
            if mode == .videos {
                message(ctx, in: area, symbol: "play.rectangle", title: "No videos in this folder",
                        detail: "Folders and videos you keep here show up as soon as they are added.", action: ("elsewhere", "Look in \(elsewhere)"))
            } else if mode == .apps {
                message(ctx, in: area, symbol: "square.and.arrow.down", title: "No app files in this folder",
                        detail: "Apps made for standalone headsets come as .apk files. Choose one and Halliday installs it into Games.",
                        action: ("elsewhere", "Look in \(elsewhere)"))
            } else {
                message(ctx, in: area, symbol: "folder", title: "This folder is empty",
                        detail: "Files and folders you keep here show up as soon as they are added.", action: ("elsewhere", "Look in \(elsewhere)"))
            }
            return
        }
        if isWall {
            drawWall(ctx, entries, in: area)
            if pages {
                let text = "\(scroll * perStep + 1)–\(min(entries.count, scroll * perStep + perPage)) of \(entries.count)"
                let size = NightGlass.textSize(text, style: .caption)
                NightGlass.drawText(text, at: CGPoint(x: right - 144 - size.width, y: headerMid - size.height / 2), style: .caption, color: NightGlass.tertiary, tabular: true)
            }
            return
        }
        // The list, clipped to its area.
        // (Scrolling is instant: a glide redrew the whole panel every frame, too slow for 120 Hz; the
        // page buttons cross-fade instead. A glide on the GPU is for later.)
        let offset = CGFloat(scroll)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: left - 4, y: listTop, width: right - left + 8, height: CGFloat(Self.visibleRows) * Self.row))
        let first = max(0, Int(offset.rounded(.down)))
        for index in first..<max(first, min(entries.count, Int(offset.rounded(.up)) + Self.visibleRows)) {
            let e = entries[index]
            let id = "row:\(index)"
            let rect = CGRect(x: left, y: listTop + (CGFloat(index) - offset) * Self.row, width: right - left, height: Self.row - 4)
            row(ctx, id, rect)
            // Thumbnail (16:9) or a folder / film icon.
            let thumb = CGRect(x: rect.minX + 8, y: rect.minY + 6, width: 86, height: rect.height - 12)
            if e.isFolder {
                NightGlass.drawSymbol("folder.fill", in: thumb, size: 22, color: NightGlass.accent)
            } else if let image = thumbnails[e.url] {
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 8, cornerHeight: 8, transform: nil))
                ctx.clip()
                // Aspect fill, upright in the flipped context.
                let scale = max(thumb.width / CGFloat(image.width), thumb.height / CGFloat(image.height))
                let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                ctx.translateBy(x: thumb.midX - w / 2, y: thumb.midY + h / 2)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                ctx.restoreGState()
            } else {
                NightGlass.fill(ctx, thumb, radius: 8, color: NSColor(white: 1, alpha: 0.06))
                let symbol = switch e.kind {
                case .image: "photo"
                case .text: "doc.text"
                case .other: "doc"
                default: "film"
                }
                NightGlass.drawSymbol(symbol, in: thumb, size: 16, color: NightGlass.tertiary)
            }
            let textX = thumb.maxX + 14, textWidth = rect.maxX - textX - 16
            if e.isFolder {
                let h = NightGlass.textSize("Ag", style: .body).height
                NightGlass.drawText(e.name, at: CGPoint(x: textX, y: rect.midY - h / 2), style: .body, width: textWidth)
            } else {
                NightGlass.drawText(e.name, at: CGPoint(x: textX, y: rect.minY + 9), style: .body, width: textWidth)
                // A package (a library, a bundle) has no single size: only its kind is shown.
                let kind = e.url.pathExtension.uppercased()
                let detail = e.size > 0 ? "\(kind) · \(ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))" : (kind.isEmpty ? "File" : kind)
                NightGlass.drawText(detail, at: CGPoint(x: textX, y: rect.minY + 33), style: .caption, color: NightGlass.secondary, width: textWidth)
            }
        }
        ctx.restoreGState()
        if pages {
            let text = "\(scroll + 1)–\(min(entries.count, scroll + Self.visibleRows)) of \(entries.count)"
            let size = NightGlass.textSize(text, style: .caption)
            NightGlass.drawText(text, at: CGPoint(x: right - 144 - size.width, y: headerMid - size.height / 2), style: .caption, color: NightGlass.tertiary, tabular: true)
        }
    }

    // --- The Videos wall ---

    /// Videos as large tiles, three across: the picture (one eye's, for a 3D video), what kind
    /// of video it is, its length, how far it was watched, and its name under it. Folders are
    /// tiles among them.
    private func drawWall(_ ctx: CGContext, _ entries: [Entry], in area: CGRect) {
        let columns = CGFloat(Self.wallColumns)
        let tileWidth = (area.width - Self.tileGap * (columns - 1)) / columns
        let thumbHeight = (area.height - Self.tileGap * CGFloat(Self.wallRows - 1)) / CGFloat(Self.wallRows) - Self.tileText
        let first = scroll * perStep
        for index in first..<min(entries.count, first + perPage) {
            let e = entries[index]
            let k = index - first
            let x = area.minX + CGFloat(k % Self.wallColumns) * (tileWidth + Self.tileGap)
            let y = area.minY + CGFloat(k / Self.wallColumns) * (thumbHeight + Self.tileText + Self.tileGap)
            let tile = CGRect(x: x, y: y, width: tileWidth, height: thumbHeight + Self.tileText)
            row(ctx, "row:\(index)", tile.insetBy(dx: -6, dy: -6), radius: 20)
            let thumb = CGRect(x: x, y: y, width: tileWidth, height: thumbHeight)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: thumb, cornerWidth: 14, cornerHeight: 14, transform: nil))
            ctx.clip()
            let hot = hovered == "row:\(index)" && !e.isFolder
            if e.isFolder, let pictures = folderPictures[e.url], !pictures.isEmpty {
                // The folder's first videos, two by two (one alone fills the tile).
                ctx.setFillColor(NSColor(white: 0, alpha: 0.35).cgColor)
                ctx.fill(thumb)
                let gap: CGFloat = 3
                let across = pictures.count == 1 ? 1 : 2, down = pictures.count <= 2 ? 1 : 2
                let cw = (thumb.width - gap * CGFloat(across - 1)) / CGFloat(across), ch = (thumb.height - gap * CGFloat(down - 1)) / CGFloat(down)
                for (k, picture) in pictures.prefix(4).enumerated() {
                    Self.fill(ctx, CGRect(x: thumb.minX + CGFloat(k % across) * (cw + gap), y: thumb.minY + CGFloat(k / across) * (ch + gap), width: cw, height: ch),
                              with: picture)
                }
                let chip = CGRect(x: thumb.minX + 10, y: thumb.minY + 10, width: 34, height: 26)
                NightGlass.fill(ctx, chip, radius: 13, color: NSColor(white: 0, alpha: 0.55))
                NightGlass.drawSymbol("folder.fill", in: chip, size: 12, color: NightGlass.text)
            } else if e.isFolder {
                ctx.setFillColor(NightGlass.accent.withAlphaComponent(0.10).cgColor)
                ctx.fill(thumb)
                NightGlass.drawSymbol("folder.fill", in: thumb, size: 54, color: NightGlass.accent)
            } else if let image = thumbnails[e.url] {
                // Under the pointer: pictures from along the video, in turn.
                var shown = image
                if hot {
                    if let pictures = previews[e.url] {
                        let now = CACurrentMediaTime(), each = 0.9
                        shown = pictures[Int(now / each) % pictures.count]
                        redraw(at: (now / each).rounded(.down) * each + each + 0.01)
                    } else {
                        requestPreviews(e.url)
                    }
                }
                Self.fill(ctx, thumb, with: shown)
            } else {
                ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
                ctx.fill(thumb)
                NightGlass.drawSymbol("film", in: thumb, size: 34, color: NightGlass.tertiary)
            }
            if !e.isFolder {
                let known = facts[e.url]
                let kept = VideoPlayer.resume(for: e.url)
                // Along the bottom, on a shade so they read on any picture: how far it was
                // watched, and its length.
                let length = known?.length ?? kept?.length ?? 0
                if length > 0 || kept != nil {
                    let shade = CGGradient(colorsSpace: nil, colors: [NSColor(white: 0, alpha: 0).cgColor, NSColor(white: 0, alpha: 0.62).cgColor] as CFArray,
                                           locations: [0, 1])
                    if let shade { ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: thumb.maxY - 64), end: CGPoint(x: 0, y: thumb.maxY), options: []) }
                }
                if length > 0 {
                    let text = Self.clock(Int(length))
                    let size = NightGlass.textSize(text, style: .caption, weight: .semibold, tabular: true)
                    NightGlass.drawText(text, at: CGPoint(x: thumb.maxX - size.width - 12, y: thumb.maxY - size.height - 12), style: .caption,
                                        color: NightGlass.text, weight: .semibold, tabular: true)
                }
                if let kept, length > 0, kept.position > 0 {
                    let track = CGRect(x: thumb.minX, y: thumb.maxY - 5, width: thumb.width, height: 5)
                    ctx.setFillColor(NSColor(white: 1, alpha: 0.25).cgColor)
                    ctx.fill(track)
                    ctx.setFillColor(NightGlass.accent.cgColor)
                    ctx.fill(CGRect(x: track.minX, y: track.minY, width: track.width * CGFloat(min(1, kept.position / length)), height: track.height))
                }
                // Under the pointer, also the frame's size.
                let badge = [known?.badge, hot ? known?.frame : nil].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                if !badge.isEmpty {
                    let size = NightGlass.textSize(badge, style: .caption, weight: .semibold)
                    let chip = CGRect(x: thumb.minX + 10, y: thumb.minY + 10, width: size.width + 18, height: 24)
                    NightGlass.fill(ctx, chip, radius: 12, color: NSColor(white: 0, alpha: 0.55))
                    NightGlass.drawText(badge, at: CGPoint(x: chip.minX + 9, y: chip.midY - size.height / 2), style: .caption, color: NightGlass.text, weight: .semibold)
                }
            }
            ctx.restoreGState()
            // The name without its extension, on two lines at most; what is left to watch under it.
            let name = e.isFolder ? e.name : e.url.deletingPathExtension().lastPathComponent
            let lines = NightGlass.wrap(name, style: .label, width: tileWidth - 8)
            var ty = thumb.maxY + 9
            let kept = e.isFolder ? nil : VideoPlayer.resume(for: e.url)
            for line in lines.prefix(kept == nil ? 2 : 1) {
                NightGlass.drawText(line, at: CGPoint(x: x + 4, y: ty), style: .label, weight: .medium, width: tileWidth - 8)
                ty += 20
            }
            if let kept, kept.length > kept.position {
                NightGlass.drawText("\(Self.clock(Int(kept.length - kept.position))) left", at: CGPoint(x: x + 4, y: ty + 1), style: .caption,
                                    color: NightGlass.accent, tabular: true)
            } else if e.isFolder, let count = folderCounts[e.url] {
                NightGlass.drawText(count == 0 ? "No videos" : count == 1 ? "1 video" : "\(count) videos", at: CGPoint(x: x + 4, y: ty + 1),
                                    style: .caption, color: NightGlass.secondary)
            }
        }
    }

    /// Draws `image` filling `rect` (cropped to its shape), upright in the panel's flipped context.
    private static func fill(_ ctx: CGContext, _ rect: CGRect, with image: CGImage) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.midX - w / 2, y: rect.midY + h / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    private static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

}
