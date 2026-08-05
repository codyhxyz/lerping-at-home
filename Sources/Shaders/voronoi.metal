// Voronoi — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Double-pass Voronoi borders after https://www.shadertoy.com/view/ldl3W8
// (Inigo Quilez, MIT). The original's noise-texture randomizer is replaced
// with the prelude's procedural hash22. Recolored from the orange/yellow
// demo default to a dark stained-glass palette with shaded cell rims.
//
// Parameters mirror the upstream <Voronoi> props. Upstream takes a
// variable-length `colors` array (max 5); this port fixes four tunable slots.
// `colorGlow`'s alpha is the glow strength, as upstream. The gap's edge
// softness stays hardcoded — upstream has no prop for it.
//
// lerp-param: color1        color       = (0.173, 0.227, 0.388, 1.0) "Slate indigo"
// lerp-param: color2        color       = (0.090, 0.341, 0.361, 1.0) "Deep teal"
// lerp-param: color3        color       = (0.325, 0.227, 0.471, 1.0) "Rich violet"
// lerp-param: color4        color       = (0.071, 0.137, 0.239, 1.0) "Midnight blue"
// lerp-param: colorGlow     color       = (0.012, 0.018, 0.038, 0.60) "Glow"
// lerp-param: colorGap      color       = (0.016, 0.022, 0.042) "Gap"
// lerp-param: scale         float 0.1 20 = 2.2 "Scale"
// lerp-param: stepsPerColor int 1 3     = 2    "Steps per colour"
// lerp-param: distortion    float 0 0.5 = 0.45 "Distortion"
// lerp-param: gap           float 0 0.1 = 0.04 "Gap"
// lerp-param: glow          float 0 1   = 0.6  "Glow"
// lerp-param: speed         float 0 1   = 0.2  "Speed"
//
// Upstream presets, scale mapped into this port's units and speed scaled to
// this port's ambience (upstream × 0.4).
// lerp-preset: Lights  color1=#fffffffc, color2=#bbff00, color3=#00ffff, color4=#fffffffc
// lerp-preset: Lights  colorGlow=#ff00d0, colorGap=#ff00d0, stepsPerColor=2
// lerp-preset: Lights  distortion=0.38, gap=0, glow=1, scale=14.5, speed=0.2
// lerp-preset: Cells   color1=#ffffff, color2=#ffffff, color3=#ffffff, color4=#ffffff
// lerp-preset: Cells   colorGlow=#ffffff, colorGap=#000000, stepsPerColor=1
// lerp-preset: Cells   distortion=0.5, gap=0.03, glow=0.8, scale=2.2, speed=0.2
// lerp-preset: Bubbles color1=#83c9fb, color2=#83c9fb, color3=#83c9fb, color4=#83c9fb
// lerp-preset: Bubbles colorGlow=#ffffff, colorGap=#ffffff, stepsPerColor=1
// lerp-preset: Bubbles distortion=0.4, gap=0, glow=1, scale=3.3, speed=0.2

constant int   VN_COLOR_COUNT = 4;
constant float VN_EDGE_SMOOTH = 0.02;

// Returns (border distance, offset to cell center, cell hash).
static float4 vnVoronoi(float2 x, float t, float distortion) {
    float2 ip = floor(x);
    float2 fp = fract(x);

    float2 mg = float2(0.0), mr = float2(0.0);
    float md = 8.0;
    float rand = 0.0;

    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(float(i), float(j));
            float2 o = hash22(ip + g);
            float rawHash = o.x;
            o = 0.5 + distortion * sin(t + TWO_PI * o);
            float2 r = g + o - fp;
            float d = dot(r, r);
            if (d < md) {
                md = d;
                mr = r;
                mg = g;
                rand = rawHash;
            }
        }
    }

    md = 8.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float2 g = mg + float2(float(i), float(j));
            float2 o = hash22(ip + g);
            o = 0.5 + distortion * sin(t + TWO_PI * o);
            float2 r = g + o - fp;
            if (dot(mr - r, mr - r) > 0.00001) {
                md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
            }
        }
    }

    return float4(md, mr, rand);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[VN_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4 };

    float2 shapeUV = lerpUV(pos, u.resolution) * u.scale;
    shapeUV *= 1.25;
    shapeUV += u.seed * 57.0; // per-launch pattern offset

    float t = u.speed * u.time + u.seed * 31.0;

    float4 res = vnVoronoi(shapeUV, t, u.distortion);

    // Quantized gradient across the baked colors, keyed by the cell hash.
    float shape = clamp(res.w, 0.0, 1.0);
    float count = float(VN_COLOR_COUNT);
    float mixer = (shape - 0.5 / count) * count;
    float steps = max(1.0, float(u.stepsPerColor));

    float4 gradient = colors[0];
    for (int i = 1; i < VN_COLOR_COUNT; i++) {
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = round(localT * steps) / steps;
        gradient = mix(gradient, colors[i], localT);
    }
    if ((mixer < 0.0) || (mixer > (count - 1.0))) {
        float localT = mixer + 1.0;
        if (mixer > (count - 1.0)) {
            localT = mixer - (count - 1.0);
        }
        localT = round(localT * steps) / steps;
        gradient = mix(colors[VN_COLOR_COUNT - 1], colors[0], localT);
    }

    // Radial rim glow inside each cell (grows toward the cell edge).
    float glows = length(res.yz * u.glow);
    glows = pow(glows, 1.5);
    float3 color = mix(gradient.rgb, u.colorGlow.rgb, u.colorGlow.a * glows);

    // Anti-aliased gap between cells.
    float edge = smoothstep(u.gap - VN_EDGE_SMOOTH, u.gap + VN_EDGE_SMOOTH, res.x);
    color = mix(u.colorGap.rgb, color, edge);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
