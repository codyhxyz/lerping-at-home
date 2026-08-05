// Heatmap — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
//
// lerp-data: heatmap
//
// Upstream is an image filter with a CPU pre-pass in front of it: its
// `toProcessedHeatmap` box-blurs the source silhouette at three radii and packs
// them into one RGB texture (R contour, G outer blur, B inner blur), and this
// shader flows heat through that. A screensaver has no image to supply, so
// Sources/LerpCore/HeatmapData.swift draws a seeded Lissajous ribbon and runs
// upstream's pre-pass on it verbatim — same integral-image box blurs, same
// radii, same channel packing. Everything from the texture onward is upstream's
// algorithm. Two upstream pieces are dropped because the substitution removes
// the thing they existed for: the image-box fit/scale/rotation (the processed
// texture is generated at the drawable's aspect, so image UV *is* screen UV)
// and with it the soft image frame (`getImgFrame`, baked to 1).

// Preset "Default", except for the grain, which upstream leaves at 0.
constant float HM_CONTOUR    = 0.5;
constant float HM_NOISE      = 0.12;
constant float HM_INNER_GLOW = 0.5;
constant float HM_OUTER_GLOW = 0.5;
constant float HM_ANGLE      = 0.0;   // heatwave direction, degrees
constant float HM_SPEED      = 0.07;  // upstream 0.1, slowed to house pace

// The default preset's thermal ramp, cool to hot.
constant int HM_COLOR_COUNT = 7;
constant float3 HM_COLORS[7] = {
    float3(0.0667, 0.1255, 0.4157), // #11206a deep navy
    float3(0.1216, 0.2314, 0.6353), // #1f3ba2
    float3(0.1843, 0.3882, 0.9059), // #2f63e7
    float3(0.4196, 0.8431, 1.0000), // #6bd7ff pale cyan
    float3(1.0000, 0.9020, 0.4745), // #ffe679
    float3(1.0000, 0.6000, 0.1176), // #ff991e
    float3(1.0000, 0.2980, 0.0000), // #ff4c00 hot orange
};
constant float3 HM_COLOR_BACK = float3(0.0);

// ---------------------------------------------------------------------------
// Upstream's `sst`/`lst` helpers. `sst` is spelled out rather than calling
// smoothstep because the original passes reversed edges (sst(.6, .3, t) and
// friends) — well defined in GLSL, undefined in MSL.

static inline float hmSst(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static inline float hmLst(float e0, float e1, float x) {
    return clamp((x - e0) / (e1 - e0), 0.0, 1.0);
}

static inline float hmCircle(float2 uv, float2 c, float2 r) {
    return 1.0 - hmSst(r.x, r.y, length(uv - c));
}

// The travelling shadow that carves heat out of the shape's interior, verbatim
// from upstream (its hard-coded circles were cut to fit the Apple logo of the
// original demo; over any other silhouette they read as a sweeping wave front).
static float hmShadowShape(float2 uv, float t, float contour) {
    float2 scaledUV = uv;

    // base shape trajectory
    float posY = mix(-1.0, 2.0, t);

    // scaleX while it moves down
    scaledUV.y -= 0.5;
    float mainCircleScale = hmSst(0.0, 0.8, posY) * hmLst(1.4, 0.9, posY);
    scaledUV *= float2(1.0, 1.0 + 1.5 * mainCircleScale);
    scaledUV.y += 0.5;

    // base shape
    float innerR = 0.4;
    float outerR = 1.0 - 0.3 * (hmSst(0.1, 0.2, t) * (1.0 - hmSst(0.2, 0.5, t)));
    float s = hmCircle(scaledUV, float2(0.5, posY - 0.2), float2(innerR, outerR));
    s = pow(s, 1.4);
    s *= 1.2;

    // flat gradient that takes over the shadow shape
    {
        float p = posY - uv.y;
        float edge = 1.2;
        float topFlattener = hmLst(-0.4, 0.0, p) * (1.0 - hmSst(0.0, edge, p));
        topFlattener = pow(topFlattener, 3.0);
        float topFlattenerMixer = 1.0 - hmSst(0.0, 0.3, p);
        s = mix(topFlattener, s, topFlattenerMixer);
    }

    // right circle
    {
        float visibility = hmSst(0.6, 0.7, t) * (1.0 - hmSst(0.8, 0.9, t));
        float angle = -2.0 - t * TWO_PI;
        float rightCircle = hmCircle(uv, float2(0.95 - 0.2 * cos(angle),
                                                0.4 - 0.1 * sin(angle)), float2(0.15, 0.3));
        rightCircle *= visibility;
        s = mix(s, 0.0, rightCircle);
    }

    // top circle
    {
        float topCircle = hmCircle(uv, float2(0.5, 0.19), float2(0.05, 0.25));
        topCircle += 2.0 * contour * hmCircle(uv, float2(0.5, 0.19), float2(0.2, 0.5));
        float visibility = 0.55 * hmSst(0.2, 0.3, t) * (1.0 - hmSst(0.3, 0.45, t));
        topCircle *= visibility;
        s = mix(s, 0.0, topCircle);
    }

    float leafMask = hmCircle(uv, float2(0.53, 0.13), float2(0.08, 0.19));
    leafMask = mix(leafMask, 0.0, 1.0 - hmSst(0.4, 0.54, uv.x));
    leafMask = mix(0.0, leafMask, hmSst(0.0, 0.2, uv.y));
    leafMask *= (hmSst(0.5, 1.1, posY) * hmSst(1.5, 1.3, posY));
    s += leafMask;

    // bottom circle
    {
        float visibility = hmSst(0.0, 0.4, t) * (1.0 - hmSst(0.6, 0.8, t));
        s = mix(s, 0.0, visibility * hmCircle(uv, float2(0.52, 0.92), float2(0.09, 0.25)));
    }

    // drifting satellites
    {
        float p = hmSst(0.0, 0.6, t) * (1.0 - hmSst(0.6, 1.0, t));
        s = mix(s, 0.5, hmCircle(uv, float2(0.0, 1.2 - 0.5 * p), float2(0.1, 0.3)));
        s = mix(s, 0.0, hmCircle(uv, float2(1.0, 0.5 + 0.5 * p), float2(0.1, 0.3)));

        s = mix(s, 1.0, hmCircle(uv, float2(0.95, 0.2 + 0.2 * hmSst(0.3, 0.4, t) * hmSst(0.7, 0.5, t)),
                                 float2(0.07, 0.22)));
        s = mix(s, 1.0, hmCircle(uv, float2(0.95, 0.2 + 0.2 * hmSst(0.3, 0.4, t) * (1.0 - hmSst(0.5, 0.7, t))),
                                 float2(0.07, 0.22)));
        s /= max(1e-4, hmSst(1.0, 0.85, uv.y));
    }

    // Upstream writes `clamp(0., 1., s)`, which under GLSL's (x, minVal, maxVal)
    // argument order evaluates to min(1., s) — there is no lower clamp, and s
    // does go negative where the contour-fed top circle exceeds 1. Kept as-is:
    // that overshoot brightens the shape and is part of the look.
    return min(1.0, s);
}

// Upstream's extra 3x3 tap on the outer-blur channel, which softens the seam
// where the big blur meets the silhouette. Upstream reaches for textureGrad to
// pin the mip level; this texture is only ever magnified, so a plain sample is
// the same thing.
static float hmBlurEdge3x3(texture2d<float> tex, float2 uv, float radius, float centerSample) {
    float2 texel = 1.0 / float2(tex.get_width(), tex.get_height());
    float2 r = radius * texel;

    float sum = 4.0 * centerSample;
    sum += 2.0 * tex.sample(lerpHeatmapSampler, uv + float2(0.0, -r.y)).g;
    sum += 2.0 * tex.sample(lerpHeatmapSampler, uv + float2(0.0,  r.y)).g;
    sum += 2.0 * tex.sample(lerpHeatmapSampler, uv + float2(-r.x, 0.0)).g;
    sum += 2.0 * tex.sample(lerpHeatmapSampler, uv + float2( r.x, 0.0)).g;

    sum += tex.sample(lerpHeatmapSampler, uv + float2(-r.x, -r.y)).g;
    sum += tex.sample(lerpHeatmapSampler, uv + float2( r.x, -r.y)).g;
    sum += tex.sample(lerpHeatmapSampler, uv + float2(-r.x,  r.y)).g;
    sum += tex.sample(lerpHeatmapSampler, uv + float2( r.x,  r.y)).g;

    return sum / 16.0;
}

// ---------------------------------------------------------------------------

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        texture2d<float> processed [[texture(1)]]) {
    float2 screenUV = lerpScreenUV(pos, u.resolution);   // 0..1, y down
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);

    float2 imgUV = screenUV;
    float4 img = processed.sample(lerpHeatmapSampler, imgUV);

    // Three copies of the same wave, a third of a cycle apart.
    float t = HM_SPEED * u.time - 0.3 + u.seed;
    float tCopy  = t + 1.0 / 3.0;
    float tCopy2 = t + 2.0 / 3.0;
    t      = glmod(t,      1.0);
    tCopy  = glmod(tCopy,  1.0);
    tCopy2 = glmod(tCopy2, 1.0);

    // Aspect-corrected so the waves are not stretched on a wide drawable. y
    // stays 0..1 either way, which upstream's shape math assumes.
    float2 animationUV = float2((screenUV.x - 0.5) * aspect, screenUV.y - 0.5);
    float angle = -HM_ANGLE * PI / 180.0;
    float cosA = cos(angle), sinA = sin(angle);
    animationUV = float2(animationUV.x * cosA - animationUV.y * sinA,
                         animationUV.x * sinA + animationUV.y * cosA) + 0.5;

    float shape = img.r;
    float bigBlur = hmBlurEdge3x3(processed, imgUV, 8.0, img.g);

    float outerBlur = 1.0 - mix(1.0, bigBlur, shape);   // halo outside the shape
    float innerBlur = mix(bigBlur, 0.0, shape);         // bleed inside it
    float contour   = mix(img.b, 0.0, shape);           // rim just inside the edge

    float shadow      = hmShadowShape(animationUV, t,      innerBlur);
    float shadowCopy  = hmShadowShape(animationUV, tCopy,  innerBlur);
    float shadowCopy2 = hmShadowShape(animationUV, tCopy2, innerBlur);

    float inner = 0.8 + 0.8 * innerBlur;
    inner = mix(inner, 0.0, shadow);
    inner = mix(inner, 0.0, shadowCopy);
    inner = mix(inner, 0.0, shadowCopy2);

    inner *= mix(0.0, 2.0, HM_INNER_GLOW);
    inner += (HM_CONTOUR * 2.0) * contour;
    inner = min(1.0, inner);
    inner *= (1.0 - shape);

    float outer = 0.0;
    {
        float ot = glmod(3.0 * t - 0.1, 1.0);
        outer = 0.9 * pow(outerBlur, 0.8);
        float y = glmod(animationUV.y - ot, 1.0);
        float animatedMask = hmSst(0.3, 0.65, y) * (1.0 - hmSst(0.65, 1.0, y));
        animatedMask = 0.5 + animatedMask;
        outer *= animatedMask;
        outer *= mix(0.0, 5.0, pow(HM_OUTER_GLOW, 2.0));
    }

    inner = pow(inner, 1.2);
    float heat = clamp(inner + outer, 0.0, 1.0);

    float2 grainUV = screenUV + u.seed;
    heat += (0.005 + 0.35 * HM_NOISE) *
            (fract(sin(dot(grainUV, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Walk the ramp. The first step doubles as the overall coverage, so the
    // graphic fades into the background instead of ending on a hard edge.
    float mixer = heat * float(HM_COLOR_COUNT);
    float3 gradient = HM_COLORS[0];
    float outerShape = 0.0;
    for (int i = 1; i <= HM_COLOR_COUNT; ++i) {
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        if (i == 1) outerShape = m;
        gradient = mix(gradient, HM_COLORS[i - 1], m);
    }

    float3 color = gradient * outerShape + HM_COLOR_BACK * (1.0 - outerShape);
    color += 0.02 * (fract(sin(dot(grainUV + 1.0, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
