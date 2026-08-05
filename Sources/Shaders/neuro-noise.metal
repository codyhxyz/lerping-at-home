// Neuro Noise — ported from paper-design/shaders (Apache-2.0),
// original algorithm by @zozuar: https://x.com/zozuar/status/1625182758745128981
// https://github.com/paper-design/shaders
//
// Parameters mirror the upstream <NeuroNoise> props. `scale` is in this port's
// units, not upstream's sizing system.
//
// lerp-param: colorFront color       = (0.494, 0.910, 0.980) "Front"
// lerp-param: colorMid   color       = (0.129, 0.267, 0.373) "Mid"
// lerp-param: colorBack  color       = (0.012, 0.020, 0.043) "Background"
// lerp-param: scale      float 0.2 6 = 1.4  "Scale"
// lerp-param: brightness float 0 1   = 0.20 "Brightness"
// lerp-param: contrast   float 0 1   = 0.30 "Contrast"
// lerp-param: speed      float 0 2   = 0.3  "Speed"
//
// Upstream presets; scale mapped into this port's units (upstream × 1.4),
// speed scaled to this port's ambience (upstream × 0.3).
// lerp-preset: Sensation  colorFront=#00c8ff, colorMid=#fbff00, colorBack=#8b42ff
// lerp-preset: Sensation  brightness=0.19, contrast=0.12, scale=4.2, speed=0.3
// lerp-preset: Bloodstream colorFront=#ff0000, colorMid=#ff0000, colorBack=#ffffff
// lerp-preset: Bloodstream brightness=0.24, contrast=0.17, scale=0.98, speed=0.3
// lerp-preset: Ghost      colorFront=#ffffff, colorMid=#000000, colorBack=#ffffff
// lerp-preset: Ghost      brightness=0, contrast=1, scale=0.77, speed=0.3

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
    float2 shapeUV = uv * u.scale;

    float t = u.speed * u.time + u.seed * 20.0;

    float noise = neuroShape(shapeUV, t);

    noise = (1.0 + u.brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * u.contrast);
    noise = min(1.4, noise);

    float blend = smoothstep(0.7, 1.4, noise);

    float3 blendFront = mix(u.colorMid.rgb, u.colorFront.rgb, blend);
    float safeNoise = max(noise, 0.0);
    float3 color = blendFront * safeNoise;
    float opacity = clamp(safeNoise, 0.0, 1.0);
    color += u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
