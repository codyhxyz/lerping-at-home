// Aurora — original shader written for Lerping@Home (MIT, do whatever).
// Slow fbm-warped light curtains over a starfield. Doubles as a worked
// example of the custom-shader contract: copy this file into
// ~/Library/Application Support/Lerping/Shaders, edit, and it hot-reloads
// in LerpPreview.
//
// It also shows the parameter contract: every `// lerp-param:` line below
// becomes a field on `LerpUniforms`, so the shader reads it as `u.NAME` with
// no change to the lerpMain signature. `// lerp-preset:` lines name a set of
// overrides. See PORTING.md for the full syntax.
//
// lerp-param: colorSkyLow  color       = (0.004, 0.008, 0.028) "Sky, horizon"
// lerp-param: colorSkyHigh color       = (0.016, 0.035, 0.090) "Sky, zenith"
// lerp-param: colorLow     color       = (0.05, 0.85, 0.45) "Curtain, base"
// lerp-param: colorMid     color       = (0.13, 0.42, 0.95) "Curtain, middle"
// lerp-param: colorHigh    color       = (0.72, 0.25, 0.86) "Curtain, top"
// lerp-param: layers       int 1 3     = 2      "Curtain layers"
// lerp-param: brightness   float 0 3   = 1.35   "Brightness"
// lerp-param: starDensity  float 0 0.02 = 0.0013 "Star density"
// lerp-param: speed        float 0 1   = 0.12   "Speed"
//
// lerp-preset: Ember   colorLow=#ff7a1a, colorMid=#ff2f6b, colorHigh=#7a1aff
// lerp-preset: Ember   colorSkyLow=#050206, colorSkyHigh=#160a1c, brightness=1.6
// lerp-preset: Ember   layers=3, starDensity=0.002, speed=0.09
// lerp-preset: Quiet   layers=1, brightness=0.8, starDensity=0.004, speed=0.05

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
    float t = u.speed * u.time + u.seed * 100.0;

    // Night sky gradient.
    float3 color = mix(u.colorSkyLow.rgb, u.colorSkyHigh.rgb, height);

    // Two layered curtains, the far one dimmer and slower.
    for (int layer = 0; layer < u.layers; layer++) {
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
        float3 auroraColor = mix(u.colorLow.rgb,
                                 u.colorMid.rgb,
                                 clamp(p.y - centerline + 0.5, 0.0, 1.0));
        auroraColor = mix(auroraColor, u.colorHigh.rgb,
                          0.6 * pow(clamp(p.y - centerline + 0.35, 0.0, 1.0), 2.0));

        color += auroraColor * intensity * u.brightness;
    }

    // Sparse static stars, dimmed where the aurora glows.
    float2 cell = floor(pos.xy / 2.0);
    float star = step(1.0 - u.starDensity, hash21(cell));
    star *= 0.35 + 0.65 * hash21(cell + 7.0);
    star *= smoothstep(0.15, 0.65, height);
    color += float3(star) * (1.0 - clamp(length(color) * 1.2 - 0.15, 0.0, 1.0));

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
