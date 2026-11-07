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
// Time only scrolls the log radius, so upstream
// is an endless zoom that repeats exactly every 1/0.3 time units.
//
// Port changes: time is slowed and offset by u.seed (house style). Upstream
// divides the screen by the resolution per axis, which squashes the spiral
// into an ellipse stretched to the frame (1.6:1 on a 16:10 screen); this port
// divides by the short side, so the spiral is round, fills the height and
// the outer arms and star-dust fill the rest of the width. `speed`,
// `ring` and `knee` are this port's own parameters; upstream has none.
// `ring` is upstream's fixed 0.4 in log2(radius + 0.4) — it sets how the
// rings of one level turn into the arms of the next (lower: long open arms;
// higher: a tight bright rosette inside wide outer swirls) — and it drifts
// slowly between 0.3 and 0.55 so the zoom loop never quite repeats.
// Negative colour is clamped.
//
// Highlights (`knee`): upstream clamps, and its core is a flat white plate.
// Near the centre the march converges (the step shrinks geometrically) and
// every converged step adds glow, so the core sums to 2-4x full scale (p99
// of the brightest channel ~3.5 at 1352x878, measured with the output scaled
// by 1/8): 7% of the default frame and 14% of Upstream's clipped, a third of
// the 600x400 core. fdTone keeps each channel as it was up to `knee` and
// rolls off above it, so the star inside the core, its radial streaks and
// the lilac/blue tint stay visible and the faint arms and dust do not
// change. Default 0.4; Upstream keeps a hotter core at 0.6; 1 is the clamp.
// (Tried and rejected: a hue-preserving shoulder on the brightest channel,
// which turns the white-hot core flat saturated blue, and 1 - exp(-c), which
// greys the mid-tones of the arms.)
//
// Aliasing: each fold's fract() tiling has hard edges, and the log-polar map
// packs more of those tiles into a pixel the nearer it is to the centre, so
// the radial streaks there stair-step and crawl as the zoom scrolls. The
// core is supersampled: 4 samples (rotated grid) within |xy| < 0.1 and 2 out
// to 0.3, 1 beyond, where the arms are smooth at one sample. |xy| is the
// spiral's own radius, so the rings follow it; on a 16:10 screen that
// covers ~0.9% and ~8% of the frame, and it is smooth across the
// screen, so whole SIMD groups take the same branch. Each sample is
// shouldered before the average, so the average is of what the screen
// would show. Clamping the plate used to hide most of this aliasing, which
// is why the shoulder and the supersampling arrived together.
//
// GPU cost: upstream marches 100 steps of 4 folds, each a log2, an atan2 and
// a division, and costs ~5.5x fractal-multiverse. Savings, in order of how
// faithful they are:
//   1. Exact: the first fold's length/log2/atan2 depend only on the pixel,
//      so they are computed once, outside the march; a step whose glow is
//      provably below 1e-8 skips the colour; one rsqrt per fold gives both
//      the radius and the 1/radius upstream divides by; and the scroll is
//      wrapped with fract() once, since it only reaches the picture through
//      fract().
//   2. Near-exact: the other folds use a polynomial atan2 (fdAtan2, error
//      ~1e-5 rad), ~10% faster than the built-in; mean 0.4/255 per pixel.
//   3. A cap: `steps` marches 24 steps by default, each 100/24 as long and
//      100/24 as bright, so the ray still reaches upstream's depth. The
//      central spiral is unchanged; the faint star-dust between the outer
//      arms is much thinner (mean 20-26/255 per pixel against upstream, almost
//      all of it in the dust).
// The "Upstream" preset used to restore all 100 steps, which cost 23.7 ms
// p95 at 2704x1756 (142% of a 60 fps frame). It now marches 44: against
// 100 steps at 1352x878, t=75, 50 steps differ by a mean 6.7/255 and 40 by
// 10.5/255, with the spiral and arms unchanged and only the star-dust a
// little thinner (frame mean 58.5 and 54.7 against 64.3/255); 24 steps
// differ by 33/255. Estimated cost, scaling the measured 100-step time:
// ~10.5 ms for the march plus ~15% for the supersampled core.
// Measured before this change, LerpPreview --bench, Apple M5, 2704x1756:
// default ~5.6-6.5 ms p95.
//
// lerp-category: Fractals
// lerp-param: speed float 0 2   = 0.5 "Speed"
// lerp-param: steps int 20 100  = 24  "March steps"
// lerp-param: ring  float 0.1 0.8 = 0.4 "Ring offset"
// lerp-animate: ring 0.3 0.55 period=200
// lerp-param: knee  float 0.2 1   = 0.4 "Highlight knee"
//
// lerp-preset: Upstream speed=1.0, steps=44, ring=0.4, knee=0.6

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

// One sample of upstream's march at fc (GLSL gl_FragCoord, y up), linear
// and unclamped above.
static float3 fdSample(float2 fc, float scroll, constant LerpUniforms& u) {
    float2 r = u.resolution;

    // Upstream's sample is p = (xy, 1 - g) with xy fixed per pixel. Upstream
    // divides by the resolution per axis, which squashes the spiral; this
    // divides by the short side so it stays round. The first fold only needs
    // |xy|, log2 and atan2 of it, so that part is computed once here.
    float2 xy = (fc - 0.5 * r) / min(r.x, r.y) * 1.5;
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
        float g2 = g * g;
        float3 p = float3(fract(first - g2) - 0.5, (1.0 - g) / l0 + l0);

        // Folds 2-4: the same map on the tiled coordinates. v collects the
        // product of the radii, which scales the step. One rsqrt gives both
        // the radius and the 1/radius upstream divides by.
        for (int j = 1; j < 4; j++) {
            float l2 = max(dot(p.xy, p.xy), 1e-30);
            float il = rsqrt(l2);
            l = l2 * il;
            v *= l;
            p = float3(log2(l + u.ring) - scroll, fdAtan2(p.y, p.x) / 3.1415 * 4.0, p.z * il + l);
            p.xy = fract(p.xy - g2) - 0.5;
        }

        float e = length(p) * v;
        g += e * stride;

        // Glow: 0.04 * exp(-3000 e), hue from the last radius, saturation
        // -g. Past e*3000 = 16 the term is under 1e-8; skip it.
        float k = e * 3e3;
        if (k < 16.0) col += stride * fdHsv(0.05 / l, -g, 0.04 * exp(-k));
    }

    return max(col, 0.0);
}

// The highlight shoulder: the identity up to `knee`, then an exponential
// roll-off with slope 1 at the knee that reaches 1.0 only asymptotically.
// Per channel, so the hottest cores still go white, but through a range of
// pale lilac and blue rather than all at once. knee = 1 is upstream's clamp.
static float3 fdTone(float3 c, float knee) {
    float k = min(knee, 0.999);
    float3 hi = k + (1.0 - k) * (1.0 - exp(-(c - k) / (1.0 - k)));
    return select(c, hi, c > k);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = u.speed * u.time + u.seed * 60.0;
    // The radial zoom. It only ever reaches the picture through fract(), so
    // wrapping it here is exact and keeps float precision at large times.
    float scroll = fract(t * 0.3);

    // Supersampling where the log-polar folds put the most detail into a
    // pixel: the core, where every fold's tiles shrink towards the centre
    // and the radial streaks stair-step. The radius is fdSample's own |xy|,
    // so the rings follow the spiral, and it
    // changes slowly enough across the screen that whole SIMD groups take
    // the same branch. Each sample is shouldered before averaging, so the
    // average is of what the screen would show.
    float l0 = length((fc - 0.5 * r) / min(r.x, r.y) * 1.5);
    float3 color;
    if (l0 < 0.1) {
        // Rotated grid, 4 samples.
        color = 0.25 * (fdTone(fdSample(fc + float2( 0.125,  0.375), scroll, u), u.knee)
                      + fdTone(fdSample(fc + float2(-0.375,  0.125), scroll, u), u.knee)
                      + fdTone(fdSample(fc + float2( 0.375, -0.125), scroll, u), u.knee)
                      + fdTone(fdSample(fc + float2(-0.125, -0.375), scroll, u), u.knee));
    } else if (l0 < 0.3) {
        color = 0.5 * (fdTone(fdSample(fc + float2( 0.25,  0.25), scroll, u), u.knee)
                     + fdTone(fdSample(fc + float2(-0.25, -0.25), scroll, u), u.knee));
    } else {
        color = fdTone(fdSample(fc, scroll, u), u.knee);
    }

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
