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
// this port's own parameter, upstream has none. Upstream divides by the
// resolution's height; this uses the short axis so portrait screens see the
// same framing (identical on landscape). Negative colour is clamped.
//
// GPU cost: 18 x 9 fold iterations per pixel, no cap needed. LerpPreview
// --bench, Apple M5: ~0.95 ms/frame at 1200x750, ~8.7 ms at 3840x2160
// (between pipes and paper-texture).
//
// lerp-param: speed float 0 2 = 0.5 "Speed"
//
// lerp-preset: Upstream speed=1.0

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

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float t = u.speed * u.time + u.seed * 60.0;

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

    float3 color = max(col, 0.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
