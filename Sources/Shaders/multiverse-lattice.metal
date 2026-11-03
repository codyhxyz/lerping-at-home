// Multiverse Lattice — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, each sample folded a few times and
// lit by how its orbit behaves, so the frame is a stack of glowing
// cross-sections rather than a shaded surface. The fold, the light, the
// camera and the colouring here are this file's own.
//
// The fold is four-dimensional. Each sample becomes (x, y, z, w) and runs 8
// rounds of: mirror every axis, sort x >= y >= z (the octahedral
// kaleidoscope of a KIFS), turn the xw and yz planes together (a double
// rotation, which has no 3D counterpart), then Kali's inversion
// |q| / q.q - c. Space repeats every 2.4 units first, and the first fold is
// a mirror, so the repetition has no seams and the slab can drift forever.
// Each layer keeps the orbit's closest approach to the unit 3-sphere,
// paying a little for every later round, and draws it as fine faceted
// lines over a faint blue frost. Near layers are ice-white, middle cyan,
// far gold.
//
// The `twist` angle is the double rotation: it changes which of the 4D
// crystal's facets this 3D slice cuts through, so as it drifts
// (lerp-animate) the lattice slowly turns inside out. u.seed picks where
// on the drift each activation begins.
//
// GPU cost: 11 layers x 8 rounds. The sort is a min/max network, and since
// every step but the inversion keeps |q|, one dot product per round serves
// both the inversion and the trap. LerpPreview --bench, Apple M5,
// 3840x2160: within about 0-10% of fractal-multiverse measured in the same
// run (~9 ms), every look.
//
// lerp-param: speed  float 0 2       = 0.5  "Speed"
// lerp-param: twist  float 0 1       = 0.4  "4D twist"
// lerp-animate: twist 0.28 0.52 period=240
// lerp-param: facets float 30 200    = 80   "Facet sharpness"
// lerp-param: frost  float 0 0.1     = 0.03 "Frost"
// lerp-param: glow   float 0.2 3     = 1.0  "Glow"
// lerp-param: zoom   float 0.5 2     = 1.0  "Zoom"
// lerp-param: ice    color           = (0.90, 0.98, 1.0)  "Near (ice)"
// lerp-param: cyan   color           = (0.25, 0.85, 1.0)  "Middle (cyan)"
// lerp-param: gold   color           = (1.0, 0.70, 0.25)  "Far (gold)"
//
// lerp-preset: Geode    zoom=0.7, facets=60, gold=(1.0, 0.55, 0.2), glow=0.7, frost=0.015
// lerp-preset: Rime     facets=140, frost=0.012, glow=1.4, cyan=(0.55, 0.8, 1.0), gold=(0.8, 0.88, 1.0)
// lerp-preset: Quasar   twist=animate(0.15, 0.75, period=300), speed=0.3

constant int LM_LAYERS = 11;
constant int LM_ROUNDS = 8;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;

    float2 xy = rotate(uv, 0.02 * t) * u.zoom;
    // The slab stays square to the crystal, so its axes and mirror planes
    // line up with the screen's; it drifts forward through the repeating
    // cells and wanders sideways across them.
    float3 drift = float3(0.7 * sin(0.021 * t), 0.6 * cos(0.017 * t), 0.05 * t);
    float ca = cos(u.twist), sa = sin(u.twist);
    float cb = cos(0.7 * u.twist + 0.3), sb = sin(0.7 * u.twist + 0.3);
    float w0 = 0.2 + 0.1 * sin(0.05 * t);
    const float4 c = float4(0.6);
    const float period = 2.4;

    // Layer L samples (xy * (1 + 0.4 L), 1.6 L) + drift.
    float3 origin = float3(xy, 0.0) + drift;
    float3 step = float3(0.4 * xy, 1.6);

    float3 col = float3(0.0);
    for (int i = 0; i < LM_LAYERS; i++) {
        float layer = float(i) / float(LM_LAYERS);
        float3 p = origin + step * layer;
        p = glmod3(p + 0.5 * period, period) - 0.5 * period;

        float4 q = float4(p, w0);
        float r2 = dot(q, q);
        float trap = 1e9;
        for (int j = 0; j < LM_ROUNDS; j++) {
            q = abs(q);
            // Octahedral sort x >= y >= z as a min/max network.
            float a = max(q.x, q.y), b = min(q.x, q.y);
            float m = min(a, q.z);
            q.xyz = float3(max(a, q.z), max(b, m), min(b, m));
            // Double rotation in the xw and yz planes.
            q.xw = float2(ca * q.x - sa * q.w, sa * q.x + ca * q.w);
            q.yz = float2(cb * q.y - sb * q.z, sb * q.y + cb * q.z);
            // Kali's inversion. Mirrors, the sort and rotations keep |q|,
            // so r2 from the last round is still q.q here.
            q = abs(q) / max(r2, 1e-3) - c;
            r2 = dot(q, q);
            // Closest approach to the unit 3-sphere (|q|^2 - 1 ~ 2(|q| - 1)
            // near it), later rounds paying a little.
            trap = min(trap, 0.5 * abs(r2 - 1.0) + 0.012 * float(j));
        }
        float line = exp(-trap * u.facets);
        float frost = u.frost * exp(-trap * 12.0);

        float3 tint = mix(u.ice.rgb, u.cyan.rgb, smoothstep(0.05, 0.45, layer));
        tint = mix(tint, u.gold.rgb, smoothstep(0.45, 0.85, layer));
        col += tint * line + float3(0.1, 0.35, 0.6) * frost;
    }
    col *= 1.5 * u.glow;

    float3 color = 1.0 - exp(-col);
    color += float3(0.0, 0.004, 0.01);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
