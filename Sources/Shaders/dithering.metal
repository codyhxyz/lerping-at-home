// Dithering — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Two-colour ordered dithering over a drifting simplex field: the upstream
// "simplex" shape with the 8x8 Bayer matrix, which is the combination that
// reads best full-screen.

constant float3 DT_COLOR_BACK  = float3(0.031, 0.035, 0.063); // near-black indigo
constant float3 DT_COLOR_FRONT = float3(0.792, 0.851, 1.000); // pale periwinkle

constant float DT_PX_SIZE = 2.0; // dither cell size in pixels
constant float DT_SCALE   = 3.0; // simplex field zoom

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
    float2 pxSizeUV = (fragUV - 0.5 * u.resolution) / DT_PX_SIZE;
    float2 pixelated = (floor(pxSizeUV) + 0.5) * DT_PX_SIZE;

    float t = 0.25 * u.time + 80.0 * u.seed;

    float2 shapeUV = pixelated * (DT_SCALE / min(u.resolution.x, u.resolution.y));
    shapeUV = rotate(shapeUV, 0.6 * u.seed);

    float shape = 0.5 + 0.5 * dtSimplexField(shapeUV, t);
    shape = smoothstep(0.28, 0.92, shape);

    float dithering = dtBayer(pxSizeUV) - 0.5;
    float res = step(0.5, shape + dithering);

    float3 color = mix(DT_COLOR_BACK, DT_COLOR_FRONT, res);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
