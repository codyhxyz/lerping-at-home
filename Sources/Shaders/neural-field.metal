// Neural Field — a CPPN (compositional pattern-producing network) run per pixel
// on Metal 4 shader ML. Original to Lerping@Home.
//
// Every pixel feeds its position and a slowly orbiting latent vector through a
// tiny MLP (16 → 16 sin → 16 tanh → 4) whose half-precision weights live in an
// MTLTensor. The three matrix multiplies are Metal Performance Primitives
// `matmul2d` ops on single-thread scope, the one fragment shaders support;
// activations stay float, because the satin lighting differentiates the output
// in screen space and half-precision steps show up as grain. The four outputs
// are read as a palette coordinate, a height field (lit as satin), contour
// lines and luminous veins along a zero set. `u.seed` picks one of eight weight
// banks and a point on the latent orbit, so every activation is a different
// network. See Sources/LerpCore/NeuralFieldData.swift for the weights.
//
// lerp-category: Simulations
// lerp-data: neural-field
// lerp-requires: metal4
//
// lerp-param: speed      float 0 2     = 0.5  "Speed"
// lerp-param: detail     float 0.3 4   = 2.0  "Detail"
// lerp-param: contours   float 0 1     = 0.3  "Contours"
// lerp-param: sheen      float 0 1     = 0.55 "Sheen"
// lerp-param: veins      float 0 1     = 0.6  "Veins"
// lerp-param: colorDeep  color         = (0.012, 0.016, 0.040) "Deep"
// lerp-param: colorMid   color         = (0.055, 0.180, 0.235) "Mid"
// lerp-param: colorHigh  color         = (0.740, 0.530, 0.345) "High"
// lerp-param: colorGlow  color         = (0.930, 0.420, 0.470) "Glow"
//
// lerp-preset: Ember   detail=1.4, colorDeep=(0.020, 0.008, 0.010), colorMid=(0.240, 0.050, 0.040), colorHigh=(0.980, 0.620, 0.260), colorGlow=(1.000, 0.850, 0.550), contours=0.15
// lerp-preset: Lichen  detail=1.2, sheen=0.75, contours=0.5, colorDeep=(0.010, 0.020, 0.015), colorMid=(0.120, 0.200, 0.120), colorHigh=(0.700, 0.760, 0.520), colorGlow=(0.420, 0.780, 0.700)

using namespace mpp::tensor_ops;

// Inputs to the network. Spatial terms are scaled by `detail`; the latent
// orbit (six incommensurate sines) is what makes the picture breathe.
// `NeuralFieldData.calibrate` probes the network with a copy of these at the
// default detail; keep the two in step.
static void nfInputs(float2 q, float t, float detail, thread float* x) {
    float z0 = sin(t * 0.91), z1 = sin(t * 1.27 + 1.3), z2 = sin(t * 0.67 + 2.1);
    float z3 = sin(t * 1.13 + 4.0), z4 = sin(t * 0.53 + 0.7), z5 = sin(t * 1.61 + 5.2);
    float2 s = q * detail;
    float r = length(s);
    x[0]  = s.x;
    x[1]  = s.y;
    x[2]  = r - 0.8;
    x[3]  = sin(1.7 * s.x + z0);
    x[4]  = cos(1.9 * s.y + z1);
    x[5]  = sin(1.3 * (s.x + s.y) + z2);
    x[6]  = z0;
    x[7]  = z1;
    x[8]  = z2;
    x[9]  = z3;
    x[10] = z4;
    x[11] = z5;
    x[12] = s.x * z3;
    x[13] = s.y * z4;
    x[14] = r * z5;
    x[15] = 1.0;                       // bias
}

static float3 nfPalette(float s, constant LerpUniforms& u) {
    float3 c = mix(u.colorDeep.rgb, u.colorMid.rgb, smoothstep(0.18, 0.5, s));
    return mix(c, u.colorHigh.rgb, smoothstep(0.6, 0.88, s));
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpNeuralFieldArgs& nf [[buffer(1)]]) {
    float2 p = lerpUV(pos, u.resolution);
    float t = u.time * 0.12 * u.speed + u.seed * 157.0;
    int bank = min(int(u.seed * float(NF_BANKS)), NF_BANKS - 1);
    int row = bank * NF_ROWS_PER_BANK;

    // A slow drift of the whole field, so even its static structure travels.
    float2 q = rotate(p, 0.05 * t) + 0.25 * float2(sin(0.21 * t), cos(0.17 * t));

    float x[16], h0[16], h1[16], y[4];
    nfInputs(q, t, u.detail, x);

    auto W = nf.weights;
    auto W0 = W.template slice<16, 16>(0, row);
    auto W1 = W.template slice<16, 16>(0, row + 16);
    auto W2 = W.template slice<4, 16>(0, row + 32);
    auto X  = tensor<thread float, extents<int, 16, 1>, tensor_inline>(x,  extents<int, 16, 1>());
    auto H0 = tensor<thread float, extents<int, 16, 1>, tensor_inline>(h0, extents<int, 16, 1>());
    auto H1 = tensor<thread float, extents<int, 16, 1>, tensor_inline>(h1, extents<int, 16, 1>());
    auto Y  = tensor<thread float, extents<int, 4, 1>, tensor_inline>(y,  extents<int, 4, 1>());

    matmul2d<matmul2d_descriptor(1, 16, 16), execution_thread> hidden;
    matmul2d<matmul2d_descriptor(1, 4, 16), execution_thread> head;

    hidden.run(X, W0, H0);
    for (int i = 0; i < 15; ++i) h0[i] = sin(h0[i]);
    h0[15] = 1.0;
    hidden.run(H0, W1, H1);
    for (int i = 0; i < 15; ++i) h1[i] = tanh(h1[i]);
    h1[15] = 1.0;
    head.run(H1, W2, Y);

    float s = 0.5 + 0.5 * sin(1.6 * y[0] + 0.8 * y[1]);
    float h = tanh(y[1]);
    float c = y[2];

    // Satin: light the height field through its screen-space gradient.
    float uvPerPixel = 2.0 / min(u.resolution.x, u.resolution.y);
    float2 grad = float2(dfdx(h), -dfdy(h)) / uvPerPixel;
    float3 n = normalize(float3(-0.6 * grad / u.detail, 1.0));
    float3 L = normalize(float3(-0.45, 0.55, 0.70));
    float diffuse = 0.55 + 0.45 * dot(n, L);
    float spec = pow(max(dot(reflect(-L, n), float3(0, 0, 1)), 0.0), 18.0);

    float tone = pow(s, 2.0);
    float3 color = nfPalette(tone, u) * diffuse;
    color += u.sheen * 0.4 * spec * smoothstep(0.2, 0.7, tone) * mix(u.colorHigh.rgb, float3(1.0), 0.4);

    // Veins: the zero set of the fourth output, a hairline core in a soft halo.
    float v = y[3];
    float core = exp(-abs(v) / (1.5 * fwidth(v) + 1e-4));
    float halo = exp(-6.0 * abs(v));
    color += u.veins * u.colorGlow.rgb * (0.55 * core + 0.18 * halo);

    // Topographic lines on the third output, anti-aliased by its own fwidth.
    float bands = 5.0 * c;
    float w = abs(fract(bands - 0.5) - 0.5) / max(fwidth(bands), 1e-4);
    color += u.contours * 0.26 * (1.0 - smoothstep(0.0, 1.4, w)) * mix(u.colorHigh.rgb, float3(1.0), 0.5);

    color = lerpDither(color, pos);
    return half4(half3(saturate(color)), 1.0h);
}
