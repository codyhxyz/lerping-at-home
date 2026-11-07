// Lens Distortion — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Upstream is an image filter: it splits a picture into up to 50 colour
// layers fanned out along a spread axis (chromatic aberration), and warps the
// geometry into a barrel, pincushion or circular fisheye. A screensaver has no
// picture, so the sampler is replaced with a procedural plate — a faint
// drafting grid with a few bold pale shapes drifting across it — because the
// effect only shows where there are edges to split. Everything that happens
// to the plate — the lens warp, the spread axis and its focus / swirl / noise
// / grain shaping, the biased fan of taps and the per-layer hue weights — is
// the upstream algorithm.
//
// Deviations, all forced by the substitution:
//   - The plate is opaque and fills the screen, so upstream's "over white"
//     transparency handling (sampleOverWhite, the ground/alpha recovery) is
//     dropped and the image frame is baked to 1. Where a strong bulge fades
//     the corners out, they fade to `colorBack`.
//   - The image box is the screen (upstream's `fit: contain` on an image the
//     drawable's shape), so the sizing props are not ported.
//   - `speed` is this port's own addition; upstream is static. It drives the
//     plate, never the lens: the shapes orbit and the drafting grid pans
//     slowly. Without the pan, Fisheye — which magnifies only the middle of
//     the plate — sat still whenever the shapes were outside it (0.6-28% of
//     pixels changing per 2 s); with it, 11-33%.
//
// Parameters mirror the upstream <LensDistortion> props. `count` is upstream's
// float prop floored, as upstream does, so it is exposed as an int.
//
// Cost: upstream's 35 layers mean 35 evaluations of the procedural plate per
// pixel where upstream takes 35 texture taps — about 15 ms a frame at
// 3024x1964 on an M5. This port defaults to 20 layers (~8.6 ms, in line with
// the raymarched fractals) and hides the steps that fewer layers leave in
// the fringes by jittering each pixel's taps by up to half a layer along the
// fan, from a fixed per-pixel hash so frames stay pure. The jitter fades out
// below ~8 layers, where the layers are meant to read as distinct (Duotone).
//
// lerp-category: Patterns
// lerp-param: colorBack       color         = (0.012, 0.014, 0.024) "Background"
// lerp-param: spread          float 0 1     = 0.6  "Spread"
// lerp-param: bias            float -1 1    = 1.0  "Bias"
// lerp-param: angle           float 0 360   = 0.0  "Angle"
// lerp-param: perspective     float 0 1     = 0.1  "Perspective"
// lerp-param: count           int 2 50      = 20   "Layers"
// lerp-param: dispersion      float 0 1     = 1.0  "Dispersion"
// lerp-param: dispersionShift float -1 1    = 0.0  "Dispersion shift"
// lerp-param: dispersionColor float 0 1     = 0.6  "Dispersion colour"
// lerp-param: focusCenter     float 0 1     = 0.8  "Focus centre"
// lerp-param: focusEdges      float 0 1     = 1.0  "Focus edges"
// lerp-param: swirl           float -1 1    = 0.35 "Swirl"
// lerp-param: noise           float 0 1     = 0.0  "Noise"
// lerp-param: noiseFrequency  float 0 1     = 0.25 "Noise frequency"
// lerp-param: noiseOffset     float 0 1     = 0.0  "Noise offset"
// lerp-param: lensBulge       float -1 1    = 0.0  "Lens bulge"
// lerp-param: lensCircle      float 0 1     = 0.0  "Lens circle"
// lerp-param: grainMixer      float 0 1     = 0.0  "Grain mixer"
// lerp-param: grainOverlay    float 0 1     = 0.0  "Grain overlay"
// lerp-param: imageX          float -1 1    = 0.0  "Image X"
// lerp-param: imageY          float -1 1    = 0.0  "Image Y"
// lerp-param: speed           float 0 2     = 0.25 "Plate speed"
//
// lerp-animate: dispersionColor 0.45 0.8 period=240
//
// Upstream presets (its Default is this file's defaults, at 20 layers; Smoke
// is capped from 50 layers to 24 for the same reason).
// lerp-preset: Fisheye spread=0.7, perspective=0.75, count=15, dispersionColor=0.7
// lerp-preset: Fisheye focusCenter=0.9, swirl=1, lensBulge=0.95, lensCircle=1, grainMixer=0.5
// lerp-preset: Duotone spread=0.1, bias=0, perspective=0, count=2, dispersionColor=0.1
// lerp-preset: Duotone focusCenter=0, focusEdges=0, swirl=0, grainMixer=0.1, grainOverlay=0.3
// lerp-preset: Smoke   spread=0.65, bias=-1, perspective=0.4, count=24, dispersion=0
// lerp-preset: Smoke   dispersionColor=0.31, focusCenter=0, focusEdges=0.6, swirl=0
// lerp-preset: Smoke   noise=1, noiseFrequency=0.35, noiseOffset=0.3

constant int LD_MAX_SAMPLES = 50;

// ---------------------------------------------------------------------------
// The plate that stands in for u_image. `p` is image UV (0..1, y down, as
// upstream samples), returned colour is opaque.

// Everything about the plate that depends only on time, computed once per
// pixel rather than once per tap: up to 50 taps share it.
struct LdPlateFrame {
    float2 c0, c1, c2, c3;
    float2 barCS;      // cos/sin of the bar's rotation
    float2 grid;       // the drafting grid's slow pan
    float aspect, px;
};

static LdPlateFrame ldPlateFrame(float aspect, float t, float px) {
    LdPlateFrame f;
    // A ring, a disc, a rounded bar and a smaller ring on slow Lissajous
    // orbits.
    f.c0 = float2(0.45 * aspect * sin(0.13 * t),        0.28 * sin(0.17 * t + 1.0));
    f.c1 = float2(0.40 * aspect * sin(0.11 * t + 2.1),  0.30 * cos(0.09 * t + 0.4));
    f.c2 = float2(0.38 * aspect * cos(0.07 * t + 4.0),  0.26 * sin(0.12 * t + 2.7));
    f.c3 = float2(0.42 * aspect * cos(0.15 * t + 5.3),  0.32 * cos(0.14 * t + 3.9));
    float a = 0.21 * t + 0.6;
    f.barCS = float2(cos(a), sin(a));
    f.grid = float2(0.06, 0.035) * t;
    f.aspect = aspect;
    f.px = px;
    return f;
}

static float ldBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float3 ldPlate(float2 uv, thread const LdPlateFrame& f) {
    float2 p = (uv - 0.5) * float2(f.aspect, 1.0);   // centred, short axis 1
    float px = f.px;                                 // one drawable pixel

    // Drafting grid: thin lines every 1/8 of the short axis, a brighter one
    // every fourth. Lines are what make the bulge and the fan legible.
    float2 pg = p + f.grid;
    float2 g = abs(fract(pg * 8.0 + 0.5) - 0.5) / 8.0;
    float minor = 1.0 - smoothstep(0.0, px, min(g.x, g.y));
    float2 G = abs(fract(pg * 2.0 + 0.5) - 0.5) / 2.0;
    float major = 1.0 - smoothstep(0.0, 1.6 * px, min(G.x, G.y));
    float3 color = float3(0.035, 0.040, 0.060);
    color += float3(0.10, 0.11, 0.14) * minor + float3(0.16, 0.17, 0.21) * major;

    // Pale, near-white shapes so every hue in the fan has something to
    // subtract from.
    float ring = abs(length(p - f.c0) - 0.22) - 0.035;
    float disc = length(p - f.c1) - 0.12;
    float2 q = p - f.c2;
    q = float2(f.barCS.x * q.x - f.barCS.y * q.y, f.barCS.y * q.x + f.barCS.x * q.y);
    float bar  = ldBox(q, float2(0.30, 0.045), 0.045);
    float ring2 = abs(length(p - f.c3) - 0.09) - 0.018;

    float aa = 1.5 * px;
    color = mix(color, float3(0.93, 0.92, 0.88), saturate(0.5 - 0.5 * ring / aa));
    color = mix(color, float3(0.96, 0.90, 0.80), saturate(0.5 - 0.5 * disc / aa));
    color = mix(color, float3(0.86, 0.90, 0.96), saturate(0.5 - 0.5 * bar / aa));
    color = mix(color, float3(0.98, 0.98, 0.98), saturate(0.5 - 0.5 * ring2 / aa));
    return color;
}

// ---------------------------------------------------------------------------
// Upstream helpers. `ar` is u_imageAspectRatio.

static float3 ldHueColor(float hue) {
    float3 rgb = clamp(abs(glmod3(hue * 6.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return rgb * rgb * (3.0 - 2.0 * rgb);
}

static float ldInnerCircleMask(float radius, float inradius) {
    return 1.0 - smoothstep(0.5 * inradius, 1.1 * inradius, radius);
}

static float ldDispersionCurve(float t, float biasPow, float bias) {
    float mirroredT = bias < 0.0 ? 1.0 - t : t;
    float curved = pow(mirroredT, biasPow);
    return bias < 0.0 ? 1.0 - curved : curved;
}

static float2 ldGetSpread(constant LerpUniforms& u, float ar, float2 fromCenter, float radius,
                          float2 warpedUV, float edgeAA, float inradius, float outradius,
                          float reach, thread float& outStrength) {
    float angleRad = u.angle * PI / 180.0;
    float2 uniformDir = float2(cos(angleRad), sin(angleRad));

    float invInradius = 1.0 / inradius;
    float2 radialDir = fromCenter * invInradius;
    float maxLen = (outradius + reach) * invInradius;
    float radialLen = radius * invInradius;
    if (radialLen > maxLen) radialDir *= maxLen / radialLen;
    float2 spreadDir = mix(uniformDir, radialDir, u.perspective);

    float bandProximity = smoothstep(inradius * 0.8, inradius, radius);
    float lensCircleMaxing = bandProximity * u.lensCircle * u.lensCircle * u.lensCircle;
    spreadDir = mix(spreadDir, radialDir, lensCircleMaxing);

    float2 warpedAbs = abs(warpedUV - 0.5);
    float inner = mix(1.0, smoothstep(0.0, mix(inradius, outradius, u.focusCenter), radius), u.focusCenter);
    float boxDist = max(warpedAbs.x, warpedAbs.y) * 2.0;
    float outer = mix(1.0, 1.0 - min(boxDist, 1.0), u.focusEdges);
    float strength = inner * outer;

    strength *= mix(1.0, mix(0.15, 0.03, max(-u.lensBulge, 0.0)), lensCircleMaxing);

    float2 outside = max(warpedAbs - 0.5, 0.0);
    float margin = max(reach * length(spreadDir) * (1.0 - u.lensCircle), edgeAA);
    strength *= 1.0 - smoothstep(0.0, margin, length(outside));

    outStrength = strength;
    float2 axis = spreadDir * (reach * strength);

    if (u.noise > 0.0) {
        float turn = (valueNoise(fromCenter * u.noiseFrequency * 18.0 + u.noiseOffset * 30.0) - 0.5)
                     * 2.0 * u.noise;
        float cs = cos(turn), sn = sin(turn);
        axis = float2x2(float2(cs, -sn), float2(sn, cs)) * axis;
    }

    axis.x /= ar;
    return axis;
}

static float2 ldLensWarp(constant LerpUniforms& u, float ar, float2 fromCenter, float radius,
                         float inradius, thread float& bulgeFade) {
    bulgeFade = 1.0;
    if (u.lensBulge == 0.0 && u.lensCircle <= 0.0) return fromCenter;
    if (radius < 1e-5) return fromCenter;

    float r = radius;

    if (u.lensBulge != 0.0) {
        float rn = radius / inradius;
        float bulge = abs(u.lensBulge) * (u.lensBulge > 0.0 ? 1.4 : 1.2);
        if (u.lensBulge > 0.0) bulgeFade = 1.0 - smoothstep(1.45, 1.53, rn * bulge);
        float map = u.lensBulge > 0.0
            ? tan(min(rn * bulge, 1.53)) / tan(bulge)
            : atan(rn * tan(bulge)) / bulge;
        float bulgeScale = map / rn;
        fromCenter *= bulgeScale;
        r *= bulgeScale;
    }

    if (u.lensCircle > 0.0) {
        float2 dir = fromCenter / max(r, 1e-5);
        float2 halfBox = float2(ar, 1.0) * 0.5;
        float rBox = min(halfBox.x / max(abs(dir.x), 1e-4), halfBox.y / max(abs(dir.y), 1e-4));
        float band = inradius * mix(0.03, 0.2, 0.5 * (u.lensBulge + 1.0));
        float innerEdge = inradius - band;
        float over = smoothstep(0.0, 1.0, (r - innerEdge) / band);
        float g = r + (rBox - inradius) * pow(over, 14.0);
        fromCenter = dir * mix(r, g, u.lensCircle);
    }

    return fromCenter;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float ar = u.resolution.x / max(u.resolution.y, 1.0);
    float2 uv = pos.xy / u.resolution;              // v_imageUV: image box == screen
    float t = u.speed * u.time + 300.0 * u.seed;

    float invAspect = 1.0 / ar;
    float inradius = 0.5 * min(ar, 1.0);
    float outradius = 0.5 * length(float2(ar, 1.0));
    float reach = 0.7 * pow(u.spread, 1.3 + 2.7 * u.spread);

    float2 fromCenter = uv - 0.5;
    fromCenter.x *= ar;
    float radius = length(fromCenter);

    float bulgeFade;
    float2 warpedFromCenter = ldLensWarp(u, ar, fromCenter, radius, inradius, bulgeFade);
    float2 baseUV = float2(warpedFromCenter.x * invAspect, warpedFromCenter.y) + 0.5;

    float2 baseDerivative = fwidth(baseUV);
    float edgeAA = clamp(2.0 * max(baseDerivative.x, baseDerivative.y), 0.001, 0.02);

    float spreadStrength;
    float2 spreadAxis = ldGetSpread(u, ar, fromCenter, radius, baseUV, edgeAA,
                                    inradius, outradius, reach, spreadStrength);

    // Upstream derives the grain lattice from the image UV's screen-space
    // derivatives; with the image box equal to the screen that is pixels.
    float2 grainUV = (uv - 0.5) * 0.8 * u.resolution + 0.5;

    if (u.grainMixer > 0.0) {
        float grainSeed = valueNoise(grainUV);
        float2 jit = fract(grainSeed * float2(157.31, 113.57)) * 2.0 - 1.0;
        spreadAxis += jit * 0.3 * u.grainMixer * length(spreadAxis);
    }

    int countInteger = clamp(u.count, 2, LD_MAX_SAMPLES);
    float count = float(countInteger);

    float invCount = 1.0 / count;
    float invSpan = 1.0 / max(count - 1.0, 1.0);
    float hueBase = u.dispersionColor + 0.5;
    float biasPower = 1.0 + 2.0 * abs(u.bias);
    float2 tapBias = 0.5 - float2(u.imageX, u.imageY);

    float centerAmount = clamp(1.0 - u.dispersionShift, 0.0, 1.0);
    float edgesAmount = clamp(1.0 + u.dispersionShift, 0.0, 1.0);
    float dispersion = u.dispersion * mix(edgesAmount, centerAmount, ldInnerCircleMask(radius, inradius));
    float dispersionPower = pow(dispersion, 0.8);

    float warpedRadius = length(warpedFromCenter);
    float swirlAngle = u.swirl * 0.4 * PI * spreadStrength * u.spread
                       * min(1.0, inradius / max(warpedRadius, 1e-4));

    LdPlateFrame plate = ldPlateFrame(ar, t, 1.0 / max(u.resolution.y, 1.0));

    float tapJitter = (hash21(floor(pos.xy)) - 0.5) * smoothstep(4.0, 10.0, count);

    float3 colorSum = float3(0.0);
    float3 weightSum = float3(0.0);

    for (int i = 0; i < LD_MAX_SAMPLES; i++) {
        if (i >= countInteger) break;

        float layer = float(i);
        float hue = hueBase + layer * invCount;

        float spread = saturate((layer + tapJitter) * invSpan);
        if (u.bias != 0.0) spread = ldDispersionCurve(spread, biasPower, u.bias);

        float fanPos = 1.0 - 2.0 * spread;
        float2 tapUV = baseUV + spreadAxis * fanPos - 0.5;

        if (u.swirl != 0.0) {
            tapUV.x *= ar;
            tapUV = rotate(tapUV, swirlAngle * fanPos);
            tapUV.x *= invAspect;
        }

        float3 tap = ldPlate(tapUV + tapBias, plate);
        float3 weight = 1.0 - dispersionPower * ldHueColor(hue);

        colorSum += tap * weight;
        weightSum += weight;
    }

    float3 color = colorSum / max(weightSum, 1e-4);
    color = mix(u.colorBack.rgb, color, bulgeFade);

    if (u.grainOverlay > 0.0) {
        color = lerpGrainOverlay(color, grainUV, u.grainOverlay);
    }

    color = lerpDither(clamp(color, 0.0, 1.0), pos);
    return half4(half3(color), 1.0h);
}
