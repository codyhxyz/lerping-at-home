// Waves — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original is a static line pattern. For screensaver duty this port
// scrolls the band field and slowly morphs the wave between the upstream
// zigzag / sine / irregular shapes, so it drifts instead of sitting still.

constant float3 WV_COLOR_FRONT = float3(0.184, 0.596, 0.588); // muted teal
constant float3 WV_COLOR_BACK  = float3(0.024, 0.035, 0.071); // near-black indigo

constant float WV_FREQUENCY  = 0.42;
constant float WV_AMPLITUDE  = 0.60;
constant float WV_SPACING    = 0.85;
constant float WV_PROPORTION = 0.34;
constant float WV_SOFTNESS   = 0.34;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // ~= the original's v_patternUV * 4.
    float2 shapeUV = lerpUV(pos, u.resolution) * 3.0;

    float t = 0.15 * u.time + 60.0 * u.seed;

    // Ambience the original doesn't have: the bands drift while the wave
    // shape eases through the four upstream profiles.
    shapeUV.y += 0.30 * t;
    shapeUV.x += 0.45 * sin(0.19 * t);
    float shapeMix = 1.5 + 1.5 * sin(0.07 * t);

    float f = WV_FREQUENCY;
    float wave       = 0.5 * cos(shapeUV.x * f * TWO_PI);
    float zigzag     = 2.0 * abs(fract(shapeUV.x * f) - 0.5);
    float irregular  = sin(shapeUV.x * 0.25 * f * TWO_PI) * cos(shapeUV.x * f * TWO_PI);
    float irregular2 = 0.75 * (sin(shapeUV.x * f * TWO_PI) +
                               0.5 * cos(shapeUV.x * 0.5 * f * TWO_PI));

    float offset = mix(zigzag, wave, smoothstep(0.0, 1.0, shapeMix));
    offset = mix(offset, irregular, smoothstep(1.0, 2.0, shapeMix));
    offset = mix(offset, irregular2, smoothstep(2.0, 3.0, shapeMix));
    offset *= 2.0 * WV_AMPLITUDE;

    float spacing = 0.001 + WV_SPACING;
    float shape = 0.5 + 0.5 * sin((shapeUV.y + offset) * PI / spacing);

    float aa = 0.0001 + fwidth(shape);
    float dc = 1.0 - clamp(WV_PROPORTION, 0.0, 1.0);
    float e0 = dc - WV_SOFTNESS - aa;
    float e1 = dc + WV_SOFTNESS + aa;
    float res = smoothstep(min(e0, e1), max(e0, e1), shape);

    float3 color = mix(WV_COLOR_BACK, WV_COLOR_FRONT, res);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
