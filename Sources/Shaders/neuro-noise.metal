// Neuro Noise — ported from paper-design/shaders (Apache-2.0),
// original algorithm by @zozuar: https://x.com/zozuar/status/1625182758745128981
// https://github.com/paper-design/shaders

static float neuroShape(float2 uv, float t) {
    float2 sineAcc = float2(0.0);
    float2 res = float2(0.0);
    float scale = 8.0;

    for (int j = 0; j < 15; j++) {
        uv = rotate(uv, 1.0);
        sineAcc = rotate(sineAcc, 1.0);
        float2 layer = uv * scale + float(j) + sineAcc - t;
        sineAcc += sin(layer);
        res += (0.5 + 0.5 * cos(layer)) / scale;
        scale *= 1.2;
    }
    return res.x + res.y;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float2 shapeUV = uv * 1.4;

    float t = 0.3 * u.time + u.seed * 20.0;

    float noise = neuroShape(shapeUV, t);

    const float brightness = 0.20;
    const float contrast = 0.30;
    noise = (1.0 + brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * contrast);
    noise = min(1.4, noise);

    float blend = smoothstep(0.7, 1.4, noise);

    const float3 colorFront = float3(0.494, 0.910, 0.980); // cyan glow
    const float3 colorMid   = float3(0.129, 0.267, 0.373); // deep steel blue
    const float3 colorBack  = float3(0.012, 0.020, 0.043); // near-black navy

    float3 blendFront = mix(colorMid, colorFront, blend);
    float safeNoise = max(noise, 0.0);
    float3 color = blendFront * safeNoise;
    float opacity = clamp(safeNoise, 0.0, 1.0);
    color += colorBack * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
