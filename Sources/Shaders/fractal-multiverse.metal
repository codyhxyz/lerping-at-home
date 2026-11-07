
// Fractal Multiverse — Yohei Nishitsuji's "fractal, the multiverse" and this
// project's three originals in its idiom, as one look with a `form` setting.
//
// The port (form 0, the default look) is MIT, Copyright (c) 2026
// @YoheiNishitsuji; its full notice is in its section below and in
// NOTICE.txt. Forms 1-3 are original work for Lerping@Home (AGPL-3.0).
//
// Forms (each section below keeps its original notes):
//   0 Multiverse  the faithful port
//   1 Cathedral   a negative-scale Mandelbox, mirrored like a nave
//   2 Coral       the sphere-inversion Apollonian packing
//   3 Lattice     a four-dimensional KIFS with a double rotation
//
// These were four shaders built on one technique (a short fixed march
// through a slab of fractal space, lit by each sample's orbit), so one
// shader with a form setting keeps all four and drops the repeated looks.
// Each form's drawing function now returns its colour before dithering, so
// the dispatch can supersample; Coral's lace is prefiltered (below).
// The playground cannot hide a setting a form ignores, so the settings are
// the ones every form shares, scaled to each form's own defaults:
//   zoom       multiplies the form's own zoom (port 1, Cathedral 1.3,
//              Coral 1.6, Lattice 1)
//   sharpness  multiplies Cathedral's tracery (42), Coral's lace (1500) and
//              Lattice's facets (80)
//   morph      the slow drift each original form had on its own parameter:
//              0..1 spans Cathedral's fold scale -1.9..-1.72, Coral's
//              inversion 1.08..1.24 and Lattice's twist 0.28..0.52, and
//              values outside 0..1 carry on past those ends
//   near, mid, far  depth colours (Cathedral and Coral use near and far)
// The port ignores everything but speed, zoom and glow; zoom and glow are
// identity at their defaults, and its speed is a fifth of upstream's (below).
//
// Sparkle: the port and Coral put more fractal detail into a pixel than one
// sample can hold (the port's inversions leave isolated white pixels and a
// frost that reshuffles every frame; Coral's lace is ~0.7 px wide at
// 1352x878 and its pearl clusters are sub-pixel), so those two forms take
// two samples on the pixel's diagonal. Each sample is clamped before the
// two are averaged, so a firefly is averaged as the screen would show it,
// not as an unbounded linear value. Coral's lace is also prefiltered: its
// width is widened by the sample's footprint and dimmed by the same ratio
// (see mcoCoral). Cathedral and Lattice render within ~0.003 mean of a
// 16-sample reference at one sample, so they stay at one.
// Measured at 1352x878 (mean |frame(t-dt) - 2 frame(t) + frame(t+dt)| at
// dt = 1/60, t = 20, 75, 140; reference = 16 samples a pixel), before the
// port's clock was slowed and Coral's forward drift became a sideways pan
// (see their sections), so the port and Coral now move less per frame:
//   Upstream  0.0964 -> 0.0862 (reference 0.0775); 0.0162 -> 0.0106 off it
//   port      0.0409 -> 0.0343 (reference 0.0263); 0.0132 -> 0.0088 off it
//   Coral     0.0160 -> 0.0102 (reference 0.0093); 0.0052 -> 0.0053 off it,
//             the lace a touch softer than the reference, 2% dimmer
// Most of what is left in the port is the fractal's own frost, which the
// 16-sample reference shows too, carried along at ~3 px a frame.
// (Tried and rejected: a per-step soft cap on the port's glow, which cut
// flicker a little more but darkened the frame 4-11%, and an fwidth-based
// prefilter on Cathedral's tracery, which made quad-sized blocks flicker.)
//
// GPU cost: the form is a uniform branch, so a frame costs what its form
// always cost per sample (~9 ms at 3840x2160 on an M5, every form). Two
// samples double it: LerpPreview --bench at 2704x1756, Apple M5, under
// load from other jobs: ~5.5 ms a sample, so the port, Upstream and Coral
// read ~11 ms mean and ~12.3-12.8 p95, Cathedral and Lattice ~5.5.
//
// lerp-category: Fractals
// lerp-param: form      int   0 3       = 0     "Form"
// lerp-param: speed     float 0 2.5     = 0.5   "Speed"
// lerp-param: morph     float -1 2      = 0.5   "Morph"
// lerp-animate: morph 0 1 period=210
// lerp-param: glow      float 0.2 3     = 1.0   "Glow"
// lerp-param: zoom      float 0.4 2     = 1.0   "Zoom"
// lerp-param: sharpness float 0.4 2.5   = 1.0   "Sharpness"
// lerp-param: near      color           = (0.90, 0.98, 1.0)  "Near colour"
// lerp-param: mid       color           = (0.25, 0.85, 1.0)  "Middle colour"
// lerp-param: far       color           = (1.0, 0.70, 0.25)  "Far colour"
//
// lerp-preset: Upstream  speed=2.5
// lerp-preset: Cathedral form=1, near=(1.0, 0.70, 0.36), far=(0.92, 0.27, 0.42)
// lerp-preset: Coral     form=2, near=(0.12, 0.95, 0.78), far=(0.52, 0.24, 1.0)
// lerp-preset: Lattice   form=3

// What each form's drawing function reads as `u`: the frame's header fields
// and that form's own settings, filled in by lerpMain at the bottom.
struct MvPortIn {
    float2 resolution;
    float time;
    float seed;
    float speed;
};
struct MvCathedralIn {
    float2 resolution;
    float time;
    float seed;
    float speed; float foldScale; float tracery; float glow; float zoom;
    float4 near; float4 far;
};
struct MvCoralIn {
    float2 resolution;
    float time;
    float seed;
    float speed; float inversion; float lace; float pearls; float glow;
    float zoom; float footprint; float4 near; float4 far;
};
struct MvLatticeIn {
    float2 resolution;
    float time;
    float seed;
    float speed; float twist; float facets; float frost; float glow;
    float zoom; float4 ice; float4 cyan; float4 gold;
};

// ============================================================================
// Form source: was Sources/Shaders/fractal-multiverse.metal
// ============================================================================
// Fractal Multiverse — ported from "fractal, the multiverse" by Yohei Nishitsuji (MIT)
// https://fragcoord.xyz/s/ftisi70e
// Copyright (c) 2026 @YoheiNishitsuji. SPDX-License-Identifier: MIT
// Licence statement: the source carries "SPDX-License-Identifier: MIT /
// Copyright (c) 2026 @YoheiNishitsuji", FragCoord lists it as MIT, and the
// author's X profile (https://x.com/YoheiNishitsuji) reads "My code shared @x
// is MIT Licensed". Full MIT text: https://opensource.org/licenses/MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions: The above copyright
// notice and this permission notice shall be included in all copies or
// substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
// WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
//
// One of the author's #つぶやきGLSL fractals, from the readable version he
// published on FragCoord. An orthographic 18-step march along z through a
// spherical-inversion / box-fold fractal: each sample is rotated by a slowly
// tumbling 3D rotation, folded 9 times (scale by max(0.95, 9/|p|^2), then
// mirror with abs() against a fixed offset), and the accumulated fold scale
// both sets the step and lights the ray in a single cyan-blue hue whose
// saturation fades with depth. The view breathes in and out with cos(t/2).
//
// Port changes: time is slowed and offset by u.seed (house style); `speed` is
// this port's own parameter, upstream has none. The port's clock is
// 0.4 x speed, so the default 0.5 runs upstream's motion at a fifth of its
// rate and the Upstream preset's 2.5 is upstream exactly. The tumble turns
// the fractal out of the screen's plane, through a slab only 18 samples
// deep; at upstream x 0.5 (the old default, 0.25 rad/s) the sparse far
// samples swelled and vanished as the volume turned, which read as the
// distance morphing. At 0.1 rad/s a CPU model of the march shows the
// motion-compensated change over 2 s falling from 0.74 to 0.46 (a rigid
// camera orbit through castle-to-castle scores 0.84, so what is left is the
// turn itself), the zoom breathes over 63 s instead of 25 (a 3%/s peak, not
// 8%), and 41-96% of a 480x300 frame still changes in any 2 s.
//
// Upstream divides by the resolution's height; this uses the short axis so
// portrait screens see the same framing (identical on landscape). Negative
// colour is clamped. Two samples a pixel (see the note at the top of the
// file).
//
// GPU cost: 18 x 9 fold iterations per sample, no cap needed. LerpPreview
// --bench, Apple M5: ~0.95 ms/frame at 1200x750, ~8.7 ms at 3840x2160
// (between pipes and paper-texture).
//

// twigl's hsv(): hue/saturation/value to RGB.
static inline float3 fmHsv(float h, float s, float v) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(float3(h) + k.xyz) * 6.0 - k.www);
    return v * mix(float3(k.x), clamp(p - k.xxx, 0.0, 1.0), s);
}

// twigl's rotate3D(): Rodrigues rotation by `angle` about `axis`, built in
// the same column order as the GLSL mat3 constructor.
static inline float3x3 fmRotate3D(float angle, float3 axis) {
    float3 a = normalize(axis);
    float s = sin(angle), c = cos(angle), r = 1.0 - c;
    return float3x3(float3(a.x * a.x * r + c,       a.y * a.x * r + a.z * s, a.z * a.x * r - a.y * s),
                    float3(a.x * a.y * r - a.z * s, a.y * a.y * r + c,       a.z * a.y * r + a.x * s),
                    float3(a.x * a.z * r + a.y * s, a.y * a.z * r - a.x * s, a.z * a.z * r + c));
}

static float3 fmPort(float4 pos, MvPortIn u) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = 0.4 * u.speed * u.time + u.seed * 60.0; // speed 2.5 = upstream

    // Per-pixel constants hoisted out of the march (upstream rebuilds them
    // every step; the values are identical).
    float2 xy = (fc * 2.0 - r) / min(r.x, r.y) * (9.0 + cos(t * 0.5) * 3.0);
    float3x3 tumble = fmRotate3D(t * 0.5, float3(-4.0, sin(t) + 7.0, 0.0));

    float3 col = float3(0.0);
    float g = 0.0;   // distance marched along z
    for (int i = 0; i < 18; i++) {
        // Orthographic sample, rotated (GLSL p *= M: row vector times matrix).
        float3 p = float3(xy, g + 0.2) * tumble;

        // Nine folds: spherical inversion, then an abs() mirror against a
        // fixed offset. s accumulates the total scale (a distance estimate).
        float s = 1.0;
        for (int j = 0; j < 9; j++) {
            float e = max(0.95, 9.0 / dot(p, p));
            s *= e;
            p = float3(1.5, 4.0, 3.0) - abs(abs(p) * e - float3(1.0, 1.2, 3.0));
        }

        // Advance: GLSL mod(length(p.yy), p.y) / s * 0.5.
        g += glmod(length(p.yy), p.y) / s * 0.5;

        // Light: one cyan-blue hue, saturation falling with depth.
        col += fmHsv(0.59, 0.4 - g, s / 4e3);
    }

    return max(col, 0.0);
}

// ============================================================================
// Form source: was Sources/Shaders/multiverse-cathedral.metal
// ============================================================================
// Multiverse Cathedral — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, where every sample is folded a few
// times and lights the pixel by how its orbit behaves, so the picture is a
// stack of glowing cross-sections rather than a shaded surface. The fold,
// the light, the camera and the colouring here are this file's own.
//
// The fractal is Tom Lowe's Mandelbox (box fold, then sphere fold, then
// scale and add the starting point) at a negative scale, whose sections are
// full of pointed lancets, ribbed vaults and concentric rose windows. Each of
// 14 layers through the slab runs 8 folds and keeps the closest its orbit
// comes to the unit sphere: that orbit trap draws the thin tracery (a sharp
// exp falloff) over a soft haze (a broad one). The picture is mirrored about
// the vertical axis, as a nave is, and the slab glides through the box
// while it turns, so arcades open, close and re-form every few seconds.
// Near layers are amber, far layers rose, so the depth of each line is its
// colour.
//
// u.seed picks where on the route each activation begins. `foldScale`
// drifts slowly (lerp-animate), which morphs the tracery continuously.
//
// GPU cost: 14 layers x 8 folds, no trig or square root in the loop.
// LerpPreview --bench, Apple M5, 3840x2160: within about 5-10% of
// fractal-multiverse measured in the same run (~9-10 ms when it reads
// ~8.7-9.3), every look.
//

static inline float3x3 mcRotY(float a, float tilt) {
    float c = cos(a), s = sin(a), ct = cos(tilt), st = sin(tilt);
    // Yaw about y, then a fixed small pitch about x.
    float3x3 yaw = float3x3(float3(c, 0.0, -s), float3(0.0, 1.0, 0.0), float3(s, 0.0, c));
    float3x3 pitch = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, ct, st), float3(0.0, -st, ct));
    return pitch * yaw;
}

static float3 mcCathedral(float4 pos, MvCathedralIn u) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;
    uv.x = abs(uv.x);                                   // the nave's mirror

    float2 xy = uv * u.zoom * (1.0 + 0.08 * sin(0.13 * t));
    // The turn and the glide run five times faster than the zoom's breath.
    // At the old 1x pace the arcades re-formed over minutes, so on screen the
    // look read as a still, mirrored picture; at 5x they open and close
    // every few seconds while the breath stays slow.
    float m = 5.0 * t;
    float3x3 turn = mcRotY(0.05 * m, 0.12 * sin(0.041 * m));
    // The slab's route through the box: a never-repeating glide.
    float3 route = float3(0.25 * sin(0.017 * m), 0.6 * sin(0.031 * m), 1.5 * sin(0.023 * m));

    const float S = u.foldScale;
    const float minR2 = 0.09;                           // inner sphere radius 0.3

    // turn * (xy, z) + route, split so each layer only adds z * column 3.
    float3 base = turn * float3(xy, 0.0) + route;
    float3 axis = turn[2];

    float3 col = float3(0.0);
    for (int i = 0; i < 14; i++) {
        float layer = float(i) / 14.0;
        float3 p = base + axis * (2.0 * layer);
        float3 q = p;
        float trap = 1e9;
        for (int j = 0; j < 8; j++) {
            q = clamp(q, -1.0, 1.0) * 2.0 - q;          // box fold
            float r2 = dot(q, q);
            q *= clamp(1.0 / r2, 1.0, 1.0 / minR2) * S; // sphere fold, scale
            q += p;
            // Closest approach to the unit sphere (|q|^2 - 1 ~ 2(|q| - 1)
            // near it); later folds pay a little so the coarse tracery
            // wins over fine dust.
            trap = min(trap, 0.5 * abs(dot(q, q) - 1.0) + 0.01 * float(j));
        }
        float line = exp(-trap * u.tracery);
        float haze = exp(-trap * 7.0);
        float3 tint = mix(u.near.rgb, u.far.rgb, smoothstep(0.2, 0.8, layer));
        // The hottest cores of the tracery burn whiter.
        tint = mix(tint, float3(1.0, 0.9, 0.78), 0.3 * line);
        col += tint * (0.257 * line + 0.0154 * haze);
    }
    col *= u.glow;

    float3 color = 1.0 - exp(-col * 1.6);
    color += float3(0.012, 0.004, 0.008);               // a nave is never quite black
    return color;
}

// ============================================================================
// Form source: was Sources/Shaders/multiverse-coral.metal
// ============================================================================
// Multiverse Coral — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, each sample folded a few times and
// lit by how its orbit behaves, so the frame is a stack of glowing
// cross-sections rather than a shaded surface. The fold, the light, the
// camera and the colouring here are this file's own.
//
// The fractal is the sphere-inversion Apollonian packing (fold space into a
// repeating cube, invert in the unit sphere, repeat), which is periodic, so
// the slab can drift sideways forever without leaving it. Each of 14 layers
// runs 8 folds; the running inversion scale turns the final distance to the
// unit sphere into a distance in world space, so the lace stays thin at
// every depth of the packing, and the orbit's closest approach to the
// centre lights pearls of brighter, whiter glow where the inversions
// cluster. The layers spread slightly with depth (a little perspective) and
// fade from teal to violet, so the far filaments read as further down.
//
// u.seed picks where on the drift each activation begins, the slab's
// heading through the packing and which slices its layers are. `inversion`
// drifts slowly (lerp-animate), swelling and thinning the strands.
//
// Motion is in the slab's own plane only. The layers sit at fixed depths, so
// anything moving through them reshapes: the slab used to drift forward
// 0.05 t (a layer's spacing, 0.07, every ~3 s at the default speed) and to
// yaw 0.03 t out of its plane, which at the frame's edges swept the layers
// through the packing faster still, so strands thinner than a layer swelled
// and shrank instead of moving. Now the heading is fixed for the activation
// and the slab pans sideways at the old forward rate: every layer slides
// rigidly, the near ones faster (the layers spread with depth), which is
// parallax. A CPU model's motion-compensated change over 2 s falls from 0.49
// to 0.02 (the pan and the screen's own slow turn), with 54-65% of a 480x300
// frame changing per 2 s (70-79% before).
//
// GPU cost: 14 layers x 8 folds, no trig in the loop, and each layer's
// sample point is one multiply-add from a per-pixel origin and step.
// LerpPreview --bench, Apple M5, 3840x2160: within about 0-10% of
// fractal-multiverse measured in the same run (~9 ms), every look.
//

// The view: a fixed tilt of 0.7 rad about x, so the cube lattice never
// lines up with the screen, then a slow turn (cos, sin) about y.
static inline float3 mcoView(float3 v, float2 turn) {
    const float co = 0.7648, so = 0.6442;               // cos, sin of 0.7
    v.yz = float2(co * v.y - so * v.z, so * v.y + co * v.z);
    v.xz = float2(turn.x * v.x - turn.y * v.z, turn.y * v.x + turn.x * v.z);
    return v;
}

static float3 mcoCoral(float4 pos, MvCoralIn u) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;

    float2 xy = rotate(uv, 0.02 * t) * u.zoom;
    // A sideways pan across the periodic packing, with a slow sway; the
    // depth is the seed's and stays put (see the header).
    float3 drift = float3(0.3 * sin(0.05 * t) + 0.0413 * t,   // 0.05 t along 0.6 rad
                          0.2 * cos(0.04 * t) + 0.0282 * t,
                          20.0 * u.seed);
    float yaw = 0.49 + 12.0 * u.seed;
    float2 turn = float2(cos(yaw), sin(yaw));
    // Layer L samples view((xy * (1 + 0.5 L), L) + drift), which is linear
    // in L, so it is built once here as origin + L * step. The packing
    // repeats every 2 on each axis, so the drift is wrapped to that (exact)
    // to keep float precision however long the pan runs.
    float3 flat = mcoView(float3(xy, 0.0), turn);
    float3 origin = flat + (glmod3(mcoView(drift, turn) + 1.0, 2.0) - 1.0);
    float3 step = 0.5 * flat + mcoView(float3(0.0, 0.0, 1.0), turn);

    float3 col = float3(0.0);
    for (int i = 0; i < 14; i++) {
        float layer = float(i) / 14.0;
        float3 q = origin + step * layer;

        float scale = 1.0;
        float trap = 1e9;
        for (int j = 0; j < 8; j++) {
            q = -1.0 + 2.0 * fract(0.5 * q + 0.5);       // repeat the cube
            float r2 = dot(q, q);
            trap = min(trap, r2);
            float k = u.inversion / r2;                  // invert
            q *= k;
            scale *= k;
        }
        float d = 0.25 * abs(length(q) - 1.0) / scale;   // world-space lace distance
        float pearl = exp(-trap * 20.0);
        // The lace, prefiltered: its width 1/lace is widened by the sample's
        // footprint (in d's units, so 0.25 x world, and growing with the
        // layer's spread) and dimmed by the same ratio, so a strand thinner
        // than a pixel keeps its brightness on average instead of landing
        // on some pixels and missing their neighbours.
        float w = 1.0 / u.lace;
        float wf = length(float2(w, u.footprint * (1.0 + 0.5 * layer)));
        float light = (w / wf) * exp(-d / wf) * (0.3 + u.pearls * pearl);

        float3 tint = mix(u.near.rgb, u.far.rgb, smoothstep(0.1, 0.9, layer));
        tint = mix(tint, float3(0.85, 1.0, 0.96), pearl);
        col += tint * light * 0.75;
    }
    col *= u.glow;

    float3 color = 1.0 - exp(-col);
    color += float3(0.0, 0.006, 0.014);                  // deep water, not void
    return color;
}

// ============================================================================
// Form source: was Sources/Shaders/multiverse-lattice.metal
// ============================================================================
// Multiverse Lattice — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, each sample folded a few times and
// lit by how its orbit behaves, so the frame is a stack of glowing
// cross-sections rather than a shaded surface. The fold, the light, the
// camera and the colouring here are this file's own.
//
// The fold is four-dimensional. Each sample becomes (x, y, z, w) and runs 8
// rounds of: mirror every axis, sort x >= y >= z (the octahedral
// kaleidoscope of a KIFS), turn the xw and yz planes together (a double
// rotation, which has no 3D counterpart), then Kali's inversion
// |q| / q.q - c. Space repeats every 2.4 units first, and the first fold is
// a mirror, so the repetition has no seams and the slab can pan forever.
// Each layer keeps the orbit's closest approach to the unit 3-sphere,
// paying a little for every later round, and draws it as fine faceted
// lines over a faint blue frost. Near layers are ice-white, middle cyan,
// far gold.
//
// The `twist` angle is the double rotation: it changes which of the 4D
// crystal's facets this 3D slice cuts through, so as it drifts
// (lerp-animate) the lattice slowly turns inside out. u.seed picks where
// on the pan each activation begins and which slices its layers are.
//
// Motion is in the slab's own plane only. The slab used to drift forward
// 0.05 t through layers 0.145 apart (one every ~6 s at the default speed),
// and the facets are thin in z, so they swelled and shrank as they crossed
// a layer instead of moving: even a tenth of that rate still showed in a
// CPU model. Now each layer is a fixed slice and the slab pans sideways at the
// old forward rate, the near layers sliding faster than the far (parallax);
// what still changes shape is the slow 4D slice (w0) and `twist`. The
// model's motion-compensated change over 2 s falls from 0.56 to 0.11 (most
// of it the layers' parallax), and 87-96% of a 480x300 frame still changes
// per 2 s.
//
// GPU cost: 11 layers x 8 rounds. The sort is a min/max network, and since
// every step but the inversion keeps |q|, one dot product per round serves
// both the inversion and the trap. LerpPreview --bench, Apple M5,
// 3840x2160: within about 0-10% of fractal-multiverse measured in the same
// run (~9 ms), every look.
//

constant int LM_LAYERS = 11;
constant int LM_ROUNDS = 8;

static float3 lmLattice(float4 pos, MvLatticeIn u) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;

    float2 xy = rotate(uv, 0.02 * t) * u.zoom;
    // The slab stays square to the crystal, so its axes and mirror planes
    // line up with the screen's; it pans across the repeating cells (0.05 t
    // along 0.5 rad, wandering as it goes) at a depth the seed picks. The
    // cells repeat every `period`, so the drift is wrapped to it (exact) to
    // keep float precision however long the pan runs.
    const float period = 2.4;
    float3 drift = float3(0.7 * sin(0.021 * t) + 0.0439 * t,
                          0.6 * cos(0.017 * t) + 0.0240 * t,
                          20.0 * u.seed);
    drift = glmod3(drift, period);
    float ca = cos(u.twist), sa = sin(u.twist);
    float cb = cos(0.7 * u.twist + 0.3), sb = sin(0.7 * u.twist + 0.3);
    float w0 = 0.2 + 0.1 * sin(0.05 * t);
    const float4 c = float4(0.6);

    // Layer L samples (xy * (1 + 0.4 L), 1.6 L) + drift.
    float3 origin = float3(xy, 0.0) + drift;
    float3 step = float3(0.4 * xy, 1.6);

    float3 col = float3(0.0);
    for (int i = 0; i < LM_LAYERS; i++) {
        float layer = float(i) / float(LM_LAYERS);
        float3 p = origin + step * layer;
        p = glmod3(p + 0.5 * period, period) - 0.5 * period;

        float4 q = float4(p, w0);
        float r2 = dot(q, q);
        float trap = 1e9;
        for (int j = 0; j < LM_ROUNDS; j++) {
            q = abs(q);
            // Octahedral sort x >= y >= z as a min/max network.
            float a = max(q.x, q.y), b = min(q.x, q.y);
            float m = min(a, q.z);
            q.xyz = float3(max(a, q.z), max(b, m), min(b, m));
            // Double rotation in the xw and yz planes.
            q.xw = float2(ca * q.x - sa * q.w, sa * q.x + ca * q.w);
            q.yz = float2(cb * q.y - sb * q.z, sb * q.y + cb * q.z);
            // Kali's inversion. Mirrors, the sort and rotations keep |q|,
            // so r2 from the last round is still q.q here.
            q = abs(q) / max(r2, 1e-3) - c;
            r2 = dot(q, q);
            // Closest approach to the unit 3-sphere (|q|^2 - 1 ~ 2(|q| - 1)
            // near it), later rounds paying a little.
            trap = min(trap, 0.5 * abs(r2 - 1.0) + 0.012 * float(j));
        }
        float line = exp(-trap * u.facets);
        float frost = u.frost * exp(-trap * 12.0);

        float3 tint = mix(u.ice.rgb, u.cyan.rgb, smoothstep(0.05, 0.45, layer));
        tint = mix(tint, u.gold.rgb, smoothstep(0.45, 0.85, layer));
        col += tint * line + float3(0.1, 0.35, 0.6) * frost;
    }
    col *= 1.5 * u.glow;

    float3 color = 1.0 - exp(-col);
    color += float3(0.0, 0.004, 0.01);
    return color;
}

// ============================================================================
// Dispatch
// ============================================================================

// One form's colour at one sample position, clamped to what the screen can
// show, so a supersampled pixel averages what each sample would display.
static float3 mvSample(float4 pos, constant LerpUniforms& u, int form) {
    if (form == 0) {
        // The port has no zoom or glow of its own: zoom scales its view about
        // the centre (the short axis it divides by) and glow its light, both
        // the identity at 1.
        MvPortIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.speed = u.speed;
        float2 c = 0.5 * u.resolution;
        float4 p = float4(c + (pos.xy - c) * u.zoom, pos.zw);
        return saturate(fmPort(p, s) * u.glow);
    }
    if (form == 1) {
        MvCathedralIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.speed = u.speed;
        s.foldScale = clamp(mix(-1.9, -1.72, u.morph), -2.2, -1.5);
        s.tracery = 42.0 * u.sharpness;
        s.glow = u.glow; s.zoom = 1.3 * u.zoom;
        s.near = u.near; s.far = u.far;
        return saturate(mcCathedral(pos, s));
    }
    if (form == 2) {
        MvCoralIn s;
        s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
        s.speed = u.speed;
        s.inversion = clamp(mix(1.08, 1.24, u.morph), 1.0, 1.4);
        s.lace = 1500.0 * u.sharpness;
        s.pearls = 2.0;
        s.glow = u.glow; s.zoom = 1.6 * u.zoom;
        // One supersample's footprint in the lace's distance units: uv
        // spacing 2/short side, x zoom, x 0.25 (d's scale), x 0.35 (tuned
        // against 16 samples a pixel: wider blurs the strands).
        s.footprint = 0.175 * s.zoom / min(u.resolution.x, u.resolution.y);
        s.near = u.near; s.far = u.far;
        return saturate(mcoCoral(pos, s));
    }
    MvLatticeIn s;
    s.resolution = u.resolution; s.time = u.time; s.seed = u.seed;
    s.speed = u.speed;
    s.twist = clamp(mix(0.28, 0.52, u.morph), 0.0, 1.0);
    s.facets = 80.0 * u.sharpness;
    s.frost = 0.03;
    s.glow = u.glow; s.zoom = u.zoom;
    s.ice = u.near; s.cyan = u.mid; s.gold = u.far;
    return saturate(lmLattice(pos, s));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    int form = clamp(u.form, 0, 3);
    float3 color;
    if (form == 0 || form == 2) {
        // Two samples on the pixel's diagonal, each clamped before they are
        // averaged (see the note at the top of the file).
        color = 0.5 * (mvSample(pos + float4(0.25, 0.25, 0.0, 0.0), u, form)
                     + mvSample(pos - float4(0.25, 0.25, 0.0, 0.0), u, form));
    } else {
        color = mvSample(pos, u, form);
    }
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
