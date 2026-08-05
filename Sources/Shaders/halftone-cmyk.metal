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

constant float3 HC_PAPER   = float3(0.616, 0.588, 0.533); // dimmed newsprint
constant float3 HC_INK_C   = float3(0.000, 0.663, 0.882);
constant float3 HC_INK_M   = float3(0.925, 0.098, 0.514);
constant float3 HC_INK_Y   = float3(1.000, 0.859, 0.020);
constant float3 HC_INK_K   = float3(0.078, 0.071, 0.086);

constant float HC_SIZE          = 0.86; // -> ~44 cells on the short axis
constant float HC_CONTRAST      = 1.35;
// The procedural source has no paper-white regions the way a photograph
// does, so every cell would otherwise ink up solid. Scales dot coverage.
constant float HC_COVERAGE      = 0.58;
constant float HC_SOFTNESS      = 0.35;
constant float HC_GRID_NOISE    = 0.16;
constant float HC_GRAIN_MIXER   = 0.18;
constant float HC_GRAIN_OVERLAY = 0.22;
constant float HC_GRAIN_SIZE    = 0.55;

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

static float3 hcContrast(float3 rgb) {
    return clamp((rgb - 0.5) * HC_CONTRAST + 0.5, 0.0, 1.0);
}

static float4 hcSeparate(float4 rgba) {
    float3 c = hcContrast(rgba.rgb);
    float maxRGB = max(max(c.r, c.g), c.b);
    float3 cmy = (maxRGB > 1e-5) ? (maxRGB - c) / maxRGB : float3(0.0);
    float k = 1.0 - maxRGB;
    return float4(cmy, k) * rgba.a;
}

static float2 hcCellCenter(float2 uv, float2 cellOffset, float channelIdx) {
    float2 cellCenter = floor(uv) + 0.5 + cellOffset;
    return cellCenter + (hash22(cellCenter + channelIdx * 50.0) - 0.5) * HC_GRID_NOISE;
}

static float hcColorMask(float2 p, float2 cellCenter, float rad,
                         float grain, float generalComp) {
    float dist = length(p - cellCenter);

    float radius = rad * HC_COVERAGE * (1.0 + generalComp);
    radius += 0.09;
    radius = max(0.0, radius);
    radius *= (1.0 - grain);

    float mask = 1.0 - smoothstep(0.0, radius, dist);
    // "dots" (separate) — hard-shoulder the falloff so the dots stay discrete.
    mask = smoothstep(0.5 - 0.5 * HC_SOFTNESS, 0.51 + 0.49 * HC_SOFTNESS, mask);
    mask *= mix(1.0, mix(0.5, 1.0, 1.5 * radius), HC_SOFTNESS);
    return mask;
}

static float3 hcApplyInk(float3 paper, float3 inkColor, float cov) {
    return paper * mix(float3(1.0), inkColor, clamp(cov, 0.0, 1.0));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 imageUV = float2(pos.x, u.resolution.y - pos.y) / u.resolution;

    float t = 0.35 * u.time + 45.0 * u.seed;

    float cellsPerSide = mix(400.0, 7.0, pow(HC_SIZE, 0.7));
    float2 pad = (1.0 / cellsPerSide) * float2(1.0 / aspect, 1.0);
    float2 uvGrid = (imageUV - 0.5) / pad;

    float generalComp = 0.1 * HC_SOFTNESS + 0.1 * HC_GRID_NOISE
                      + 0.1 * (1.5 - HC_SOFTNESS);

    float2 uvC = rotate(uvGrid, HC_ANG_C) + HC_SHIFT_C;
    float2 uvM = rotate(uvGrid, HC_ANG_M) + HC_SHIFT_M;
    float2 uvY = rotate(uvGrid, HC_ANG_Y) + HC_SHIFT_Y;
    float2 uvK = rotate(uvGrid, HC_ANG_K) + HC_SHIFT_K;

    float2 grainUV = (imageUV - 0.5) * mix(2000.0, 200.0, HC_GRAIN_SIZE)
                     * float2(1.0, 1.0 / aspect) + 0.5;
    float3 noiseValues = float3(valueNoise(grainUV),
                                valueNoise(grainUV + 11.3),
                                valueNoise(grainUV - 7.1));
    float grain = smoothstep(0.55, 1.0, noiseValues.r) * HC_GRAIN_MIXER;

    // Upstream's "dots" mode re-samples the image at every neighbouring cell
    // centre of every ink — 36 taps per pixel. The procedural source varies
    // over tens of cells, so one tap per pixel (upstream's "sharp" sampling)
    // is visually identical here and roughly 5x cheaper, which is the
    // difference between 38 fps and 130 fps at 5K.
    float4 cmyk = hcSeparate(hcSource(imageUV, t));

    float4 outMask = float4(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 cellOffset = float2(float(dx), float(dy));
            outMask[0] += hcColorMask(uvC, hcCellCenter(uvC, cellOffset, 0.0), cmyk.x, grain, generalComp);
            outMask[1] += hcColorMask(uvM, hcCellCenter(uvM, cellOffset, 1.0), cmyk.y, grain, generalComp);
            outMask[2] += hcColorMask(uvY, hcCellCenter(uvY, cellOffset, 2.0), cmyk.z, grain, generalComp);
            outMask[3] += hcColorMask(uvK, hcCellCenter(uvK, cellOffset, 3.0), cmyk.w, grain, generalComp);
        }
    }

    float C = outMask[0], M = outMask[1], Y = outMask[2], K = outMask[3];

    float3 ink = HC_PAPER;
    ink = hcApplyInk(ink, HC_INK_K, K);
    ink = hcApplyInk(ink, HC_INK_C, C);
    ink = hcApplyInk(ink, HC_INK_M, M);
    ink = hcApplyInk(ink, HC_INK_Y, Y);

    float shape = clamp(max(max(C, M), max(Y, K)), 0.0, 1.0);
    float3 color = mix(HC_PAPER, ink, shape);

    float grainOverlay = pow(mix(noiseValues.g, noiseValues.b, 0.5), 1.3);
    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(HC_GRAIN_OVERLAY * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.4 * grainOverlayStrength);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
