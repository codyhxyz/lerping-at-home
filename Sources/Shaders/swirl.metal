// Swirl — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
//
// Parameters mirror the upstream <Swirl> props. Upstream takes a
// variable-length `colors` array (max 10); this port fixes four tunable slots.
//
// lerp-param: color1         color     = (0.043, 0.153, 0.200) "Deep petrol"
// lerp-param: color2         color     = (0.078, 0.349, 0.369) "Dark teal"
// lerp-param: color3         color     = (0.196, 0.522, 0.463) "Sea green"
// lerp-param: color4         color     = (0.871, 0.945, 0.914) "Pale seafoam"
// lerp-param: colorBack      color     = (0.012, 0.024, 0.043) "Background"
// lerp-param: bandCount      int 0 15  = 4     "Band count"
// lerp-param: twist          float 0 1 = 0.25  "Twist"
// lerp-param: center         float 0 1 = 0.3   "Center"
// lerp-param: proportion     float 0 1 = 0.5   "Proportion"
// lerp-param: softness       float 0 1 = 0.55  "Softness"
// lerp-param: noise          float 0 1 = 0.15  "Noise"
// lerp-param: noiseFrequency float 0 1 = 0.4   "Noise frequency"
// lerp-param: speed          float 0 2 = 0.15  "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 0.15).
// lerp-preset: 007     colorBack=#e9e7da, color1=#000000, color2=#000000, color3=#000000
// lerp-preset: 007     color4=#000000, bandCount=5, twist=0.3, center=0, proportion=0
// lerp-preset: 007     softness=0, noiseFrequency=0.5, noise=0, speed=0.15
// lerp-preset: Opening colorBack=#ff8b61, color1=#fefff0, color2=#ffd8bd, color3=#ff8b61
// lerp-preset: Opening color4=#fefff0, bandCount=2, twist=0.3, center=0.2, proportion=0.5
// lerp-preset: Opening softness=0, noiseFrequency=0, noise=0, speed=0.075
// lerp-preset: Candy   colorBack=#ffcd66, color1=#6bbceb, color2=#d7b3ff, color3=#ff9fff
// lerp-preset: Candy   color4=#6bbceb, bandCount=2, twist=0.15, center=0.2, proportion=0.5
// lerp-preset: Candy   softness=1, noiseFrequency=0.5, noise=0, speed=0.15

constant int SW_COLOR_COUNT = 4;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[SW_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4 };

    // Matches the original's v_objectUV range ([-0.5, 0.5] on the short axis).
    float2 shapeUV = lerpUV(pos, u.resolution) * 0.5;

    float l = max(1e-4, length(shapeUV));

    float t = u.speed * u.time + 40.0 * u.seed;

    float angle = float(u.bandCount) * atan2(shapeUV.y, shapeUV.x) + t;
    float angleNorm = angle / TWO_PI;

    float twist = 3.0 * clamp(u.twist, 0.0, 1.0);
    float offset = pow(l, -twist) + angleNorm;

    float shape = fract(offset);
    shape = 1.0 - abs(2.0 * shape - 1.0);
    shape += u.noise * snoise(15.0 * u.noiseFrequency * u.noiseFrequency * shapeUV);

    float mid = smoothstep(0.2, 0.2 + 0.8 * u.center, pow(l, twist));
    shape = mix(0.0, shape, mid);

    // max() guards pow() against the small negative dips the noise can add.
    float proportion = clamp(u.proportion, 0.0, 1.0);
    float exponent = mix(0.25, 1.0, proportion * 2.0);
    exponent = mix(exponent, 10.0, max(0.0, proportion * 2.0 - 1.0));
    shape = pow(max(shape, 0.0), exponent);

    float mixer = shape * float(SW_COLOR_COUNT);
    float4 gradient = colors[0];

    float outerShape = 0.0;
    for (int i = 1; i <= SW_COLOR_COUNT; i++) {
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float aa = fwidth(m);
        m = smoothstep(0.5 - 0.5 * u.softness - aa, 0.5 + 0.5 * u.softness + aa, m);
        if (i == 1) {
            outerShape = m;
        }
        gradient = mix(gradient, colors[i - 1], m);
    }

    float midAA = max(0.1 * fwidth(pow(l, -twist)), 1e-4);
    float outerMid = smoothstep(0.2, 0.2 + midAA, pow(l, twist));
    outerShape = mix(0.0, outerShape, outerMid);

    float3 color = gradient.rgb * outerShape;
    float opacity = gradient.a * outerShape;
    color += u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
