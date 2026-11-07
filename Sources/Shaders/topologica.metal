
// Topologica — Otavio Good's "Topologica" and this project's three remixes of
// it, as one look with a `form` setting.
// https://www.shadertoy.com/view/4djXzz  (2014-08-21), CC0 1.0. The upstream
// dedication is quoted in full in the Classic section below.
//
// Forms (each section below keeps its original notes, word for word):
//   0 Classic           the faithful port (the default look)
//   1 Lattice           2 Filigree        3 Jacks
//                       a self-similar KIFS wire network, zooming forever
//   4 Minimal surfaces  triply periodic minimal surfaces, morphing G/P/D/N
//   5 Strata            the same, with iso-bands
//   6 Tesseract         7 24-cell         8 Hopf fibration   9 Torus knots
//                       four-dimensional geometry, sliced or projected
//
// These were four separate shaders sharing one camera, one glow and one
// default blue, so the rotation spent nineteen looks on glowing blue wire.
// One shader with eight looks keeps every distinct idea and drops the
// repeats. The playground cannot hide a setting that a form ignores, so the
// settings are the few every form shares, and each form's own constants are
// baked at the values its kept looks used:
//   gain    multiplies the form's own default glow gain (Classic 0.02,
//           wires 1, surfaces 0.02, 4D 800)
//   detail  multiplies the form's own default march steps (Classic 16,
//           wires 7, Jacks 6, surfaces 10, 4D 16); "Upstream" sets
//           gain=10, detail=2.32, which is upstream's 0.2 and 37 steps
//   accent  the surfaces' depth/membrane colour, and 4D's second colour
//   morph   drifts the surfaces' warp (0.25-0.6) and 4D's slice thickness
//           (0.1-0.22); both used to drift on their own parameters
//
// GPU cost: the form is a uniform branch, so a frame costs what its form
// always cost (checked with `LerpPreview --bench --looks` against the
// separate shaders before they were removed).
//
// lerp-param: form   int   0 9        = 0                  "Form"
// lerp-param: color  color            = (0.01, 0.1, 1.0)   "Glow colour"
// lerp-param: accent color            = (0.42, 0.06, 1.0)  "Accent colour"
// lerp-param: speed  float 0 4        = 1.0                "Speed"
// lerp-param: gain   float 0.1 10     = 1.0                "Glow gain"
// lerp-param: detail float 0.25 2.5   = 1.0                "Detail"
// lerp-param: morph  float 0 1        = 0.5                "Morph"
// lerp-param: yaw      float -180 180 = 0 "Turn"
// lerp-param: pitch    float -90 90   = 0 "Tilt"
// lerp-animate: morph 0 1 period=180
//
// lerp-preset: Upstream           gain=10, detail=2.32
// lerp-preset: "Gold Filigree"    form=2, color=(0.42, 0.15, 0.02)
// lerp-preset: "Violet Jacks"     form=3, color=(0.22, 0.03, 0.55)
// lerp-preset: "Minimal Surfaces" form=4
// lerp-preset: Strata             form=5, color=(1.0, 0.55, 0.12), accent=(0.85, 0.10, 0.06)
// lerp-preset: "Hopf Fibration"   form=8, color=(0.9, 0.06, 0.6), accent=(0.04, 0.6, 1.0)
// lerp-preset: "Torus-Knot Weave" form=9, color=(1.0, 0.25, 0.04), accent=(1.0, 0.55, 0.12)

// What each form's drawing function reads as `u`: the frame's header fields
// and that form's own settings, filled in by lerpMain at the bottom.
struct TopoClassicIn {
    float2 resolution;
    float time;
    float seed;
    float yaw; float pitch;           // drag to turn
    float4 color; float speed; float gain; int steps;
};
struct TopoFractalIn {
    float2 resolution;
    float time;
    float seed;
    float yaw; float pitch;           // drag to turn
    float4 color; float speed; float zoom; float gain; int wire;
    float tilt; float bloom; int steps;
};
struct TopoGyroidIn {
    float2 resolution;
    float time;
    float seed;
    float yaw; float pitch;           // drag to turn
    float4 color; float4 accent; float speed; float gain; int steps;
    float surface; float morph; float scale; float twist; float warp;
    float membrane; float bands;
};
struct Topo4DIn {
    float2 resolution;
    float time;
    float seed;
    float yaw; float pitch;           // drag to turn
    int mode; float4 color; float4 color2; float dichroic; float speed;
    float gain; float width; float slab; float cells; float tilt; float drift;
    float turn; int rings; int fibers; int knotP; int knotQ; int steps;
};

// ============================================================================
// Form source: was Sources/Shaders/topologica.metal
// ============================================================================
// Topologica — ported from Shadertoy "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21)
// Upstream licence, verbatim:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   To the extent possible under law, the author(s) have dedicated all
//   copyright and related and neighboring rights to this software to the
//   public domain worldwide. This software is distributed without any
//   warranty.
//   ^ This means do ANYTHING YOU WANT with this code. Because we are
//   programmers, not lawyers.
//   -Otavio Good
//
// A camera orbits far outside a cloud of 3D value noise; a short, coarse
// raymarch accumulates 0.1/|n1^2 * n2| so only the thin sheets where the
// noise crosses its midpoint glow, like contour lines on a topographic map
// folded into space. Port notes:
// - Upstream's mouse orbit is replaced by `u.seed`, which picks the starting
//   orbit angle so every activation shows a different side of the cloud.
// - `speed` is added by this port (upstream is fixed at 1x); its default
//   keeps upstream's already-slow orbit. `color` is upstream's baked
//   vec3(0.01, 0.1, 1.0), exposed. `gain` is upstream's baked 0.2 density
//   scale; the default is 0.02 so more of the screen stays dark and only
//   the thin contour sheets glow (upstream saturates large areas to white,
//   mean luma ~0.55). The "Upstream" preset restores 0.2.
// - GPU cost, reduced: upstream marches 37 steps x 2 trilinear noise lookups
//   (8 hashes each), about 4x the cost of the heaviest paper-design port at
//   4K. This port defaults to 16 steps, each striding 37/16 as far so the
//   march still spans upstream's depth (fewer, sparser contour layers; a
//   calmer picture), and replaces upstream's `fract(cos(f*3.333)*100003.9)`
//   lattice hash with the prelude's trig-free `hash21` (same role: a random
//   value per lattice corner). `steps` (added by this port) restores
//   upstream's 37, as does the "Upstream" preset.
// - Lattice cache. A step moves about a tenth of a noise cell (8.6 steps
//   per cell at upstream's stride), so each noise keeps its cell's eight
//   corner hashes and only rehashes on entering a new cell; neighbouring
//   pixels' rays cross cells at the same step, so the branch is coherent.
//   The picture is unchanged (with the filtering below disabled it matched
//   the uncached march in all but 0.02% of pixels, the singular points) and
//   the march costs half: at 2704x1756 on an M5, 9.5 -> 5.9 ms mean for the
//   default and 22.0 -> 11.3 ms for "Upstream", in the same contended runs
//   (cache alone, before the filtering below; the filtering spends part of
//   that saving back, and was written after GPU benching was frozen: its
//   cost is not yet measured. If "Upstream" lands over 13 ms p95, set
//   TOPO_SS to 4).
// - Filaments are supersampled, analytically. Upstream point-samples
//   0.1/|a^2 b|, whose glowing cores (a = 0 is a 1/a^2 spike) are far
//   thinner than a pixel, so a pixel lit up only when its centre landed in
//   one: lines drew as dotted, stair-stepped strings of single bright pixels
//   that sparkled as they moved. Widening the zeros by the pixel footprint
//   (1/(a^2 + eps^2)) cannot fix that: the energy is in sub-pixel cores
//   that saturate under the clamp, so softening dimmed the picture (mean
//   -3 to -9 levels against a 16x supersampled render). Instead each step
//   takes the noises' gradients with their values (same eight corners), the
//   noises are linear across a pixel (a cell spans 100+ pixels), and the
//   density is evaluated at 8 sub-pixel offsets of the linearised field, each
//   accumulated, clamped and gamma'd on its own, then averaged: true 8x
//   supersampling of the brightness for the price of one noise lookup. More
//   than 3 pixels from either zero the 8 values differ by under 15% and their
//   mean is the centre value times a second-order Taylor factor (exact to
//   ~0.3% at 3 pixels, so the switch leaves no seam), so only steps near a
//   filament pay for 8 divides.
// - The ray's step length. Upstream lengthens each step by the density
//   there ("this makes it look extra crazy!"), so after passing near a core a
//   ray jumps ahead and every later sample moves. That jump, taken from the
//   point-sampled density, is singular too, and it differs between adjacent
//   pixels: with supersampled brightness alone, isolated bright pixels
//   remained exactly where the jump varied (with a fixed step they vanished,
//   but the picture changed, MAE 12 levels). So each step's length uses the
//   density with both zeros widened by one pixel, which neighbouring pixels
//   agree on, while each sub-pixel keeps upstream's own step weight in its
//   brightness. Against a 16x supersampled render of the original at
//   1352x878, mean absolute error 2.8 -> 1.8 levels (p99 50 -> 35) for the
//   default and 3.1 -> 2.1 (p99 54 -> 41) for "Upstream", mean bias still
//   0.0-0.1; the dotted lines draw as continuous filaments. (Measured with
//   every step supersampled, before the Taylor shortcut was added.)

static float topoHash3d(float3 uv) {
    return hash21(float2(uv.x + uv.z * 57.0, uv.y - uv.z * 113.0));
}

// The eight corner values of the lattice cell a noise lookup last landed in.
// A march step moves about a tenth of a cell, so consecutive steps nearly
// always share a cell and the 8 hashes are reused (see header).
struct TopoCell {
    float3 id;   // floor of the cell's lower corner; NaN-free sentinel first
    float4 lo;   // corners at z = 0: 000, 100, 010, 110
    float4 hi;   // corners at z = 1: 001, 101, 011, 111
};

static void topoFetch(thread TopoCell& c, float3 fl) {
    if (all(fl == c.id)) return;
    c.id = fl;
    const float2 zo = float2(0.0, 1.0);
    c.lo = float4(topoHash3d(fl), topoHash3d(fl + zo.yxx),
                  topoHash3d(fl + zo.xyx), topoHash3d(fl + zo.yyx));
    c.hi = float4(topoHash3d(fl + zo.xxy), topoHash3d(fl + zo.yxy),
                  topoHash3d(fl + zo.xyy), topoHash3d(fl + zo.yyy));
}

// Upstream's trilinear value noise with smoothstep weights, and its gradient
// (per lattice unit): (n, dn/dx, dn/dy, dn/dz).
static float4 topoNoiseGrad(float3 uv, thread TopoCell& c) {
    float3 fl = floor(uv);
    topoFetch(c, fl);
    float3 fr = fract(uv);
    float3 w = fr * fr * (3.0 - 2.0 * fr);
    float3 dw = 6.0 * fr * (1.0 - fr);
    float4 x0 = float4(c.lo.x, c.lo.z, c.hi.x, c.hi.z);   // h0yz: 00 10 01 11
    float4 dx = float4(c.lo.y, c.lo.w, c.hi.y, c.hi.w) - x0;
    float4 e = x0 + dx * w.x;                              // x-lerps, by (y, z)
    float2 dy = float2(e.y - e.x, e.w - e.z);
    float2 f = e.xz + dy * w.y;                            // y-lerps, by z
    float n = f.x + (f.y - f.x) * w.z;
    float2 gx2 = dx.xz + (dx.yw - dx.xz) * w.y;
    return float4(n,
                  (gx2.x + (gx2.y - gx2.x) * w.z) * dw.x,
                  (dy.x + (dy.y - dy.x) * w.z) * dw.y,
                  (f.y - f.x) * dw.z);
}

// Sub-pixel samples per pixel near a filament (see header): 8, or 4 to
// trade some smoothness for cost. topoSubM is the pattern's second moment,
// mean(o o^T), as (xx, yy, xy), for the Taylor estimate away from filaments.
#ifndef TOPO_SS
#define TOPO_SS 8
#endif
#if TOPO_SS == 8
// The 8x MSAA "rooks" pattern, in pixels: its projection onto any direction
// is evenly spread, so a line at any angle is covered in even steps.
constant float2 topoSub[8] = {
    float2( 1, -3) / 16.0, float2(-1,  3) / 16.0, float2( 5,  1) / 16.0, float2(-3, -5) / 16.0,
    float2(-5,  5) / 16.0, float2(-7, -1) / 16.0, float2( 3,  7) / 16.0, float2( 7, -7) / 16.0 };
constant float3 topoSubM = float3(168.0, 168.0, -32.0) / (8.0 * 256.0);
#else
constant float2 topoSub[4] = {
    float2(-2, -6) / 16.0, float2( 6, -2) / 16.0, float2(-6,  2) / 16.0, float2( 2,  6) / 16.0 };
constant float3 topoSubM = float3(80.0, 80.0, 0.0) / (4.0 * 256.0);
#endif

static float topoSubQ(float2 x, float2 y) {
    return x.x * y.x * topoSubM.x + x.y * y.y * topoSubM.y + (x.x * y.y + x.y * y.x) * topoSubM.z;
}

static half4 topoClassic(float4 pos, TopoClassicIn u) {
    // Upstream: uv = fragCoord/iResolution * 2 - 1, y up.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;

    float3 camUp = float3(0.0, 1.0, 0.0);
    float3 camLookat = float3(0.0);

    float mx = u.seed * TWO_PI + time * 0.01;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.2 + 0.2;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * 200.2;

    float3 camVec = normalize(camLookat - camPos);
    float3 sideNorm = normalize(cross(camUp, camVec));
    lerpOrbit(u.yaw, u.pitch, camLookat, camUp, camPos, sideNorm, camVec);
    float3 upNorm = cross(camVec, sideNorm);
    float3 worldFacing = camPos + camVec;
    float3 worldPix = worldFacing + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm;
    float3 relVec = normalize(worldPix - camPos);

    // How far a point at ray distance 1 moves, in noise-lattice units, when
    // the pixel moves one pixel right (dX) or up (dY): the image plane is
    // 2 units tall at distance |worldPix - camPos|, and only the part of the
    // step across the ray counts.
    float ppx = 2.0 / u.resolution.y / length(worldPix - camPos) * 0.06125;
    float3 dX = (sideNorm - dot(sideNorm, relVec) * relVec) * ppx;
    float3 dY = (upNorm - dot(upNorm, relVec) * relVec) * ppx;

    float t = 0.0;
    float inc = 0.02;
    const float maxDepth = 70.0;
    float common = 0.0;               // density shared by all sub-pixels
    float density[TOPO_SS];           // and each one's own
    for (int j = 0; j < TOPO_SS; j++) density[j] = 0.0;
    // Fewer steps than upstream's 37 each stride proportionally further, so
    // the march still spans the same depth.
    float stride = 37.0 / float(u.steps);
    TopoCell ca, cb;
    ca.id = cb.id = float3(-1e9);
    ca.lo = ca.hi = cb.lo = cb.hi = 0.0;
    for (int i = 0; i < u.steps; i++) {
        if (t > maxDepth) break;
        float3 q = (camPos + relVec * t) * 0.06125;
        float4 na = topoNoiseGrad(q, ca);
        float4 nb = topoNoiseGrad(q + 1234.567, cb);
        float a = na.x - 0.5;
        float b = nb.x - 0.5;
        // Each noise's change per pixel, right and up, at this depth.
        float2 sa = float2(dot(na.yzw, dX), dot(na.yzw, dY)) * t;
        float2 sb = float2(dot(nb.yzw, dX), dot(nb.yzw, dY)) * t;
        float sa2 = dot(sa, sa);
        float sb2 = dot(sb, sb);
        // upstream: "this makes it look extra crazy!": a step's weight, and
        // its length, grow with the density there.
        if (a * a <= 9.0 * sa2 || b * b <= 9.0 * sb2) {
            // Within 3 pixels of a filament: upstream's density,
            // 0.1/|a^2 b| + 0.5 scaled by 1e-4, at each sub-pixel offset (the
            // noises are linear across a pixel), each with its own weight.
            for (int j = 0; j < TOPO_SS; j++) {
                float aj = a + dot(sa, topoSub[j]);
                float bj = b + dot(sb, topoSub[j]);
                float temp = (0.1 / abs(aj * aj * bj) + 0.5) * 0.0001;
                density[j] += temp * (1.9 + temp * 0.05) * stride;
            }
        } else {
            // Further out the sub-pixels vary smoothly, and their mean is the
            // centre value times a second-order Taylor factor (within ~0.3%
            // of the sum above at 3 pixels, so the switch leaves no seam).
            float f = 0.1 / abs(a * a * b);
            f *= 1.0 + 3.0 * topoSubQ(sa, sa) / (a * a) + topoSubQ(sb, sb) / (b * b)
                     + 2.0 * topoSubQ(sa, sb) / (a * b);
            float temp = (f + 0.5) * 0.0001;
            common += temp * (1.9 + temp * 0.05) * stride;
        }
        // The ray steps by the density with each zero widened by a pixel, so
        // neighbouring pixels jump alike (see header).
        float soft = (0.1 / ((a * a + sa2) * sqrt(b * b + sb2)) + 0.5) * 0.0001;
        inc = (1.9 + soft * 0.05) * stride;
        t += inc;
    }

    // Upstream's sqrt "gamma correction", per sub-pixel, then averaged.
    float3 color = 0.0;
    for (int j = 0; j < TOPO_SS; j++)
        color += sqrt(clamp(u.color.rgb * (common + density[j]) * u.gain, 0.0, 1.0));
    color *= 1.0 / float(TOPO_SS);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}

// ============================================================================
// Form source: was Sources/Shaders/topologica-fractal.metal
// ============================================================================
// Topologica Fractal — a remix of "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21), CC0 1.0:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   (Upstream's dedication is quoted in full in topologica.metal.)
//
// An original remix written for Lerping@Home, not a port. What it keeps from
// Topologica: glowing filaments in a dark volume, a short fixed-stride march
// that sums glow along each ray, upstream's colour multiply and sqrt
// "gamma", its default blue, and a camera slowly orbiting a centre point.
// What it replaces: upstream's noise lattice becomes a self-similar wire
// network, and the camera flies into it forever.
//
// The network is a kaleidoscopic IFS (Knighty's KIFS, as described in
// Mikael Hvidtfeldt Christensen's "Distance Estimated 3D Fractals" on
// Syntopia). The level loop is written here from that math; no code comes
// from Syntopia or from any Shadertoy other than Topologica's CC0 code.
// Space is sorted once into the chamber x >= y >= z. Then each level folds
// with abs() and one tilted mirror, adds the glow of a few straight wires,
// and scales space by S = 3 about C = (1,1,1). Each level is a copy of the
// one above at a third of the size, so the wires branch into ever-finer
// copies of themselves.
//
// The glow is not sampled at points. Each march step is a straight piece of
// ray, folded with the mirrors chosen at its middle, and the shader finds
// that piece's closest approach to each wire analytically. A tent in where
// that approach falls splits each wire's glow between the two nearest
// pieces, so the coarse wires draw as crisp, unbroken lines with only 7
// steps. The folds are rounded (C1) rather than sharp, so a piece that
// straddles a mirror bends smoothly instead of tearing, and the picture
// stays continuous from pixel to pixel and frame to frame. On the finest
// levels one piece spans several mirrors, so its single bent line is only an
// approximation of the true wires there. That approximation is what curls
// the fine wires into Topologica-like curves, and it is kept as the look.
//
// Seamless zoom. abs() and the tilted mirror never act within `rho` of C.
// The sort's mirrors pass through C and its rounding grows with distance
// from C, so it commutes with scaling about C. (It runs once, before the
// level loop: a rounded fold is not idempotent, so sorting again on every
// level would leave a seam.) Near C, then, one level is exactly the level
// above scaled by 3. The camera zooms toward C by exactly that factor once
// per cycle, and each level's brightness is a window over (level - phase).
// At phase 1 every level stands exactly where the level above stood at
// phase 0, so the wrap has no seam. That only holds while all the camera can
// see at phase 1 lies within `rho` of C, so the view's world scale is derived
// from `rho` and the fog depth every frame. (Checked by rendering 4 ms
// either side of a wrap: the difference matches two ordinary frames 4 ms
// apart.)
//
// Seed: picks the orbit's starting angle and height, the phase of the
// mirror and anchor drift, and where in the zoom cycle the run starts.
//
// GPU cost: steps x 4 levels x 1-3 analytic wires. On an M5 at 3840x2160
// (`LerpPreview --bench --looks`, quiet rounds) the default and the Gold
// Filigree and Ice Lattice looks measure 16.7-17.3 ms against topologica's
// 17.0-17.4 ms in the same rounds. Violet Jacks runs 6 steps to stay under
// it too. `steps` above 7 costs proportionally more than topologica.
//

constant int   TFR_LEVELS = 4;
constant float TFR_S      = 3.0;   // scale per level
constant float TFR_EYE    = 1.0;   // eye distance from C, camera units
constant float TFR_FOG    = 3.0;   // march depth, camera units
constant float TFR_SIGMA  = 0.004; // wire core radius, in each level's own units
constant float TFR_SOFT   = 0.05;  // fold rounding, in each level's own units
constant float TFR_HALO   = 0.15;  // soft glow around each wire, relative to the core
constant float TFR_SORT_SOFT = 0.12; // sort-mirror rounding, per unit distance from C

// Rounded mirror fold of a ray piece (point p, half-vector h) through the
// plane through the origin with unit normal n: exactly a reflection more
// than `soft` from the plane, a C1 parabola inside, so the folded picture
// stays continuous where a piece of the march straddles a mirror. h is
// carried by the fold's Jacobian.
static void tfrFold(thread float3& p, thread float3& h, float3 n, float soft) {
    float d = dot(p, n);
    float ad = abs(d);
    bool in = ad < soft;
    float sa = in ? 0.5 * (d * d / soft + soft) : ad;
    float g = in ? d / soft : sign(d);
    p += (sa - d) * n;
    h += (g - 1.0) * dot(h, n) * n;
}

static void tfrFoldAbs(thread float3& p, thread float3& h) {
    float3 ap = abs(p);
    bool3 in = ap < TFR_SOFT;
    float3 sa = select(ap, 0.5 * (p * p / TFR_SOFT + TFR_SOFT), in);
    float3 g = select(sign(p), p / TFR_SOFT, in);
    p = sa;
    h *= g;
}

// Cross-section of one wire's glow at squared distance x2 (in core radii):
// a sharp 1/x^2 core, like Topologica's 0.1/|n^2|, plus a soft halo.
// 1/a + H/b written over one divide.
static float tfrProfile(float x2) {
    float a = x2 + 0.03;
    float b = 1.0 + 0.01 * x2;
    return (b + TFR_HALO * a) / (a * b);
}

// Glow of a straight wire seen from one piece of the ray, everything in one
// level's units. The piece is p + s*h, s in [-1, 1]; neighbouring pieces sit
// at s = +-2. b is the closest approach of the ray's line to the wire's line
// and s* where along the ray it happens; a tent in s* hands each approach to
// the two nearest pieces with weights summing to one, so every wire draws as
// one continuous crisp line however coarse the march. `r` is p relative to a
// point on the wire, `w` the wire's unit direction, and the wire is kept for
// u <= 0 along w (the far end is the mirror plane, which completes it).
static float tfrWireGlow(float3 r, float3 h, float3 w, float isig2) {
    float3 rp = r - dot(r, w) * w;
    float3 hp = h - dot(h, w) * w;
    float A = dot(hp, hp) + 1e-9;
    float sStar = -dot(rp, hp) / A;
    float3 cl = rp + sStar * hp;
    float tent = saturate(1.0 - 0.5 * abs(sStar));
    float ends = saturate(1.0 - dot(r + sStar * h, w) * 30.0);
    float x2 = dot(cl, cl) * isig2;
    return tent * ends * tfrProfile(x2);
}

// The same for a wire along a coordinate axis: r2/h2 are the two components
// across it, ru/hu the component along it.
static float tfrAxisGlow(float2 r2, float2 h2, float ru, float hu, float isig2) {
    float A = dot(h2, h2) + 1e-9;
    float sStar = -dot(r2, h2) / A;
    float2 cl = r2 + sStar * h2;
    float tent = saturate(1.0 - 0.5 * abs(sStar));
    float ends = saturate(1.0 - (ru + sStar * hu) * 30.0);
    float x2 = dot(cl, cl) * isig2;
    return tent * ends * tfrProfile(x2);
}

// Fold the ray piece into the chamber x >= y >= z through the mirrors x=y,
// x=z, y=z. All three pass through C = (1,1,1), and the rounding grows with
// distance from C, so this fold commutes with scaling about C and the zoom
// stays exact (see header).
static void tfrSort(thread float3& p, thread float3& h) {
    float soft = TFR_SORT_SOFT * length(p - 1.0);
    tfrFold(p, h, float3(M_SQRT1_2_F, -M_SQRT1_2_F, 0.0), soft);
    tfrFold(p, h, float3(M_SQRT1_2_F, 0.0, -M_SQRT1_2_F), soft);
    tfrFold(p, h, float3(0.0, M_SQRT1_2_F, -M_SQRT1_2_F), soft);
}

// One level's wires, in that level's units, already folded. `k` is the
// (drifting) anchor of the wire shape.
static float tfrWires(float3 p, float3 h, float3 k, int wire, float isig2) {
    float3 r = p - k;
    if (wire == 1) {
        // Filigree: a strut from the origin out to k, and a rib dropping from
        // k toward the y = 0 mirror; the folds of every level branch them
        // into a tree.
        return tfrWireGlow(r, h, normalize(k), isig2)
             + tfrAxisGlow(r.xz, h.xz, r.y, h.y, isig2);
    }
    // Lattice: the three edges of a box through its corner k, mirrored by
    // abs() into the whole frame. Jacks: the same three axis wires pushed
    // 0.3 past k, so they cross there like jacks instead of meeting.
    float ext = wire == 2 ? 0.3 : 0.0;
    return tfrAxisGlow(r.yz, h.yz, r.x - ext, h.x, isig2)
         + tfrAxisGlow(r.xz, h.xz, r.y - ext, h.y, isig2)
         + tfrAxisGlow(r.xy, h.xy, r.z - ext, h.z, isig2);
}

static half4 topoFractal(float4 pos, TopoFractalIn u) {
    float time = u.time * u.speed;

    // --- the map ------------------------------------------------------------
    // Sort once, then per level: abs(), one tilted mirror (through p0,
    // normal nt), the wires, then scale by S about C. The mirror and the wire
    // anchor k drift slowly ("bloom"); the seed picks their phase.
    const float3 c = float3(1.0);
    float ph = u.seed * 37.0;
    float drift = u.bloom;
    float3 nt = normalize(float3(-1.0, 0.3 + u.tilt * 0.9 + 0.25 * drift * sin(time * 0.041 + ph),
                                 1.0 - u.tilt * 0.5 + 0.2 * drift * sin(time * 0.029 + ph * 1.3)));
    float3 p0 = float3(0.6, 0.0, 0.0);
    float3 k = (u.wire == 1 ? float3(1.5, 1.3, 1.1) : u.wire == 2 ? float3(1.25, 1.12, 1.05)
                                                    : float3(1.4, 1.2, 1.08))
             + 0.08 * drift * float3(sin(time * 0.037 + ph * 2.1), sin(time * 0.031 + ph * 0.7),
                                     sin(time * 0.023 + ph * 1.9));

    // Radius of the ball around C on which abs() and the tilted mirror are
    // the identity; the view at phase 1 must fit inside it (see header).
    float rho = min(1.0, dot(c - p0, nt)) - TFR_SOFT;
    float viewScale = 0.9 * rho * TFR_S / (TFR_EYE + TFR_FOG); // world per camera unit

    // --- zoom phase: one map per cycle -------------------------------------
    float phase = fract(time * u.zoom / 60.0 + u.seed * 3.0);
    float worldPerCam = viewScale / pow(TFR_S, phase);

    // --- camera: orbits C slowly in camera space ---------------------------
    float az = u.seed * TWO_PI + time * 0.012;
    float el = sin(time * 0.017 + u.seed * 11.0) * 0.5;
    float3 eye = TFR_EYE * float3(cos(el) * cos(az), sin(el), cos(el) * sin(az));
    float3 fwd = normalize(-eye);
    float3 side = normalize(cross(float3(0.0, 1.0, 0.0), fwd));
    lerpOrbit(u.yaw, u.pitch, float3(0.0), float3(0.0, 1.0, 0.0), eye, side, fwd);
    float3 up = cross(fwd, side);
    float2 uv = lerpUV(pos, u.resolution);
    float3 dir = normalize(fwd * 1.5 + uv.x * side + uv.y * up);

    // Per-level weights: a window over (level - phase), zero at both ends,
    // so levels enter at the fine end and leave at the coarse end.
    float lw[TFR_LEVELS];
    for (int n = 0; n < TFR_LEVELS; n++) {
        float kk = float(n) - phase;
        lw[n] = smoothstep(-1.0, 0.0, kk)
              * (1.0 - smoothstep(float(TFR_LEVELS) - 2.0, float(TFR_LEVELS) - 1.0, kk));
    }

    float stride = (TFR_EYE + TFR_FOG) / float(u.steps);
    float pix = 1.5 / u.resolution.y;      // one pixel at unit distance, camera units
    float3 hw = dir * (0.5 * stride * worldPerCam);
    float density = 0.0;
    for (int i = 1; i <= u.steps; i++) {
        float t = float(i) * stride;
        float3 p = c + (eye + dir * t) * worldPerCam;
        float3 h = hw;
        float pixLevel = pix * t * worldPerCam;   // one pixel, in level units
        float glow = 0.0;
        tfrSort(p, h);
        for (int n = 0; n < TFR_LEVELS; n++) {
            tfrFoldAbs(p, h);
            float3 q = p - p0;
            tfrFold(q, h, nt, TFR_SOFT);
            p = q + p0;
            if (lw[n] > 0.0) {
                float sig = max(TFR_SIGMA, pixLevel);
                glow += lw[n] * (TFR_SIGMA / sig) * tfrWires(p, h, k, u.wire, 1.0 / (sig * sig));
            }
            p = TFR_S * (p - c) + c;
            h *= TFR_S;
            pixLevel *= TFR_S;
        }
        float fog = 1.0 - smoothstep(0.35 * TFR_FOG, TFR_FOG, t);
        density += glow * fog;
    }

    float3 finalColor = u.color.rgb * density * u.gain * 0.5;
    // Upstream's sqrt "gamma correction".
    float3 color = sqrt(clamp(finalColor, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}

// ============================================================================
// Form source: was Sources/Shaders/topologica-gyroid.metal
// ============================================================================
// Topologica Gyroid — a remix of "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21)
// Upstream licence, verbatim:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   To the extent possible under law, the author(s) have dedicated all
//   copyright and related and neighboring rights to this software to the
//   public domain worldwide. This software is distributed without any
//   warranty.
//   ^ This means do ANYTHING YOU WANT with this code. Because we are
//   programmers, not lawyers.
//   -Otavio Good
//
// Remix (not a port; topologica.metal is the faithful one). Kept from
// upstream: a short, coarse march through a slowly orbiting volume that
// accumulates 0.1/|a^2 * b|, so light gathers where field a vanishes and
// blazes where field b vanishes there too; the colour scaled by density and
// upstream's sqrt "gamma". Replaced: the two value-noise fields, with triply
// periodic minimal surfaces.
//
// - Field a blends the gyroid, Schwarz P, Schwarz D (diamond) and Neovius
//   implicit functions; field b is the next family round that cycle, offset
//   by a slowly drifting phase. The filaments are the curves where the two
//   surfaces intersect, rendered as thin glowing tubes; a faint membrane
//   shows surface a itself, so the labyrinth's tunnels read as dark holes.
//   `bands` adds the curves where a meets b's other level sets, b = k/bands.
// - Upstream point-samples the field, so a 16-step march sees each sheet
//   only where a sample lands on it (the contour-line look). Here a and b
//   are taken as linear between samples and 1/(a^2 + b^2 + r^2) is
//   integrated exactly per segment (closed form, atan), so no filament can
//   fall between steps. That is why 10 steps look like 32 and the march
//   can afford a telephoto view that shows the lattice's order.
// - Motion: the blend wanders gyroid -> P -> D -> Neovius -> gyroid,
//   dwelling on each and morphing between them (blending implicit functions
//   moves their zero sets continuously, so the network reorganises); the
//   lattice twists about the vertical axis, slowly breathes in scale and
//   warps gently; the camera orbits as upstream's does. `u.seed` picks the
//   orbit angle and height phase, the morph phase, the partner offset and
//   the breathing/twist phases.
// - Cost: all four surfaces, and the partner's four, come from one sin/cos
//   of the sample point (the partner by angle addition), so a step costs
//   about what upstream's two trilinear noise lookups do, at fewer steps.
//   Two more exact savings per step: the samples are evenly spaced on a
//   straight ray, so the warp's three sines step by angle addition too, and
//   each closed-form integral's difference of two atans is one atan2.
//

// The four surfaces at one point, from its sin and cos. Each is scaled so
// that its gradient across the zero set is roughly the same, which keeps the
// filament width steady while the blend morphs.
static float4 tgySurfaces(float3 s, float3 c) {
    float g = s.x * c.y + s.y * c.z + s.z * c.x;                          // gyroid
    float p = c.x + c.y + c.z;                                            // Schwarz P
    float d = s.x * s.y * s.z + s.x * c.y * c.z
            + c.x * s.y * c.z + c.x * c.y * s.z;                          // Schwarz D
    float n = 3.0 * (c.x + c.y + c.z) + 4.0 * c.x * c.y * c.z;            // Neovius
    return float4(g, p * 0.8, d * 1.1, n * 0.28);
}

// Blend weights for a position x on the cycle G(0) P(1) D(2) N(3) G(4).
static float4 tgyWeights(float x) {
    float4 k = float4(0.0, 1.0, 2.0, 3.0);
    float4 r = x - k + 2.0;
    float4 d = abs(r - 4.0 * floor(r * 0.25) - 2.0); // cyclic distance, 0..2
    float4 w = clamp(1.0 - d, 0.0, 1.0);
    return w * w * (3.0 - 2.0 * w);                // adjacent pair sums to 1
}

// Everything that places the lattice in the world for this frame.
struct TgyFrame {
    float4 w;          // surface blend weights
    float k;           // lattice frequency
    float twistRate;   // radians of twist per unit of height
    float spin;        // twist phase
    float warpAmp;
    float warpPhase;
    float3 so, co;     // sin, cos of the partner's lattice offset
};

// The warp's sine argument at world point p.
static float3 tgyWarpArg(float3 p, TgyFrame f) {
    return p.zxy * 0.06 + float3(0.0, 2.1, 4.2) + f.warpPhase;
}

// (a, b): the blended surface and its partner, at world point p, given
// sin(tgyWarpArg(p)). The march's samples are evenly spaced on a straight
// ray, so that argument steps by a constant and its sine comes from an
// angle-addition recurrence instead of three sines a step.
static float2 tgyField(float3 p, float3 warpSin, TgyFrame f) {
    p += f.warpAmp * warpSin;
    float ang = p.y * f.twistRate + f.spin;
    float cs = cos(ang), sn = sin(ang);
    p.xz = float2(cs * p.x - sn * p.z, sn * p.x + cs * p.z);

    float3 q = p * f.k;
    float3 s = sin(q), c = cos(q);
    float a = dot(f.w, tgySurfaces(s, c));
    // The partner is the next family round the cycle, offset by a drifting
    // phase: sin/cos of (q + offset) by angle addition, no more trig.
    float b = dot(f.w.yzwx, tgySurfaces(s * f.co + c * f.so, c * f.co - s * f.so));
    return float2(a, b);
}

// Exact integral over a segment of length dt of 1/(a^2 + e^2), with a
// varying linearly from a0 to a1. A zero crossing anywhere inside the
// segment is caught, and is brightest where the ray grazes the surface.
static float tgySegment(float a0, float a1, float e, float dt) {
    float da = a1 - a0;
    if (abs(da) < 1e-4) return dt / (a0 * a0 + e * e);
    // atan(a1/e) - atan(a0/e) as one atan2 (the difference identity, exact,
    // and free of the cancellation between two nearly equal angles).
    return dt * atan2(e * da, e * e + a0 * a1) / (e * da);
}

// A thin tube around the curve where both surfaces vanish, integrated
// exactly along a segment over which (a, b) moves linearly from p0 to p1,
// so no step can skip a filament. With Q(s) = |p(s)|^2 + r^2:
//   x = integral of 1/Q    (soft halo, upstream's 1/|b| falloff)
//   y = integral of 1/Q^2  (crisp core)
static float2 tgyTube(float2 p0, float2 p1, float r2) {
    float2 D = p1 - p0;
    float A = max(dot(D, D), 1e-8);
    float B = 2.0 * dot(p0, D);
    float C = dot(p0, p0) + r2;
    float q2 = max(4.0 * A * C - B * B, 1e-14);
    float q = sqrt(q2);
    // atan((2A+B)/q) - atan(B/q) by the difference identity: the atan2 of
    // (2A/q, 1 + B(2A+B)/q^2), scaled by q^2/2A to (q, 2C + B), and
    // 2C + B = 2(p0.p1 + r2). One atan2 instead of two atans (exact).
    float i1 = 2.0 / q * atan2(q, 2.0 * (dot(p0, p1) + r2));
    float i2 = ((2.0 * A + B) / (A + B + C) - B / C + 2.0 * A * i1) / q2;
    return float2(i1, i2);
}

static half4 topoGyroid(float4 pos, TopoGyroidIn u) {
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;

    // Upstream's slow orbit, with a longer lens: the march spans +-45 units
    // around the origin, the axis the lattice twists about.
    const float camDist = 110.0;
    const float focal = 2.2;
    float mx = u.seed * TWO_PI + time * 0.01;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.25 + 0.15;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * camDist;

    float3 camVec = normalize(-camPos);
    float3 sideNorm = normalize(cross(float3(0.0, 1.0, 0.0), camVec));
    lerpOrbit(u.yaw, u.pitch, float3(0.0), float3(0.0, 1.0, 0.0), camPos, sideNorm, camVec);
    float3 upNorm = cross(camVec, sideNorm);
    float3 relVec = normalize(camVec * focal + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm);

    // Surface blend: `surface` places it on the cycle, `morph` lets time
    // carry it round, dwelling on each family before moving on.
    float m = time * 0.02 + u.seed * 4.0;
    m = floor(m) + smoothstep(0.2, 0.8, fract(m));

    TgyFrame f;
    f.w = tgyWeights(u.surface + u.morph * m);
    f.k = 0.1 * u.scale * (1.0 + 0.12 * sin(time * 0.031 + u.seed * 5.0));
    f.twistRate = u.twist * 0.035 * (1.0 + 0.5 * sin(time * 0.043 + u.seed * 9.0));
    f.spin = time * 0.015;
    f.warpAmp = u.warp * 5.0;
    f.warpPhase = time * 0.04;
    float3 partnerOffset = float3(u.seed * 31.0, time * 0.05, u.seed * 17.0 - time * 0.03);
    f.so = sin(partnerOffset);
    f.co = cos(partnerOffset);

    const float t0 = camDist - 45.0;
    const float maxDepth = camDist + 45.0;
    const float e = 0.004;    // sheet thickness (field units)
    const float r2 = 0.006 * 0.006; // filament radius^2 (field units)
    float bandK = u.bands * PI;
    float dt = (maxDepth - t0) / float(u.steps);
    float t = t0;
    float3 ws = sin(tgyWarpArg(camPos + relVec * t, f));
    float3 wc = cos(tgyWarpArg(camPos + relVec * t, f));
    float3 wStep = relVec.zxy * (0.06 * dt);
    float3 sStep = sin(wStep), cStep = cos(wStep);
    float2 ab0 = tgyField(camPos + relVec * t, ws, f) * 0.3;
    if (bandK > 0.0) ab0.y = sin(ab0.y * bandK) / bandK;
    float3 glow = float3(0.0);
    for (int i = 0; i < u.steps; i++) {
        t += dt;
        float3 wsNext = ws * cStep + wc * sStep;
        wc = wc * cStep - ws * sStep;
        ws = wsNext;
        float2 ab1 = tgyField(camPos + relVec * t, ws, f) * 0.3;
        // Iso-bands: b = k / bands for every integer k, not just b = 0.
        if (bandK > 0.0) ab1.y = sin(ab1.y * bandK) / bandK;
        // Fade in past the near clip, out with depth; tint toward the
        // partner colour with depth.
        float depth = t - 0.5 * dt - t0;
        float fade = smoothstep(0.0, 14.0, depth) * exp(-depth * 0.02) * dt;
        float3 tint = mix(u.color.rgb, u.accent.rgb, smoothstep(10.0, 80.0, depth));
        // Upstream's 0.1/|a^2 b| glow, made exact: filaments along the
        // curves where surface a meets surface b, and a faint membrane on a.
        float2 tube = tgyTube(ab0, ab1, r2);
        float sheet = u.membrane > 0.0 ? tgySegment(ab0.x, ab1.x, e, 1.0) : 0.0;
        float core = tube.y * r2;
        glow += (tint * (core * 0.03 + tube.x * 0.001) + core * 0.003
               + u.accent.rgb * sheet * u.membrane * 0.0002) * fade;
        ab0 = ab1;
    }

    // Upstream's sqrt "gamma correction".
    float3 color = sqrt(clamp(glow * u.gain, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}

// ============================================================================
// Form source: was Sources/Shaders/topologica-4d.metal
// ============================================================================
// Topologica 4D — a remix of "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21), CC0 1.0:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   To the extent possible under law, the author(s) have dedicated all
//   copyright and related and neighboring rights to this software to the
//   public domain worldwide. This software is distributed without any
//   warranty.
//   -Otavio Good
//
// Kept from Topologica: the slowly orbiting camera and its framing, the
// additive glow along each ray, and the colour curve — a glow colour scaled
// past 1.0 and clamped per channel, so cores burn from blue through cyan to
// white — with its sqrt "gamma". New here: the glowing structure is no longer
// noise but four-dimensional geometry, written for this file.
//
//   mode 0  Tesseractic honeycomb. The edges of Z^4 (every axis-parallel line
//           through an integer point) cut by a 3D hyperplane that tilts in
//           two 4D planes and drifts along its normal. An edge glows where it
//           passes within `slab` of the hyperplane, so the edges lying nearly
//           in the slice show as filaments in patches that come and go,
//           split and reconnect as the slice moves; the edges piercing it are
//           the faint nodes in between.
//   mode 1  24-cell honeycomb {3,4,3,3}, the Voronoi tessellation of the D4
//           lattice, cut the same way. Its edges (axis edges and the
//           (1,0,0,0)-(1/2,1/2,1/2,1/2) diagonals of every 24-cell) also run
//           on whole straight lines.
//   mode 2  Hopf fibration. Great circles of S^3 on nested tori — the fibres
//           over rings of latitude of the base S^2, as dense on every torus as
//           on the Clifford torus — stereographically projected to R^3:
//           linked Villarceau circles. S^3 turns slowly in two planes that mix
//           its two complex coordinates, carrying fibres through the
//           projection pole, so circles swell into lines through infinity and
//           come back.
//   mode 3  Torus-knot weave. (knotP, knotQ) torus knots on the same nested
//           tori (the curves q*alpha - p*beta = const), each linked with its
//           neighbours in and out, under the same rotation of S^3. `fibers`
//           above 1 draws that many parallel copies on each torus: a torus
//           link.
//
// Rendering. Topologica marches a fixed stride and lets coarse samples of a
// singular density draw its contours. Here the march only has to find the
// lines and curves passing near each ray; each one found adds its glow along
// the whole ray in closed form (`t4dGlow`), so filaments a fraction of a pixel
// wide are drawn whole and unaliased, whichever sample finds them.
// - Lattices: every edge line is an axis line through the integer points of
//   some frame (the 24-cell's in three frames, related by D4's triality), so
//   per family the nearest line is a rounding, the ray-line integral is exact
//   and a fixed stride of 0.6 cells finds every line that can show.
// - Curves of S^3: the march steps by distance. For each curve passed, the
//   nearest sample's tangent line (derivative and tangent pulled back through
//   the stereographic projection) predicts the closest approach, one more
//   look there measures it, and that measurement sets the glow.
//
// Parameters: `slab`, `cells`, `tilt` and `drift` shape the lattices;
// `rings`, `fibers`, `knotP` and `knotQ` the curves; `turn` sets the pace of
// the 4D rotation in both. All are added by this remix except `color`,
// `speed`, `gain` and `steps`, which keep Topologica's port's meanings (gain
// rescaled to the new glow, steps now counting lattice strides).
//
// GPU cost at 3840x2160 on an M5 (`LerpPreview --bench --looks`), against
// 16 ms for topologica in the same runs: tesseract 7 ms, 24-cell 11 ms,
// torus knots 12 ms, Hopf 15 ms.
//
// `seed` picks the lattice's 3D orientation (and so the planes the two tilts
// turn in), the lattice offset, the phases of the tilts and of the S^3
// rotation, and the starting orbit.
//

constant float T4D_HALF_PI = 1.57079632679;

static float2 t4dTurn(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Glow of one line along the ray, in closed form: the integral over
// y in [y0, y0 + L] of w^3 / (d^2 + w^2)^2, where the squared distance to the
// line is b2 + A y^2 (y measured from the ray's closest approach). A full
// perpendicular crossing at b = 0 gives pi/2 whatever the width, so `gain`
// reads the same at any width; across a line the profile falls as 1/b^3,
// which keeps the space between lines dark.
static float t4dGlow(float b2, float A, float y0, float L, float w) {
    float B = b2 + w * w;
    float sAB = sqrt(A * B);
    float y1 = y0 + L;
    float F1 = y1 / (A * y1 * y1 + B) + atan(y1 * A / sAB) / sAB;
    float F0 = y0 / (A * y0 * y0 + B) + atan(y0 * A / sAB) / sAB;
    return (F1 - F0) * w * w * w / (2.0 * B);
}

// ---- Lattice slices -------------------------------------------------------

// The linear part of the slice: slice coordinates (x, y, z, w-offset) to
// lattice coordinates. A seeded 3D orientation, then the two tilts, which
// turn the slice in the (x,w) and (y,w) planes.
static float4 t4dSliceMap(float4 v, float3 ang) {
    v.xz = t4dTurn(v.xz, ang.z);
    v.yz = t4dTurn(v.yz, ang.z * 1.618 + 0.7);
    v.xw = t4dTurn(v.xw, ang.x);
    v.yw = t4dTurn(v.yw, ang.y);
    return v;
}

// One frame of axis-parallel lines through the integer points, as four
// families, one per axis, handled side by side in the lanes of a float4.
// `dir` and `nrm` are the ray and the slice normal in this frame; what
// depends only on them is worked out once per pixel.
struct T4DFrame {
    float4 dir;
    float4 nrm;
    float4 invA;     // 1 / (ray speed across each family)^2
    float4 dirN;     // dir * nrm
    float4 weight;   // edges piercing the slice steeply show only as nodes
    float4 last;     // the rounded sample of the last step
};

static T4DFrame t4dFrame(float4 dir, float4 nrm) {
    T4DFrame fr;
    fr.dir = dir;
    fr.nrm = nrm;
    fr.invA = 1.0 / max(1.0 - dir * dir, 0.02);
    fr.dirN = dir * nrm;
    float4 inSlice = 1.0 - nrm * nrm;
    fr.weight = inSlice * inSlice;
    fr.last = float4(1e6);
    return fr;
}

// One line's glow, its fade with depth and its presence in the slab.
static float3 t4dLine(float b3, float A, float h, float tcl, float weight, float tint,
                      float maxC, float w, float slab2, float3 c1, float3 c2) {
    float g = t4dGlow(max(b3, 0.0), A, -tcl, maxC, w);
    float depth = clamp(tcl, 0.0, maxC);
    float fade = 1.0 - depth / maxC;
    fade *= fade * smoothstep(0.1, 1.5, depth);
    return mix(c1, c2, tint) * (g * fade * weight * exp(-h * h / slab2));
}

// Within a family the nearest line is just the rounded other three
// coordinates, and along a ray that rounding only ever moves on, so a line is
// met over one unbroken run of samples: the first sample of the run adds the
// line's glow along the whole ray, in closed form, and the rest of the run
// sees the same rounding and adds nothing. Every quantity used belongs to the
// line and the ray, not to the sample, so every sample of the run would
// compute the same glow and the picture has no seams.
static float3 t4dFamilies(float4 y, thread T4DFrame& fr, float tc,
                          float maxC, float w, float slab2, float3 c1, float3 c2) {
    float4 r = round(y);
    float4 f = y - r;
    // Family i has moved to a new line when any coordinate but the i-th
    // rounds differently from the last step.
    float4 moved = select(float4(0.0), float4(1.0), r != fr.last);
    float4 newLine = (moved.x + moved.y + moved.z + moved.w) - moved;
    fr.last = r;

    float4 od = dot(f, fr.dir) - f * fr.dir;
    float4 s = od * fr.invA;                    // sample minus closest approach
    float4 b2 = (dot(f, f) - f * f) - od * s;   // squared 4D miss distance
    // Height of the line above the slice where it passes the ray, and the
    // miss distance within the slice.
    float4 h = (dot(f, fr.nrm) - f * fr.nrm) + s * fr.dirN;
    float4 b3 = b2 - h * h;
    // Skip lines too far off (15 widths in the slice, 2.5 slab heights off
    // it) to add more than a faint trace.
    bool4 fresh = (newLine > 0.5) & (b3 < 225.0 * w * w) & (h * h < 6.25 * slab2) & (fr.weight > 0.02);

    float3 acc = float3(0.0);
    if (any(fresh)) {
        float4 A = 1.0 / fr.invA;
        float4 tcl = tc - s;
        // Dichroic tint: how end-on the ray sees the family.
        float4 tint = abs(fr.dir);
        if (fresh.x) acc += t4dLine(b3.x, A.x, h.x, tcl.x, fr.weight.x, tint.x, maxC, w, slab2, c1, c2);
        if (fresh.y) acc += t4dLine(b3.y, A.y, h.y, tcl.y, fr.weight.y, tint.y, maxC, w, slab2, c1, c2);
        if (fresh.z) acc += t4dLine(b3.z, A.z, h.z, tcl.z, fr.weight.z, tint.z, maxC, w, slab2, c1, c2);
        if (fresh.w) acc += t4dLine(b3.w, A.w, h.w, tcl.w, fr.weight.w, tint.w, maxC, w, slab2, c1, c2);
    }
    return acc;
}

// The orthogonal (and symmetric, so self-inverse) map that takes the four
// mutually orthogonal diagonals (1/2)(+-1,+-1,+-1,+-1) with an even number of
// minus signs onto the coordinate axes. It preserves D4 and carries the
// 24-cell honeycomb's even diagonal edge lines onto the axis lines through
// the half-integer points.
static float4 t4dHad(float4 v) {
    return 0.5 * float4(v.x + v.y + v.z + v.w, v.x + v.y - v.z - v.w,
                        v.x - v.y + v.z - v.w, v.x - v.y - v.z + v.w);
}

// ---- Curves on the nested tori of S^3 ---------------------------------------

static float2 t4dCmul(float2 a, float2 b) {
    return float2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x);
}

// One 4D rotation of S^3, applied to a column. Two seeded fixed turns, then
// the time-varying pair in (0,2) and (1,3) — planes that mix z1 = (x0, x1)
// with z2 = (x2, x3), so curves are carried from torus to torus.
static float4 t4dS3Turn(float4 v, float4 ang) {
    v.xw = t4dTurn(v.xw, ang.z);
    v.yz = t4dTurn(v.yz, ang.w);
    v.xz = t4dTurn(v.xz, ang.x);
    v.yw = t4dTurn(v.yw, ang.y);
    return v;
}

struct T4DCurve {
    float d;      // S^3 distance to the nearest drawn curve
    float id;     // which curve: torus * 64 + copy
    float hue;    // colour phase of that curve
    float dE;     // distance across tori
    float dTg;    // distance along the torus, over |grad psi|
    float safe;   // no drawn curve on any torus is nearer than this
};

// x on S^3, torus coordinates |z1| = cos(eta), |z2| = sin(eta). A (p, q)
// curve on a torus is q*alpha - p*beta = const (the Hopf fibres are the
// (1, 1) curves); psi = arg(z1^q * conj(z2)^p) is that phase without two
// separate angles. Distance: across tori in eta, along the torus in psi
// over |grad psi|.
static T4DCurve t4dTori(float4 x, int P, int Q, int K, int F, bool hopf, float phase) {
    float r1 = max(length(x.xy), 1e-5), r2 = max(length(x.zw), 1e-5);
    float eta = atan2(r2, r1);
    float fk = float(K);
    float k = clamp(floor(eta / T4D_HALF_PI * fk), 0.0, fk - 1.0);
    float etaK = (k + 0.5) * T4D_HALF_PI / fk;

    float2 u1 = x.xy / r1;
    float2 u2 = float2(x.z, -x.w) / r2;
    float2 c = float2(1.0, 0.0);
    for (int i = 0; i < Q; i++) c = t4dCmul(c, u1);
    for (int i = 0; i < P; i++) c = t4dCmul(c, u2);
    float psi = atan2(c.y, c.x);

    float pf = float(P), qf = float(Q);
    float se = sin(etaK), ce = cos(etaK);
    float n = hopf ? max(1.0, round(float(F) * 2.0 * se * ce)) : float(F);
    float sp = (psi - phase - k * 0.9) * n / TWO_PI;
    float j = round(sp);
    float dPsi = (sp - j) * TWO_PI / n;
    float gradPsi = sqrt(qf * qf * se * se + pf * pf * ce * ce) / (se * ce);
    float dT = dPsi / gradPsi;
    float dE = eta - etaK;

    T4DCurve cv;
    cv.d = sqrt(dE * dE + dT * dT);
    float jm = glmod(j, n);
    cv.id = k * 64.0 + jm;
    cv.hue = TWO_PI * jm / n + k * 1.7;
    cv.dE = dE;
    cv.dTg = dT / gradPsi;
    // Curves on the next torus out or in are at least their torus's eta
    // away, which can be nearer than this torus's own curve when that one
    // is sparse (a single knot); stepping must respect both.
    cv.safe = min(cv.d, T4D_HALF_PI / fk - abs(dE));
    return cv;
}

// Half the gradient of d^2 on S^3 at x, for the curve `cv` found there.
static float4 t4dToriGrad(float4 x, T4DCurve cv, int P, int Q) {
    float r1s = max(dot(x.xy, x.xy), 1e-10), r2s = max(dot(x.zw, x.zw), 1e-10);
    float q12 = sqrt(r2s / r1s);
    float4 gEta = float4(-q12 * x.xy, x.zw / q12);
    float4 gPsi = float4(float(Q) * float2(-x.y, x.x) / r1s, -float(P) * float2(-x.w, x.z) / r2s);
    return cv.dE * gEta + cv.dTg * gPsi;
}

// What the S^3 march holds fixed across a pixel.
struct T4DS3 {
    float4 m0, m1, m2, m3;  // columns of the rotation of S^3
    int P, Q, K, F;
    bool hopf;
    float phase;
};

// What the S^3 march knows about one point of the ray.
struct T4DSample {
    T4DCurve cv;
    float3 p;               // the point, in R^3
    float4 x;               // the point on S^3, rotated
    float dR;               // distance to the curve, R^3 units
    float cf;               // R^3 length per S^3 length
    float s;                // ray parameter minus predicted closest approach
    float b2;               // predicted squared miss distance
    float A;                // squared ray speed across the curve
};

static T4DSample t4dLook(float3 ro, float3 rd, float t, thread const T4DS3& g) {
    T4DSample sm;
    sm.p = ro + rd * t;
    float pp = dot(sm.p, sm.p);
    float inv = 1.0 / (1.0 + pp);
    float4 x0 = float4(2.0 * sm.p * inv, (pp - 1.0) * inv);
    sm.x = g.m0 * x0.x + g.m1 * x0.y + g.m2 * x0.z + g.m3 * x0.w;
    sm.cv = t4dTori(sm.x, g.P, g.Q, g.K, g.F, g.hopf, g.phase);
    sm.cf = 0.5 * (1.0 + pp);
    sm.dR = sm.cv.d * sm.cf;
    sm.s = 0.0;
    sm.A = 1.0;
    sm.b2 = sm.dR * sm.dR;
    return sm;
}

// The closest approach the curve's tangent line predicts, which only the best
// sample of each curve needs.
static void t4dPredict(thread T4DSample& sm, float3 rd, thread const T4DS3& g) {
    float3 p = sm.p;
    float4 x = sm.x;
    float pp = dot(p, p);
    float inv = 1.0 / (1.0 + pp);
    // d(x)/dt along the ray, pushed through the rotation.
    float pr = dot(p, rd);
    float4 dx0 = float4(2.0 * inv * (rd - 2.0 * pr * inv * p), 4.0 * pr * inv * inv);
    float4 dx = g.m0 * dx0.x + g.m1 * dx0.y + g.m2 * dx0.z + g.m3 * dx0.w;
    // The curve's tangent, pulled back to R^3.
    float4 tang = float4(float(g.P) * float2(-x.y, x.x), float(g.Q) * float2(-x.w, x.z));
    float4 tg = float4(dot(g.m0, tang), dot(g.m1, tang), dot(g.m2, tang), dot(g.m3, tang));
    float3 T3 = normalize(tg.xyz + p * tg.w);
    float ct = dot(T3, rd);
    sm.A = max(1.0 - ct * ct, 0.1);
    // d(dR^2)/dt, dR = d * cf: both factors change along the ray.
    float slope = 2.0 * sm.cf * (sm.cf * dot(t4dToriGrad(x, sm.cv, g.P, g.Q), dx) + sm.cv.d * sm.cv.d * pr);
    sm.s = slope / (2.0 * sm.A);
    // The tangent line's prediction, but no nearer than distance can shrink
    // (at most 1:1 along the ray) on the way to the predicted point.
    float near = max(sm.dR - abs(sm.s), 0.0);
    sm.b2 = max(sm.dR * sm.dR - sm.A * sm.s * sm.s, near * near);
}

// The glow of a sample's curve along the whole ray.
static float3 t4dCurveGlow(T4DSample sm, float t, float maxDepth, float w, float3 c1, float3 c2) {
    float tClose = t - sm.s;
    float fade = 1.0 - clamp(tClose, 0.0, maxDepth) / maxDepth;
    // A tube of constant S^3 width swells with cf in R^3; let it swell by
    // sqrt(cf) only and dim by cf, so the vast outer circles stay a fine
    // backdrop to the core.
    float g = t4dGlow(sm.b2, sm.A, -tClose, maxDepth, w * sqrt(sm.cf)) / sm.cf;
    return mix(c1, c2, 0.5 + 0.5 * cos(sm.cv.hue)) * (g * fade * fade);
}

static half4 topo4D(float4 pos, Topo4DIn u) {
    // Topologica's camera: uv in [-1, 1], y up, a slow orbit about the origin.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;
    bool lattice = u.mode < 2;

    float mx = u.seed * TWO_PI + time * 0.02;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.2 + 0.2;
    float camDist = lattice ? 5.0 : 2.6;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * camDist;

    float3 camVec = normalize(-camPos);
    float3 sideNorm = normalize(cross(float3(0.0, 1.0, 0.0), camVec));
    lerpOrbit(u.yaw, u.pitch, float3(0.0), float3(0.0, 1.0, 0.0), camPos, sideNorm, camVec);
    float3 upNorm = cross(camVec, sideNorm);
    float3 rd = normalize(camVec + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm);

    float3 c1 = u.color.rgb;
    float3 c2 = mix(c1, u.color2.rgb, u.dichroic);
    float3 acc = float3(0.0);
    int steps = u.steps;
    float rt = time * u.turn;

    if (lattice) {
        // Slice -> lattice is affine, so each ray is a straight line in 4D.
        float3 ang = float3(u.tilt * sin(rt * 0.031 + u.seed * 41.0),
                            u.tilt * cos(rt * 0.019 + u.seed * 23.0),
                            u.seed * 9.7);
        // The drift moves the lattice along its w axis, nearly the slice
        // normal; (0,0,0,2) is a symmetry of both lattices, so wrap it there
        // and the coordinates stay small however long the saver runs.
        float drift = glmod(time * u.drift * 0.06 + u.seed * 5.0, 2.0);
        float4 shift = float4(hash11(u.seed * 31.0), hash11(u.seed * 57.0),
                              hash11(u.seed * 77.0), drift);
        float4 q0 = t4dSliceMap(float4(camPos * u.cells, 0.0), ang) + shift;
        float4 dir = t4dSliceMap(float4(rd, 0.0), ang);
        float4 nrm = t4dSliceMap(float4(0.0, 0.0, 0.0, 1.0), ang);
        float slab2 = u.slab * u.slab;
        // A fixed stride of 0.6 cells. A family's lines own unit cubes of its
        // other three coordinates, so any line passing within 0.4 cells of
        // the ray (as close as a line can and still show) owns a run of it
        // at least 0.6 long and cannot be stepped over. The 24-cell, with
        // three times the lines, marches half as deep.
        const float stepC = 0.6;
        int n = u.mode == 0 ? steps : steps / 2;
        float maxC = stepC * float(n);           // depth, in cells
        // 24-cell honeycomb: its edges are the axis lines through the
        // half-integer points (the tesseract's, shifted) in three frames —
        // the axes, the even diagonals (t4dHad) and the odd diagonals (t4dHad
        // after flipping w). The D4 lattice's triality, in one line each.
        float4 flip = float4(1.0, 1.0, 1.0, -1.0);
        T4DFrame f0 = t4dFrame(dir, nrm);
        T4DFrame f1 = t4dFrame(t4dHad(dir), t4dHad(nrm));
        T4DFrame f2 = t4dFrame(t4dHad(dir * flip), t4dHad(nrm * flip));
        float w = u.width;
        for (int i = 0; i < n; i++) {
            float tc = float(i) * stepC;
            float4 q = q0 + tc * dir;
            if (u.mode == 0) {
                acc += t4dFamilies(q, f0, tc, maxC, w, slab2, c1, c2);
            } else {
                acc += t4dFamilies(q - 0.5, f0, tc, maxC, w, slab2, c1, c2);
                acc += t4dFamilies(t4dHad(q) - 0.5, f1, tc, maxC, w, slab2, c1, c2);
                acc += t4dFamilies(t4dHad(q * flip) - 0.5, f2, tc, maxC, w, slab2, c1, c2);
            }
        }
    } else {
        float4 ang = float4(rt * 0.043 + u.seed * 11.0, rt * 0.029 + u.seed * 29.0,
                            u.seed * 7.3, u.seed * 13.1);
        T4DS3 g;
        // Columns of the rotation, built once per pixel.
        g.m0 = t4dS3Turn(float4(1, 0, 0, 0), ang);
        g.m1 = t4dS3Turn(float4(0, 1, 0, 0), ang);
        g.m2 = t4dS3Turn(float4(0, 0, 1, 0), ang);
        g.m3 = t4dS3Turn(float4(0, 0, 0, 1), ang);
        g.hopf = u.mode == 2;
        g.P = g.hopf ? 1 : u.knotP;
        g.Q = g.hopf ? 1 : u.knotQ;
        g.K = u.rings;
        g.F = u.fibers;
        g.phase = rt * 0.05;
        const float maxDepth = 7.0;
        // The curves take a quarter more samples than the lattices: each is
        // found by distance, not by a fixed stride.
        int n = (steps * 5) / 4;
        float minStep = maxDepth / float(n) * 0.5;
        // The curve being passed: its best sample so far, and that sample's
        // ray parameter and step.
        T4DSample best;
        float bestT = 0.0, bestL = 0.0;
        bool have = false;
        // Distance to the current curve at the last sample, and whether it
        // has started growing: if it then shrinks again the ray is coming up
        // on another strand of the same curve (a knot passes a point many
        // times), which is a new pass with its own glow.
        float prevD = 0.0;
        bool rising = false;
        float t = 0.0;
        for (int i = 0; i <= n; i++) {
            bool done = i == n || t > maxDepth;
            T4DSample sm;
            if (!done) sm = t4dLook(camPos, rd, t, g);
            bool newPass = false;
            if (have && !done && sm.cv.id == best.cv.id) {
                if (sm.dR > prevD * 1.02) rising = true;
                else if (rising && sm.dR < prevD * 0.98) newPass = true;
            }
            if (have && (done || newPass || sm.cv.id != best.cv.id)) {
                // A curve no sample came within 24 tube widths of adds too
                // little to look at again (the samples step by distance, so
                // none passes a curve much nearer than its nearest sample).
                float far = 24.0 * u.width * sqrt(best.cf);
                if (best.dR < far) {
                    // Leaving a curve: look once more where its best sample
                    // put the closest approach, and keep that if it is nearer.
                    // Each curve's glow then comes from a sample right at its
                    // closest approach, so neighbouring pixels agree.
                    t4dPredict(best, rd, g);
                    float t2 = max(clamp(bestT - best.s, bestT - 1.5 * bestL, bestT + 1.5 * bestL), 0.0);
                    T4DSample r = t4dLook(camPos, rd, t2, g);
                    if (r.cv.id == best.cv.id && r.dR < best.dR) {
                        // There, the measured distance is the miss distance.
                        r.A = best.A;
                        best = r;
                        bestT = t2;
                    }
                    // A prediction the second look did not bear out (the
                    // curve was not there) cannot claim a miss much nearer
                    // than any distance actually measured.
                    float seen = best.dR * 0.5;
                    best.b2 = max(best.b2, seen * seen);
                    acc += t4dCurveGlow(best, bestT, maxDepth, u.width, c1, c2)
                         * smoothstep(far, 0.6 * far, best.dR);
                }
                have = false;
            }
            if (done) break;
            float L = max(0.75 * sm.cv.safe * sm.cf, minStep);
            if (!have || sm.dR < best.dR) {
                best = sm;
                bestT = t;
                bestL = L;
                if (!have) rising = false;
                have = true;
            }
            prevD = sm.dR;
            t += L;
        }
    }
    // Topologica's finish: clamp per channel, then its sqrt "gamma".
    float3 color = sqrt(clamp(acc * u.gain / 100.0, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}

// ============================================================================
// Dispatch
// ============================================================================

static int topoSteps(float base, float detail) {
    return max(int(round(base * detail)), 2);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    int form = clamp(u.form, 0, 9);
    if (form == 0) {
        TopoClassicIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.yaw = u.yaw; s.pitch = u.pitch;
        s.color = u.color; s.speed = u.speed;
        s.gain = 0.02 * u.gain;
        s.steps = topoSteps(16.0, u.detail);
        return topoClassic(pos, s);
    }
    if (form <= 3) {
        TopoFractalIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.yaw = u.yaw; s.pitch = u.pitch;
        s.color = u.color; s.speed = u.speed;
        s.wire = form - 1;
        s.zoom = 1.5;
        s.gain = u.gain;
        s.tilt = form == 2 ? 0.7 : form == 3 ? 0.3 : 0.5;
        s.bloom = 0.5;
        s.steps = topoSteps(form == 3 ? 6.0 : 7.0, u.detail);
        return topoFractal(pos, s);
    }
    if (form <= 5) {
        TopoGyroidIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.yaw = u.yaw; s.pitch = u.pitch;
        s.color = u.color; s.accent = u.accent; s.speed = u.speed;
        s.gain = 0.02 * u.gain;
        s.steps = topoSteps(10.0, u.detail);
        s.surface = 0.0; s.morph = 1.0; s.scale = 1.0;
        s.twist = form == 5 ? 0.8 : 0.5;
        s.warp = mix(0.25, 0.6, u.morph);
        s.membrane = 0.15;
        s.bands = form == 5 ? 1.5 : 0.0;
        return topoGyroid(pos, s);
    }
    Topo4DIn s;
    s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
    s.yaw = u.yaw; s.pitch = u.pitch;
    s.mode = form - 6;
    s.color = u.color; s.color2 = u.accent; s.dichroic = 1.0;
    s.speed = u.speed;
    s.gain = 800.0 * u.gain;
    s.width = 0.006;
    s.slab = mix(0.1, 0.22, u.morph);
    s.cells = 1.0; s.tilt = 0.45; s.drift = 0.3; s.turn = 1.0;
    s.rings = 4;
    s.fibers = form == 9 ? 1 : 8;
    s.knotP = 2; s.knotQ = 3;
    s.steps = topoSteps(16.0, u.detail);
    return topo4D(pos, s);
}
