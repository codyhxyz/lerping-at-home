// Aurora — original shader written for Lerping@Home (MIT, do whatever).
// Slow fbm-warped light curtains over a starfield. Doubles as a worked
// example of the custom-shader contract: copy this file into
// ~/Library/Application Support/Lerping/Shaders, edit, and it hot-reloads
// in LerpPreview.

static float auroraFbm(float2 p) {
    float value = 0.0;
    float amplitude = 0.55;
    for (int i = 0; i < 4; i++) {
        value += amplitude * valueNoise(p);
        p = rotate(p, 0.62) * 2.02;
        amplitude *= 0.5;
    }
    return value;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);       // centered, y up
    float height = clamp(uv.y * 0.5 + 0.5, 0.0, 1.0);
    float t = 0.12 * u.time + u.seed * 100.0;

    // Night sky gradient.
    float3 color = mix(float3(0.004, 0.008, 0.028), float3(0.016, 0.035, 0.090), height);

    // Two layered curtains, the far one dimmer and slower.
    for (int layer = 0; layer < 2; layer++) {
        float fl = float(layer);
        float speed = mix(1.0, 0.55, fl);
        float2 p = uv * mix(1.0, 1.7, fl);

        float warp = auroraFbm(float2(p.x * 1.1 + t * speed, p.y * 0.4 - 0.3 * t * speed));
        float rays = auroraFbm(float2(3.0 * p.x + 2.0 * warp + 13.7 * fl, 0.6 * t * speed));
        rays = pow(clamp(rays * 1.7 - 0.42, 0.0, 1.0), 2.2);

        float centerline = rays * 0.9 - 0.25 + 0.18 * fl;
        float vertical = exp(-2.0 * abs(p.y - centerline));
        float intensity = rays * vertical * mix(1.0, 0.45, fl);

        // Green near the base, teal-blue mid, violet at the top edge.
        float3 auroraColor = mix(float3(0.05, 0.85, 0.45),
                                 float3(0.13, 0.42, 0.95),
                                 clamp(p.y - centerline + 0.5, 0.0, 1.0));
        auroraColor = mix(auroraColor, float3(0.72, 0.25, 0.86),
                          0.6 * pow(clamp(p.y - centerline + 0.35, 0.0, 1.0), 2.0));

        color += auroraColor * intensity * 1.35;
    }

    // Sparse static stars, dimmed where the aurora glows.
    float2 cell = floor(pos.xy / 2.0);
    float star = step(0.9987, hash21(cell));
    star *= 0.35 + 0.65 * hash21(cell + 7.0);
    star *= smoothstep(0.15, 0.65, height);
    color += float3(star) * (1.0 - clamp(length(color) * 1.2 - 0.15, 0.0, 1.0));

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
