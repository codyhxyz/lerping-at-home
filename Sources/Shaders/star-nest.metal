// Star Nest — ported from Shadertoy "Star Nest" by Pablo Roman Andrioli (Kali)
// https://www.shadertoy.com/view/XlfGRj  (2013-06-17)
// Upstream licence line, verbatim: "// License: MIT"
//
// Copyright (c) 2013 Pablo Roman Andrioli
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// A 3D Kaliset fractal rendered volumetrically: a slow drift through tiled
// nebula and star clusters. Port notes:
// - The parameters are upstream's own `#define`s ("I put the params on top
//   to play with"), with upstream's names and values. `speed` keeps
//   upstream's 0.010 scale; its default is 0.6x upstream for calm.
// - Upstream steers with the mouse; here `u.seed` picks the viewing angles
//   and the starting point instead, so every activation flies through a
//   different region. With the mouse at rest upstream's angles are a1=0.5,
//   a2=0.8. `useSeed` (added by this port) switches the seeding off; the
//   "Upstream" preset does that and restores upstream's speed and counts.
// - GPU cost, reduced: cost scales with volsteps x iterations. Upstream's
//   20 x 17 = 340 fractal steps a pixel measured about 2x the heaviest
//   paper-design port at 4K, so the defaults are 14 x 14 = 196 (58%). That
//   keeps the bright clusters and nebula colour but marches less deep, so
//   there are fewer faint far stars. The "Upstream" preset restores 20 x 17.
//
// lerp-param: iterations int 4 24      = 14     "Iterations"
// lerp-param: volsteps   int 4 24      = 14     "Volume steps"
// lerp-param: formuparam float 0.4 0.65 = 0.53  "Formula param"
// lerp-param: stepsize   float 0.05 0.2 = 0.1   "Step size"
// lerp-param: zoom       float 0.3 2    = 0.8   "Zoom"
// lerp-param: tile       float 0.5 1.2  = 0.85  "Tile"
// lerp-param: speed      float 0 0.03   = 0.006 "Speed"
// lerp-param: brightness float 0.0005 0.004 = 0.0015 "Brightness"
// lerp-param: darkmatter float 0 0.6    = 0.3   "Dark matter"
// lerp-param: distfading float 0.5 0.9  = 0.73  "Distance fading"
// lerp-param: saturation float 0 1      = 0.85  "Saturation"
// lerp-param: useSeed    bool           = true  "Seeded view"
//
// lerp-preset: Upstream speed=0.01, useSeed=false, iterations=17, volsteps=20

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Upstream: uv = fragCoord/iResolution - 0.5, y scaled by the aspect.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution - 0.5;
    uv.y *= u.resolution.y / u.resolution.x;
    float3 dir = float3(uv * u.zoom, 1.0);
    float seed = u.useSeed != 0 ? u.seed : 0.0;
    float time = u.time * u.speed + 0.25 + seed * 40.0;

    // Upstream's mouse rotation at rest, nudged by the seed.
    float a1 = 0.5 + seed * TWO_PI;
    float a2 = 0.8 + seed * 2.3;
    float2x2 rot1 = float2x2(float2(cos(a1), sin(a1)), float2(-sin(a1), cos(a1)));
    float2x2 rot2 = float2x2(float2(cos(a2), sin(a2)), float2(-sin(a2), cos(a2)));
    // GLSL `v *= m` is v * m (row-vector), i.e. transpose(m) * v.
    dir.xz = dir.xz * rot1;
    dir.xy = dir.xy * rot2;
    float3 from = float3(1.0, 0.5, 0.5);
    from += float3(time * 2.0, time, -2.0);
    from.xz = from.xz * rot1;
    from.xy = from.xy * rot2;

    // Volumetric rendering.
    float s = 0.1, fade = 1.0;
    float3 v = float3(0.0);
    for (int r = 0; r < u.volsteps; r++) {
        float3 p = from + s * dir * 0.5;
        p = abs(float3(u.tile) - glmod3(p, u.tile * 2.0)); // tiling fold
        float pa = 0.0, a = 0.0;
        for (int i = 0; i < u.iterations; i++) {
            p = abs(p) / dot(p, p) - u.formuparam; // the magic formula
            float lp = length(p);
            a += abs(lp - pa); // absolute sum of average change
            pa = lp;
        }
        float dm = max(0.0, u.darkmatter - a * a * 0.001); // dark matter
        a *= a * a; // add contrast
        if (r > 6) fade *= 1.0 - dm; // dark matter, don't render near
        v += fade;
        v += float3(s, s * s, s * s * s * s) * a * u.brightness * fade; // colour by distance
        fade *= u.distfading; // distance fading
        s += u.stepsize;
    }
    v = mix(float3(length(v)), v, u.saturation); // colour adjust
    float3 color = clamp(v * 0.01, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
