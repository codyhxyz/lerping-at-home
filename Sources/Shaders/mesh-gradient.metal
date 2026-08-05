// Mesh Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// "Lagoon" palette.
//
// Parameters mirror the upstream <MeshGradient> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes five tunable slots.
// Upstream's grainMixer/grainOverlay are not ported — this file has no grain.
//
// lerp-param: color1     color     = (0.043, 0.231, 0.290) "Deep teal"
// lerp-param: color2     color     = (0.106, 0.604, 0.667) "Turquoise"
// lerp-param: color3     color     = (0.498, 0.847, 0.745) "Seafoam"
// lerp-param: color4     color     = (0.957, 0.914, 0.804) "Warm sand"
// lerp-param: color5     color     = (0.180, 0.251, 0.341) "Slate indigo"
// lerp-param: distortion float 0 1 = 0.8  "Distortion"
// lerp-param: swirl      float 0 1 = 0.35 "Swirl"
// lerp-param: speed      float 0 2 = 0.22 "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 0.22).
// lerp-preset: Ink    color1=#ffffff, color2=#000000, color3=#ffffff, color4=#000000
// lerp-preset: Ink    color5=#ffffff, distortion=1, swirl=0.2, speed=0.22
// lerp-preset: Purple color1=#aaa7d7, color2=#3c2b8e, color3=#aaa7d7, color4=#3c2b8e
// lerp-preset: Purple color5=#aaa7d7, distortion=1, swirl=1, speed=0.132
// lerp-preset: Beach  color1=#bcecf6, color2=#00aaff, color3=#00f7ff, color4=#ffd447
// lerp-preset: Beach  color5=#bcecf6, distortion=0.8, swirl=0.35, speed=0.022

constant int MG_COLOR_COUNT = 5;

static float2 mgPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    return 0.5 + 0.5 * float2(sin(t * b + a), cos(t * c + a * 1.5));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[MG_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4, u.color5 };

    float2 uv = lerpUV(pos, u.resolution) * 0.5 + 0.5;

    const float firstFrameOffset = 41.5;
    float t = 0.5 * (u.speed * u.time + firstFrameOffset + u.seed * 40.0);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i += 1.0) {
        uv.x += u.distortion * center / i
              * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y))
              * cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += u.distortion * center / i
              * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uvRotated = uv - 0.5;
    uvRotated = rotate(uvRotated, -3.0 * u.swirl * radius);
    uvRotated += 0.5;

    float3 color = float3(0.0);
    float totalWeight = 0.0;
    for (int i = 0; i < MG_COLOR_COUNT; i++) {
        float2 p = mgPosition(i, t);
        float dist = length(uvRotated - p);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        color += colors[i].rgb * weight;
        totalWeight += weight;
    }
    color /= max(1e-4, totalWeight);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
