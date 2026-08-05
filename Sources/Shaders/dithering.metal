// Dithering — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Two-colour ordered dithering over a drifting simplex field: the upstream
// "simplex" shape with the 8x8 Bayer matrix, which is the combination that
// reads best full-screen.
//
// Parameters mirror the upstream <Dithering> props. Upstream's `shape` and
// `type` enums are not ported — this file is always simplex + 8x8 Bayer.
// `scale` is in this port's units, not upstream's sizing system; `size` is the
// dither cell in pixels, as upstream.
//
// lerp-param: colorBack  color        = (0.031, 0.035, 0.063) "Background"
// lerp-param: colorFront color        = (0.792, 0.851, 1.000) "Front"
// lerp-param: size       float 1 20   = 2.0 "Pixel size"
// lerp-param: scale      float 0.2 12 = 3.0 "Scale"
// lerp-param: speed      float 0 2    = 0.25 "Speed"
//
// Upstream presets that use the simplex shape, plus the palettes of two others.
// lerp-preset: Default    colorBack=#000000, colorFront=#00b2ff, size=2, scale=3
// lerp-preset: "Sine Wave" colorBack=#730d54, colorFront=#00becc, size=11, scale=6
// lerp-preset: Bugs       colorBack=#000000, colorFront=#008000, size=9, scale=3

constant int DT_BAYER8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
};

static float dtBayer(float2 uv) {
    int2 cell = int2(fract(uv / 8.0) * 8.0);
    cell = clamp(cell, int2(0), int2(7));
    return float(DT_BAYER8[cell.y * 8 + cell.x]) / 64.0;
}

static float dtSimplexField(float2 uv, float t) {
    float n = 0.5 * snoise(uv - float2(0.0, 0.3 * t));
    n += 0.5 * snoise(2.0 * uv + float2(0.0, 0.32 * t));
    return n;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Sizing happens in the fragment shader so the dither cell stays an exact
    // pixel multiple regardless of the pattern zoom (as upstream).
    float2 fragUV = float2(pos.x, u.resolution.y - pos.y);
    float2 pxSizeUV = (fragUV - 0.5 * u.resolution) / u.size;
    float2 pixelated = (floor(pxSizeUV) + 0.5) * u.size;

    float t = u.speed * u.time + 80.0 * u.seed;

    float2 shapeUV = pixelated * (u.scale / min(u.resolution.x, u.resolution.y));
    shapeUV = rotate(shapeUV, 0.6 * u.seed);

    float shape = 0.5 + 0.5 * dtSimplexField(shapeUV, t);
    shape = smoothstep(0.28, 0.92, shape);

    float dithering = dtBayer(pxSizeUV) - 0.5;
    float res = step(0.5, shape + dithering);

    float3 color = mix(u.colorBack.rgb, u.colorFront.rgb, res);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
