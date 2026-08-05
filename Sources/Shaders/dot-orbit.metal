// Dot Orbit — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Voronoi dots orbiting their cell centers; ember palette after the
// paper.design default preset. Texture randomizers replaced with the
// procedural hashes from the prelude.

// Parameters mirror the upstream <DotOrbit> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes five tunable slots.
// `scale` is in this port's units, not upstream's sizing system.
//
// lerp-param: color1        color        = (1.000, 0.788, 0.420) "Pale amber"
// lerp-param: color2        color        = (1.000, 0.384, 0.000) "Orange"
// lerp-param: color3        color        = (1.000, 0.184, 0.000) "Vermilion"
// lerp-param: color4        color        = (0.259, 0.067, 0.000) "Burnt umber"
// lerp-param: color5        color        = (0.102, 0.000, 0.000) "Ember black"
// lerp-param: colorBack     color        = (0.016, 0.006, 0.004) "Background"
// lerp-param: scale         float 0.5 24 = 5.6 "Scale"
// lerp-param: stepsPerColor int 1 4      = 4   "Steps per colour"
// lerp-param: size          float 0 1    = 1.0 "Dot size"
// lerp-param: sizeRange     float 0 1    = 0.0 "Size range"
// lerp-param: spreading     float 0 1    = 1.0 "Spreading"
// lerp-param: speed         float 0 8    = 0.55 "Speed"
//
// Upstream presets, scale mapped into this port's units and speed scaled to
// this port's ambience (upstream × 0.367).
// lerp-preset: Bubbles color1=#d0d2d5, color2=#d0d2d5, color3=#d0d2d5, color4=#d0d2d5
// lerp-preset: Bubbles color5=#d0d2d5, colorBack=#989ca4, stepsPerColor=2
// lerp-preset: Bubbles size=0.9, sizeRange=0.7, spreading=1, scale=9.2, speed=0.147
// lerp-preset: Shine   color1=#ffffff, color2=#006aff, color3=#fff675, color4=#ffffff
// lerp-preset: Shine   color5=#006aff, colorBack=#000000, stepsPerColor=4
// lerp-preset: Shine   size=0.3, sizeRange=0.2, spreading=1, scale=2.24, speed=0.037
// lerp-preset: Hallucinatory color1=#000000, color2=#000000, color3=#000000
// lerp-preset: Hallucinatory color4=#000000, color5=#000000, colorBack=#ffe500
// lerp-preset: Hallucinatory stepsPerColor=2, size=0.65, sizeRange=0, spreading=0.3
// lerp-preset: Hallucinatory scale=2.8, speed=1.835

constant int DO_COLOR_COUNT = 5;

static float3 doVoronoi(float2 uv, float time, float spreadingAmount) {
    float2 iUV = floor(uv);
    float2 fUV = fract(uv);

    float spreading = 0.25 * clamp(spreadingAmount, 0.0, 1.0);

    float minDist = 1.0;
    float2 randomizer = float2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 tileOffset = float2(float(x), float(y));
            float2 rand = hash22(iUV + tileOffset);
            float2 cellCenter = float2(0.5 + 1e-4);
            cellCenter += spreading * cos(time + TWO_PI * rand);
            cellCenter -= 0.5;
            cellCenter = rotate(cellCenter, hash21(rand) + 0.1 * time);
            cellCenter += 0.5;
            float dist = length(tileOffset + cellCenter - fUV);
            if (dist < minDist) {
                minDist = dist;
                randomizer = rand;
            }
        }
    }

    return float3(minDist, randomizer);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float3 colors[DO_COLOR_COUNT] = {
        u.color1.rgb, u.color2.rgb, u.color3.rgb, u.color4.rgb, u.color5.rgb,
    };

    // ~= v_patternUV * 1.5 of the original at a 750px short axis.
    float2 shapeUV = lerpUV(pos, u.resolution) * u.scale;

    const float firstFrameOffset = -10.0;
    float t = u.speed * u.time + firstFrameOffset + 60.0 * u.seed;

    float3 voronoi = doVoronoi(shapeUV, t, u.spreading) + 1e-4;

    float radius = 0.25 * clamp(u.size, 0.0, 1.0)
                 - 0.5 * clamp(u.sizeRange, 0.0, 1.0) * voronoi[2];
    float dist = voronoi[0];
    float edgeWidth = fwidth(dist);
    float dots = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, dist);

    float shape = voronoi[1];

    const float colorsCount = float(DO_COLOR_COUNT);
    float mixer = (shape - 0.5 / colorsCount) * colorsCount;
    float steps = max(1.0, float(u.stepsPerColor));

    float3 gradient = colors[0];
    for (int i = 1; i < DO_COLOR_COUNT; i++) {
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = round(localT * steps) / steps;
        gradient = mix(gradient, colors[i], localT);
    }

    if ((mixer < 0.0) || (mixer > (colorsCount - 1.0))) {
        float localT = mixer + 1.0;
        if (mixer > (colorsCount - 1.0)) {
            localT = mixer - (colorsCount - 1.0);
        }
        localT = round(localT * steps) / steps;
        gradient = mix(colors[DO_COLOR_COUNT - 1], colors[0], localT);
    }

    float3 color = gradient * dots + u.colorBack.rgb * (1.0 - dots);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
