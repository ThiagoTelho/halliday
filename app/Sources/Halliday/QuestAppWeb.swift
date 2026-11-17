// A Quest app's web half, hosted (ROADMAP W15.3, stage 1).
//
// Some apps are two activities: an interface that is a web application bundled in the package
// (Capacitor: `assets/public`, with `assets/native-bridge.js` and `capacitor.config.json`), and a
// VR player the interface starts with what to play. On a Quest the first runs in an Android web
// view whose Java side answers the page's calls. Here the page is served out of the installed
// package into one of Halliday's browser tabs, under the app's own scheme and host (so the app's
// servers see the origin they expect), and this file is the Java side: `androidBridge` in,
// `Capacitor.fromNative` out. The user signs in there as they would on the headset; what they
// type goes to the app's own servers, as in any browser tab.
//
// The page's requests to the app's servers are sent by Halliday for it (`CapacitorHttp`, as
// Capacitor does on Android when an app asks): from the page itself they would be refused, its
// origin here not being the one the servers allow. This is network code of Halliday's, on the
// app's behalf and only while the user has the app open (tools/check-privacy.sh, PRIVACY.md).
//
// Answered here: Capacitor's standard plugins only, `Device`, `NetworkInfo`, `Filesystem` (inside
// the app's own folder in Halliday's, never outside it) and `CapacitorHttp`. An app's own plugins
// (its launcher, its downloads, ...) are answered by an extension for that app, if the user
// installed one (docs/extensions.md, `ExtensionHost.swift`): nothing about one app is written
// here. "Launch in VR" comes from the extension, with the session it built.
//
// The page is the app's own code but still a page: only calls to the plugins below, or to the
// plugins an extension declares, are acted on, and every file path is kept inside the app's
// folder.

import AppKit
@preconcurrency import WebKit

@MainActor
final class QuestAppWeb: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    let app: QuestApp
    private let scheme: String
    private let host: String
    /// The web application's files, and the app's own data.
    private let root: URL
    private let data: URL
    weak var webView: WKWebView?
    /// "Launch in VR": the file holding the scene's description, and the one with the rest.
    var onLaunch: ((_ session: URL, _ extras: URL) -> Void)?

    /// Listeners the page added, by plugin and event: the call ids to answer on.
    private var listeners: [String: [String]] = [:]
    /// The app's folder: paths, downloads, archives (`QuestAppFiles.swift`).
    let files: QuestAppFiles
    /// The extensions answering this app's own plugins, switched on when the app was opened.
    private(set) var extensions: [ExtensionHost] = []

    /// Whether an installed app has a web half Halliday can host.
    static func has(_ app: QuestApp) -> Bool { app.hasWebInterface }

    init?(app: QuestApp) {
        guard Self.has(app) else { return nil }
        self.app = app
        let assets = app.folder.appendingPathComponent("payload/assets")
        root = assets.appendingPathComponent("public").standardizedFileURL
        data = app.folder.appendingPathComponent("userdata").standardizedFileURL
        // The origin the app's own servers expect: its iOS scheme (WebKit serves no page of ours
        // under https) and its host.
        let config = (try? Data(contentsOf: assets.appendingPathComponent("capacitor.config.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let server = config?["server"] as? [String: Any]
        let wanted = (server?["iosScheme"] as? String ?? "capacitor").lowercased()
        scheme = wanted.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) && !["http", "https", "file", "about", "data", "blob", "halliday"].contains(wanted) ? wanted : "capacitor"
        host = server?["hostname"] as? String ?? "localhost"
        files = QuestAppFiles(data: data, origin: "https://\(host)")
        super.init()
        for installed in Extensions.active(for: app.package) {
            let x = ExtensionHost(installed, app: app, files: files)
            if let problem = x.problem { log("[extensions] \(installed.id) for \(app.name): \(problem)") }
            x.resolve = { [weak self] id, plugin, method, data in self?.resolve(Call(id: id, plugin: plugin, method: method), data) }
            x.reject = { [weak self] id, plugin, method, message in self?.reject(Call(id: id, plugin: plugin, method: method), message) }
            x.emit = { [weak self] plugin, event, data in self?.notify(plugin, event, data) }
            x.onLaunch = { [weak self] session, extras in self?.onLaunch?(session, extras) }
            extensions.append(x)
            log("[extensions] \(installed.id) \(installed.manifest.version) answers \(app.name)'s \(installed.manifest.plugins.map(\.name).joined(separator: ", "))")
        }
    }

    /// The extension answering `plugin`: the first one that declares it.
    private func extensionFor(_ plugin: String) -> ExtensionHost? { extensions.first { $0.declares(plugin) } }

    var startURL: URL { URL(string: "\(scheme)://\(host)/")! }

    /// A web view configuration that serves the app and answers its bridge. Cookies and storage
    /// are the browser's own, kept between runs: the sign-in stays.
    func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(self, forURLScheme: scheme)
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let controller = WKUserContentController()
        controller.add(self, name: "questApp")
        // What Capacitor's Android bridge puts into a page before its own code runs: the door to
        // the native side, Capacitor's bridge script (the app's own copy), and the plugins there are.
        let bridge = (try? String(contentsOf: app.folder.appendingPathComponent("payload/assets/native-bridge.js"), encoding: .utf8)) ?? ""
        // Capacitor's standard plugins, then the ones the app's extensions declare.
        var all = Self.plugins
        for x in extensions {
            for p in x.manifest.plugins where !all.contains(where: { $0.0 == p.name }) { all.append((p.name, p.methods)) }
        }
        let headers = all.map { name, methods in
            // As Capacitor's Android side declares them: a listener is a callback (the page goes on
            // at once and events come to it later), removing one answers nothing, the rest are
            // promises. Declared a promise, `addListener` is waited for and never comes: the app
            // stopped right before starting a download.
            ["name": name, "methods": methods.map { method -> [String: String] in
                switch method {
                case "addListener": ["name": method, "rtype": "callback"]
                case "removeListener", "removeAllListeners": ["name": method]
                default: ["name": method, "rtype": "promise"]
                }
            }] as [String: Any]
        }
        let headersJSON = (try? JSONSerialization.data(withJSONObject: headers)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let script = """
        window.androidBridge = { postMessage: function (s) { window.webkit.messageHandlers.questApp.postMessage(s); } };
        // Capacitor's native HTTP: the bridge script then sends the page's own requests through
        // the native side (here: Halliday), which is what gives them the origin the app's servers
        // expect. A page served under another scheme is refused by them (cross-origin).
        window.CapacitorHttpAndroidInterface = { isEnabled: function () { return true; } };
        // The page's own errors, for Halliday's log (what a failed start looks like from outside is a blank tab).
        (function () {
          var tell = function (kind, text) {
            try { window.webkit.messageHandlers.questApp.postMessage(JSON.stringify({ callbackId: '-1', pluginId: 'HallidayLog', methodName: kind, options: { text: String(text).slice(0, 600) } })); } catch (e) {}
          };
          window.addEventListener('error', function (e) { tell('error', (e.message || 'error') + ' at ' + (e.filename || '?') + ':' + (e.lineno || 0)); });
          window.addEventListener('unhandledrejection', function (e) { tell('rejection', (e.reason && (e.reason.message || e.reason)) || 'unhandled rejection'); });
          // Requests that fail (with `--app-web-log`, every request): where to, and how.
          var verbose = \(Self.uiLog ? "true" : "false");
          var realFetch = window.fetch;
          window.fetch = function (input, init) {
            var url = (input && input.url) || String(input);
            return realFetch.apply(this, arguments).then(function (r) {
              if (verbose || !r.ok) tell('fetch', r.status + ' ' + ((init && init.method) || 'GET') + ' ' + url.slice(0, 200));
              return r;
            }, function (e) { tell('fetch', 'failed ' + ((init && init.method) || 'GET') + ' ' + url.slice(0, 200) + ': ' + (e && e.message)); throw e; });
          };
          var open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            var x = this;
            x.addEventListener('loadend', function () { if (verbose || x.status === 0 || x.status >= 400) tell('xhr', x.status + ' ' + method + ' ' + String(url).slice(0, 200)); });
            return open.apply(this, arguments);
          };
        })();
        window.Capacitor = { DEBUG: false, isLoggingEnabled: false, Plugins: {} };
        window.WEBVIEW_SERVER_URL = '\(scheme)://\(host)';
        \(bridge)
        window.Capacitor.PluginHeaders = \(headersJSON);
        """
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController = controller
        return config
    }

    /// Capacitor's standard plugins answered here, with their methods (what the page is told
    /// exists, with the plugins of the app's extensions).
    private static let plugins: [(String, [String])] = [
        ("Device", ["getInfo", "getId", "getLanguageCode", "getBatteryInfo"]),
        ("NetworkInfo", ["getNetworkInfo"]),
        ("Filesystem", ["readFile", "writeFile", "appendFile", "deleteFile", "mkdir", "rmdir", "readdir", "getUri", "stat",
                        "rename", "copy", "downloadFile", "checkPermissions", "requestPermissions", "addListener", "removeListener"]),
        ("CapacitorHttp", ["request", "get", "post", "put", "patch", "delete"]),
    ]

    // --- Serving the app's files ---

    private static let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
                                "json": "application/json", "webmanifest": "application/manifest+json", "svg": "image/svg+xml",
                                "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
                                "ico": "image/x-icon", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
                                "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "wasm": "application/wasm",
                                "xml": "application/xml", "txt": "text/plain"]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        // Capacitor's bridge sends the page's XMLHttpRequests here, the real address in `u`, for
        // the native side to make them (see `request` below for why).
        if url.path == "/_capacitor_http_interceptor_" {
            intercept(task, url)
            return
        }
        var file: URL
        if url.path.hasPrefix("/_capacitor_file_/") {
            // A file of the app's own data, as Capacitor serves local files to its page.
            file = URL(fileURLWithPath: String(url.path.dropFirst("/_capacitor_file_".count))).standardizedFileURL
            guard file.path.hasPrefix(data.path + "/") else {
                task.didFailWithError(URLError(.noPermissionsToReadFile))
                return
            }
        } else {
            file = root.appendingPathComponent(url.path).standardizedFileURL
            // The page's own routes (no file of that name) are the application itself.
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory)
            if !file.path.hasPrefix(root.path) || !exists || isDirectory.boolValue {
                guard url.pathExtension.isEmpty else {
                    task.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                file = root.appendingPathComponent("index.html")
            }
        }
        guard let body = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type, "Content-Length": "\(body.count)", "Cache-Control": "no-cache",
        ])!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // A task WebKit stopped must not be answered any more (it raises).
        pending.removeValue(forKey: ObjectIdentifier(task))?.work.cancel()
    }

    /// Requests being made for the page: the task waiting for each, and the request.
    private var pending: [ObjectIdentifier: (task: any WKURLSchemeTask, work: URLSessionDataTask)] = [:]

    /// One of the page's XMLHttpRequests, made for it: the method, headers and body it gave, to
    /// the address in `u` (http or https only), the answer handed back as it came.
    private func intercept(_ task: any WKURLSchemeTask, _ url: URL) {
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value
        guard let target, let real = URL(string: target), ["http", "https"].contains(real.scheme?.lowercased() ?? "") else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        var r = URLRequest(url: real)
        r.httpMethod = task.request.httpMethod ?? "GET"
        for (name, value) in task.request.allHTTPHeaderFields ?? [:] where !["host", "origin", "referer", "content-length"].contains(name.lowercased()) {
            r.setValue(value, forHTTPHeaderField: name)
        }
        r.setValue(androidOrigin, forHTTPHeaderField: "Origin")
        r.setValue(androidOrigin + "/", forHTTPHeaderField: "Referer")
        r.httpBody = task.request.httpBody
        let (id, method, started) = (ObjectIdentifier(task), r.httpMethod ?? "GET", CACurrentMediaTime())
        let work = http.dataTask(with: r) { [weak self] data, response, error in
            Task { @MainActor in
                // (Gone from `pending`: WebKit stopped the task meanwhile.)
                guard let self, let task = self.pending.removeValue(forKey: id)?.task else { return }
                guard let response = response as? HTTPURLResponse, let data else {
                    if Self.uiLog { log("[app-web] \(method) \(real.host ?? "") failed: \(error?.localizedDescription ?? "no answer")") }
                    task.didFailWithError(error ?? URLError(.badServerResponse))
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in response.allHeaderFields {
                    let name = "\(name)"
                    // The body is handed over whole and decoded: its own length and encoding apply no more.
                    if !["content-encoding", "content-length", "transfer-encoding"].contains(name.lowercased()) { headers[name] = "\(value)" }
                }
                headers["Content-Length"] = "\(data.count)"
                if Self.uiLog {
                    log(String(format: "[app-web] %d %@ %@%@ (%d bytes, %.0f ms)", response.statusCode, method, real.host ?? "", real.path, data.count, (CACurrentMediaTime() - started) * 1000))
                }
                let answer = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
                task.didReceive(answer)
                task.didReceive(data)
                task.didFinish()
            }
        }
        pending[id] = (task, work)
        work.resume()
    }

    // --- The bridge ---

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = json["callbackId"] as? String, let plugin = json["pluginId"] as? String, let method = json["methodName"] as? String else { return }
        let options = json["options"] as? [String: Any] ?? [:]
        if plugin == "HallidayLog" {
            log("[app-web] \(app.name) page \(method): \(options["text"] as? String ?? "")")
            return
        }
        let call = Call(id: id, plugin: plugin, method: method)
        if Self.uiLog { log("[app-web] \(plugin).\(method)(\(options.keys.sorted().joined(separator: ", ")))") }
        do {
            if let answer = try handle(call, options) { resolve(call, answer) }
        } catch let error as Refusal {
            reject(call, error.message)
        } catch {
            reject(call, error.localizedDescription)
        }
    }

    private static let uiLog = QuestAppFiles.verbose

    private struct Call {
        let id: String, plugin: String, method: String
    }

    private typealias Refusal = AppRefusal

    private func send(_ result: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        webView?.evaluateJavaScript("window.Capacitor && window.Capacitor.fromNative(\(String(decoding: data, as: UTF8.self)))", completionHandler: nil)
    }

    private func resolve(_ call: Call, _ data: [String: Any], keep: Bool = false) {
        send(["callbackId": call.id, "pluginId": call.plugin, "methodName": call.method, "success": true, "data": data, "save": keep])
    }

    private func reject(_ call: Call, _ message: String) {
        if Self.uiLog { log("[app-web] \(call.plugin).\(call.method) refused: \(message)") }
        send(["callbackId": call.id, "pluginId": call.plugin, "methodName": call.method, "success": false,
              "error": ["message": message], "save": false])
    }

    /// Tells the page's listeners of `event` on `plugin`.
    private func notify(_ plugin: String, _ event: String, _ data: [String: Any] = [:]) {
        for id in listeners["\(plugin).\(event)"] ?? [] {
            send(["callbackId": id, "pluginId": plugin, "methodName": "addListener", "success": true, "data": data, "save": true])
        }
    }

    /// One call. The answer, or nil when it is answered later (or kept open: a listener).
    private func handle(_ call: Call, _ o: [String: Any]) throws -> [String: Any]? {
        // The app's own plugins: its extension's to answer (listeners stay Halliday's).
        if !["addListener", "removeListener"].contains(call.method), let x = extensionFor(call.plugin) {
            x.call(id: call.id, plugin: call.plugin, method: call.method, options: o)
            return nil
        }
        switch (call.plugin, call.method) {
        case (_, "addListener"):
            if let event = o["eventName"] as? String { listeners["\(call.plugin).\(event)", default: []].append(call.id) }
            return nil
        case (_, "removeListener"):
            if let event = o["eventName"] as? String, let id = o["callbackId"] as? String {
                listeners["\(call.plugin).\(event)"]?.removeAll { $0 == id }
            }
            return [:]

        // The device: a headset of the kind the app was made for, as far as it asks.
        case ("Device", "getInfo"):
            // The room there really is, on the disk the app's folder is on: an app measures a
            // download against it (with none reported, "not enough space" for everything).
            let volume = try? data.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = volume?.volumeAvailableCapacityForImportantUsage ?? 0
            let total = Int64(volume?.volumeTotalCapacity ?? 0)
            return ["name": "Halliday", "model": "Quest 3", "platform": "android", "operatingSystem": "android", "osVersion": "14",
                    "androidSDKVersion": 34, "manufacturer": "Oculus", "isVirtual": false, "webViewVersion": "124.0.0.0",
                    "diskFree": free, "diskTotal": total, "realDiskFree": free, "realDiskTotal": total, "memUsed": 0]
        case ("Device", "getId"): return ["identifier": deviceID]
        case ("Device", "getLanguageCode"): return ["value": Locale.current.language.languageCode?.identifier ?? "en"]
        case ("Device", "getBatteryInfo"): return ["batteryLevel": 1, "isCharging": true]
        case ("NetworkInfo", "getNetworkInfo"):
            // Nothing is measured: only that there is a connection of the usual kind.
            return ["connectionType": "wifi", "downstreamBandwidthMbps": 0, "upstreamBandwidthMbps": 0, "wifiSignalPercent": -1, "apiLevel": 34]

        case ("CapacitorHttp", _):
            try request(call, o)
            return nil

        case ("Filesystem", "checkPermissions"), ("Filesystem", "requestPermissions"): return ["publicStorage": "granted"]
        case ("Filesystem", "downloadFile"):
            guard let url = o["url"] as? String else { throw Refusal(message: "url is needed") }
            let target = try file(o)
            _ = try files.download(url, to: target, headers: o["headers"] as? [String: Any] ?? [:]) { [weak self] d, state, error in
                guard let self else { return }
                if o["progress"] as? Bool ?? false {
                    self.notify("Filesystem", "progress", ["url": d.url, "bytes": d.received, "contentLength": d.expected])
                }
                switch state {
                case "completed": self.resolve(call, ["path": target.path])
                case "failed", "cancelled": self.reject(call, error ?? "The download failed")
                default: break
                }
            }
            return nil
        case ("Filesystem", _): return try filesystem(call.method, o)

        default:
            throw Refusal(message: "\(call.plugin).\(call.method) isn't available in Halliday")
        }
    }

    /// An id for this installation of the app, made once.
    private var deviceID: String {
        let file = data.appendingPathComponent(".halliday-device-id")
        if let known = try? String(contentsOf: file, encoding: .utf8), !known.isEmpty { return known }
        let id = UUID().uuidString.lowercased()
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    // --- The page's requests to the app's own servers ---

    /// The origin an Android web view would have given the page: what the app's servers allow.
    private var androidOrigin: String { files.origin }
    /// One session for the app, with the cookies its servers set (kept, as a browser keeps them).
    private var http: URLSession { files.http }

    /// A request the page makes, sent for it (Capacitor's `CapacitorHttp.request`): only to
    /// http(s) addresses, with the page's own headers and body, answered as the bridge script
    /// expects (JSON parsed, text as text, anything else base64).
    private func request(_ call: Call, _ o: [String: Any]) throws {
        guard let text = o["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw Refusal(message: "Not an http address")
        }
        var r = URLRequest(url: url)
        r.httpMethod = (o["method"] as? String ?? call.method).uppercased()
        if r.httpMethod == "REQUEST" { r.httpMethod = "GET" }
        for (name, value) in o["headers"] as? [String: Any] ?? [:] {
            if let value = value as? String { r.setValue(value, forHTTPHeaderField: name) }
        }
        r.setValue(androidOrigin, forHTTPHeaderField: "Origin")
        r.setValue(androidOrigin + "/", forHTTPHeaderField: "Referer")
        let kind = o["dataType"] as? String ?? ""
        if let body = o["data"], !(body is NSNull), r.httpMethod != "GET", r.httpMethod != "HEAD" {
            if kind == "formData" { throw Refusal(message: "Form uploads aren't available in Halliday yet") }
            if let string = body as? String {
                r.httpBody = kind == "file" ? Data(base64Encoded: string, options: .ignoreUnknownCharacters) : Data(string.utf8)
            } else if JSONSerialization.isValidJSONObject(body) {
                r.httpBody = try JSONSerialization.data(withJSONObject: body)
                if r.value(forHTTPHeaderField: "Content-Type") == nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            }
        }
        let started = CACurrentMediaTime()
        let method = r.httpMethod ?? "GET"
        http.dataTask(with: r) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                guard let response = response as? HTTPURLResponse, let data else {
                    if Self.uiLog { log("[app-web] \(method) \(url.host ?? "") failed: \(error?.localizedDescription ?? "no answer")") }
                    self.reject(call, error?.localizedDescription ?? "The request failed")
                    return
                }
                var headers: [String: String] = [:]
                for (name, value) in response.allHeaderFields { headers["\(name)"] = "\(value)" }
                let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                let body: Any
                if type.hasPrefix("application/json"), let json = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
                    body = json
                } else if let text = String(data: data, encoding: .utf8) {
                    body = text
                } else {
                    body = data.base64EncodedString()
                }
                if Self.uiLog {
                    log(String(format: "[app-web] %d %@ %@%@ (%d bytes, %.0f ms)", response.statusCode, method, url.host ?? "", url.path, data.count, (CACurrentMediaTime() - started) * 1000))
                }
                self.resolve(call, ["status": response.statusCode, "headers": headers, "url": response.url?.absoluteString ?? text, "data": body])
            }
        }.resume()
    }

    // --- The player ---

    /// The player ended: the app's extensions hear of it (and tell the page as they need).
    func playerEnded(status: Int32) {
        for x in extensions { x.playerEnded(status: status) }
    }

    // --- Files: the app's own folder, and nothing else ---

    private func inside(_ path: String) throws -> URL { try files.inside(path) }
    private func address(_ file: URL) -> String { files.address(file) }

    /// Capacitor's (path, directory) as a file: each directory is a folder of the app's data.
    private func file(_ o: [String: Any], path key: String = "path", directory dkey: String = "directory") throws -> URL {
        let path = o[key] as? String ?? ""
        guard let directory = o[dkey] as? String, !directory.isEmpty else { return try inside(path) }
        guard directory.allSatisfy({ $0.isLetter || $0 == "_" }) else { throw Refusal(message: "Unknown directory") }
        let base = data.appendingPathComponent(directory.lowercased())
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try inside(base.appendingPathComponent(path).path)
    }

    private func entry(_ url: URL) throws -> [String: Any] {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw Refusal(message: "File does not exist") }
        let ms = { (d: Any?) in Int(((d as? Date)?.timeIntervalSince1970 ?? 0) * 1000) }
        return ["name": url.lastPathComponent, "type": (a[.type] as? FileAttributeType) == .typeDirectory ? "directory" : "file",
                "size": (a[.size] as? NSNumber)?.intValue ?? 0, "ctime": ms(a[.creationDate]), "mtime": ms(a[.modificationDate]),
                "uri": address(url)]
    }

    private func filesystem(_ method: String, _ o: [String: Any]) throws -> [String: Any] {
        let fm = FileManager.default
        switch method {
        case "getUri": return ["uri": address(try file(o))]
        case "stat": return try entry(try file(o))
        case "readdir":
            let folder = try file(o)
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { throw Refusal(message: "Directory does not exist") }
            return ["files": try names.sorted().map { try entry(folder.appendingPathComponent($0)) }]
        case "mkdir":
            try fm.createDirectory(at: try file(o), withIntermediateDirectories: o["recursive"] as? Bool ?? false)
            return [:]
        case "rmdir", "deleteFile":
            let target = try file(o)
            // (Never the data folder itself, nor one of its top folders.)
            guard target.path != data.path, target.deletingLastPathComponent().path != data.path || method == "deleteFile" else {
                throw Refusal(message: "That folder can't be removed")
            }
            guard fm.fileExists(atPath: target.path) else { throw Refusal(message: "File does not exist") }
            if method == "rmdir", !(o["recursive"] as? Bool ?? false),
               let inside = try? fm.contentsOfDirectory(atPath: target.path), !inside.isEmpty {
                throw Refusal(message: "Folder is not empty")
            }
            try fm.removeItem(at: target)
            return [:]
        case "writeFile", "appendFile":
            let target = try file(o)
            if o["recursive"] as? Bool ?? false {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            let text = o["data"] as? String ?? ""
            // With an encoding the data is text; without, base64.
            guard let bytes = o["encoding"] is String ? Data(text.utf8) : Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                throw Refusal(message: "The data isn't base64")
            }
            if method == "appendFile", let handle = try? FileHandle(forWritingTo: target) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: bytes)
            } else {
                try bytes.write(to: target, options: .atomic)
            }
            return ["uri": address(target)]
        case "readFile":
            guard let bytes = try? Data(contentsOf: try file(o)) else { throw Refusal(message: "File does not exist") }
            return ["data": o["encoding"] is String ? String(decoding: bytes, as: UTF8.self) : bytes.base64EncodedString()]
        case "rename", "copy":
            var to = o
            if o["toDirectory"] == nil { to["toDirectory"] = o["directory"] }
            let (source, target) = (try file(o, path: "from"), try file(to, path: "to", directory: "toDirectory"))
            guard fm.fileExists(atPath: source.path) else { throw Refusal(message: "File does not exist") }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if method == "rename" { try fm.moveItem(at: source, to: target) } else { try fm.copyItem(at: source, to: target) }
            return ["uri": address(target)]
        case "downloadFile":
            // Answered when the file is there (see `handle`: this one call is taken there).
            throw Refusal(message: "Filesystem.downloadFile needs its call")
        default:
            throw Refusal(message: "Filesystem.\(method) isn't available in Halliday")
        }
    }


}
