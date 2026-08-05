// Mesh Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// "Lagoon" palette.

constant int   MG_COLOR_COUNT = 5;
constant float4 MG_COLORS[MG_COLOR_COUNT] = {
    float4(0.043, 0.231, 0.290, 1.0), // deep teal
    float4(0.106, 0.604, 0.667, 1.0), // turquoise
    float4(0.498, 0.847, 0.745, 1.0), // seafoam
    float4(0.957, 0.914, 0.804, 1.0), // warm sand
    float4(0.180, 0.251, 0.341, 1.0), // slate indigo
};
constant float MG_DISTORTION = 0.8;
constant float MG_SWIRL = 0.35;

static float2 mgPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    return 0.5 + 0.5 * float2(sin(t * b + a), cos(t * c + a * 1.5));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution) * 0.5 + 0.5;

    const float firstFrameOffset = 41.5;
    float t = 0.5 * (0.22 * u.time + firstFrameOffset + u.seed * 40.0);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i += 1.0) {
        uv.x += MG_DISTORTION * center / i
              * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y))
              * cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += MG_DISTORTION * center / i
              * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uvRotated = uv - 0.5;
    uvRotated = rotate(uvRotated, -3.0 * MG_SWIRL * radius);
    uvRotated += 0.5;

    float3 color = float3(0.0);
    float totalWeight = 0.0;
    for (int i = 0; i < MG_COLOR_COUNT; i++) {
        float2 p = mgPosition(i, t);
        float dist = length(uvRotated - p);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        color += MG_COLORS[i].rgb * weight;
        totalWeight += weight;
    }
    color /= max(1e-4, totalWeight);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
