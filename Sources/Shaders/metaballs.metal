// Metaballs — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original reads ball trajectories from a noise texture; this port
// drives them with the prelude's procedural value noise instead.

// Parameters mirror the upstream <Metaballs> props. Upstream takes a
// variable-length `colors` array (max 8); this port fixes five tunable slots,
// cycled across the balls exactly as upstream does.
//
// lerp-param: color1    color     = (0.431, 0.200, 0.800, 1.0) "Deep violet"
// lerp-param: color2    color     = (1.000, 0.333, 0.000, 1.0) "Ember orange"
// lerp-param: color3    color     = (1.000, 0.757, 0.020, 1.0) "Amber"
// lerp-param: color4    color     = (1.000, 0.784, 0.000, 1.0) "Gold"
// lerp-param: color5    color     = (0.961, 0.522, 1.000, 1.0) "Orchid"
// lerp-param: colorBack color     = (0.014, 0.012, 0.027) "Background"
// lerp-param: count     int 1 20  = 10   "Ball count"
// lerp-param: size      float 0 1 = 0.83 "Size"
// lerp-param: speed     float 0 2 = 0.5  "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 0.5).
// lerp-preset: "Ink Drops" colorBack=#ffffff, color1=#000000, color2=#000000
// lerp-preset: "Ink Drops" color3=#000000, color4=#000000, color5=#000000
// lerp-preset: "Ink Drops" count=18, size=0.1, speed=1
// lerp-preset: Solar   colorBack=#102f84, color1=#ffc800, color2=#ff5500, color3=#ffc105
// lerp-preset: Solar   color4=#ffc800, color5=#ff5500, count=7, size=0.75, speed=0.5
// lerp-preset: Background colorBack=#2a273f, color1=#ae00ff, color2=#00ff95, color3=#ffc105
// lerp-preset: Background color4=#ae00ff, color5=#00ff95, count=13, size=0.81, speed=0.25

constant int   MB_MAX_BALLS   = 20;
constant int   MB_COLOR_COUNT = 5;

static float mbBallShape(float2 uv, float2 c, float p) {
    float s = 0.5 * length(uv - c);
    s = 1.0 - clamp(s, 0.0, 1.0);
    return pow(s, p);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[MB_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4, u.color5 };

    float2 shapeUV = lerpUV(pos, u.resolution) * 0.5 + 0.5;

    // Original: t = .2 * (u_time + 2503.4). Slowed for ambience, seeded per launch.
    float t = 0.2 * (u.speed * u.time + 2503.4 + 600.0 * u.seed);

    // Spread ball centers across the full 16:10-ish canvas instead of the
    // original's square object box.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 spread = float2(0.9 * clamp(aspect, 1.0, 1.7), 0.9);

    float3 totalColor = float3(0.0);
    float totalShape = 0.0;
    float totalOpacity = 0.0;

    for (int i = 0; i < u.count; i++) {
        float idxFract = float(i) / float(MB_MAX_BALLS);
        float angle = TWO_PI * idxFract;

        float speed = 1.0 - 0.2 * idxFract;
        float noiseX = valueNoise(float2(angle * 10.0 + float(i) + t * speed, 0.0));
        float noiseY = valueNoise(float2(angle * 20.0 + float(i) - t * speed, 0.0));

        float2 c = float2(0.5) + 1e-4 + spread * (float2(noiseX, noiseY) - 0.5);

        int safeIndex = i % MB_COLOR_COUNT;
        float4 ballColor = colors[safeIndex];

        float shape = mbBallShape(shapeUV, c, 45.0 - 30.0 * u.size);
        shape *= pow(u.size, 0.2);
        shape = smoothstep(0.0, 1.0, shape);

        totalColor += ballColor.rgb * shape;
        totalShape += shape;
        totalOpacity += ballColor.a * shape;
    }

    totalColor /= max(totalShape, 1e-4);
    totalOpacity /= max(totalShape, 1e-4);

    float edgeWidth = max(fwidth(totalShape), 1e-4);
    float finalShape = smoothstep(0.4, 0.4 + edgeWidth, totalShape);

    float3 color = totalColor * finalShape;
    float opacity = totalOpacity * finalShape;
    color += u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
