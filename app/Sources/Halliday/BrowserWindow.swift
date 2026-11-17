// Halliday's own browser (ROADMAP W9, W11.A): a window of tabs, each a WKWebView, living on the
// virtual display and used in VR like any other window. The window shows only the active page: the
// tabs, toolbar and address bar are drawn by Halliday in VR (BrowserBar.swift, W11.B). It hosts the
// WebXR bridge (9.3/9.4) and
// "Watch in VR" (9.2) — Safari and Chrome on macOS don't offer WebXR for a headset.
//
// Tabs: pop-ups (window.open, target=_blank) open as tabs built from the configuration WebKit hands
// over, so the opener link survives and OAuth sign-in flows complete. Private tabs share a
// non-persistent data store that is dropped when the last one closes. The browser presents itself
// as Safari: Google refuses sign-in from web views that don't.

import AppKit
import UniformTypeIdentifiers
import WebKit
import simd

/// A video found in a page (or one of its frames).
struct PageVideo {
    let src: URL
    let width: Int, height: Int
    let duration: Double, time: Double
    let playing: Bool
    let area: Int
    let pageTitle: String
    let frame: URL?
    /// MSE streams (blob:) have no file the native player can open.
    var isStream: Bool { src.scheme == "blob" }
}

/// One page of the browser.
@MainActor
final class BrowserTab: NSObject {
    let webView: WKWebView
    let isPrivate: Bool
    weak var owner: BrowserWindow?
    /// Videos per frame, as last reported by the video finder.
    fileprivate var videosByFrame: [String: [PageVideo]] = [:]
    /// True while the page has an immersive WebXR session.
    fileprivate(set) var xrActive = false
    /// Size in pixels of the page's side-by-side image while it is presented.
    fileprivate(set) var presentedPixels: CGSize?
    fileprivate var runAfterLoad: String?
    private var observations: [NSKeyValueObservation] = []

    var title: String {
        let t = webView.title ?? ""
        return t.isEmpty ? (webView.url?.host ?? "New Tab") : t
    }

    init(webView: WKWebView, isPrivate: Bool, owner: BrowserWindow) {
        self.webView = webView
        self.isPrivate = isPrivate
        self.owner = owner
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = BrowserWindow.safariUserAgent
        observations = [
            webView.observe(\.title) { [weak self] _, _ in MainActor.assumeIsolated { self?.owner?.tabChanged(self) } },
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.owner?.tabChanged(self) } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.owner?.tabChanged(self) } },
            webView.observe(\.isLoading) { [weak self] _, _ in MainActor.assumeIsolated { self?.owner?.tabChanged(self) } },
        ]
    }

    var bestVideo: PageVideo? {
        videosByFrame.values.flatMap { $0 }.filter { !$0.isStream }
            .max { ($0.playing ? 1 : 0, $0.area) < ($1.playing ? 1 : 0, $1.area) }
    }

    var onlyStreams: Bool {
        let all = videosByFrame.values.flatMap { $0 }
        return !all.isEmpty && all.allSatisfy(\.isStream)
    }
}

@MainActor
final class BrowserWindow: NSObject {
    static let homePage = URL(string: "https://immersive-web.github.io/webxr-samples/")!

    /// Safari's user agent for this Mac's Safari version (Google rejects sign-in from web views that
    /// present themselves as embedded).
    static let safariUserAgent: String = {
        let plist = NSDictionary(contentsOfFile: "/Applications/Safari.app/Contents/Info.plist")
        let version = plist?["CFBundleShortVersionString"] as? String ?? "18.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    let window: NSWindow
    private(set) var tabs: [BrowserTab] = []
    private(set) var active: BrowserTab?
    private let content = NSView()
    /// Called when anything the VR browser bar shows changes (tabs, titles, URL, loading, videos).
    var onChange: (() -> Void)?
    /// Called when the address bar should take the keyboard (⌘L, a new tab).
    var onFocusAddress: (() -> Void)?
    /// Content size before presenting an immersive page, restored afterwards.
    private var sizeBeforePresenting: NSSize?

    private let messages = ScriptMessageProxy()
    private lazy var normalScripts = makeContentController()
    private lazy var privateScripts = makeContentController()
    /// Shared by private tabs; dropped when the last one closes.
    private var privateStore: WKWebsiteDataStore?

    /// Called when an immersive session starts or ends.
    var onXRSessionChange: ((Bool) -> Void)?
    /// Called when a page finishes loading.
    var onPageLoad: (() -> Void)?
    /// Called when the user asks to watch the page's video in VR.
    var onWatchInVR: ((PageVideo) -> Void)?
    /// Optics sent to every page on load (IPD, per-eye FOV, eye size).
    private var xrOptics: (ipd: Float, left: Fov, right: Fov, eyeSize: Int)?

    /// A script from app/Resources, from the app bundle or, when running the bare binary during
    /// development, from the source tree.
    static func resourceScript(_ name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: "js")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/\(name).js")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Pages tell an Apple Vision Pro from a Mac by what Safari offers there, not by the user agent
    /// (visionOS Safari sends the Mac's): WebXR plus touch support. The bridge provides WebXR; this
    /// adds the touch signals, in every frame. Off with `--desktop-identity`.
    static var visionIdentity: Bool { Settings.shared.visionIdentity }
    static let visionIdentityScript = """
        (() => {
          try { Object.defineProperty(Navigator.prototype, "maxTouchPoints", { get: () => 5, configurable: true }); } catch (e) {}
          for (const target of [window, document, HTMLElement.prototype]) {
            for (const name of ["ontouchstart", "ontouchmove", "ontouchend", "ontouchcancel"]) {
              if (!(name in target)) { try { Object.defineProperty(target, name, { value: null, writable: true, configurable: true }); } catch (e) {} }
            }
          }
        })();
        """

    static let bridgeScript = resourceScript("webxr-bridge")
    static let videoFinderScript = resourceScript("video-finder")

    init(startURL: URL? = nil, runAfterLoad: String? = nil) {
        // Titled (so it behaves as a normal window) but with the page under an invisible title bar:
        // in VR the window is just the page.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
                          styleMask: [.titled, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        messages.target = self
        window.title = "Halliday Browser"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.contentView = content
        let tab = newTab(private: false, select: true)
        tab.runAfterLoad = runAfterLoad
        if let startURL { load(startURL, in: tab) } else { loadHome(in: tab) }
        if Self.bridgeScript == nil { log("[browser] webxr-bridge.js not found: pages won't see WebXR") }
    }

    // --- Tabs ---

    private func makeContentController() -> WKUserContentController {
        let c = WKUserContentController()
        if Self.visionIdentity {
            c.addUserScript(WKUserScript(source: Self.visionIdentityScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let s = Self.bridgeScript {
            c.addUserScript(WKUserScript(source: s, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let s = Self.videoFinderScript {
            c.addUserScript(WKUserScript(source: s, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        }
        c.add(messages, name: "halliday")
        return c
    }

    private func makeConfiguration(private isPrivate: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.userContentController = isPrivate ? privateScripts : normalScripts
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else {
            config.websiteDataStore = .default()
        }
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        return config
    }

    @discardableResult
    func newTab(private isPrivate: Bool, select: Bool, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? makeConfiguration(private: isPrivate))
        let tab = BrowserTab(webView: webView, isPrivate: isPrivate, owner: self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let i = active.flatMap({ a in tabs.firstIndex { $0 === a } }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
        if select { self.select(tab) } else { onChange?() }
        return tab
    }

    func select(_ tab: BrowserTab) {
        guard tab !== active else { return }
        if let a = active, a.xrActive { endXR() } // an immersive page can't keep running behind another tab
        active?.webView.removeFromSuperview()
        active = tab
        let v = tab.webView
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor), v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor), v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        tabChanged(tab)
        window.makeFirstResponder(v)
    }

    func close(_ tab: BrowserTab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab.xrActive { tab.webView.evaluateJavaScript("window.__halliday && __halliday.end()", completionHandler: nil) }
        tabs.remove(at: i)
        tab.webView.removeFromSuperview()
        if !tabs.contains(where: \.isPrivate) { privateStore = nil } // private data is gone
        if tabs.isEmpty {
            newTab(private: false, select: true)
            loadHome(in: active!)
        } else if tab === active {
            active = nil
            select(tabs[min(i, tabs.count - 1)])
        } else {
            onChange?()
        }
    }

    func closeActiveTab() { if let a = active { close(a) } }

    func selectNextTab(_ step: Int) {
        guard let a = active, let i = tabs.firstIndex(where: { $0 === a }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    /// Opens a new tab on the home page and puts the cursor in the address bar.
    func openNewTab(private isPrivate: Bool) {
        let tab = newTab(private: isPrivate, select: true)
        if isPrivate {
            tab.webView.loadHTMLString(Self.privatePage, baseURL: nil)
        } else {
            loadHome(in: tab)
        }
        focusAddressBar()
    }

    func focusAddressBar() { onFocusAddress?() }

    private static let privatePage = """
        <html><body style="background:#1e1b2e;color:#ddd;font:16px -apple-system;display:flex;align-items:center;justify-content:center;height:90vh">
        <div style="text-align:center"><h1 style="font-weight:600">Private tab</h1>
        <p>Pages you open here leave no cookies or site data once the last private tab closes.</p></div></body></html>
        """

    /// Called by tabs when their title, URL, history or loading state changes.
    fileprivate func tabChanged(_ tab: BrowserTab?) {
        guard let tab else { return }
        if tab === active { window.title = (tab.isPrivate ? "Private — " : "") + tab.title }
        onChange?()
    }

    /// The active page's address as the address bar shows it ("" for local and blank pages).
    var displayURL: String {
        active?.webView.url.map { $0.isFileURL || $0.scheme == "about" ? "" : $0.absoluteString } ?? ""
    }

    /// Loads what the user typed in the address bar (a URL, a host name or a search).
    func navigate(_ text: String) {
        guard let tab = active, let u = Self.url(from: text) else { return }
        load(u, in: tab)
        window.makeFirstResponder(tab.webView)
    }

    @objc func goBack() { active?.webView.goBack() }
    @objc func goForward() { active?.webView.goForward() }
    @objc func reloadPage() { active?.webView.reload() }

    func load(_ url: URL) { if let t = active { load(url, in: t) } }

    /// Shows the history page in a tab of its own, beside the one in use (never over it): the tab
    /// already showing history if there is one (brought up to date), else a new one.
    @objc func showHistory() {
        let tab = tabs.first { $0.webView.url?.absoluteString == "about:blank" && $0.webView.title == "History" }
            ?? newTab(private: false, select: true)
        select(tab)
        tab.videosByFrame = [:]
        tab.webView.loadHTMLString(BrowserHistory.shared.historyPageHTML(), baseURL: nil)
        onChange?()
    }

    /// The home page set in Settings, or Halliday's start page (bookmarks and recent pages).
    func loadHome(in tab: BrowserTab) {
        if let u = Self.url(from: Settings.shared.homePage), !Settings.shared.homePage.isEmpty {
            load(u, in: tab)
        } else {
            tab.videosByFrame = [:]
            tab.webView.loadHTMLString(BrowserHistory.shared.startPageHTML(), baseURL: nil)
            onChange?()
        }
    }

    // --- Bookmarks, find, zoom ---

    var isBookmarked: Bool { BrowserHistory.shared.isBookmarked(active?.webView.url) }

    func toggleBookmark() {
        guard let tab = active, let url = tab.webView.url, url.scheme == "http" || url.scheme == "https" else { return }
        BrowserHistory.shared.toggleBookmark(url: url, title: tab.webView.title ?? "")
        onChange?()
    }

    /// Finds `text` in the active page (the next match, or the previous one). `found` is called
    /// with whether there was a match.
    func find(_ text: String, backwards: Bool = false, found: @escaping (Bool) -> Void) {
        guard let v = active?.webView, !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        v.find(text, configuration: config) { result in found(result.matchFound) }
    }

    /// Page zoom: `step` > 0 larger, < 0 smaller, 0 back to actual size.
    func zoom(_ step: Int) {
        guard let v = active?.webView else { return }
        v.pageZoom = step == 0 ? 1 : max(0.5, min(3, v.pageZoom * (step > 0 ? 1.1 : 1 / 1.1)))
    }

    func load(_ url: URL, in tab: BrowserTab) {
        tab.videosByFrame = [:]
        if url.isFileURL {
            tab.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            tab.webView.load(URLRequest(url: url))
        }
        onChange?()
    }

    /// What the user typed: a URL, a host name, or a search.
    static func url(from text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let scheme = u.scheme, ["http", "https", "file"].contains(scheme) { return u }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { return u }
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    // --- The active tab, for the rest of Halliday (WebXR, Watch in VR) ---

    var webView: WKWebView? { active?.webView }
    var xrActive: Bool { active?.xrActive ?? false }
    var presentedPixels: CGSize? { active?.presentedPixels }
    var bestVideo: PageVideo? { active?.bestVideo }

    /// The active page's area in global display coordinates (points, origin top-left).
    var webViewGlobalFrame: CGRect {
        guard let v = active?.webView else { return .zero }
        let r = window.convertToScreen(v.convert(v.bounds, to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// Sends the optics to every page (and to pages loaded later): IPD (m), per-eye FOV and the eye
    /// render size (px).
    func configureXR(ipd: Float, fovLeft: Fov, fovRight: Fov, eyeSize: Int) {
        xrOptics = (ipd, fovLeft, fovRight, eyeSize)
        tabs.forEach(configureXR)
    }

    private func configureXR(_ tab: BrowserTab) {
        guard let o = xrOptics else { return }
        func tangents(_ f: Fov) -> String { "[\(tan(f.left)),\(tan(f.right)),\(tan(f.up)),\(tan(f.down))]" }
        let js = "window.__halliday && __halliday.configure({ipd:\(o.ipd),fov:[\(tangents(o.left)),\(tangents(o.right))],eyeSize:\(o.eyeSize)})"
        tab.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Sends the head pose (and pointer) to the active page, with the id it stamps on its frames.
    func pushPose(_ head: HeadPose, id: UInt16, pointer: simd_quatf) {
        let p = head.position, q = head.orientation.vector, r = pointer.vector
        let js = "window.__halliday && __halliday.update({id:\(id),p:[\(p.x),\(p.y),\(p.z)],q:[\(q.x),\(q.y),\(q.z),\(q.w)],r:[\(r.x),\(r.y),\(r.z),\(r.w)]})"
        active?.webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func select(down: Bool) {
        active?.webView.evaluateJavaScript("window.__halliday && __halliday.select('\(down ? "down" : "up")')", completionHandler: nil)
    }

    func endXR() {
        active?.webView.evaluateJavaScript("window.__halliday && __halliday.end()", completionHandler: nil)
    }

    @objc func watchInVR() {
        guard let tab = active, let video = tab.bestVideo else {
            log(active?.onlyStreams == true
                ? "[browser] this page streams its video through MSE (blob:): it can't be opened in the native player; use the site's own VR mode if it has one"
                : "[browser] no video found on this page")
            return
        }
        tab.webView.evaluateJavaScript("window.__hallidayVideos && __hallidayVideos.pause()", completionHandler: nil)
        onWatchInVR?(video)
    }

    /// Cookies, Referer and user agent for fetching `video` the way the page does.
    func requestContext(for video: PageVideo) async -> (cookies: [HTTPCookie], headers: [String: String]) {
        guard let v = active?.webView else { return ([], [:]) }
        let all = await v.configuration.websiteDataStore.httpCookieStore.allCookies()
        let host = video.src.host ?? ""
        let cookies = all.filter { c in
            let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        var headers: [String: String] = ["User-Agent": Self.safariUserAgent]
        if let page = video.frame ?? v.url { headers["Referer"] = page.absoluteString }
        return (cookies, headers)
    }

    // --- Messages from the page scripts (untrusted content: only known messages are acted on) ---

    fileprivate func received(_ message: WKScriptMessage) {
        guard let tab = tabs.first(where: { $0.webView === message.webView }),
              let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "session":
            let started = (body["state"] as? String) == "start"
            guard started != tab.xrActive else { return }
            if started, tab !== active { select(tab) }
            tab.xrActive = started
            log("[webxr] immersive session \(started ? "started" : "ended") on \(tab.webView.url?.host ?? "?")")
            if !started {
                tab.presentedPixels = nil
                if let size = sizeBeforePresenting { window.setContentSize(size) }
                sizeBeforePresenting = nil
            }
            if tab === active { onXRSessionChange?(started) }
        case "present":
            // The page's canvas now fills the page: make the page exactly its size in points (2 pixels
            // per point on the virtual display), so the capture sees it pixel for pixel.
            guard tab === active, let w = body["width"] as? Double, let h = body["height"] as? Double else { return }
            if sizeBeforePresenting == nil { sizeBeforePresenting = window.contentView?.frame.size }
            window.setContentSize(NSSize(width: w / 2, height: h / 2))
            tab.presentedPixels = CGSize(width: w, height: h)
        case "videos":
            guard let frame = body["frame"] as? String, let items = body["items"] as? [[String: Any]] else { return }
            let title = (body["title"] as? String) ?? ""
            tab.videosByFrame[frame] = items.compactMap { i in
                guard let s = i["src"] as? String, let src = URL(string: s) else { return nil }
                return PageVideo(src: src, width: i["width"] as? Int ?? 0, height: i["height"] as? Int ?? 0,
                                 duration: i["duration"] as? Double ?? 0, time: i["time"] as? Double ?? 0,
                                 playing: i["playing"] as? Bool ?? false, area: i["area"] as? Int ?? 0,
                                 pageTitle: title, frame: URL(string: frame))
            }
            if tab === active { onChange?() }
        case "console":
            let text = (body["text"] as? String ?? "").prefix(600)
            log("[browser] console.\(body["level"] as? String ?? "log"): \(text)")
        default:
            break
        }
    }

    fileprivate func tab(of webView: WKWebView) -> BrowserTab? { tabs.first { $0.webView === webView } }
}

// --- Navigation, pop-ups, dialogs, uploads, downloads ---

extension BrowserWindow: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tab(of: webView) else { return }
        tab.videosByFrame = [:]
        if tab === active { onChange?() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(of: webView) else { return }
        configureXR(tab)
        // Remembered for suggestions and the start page; never for private tabs.
        if !tab.isPrivate, let url = webView.url { BrowserHistory.shared.record(url: url, title: webView.title ?? "") }
        tabChanged(tab)
        if tab === active { onPageLoad?() }
        if let js = tab.runAfterLoad {
            tab.runAfterLoad = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                webView.evaluateJavaScript(js) { result, error in
                    log("[browser] debug script → \(error.map { "error: \($0.localizedDescription)" } ?? String(describing: result ?? "ok"))")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        log("[browser] load failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        log("[browser] load failed: \(error.localizedDescription)")
    }

    // Pop-ups and target=_blank: a new tab from WebKit's configuration keeps window.opener, which
    // OAuth sign-in flows rely on.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let opener = tab(of: webView)
        let tab = newTab(private: opener?.isPrivate ?? false, select: true, configuration: configuration)
        log("[browser] pop-up opened as tab \(tabs.count): \(navigationAction.request.url?.host ?? "?")")
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tab(of: webView) { close(tab) }
    }

    // Page dialogs, as sheets on the browser window (visible in VR with the window).
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = prompt
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    // File uploads (<input type=file>).
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    // Downloads: anything the page can't show, or links marked as downloads, go to ~/Downloads.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Halliday's own pages link to each other with halliday:// addresses.
        if let url = navigationAction.request.url, url.scheme == "halliday" {
            decisionHandler(.cancel)
            guard let tab = tabs.first(where: { $0.webView === webView }) else { return }
            if url.host == "history" {
                showHistory()
            } else if url.host == "start" {
                loadHome(in: tab)
            }
            onChange?()
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var url = folder.appendingPathComponent(suggestedFilename)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        log("[browser] downloading \(suggestedFilename) → \(url.path)")
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        log("[browser] download finished")
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        log("[browser] download failed: \(error.localizedDescription)")
    }
}

/// Routes script messages to the browser without being retained by it (WKUserContentController
/// retains its handlers).
@MainActor
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: BrowserWindow?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.received(message)
    }
}
