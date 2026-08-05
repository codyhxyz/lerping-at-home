// Voronoi — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Double-pass Voronoi borders after https://www.shadertoy.com/view/ldl3W8
// (Inigo Quilez, MIT). The original's noise-texture randomizer is replaced
// with the prelude's procedural hash22. Recolored from the orange/yellow
// demo default to a dark stained-glass palette with shaded cell rims.

constant int    VN_COLOR_COUNT = 4;
constant float4 VN_COLORS[VN_COLOR_COUNT] = {
    float4(0.173, 0.227, 0.388, 1.0), // slate indigo
    float4(0.090, 0.341, 0.361, 1.0), // deep teal
    float4(0.325, 0.227, 0.471, 1.0), // rich violet
    float4(0.071, 0.137, 0.239, 1.0), // midnight blue
};
constant float  VN_STEPS_PER_COLOR = 2.0;
constant float4 VN_COLOR_GLOW = float4(0.012, 0.018, 0.038, 0.60); // inner shadow
constant float3 VN_COLOR_GAP  = float3(0.016, 0.022, 0.042);       // near-black
constant float  VN_DISTORTION  = 0.45;
constant float  VN_GAP         = 0.04;
constant float  VN_GLOW        = 0.6;
constant float  VN_EDGE_SMOOTH = 0.02;
constant float  VN_SCALE       = 2.2;

// Returns (border distance, offset to cell center, cell hash).
static float4 vnVoronoi(float2 x, float t) {
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
            o = 0.5 + VN_DISTORTION * sin(t + TWO_PI * o);
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
            o = 0.5 + VN_DISTORTION * sin(t + TWO_PI * o);
            float2 r = g + o - fp;
            if (dot(mr - r, mr - r) > 0.00001) {
                md = min(md, dot(0.5 * (mr + r), normalize(r - mr)));
            }
        }
    }

    return float4(md, mr, rand);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 shapeUV = lerpUV(pos, u.resolution) * VN_SCALE;
    shapeUV *= 1.25;
    shapeUV += u.seed * 57.0; // per-launch pattern offset

    float t = 0.2 * u.time + u.seed * 31.0;

    float4 res = vnVoronoi(shapeUV, t);

    // Quantized gradient across the baked colors, keyed by the cell hash.
    float shape = clamp(res.w, 0.0, 1.0);
    float count = float(VN_COLOR_COUNT);
    float mixer = (shape - 0.5 / count) * count;
    float steps = max(1.0, VN_STEPS_PER_COLOR);

    float4 gradient = VN_COLORS[0];
    for (int i = 1; i < VN_COLOR_COUNT; i++) {
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = round(localT * steps) / steps;
        gradient = mix(gradient, VN_COLORS[i], localT);
    }
    if ((mixer < 0.0) || (mixer > (count - 1.0))) {
        float localT = mixer + 1.0;
        if (mixer > (count - 1.0)) {
            localT = mixer - (count - 1.0);
        }
        localT = round(localT * steps) / steps;
        gradient = mix(VN_COLORS[VN_COLOR_COUNT - 1], VN_COLORS[0], localT);
    }

    // Radial rim glow inside each cell (grows toward the cell edge).
    float glows = length(res.yz * VN_GLOW);
    glows = pow(glows, 1.5);
    float3 color = mix(gradient.rgb, VN_COLOR_GLOW.rgb, VN_COLOR_GLOW.a * glows);

    // Anti-aliased gap between cells.
    float edge = smoothstep(VN_GAP - VN_EDGE_SMOOTH, VN_GAP + VN_EDGE_SMOOTH, res.x);
    color = mix(VN_COLOR_GAP, color, edge);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
