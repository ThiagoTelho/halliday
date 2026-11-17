// A Quest app's own folder in Halliday's, and what may be done in it (ROADMAP W15.3): paths kept
// inside it, downloads into it, unzipping and unpacking. Shared by the app's web half
// (`QuestAppWeb.swift`, Capacitor's standard `Filesystem`) and its extensions
// (`ExtensionHost.swift`, `halliday.files`).
//
// Downloads are network code of Halliday's, on the app's behalf and only while the user has the
// app open (tools/check-privacy.sh, PRIVACY.md): an extension's only to the hosts its manifest
// lists.

import Foundation

/// A call refused, with why: what the page or the extension is told.
struct AppRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
final class QuestAppFiles {
    /// The app's own data: the only folder its page and its extensions may use.
    let data: URL
    /// The origin an Android web view would have given the app's page (what its servers allow).
    let origin: String
    /// One session for the app, with the cookies its servers set (kept, as a browser keeps them).
    let http = URLSession(configuration: .default)

    static let verbose = CommandLine.arguments.contains("--ui-log") || CommandLine.arguments.contains("--app-web-log")

    init(data: URL, origin: String) {
        self.data = data.standardizedFileURL
        self.origin = origin
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    }

    // --- Paths ---

    /// An absolute path, a `file://` address, or a path relative to the app's data, kept inside it.
    func inside(_ path: String) throws -> URL {
        // As it comes back from a page: with or without `file://`, and with or without the
        // percent signs an address has (Halliday's folder has a space in its path, which an
        // Android path never has: the page strips `file://` and hands the rest on as a path).
        let bare = path.hasPrefix("file://") ? String(path.dropFirst(7)) : path
        for candidate in [bare, bare.removingPercentEncoding ?? bare] {
            let file = (candidate.hasPrefix("/") ? URL(fileURLWithPath: candidate) : data.appendingPathComponent(candidate)).standardizedFileURL
            if file.path == data.path || file.path.hasPrefix(data.path + "/") { return file }
        }
        throw AppRefusal(message: "That path is outside the app's own folder")
    }

    /// A file's address for a page: `file://` and the path as it is, not percent-encoded, so
    /// that what the page (and, through it, the player) makes of it is a path that opens.
    func address(_ file: URL) -> String { "file://" + file.path }

    // --- Downloads ---

    final class Download {
        let id = UUID().uuidString.lowercased()
        let url: String
        let target: URL
        var task: URLSessionDownloadTask!
        var received: Int64 = 0
        /// How much of `received` the page has been told of (for callers that report steps).
        var told: Int64 = 0
        var expected: Int64 = 0
        var speed: Double = 0
        var report: (Download, String, String?) -> Void = { _, _, _ in }
        init(url: String, target: URL) {
            self.url = url
            self.target = target
        }
    }

    private(set) var downloads: [String: Download] = [:]
    private var downloadTimer: Timer?

    /// Fetches `address` (http or https) into `target`, a file inside the app's folder. `report`
    /// is called twice a second while it runs ("downloading") and once at its end ("completed",
    /// "failed" or "cancelled", with why). Returns the download's id.
    func download(_ address: String, to target: URL, headers: [String: Any],
                  report: @escaping (Download, String, String?) -> Void) throws -> String {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AppRefusal(message: "Not an http address")
        }
        var r = URLRequest(url: url)
        for (name, value) in headers { if let value = value as? String { r.setValue(value, forHTTPHeaderField: name) } }
        r.setValue(origin, forHTTPHeaderField: "Origin")
        let d = Download(url: address, target: target)
        d.report = report
        let id = d.id
        d.task = http.downloadTask(with: r) { [weak self] file, response, error in
            // The file is gone when this returns: moved into place here, then told of on the main actor.
            var failure = error.map { ($0 as NSError).code == NSURLErrorCancelled ? "cancelled" : $0.localizedDescription }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if failure == nil, !(200..<300).contains(status) { failure = "The server answered \(status)" }
            if failure == nil, let file {
                do {
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.moveItem(at: file, to: target)
                } catch {
                    failure = error.localizedDescription
                }
            }
            let ended = failure
            Task { @MainActor in
                guard let self, let d = self.downloads.removeValue(forKey: id) else { return }
                d.received = d.task.countOfBytesReceived
                d.expected = max(d.task.countOfBytesExpectedToReceive, d.received)
                if Self.verbose || ended != nil {
                    log("[app-web] download of \(url.lastPathComponent): \(ended ?? "done"), \(d.received) bytes")
                }
                d.report(d, ended == nil ? "completed" : (ended == "cancelled" ? "cancelled" : "failed"), ended)
                if self.downloads.isEmpty {
                    self.downloadTimer?.invalidate()
                    self.downloadTimer = nil
                }
            }
        }
        downloads[id] = d
        d.task.resume()
        if downloadTimer == nil {
            downloadTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    for d in self?.downloads.values.map({ $0 }) ?? [] {
                        let now = d.task.countOfBytesReceived
                        d.speed = Double(now - d.received) * 2
                        d.received = now
                        d.expected = max(d.task.countOfBytesExpectedToReceive, now)
                        d.report(d, "downloading", nil)
                    }
                }
            }
        }
        return id
    }

    func cancel(_ id: String) { downloads[id]?.task.cancel() }

    /// Stops every download (the app's page closed).
    func cancelAll() { for d in downloads.values { d.task.cancel() } }

    // --- Archives ---

    /// Unzips `zip` into `folder`, both inside the app's folder, off the main thread.
    func unzip(_ zip: URL, to folder: URL, done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                p.arguments = ["-q", "-o", zip.path, "-d", folder.path]
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus > 1 { failure = "The archive couldn't be unpacked" }
            } catch {
                failure = error.localizedDescription
            }
            let result = failure
            Task { @MainActor in done(result) }
        }
    }

    /// Unpacks `source` into `target`, both in the app's folder: xz, Zstandard and OpenZL (one
    /// frame, or a file cut in pieces of a frame each), all by Halliday's own `unzl` in the bundle
    /// (tools/unzl.c, `make unzl`; macOS carries neither xz nor zstd), found from the file's first
    /// bytes. `progress` gets a percentage now and then, `done` nil or why it failed.
    func unpack(_ source: URL, to target: URL, kind: String = "", progress: @escaping @MainActor (Int) -> Void,
                done: @escaping @MainActor (String?) -> Void) throws {
        let magic = (try? FileHandle(forReadingFrom: source))?.readData(ofLength: 6) ?? Data()
        let format: String?
        if magic.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            format = "xz"
        } else if magic.starts(with: [0x28, 0xB5, 0x2F, 0xFD]) {
            format = "zstd"
        } else if magic.starts(with: Array("SANT".utf8))
                    || (magic.count >= 4 && magic[0] & 0xC0 == 0xC0 && magic[1...3].elementsEqual([0xA5, 0xB1, 0xD7])) {
            // A file in pieces, or one OpenZL frame (its number's low bits are the format's version).
            format = "openzl"
        } else {
            format = nil
        }
        log("[app-web] unpack, kind \"\(kind)\", starts \(magic.map { String(format: "%02x", $0) }.joined()), \(format ?? "no tool for it")")
        guard format != nil else {
            throw AppRefusal(message: "This content is packed in a way Halliday can't unpack yet (kind \(kind.isEmpty ? "unknown" : kind))")
        }
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("quest/unzl").path,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw AppRefusal(message: "Unpacking this content needs Halliday's unpacker, which this build doesn't carry (make unzl)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.standardError = FileHandle.nullDevice
        // It writes the file itself and says how far it is, a percentage a line.
        let said = Pipe()
        p.arguments = [source.path, target.path]
        p.standardOutput = said
        said.fileHandleForReading.readabilityHandler = { handle in
            let lines = String(decoding: handle.availableData, as: UTF8.self).split(separator: "\n")
            guard let percent = lines.last.flatMap({ Int($0) }), percent < 100 else { return }
            Task { @MainActor in progress(percent) }
        }
        p.terminationHandler = { done_ in
            said.fileHandleForReading.readabilityHandler = nil
            let status = done_.terminationStatus
            Task { @MainActor in done(status == 0 ? nil : "The content couldn't be unpacked") }
        }
        try p.run()
    }
}
