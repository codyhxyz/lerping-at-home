// Dot Orbit — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Voronoi dots orbiting their cell centers; ember palette after the
// paper.design default preset. Texture randomizers replaced with the
// procedural hashes from the prelude.

constant int    DO_COLOR_COUNT = 5;
constant float3 DO_COLORS[DO_COLOR_COUNT] = {
    float3(1.000, 0.788, 0.420), // pale amber
    float3(1.000, 0.384, 0.000), // orange
    float3(1.000, 0.184, 0.000), // vermilion
    float3(0.259, 0.067, 0.000), // burnt umber
    float3(0.102, 0.000, 0.000), // ember black
};
constant float3 DO_COLOR_BACK = float3(0.016, 0.006, 0.004); // near-black warm
constant float DO_SIZE            = 1.0;
constant float DO_SIZE_RANGE      = 0.0;
constant float DO_SPREADING       = 1.0;
constant float DO_STEPS_PER_COLOR = 4.0;

static float3 doVoronoi(float2 uv, float time) {
    float2 iUV = floor(uv);
    float2 fUV = fract(uv);

    float spreading = 0.25 * clamp(DO_SPREADING, 0.0, 1.0);

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
    // ~= v_patternUV * 1.5 of the original at a 750px short axis.
    float2 shapeUV = lerpUV(pos, u.resolution) * 5.6;

    const float firstFrameOffset = -10.0;
    float t = 0.55 * u.time + firstFrameOffset + 60.0 * u.seed;

    float3 voronoi = doVoronoi(shapeUV, t) + 1e-4;

    float radius = 0.25 * clamp(DO_SIZE, 0.0, 1.0)
                 - 0.5 * clamp(DO_SIZE_RANGE, 0.0, 1.0) * voronoi[2];
    float dist = voronoi[0];
    float edgeWidth = fwidth(dist);
    float dots = 1.0 - smoothstep(radius - edgeWidth, radius + edgeWidth, dist);

    float shape = voronoi[1];

    const float colorsCount = float(DO_COLOR_COUNT);
    float mixer = (shape - 0.5 / colorsCount) * colorsCount;
    float steps = max(1.0, DO_STEPS_PER_COLOR);

    float3 gradient = DO_COLORS[0];
    for (int i = 1; i < DO_COLOR_COUNT; i++) {
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = round(localT * steps) / steps;
        gradient = mix(gradient, DO_COLORS[i], localT);
    }

    if ((mixer < 0.0) || (mixer > (colorsCount - 1.0))) {
        float localT = mixer + 1.0;
        if (mixer > (colorsCount - 1.0)) {
            localT = mixer - (colorsCount - 1.0);
        }
        localT = round(localT * steps) / steps;
        gradient = mix(DO_COLORS[DO_COLOR_COUNT - 1], DO_COLORS[0], localT);
    }

    float3 color = gradient * dots + DO_COLOR_BACK * (1.0 - dots);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
