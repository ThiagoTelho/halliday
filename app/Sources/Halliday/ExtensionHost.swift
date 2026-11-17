// Runs one extension for one open app (docs/extensions.md): its script in a JavaScriptCore
// context of its own, and the `halliday` object, which is all the script can reach.
//
// The context has no page, no DOM, no network and no file system: JavaScriptCore alone gives it
// none of those. What the script does to the world goes through the functions set up in
// `install`, each of which checks what it is given: plugins the manifest declares, paths inside
// the app's folder, download hosts the manifest lists.
//
// How to write the script: docs/extensions.md ("The `halliday` API"), and
// extensions/example/main.js. Adding to the API: a function here, its row in that table, and
// `ExtensionManifest.apiVersion` raised when something an older script relies on changes.
//
// Threading: everything here, the script included, runs on the main thread. Work that takes
// time (downloads, unpacking) runs elsewhere and comes back to the main thread to call the script.

import Foundation
import JavaScriptCore

@MainActor
final class ExtensionHost {
    let installed: InstalledExtension
    var manifest: ExtensionManifest { installed.manifest }
    let app: QuestApp
    let files: QuestAppFiles

    /// To the page: a call's answer, a refusal, an event for the listeners of a plugin.
    var resolve: ((_ callID: String, _ plugin: String, _ method: String, _ data: [String: Any]) -> Void)?
    var reject: ((_ callID: String, _ plugin: String, _ method: String, _ message: String) -> Void)?
    var emit: ((_ plugin: String, _ event: String, _ data: [String: Any]) -> Void)?
    /// "Launch in VR": the files holding the session and the extras, for the runner.
    var onLaunch: ((_ session: URL, _ extras: URL) -> Void)?

    private let context: JSContext
    /// The script's answers, by plugin: an object of functions.
    private var answers: [String: JSValue] = [:]
    private var endedHandlers: [JSValue] = []
    /// Whether the script ran to its end without throwing.
    private(set) var loaded = false
    private(set) var problem: String?

    init(_ installed: InstalledExtension, app: QuestApp, files: QuestAppFiles) {
        self.installed = installed
        self.app = app
        self.files = files
        context = JSContext()
        context.name = "Halliday extension \(installed.manifest.id)"
        let id = installed.manifest.id
        context.exceptionHandler = { context, exception in
            // Kept for whoever made the call (`call` below), and logged.
            context?.exception = exception
            log("[extension] \(id): \(exception?.toString() ?? "an exception")")
        }
        install()
        let script = installed.folder.appendingPathComponent(manifest.main)
        guard let source = try? String(contentsOf: script, encoding: .utf8) else {
            problem = "Its script, \(manifest.main), can't be read"
            return
        }
        context.exception = nil
        context.evaluateScript(source, withSourceURL: script)
        if let e = context.exception {
            problem = "Its script stopped: \(e.toString() ?? "an exception")"
            context.exception = nil
        } else {
            loaded = true
        }
    }

    /// Whether this extension answers `plugin` (the manifest declares it).
    func declares(_ plugin: String) -> Bool { manifest.plugins.contains { $0.name == plugin } }

    /// Whether its script answers `method` of `plugin` (for `--check-extension`).
    func answers(_ plugin: String, _ method: String) -> Bool {
        guard let fn = answers[plugin]?.forProperty(method) else { return false }
        return fn.isObject && !fn.isUndefined
    }

    /// A call of the page's to one of this extension's plugins. Answered through `resolve` or
    /// `reject`, now or later.
    func call(id: String, plugin: String, method: String, options: [String: Any]) {
        guard loaded else {
            reject?(id, plugin, method, "The extension \(manifest.name) didn't load: \(problem ?? "")")
            return
        }
        guard let methods = answers[plugin], let fn = methods.forProperty(method), fn.isObject, !fn.isUndefined else {
            reject?(id, plugin, method, "\(plugin).\(method) isn't answered by the extension \(manifest.name)")
            return
        }
        let call = callObject(id: id, plugin: plugin, method: method)
        let arguments = JSValue(object: options, in: context) ?? JSValue(newObjectIn: context)!
        context.exception = nil
        let result = fn.call(withArguments: [arguments, call])
        if let e = context.exception {
            context.exception = nil
            reject?(id, plugin, method, message(of: e))
            return
        }
        guard let result, !result.isUndefined else { return } // answered later, through `call`
        if result.isObject, let then = result.forProperty("then"), !then.isUndefined, then.isObject {
            let ok: @convention(block) (JSValue?) -> Void = { [weak self] value in self?.answer(id, plugin, method, value) }
            let fail: @convention(block) (JSValue?) -> Void = { [weak self] error in
                guard let self else { return }
                self.reject?(id, plugin, method, error.map { self.message(of: $0) } ?? "Refused")
            }
            result.invokeMethod("then", withArguments: [JSValue(object: ok, in: context)!, JSValue(object: fail, in: context)!])
        } else {
            answer(id, plugin, method, result)
        }
    }

    /// The player ended: the script's `halliday.player.onEnded` functions hear of it.
    func playerEnded(status: Int32) {
        for fn in endedHandlers { fn.call(withArguments: [Int(status)]) }
    }

    // --- Answers ---

    private func answer(_ id: String, _ plugin: String, _ method: String, _ value: JSValue?) {
        guard let value, !value.isUndefined, !value.isNull else { resolve?(id, plugin, method, [:]); return }
        guard let object = value.toObject() as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            reject?(id, plugin, method, "The extension's answer to \(plugin).\(method) isn't an object")
            return
        }
        resolve?(id, plugin, method, object)
    }

    private func message(of error: JSValue) -> String {
        if error.isObject, let m = error.forProperty("message"), m.isString { return m.toString() }
        return error.toString() ?? "Refused"
    }

    /// The `call` handed to an answer, to answer later: `resolve(data)` and `reject(message)`.
    private func callObject(id: String, plugin: String, method: String) -> JSValue {
        let o = JSValue(newObjectIn: context)!
        let ok: @convention(block) (JSValue?) -> Void = { [weak self] value in self?.answer(id, plugin, method, value) }
        let fail: @convention(block) (JSValue?) -> Void = { [weak self] error in
            guard let self else { return }
            self.reject?(id, plugin, method, error.map { self.message(of: $0) } ?? "Refused")
        }
        o.setObject(ok, forKeyedSubscript: "resolve" as NSString)
        o.setObject(fail, forKeyedSubscript: "reject" as NSString)
        o.setObject(plugin, forKeyedSubscript: "plugin" as NSString)
        o.setObject(method, forKeyedSubscript: "method" as NSString)
        return o
    }

    // --- The `halliday` object ---

    /// Throws `message` into the script, from inside one of the functions below.
    private static func fail(_ message: String) {
        guard let c = JSContext.current() else { return }
        c.exception = JSValue(newErrorFromMessage: message, in: c)
    }

    private func install() {
        let h = JSValue(newObjectIn: context)!
        let id = manifest.id

        let answer: @convention(block) (String, JSValue) -> Void = { [weak self] plugin, methods in
            guard let self else { return }
            guard self.declares(plugin) else {
                Self.fail("\(plugin) isn't one of the plugins the manifest declares")
                return
            }
            guard methods.isObject else { Self.fail("halliday.answer needs an object of functions"); return }
            self.answers[plugin] = methods
        }
        h.setObject(answer, forKeyedSubscript: "answer" as NSString)

        let emit: @convention(block) (String, String, JSValue?) -> Void = { [weak self] plugin, event, data in
            guard let self else { return }
            guard self.declares(plugin) else { Self.fail("\(plugin) isn't one of the plugins the manifest declares"); return }
            self.emit?(plugin, event, (data?.toObject() as? [String: Any]) ?? [:])
        }
        h.setObject(emit, forKeyedSubscript: "emit" as NSString)

        h.setObject(["name": app.name, "package": app.package, "version": app.version], forKeyedSubscript: "app" as NSString)

        let say: @convention(block) (JSValue?) -> Void = { text in log("[extension] \(id): \(text?.toString() ?? "")") }
        h.setObject(say, forKeyedSubscript: "log" as NSString)

        let uuid: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        h.setObject(uuid, forKeyedSubscript: "uuid" as NSString)

        let later: @convention(block) (Double, JSValue) -> Void = { ms, fn in
            guard fn.isObject else { Self.fail("halliday.later needs a function"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, ms) / 1000) { fn.call(withArguments: []) }
        }
        h.setObject(later, forKeyedSubscript: "later" as NSString)

        // The player.
        let player = JSValue(newObjectIn: context)!
        let launch: @convention(block) (JSValue) -> Void = { [weak self] o in
            guard let self else { return }
            do { try self.launch(o) } catch { Self.fail("\(error)") }
        }
        player.setObject(launch, forKeyedSubscript: "launch" as NSString)
        let onEnded: @convention(block) (JSValue) -> Void = { [weak self] fn in
            guard fn.isObject else { Self.fail("halliday.player.onEnded needs a function"); return }
            self?.endedHandlers.append(fn)
        }
        player.setObject(onEnded, forKeyedSubscript: "onEnded" as NSString)
        h.setObject(player, forKeyedSubscript: "player" as NSString)

        // Files, inside the app's folder only.
        let f = JSValue(newObjectIn: context)!
        let path: @convention(block) (String) -> String? = { [weak self] p in
            guard let self else { return nil }
            do { return try self.files.inside(p).path } catch { Self.fail("\(error)"); return nil }
        }
        f.setObject(path, forKeyedSubscript: "path" as NSString)
        let remove: @convention(block) (String) -> Void = { [weak self] p in
            guard let self else { return }
            do {
                let target = try self.files.inside(p)
                guard target.path != self.files.data.path else { Self.fail("The app's folder itself can't be removed"); return }
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            } catch { Self.fail("\(error)") }
        }
        f.setObject(remove, forKeyedSubscript: "remove" as NSString)
        let download: @convention(block) (String, String, JSValue?) -> String? = { [weak self] url, p, o in
            guard let self else { return nil }
            do { return try self.download(url, p, o) } catch { Self.fail("\(error)"); return nil }
        }
        f.setObject(download, forKeyedSubscript: "download" as NSString)
        let cancel: @convention(block) (String) -> Void = { [weak self] d in self?.files.cancel(d) }
        f.setObject(cancel, forKeyedSubscript: "cancel" as NSString)
        let unzip: @convention(block) (String, String) -> JSValue? = { [weak self] zip, folder in
            guard let self, let c = JSContext.current() else { return nil }
            return JSValue(newPromiseIn: c) { resolve, reject in
                do {
                    let (from, to) = (try self.files.inside(zip), try self.files.inside(folder))
                    self.files.unzip(from, to: to) { failure in
                        if let failure { reject?.call(withArguments: [JSValue(newErrorFromMessage: failure, in: c)!]) } else { resolve?.call(withArguments: []) }
                    }
                } catch {
                    reject?.call(withArguments: [JSValue(newErrorFromMessage: "\(error)", in: c)!])
                }
            }
        }
        f.setObject(unzip, forKeyedSubscript: "unzip" as NSString)
        let unpack: @convention(block) (String, String, JSValue?) -> JSValue? = { [weak self] from, to, o in
            guard let self, let c = JSContext.current() else { return nil }
            let onProgress = o?.forProperty("onProgress").flatMap { $0.isObject ? $0 : nil }
            let kind = o?.forProperty("kind").flatMap { $0.isString ? $0.toString() : nil } ?? ""
            return JSValue(newPromiseIn: c) { resolve, reject in
                do {
                    let (source, target) = (try self.files.inside(from), try self.files.inside(to))
                    try self.files.unpack(source, to: target, kind: kind, progress: { percent in
                        onProgress?.call(withArguments: [percent])
                    }, done: { failure in
                        if let failure { reject?.call(withArguments: [JSValue(newErrorFromMessage: failure, in: c)!]) } else { resolve?.call(withArguments: []) }
                    })
                } catch {
                    reject?.call(withArguments: [JSValue(newErrorFromMessage: "\(error)", in: c)!])
                }
            }
        }
        f.setObject(unpack, forKeyedSubscript: "unpack" as NSString)
        h.setObject(f, forKeyedSubscript: "files" as NSString)

        h.setObject(ExtensionManifest.apiVersion, forKeyedSubscript: "api" as NSString)
        context.setObject(h, forKeyedSubscript: "halliday" as NSString)
        // The object itself can't be replaced or changed by the script.
        context.evaluateScript("Object.freeze(halliday.player); Object.freeze(halliday.files); Object.freeze(halliday.app); Object.freeze(halliday);")
    }

    /// `halliday.files.download(url, path, { headers, onProgress, onEnd })`.
    private func download(_ address: String, _ path: String, _ o: JSValue?) throws -> String {
        guard let url = URL(string: address), let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw AppRefusal(message: "Not an http address")
        }
        guard manifest.allows(host: host) else {
            throw AppRefusal(message: "\(host) isn't one of the hosts the manifest lists")
        }
        // Which hosts an extension reaches, once each: what an author narrows "network" from.
        if reached.insert(host).inserted { log("[extension] \(manifest.id): downloading from \(host)") }
        let target = try files.inside(path)
        let headers = o?.forProperty("headers")?.toObject() as? [String: Any] ?? [:]
        let onProgress = o?.forProperty("onProgress").flatMap { $0.isObject ? $0 : nil }
        let onEnd = o?.forProperty("onEnd").flatMap { $0.isObject ? $0 : nil }
        return try files.download(address, to: target, headers: headers) { d, state, error in
            if state == "downloading" {
                onProgress?.call(withArguments: [["received": d.received, "total": d.expected, "speed": d.speed]])
            } else {
                onEnd?.call(withArguments: [["ok": state == "completed", "status": state, "error": error ?? NSNull(),
                                             "received": d.received, "total": d.expected]])
            }
        }
    }

    private var reached: Set<String> = []

    /// `halliday.player.launch({ session, extras })`: the files the runner reads, then the player.
    private func launch(_ o: JSValue) throws {
        guard o.isObject, let session = o.forProperty("session"), session.isString else {
            throw AppRefusal(message: "halliday.player.launch needs { session: a string }")
        }
        let extras = o.forProperty("extras")?.toObject() as? [String: Any] ?? [:]
        let sessionFile = app.folder.appendingPathComponent("session-metadata")
        let extrasFile = app.folder.appendingPathComponent("session-extras")
        try session.toString().write(to: sessionFile, atomically: true, encoding: .utf8)
        let lines = extras.compactMap { key, value -> String? in
            guard !key.contains("="), !key.contains("\n") else { return nil }
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue
            return text.map { "\(key)=\($0.replacingOccurrences(of: "\n", with: " "))" }
        }
        try lines.sorted().joined(separator: "\n").appending("\n").write(to: extrasFile, atomically: true, encoding: .utf8)
        log("[extension] \(manifest.id): launch in VR (\(session.toString().utf8.count) bytes of session, \(lines.count) extras)")
        onLaunch?(sessionFile, extrasFile)
    }
}
