// Swirl — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders

constant int    SW_COLOR_COUNT = 4;
constant float4 SW_COLORS[SW_COLOR_COUNT] = {
    float4(0.043, 0.153, 0.200, 1.0), // deep petrol
    float4(0.078, 0.349, 0.369, 1.0), // dark teal
    float4(0.196, 0.522, 0.463, 1.0), // sea green
    float4(0.871, 0.945, 0.914, 1.0), // pale seafoam
};
constant float3 SW_BACKGROUND = float3(0.012, 0.024, 0.043); // near-black navy

constant float SW_BAND_COUNT = 4.0;
constant float SW_TWIST      = 0.25;
constant float SW_CENTER     = 0.3;
constant float SW_PROPORTION = 0.5;
constant float SW_SOFTNESS   = 0.55;
constant float SW_NOISE      = 0.15;
constant float SW_NOISE_FREQ = 0.4;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Matches the original's v_objectUV range ([-0.5, 0.5] on the short axis).
    float2 shapeUV = lerpUV(pos, u.resolution) * 0.5;

    float l = max(1e-4, length(shapeUV));

    float t = 0.15 * u.time + 40.0 * u.seed;

    float angle = ceil(SW_BAND_COUNT) * atan2(shapeUV.y, shapeUV.x) + t;
    float angleNorm = angle / TWO_PI;

    float twist = 3.0 * clamp(SW_TWIST, 0.0, 1.0);
    float offset = pow(l, -twist) + angleNorm;

    float shape = fract(offset);
    shape = 1.0 - abs(2.0 * shape - 1.0);
    shape += SW_NOISE * snoise(15.0 * SW_NOISE_FREQ * SW_NOISE_FREQ * shapeUV);

    float mid = smoothstep(0.2, 0.2 + 0.8 * SW_CENTER, pow(l, twist));
    shape = mix(0.0, shape, mid);

    // max() guards pow() against the small negative dips the noise can add.
    float proportion = clamp(SW_PROPORTION, 0.0, 1.0);
    float exponent = mix(0.25, 1.0, proportion * 2.0);
    exponent = mix(exponent, 10.0, max(0.0, proportion * 2.0 - 1.0));
    shape = pow(max(shape, 0.0), exponent);

    float mixer = shape * float(SW_COLOR_COUNT);
    float4 gradient = SW_COLORS[0];

    float outerShape = 0.0;
    for (int i = 1; i <= SW_COLOR_COUNT; i++) {
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float aa = fwidth(m);
        m = smoothstep(0.5 - 0.5 * SW_SOFTNESS - aa, 0.5 + 0.5 * SW_SOFTNESS + aa, m);
        if (i == 1) {
            outerShape = m;
        }
        gradient = mix(gradient, SW_COLORS[i - 1], m);
    }

    float midAA = max(0.1 * fwidth(pow(l, -twist)), 1e-4);
    float outerMid = smoothstep(0.2, 0.2 + midAA, pow(l, twist));
    outerShape = mix(0.0, outerShape, outerMid);

    float3 color = gradient.rgb * outerShape;
    float opacity = gradient.a * outerShape;
    color += SW_BACKGROUND * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
