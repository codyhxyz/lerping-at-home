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

// Parameters mirror the upstream <FlutedGlass> props. Upstream's `shape` and
// `distortionShape` enums are not ported — this file is always "lines" ribs
// with the "prism" flute. `blur`, `edges` and the four margins are not ported
// either. The shadow and highlight alphas come from upstream's 8-digit hex
// colours. `speed` is this port's own addition: upstream FlutedGlass is
// static, and here it drives the procedural backdrop that replaces the image.
//
// (Upstream's `colorBack` is not exposed: the procedural backdrop is opaque
// and covers it everywhere, so it would be a knob that does nothing.)
// lerp-param: colorShadow    color       = (0.012, 0.024, 0.055, 0.60) "Shadow"
// lerp-param: colorHighlight color       = (0.925, 0.965, 1.000, 0.45) "Highlight"
// lerp-param: size           float 0.01 1 = 0.86 "Size"
// lerp-param: angle          float 0 180 = 0.0  "Angle"
// lerp-param: shadows        float 0 1   = 0.70 "Shadows"
// lerp-param: highlights     float 0 1   = 0.55 "Highlights"
// lerp-param: distortion     float 0 1   = 0.55 "Distortion"
// lerp-param: shift          float -1 1  = 0.20 "Shift"
// lerp-param: stretch        float 0 1   = 0.35 "Stretch"
// lerp-param: grainMixer     float 0 1   = 0.20 "Grain mixer"
// lerp-param: grainOverlay   float 0 1   = 0.22 "Grain overlay"
// lerp-param: speed          float 0 2   = 0.35 "Backdrop speed"
//
// Upstream presets, restricted to the props this port implements.
// lerp-preset: Waves  size=0.9, angle=0, shadows=0, highlights=0, distortion=0.5
// lerp-preset: Waves  shift=0, stretch=1, grainMixer=0, grainOverlay=0.05
// lerp-preset: Folds  size=0.4, angle=0, shadows=0.4, highlights=0, distortion=0.75
// lerp-preset: Folds  shift=0, stretch=0, grainMixer=0, grainOverlay=0
// lerp-preset: Abstract size=0.7, angle=30, shadows=0, highlights=0, distortion=1
// lerp-preset: Abstract shift=0, stretch=1, grainMixer=0.1, grainOverlay=0.1

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

    float t = u.speed * u.time + 70.0 * u.seed;

    float patternRotation = -u.angle * PI / 180.0;
    float patternSize = mix(200.0, 5.0, u.size);

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
    highlights = clamp((1.0 - highlights) * u.highlights, 0.0, 1.0);

    float shadows = pow(x, 1.3);

    float aa = max(max(fwidth(xNonSmooth), fwidth(uv.x)), 0.0001);

    // u_distortionShape = 1: the classic convex flute.
    float distortion = -pow(1.5 * x, 3.0) + (0.5 - u.shift);
    aa = max(0.2, aa) + mix(0.2, 0.0, u.size);
    float fadeX = smoothstep(0.0, aa, xNonSmooth) * smoothstep(1.0, 1.0 - aa, xNonSmooth);
    distortion = mix(0.5, distortion, fadeX);

    float2 grainUV = (imageUV - 0.5) * 0.8 * u.resolution + 0.5;
    float grain = smoothstep(0.4, 0.7, valueNoise(grainUV)) * u.grainMixer;
    distortion = mix(distortion, 0.0, grain);

    shadows = clamp(min(shadows, 1.0) * pow(u.shadows, 2.0), 0.0, 1.0);
    distortion *= 3.0 * u.distortion;

    fractOrigUV.x += distortion;
    floorOrigUV = fgRotateAspect(floorOrigUV, -patternRotation, aspect);
    fractOrigUV = fgRotateAspect(fractOrigUV, -patternRotation, aspect);

    float2 sampleUV = (floorOrigUV + fractOrigUV) / patternSize + 0.5;

    float stretch = 1.0 - smoothstep(0.0, 0.5, xNonSmooth) * smoothstep(1.0, 0.5, xNonSmooth);
    stretch = pow(stretch, 2.0);
    sampleUV.y = mix(sampleUV.y, 0.5, u.stretch * stretch);

    float3 image = fgBackdrop(sampleUV, t);

    float3 color = u.colorHighlight.rgb * u.colorHighlight.a * highlights;
    float opacity = u.colorHighlight.a * highlights;

    shadows = mix(shadows * u.colorShadow.a, 0.0, highlights);
    color = mix(color, u.colorShadow.rgb * u.colorShadow.a, 0.5 * shadows);
    color += 0.5 * pow(shadows, 0.5) * u.colorShadow.rgb;
    opacity = clamp(opacity + shadows, 0.0, 1.0);
    color = clamp(color, 0.0, 1.0);

    // The backdrop is opaque, so it fills whatever the glass layer leaves.
    color += image * (1.0 - opacity);

    color = lerpGrainOverlay(color, grainUV, u.grainOverlay);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
