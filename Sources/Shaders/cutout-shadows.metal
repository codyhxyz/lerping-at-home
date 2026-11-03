// Cutout Shadows — original shader for Lerping@Home, built from Ronja
// Böhringer's 2D signed-distance-field and dithering tutorials.
// https://www.ronja-tutorials.com
// Tutorial code: https://github.com/ronja-tutorials/ShaderTutorials, licensed
// CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/) per that
// repository's README. Adapted from it, translated from HLSL to MSL and
// modified:
//   csRoundMerge  <- round_merge    (035 "2D SDF Combination")
//   csShadow      <- traceShadows   (037 "2D SDF Shadows"); returns the
//                    accumulated penumbra instead of 0 when the sample budget
//                    runs out, treats the light as a disc, not a point, and
//                    marches only the stretch of the ray near a cutout
//   csRosette     <- radial_cells   (036 "2D SDF Space Manipulation"), with
//                    centred cells instead of edge-aligned ones
//   csBox         <- rectangle      (034 "2D SDF Basics"), plus corner rounding
//   the step(threshold, value) two-colour dither (042 "Dithering"),
//   generalised to N tones
// Everything else (the morphing cutouts, the light, the ink compositing, the
// misregistration, the procedural dither thresholds) is this project's own.
//
// A handful of paper cutouts drift over a floor, each slowly morphing between
// a disc, a card, a flower, a ring and a rosette, and melting into its
// neighbours where they touch. A wandering light throws long soft 2D shadows
// off them. Every tone — floor light, penumbra, the cutouts' own shading — is
// quantised to a few flat inks with an ordered dither on chunky pixels: a
// Mac-classic 1-bit look at one end, a two-ink risograph print at the other.
//
// Dither thresholds are procedural, so no texture is bound: `pattern` 0 is a
// 4x4 Bayer matrix (as in the tutorial), 1 is interleaved gradient noise
// (Jorge Jimenez, "Next Generation Post Processing in Call of Duty: Advanced
// Warfare", SIGGRAPH 2014), 2 is the R2 quasirandom sequence (Martin Roberts,
// "The Unreasonable Effectiveness of Quasirandom Sequences", 2018). 1 and 2 are
// blue-noise-like: no visible tile, no Bayer cross-hatch.
//
// Inks: the "key" layer (shadow ink, outlines, contour rings, the light's rim)
// is drawn where it falls; the cutout fill is a second layer that
// `misregister` shifts by that many pixels, as two drums of a riso printer
// drift. `overprint` 1 multiplies the layers like transparent ink on paper;
// 0 lays them on opaque.
//
// lerp-param: colorBack   color          = (0.035, 0.030, 0.075) "Shadow"
// lerp-param: colorLight  color          = (0.180, 0.420, 0.470) "Lit floor"
// lerp-param: colorShape  color          = (0.950, 0.470, 0.360) "Cutouts"
// lerp-param: colorLine   color          = (0.012, 0.010, 0.030) "Ink line"
// lerp-param: count       int 1 6        = 5     "Cutouts"
// lerp-param: melt        float 0 0.4    = 0.10  "Melt"
// lerp-param: hardness    float 1 40     = 7.0   "Shadow hardness"
// lerp-param: reach       float 0.3 4    = 1.6   "Light reach"
// lerp-param: ambient     float 0 0.6    = 0.08  "Ambient"
// lerp-param: levels      int 2 5        = 3     "Tones"
// lerp-param: pattern     int 0 2        = 1     "Dither (Bayer, IGN, R2)"
// lerp-param: pixel       float 1 8      = 3.0   "Pixel size"
// lerp-param: line        float 0 4      = 1.0   "Outline width"
// lerp-param: contours    int 0 5        = 0     "Contour rings"
// lerp-param: shade       float 0 1      = 0.65  "Cutout shading"
// lerp-param: misregister float 0 16     = 0.0   "Misregistration"
// lerp-param: overprint   float 0 1      = 0.0   "Overprint"
// lerp-param: showLight   bool           = true  "Show light"
// lerp-param: morph       float 0 3      = 1.0   "Morph rate"
// lerp-param: speed       float 0 2      = 0.35  "Speed"
//
// lerp-preset: Classic colorBack=(0.055, 0.055, 0.065), colorLight=(0.760, 0.760, 0.720)
// lerp-preset: Classic colorShape=(0.760, 0.760, 0.720), colorLine=(0.055, 0.055, 0.065)
// lerp-preset: Classic levels=2, pattern=0, pixel=3, line=1, melt=0, hardness=14
// lerp-preset: Classic reach=1.4, ambient=0.04, shade=0
// lerp-preset: Riso colorBack=(0.000, 0.420, 0.690), colorLight=(0.950, 0.920, 0.840)
// lerp-preset: Riso colorShape=(1.000, 0.330, 0.560), colorLine=(0.050, 0.180, 0.420)
// lerp-preset: Riso levels=3, pattern=2, pixel=2, line=1.5, misregister=6, overprint=1
// lerp-preset: Riso melt=0.16, hardness=5, reach=2.2, ambient=0.25
// lerp-preset: Topo colorBack=(0.020, 0.045, 0.035), colorLight=(0.300, 0.520, 0.300)
// lerp-preset: Topo colorShape=(0.880, 0.780, 0.420), colorLine=(0.010, 0.030, 0.020)
// lerp-preset: Topo levels=4, pattern=1, pixel=2, line=1, contours=5, melt=0.3
// lerp-preset: Topo count=4, hardness=3, reach=2.2, ambient=0.12, morph=0.6

constant int   CS_MAX_SHAPES   = 6;
constant int   CS_PRIMS        = 5;
constant int   CS_SHADOW_STEPS = 40;
constant float CS_BOUND        = 1.15;  // every primitive fits in 1.15 x its radius
constant float CS_LIGHT_R      = 0.045; // the light's disc, scene units

constant float CS_BAYER4[16] = {
     0.0,  8.0,  2.0, 10.0,
    12.0,  4.0, 14.0,  6.0,
     3.0, 11.0,  1.0,  9.0,
    15.0,  7.0, 13.0,  5.0,
};

struct CSShape {
    float2 c;     // centre
    float2 cs;    // cos, sin of its rotation
    float  r;     // radius
    int    kA;    // primitive it is leaving
    int    kB;    // primitive it is becoming
    float  f;     // 0..1 between them
};

// --- primitives, all in the cutout's local frame -----------------------------

static float csBox(float2 q, float2 halfSize, float corner) {
    float2 d = abs(q) - halfSize + corner;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - corner;
}

// Six discs repeated around the centre in polar space.
static float csRosette(float2 q, float r) {
    const float cell = TWO_PI / 6.0;
    float a = atan2(q.x, q.y);
    a = glmod(a + 0.5 * cell, cell) - 0.5 * cell;
    float2 p = float2(sin(a), cos(a)) * length(q);
    float petals = length(p - float2(0.0, 0.64 * r)) - 0.32 * r;
    return min(petals, length(q) - 0.22 * r);
}

static float csPrim(int k, float2 q, float r) {
    switch (k) {
        case 0:  return length(q) - 0.9 * r;
        case 1:  return csBox(q, float2(0.95 * r, 0.62 * r), 0.14 * r);
        case 2: {
            float a = atan2(q.y, q.x);
            float edge = r * (0.76 + 0.24 * cos(5.0 * a));
            return 0.62 * (length(q) - edge);   // 0.62: keep it Lipschitz-safe
        }
        case 3:  return abs(length(q) - 0.70 * r) - 0.24 * r;
        default: return csRosette(q, r);
    }
}

// Round union: fillets the crease where two shapes meet.
static float csRoundMerge(float a, float b, float radius) {
    float2 inside = min(float2(a - radius, b - radius), 0.0);
    return -length(inside) + max(min(a, b), radius);
}

// `mask` picks which cutouts take part (bit i = cutout i).
static float csScene(float2 p, thread const CSShape* shapes, int count, float melt,
                     uint mask = 0x3Fu) {
    float d = 1e3;
    for (int i = 0; i < count; i++) {
        if ((mask & (1u << i)) == 0u) continue;
        float2 q = p - shapes[i].c;
        // Far outside this cutout's bounding disc it cannot change the union
        // (for round_merge too, once it is beyond both `d` and the radius),
        // so skip the exact primitives.
        float bound = length(q) - CS_BOUND * shapes[i].r;
        if (bound >= max(d, melt)) continue;

        float2 cs = shapes[i].cs;
        q = float2(cs.x * q.x + cs.y * q.y, cs.x * q.y - cs.y * q.x);
        float di = csPrim(shapes[i].kA, q, shapes[i].r);
        if (shapes[i].f > 0.0) di = mix(di, csPrim(shapes[i].kB, q, shapes[i].r), shapes[i].f);
        d = melt > 0.0 ? csRoundMerge(d, di, melt) : min(d, di);
    }
    return d;
}

// Soft 2D shadow: march from the floor point toward the light, keeping the
// narrowest clearance-to-distance ratio seen along the way.
static float csShadow(float2 p, float2 light, float hardness,
                      thread const CSShape* shapes, int count, float melt) {
    float2 dir = light - p;
    float lightDist = length(dir) - CS_LIGHT_R;
    dir = normalize(dir);

    // Only march where something can darken the ray. A cutout contributes
    // hardness * d / progress, which is >= 1 (no shadow) wherever the ray
    // stays farther than progress / hardness from its bounding disc, so a
    // cutout whose widened disc misses the segment is dropped, and the march
    // covers just the stretch where the survivors' discs overlap it. Dropping
    // a cutout never lets the march step into one that is kept: those keep
    // their exact distance. Most floor cells then march nothing at all.
    uint near = 0u;
    float sFrom = lightDist, sTo = 0.0;
    for (int i = 0; i < count; i++) {
        float2 oc = shapes[i].c - p;
        float along = dot(oc, dir);
        float perp2 = max(dot(oc, oc) - along * along, 0.0);
        float bound = CS_BOUND * shapes[i].r;
        float reach = bound + melt + (max(along, 0.0) + bound) / hardness;
        if (perp2 >= reach * reach) continue;
        float half_ = sqrt(reach * reach - perp2);
        float s0 = max(along - half_, 0.0), s1 = min(along + half_, lightDist);
        if (s1 <= s0) continue;
        near |= 1u << i;
        sFrom = min(sFrom, s0);
        sTo = max(sTo, s1);
    }
    if (near == 0u) return 1.0;

    float progress = max(sFrom, 1e-4);
    float shadow = 1.0;
    for (int i = 0; i < CS_SHADOW_STEPS; i++) {
        if (progress > sTo) return saturate(shadow);
        float d = csScene(p + dir * progress, shapes, count, melt, near);
        if (d <= 0.0) return 0.0;
        shadow = min(shadow, hardness * d / progress);
        if (shadow < 0.004) return 0.0;
        progress += max(d, 0.004 + 0.01 * progress);
    }
    return saturate(shadow);
}

static float csThreshold(int pattern, float2 cell) {
    if (pattern == 0) {
        int2 b = int2(glmod2(cell, 4.0));
        return (CS_BAYER4[b.y * 4 + b.x] + 0.5) / 16.0;
    }
    if (pattern == 1) {
        return fract(52.9829189 * fract(dot(cell, float2(0.06711056, 0.00583715))));
    }
    return fract(0.5 + dot(cell, float2(0.7548776662, 0.5698402910)));
}

// N flat tones, ordered-dithered: value v in [0,1] -> one of `levels` steps.
static float csQuantise(float v, float threshold, int levels) {
    float n = float(levels - 1);
    return clamp(floor(saturate(v) * n + threshold), 0.0, n) / n;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float minRes = min(u.resolution.x, u.resolution.y);

    // Chunky pixels: every quantity below is evaluated at the cell centre.
    float px = max(u.pixel, 1.0);
    float2 cell = floor(pos.xy / px);
    float2 centre = (cell + 0.5) * px;
    float2 p = lerpUV(float4(centre, 0.0, 1.0), u.resolution);
    float cellUV = 2.0 * px / minRes;                 // one cell, scene units
    float2 extent = float2(max(aspect, 1.0), max(1.0 / aspect, 1.0));

    float t = u.speed * u.time + 100.0 * u.seed;

    // The light wanders a slow Lissajous over most of the frame.
    float2 light = extent * float2(0.72 * cos(0.21 * t + 6.0 * u.seed),
                                   0.62 * sin(0.16 * t + 3.0 * u.seed));

    int count = clamp(u.count, 1, CS_MAX_SHAPES);
    float morphT = 0.15 * u.morph * t;
    CSShape shapes[CS_MAX_SHAPES];
    for (int i = 0; i < count; i++) {
        float fi = float(i);
        float h1 = hash11(fi * 7.31 + 1.7);
        float h2 = hash11(fi * 3.17 + 9.1);
        float h3 = hash11(fi * 5.93 + 4.3);

        float r = 0.20 + 0.10 * h3;
        // Each cutout wanders around its own home on a 3x2 lattice that turns
        // slowly, so the frame stays filled instead of the drift bunching
        // everything into one corner; the wander is wide enough for
        // neighbours to meet and melt.
        float2 home = float2(0.62 * float(i % 3) - 0.62, i < 3 ? 0.36 : -0.36);
        home = rotate(home, 0.03 * t + 0.4 * u.seed);
        float2 wander = float2(0.36 * sin(t * (0.13 + 0.07 * h1) + 6.28 * h2),
                               0.30 * sin(t * (0.11 + 0.06 * h2) + 6.28 * h1 + fi));
        float2 c = extent * (home + wander);
        // Shoo cutouts off the light, so it is never swallowed by one.
        float2 away = c - light;
        float gap = length(away);
        float clearance = CS_BOUND * r + 2.0 * CS_LIGHT_R;
        c += away / max(gap, 1e-4) * max(clearance - gap, 0.0);

        float angle = 6.28 * h1 + t * 0.35 * (h2 - 0.5);

        // Hold each primitive, then morph into the next over the last 40%.
        float phase = morphT + 1.7 * fi + 3.0 * u.seed;
        int stage = int(floor(phase));
        int kA = (stage + 2 * i) % CS_PRIMS;

        shapes[i].c  = c;
        shapes[i].cs = float2(cos(angle), sin(angle));
        shapes[i].r  = r;
        shapes[i].kA = kA;
        shapes[i].kB = (kA + 1) % CS_PRIMS;
        shapes[i].f  = smoothstep(0.6, 1.0, fract(phase));
    }

    float melt = u.melt;
    float threshold = csThreshold(u.pattern, cell);

    // Key layer: floor light and shadow.
    float dKey = csScene(p, shapes, count, melt);
    float toLight = length(p - light);
    float falloff = 1.0 / (1.0 + 3.0 * (toLight * toLight) / (u.reach * u.reach));
    float lit = 1.0;   // the floor under a cutout is never seen in shadow
    if (dKey > 0.0) lit = csShadow(p, light, u.hardness, shapes, count, melt);
    float floorTone = u.ambient + (1.0 - u.ambient) * falloff * lit;
    float3 floorCol = mix(u.colorBack.rgb, u.colorLight.rgb,
                          csQuantise(floorTone, threshold, u.levels));
    float3 color = floorCol;

    // Fill layer, shifted by the misregistration (down and to the right).
    float dFill = dKey;
    if (u.misregister > 0.0) {
        float2 shift = float2(0.8, -0.6) * u.misregister * 2.0 / minRes;
        dFill = csScene(p - shift, shapes, count, melt);
    }
    if (dFill < 0.0) {
        // `shade` 0 is a flat, solid cutout; 1 lets it fall off with the light.
        float fillTone = 1.0 - u.shade * (1.0 - falloff);
        float3 fill = mix(u.colorBack.rgb, u.colorShape.rgb,
                          csQuantise(fillTone, threshold, u.levels));
        color = mix(fill, floorCol * fill, u.overprint);
    }

    // Key-layer linework: outlines, contour rings inside the cutouts.
    float halfLine = 0.5 * u.line * cellUV;
    bool ink = u.line > 0.0 && abs(dKey) < halfLine;
    if (u.contours > 0 && dKey < 0.0) {
        float spacing = 0.055;
        float ring = -dKey / spacing;
        float k = round(ring);
        ink = ink || (k >= 1.0 && k <= float(u.contours)
                      && abs(ring - k) * spacing < max(halfLine, 0.5 * cellUV));
    }

    if (u.showLight) {
        float dl = toLight - CS_LIGHT_R;
        if (dl < 0.0) color = u.colorLight.rgb;
        ink = ink || (u.line > 0.0 && abs(dl) < halfLine);
    }

    if (ink) color = mix(u.colorLine.rgb, color * u.colorLine.rgb, u.overprint);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
