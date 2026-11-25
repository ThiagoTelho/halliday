// The browser's memory (ROADMAP W11 A.7): visited pages and bookmarks, kept in a JSON file in
// Application Support. Pages opened in private tabs are never recorded. It feeds the address bar's
// suggestions and the start page.

import Foundation

@MainActor
final class BrowserHistory {
    static let shared = BrowserHistory()

    struct Page: Codable, Equatable {
        var url: String
        var title: String
        var visits = 1
        var lastVisit = Date()
    }

    struct Suggestion: Equatable {
        enum Kind { case bookmark, history, search }
        let kind: Kind
        let title: String
        let url: URL
    }

    private struct Store: Codable {
        var history: [Page] = []
        var bookmarks: [Page] = []
    }

    private var store = Store()
    private let file: URL
    private var saveScheduled = false

    private init() {
        let dir = RuntimePaths.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("browser.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Store.self, from: data) { store = saved }
    }

    var bookmarks: [Page] { store.bookmarks }
    /// Most recent first.
    var recent: [Page] { store.history.sorted { $0.lastVisit > $1.lastVisit } }

    /// Records a visit (http/https pages only).
    func record(url: URL, title: String) {
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }
        let key = url.absoluteString
        if let i = store.history.firstIndex(where: { $0.url == key }) {
            store.history[i].visits += 1
            store.history[i].lastVisit = Date()
            if !title.isEmpty { store.history[i].title = title }
        } else {
            store.history.append(Page(url: key, title: title))
            if store.history.count > 2000 { store.history = Array(recent.prefix(1500)) }
        }
        save()
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let key = url?.absoluteString else { return false }
        return store.bookmarks.contains { $0.url == key }
    }

    /// Adds or removes a bookmark. Returns true if the page is bookmarked afterwards.
    @discardableResult
    func toggleBookmark(url: URL, title: String) -> Bool {
        let key = url.absoluteString
        if let i = store.bookmarks.firstIndex(where: { $0.url == key }) {
            store.bookmarks.remove(at: i)
            save()
            return false
        }
        store.bookmarks.append(Page(url: key, title: title.isEmpty ? (url.host ?? key) : title))
        save()
        return true
    }

    func clearHistory() {
        store.history = []
        save()
    }

    /// What to offer for `text` typed in the address bar: bookmarks and visited pages whose address
    /// or title match (most used first), then a web search.
    func suggestions(for text: String, limit: Int = 5) -> [Suggestion] {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        func matches(_ p: Page) -> Bool {
            let bare = p.url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "www.", with: "").lowercased()
            return bare.hasPrefix(t) || bare.contains(t) || p.title.lowercased().contains(t)
        }
        var out: [Suggestion] = []
        var seen: Set<String> = []
        for p in store.bookmarks where matches(p) {
            if let u = URL(string: p.url), seen.insert(p.url).inserted { out.append(Suggestion(kind: .bookmark, title: p.title, url: u)) }
        }
        for p in store.history.filter(matches).sorted(by: { ($0.visits, $0.lastVisit) > ($1.visits, $1.lastVisit) }) {
            if let u = URL(string: p.url), seen.insert(p.url).inserted { out.append(Suggestion(kind: .history, title: p.title, url: u)) }
        }
        out = Array(out.prefix(limit - 1))
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: text)]
        if let u = c.url { out.append(Suggestion(kind: .search, title: "Search for “\(text)”", url: u)) }
        return out
    }

    /// Written a moment later, so a burst of changes is one write.
    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            saveScheduled = false
            if let data = try? JSONEncoder().encode(store) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// The history page: every visited page, newest first, by day, with a filter (the page's own
    /// script; it sends nothing to Halliday).
    func historyPageHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let calendar = Calendar.current
        let day = DateFormatter()
        day.locale = NightGlass.dateLocale
        day.setLocalizedDateFormatFromTemplate("EEEEdMMMMyyyy")
        let time = DateFormatter()
        time.timeStyle = .short
        var sections = ""
        var current: Date?
        for p in recent {
            let start = calendar.startOfDay(for: p.lastVisit)
            if start != current {
                if current != nil { sections += "</div>" }
                current = start
                let name = calendar.isDateInToday(start) ? "Today" : calendar.isDateInYesterday(start) ? "Yesterday" : day.string(from: start)
                sections += "<div class=\"day\"><h2>\(esc(name))</h2>"
            }
            let host = URL(string: p.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? p.url
            let title = p.title.isEmpty ? host : p.title
            sections += "<a class=\"row\" href=\"\(esc(p.url))\" data-k=\"\(esc((title + " " + p.url).lowercased()))\"><span class=\"time\">\(esc(time.string(from: p.lastVisit)))</span>"
                + "<span class=\"dot\">\(esc(String(host.prefix(1)).uppercased()))</span><span class=\"t\">\(esc(title))</span><span class=\"h\">\(esc(host))</span></a>"
        }
        if current != nil { sections += "</div>" }
        let count = store.history.count
        let search = count == 0 ? "" : "<input id=\"q\" type=\"search\" placeholder=\"Search history\" aria-label=\"Search history\">"
        let intro = count == 0 ? "Pages you visit show here (never those in private tabs)."
            : "\(count) page\(count == 1 ? "" : "s"), newest first. Private tabs are never kept. Clearing is in the browser's settings, beside the bar."
        let body = count == 0 ? "<div class=\"empty\"><a href=\"halliday://start\">Back to the start page</a></div>" : sections
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>History</title><style>
        html{background:#0A0B10;color:#F2F3F7;font:16px -apple-system,system-ui,sans-serif}
        body{max-width:980px;margin:0 auto;padding:48px 32px 80px}
        .top{display:flex;justify-content:space-between;align-items:center;gap:24px;margin-bottom:8px}
        h1{font-size:34px;font-weight:700;letter-spacing:-.01em;margin:0}
        p{color:#A9AEBD;margin:0 0 28px}
        input{width:340px;height:44px;border-radius:22px;border:0;background:rgba(0,0,0,.4);color:#F2F3F7;font:16px -apple-system,system-ui,sans-serif;
          padding:0 20px;box-sizing:border-box;outline:none}
        input:focus{background:#0E0F15;box-shadow:0 0 0 2px #8AB4FF,0 0 0 7px rgba(138,180,255,.2)}
        h2{font-size:13px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#8A90A0;margin:30px 0 8px}
        .row{display:flex;align-items:center;gap:14px;height:52px;padding:0 14px;border-radius:16px;color:inherit;text-decoration:none}
        .row:hover{background:rgba(255,255,255,.10)}
        .time{width:64px;color:#8A90A0;font-size:14px;font-variant-numeric:tabular-nums;flex:none}
        .dot{width:30px;height:30px;border-radius:15px;background:rgba(138,180,255,.18);color:#8AB4FF;display:flex;align-items:center;
          justify-content:center;font-weight:700;font-size:14px;flex:none}
        .t{font-weight:500;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
        .h{font-size:14px;color:#A9AEBD;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:260px}
        .empty{color:#A9AEBD;padding:60px 0;text-align:center}
        .empty a{color:#8AB4FF;text-decoration:none;font-weight:500}
        </style></head><body>
        <div class="top"><h1>History</h1>\(search)</div>
        <p>\(intro)</p>
        \(body)
        <div class="empty" id="none" hidden>No page matches.</div>
        <script>
        const q = document.getElementById('q');
        if (q) q.addEventListener('input', () => {
          const t = q.value.trim().toLowerCase();
          let any = false;
          for (const d of document.querySelectorAll('.day')) {
            let shown = 0;
            for (const r of d.querySelectorAll('.row')) { const on = !t || r.dataset.k.includes(t); r.hidden = !on; if (on) shown++; }
            d.hidden = shown === 0; if (shown) any = true;
          }
          document.getElementById('none').hidden = any;
        });
        </script></body></html>
        """
    }

    /// The start page: bookmarks and recently visited pages, in Night Glass.
    func startPageHTML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        func tiles(_ pages: [Page]) -> String {
            pages.map { p in
                let host = URL(string: p.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? p.url
                return "<a class=\"tile\" href=\"\(esc(p.url))\"><span class=\"dot\">\(esc(String(host.prefix(1)).uppercased()))</span><span class=\"t\">\(esc(p.title.isEmpty ? host : p.title))</span><span class=\"h\">\(esc(host))</span></a>"
            }.joined()
        }
        let starters = [Page(url: "https://immersive-web.github.io/webxr-samples/", title: "WebXR Samples"),
                        Page(url: "https://duckduckgo.com/", title: "DuckDuckGo"), Page(url: "https://www.wikipedia.org/", title: "Wikipedia")]
        let marks = store.bookmarks.isEmpty ? starters : store.bookmarks
        let recents = Array(recent.prefix(8))
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Start</title><style>
        html{background:#0A0B10;color:#F2F3F7;font:16px -apple-system,system-ui,sans-serif}
        body{max-width:980px;margin:0 auto;padding:56px 32px}
        h1{font-size:34px;font-weight:700;letter-spacing:-.01em;margin:0 0 6px}
        p{color:#A9AEBD;margin:0 0 36px}
        h2{font-size:13px;font-weight:600;letter-spacing:.06em;text-transform:uppercase;color:#8A90A0;margin:34px 0 14px}
        .grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}
        .tile{display:flex;flex-direction:column;gap:6px;padding:18px;border-radius:20px;background:rgba(255,255,255,.06);
          border:1px solid rgba(255,255,255,.08);color:inherit;text-decoration:none;min-height:96px}
        .tile:hover{background:rgba(255,255,255,.12)}
        .dot{width:36px;height:36px;border-radius:18px;background:rgba(138,180,255,.18);color:#8AB4FF;display:flex;align-items:center;
          justify-content:center;font-weight:700}
        .t{font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .h{font-size:13px;color:#A9AEBD;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .top{display:flex;justify-content:space-between;align-items:baseline}
        .top a{color:#8AB4FF;text-decoration:none;font-weight:500}.top a:hover{color:#D5E3FF}
        </style></head><body><div class="top"><h1>Halliday</h1>\(store.history.isEmpty ? "" : "<a href=\"halliday://history\">History</a>")</div>
        <p>Type an address or a search above. The star in the bar keeps a page here.</p>
        <h2>\(store.bookmarks.isEmpty ? "Places to start" : "Bookmarks")</h2><div class="grid">\(tiles(marks))</div>
        \(recents.isEmpty ? "" : "<h2>Recently visited</h2><div class=\"grid\">\(tiles(recents))</div>")
        </body></html>
        """
    }
}
