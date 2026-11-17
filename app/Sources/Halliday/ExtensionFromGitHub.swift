// An extension from a GitHub link (docs/extensions.md, "Installing from GitHub"): the user pastes
// the address of a repository, or of a folder in one, and Halliday fetches that repository's
// archive once, unpacks it in a temporary folder and finds the extension in it. What happens next
// is what happens for a folder on the Mac: the manifest is checked and the user sees what the
// extension is before anything is installed.
//
// This is network code of Halliday's (tools/check-privacy.sh, PRIVACY.md), started only by the
// user's own request: one download from github.com (redirected to codeload.github.com, its
// archive server, and to nothing else), without cookies, at most 25 MB. Nothing is sent but the
// request for that archive. No updates, no store: a link is fetched when the user gives it.
//
// Links understood:
//   https://github.com/OWNER/REPO                     its default branch, the extension at the top
//                                                     (or in the one folder of it that holds one)
//   https://github.com/OWNER/REPO/tree/REF            a branch, tag or commit
//   https://github.com/OWNER/REPO/tree/REF/PATH       the extension in that folder
// with or without https://, www. or a trailing .git. A branch whose name has a slash in it can't
// be told from a folder: link to a tag or a commit instead.

import Foundation

/// Where an extension came from on GitHub.
struct GitHubSource: Equatable, Sendable, Codable {
    let owner: String
    let repo: String
    /// A branch, tag or commit; nil: the default branch.
    let ref: String?
    /// The extension's folder inside the repository ("" for its top).
    let path: String

    var display: String {
        "github.com/\(owner)/\(repo)" + (ref.map { "/tree/\($0)" } ?? "") + (path.isEmpty ? "" : (ref == nil ? "/tree/HEAD/" : "/") + path)
    }

    var archive: URL { URL(string: "https://github.com/\(owner)/\(repo)/archive/\(ref ?? "HEAD").zip")! }

    /// The source a link names, or nil when it isn't a GitHub repository's address.
    static func parse(_ text: String) -> GitHubSource? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        if t.lowercased().hasPrefix("www.") { t = String(t.dropFirst(4)) }
        guard t.lowercased().hasPrefix("github.com/") else { return nil }
        t = String(t.dropFirst("github.com/".count))
        if let cut = t.firstIndex(where: { $0 == "?" || $0 == "#" }) { t = String(t[..<cut]) }
        var parts = t.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let name = #"^[A-Za-z0-9._-]+$"#
        let owner = parts.removeFirst()
        var repo = parts.removeFirst()
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard owner.range(of: name, options: .regularExpression) != nil, repo.range(of: name, options: .regularExpression) != nil,
              !owner.hasPrefix("."), !repo.hasPrefix(".") else { return nil }
        guard !parts.isEmpty else { return GitHubSource(owner: owner, repo: repo, ref: nil, path: "") }
        guard parts.count >= 2, parts[0] == "tree", parts[1].range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return nil }
        let path = parts.dropFirst(2)
        guard path.allSatisfy({ $0 != ".." && $0 != "." }) else { return nil }
        return GitHubSource(owner: owner, repo: repo, ref: parts[1], path: path.joined(separator: "/"))
    }
}

enum ExtensionFromGitHub {
    static let largest: Int64 = 25 * 1024 * 1024

    /// Fetches `source`'s archive and returns the folder holding the extension (`folder`), inside
    /// `temporary`, a folder made for this fetch alone, which the caller deletes after installing.
    static func fetch(_ source: GitHubSource) async throws -> (folder: URL, temporary: URL) {
        let session = URLSession(configuration: .ephemeral, delegate: OnlyGitHub(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: source.archive, timeoutInterval: 60)
        request.setValue("Halliday", forHTTPHeaderField: "User-Agent")
        log("[extensions] fetching \(source.display)")
        let (file, response): (URL, URLResponse)
        do {
            (file, response) = try await session.download(for: request)
        } catch {
            throw ExtensionError.failed("GitHub couldn't be reached: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ExtensionError.failed(status == 404
                ? "There is no public repository (or branch) at \(source.display)."
                : "GitHub answered \(status) for \(source.display).")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= largest else { throw ExtensionError.failed("That repository is larger than 25 MB: too large to be an extension.") }

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("halliday-extension-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            return (try find(source, unpacking: file, into: out), out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// Unpacks the archive into `out` and finds the extension in it.
    private static func find(_ source: GitHubSource, unpacking file: URL, into out: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, out.path]
        try p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: file)
        guard p.terminationStatus == 0 else { throw ExtensionError.failed("GitHub's archive of \(source.display) couldn't be unpacked.") }

        // The archive holds one folder, REPO-REF, with the repository in it.
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: out, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.hasDirectoryPath } ?? []
        guard top.count == 1, let repository = top.first else { throw ExtensionError.failed("GitHub's archive of \(source.display) isn't laid out as expected.") }
        let start = (source.path.isEmpty ? repository : repository.appendingPathComponent(source.path)).standardizedFileURL
        guard start.path.hasPrefix(repository.standardizedFileURL.path) else { throw ExtensionError.notAnExtension }
        if fm.fileExists(atPath: start.appendingPathComponent("manifest.json").path) { return start }
        guard source.path.isEmpty else {
            throw ExtensionError.failed("There is no manifest.json in \(source.display).")
        }
        // Not at the top: the one folder of it that holds an extension.
        let holding = ((try? fm.contentsOfDirectory(at: repository, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.hasDirectoryPath && fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if holding.count == 1 { return holding[0] }
        if holding.isEmpty { throw ExtensionError.failed("\(source.display) holds no extension (no manifest.json at its top, nor in a folder of it).") }
        throw ExtensionError.failed("\(source.display) holds several extensions: link to the one you want, as github.com/\(source.owner)/\(source.repo)/tree/BRANCH/FOLDER. Its folders with one: "
                                    + holding.prefix(6).map(\.lastPathComponent).joined(separator: ", ") + ".")
    }

    /// Redirects only to GitHub's own archive server.
    private final class OnlyGitHub: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard request.url?.scheme == "https", ["github.com", "codeload.github.com"].contains(request.url?.host ?? "") else {
                log("[extensions] a redirect to \(request.url?.host ?? "?") was not followed")
                return nil
            }
            return request
        }
    }
}
