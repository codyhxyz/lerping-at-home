// Dot Grid — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original grid is static; this port scrolls it on a slow diagonal and
// walks the per-cell size/opacity randomizers through time so the field
// breathes. Circle shape, stroked, from the paper.design default.
//
// Parameters mirror the upstream <DotGrid> props, in the same pixel units.
// Upstream's `shape` enum is not ported — this file always draws circles.
// `speed` is this port's own addition: upstream DotGrid does not animate.
//
// lerp-param: colorBack    color        = (0.016, 0.020, 0.043) "Background"
// lerp-param: colorFill    color        = (0.192, 0.310, 0.847) "Fill"
// lerp-param: colorStroke  color        = (0.749, 0.847, 1.000) "Stroke"
// lerp-param: size         float 1 100  = 10.0 "Dot size (px)"
// lerp-param: gapX         float 2 500  = 46.0 "Gap X (px)"
// lerp-param: gapY         float 2 500  = 46.0 "Gap Y (px)"
// lerp-param: strokeWidth  float 0 50   = 2.2  "Stroke width (px)"
// lerp-param: sizeRange    float 0 1    = 0.75 "Size range"
// lerp-param: opacityRange float 0 1    = 0.70 "Opacity range"
// lerp-param: speed        float 0 2    = 0.5  "Speed"
//
// Upstream presets (the two whose shape is a circle).
// lerp-preset: "Tree line" colorBack=#f4fce7, colorFill=#052e19, colorStroke=#000000
// lerp-preset: "Tree line" size=8, gapX=20, gapY=90, strokeWidth=0, sizeRange=1, opacityRange=0.6
// lerp-preset: Default     colorBack=#000000, colorFill=#ffffff, colorStroke=#ffaa00
// lerp-preset: Default     size=2, gapX=32, gapY=32, strokeWidth=0, sizeRange=0, opacityRange=0

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float t = u.speed * u.time + 90.0 * u.seed;

    // Pattern space is plain pixels (the original's 100 * v_patternUV).
    float2 shapeUV = float2(pos.x, u.resolution.y - pos.y);
    shapeUV += float2(3.1 * t, 2.2 * t); // slow diagonal drift

    float2 gap = float2(u.gapX, u.gapY);
    float2 grid = fract(shapeUV / gap) + 1e-4;
    float2 gridIdx = floor(shapeUV / gap);

    float sizeRandomizer = 0.5 + 0.8 * snoise(2.0 * float2(gridIdx.x * 100.0, gridIdx.y)
                                              + float2(0.0, 0.11 * t));
    float opacityRandomizer = 0.5 + 0.7 * snoise(2.0 * float2(gridIdx.y, gridIdx.x)
                                                 + float2(0.09 * t, 0.0));

    float2 center = float2(0.5) - 1e-3;
    float2 p = (grid - center) * gap;

    float baseSize = u.size * (1.0 - sizeRandomizer * u.sizeRange);
    float strokeWidth = u.strokeWidth * (1.0 - sizeRandomizer * u.sizeRange);

    float dist = length(p); // circle

    float edgeWidth = fwidth(dist);
    float shapeOuter = 1.0 - smoothstep(baseSize - edgeWidth, baseSize + edgeWidth, dist - strokeWidth);
    float shapeInner = 1.0 - smoothstep(baseSize - edgeWidth, baseSize + edgeWidth, dist);
    float stroke = shapeOuter - shapeInner;

    float dotOpacity = max(0.0, 1.0 - opacityRandomizer * u.opacityRange);
    stroke *= dotOpacity;
    shapeInner *= dotOpacity;

    float3 color = stroke * u.colorStroke.rgb
                 + shapeInner * u.colorFill.rgb
                 + (1.0 - shapeInner - stroke) * u.colorBack.rgb;

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
