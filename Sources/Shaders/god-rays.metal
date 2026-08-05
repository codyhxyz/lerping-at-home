// God Rays — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original samples a noise texture for its randomizer; this port uses
// the prelude's procedural hash-based valueNoise instead. The uniform
// params are baked from the paper.design "Default" preset, recolored to a
// dark cosmic palette, with the light source placed low-center.

constant int    GR_COLOR_COUNT = 4;
constant float4 GR_COLORS[GR_COLOR_COUNT] = {
    float4(0.651, 0.000, 1.000, 0.43), // violet
    float4(0.384, 0.000, 1.000, 0.94), // electric indigo
    float4(1.000, 1.000, 1.000, 0.60), // white core
    float4(0.200, 1.000, 0.961, 0.75), // aqua
};
constant float3 GR_COLOR_BACK  = float3(0.010, 0.013, 0.038); // deep navy
constant float3 GR_COLOR_BLOOM = float3(0.05, 0.10, 0.85);    // blue bloom overlay
constant float  GR_BLOOM         = 0.4;  // 0 = alpha blend, 1 = additive
constant float  GR_DENSITY       = 1.8;  // preset density 0.3 -> 6*0.3
constant float  GR_SPOTS         = 1.95; // preset spotty 0.3 -> 6.5*0.3
constant float  GR_INTENSITY     = 2.7;  // sharper than preset (more dark sky)
constant float  GR_MID_SIZE      = 2.0;  // preset midSize 0.2 -> 10*0.2
constant float  GR_MID_INTENSITY = 0.4;
constant float2 GR_SOURCE = float2(0.0, -0.5); // ray origin in lerpUV space

static float grRaysShape(float2 uv, float r, float freq, float intensity) {
    float a = atan2(uv.y, uv.x);
    float2 left  = float2(a * freq, r);
    float2 right = float2(fract(a / TWO_PI) * TWO_PI * freq, r);
    float nLeft  = pow(valueNoise(left), intensity);
    float nRight = pow(valueNoise(right), intensity);
    // left is seam-free on +x, right on -x; blend across the boundary.
    return mix(nRight, nLeft, smoothstep(-0.15, 0.15, uv.x));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 shapeUV = lerpUV(pos, u.resolution) - GR_SOURCE;
    shapeUV = rotate(shapeUV, u.seed * TWO_PI); // per-launch ray orientation

    float t = 0.08 * u.time + u.seed * 43.0;

    float radius = length(shapeUV);

    float msLo = 0.02 * GR_MID_SIZE;
    float msHi = max(GR_MID_SIZE, 1e-6);
    float middleShape = pow(GR_MID_INTENSITY, 0.3) *
                        (1.0 - smoothstep(msLo, msHi, 3.0 * radius));
    middleShape = pow(middleShape, 5.0);

    float3 accumColor = float3(0.0);
    float  accumAlpha = 0.0;

    for (int i = 0; i < GR_COLOR_COUNT; i++) {
        float2 rotatedUV = rotate(shapeUV, float(i) + 1.0);

        float r1 = radius * (1.0 + 0.4 * float(i)) - 3.0 * t;
        float r2 = 0.5 * radius * (1.0 + GR_SPOTS) - 2.0 * t;
        float f = mix(1.0, 3.0 + 0.5 * float(i), hash11(float(i) * 15.0)) * GR_DENSITY;

        float ray = grRaysShape(rotatedUV, r1, 5.0 * f, GR_INTENSITY);
        ray *= grRaysShape(rotatedUV, r2, 4.0 * f, GR_INTENSITY);
        ray += (1.0 + 4.0 * ray) * middleShape;
        ray = clamp(ray, 0.0, 1.0);

        float srcAlpha = GR_COLORS[i].a * ray;
        float3 srcColor = GR_COLORS[i].rgb * srcAlpha;

        float3 alphaBlendColor = accumColor + (1.0 - accumAlpha) * srcColor;
        float  alphaBlendAlpha = accumAlpha + (1.0 - accumAlpha) * srcAlpha;
        float3 addBlendColor = accumColor + srcColor;
        float  addBlendAlpha = accumAlpha + srcAlpha;

        accumColor = mix(alphaBlendColor, addBlendColor, GR_BLOOM);
        accumAlpha = mix(alphaBlendAlpha, addBlendAlpha, GR_BLOOM);
    }

    // Bloom color overlay, then composite over the background.
    accumColor = mix(accumColor, accumColor + accumAlpha * GR_COLOR_BLOOM, GR_BLOOM);
    // accumColor is premultiplied; composite over the opaque background.
    float a = clamp(accumAlpha, 0.0, 1.0);
    float3 color = clamp(accumColor, 0.0, 1.0) + (1.0 - a) * GR_COLOR_BACK;
    color = clamp(color, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
