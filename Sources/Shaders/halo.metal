// Halo — ported from "Halo" by Xor (@XorDev) (CC BY 4.0)
// https://fragcoord.xyz/s/hp79nubv  (originally posted at
// https://x.com/XorDev/status/1938036074183594311)
// Copyright (c) 2026 @Xor. SPDX-License-Identifier: CC-BY-4.0
// Licensed under the Creative Commons Attribution 4.0 International licence,
// https://creativecommons.org/licenses/by/4.0/ — the FragCoord source carries
// "SPDX-License-Identifier: CC-BY-4.0 / Copyright (c) 2026 @Xor".
// This is a modified version (see "Port changes" below), translated from
// FragCoord's golf dialect to Metal; it is not endorsed by the author.
//
// A three-line golf shader. The algorithm, expanded:
//   p = centred coords, scaled so the ring sits at |p| = 1;
//   l = |p| - 1 (signed distance to the ring), a = polar angle;
//   glow = max(0.2 / l, -0.02 - 0.02 / l): a 1/l falloff outside the ring
//          and a weaker one inside it, so the centre stays dark;
//   petals = 2 + cos(8a + cos(5a + T)) * sin(4a - T), in [1, 3]: dividing by
//          it pinches the glow into slowly travelling flower-like lobes;
//   tint = cos(p.x + T/2 + (1,2,3)) + 1.5: a rainbow sliding across x;
//   colour = tanh(tint * glow / petals), a soft tonemap.
//
// Port changes: time is slowed and offset by u.seed (house style); `speed` is
// this port's own parameter, upstream has none. Upstream scales by the
// resolution's height; this uses the short axis so portrait screens keep the
// whole ring (identical on landscape). The tanh argument is clamped to ±12,
// where tanh is already 1, to keep fast-math tanh finite on the ring itself.
//
// GPU cost: negligible — no loops. LerpPreview --bench, Apple M5: ~0.06 ms
// per frame at 1200x750, ~0.5 ms at 3840x2160.
//
// lerp-category: Abstract
// lerp-param: speed float 0 2 = 0.5 "Speed"
//
// lerp-preset: Upstream speed=1.0

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float2 fc = float2(pos.x, r.y - pos.y);           // GLSL gl_FragCoord (y up)
    float T = u.speed * u.time + u.seed * 60.0;

    float2 p = (fc * 2.0 - r) / min(r.x, r.y) / 0.6;
    float l = length(p) - 1.0;
    l = (abs(l) < 1e-4) ? copysign(1e-4, l) : l;      // never divide by exactly 0
    float a = atan2(p.y, p.x);

    float glow = max(0.2 / l, -0.02 - 0.02 / l);
    float petals = 2.0 + cos(a * 8.0 + cos(a * 5.0 + T)) * sin(a * 4.0 - T);
    float3 tint = cos(p.x + T / 2.0 + float3(1.0, 2.0, 3.0)) + 1.5;

    float3 color = tanh(clamp(tint * glow / petals, -12.0, 12.0));
    color = lerpDither(max(color, 0.0), pos);
    return half4(half3(color), 1.0h);
}
