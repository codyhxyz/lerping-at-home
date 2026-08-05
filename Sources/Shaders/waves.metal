// Waves — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original is a static line pattern. For screensaver duty this port
// scrolls the band field and slowly morphs the wave between the upstream
// zigzag / sine / irregular shapes, so it drifts instead of sitting still.
//
// Parameters mirror the upstream <Waves> props. `shape` keeps upstream's
// meaning (0 zigzag, 1 sine, 2/3 irregular) but is the *centre* of this port's
// slow sweep rather than a fixed value. `speed` is this port's own addition:
// upstream Waves has no speed prop because it does not animate. `scale` is in
// this port's units, not upstream's sizing system.
//
// lerp-param: colorBack  color        = (0.024, 0.035, 0.071) "Background"
// lerp-param: colorFront color        = (0.184, 0.596, 0.588) "Front"
// lerp-param: scale      float 0.25 30 = 3.0  "Scale"
// lerp-param: shape      float 0 3    = 1.5   "Shape"
// lerp-param: frequency  float 0 2    = 0.42  "Frequency"
// lerp-param: amplitude  float 0 1    = 0.60  "Amplitude"
// lerp-param: spacing    float 0 2    = 0.85  "Spacing"
// lerp-param: proportion float 0 1    = 0.34  "Proportion"
// lerp-param: softness   float 0 1    = 0.34  "Softness"
// lerp-param: speed      float 0 2    = 0.15  "Speed"
//
// Upstream presets; scale mapped into this port's units, speed left at the
// port default since upstream has none.
// lerp-preset: Groovy       colorFront=#fcfcee, colorBack=#ff896b, scale=25
// lerp-preset: Groovy       shape=3, frequency=0.2, amplitude=0.25, spacing=1.17
// lerp-preset: Groovy       proportion=0.57, softness=0
// lerp-preset: "Tangled up" colorFront=#133a41, colorBack=#c2d8b6, scale=2.5
// lerp-preset: "Tangled up" shape=2.07, frequency=0.44, amplitude=0.57, spacing=1.05
// lerp-preset: "Tangled up" proportion=0.75, softness=0
// lerp-preset: "Ride the wave" colorFront=#fdffe6, colorBack=#1f1f1f, scale=8.5
// lerp-preset: "Ride the wave" shape=2.25, frequency=0.2, amplitude=1, spacing=1.25
// lerp-preset: "Ride the wave" proportion=1, softness=0

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // ~= the original's v_patternUV * 4.
    float2 shapeUV = lerpUV(pos, u.resolution) * u.scale;

    float t = u.speed * u.time + 60.0 * u.seed;

    // Ambience the original doesn't have: the bands drift while the wave
    // shape eases through the four upstream profiles.
    shapeUV.y += 0.30 * t;
    shapeUV.x += 0.45 * sin(0.19 * t);
    float shapeMix = u.shape + 1.5 * sin(0.07 * t);

    float f = u.frequency;
    float wave       = 0.5 * cos(shapeUV.x * f * TWO_PI);
    float zigzag     = 2.0 * abs(fract(shapeUV.x * f) - 0.5);
    float irregular  = sin(shapeUV.x * 0.25 * f * TWO_PI) * cos(shapeUV.x * f * TWO_PI);
    float irregular2 = 0.75 * (sin(shapeUV.x * f * TWO_PI) +
                               0.5 * cos(shapeUV.x * 0.5 * f * TWO_PI));

    float offset = mix(zigzag, wave, smoothstep(0.0, 1.0, shapeMix));
    offset = mix(offset, irregular, smoothstep(1.0, 2.0, shapeMix));
    offset = mix(offset, irregular2, smoothstep(2.0, 3.0, shapeMix));
    offset *= 2.0 * u.amplitude;

    float spacing = 0.001 + u.spacing;
    float shape = 0.5 + 0.5 * sin((shapeUV.y + offset) * PI / spacing);

    float aa = 0.0001 + fwidth(shape);
    float dc = 1.0 - clamp(u.proportion, 0.0, 1.0);
    float e0 = dc - u.softness - aa;
    float e1 = dc + u.softness + aa;
    float res = smoothstep(min(e0, e1), max(e0, e1), shape);

    float3 color = mix(u.colorBack.rgb, u.colorFront.rgb, res);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
