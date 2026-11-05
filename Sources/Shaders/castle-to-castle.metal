// Castle To Castle — ported from "castle to castle -r6-" by Yohei Nishitsuji (MIT)
// https://fragcoord.xyz/s/cltuv8os
// Copyright (c) 2026 @YoheiNishitsuji. SPDX-License-Identifier: MIT
// Licence statement: the source carries "SPDX-License-Identifier: MIT /
// Copyright (c) 2026 @YoheiNishitsuji / [LICENSE] https://opensource.org/
// licenses/MIT", FragCoord lists it as MIT, and the author's X profile
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
// A perspective march into a folding IFS: seven times over, space is turned
// a quarter-turn about an axis whose tilt breathes with time, then mirror-
// folded with abs(2p) - 2, and the folded point is measured against a
// slanted torus. The result is a carved, self-similar ivory architecture —
// keyholes, rosettes and lattices of tori — that slowly tumbles about the x
// axis and reorganises itself as the fold axis swings. Light is a sharp
// exp(-2000 e) glow gathered at every step, so surfaces read as lit stone and
// the depth falls away into black.
//
// The swing is a morph, not a motion: seven folds each turn the sub-structure
// below them by the change in the fold, so the fine, distant detail reshuffles
// fastest. At upstream's rate (up to ~0.2 rad/s of axis tilt at the default
// speed) a patch of it is unrecognisable within half a second, which reads as
// the castle melting rather than turning. So `swing` scales the swing's rate
// and defaults to 0.02: one castle becomes the next over ~13 minutes, and in
// any 2 s a CPU model of this march shows no more reshaping than 0.25 s of
// the camera's own orbit (motion-compensated residual: median 0.07, at most
// 0.14; the orbit's 0.08 and 0.14; swing 1's median 0.97). The seed lands each
// activation anywhere on the swing, so the castle on screen differs from one
// activation to the next, and the tumble keeps the look moving (84-95% of a
// 480x300 frame changes per 2 s).
//
// Port changes: time is slowed and offset by u.seed (house style). `speed`,
// `swing` and `tint` are this port's own parameters; upstream has none.
// Upstream is pure white, and when the camera drifts up against a large face
// the frame goes almost entirely white (mean luma ~0.75), so the default
// tint is a dimmer warm ivory; the "Upstream" preset restores white (and
// swing=1, upstream's rate). Upstream divides by the resolution's height;
// this uses the short axis so portrait screens see the same framing
// (identical on landscape).
//
// GPU cost: upstream marches 100 steps of 7 rotate-and-fold passes, ~5x
// fractal-multiverse. The march is a heavily under-relaxed sphere trace
// (the folds scale space by 2^7 = 128 and the step divides by 800, so each
// step covers 0.16 of the true distance), which is what makes a cap cheap
// here: `steps` takes 20 steps by default, each 100/20 = 5x as long (0.8 of
// the true distance, still short of overshooting). Surfaces land in the same
// place; with the light weight below, the capped march differs from upstream
// by a mean ~12/255 per pixel (shading on the far layers, not structure).
// Exact savings on top: the ray is linear in its depth, so the per-step
// tumble becomes a per-pixel origin and direction, and the 2x of each fold
// is folded into its rotation matrix. The "Upstream" preset restores 100
// steps. LerpPreview --bench, Apple M5, best of 6 in one quiet window:
// ~8.3 ms/frame at 3840x2160 (0.94x fractal-multiverse's 8.8 ms), ~0.93 ms
// at 1200x750; Upstream ~42 ms at 3840x2160 before the grouping below.
//
// Upstream's 100 steps (any `steps` from 80 up) are grouped: at stride ~1
// the march closes on a surface geometrically, e falling by a near-steady
// ratio rho (~0.85-0.95) per step, so three steps share one distance
// evaluation. The group advances by e(1 + rho + rho^2) with rho from the
// previous group, and its glow is summed over e, e*rho', e*rho'^2 with rho'
// measured to the next group's distance. 35 evaluations instead of 100
// (23 ms p95 at 2704x1756 before, over the 13 ms 60 fps budget there). A
// float64 model of both marches at 2704x1756 differs by a mean 1.2/255
// (p99 7/255, bias under 0.4/255): the same structure and light, with the
// odd edge a few levels brighter or darker. Grouping by four (27
// evaluations) roughly doubles that, and the stride-5 default can't be
// grouped (rho is far from steady there), which is why the 20-step default
// marches every step as before.
//
// lerp-param: speed float 0 2   = 0.5  "Speed"
// lerp-param: swing float 0 1   = 0.02 "Fold swing"
// lerp-param: steps int 20 100  = 20   "March steps"
// lerp-param: tint  color       = (0.86, 0.81, 0.72) "Tint"
//
// lerp-preset: Upstream  speed=1.0, swing=1.0, steps=100, tint=(1.0, 1.0, 1.0)
// lerp-preset: Moonstone tint=(0.58, 0.70, 0.86)

// twigl's rotate3D(): Rodrigues rotation by `angle` about `axis`, built in
// the same column order as the GLSL mat3 constructor.
static inline float3x3 ccRotate3D(float angle, float3 axis) {
    float3 a = normalize(axis);
    float s = sin(angle), c = cos(angle), r = 1.0 - c;
    return float3x3(float3(a.x * a.x * r + c,       a.y * a.x * r + a.z * s, a.z * a.x * r - a.y * s),
                    float3(a.x * a.y * r - a.z * s, a.y * a.y * r + c,       a.z * a.y * r + a.x * s),
                    float3(a.x * a.z * r + a.y * s, a.y * a.z * r - a.x * s, a.z * a.z * r + c));
}

// Distance to a slanted torus in the folded space (scaled by 128 from the
// folds; /800 makes the step a fraction of the true distance).
static inline float ccDistance(float3 p, float3x3 fold) {
    for (int j = 0; j < 7; j++) p = abs(p * fold) - 2.0;
    return (length(float2(length(p.xz) - 2.0, (p.y - p.x) * 0.7)) - 0.6) / 8e2;
}

// From this many steps up the march is taken in predicted groups of three.
constant int CC_GROUP_FROM = 80;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = u.speed * u.time + u.seed * 60.0;

    // The fold: a quarter turn about (1, tilt, 0), tilt breathing between
    // -0.5 and 1.0, then abs(p + p) - 2. GLSL p *= M is row-vector times
    // matrix; the 2x is folded into the matrix (exact). Upstream's phase is
    // 0.4 t; here only the time part runs at `swing`'s rate (identical at 1),
    // the seed's offset at full rate so each activation finds its own castle.
    float swingPhase = 0.4 * (u.swing * u.speed * u.time + u.seed * 60.0);
    float tilt = 1.5 * smoothstep(-1.0, 1.0, sin(swingPhase)) - 0.5;
    float3x3 fold = 2.0 * ccRotate3D(1.57, float3(1.0, tilt, 0.0));

    // Upstream samples p = (uv * g, g - 4.3) and turns its zy plane by t*0.2.
    // That is linear in the depth g, so p = origin + g * dir.
    float2 uv = (fc - 0.5 * r) / min(r.x, r.y);
    float c = cos(t * 0.2), s = sin(t * 0.2);
    float2x2 tumble = float2x2(float2(c, -s), float2(s, c));
    float3 origin = float3(0.0, 0.0, -4.3);
    float3 dir = float3(uv, 1.0);
    origin.zy = origin.zy * tumble;
    dir.zy = dir.zy * tumble;

    // Fewer, longer, brighter steps when capped (stride 1 at 100 steps).
    int steps = u.steps;
    float stride = 100.0 / float(steps);
    // A longer step lands more samples on a surface, so its light is scaled
    // by stride^0.78 rather than stride: calibrated so a capped march matches
    // upstream's mean brightness (exactly 1 at 100 steps).
    float weight = pow(stride, 0.78);

    float glow = 0.0;
    float g = 0.0;   // depth along the ray
    if (steps < CC_GROUP_FROM) {
        for (int i = 0; i < steps; i++) {
            float e = ccDistance(origin + g * dir, fold);
            g += e * stride;
            glow += weight * exp(-e * 2e3) / 4e1;
        }
    } else {
        // Long marches (Upstream's 100): the under-relaxed march closes on
        // a surface geometrically, e shrinking by a near-constant ratio per
        // step, so steps are taken in groups of three on one distance
        // evaluation each: the group's three distances are e, e*rho, e*rho^2
        // with rho measured from the last group (predictor), and once the
        // next group's distance is known the glow is summed along the
        // measured decay between the two (corrector). See the header.
        float ePrev = 0.0;
        for (int i = 0; i < 2; i++) {
            float e = ccDistance(origin + g * dir, fold);
            g += e * stride;
            glow += weight * exp(-e * 2e3) / 4e1;
            ePrev = e;
        }
        float e = ccDistance(origin + g * dir, fold);
        float rho = clamp(max(e, 1e-12) / max(ePrev, 1e-12), 0.3, 0.999);
        for (int i = 2; i < steps; i += 3) {
            int k = min(3, steps - i);
            float next = e, rhoNext = rho;
            float travel = e * (1.0 + (k > 1 ? rho : 0.0) + (k > 2 ? rho * rho : 0.0));
            g += travel * stride;
            if (i + k < steps) {
                next = ccDistance(origin + g * dir, fold);
                float ratio = max(next, 1e-12) / max(e, 1e-12);
                rhoNext = clamp(k == 3 ? pow(ratio, 1.0 / 3.0) : k == 2 ? sqrt(ratio) : ratio, 0.3, 0.999);
            }
            float ej = e;
            float sum = exp(-ej * 2e3);
            for (int j = 1; j < k; j++) {
                ej *= rhoNext;
                sum += exp(-ej * 2e3);
            }
            glow += weight * sum / 4e1;
            e = next;
            rho = rhoNext;
        }
    }

    float3 color = glow * u.tint.rgb;
    color = lerpDither(max(color, 0.0), pos);
    return half4(half3(color), 1.0h);
}
