// Halliday's WebXR bridge (ROADMAP W9 9.3): a WebXR Device API implementation injected into pages
// of Halliday's browser at document start. Macs have no WebXR for headsets, so Halliday provides
// navigator.xr itself: head poses and per-eye optics come from Halliday each frame
// (window.__halliday.update / .configure), and the page renders both eyes side by side into its
// WebGL canvas, which Halliday shows in the headset (9.4).
//
// Scope: what pages and engines (three.js, A-Frame, Babylon.js) use for "immersive-vr" and
// "inline" sessions, plus one input source: Halliday's VR pointer (the mouse ray), exposed as a
// tracked pointer whose clicks are select events. WebXR Layers: projection layers from WebGL
// (XRWebGLBinding) and WebGPU (XRGPUBinding), and video layers (XRMediaBinding: quad, cylinder,
// equirect), composited by the bridge into the canvas Halliday shows. Not yet: real controllers,
// quad/cylinder layers from WebGL textures, hit testing.
// Written for Halliday (MIT); follows the WebXR Device API spec (W3C).

(() => {
  "use strict";
  if (navigator.xr) return; // a real implementation exists: leave it alone

  // --- Link to Halliday ---------------------------------------------------------------------

  const H = {
    // Head pose in Halliday's tracking space (meters; y up, -z forward; floor at y = 0), with the
    // id Halliday gave it: each immersive frame is stamped with the id of the pose it used.
    // r: the VR pointer's rotation relative to the head (the mouse ray).
    pose: { id: 0, p: [0, 1.65, 0], q: [0, 0, 0, 1], r: [0, 0, 0, 1] },
    // Optics: interpupillary distance (m) and per-eye FOV as tangents [left, right, up, down].
    cfg: { ipd: 0.064, fov: [[-1.84, 0.95, 1.33, -1.33], [-0.95, 1.84, 1.33, -1.33]], eyeSize: 1440 },
    // The canvas must fit on Halliday's virtual display (2880 points across, 2 pixels per point,
    // two eyes side by side), so an eye is at most this many pixels across.
    maxEye: 2816,
    // The headset's own resolution per eye (what getNativeFramebufferScaleFactor reaches).
    nativeEye: 2048,
    session: null,
    // Diagnostics: XR frames run and the views of the last viewer pose handed to the page.
    stats: { frames: 0, lastViews: 0 },
    // Diagnostics: which parts of WebXR input the page uses (reported in Halliday's log during a
    // session), to see why a page's controls don't react.
    usage: null,
  };
  function newUsage(init) {
    return { required: init.requiredFeatures ?? [], optional: init.optionalFeatures ?? [], listeners: new Set(),
             reads: {}, pointerPoses: 0, clicks: 0, reported: 0 };
  }
  function usageReport(session) {
    const u = H.usage;
    if (!u) return "";
    const on = ["select", "selectstart", "selectend", "squeeze", "squeezestart", "squeezeend", "inputsourceschange"]
      .filter((t) => typeof session["on" + t] === "function").map((t) => "on" + t);
    const reads = Object.entries(u.reads).map(([k, v]) => `${k}×${v}`).join(" ") || "none";
    return `xr usage: required [${u.required}] optional [${u.optional}] · listeners [${[...u.listeners, ...on]}] · ` +
           `input source reads: ${reads} · pointer poses asked: ${u.pointerPoses} · clicks sent: ${u.clicks}`;
  }
  Object.defineProperty(window, "__halliday", { value: H });
  H.update = (pose) => { H.pose = pose; };
  H.configure = (cfg) => { Object.assign(H.cfg, cfg); };
  H.end = () => { if (H.session) H.session.end(); };
  // Halliday's mouse button on the VR pointer: "down" → selectstart, "up" → selectend + select.
  H.select = (phase) => {
    const s = H.session;
    if (!s) return;
    s._pointer?._gamepad?._trigger(phase === "down");
    if (phase === "down" && H.usage) H.usage.clicks++;
    if (phase === "down") s._fireInput("selectstart");
    else { s._fireInput("selectend"); s._fireInput("select"); }
  };

  function post(msg) {
    try { window.webkit.messageHandlers.halliday.postMessage(msg); } catch (_) { /* not in Halliday */ }
  }
  for (const level of ["error", "warn"]) {
    const original = console[level];
    console[level] = function (...args) {
      post({ type: "console", level, text: args.map(String).join(" ").slice(0, 500) });
      return original.apply(this, args);
    };
  }

  // --- Math (column-major 4x4 matrices, like WebGL) -----------------------------------------

  const identity = () => new Float32Array([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]);

  function fromPose(p, q) {
    const [x, y, z, w] = q;
    const m = new Float32Array(16);
    m[0] = 1 - 2 * (y * y + z * z); m[1] = 2 * (x * y + z * w); m[2] = 2 * (x * z - y * w); m[3] = 0;
    m[4] = 2 * (x * y - z * w); m[5] = 1 - 2 * (x * x + z * z); m[6] = 2 * (y * z + x * w); m[7] = 0;
    m[8] = 2 * (x * z + y * w); m[9] = 2 * (y * z - x * w); m[10] = 1 - 2 * (x * x + y * y); m[11] = 0;
    m[12] = p[0]; m[13] = p[1]; m[14] = p[2]; m[15] = 1;
    return m;
  }

  function multiply(a, b) {
    const out = new Float32Array(16);
    for (let c = 0; c < 4; c++) {
      for (let r = 0; r < 4; r++) {
        out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
      }
    }
    return out;
  }

  // Inverse of a rigid transform (rotation + translation).
  function invertRigid(m) {
    const out = new Float32Array(16);
    out[0] = m[0]; out[1] = m[4]; out[2] = m[8];
    out[4] = m[1]; out[5] = m[5]; out[6] = m[9];
    out[8] = m[2]; out[9] = m[6]; out[10] = m[10];
    out[12] = -(out[0] * m[12] + out[4] * m[13] + out[8] * m[14]);
    out[13] = -(out[1] * m[12] + out[5] * m[13] + out[9] * m[14]);
    out[14] = -(out[2] * m[12] + out[6] * m[13] + out[10] * m[14]);
    out[15] = 1;
    return out;
  }

  function quatFromMatrix(m) {
    const t = m[0] + m[5] + m[10];
    let x, y, z, w;
    if (t > 0) {
      const s = 0.5 / Math.sqrt(t + 1);
      w = 0.25 / s; x = (m[6] - m[9]) * s; y = (m[8] - m[2]) * s; z = (m[1] - m[4]) * s;
    } else if (m[0] > m[5] && m[0] > m[10]) {
      const s = 2 * Math.sqrt(1 + m[0] - m[5] - m[10]);
      w = (m[6] - m[9]) / s; x = 0.25 * s; y = (m[4] + m[1]) / s; z = (m[8] + m[2]) / s;
    } else if (m[5] > m[10]) {
      const s = 2 * Math.sqrt(1 + m[5] - m[0] - m[10]);
      w = (m[8] - m[2]) / s; x = (m[4] + m[1]) / s; y = 0.25 * s; z = (m[9] + m[6]) / s;
    } else {
      const s = 2 * Math.sqrt(1 + m[10] - m[0] - m[5]);
      w = (m[1] - m[4]) / s; x = (m[8] + m[2]) / s; y = (m[9] + m[6]) / s; z = 0.25 * s;
    }
    return [x, y, z, w];
  }

  // Yaw-only rotation of a quaternion (for gravity-aligned reference spaces).
  function yawOnly(q) {
    const [x, y, z, w] = q;
    // Forward (-z) rotated by q, projected on the floor.
    const fx = -(2 * (x * z + y * w)), fz = -(1 - 2 * (x * x + y * y));
    const yaw = Math.atan2(-fx, -fz);
    return [0, Math.sin(yaw / 2), 0, Math.cos(yaw / 2)];
  }

  function projection(tan, near, far) {
    const [l, r, u, d] = tan;
    const m = new Float32Array(16);
    m[0] = 2 / (r - l);
    m[5] = 2 / (u - d);
    m[8] = (r + l) / (r - l);
    m[9] = (u + d) / (u - d);
    m[10] = -(far + near) / (far - near);
    m[11] = -1;
    m[14] = -2 * far * near / (far - near);
    return m;
  }

  // --- WebXR objects ------------------------------------------------------------------------

  class XRRigidTransform {
    constructor(position = {}, orientation = {}) {
      if (position instanceof Float32Array) { // internal: from a matrix
        this._m = position;
        const q = quatFromMatrix(position);
        this.position = new DOMPointReadOnly(position[12], position[13], position[14], 1);
        this.orientation = new DOMPointReadOnly(q[0], q[1], q[2], q[3]);
        return;
      }
      this.position = new DOMPointReadOnly(position.x ?? 0, position.y ?? 0, position.z ?? 0, 1);
      let { x = 0, y = 0, z = 0, w = 1 } = orientation;
      const n = Math.hypot(x, y, z, w) || 1;
      this.orientation = new DOMPointReadOnly(x / n, y / n, z / n, w / n);
    }
    get matrix() {
      if (!this._m) {
        const p = this.position, o = this.orientation;
        this._m = fromPose([p.x, p.y, p.z], [o.x, o.y, o.z, o.w]);
      }
      return this._m;
    }
    get inverse() { return new XRRigidTransform(invertRigid(this.matrix)); }
  }

  class XRSpace extends EventTarget {}

  class XRReferenceSpace extends XRSpace {
    // origin: matrix of this space's origin in Halliday's tracking space; viewer: follows the head.
    constructor(type, origin, viewer = false) {
      super();
      this._type = type;
      this._origin = origin;
      this._viewer = viewer;
      this.onreset = null;
    }
    getOffsetReferenceSpace(offset) {
      return new XRReferenceSpace(this._type, multiply(this._origin, offset.matrix), this._viewer);
    }
    // This space's origin in tracking space right now.
    _originNow() {
      return this._viewer ? multiply(H._headMatrix(), this._origin) : this._origin;
    }
  }

  // The pose of the frame being rendered (fixed for the whole frame), or the latest one.
  H._framePose = null;
  H._headMatrix = () => { const p = H._framePose ?? H.pose; return fromPose(p.p, p.q); };

  // --- Presenting the canvas to Halliday ----------------------------------------------------
  // While immersive, the canvas fills the page so Halliday's capture of the browser window shows it.
  // Each frame gets a stamp along the top edge (STAMP_OFFSET squares in): 16 squares with the pose id in binary
  // (white = 1), then a white and a black square as a marker. A square is 1/360 of the canvas
  // width, so Halliday finds it whatever resolution the canvas ends up displayed at. (The top edge,
  // because the window's bottom corners are rounded.)

  // The canvas goes into the browser's top layer (popover): pages often put their own "put on
  // your headset" screen over everything while a session runs, and a z-index can't beat an overlay
  // in another stacking context. The top layer is above all of the page, whatever its CSS.
  const PRESENT_STYLE = "position:fixed;inset:0;left:0;top:0;width:100vw;height:100vh;max-width:none;max-height:none;" +
    "margin:0;border:0;padding:0;z-index:2147483647;background:#000;display:block;visibility:visible;opacity:1;" +
    "transform:none;filter:none;clip-path:none;pointer-events:auto;";

  function present(canvas) {
    const saved = { style: canvas.getAttribute("style"), parent: canvas.parentNode, next: canvas.nextSibling,
                    popover: canvas.getAttribute("popover"), overflow: document.documentElement.style.overflow };
    let moved = false;
    const toBody = () => { (document.body ?? document.documentElement).appendChild(canvas); moved = true; };
    if (!canvas.isConnected) toBody();
    canvas.setAttribute("style", PRESENT_STYLE);
    const show = () => {
      try {
        canvas.setAttribute("popover", "manual");
        canvas.showPopover();
      } catch (e) { /* no popover support, or already shown: the fixed position still applies */ }
    };
    show();
    // Inside a hidden container (display:none) even the top layer shows nothing: move it out.
    if (canvas.getClientRects().length === 0) {
      try { canvas.hidePopover(); } catch (e) {}
      toBody();
      show();
    }
    document.documentElement.style.overflow = "hidden";
    return () => {
      try { canvas.hidePopover(); } catch (e) {}
      if (saved.popover === null) canvas.removeAttribute("popover"); else canvas.setAttribute("popover", saved.popover);
      if (saved.style === null) canvas.removeAttribute("style"); else canvas.setAttribute("style", saved.style);
      if (moved) {
        if (saved.parent && saved.parent.isConnected) saved.parent.insertBefore(canvas, saved.next?.parentNode === saved.parent ? saved.next : null);
        else canvas.remove();
      }
      document.documentElement.style.overflow = saved.overflow;
    };
  }

  // What is actually on top in the middle of the page (for the log, when frames don't arrive).
  function coveredBy(canvas) {
    const top = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
    if (!top || top === canvas) return null;
    return `${top.tagName.toLowerCase()}${top.id ? "#" + top.id : ""}${typeof top.className === "string" && top.className ? "." + top.className.trim().split(/\s+/).slice(0, 2).join(".") : ""}`;
  }

  // The stamp starts STAMP_OFFSET squares in from the left: the page fills the window up to its
  // rounded top corners, which would clip the first squares.
  const STAMP_BITS = 16, STAMP_FRACTION = 360, STAMP_OFFSET = 12;

  // Square i spans [x, x + width) in whole pixels, its edges at multiples of width / 360 (not
  // rounded once: at sizes not divisible by 360 the error would add up along the stamp and
  // Halliday, which reads at the exact fractions, would miss the last squares).
  function stampSquare(width, i) {
    const size = Math.max(2, width / STAMP_FRACTION);
    const x = Math.round((STAMP_OFFSET + i) * size);
    return { x, width: Math.round((STAMP_OFFSET + i + 1) * size) - x, height: Math.max(2, Math.round(size)) };
  }

  function stamp(gl, id) {
    const square = stampSquare(gl.drawingBufferWidth, 0).height;
    const top = gl.drawingBufferHeight - square; // GL origin is bottom-left
    const fb = gl.getParameter(gl.FRAMEBUFFER_BINDING);
    const scissorOn = gl.isEnabled(gl.SCISSOR_TEST);
    const box = gl.getParameter(gl.SCISSOR_BOX);
    const clear = gl.getParameter(gl.COLOR_CLEAR_VALUE);
    const mask = gl.getParameter(gl.COLOR_WRITEMASK);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.enable(gl.SCISSOR_TEST);
    gl.colorMask(true, true, true, true);
    for (let i = 0; i < STAMP_BITS + 2; i++) {
      const on = i < STAMP_BITS ? (id >> i) & 1 : (i === STAMP_BITS ? 1 : 0);
      const sq = stampSquare(gl.drawingBufferWidth, i);
      gl.scissor(sq.x, top, sq.width, square);
      gl.clearColor(on, on, on, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    if (!scissorOn) gl.disable(gl.SCISSOR_TEST);
    gl.scissor(box[0], box[1], box[2], box[3]);
    gl.clearColor(clear[0], clear[1], clear[2], clear[3]);
    gl.colorMask(mask[0], mask[1], mask[2], mask[3]);
  }

  // The VR pointer's ray: head pose rotated by the pointer, in tracking space.
  class XRPointerSpace extends XRSpace {
    _originNow() {
      const p = H._framePose ?? H.pose;
      return multiply(fromPose(p.p, p.q), fromPose([0, 0, 0], p.r ?? [0, 0, 0, 1]));
    }
  }

  // Many engines (A-Frame's controls, some video players) read the trigger from the gamepad
  // instead of listening for select events: expose an xr-standard gamepad whose trigger is the click.
  class XRPointerGamepad {
    constructor() {
      this.id = "Halliday VR pointer";
      this.index = -1;
      this.connected = true;
      this.mapping = "xr-standard";
      this.timestamp = performance.now();
      // xr-standard: 0 trigger, 1 squeeze, 2 touchpad, 3 thumbstick.
      this.buttons = [0, 1, 2, 3].map(() => ({ pressed: false, touched: false, value: 0 }));
      this.axes = [0, 0, 0, 0];
      this.hapticActuators = [];
      this.vibrationActuator = null;
    }
    _trigger(down) {
      this.buttons[0] = { pressed: down, touched: down, value: down ? 1 : 0 };
      this.timestamp = performance.now();
    }
  }

  class XRInputSource {
    constructor() {
      this._handedness = "right";
      this._targetRayMode = "tracked-pointer";
      this._targetRaySpace = new XRPointerSpace();
      // Pages that drive their own VR menus often take the controller's pose from the grip space
      // and skip input sources without one. The grip is given the pointer ray's pose, so a ray cast
      // from it lands where Halliday draws its cursor.
      this._gripSpace = new XRPointerSpace();
      this._gamepad = new XRPointerGamepad();
      this._hand = null;
      this._profiles = Object.freeze(["generic-trigger"]);
    }
  }
  // Each property counts how often the page reads it (see H.usage).
  for (const name of ["handedness", "targetRayMode", "targetRaySpace", "gripSpace", "gamepad", "hand", "profiles"]) {
    Object.defineProperty(XRInputSource.prototype, name, {
      get() { if (H.usage) H.usage.reads[name] = (H.usage.reads[name] ?? 0) + 1; return this["_" + name]; },
      enumerable: true, configurable: true,
    });
  }

  class XRInputSourceEvent extends Event {
    constructor(type, init) { super(type, init); this.frame = init.frame; this.inputSource = init.inputSource; }
  }

  class XRInputSourcesChangeEvent extends Event {
    constructor(type, init) {
      super(type, init);
      this.session = init.session;
      this.added = Object.freeze(init.added ?? []);
      this.removed = Object.freeze(init.removed ?? []);
    }
  }

  class XRView {
    constructor(eye, projectionMatrix, transform) {
      this.eye = eye;
      this.projectionMatrix = projectionMatrix;
      this.transform = transform;
      this.recommendedViewportScale = null;
    }
    requestViewportScale() {}
  }

  class XRViewport {
    constructor(x, y, width, height) { this.x = x; this.y = y; this.width = width; this.height = height; }
  }

  class XRPose {
    constructor(transform) { this.transform = transform; this.emulatedPosition = false; }
  }

  class XRViewerPose extends XRPose {
    constructor(transform, views) { super(transform); this.views = Object.freeze(views); }
  }

  class XRRenderState {
    constructor(init = {}) {
      this.depthNear = init.depthNear ?? 0.1;
      this.depthFar = init.depthFar ?? 1000;
      this.inlineVerticalFieldOfView = init.inlineVerticalFieldOfView ?? null;
      this.baseLayer = init.baseLayer ?? null;
      this.layers = Object.freeze([...(init.layers ?? [])]);
    }
  }

  class XRFrame {
    constructor(session, time) { this.session = session; this.predictedDisplayTime = time; this._active = true; }
    getViewerPose(refSpace) {
      if (!this._active) throw new DOMException("Frame is not active", "InvalidStateError");
      const s = this.session;
      // Head in the reference space = inverse(space origin) * head (both in tracking space).
      const head = multiply(invertRigid(refSpace._originNow()), H._headMatrix());
      const rs = s.renderState;
      if (s.mode === "inline") {
        const canvas = rs.baseLayer?.context?.canvas;
        const aspect = canvas ? canvas.width / Math.max(canvas.height, 1) : 1;
        const t = Math.tan((rs.inlineVerticalFieldOfView ?? Math.PI / 2) / 2);
        const view = new XRView("none", projection([-t * aspect, t * aspect, t, -t], rs.depthNear, rs.depthFar),
                                new XRRigidTransform(head));
        return new XRViewerPose(new XRRigidTransform(head), [view]);
      }
      const half = H.cfg.ipd / 2;
      const views = ["left", "right"].map((eye, i) => {
        const offset = identity();
        offset[12] = i === 0 ? -half : half;
        return new XRView(eye, projection(H.cfg.fov[i], rs.depthNear, rs.depthFar),
                          new XRRigidTransform(multiply(head, offset)));
      });
      H.stats.lastViews = views.length;
      H.stats.lastHead = [head[12], head[13], head[14]].map((v) => +v.toFixed(3));
      return new XRViewerPose(new XRRigidTransform(head), views);
    }
    getPose(space, baseSpace) {
      if (!space?._originNow || !baseSpace?._originNow) return null;
      if (H.usage && space instanceof XRPointerSpace) H.usage.pointerPoses++;
      const m = multiply(invertRigid(baseSpace._originNow()), space._originNow());
      return new XRPose(new XRRigidTransform(m));
    }
  }

  // Pixels across one eye for a page asking for `scale` × the default size.
  function eyeFor(scale) {
    const s = Number.isFinite(scale) && scale > 0 ? scale : 1;
    // Even, so the window showing it is a whole number of points (2 pixels each) tall.
    return Math.max(256, Math.min(H.maxEye, Math.round(H.cfg.eyeSize * s / 2) * 2));
  }
  const nativeScale = () => Math.min(H.nativeEye, H.maxEye) / H.cfg.eyeSize;

  // Sizes the canvas for both eyes side by side and puts it in front of the page. Returns the eye size.
  function presentCanvas(session, canvas, eye) {
    if (session._canvas && session._canvas !== canvas && session._savedSize) {
      [session._canvas.width, session._canvas.height] = session._savedSize;
    }
    if (session._canvas !== canvas) {
      session._canvas = canvas;
      session._savedSize = [canvas.width, canvas.height];
    }
    canvas.width = eye * 2;
    canvas.height = eye;
    session._unpresent?.();
    session._unpresent = present(canvas);
    post({ type: "present", width: canvas.width, height: canvas.height });
    return eye;
  }

  class XRWebGLLayer {
    constructor(session, context, init = {}) {
      if (session._ended) throw new DOMException("Session ended", "InvalidStateError");
      this.context = context;
      this.antialias = init.antialias ?? true;
      this.ignoreDepthValues = false;
      this.fixedFoveation = null;
      // null: render into the canvas's default framebuffer (what Halliday captures).
      this.framebuffer = null;
      this._session = session;
      if (session.mode !== "inline") {
        // Both eyes side by side; the canvas is restored when the session ends.
        const eye = presentCanvas(session, context.canvas, eyeFor(init.framebufferScaleFactor));
        // Engines size the canvas from framebufferWidth/Height right after creating the layer
        // (three.js does), so report the intended size, not the drawing buffer's (it updates late).
        this._width = eye * 2;
        this._height = eye;
      }
    }
    get framebufferWidth() { return this._width ?? this.context.drawingBufferWidth; }
    get framebufferHeight() { return this._height ?? this.context.drawingBufferHeight; }
    getViewport(view) {
      const w = this.framebufferWidth, h = this.framebufferHeight;
      if (view.eye === "left") return new XRViewport(0, 0, w / 2, h);
      if (view.eye === "right") return new XRViewport(w / 2, 0, w / 2, h);
      return new XRViewport(0, 0, w, h);
    }
    static getNativeFramebufferScaleFactor() { return nativeScale(); }
  }

  // --- WebXR Layers -------------------------------------------------------------------------
  // A page that sets renderState.layers draws into textures Halliday's bridge gives it (projection
  // layers) or hands it videos (media layers); after each frame the bridge composites them, far to
  // near, into one canvas with both eyes side by side, which is presented like a base layer.

  class XRCompositionLayer extends EventTarget {
    constructor(session, layout) {
      super();
      this._session = session;
      this.layout = layout;
      this.blendTextureSourceAlpha = true;
      this.chromaticAberrationCorrection = null;
      this.mipLevels = 1;
      this.needsRedraw = false;
      this.quality = "default";
      this.onredraw = null;
    }
    destroy() { this._destroyed = true; this._release?.(); }
  }

  class XRProjectionLayer extends XRCompositionLayer {
    constructor(session, eye) {
      super(session, "stereo-left-right");
      this.textureWidth = eye * 2;
      this.textureHeight = eye;
      this.textureArrayLength = 1;
      this.ignoreDepthValues = false;
      this.fixedFoveation = null;
      this.deltaPose = null;
      this._eye = eye;
    }
    _viewport(view) {
      const e = this._eye;
      return view.eye === "right" ? new XRViewport(e, 0, e, e) : new XRViewport(0, 0, e, e);
    }
  }

  // Video layers (XRMediaBinding): the bridge draws the video itself, each frame.
  class XRMediaLayer extends XRCompositionLayer {
    constructor(session, video, init, kind) {
      super(session, init.layout === "stereo" ? "stereo-left-right" : (init.layout ?? "mono"));
      this._kind = kind;
      this._video = video;
      this.space = init.space;
      this.transform = init.transform ?? new XRRigidTransform();
      this.invertStereo = !!init.invertStereo;
    }
  }
  class XRQuadLayer extends XRMediaLayer {
    constructor(session, video, init) {
      super(session, video, init, 0);
      // Only one side given: the other follows the video's shape (the eye's half, for stereo).
      const aspect = () => {
        const w = video.videoWidth || 16, h = video.videoHeight || 9;
        return this.layout === "stereo-left-right" ? w / 2 / h : this.layout === "stereo-top-bottom" ? w / (h / 2) : w / h;
      };
      this.width = init.width ?? (init.height ? init.height * aspect() : 1);
      this.height = init.height ?? this.width / aspect();
    }
  }
  class XRCylinderLayer extends XRMediaLayer {
    constructor(session, video, init) {
      super(session, video, init, 1);
      this.radius = init.radius ?? 2;
      this.centralAngle = init.centralAngle ?? 0.78539;
      this.aspectRatio = init.aspectRatio ?? 2;
    }
  }
  class XREquirectLayer extends XRMediaLayer {
    constructor(session, video, init) {
      super(session, video, init, 2);
      this.radius = init.radius ?? 0;
      this.centralHorizontalAngle = init.centralHorizontalAngle ?? 2 * Math.PI;
      this.upperVerticalAngle = init.upperVerticalAngle ?? Math.PI / 2;
      this.lowerVerticalAngle = init.lowerVerticalAngle ?? -Math.PI / 2;
    }
  }

  class XRMediaBinding {
    constructor(session) {
      if (session._ended) throw new DOMException("Session ended", "InvalidStateError");
      this._session = session;
    }
    _check(video, init) {
      if (!(video instanceof HTMLVideoElement)) throw new TypeError("A video element is needed");
      if (!init?.space) throw new TypeError("A space is needed");
    }
    createQuadLayer(video, init = {}) { this._check(video, init); return new XRQuadLayer(this._session, video, init); }
    createCylinderLayer(video, init = {}) { this._check(video, init); return new XRCylinderLayer(this._session, video, init); }
    createEquirectLayer(video, init = {}) { this._check(video, init); return new XREquirectLayer(this._session, video, init); }
  }

  class XRSubImage { constructor(viewport) { this.viewport = viewport; } }
  class XRWebGLSubImage extends XRSubImage {
    constructor(viewport, color, depth, width, height) {
      super(viewport);
      this.colorTexture = color;
      this.depthStencilTexture = depth;
      this.motionVectorTexture = null;
      this.imageIndex = null;
      this.colorTextureWidth = width;
      this.colorTextureHeight = height;
      this.depthStencilTextureWidth = depth ? width : null;
      this.depthStencilTextureHeight = depth ? height : null;
    }
  }

  // Projection layers drawn with WebGL: one texture with both eyes side by side (and a depth
  // texture when asked for), in the page's own context.
  class XRWebGLBinding {
    constructor(session, context) {
      if (session._ended) throw new DOMException("Session ended", "InvalidStateError");
      this._session = session;
      this._gl = context;
      this.nativeProjectionScaleFactor = nativeScale();
      this.usesDepthValues = false;
    }
    createProjectionLayer(init = {}) {
      const gl = this._gl, gl2 = isGL2(gl);
      if ((init.textureType ?? "texture") === "texture-array") throw new DOMException("Texture arrays are not supported", "NotSupportedError");
      const eye = eyeFor(init.scaleFactor);
      const layer = new XRProjectionLayer(this._session, eye);
      layer._gl = gl;
      const saved = gl.getParameter(gl.TEXTURE_BINDING_2D);
      const make = (internal, format, type) => {
        const t = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, t);
        gl.texImage2D(gl.TEXTURE_2D, 0, internal, eye * 2, eye, 0, format, type, null);
        for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                              [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);
        return t;
      };
      const color = init.colorFormat ?? gl.RGBA;
      layer._color = gl2 && color === gl.RGBA8 ? make(gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE)
        : gl2 && color === gl.SRGB8_ALPHA8 ? make(gl.SRGB8_ALPHA8, gl.RGBA, gl.UNSIGNED_BYTE) : make(gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE);
      const depth = init.depthFormat ?? 0;
      if (depth && gl2) {
        layer._depth = depth === gl.DEPTH24_STENCIL8 || depth === gl.DEPTH_STENCIL ? make(gl.DEPTH24_STENCIL8, gl.DEPTH_STENCIL, gl.UNSIGNED_INT_24_8)
          : depth === gl.DEPTH32F_STENCIL8 ? make(gl.DEPTH32F_STENCIL8, gl.DEPTH_STENCIL, gl.FLOAT_32_UNSIGNED_INT_24_8_REV)
          : depth === gl.DEPTH_COMPONENT32F ? make(gl.DEPTH_COMPONENT32F, gl.DEPTH_COMPONENT, gl.FLOAT)
          : make(gl.DEPTH_COMPONENT24, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT);
      } else if (depth) {
        const ext = gl.getExtension("WEBGL_depth_texture");
        if (ext) layer._depth = make(gl.DEPTH_STENCIL, gl.DEPTH_STENCIL, ext.UNSIGNED_INT_24_8_WEBGL);
      }
      gl.bindTexture(gl.TEXTURE_2D, saved);
      layer._release = () => { gl.deleteTexture(layer._color); if (layer._depth) gl.deleteTexture(layer._depth); };
      return layer;
    }
    getViewSubImage(layer, view) {
      if (!(layer instanceof XRProjectionLayer) || !layer._gl) throw new DOMException("Not a WebGL projection layer", "InvalidStateError");
      return new XRWebGLSubImage(layer._viewport(view), layer._color, layer._depth ?? null, layer.textureWidth, layer.textureHeight);
    }
    getSubImage() { throw new DOMException("Only projection layers are supported from WebGL", "NotSupportedError"); }
    createQuadLayer() { throw new DOMException("Quad layers from WebGL are not supported", "NotSupportedError"); }
    createCylinderLayer() { throw new DOMException("Cylinder layers from WebGL are not supported", "NotSupportedError"); }
    createEquirectLayer() { throw new DOMException("Equirect layers from WebGL are not supported", "NotSupportedError"); }
    createCubeLayer() { throw new DOMException("Cube layers are not supported", "NotSupportedError"); }
    getReflectionCubeMap() { return null; }
    getCameraImage() { return null; }
    getDepthInformation() { return null; }
  }

  // Projection layers drawn with WebGPU: the bridge's own canvas, configured for the page's
  // device; both eyes side by side in its texture.
  class XRGPUSubImage extends XRSubImage {
    constructor(viewport, color, depth) {
      super(viewport);
      this.colorTexture = color;
      this.depthStencilTexture = depth;
      this.motionVectorTexture = null;
    }
    getViewDescriptor() { return { dimension: "2d", baseMipLevel: 0, mipLevelCount: 1, baseArrayLayer: 0, arrayLayerCount: 1 }; }
  }

  class XRGPUBinding {
    constructor(session, device) {
      if (session._ended) throw new DOMException("Session ended", "InvalidStateError");
      if (!device?.queue) throw new TypeError("A GPUDevice is needed");
      this._session = session;
      this._device = device;
      this.nativeProjectionScaleFactor = nativeScale();
    }
    getPreferredColorFormat() { return navigator.gpu?.getPreferredCanvasFormat?.() ?? "bgra8unorm"; }
    createProjectionLayer(init = {}) {
      const usage = (init.textureUsage ?? GPUTextureUsage.RENDER_ATTACHMENT) | GPUTextureUsage.COPY_DST;
      let format = init.colorFormat ?? this.getPreferredColorFormat();
      if (!["bgra8unorm", "rgba8unorm", "rgba16float"].includes(format)) {
        console.warn(`Halliday: color format ${format} can't be shown; ${this.getPreferredColorFormat()} is used`);
        format = this.getPreferredColorFormat();
      }
      const eye = eyeFor(init.scaleFactor);
      const layer = new XRProjectionLayer(this._session, eye);
      const canvas = document.createElement("canvas");
      canvas.width = eye * 2;
      canvas.height = eye;
      const ctx = canvas.getContext("webgpu");
      if (!ctx) throw new DOMException("WebGPU canvases are not available", "NotSupportedError");
      ctx.configure({ device: this._device, format, usage, alphaMode: "opaque" });
      layer._gpu = { device: this._device, canvas, ctx, format, frame: -1, texture: null, depth: null };
      if (init.depthStencilFormat) {
        layer._gpu.depth = this._device.createTexture({ size: [eye * 2, eye], format: init.depthStencilFormat,
                                                        usage: GPUTextureUsage.RENDER_ATTACHMENT });
      }
      layer._release = () => { layer._gpu.depth?.destroy(); try { ctx.unconfigure(); } catch (e) {} canvas.remove(); };
      return layer;
    }
    getViewSubImage(layer, view) {
      const g = layer?._gpu;
      if (!g) throw new DOMException("Not a WebGPU projection layer", "InvalidStateError");
      // One texture per frame, the same for both eyes.
      if (g.frame !== H.stats.frames) {
        g.frame = H.stats.frames;
        g.texture = g.ctx.getCurrentTexture();
      }
      return new XRGPUSubImage(layer._viewport(view), g.texture, g.depth);
    }
    getSubImage() { throw new DOMException("Only projection layers are supported from WebGPU", "NotSupportedError"); }
  }

  const isGL2 = (gl) => typeof WebGL2RenderingContext !== "undefined" && gl instanceof WebGL2RenderingContext;

  // Composites a session's layers into a WebGL canvas, far to near: projection layers are copied,
  // media layers drawn by casting each pixel's ray at the quad, cylinder or sphere. GLSL 1.00, so
  // the page's WebGL 1 or 2 context can do it; the page's GL state is put back afterwards.
  class GLCompositor {
    constructor(gl) {
      this.gl = gl;
      this.gl2 = isGL2(gl);
      const vs = "attribute vec2 aPos; varying vec2 vNdc; void main() { vNdc = aPos; gl_Position = vec4(aPos, 0.0, 1.0); }";
      const fs = `precision highp float;
        varying vec2 vNdc;
        uniform sampler2D uTex;
        uniform float uType;     // 0 quad, 1 cylinder, 2 equirect, 3 copy (a projection layer)
        uniform vec4 uTan;       // the eye's FOV tangents: left, right, up, down
        uniform mat3 uRot;       // eye → layer rotation
        uniform vec3 uOrigin;    // the eye in the layer's space
        uniform vec4 uShape;     // quad: w, h · cylinder: radius, central angle, aspect · equirect: radius, central, upper, lower
        uniform vec3 uStereo;    // x: 0 mono, 1 left-right, 2 top-bottom; y: this eye (0, 1)
        void main() {
          if (uType > 2.5) { gl_FragColor = texture2D(uTex, vNdc * 0.5 + 0.5); return; }
          vec2 t = vNdc * 0.5 + 0.5;
          vec3 d = normalize(uRot * vec3(mix(uTan.x, uTan.y, t.x), mix(uTan.w, uTan.z, t.y), -1.0));
          vec3 o = uOrigin;
          vec2 uv;
          if (uType < 0.5) {
            if (abs(d.z) < 1e-6) discard;
            float k = -o.z / d.z;
            if (k <= 0.0) discard;
            vec3 p = o + k * d;
            uv = vec2(p.x / uShape.x + 0.5, 0.5 - p.y / uShape.y);
          } else if (uType < 1.5) {
            float a = d.x * d.x + d.z * d.z, b = 2.0 * (o.x * d.x + o.z * d.z), c = o.x * o.x + o.z * o.z - uShape.x * uShape.x;
            float disc = b * b - 4.0 * a * c;
            if (a < 1e-8 || disc < 0.0) discard;
            float k = (-b + sqrt(disc)) / (2.0 * a);
            if (k <= 0.0) discard;
            vec3 p = o + k * d;
            float angle = atan(p.x, -p.z);
            float height = uShape.x * uShape.y / uShape.z;
            uv = vec2(angle / uShape.y + 0.5, 0.5 - p.y / height);
          } else {
            vec3 p = d;
            if (uShape.x > 0.0) {
              float b = dot(o, d), c = dot(o, o) - uShape.x * uShape.x, disc = b * b - c;
              if (disc < 0.0) discard;
              float k = -b + sqrt(disc);
              if (k <= 0.0) discard;
              p = normalize(o + k * d);
            }
            float lon = atan(p.x, -p.z), lat = asin(clamp(p.y, -1.0, 1.0));
            uv = vec2(lon / uShape.y + 0.5, (uShape.z - lat) / (uShape.z - uShape.w));
          }
          if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) discard;
          if (uStereo.x > 0.5 && uStereo.x < 1.5) uv.x = (uv.x + uStereo.y) * 0.5;
          else if (uStereo.x > 1.5) uv.y = (uv.y + uStereo.y) * 0.5;
          gl_FragColor = texture2D(uTex, uv);
        }`;
      const compile = (type, src) => {
        const sh = gl.createShader(type);
        gl.shaderSource(sh, src);
        gl.compileShader(sh);
        if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) console.error("Halliday layers: " + gl.getShaderInfoLog(sh));
        return sh;
      };
      const prog = gl.createProgram();
      gl.attachShader(prog, compile(gl.VERTEX_SHADER, vs));
      gl.attachShader(prog, compile(gl.FRAGMENT_SHADER, fs));
      gl.bindAttribLocation(prog, 0, "aPos");
      gl.linkProgram(prog);
      this.prog = prog;
      this.loc = {};
      for (const n of ["uTex", "uType", "uTan", "uRot", "uOrigin", "uShape", "uStereo"]) this.loc[n] = gl.getUniformLocation(prog, n);
      const savedBuffer = gl.getParameter(gl.ARRAY_BUFFER_BINDING);
      this.buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
      gl.bindBuffer(gl.ARRAY_BUFFER, savedBuffer);
      this.vaoExt = this.gl2 ? null : gl.getExtension("OES_vertex_array_object");
      this.videos = new Map();
    }

    // Saves what compositing changes in the page's GL state and returns a function putting it back.
    _save() {
      const gl = this.gl, gl2 = this.gl2;
      const caps = [gl.BLEND, gl.DEPTH_TEST, gl.CULL_FACE, gl.SCISSOR_TEST, gl.STENCIL_TEST];
      const on = caps.map((c) => gl.isEnabled(c));
      const st = {
        draw: gl.getParameter(gl2 ? gl.DRAW_FRAMEBUFFER_BINDING : gl.FRAMEBUFFER_BINDING),
        read: gl2 ? gl.getParameter(gl.READ_FRAMEBUFFER_BINDING) : null,
        viewport: gl.getParameter(gl.VIEWPORT), mask: gl.getParameter(gl.COLOR_WRITEMASK), clear: gl.getParameter(gl.COLOR_CLEAR_VALUE),
        program: gl.getParameter(gl.CURRENT_PROGRAM), active: gl.getParameter(gl.ACTIVE_TEXTURE),
        buffer: gl.getParameter(gl.ARRAY_BUFFER_BINDING),
        flip: gl.getParameter(gl.UNPACK_FLIP_Y_WEBGL), premultiply: gl.getParameter(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL),
        colorspace: gl.getParameter(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL),
      };
      gl.activeTexture(gl.TEXTURE0);
      st.texture = gl.getParameter(gl.TEXTURE_BINDING_2D);
      if (gl2) {
        st.vao = gl.getParameter(gl.VERTEX_ARRAY_BINDING);
        st.sampler = gl.getParameter(gl.SAMPLER_BINDING);
        st.unpackBuffer = gl.getParameter(gl.PIXEL_UNPACK_BUFFER_BINDING);
        gl.bindVertexArray(this.vao ??= gl.createVertexArray());
        gl.bindSampler(0, null);
        gl.bindBuffer(gl.PIXEL_UNPACK_BUFFER, null);
      } else if (this.vaoExt) {
        st.vao = gl.getParameter(this.vaoExt.VERTEX_ARRAY_BINDING_OES);
        this.vaoExt.bindVertexArrayOES(this.vao ??= this.vaoExt.createVertexArrayOES());
      } else {
        // No vertex array objects: attribute 0 as the page left it.
        st.attrib = { enabled: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_ENABLED), buffer: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING),
                      size: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_SIZE), type: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_TYPE),
                      normalized: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_NORMALIZED), stride: gl.getVertexAttrib(0, gl.VERTEX_ATTRIB_ARRAY_STRIDE),
                      offset: gl.getVertexAttribOffset(0, gl.VERTEX_ATTRIB_ARRAY_POINTER) };
      }
      for (const c of caps) gl.disable(c);
      return () => {
        if (gl2) {
          gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, st.draw);
          gl.bindFramebuffer(gl.READ_FRAMEBUFFER, st.read);
          gl.bindVertexArray(st.vao);
          gl.bindSampler(0, st.sampler);
          gl.bindBuffer(gl.PIXEL_UNPACK_BUFFER, st.unpackBuffer);
        } else {
          gl.bindFramebuffer(gl.FRAMEBUFFER, st.draw);
          if (this.vaoExt) this.vaoExt.bindVertexArrayOES(st.vao);
          else if (st.attrib) {
            const a = st.attrib;
            gl.bindBuffer(gl.ARRAY_BUFFER, a.buffer);
            gl.vertexAttribPointer(0, a.size, a.type, a.normalized, a.stride, a.offset);
            if (a.enabled) gl.enableVertexAttribArray(0); else gl.disableVertexAttribArray(0);
          }
        }
        caps.forEach((c, i) => (on[i] ? gl.enable(c) : gl.disable(c)));
        gl.viewport(st.viewport[0], st.viewport[1], st.viewport[2], st.viewport[3]);
        gl.colorMask(st.mask[0], st.mask[1], st.mask[2], st.mask[3]);
        gl.clearColor(st.clear[0], st.clear[1], st.clear[2], st.clear[3]);
        gl.bindTexture(gl.TEXTURE_2D, st.texture);
        gl.activeTexture(st.active);
        gl.useProgram(st.program);
        gl.bindBuffer(gl.ARRAY_BUFFER, st.buffer);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, st.flip);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, st.premultiply);
        gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, st.colorspace);
      };
    }

    // The newest picture of a video layer's video, in a texture of its own.
    _videoTexture(layer) {
      const gl = this.gl, v = layer._video;
      let t = this.videos.get(layer);
      if (!t) {
        t = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, t);
        for (const [k, val] of [[gl.TEXTURE_MIN_FILTER, gl.LINEAR], [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
                                [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, val);
        this.videos.set(layer, t);
        layer._release = () => { gl.deleteTexture(t); this.videos.delete(layer); };
      }
      gl.bindTexture(gl.TEXTURE_2D, t);
      if (v.readyState >= 2 && v.videoWidth > 0) {
        try {
          gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, v);
          t._ready = true;
        } catch (e) {
          if (!layer._warned) { layer._warned = true; console.warn("Halliday layers: the video can't be read (" + e.message + "); a cross-origin video needs CORS"); }
        }
      }
      return t._ready ? t : null;
    }

    composite(session) {
      const gl = this.gl;
      const eye = Math.round(gl.drawingBufferHeight);
      const restore = this._save();
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
      gl.colorMask(true, true, true, true);
      gl.clearColor(0, 0, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.useProgram(this.prog);
      gl.bindBuffer(gl.ARRAY_BUFFER, this.buffer);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(this.loc.uTex, 0);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
      const head = H._headMatrix();
      for (const layer of session.renderState.layers) {
        if (layer._destroyed) continue;
        // Layers over the first one blend over it by their alpha.
        if (layer !== session.renderState.layers[0] && layer.blendTextureSourceAlpha) {
          gl.enable(gl.BLEND);
          gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
        } else {
          gl.disable(gl.BLEND);
        }
        if (layer instanceof XRProjectionLayer) {
          if (!layer._color || layer._gl !== gl) continue;
          gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight);
          gl.bindTexture(gl.TEXTURE_2D, layer._color);
          gl.uniform1f(this.loc.uType, 3);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
          continue;
        }
        if (!(layer instanceof XRMediaLayer) || !layer.space?._originNow) continue;
        const tex = this._videoTexture(layer);
        if (!tex) continue;
        gl.uniform1f(this.loc.uType, layer._kind);
        const shape = layer._kind === 0 ? [layer.width, layer.height, 0, 0]
          : layer._kind === 1 ? [layer.radius, layer.centralAngle, layer.aspectRatio, 0]
          : [layer.radius, layer.centralHorizontalAngle, layer.upperVerticalAngle, layer.lowerVerticalAngle];
        gl.uniform4fv(this.loc.uShape, shape);
        // The layer's space in tracking space, then where each eye is in it.
        const layerFromTracking = invertRigid(multiply(layer.space._originNow(), layer.transform.matrix));
        const half = H.cfg.ipd / 2;
        for (let i = 0; i < 2; i++) {
          const offset = identity();
          offset[12] = i === 0 ? -half : half;
          const m = multiply(layerFromTracking, multiply(head, offset));
          gl.viewport(i * eye, 0, eye, eye);
          gl.uniform4fv(this.loc.uTan, H.cfg.fov[i]);
          gl.uniformMatrix3fv(this.loc.uRot, false, [m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]);
          gl.uniform3f(this.loc.uOrigin, m[12], m[13], m[14]);
          const layout = layer.layout === "stereo-left-right" ? 1 : layer.layout === "stereo-top-bottom" ? 2 : 0;
          gl.uniform3f(this.loc.uStereo, layout, layer.invertStereo ? 1 - i : i, 0);
          gl.drawArrays(gl.TRIANGLES, 0, 3);
        }
      }
      restore();
    }

    destroy() {
      const gl = this.gl;
      for (const t of this.videos.values()) gl.deleteTexture(t);
      this.videos.clear();
      gl.deleteBuffer(this.buffer);
      gl.deleteProgram(this.prog);
      if (this.vao) { if (this.gl2) gl.deleteVertexArray(this.vao); else this.vaoExt?.deleteVertexArrayOES(this.vao); }
    }
  }

  // The pose stamp written into a WebGPU canvas's texture (see `stamp`), white and black squares.
  function stampGPU(g, id) {
    const w = g.canvas.width;
    const square = stampSquare(w, 0).height, most = square + 1;
    const white = new Uint8Array(most * square * 4).fill(255);
    const black = new Uint8Array(most * square * 4);
    for (let i = 3; i < black.length; i += 4) black[i] = 255;
    for (let i = 0; i < STAMP_BITS + 2; i++) {
      const on = i < STAMP_BITS ? (id >> i) & 1 : (i === STAMP_BITS ? 1 : 0);
      const sq = stampSquare(w, i);
      g.device.queue.writeTexture({ texture: g.texture, origin: { x: sq.x, y: 0 } }, on ? white : black,
                                  { bytesPerRow: most * 4 }, { width: Math.min(sq.width, most), height: square });
    }
  }

  class XRSession extends EventTarget {
    constructor(mode, features) {
      super();
      this.mode = mode;
      this.renderState = new XRRenderState(mode === "inline" ? { inlineVerticalFieldOfView: Math.PI / 2 } : {});
      this._pointer = mode === "inline" ? null : new XRInputSource();
      this.inputSources = Object.freeze(this._pointer ? [this._pointer] : []);
      this.visibilityState = "visible";
      this.environmentBlendMode = "opaque";
      this.interactionMode = "world-space";
      this.enabledFeatures = Object.freeze(features);
      // The page's frames run at its chosen rate (60 unless it asks), on a display that runs at 120.
      this.supportedFrameRates = new Float32Array([60, 120]);
      this.frameRate = 60;
      this.onend = this.onselect = this.onselectstart = this.onselectend = null;
      this.oninputsourceschange = this.onvisibilitychange = this.onframeratechange = null;
      this._callbacks = new Map();
      this._nextHandle = 1;
      this._scheduled = false;
      this._ended = false;
    }
    updateRenderState(init = {}) {
      if (this._ended) throw new DOMException("Session ended", "InvalidStateError");
      const rs = this.renderState;
      if (init.baseLayer && init.layers?.length) throw new TypeError("baseLayer and layers can't both be set");
      const layers = init.layers ?? (init.baseLayer ? [] : rs.layers);
      this.renderState = new XRRenderState({
        depthNear: init.depthNear ?? rs.depthNear,
        depthFar: init.depthFar ?? rs.depthFar,
        inlineVerticalFieldOfView: init.inlineVerticalFieldOfView ?? rs.inlineVerticalFieldOfView,
        baseLayer: init.layers?.length ? null : (init.baseLayer ?? rs.baseLayer),
        layers,
      });
      if (init.layers && this.mode !== "inline") this._presentLayers();
    }

    // Layers: the canvas Halliday shows is a WebGPU projection layer's, else the WebGL context of a
    // projection layer (or a context of the bridge's own, for videos alone), composited each frame.
    _presentLayers() {
      const layers = this.renderState.layers;
      if (!layers.length) return;
      const gpu = layers.find((l) => l._gpu);
      if (gpu) {
        if (this._canvas !== gpu._gpu.canvas) presentCanvas(this, gpu._gpu.canvas, gpu._eye);
        this._compositor = null;
        return;
      }
      const projection = layers.find((l) => l instanceof XRProjectionLayer && l._gl);
      let gl = projection?._gl ?? this._ownGL;
      if (!gl) {
        const canvas = document.createElement("canvas");
        gl = canvas.getContext("webgl2") ?? canvas.getContext("webgl");
        if (!gl) { console.error("Halliday layers: no WebGL for video layers"); return; }
        this._ownGL = gl;
        this._ownCanvas = canvas;
      }
      const eye = projection?._eye ?? eyeFor(1);
      if (this._canvas !== gl.canvas || gl.canvas.height !== eye) presentCanvas(this, gl.canvas, eye);
      if (this._compositor?.gl !== gl) {
        this._compositor?.destroy();
        this._compositor = new GLCompositor(gl);
      }
    }
    updateTargetFrameRate(rate) {
      if (!this.supportedFrameRates.includes(rate)) return Promise.reject(new DOMException(`${rate} Hz is not supported`, "InvalidStateError"));
      this.frameRate = rate;
      post({ type: "console", level: "info", text: `xr frame rate: ${rate} Hz` });
      const ev = new Event("frameratechange");
      this.dispatchEvent(ev);
      if (typeof this.onframeratechange === "function") this.onframeratechange(ev);
      return Promise.resolve();
    }
    async requestReferenceSpace(type) {
      const head = H.pose;
      // Gravity-aligned origin under (or at) the head when the space is created.
      const yaw = yawOnly(head.q);
      switch (type) {
        case "viewer": return new XRReferenceSpace(type, identity(), true);
        case "local": return new XRReferenceSpace(type, fromPose(head.p, yaw));
        case "local-floor": return new XRReferenceSpace(type, fromPose([head.p[0], 0, head.p[2]], yaw));
        default: throw new DOMException(`Reference space "${type}" is not supported`, "NotSupportedError");
      }
    }
    requestAnimationFrame(callback) {
      if (this._ended) return 0;
      const handle = this._nextHandle++;
      this._callbacks.set(handle, callback);
      if (!this._scheduled) {
        this._scheduled = true;
        window.requestAnimationFrame((t) => this._tick(t));
      }
      return handle;
    }
    cancelAnimationFrame(handle) { this._callbacks.delete(handle); }
    // Fires an input event with a frame that is active while listeners run (they call getPose).
    _fireInput(type) {
      if (this._ended || !this._pointer) return;
      const frame = new XRFrame(this, performance.now());
      const ev = new XRInputSourceEvent(type, { frame, inputSource: this._pointer });
      this.dispatchEvent(ev);
      const handler = this["on" + type];
      if (typeof handler === "function") { try { handler.call(this, ev); } catch (e) { console.error(e); } }
      frame._active = false;
    }
    _announceInput() {
      if (!this._pointer) return;
      const ev = new XRInputSourcesChangeEvent("inputsourceschange", { session: this, added: [this._pointer] });
      this.dispatchEvent(ev);
      if (typeof this.oninputsourceschange === "function") this.oninputsourceschange(ev);
    }
    addEventListener(type, ...rest) {
      if (H.usage && this.mode !== "inline") H.usage.listeners.add(type);
      return super.addEventListener(type, ...rest);
    }
    _tick(time) {
      this._scheduled = false;
      if (this._ended) return;
      // The browser's frames come at the display's rate: below it, some are skipped (a frame is
      // due once its interval has nearly passed, so 60 on a 120 Hz display is every other one).
      if (this.mode !== "inline" && this._lastFrame !== undefined && time - this._lastFrame < 1000 / this.frameRate - 3) {
        this._scheduled = true;
        window.requestAnimationFrame((t) => this._tick(t));
        return;
      }
      this._lastFrame = time;
      // Usage report: 5 s into the session, then every 30 s (clicks and reads keep counting).
      if (this.mode !== "inline" && H.usage && time - (this._startedAt ??= time) > (H.usage.reported ? 30000 * H.usage.reported : 5000)) {
        H.usage.reported++;
        post({ type: "console", level: "info", text: usageReport(this) });
      }
      const callbacks = [...this._callbacks];
      this._callbacks.clear();
      const frame = new XRFrame(this, time);
      H.stats.frames++;
      H._framePose = H.pose;
      for (const [, cb] of callbacks) {
        try { cb(time, frame); } catch (e) { console.error(e); }
      }
      frame._active = false;
      // Layers: composite them, then stamp what is shown.
      const layers = this.renderState.layers;
      if (this.mode !== "inline" && layers.length) {
        const gpu = layers.find((l) => l._gpu)?._gpu;
        if (gpu) {
          if (gpu.frame !== H.stats.frames) { gpu.frame = H.stats.frames; gpu.texture = gpu.ctx.getCurrentTexture(); }
          try { stampGPU(gpu, H._framePose.id ?? 0); } catch (e) { console.warn("Halliday layers: " + e.message); }
        } else if (this._compositor) {
          this._compositor.composite(this);
          stamp(this._compositor.gl, H._framePose.id ?? 0);
        }
      }
      const layer = this.renderState.baseLayer;
      if (this.mode !== "inline" && layer) {
        const gl = layer.context;
        stamp(gl, H._framePose.id ?? 0);
        // Once, a second into presenting: say so if something of the page still covers the canvas.
        if (!this._checkedCover && time - (this._presentedAt ??= time) > 1000) {
          this._checkedCover = true;
          const cover = coveredBy(gl.canvas);
          if (cover) post({ type: "console", level: "warn", text: `the page covers the VR canvas with ${cover}` });
        }
        if (!this._reportedSize) {
          this._reportedSize = true;
          post({ type: "console", level: "info", text: `canvas ${gl.canvas.width}x${gl.canvas.height}, drawing buffer ${gl.drawingBufferWidth}x${gl.drawingBufferHeight}, css ${gl.canvas.clientWidth}x${gl.canvas.clientHeight}, dpr ${devicePixelRatio}` });
        }
      }
      H._framePose = null;
    }
    async end() {
      if (this._ended) return;
      this._ended = true;
      if (this.mode !== "inline" && H.usage) post({ type: "console", level: "info", text: usageReport(this) });
      this._unpresent?.();
      if (this._canvas && this._savedSize) [this._canvas.width, this._canvas.height] = this._savedSize;
      this._compositor?.destroy();
      this._compositor = null;
      this._ownCanvas?.remove();
      if (H.session === this) H.session = null;
      post({ type: "session", mode: this.mode, state: "end" });
      const ev = new Event("end");
      ev.session = this;
      this.dispatchEvent(ev);
      if (typeof this.onend === "function") this.onend(ev);
    }
  }

  const SUPPORTED_FEATURES = new Set(["viewer", "local", "local-floor", "layers", ...(navigator.gpu ? ["webgpu"] : [])]);

  class XRSystem extends EventTarget {
    constructor() { super(); this.ondevicechange = null; }
    async isSessionSupported(mode) { return mode === "immersive-vr" || mode === "inline"; }
    async requestSession(mode, init = {}) {
      if (mode !== "immersive-vr" && mode !== "inline") {
        throw new DOMException(`Session mode "${mode}" is not supported`, "NotSupportedError");
      }
      const required = init.requiredFeatures ?? [];
      for (const f of required) {
        if (!SUPPORTED_FEATURES.has(f)) throw new DOMException(`Feature "${f}" is not supported`, "NotSupportedError");
      }
      if (mode === "immersive-vr" && H.session) {
        throw new DOMException("An immersive session is already active", "InvalidStateError");
      }
      const features = ["viewer", ...(mode === "inline" ? [] : ["local"]),
                        ...[...required, ...(init.optionalFeatures ?? [])].filter((f) => SUPPORTED_FEATURES.has(f))];
      const session = new XRSession(mode, [...new Set(features)]);
      if (mode === "immersive-vr") {
        H.usage = newUsage(init);
        H.session = session;
        post({ type: "session", mode, state: "start" });
        // Engines attach their listeners right after requestSession resolves: announce the pointer then.
        setTimeout(() => session._announceInput(), 0);
      }
      return session;
    }
  }

  const xr = new XRSystem();
  Object.defineProperty(navigator, "xr", { value: xr, configurable: true, enumerable: true });
  Object.assign(window, {
    XRSystem, XRSession, XRFrame, XRView, XRViewport, XRSpace, XRReferenceSpace, XRRigidTransform,
    XRPose, XRViewerPose, XRRenderState, XRWebGLLayer, XRInputSource, XRInputSourceEvent,
    XRInputSourcesChangeEvent, XRWebGLBinding, XRMediaBinding, XRCompositionLayer, XRProjectionLayer,
    XRQuadLayer, XRCylinderLayer, XREquirectLayer, XRSubImage, XRWebGLSubImage,
    ...(navigator.gpu ? { XRGPUBinding, XRGPUSubImage } : {}),
  });
  for (const proto of [window.WebGLRenderingContext?.prototype, window.WebGL2RenderingContext?.prototype]) {
    if (proto && !proto.makeXRCompatible) proto.makeXRCompatible = function () { return Promise.resolve(); };
  }
  post({ type: "ready" });
})();
