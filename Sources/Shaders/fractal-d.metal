// Fractal D — ported from "fractal -d-" by Yohei Nishitsuji (MIT)
// https://fragcoord.xyz/s/fo2g251b
// Copyright (c) 2026 @YoheiNishitsuji. SPDX-License-Identifier: MIT
// Licence statement: the source carries "SPDX-License-Identifier: MIT /
// Copyright (c) 2026 @YoheiNishitsuji" with the full MIT permission text,
// FragCoord lists it as MIT, and the author's X profile
// (https://x.com/YoheiNishitsuji) reads "My code shared @x is MIT Licensed".
// Full MIT text: https://opensource.org/licenses/MIT
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
// The author's readable FragCoord version of one of his #つぶやきGLSL pieces.
// A march straight into the screen through a log-polar fold: each sample is
// sent to (log radius, angle, depth/radius + radius) four times over, with a
// fract() tiling after every pass, so the rings of each level become the
// parallel strips of the next and a spiral galaxy of feathered arms blooms
// out of the centre. The product of the radii is the step; light gathers
// wherever the step gets tiny, hue from the last radius, saturation running
// negative with depth (that is what turns the far glow violet and gold).
// The view keeps upstream's per-axis screen scaling, so the spiral is an
// ellipse that fills the frame. Time only scrolls the log radius, so upstream
// is an endless zoom that repeats exactly every 1/0.3 time units.
//
// Port changes: time is slowed and offset by u.seed (house style). `speed`
// and `ring` are this port's own parameters; upstream has neither. `ring` is
// upstream's fixed 0.4 in log2(radius + 0.4) — it sets how the rings of one
// level turn into the arms of the next (lower: long open arms; higher: a
// tight bright rosette inside wide outer swirls) — and it drifts slowly
// between 0.3 and 0.55 so the zoom loop never quite repeats. Negative colour
// is clamped.
//
// GPU cost: upstream marches 100 steps of 4 folds, each a log2, an atan2 and
// a division, and costs ~5.5x fractal-multiverse. Savings, in order of how
// faithful they are:
//   1. Exact: the first fold's length/log2/atan2 depend only on the pixel,
//      so they are computed once, outside the march; and a step whose glow
//      is provably below 1e-8 skips the colour.
//   2. Near-exact: the other folds use a polynomial atan2 (fdAtan2, error
//      ~1e-5 rad), ~10% faster than the built-in; mean 0.4/255 per pixel.
//   3. A cap: `steps` marches 24 steps by default, each 100/24 as long and
//      100/24 as bright, so the ray still reaches upstream's depth. The
//      central spiral is unchanged; the faint star-dust between the outer
//      arms is much thinner (mean 20-26/255 per pixel against upstream, almost
//      all of it in the dust).
// The "Upstream" preset restores 100 steps. LerpPreview --bench, Apple M5,
// best of 6 in one quiet window: ~9.6 ms/frame at 3840x2160 (1.09x
// fractal-multiverse's 8.8 ms), ~1.1 ms at 1200x750; Upstream ~41 ms at
// 3840x2160.
//
// lerp-param: speed float 0 2   = 0.5 "Speed"
// lerp-param: steps int 20 100  = 24  "March steps"
// lerp-param: ring  float 0.1 0.8 = 0.4 "Ring offset"
// lerp-animate: ring 0.3 0.55 period=200
//
// lerp-preset: Upstream speed=1.0, steps=100, ring=0.4

// twigl's hsv(): hue/saturation/value to RGB.
static inline float3 fdHsv(float h, float s, float v) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(float3(h) + k.xyz) * 6.0 - k.www);
    return v * mix(float3(k.x), clamp(p - k.xxx, 0.0, 1.0), s);
}

// atan2 via octant reduction and a degree-7 odd polynomial on [0, 1]
// (max error ~1e-5 rad). Same range and branch cut as atan2(y, x).
static inline float fdAtan2(float y, float x) {
    float ax = abs(x), ay = abs(y);
    float a = min(ax, ay) / max(max(ax, ay), 1e-30);
    float s = a * a;
    float r = ((-0.0464964749 * s + 0.15931422) * s - 0.327622764) * s * a + a;
    r = ay > ax ? 1.57079637 - r : r;
    r = x < 0.0 ? 3.14159274 - r : r;
    return y < 0.0 ? -r : r;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = u.speed * u.time + u.seed * 60.0;
    float scroll = t * 0.3;                           // the radial zoom

    // Upstream's sample is p = (xy, 1 - g) with xy fixed per pixel (divided
    // by the resolution per axis, on purpose). The first fold only needs
    // |xy|, log2 and atan2 of it, so that part is computed once here.
    float2 xy = (fc - 0.5 * r) / r * 1.5;
    float l0 = length(xy);
    float2 first = float2(log2(l0 + u.ring) - scroll, atan2(xy.y, xy.x) / 3.1415 * 4.0);

    // Fewer, longer, brighter steps when capped (stride 1 at 100 steps).
    int steps = u.steps;
    float stride = 100.0 / float(steps);

    float3 col = float3(0.0);
    float g = 0.0;   // distance marched
    for (int i = 0; i < steps; i++) {
        // Fold 1 (hoisted): log-polar map, then tile with fract().
        float v = 0.1 * l0;
        float l = l0;
        float3 p = float3(fract(first - g * g) - 0.5, (1.0 - g) / l0 + l0);

        // Folds 2-4: the same map on the tiled coordinates. v collects the
        // product of the radii, which scales the step.
        for (int j = 1; j < 4; j++) {
            l = length(p.xy);
            v *= l;
            p = float3(log2(l + u.ring) - scroll, fdAtan2(p.y, p.x) / 3.1415 * 4.0, p.z / l + l);
            p.xy = fract(p.xy - g * g) - 0.5;
        }

        float e = length(p) * v;
        g += e * stride;

        // Glow: 0.04 * exp(-3000 e), hue from the last radius, saturation
        // -g. Past e*3000 = 16 the term is under 1e-8; skip it.
        float k = e * 3e3;
        if (k < 16.0) col += stride * fdHsv(0.05 / l, -g, 0.04 * exp(-k));
    }

    float3 color = max(col, 0.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
