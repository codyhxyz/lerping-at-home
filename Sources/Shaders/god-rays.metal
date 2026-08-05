// God Rays — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original samples a noise texture for its randomizer; this port uses
// the prelude's procedural hash-based valueNoise instead. The uniform
// params are baked from the paper.design "Default" preset, recolored to a
// dark cosmic palette, with the light source placed low-center.

// Parameters mirror the upstream <GodRays> props. `density`, `spotty`,
// `intensity` and `midSize` are pre-multiplied here the way upstream's GLSL
// multiplies its 0..1 props, so the ranges below are the upstream ranges
// scaled by the same factor. Colour alphas are the per-ray opacities upstream
// carries in its 8-digit hex colours. `offsetX`/`offsetY` are upstream's ray
// origin, in this port's lerpUV space.
//
// lerp-param: color1       color         = (0.651, 0.000, 1.000, 0.43) "Violet"
// lerp-param: color2       color         = (0.384, 0.000, 1.000, 0.94) "Electric indigo"
// lerp-param: color3       color         = (1.000, 1.000, 1.000, 0.60) "White core"
// lerp-param: color4       color         = (0.200, 1.000, 0.961, 0.75) "Aqua"
// lerp-param: colorBack    color         = (0.010, 0.013, 0.038) "Background"
// lerp-param: colorBloom   color         = (0.05, 0.10, 0.85) "Bloom"
// lerp-param: bloom        float 0 1     = 0.4  "Bloom"
// lerp-param: density      float 0 6     = 1.8  "Density"
// lerp-param: spotty       float 0 6.5   = 1.95 "Spotty"
// lerp-param: intensity    float 0 10    = 2.7  "Intensity"
// lerp-param: midSize      float 0 10    = 2.0  "Mid size"
// lerp-param: midIntensity float 0 1     = 0.4  "Mid intensity"
// lerp-param: offsetX      float -1 1    = 0.0  "Offset X"
// lerp-param: offsetY      float -1 1    = -0.5 "Offset Y"
// lerp-param: speed        float 0 2     = 0.08 "Speed"
//
// Upstream presets, with the pre-multiplied scaling applied and speed scaled
// to this port's ambience (upstream × 0.107).
// lerp-preset: Warp   colorBack=#000000, colorBloom=#222288, color1=#ff47d4, color2=#ff8c00
// lerp-preset: Warp   color3=#ffffff, color4=#ff47d4, density=2.7, spotty=0.975
// lerp-preset: Warp   midIntensity=0.4, midSize=3.3, intensity=7.9, bloom=0.4, speed=0.214
// lerp-preset: Linear offsetX=0.2, offsetY=-0.8, colorBack=#000000, colorBloom=#eeeeee
// lerp-preset: Linear color1=#ffffff1f, color2=#ffffff3d, color3=#ffffff29, color4=#ffffff1f
// lerp-preset: Linear density=2.46, spotty=1.625, midSize=1, midIntensity=0.75
// lerp-preset: Linear intensity=7.9, bloom=1, speed=0.054
// lerp-preset: Ether  offsetX=-0.6, colorBack=#090f1d, colorBloom=#ffffff
// lerp-preset: Ether  color1=#148effa6, color2=#c4dffebe, color3=#232a47, color4=#148effa6
// lerp-preset: Ether  density=0.18, spotty=5.005, midSize=1, midIntensity=0.6
// lerp-preset: Ether  intensity=6, bloom=0.6, speed=0.107

constant int GR_COLOR_COUNT = 4;

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
    float4 colors[GR_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4 };

    float2 shapeUV = lerpUV(pos, u.resolution) - float2(u.offsetX, u.offsetY);
    shapeUV = rotate(shapeUV, u.seed * TWO_PI); // per-launch ray orientation

    float t = u.speed * u.time + u.seed * 43.0;

    float radius = length(shapeUV);

    float msLo = 0.02 * u.midSize;
    float msHi = max(u.midSize, 1e-6);
    float middleShape = pow(u.midIntensity, 0.3) *
                        (1.0 - smoothstep(msLo, msHi, 3.0 * radius));
    middleShape = pow(middleShape, 5.0);

    float3 accumColor = float3(0.0);
    float  accumAlpha = 0.0;

    for (int i = 0; i < GR_COLOR_COUNT; i++) {
        float2 rotatedUV = rotate(shapeUV, float(i) + 1.0);

        float r1 = radius * (1.0 + 0.4 * float(i)) - 3.0 * t;
        float r2 = 0.5 * radius * (1.0 + u.spotty) - 2.0 * t;
        float f = mix(1.0, 3.0 + 0.5 * float(i), hash11(float(i) * 15.0)) * u.density;

        float ray = grRaysShape(rotatedUV, r1, 5.0 * f, u.intensity);
        ray *= grRaysShape(rotatedUV, r2, 4.0 * f, u.intensity);
        ray += (1.0 + 4.0 * ray) * middleShape;
        ray = clamp(ray, 0.0, 1.0);

        float srcAlpha = colors[i].a * ray;
        float3 srcColor = colors[i].rgb * srcAlpha;

        float3 alphaBlendColor = accumColor + (1.0 - accumAlpha) * srcColor;
        float  alphaBlendAlpha = accumAlpha + (1.0 - accumAlpha) * srcAlpha;
        float3 addBlendColor = accumColor + srcColor;
        float  addBlendAlpha = accumAlpha + srcAlpha;

        accumColor = mix(alphaBlendColor, addBlendColor, u.bloom);
        accumAlpha = mix(alphaBlendAlpha, addBlendAlpha, u.bloom);
    }

    // Bloom color overlay, then composite over the background.
    accumColor = mix(accumColor, accumColor + accumAlpha * u.colorBloom.rgb, u.bloom);
    // accumColor is premultiplied; composite over the opaque background.
    float a = clamp(accumAlpha, 0.0, 1.0);
    float3 color = clamp(accumColor, 0.0, 1.0) + (1.0 - a) * u.colorBack.rgb;
    color = clamp(color, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
