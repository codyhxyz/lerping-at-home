// Topologica — ported from Shadertoy "Topologica" by Otavio Good
// https://www.shadertoy.com/view/4djXzz  (2014-08-21)
// Upstream licence, verbatim:
//   License CC0 - http://creativecommons.org/publicdomain/zero/1.0/
//   To the extent possible under law, the author(s) have dedicated all
//   copyright and related and neighboring rights to this software to the
//   public domain worldwide. This software is distributed without any
//   warranty.
//   ^ This means do ANYTHING YOU WANT with this code. Because we are
//   programmers, not lawyers.
//   -Otavio Good
//
// A camera orbits far outside a cloud of 3D value noise; a short, coarse
// raymarch accumulates 0.1/|n1^2 * n2| so only the thin sheets where the
// noise crosses its midpoint glow, like contour lines on a topographic map
// folded into space. Port notes:
// - Upstream's mouse orbit is replaced by `u.seed`, which picks the starting
//   orbit angle so every activation shows a different side of the cloud.
// - `speed` is added by this port (upstream is fixed at 1x); its default
//   keeps upstream's already-slow orbit. `color` is upstream's baked
//   vec3(0.01, 0.1, 1.0), exposed. `gain` is upstream's baked 0.2 density
//   scale; the default is 0.02 so more of the screen stays dark and only
//   the thin contour sheets glow (upstream saturates large areas to white,
//   mean luma ~0.55). The "Upstream" preset restores 0.2.
// - GPU cost, reduced: upstream marches 37 steps x 2 trilinear noise lookups
//   (8 hashes each), about 4x the cost of the heaviest paper-design port at
//   4K. This port defaults to 16 steps, each striding 37/16 as far so the
//   march still spans upstream's depth (fewer, sparser contour layers; a
//   calmer picture), and replaces upstream's `fract(cos(f*3.333)*100003.9)`
//   lattice hash with the prelude's trig-free `hash21` (same role: a random
//   value per lattice corner). `steps` (added by this port) restores
//   upstream's 37, as does the "Upstream" preset.
//
// lerp-param: color  color       = (0.01, 0.1, 1.0) "Glow colour"
// lerp-param: speed  float 0 4   = 1.0              "Speed"
// lerp-param: gain   float 0.01 0.4 = 0.02          "Glow gain"
// lerp-param: steps  int 8 37       = 16            "March steps"
//
// lerp-preset: Upstream gain=0.2, steps=37
// lerp-preset: Ember   color=(1.0, 0.25, 0.04)
// lerp-preset: Verdant color=(0.08, 1.0, 0.35)

static float topoHash3d(float3 uv) {
    return hash21(float2(uv.x + uv.z * 57.0, uv.y - uv.z * 113.0));
}

static float topoMixP(float f0, float f1, float a) {
    return mix(f0, f1, a * a * (3.0 - 2.0 * a));
}

static float topoNoise(float3 uv) {
    const float2 zeroOne = float2(0.0, 1.0);
    float3 fr = fract(uv);
    float3 fl = floor(uv);
    float h000 = topoHash3d(fl);
    float h100 = topoHash3d(fl + zeroOne.yxx);
    float h010 = topoHash3d(fl + zeroOne.xyx);
    float h110 = topoHash3d(fl + zeroOne.yyx);
    float h001 = topoHash3d(fl + zeroOne.xxy);
    float h101 = topoHash3d(fl + zeroOne.yxy);
    float h011 = topoHash3d(fl + zeroOne.xyy);
    float h111 = topoHash3d(fl + zeroOne.yyy);
    return topoMixP(
        topoMixP(topoMixP(h000, h100, fr.x), topoMixP(h010, h110, fr.x), fr.y),
        topoMixP(topoMixP(h001, h101, fr.x), topoMixP(h011, h111, fr.x), fr.y),
        fr.z);
}

static float topoDensity(float3 p) {
    float final = topoNoise(p * 0.06125);
    float other = topoNoise(p * 0.06125 + 1234.567);
    other -= 0.5;
    final -= 0.5;
    final = 0.1 / (abs(final * final * other));
    final += 0.5;
    return final * 0.0001;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Upstream: uv = fragCoord/iResolution * 2 - 1, y up.
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;

    float3 camUp = float3(0.0, 1.0, 0.0);
    float3 camLookat = float3(0.0);

    float mx = u.seed * TWO_PI + time * 0.01;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.2 + 0.2;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * 200.2;

    float3 camVec = normalize(camLookat - camPos);
    float3 sideNorm = normalize(cross(camUp, camVec));
    float3 upNorm = cross(camVec, sideNorm);
    float3 worldFacing = camPos + camVec;
    float3 worldPix = worldFacing + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm;
    float3 relVec = normalize(worldPix - camPos);

    float t = 0.0;
    float inc = 0.02;
    const float maxDepth = 70.0;
    float density = 0.0;
    // Fewer steps than upstream's 37 each stride proportionally further, so
    // the march still spans the same depth.
    float stride = 37.0 / float(u.steps);
    for (int i = 0; i < u.steps; i++) {
        if (t > maxDepth) break;
        float3 p = camPos + relVec * t;
        float temp = topoDensity(p);
        inc = (1.9 + temp * 0.05) * stride; // upstream: "this makes it look extra crazy!"
        density += temp * inc;
        t += inc;
    }

    float3 finalColor = u.color.rgb * density * u.gain;
    // Upstream's sqrt "gamma correction".
    float3 color = sqrt(clamp(finalColor, 0.0, 1.0));

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
