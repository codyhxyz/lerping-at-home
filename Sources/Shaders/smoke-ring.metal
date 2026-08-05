// Smoke Ring — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original samples a noise texture; this port uses the procedural
// hash-based valueNoise from the prelude instead.

constant int   SR_COLOR_COUNT = 4;
constant float4 SR_COLORS[SR_COLOR_COUNT] = {
    float4(0.980, 0.980, 0.996, 1.0), // hot white core
    float4(0.965, 0.678, 0.333, 1.0), // amber
    float4(0.769, 0.286, 0.580, 1.0), // magenta
    float4(0.212, 0.114, 0.400, 1.0), // deep violet
};
constant float3 SR_BACKGROUND = float3(0.016, 0.012, 0.031);

constant float SR_THICKNESS = 0.50;
constant float SR_RADIUS = 0.42;
constant float SR_INNER_SHAPE = 1.0;
constant float SR_NOISE_SCALE = 1.8;
constant int   SR_NOISE_ITERATIONS = 6;

static float2 srFbm(float2 n0, float2 n1) {
    float2 total = float2(0.0);
    float amplitude = 0.4;
    for (int i = 0; i < SR_NOISE_ITERATIONS; i++) {
        total.x += valueNoise(n0) * amplitude;
        total.y += valueNoise(n1) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

static float srNoise(float2 uv, float2 pUv, float t) {
    float2 pUvLeft = pUv + 0.03 * t;
    float period = max(abs(SR_NOISE_SCALE * TWO_PI), 1e-6);
    float2 pUvRight = float2(fract(pUv.x / period) * period, pUv.y) + 0.03 * t;
    float2 noise = srFbm(pUvLeft, pUvRight);
    return mix(noise.y, noise.x, smoothstep(-0.25, 0.25, uv.x));
}

static float srRingShape(float2 uv) {
    float dist = length(uv);
    float ring = 1.0 - smoothstep(SR_RADIUS, SR_RADIUS + SR_THICKNESS, dist);
    ring *= smoothstep(SR_RADIUS - pow(SR_INNER_SHAPE, 3.0) * SR_THICKNESS, SR_RADIUS, dist);
    return ring;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 shapeUV = lerpUV(pos, u.resolution);

    float t = 0.8 * u.time + u.seed * 60.0;

    float cycleDuration = 3.0;
    float period2 = 2.0 * cycleDuration;
    float localTime1 = fract((0.1 * t + cycleDuration) / period2) * period2;
    float localTime2 = fract((0.1 * t) / period2) * period2;
    float timeBlend = 0.5 + 0.5 * sin(0.1 * t * PI / cycleDuration - 0.5 * PI);

    float atg = atan2(shapeUV.y, shapeUV.x) + 0.001;
    float l = length(shapeUV);
    float radialOffset = 0.5 * l - rsqrt(max(1e-4, l));
    float2 polarUV1 = float2(atg, localTime1 - radialOffset) * SR_NOISE_SCALE;
    float2 polarUV2 = float2(atg, localTime2 - radialOffset) * SR_NOISE_SCALE;

    float noise1 = srNoise(shapeUV, polarUV1, t);
    float noise2 = srNoise(shapeUV, polarUV2, t);
    float noise = mix(noise1, noise2, timeBlend);

    shapeUV *= (0.8 + 1.2 * noise);

    float ringShape = srRingShape(shapeUV);

    float mixer = ringShape * ringShape * float(SR_COLOR_COUNT - 1);
    int idxLast = SR_COLOR_COUNT - 1;
    float4 gradient = SR_COLORS[idxLast];
    for (int i = SR_COLOR_COUNT - 2; i >= 0; i--) {
        float localT = clamp(mixer - float(idxLast - i - 1), 0.0, 1.0);
        gradient = mix(gradient, SR_COLORS[i], localT);
    }

    float3 color = gradient.rgb * ringShape;
    float opacity = gradient.a * ringShape;
    color += SR_BACKGROUND * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
