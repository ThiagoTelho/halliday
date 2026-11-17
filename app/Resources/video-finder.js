// Halliday's video finder (ROADMAP W9 9.2): reports the <video> elements of a page (and its
// frames) to Halliday, so "Watch in VR" can open the page's video in the native player.
// Injected at document end into every frame of Halliday's browser. Written for Halliday (MIT).

(() => {
  "use strict";
  if (window.__hallidayVideos) return;

  const post = (msg) => {
    try { window.webkit.messageHandlers.halliday.postMessage(msg); } catch (_) { /* not in Halliday */ }
  };

  function sourceOf(v) {
    let src = v.currentSrc || v.src || "";
    if (!src) {
      const s = v.querySelector("source[src]");
      if (s) src = s.src;
    }
    return src;
  }

  function collect() {
    const items = [];
    for (const v of document.querySelectorAll("video")) {
      const src = sourceOf(v);
      if (!src) continue;
      const r = v.getBoundingClientRect();
      items.push({
        src,
        width: v.videoWidth || 0,
        height: v.videoHeight || 0,
        duration: Number.isFinite(v.duration) ? v.duration : 0,
        time: v.currentTime || 0,
        playing: !v.paused && !v.ended,
        area: Math.round(r.width * r.height),
      });
    }
    return items;
  }

  let last = "", timer = 0;
  function report() {
    const items = collect();
    const key = JSON.stringify(items.map((i) => [i.src, i.width, i.height, i.playing]));
    if (key === last) return;
    last = key;
    post({ type: "videos", frame: location.href, title: document.title, items });
  }
  const schedule = () => { clearTimeout(timer); timer = setTimeout(report, 300); };

  new MutationObserver(schedule).observe(document.documentElement, {
    subtree: true, childList: true, attributes: true, attributeFilter: ["src"],
  });
  for (const type of ["loadedmetadata", "play", "pause", "emptied"]) document.addEventListener(type, schedule, true);
  schedule();

  window.__hallidayVideos = {
    // Pauses this frame's videos (called when the video moves to Halliday's player).
    pause: () => { for (const v of document.querySelectorAll("video")) v.pause(); },
  };
})();
