// Waves — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original is a static line pattern. For screensaver duty this port
// scrolls the band field and slowly morphs the wave between the upstream
// zigzag / sine / irregular shapes.
//
// Scrolling alone read as "completely still" on the lock screen: the pattern
// slid as one rigid piece, which gives the eye nothing to compare against.
// What keeps it moving now is the wave's own shape:
// - its phase wanders by a modulation travelling along the wave, so crests
//   bunch, spread and move at different speeds in different places;
// - an envelope travelling the other way lifts and flattens the crests;
// - a second, shorter wave train runs against the first and interferes;
// - a long swell, in screen units, bends the bands, so a dense preset
//   ("Groovy", scale 25, whose wave is tiny on screen) moves as much as a
//   sparse one.
// Height enters the wave's phase only weakly: |d offset / dy| stays well
// under 1, so neighbouring bands stay parallel instead of folding into each
// other where the wave is steep. Local change is now about 0.7-2%/s.
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
    // Screen units: the short side spans 2, whatever the aspect.
    float2 uv = lerpUV(pos, u.resolution);
    // ~= the original's v_patternUV * 4.
    float2 shapeUV = uv * u.scale;

    float t = u.speed * u.time + 60.0 * u.seed;

    // Ambience the original doesn't have: the bands drift while the wave
    // shape eases through the four upstream profiles.
    shapeUV.y += 0.30 * t;
    shapeUV.x += 0.45 * sin(0.19 * t);
    float shapeMix = u.shape + 1.5 * sin(0.07 * t);

    // Swell, in screen units so a dense preset moves as much on screen as a
    // sparse one: two long, gentle waves crossing the bands, travelling at
    // different speeds and directions. Their sum never pauses everywhere at
    // once, so the bands keep bending against each other.
    float swell = 0.040 * sin(dot(uv, float2(1.7, 0.6)) - 2.6 * t)
                + 0.028 * sin(dot(uv, float2(-0.9, 1.5)) + 1.9 * t + 1.3);
    shapeUV.y += swell * u.scale;

    float f = u.frequency;
    // The wave itself evolves. Its phase wanders, by a modulation that
    // travels along the wave and varies with height, so crests bunch,
    // spread and travel at different speeds in different places; an
    // envelope travelling the other way lifts and flattens them.
    float phase = shapeUV.x * f
                + 0.22 * sin(TWO_PI * 0.27 * f * shapeUV.x + 0.35 * uv.y - 1.3 * t)
                + 0.18 * sin(0.25 * uv.y - 0.6 * uv.x + 0.8 * t);
    float envelope = 0.62 + 0.38 * sin(1.3 * uv.x - 0.8 * uv.y + 1.0 * t + 0.7);

    float wave       = 0.5 * cos(phase * TWO_PI);
    float zigzag     = 2.0 * abs(fract(phase) - 0.5);
    float irregular  = sin(phase * 0.25 * TWO_PI) * cos(phase * TWO_PI);
    float irregular2 = 0.75 * (sin(phase * TWO_PI) + 0.5 * cos(phase * 0.5 * TWO_PI));

    float offset = mix(zigzag, wave, smoothstep(0.0, 1.0, shapeMix));
    offset = mix(offset, irregular, smoothstep(1.0, 2.0, shapeMix));
    offset = mix(offset, irregular2, smoothstep(2.0, 3.0, shapeMix));
    // A second, shorter wave train running against the first, so the two
    // interfere and the profile keeps changing shape rather than sliding.
    offset = offset * envelope
           + 0.24 * sin(TWO_PI * 1.53 * f * shapeUV.x + 1.7 * t + 1.1 * uv.y);
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
