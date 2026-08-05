// Static Mesh Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The upstream shader is a still frame: inverse-distance blended colour spots
// under a heavy film grain. This port advances the spot-placement seed very
// slowly (a full circuit takes minutes) so the poster keeps its grain but
// never freezes. Texture randomizers replaced with the prelude's valueNoise.

constant int SMG_COLOR_COUNT = 6;
constant float3 SMG_COLORS[SMG_COLOR_COUNT] = {
    float3(0.035, 0.047, 0.125), // midnight blue
    float3(0.180, 0.106, 0.353), // indigo
    float3(0.451, 0.157, 0.392), // magenta plum
    float3(0.647, 0.267, 0.278), // terracotta
    float3(0.729, 0.443, 0.251), // apricot
    float3(0.769, 0.596, 0.396), // dim gold
};

constant float SMG_WAVE_X       = 0.45;
constant float SMG_WAVE_X_SHIFT = 0.15;
constant float SMG_WAVE_Y       = 0.35;
constant float SMG_WAVE_Y_SHIFT = 0.60;
constant float SMG_MIXING       = 0.6;
constant float SMG_GRAIN_MIXER  = 0.5;
constant float SMG_GRAIN_OVERLAY = 0.32;

static float2 smgPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + glmod(float(i), 3.0) * 0.3;
    float c = 0.8 + glmod(float(i + 1), 4.0) * 0.25;
    return 0.5 + 0.5 * float2(sin(t * b + a), cos(t * c + a * 1.5));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // v_objectUV + .5 — aspect-corrected, 0..1 across the short axis.
    float2 uv = lerpUV(pos, u.resolution) * 0.5 + 0.5;
    float2 grainUV = uv * 1000.0;

    float grain = valueNoise(grainUV);
    float mixerGrain = 0.4 * SMG_GRAIN_MIXER * (grain - 0.5);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i += 1.0) {
        uv.x += SMG_WAVE_X * center / i * cos(TWO_PI * SMG_WAVE_X_SHIFT + i * 2.0 * smoothstep(0.0, 1.0, uv.y));
        uv.y += SMG_WAVE_Y * center / i * cos(TWO_PI * SMG_WAVE_Y_SHIFT + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    // Upstream bakes this as a fixed "positions" seed; drifting it very slowly
    // keeps the still-poster feel while giving the screensaver some life.
    float positionSeed = 25.0 + 0.035 * u.time + 60.0 * u.seed;

    float3 color = float3(0.0);
    float totalWeight = 0.0;
    for (int i = 0; i < SMG_COLOR_COUNT; i++) {
        float2 p = smgPosition(i, positionSeed) + mixerGrain;
        float dist = length(uv - p);

        float mixing = pow(SMG_MIXING, 0.7);
        float power = mix(2.0, 1.0, mixing);
        dist = pow(dist, power);

        float w = 1.0 / (dist + 1e-3);
        float baseSharpness = mix(0.0, 8.0, clamp(w, 0.0, 1.0));
        float sharpness = mix(baseSharpness, 1.0, mixing);
        w = pow(w, sharpness);

        color += SMG_COLORS[i] * w;
        totalWeight += w;
    }
    color /= max(1e-4, totalWeight);

    float grainOverlay = valueNoise(rotate(grainUV, 1.0) + 3.0);
    grainOverlay = mix(grainOverlay, valueNoise(rotate(grainUV, 2.0) - 1.0), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);

    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(SMG_GRAIN_OVERLAY * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
