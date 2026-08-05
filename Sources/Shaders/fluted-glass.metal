// Fluted Glass — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Upstream refracts an input image through a ribbed glass panel. A
// screensaver has no image to feed it, so the sampler is replaced with a
// procedural drifting colour field: everything else — the rib profile, the
// per-rib refraction offset, the edge highlights, the shadow ramp and the
// film grain — is the upstream algorithm.

constant int FG_BACK_COUNT = 5;
constant float3 FG_BACK_COLORS[FG_BACK_COUNT] = {
    float3(0.024, 0.043, 0.110), // midnight
    float3(0.086, 0.267, 0.404), // deep teal
    float3(0.502, 0.216, 0.478), // orchid
    float3(0.914, 0.451, 0.318), // coral
    float3(0.976, 0.784, 0.463), // warm gold
};

constant float3 FG_COLOR_BACK      = float3(0.016, 0.020, 0.039);
constant float3 FG_COLOR_SHADOW    = float3(0.012, 0.024, 0.055);
constant float3 FG_COLOR_HIGHLIGHT = float3(0.925, 0.965, 1.000);
constant float  FG_HIGHLIGHT_ALPHA = 0.45;
constant float  FG_SHADOW_ALPHA    = 0.60;

constant float FG_SIZE          = 0.86; // -> ~32 ribs across
constant float FG_ANGLE         = 0.0;  // degrees
constant float FG_SHADOWS       = 0.70;
constant float FG_HIGHLIGHTS    = 0.55;
constant float FG_DISTORTION    = 0.55;
constant float FG_SHIFT         = 0.20;
constant float FG_STRETCH       = 0.35;
constant float FG_GRAIN_MIXER   = 0.20;
constant float FG_GRAIN_OVERLAY = 0.22;

static float2 fgRotateAspect(float2 p, float a, float aspect) {
    p.x *= aspect;
    p = rotate(p, a);
    p.x /= aspect;
    return p;
}

static float fgSmoothFract(float x) {
    float f = fract(x);
    float w = fwidth(x);
    float edge = abs(f - 0.5) - 0.5;
    float band = smoothstep(-w, w, edge);
    return mix(f, 1.0 - f, band);
}

// Stand-in for the original's u_image sampler: a slow multi-spot colour field
// with enough structure that the rib refraction stays legible.
static float3 fgBackdrop(float2 uv, float t) {
    float3 color = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < FG_BACK_COUNT; i++) {
        float a = float(i) * 1.73;
        float2 p = 0.5 + 0.46 * float2(sin(t * (0.33 + 0.06 * float(i)) + a),
                                       cos(t * (0.27 + 0.05 * float(i)) + a * 1.31));
        float d = length((uv - p) * float2(1.7, 1.0));
        float w = 1.0 / (pow(d, 2.6) + 2e-3);
        color += FG_BACK_COLORS[i] * w;
        total += w;
    }
    return color / max(total, 1e-4);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 imageUV = float2(pos.x, u.resolution.y - pos.y) / u.resolution;

    float t = 0.35 * u.time + 70.0 * u.seed;

    float patternRotation = -FG_ANGLE * PI / 180.0;
    float patternSize = mix(200.0, 5.0, FG_SIZE);

    float2 uv = (imageUV - 0.5) * patternSize;
    uv = fgRotateAspect(uv, patternRotation, aspect);

    // u_shape = "lines": no curve added to the rib coordinate.
    float2 uvToFract = uv;
    float2 fractOrigUV = fract(uv);
    float2 floorOrigUV = floor(uv);

    float x = fgSmoothFract(uvToFract.x);
    float xNonSmooth = fract(uvToFract.x) + 0.0001;

    float highlightsWidth = 2.0 * max(0.001, fwidth(uvToFract.x));
    float highlights = smoothstep(0.0, highlightsWidth, xNonSmooth)
                     * smoothstep(1.0, 1.0 - highlightsWidth, xNonSmooth);
    highlights = clamp((1.0 - highlights) * FG_HIGHLIGHTS, 0.0, 1.0);

    float shadows = pow(x, 1.3);

    float aa = max(max(fwidth(xNonSmooth), fwidth(uv.x)), 0.0001);

    // u_distortionShape = 1: the classic convex flute.
    float distortion = -pow(1.5 * x, 3.0) + (0.5 - FG_SHIFT);
    aa = max(0.2, aa) + mix(0.2, 0.0, FG_SIZE);
    float fadeX = smoothstep(0.0, aa, xNonSmooth) * smoothstep(1.0, 1.0 - aa, xNonSmooth);
    distortion = mix(0.5, distortion, fadeX);

    float2 grainUV = (imageUV - 0.5) * 0.8 * u.resolution + 0.5;
    float grain = smoothstep(0.4, 0.7, valueNoise(grainUV)) * FG_GRAIN_MIXER;
    distortion = mix(distortion, 0.0, grain);

    shadows = clamp(min(shadows, 1.0) * pow(FG_SHADOWS, 2.0), 0.0, 1.0);
    distortion *= 3.0 * FG_DISTORTION;

    fractOrigUV.x += distortion;
    floorOrigUV = fgRotateAspect(floorOrigUV, -patternRotation, aspect);
    fractOrigUV = fgRotateAspect(fractOrigUV, -patternRotation, aspect);

    float2 sampleUV = (floorOrigUV + fractOrigUV) / patternSize + 0.5;

    float stretch = 1.0 - smoothstep(0.0, 0.5, xNonSmooth) * smoothstep(1.0, 0.5, xNonSmooth);
    stretch = pow(stretch, 2.0);
    sampleUV.y = mix(sampleUV.y, 0.5, FG_STRETCH * stretch);

    float3 image = fgBackdrop(sampleUV, t);

    float3 color = FG_COLOR_HIGHLIGHT * FG_HIGHLIGHT_ALPHA * highlights;
    float opacity = FG_HIGHLIGHT_ALPHA * highlights;

    shadows = mix(shadows * FG_SHADOW_ALPHA, 0.0, highlights);
    color = mix(color, FG_COLOR_SHADOW * FG_SHADOW_ALPHA, 0.5 * shadows);
    color += 0.5 * pow(shadows, 0.5) * FG_COLOR_SHADOW;
    opacity = clamp(opacity + shadows, 0.0, 1.0);
    color = clamp(color, 0.0, 1.0);

    // The backdrop is opaque, so it fills whatever the glass layer leaves.
    color += image * (1.0 - opacity);

    float grainOverlay = valueNoise(rotate(grainUV, 1.0) + 3.0);
    grainOverlay = mix(grainOverlay, valueNoise(rotate(grainUV, 2.0) - 1.0), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);

    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(FG_GRAIN_OVERLAY * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
