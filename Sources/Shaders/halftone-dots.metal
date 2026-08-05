// Halftone Dots — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Upstream reproduces an input image as a grid of dots whose radius tracks
// local luminance. A screensaver has no image, so the sampler is replaced
// with a slow inverse-distance colour field; the halftone itself — the cell
// lattice, the sigmoid contrast on the sampled luminance, the 2x2
// supersampled sublattices, the "original colours" ink and the two grain
// layers — is the upstream algorithm ("classic" dot type, square grid).

constant int HD_SOURCE_COUNT = 5;
constant float3 HD_SOURCE_COLORS[HD_SOURCE_COUNT] = {
    float3(0.192, 0.325, 0.914), // electric blue
    float3(0.157, 0.796, 0.808), // aqua
    float3(0.913, 0.247, 0.529), // hot pink
    float3(0.988, 0.643, 0.216), // amber
    float3(0.522, 0.271, 0.898), // violet
};
constant float3 HD_COLOR_BACK = float3(0.016, 0.018, 0.035); // near-black

constant float HD_SIZE         = 0.76; // -> ~30 cells on the short axis
constant float HD_RADIUS       = 1.00;
constant float HD_CONTRAST     = 0.95;
constant float HD_GRAIN_MIXER  = 0.22;
constant float HD_GRAIN_OVERLAY = 0.30;
constant float HD_GRAIN_SIZE   = 0.55;

// Stand-in for u_image: a handful of coloured spots drifting on their own
// orbits, blended by inverse distance. Smooth enough that the dot radii
// change gradually from cell to cell, which is what makes a halftone read.
static float4 hdSource(float2 uv, float t, float aspect) {
    float3 color = float3(0.0);
    float total = 0.0;
    for (int i = 0; i < HD_SOURCE_COUNT; i++) {
        float a = float(i) * 1.61;
        float2 p = 0.5 + 0.44 * float2(sin(t * (0.31 + 0.07 * float(i)) + a),
                                       cos(t * (0.24 + 0.06 * float(i)) + a * 1.27));
        float d = length((uv - p) * float2(aspect, 1.0));
        float w = 1.0 / (pow(d, 2.4) + 4e-3);
        color += HD_SOURCE_COLORS[i] * w;
        total += w;
    }
    color /= max(total, 1e-4);

    // A big soft vignette-free falloff gives the field light and dark regions
    // so the dot sizes actually vary instead of sitting at one radius.
    float shade = 0.5 + 0.5 * sin(TWO_PI * (0.7 * uv.x + 0.5 * uv.y) + 0.6 * t);
    shade = mix(0.25, 1.0, shade);
    return float4(color * shade, 1.0);
}

static float hdSigmoid(float x, float k) { return 1.0 / (1.0 + exp(-k * (x - 0.5))); }

static float hdLuminance(float4 tex, float contrast) {
    float3 c = float3(hdSigmoid(tex.r, contrast),
                      hdSigmoid(tex.g, contrast),
                      hdSigmoid(tex.b, contrast));
    return dot(float3(0.2126, 0.7152, 0.0722), c);
}

// Dark cells get a big dot, bright cells shrink to nothing.
static float hdCircle(float2 uv, float r, float baseR) {
    r = mix(0.25 * baseR, 0.0, r);
    float d = length(uv - 0.5);
    float aa = fwidth(d);
    return 1.0 - smoothstep(r - aa, r + aa, d);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float2 imageUV = float2(pos.x, u.resolution.y - pos.y) / u.resolution;

    float t = 0.30 * u.time + 55.0 * u.seed;

    // "classic" runs at half the cell count and supersamples 2x2, which is
    // what interleaves the sublattices back to full density.
    const float stepMultiplier = 2.0;
    const float stepSize = 1.0 / stepMultiplier;
    float cellsPerSide = mix(300.0, 7.0, pow(HD_SIZE, 0.7)) / stepMultiplier;
    float2 pad = (1.0 / cellsPerSide) * float2(1.0 / aspect, 1.0);

    float2 uv = (imageUV - 0.5) / pad;

    // u_originalColors = true: softer contrast, fatter base radius.
    float contrast = mix(0.1, 4.0, pow(HD_CONTRAST, 2.0));
    float baseRadius = 2.0 * pow(0.5 * HD_RADIUS, 0.3);

    float totalShape = 0.0;
    float3 totalColor = float3(0.0);

    for (int xi = 0; xi < 2; xi++) {
        for (int yi = 0; yi < 2; yi++) {
            float2 offset = float2(-0.5 + float(xi) * stepSize,
                                   -0.5 + float(yi) * stepSize);

            float2 p = uv + offset;
            float2 cell = floor(p);
            float2 inCell = fract(p);

            // Sample the source once at the cell centre, as upstream does.
            float2 samplingUV = (cell + 0.5 - offset) * pad + 0.5;
            float4 tex = hdSource(samplingUV, t, aspect);
            float lum = hdLuminance(tex, contrast);

            float shape = hdCircle(inCell, lum, baseRadius);
            totalColor += tex.rgb * shape;
            totalShape += shape;
        }
    }

    totalColor /= max(totalShape, 1e-4);
    float finalShape = min(1.0, totalShape);

    float2 grainUV = (imageUV - 0.5) * mix(2000.0, 200.0, HD_GRAIN_SIZE)
                     * float2(1.0, 1.0 / aspect) + 0.5;
    float grain = valueNoise(grainUV);
    grain = smoothstep(0.55, 0.7 + 0.2 * HD_GRAIN_MIXER, grain) * HD_GRAIN_MIXER;
    finalShape = mix(finalShape, 0.0, grain);

    // Ink is premultiplied by the dot coverage; the background fills the rest.
    float3 color = totalColor * finalShape + HD_COLOR_BACK * (1.0 - finalShape);

    float grainOverlay = valueNoise(rotate(grainUV, 1.0) + 3.0);
    grainOverlay = mix(grainOverlay, valueNoise(rotate(grainUV, 2.0) - 1.0), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);

    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = pow(HD_GRAIN_OVERLAY * abs(grainOverlayV), 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);

    color = clamp(color, 0.0, 1.0);
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
