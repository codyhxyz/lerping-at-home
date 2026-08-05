// Water — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original works as an image filter (caustic distortion over u_image).
// This standalone port replaces the image with a procedural deep-water
// gradient that the caustics refract, and drops the image edge-frame logic
// (edges baked to 1, i.e. distortion everywhere).

constant float3 WT_DEEP      = float3(0.006, 0.030, 0.052); // abyss floor
constant float3 WT_SHALLOW   = float3(0.024, 0.128, 0.158); // upper teal
constant float3 WT_HIGHLIGHT = float3(0.620, 0.910, 1.000); // pale aqua

constant float WT_HIGHLIGHTS    = 0.55; // preset 0.07, raised for the dark bg
constant float WT_LAYERING      = 0.5;  // preset default
constant float WT_WAVES         = 0.3;  // preset default
constant float WT_CAUSTIC       = 0.5;  // background refraction strength
constant float WT_PATTERN_SCALE = 5.0;  // matches preset size=1 at ~16:10

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
    float2 patternUV = lerpUV(pos, u.resolution) * WT_PATTERN_SCALE;

    float t = 0.22 * u.time + u.seed * 50.0;

    float wavesNoise = snoise((0.3 + 0.1 * sin(t)) * 0.1 * patternUV + float2(0.0, 0.4 * t));

    float causticNoise = wtCausticNoise(
        patternUV + WT_WAVES * float2(1.0, -1.0) * wavesNoise, 2.0 * t, 1.5);
    causticNoise += WT_LAYERING * wtCausticNoise(
        patternUV + 2.0 * WT_WAVES * float2(1.0, -1.0) * wavesNoise, 1.5 * t, 2.0);
    causticNoise = causticNoise * causticNoise;

    // Refract the procedural background the way the original warps imageUV.
    float wavesDistortion = 0.1 * WT_WAVES * wavesNoise;
    float2 bgUV = screenUV + float2(wavesDistortion, -wavesDistortion);
    bgUV += WT_CAUSTIC * 0.02 * causticNoise;

    // Deep-water gradient: brighter toward the surface (top of screen),
    // with a slow broad swell to keep large areas from looking flat.
    float depth = smoothstep(0.0, 1.0, bgUV.y);
    float swell = 0.5 + 0.5 * snoise(bgUV * 1.4 + float2(0.05 * t, 0.02 * t));
    float3 color = mix(WT_SHALLOW, WT_DEEP, depth);
    color *= 0.85 + 0.3 * swell;

    // Caustic highlights.
    causticNoise = max(-0.2, causticNoise);
    float highlight = 0.025 * WT_HIGHLIGHTS * causticNoise;
    color = mix(color, WT_HIGHLIGHT, 0.05 * WT_HIGHLIGHTS * causticNoise);
    color += WT_HIGHLIGHT * highlight * (0.5 + 0.5 * wavesNoise);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
