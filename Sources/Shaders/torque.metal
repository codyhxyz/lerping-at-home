// Torque — ported from "Torque" by Xor (@XorDev) (CC BY 4.0)
// https://fragcoord.xyz/s/t4e02wdx  (originally posted at
// https://x.com/XorDev/status/1938412395245834611)
// Copyright (c) 2026 @Xor. SPDX-License-Identifier: CC-BY-4.0
// Licensed under the Creative Commons Attribution 4.0 International licence,
// https://creativecommons.org/licenses/by/4.0/ — the FragCoord source carries
// "SPDX-License-Identifier: CC-BY-4.0 / Copyright (c) 2026 @Xor".
// This is a modified version (see "Port changes" below), translated from
// FragCoord's golf dialect to Metal; it is not endorsed by the author.
//
// A three-line golf shader. The algorithm, expanded:
//   p = centred coords, then squeezed through the symmetric matrix
//       [9 -8; -8 9] (stretch 17x along one diagonal, 1x along the other)
//       and scaled by 5 / (4 + |p|^2), which bulges the middle like a lens;
//   p += a per-pixel random offset in [0, 1) along the (1, 1) diagonal (a
//       stochastic blur: neighbouring pixels sample the pattern up to one
//       unit apart, so lines smear) and a steady diagonal drift (the
//       "torque" flow);
//   filaments = 1 / (1 + sin(dot(cos(p + p.x/7), sin(0.61 p.yx)) + hue)):
//       a sine-of-sines turbulence that blows up wherever the sine reaches
//       -1, with the hue offset (0, .1, .2) * (1 + cos(p.x/10)) splitting the
//       lines into colour fringes;
//   brightness = exp(sin(T + p.x + p.y)) / 10: broad diagonal swells;
//   colour = tanh(brightness * filaments), a soft tonemap.
//
// Port changes: time is slowed and offset by u.seed (house style); `speed`
// and `drift` are this port's own parameters (upstream: speed 1, drift 10,
// the "Upstream" preset). FragCoord's gl_FragCoord.zw for a fullscreen pass
// is (0.5, 1), which only fed upstream's grain hash.
//
// The blur is drawn as its average, not as a random sample. Upstream hashes
// the pixel with the clock, so every pixel takes a new offset every frame:
// the soft smear arrives as TV-static grain that crawls at any speed (1/60 s
// frame-to-frame flicker 0.136 of full scale at 1352x878, and still 0.087 at
// 1/960 s: alpha 0.16, pure per-frame noise). What the eye reads from that
// grain, and what a long exposure of upstream would show, is the mean over
// the offset, so this port sums TORQUE_TAPS evenly spaced offsets across the
// same [0, 1) instead: the same soft lines, colours and brightness, steady
// from frame to frame (flicker 0.002, 68x less; the rest is 8-bit rounding).
// 12 taps land within 1/255 of a 128-tap average everywhere (8 taps: 2/255).
// The grain texture itself is gone; that is the deliberate change.
//
// Upstream scales by the resolution's height; this uses the short axis so
// portrait screens keep the framing (identical on landscape). The tanh
// argument is clamped to 12, where tanh is already 1, to keep fast-math
// tanh finite on the filaments. `drift` has no // lerp-animate: it multiplies
// the clock, so any change to it would jump the whole pattern sideways.
//
// GPU cost: small, but 12x the arithmetic of one sample. With one sample,
// LerpPreview --bench at 2704x1756 on an M5 measured 0.41 ms mean, 0.68-0.76
// ms p95; the 12-tap version is not yet benched (GPU benching was frozen),
// and should land around 2-5 ms. TORQUE_TAPS 8 is within 2/255 if needed.
//
// lerp-param:   speed float 0 2   = 0.3 "Speed"
// lerp-param:   drift float 0 10  = 4   "Drift"
//
// lerp-preset: Upstream speed=1.0, drift=10

#ifndef TORQUE_TAPS
#define TORQUE_TAPS 12
#endif

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 r = u.resolution;
    float4 C = float4(pos.x, r.y - pos.y, 0.5, 1.0);  // GLSL gl_FragCoord (y up)
    float T = u.speed * u.time + u.seed * 60.0;

    float2 p = (C.xy * 2.0 - r) / min(r.x, r.y);
    // GLSL p * mat2(9,-8,-8,9): the matrix is symmetric, so order is moot.
    p = p * float2x2(float2(9.0, -8.0), float2(-8.0, 9.0)) * 5.0 / (4.0 + dot(p, p));
    p += T * u.drift;                                 // the diagonal flow

    // Upstream's stochastic blur, p += U[0, 1) along the (1, 1) diagonal, as
    // its expectation: TORQUE_TAPS fixed, evenly spaced offsets averaged.
    float4 col = 0.0;
    for (int k = 0; k < TORQUE_TAPS; k++) {
        float2 q = p + (float(k) + 0.5) / float(TORQUE_TAPS);
        float swell = exp(sin(T + q.x + q.y)) / 10.0;
        float4 hue = (cos(q.x / 10.0) + 1.0) * float4(0.0, 0.1, 0.2, 0.0);
        float4 lines = sin(dot(cos(q + q.x / 7.0), sin(q.yx * 0.61)) + hue) + 1.0;
        col += tanh(min(swell / max(lines, 1e-6), 12.0));
    }
    col /= float(TORQUE_TAPS);
    float3 color = lerpDither(max(col.rgb, 0.0), pos);
    return half4(half3(color), 1.0h);
}
