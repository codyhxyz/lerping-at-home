// Halftone CMYK — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Four-colour process printing: the source is separated into cyan, magenta,
// yellow and black, and each ink is screened on its own lattice rotated to
// the traditional 15°/75°/0°/45° so the dots interleave into a rosette.
// Upstream separates an input image; with no image to print this port feeds
// the separation a drifting procedural colour field. Everything else — the
// screen angles, the per-cell jitter, the radius/coverage curve and the
// subtractive ink stack — is the upstream "dots" algorithm.
//
// One deliberate deviation: upstream lays the inks over pure white paper.
// A full-screen white screensaver is unpleasant, so the paper is a dimmed
// newsprint and the inks multiply down from there.

// Parameters mirror the upstream <HalftoneCmyk> props. Upstream's `type` enum
// is not ported (always "dots"), and neither are its per-channel `flood*` /
// `gain*` props — this port has a single global coverage scale instead, which
// stays hardcoded below because it has no upstream counterpart. `colorBack` is
// upstream's paper. `speed` is this port's own addition, driving the
// procedural field that replaces the image.
//
// lerp-param: colorBack    color        = (0.616, 0.588, 0.533) "Paper"
// lerp-param: colorC       color        = (0.000, 0.663, 0.882) "Cyan ink"
// lerp-param: colorM       color        = (0.925, 0.098, 0.514) "Magenta ink"
// lerp-param: colorY       color        = (1.000, 0.859, 0.020) "Yellow ink"
// lerp-param: colorK       color        = (0.078, 0.071, 0.086) "Black ink"
// lerp-param: size         float 0.01 1 = 0.86 "Size"
// lerp-param: contrast     float 0 2    = 1.35 "Contrast"
// lerp-param: softness     float 0 1    = 0.35 "Softness"
// lerp-param: gridNoise    float 0 1    = 0.16 "Grid noise"
// lerp-param: grainMixer   float 0 1    = 0.18 "Grain mixer"
// lerp-param: grainOverlay float 0 1    = 0.22 "Grain overlay"
// lerp-param: grainSize    float 0 1    = 0.55 "Grain size"
// lerp-param: speed        float 0 2    = 0.35 "Source speed"
//
// Upstream presets, restricted to the props this port implements.
// lerp-preset: Drops     colorBack=#eeefd7, colorC=#00b2ff, colorM=#fc4f4f
// lerp-preset: Drops     colorY=#ffd900, colorK=#231f20, size=0.88, contrast=1.15
// lerp-preset: Drops     softness=0, grainSize=0.01, grainMixer=0.05, grainOverlay=0.25
// lerp-preset: Drops     gridNoise=0.5
// lerp-preset: Newspaper colorBack=#f2f1e8, colorC=#7a7a75, colorM=#7a7a75
// lerp-preset: Newspaper colorY=#7a7a75, colorK=#231f20, size=0.01, contrast=2
// lerp-preset: Newspaper softness=0.2, grainSize=0, grainMixer=0, grainOverlay=0.2
// lerp-preset: Newspaper gridNoise=0.6
// lerp-preset: Vintage   colorBack=#fffaf0, colorC=#59afc5, colorM=#d8697c
// lerp-preset: Vintage   colorY=#fad85c, colorK=#2d2824, size=0.2, contrast=1.25
// lerp-preset: Vintage   softness=0.4, grainSize=0.5, grainMixer=0.15, grainOverlay=0.1
// lerp-preset: Vintage   gridNoise=0.45

// The procedural source has no paper-white regions the way a photograph
// does, so every cell would otherwise ink up solid. Scales dot coverage.
// No upstream counterpart — deliberately not a parameter.
constant float HC_COVERAGE = 0.58;

// Traditional process screen angles.
constant float HC_ANG_C = 0.26179939; // 15°
constant float HC_ANG_M = 1.30899694; // 75°
constant float HC_ANG_Y = 0.0;        // 0°
constant float HC_ANG_K = 0.78539816; // 45°

constant float2 HC_SHIFT_C = float2(0.00, 0.00);
constant float2 HC_SHIFT_M = float2(0.50, 0.30);
constant float2 HC_SHIFT_Y = float2(0.20, 0.70);
constant float2 HC_SHIFT_K = float2(0.80, 0.10);

// Stand-in for u_image: a smooth drifting colour field. Kept cheap (a
// handful of trig ops) because the separation samples it once per ink per
// neighbouring cell.
static float3 hcPalette(float x) {
    return clamp(0.5 + 0.5 * cos(TWO_PI * (x + float3(0.00, 0.33, 0.67))), 0.0, 1.0);
}

static float4 hcSource(float2 uv, float t) {
    float2 p = uv - 0.5;
    float f = 0.55 * sin(4.1 * p.x + 0.52 * t) + 0.55 * cos(3.3 * p.y - 0.41 * t);
    f += 0.35 * sin(2.5 * (p.x + p.y) + 0.31 * t);
    float3 col = hcPalette(0.5 + 0.3 * f + 0.04 * t);
    // Two tonal bands at different rates, so the print has light and dark
    // passages rather than one even screen.
    float shade = 0.5 + 0.5 * sin(TWO_PI * (0.42 * uv.x + 0.31 * uv.y) - 0.27 * t);
    shade *= 0.5 + 0.5 * cos(TWO_PI * (0.27 * uv.y - 0.19 * uv.x) + 0.21 * t);
    return float4(col * mix(0.38, 1.05, shade), 1.0);
}

static float3 hcContrast(float3 rgb, float contrast) {
    return clamp((rgb - 0.5) * contrast + 0.5, 0.0, 1.0);
}

static float4 hcSeparate(float4 rgba, float contrast) {
    float3 c = hcContrast(rgba.rgb, contrast);
    float maxRGB = max(max(c.r, c.g), c.b);
    float3 cmy = (maxRGB > 1e-5) ? (maxRGB - c) / maxRGB : float3(0.0);
    float k = 1.0 - maxRGB;
    return float4(cmy, k) * rgba.a;
}

static float2 hcCellCenter(float2 uv, float2 cellOffset, float channelIdx, float gridNoise) {
    float2 cellCenter = floor(uv) + 0.5 + cellOffset;
    return cellCenter + (hash22(cellCenter + channelIdx * 50.0) - 0.5) * gridNoise;
}

static float hcColorMask(float2 p, float2 cellCenter, float rad,
                         float grain, float generalComp, float softness) {
    float dist = length(p - cellCenter);

    float radius = rad * HC_COVERAGE * (1.0 + generalComp);
    radius += 0.09;
    radius = max(0.0, radius);
    radius *= (1.0 - grain);

    float mask = 1.0 - smoothstep(0.0, radius, dist);
    // "dots" (separate) — hard-shoulder the falloff so the dots stay discrete.
    mask = smoothstep(0.5 - 0.5 * softness, 0.51 + 0.49 * softness, mask);
    mask *= mix(1.0, mix(0.5, 1.0, 1.5 * radius), softness);
    return mask;
}

static float3 hcApplyInk(float3 paper, float3 inkColor, float cov) {
    return paper * mix(float3(1.0), inkColor, clamp(cov, 0.0, 1.0));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 imageUV = float2(pos.x, u.resolution.y - pos.y) / u.resolution;

    float t = u.speed * u.time + 45.0 * u.seed;

    float cellsPerSide = mix(400.0, 7.0, pow(u.size, 0.7));
    float2 pad = (1.0 / cellsPerSide) * float2(1.0 / aspect, 1.0);
    float2 uvGrid = (imageUV - 0.5) / pad;

    float generalComp = 0.1 * u.softness + 0.1 * u.gridNoise
                      + 0.1 * (1.5 - u.softness);

    float2 uvC = rotate(uvGrid, HC_ANG_C) + HC_SHIFT_C;
    float2 uvM = rotate(uvGrid, HC_ANG_M) + HC_SHIFT_M;
    float2 uvY = rotate(uvGrid, HC_ANG_Y) + HC_SHIFT_Y;
    float2 uvK = rotate(uvGrid, HC_ANG_K) + HC_SHIFT_K;

    float2 grainUV = (imageUV - 0.5) * mix(2000.0, 200.0, u.grainSize)
                     * float2(1.0, 1.0 / aspect) + 0.5;
    float3 noiseValues = float3(valueNoise(grainUV),
                                valueNoise(grainUV + 11.3),
                                valueNoise(grainUV - 7.1));
    float grain = smoothstep(0.55, 1.0, noiseValues.r) * u.grainMixer;

    // Upstream's "dots" mode re-samples the image at every neighbouring cell
    // centre of every ink — 36 taps per pixel. The procedural source varies
    // over tens of cells, so one tap per pixel (upstream's "sharp" sampling)
    // is visually identical here and roughly 5x cheaper, which is the
    // difference between 38 fps and 130 fps at 5K.
    float4 cmyk = hcSeparate(hcSource(imageUV, t), u.contrast);

    float4 outMask = float4(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 cellOffset = float2(float(dx), float(dy));
            outMask[0] += hcColorMask(uvC, hcCellCenter(uvC, cellOffset, 0.0, u.gridNoise), cmyk.x, grain, generalComp, u.softness);
            outMask[1] += hcColorMask(uvM, hcCellCenter(uvM, cellOffset, 1.0, u.gridNoise), cmyk.y, grain, generalComp, u.softness);
            outMask[2] += hcColorMask(uvY, hcCellCenter(uvY, cellOffset, 2.0, u.gridNoise), cmyk.z, grain, generalComp, u.softness);
            outMask[3] += hcColorMask(uvK, hcCellCenter(uvK, cellOffset, 3.0, u.gridNoise), cmyk.w, grain, generalComp, u.softness);
        }
    }

    float C = outMask[0], M = outMask[1], Y = outMask[2], K = outMask[3];

    float3 ink = u.colorBack.rgb;
    ink = hcApplyInk(ink, u.colorK.rgb, K);
    ink = hcApplyInk(ink, u.colorC.rgb, C);
    ink = hcApplyInk(ink, u.colorM.rgb, M);
    ink = hcApplyInk(ink, u.colorY.rgb, Y);

    float shape = clamp(max(max(C, M), max(Y, K)), 0.0, 1.0);
    float3 color = mix(u.colorBack.rgb, ink, shape);

    float grainOverlay = pow(mix(noiseValues.g, noiseValues.b, 0.5), 1.3);
    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(u.grainOverlay * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.4 * grainOverlayStrength);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
