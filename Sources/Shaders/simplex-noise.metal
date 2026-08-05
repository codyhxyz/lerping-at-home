// Simplex Noise — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// A multi-colour gradient mapped onto two stacked layers of 2D simplex noise,
// posterised into soft steps between each pair of colours.

constant int SN_COLOR_COUNT = 6;
constant float3 SN_COLORS[SN_COLOR_COUNT] = {
    float3(0.043, 0.043, 0.129), // midnight
    float3(0.180, 0.106, 0.353), // deep violet
    float3(0.427, 0.145, 0.478), // plum
    float3(0.749, 0.259, 0.412), // rose
    float3(0.945, 0.494, 0.310), // coral
    float3(0.988, 0.784, 0.475), // warm sand
};

constant float SN_STEPS_PER_COLOR = 3.0;
constant float SN_SOFTNESS        = 0.45;
constant float SN_SCALE           = 0.7;

static float snField(float2 uv, float t) {
    float noise = 0.5 * snoise(uv - float2(0.0, 0.3 * t));
    noise += 0.5 * snoise(2.0 * uv + float2(0.0, 0.32 * t));
    return noise;
}

static float snStepped(float m, float steps, float softness) {
    float stepT = floor(m * steps) / steps;
    float f = m * steps - floor(m * steps);
    float fw = steps * fwidth(m);
    float smoothed = smoothstep(0.5 - softness, min(1.0, 0.5 + softness + fw), f);
    return stepT + smoothed / steps;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 shapeUV = lerpUV(pos, u.resolution) * SN_SCALE;
    shapeUV = rotate(shapeUV, 0.35 * u.seed * TWO_PI);

    // Original: t = .2 * u_time. Halved for ambience, seeded per launch.
    float t = 0.1 * u.time + 70.0 * u.seed;

    float shape = 0.5 + 0.5 * snField(shapeUV, t);

    const float count = float(SN_COLOR_COUNT);
    const float steps = max(1.0, SN_STEPS_PER_COLOR);
    const float softness = 0.5 * SN_SOFTNESS;

    // u_extraSides = true upstream: the ramp wraps past both ends.
    float mixer = (shape - 0.5 / count) * count;

    float3 gradient = SN_COLORS[0];
    for (int i = 1; i < SN_COLOR_COUNT; i++) {
        float localM = clamp(mixer - float(i - 1), 0.0, 1.0);
        localM = snStepped(localM, steps, softness);
        gradient = mix(gradient, SN_COLORS[i], localM);
    }

    // Wrap band, evaluated unconditionally so fwidth() stays in uniform flow.
    bool past = mixer > (count - 1.0);
    float edgeM = past ? (mixer - (count - 1.0)) : (mixer + 1.0);
    edgeM = snStepped(edgeM, steps, softness);
    float3 edgeGradient = mix(SN_COLORS[SN_COLOR_COUNT - 1], SN_COLORS[0], edgeM);
    if (mixer < 0.0 || past) {
        gradient = edgeGradient;
    }

    float3 color = gradient;

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
