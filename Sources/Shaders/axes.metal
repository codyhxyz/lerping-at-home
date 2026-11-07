// Axes — ported from "Axes" by Xor (@XorDev) (CC BY 4.0)
// https://fragcoord.xyz/s/a340ofb0
// Copyright (c) 2026 @Xor. SPDX-License-Identifier: CC-BY-4.0
// Licensed under the Creative Commons Attribution 4.0 International licence,
// https://creativecommons.org/licenses/by/4.0/ — the FragCoord source carries
// "SPDX-License-Identifier: CC-BY-4.0 / Copyright (c) 2026 @Xor".
// This is a modified version (see "Port changes" below), translated from
// FragCoord's golf dialect to Metal; it is not endorsed by the author.
//
// A five-line golf shader. The algorithm, expanded:
//   p = centred coords; s = (sqrt(max(0.5 - |p|^2, 0)), p.x, p.y), the
//       point on a radius-0.707 sphere seen face on (depth first), and a flat
//       plane outside it;
//   a = (cos T, cos(T + 11), 1): an axis that wobbles around the view;
//   v = mix(a (a.s), s, 0.8) - 0.6 (a x s): s pulled towards its projection
//       on the axis and twisted about it, a rotation-like map;
//   colour = 0.1 / |v| / (1 + |p|^2): each channel glows where its component
//       of v crosses zero, which traces three great circles, one per colour,
//       around the sphere, and their tilted continuations across the plane;
//   colour = tanh(colour + |colour| / 5), a soft tonemap that whitens the
//       crossings.
//
// Port changes: time is slowed and offset by u.seed (house style); `speed`
// is this port's own parameter (upstream: 1, the "Upstream" preset).
// Upstream scales by the resolution's height; this uses the short axis so
// portrait screens keep the whole sphere (identical on landscape). Each
// channel's |v| is floored at 1e-4 so it never divides by exactly 0, and the
// tanh argument is clamped to 12, where tanh is already 1.
//
// GPU cost: negligible — no loops. LerpPreview --bench, Apple M5: ~0.32 ms
// per frame at 3840x2160 (fractal-multiverse ~8.9 ms in the same run).
//
// lerp-category: Abstract
// lerp-param: speed float 0 2 = 0.3 "Speed"
//
// lerp-preset: Upstream speed=1.0

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float T = u.speed * u.time + u.seed * 60.0;

    float3 p = float3(fc * 2.0 - r, 0.0) / min(r.x, r.y);
    float3 s = float3(sqrt(max(0.5 - dot(p, p), 0.0)), p.x, p.y);
    float3 a = cos(T + float3(0.0, 11.0, -T));        // (cos T, cos(T+11), 1)

    float3 v = mix(a * dot(a, s), s, 0.8) - 0.6 * cross(a, s);
    float3 col = 0.1 / max(abs(v), 1e-4) / (1.0 + dot(p, p));
    col = tanh(min(col + length(col / 5.0), 12.0));

    float3 color = lerpDither(max(col, 0.0), pos);
    return half4(half3(color), 1.0h);
}
