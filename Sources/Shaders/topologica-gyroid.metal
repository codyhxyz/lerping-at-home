// Topologica Gyroid — a remix of "Topologica" by Otavio Good
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
// Remix (not a port; topologica.metal is the faithful one). Kept from
// upstream: a short, coarse march through a slowly orbiting volume that
// accumulates 0.1/|a^2 * b|, so light gathers where field a vanishes and
// blazes where field b vanishes there too; the colour scaled by density and
// upstream's sqrt "gamma". Replaced: the two value-noise fields, with triply
// periodic minimal surfaces.
//
// - Field a blends the gyroid, Schwarz P, Schwarz D (diamond) and Neovius
//   implicit functions; field b is the next family round that cycle, offset
//   by a slowly drifting phase. The filaments are the curves where the two
//   surfaces intersect, rendered as thin glowing tubes; a faint membrane
//   shows surface a itself, so the labyrinth's tunnels read as dark holes.
//   `bands` adds the curves where a meets b's other level sets, b = k/bands.
// - Upstream point-samples the field, so a 16-step march sees each sheet
//   only where a sample lands on it (the contour-line look). Here a and b
//   are taken as linear between samples and 1/(a^2 + b^2 + r^2) is
//   integrated exactly per segment (closed form, atan), so no filament can
//   fall between steps. That is why 10 steps look like 32 and the march
//   can afford a telephoto view that shows the lattice's order.
// - Motion: the blend wanders gyroid -> P -> D -> Neovius -> gyroid,
//   dwelling on each and morphing between them (blending implicit functions
//   moves their zero sets continuously, so the network reorganises); the
//   lattice twists about the vertical axis, slowly breathes in scale and
//   warps gently; the camera orbits as upstream's does. `u.seed` picks the
//   orbit angle and height phase, the morph phase, the partner offset and
//   the breathing/twist phases.
// - Cost: all four surfaces, and the partner's four, come from one sin/cos
//   of the sample point (the partner by angle addition), so a step costs
//   about what upstream's two trilinear noise lookups do, at fewer steps.
//
// lerp-param: color   color         = (0.01, 0.1, 1.0)   "Glow colour"
// lerp-param: accent  color         = (0.42, 0.06, 1.0)  "Depth / membrane colour"
// lerp-param: speed   float 0 4     = 1.0                "Speed"
// lerp-param: gain    float 0.005 0.2 = 0.02             "Glow gain"
// lerp-param: steps   int 6 32      = 10                 "March steps"
// lerp-param: surface float 0 3     = 0.0                "Surface (G/P/D/N)"
// lerp-param: morph   float 0 1     = 1.0                "Auto morph"
// lerp-param: scale   float 0.4 2.5 = 1.0                "Cell density"
// lerp-param: twist   float 0 1     = 0.5                "Twist"
// lerp-param: warp    float 0 1     = 0.4                "Warp"
// lerp-param: membrane float 0 1  = 0.15               "Membrane"
// lerp-param: bands   float 0 3     = 0.0                "Iso-bands"
//
// lerp-preset: Gyroid      surface=0, morph=0
// lerp-preset: "Schwarz P" surface=1, morph=0, color=(1.0, 0.25, 0.04), accent=(1.0, 0.04, 0.10)
// lerp-preset: Diamond     surface=2, morph=0, color=(0.08, 1.0, 0.35), accent=(0.0, 0.55, 1.0)
// lerp-preset: Neovius     surface=3, morph=0, scale=0.7, color=(0.0, 0.75, 1.0), accent=(0.45, 0.08, 1.0)
// lerp-preset: Strata      bands=1.5, twist=0.8, color=(1.0, 0.55, 0.12), accent=(0.85, 0.10, 0.06)

// The four surfaces at one point, from its sin and cos. Each is scaled so
// that its gradient across the zero set is roughly the same, which keeps the
// filament width steady while the blend morphs.
static float4 tgySurfaces(float3 s, float3 c) {
    float g = s.x * c.y + s.y * c.z + s.z * c.x;                          // gyroid
    float p = c.x + c.y + c.z;                                            // Schwarz P
    float d = s.x * s.y * s.z + s.x * c.y * c.z
            + c.x * s.y * c.z + c.x * c.y * s.z;                          // Schwarz D
    float n = 3.0 * (c.x + c.y + c.z) + 4.0 * c.x * c.y * c.z;            // Neovius
    return float4(g, p * 0.8, d * 1.1, n * 0.28);
}

// Blend weights for a position x on the cycle G(0) P(1) D(2) N(3) G(4).
static float4 tgyWeights(float x) {
    float4 k = float4(0.0, 1.0, 2.0, 3.0);
    float4 r = x - k + 2.0;
    float4 d = abs(r - 4.0 * floor(r * 0.25) - 2.0); // cyclic distance, 0..2
    float4 w = clamp(1.0 - d, 0.0, 1.0);
    return w * w * (3.0 - 2.0 * w);                // adjacent pair sums to 1
}

// Everything that places the lattice in the world for this frame.
struct TgyFrame {
    float4 w;          // surface blend weights
    float k;           // lattice frequency
    float twistRate;   // radians of twist per unit of height
    float spin;        // twist phase
    float warpAmp;
    float warpPhase;
    float3 so, co;     // sin, cos of the partner's lattice offset
};

// (a, b): the blended surface and its partner, at world point p.
static float2 tgyField(float3 p, TgyFrame f) {
    p += f.warpAmp * sin(p.zxy * 0.06 + float3(0.0, 2.1, 4.2) + f.warpPhase);
    float ang = p.y * f.twistRate + f.spin;
    float cs = cos(ang), sn = sin(ang);
    p.xz = float2(cs * p.x - sn * p.z, sn * p.x + cs * p.z);

    float3 q = p * f.k;
    float3 s = sin(q), c = cos(q);
    float a = dot(f.w, tgySurfaces(s, c));
    // The partner is the next family round the cycle, offset by a drifting
    // phase: sin/cos of (q + offset) by angle addition, no more trig.
    float b = dot(f.w.yzwx, tgySurfaces(s * f.co + c * f.so, c * f.co - s * f.so));
    return float2(a, b);
}

// Exact integral over a segment of length dt of 1/(a^2 + e^2), with a
// varying linearly from a0 to a1. A zero crossing anywhere inside the
// segment is caught, and is brightest where the ray grazes the surface.
static float tgySegment(float a0, float a1, float e, float dt) {
    float da = a1 - a0;
    if (abs(da) < 1e-4) return dt / (a0 * a0 + e * e);
    return dt * (atan(a1 / e) - atan(a0 / e)) / (e * da);
}

// A thin tube around the curve where both surfaces vanish, integrated
// exactly along a segment over which (a, b) moves linearly from p0 to p1,
// so no step can skip a filament. With Q(s) = |p(s)|^2 + r^2:
//   x = integral of 1/Q    (soft halo, upstream's 1/|b| falloff)
//   y = integral of 1/Q^2  (crisp core)
static float2 tgyTube(float2 p0, float2 p1, float r2) {
    float2 D = p1 - p0;
    float A = max(dot(D, D), 1e-8);
    float B = 2.0 * dot(p0, D);
    float C = dot(p0, p0) + r2;
    float q2 = max(4.0 * A * C - B * B, 1e-14);
    float q = sqrt(q2);
    float i1 = 2.0 / q * (atan((2.0 * A + B) / q) - atan(B / q));
    float i2 = ((2.0 * A + B) / (A + B + C) - B / C + 2.0 * A * i1) / q2;
    return float2(i1, i2);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 frag = float2(pos.x, u.resolution.y - pos.y);
    float2 uv = frag / u.resolution * 2.0 - 1.0;
    float time = u.time * u.speed;

    // Upstream's slow orbit, with a longer lens: the march spans +-45 units
    // around the origin, the axis the lattice twists about.
    const float camDist = 110.0;
    const float focal = 2.2;
    float mx = u.seed * TWO_PI + time * 0.01;
    float my = sin(time * 0.03 + u.seed * 17.0) * 0.25 + 0.15;
    float3 camPos = float3(cos(my) * cos(mx), sin(my), cos(my) * sin(mx)) * camDist;

    float3 camVec = normalize(-camPos);
    float3 sideNorm = normalize(cross(float3(0.0, 1.0, 0.0), camVec));
    float3 upNorm = cross(camVec, sideNorm);
    float3 relVec = normalize(camVec * focal + uv.x * sideNorm * (u.resolution.x / u.resolution.y) + uv.y * upNorm);

    // Surface blend: `surface` places it on the cycle, `morph` lets time
    // carry it round, dwelling on each family before moving on.
    float m = time * 0.02 + u.seed * 4.0;
    m = floor(m) + smoothstep(0.2, 0.8, fract(m));

    TgyFrame f;
    f.w = tgyWeights(u.surface + u.morph * m);
    f.k = 0.1 * u.scale * (1.0 + 0.12 * sin(time * 0.031 + u.seed * 5.0));
    f.twistRate = u.twist * 0.035 * (1.0 + 0.5 * sin(time * 0.043 + u.seed * 9.0));
    f.spin = time * 0.015;
    f.warpAmp = u.warp * 5.0;
    f.warpPhase = time * 0.04;
    float3 partnerOffset = float3(u.seed * 31.0, time * 0.05, u.seed * 17.0 - time * 0.03);
    f.so = sin(partnerOffset);
    f.co = cos(partnerOffset);

    const float t0 = camDist - 45.0;
    const float maxDepth = camDist + 45.0;
    const float e = 0.004;    // sheet thickness (field units)
    const float r2 = 0.006 * 0.006; // filament radius^2 (field units)
    float bandK = u.bands * PI;
    float dt = (maxDepth - t0) / float(u.steps);
    float t = t0;
    float2 ab0 = tgyField(camPos + relVec * t, f) * 0.3;
    if (bandK > 0.0) ab0.y = sin(ab0.y * bandK) / bandK;
    float3 glow = float3(0.0);
    for (int i = 0; i < u.steps; i++) {
        t += dt;
        float2 ab1 = tgyField(camPos + relVec * t, f) * 0.3;
        // Iso-bands: b = k / bands for every integer k, not just b = 0.
        if (bandK > 0.0) ab1.y = sin(ab1.y * bandK) / bandK;
        // Fade in past the near clip, out with depth; tint toward the
        // partner colour with depth.
        float depth = t - 0.5 * dt - t0;
        float fade = smoothstep(0.0, 14.0, depth) * exp(-depth * 0.02) * dt;
        float3 tint = mix(u.color.rgb, u.accent.rgb, smoothstep(10.0, 80.0, depth));
        // Upstream's 0.1/|a^2 b| glow, made exact: filaments along the
        // curves where surface a meets surface b, and a faint membrane on a.
        float2 tube = tgyTube(ab0, ab1, r2);
        float sheet = u.membrane > 0.0 ? tgySegment(ab0.x, ab1.x, e, 1.0) : 0.0;
        float core = tube.y * r2;
        glow += (tint * (core * 0.03 + tube.x * 0.001) + core * 0.003
               + u.accent.rgb * sheet * u.membrane * 0.0002) * fade;
        ab0 = ab1;
    }

    // Upstream's sqrt "gamma correction".
    float3 color = sqrt(clamp(glow * u.gain, 0.0, 1.0));
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
