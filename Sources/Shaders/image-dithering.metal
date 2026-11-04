// Image Dithering — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Upstream dithers an input image: it pixelates it onto a grid of `size`
// pixels, quantises the luminance to `colorSteps` levels with a random or
// 2x2 / 4x4 / 8x8 Bayer threshold, and inks it either in a three-colour
// palette or in the image's own hues. A screensaver has no image, so the
// sampler is replaced with a procedural dusk landscape — sky gradient, a
// low sun, drifting cloud banks and three ridgelines scrolling at parallax
// speeds — chosen because a smooth, photo-like range of light is what
// ordered dithering is for. Everything from the sample onward (the pixel
// grid, the thresholds, the quantiser, the highlight band and both colour
// modes) is the upstream algorithm.
//
// The procedural Dithering look (`dithering.metal`) is the other half of
// upstream's pair; this one is the filter.
//
// Deviations, all forced by the substitution:
//   - The scene fills the screen, so the image-box sizing props and the
//     soft image frame are not ported (frame baked to 1).
//   - The scene is opaque, so the alpha paths reduce to opacity 1 and the
//     result is composited over `colorBack` as upstream would on a page.
//   - `size` is in drawable pixels, like `dithering.metal`, not CSS pixels.
//   - `speed` is this port's own addition; upstream is static. It drives the
//     landscape, never the dither.
//
// `type` is upstream's enum: 1 random, 2 Bayer 2x2, 3 Bayer 4x4, 4 Bayer 8x8.
//
// lerp-param: colorFront     color      = #94ffaf "Front"
// lerp-param: colorBack      color      = #000c38 "Background"
// lerp-param: colorHighlight color      = #eaff94 "Highlight"
// lerp-param: type           int 1 4    = 4     "Dither type"
// lerp-param: size           float 1 20 = 3.0   "Pixel size"
// lerp-param: colorSteps     int 1 7    = 2     "Colour steps"
// lerp-param: originalColors bool       = false "Original colours"
// lerp-param: inverted       bool       = false "Inverted"
// lerp-param: speed          float 0 2  = 0.35  "Scene speed"
//
// Upstream presets (its Default is this file's defaults, at size 3 rather
// than 2 so the grid reads at native Retina resolution). Pixel sizes are
// scaled the same way.
// lerp-preset: Noise   colorFront=#a2997c, colorBack=#000000, colorHighlight=#ededed
// lerp-preset: Noise   type=1, size=1.5, colorSteps=1
// lerp-preset: Retro   colorFront=#eeeeee, colorBack=#5452ff, colorHighlight=#eeeeee
// lerp-preset: Retro   type=2, size=4.5, colorSteps=1, originalColors=true
// lerp-preset: Natural colorFront=#ffffff, colorBack=#000000, colorHighlight=#ffffff
// lerp-preset: Natural type=4, size=3, colorSteps=5, originalColors=true

constant int ID_BAYER2[4] = { 0, 2, 3, 1 };
constant int ID_BAYER4[16] = {
     0,  8,  2, 10,
    12,  4, 14,  6,
     3, 11,  1,  9,
    15,  7, 13,  5,
};
constant int ID_BAYER8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
};

static float idBayer(float2 uv, int size) {
    int2 p = clamp(int2(fract(uv / float(size)) * float(size)), int2(0), int2(size - 1));
    int index = p.y * size + p.x;
    if (size == 2) return float(ID_BAYER2[index]) / 4.0;
    if (size == 4) return float(ID_BAYER4[index]) / 16.0;
    return float(ID_BAYER8[index]) / 64.0;
}

// ---------------------------------------------------------------------------
// The landscape that stands in for u_image. `p` is centred, y up, short axis
// spanning [-0.5, 0.5]; colours are linear-ish display RGB in 0..1.

static float idFbm(float x) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) {
        v += a * valueNoise(float2(x, 0.37 * float(i)));
        x = 2.03 * x + 11.7;
        a *= 0.5;
    }
    return v;
}

static float idCloud(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * valueNoise(p);
        p = 2.1 * p + float2(5.2, 1.3);
        a *= 0.5;
    }
    return v;
}

static float3 idScene(float2 p, float aspect, float t, float seed) {
    // The sun rides a long, low arc and the sky's warmth follows it.
    float2 sun = float2(0.32 * aspect * sin(0.021 * t + 6.0 * seed),
                        -0.02 + 0.13 * cos(0.017 * t + 6.0 * seed));
    float warm = smoothstep(-0.12, 0.12, sun.y);

    // Sky: deep indigo at the zenith down to a glowing horizon.
    float h = clamp(p.y + 0.12, 0.0, 1.0);
    float3 zenith  = mix(float3(0.06, 0.05, 0.20), float3(0.16, 0.20, 0.45), warm);
    float3 horizon = mix(float3(0.78, 0.36, 0.42), float3(1.00, 0.70, 0.42), warm);
    float3 sky = mix(horizon, zenith, pow(h / 0.62, 0.7));

    float d = length(p - sun);
    sky += float3(1.0, 0.62, 0.32) * (0.55 * exp(-d * 7.0) + 0.25 * exp(-d * 2.2));
    sky = mix(sky, float3(1.0, 0.95, 0.82), 1.0 - smoothstep(0.050, 0.056, d));

    // Two cloud banks drifting at different heights.
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float2 q = float2(p.x * (2.2 - 0.6 * fi) + (0.05 + 0.03 * fi) * t + 13.0 * fi,
                          (p.y - 0.18 - 0.14 * fi) * (9.0 - 2.0 * fi));
        float c = idCloud(q) * exp(-q.y * q.y * 0.9);
        c = smoothstep(0.30, 0.62, c);
        float3 lit = mix(float3(0.42, 0.28, 0.46), float3(1.0, 0.78, 0.62), warm * exp(-1.5 * abs(p.x - sun.x)));
        sky = mix(sky, lit, 0.8 * c);
    }

    float3 color = sky;

    // Ridgelines, far to near. Each scrolls at its own parallax rate and
    // takes on less of the sky's colour the nearer it is.
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float rate = 0.010 + 0.022 * fi * fi;
        float x = p.x * (1.6 + 0.9 * fi) + rate * t + 37.0 * fi + 50.0 * seed;
        float ridge = -0.06 - 0.11 * fi + (0.16 - 0.03 * fi) * (idFbm(x) - 0.5) * 2.0;
        float edge = 1.5 / 900.0;
        float m = smoothstep(ridge + edge, ridge - edge, p.y);
        float haze = 0.62 - 0.27 * fi;
        float3 land = mix(float3(0.05, 0.04, 0.10), horizon * 0.85, haze * (0.6 + 0.4 * warm));
        // A little light along the crest of each ridge.
        land += horizon * 0.25 * haze * exp(-(ridge - p.y) * 40.0);
        color = mix(color, land, m);
    }

    return clamp(color, 0.0, 1.0);
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(u.resolution.y, 1.0);
    float t = u.speed * u.time + 400.0 * u.seed;

    // Sizing happens on the pixel grid, from the fragment position, as upstream.
    float pxSize = u.size;
    float2 fragUV = float2(pos.x, u.resolution.y - pos.y);
    float2 pxSizeUV = (fragUV - 0.5 * u.resolution) / pxSize;
    float2 canvasPixelizedUV = (floor(pxSizeUV) + 0.5) * pxSize;

    float2 p = canvasPixelizedUV / u.resolution.y;      // centred, y up
    float3 image = idScene(p, aspect, t, u.seed);

    float lum = dot(float3(0.2126, 0.7152, 0.0722), image);
    lum = u.inverted != 0 ? 1.0 - lum : lum;

    float dithering;
    switch (u.type) {
        case 1:  dithering = step(hash21(canvasPixelizedUV), lum); break;
        case 2:  dithering = idBayer(pxSizeUV, 2); break;
        case 3:  dithering = idBayer(pxSizeUV, 4); break;
        default: dithering = idBayer(pxSizeUV, 8); break;
    }

    float colorSteps = float(max(u.colorSteps, 1));
    dithering -= 0.5;
    float brightness = clamp(lum + dithering / colorSteps, 0.0, 1.0);
    float quantLum = floor(brightness * colorSteps + 0.5) / colorSteps;

    float3 color;
    if (u.originalColors != 0) {
        // Opaque source: upstream's quantised alpha is 1, so opacity is 1.
        float3 normColor = image / max(lum, 0.001);
        color = normColor * quantLum;
    } else {
        float4 fg = u.colorFront, bg = u.colorBack, hl = u.colorHighlight;
        float3 fgColor = fg.rgb * fg.a;
        float fgOpacity = fg.a;
        float3 bgColor = bg.rgb * bg.a;
        float bgOpacity = bg.a;
        float3 hlColor = hl.rgb * hl.a;
        float hlOpacity = hl.a;

        float band = step(1.02 - 0.02 * colorSteps, brightness);
        fgColor = mix(fgColor, hlColor, band);
        fgOpacity = mix(fgOpacity, hlOpacity, band);

        color = fgColor * quantLum;
        float opacity = fgOpacity * quantLum;
        color += bgColor * (1.0 - opacity);
        // Premultiplied; any remaining transparency shows black, as on a
        // dark page.
    }

    // No lerpDither: the output is already a handful of flat inks, and
    // banding noise on top would muddy the dither pattern.
    return half4(half3(clamp(color, 0.0, 1.0)), 1.0h);
}
