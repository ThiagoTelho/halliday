# Extensions

An extension adapts Halliday to one app without changing Halliday. It is a small folder of
JSON and JavaScript that the user installs from the companion (Halliday's window on the Mac's
screen, section **Extensions**). Halliday's own code stays general: what only one app needs lives
in an extension, never in Halliday's source.

This guide is also inside Halliday: the companion shows it under **Making an extension**, and
**Save the example…** there saves the example below, ready to change.

## What extensions are for

Version 1 has one kind: **Quest app adapters**. Some Quest apps come in two halves: a web
interface (a Capacitor application inside the APK) and a native VR player that the interface
starts with what to play. Halliday runs the interface in its browser and answers Capacitor's
standard plugins itself (`Device`, `NetworkInfo`, `Filesystem`, `CapacitorHttp`). The app's own
plugins (its launcher, its downloads) are the app's own business, and only an extension for that
app answers them. The extension can also start the app's player with the session it builds, and
tell Klepton's runner how to answer the player's own Java methods.

An app with a web interface and no extension still opens: its page loads, and every call to a
plugin nobody answers is refused with a message naming the plugin and method. With
`--app-web-log` Halliday logs every call the page makes, which is where writing an adapter starts.

## What an extension can and cannot do

The script runs in a JavaScriptCore context of its own: no web page, no DOM, no `fetch`, no
`XMLHttpRequest`, no file system, no `setTimeout`, no `require`. All it can reach is the
`halliday` object, which it can't change.

| It can | It cannot |
|---|---|
| Answer the page's calls to the plugins its manifest declares | Answer any other plugin, or the calls of an app it doesn't name |
| Send events to the page's listeners of those plugins | Read or change the page |
| Start the app's player with a session it builds | Start any other program |
| Download into the app's folder, from the hosts its manifest lists | Reach any other host, or anything for itself |
| Unzip, unpack and delete files inside the app's folder | Read or write outside that folder |
| Keep values in memory while the app's page is open | Keep anything once the page closes |
| Tell the runner how to answer the player's Java methods, from a fixed set of answers | Run code inside the runner |

Extensions with native code (a library loaded into Halliday) are not supported, on purpose:
Halliday holds the Screen Recording and Accessibility permissions, and code loaded into it would
hold them too.

## The folder

```
Example.hallidayext/
├── manifest.json
└── main.js
```

A folder (its name ending in `.hallidayext` by convention), or a `.zip` of one. Installing copies
it to `~/Library/Application Support/Halliday/Extensions/<id>/`.

### manifest.json

```json
{
  "id": "org.example.launcher-adapter",
  "name": "Example Launcher adapter",
  "version": "1.0.0",
  "author": "Example",
  "description": "Answers the made-up Example VR app's launcher and downloads plugins.",
  "halliday": 1,
  "apps": ["com.example.vr"],
  "plugins": {
    "ExampleLauncher": ["launch", "setUser", "exitData", "acknowledgeExit", "addListener", "removeListener"],
    "ExampleDownloads": ["start", "cancel", "addListener", "removeListener"]
  },
  "network": ["cdn.example.com", "*.content.example.com"],
  "runner": {
    "java": [
      { "method": "getSession", "signature": "()Ljava/lang/String;", "answer": "session" },
      { "method": "sessionEnded", "signature": "(ILjava/lang/String;)V", "answer": "end" },
      { "method": "logEvent", "signature": "(ILjava/lang/String;)V", "answer": "ignore" }
    ]
  },
  "main": "main.js"
}
```

| Field | Meaning |
|---|---|
| `id` | Reverse-DNS, unique. Installing an extension whose `id` is already installed replaces it. |
| `name`, `version` | Shown in the companion. Required. |
| `author`, `description` | Shown before installing. The author is what the manifest says: nothing checks it. |
| `halliday` | The API version the extension was written for: 1. A newer one is refused. |
| `apps` | The Quest packages it adapts: exact names, or a prefix ending in `.*`. |
| `plugins` | The page's plugins it answers, and their methods: what the page is told exists. `addListener` and `removeListener` are answered by Halliday; list them if the page uses them. A plugin Halliday answers itself can't be taken over. |
| `network` | The hosts `halliday.files.download` may reach: exact names, `*.domain` for any subdomain, or `*` for any host (shown to the user with a warning). Missing or empty: no network at all. |
| `runner.java` | Java methods of the player's activity, by name and JNI signature, and how the runner answers each (below). |
| `main` | The script, inside the folder. `main.js` if left out. |

Every problem in a manifest is reported at once, when checking or installing.

### main.js

```js
let user = "";      // who is signed in, as the page said
let exit = null;    // how the player last ended, until the page takes it

halliday.answer("ExampleLauncher", {
  // A method's answer is what it returns: an object (or a Promise of one). Throwing refuses it.
  setUser(options) {
    user = options.userId || "";
    return {};
  },

  launch(options) {
    if (typeof options.scene !== "string") throw new Error("scene is needed");
    const scene = JSON.parse(options.scene);
    if (user) scene.user = user;
    halliday.player.launch({
      session: JSON.stringify(scene),           // what the player's getSession() returns
      extras: { appName: halliday.app.name },   // Intent.getStringExtra(key)
    });
    return {};
  },

  exitData() { return { result: exit }; },
  acknowledgeExit() { exit = null; return {}; },
});

// The player ended (status 0: as it should): tell the page, as the app's Android side would.
halliday.player.onEnded((status) => {
  exit = { status };
  halliday.emit("ExampleLauncher", "exit", {});
});

halliday.answer("ExampleDownloads", {
  // Answered later: nothing returned now, `call.resolve` or `call.reject` when it is done.
  start(options, call) {
    const id = halliday.files.download(options.url, options.path, {
      headers: options.headers,
      onProgress: (p) => halliday.emit("ExampleDownloads", "progress", { id, received: p.received, total: p.total }),
      onEnd: (r) => (r.ok ? call.resolve({ id }) : call.reject(r.error)),
    });
  },
  cancel(options) {
    halliday.files.cancel(options.id);
    return {};
  },
});
```

This is `extensions/example/` in Halliday's source.

## The `halliday` API (version 1)

A method's answer is what it returns: an object, or a `Promise` of one. A thrown `Error` refuses
the call with its message. A method that returns nothing answers later, through `call`.

| | |
|---|---|
| `halliday.answer(plugin, methods)` | Answers the page's calls to `plugin`, a plugin the manifest declares. `methods` maps each method's name to `(options, call) => answer`. |
| `call.resolve(data)`, `call.reject(message)` | Answers a call later. `call.plugin` and `call.method` say which. |
| `halliday.emit(plugin, event, data)` | Sends `event` to the page's listeners on `plugin` (one of the manifest's). |
| `halliday.app` | `{ name, package, version }` of the app being adapted. |
| `halliday.player.launch({ session, extras })` | Starts the app's player. `session` (a string) is what the `"session"` Java answer returns. `extras` (strings, numbers, booleans) are what `Intent.getStringExtra` returns. |
| `halliday.player.onEnded(fn)` | `fn(status)` when the player ends (0: as it should). |
| `halliday.files.download(url, path, { headers, onProgress, onEnd })` | Downloads `url` (http or https, on a host in `network`) to `path` in the app's folder. `onProgress({ received, total, speed })` twice a second, `onEnd({ ok, status, error, received, total })` once, `status` being `"completed"`, `"failed"` or `"cancelled"`. Returns the download's id. |
| `halliday.files.cancel(id)` | Stops a download (its `onEnd` says `"cancelled"`). |
| `halliday.files.unzip(zip, folder)` | Unzips. Returns a `Promise`. |
| `halliday.files.unpack(from, to, { kind, onProgress })` | Unpacks a file packed with xz, zstd or OpenZL, found from its first bytes (`kind` is only for the log). `onProgress(percent)`. Returns a `Promise`. |
| `halliday.files.remove(path)` | Deletes a file or folder in the app's folder. |
| `halliday.files.path(p)` | The absolute path for `p`; throws when it is outside the app's folder. |
| `halliday.uuid()` | A new random id. |
| `halliday.later(ms, fn)` | Calls `fn` once, after `ms`. |
| `halliday.log(text)` | A line in Halliday's log, tagged with the extension's id. |
| `halliday.api` | The API version: 1. |

Paths are absolute paths, `file://` addresses, or paths relative to the app's data folder.
Anything that resolves outside the app's folder is refused.

### The runner's Java answers

| `answer` | For a method returning | What the runner does |
|---|---|---|
| `"session"` | `String` | Returns the `session` given to `halliday.player.launch`. |
| `"end"` | `void` | The session is over: the player ends, with the method's first `int` as its status when its signature starts with one (0: as it should), and `halliday.player.onEnded` hears of it. |
| `"ignore"` | `void` | Nothing (logged once). |
| `"false"`, `"true"`, `"zero"` | `boolean` or `int` | Returns that. |
| `"empty"` | `String` | Returns `""`. |

The answers apply to a player started by `halliday.player.launch`. `Intent.getStringExtra(key)` is
answered from the launch's `extras` for every app: nothing to declare. Signatures are JNI's, as
`dexdump -d classes.dex` (Android build-tools) prints them.

## Checking and installing

From a terminal (`build/Halliday.app/Contents/MacOS/halliday`, or the installed app's):

```sh
halliday --check-extension Example.hallidayext \
  --call ExampleLauncher.setUser '{"userId":"u1"}' \
  --call ExampleLauncher.launch '{"scene":"{\"level\":1}"}'
halliday --install-extension Example.hallidayext
```

Both also take a GitHub link, fetched as the companion fetches it. `--check-extension` checks the
manifest, runs `main.js` against a stand-in app (an empty folder,
deleted after), says which declared methods have no answer, makes the calls given and prints every
answer, refusal, event and launch, then pretends the player ended. Nothing is installed.

In the companion, **Install…** (or a folder or `.zip` dropped on its window), or a GitHub link
pasted under **Or from GitHub** (or dropped from a browser), reads and checks the extension, then
shows what it is before copying anything: its name and version, the author as the
manifest gives it, the apps it adapts, the plugins it answers and the hosts it may download from,
with *"Extensions are code from their authors, not Halliday's. Install only extensions you
trust."* Each installed extension has a switch (off keeps it but doesn't use it), **Show files**
and **Remove**. A change applies the next time its app is opened.

## Publishing on GitHub

To share an extension, put it on GitHub: `manifest.json` and `main.js` at the top of a public
repository, or in a folder of one. People install it by pasting its link in the companion:

| Link | Installs |
|---|---|
| `https://github.com/OWNER/REPO` | The extension at the top of the default branch, or in the one folder of it that holds one |
| `https://github.com/OWNER/REPO/tree/REF` | The same, from a branch, tag or commit |
| `https://github.com/OWNER/REPO/tree/REF/FOLDER` | The extension in that folder (for a repository holding several) |

Halliday fetches the repository's archive once (at most 25 MB), finds the extension, and shows
the same sheet as for a folder, with where it came from. The companion then lists the link beside
the extension. There are no automatic updates: pasting the link again installs the version on
GitHub now, replacing the one installed. Link to a tag (a release) when the version matters. A
branch whose name has a slash in it can't be told from a folder: link to a tag or a commit.

Extensions hold plain files only: one with a symbolic link in it is refused, as is one over 2000
files or 50 MB.

## Privacy

Halliday's privacy promise is about Halliday's own code. With extensions:

- An extension reaches the network only through `halliday.files.download`, only to the hosts its
  manifest lists, and only while its app is open. That one path is in Halliday's privacy check
  (`tools/check-privacy.sh`, `QuestAppFiles.swift`).
- The user sees those hosts before installing. Halliday logs each host an extension downloads
  from, once (`[extension] … downloading from HOST`), which is how an author narrows `network`.
- There is no extension store and no updates. Halliday fetches an extension only when the user
  gives it a GitHub link, from GitHub, once, without cookies (`ExtensionFromGitHub.swift`, in the
  privacy check).
- What extensions are installed and which are off stays on the Mac (PRIVACY.md).

## Inside Halliday

| Piece | What it does |
|---|---|
| `Extensions.swift` | The manifest and its checks; installing, listing, switching and removing; the extensions for an app. |
| `ExtensionHost.swift` | One JavaScriptCore context per extension per open app, and the `halliday` object. |
| `QuestAppFiles.swift` | The app's folder: paths, downloads, unzipping and unpacking, for the page's `Filesystem` and for extensions. |
| `QuestAppWeb.swift` | Capacitor's standard plugins; calls of the plugins an extension declares go to it. |
| `QuestApps.launch` | Writes the runner's Java answers to a file named by `KL_APP_JAVA`, beside `KL_APP_SESSION` and `KL_APP_EXTRAS`. |
| `tools/klepton-halliday.patch` | `kl_jni_appsession.c` answers from that file: no method name is written in it. |
| `CompanionExtensions.swift` | The companion's Extensions section, the install sheet and this guide. |
| `ExtensionFromGitHub.swift` | A GitHub link: the repository's archive fetched once, the extension found in it. |
| `ExtensionCheck.swift` | `--check-extension` and `--install-extension` (a folder, a `.zip` or a GitHub link). |
| `extensions/example/` | The example, copied into Halliday's bundle for **Save the example…**. |

Adding to the API: a function in `ExtensionHost.install`, its row in the table above, and
`ExtensionManifest.apiVersion` raised when something an older script relies on changes.
