// Grain Gradient — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// "Corners" shape from the paper.design default preset: grainy color bands
// radiating from opposite corners over black. Texture randomizers replaced
// with the procedural hash noise from the prelude.
//
// Parameters mirror the upstream <GrainGradient> props. Upstream's `shape`
// enum is not ported — this file is always the "corners" shape. Upstream takes
// a variable-length `colors` array (max 7); this port fixes four slots.
//
// lerp-param: color1    color     = (0.451, 0.000, 1.000) "Violet"
// lerp-param: color2    color     = (0.922, 0.659, 1.000) "Pale orchid"
// lerp-param: color3    color     = (0.000, 0.749, 1.000) "Sky cyan"
// lerp-param: color4    color     = (0.165, 0.000, 1.000) "Deep ultramarine"
// lerp-param: colorBack color     = (0.000, 0.000, 0.000) "Background"
// lerp-param: softness  float 0 1 = 0.5  "Softness"
// lerp-param: intensity float 0 1 = 0.5  "Intensity"
// lerp-param: noise     float 0 1 = 0.25 "Noise"
// lerp-param: speed     float 0 2 = 0.4  "Speed"
//
// Palettes from upstream's presets (their shapes are not ported, so only the
// colour/softness/intensity/noise parts carry over).
// lerp-preset: Wave    colorBack=#000a0f, color1=#c4730b, color2=#bdad5f, color3=#d8ccc7
// lerp-preset: Wave    color4=#c4730b, softness=0.7, intensity=0.15, noise=0.5, speed=0.4
// lerp-preset: Truchet colorBack=#0a0000, color1=#6f2200, color2=#eabb7c, color3=#39b523
// lerp-preset: Truchet color4=#6f2200, softness=0, intensity=0.2, noise=1, speed=0.4
// lerp-preset: Blob    colorBack=#0f0e18, color1=#3e6172, color2=#a49b74, color3=#568c50
// lerp-preset: Blob    color4=#3e6172, softness=0, intensity=0.15, noise=0.5, speed=0.4

constant int GG_COLOR_COUNT = 4;

static float4 ggFbm(float2 n0, float2 n1, float2 n2, float2 n3) {
    float amplitude = 0.2;
    float4 total = float4(0.0);
    for (int i = 0; i < 3; i++) {
        n0 = rotate(n0, 0.3);
        n1 = rotate(n1, 0.3);
        n2 = rotate(n2, 0.3);
        n3 = rotate(n3, 0.3);
        total.x += valueNoise(n0) * amplitude;
        total.y += valueNoise(n1) * amplitude;
        total.z += valueNoise(n2) * amplitude;
        total.z += valueNoise(n3) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        n2 *= 1.99;
        n3 *= 1.99;
        amplitude *= 0.6;
    }
    return total;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float3 colors[GG_COLOR_COUNT] = { u.color1.rgb, u.color2.rgb, u.color3.rgb, u.color4.rgb };

    const float firstFrameOffset = 7.0;
    float t = 0.1 * (u.speed * u.time + firstFrameOffset + 53.0 * u.seed);

    // ~= v_objectUV (fit: contain box on the short axis) of the original.
    float2 shapeUV = lerpUV(pos, u.resolution) * 0.5;
    // ~= grain_uv: object UV scaled back up to pixels, * 0.7.
    float2 grainUV = shapeUV * min(u.resolution.x, u.resolution.y) * 0.7;

    // Shape: corners.
    float2 suv = shapeUV * 0.6;
    const float2 outer = float2(0.5);

    float2 bl = smoothstep(float2(0.0), outer,
                           suv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * sin(5.25 * t)));
    float2 tr = smoothstep(float2(0.0), outer, 1.0 - suv);
    float shape = 1.0 - bl.x * bl.y * tr.x * tr.y;

    suv = -suv;
    bl = smoothstep(float2(0.0), outer,
                    suv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * cos(5.25 * t)));
    tr = smoothstep(float2(0.0), outer, 1.0 - suv);
    shape -= bl.x * bl.y * tr.x * tr.y;

    shape = 1.0 - smoothstep(0.0, 1.0, shape);

    // Grain.
    const float colorsCount = float(GG_COLOR_COUNT);
    float baseNoise = snoise(grainUV * 0.5);
    float4 fbmVals = ggFbm(0.002 * grainUV + 10.0,
                           0.003 * grainUV,
                           0.001 * grainUV,
                           rotate(0.4 * grainUV, 2.0));
    float grainDist = baseNoise * snoise(grainUV * 0.2) - fbmVals.x - fbmVals.y;
    float rawNoise = 0.75 * baseNoise - fbmVals.w - fbmVals.z;
    float noise = clamp(rawNoise, 0.0, 1.0);

    shape += u.intensity * 2.0 / colorsCount * (grainDist + 0.5);
    shape += u.noise * 10.0 / colorsCount * noise;

    float aa = fwidth(shape);

    shape = clamp(shape - 0.5 / colorsCount, 0.0, 1.0);
    float totalShape = smoothstep(0.0, u.softness + 2.0 * aa, clamp(shape * colorsCount, 0.0, 1.0));
    float mixer = shape * (colorsCount - 1.0);

    float3 gradient = colors[0];
    for (int i = 1; i < GG_COLOR_COUNT; i++) {
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = smoothstep(0.5 - 0.5 * u.softness - aa, 0.5 + 0.5 * u.softness + aa, localT);
        gradient = mix(gradient, colors[i], localT);
    }

    float3 color = gradient * totalShape + u.colorBack.rgb * (1.0 - totalShape);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
