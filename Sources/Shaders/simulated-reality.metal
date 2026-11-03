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
// pixel. Three things bring it down. (1) The octave rotations are hoisted
// into per-pixel wave vectors (exact). (2) Sky pixels stop marching as soon
// as their result is provably black (exact; it halves the work, since the
// sky is half the frame and upstream's sky is black). (3) `steps` caps the
// march at 64 by default instead of 89: the sea converges early, and the
// only visible difference is a slightly softer far horizon (mean 3/255 per
// pixel). The "Upstream" preset restores 89. LerpPreview --bench, Apple M5,
// defaults: ~3.3 ms/frame at 1200x750, ~30 ms at 3840x2160 (about 2.4x
// paper-texture, the heaviest shader before it; a straight port measured
// ~13.5 ms at 1200x750). On 4K-and-up screens it wants the saver's 75% or
// 50% render scale to hold 60 fps.
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

    float3 col = float3(0.0);
    float g = 0.0;   // distance travelled along the ray
    for (int k = 0; k < u.steps; k++) {
        // Base distance: height of (uv*g, g) above the sea plane y = -0.7.
        float e = uv.y * g + 0.7;

        // Turbulence fBm: |sin| ripples along the rotated wave vectors.
        f = 1.0;
        for (int o = 0; o < 9; o++) {
            e += abs(0.1 * (sin(g * wave[o].x + t) + sin(g * wave[o].y + t))) / f;
            f += f;
        }

        // Advance the ray.
        g += e * 1.4;

        // Volumetric shading: sky hue follows height, sea is a fixed blue-grey;
        // brightness peaks in a thin shell near the surface (upstream's
        // octave counter is 512 here).
        col += srHsv(uv.y > 0.0 ? uv.y : 0.57, 0.3, min(e * 512.0 - 0.05, 0.45 - e) / 63.0);

        // Above the horizon e only grows and never drops below 0.7, so every
        // step subtracts light. Once even the sun cannot lift any channel back
        // above zero the pixel's final value is black; stop marching. (Exact:
        // the remaining steps could only push it further below zero.)
        if (uv.y > 0.0 && all(col + sun <= 0.0)) break;
    }

    col += sun;

    float3 color = max(col, 0.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
