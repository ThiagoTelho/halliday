// Metal shaders, compiled at startup (the Command Line Tools have no offline Metal compiler).
//
// Two passes per frame:
//   1. scene: per eye, ray-cast the environment (sky, floor grid, reference boxes) and the quad
//      layers into a side-by-side eye texture.
//   2. distortion: draw each eye's distortion mesh over its half of the panel and sample the eye
//      texture once per color channel (lens + chromatic correction).
//
// Struct layouts here must match Renderer.swift (SceneUniforms, LayerData).

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

constant uint MAX_LAYERS = 24;

struct SceneUniforms {
    float4 tanLRUD;      // tan of the eye's FOV angles: left, right, up, down
    float4 eyePosition;  // world position of the eye (xyz)
    float4x4 rotation;   // world-from-head rotation (upper 3x3 used)
    float4 params;       // x: layer count, y: eye width in pixels, z: time (s), w: environment dimming (0..1)
    float4 cursor;       // xyz: world pointer direction from the head; w: 1 = draw
    float4 highlight;    // x: hovered layer index or -1; y: the view's brightness (scene fade, 0..1)
    // Projection layer (an immersive WebXR page): its stereo image covers the whole view.
    float4x4 projFromWorld; // inverse of the head rotation the image was rendered with
    float4 projUV;          // side-by-side image's region of its texture: x, y, width, height
    float4 projTan;         // this eye's FOV tangents the image was rendered with: left, right, up, down
    float4 projFlags;       // x: 1 = active, y: this eye (0 left, 1 right), z: 1 = a 3D place's geometry was drawn
    // Video sphere (360°/180°/fisheye video around the viewer).
    float4x4 videoFromWorld; // inverse of the sphere's orientation
    float4 videoParams;      // x: projection + 1 (1 = 360, 2 = 180, 3 = fisheye; 0 = off), y: stereo (0 mono, 1 SBS, 2 TB), z: fisheye FOV (rad), w: zoom (1 = as filmed)
    float4x4 videoTilt;      // where the viewer's "straight ahead" looks in the video (the sticks' tilt)
    float4 videoView;        // x: 1 = both eyes see the left eye's picture (the interface is up over a 3D video), y: brightness
    float4 videoKey;         // a video made for passthrough: rgb the colour that stands for "the room here"; w: 0 off, 1 keyed by that colour, 2 by darkness, 3 by greyness (r: its brightness), 4 a mask in the frame's lower half, 5 in its right half, 6 the backdrop's own colour as found in the video (rgb)
    float4 videoKeyFit;      // for 6: x, y: how far from the backdrop's colour a pixel is still the room's, and from where it is all the video's own (0, 0: no backdrop found); z: how much brightness counts beside hue
    // The saber (Halliday's pointer beam, Night Glass).
    float4 saberStart;       // xyz: start (hand, or below the chin); w: 1 = draw
    float4 saberEnd;         // xyz: end; w: 1 = lands on a surface (cursor ring there)
    float4 saberParams;      // x: brightness (0.6 idle, 0.85 over a target, 1 pressed), y: 1 = pressed, z: 1 = no hand (fade in)
    float4 envParams;        // x: 1 = reference boxes, y: hold-to-recenter progress (0 = no ring), z: environment, w: its yaw
    float4 projShift;        // immersive page: xyz head movement since its frame was rendered (m), w: assumed scene depth (m)
    float4 projTanOther;     // desktop view: the other eye's FOV tangents, for what this eye's image doesn't cover (0: none)
    float4 gameFade;         // a game's fade over its frames (IVRCompositor::FadeToColor), premultiplied
    float4 gameBackgroundFade; // … over the place shown when it sends none (bBackground)
    float4 gameAway;         // x: dashboard amount; y: premultiplied alpha; z/w: left/right transfer (0 legacy, 1 linear, 2 sRGB)
    // Passthrough (the room, through the headset's bottom cameras).
    float4x4 seeFromWorld;   // the cameras' frame (x right, y down, z forward) at the exposure, from world
    float4 seeParams;        // x: how much is shown (0..1), y: focal length (pixels), z: this eye's camera's centre x, w: centre y
    // Camera mode 0x10's raw fisheyes (left, right): the turn from the cameras' frame to each in the
    // upper 3x3, column 3 its focal length, centre x, centre y and k1 (pixels of its 1000 x 1016 picture).
    float4x4 seeFishLeft;
    float4x4 seeFishRight;
    float4 seeFish;          // x: 1 = the picture is the two fisheyes one above the other (BC4); y, z: k2 left, right
};

// The room as this eye's own bottom camera saw it, for the ray `d`: the picture holds the left
// camera then the right, each square, rectified (a pinhole: tracking/stereo.rs). Turned with the
// head from the exposure to now, not moved: the room is taken as far away. Grey, as it is sent.
// Where a direction of the cameras' frame lands in one fisheye's picture, and how far inside the
// picture that is (0 outside, 1 well in): Kannala-Brandt with two terms, as the core's `Camera`.
static float2 fisheye_pixel(float3 c, float4x4 m, float k2, thread float &inside) {
    float3 x = float3x3(m[0].xyz, m[1].xyz, m[2].xyz) * c;
    float across = length(x.xy);
    float theta = atan2(across, x.z);
    float t2 = theta * theta;
    float r = m[3].x * theta * (1.0 + m[3].w * t2 + k2 * t2 * t2);
    float2 p = m[3].yz + (across > 1e-6 ? x.xy / across * r : float2(0.0));
    float2 edge = min(p, float2(1000.0, 1016.0) - p);
    // The lens model holds to about 75° off the axis; the picture's edge is near 70°.
    inside = smoothstep(0.0, 24.0, min(edge.x, edge.y)) * (1.0 - smoothstep(1.25, 1.35, theta));
    return p;
}

// The room through camera mode 0x10's two raw fisheyes (about 170° across together): each eye
// looks through its own side's camera, and through the other where its own doesn't see. The
// pictures are darker than mode 1's, which the headset passes through a curve; the same curve,
// fitted from a still room seen both ways (295 · (1 − e^(−raw/103.5)), in levels).
static float3 see_through_fisheyes(float3 c, float eye, constant SceneUniforms &u, texture2d<float> picture, sampler smp) {
    float insideL, insideR;
    float2 pl = fisheye_pixel(c, u.seeFishLeft, u.seeFish.y, insideL);
    float2 pr = fisheye_pixel(c, u.seeFishRight, u.seeFish.z, insideR);
    float2 size = float2(picture.get_width(), picture.get_height());
    float gl = picture.sample(smp, float2(pl.x, pl.y) / size, level(0.0)).r;
    float gr = picture.sample(smp, float2(pr.x, pr.y + 1016.0) / size, level(0.0)).r;
    float own = eye < 0.5 ? insideL : insideR;
    float other = eye < 0.5 ? insideR : insideL;
    float raw = eye < 0.5 ? mix(gr, gl, own) : mix(gl, gr, own);
    float shown = max(own, other);
    float grey = min(1.0, 1.157 * (1.0 - exp(-2.464 * raw)));
    return float3(grey) * shown;
}

static float3 see_through(float3 d, float eye, constant SceneUniforms &u, texture2d<float> picture, sampler smp) {
    float3 c = (u.seeFromWorld * float4(d, 0.0)).xyz;
    if (u.seeFish.x > 0.5) return see_through_fisheyes(c, eye, u, picture, smp);
    if (c.z < 0.05) return float3(0.0);
    float side = float(picture.get_height());
    float2 p = c.xy / c.z * u.seeParams.y + u.seeParams.zw;
    // Dark towards the picture's edge, so the room ends softly where the camera's view does.
    float2 edge = min(p, side - p);
    float inside = smoothstep(0.0, 24.0, min(edge.x, edge.y));
    if (inside <= 0.0) return float3(0.0);
    float2 uv = float2((eye * side + clamp(p.x, 0.5, side - 0.5)) / float(picture.get_width()), p.y / side);
    float grey = picture.sample(smp, uv, level(0.0)).r;
    return float3(grey) * inside;
}

\(projectionColourShaderFunctions)

// A game's frame while Halliday is over it (design board 14, A): blurred by `away` (a ring of taps
// around `uv`, `texel` the size of one source pixel) and darkened, a little desaturated.
static float3 game_away(texture2d<float> tex, sampler smp, float2 uv, float2 texel, float away,
                        float3 sharp, float4 rect, uint eye, uint colour) {
    float3 sum = sharp;
    float r = away * 9.0;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.5235988;
        float2 off = float2(cos(a), sin(a)) * texel * (i % 2 == 0 ? r : r * 0.5);
        float2 tap = projection_clamp_eye_uv(tex, uv + off, rect, eye, colour);
        sum += tex.sample(smp, tap, level(0.0)).rgb;
    }
    float3 soft = sum / 13.0;
    float grey = dot(soft, float3(0.2126, 0.7152, 0.0722));
    soft = mix(float3(grey), soft, 0.75) * 0.42;
    return mix(sharp, soft, away);
}

// The view's last touch: the fade-up after a change of scene.
static float4 finish_view(float3 color, constant SceneUniforms &u) {
    return float4(color * u.highlight.y, 1.0);
}

struct LayerData {
    float4x4 layerFromWorld; // inverse of the layer's pose
    float4 size;             // x: width (m), y: height (m), z: pixels across the shown region, w: mip levels
    float4 uvRect;           // shown region of the texture: x, y, width, height (0..1, origin top-left)
    float4 stereo;           // x: 0 mono, 1 side by side, 2 top/bottom; y: opacity; z: hover glow (0..1); w: fade from the previous texture (0..1)
    float4 shape;            // x: corner radius (m), y: 1 = has a glass surface, z: the glass's corner radius (m), w: 1 = casts a shadow
    float4 glass;            // the glass surface: center x, y (m from the layer's center), half width, half height
    float4 glass2;           // a second glass surface of the same corner radius (zero: none)
    float4 patch;            // part covered with the color just right of it (0..1, top-left origin; zero: none)
};

// Distance to a panel's glass (one rounded rectangle, or two of the same corner radius), the
// shape moved down by `dy` (for its shadows).
static float glass_sd(float2 p, float4 g, float4 g2, float r, float dy) {
    float2 q = abs(p - g.xy + float2(0.0, dy)) - (g.zw - r);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    if (g2.z > 0.0) {
        float2 q2 = abs(p - g2.xy + float2(0.0, dy)) - (g2.zw - r);
        d = min(d, length(max(q2, 0.0)) + min(max(q2.x, q2.y), 0.0) - r);
    }
    return d;
}

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreen_vs(uint vid [[vertex_id]]) {
    // One triangle covering the viewport; uv 0..1 with v down.
    float2 p = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

constant float3 ACCENT = float3(0.541, 0.706, 1.0); // Night Glass accent #8AB4FF

// Night Glass sky: near-black zenith, deep blue toward a softly glowing horizon.
static float3 sky(float3 d) {
    float h = clamp(d.y, -1.0, 1.0);
    float3 zenith = float3(0.027, 0.031, 0.051);
    float3 mid = float3(0.055, 0.071, 0.125);
    float3 horizon = float3(0.106, 0.133, 0.220);
    float up = max(h, 0.0);
    float3 c = mix(horizon, mid, smoothstep(0.0, 0.25, up));
    c = mix(c, zenith, smoothstep(0.25, 0.9, up));
    c += ACCENT * 0.07 * exp(-abs(h) * 14.0);
    return c;
}

// --- Environments (ROADMAP W12.D) ---
// The place the user stands in. 0: Grid (the plain night grid above). 1: Dusk, a field under a
// low sun. 2: Terrace, a polished platform over city lights at night. 3: Focus, almost nothing.
// 4: a 360° image. Each is a function of the view ray only (plus time, for slow ambient motion),
// so it costs a few noise lookups per pixel.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
               mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x), u.y);
}

static float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * valueNoise(p); p = p * 2.03 + 17.0; a *= 0.5; }
    return v;
}

// Stars: sparse points on a grid over the sky, with a slow twinkle.
static float stars(float3 d, float time, float density) {
    float2 uv = float2(atan2(d.x, -d.z), asin(clamp(d.y, -1.0, 1.0))) * 60.0;
    float2 cell = floor(uv), f = fract(uv) - 0.5;
    float h = hash21(cell);
    if (h > density) return 0.0;
    float2 offset = float2(hash21(cell + 3.1), hash21(cell + 7.7)) - 0.5;
    float r = length(f - offset * 0.6);
    float twinkle = 0.75 + 0.25 * sin(time * (0.6 + h * 40.0) + h * 100.0);
    return smoothstep(0.09, 0.0, r) * twinkle * (0.4 + 0.6 * hash21(cell + 1.3));
}

// Dusk: a field under a sun that has just set, toward −z.
static float3 duskSky(float3 d, float time) {
    float h = d.y;
    float3 zenith = float3(0.030, 0.040, 0.110);
    float3 high = float3(0.110, 0.100, 0.260);
    float3 low = float3(0.560, 0.270, 0.300);
    float3 edge = float3(0.980, 0.560, 0.300);
    float3 c = mix(edge, low, smoothstep(0.0, 0.10, h));
    c = mix(c, high, smoothstep(0.06, 0.38, h));
    c = mix(c, zenith, smoothstep(0.30, 0.95, h));
    // The glow where the sun went down, wide and soft.
    float3 sun = normalize(float3(0.0, 0.02, -1.0));
    float toward = max(dot(normalize(float3(d.x, max(d.y, 0.0), d.z)), sun), 0.0);
    c += float3(1.0, 0.55, 0.25) * (pow(toward, 6.0) * 0.35 + pow(toward, 48.0) * 0.5) * smoothstep(-0.05, 0.25, 0.3 - h);
    // Thin clouds, lit from below, drifting slowly.
    if (h > 0.0) {
        float2 cp = d.xz / (h + 0.18) * 1.6 + float2(time * 0.006, 0.0);
        float cloud = smoothstep(0.52, 0.80, fbm(cp)) * smoothstep(0.02, 0.22, h) * (1.0 - smoothstep(0.55, 0.95, h));
        c = mix(c, mix(float3(0.95, 0.52, 0.42), float3(0.30, 0.22, 0.38), smoothstep(0.05, 0.4, h)), cloud * 0.55);
        c += float3(1.0) * stars(d, time, 0.10) * smoothstep(0.25, 0.7, h);
    }
    return c;
}

static float3 duskScene(float3 o, float3 d, float time, thread float &tGround) {
    float3 c = duskSky(d, time);
    // Far hills against the sky, a silhouette along the horizon.
    float az = atan2(d.x, -d.z);
    float ridge = 0.018 + 0.030 * fbm(float2(az * 3.0, 1.7)) + 0.012 * fbm(float2(az * 11.0, 9.2));
    float3 hillColor = float3(0.060, 0.045, 0.085);
    c = mix(hillColor, c, smoothstep(ridge - 0.003, ridge + 0.001, d.y));
    if (d.y < -1e-4) {
        // The field: dark grass with soft patches, catching a little of the sky's warmth far away.
        float t = -o.y / d.y;
        float2 p = (o + t * d).xz;
        float patch = fbm(p * 0.35);
        float blades = valueNoise(p * 9.0) * exp(-t * 0.25);
        float3 ground = mix(float3(0.030, 0.045, 0.040), float3(0.055, 0.075, 0.055), patch) + blades * 0.012;
        float fog = 1.0 - exp(-t * 0.045);
        c = mix(ground, mix(hillColor, float3(0.42, 0.22, 0.24), 0.25), fog);
        // The last light of the sun lies along the ground toward where it set.
        float toward = max(dot(normalize(float3(d.x, 0.0, d.z)), float3(0.0, 0.0, -1.0)), 0.0);
        c += float3(0.90, 0.42, 0.22) * pow(toward, 10.0) * fog * 0.16;
        tGround = t;
    }
    return c;
}

// Terrace: a polished platform at night, a city far below, a moon and an aurora above.
static float3 terraceSky(float3 d, float time) {
    float h = d.y;
    float3 c = mix(float3(0.040, 0.060, 0.125), float3(0.008, 0.010, 0.028), smoothstep(0.0, 0.8, h));
    c += float3(0.12, 0.20, 0.38) * exp(-max(h, 0.0) * 8.0) * 0.7;
    if (h > 0.0) {
        c += float3(1.0) * stars(d, time, 0.16) * smoothstep(0.05, 0.5, h);
        // Aurora: slow ribbons across the sky ahead.
        float az = atan2(d.x, -d.z);
        float band = fbm(float2(az * 2.2 + time * 0.012, h * 3.0));
        float ribbon = smoothstep(0.42, 0.80, band) * smoothstep(0.06, 0.26, h) * (1.0 - smoothstep(0.45, 0.85, h));
        c += mix(float3(0.10, 0.85, 0.60), float3(0.40, 0.45, 1.00), fbm(float2(az * 1.3, time * 0.02))) * ribbon * 0.55;
        // The moon, high to the left, with a soft halo.
        float3 moon = normalize(float3(-0.55, 0.50, -0.67));
        float m = dot(d, moon);
        c += float3(0.80, 0.86, 1.00) * (smoothstep(0.99955, 0.99975, m) * 0.9 + pow(max(m, 0.0), 220.0) * 0.20 + pow(max(m, 0.0), 24.0) * 0.05);
    }
    return c;
}

// What is around and below the terrace: the sky, or the city far below as lights in haze.
static float3 terraceFar(float3 o, float3 d, float time) {
    float3 c = terraceSky(d, time);
    if (d.y < -1e-4) {
        float depth = 70.0;
        float tc = -(o.y + depth) / d.y;
        float2 q = (o + tc * d).xz;
        float3 lights = float3(0.0);
        // Two scales of lights: streets, and the dense glow of blocks.
        for (int k = 0; k < 2; k++) {
            float size = k == 0 ? 7.0 : 2.6;
            float2 cell = floor(q / size), f = fract(q / size) - 0.5;
            float district = smoothstep(0.38, 0.62, valueNoise(cell * (k == 0 ? 0.07 : 0.03) + 4.0));
            float on = step(hash21(cell), k == 0 ? 0.60 : 0.42) * district;
            float spot = smoothstep(k == 0 ? 0.30 : 0.36, 0.0, length(f - (float2(hash21(cell + 2.0), hash21(cell + 5.0)) - 0.5) * 0.5));
            float3 tint = mix(float3(1.00, 0.70, 0.38), float3(0.55, 0.78, 1.00), step(0.72, hash21(cell + 9.0)));
            lights += tint * spot * on * (k == 0 ? 1.5 : 0.8);
        }
        float haze = exp(-tc * 0.0022);
        c = mix(float3(0.040, 0.060, 0.125), float3(0.010, 0.012, 0.022) + lights, haze);
    }
    return c;
}

// --- More places: painted into the 360° picture like Dusk ---

// The moon of the sea, low and to the right of the panels.
constant float3 SEA_MOON = float3(0.4610, 0.1910, -0.8670);

static float3 seaSky(float3 d, float time, bool withStars) {
    float h = max(d.y, 0.0);
    float3 c = mix(float3(0.055, 0.075, 0.130), float3(0.008, 0.012, 0.035), smoothstep(0.0, 0.6, h));
    float m = dot(d, SEA_MOON);
    c += float3(0.85, 0.88, 1.00) * (smoothstep(0.99985, 0.99991, m) * 1.2 + pow(max(m, 0.0), 600.0) * 0.20 + pow(max(m, 0.0), 18.0) * 0.07);
    if (withStars) c += float3(1.0) * stars(d, time, 0.20) * smoothstep(0.04, 0.4, h) * (1.0 - pow(max(m, 0.0), 6.0));
    return c;
}

// The swell: long slow waves and a finer chop, drifting toward the viewer.
static float seaHeight(float2 p, float time) {
    return 0.30 * fbm(p * 0.05 + float2(0.0, time * 0.02))
         + 0.07 * valueNoise(p * 1.1 + float2(time * 0.10, time * 0.06))
         + 0.025 * valueNoise(p * 3.3 - float2(time * 0.07, time * 0.12));
}

static float3 seaScene(float3 o, float3 d, float time) {
    if (d.y >= -1e-4) return seaSky(d, time, true);
    float t = -o.y / d.y;
    float2 p = (o + t * d).xz;
    // The water's slope from its height, over a wider step far away (the chop averages out there).
    float e = 0.05 + t * 0.006;
    float hx = seaHeight(p + float2(e, 0.0), time) - seaHeight(p - float2(e, 0.0), time);
    float hz = seaHeight(p + float2(0.0, e), time) - seaHeight(p - float2(0.0, e), time);
    float3 n = normalize(float3(-hx / (2.0 * e), 1.0, -hz / (2.0 * e)));
    float3 r = reflect(d, n);
    r.y = abs(r.y);
    float fresnel = 0.02 + 0.98 * pow(1.0 - saturate(dot(-d, n)), 5.0);
    float3 c = float3(0.004, 0.009, 0.018) + seaSky(r, time, false) * fresnel;
    // The moon's path: the waves that tilt toward it catch its light, in a streak toward the viewer.
    float m = max(dot(r, SEA_MOON), 0.0);
    c += float3(0.85, 0.88, 1.00) * (pow(m, 2500.0) * 3.0 + pow(m, 120.0) * 0.10);
    float fog = 1.0 - exp(-t * 0.004);
    return mix(c, float3(0.055, 0.075, 0.130), fog);
}

// Dunes at first light: the sun just under the horizon to the right, sand ridges all around.
constant float3 DUNE_SUN = float3(0.6400, -0.0300, -0.7675);

static float3 duneSky(float3 d, float time) {
    float h = d.y;
    float3 c = mix(float3(0.98, 0.66, 0.44), float3(0.55, 0.36, 0.45), smoothstep(0.0, 0.16, h));
    c = mix(c, float3(0.20, 0.18, 0.36), smoothstep(0.10, 0.45, h));
    c = mix(c, float3(0.07, 0.08, 0.20), smoothstep(0.40, 1.0, h));
    float toward = max(dot(normalize(float3(d.x, 0.0, d.z)), normalize(float3(DUNE_SUN.x, 0.0, DUNE_SUN.z))), 0.0);
    c += float3(1.0, 0.62, 0.36) * (pow(toward, 5.0) * 0.30 + pow(toward, 40.0) * 0.45) * (1.0 - smoothstep(0.0, 0.35, max(h, 0.0)));
    if (h > 0.0) c += float3(1.0) * stars(d, time, 0.06) * smoothstep(0.45, 0.9, h);
    return c;
}

static float duneHeight(float2 p) {
    float warp = fbm(p * 0.010) * 5.0;
    // Ridges with a sharp crest and a long back.
    float s = sin(p.x * 0.045 + p.y * 0.020 + warp);
    float ridge = pow(1.0 - abs(s), 2.0) + 0.25 * s;
    float h = 13.0 * ridge + 9.0 * fbm(p * 0.006);
    // A small flat of sand where the user stands, between the dunes.
    return h * smoothstep(6.0, 30.0, length(p));
}

static float3 duneShade(float3 o, float3 d, float t, float time) {
    float2 p = (o + t * d).xz;
    float e = 0.2 + t * 0.002;
    float3 n = normalize(float3(duneHeight(p - float2(e, 0.0)) - duneHeight(p + float2(e, 0.0)), 2.0 * e,
                                duneHeight(p - float2(0.0, e)) - duneHeight(p + float2(0.0, e))));
    float3 light = normalize(float3(DUNE_SUN.x, 0.16, DUNE_SUN.z));
    float lit = saturate(dot(n, light));
    float3 sand = mix(float3(0.13, 0.09, 0.16), float3(0.95, 0.58, 0.38), smoothstep(0.05, 0.8, lit));
    // The sky's cool light in the shade, and fine ripples in the sand.
    sand += float3(0.05, 0.05, 0.10) * saturate(n.y);
    sand *= 0.88 + 0.12 * valueNoise(p * float2(2.0, 6.0));
    // Haze: far dunes fade toward the dim sky just above the horizon (not its bright band).
    float fog = 1.0 - exp(-t * 0.005);
    return mix(sand * 0.62, duneSky(normalize(float3(d.x, 0.12, d.z)), time) * 0.7, fog);
}

static float3 duneScene(float3 o, float3 d, float time) {
    float3 sky = duneSky(d, time);
    // March the ray over the height field (baked, so it can afford it), then refine the hit.
    // A ray that only just clears a crest is partly sand: how narrowly it missed, in texels of the
    // baked picture, softens the crest's edge, which would otherwise show the texels as steps.
    const float texel = M_PI_F / 2048.0;
    float t = 0.5, last = 0.5, closest = 1e9, tClosest = 0.0;
    bool hit = false;
    for (int i = 0; i < 200 && t < 1200.0; i++) {
        float3 q = o + t * d;
        float gap = q.y - duneHeight(q.xz);
        if (gap < 0.0) { hit = true; break; }
        float ratio = gap / (t * texel);
        if (ratio < closest) { closest = ratio; tClosest = t; }
        last = t;
        // Small steps where the ray grazes a crest, so thin crests aren't stepped over.
        t += max(gap * 0.45, 0.003 * t);
    }
    if (!hit) {
        float cover = saturate(1.0 - closest);
        return cover > 0.0 ? mix(sky, duneShade(o, d, tClosest, time), cover) : sky;
    }
    for (int i = 0; i < 6; i++) {
        float mid = 0.5 * (last + t);
        float3 q = o + mid * d;
        if (q.y < duneHeight(q.xz)) t = mid; else last = mid;
    }
    return duneShade(o, d, t, time);
}

// A ring of conifers seen from inside the clearing: the top of the silhouette at azimuth az.
static float treeLine(float az, float cells, float seed, float low, float high) {
    float f = az / (2.0 * M_PI_F) * cells;
    float top = -1.0;
    // A tree's crown is wider than its cell: look at the neighbours too.
    for (int k = -1; k <= 1; k++) {
        float cell = floor(f) + float(k);
        float x = f - cell - 0.5 + 0.3 * (hash21(float2(cell, seed + 1.0)) - 0.5);
        float tall = mix(low, high, hash21(float2(cell, seed)));
        // Tiers: a saw-toothed edge down the cone.
        float width = 1.1 + 0.5 * hash21(float2(cell, seed + 2.0));
        float cone = tall - abs(x) * width * tall;
        // Seven tiers of branches: each droops from the trunk out to its tip.
        float tier = fract((tall - cone) * 7.0 / tall);
        top = max(top, cone - 0.06 * tall * tier * tier * smoothstep(0.0, 0.06, abs(x)));
    }
    return top;
}

static float3 forestScene(float3 o, float3 d, float time) {
    float h = d.y;
    float3 c = mix(float3(0.050, 0.070, 0.095), float3(0.006, 0.010, 0.022), smoothstep(0.0, 0.7, max(h, 0.0)));
    if (h > 0.0) c += float3(1.0) * stars(d, time, 0.16) * smoothstep(0.25, 0.6, h);
    float az = atan2(d.x, -d.z);
    // Two rows: the far one a little lighter in the haze, the near one taller and black.
    float far = treeLine(az, 170.0, 3.0, 0.16, 0.26);
    float near = treeLine(az + 0.013, 95.0, 11.0, 0.22, 0.42);
    float aa = 0.003;
    c = mix(c, float3(0.016, 0.024, 0.030), 1.0 - smoothstep(far - aa, far + aa, h));
    c = mix(c, float3(0.005, 0.009, 0.010), 1.0 - smoothstep(near - aa, near + aa, h));
    if (h < -1e-4) {
        float t = -o.y / h;
        float2 p = (o + t * d).xz;
        float3 grass = mix(float3(0.026, 0.044, 0.032), float3(0.044, 0.068, 0.048), fbm(p * 0.4));
        grass *= 0.8 + 0.4 * valueNoise(p * 5.0);
        float r = length(p);
        c = mix(grass, float3(0.005, 0.009, 0.010), smoothstep(14.0, 22.0, r));
    }
    return c;
}

// Snowfield under an aurora: snow to low hills on the horizon, curtains of green light above.
static float3 snowScene(float3 o, float3 d, float time) {
    float h = d.y;
    float3 glow = float3(0.060, 0.085, 0.120);
    float3 c = mix(glow, float3(0.004, 0.008, 0.024), smoothstep(0.0, 0.6, max(h, 0.0)));
    float az = atan2(d.x, -d.z);
    if (h > 0.0) {
        c += float3(1.0) * stars(d, time, 0.18) * smoothstep(0.05, 0.5, h);
        // Two curtains, folding slowly; tall rays within them.
        for (int k = 0; k < 2; k++) {
            float fold = fbm(float2(az * (1.4 + k * 0.7) + time * 0.008, k * 5.0)) * 0.35;
            float base = 0.14 + k * 0.10 + fold;
            float curtain = smoothstep(base - 0.03, base + 0.03, h) * (1.0 - smoothstep(base + 0.06, base + 0.38, h));
            float rays = 0.55 + 0.45 * valueNoise(float2(az * 80.0, k * 7.0 + time * 0.05));
            float3 tint = mix(float3(0.15, 0.95, 0.55), float3(0.45, 0.40, 1.00), smoothstep(base + 0.05, base + 0.35, h));
            c += tint * curtain * rays * (k == 0 ? 0.30 : 0.18);
        }
        // Low hills far away, under the snow's haze.
        float hills = 0.012 + 0.030 * fbm(float2(az * 3.0, 2.0)) + 0.010 * fbm(float2(az * 14.0, 6.0));
        c = mix(c, float3(0.026, 0.036, 0.056), 1.0 - smoothstep(hills - 0.002, hills + 0.002, h));
    }
    if (h < -1e-4) {
        float t = -o.y / h;
        float2 p = (o + t * d).xz;
        float drift = fbm(p * float2(0.08, 0.30)) * 0.5 + valueNoise(p * 1.5) * 0.15;
        float3 snow = float3(0.150, 0.178, 0.235) * (0.80 + 0.35 * drift);
        // The aurora's green on the snow, strongest toward where it hangs.
        snow += float3(0.02, 0.07, 0.04) * (0.5 + 0.5 * sin(az * 1.4 + 1.0));
        float fog = 1.0 - exp(-t * 0.012);
        c = mix(snow, float3(0.080, 0.100, 0.135), fog);
    }
    return c;
}

// Deep space: stars, a faint nebula, a small planet below to the left. No floor.
constant float3 SPACE_PLANET = float3(-0.5850, -0.3090, -0.7500); // where it is; it spans about 9°

static float3 spaceScene(float3 d, float time) {
    float az = atan2(d.x, -d.z), el = asin(clamp(d.y, -1.0, 1.0));
    float2 q = float2(az, el) * 1.3;
    float cloud = fbm(q * 1.6 + 3.0) * fbm(q * 3.1 - 7.0);
    float3 nebula = mix(float3(0.20, 0.10, 0.40), float3(0.05, 0.30, 0.45), fbm(q * 0.9 + 11.0)) * smoothstep(0.12, 0.45, cloud) * 0.55;
    float3 c = float3(0.006, 0.006, 0.014) + nebula;
    c += float3(1.0) * (stars(d, time, 0.22) + 0.6 * stars(float3(d.z, d.x, d.y), time, 0.30));
    // The planet: lit from the upper right, with a thin atmosphere at its edge.
    float m = dot(d, SPACE_PLANET), radius = 0.9969;
    if (m > radius) {
        // The sphere's normal where the ray meets it: the offset from its center, in units of its
        // apparent radius, lifted toward the viewer.
        float3 u = (d - SPACE_PLANET * m) / sqrt(1.0 - radius * radius);
        float3 n = normalize(u - SPACE_PLANET * sqrt(saturate(1.0 - dot(u, u))));
        float lit = saturate(dot(n, normalize(float3(0.75, 0.55, 0.35))));
        float bands = fbm(float2(atan2(n.x, n.z) * 1.5, n.y * 9.0));
        float3 surface = mix(float3(0.12, 0.18, 0.30), float3(0.38, 0.54, 0.68), bands);
        c = surface * (0.02 + 0.85 * lit);
    }
    c += float3(0.35, 0.60, 1.00) * smoothstep(radius - 0.0012, radius, m) * (1.0 - smoothstep(radius, radius + 0.0004, m)) * 0.5;
    return c;
}

// The lounge (board 12, A): a pavilion on a summit above a sea of clouds at dusk. The far view is
// baked (pavilionFar); the floor, the roof and its columns are traced live (pavilion), so they
// stand still as the user leans and walks.
constant float3 PAV_SUN = float3(-0.4223, -0.0349, -0.9057); // just under the horizon, left of the panels
constant float PAV_FLOOR = 30.0, PAV_ROOF_Y = 15.0, PAV_ROOF = 38.0, PAV_OCULUS = 10.0;
constant float PAV_COLUMN_RING = 24.0, PAV_COLUMN = 0.3;

static float3 pavilionSky(float3 d, float time) {
    float h = max(d.y, 0.0);
    float3 c = mix(float3(0.95, 0.60, 0.42), float3(0.62, 0.34, 0.44), smoothstep(0.0, 0.12, h));
    c = mix(c, float3(0.22, 0.17, 0.34), smoothstep(0.08, 0.40, h));
    c = mix(c, float3(0.05, 0.06, 0.16), smoothstep(0.35, 1.0, h));
    float toward = max(dot(normalize(float3(d.x, 0.0, d.z) + 1e-5), normalize(float3(PAV_SUN.x, 0.0, PAV_SUN.z))), 0.0);
    c += float3(1.0, 0.60, 0.35) * (pow(toward, 6.0) * 0.22 + pow(toward, 40.0) * 0.35) * (1.0 - smoothstep(0.0, 0.3, h));
    c += float3(1.0) * stars(d, time, 0.14) * smoothstep(0.35, 0.8, h);
    return c;
}

// The peaks rising out of the clouds: the top of their silhouette (sine of the elevation). Each
// cell of azimuth may hold one peak, a cone with its own height and steepness, roughened by noise.
static float pavilionPeaks(float az) {
    const float cell = 0.22;
    float f = az / cell, top = -0.02;
    for (int k = -2; k <= 2; k++) {
        float c = floor(f) + float(k);
        float2 key = float2(c, 21.0);
        if (hash21(key) < 0.45) continue;
        float centre = (c + 0.5 + 0.6 * (hash21(key + 1.0) - 0.5)) * cell;
        float height = 0.015 + 0.060 * hash21(key + 2.0) * hash21(key + 3.0);
        float steep = 0.18 + 0.25 * hash21(key + 4.0);
        top = max(top, height - abs(az - centre) * steep);
    }
    return top + 0.004 * (fbm(float2(az * 60.0, 5.0)) - 0.5) - 0.006;
}

static float3 pavilionFar(float3 d, float time) {
    float3 sky = pavilionSky(d, time);
    float3 horizon = pavilionSky(normalize(float3(d.x, 0.0, d.z) + 1e-5), time);
    float az = atan2(d.x, -d.z);
    float top = pavilionPeaks(az);
    float3 c = sky;
    if (d.y < -0.004) {
        // The sea of clouds, 350 m below: drifting banks lit warm toward the sun.
        float t = 350.0 / -d.y;
        float2 p = d.xz * t;
        float banks = fbm(p * 0.0012 + float2(time * 0.004, 0.0));
        float puffs = fbm(p * 0.0045 - float2(0.0, time * 0.006));
        float body = smoothstep(0.30, 0.72, banks * 0.7 + puffs * 0.3);
        float toward = pow(max(dot(normalize(d.xz), normalize(PAV_SUN.xz)), 0.0), 3.0);
        float3 lit = mix(float3(0.40, 0.28, 0.42), float3(0.98, 0.66, 0.52), 0.2 + 0.8 * toward);
        c = mix(float3(0.16, 0.12, 0.22), lit, body);
        c = mix(c, horizon * 0.92, 1.0 - exp(-t * 0.00004));
    }
    if (d.y < top && d.y > -0.03) {
        // A peak: dark rock, its crest and the side toward the sun catching the light; hazy.
        float slope = pavilionPeaks(az + 0.002) - pavilionPeaks(az - 0.002);
        float3 rock = float3(0.20, 0.14, 0.24);
        float crest = smoothstep(top - 0.012, top - 0.002, d.y) * (slope > 0.0 ? 1.0 : 0.35);
        rock = mix(rock, float3(0.80, 0.56, 0.52), crest * 0.7);
        float edge = smoothstep(top, top - 0.0015, d.y);
        c = mix(c, mix(rock, horizon, 0.35), edge);
    }
    return c;
}

static float3 envAt(texture2d<float> env, sampler smp, float3 d) {
    float lon = atan2(d.x, -d.z), lat = asin(clamp(d.y, -1.0, 1.0));
    return env.sample(smp, float2(fract(0.5 + lon / (2.0 * M_PI_F)), 0.5 - lat / M_PI_F), level(0.0)).rgb;
}

static float3 pavilionRoof(float2 p) {
    // Its underside holds the glow of the sky and the clouds, warmest toward the edge and the sun;
    // shallow rings make it read as a built surface.
    float r = length(p);
    float toward = 0.5 + 0.5 * dot(normalize(p + 1e-4), normalize(PAV_SUN.xz));
    float3 c = float3(0.040, 0.032, 0.052) + float3(0.20, 0.12, 0.12) * smoothstep(PAV_OCULUS, PAV_ROOF, r) * (0.5 + 0.5 * toward);
    float aa = max(fwidth(r), 1e-3);
    float groove = 1.0 - smoothstep(0.02, 0.02 + aa, abs(fract(r / 2.5 + 0.5) - 0.5) * 2.5);
    c *= 1.0 - 0.25 * groove;
    float rims = smoothstep(PAV_ROOF - 0.15 - aa, PAV_ROOF - 0.15, r) + 1.0 - smoothstep(PAV_OCULUS + 0.15, PAV_OCULUS + 0.15 + aa, r);
    return c + ACCENT * 0.30 * rims;
}

static void pavilion(float3 o, float3 d, thread float3 &color, thread float &tGround, texture2d<float> env, sampler smp) {
    float best = INFINITY;
    int what = 0; // 1 floor, 2 roof, 3 column
    float2 columnCenter = float2(0.0);
    if (d.y < -1e-4) {
        float t = -o.y / d.y;
        if (length((o + t * d).xz) < PAV_FLOOR) { best = t; what = 1; }
    } else if (d.y > 1e-4) {
        float t = (PAV_ROOF_Y - o.y) / d.y;
        float r = length((o + t * d).xz);
        if (r < PAV_ROOF && r > PAV_OCULUS) { best = t; what = 2; }
    }
    // Eight slender columns on a ring, none straight ahead. Near the middle (where the user
    // usually is) only the column in the ray's eighth of the circle and its neighbours can be hit.
    float a = dot(d.xz, d.xz);
    if (a > 1e-6) {
        bool near = dot(o.xz, o.xz) < 16.0;
        float sector = floor(atan2(d.x, -d.z) / (M_PI_F / 4.0));
        for (int j = 0; j < (near ? 3 : 8); j++) {
            float i = near ? sector + float(j) - 1.0 : float(j);
            float ang = (i + 0.5) * M_PI_F / 4.0;
            float2 cc = float2(sin(ang), -cos(ang)) * PAV_COLUMN_RING;
            float2 oc = o.xz - cc;
            float b = dot(oc, d.xz), k = dot(oc, oc) - PAV_COLUMN * PAV_COLUMN;
            float disc = b * b - a * k;
            if (disc > 0.0) {
                float t = (-b - sqrt(disc)) / a;
                float y = o.y + t * d.y;
                if (t > 0.0 && t < best && y > 0.0 && y < PAV_ROOF_Y) { best = t; what = 3; columnCenter = cc; }
            }
        }
    }
    tGround = best;
    if (what == 0) return; // the sky, the clouds below or the peaks: the baked picture
    float3 q = o + best * d;
    if (what == 1) {
        // Dark polished stone in large slabs, holding the sky and the roof; a warm line at its edge.
        float2 p = q.xz;
        float r = length(p);
        float3 rd = float3(d.x, -d.y, d.z);
        float tr = (PAV_ROOF_Y - q.y) / rd.y;
        float2 pr = p + tr * rd.xz;
        float rr = length(pr);
        float3 mirrored = (rr < PAV_ROOF && rr > PAV_OCULUS) ? pavilionRoof(pr) : envAt(env, smp, rd);
        float fresnel = pow(1.0 - saturate(-d.y), 4.0);
        float2 g = abs(fract(p / 3.0 + 0.5) - 0.5) * 3.0;
        float2 ga = max(fwidth(p), float2(1e-3));
        float joints = 1.0 - smoothstep(0.004, 0.004 + ga.x, g.x) * smoothstep(0.004, 0.004 + ga.y, g.y);
        float3 stone = float3(0.028, 0.025, 0.038) * (1.0 - 0.3 * joints);
        float aa = max(fwidth(r), 1e-3);
        float edge = smoothstep(PAV_FLOOR - 0.08 - aa, PAV_FLOOR - 0.08, r);
        color = stone + mirrored * (0.06 + 0.60 * fresnel) + float3(0.95, 0.65, 0.50) * edge * 0.45;
    } else if (what == 2) {
        color = pavilionRoof(q.xz);
    } else {
        // A column: dark, with the sun's warm light along one side and the floor's bounce low down.
        float2 n = normalize(q.xz - columnCenter);
        float lit = saturate(dot(n, normalize(PAV_SUN.xz)));
        color = float3(0.016, 0.014, 0.022) + float3(0.90, 0.55, 0.40) * 0.22 * lit * lit
              + float3(0.05, 0.04, 0.06) * (1.0 - smoothstep(0.0, 3.0, q.y));
    }
}

// Live touches drawn over the baked picture each frame (the bake refreshes every few seconds,
// too slow for these): glints on the sea in the moon's path, fireflies in the clearing, sand
// blowing off the dunes. Each is kept to the pixels where it can appear.
constant int FIREFLY_COUNT = 12; // Renderer.fireflyCount

static float3 liveTouches(int place, float3 o, float3 d, float time, constant float4 *fireflies) {
    float3 c = float3(0.0);
    if (place == 5 && d.y < -1e-4) {
        float t = -o.y / d.y;
        float2 p = (o + t * d).xz;
        float toward = pow(max(dot(normalize(float3(d.x, 0.0, d.z)), normalize(float3(SEA_MOON.x, 0.0, SEA_MOON.z))), 0.0), 400.0);
        if (toward > 0.01) {
            float2 cell = floor(p * float2(2.0, 0.8));
            float g = hash21(cell + floor(time * 2.0 + hash21(cell) * 7.0));
            c += float3(0.9, 0.92, 1.0) * step(0.97, g) * toward * exp(-t * 0.02) * 0.6;
        }
    } else if (place == 6 && d.y > -0.05 && d.y < 0.03) {
        float az = atan2(d.x, -d.z);
        float wisp = valueNoise(float2(az * 60.0 - time * 0.9, d.y * 300.0)) * valueNoise(float2(az * 13.0 - time * 0.3, 4.0));
        c += float3(0.95, 0.70, 0.52) * wisp * 0.05 * (1.0 - smoothstep(0.0, 0.03, abs(d.y + 0.01)));
    } else if (place == 7 && d.y > -0.35 && d.y < 0.35) {
        for (int i = 0; i < FIREFLY_COUNT; i++) {
            float3 to = fireflies[i].xyz - o;
            float along = dot(d, to);
            // The squared distance from the ray to the firefly, in meters: no trigonometry.
            float miss = dot(to, to) - along * along;
            if (along > 0.0 && miss < 0.03) c += float3(0.85, 0.95, 0.45) * (exp(-miss / 0.0003) + 0.15 * exp(-miss / 0.004)) * fireflies[i].w;
        }
    }
    return c;
}

// Focus: nothing to look at. A dark, even space with the faintest floor.
static float3 focusScene(float3 o, float3 d, thread float &tGround) {
    float3 c = mix(float3(0.030, 0.032, 0.040), float3(0.012, 0.013, 0.018), smoothstep(-0.2, 0.9, d.y));
    if (d.y < -1e-4) {
        float t = -o.y / d.y;
        float r = length((o + t * d).xz);
        c = mix(float3(0.040, 0.042, 0.052), c, 1.0 - exp(-r * 0.25));
        tGround = t;
    }
    return c;
}

static float grid(float2 p, float2 fw, float spacing, float width) {
    float2 g = abs(fract(p / spacing - 0.5) - 0.5) * spacing;
    float2 aa = max(fw, 1e-4);
    float2 line = 1.0 - smoothstep(width - aa, width + aa, g);
    return max(line.x, line.y);
}

static bool hitBox(float3 o, float3 d, float3 bmin, float3 bmax, thread float &t, thread float3 &n) {
    float3 inv = 1.0 / d;
    float3 t0 = (bmin - o) * inv, t1 = (bmax - o) * inv;
    float3 tmin = min(t0, t1), tmax = max(t0, t1);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn > tf || tf < 0.0) return false;
    t = tn;
    n = -sign(d) * step(tmin.yzx, tmin) * step(tmin.zxy, tmin);
    return true;
}

// --- Geometry: 3D places, drawn with depth before the scene pass (Scene3D.swift) ---

struct PlaceVertex {
    packed_float3 position;
    packed_float3 normal;
    float2 uv;
};

struct MeshUniforms {
    float4x4 viewProjection; // clip from world, for this eye
    float4x4 model;          // world from the part
    float4 eye;              // xyz: the eye in the world
    float4 baseColor;
    float4 emission;         // xyz; w: 1 = sample the base color texture
};

struct MeshOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};

vertex MeshOut mesh_vs(uint vid [[vertex_id]], const device PlaceVertex *vertices [[buffer(0)]],
                       constant MeshUniforms &u [[buffer(1)]]) {
    PlaceVertex v = vertices[vid];
    float4 world = u.model * float4(float3(v.position), 1.0);
    MeshOut o;
    o.position = u.viewProjection * world;
    o.world = world.xyz;
    o.normal = normalize((u.model * float4(float3(v.normal), 0.0)).xyz);
    o.uv = v.uv;
    return o;
}

struct MeshTargets {
    float4 color [[color(0)]];
    float distance [[color(1)]];
};

fragment MeshTargets mesh_fs(MeshOut in [[stage_in]], constant MeshUniforms &u [[buffer(1)]],
                             texture2d<float> baseTexture [[texture(0)]], sampler smp [[sampler(0)]]) {
    float3 base = u.baseColor.rgb;
    if (u.emission.w > 0.5) base *= baseTexture.sample(smp, in.uv).rgb;
    // A soft key light from above and a little behind, and a fill: calm, no hard shadows.
    float3 n = normalize(in.normal);
    float3 toEye = normalize(u.eye.xyz - in.world);
    if (dot(n, toEye) < 0.0) n = -n; // two-sided
    float key = max(dot(n, normalize(float3(0.35, 0.85, 0.40))), 0.0);
    float fill = 0.5 + 0.5 * n.y;
    float3 c = base * (0.18 + 0.55 * key + 0.22 * fill) + u.emission.xyz;
    MeshTargets t;
    t.color = float4(c, 1.0);
    t.distance = length(in.world - u.eye.xyz);
    return t;
}

fragment float4 scene_fs(FullscreenOut in [[stage_in]],
                         constant SceneUniforms &u [[buffer(0)]],
                         constant LayerData *layers [[buffer(1)]],
                         constant float4 *fireflies [[buffer(2)]],
                         array<texture2d<float>, MAX_LAYERS> textures [[texture(0)]],
                         texture2d<float> projTexture [[texture(24)]],
                         texture2d<float> videoTexture [[texture(25)]],
                         texture2d<float> envTexture [[texture(26)]],
                         array<texture2d<float>, MAX_LAYERS> previousTextures [[texture(27)]],
                         texture2d<float> meshColor [[texture(51)]],
                         texture2d<float> meshDistance [[texture(52)]],
                         texture2d<float> cameraPicture [[texture(53)]],
                         texture2d<float> projSRGBTexture [[texture(54)]],
                         sampler smp [[sampler(0)]]) {
    float tx = mix(u.tanLRUD.x, u.tanLRUD.y, in.uv.x);
    float ty = mix(u.tanLRUD.z, u.tanLRUD.w, in.uv.y);
    float3x3 rot = float3x3(u.rotation[0].xyz, u.rotation[1].xyz, u.rotation[2].xyz);
    float3 d = normalize(rot * float3(tx, ty, -1.0));
    float3 o = u.eyePosition.xyz;

    // Immersive page: reproject its image (rendered with an older head rotation) into the current
    // view. Rotation only: the scene is treated as far away, which hides most of the latency. The
    // page replaces the environment and the panels; the saber and the recenter ring go over it.
    bool immersive = u.projFlags.x > 0.5;
    float3 page = float3(0.0);
    float pageAlpha = 1.0;
    float videoKeep = 1.0; // how much of a passthrough video's pixel is its own (the rest is the room's)
    if (immersive) {
        // Positional reprojection: the point this ray meets at the assumed depth, seen from where
        // the head was when the frame was rendered.
        float3 dr = u.projShift.w > 0.0 ? normalize(d * u.projShift.w + u.projShift.xyz) : d;
        float3 r = (u.projFromWorld * float4(dr, 0.0)).xyz;
        if (r.z < -1e-4) {
            float2 tanXY = r.xy / -r.z;
            float2 eyeUV = float2((tanXY.x - u.projTan.x) / (u.projTan.y - u.projTan.x),
                                  (u.projTan.z - tanXY.y) / (u.projTan.z - u.projTan.w));
            if (all(eyeUV >= 0.0) && all(eyeUV <= 1.0)) {
                float2 sbs = float2((u.projFlags.y + eyeUV.x) * 0.5, eyeUV.y);
                float2 uv = u.projUV.xy + sbs * u.projUV.zw;
                uint colour = uint(u.projFlags.y < 0.5 ? u.gameAway.z : u.gameAway.w);
                uint sourceEye = uint(u.projFlags.y);
                uv = projection_clamp_eye_uv(projTexture, uv, u.projUV, sourceEye, colour);
                float4 drawn = projection_sample(projTexture, projSRGBTexture, smp, uv, colour);
                page = drawn.rgb;
                pageAlpha = drawn.a;
                if (u.gameAway.x > 0.001) {
                    float2 texel = 1.0 / float2(projTexture.get_width(), projTexture.get_height());
                    if (colour == 2) page = game_away(projSRGBTexture, smp, uv, texel, u.gameAway.x, page, u.projUV, sourceEye, colour);
                    else page = game_away(projTexture, smp, uv, texel, u.gameAway.x, page, u.projUV, sourceEye, colour);
                }
                page = projection_display_rgb(page, pageAlpha, colour, u.gameAway.y > 0.5);
            } else if (u.projTanOther.y > u.projTanOther.x) {
                // The desktop view is wider than one eye's image on its inner side: the other eye
                // (the right one) covers it.
                float2 otherUV = float2((tanXY.x - u.projTanOther.x) / (u.projTanOther.y - u.projTanOther.x),
                                        (u.projTanOther.z - tanXY.y) / (u.projTanOther.z - u.projTanOther.w));
                if (all(otherUV >= 0.0) && all(otherUV <= 1.0)) {
                    float2 sbs = float2((1.0 + otherUV.x) * 0.5, otherUV.y);
                    float2 uv = u.projUV.xy + sbs * u.projUV.zw;
                    uint colour = uint(u.gameAway.w);
                    uv = projection_clamp_eye_uv(projTexture, uv, u.projUV, 1, colour);
                    float4 drawn = projection_sample(projTexture, projSRGBTexture, smp, uv, colour);
                    page = drawn.rgb;
                    if (u.gameAway.x > 0.001) {
                        float2 texel = 1.0 / float2(projTexture.get_width(), projTexture.get_height());
                        if (colour == 2) page = game_away(projSRGBTexture, smp, uv, texel, u.gameAway.x, page, u.projUV, 1, colour);
                        else page = game_away(projTexture, smp, uv, texel, u.gameAway.x, page, u.projUV, 1, colour);
                    }
                    page = projection_display_rgb(page, drawn.a, colour, u.gameAway.y > 0.5);
                }
            }
        }
    }

    float eye = u.projFlags.y;

    // Video sphere: the whole surroundings are the video.
    float3 color = float3(0.0);
    float tHit = INFINITY;
    bool video = u.videoParams.x > 0.5;
    bool surround = video || immersive;
    if (immersive) {
        color = page;
    } else if (video) {
        float3 v = (u.videoFromWorld * float4(d, 0.0)).xyz;
        // Zoom: angles from straight ahead shrink (zoomed in) or grow, so the picture is larger
        // or smaller around the middle of the view; then the tilt, so the middle of the view
        // is the part of the video the user chose.
        float zoom = max(u.videoParams.w, 0.1);
        bool beyond = false;
        if (abs(zoom - 1.0) > 0.001) {
            float away = acos(clamp(-v.z, -1.0, 1.0)) / zoom;
            beyond = away > M_PI_F;
            float2 side = v.xy / max(length(v.xy), 1e-6);
            v = float3(side * sin(away), -cos(away));
        }
        v = (u.videoTilt * float4(v, 0.0)).xyz;
        int kind = int(u.videoParams.x + 0.5);
        float2 uv;
        bool outside = false;
        if (kind == 3) {
            // Fisheye (equidistant): angle from the lens axis maps linearly to radius.
            float theta = acos(clamp(-v.z, -1.0, 1.0));
            float r = theta / (u.videoParams.z * 0.5) * 0.5;
            float phi = atan2(v.y, v.x);
            uv = float2(0.5 + r * cos(phi), 0.5 - r * sin(phi));
            outside = r > 0.5;
        } else {
            float lon = atan2(v.x, -v.z);
            float lat = asin(clamp(v.y, -1.0, 1.0));
            if (kind == 2) {
                outside = abs(lon) > M_PI_F * 0.5;
                uv = float2(0.5 + lon / M_PI_F, 0.5 - lat / M_PI_F);
            } else {
                uv = float2(0.5 + lon / (2.0 * M_PI_F), 0.5 - lat / M_PI_F);
            }
        }
        int stereo = int(u.videoParams.y + 0.5);
        float videoEye = u.videoView.x > 0.5 ? 0.0 : eye;
        if (stereo == 1) uv.x = (videoEye + uv.x) * 0.5;
        else if (stereo == 2) uv.y = (videoEye + uv.y) * 0.5;
        // Halliday's panels (video controls, dock) and the saber are drawn over the video below.
        // A video that carries its mask in the frame: the picture is one half of the frame
        // (the upper, or the left) and the other half says, in grey, how much of each of its
        // pixels is the video's own (white) and how much the room's (black).
        float2 maskUV = uv;
        bool masked = u.videoKey.w > 3.5 && u.videoKey.w < 5.5;
        if (masked && u.videoKey.w > 4.5) {
            uv.x *= 0.5;
            maskUV = float2(uv.x + 0.5, uv.y);
        } else if (masked) {
            uv.y *= 0.5;
            maskUV = float2(uv.x, uv.y + 0.5);
        }
        color = (outside || beyond) ? float3(0.0) : videoTexture.sample(smp, uv, level(0.0)).rgb;
        // A video made for passthrough: its backdrop is one flat colour (or black), and the
        // room belongs there. Keyed on the colour's hue, whatever its brightness (a cone around
        // the key's direction in the chroma plane), with the key's tint taken off the edges.
        if (u.videoKey.w > 5.5) {
            // The backdrop's colour as measured in this video (`VideoPlayer.scanBackdrop`): a
            // pixel is the room's by how near it is to that colour, hue counting in full and
            // brightness by `videoKeyFit.z` (little for a coloured backdrop, whose folds and
            // shadows are the same hue darker; in full for a black, grey or white one).
            const float3 LUMA = float3(0.299, 0.587, 0.114), CB = float3(-0.169, -0.331, 0.5), CR = float3(0.5, -0.419, -0.081);
            float2 ch = float2(dot(color, CB), dot(color, CR));
            float2 kch = float2(dot(u.videoKey.rgb, CB), dot(u.videoKey.rgb, CR));
            float ly = dot(color, LUMA), dy = ly - dot(u.videoKey.rgb, LUMA);
            float d = sqrt(dot(ch - kch, ch - kch) + u.videoKeyFit.z * dy * dy);
            if (u.videoKeyFit.y > 0.0) {
                videoKeep = smoothstep(u.videoKeyFit.x, u.videoKeyFit.y, d);
                // A coloured backdrop tints what stands before it: its hue is taken off the edges.
                if (length(kch) > 0.08) {
                    float2 k = normalize(kch);
                    // (Only close to the backdrop's colour: farther out it turned a blue of the
                    // video's own towards purple.)
                    float spill = 1.0 - smoothstep(u.videoKeyFit.y, u.videoKeyFit.y + 0.07, d);
                    float2 clean = ch - k * max(dot(ch, k) - 0.02, 0.0) * spill;
                    color = float3(ly + 1.402 * clean.y, ly - 0.344 * clean.x - 0.714 * clean.y, ly + 1.772 * clean.x);
                }
            }
        } else if (masked) {
            float3 m = videoTexture.sample(smp, maskUV, level(0.0)).rgb;
            videoKeep = smoothstep(0.04, 0.96, dot(m, float3(0.2126, 0.7152, 0.0722)));
        } else if (u.videoKey.w > 2.5) {
            // A grey backdrop has no hue to go by: what is as grey as it (hardly any colour)
            // and as bright as it (videoKey.r) is the room's. Grey things of the video's own
            // at that brightness go with it; a coloured backdrop keys cleaner.
            float2 ch = float2(dot(color, float3(-0.169, -0.331, 0.5)), dot(color, float3(0.5, -0.419, -0.081)));
            float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
            videoKeep = max(smoothstep(0.025, 0.07, length(ch)), smoothstep(0.08, 0.16, abs(luma - u.videoKey.r)));
        } else if (u.videoKey.w > 1.5) {
            videoKeep = smoothstep(0.03, 0.10, max(color.r, max(color.g, color.b)));
        } else if (u.videoKey.w > 0.5) {
            float2 ch = float2(dot(color, float3(-0.169, -0.331, 0.5)), dot(color, float3(0.5, -0.419, -0.081)));
            float2 k = normalize(float2(dot(u.videoKey.rgb, float3(-0.169, -0.331, 0.5)), dot(u.videoKey.rgb, float3(0.5, -0.419, -0.081))));
            float along = dot(ch, k);
            float keyness = along - 1.5 * length(ch - along * k);
            videoKeep = 1.0 - smoothstep(0.06, 0.16, keyness);
            float spill = clamp(keyness / 0.06, 0.0, 1.0);
            float3 other = color * (1.0 - u.videoKey.rgb);
            float cap = max(other.r, max(other.g, other.b));
            color = mix(color, min(color, float3(cap) + color * (1.0 - u.videoKey.rgb)), spill);
        }
        if (outside || beyond) videoKeep = 1.0;
        color *= videoKeep * u.videoView.y;
    }

    // The environment the user stands in (u.envParams.z; see "Environments" above).
    int place = int(u.envParams.z + 0.5);
    if (!surround) {
        float tGround = INFINITY;
        if (place == 1 || place == 2 || place >= 5) {
            // Dusk, Terrace and the places of round 4 are painted into a 360° picture a strip at a
            // time (env_bake_fs) and looked up here: their clouds, stars and city cost one texture
            // sample per pixel.
            float lon = atan2(d.x, -d.z), lat = asin(clamp(d.y, -1.0, 1.0));
            color = envTexture.sample(smp, float2(fract(0.5 + lon / (2.0 * M_PI_F)), 0.5 - lat / M_PI_F), level(0.0)).rgb;
            if (d.y < -1e-4) {
                tGround = -o.y / d.y;
                if (place == 2) {
                    // The terrace's platform is near, so it is drawn here, where it moves as the
                    // user does: dark stone polished enough to hold the sky, with fine rings.
                    float2 p = (o + tGround * d).xz;
                    float r = length(p), radius = 7.0;
                    if (r < radius) {
                        float rlon = atan2(d.x, -d.z), rlat = asin(clamp(-d.y, -1.0, 1.0));
                        float3 mirrored = envTexture.sample(smp, float2(fract(0.5 + rlon / (2.0 * M_PI_F)), 0.5 - rlat / M_PI_F), level(0.0)).rgb;
                        float fresnel = pow(1.0 - saturate(-d.y), 3.0);
                        float3 stone = float3(0.030, 0.034, 0.048) + 0.010 * valueNoise(p * 6.0);
                        float aa = max(fwidth(r), 1e-4);
                        float rings = 1.0 - smoothstep(0.006, 0.006 + aa, abs(fract(r + 0.5) - 0.5));
                        float rim = smoothstep(radius - 0.05 - aa, radius - 0.05, r);
                        color = stone + mirrored * (0.10 + 0.55 * fresnel) + ACCENT * (rings * 0.035 + rim * 0.5);
                    } else {
                        tGround = INFINITY;
                    }
                }
                // Deep space has no floor.
                if (place == 9) tGround = INFINITY;
            }
            if (place == 10) pavilion(o, d, color, tGround, envTexture, smp);
            if (place >= 5) color += liveTouches(place, o, d, u.params.z, fireflies);
        }
        else if (place == 3) color = focusScene(o, d, tGround);
        else if (place == 4) {
            // A 360° image around the user, turned by envParams.w; mip level from the pixel's angle.
            float lon = atan2(d.x, -d.z) + u.envParams.w;
            float lat = asin(clamp(d.y, -1.0, 1.0));
            float2 euv = float2(fract(0.5 + lon / (2.0 * M_PI_F)), 0.5 - lat / M_PI_F);
            float texelAngle = 2.0 * M_PI_F / float(envTexture.get_width());
            float elod = clamp(log2(max(((u.tanLRUD.y - u.tanLRUD.x) / u.params.y) / texelAngle, 1.0)), 0.0, 6.0);
            color = envTexture.sample(smp, euv, level(elod)).rgb;
        } else color = sky(d);
        if (place != 0) tHit = tGround;
        color *= u.saberParams.w; // the place dips to black while it changes
    }

    // Geometry (a 3D place): where its surface is nearer than the environment, it shows instead.
    if (u.projFlags.z > 0.5 && !surround) {
        uint2 pix = uint2(in.position.xy);
        float md = meshDistance.read(pix).r;
        if (md > 0.0 && md < tHit) {
            color = meshColor.read(pix).rgb * u.saberParams.w;
            tHit = md;
        }
    }

    // Floor at y = 0 (computed unconditionally so derivatives are valid).
    float tFloor = d.y < -1e-5 ? -o.y / d.y : 1e9;
    float2 fp = (o + tFloor * d).xz;
    float2 fw = fwidth(fp);
    if (!surround && place == 0 && d.y < -1e-5 && tFloor < tHit) {
        // Night floor: dark, with a faint blue grid that fades into the horizon.
        float fine = grid(fp, fw, 1.0, 0.008);
        float coarse = grid(fp, fw, 5.0, 0.016);
        float3 base = float3(0.035, 0.040, 0.058);
        float3 line = float3(0.45, 0.52, 0.72);
        float3 c = mix(base, line, fine * 0.10 + coarse * 0.16);
        float fog = 1.0 - exp(-tFloor * 0.06);
        color = mix(c, sky(d), fog);
        tHit = tFloor;
    }

    // Reference boxes: front (red), left (green), right (blue), behind (yellow).
    const float3 boxMin[4] = { float3(-0.25, 0.0, -3.25), float3(-3.25, 0.0, -0.25), float3(2.75, 0.0, -0.25), float3(-0.25, 0.0, 2.75) };
    const float3 boxColor[4] = { float3(0.85, 0.25, 0.2), float3(0.25, 0.75, 0.3), float3(0.25, 0.45, 0.9), float3(0.9, 0.8, 0.25) };
    for (int i = 0; i < (u.envParams.x > 0.5 && !surround ? 4 : 0); i++) {
        float t; float3 n;
        if (hitBox(o, d, boxMin[i], boxMin[i] + float3(0.5, 1.0, 0.5), t, n) && t < tHit) {
            float lit = 0.45 + 0.55 * max(dot(n, normalize(float3(0.4, 0.9, 0.3))), 0.0);
            color = boxColor[i] * lit;
            tHit = t;
        }
    }

    // Dim the surroundings (e.g. around a movie screen); params.w = 0 none .. 1 black.
    if (!surround) color *= 1.0 - u.params.w;
    // A game's fades: its frames, or the place shown instead; its overlays (drawn next) stay.
    float4 fade = immersive ? u.gameFade : u.gameBackgroundFade;
    color = color * (1.0 - fade.a) + fade.rgb;
    // Halliday up over a game that shows no frame (loading: its skybox or the place): dimmed too.
    if (!immersive && u.gameAway.x > 0.001) {
        float grey = dot(color, float3(0.2126, 0.7152, 0.0722));
        color = mix(color, mix(float3(grey), color, 0.75) * 0.42, u.gameAway.x);
    }

    // Passthrough: the room in place of whatever is behind the panels (the place, a video, a
    // game's picture).
    // A game that says its picture's alpha is meant (a Quest app with passthrough under its
    // scene) keeps its picture: the room shows where it left it clear (premultiplied).
    if (u.seeParams.x > 0.001) {
        float3 room = see_through(d, eye, u, cameraPicture, smp);
        if (immersive && u.gameAway.y > 0.5) color += room * (1.0 - clamp(pageAlpha, 0.0, 1.0)) * u.seeParams.x;
        else if (video && !immersive && u.videoKey.w > 0.5) color += room * (1.0 - videoKeep) * u.seeParams.x;
        else color = mix(color, room, u.seeParams.x);
    }

    // Quad layers: rectangles in their local xy plane, facing +z, centered on the origin. They come
    // sorted far to near and blend in that order (textures are premultiplied), so see-through
    // panels show what is behind them. tSurface: the nearest solid surface, for the saber.
    float pixelAngle = (u.tanLRUD.y - u.tanLRUD.x) / u.params.y;
    float tSurface = tHit;
    float covered = 0.0; // how much of this pixel the layers so far have covered
    // Over an immersive page nothing is drawn; over a game, its own overlays are, or Halliday's
    // panels while Halliday is up over it (projFlags.w).
    uint count = immersive && u.projFlags.w < 0.5 ? 0 : min(uint(u.params.x), MAX_LAYERS);
    for (uint i = 0; i < count; i++) {
        float3 lo = (layers[i].layerFromWorld * float4(o, 1.0)).xyz;
        float3 ld = (layers[i].layerFromWorld * float4(d, 0.0)).xyz;
        if (abs(ld.z) < 1e-6) continue;
        float t = -lo.z / ld.z;
        // Panels are never hidden by the environment: a large or low panel may reach below the
        // floor line, and the floor must not cut it.
        if (t <= 0.0) continue;
        float2 p = lo.xy + t * ld.xy;
        float2 half_size = layers[i].size.xy * 0.5;
        // Well away from the layer (beyond its shadow and glow, which reach about 0.05 × t): nothing
        // of it shows here. Most pixels leave most layers here.
        float reach = 0.07 * t + 0.015;
        if (abs(p.x) > half_size.x + reach || abs(p.y) > half_size.y + reach) continue;
        // Signed distance to the layer's rounded rectangle (negative inside), for clean edges.
        float radius = min(layers[i].shape.x, min(half_size.x, half_size.y));
        float2 q = abs(p) - (half_size - radius);
        float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float px = max(t * pixelAngle / max(abs(ld.z), 0.2), 1e-5); // meters covered by one pixel here
        float opacity = layers[i].stereo.y;
        float glow = layers[i].stereo.z;
        // The window under the pointer glows: a soft halo of the accent around it.
        if (glow > 0.003 && sd > 0.0) {
            float halo = exp(-sd / 0.012);
            color += ACCENT * 0.30 * halo * halo * glow * opacity;
        }
        // Night Glass: a soft shadow falls around a panel's glass, on whatever is behind it
        // (sizes follow the distance, like everything measured in dmm).
        float onGlass = 0.0;
        if (layers[i].shape.y > 0.5) {
            float gr = layers[i].shape.z;
            float gsd = glass_sd(p, layers[i].glass, layers[i].glass2, gr, 0.0);
            float ssd = glass_sd(p, layers[i].glass, layers[i].glass2, gr, 0.010 * t);
            float shadow = 1.0 - smoothstep(-0.006 * t, 0.034 * t, ssd);
            color *= 1.0 - shadow * shadow * smoothstep(-px, px, gsd) * 0.45 * opacity;
            // …and a close one under it (board 19: one far and soft, one close).
            float csd = glass_sd(p, layers[i].glass, layers[i].glass2, gr, 0.003 * t);
            float contact = 1.0 - smoothstep(-0.002 * t, 0.009 * t, csd);
            color *= 1.0 - contact * contact * smoothstep(-px, px, gsd) * 0.28 * opacity;
            onGlass = saturate(0.5 - gsd / px);
        } else if (layers[i].shape.w > 0.5) {
            // A window's shadow, around all of it.
            float wr = layers[i].shape.x;
            float2 wq = abs(p + float2(0.0, 0.012 * t)) - (half_size - wr);
            float wsd = length(max(wq, 0.0)) + min(max(wq.x, wq.y), 0.0) - wr;
            float shadow = 1.0 - smoothstep(-0.008 * t, 0.040 * t, wsd);
            color *= 1.0 - shadow * shadow * smoothstep(-px, px, sd) * 0.45 * opacity;
        }
        if (sd > px) continue;
        float coverage = saturate(0.5 - sd / px);
        // On the glass, the place behind shows blurred (only the place: a window behind a panel
        // stays as it is, under a denser tint).
        if (onGlass > 0.0 && !surround) {
            // The place, blurred: the coarse levels of its 360° picture, or its plain sky.
            float3 blurred;
            if (place == 1 || place == 2 || place == 4 || place >= 5) {
                float blon = atan2(d.x, -d.z) + (place == 4 ? u.envParams.w : 0.0), blat = asin(clamp(d.y, -1.0, 1.0));
                blurred = envTexture.sample(smp, float2(fract(0.5 + blon / (2.0 * M_PI_F)), 0.5 - blat / M_PI_F), level(5.2)).rgb;
            } else if (place == 3) {
                blurred = mix(float3(0.030, 0.032, 0.040), float3(0.012, 0.013, 0.018), smoothstep(-0.2, 0.9, d.y));
            } else {
                blurred = d.y < 0.0 ? mix(float3(0.045, 0.052, 0.075), sky(d), 1.0 - exp(-tFloor * 0.06)) : sky(d);
            }
            // The place's own colour comes through (board 19): the glass is tinted by where it is.
            blurred = mix(float3(dot(blurred, float3(0.3, 0.59, 0.11))), blurred, 1.6) * u.saberParams.w * (1.0 - u.params.w);
            color = mix(color, blurred, onGlass * (1.0 - covered) * opacity);
        }
        float2 local = float2(p.x / layers[i].size.x + 0.5, 0.5 - p.y / layers[i].size.y);
        int layerStereo = int(layers[i].stereo.x + 0.5);
        if (layerStereo == 1) local.x = (eye + local.x) * 0.5;
        else if (layerStereo == 2) local.y = (eye + local.y) * 0.5;
        // macOS's recording badge on a captured window: covered with the title bar beside it.
        float4 pr = layers[i].patch;
        if (pr.z > 0.0 && local.x >= pr.x && local.x <= pr.x + pr.z && local.y >= pr.y && local.y <= pr.y + pr.w) {
            local = float2(pr.x + pr.z * 1.04, pr.y + pr.w * 0.5);
        }
        float2 uv = layers[i].uvRect.xy + saturate(local) * layers[i].uvRect.zw;
        // Analytic mip level: texels covered by one pixel at this distance.
        float texelsPerMeter = layers[i].size.z / layers[i].size.x;
        float footprint = t * pixelAngle * texelsPerMeter / max(abs(ld.z), 0.2);
        // Four samples spread over the pixel's footprint (a rotated grid), each from a level twice
        // as fine: one sample per pixel left text and hairlines shimmering as the head moved, once
        // the lens pass resampled the eye picture.
        // Capped at 4: coarser mips of a shared texture would bleed in neighbouring windows.
        float lod = clamp(log2(max(footprint * 0.5, 1.0)), 0.0, min(layers[i].size.w - 1.0, 4.0));
        float2 texSize = float2(textures[i].get_width(), textures[i].get_height());
        float2 du = footprint / texSize;
        float2 o1 = float2(0.125, 0.375) * du, o2 = float2(0.375, -0.125) * du;
        float4 c = 0.25 * (textures[i].sample(smp, uv + o1, level(lod)) + textures[i].sample(smp, uv - o1, level(lod))
                         + textures[i].sample(smp, uv + o2, level(lod)) + textures[i].sample(smp, uv - o2, level(lod)));
        // A panel whose picture just changed fades from the old one.
        if (layers[i].stereo.w < 0.999) {
            float4 before = 0.25 * (previousTextures[i].sample(smp, uv + o1, level(lod)) + previousTextures[i].sample(smp, uv - o1, level(lod))
                                  + previousTextures[i].sample(smp, uv + o2, level(lod)) + previousTextures[i].sample(smp, uv - o2, level(lod)));
            c = mix(before, c, layers[i].stereo.w);
        }
        // Glass over a window (not over the place): denser, so what is behind doesn't fight the text.
        if (onGlass > 0.0 && covered > 0.0 && c.a > 0.01) {
            float dense = mix(c.a, 1.0 - (1.0 - c.a) * 0.25, covered * onGlass);
            c.rgb *= dense / c.a;
            c.a = dense;
        }
        c *= coverage * opacity;
        color = color * (1.0 - c.a) + c.rgb;
        covered = max(covered, c.a);
        if (c.a > 0.5) tSurface = min(tSurface, t);
        // …and a thin line of light along its edge, about two pixels, fading inward.
        if (glow > 0.003) {
            float rim = saturate(1.0 + sd / (2.5 * px));
            color = mix(color, mix(ACCENT, float3(1.0), 0.35), rim * rim * 0.7 * coverage * glow * opacity);
        }
    }

    // Hold-to-recenter: a ring in the middle of the view that fills clockwise from the top while
    // the button is held (drawn over everything, panels included).
    if (u.envParams.y > 0.001) {
        float3 fwd = normalize(rot * float3(0.0, 0.0, -1.0));
        float3 right = normalize(rot * float3(1.0, 0.0, 0.0));
        float3 up = normalize(rot * float3(0.0, 1.0, 0.0));
        float2 a = float2(dot(d, right), dot(d, up)) / max(dot(d, fwd), 1e-3); // tangent offsets from the center
        float ringR = 0.045, ringW = 0.006;
        float dist = abs(length(a) - ringR);
        float aa = pixelAngle * 1.5;
        float band = 1.0 - smoothstep(ringW - aa, ringW + aa, dist);
        float turn = fract(atan2(a.x, a.y) / (2.0 * M_PI_F) + 1.0); // 0 at the top, clockwise
        float filled = step(turn, u.envParams.y);
        float disc = 1.0 - smoothstep(ringR + ringW, ringR + ringW + 0.02, length(a));
        color = mix(color, color * 0.55, disc * 0.6);
        color = mix(color, float3(1.0), band * 0.22);
        color = mix(color, mix(ACCENT, float3(1.0), 0.25), band * filled);
    }

    // A hand's saber has a hilt: a short graphite handle behind the beam's start, along the beam,
    // with a ring of the accent where the beam leaves it. (It stands for the controller until
    // there is a model of it; a capsule, met by the ray exactly.)
    if (u.saberStart.w > 0.5 && u.saberParams.z < 0.5) {
        float3 tip = u.saberStart.xyz;
        float3 along = u.saberEnd.xyz - tip;
        float alongLen = length(along);
        if (alongLen > 1e-4) {
            const float radius = 0.017;
            float3 pa = tip - along / alongLen * 0.13, ba = tip - pa, oa = o - pa;
            float baba = dot(ba, ba), bard = dot(ba, d), baoa = dot(ba, oa), rdoa = dot(d, oa), oaoa = dot(oa, oa);
            float qa = baba - bard * bard, qb = baba * rdoa - baoa * bard, qc = baba * oaoa - baoa * baoa - radius * radius * baba;
            float h = qb * qb - qa * qc;
            float th = -1.0;
            if (h >= 0.0 && qa > 1e-9) {
                float t0 = (-qb - sqrt(h)) / qa;
                float y = baoa + t0 * bard;
                if (y > 0.0 && y < baba) {
                    th = t0;
                } else {
                    float3 oc = y <= 0.0 ? oa : o - tip;
                    float cb = dot(d, oc), cc = dot(oc, oc) - radius * radius, ch = cb * cb - cc;
                    if (ch > 0.0) th = -cb - sqrt(ch);
                }
            }
            if (th > 0.0 && th < tSurface) {
                float3 pos = o + th * d;
                float where = saturate(dot(pos - pa, ba) / baba);
                float3 n = normalize(pos - (pa + ba * where));
                float rim = pow(1.0 - saturate(abs(dot(n, d))), 3.0);
                float3 hilt = float3(0.035, 0.038, 0.046) * (0.6 + 0.7 * saturate(n.y * 0.5 + 0.5)) + float3(0.10, 0.11, 0.13) * rim;
                // The emitter's ring, and a thin band near the pommel.
                float ring = smoothstep(0.86, 0.90, where) * (1.0 - smoothstep(0.96, 0.99, where));
                float band = smoothstep(0.10, 0.12, where) * (1.0 - smoothstep(0.15, 0.17, where));
                hilt = mix(hilt, ACCENT * (0.7 + 0.3 * u.saberParams.x), ring);
                hilt = mix(hilt, ACCENT * 0.35, band * 0.6);
                color = hilt * u.saberParams.w;
                tSurface = min(tSurface, th);
            }
        }
    }

    // The saber: a beam from its start to where the pointer lands. Bright near-white core (2 mm,
    // at least ~1.5 px), accent glow (~7 mm radius) fading toward the end; hidden behind surfaces.
    if (u.saberStart.w > 0.5) {
        float3 A = u.saberStart.xyz;
        float3 seg = u.saberEnd.xyz - A;
        float len = length(seg);
        if (len > 1e-4) {
            float3 sd = seg / len;
            float3 w0 = o - A;
            float b = dot(d, sd), dw = dot(d, w0), e = dot(sd, w0);
            float denom = 1.0 - b * b;
            float ts = denom > 1e-6 ? clamp((e - b * dw) / denom, 0.0, len) : 0.0;
            float3 P = A + ts * sd;
            float tv = dot(P - o, d);
            float dist = length(o + tv * d - P);
            if (tv > 0.0 && tv < tSurface + 0.002) {
                float px = tv * pixelAngle;
                float along = ts / len;
                float energy = u.saberParams.x;
                float fade = u.saberEnd.w > 0.5 ? mix(1.0, 0.45, along) : (1.0 - along) * (1.0 - along);
                // A hand's beam that lands nowhere stays lit along its length: it is how the user
                // sees where the controller points.
                if (u.saberParams.z < 0.5 && u.saberEnd.w < 0.5) fade = mix(1.0, 0.12, along);
                // No hand to start from (mouse pointer): the beam appears gradually, so it doesn't
                // cut across what is being looked at.
                if (u.saberParams.z > 0.5) fade *= u.saberEnd.w > 0.5 ? smoothstep(0.35, 0.95, along) : smoothstep(0.1, 0.5, along) * 2.0;
                float coreR = max(0.001, 0.75 * px);
                float core = 1.0 - smoothstep(coreR, coreR + px, dist);
                float glow = exp(-(dist * dist) / (0.007 * 0.007));
                float3 coreColor = mix(float3(1.0), ACCENT, along * 0.7);
                color += ACCENT * glow * 0.30 * fade * energy;
                color = mix(color, coreColor, saturate(core * fade * (0.55 + 0.45 * energy)));
            }
        }
        // Cursor ring where it lands: constant angular size; closes to a dot while pressed.
        // (saberStart.w = 2: no ring; the app's own cursor is shown there instead.)
        if (u.saberEnd.w > 0.5 && u.saberStart.w < 1.5) {
            float3 toEnd = u.saberEnd.xyz - o;
            float a = acos(clamp(dot(d, normalize(toEnd)), -1.0, 1.0)) / pixelAngle;
            color += ACCENT * exp(-(a * a) / 160.0) * 0.18;
            // Pressed: the ring closes to a dot. Otherwise a thin ring with a small center dot.
            // The ring closes smoothly into a dot as the button goes down (saberParams.y: 0 → 1).
            float press = u.saberParams.y;
            float ringR = mix(7.0, 2.2, press);
            float ring = 1.0 - smoothstep(0.7, 1.5, abs(a - ringR));
            float dot_ = 1.0 - smoothstep(mix(1.0, 3.4, press), mix(1.9, 4.4, press), a);
            float shade = 1.0 - smoothstep(1.5, 3.5, abs(a - ringR));
            color *= 1.0 - 0.30 * shade;
            color = mix(color, float3(1.0), saturate(max(ring, dot_)));
        }
        return finish_view(color, u);
    }

    // Cursor: a ring around the pointer direction, constant angular size.
    if (u.cursor.w > 0.5) {
        float a = acos(clamp(dot(d, normalize(u.cursor.xyz)), -1.0, 1.0)) / pixelAngle;
        if (a < 9.0) color = a < 5.5 ? float3(1.0) : float3(0.05);
    }

    // highlight.y: the whole view fading up after a change of scene (into or out of a video, a
    // picture around the viewer or a VR page).
    return finish_view(color, u);
}

// --- Environment bake ---
// Paints Dusk or Terrace as a 360° picture (equirectangular), seen from standing height. The
// renderer draws it a strip per frame and starts over every few seconds, so slow motion (clouds,
// the aurora) keeps going while each frame pays almost nothing.

struct BakeUniforms {
    float4 params; // x: place (1 dusk, 2 terrace), y: time (s), z: eye height (m)
};

fragment float4 env_bake_fs(FullscreenOut in [[stage_in]], constant BakeUniforms &b [[buffer(0)]]) {
    float lon = (in.uv.x - 0.5) * 2.0 * M_PI_F, lat = (0.5 - in.uv.y) * M_PI_F;
    float3 d = float3(sin(lon) * cos(lat), sin(lat), -cos(lon) * cos(lat));
    float3 o = float3(0.0, b.params.z, 0.0);
    float tGround = INFINITY;
    int place = int(b.params.x + 0.5);
    float3 c;
    switch (place) {
    case 1: c = duskScene(o, d, b.params.y, tGround); break;
    case 2: c = terraceFar(o, d, b.params.y); break;
    case 5: c = seaScene(o, d, b.params.y); break;
    case 6: c = duneScene(o, d, b.params.y); break;
    case 7: c = forestScene(o, d, b.params.y); break;
    case 8: c = snowScene(o, d, b.params.y); break;
    case 10: c = pavilionFar(d, b.params.y); break;
    default: c = spaceScene(d, b.params.y); break;
    }
    return float4(c, 1.0);
}

// --- Distortion pass ---

struct MeshVertex {
    float2 position;
    float2 uvR;
    float2 uvG;
    float2 uvB;
};

struct DistortOut {
    float4 position [[position]];
    float2 uvR;
    float2 uvG;
    float2 uvB;
    // The mesh's own coordinates: where the lens's picture ends (outside 0..1: black).
    float2 lensR;
    float2 lensG;
    float2 lensB;
    float eye [[flat]];
};

// Late latching (LateLatch.swift): the turn from the view shown to the view the eye texture was
// drawn from, and each eye's tangents (left, right, up, down). Must match `LensWarp`.
struct LensWarp {
    float3x3 rotation;
    float4 tanLeft;
    float4 tanRight;
    float4 scan; // xyz: how the head turns (rad/s, its own axes); w: how long the panel takes from its top row to its bottom one (s)
};

// A point of the eye texture (0..1, top left) seen from the late orientation: its direction in
// the eye's frame, turned into the rendered view's, and back to the texture.
// `turn`: how far the head has turned on (rad, its own axes) when this row of the panel lights:
// the panel lights its rows from top to bottom over most of a refresh, and the pose is for the
// middle one, so with the head turning the top showed where the head had been and the bottom
// where it would be (the picture stretched and squeezed with every nod).
static float2 warped(float2 uv, float3x3 r, float4 t, float3 turn) {
    float3 seen = float3(mix(t.x, t.y, uv.x), mix(t.z, t.w, uv.y), -1.0);
    float3 d = r * (seen + cross(turn, seen));
    float2 p = d.xy / max(-d.z, 1e-4);
    return float2((p.x - t.x) / (t.y - t.x), (p.y - t.z) / (t.w - t.z));
}

vertex DistortOut distort_vs(uint vid [[vertex_id]],
                             const device MeshVertex *verts [[buffer(0)]],
                             constant float &eye [[buffer(1)]],
                             constant LensWarp &warp [[buffer(2)]]) {
    MeshVertex v = verts[vid];
    DistortOut o;
    float x = (eye + v.position.x) * 0.5;      // panel u across both eyes
    o.position = float4(x * 2.0 - 1.0, 1.0 - v.position.y * 2.0, 0.0, 1.0);
    float4 t = eye < 0.5 ? warp.tanLeft : warp.tanRight;
    float3 turn = warp.scan.xyz * ((v.position.y - 0.5) * warp.scan.w);
    o.uvR = warped(v.uvR, warp.rotation, t, turn);
    o.uvG = warped(v.uvG, warp.rotation, t, turn);
    o.uvB = warped(v.uvB, warp.rotation, t, turn);
    o.lensR = v.uvR; o.lensG = v.uvG; o.lensB = v.uvB;
    o.eye = eye;
    return o;
}

static float channel(texture2d<float> tex, sampler s, float2 uv, float2 lens, float eye, int c) {
    if (any(lens < 0.0) || any(lens > 1.0)) return 0.0;
    // A turned point just past the eye texture's edge takes the edge (a late turn is a fraction
    // of a degree); the lens's own edge stays where it was.
    uv = clamp(uv, 0.0, 1.0);
    float2 sbs = float2((eye + uv.x) * 0.5, uv.y);
    return tex.sample(s, sbs)[c];
}

fragment float4 distort_fs(DistortOut in [[stage_in]],
                           texture2d<float> eyes [[texture(0)]],
                           sampler smp [[sampler(0)]]) {
    return float4(channel(eyes, smp, in.uvR, in.lensR, in.eye, 0),
                  channel(eyes, smp, in.uvG, in.lensG, in.eye, 1),
                  channel(eyes, smp, in.uvB, in.lensB, in.eye, 2), 1.0);
}

// --- Video: YUV (biplanar 4:2:0) to RGB, into a texture the scene samples ---

struct YUVParams {
    float4 rCoeffs;  // R = y + rCoeffs.z * cr (x, y unused)
    float4 gCoeffs;  // G = y + gCoeffs.y * cb + gCoeffs.z * cr
    float4 bCoeffs;  // B = y + bCoeffs.y * cb
    float4 range;    // x: luma offset, y: luma scale, z: chroma scale, w: transfer (0 SDR, 1 PQ, 2 HLG)
};

fragment float4 yuv_fs(FullscreenOut in [[stage_in]],
                       texture2d<float> lumaTex [[texture(0)]],
                       texture2d<float> chromaTex [[texture(1)]],
                       constant YUVParams &p [[buffer(0)]],
                       sampler smp [[sampler(0)]]) {
    float y = (lumaTex.sample(smp, in.uv).r - p.range.x) * p.range.y;
    float2 c = (chromaTex.sample(smp, in.uv).rg - 0.5) * p.range.z;
    float3 rgb = float3(y + p.rCoeffs.z * c.y,
                        y + p.gCoeffs.y * c.x + p.gCoeffs.z * c.y,
                        y + p.bCoeffs.y * c.x);
    if (p.range.w > 0.5) {
        // HDR (BT.2020 with a PQ or HLG curve) shown on an SDR pipeline: to linear light with
        // reference white at 1, tone-mapped so highlights roll off up to 1000 nits, then to BT.709
        // primaries and back to a display curve.
        float3 e = saturate(rgb), lin;
        if (p.range.w < 1.5) {
            const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
            float3 ep = pow(e, float3(1.0 / m2));
            lin = pow(max(ep - c1, 0.0) / (c2 - c3 * ep), float3(1.0 / m1)) * (10000.0 / 203.0);
        } else {
            const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
            float3 scene = mix(e * e / 3.0, (exp((e - c) / a) + b) / 12.0, step(0.5, e));
            lin = pow(scene, float3(1.2)) * (1000.0 / 203.0);
        }
        const float white = 1000.0 / 203.0;
        lin = lin * (1.0 + lin / (white * white)) / (1.0 + lin);
        float3 r709 = float3(dot(lin, float3(1.6605, -0.5876, -0.0728)),
                             dot(lin, float3(-0.1246, 1.1329, -0.0083)),
                             dot(lin, float3(-0.0182, -0.1006, 1.1187)));
        rgb = pow(saturate(r709), float3(1.0 / 2.2));
    }
    return float4(saturate(rgb), 1.0);
}

// Undistorted view (distortion off): the side-by-side eye texture stretched over the output.
fragment float4 passthrough_fs(FullscreenOut in [[stage_in]],
                               texture2d<float> eyes [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    return eyes.sample(smp, in.uv);
}
"""
