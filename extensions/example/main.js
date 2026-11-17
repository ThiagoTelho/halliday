// Example Launcher adapter: an extension for a made-up Quest app, "Example VR" (com.example.vr),
// to start a real one from. docs/extensions.md describes every part of it.
//
// The app's page (its web interface) calls two plugins of its own: ExampleLauncher, to start the
// VR player, and ExampleDownloads, to fetch content. Halliday doesn't know them; this script
// answers them. Check it with:
//
//   halliday --check-extension extensions/example \
//     --call ExampleLauncher.setUser '{"userId":"u1"}' \
//     --call ExampleLauncher.launch '{"scene":"{\"level\":1}"}'

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
  // addListener and removeListener are Halliday's: no answer needed.
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
