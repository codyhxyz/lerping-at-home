// Warp — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Checks pattern with noise distortion + layered swirls; dark violet marble
// palette after the paper.design default preset.

constant int    WARP_COLOR_COUNT = 4;
constant float3 WARP_COLORS[WARP_COLOR_COUNT] = {
    float3(0.071, 0.071, 0.078), // near-black charcoal
    float3(0.580, 0.439, 1.000), // soft violet
    float3(0.071, 0.071, 0.078), // near-black charcoal
    float3(0.533, 0.220, 1.000), // electric purple
};
constant float WARP_PROPORTION       = 0.45;
constant float WARP_SOFTNESS         = 1.0;
constant float WARP_SHAPE_SCALE      = 0.1;  // checks zoom
constant float WARP_DISTORTION       = 0.25;
constant float WARP_SWIRL            = 0.8;
constant int   WARP_SWIRL_ITERATIONS = 10;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // ~= v_patternUV * 0.5 of the original at a 750px short axis.
    float2 uv = lerpUV(pos, u.resolution) * 1.9;

    const float firstFrameOffset = 118.0;
    float t = 0.0625 * (0.5 * u.time + firstFrameOffset + 97.0 * u.seed);

    float n1 = valueNoise(uv + t);
    float n2 = valueNoise(uv * 2.0 - t);
    float angle = n1 * TWO_PI;
    uv.x += 4.0 * WARP_DISTORTION * n2 * cos(angle);
    uv.y += 4.0 * WARP_DISTORTION * n2 * sin(angle);

    for (int i = 1; i < WARP_SWIRL_ITERATIONS; i++) {
        float iF = float(i);
        uv.x += WARP_SWIRL / iF * cos(t + iF * 1.5 * uv.y);
        uv.y += WARP_SWIRL / iF * cos(t + iF * 1.0 * uv.x);
    }

    // Base pattern: checks.
    float2 checksUV = uv * (0.5 + 3.5 * WARP_SHAPE_SCALE);
    float shape = 0.5 + 0.5 * sin(checksUV.x) * cos(checksUV.y);
    shape += 0.48 * sign(WARP_PROPORTION - 0.5) * pow(abs(WARP_PROPORTION - 0.5), 0.5);

    float mixer = shape * float(WARP_COLOR_COUNT - 1);
    float3 gradient = WARP_COLORS[0];
    float aa = fwidth(shape);
    for (int i = 1; i < WARP_COLOR_COUNT; i++) {
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);

        float localMixerStart = floor(m);
        float softness = 0.5 * WARP_SOFTNESS + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa),
                                    min(1.0, 0.5 + softness + aa),
                                    m - localMixerStart);
        float stepped = localMixerStart + smoothed;

        m = mix(stepped, m, WARP_SOFTNESS);
        gradient = mix(gradient, WARP_COLORS[i], m);
    }

    float3 color = gradient;
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
