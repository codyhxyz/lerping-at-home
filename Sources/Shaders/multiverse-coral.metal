// Multiverse Coral — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, each sample folded a few times and
// lit by how its orbit behaves, so the frame is a stack of glowing
// cross-sections rather than a shaded surface. The fold, the light, the
// camera and the colouring here are this file's own.
//
// The fractal is the sphere-inversion Apollonian packing (fold space into a
// repeating cube, invert in the unit sphere, repeat), which is periodic, so
// the slab can drift forward forever without leaving it. Each of 14 layers
// runs 8 folds; the running inversion scale turns the final distance to the
// unit sphere into a distance in world space, so the lace stays thin at
// every depth of the packing, and the orbit's closest approach to the
// centre lights pearls of brighter, whiter glow where the inversions
// cluster. The layers spread slightly with depth (a little perspective) and
// fade from teal to violet, so the far filaments read as further down.
//
// u.seed picks where on the drift each activation begins. `inversion`
// drifts slowly (lerp-animate), swelling and thinning the strands.
//
// GPU cost: 14 layers x 8 folds, no trig in the loop, and each layer's
// sample point is one multiply-add from a per-pixel origin and step.
// LerpPreview --bench, Apple M5, 3840x2160: within about 0-10% of
// fractal-multiverse measured in the same run (~9 ms), every look.
//
// lerp-param: speed     float 0 2      = 0.5   "Speed"
// lerp-param: inversion float 1.0 1.4  = 1.15  "Inversion"
// lerp-animate: inversion 1.08 1.24 period=190
// lerp-param: lace      float 400 4000 = 1500  "Lace sharpness"
// lerp-param: pearls    float 0 4      = 2.0   "Pearls"
// lerp-param: glow      float 0.2 3    = 1.0   "Glow"
// lerp-param: zoom      float 0.8 4    = 1.6   "Zoom"
// lerp-param: near      color          = (0.12, 0.95, 0.78) "Near (teal)"
// lerp-param: far       color          = (0.52, 0.24, 1.0)  "Far (violet)"
//
// lerp-preset: Abyss    zoom=2.6, speed=0.3, glow=1.3, far=(0.30, 0.16, 0.85)
// lerp-preset: Plankton pearls=4.0, lace=2500, inversion=1.3
// lerp-preset: Kelp     near=(0.55, 1.0, 0.45), far=(0.05, 0.55, 0.75), zoom=1.2

// The view: a fixed tilt of 0.7 rad about x, so the cube lattice never
// lines up with the screen, then a slow turn (cos, sin) about y.
static inline float3 mcoView(float3 v, float2 turn) {
    const float co = 0.7648, so = 0.6442;               // cos, sin of 0.7
    v.yz = float2(co * v.y - so * v.z, so * v.y + co * v.z);
    v.xz = float2(turn.x * v.x - turn.y * v.z, turn.y * v.x + turn.x * v.z);
    return v;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;

    float2 xy = rotate(uv, 0.02 * t) * u.zoom;
    // Forward drift through the periodic packing, with a slow sway.
    float3 drift = float3(0.3 * sin(0.05 * t), 0.2 * cos(0.04 * t), 0.05 * t);
    float yaw = 0.49 + 0.03 * t;
    float2 turn = float2(cos(yaw), sin(yaw));
    // Layer L samples view((xy * (1 + 0.5 L), L) + drift), which is linear
    // in L, so it is built once here as origin + L * step.
    float3 flat = mcoView(float3(xy, 0.0), turn);
    float3 origin = flat + mcoView(drift, turn);
    float3 step = 0.5 * flat + mcoView(float3(0.0, 0.0, 1.0), turn);

    float3 col = float3(0.0);
    for (int i = 0; i < 14; i++) {
        float layer = float(i) / 14.0;
        float3 q = origin + step * layer;

        float scale = 1.0;
        float trap = 1e9;
        for (int j = 0; j < 8; j++) {
            q = -1.0 + 2.0 * fract(0.5 * q + 0.5);       // repeat the cube
            float r2 = dot(q, q);
            trap = min(trap, r2);
            float k = u.inversion / r2;                  // invert
            q *= k;
            scale *= k;
        }
        float d = 0.25 * abs(length(q) - 1.0) / scale;   // world-space lace distance
        float pearl = exp(-trap * 20.0);
        float light = exp(-d * u.lace) * (0.3 + u.pearls * pearl);

        float3 tint = mix(u.near.rgb, u.far.rgb, smoothstep(0.1, 0.9, layer));
        tint = mix(tint, float3(0.85, 1.0, 0.96), pearl);
        col += tint * light * 0.75;
    }
    col *= u.glow;

    float3 color = 1.0 - exp(-col);
    color += float3(0.0, 0.006, 0.014);                  // deep water, not void
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
