// Dot Grid — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original grid is static; this port scrolls it on a slow diagonal and
// walks the per-cell size/opacity randomizers through time so the field
// breathes. Circle shape, stroked, from the paper.design default.

constant float3 DG_COLOR_BACK   = float3(0.016, 0.020, 0.043); // near-black navy
constant float3 DG_COLOR_FILL   = float3(0.192, 0.310, 0.847); // cobalt
constant float3 DG_COLOR_STROKE = float3(0.749, 0.847, 1.000); // pale ice

constant float DG_DOT_SIZE      = 10.0; // pixels
constant float DG_GAP_X         = 46.0; // pixels
constant float DG_GAP_Y         = 46.0; // pixels
constant float DG_STROKE_WIDTH  = 2.2;  // pixels
constant float DG_SIZE_RANGE    = 0.75;
constant float DG_OPACITY_RANGE = 0.70;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float t = 0.5 * u.time + 90.0 * u.seed;

    // Pattern space is plain pixels (the original's 100 * v_patternUV).
    float2 shapeUV = float2(pos.x, u.resolution.y - pos.y);
    shapeUV += float2(3.1 * t, 2.2 * t); // slow diagonal drift

    float2 gap = float2(DG_GAP_X, DG_GAP_Y);
    float2 grid = fract(shapeUV / gap) + 1e-4;
    float2 gridIdx = floor(shapeUV / gap);

    float sizeRandomizer = 0.5 + 0.8 * snoise(2.0 * float2(gridIdx.x * 100.0, gridIdx.y)
                                              + float2(0.0, 0.11 * t));
    float opacityRandomizer = 0.5 + 0.7 * snoise(2.0 * float2(gridIdx.y, gridIdx.x)
                                                 + float2(0.09 * t, 0.0));

    float2 center = float2(0.5) - 1e-3;
    float2 p = (grid - center) * gap;

    float baseSize = DG_DOT_SIZE * (1.0 - sizeRandomizer * DG_SIZE_RANGE);
    float strokeWidth = DG_STROKE_WIDTH * (1.0 - sizeRandomizer * DG_SIZE_RANGE);

    float dist = length(p); // circle

    float edgeWidth = fwidth(dist);
    float shapeOuter = 1.0 - smoothstep(baseSize - edgeWidth, baseSize + edgeWidth, dist - strokeWidth);
    float shapeInner = 1.0 - smoothstep(baseSize - edgeWidth, baseSize + edgeWidth, dist);
    float stroke = shapeOuter - shapeInner;

    float dotOpacity = max(0.0, 1.0 - opacityRandomizer * DG_OPACITY_RANGE);
    stroke *= dotOpacity;
    shapeInner *= dotOpacity;

    float3 color = stroke * DG_COLOR_STROKE
                 + shapeInner * DG_COLOR_FILL
                 + (1.0 - shapeInner - stroke) * DG_COLOR_BACK;

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
