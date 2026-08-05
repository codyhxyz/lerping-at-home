// Water — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original works as an image filter (caustic distortion over u_image).
// This standalone port replaces the image with a procedural deep-water
// gradient that the caustics refract, and drops the image edge-frame logic
// (edges baked to 1, i.e. distortion everywhere).

// Parameters mirror the upstream <Water> props, except that upstream's single
// `colorBack` becomes a two-stop depth gradient here (`colorBack` at the
// bottom, `colorSurface` at the top) because there is no input image to tint.
// Upstream's `edges` prop controls the image frame, which this port drops, so
// it is not exposed. `size` is in this port's units.
//
// lerp-param: colorBack      color         = (0.006, 0.030, 0.052) "Abyss"
// lerp-param: colorSurface   color         = (0.024, 0.128, 0.158) "Surface"
// lerp-param: colorHighlight color         = (0.620, 0.910, 1.000) "Highlight"
// lerp-param: size           float 0.25 25 = 5.0  "Size"
// lerp-param: highlights     float 0 1     = 0.55 "Highlights"
// lerp-param: layering       float 0 1     = 0.5  "Layering"
// lerp-param: waves          float 0 1     = 0.3  "Waves"
// lerp-param: caustic        float 0 1     = 0.5  "Caustic"
// lerp-param: speed          float 0 3     = 0.22 "Speed"
//
// Upstream presets, size mapped into this port's units and speed scaled to
// this port's ambience (upstream × 0.22).
// lerp-preset: "Slow-mo"  highlights=0.4, layering=0, waves=0, caustic=0.2, size=3.5, speed=0.022
// lerp-preset: Abstract   highlights=0, layering=0, waves=1, caustic=0.4, size=0.75, speed=0.22
// lerp-preset: Streaming  highlights=0, layering=0, waves=0.5, caustic=0, size=2.5, speed=0.44

static float wtCausticNoise(float2 uv, float t, float scale) {
    float2 n = float2(0.1);
    float2 N = float2(0.1);
    float2x2 m = float2x2(float2(cos(0.5), sin(0.5)), float2(-sin(0.5), cos(0.5)));
    for (int j = 0; j < 6; j++) {
        uv = uv * m; // row-vector product, matches GLSL `uv *= m`
        n = n * m;
        float2 q = uv * scale + float(j) + n +
                   (0.5 + 0.5 * float(j)) * (glmod(float(j), 2.0) - 1.0) * t;
        n += sin(q);
        N += cos(q) / scale;
        scale *= 1.1;
    }
    return N.x + N.y + 1.0;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 screenUV = lerpScreenUV(pos, u.resolution); // 0..1, y down
    float2 patternUV = lerpUV(pos, u.resolution) * u.size;

    float t = u.speed * u.time + u.seed * 50.0;

    float wavesNoise = snoise((0.3 + 0.1 * sin(t)) * 0.1 * patternUV + float2(0.0, 0.4 * t));

    float causticNoise = wtCausticNoise(
        patternUV + u.waves * float2(1.0, -1.0) * wavesNoise, 2.0 * t, 1.5);
    causticNoise += u.layering * wtCausticNoise(
        patternUV + 2.0 * u.waves * float2(1.0, -1.0) * wavesNoise, 1.5 * t, 2.0);
    causticNoise = causticNoise * causticNoise;

    // Refract the procedural background the way the original warps imageUV.
    float wavesDistortion = 0.1 * u.waves * wavesNoise;
    float2 bgUV = screenUV + float2(wavesDistortion, -wavesDistortion);
    bgUV += u.caustic * 0.02 * causticNoise;

    // Deep-water gradient: brighter toward the surface (top of screen),
    // with a slow broad swell to keep large areas from looking flat.
    float depth = smoothstep(0.0, 1.0, bgUV.y);
    float swell = 0.5 + 0.5 * snoise(bgUV * 1.4 + float2(0.05 * t, 0.02 * t));
    float3 color = mix(u.colorSurface.rgb, u.colorBack.rgb, depth);
    color *= 0.85 + 0.3 * swell;

    // Caustic highlights.
    causticNoise = max(-0.2, causticNoise);
    float highlight = 0.025 * u.highlights * causticNoise;
    color = mix(color, u.colorHighlight.rgb, 0.05 * u.highlights * causticNoise);
    color += u.colorHighlight.rgb * highlight * (0.5 + 0.5 * wavesNoise);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
