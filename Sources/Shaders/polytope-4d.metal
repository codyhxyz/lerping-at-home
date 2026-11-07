// Polytope 4D — original work for Lerping@Home, not a port.
//
// lerp-data: polytope-4d
//
// Regular four-dimensional polytopes turning in a double rotation — two
// completely orthogonal planes at once, one of them containing w, so the
// figure keeps passing through itself — projected into 3D and drawn as
// glowing glass tubes with beads at the vertices. Colour and brightness are
// cued by w: warm toward the 4D viewer, cool away from it.
//
// The CPU side (Sources/LerpCore/Polytope4DData.swift) builds the vertex sets
// from their textbook coordinates (tesseract (±½,±½,±½,±½); 16-cell ±e_i;
// 24-cell = the 24 Hurwitz units; 600-cell = the 120 unit icosians; 120-cell
// from the standard seven permutation classes; p,q-duoprism on the Clifford
// torus), takes edges as the nearest-neighbour pairs, rotates and projects
// them every frame from (time, seed, params) alone, and bins the result into
// screen tiles. This file shades the tiles.
//
// Projection: perspective from a 4D eye on the w axis (edges stay straight),
// or stereographic from the pole of S³ — conformal, so every great-circle
// edge becomes a true circular arc (adaptively subdivided on the CPU) and the
// tubes swell as they swing toward the pole, fading out before they reach it.
//
// polytope: 0 tesseract (8-cell), 1 16-cell, 2 24-cell, 3 600-cell,
//           4 120-cell, 5 p,q-duoprism (duoP x duoQ; large p = q is a grid
//           on the Clifford torus).
//
// lerp-param: polytope      int 0 5      = 0     "Polytope"
// lerp-param: stereographic bool         = false "Stereographic"
// lerp-param: duoP          int 3 32     = 6     "Duoprism p"
// lerp-param: duoQ          int 3 32     = 6     "Duoprism q"
// lerp-param: speed         float 0 2    = 0.5   "Speed"
// lerp-param: twist         float 0 2    = 0.62  "3D spin / 4D spin"
// lerp-param: eye4          float 1.2 6  = 2.4   "4D eye distance"
// lerp-animate: eye4          2.0 3.0 period=150
// lerp-param: zoom          float 0.4 2  = 1.0   "Zoom"
// lerp-param: tube          float 0.001 0.04 = 0.011 "Edge thickness"
// lerp-param: node          float 0 0.08 = 0.026 "Vertex size"
// lerp-param: glow          float 0 1    = 0.5   "Glow"
// lerp-param: glass         float 0 1    = 0.6   "Glass"
// lerp-param: depthCue      float 0 1    = 0.7   "Depth cue (w)"
// lerp-param: brightness    float 0.2 3  = 1.0   "Brightness"
// lerp-param: colorNear     color        = (0.96, 0.64, 0.42) "Near (w+)"
// lerp-param: colorFar      color        = (0.20, 0.50, 0.86) "Far (w-)"
// lerp-param: background    color        = (0.010, 0.014, 0.028) "Background"
// lerp-param: yaw           float -180 180 = 0 "Turn"
// lerp-param: pitch         float -90 90 = 0 "Tilt"
//
// lerp-preset: "16-Cell"        polytope=1, eye4=2.1, tube=0.013, node=0.03
// lerp-preset: "24-Cell"        polytope=2, eye4=2.6, tube=0.008, node=0.02, glass=0.75, colorNear=(0.90, 0.80, 0.55), colorFar=(0.30, 0.42, 0.80)
// lerp-preset: "600-Cell"       polytope=3, stereographic=true, tube=0.006, node=0.013, glow=0.45, colorNear=(0.98, 0.55, 0.50), colorFar=(0.25, 0.60, 0.78)
// lerp-preset: "120-Cell"       polytope=4, stereographic=true, tube=0.0035, node=0, glow=0.35, glass=0.4, speed=0.35, colorNear=(0.70, 0.90, 0.85), colorFar=(0.30, 0.32, 0.75)
// lerp-preset: "Clifford Torus" polytope=5, duoP=24, duoQ=24, stereographic=true, tube=0.004, node=0.008, glow=0.4, twist=0.4, colorNear=(0.95, 0.75, 0.45), colorFar=(0.55, 0.30, 0.80)

static inline float p4Sq(float x) { return x * x; }

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpP4Frame& F [[buffer(1)]],
                        device const LerpP4Seg* segs [[buffer(2)]],
                        device const uint2* tiles [[buffer(3)]],
                        device const uint* indices [[buffer(4)]]) {
    float2 p = pos.xy;
    uint2 tc = min(uint2(max(p, 0.0)) / F.tileSize, F.tiles - 1u);
    uint2 h = tiles[tc.y * F.tiles.x + tc.x];

    float glass = saturate(u.glass);
    float glow = saturate(u.glow);
    float g = max(F.glowPx, 1e-3);
    float3 L = normalize(float3(-0.45, 0.55, 0.70));

    // Additive between edges; within one edge (sub-segments of an arc share
    // an id and arrive consecutively) take the strongest, so joints of a
    // subdivided arc do not double up.
    float3 acc = float3(0.0);
    float3 best = float3(0.0);
    float bestD = 1e30;
    float curId = -1e30;

    for (uint i = 0u; i < h.y; i++) {
        LerpP4Seg s = segs[indices[h.x + i]];
        float2 a = s.ends.xy, b = s.ends.zw;
        float2 pa = p - a, ba = b - a;
        float l2 = dot(ba, ba);
        float t = l2 > 1e-6 ? saturate(dot(pa, ba) / l2) : 0.0;
        float4 at = mix(s.a0, s.a1, t);
        float2 q = pa - ba * t;
        float d = length(q);
        float re = max(at.x, 0.6);
        if (d > re + F.glowPx + 1.0) continue;

        if (s.a0.w != curId) { acc += best; best = float3(0.0); bestD = 1e30; curId = s.a0.w; }
        // Within one arc the nearest sub-segment owns the pixel.
        if (d >= bestD) continue;
        bestD = d;

        float thin = at.x / re;               // sub-pixel tubes fade by width
        float x = min(d / re, 1.0);
        float nz = sqrt(saturate(1.0 - x * x));
        float cover = saturate(re - d + 0.5);
        float3 base = mix(u.colorFar.rgb, u.colorNear.rgb, at.y);

        float body, spec;
        if (s.a0.w < 0.0) {
            // Vertex bead: a lit sphere, solid when glowing, a rimmed lens as glass.
            float3 n = float3(q.x / re, -q.y / re, nz);
            float diff = saturate(dot(n, L));
            spec = pow(saturate(dot(reflect(-L, n), float3(0.0, 0.0, 1.0))), 28.0) * (0.5 + 0.8 * glass);
            body = mix(0.45 + 0.75 * diff, 0.18 + 1.1 * p4Sq(1.0 - nz) + 0.35 * diff, glass);
        } else {
            // Tube cross-section: bright core when glowing, bright rims and a
            // specular stripe on one side as glass.
            float side = (ba.x * pa.y - ba.y * pa.x) < 0.0 ? -1.0 : 1.0;
            float xs = x * side;
            body = mix(0.40 + 0.75 * nz, 0.12 + 1.0 * p4Sq(1.0 - nz) + 0.15 * nz, glass);
            spec = exp(-p4Sq((xs + 0.42) / 0.2)) * (0.15 + 0.75 * glass);
        }
        float halo = glow * 0.5 * p4Sq(p4Sq(saturate(1.0 - max(d - re, 0.0) / g)));
        float w = at.z * thin;
        best = w * (base * (cover * body + halo) + cover * spec * float3(0.92, 0.95, 1.0));
    }
    acc += best;

    float2 uv = lerpUV(pos, u.resolution);
    float3 bg = u.background.rgb * (1.25 - 0.3 * min(length(uv), 1.6));
    float3 color = 1.0 - (1.0 - bg) * exp(-1.5 * u.brightness * acc);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
