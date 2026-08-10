// Static Mesh Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The upstream shader is a still frame: inverse-distance blended colour spots
// under a heavy film grain. This port advances the spot-placement seed very
// slowly (a full circuit takes minutes) so the poster keeps its grain but
// never freezes. Texture randomizers replaced with the prelude's valueNoise.
//
// Parameters mirror the upstream <StaticMeshGradient> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes six tunable slots.
// `speed` is this port's own addition — upstream's `positions` is a fixed
// seed, and `speed` is the rate this port drifts it at.
//
// lerp-param: color1       color         = (0.035, 0.047, 0.125) "Midnight blue"
// lerp-param: color2       color         = (0.180, 0.106, 0.353) "Indigo"
// lerp-param: color3       color         = (0.451, 0.157, 0.392) "Magenta plum"
// lerp-param: color4       color         = (0.647, 0.267, 0.278) "Terracotta"
// lerp-param: color5       color         = (0.729, 0.443, 0.251) "Apricot"
// lerp-param: color6       color         = (0.769, 0.596, 0.396) "Dim gold"
// lerp-param: positions    float 0 100   = 25.0 "Positions"
// lerp-param: waveX        float 0 1     = 0.45 "Wave X"
// lerp-param: waveXShift   float 0 1     = 0.15 "Wave X shift"
// lerp-param: waveY        float 0 1     = 0.35 "Wave Y"
// lerp-param: waveYShift   float 0 1     = 0.60 "Wave Y shift"
// lerp-param: mixing       float 0 1     = 0.6  "Mixing"
// lerp-param: grainMixer   float 0 1     = 0.5  "Grain mixer"
// lerp-param: grainOverlay float 0 1     = 0.32 "Grain overlay"
// lerp-param: speed        float 0 0.5   = 0.035 "Drift speed"
//
// Upstream presets (their `positions` and wave values carry over verbatim).
// lerp-preset: 1960s  color1=#000000, color2=#082400, color3=#b1aa91, color4=#8e8c15
// lerp-preset: 1960s  color5=#000000, color6=#082400, positions=42, waveX=0.45, waveXShift=0
// lerp-preset: 1960s  waveY=1, waveYShift=0, mixing=0, grainMixer=0.37, grainOverlay=0.78
// lerp-preset: Sunset color1=#264653, color2=#9c2b2b, color3=#f4a261, color4=#ffffff
// lerp-preset: Sunset color5=#264653, color6=#9c2b2b, positions=0, waveX=0.6, waveXShift=0.7
// lerp-preset: Sunset waveY=0.7, waveYShift=0.7, mixing=0.5, grainMixer=0, grainOverlay=0
// lerp-preset: Sea    color1=#013b65, color2=#03738c, color3=#a3d3ff, color4=#f2faef
// lerp-preset: Sea    color5=#013b65, color6=#03738c, positions=0, waveX=0.53, waveXShift=0
// lerp-preset: Sea    waveY=0.95, waveYShift=0.64, mixing=0.5, grainMixer=0, grainOverlay=0

constant int SMG_COLOR_COUNT = 6;

static float2 smgPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + glmod(float(i), 3.0) * 0.3;
    float c = 0.8 + glmod(float(i + 1), 4.0) * 0.25;
    return 0.5 + 0.5 * float2(sin(t * b + a), cos(t * c + a * 1.5));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float3 colors[SMG_COLOR_COUNT] = {
        u.color1.rgb, u.color2.rgb, u.color3.rgb,
        u.color4.rgb, u.color5.rgb, u.color6.rgb,
    };

    // v_objectUV + .5 — aspect-corrected, 0..1 across the short axis.
    float2 uv = lerpUV(pos, u.resolution) * 0.5 + 0.5;
    float2 grainUV = uv * 1000.0;

    float grain = valueNoise(grainUV);
    float mixerGrain = 0.4 * u.grainMixer * (grain - 0.5);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i += 1.0) {
        uv.x += u.waveX * center / i * cos(TWO_PI * u.waveXShift + i * 2.0 * smoothstep(0.0, 1.0, uv.y));
        uv.y += u.waveY * center / i * cos(TWO_PI * u.waveYShift + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    // Upstream bakes this as a fixed "positions" seed; drifting it very slowly
    // keeps the still-poster feel while giving the screensaver some life.
    float positionSeed = u.positions + u.speed * u.time + 60.0 * u.seed;

    float3 color = float3(0.0);
    float totalWeight = 0.0;
    for (int i = 0; i < SMG_COLOR_COUNT; i++) {
        float2 p = smgPosition(i, positionSeed) + mixerGrain;
        float dist = length(uv - p);

        float mixing = pow(u.mixing, 0.7);
        float power = mix(2.0, 1.0, mixing);
        dist = pow(dist, power);

        float w = 1.0 / (dist + 1e-3);
        float baseSharpness = mix(0.0, 8.0, clamp(w, 0.0, 1.0));
        float sharpness = mix(baseSharpness, 1.0, mixing);
        w = pow(w, sharpness);

        color += colors[i] * w;
        totalWeight += w;
    }
    color /= max(1e-4, totalWeight);

    color = lerpGrainOverlay(color, grainUV, u.grainOverlay);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
