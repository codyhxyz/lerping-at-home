// Dot Grid — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original grid is static; this port scrolls it on a slow diagonal and
// walks the per-cell size/opacity randomizers through time so the field
// breathes. Circle shape, stroked, from the paper.design default.
//
// That alone read as a still picture on the lock screen: the scroll moves the
// grid as one rigid piece, and the randomizers drift so slowly that the
// "Default" preset (sizeRange = opacityRange = 0) had nothing else at all.
// What keeps it moving now is three ripples of the
// lattice: longitudinal waves, in short-side units so they look the same at
// any resolution, that push dots back and forth along their direction of
// travel, so fronts of bunched and spread dots sweep across the grid at
// different angles and speeds. Where dots bunch they swell (up to 20% larger)
// and brighten, where they spread they shrink and dim. Strain stays under
// 0.25, so the lattice never folds, and each dot is measured through the
// inverse of the warp's local Jacobian so it stays round, not squeezed. The
// neighbour search widens by the local stretch, so nothing clips, and costs
// the same as before at every preset. Local change is now about 0.7-1.1%/s.
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
// lerp-category: Patterns
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

// One longitudinal ripple of the lattice, in short-side units: dots are
// pushed back and forth along `k`, so they bunch and spread in fronts that
// travel through the grid. Accumulates the displacement, its Jacobian (as
// columns, d/ds.x and d/ds.y) and its divergence.
static inline void dgRipple(float2 s, float t, float2 k, float a, float w, float phi,
                            thread float2& d, thread float2x2& grad, thread float& div,
                            thread float& norm) {
    float ph = dot(k, s) - w * t + phi;
    float kl = length(k);
    float2 dir = k / kl;
    float c = a * cos(ph);
    d += a * sin(ph) * dir;
    grad += float2x2(c * k.x * dir, c * k.y * dir);
    div += c * kl;
    norm += a * kl;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float t = u.speed * u.time + 90.0 * u.seed;

    float2 screen = float2(pos.x, u.resolution.y - pos.y);
    float shortSide = min(u.resolution.x, u.resolution.y);
    float2 s = (screen - 0.5 * u.resolution) / shortSide;

    // Three ripples crossing at different angles, wavelengths and speeds;
    // their sum never stops everywhere at once. Strain stays under 0.25.
    float2 disp = float2(0.0);
    float2x2 grad = float2x2(0.0);
    float div = 0.0, norm = 0.0;
    dgRipple(s, t, float2( 5.6,  4.2), 0.012, 1.25, 0.0, disp, grad, div, norm);
    dgRipple(s, t, float2(-2.8,  4.8), 0.014, 1.00, 2.1, disp, grad, div, norm);
    dgRipple(s, t, float2( 1.7, -8.3), 0.008, 1.60, 4.4, disp, grad, div, norm);
    // Where the ripples crowd dots together they swell and brighten.
    float swell = div / norm; // -1..1

    // Pattern space is plain pixels (the original's 100 * v_patternUV).
    float2 shapeUV = screen + disp * shortSide;
    shapeUV += float2(3.1 * t, 2.2 * t); // slow diagonal drift

    // d(pattern)/d(screen), and its inverse: a pattern-space offset from a
    // dot centre maps back to screen pixels through it, so dots stay round
    // where the lattice is stretched or squeezed.
    float2x2 J = float2x2(1.0) + grad;
    float2x2 Jinv = float2x2(float2(J[1][1], -J[0][1]), float2(-J[1][0], J[0][0]))
                  / (J[0][0] * J[1][1] - J[1][0] * J[0][1]);
    float stretch = 1.0 + sqrt(dot(grad[0], grad[0]) + dot(grad[1], grad[1])); // >= largest singular value of J

    float2 gap = float2(u.gapX, u.gapY);
    float2 cellUV = shapeUV / gap;
    float2 ownIdx = floor(cellUV);
    // Upstream's fract(uv) + 1e-4 measured from a centre of 0.5 - 1e-3.
    float2 inCell = cellUV + 1e-4 - (0.5 - 1e-3);

    float swellSize = 1.0 + 0.2 * swell;
    float swellOpacity = 1.0 + 0.2 * swell;
    // Largest outer radius any dot can reach here (randomizer >= -0.3), plus
    // the 0.75-px AA ramp and slack, in screen pixels; cells whose centres lie
    // farther than that (in pattern space, `stretch` times as far) cannot
    // touch this pixel.
    float reach = (u.size + u.strokeWidth) * (1.0 + 0.3 * u.sizeRange) * swellSize + 1.0;
    int2 n = int2(clamp(ceil(reach * stretch / gap - 0.5), 0.0, 3.0));

    float3 acc = float3(0.0);   // premultiplied dots, composited in cell order
    float alpha = 0.0;
    for (int dy = -n.y; dy <= n.y; dy++) {
        for (int dx = -n.x; dx <= n.x; dx++) {
            float2 gridIdx = ownIdx + float2(float(dx), float(dy));
            float2 p = Jinv * ((inCell - gridIdx) * gap);
            float dist = length(p); // circle, in screen pixels
            if (dist > reach) continue;

            float sizeRandomizer = 0.5 + 0.8 * snoise(2.0 * float2(gridIdx.x * 100.0, gridIdx.y)
                                                      + float2(0.0, 0.11 * t));
            float opacityRandomizer = 0.5 + 0.7 * snoise(2.0 * float2(gridIdx.y, gridIdx.x)
                                                         + float2(0.09 * t, 0.0));
            float k = (1.0 - sizeRandomizer * u.sizeRange) * swellSize;
            float baseSize = u.size * k;
            float strokeWidth = u.strokeWidth * k;

            float shapeOuter = dgDisc(baseSize + strokeWidth, dist);
            float shapeInner = dgDisc(baseSize, dist);
            float stroke = max(shapeOuter - shapeInner, 0.0);

            float dotOpacity = saturate((1.0 - opacityRandomizer * u.opacityRange) * swellOpacity);
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
