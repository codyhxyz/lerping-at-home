// Smoke Ring — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original samples a noise texture; this port uses the procedural
// hash-based valueNoise from the prelude instead.

// Parameters mirror the upstream <SmokeRing> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes four tunable slots.
//
// lerp-param: color1          color         = (0.980, 0.980, 0.996, 1.0) "Hot white core"
// lerp-param: color2          color         = (0.965, 0.678, 0.333, 1.0) "Amber"
// lerp-param: color3          color         = (0.769, 0.286, 0.580, 1.0) "Magenta"
// lerp-param: color4          color         = (0.212, 0.114, 0.400, 1.0) "Deep violet"
// lerp-param: colorBack       color         = (0.016, 0.012, 0.031) "Background"
// lerp-param: thickness       float 0.01 1  = 0.50 "Thickness"
// lerp-param: radius          float 0 1     = 0.42 "Radius"
// lerp-param: innerShape      float 0 4     = 1.0  "Inner shape"
// lerp-param: noiseScale      float 0.01 5  = 1.8  "Noise scale"
// lerp-param: noiseIterations int 1 8       = 6    "Noise iterations"
// lerp-param: speed           float 0 4     = 0.8  "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 1.6).
// lerp-preset: Line   colorBack=#000000, color1=#4540a4, color2=#1fe8ff, color3=#4540a4
// lerp-preset: Line   color4=#1fe8ff, noiseScale=1.1, noiseIterations=2, radius=0.38
// lerp-preset: Line   thickness=0.01, innerShape=0.88, speed=4
// lerp-preset: Solar  colorBack=#000000, color1=#ffffff, color2=#ffca0a, color3=#fc6203
// lerp-preset: Solar  color4=#fc620366, noiseScale=2, noiseIterations=3, radius=0.4
// lerp-preset: Solar  thickness=0.8, innerShape=4, speed=1.6
// lerp-preset: Cloud  colorBack=#81adec, color1=#ffffff, color2=#ffffff, color3=#ffffff
// lerp-preset: Cloud  color4=#ffffff, noiseScale=3, noiseIterations=8, radius=0.5
// lerp-preset: Cloud  thickness=0.65, innerShape=0.85, speed=0.8

constant int SR_COLOR_COUNT = 4;

static float2 srFbm(float2 n0, float2 n1, int iterations) {
    float2 total = float2(0.0);
    float amplitude = 0.4;
    for (int i = 0; i < iterations; i++) {
        total.x += valueNoise(n0) * amplitude;
        total.y += valueNoise(n1) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        amplitude *= 0.65;
    }
    return total;
}

static float srNoise(float2 uv, float2 pUv, float t, float noiseScale, int iterations) {
    float2 pUvLeft = pUv + 0.03 * t;
    float period = max(abs(noiseScale * TWO_PI), 1e-6);
    float2 pUvRight = float2(fract(pUv.x / period) * period, pUv.y) + 0.03 * t;
    float2 noise = srFbm(pUvLeft, pUvRight, iterations);
    return mix(noise.y, noise.x, smoothstep(-0.25, 0.25, uv.x));
}

static float srRingShape(float2 uv, float radius, float thickness, float innerShape) {
    float dist = length(uv);
    float ring = 1.0 - smoothstep(radius, radius + thickness, dist);
    ring *= smoothstep(radius - pow(innerShape, 3.0) * thickness, radius, dist);
    return ring;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[SR_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4 };

    float2 shapeUV = lerpUV(pos, u.resolution);

    float t = u.speed * u.time + u.seed * 60.0;

    float cycleDuration = 3.0;
    float period2 = 2.0 * cycleDuration;
    float localTime1 = fract((0.1 * t + cycleDuration) / period2) * period2;
    float localTime2 = fract((0.1 * t) / period2) * period2;
    float timeBlend = 0.5 + 0.5 * sin(0.1 * t * PI / cycleDuration - 0.5 * PI);

    float atg = atan2(shapeUV.y, shapeUV.x) + 0.001;
    float l = length(shapeUV);
    float radialOffset = 0.5 * l - rsqrt(max(1e-4, l));
    float2 polarUV1 = float2(atg, localTime1 - radialOffset) * u.noiseScale;
    float2 polarUV2 = float2(atg, localTime2 - radialOffset) * u.noiseScale;

    float noise1 = srNoise(shapeUV, polarUV1, t, u.noiseScale, u.noiseIterations);
    float noise2 = srNoise(shapeUV, polarUV2, t, u.noiseScale, u.noiseIterations);
    float noise = mix(noise1, noise2, timeBlend);

    shapeUV *= (0.8 + 1.2 * noise);

    float ringShape = srRingShape(shapeUV, u.radius, u.thickness, u.innerShape);

    float mixer = ringShape * ringShape * float(SR_COLOR_COUNT - 1);
    int idxLast = SR_COLOR_COUNT - 1;
    float4 gradient = colors[idxLast];
    for (int i = SR_COLOR_COUNT - 2; i >= 0; i--) {
        float localT = clamp(mixer - float(idxLast - i - 1), 0.0, 1.0);
        gradient = mix(gradient, colors[i], localT);
    }

    float3 color = gradient.rgb * ringShape;
    float opacity = gradient.a * ringShape;
    color += u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
