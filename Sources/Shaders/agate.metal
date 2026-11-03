// Agate — original shader written for Lerping@Home (AGPL-3.0, like the rest
// of this project). Not a port: no upstream code is used.
// A polished agate slab: nested chalcedony bands that wrap a field of
// nodules, with drusy quartz crystals in the nodule hearts and a slow
// polish sheen. Built from the ideas in The Book of Shaders by Patricio
// Gonzalez Vivo & Jen Lowe — "Cellular Noise" (https://thebookofshaders.com/12/)
// and "Fractal Brownian Motion" (https://thebookofshaders.com/13/), including
// the domain-warping idea that chapter credits to Inigo Quilez — written from
// those explanations; none of the book's example code is copied.
//
// How it is built:
//   - fBm domain warp (two value-noise fBm fields) bends the slab, drifting slowly.
//   - A *smooth* cellular field (soft-minimum of distances to jittered feature
//     points) gives rounded contours that merge between neighbouring nodules —
//     the shape of agate banding, not Voronoi's polygon cells.
//   - The contour value is cut into bands of uneven width, each band given its
//     own tone and a few thin laminae, with milky lines at band boundaries.
//   - Inside each nodule's heart a fine F2 − F1 cellular layer draws quartz
//     facets, shaded by the direction to each crystal's centre.
//   - Bands creep outward from the hearts over time (`flow`).
//
// lerp-param: colorDeep  color          = (0.020, 0.028, 0.050) "Deep band"
// lerp-param: colorBand  color          = (0.150, 0.230, 0.330) "Chalcedony"
// lerp-param: colorMilk  color          = (0.620, 0.690, 0.760) "Milky band"
// lerp-param: colorCore  color          = (0.700, 0.740, 0.800) "Quartz core"
// lerp-param: scale      float 0.3 4    = 1.1  "Nodule scale"
// lerp-param: bands      float 2 40     = 22.0 "Band density"
// lerp-param: sharpness  float 0 1      = 0.7  "Band sharpness"
// lerp-param: milkiness  float 0 1      = 0.12 "Milky bands"
// lerp-param: milkLines  float 0 1      = 0.55 "Milky lines"
// lerp-param: warp       float 0 1.5    = 0.5  "Warp"
// lerp-param: core       float 0 0.4    = 0.10 "Quartz core size"
// lerp-param: sheen      float 0 1      = 0.35 "Polish"
// lerp-param: flow       float 0 1      = 0.35 "Band flow"
// lerp-param: speed      float 0 1      = 0.15 "Speed"
//
// lerp-preset: Carnelian  colorDeep=(0.060, 0.012, 0.008), colorBand=(0.420, 0.090, 0.030)
// lerp-preset: Carnelian  colorMilk=(0.860, 0.620, 0.420), colorCore=(0.900, 0.780, 0.620)
// lerp-preset: Carnelian  bands=14, sharpness=0.5, milkiness=0.18, milkLines=0.4, warp=0.8
// lerp-preset: Carnelian  core=0.07, sheen=0.45
// lerp-preset: Malachite  colorDeep=(0.004, 0.040, 0.026), colorBand=(0.030, 0.240, 0.140)
// lerp-preset: Malachite  colorMilk=(0.250, 0.680, 0.440), colorCore=(0.030, 0.240, 0.140)
// lerp-preset: Malachite  scale=1.3, bands=28, sharpness=0.9, milkiness=0.4, milkLines=0
// lerp-preset: Malachite  warp=0.6, core=0, sheen=0.5, flow=0.2
// lerp-preset: Onyx       colorDeep=(0.010, 0.010, 0.012), colorBand=(0.060, 0.058, 0.060)
// lerp-preset: Onyx       colorMilk=(0.780, 0.760, 0.720), colorCore=(0.600, 0.580, 0.560)
// lerp-preset: Onyx       scale=0.6, bands=9, sharpness=1, milkiness=0.28, milkLines=0.6
// lerp-preset: Onyx       warp=0.45, core=0.05, sheen=0.2, flow=0.25

constant float AG_SOFTNESS = 7.0;   // soft-minimum sharpness of the nodule field
constant float AG_CRYSTALS = 16.0;  // quartz crystals per nodule unit

// Value-noise fBm, each octave rotated so the lattice never lines up. The
// octave count is a literal at every call site, so the loop unrolls.
static inline float agFbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * valueNoise(p);
        p = rotate(p, 0.5) * 2.03 + 17.1;
        amplitude *= 0.5;
    }
    return value;
}

// Smooth cellular field: soft minimum of the distances to the jittered feature
// point of each of the 3x3 neighbouring cells. `.x` is the field, `.yz` is the
// offset to the nearest feature point (its heart), `.w` that point's hash.
static float4 agNodules(float2 x, float t) {
    float2 ip = floor(x);
    float2 fp = fract(x);
    float acc = 0.0;
    float nearest = 8.0;
    float2 nearestR = float2(0.0);
    float nearestH = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 h = hash22(ip + g);
            float2 o = 0.5 + 0.32 * sin(t * 0.35 + TWO_PI * h);
            float2 r = g + o - fp;
            float d = length(r);
            acc += exp(-AG_SOFTNESS * d);
            if (d < nearest) {
                nearest = d;
                nearestR = r;
                nearestH = h.x;
            }
        }
    }
    return float4(-log(acc) / AG_SOFTNESS, nearestR, nearestH);
}

// Plain F1 / F2 cellular noise for the quartz facets. Returns (F2 - F1, offset
// to the nearest crystal centre, that crystal's hash).
static float4 agCrystals(float2 x) {
    float2 ip = floor(x);
    float2 fp = fract(x);
    float f1 = 8.0, f2 = 8.0;
    float2 r1 = float2(0.0);
    float h1 = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 h = hash22(ip + g + 41.0);
            float2 r = g + h - fp;
            float d = length(r);
            if (d < f1) {
                f2 = f1;
                f1 = d;
                r1 = r;
                h1 = h.y;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }
    return float4(f2 - f1, r1, h1);
}

// Tone of band `id`, 0 = deep, 0.5 = chalcedony, 1 = milky.
// Mostly mid chalcedony; a `milk` fraction of bands goes milky, one in ten deep.
static float agTone(float id, float salt, float milk) {
    float h = hash11(id * 0.618 + salt);
    float tone = 0.22 + 0.5 * h;
    tone = mix(tone, 0.97, step(1.0 - milk, h));
    return mix(tone, 0.04, step(h, 0.10));
}

static float3 agRamp(float v, constant LerpUniforms& u) {
    float3 lo = mix(u.colorDeep.rgb, u.colorBand.rgb, smoothstep(0.05, 0.65, v));
    return mix(lo, u.colorMilk.rgb, smoothstep(0.6, 1.0, v));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float t = u.speed * u.time + u.seed * 40.0;
    float salt = floor(u.seed * 977.0);

    // Domain warp: two fBm fields push the slab around, drifting slowly.
    float2 p = uv * u.scale + u.seed * 63.0;
    float2 w = float2(agFbm(p * 0.9 + float2(0.0, 0.11 * t), 4),
                      agFbm(p * 0.9 + float2(5.2, 1.3) - 0.09 * t, 4));
    float2 q = p + u.warp * (2.0 * w - 1.0);

    float4 nod = agNodules(q, t);

    // Band coordinate: the contour value, a little fBm ripple so the bands
    // stay roughly parallel but never perfectly smooth, and a slow outward creep.
    float ripple = 0.7 * (agFbm(q * 5.0 + 3.0, 3) - 0.5);   // in band units
    float b = nod.x * u.bands + ripple - u.flow * t * 1.6;
    // Uneven band widths.
    b += 0.45 * sin(0.73 * b + 1.3) + 0.25 * sin(1.91 * b + 4.0);

    float id = floor(b);
    float f = fract(b);
    float edge = mix(0.5, 0.03, u.sharpness);
    float tone = mix(agTone(id, salt, u.milkiness), agTone(id + 1.0, salt, u.milkiness), smoothstep(1.0 - edge, 1.0, f));
    // Fine laminae inside each band: a few thin sub-bands whose count and
    // contrast change from band to band.
    float subCount = 2.0 + floor(4.0 * hash11(id * 2.11 + salt + 9.0));
    float sub = 0.5 + 0.5 * cos(TWO_PI * f * subCount);
    sub = mix(sub, smoothstep(0.35, 0.65, sub), u.sharpness);
    tone += (0.10 + 0.14 * hash11(id * 0.77 + salt + 3.0)) * (sub - 0.5);
    float3 color = agRamp(clamp(tone, 0.0, 1.0), u);

    // Thin milky lines at some band boundaries.
    float lineW = mix(0.10, 0.04, u.sharpness);
    float line = 1.0 - smoothstep(0.0, lineW, min(f, 1.0 - f));
    line *= step(0.4, hash11(id * 1.37 + salt + 5.0));
    color = mix(color, u.colorMilk.rgb, 0.8 * u.milkLines * line);

    // Quartz heart: crystals where the nodule field dips lowest.
    if (u.core > 0.0) {
        float heart = length(nod.yz);
        float coreR = u.core * (0.7 + 0.6 * nod.w);
        float coreMask = 1.0 - smoothstep(coreR - 0.015, coreR + 0.005, heart);
        if (coreMask > 0.0) {
            float4 cr = agCrystals(q * AG_CRYSTALS);
            float2 lightDir = normalize(float2(cos(0.3 * t), sin(0.3 * t)));
            float facet = 0.5 + 0.5 * dot(normalize(cr.yz + 1e-4), lightDir);
            float3 quartz = u.colorCore.rgb * (0.35 + 0.55 * facet * (0.6 + 0.4 * cr.w));
            quartz = mix(quartz * 0.45, quartz, smoothstep(0.0, 0.08, cr.x));  // facet edges
            float sparkle = pow(max(facet, 0.0), 24.0) * step(0.8, cr.w);
            quartz += u.colorCore.rgb * sparkle * 0.6;
            // A bright chalcedony rind where the bands meet the crystals.
            float rind = smoothstep(coreR - 0.03, coreR, heart);
            quartz = mix(quartz, u.colorMilk.rgb, 0.7 * rind);
            color = mix(color, quartz, coreMask);
        }
    }

    // Polish: a broad, soft reflection drifting across the slab, plus a hint
    // of translucency that lifts the lighter bands.
    float2 sheenDir = normalize(float2(0.8, 0.6));
    float sweep = dot(uv, sheenDir) - 1.6 * sin(0.07 * t);
    float sheen = exp(-2.5 * sweep * sweep);
    color += u.sheen * 0.12 * sheen * (0.4 + dot(color, float3(0.33)));
    color *= 1.0 + 0.15 * u.sheen * (valueNoise(q * 2.0 + 9.0) - 0.5);

    color = lerpDither(color, pos);
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}
