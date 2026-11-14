// Prism Caustics — Lerping's own artistic approximation, not a ray-traced
// prism. Three displaced, warped contours suggest dispersed light on a dark
// surface. Analytic line widths and fwidth keep the finest edges from aliasing.
// All motion is a function of time and seed, including in snapshots/scrubs.
// lerp-category: Abstract
// lerp-param: speed float 0 2 = 0.35 "Speed"
// lerp-param: dispersion float 0 1 = 0.55 "Dispersion"
// lerp-param: intensity float 0 2 = 1.0 "Intensity"
// lerp-preset: Ice dispersion=0.2, speed=0.2

static float pcLine(float d, float width) {
    float aa = max(fwidth(d), 0.001);
    return 1.0 - smoothstep(width, width + aa, abs(d));
}
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 p = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / min(u.resolution.x, u.resolution.y);
    float t = u.time * u.speed + u.seed * 6.2831853;
    float2 q = p;
    q.x += 0.17 * sin(2.7 * p.y + t * 0.37) + 0.08 * sin(5.0 * p.y - t * 0.23);
    q.y += 0.12 * sin(3.2 * p.x - t * 0.31);
    float3 col = float3(0.004, 0.007, 0.018) + 0.012 * exp(-1.5 * dot(p, p)) * float3(0.3, 0.5, 1.0);
    for (int i = 0; i < 3; ++i) {
        float shift = (float(i) - 1.0) * u.dispersion * 0.035;
        float d = abs(q.x + shift) * 0.78 + q.y * 0.60 - 0.23;
        float e = abs(q.x - 0.20 + shift) * 0.64 - q.y * 0.77 - 0.20;
        float light = 4.0 * pcLine(d, 0.004) + 2.6 * pcLine(e, 0.003);
        light += 0.012 / (0.018 + abs(d)) + 0.006 / (0.018 + abs(e));
        float3 tint = i == 0 ? float3(0.22, 0.55, 1.0) : (i == 1 ? float3(0.25, 1.0, 0.83) : float3(1.0, 0.32, 0.22));
        col += tint * light * (0.23 * u.intensity) * exp(-0.6 * dot(p, p));
    }
    col = 1.0 - exp(-col);
    return half4(half3(lerpDither(col, pos)), 1.0h);
}
