// Metaballs — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original reads ball trajectories from a noise texture; this port
// drives them with the prelude's procedural hash21 instead.

constant int   MB_MAX_BALLS   = 20;
constant int   MB_COUNT       = 10;
constant int   MB_COLOR_COUNT = 5;
constant float4 MB_COLORS[MB_COLOR_COUNT] = {
    float4(0.431, 0.200, 0.800, 1.0), // deep violet   #6e33cc
    float4(1.000, 0.333, 0.000, 1.0), // ember orange  #ff5500
    float4(1.000, 0.757, 0.020, 1.0), // amber         #ffc105
    float4(1.000, 0.784, 0.000, 1.0), // gold          #ffc800
    float4(0.961, 0.522, 1.000, 1.0), // orchid        #f585ff
};
constant float3 MB_BACKGROUND = float3(0.014, 0.012, 0.027); // near-black plum
constant float  MB_SIZE = 0.83;

// Stand-in for the original's noise-texture randomizer.
static float mbRandom(float2 p) {
    return hash21(floor(p));
}

// 1D value noise driving each ball's wandering path.
static float mbNoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float w = f * f * (3.0 - 2.0 * f);
    return mix(mbRandom(float2(i, 0.0)), mbRandom(float2(i + 1.0, 0.0)), w);
}

static float mbBallShape(float2 uv, float2 c, float p) {
    float s = 0.5 * length(uv - c);
    s = 1.0 - clamp(s, 0.0, 1.0);
    return pow(s, p);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 shapeUV = lerpUV(pos, u.resolution) * 0.5 + 0.5;

    // Original: t = .2 * (u_time + 2503.4). Slowed for ambience, seeded per launch.
    float t = 0.2 * (0.5 * u.time + 2503.4 + 600.0 * u.seed);

    // Spread ball centers across the full 16:10-ish canvas instead of the
    // original's square object box.
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 spread = float2(0.9 * clamp(aspect, 1.0, 1.7), 0.9);

    float3 totalColor = float3(0.0);
    float totalShape = 0.0;
    float totalOpacity = 0.0;

    for (int i = 0; i < MB_COUNT; i++) {
        float idxFract = float(i) / float(MB_MAX_BALLS);
        float angle = TWO_PI * idxFract;

        float speed = 1.0 - 0.2 * idxFract;
        float noiseX = mbNoise(angle * 10.0 + float(i) + t * speed);
        float noiseY = mbNoise(angle * 20.0 + float(i) - t * speed);

        float2 c = float2(0.5) + 1e-4 + spread * (float2(noiseX, noiseY) - 0.5);

        int safeIndex = i % MB_COLOR_COUNT;
        float4 ballColor = MB_COLORS[safeIndex];

        float shape = mbBallShape(shapeUV, c, 45.0 - 30.0 * MB_SIZE);
        shape *= pow(MB_SIZE, 0.2);
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
    color += MB_BACKGROUND * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
