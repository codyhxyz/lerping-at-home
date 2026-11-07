// Mandelbox — original shader written for Lerping@Home (AGPL-3.0, like the
// rest of this project). Slow flights through and around Tom Lowe's Mandelbox.
//
// Written from the published mathematics; no code is copied from anywhere:
//   - the Mandelbox iteration (box fold, sphere fold, scale and translate),
//     Tom Lowe, fractalforums.com, 2010
//   - the scalar running-derivative distance estimate, as explained in Mikael
//     Hvidtfeldt Christensen's "Distance Estimated 3D Fractals (VI): The
//     Mandelbox" (http://blog.hvidtfeldts.net/), in the offset form
//     (|z| - (|s| - 1)) / |dr| - |s|^(1 - n) discussed on fractalforums, which
//     goes negative inside the set and so converges in far fewer steps
//   - over-relaxed sphere tracing with fallback, Keinert et al., "Enhanced
//     Sphere Tracing" (STAG 2014)
//
// Three forms, picked by `form`:
//   0 Halls — the interior of the scale-3 box, whose central halls are wide and
//     open. (The classic scale -1.5 box is almost solid inside: its largest
//     free pockets have a distance estimate of ~0.05 in a box 4 units across,
//     so it is shown from outside, as the "Minus One and a Half" preset.)
//   1 Box   — a glide around the outside of the box at any `scale`.
//   2 Slab  — low flight over an endless horizontal cut through tiled boxes.
// `breathe` swings the scale slowly: ±0.1 in the halls (the verified range),
// ±6% for box and slab, whose cameras follow the cube as it changes size.
// The two Box presets instead let `scale` itself drift (`animate(…)` in
// their presets), slowly and within a range that keeps each look's character.
// Halls ignores `scale` (its breathing is `breathe`, held to the verified
// 3 ± 0.1), and Slab's flight distance is proportional to the cube's size, so
// a drifting scale would make that camera lurch; Endless Slab holds still.
// `breathe` stays 0 wherever `scale` drifts: one clock per parameter.
//
// Camera safety. Box and Slab are safe by construction: the camera stays
// outside the bounding cube (half-width 2(s+1)/(s-1) for s > 1, 2 for s < -1),
// or above the cut. Halls follows routes baked offline: a probe flew through
// the interior steering by ray-cast feelers and a DE margin, and the uniform
// Catmull-Rom spline through its thinned path was verified densely to keep a
// DE of at least 0.021 at every scale in 2.9…3.1 (the breathing range). Each
// route plays under one of the cube's 48 symmetries, forwards or backwards,
// chosen from (seed, segment), and re-rolls behind a few seconds of fog.
//
// Cost control, because this runs full-screen for hours (numbers per look in
// the commit message):
//   - the SIMD group crosses empty space together: one centre ray, a cone
//     wide enough to cover every lane's ray, and each lane testing a
//     different one of the next 32 strides (cf. dusk-terrain's 2x2 version)
//   - iteration count falls with distance, blended between whole counts so
//     detail fades instead of popping; the fold being blended carves
//     features at most ~2 px across (~1 px in the halls), so what fades is
//     detail too small to read and distant structure keeps its shape as the
//     camera nears
//   - hit tolerance is a fixed angle (not per drawable pixel) and widens by
//     at most half inside the fog: it used to keep growing with fog depth,
//     to 8x by the fog cutoff, which sealed holes ~30 px across far
//     away that opened as the camera approached
//   - the march ends where fog is ~97%; Box skips rays that miss the cube
//   - forward-difference normals reuse the hit sample; occlusion is one probe
//     along the normal times the orbit trap; no shadow rays (a lantern at the
//     eye in the halls casts none that can be seen)
//
// lerp-category: Fractals
// lerp-param: form    int 0 2        = 0    "Form: halls, box, slab"
// lerp-param: scale   float -2.5 3.5 = 2.0  "Box scale (box, slab)"
// lerp-param: breathe float 0 1      = 0.0  "Breathing"
// lerp-param: speed   float 0 3      = 1.0  "Camera speed"
// lerp-param: fog     float 0 1      = 0.5  "Fog"
// lerp-param: metal   float 0 1      = 0.15 "Metal"
// lerp-param: stone   color          = (0.55, 0.50, 0.44) "Stone"
// lerp-param: lamp    color          = (1.00, 0.80, 0.58) "Light"
// lerp-param: haze    color          = (0.020, 0.026, 0.036) "Fog colour"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-param: magnify  float -1 0.6 = 0 "Zoom"
//
// lerp-preset: "Outer Box"            form=1, scale=animate(1.75, 2.0, period=240)
// lerp-preset: "Minus One and a Half" form=1, scale=animate(-1.62, -1.42, period=260), metal=0.65
// lerp-preset: "Minus One and a Half" stone=(0.62, 0.50, 0.38)
// lerp-preset: "Breathing Halls"      breathe=1.0, fog=0.65, lamp=(0.78, 0.86, 1.00)
// lerp-preset: "Breathing Halls"      stone=(0.50, 0.50, 0.52)
// lerp-preset: "Endless Slab"         form=2, scale=3.0, fog=0.55

constant float MB_MINR2 = 0.25;           // sphere-fold inner radius²
constant float MB_FIXR2 = 1.0;            // sphere-fold outer radius²
constant int   MB_ITERS = 15;             // loop bound; each form sets its own cap
constant int   MB_LOD_MIN = 6;
constant int   MB_STEPS = 110;
constant int   MB_SHARED_ITERS = 24;
constant float MB_SHARED_FRAC = 0.3;      // shared stride as a fraction of the clearance
constant float MB_OMEGA = 1.3;            // over-relaxation of the per-lane march
constant float MB_FOCAL = 1.5;
constant float MB_HALLS_SCALE = 3.0;
constant float MB_HALLS_BREATHE = 0.1;    // the routes are verified for 3 ± 0.1
constant float MB_FOG_EPS = 1.5;          // most the fog may widen the hit tolerance

// Halls routes: control points every ~0.2 units, uniform Catmull-Rom.
constant int MB_ROUTE_N = 67;
constant float3 MB_ROUTE[134] = {
    float3(0.650, 0.280, 0.200), float3(0.768, 0.444, 0.182), float3(0.918, 0.498, 0.067), float3(1.028, 0.612, -0.053),
    float3(1.118, 0.706, -0.204), float3(1.139, 0.752, -0.394), float3(1.120, 0.749, -0.594), float3(1.102, 0.747, -0.793),
    float3(1.084, 0.745, -0.992), float3(1.066, 0.743, -1.191), float3(1.049, 0.741, -1.390), float3(1.066, 0.748, -1.592),
    float3(1.119, 0.764, -1.785), float3(1.171, 0.783, -1.977), float3(1.198, 0.840, -2.163), float3(1.301, 0.900, -2.323),
    float3(1.448, 0.927, -2.457), float3(1.607, 0.935, -2.576), float3(1.773, 0.935, -2.688), float3(1.950, 0.953, -2.777),
    float3(2.124, 0.993, -2.863), float3(2.264, 1.104, -2.953), float3(2.381, 1.241, -3.035), float3(2.465, 1.408, -3.107),
    float3(2.500, 1.595, -3.168), float3(2.523, 1.784, -3.227), float3(2.486, 1.974, -3.274), float3(2.382, 2.137, -3.308),
    float3(2.205, 2.234, -3.332), float3(2.013, 2.259, -3.361), float3(1.815, 2.288, -3.385), float3(1.625, 2.342, -3.367),
    float3(1.434, 2.375, -3.398), float3(1.259, 2.474, -3.418), float3(1.111, 2.601, -3.439), float3(0.938, 2.697, -3.452),
    float3(0.736, 2.699, -3.449), float3(0.537, 2.704, -3.452), float3(0.337, 2.705, -3.450), float3(0.137, 2.705, -3.443),
    float3(-0.060, 2.726, -3.445), float3(-0.249, 2.784, -3.465), float3(-0.448, 2.802, -3.472), float3(-0.645, 2.804, -3.470),
    float3(-0.836, 2.861, -3.473), float3(-1.026, 2.928, -3.475), float3(-1.215, 3.000, -3.476), float3(-1.403, 3.055, -3.471),
    float3(-1.600, 3.078, -3.475), float3(-1.785, 3.142, -3.483), float3(-1.960, 3.234, -3.507), float3(-2.145, 3.297, -3.475),
    float3(-2.275, 3.324, -3.334), float3(-2.328, 3.332, -3.140), float3(-2.297, 3.347, -2.949), float3(-2.171, 3.363, -2.795),
    float3(-1.985, 3.372, -2.732), float3(-1.789, 3.375, -2.762), float3(-1.590, 3.370, -2.787), float3(-1.393, 3.378, -2.789),
    float3(-1.200, 3.407, -2.837), float3(-1.023, 3.433, -2.920), float3(-0.829, 3.463, -2.929), float3(-0.638, 3.463, -2.884),
    float3(-0.475, 3.451, -2.770), float3(-0.278, 3.450, -2.758), float3(-0.078, 3.461, -2.771),
    float3(1.300, 0.000, 0.000), float3(1.359, 0.017, 0.192), float3(1.488, -0.007, 0.343), float3(1.649, -0.054, 0.448),
    float3(1.813, -0.136, 0.526), float3(1.983, -0.210, 0.602), float3(2.156, -0.257, 0.687), float3(2.311, -0.359, 0.771),
    float3(2.445, -0.469, 0.870), float3(2.565, -0.572, 0.990), float3(2.633, -0.654, 1.159), float3(2.722, -0.741, 1.315),
    float3(2.775, -0.831, 1.483), float3(2.828, -0.877, 1.674), float3(2.908, -0.889, 1.856), float3(2.990, -0.894, 2.038),
    float3(3.070, -0.895, 2.221), float3(3.106, -0.837, 2.404), float3(3.048, -0.706, 2.541), float3(2.970, -0.560, 2.654),
    float3(2.898, -0.400, 2.751), float3(2.787, -0.290, 2.872), float3(2.720, -0.137, 2.968), float3(2.726, 0.054, 3.030),
    float3(2.722, 0.243, 3.096), float3(2.732, 0.434, 3.158), float3(2.793, 0.601, 3.238), float3(2.780, 0.757, 3.330),
    float3(2.734, 0.946, 3.379), float3(2.783, 1.134, 3.402), float3(2.877, 1.303, 3.451), float3(2.976, 1.474, 3.471),
    float3(3.007, 1.669, 3.469), float3(2.901, 1.825, 3.464), float3(2.764, 1.976, 3.474), float3(2.688, 2.157, 3.494),
    float3(2.620, 2.344, 3.511), float3(2.475, 2.474, 3.526), float3(2.308, 2.585, 3.540), float3(2.112, 2.633, 3.550),
    float3(1.913, 2.635, 3.556), float3(1.713, 2.633, 3.562), float3(1.513, 2.632, 3.568), float3(1.313, 2.631, 3.574),
    float3(1.113, 2.630, 3.580), float3(0.913, 2.629, 3.585), float3(0.713, 2.628, 3.591), float3(0.517, 2.629, 3.598),
    float3(0.325, 2.569, 3.584), float3(0.178, 2.438, 3.559), float3(0.050, 2.285, 3.551), float3(-0.101, 2.161, 3.572),
    float3(-0.213, 1.997, 3.566), float3(-0.371, 1.877, 3.560), float3(-0.473, 1.703, 3.544), float3(-0.532, 1.513, 3.538),
    float3(-0.550, 1.314, 3.540), float3(-0.565, 1.115, 3.543), float3(-0.620, 0.924, 3.560), float3(-0.702, 0.741, 3.550),
    float3(-0.839, 0.600, 3.543), float3(-1.022, 0.524, 3.556), float3(-1.209, 0.455, 3.576), float3(-1.394, 0.382, 3.560),
    float3(-1.592, 0.343, 3.556), float3(-1.792, 0.340, 3.561), float3(-1.990, 0.345, 3.566),
};

struct MbScene {
    float s;       // fractal scale
    float E;       // half-width of the fractal's bounding cube
    int   form;
    float cut;     // slab: everything above this height is removed
    float lodBias; // extra iterations over the footprint estimate
    float nMax;    // iteration cap for this form
};

static inline float mbExtent(float s) { return s > 1.0 ? 2.0 * (s + 1.0) / (s - 1.0) : 2.0; }

// One Mandelbox step on (z, dr): box fold, sphere fold, scale and translate.
static inline void mbStep(thread float3& z, thread float& dr, thread float& trap, float3 p, float s, float as) {
    z = clamp(z, -1.0, 1.0) * 2.0 - z;
    float r2 = dot(z, z);
    trap = min(trap, r2);
    float k = clamp(MB_FIXR2 / r2, 1.0, MB_FIXR2 / MB_MINR2);
    z = z * (k * s) + p;
    dr = dr * k * as + 1.0;
}

// Distance estimate after `lod` iterations, blended between floor(lod) and
// floor(lod) + 1 so that detail fades in with distance instead of popping.
// The orbit trap is the smallest |z|² seen after a box fold.
static inline float mbFractal(float3 p, float s, float lod, thread float& trap) {
    float3 z = p;
    float dr = 1.0;
    float as = abs(s);
    float tail = as;                 // |s|^(1 - i) after i iterations
    float inv = 1.0 / as;
    int nLo = int(lod);
    trap = 1e9;
    for (int i = 0; i < MB_ITERS; i++) {
        if (i >= nLo) break;
        mbStep(z, dr, trap, p, s, as);
        tail *= inv;
    }
    float deLo = (length(z) - (as - 1.0)) / abs(dr) - tail;
    float w = lod - float(nLo);
    if (w <= 0.0) return deLo;
    mbStep(z, dr, trap, p, s, as);
    float deHi = (length(z) - (as - 1.0)) / abs(dr) - tail * inv;
    return mix(deLo, deHi, w);
}

static inline float mbScene(float3 p, MbScene S, float lod, thread float& trap) {
    if (S.form == 2) {
        // Tiles of period 2E in x and z. A step may not run more than a hair
        // past the tile edge, where the neighbour's geometry begins.
        float P = 2.0 * S.E;
        float2 c = p.xz - P * floor(p.xz / P + 0.5);
        float d = mbFractal(float3(c.x, p.y, c.y), S.s, lod, trap);
        float edge = S.E - max(abs(c.x), abs(c.y));
        d = min(d, edge + 0.01 * S.E);
        return max(d, p.y - S.cut);
    }
    float d = mbFractal(p, S.s, lod, trap);
    float3 b = abs(p) - S.E;
    float box = length(max(b, 0.0)) + min(max(b.x, max(b.y, b.z)), 0.0);
    return max(d, box);
}

static inline float mbD(float3 p, MbScene S, float lod) { float tr; return mbScene(p, S, lod, tr); }

// Iterations worth evaluating at distance t: a feature after n folds is about
// 2E/|s|^n across, so at bias b the fold being blended in (the only part of
// the shape that changes as the camera approaches) carves features 2|s|^(-1-b)
// to 2|s|^(-b) pixel footprints of a 1500-px-tall view across. Each form sets
// b so that stays about a pixel: at s = 3, bias 0 gives 0.7-2 px and 0.5 gives
// 0.4-1.2 px. (Slab used to run at -1.2, blending 2.5-7.5 px features in and out,
// and Halls at -0.5: holes grew and closed with distance.)
static inline float mbLod(float t, MbScene S, float px) {
    float n = log(S.E / max(px * t, 1e-7)) / log(abs(S.s)) + S.lodBias;
    return clamp(n, float(MB_LOD_MIN), S.nMax);
}

static inline float3 mbPerm(float3 p, int k) {
    switch (k) {
        case 0: return p.xyz;
        case 1: return p.xzy;
        case 2: return p.yxz;
        case 3: return p.yzx;
        case 4: return p.zxy;
        default: return p.zyx;
    }
}

// Uniform Catmull-Rom through route r's control points, at a in [1, N-2].
static float3 mbRoute(int r, float a) {
    a = clamp(a, 1.0, float(MB_ROUTE_N) - 2.001);
    int i = int(a);
    float f = a - float(i);
    int o = r * MB_ROUTE_N + i;
    float3 p0 = MB_ROUTE[o - 1], p1 = MB_ROUTE[o], p2 = MB_ROUTE[o + 1], p3 = MB_ROUTE[o + 2];
    return 0.5 * ((2.0 * p1) + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
                  + (3.0 * (p1 - p2) + p3 - p0) * f * f * f);
}

static inline float mbHash(float a, float b) { return hash21(float2(a * 17.31 + 3.7, b * 9.13 + 1.3)); }

// --- lerpMain's stages. Each takes what it reads and returns what it makes;
// the expressions are the ones lerpMain always ran, in the same order.

// Where a form puts the camera: position, heading, world up, how far the fog
// has closed over a re-roll, and the scene's length unit for fog and occlusion.
struct MbCamera {
    float3 ro, fwd, upv;
    float  mist;
    float  sceneUnit;
};

// --- Halls: a baked route through the scale-3 interior.
static inline MbCamera mbHallsCamera(constant LerpUniforms& u, float T, float breath,
                                     thread MbScene& S) {
    MbCamera c;
    S.s = MB_HALLS_SCALE + MB_HALLS_BREATHE * u.breathe * breath;
    S.E = mbExtent(S.s);
    const float LA = 4.0;                        // look-ahead, control points
    float span = float(MB_ROUTE_N) - 3.0 - LA;   // usable control-point span
    float v = 0.035 / 0.2 * u.speed;             // control points per second
    float g = T * v + (0.1 + 0.6 * u.seed) * span;
    float seg = floor(g / span);
    float a = g - seg * span;
    c.mist = 1.0 - smoothstep(0.0, 1.0, min(a, span - a));
    float h1 = mbHash(seg, u.seed), h2 = mbHash(seg + 0.5, u.seed + 0.25);
    int sym = int(h1 * 47.999);
    int r = int(h2 * 1.999);
    bool rev = fract(h2 * 7.0) > 0.5;
    float3 sg = float3((sym / 6) & 1 ? -1.0 : 1.0, (sym / 12) & 1 ? -1.0 : 1.0, (sym / 24) & 1 ? -1.0 : 1.0);
    int pm = sym % 6;
    float a0 = rev ? float(MB_ROUTE_N) - 2.0 - a : 1.0 + a;
    float dir = rev ? -1.0 : 1.0;
    c.ro = sg * mbPerm(mbRoute(r, a0), pm);
    float3 ah = sg * mbPerm(0.5 * (mbRoute(r, a0 + dir * 1.5) + mbRoute(r, a0 + dir * 3.5)), pm);
    c.fwd = normalize(ah - c.ro);
    c.upv = sg * mbPerm(float3(0.0, 1.0, 0.0), pm);  // the routes were flown level in y
    c.sceneUnit = 1.0;
    S.lodBias = 0.5;                             // the fading fold is 0.4-1.2 px
    S.nMax = 12.0;                               // the iteration count the routes were verified at
    return c;
}

// --- Box: glide around the outside of the bounding cube, 1.65–2.45
// half-widths out (cube norm), looking a little ahead of the centre.
static inline MbCamera mbBoxCamera(constant LerpUniforms& u, float T, float breath,
                                   thread MbScene& S) {
    MbCamera c;
    c.mist = 0.0;
    float s = u.scale;
    s = s < 0.0 ? min(s, -1.25) : max(s, 1.25);
    S.s = s * (1.0 + 0.06 * u.breathe * breath);
    S.E = mbExtent(S.s);
    float w = 0.010 * u.speed;
    float ph = u.seed * 6.2831;
    float phi = ph + w * T;
    float th = 0.38 * sin(0.63 * w * T + 2.0 * ph) + 0.12;
    float3 dv = float3(cos(phi) * cos(th), sin(th), sin(phi) * cos(th));
    float k = 2.05 + 0.4 * sin(1.37 * w * T + 3.0 * ph);
    c.ro = dv / max(abs(dv.x), max(abs(dv.y), abs(dv.z))) * S.E * k;
    float phi2 = phi + 0.45 + 0.25 * sin(0.9 * w * T + ph);
    float3 tgt = float3(cos(phi2), 0.3 * sin(th), sin(phi2)) * S.E * 0.45;
    c.fwd = normalize(tgt - c.ro);
    c.upv = float3(0.0, 1.0, 0.0);
    c.sceneUnit = S.E / 4.0;
    S.lodBias = 2.5;                             // faces need their fine folds even far away
    S.nMax = 15.0;
    return c;
}

// --- Slab: low flight over an endless cut through tiled boxes; a new
// heading every 300 s, behind fog.
static inline MbCamera mbSlabCamera(constant LerpUniforms& u, float T, float breath,
                                    thread MbScene& S) {
    MbCamera c;
    float s = u.scale;
    s = s < 0.0 ? min(s, -1.25) : max(s, 1.25);
    S.s = s * (1.0 + 0.06 * u.breathe * breath);
    S.E = mbExtent(S.s);
    S.cut = 0.35 * S.E;
    const float SEG = 300.0;
    float seg = floor(T / SEG);
    float lt = T - seg * SEG;
    float m0 = 1.0 - smoothstep(0.0, 5.0, SEG - lt);
    float m1 = seg >= 1.0 ? 1.0 - smoothstep(0.0, 5.0, lt) : 0.0;
    c.mist = max(m0, m1);
    float h1 = mbHash(seg, u.seed);
    float psi = h1 * 6.2831;
    float x = 0.012 * S.E * u.speed * lt;
    float2 hd = float2(cos(psi), sin(psi));
    float2 sd = float2(-hd.y, hd.x);
    float wph = x / S.E * 1.3 + h1 * 20.0;
    float2 xz = hd * x + sd * (0.18 * S.E * sin(wph)) + float2(h1, fract(h1 * 13.0)) * 2.0 * S.E;
    float hgt = S.cut + S.E * (0.14 + 0.05 * sin(0.02 * lt + h1 * 9.0));
    c.ro = float3(xz.x, hgt, xz.y);
    float2 fd = normalize(hd + sd * (0.18 * 1.3 * cos(wph)));
    c.fwd = normalize(float3(fd.x, -0.5, fd.y));
    c.upv = float3(0.0, 1.0, 0.0);
    c.sceneUnit = S.E / 4.0;
    S.lodBias = 0.0;                             // 0.7-2 px; most of the frame is far
    S.nMax = 11.0;
    return c;
}

// Outside the box, fog starts where the ray enters the bounding cube; a ray
// that misses it is never marched.
static inline float mbBoxEntry(float3 ro, float3 rd, float E, thread bool& boxMiss) {
    // Fast-math has no infinities: keep the direction off zero.
    float3 rs = select(rd, float3(1e-6), abs(rd) < 1e-6);
    float3 inv = 1.0 / rs;
    float3 t0 = (-E - ro) * inv, t1 = (E - ro) * inv;
    float tn = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    float tf = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    boxMiss = tn > tf || tf < 0.0;
    return boxMiss ? 0.0 : max(tn, 0.0);
}

// --- Shared phase. The lanes of a SIMD group look along nearly the
// same ray, so they cross empty space together: each lane tests a
// different one of the next strides along the group's centre ray,
// and the group advances past every sample whose own clearance (less
// the cone that covers all lanes) vouches for the gap after it.
// Control flow depends only on SIMD-reduced values, so the group
// stays in lockstep. Returns where the group got to; `i` counts its steps.
static inline float mbSharedMarch(float3 ro, float3 rd, MbScene S, float px, float tmax,
                                  thread int& i) {
    float3 rc = normalize(simd_sum(rd));
    float cmin = simd_min(dot(rd, rc));
    float cone = sqrt(max(1.0 - cmin * cmin, 0.0)) / max(cmin, 0.5) + px;
    uint rank = simd_prefix_exclusive_sum(1u);
    uint cnt = simd_sum(1u);
    float tq = 0.0;
    float stride = max(mbD(ro, S, S.nMax), 1e-4) * MB_SHARED_FRAC;
    for (int q = 0; q < MB_SHARED_ITERS; q++) {
        float ti = tq + stride * float(rank + 1);
        float dc = mbD(ro + rc * ti, S, mbLod(ti, S, px)) - cone * ti;
        bool tight = dc < 3.0 * px * ti;
        bool gapOK = !tight && dc >= stride;
        uint firstTight = simd_min(tight ? rank : cnt);
        uint firstGap = simd_min(gapOK ? cnt : rank);
        if (firstTight == 0) break;
        uint m = min(firstTight - 1, firstGap);
        float dM = simd_max(rank == m ? dc : -1e9);
        tq += stride * float(m + 1);
        i++;
        if (firstTight < cnt || tq > tmax) break;
        stride = dM * MB_SHARED_FRAC;
    }
    return tq;
}

// --- Each lane on its own ray, over-relaxed with fallback, from `t` on and
// continuing `i`'s step count. Returns whether it hit.
static inline bool mbLaneMarch(float3 ro, float3 rd, MbScene S, float px, float tFog0, float fogK,
                               float tmax, thread float& t, thread int& i,
                               thread float& trapHit, thread float& dHit) {
    bool hit = false;
    float omega = MB_OMEGA, prevD = 0.0, stepLen = 0.0;
    for (; i < MB_STEPS; i++) {
        float lod = mbLod(t, S, px);
        float d = mbScene(ro + rd * t, S, lod, trapHit);
        dHit = d;
        float eps = 2.0 * px * t * min(1.0 + 2.0 * max(t - tFog0, 0.0) * fogK, MB_FOG_EPS);
        bool fail = omega > 1.0 && (d + prevD) < stepLen;
        if (fail) {
            stepLen -= omega * stepLen;
            omega = 1.0;
        } else {
            if (d < eps) { hit = true; break; }
            stepLen = d * omega;
        }
        prevD = d;
        t += stepLen;
        if (t > tmax) break;
    }
    if (i == MB_STEPS) hit = true;   // still creeping along a surface: shade it
    return hit;
}

// The lit, fogged colour of a hit at t.
static inline float3 mbShade(float3 ro, float3 rd, float3 right, float3 up, float t, float dHit,
                             float trapHit, MbScene S, MbCamera cam, float px, float tFog0,
                             float fogK, float3 keyDir, float3 fogCol, constant LerpUniforms& u) {
    float3 p = ro + rd * t;
    float e = max(2.0 * px * t, 1e-5);
    float lod = mbLod(t, S, px);
    float3 n = normalize(float3(mbD(p + float3(e, 0.0, 0.0), S, lod), mbD(p + float3(0.0, e, 0.0), S, lod),
                                mbD(p + float3(0.0, 0.0, e), S, lod)) - dHit);
    // Occlusion: one probe along the normal, times the orbit trap (folds
    // that came close to the origin sit deep in the structure).
    float h = 0.06 * cam.sceneUnit;
    float aoP = clamp(mbD(p + n * h, S, max(lod - 2.0, float(MB_LOD_MIN))) / h, 0.0, 1.0);
    float tr = clamp(sqrt(trapHit), 0.0, 1.0);
    float ao = (0.2 + 0.8 * aoP) * mix(0.7, 1.0, tr);

    float3 alb = u.stone.rgb * mix(0.8, 1.05, tr);
    alb = mix(alb, alb * float3(0.82, 0.9, 1.08), smoothstep(0.35, 0.05, tr));

    float3 L, lc;
    if (S.form == 0) {
        float3 dl = ro + 0.08 * (up + right) - p;
        float r = length(dl);
        L = dl / r;
        lc = u.lamp.rgb * 1.6 / (1.0 + r * r * 1.2);
    } else {
        L = keyDir;
        lc = u.lamp.rgb * 1.1;
    }
    float ndl = max(dot(n, L), 0.0);
    float ndh = max(dot(n, normalize(L - rd)), 0.0);
    float fres = pow(1.0 - max(dot(n, -rd), 0.0), 5.0);
    float3 f0 = mix(float3(0.04), alb * 1.3, u.metal);
    float3 F = f0 + (1.0 - f0) * fres;
    float gloss = mix(24.0, 90.0, u.metal);
    float3 spec = F * pow(ndh, gloss) * (gloss + 8.0) / 25.0;
    float3 amb = u.haze.rgb * 9.0 * (0.6 + 0.4 * dot(n, up)) + F * fogCol * 4.0 * u.metal;
    float3 c = alb * (1.0 - 0.75 * u.metal) * (lc * ndl + amb) * ao + spec * lc * ndl * ao;
    return mix(c, fogCol, 1.0 - exp(-max(t - tFog0, 0.0) * fogK));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float T = u.time;
    int form = clamp(u.form, 0, 2);

    MbScene S;
    S.form = form;
    S.cut = 0.0;
    float breath = sin(0.045 * T + u.seed * 40.0);
    MbCamera cam;
    if (form == 0)      cam = mbHallsCamera(u, T, breath, S);
    else if (form == 1) cam = mbBoxCamera(u, T, breath, S);
    else                cam = mbSlabCamera(u, T, breath, S);
    float3 ro = cam.ro, fwd = cam.fwd, upv = cam.upv;

    float3 right = normalize(cross(upv, fwd));
    // Drag to turn: round the box from outside; in the halls and over the
    // slab the view turns where it is.
    float lens = 1.0;
    if (form == 1) lerpOrbit(u.yaw, u.pitch, u.magnify, float3(0.0), upv, ro, right, fwd);
    else           lens = lerpLook(u.yaw, u.pitch, u.magnify, upv, right, fwd);
    float3 up = cross(fwd, right);
    float3 rd = normalize(uv.x * right + uv.y * up + lens * MB_FOCAL * fwd);

    // Hit tolerance and LOD are fixed angles (2 px of a 1500-px view), so a
    // 5K frame costs no more per pixel than a small one. A fixed angle seals
    // the same on-screen size of hole at every distance; the fog may widen it
    // by at most MB_FOG_EPS, so it cannot keep sealing bigger ones further out.
    float px = 2.0 / (lens * MB_FOCAL * 1500.0);
    float fogK = mix(0.12, 0.9, u.fog) / cam.sceneUnit;

    // Fog starts at the bounding cube outside the box, at the eye elsewhere.
    float tFog0 = 0.0;
    bool boxMiss = false;
    if (form == 1) tFog0 = mbBoxEntry(ro, rd, S.E, boxMiss);
    float tmax = tFog0 + 3.5 / fogK;                 // fog is ~97% by here

    float t = 0.0;
    int i = 0;
    bool hit = false;
    float trapHit = 1.0, dHit = 0.0;
    if (!boxMiss) {
        t = mbSharedMarch(ro, rd, S, px, tmax, i);
        hit = mbLaneMarch(ro, rd, S, px, tFog0, fogK, tmax, t, i, trapHit, dHit);
    }

    // Light: a lantern just above the eye in the halls; outside, a key light
    // over the shoulder (box) or a fixed low one (slab).
    float3 keyDir = form == 1 ? normalize(-0.55 * fwd + 0.65 * up + 0.5 * right)
                              : normalize(float3(0.55, 0.62, -0.42));
    float3 fogCol = u.haze.rgb;
    if (form != 0) fogCol += u.lamp.rgb * 0.06 * pow(max(dot(rd, keyDir), 0.0), 6.0);

    float3 col = fogCol;
    if (hit) col = mbShade(ro, rd, right, up, t, dHit, trapHit, S, cam, px, tFog0, fogK, keyDir, fogCol, u);
    col = mix(col, u.haze.rgb, cam.mist);

    col = 1.0 - exp(-1.2 * col);
    col = sqrt(max(col, 0.0));
    col = lerpDither(col, pos);
    return half4(half3(col), 1.0h);
}
