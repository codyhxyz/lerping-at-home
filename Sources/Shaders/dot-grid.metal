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
// Deviations, both for antialiasing:
// - Upstream shades each pixel with its own cell's dot only, so any dot wider
//   than its cell is cut off square at the cell edge. The size randomizer runs
//   0.5 + 0.8 * snoise, i.e. -0.3 to 1.3, so a dot can reach
//   (size + strokeWidth) * (1 + 0.3 * sizeRange): 10.4 px of radius in "Tree
//   line", whose cells are 20 px wide, so its biggest dots lost their sides
//   (flat-sided, with a sliver of the dot left in the next cell's column),
//   and any user setting of size near gap / 2 clipped most dots. This port also draws the
//   neighbouring cells whose dots can reach the pixel (none at the default,
//   one either side in x for "Tree line"; capped at 3 for extreme params),
//   composited in absolute cell order so overlaps never flip at a cell edge.
// - Upstream's edge is smoothstep over +/- fwidth(dist), a 2-2.8 px ramp
//   whose width depends on direction. Pattern space is framebuffer pixels, so
//   the footprint is known to be 1 px: edges here are a fixed 1.5-px
//   smoothstep (see dgDisc), and a dot shrinking through zero size fades by
//   its area. Upstream's ramp leaves a half-lit pixel at zero size, which in
//   "Tree line" showed as specks where dots should be gone, popping off as
//   the size randomizer passed through 1. Together with the cell clipping,
//   that put up to 91/255 of per-pixel second difference between 1/60-s
//   frames into "Tree line" (14/255 with both fixed, with a 1-px ramp).
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

// Coverage of one pixel by a disc of radius r at distance d, in pixels: a
// 1.5-px smoothstep, as steep at its middle as a 1-px box-filter ramp but
// with no corners, so an edge drifting 0.025 px a frame changes every pixel
// smoothly. (A 1-px linear ramp was tried first: its corners raised the worst
// per-pixel second difference between 1/60-s frames from 3/255 to 14/255.)
// Below r = 0.75 the ramp alone would leave a centre pixel half lit at
// r = 0; scale by area instead so a shrinking dot fades out continuously.
static inline float dgDisc(float r, float d) {
    float rr = max(r, 0.75);
    float a = saturate(r / rr);
    return (1.0 - smoothstep(rr - 0.75, rr + 0.75, d)) * a * a;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float t = u.speed * u.time + 90.0 * u.seed;

    // Pattern space is plain pixels (the original's 100 * v_patternUV).
    float2 shapeUV = float2(pos.x, u.resolution.y - pos.y);
    shapeUV += float2(3.1 * t, 2.2 * t); // slow diagonal drift

    float2 gap = float2(u.gapX, u.gapY);
    float2 cellUV = shapeUV / gap;
    float2 ownIdx = floor(cellUV);
    // Upstream's fract(uv) + 1e-4 measured from a centre of 0.5 - 1e-3.
    float2 inCell = cellUV + 1e-4 - (0.5 - 1e-3);

    // Largest outer radius any dot can reach (randomizer >= -0.3), plus the
    // 0.75-px AA ramp and slack; cells whose centres lie farther than that
    // cannot touch this pixel.
    float reach = (u.size + u.strokeWidth) * (1.0 + 0.3 * u.sizeRange) + 1.0;
    int2 n = int2(clamp(ceil(reach / gap - 0.5), 0.0, 3.0));

    float3 acc = float3(0.0);   // premultiplied dots, composited in cell order
    float alpha = 0.0;
    for (int dy = -n.y; dy <= n.y; dy++) {
        for (int dx = -n.x; dx <= n.x; dx++) {
            float2 gridIdx = ownIdx + float2(float(dx), float(dy));
            float2 p = (inCell - gridIdx) * gap;
            float dist = length(p); // circle
            if (dist > reach) continue;

            float sizeRandomizer = 0.5 + 0.8 * snoise(2.0 * float2(gridIdx.x * 100.0, gridIdx.y)
                                                      + float2(0.0, 0.11 * t));
            float opacityRandomizer = 0.5 + 0.7 * snoise(2.0 * float2(gridIdx.y, gridIdx.x)
                                                         + float2(0.09 * t, 0.0));
            float k = 1.0 - sizeRandomizer * u.sizeRange;
            float baseSize = u.size * k;
            float strokeWidth = u.strokeWidth * k;

            float shapeOuter = dgDisc(baseSize + strokeWidth, dist);
            float shapeInner = dgDisc(baseSize, dist);
            float stroke = max(shapeOuter - shapeInner, 0.0);

            float dotOpacity = max(0.0, 1.0 - opacityRandomizer * u.opacityRange);
            float3 dotRgb = (stroke * u.colorStroke.rgb + shapeInner * u.colorFill.rgb) * dotOpacity;
            float dotA = (stroke + shapeInner) * dotOpacity;
            acc = dotRgb + (1.0 - dotA) * acc;
            alpha = dotA + (1.0 - dotA) * alpha;
        }
    }

    float3 color = acc + (1.0 - alpha) * u.colorBack.rgb;
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
