// Multiverse Cathedral — original work for Lerping@Home (AGPL-3.0)
//
// Written in the idiom of Yohei Nishitsuji's "fractal, the multiverse"
// (MIT; see fractal-multiverse.metal for its notice): a short fixed march
// through a thin slab of fractal space, where every sample is folded a few
// times and lights the pixel by how its orbit behaves, so the picture is a
// stack of glowing cross-sections rather than a shaded surface. The fold,
// the light, the camera and the colouring here are this file's own.
//
// The fractal is Tom Lowe's Mandelbox (box fold, then sphere fold, then
// scale and add the starting point) at a negative scale, whose sections are
// full of pointed lancets, ribbed vaults and concentric rose windows. Each of
// 14 layers through the slab runs 8 folds and keeps the closest its orbit
// comes to the unit sphere: that orbit trap draws the thin tracery (a sharp
// exp falloff) over a soft haze (a broad one). The picture is mirrored about
// the vertical axis, as a nave is, and the slab glides slowly through the
// box while it turns, so arcades open, close and re-form. Near layers are
// amber, far layers rose, so the depth of each line is its colour.
//
// u.seed picks where on the route each activation begins. `foldScale`
// drifts slowly (lerp-animate), which morphs the tracery continuously.
//
// GPU cost: 14 layers x 8 folds, no trig or square root in the loop.
// LerpPreview --bench, Apple M5, 3840x2160: within about 5-10% of
// fractal-multiverse measured in the same run (~9-10 ms when it reads
// ~8.7-9.3), every look.
//
// lerp-param: speed     float 0 2        = 0.5   "Speed"
// lerp-param: foldScale float -2.2 -1.5  = -1.8  "Fold scale"
// lerp-animate: foldScale -1.9 -1.72 period=210
// lerp-param: tracery   float 20 120     = 42    "Tracery sharpness"
// lerp-param: glow      float 0.2 3      = 1.0   "Glow"
// lerp-param: zoom      float 0.8 2.5    = 1.3   "Zoom"
// lerp-param: near      color            = (1.0, 0.70, 0.36) "Near (amber)"
// lerp-param: far       color            = (0.92, 0.27, 0.42) "Far (rose)"
//
// lerp-preset: "Rose Window" foldScale=-2.0, zoom=1.5
// lerp-preset: Lancet        foldScale=-1.6, tracery=60, zoom=1.2
// lerp-preset: Vespers       near=(0.95, 0.55, 0.22), far=(0.45, 0.16, 0.42), glow=0.8, speed=0.3

static inline float3x3 mcRotY(float a, float tilt) {
    float c = cos(a), s = sin(a), ct = cos(tilt), st = sin(tilt);
    // Yaw about y, then a fixed small pitch about x.
    float3x3 yaw = float3x3(float3(c, 0.0, -s), float3(0.0, 1.0, 0.0), float3(s, 0.0, c));
    float3x3 pitch = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, ct, st), float3(0.0, -st, ct));
    return pitch * yaw;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 400.0;
    uv.x = abs(uv.x);                                   // the nave's mirror

    float2 xy = uv * u.zoom * (1.0 + 0.08 * sin(0.13 * t));
    float3x3 turn = mcRotY(0.05 * t, 0.12 * sin(0.041 * t));
    // The slab's route through the box: a slow, never-repeating glide.
    float3 route = float3(0.25 * sin(0.017 * t), 0.6 * sin(0.031 * t), 1.5 * sin(0.023 * t));

    const float S = u.foldScale;
    const float minR2 = 0.09;                           // inner sphere radius 0.3

    // turn * (xy, z) + route, split so each layer only adds z * column 3.
    float3 base = turn * float3(xy, 0.0) + route;
    float3 axis = turn[2];

    float3 col = float3(0.0);
    for (int i = 0; i < 14; i++) {
        float layer = float(i) / 14.0;
        float3 p = base + axis * (2.0 * layer);
        float3 q = p;
        float trap = 1e9;
        for (int j = 0; j < 8; j++) {
            q = clamp(q, -1.0, 1.0) * 2.0 - q;          // box fold
            float r2 = dot(q, q);
            q *= clamp(1.0 / r2, 1.0, 1.0 / minR2) * S; // sphere fold, scale
            q += p;
            // Closest approach to the unit sphere (|q|^2 - 1 ~ 2(|q| - 1)
            // near it); later folds pay a little so the coarse tracery
            // wins over fine dust.
            trap = min(trap, 0.5 * abs(dot(q, q) - 1.0) + 0.01 * float(j));
        }
        float line = exp(-trap * u.tracery);
        float haze = exp(-trap * 7.0);
        float3 tint = mix(u.near.rgb, u.far.rgb, smoothstep(0.2, 0.8, layer));
        // The hottest cores of the tracery burn whiter.
        tint = mix(tint, float3(1.0, 0.9, 0.78), 0.3 * line);
        col += tint * (0.257 * line + 0.0154 * haze);
    }
    col *= u.glow;

    float3 color = 1.0 - exp(-col * 1.6);
    color += float3(0.012, 0.004, 0.008);               // a nave is never quite black
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
