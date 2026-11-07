// Image Dithering — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Upstream dithers an input image: it pixelates it onto a grid of `size`
// pixels, quantises the luminance to `colorSteps` levels with a random or
// 2x2 / 4x4 / 8x8 Bayer threshold, and inks it either in a three-colour
// palette or in the image's own hues. A screensaver has no image, so the
// sampler is replaced with a procedural dusk landscape — sky gradient, a
// low sun, three cloud decks, three ridgelines and a lake — chosen because a
// smooth, photo-like range of light is what ordered dithering is for.
// Everything from the sample onward (the pixel grid, the thresholds, the
// quantiser, the highlight band and both colour modes) is the upstream
// algorithm.
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
//     landscape, never the dither: the threshold pattern is fixed to the
//     screen, so cells flip only where the picture under them changes.
//
// What keeps it moving. The first landscape (a sky gradient, faint cloud
// banks, ridges sliding sideways) read on the lock screen as a still even
// after its drift was tripled. Moving silhouette edges are
// a sliver of the frame, and a 1-bit dither turns every mid-tone into a
// static texture that swamps slow scenery under it. So now most of the
// frame is moving structure, at several depths and in different ways:
//   - three cloud decks at 1.3, 3.1 and 5.8% of the short side a second at
//     the default speed (lower is nearer, so larger and faster), each with
//     octaves sliding against each other so the banks change shape, and
//     shaded within (lit tops and thin edges, dark bellies and cores) so a
//     bank carries light and dark across the dither, not one flat tone;
//   - a sky that darkens quickly above the horizon, so the clouds stand
//     out bright against it instead of matching it;
//   - a lake mirroring the sky and far ridges, its swells rolling toward
//     the viewer and a cross-chop sliding sideways, with the sun's glitter
//     path lit on the crests;
//   - the near ridge in front of the lake, scrolling fastest, its dips
//     opening and closing views of the water;
//   - the sun on a roughly ten-minute arc that sets the warmth of it all.
// Moving the dither itself (re-seeding thresholds over time) is ruled out:
// cells crawling at random read as noise, not motion.
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
// lerp-param: speed          float 0 2  = 0.40  "Scene speed"
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

static float idCloud(float2 p, float t) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * valueNoise(p + float(i) * float2(0.20, 0.12) * t);
        p = 2.1 * p + float2(5.2, 1.3);
        a *= 0.5;
    }
    return v;
}

// The sky gradient and sun, without clouds: shared by the sky and its
// reflection in the lake.
static float3 idSky(float2 p, float2 sun, float warm, float3 horizon) {
    float h = clamp(p.y + 0.12, 0.0, 1.0);
    float3 zenith = mix(float3(0.04, 0.03, 0.14), float3(0.12, 0.14, 0.36), warm);
    float3 sky = mix(horizon, zenith, pow(min(h / 0.45, 1.0), 0.5));
    float d = length(p - sun);
    sky += float3(1.0, 0.62, 0.32) * (0.55 * exp(-d * 7.0) + 0.25 * exp(-d * 2.2));
    return mix(sky, float3(1.0, 0.95, 0.82), 1.0 - smoothstep(0.050, 0.056, d));
}

constant float ID_WATER = -0.20;    // the lake's far shore, in scene units

static float3 idScene(float2 p, float aspect, float t, float seed) {
    // The sun rides a long, low arc and the sky's warmth follows it.
    float2 sun = float2(0.32 * aspect * sin(0.030 * t + 6.0 * seed),
                        -0.02 + 0.13 * cos(0.024 * t + 6.0 * seed));
    float warm = smoothstep(-0.12, 0.12, sun.y);
    float3 horizon = mix(float3(0.78, 0.36, 0.42), float3(1.00, 0.70, 0.42), warm);

    float3 color;
    float depth = ID_WATER - p.y;           // > 0 on the lake, 0 at its far shore
    float ripple = 0.0;
    float near = smoothstep(0.0, 0.03, depth);   // ripples fade out at the far shore
    if (depth > 0.0) {
        // The lake: the sky mirrored about the far shore, broken by swells
        // that roll toward the viewer and a cross-chop sliding sideways.
        // `v` is distance across the water, so the swells bunch up near
        // the shore the way a receding plane does.
        float v = 1.0 / (depth + 0.03);
        float sx = p.x * v;
        ripple = 0.6 * valueNoise(float2(0.9 * sx, 0.55 * v + 0.9 * t))
               + 0.4 * valueNoise(float2(1.7 * sx - 0.6 * t, 1.1 * v + 0.3 * t + 7.0));
        float2 m = float2(p.x, 2.0 * ID_WATER - p.y + 0.05 * near * depth * (ripple - 0.5));
        color = idSky(m, sun, warm, horizon) * (0.70 + 0.9 * near * (ripple - 0.5));
        // The sun's glitter path: a column under it, widening toward the
        // viewer, lit only on the swells' crests.
        float column = exp(-pow((p.x - sun.x) / (0.025 + 0.35 * depth), 2.0));
        float sunUp = smoothstep(-0.10, 0.02, sun.y);
        color += float3(1.0, 0.78, 0.48) * column * sunUp * smoothstep(0.45, 0.80, ripple);
    } else {
        color = idSky(p, sun, warm, horizon);

        // Three cloud decks, high to low. Lower decks are nearer, so they
        // are larger and cross faster; each deck's octaves also slide
        // against each other so the banks change shape as they go.
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float scale = 3.0 - 0.7 * fi;
            float drift = 0.032 + 0.036 * fi + 0.010 * fi * fi;      // scene units per t
            float2 q = float2(p.x * scale + drift * scale * t + 13.0 * fi + 20.0 * seed,
                              (p.y - 0.36 + 0.14 * fi) * (8.0 - 1.5 * fi));
            float n = idCloud(q, t);
            float c = smoothstep(0.34, 0.44, n * exp(-q.y * q.y * 0.6));
            // Tops and thin edges catch the sun; bellies and thick cores
            // stay in shadow, so each bank carries its own light and dark
            // with it rather than being one flat shape.
            float glow = warm * exp(-1.5 * abs(p.x - sun.x));
            float3 lit = mix(float3(0.84, 0.62, 0.76), float3(1.0, 0.88, 0.72), glow);
            float3 belly = mix(float3(0.14, 0.09, 0.22), float3(0.46, 0.24, 0.32), glow);
            float tone = smoothstep(-1.2, 0.8, q.y) - 2.0 * (n - 0.5);
            float3 cloud = mix(belly, lit, clamp(tone, 0.0, 1.0));
            color = mix(color, cloud, 0.85 * c);
        }
    }

    // Ridgelines, far to near. Each scrolls at its own parallax rate and
    // takes on less of the sky's colour the nearer it is. The two behind
    // the lake stand on its far shore and show in it upside down; the near
    // one is the foreground, its dips opening onto the water as it passes.
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float rate = 0.030 + 0.066 * fi * fi;
        float x = p.x * (1.6 + 0.9 * fi) + rate * t + 37.0 * fi + 50.0 * seed;
        float base = i < 2 ? -0.05 - 0.08 * fi : -0.42;
        float amp = i < 2 ? 0.15 - 0.05 * fi : 0.18;
        float ridge = base + amp * (idFbm(x) - 0.5) * 2.0;
        if (i < 2) ridge = max(ridge, ID_WATER + 0.01);
        float edge = 1.5 / 900.0;
        float haze = 0.50 - 0.23 * fi;
        float3 land = mix(float3(0.05, 0.04, 0.10), horizon * 0.85, haze * (0.6 + 0.4 * warm));
        float3 crest = horizon * 0.25 * haze;
        if (i < 2 && depth > 0.0) {
            float my = 2.0 * ID_WATER - p.y + 0.03 * depth * (ripple - 0.5);
            float r = smoothstep(ridge + edge, ridge - edge, my);
            color = mix(color, mix(color, land, 0.75) * (0.75 + 0.5 * near * (ripple - 0.5)), r);
        }
        // A little light along the crest of each ridge.
        land += crest * exp(-(ridge - p.y) * 40.0);
        float m = smoothstep(ridge + edge, ridge - edge, p.y);
        if (i < 2) m *= step(depth, 0.0);   // they stop at the water
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
