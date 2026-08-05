// Simplex Noise — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// A multi-colour gradient mapped onto two stacked layers of 2D simplex noise,
// posterised into soft steps between each pair of colours.
//
// Parameters mirror the upstream <SimplexNoise> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes the palette at six
// slots, all six tunable. `scale` is in this port's units.
//
// lerp-param: color1        color      = (0.043, 0.043, 0.129) "Midnight"
// lerp-param: color2        color      = (0.180, 0.106, 0.353) "Deep violet"
// lerp-param: color3        color      = (0.427, 0.145, 0.478) "Plum"
// lerp-param: color4        color      = (0.749, 0.259, 0.412) "Rose"
// lerp-param: color5        color      = (0.945, 0.494, 0.310) "Coral"
// lerp-param: color6        color      = (0.988, 0.784, 0.475) "Warm sand"
// lerp-param: scale         float 0.1 4 = 0.7 "Scale"
// lerp-param: stepsPerColor int 1 10   = 3   "Steps per colour"
// lerp-param: softness      float 0 1  = 0.45 "Softness"
// lerp-param: speed         float 0 2  = 0.1  "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream / 5).
// lerp-preset: Spots  color1=#ff7b00, color2=#f9ffeb, color3=#320d82, color4=#ff7b00
// lerp-preset: Spots  color5=#f9ffeb, color6=#320d82, stepsPerColor=1, softness=0, scale=1.17, speed=0.12
// lerp-preset: "First contact" color1=#e8cce6, color2=#120d22, color3=#442c44
// lerp-preset: "First contact" color4=#e6baba, color5=#fff5f5, color6=#e8cce6
// lerp-preset: "First contact" stepsPerColor=2, softness=0, scale=0.23, speed=0.4
// lerp-preset: Bubblegum color1=#ffffff, color2=#ff9e9e, color3=#5f57ff, color4=#00f7ff
// lerp-preset: Bubblegum color5=#ffffff, color6=#ff9e9e, stepsPerColor=1, softness=1, scale=1.87, speed=0.4

constant int SN_COLOR_COUNT = 6;

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
    float3 colors[SN_COLOR_COUNT] = {
        u.color1.rgb, u.color2.rgb, u.color3.rgb,
        u.color4.rgb, u.color5.rgb, u.color6.rgb,
    };

    float2 shapeUV = lerpUV(pos, u.resolution) * u.scale;
    shapeUV = rotate(shapeUV, 0.35 * u.seed * TWO_PI);

    // Original: t = .2 * u_time. Halved for ambience, seeded per launch.
    float t = u.speed * u.time + 70.0 * u.seed;

    float shape = 0.5 + 0.5 * snField(shapeUV, t);

    const float count = float(SN_COLOR_COUNT);
    float steps = max(1.0, float(u.stepsPerColor));
    float softness = 0.5 * u.softness;

    // u_extraSides = true upstream: the ramp wraps past both ends.
    float mixer = (shape - 0.5 / count) * count;

    float3 gradient = colors[0];
    for (int i = 1; i < SN_COLOR_COUNT; i++) {
        float localM = clamp(mixer - float(i - 1), 0.0, 1.0);
        localM = snStepped(localM, steps, softness);
        gradient = mix(gradient, colors[i], localM);
    }

    // Wrap band, evaluated unconditionally so fwidth() stays in uniform flow.
    bool past = mixer > (count - 1.0);
    float edgeM = past ? (mixer - (count - 1.0)) : (mixer + 1.0);
    edgeM = snStepped(edgeM, steps, softness);
    float3 edgeGradient = mix(colors[SN_COLOR_COUNT - 1], colors[0], edgeM);
    if (mixer < 0.0 || past) {
        gradient = edgeGradient;
    }

    float3 color = gradient;

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
