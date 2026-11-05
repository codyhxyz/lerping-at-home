// Simulated Reality — ported from "simulated reality -w-" by Yohei Nishitsuji (MIT)
// https://fragcoord.xyz/s/sa07o47u
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
// One of the author's #つぶやきGLSL "simulated reality" seascapes, from the
// readable version he published on FragCoord. An 89-step march over a sea
// plane at y = -0.7: every step rebuilds the height with a "turbulence" fBm
// (each of 9 octaves rotates the xz plane by its own frequency before adding
// |sin| waves), steps by that distance, and adds a little HSV light — blue-
// grey below the horizon, hue rising with height above it. A 1/r glow at the
// screen centre is the sun sitting on the horizon. The screen mapping is
// deliberately anisotropic (upstream divides by the full resolution).
//
// Port changes: time is slowed and offset by u.seed (house style). Upstream
// picks the sun colour from the mouse x position (warm at the left, cool at
// the right); a screensaver has no mouse, so `sunTint` replaces it with the
// same mix and defaults to upstream's no-mouse value (warm). `speed` and
// `steps` are this port's own parameters. Negative colour is clamped.
//
// GPU cost. This is the expensive kind of golf shader: upstream marches 89
// steps x 9 octaves, 18 sines and two 2x2 rotations per octave, for every
// pixel. What brings it down:
//   (1) The octave rotations are hoisted into per-pixel wave vectors, and
//       the per-step HSV into one per-pixel colour (both exact).
//   (2) Sky pixels stop marching as soon as their result is provably black
//       (exact; the sky is half the frame and upstream's sky is black).
//   (3) Sea pixels stop once the ray has settled on the surface (|e| < 1e-6)
//       and add the remaining steps' light in one go. Most of the sea
//       settles in 10-25 steps, so this halves the sea's work; against the
//       full march it differs by a mean 0.001/255 (max 1/255) at 2704x1756.
//   (4) Octaves 6-8 are replaced by their mean while the first six put the
//       sample more than 0.1 above the surface, where they move e by under
//       3% (mean-zero) and the light is linear in e. A float64 model of the
//       march puts this at a mean 0.014/255 (max 3/255) per pixel.
//   (5) `steps` caps the march at 64 by default instead of 89: the only
//       visible difference is a slightly softer far horizon (mean 3/255).
//       The "Upstream" preset restores 89.
// The pixels that never settle (the band at the horizon, and sea pixels
// whose 1.4x over-relaxed step keeps hopping across a steep ripple) still
// march every step, and set the cost. LerpPreview --bench, Apple M5,
// 2704x1756 (the 60 fps budget there is 13 ms): before the HSV hoist, (3)
// and (4), ~17.3 ms/frame default and ~22.8 ms Upstream; (3) alone measured
// 12.1 and 14.5 ms on a loaded GPU, and the model's SIMD-group step count
// puts (4) at another ~12% of the octave work.
//
// lerp-param: speed   float 0 2  = 0.35 "Speed"
// lerp-param: sunTint float 0 1  = 0.0  "Sun warm/cool"
// lerp-animate: sunTint 0 0.3 period=240
// lerp-param: steps   int 32 89  = 64   "March steps"
//
// lerp-preset: Upstream  speed=1.0, steps=89
// lerp-preset: Moonlight sunTint=1.0, speed=0.25

// twigl's hsv(): hue/saturation/value to RGB.
static inline float3 srHsv(float h, float s, float v) {
    float4 k = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(float3(h) + k.xyz) * 6.0 - k.www);
    return v * mix(float3(k.x), clamp(p - k.xxx, 0.0, 1.0), s);
}

// Mean of the dropped octaves 6-8, E|0.1 (sin a + sin b)| / f = 0.1 * 8/pi^2 / f
// for f = 64, 128, 256.
constant float SR_TAIL = 0.1 * 0.8105695 * (1.0 / 64.0 + 1.0 / 128.0 + 1.0 / 256.0);

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = u.speed * u.time + u.seed * 60.0;

    // Screen coords in [-0.5, 0.5] per axis (slightly anisotropic on purpose).
    float2 uv = (fc - 0.5 * r) / r;

    // Sun on the horizon (upstream: colour from mouse x), added after the march.
    float3 sunCol = mix(float3(1.2, 0.8, 0.5), float3(0.4, 0.7, 1.5), clamp(u.sunTint, 0.0, 1.0));
    float3 sun = sunCol * 0.045 / max(length(uv), 1e-4);

    // Upstream's turbulence loop, per octave f = 1, 2, 4 ... 256:
    //     p.xz *= rotate2D(f);  e += abs(dot(sin(p.zx*f + t), vec2(0.1))) / f;
    // At ray distance g the sample's xz is g * (uv.x, 1), and the rotations
    // are linear and fixed, so each octave's p.zx*f is g times a per-pixel
    // wave vector. Those nine vectors are built once here instead of being
    // re-rotated on all 89 steps; the sum is the same.
    float2 wave[9];
    float2 xz = float2(uv.x, 1.0);
    float f = 1.0;
    for (int o = 0; o < 9; o++) {
        // GLSL p.xz *= mat2(c,-s,s,c): row-vector times matrix.
        float c = cos(f), sn = sin(f);
        xz = xz * float2x2(float2(c, -sn), float2(sn, c));
        wave[o] = xz.yx * f;                          // (p.zx * f) / g
        f += f;
    }

    // Upstream adds srHsv(hue, 0.3, v) every step, with a hue fixed per pixel.
    // HSV is linear in v, so the sum is the per-pixel colour `tone` times the
    // sum of the v's (exact): one add per step instead of an HSV conversion.
    float3 tone = srHsv(uv.y > 0.0 ? uv.y : 0.57, 0.3, 1.0);
    // Sky: tone is positive, so tone * light + sun <= 0 in every channel
    // exactly when light <= -max(sun / tone).
    float3 ratio = sun / tone;
    float skyBlack = -max(ratio.x, max(ratio.y, ratio.z));

    float light = 0.0;
    float g = 0.0;   // distance travelled along the ray
    for (int k = 0; k < u.steps; k++) {
        // Base distance: height of (uv*g, g) above the sea plane y = -0.7.
        float e = uv.y * g + 0.7;

        // Turbulence fBm: |sin| ripples along the rotated wave vectors.
        f = 1.0;
        for (int o = 0; o < 6; o++) {
            e += abs(0.1 * (sin(g * wave[o].x + t) + sin(g * wave[o].y + t))) / f;
            f += f;
        }
        // The last three octaves (f = 64, 128, 256) add at most 0.0055 and
        // only matter near the surface, where e is small. While the first
        // six already put the sample more than 0.1 above it, their mean
        // (8/pi^2 * 0.1/f each) stands in for them: the step and the light
        // below are then linear in e, so the error is under 3% of a step and
        // zero on average.
        if (e > 0.1) {
            e += SR_TAIL;
        } else {
            for (int o = 6; o < 9; o++) {
                e += abs(0.1 * (sin(g * wave[o].x + t) + sin(g * wave[o].y + t))) / f;
                f += f;
            }
        }

        // Advance the ray.
        g += e * 1.4;

        // Volumetric shading: sky hue follows height, sea is a fixed blue-grey;
        // brightness peaks in a thin shell near the surface (upstream's
        // octave counter is 512 here).
        light += min(e * 512.0 - 0.05, 0.45 - e) / 63.0;

        // Above the horizon e only grows and never drops below 0.7, so every
        // step subtracts light. Once even the sun cannot lift any channel back
        // above zero the pixel's final value is black; stop marching. (Exact:
        // the remaining steps could only push it further below zero.)
        if (uv.y > 0.0 && light <= skyBlack) break;

        // Sea: once the ray has settled on the surface (|e| < 1e-6, so g
        // moves by under 1.4e-6 a step) every remaining step adds the same
        // -0.05/63; add them all at once and stop. Most of the sea settles
        // in 10-25 steps, the rest of a 64- or 89-step budget is this.
        if (abs(e) < 1e-6) {
            light += float(u.steps - 1 - k) * (-0.05 / 63.0);
            break;
        }
    }

    float3 col = tone * light + sun;

    float3 color = max(col, 0.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
