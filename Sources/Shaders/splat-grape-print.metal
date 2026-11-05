// Grape Print — Lerping's print looks (halftone, ordered dither, fluted
// glass) given a real photograph to work on at last: a single grape, captured
// as Gaussian splats and turning, is the source image every frame. The
// Paper ports elsewhere in this folder have to invent their input.
//
// Capture: "Grape" by danylyon (Dany Bittel), CC BY 4.0,
// https://superspl.at/scene/4ae563ac — focus-stacked macro.
// Converted by `make splats`.
//
// lerp-data: splat:orbit:grape
//
// lerp-param: filter     int 0 2       = 0     "Filter (0 halftone, 1 dither, 2 fluted glass)"
// lerp-param: cell       float 3 40    = 9     "Cell size"
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 240  = 80    "Seconds a turn"
// lerp-param: distance   float 1 8     = 4.4   "Distance"
// lerp-param: height     float -2 3    = 1.0   "Camera height"
// lerp-param: lookHeight float -1 1    = 0     "Look at height"
// lerp-param: fov        float 10 80   = 30    "Field of view"
// lerp-param: angle      float -360 360 = 0   "Start angle"
// lerp-param: arc        float 0 360   = 360  "Arc swept (360 = full turn)"
// lerp-param: paper      color         = (0.93, 0.90, 0.84) "Paper"
// lerp-param: ink        color         = (0.10, 0.09, 0.12) "Ink"
//
// lerp-preset: Halftone      filter=0, cell=9
// lerp-preset: Dither        filter=1, cell=3
// lerp-preset: "Fluted glass" filter=2, cell=26

static float3 printSource(texture2d<half> splat, float2 px, float2 res, float3 paper) {
    return lerpSplatOver(lerpSplatSample(splat, px, res), paper);
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float2 res = u.resolution;
    float cell = u.cell * max(1.0, min(res.x, res.y) / 1000.0);
    float3 paper = u.paper.rgb, ink = u.ink.rgb;
    float3 color;
    if (u.filter < 0.5) {
        // CMYK halftone: one rotated screen per ink, each dot sized by how
        // much of that ink the source needs *relative to the paper*, so bare
        // paper stays bare.
        const float4 ang = float4(0.26, 1.31, 0.79, 0.0);
        float4 cover = float4(0.0);
        for (int c = 0; c < 4; c++) {
            float2 p = rotate(pos.xy, ang[c]) / cell;
            float2 centre = floor(p) + 0.5;
            float2 back = rotate(centre * cell, -ang[c]);
            float3 src = printSource(splat, back, res, paper) / max(paper, float3(0.05));
            float3 cmy = saturate(1.0 - src);
            // Light under-colour removal: black only for the deep shadows.
            float k = 0.8 * smoothstep(0.35, 1.0, min(cmy.x, min(cmy.y, cmy.z)));
            float amt = c < 3 ? (cmy[c] - k) / max(1.0 - k, 1e-3) : k;
            float r = sqrt(saturate(amt)) * 0.66;
            float d = length(p - centre);
            float aa = 0.5 * fwidth(d) + 0.02;
            cover[c] = smoothstep(r + aa, r - aa, d);
        }
        color = paper;
        color *= 1.0 - cover.x * float3(0.85, 0.10, 0.0);   // cyan absorbs red
        color *= 1.0 - cover.y * float3(0.05, 0.85, 0.10);  // magenta absorbs green
        color *= 1.0 - cover.z * float3(0.0, 0.08, 0.85);   // yellow absorbs blue
        color = mix(color, ink, cover.w * 0.9);
    } else if (u.filter < 1.5) {
        // Ordered (Bayer 8x8) dither to two inks.
        float2 c = floor(pos.xy / cell);
        float2 centre = (c + 0.5) * cell;
        float3 src = printSource(splat, centre, res, paper);
        float lum = dot(src, float3(0.2126, 0.7152, 0.0722));
        uint2 b = uint2(c) & 7u;
        uint x = b.x ^ b.y;
        uint v = ((x & 1u) << 5) | ((b.y & 1u) << 4) | ((x & 2u) << 2) | ((b.y & 2u) << 1) | ((x & 4u) >> 1) | ((b.y & 4u) >> 2);
        float threshold = (float(v) + 0.5) / 64.0;
        color = lum > threshold ? paper : ink;
    } else {
        // Fluted glass: vertical flutes, each a shallow cylinder lens. The
        // view through one is squeezed toward its centre and softened, so the
        // grape repeats faintly flute to flute rather than in hard slices.
        float w = cell * 2.0;
        float f = fract(pos.x / w) - 0.5;          // -0.5 … 0.5 across a flute
        float bend = sin(f * 3.14159) * 0.5;       // smooth, zero at the centre
        float2 shift = float2(-bend * w * 0.55, 0.0);
        float3 dark = paper * 0.10;
        float3 c = float3(0.0);
        for (int k = -2; k <= 2; k++) {
            float2 o = shift + float2(float(k) * w * 0.06, 0.0);
            c += printSource(splat, pos.xy + o, res, dark);
        }
        color = c / 5.0;
        color *= 0.86 + 0.14 * cos(f * 3.14159);   // flutes darken toward their edges
        color += 0.05 * pow(1.0 - abs(f) * 2.0, 6.0); // a thin highlight down each ridge centre
        color += 0.04 * smoothstep(0.44, 0.5, abs(f));
    }
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
