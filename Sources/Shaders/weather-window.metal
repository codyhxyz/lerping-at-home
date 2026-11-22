// Weather Window — an out-of-focus valley through a pane in sharp focus.
// Analytic water lenses, two projected cloud decks, and no textures or raymarch.
// lerp-category: Atmosphere
// lerp-param: hour      float 0 24 = 17.5 "Local hour"
// lerp-param: rain      float 0 1  = 0.52 "Rain on glass"
// lerp-param: snow      float 0 1  = 0    "Snowfall"
// lerp-param: clouds    float 0 1  = 0.64 "Cloud cover"
// lerp-param: wind      float 0 1  = 0.28 "Wind"
// lerp-param: fog       float 0 1  = 0.22 "Condensation"
// lerp-param: thunder   float 0 1  = 0    "Sheet lightning"
// lerp-param: frost     float 0 1  = 0    "Edge frost"
// lerp-param: moonPhase float 0 1  = 0.5  "Moon phase (0 = new)"
// lerp-param: speed     float 0 2  = 1    "Motion speed"
//
// lerp-react: hour      <- clock.hour
// lerp-react: moonPhase <- clock.moonPhase
// lerp-react: rain      <- weather.rain    smooth=4
// lerp-react: snow      <- weather.snow    smooth=4
// lerp-react: clouds    <- weather.clouds  smooth=8
// lerp-react: wind      <- weather.wind    smooth=8
// lerp-react: fog       <- weather.fog     smooth=6
// lerp-react: thunder   <- weather.thunder smooth=3
//
// lerp-preset: "Live Outside" speed=1
// lerp-preset: "Midnight Storm" hour=0.5, rain=0.98, snow=0, clouds=0.99, wind=0.78, fog=0.32, thunder=0.9, moonPhase=0.5
// lerp-preset: "Golden Drizzle" hour=17.83, rain=0.36, snow=0, clouds=0.37, wind=0.20, fog=0.10, thunder=0, moonPhase=0.5
// lerp-preset: "Winter Frost" hour=7.1, rain=0, snow=0.8, clouds=0.8, wind=0.35, fog=0.26, thunder=0, frost=0.93, moonPhase=0.5
// lerp-preset: "Misty Dawn" hour=5.9, rain=0.06, snow=0, clouds=0.57, wind=0.11, fog=0.87, thunder=0, moonPhase=0.5
// lerp-preset: "Clear Moon" hour=1.2, rain=0, snow=0, clouds=0.15, wind=0.12, fog=0, thunder=0, moonPhase=0.37

static inline float wwCloudNoise(float2 p) {
    return 0.55 * valueNoise(p) + 0.28 * valueNoise(p * 2.03 + 31.0)
         + 0.12 * valueNoise(p * 4.13 - 17.0) + 0.05 * valueNoise(p * 8.27 + 91.0);
}

struct WWGlass {
    float2 bend;
    float bead;
    float wet;
    float rim;
};

// A pinned contact line with a round meniscus, a bulging lower lobe on a
// moving drop, and a sharp specular rim. Different wavelengths bend by
// different amounts; bend remains a screen-space slope until compositing.
static inline WWGlass wwLens(float2 q, float aa, float enable) {
    float d2 = dot(q, q);
    if (d2 >= 1.0 + aa || enable <= 0.0) return {float2(0.0), 0.0, 0.0, 0.0};
    float mask = (1.0 - smoothstep(0.88 - aa, 1.0 + aa, d2)) * enable;
    float height = sqrt(max(0.07, 1.0 - d2));
    float rim = smoothstep(0.65, 0.98, d2) * mask;
    float glint = powr(saturate(dot(q, float2(-0.48, 0.87))), 8.0)
                + 0.25 * powr(saturate(dot(q, float2(0.36, -0.93))), 5.0);
    return {q * (-0.53 - 0.24 * height) * mask, mask, mask, rim * glint};
}

static inline WWGlass wwRoll(float2 p, float t, float seed, float scale,
                             float rain, float pixel) {
    float2 a = p * scale * float2(1.0, 0.49);
    float lane = floor(a.x);
    float2 r = hash22(float2(lane, seed));
    // Continuous phase, with a fast slide and a slow return to motion as the
    // drop gathers water; the lane owns the phase and never jumps at row edges.
    float travel = t * mix(0.20, 0.45, r.x) + r.y * 7.0;
    a.y += travel + 0.12 * sin(TWO_PI * travel);
    float row = floor(a.y);
    float2 id = float2(lane + seed, row);
    float2 v = hash22(id);
    float enable = smoothstep(v.x * 0.88, v.x * 0.88 + 0.12, rain);
    if (enable <= 0.0) return {float2(0.0), 0.0, 0.0, 0.0};
    float y = fract(a.y) - mix(0.20, 0.29, v.y);
    float sway = sin(t * 1.6 + v.y * TWO_PI + y * 5.6);
    float center = mix(0.27, 0.73, r.x) + (v.x - 0.5) * 0.12 + (0.035 + 0.019 * y) * sway;
    float x = fract(a.x) - clamp(center, 0.23, 0.77);
    float size = mix(0.075, 0.203, v.y);
    float2 q = float2(x / (size * mix(1.08, 0.78, smoothstep(-0.06, 0.09, y))),
                      y / (size * 0.80));
    WWGlass g = wwLens(q, pixel * scale / size, enable);

    // Beads left behind on the same wavy path. The faint liquid track tails
    // the drop rather than extending the full length of the pane.
    if (y > 0.05 && y < 0.65 && abs(x) < 0.10) {
        float streak = smoothstep(0.05, 0.16, y) * (1.0 - smoothstep(0.35, 0.65, y));
        float beadID = floor(y * 18.0);
        float k = hash21(float2(lane + seed, row * 23.0 + beadID));
        float2 trailQ = float2((x + (k - 0.5) * 0.035) * 33.0,
                               (fract(y * 18.0) - 0.5) * 2.9) / mix(0.43, 1.0, k);
        WWGlass trail = wwLens(trailQ, pixel * scale * 28.0, streak * enable);
        g.bend += 0.34 * trail.bend;
        g.bead = max(g.bead, 0.75 * trail.bead);
        g.wet = max(g.wet, max(trail.wet, exp(-abs(x) * 58.0) * streak * enable * 0.60));
        g.rim += trail.rim * 0.54;
    }
    g.bend /= scale;
    return g;
}

static inline WWGlass wwPinned(float2 p, float t, float seed, float rain, float pixel) {
    float2 a = p * 29.0;
    float2 cell = floor(a) + seed;
    float2 r = hash22(cell);
    float2 q = fract(a) - mix(float2(0.19), float2(0.81), r);
    float size = mix(0.037, 0.15, r.y * r.y);
    float enable = smoothstep(r.x * 0.92, r.x * 0.92 + 0.08, rain)
                 * (0.68 + 0.32 * sin(t * 0.30 + r.y * TWO_PI));
    WWGlass g = wwLens(q / size, pixel * 29.0 / size, enable);
    g.bend *= 0.017;
    g.wet *= 0.55;
    return g;
}

struct WWLight {
    float2 sun;
    float2 moon;
    float sunY;
    float day;
    float twilight;
    float3 warm;
    float flash;
    float flashX;
};

static inline WWLight wwLight(float hour, float t, float seed, float thunder) {
    float angle = (hour - 12.0) * PI / 12.0;
    float sunY = cos(angle);
    float2 sun = float2(sin(angle) * 0.62, sunY * 0.78 + 0.13);
    float2 moon = float2(-sin(angle) * 0.57 - 0.27, -sunY * 0.44 - 0.035);
    float day = smoothstep(-0.22, 0.18, sunY);
    float twilight = exp(-abs(sunY + 0.018) * 5.9);
    // Beer–Lambert extinction along a capped air mass near the horizon.
    float airmass = 1.0 / (max(sunY, 0.0) + 0.085);
    float3 warm = exp(-airmass * float3(0.015, 0.052, 0.126));
    float stormT = t + seed * 35.0;
    float chapter = floor(stormT / 8.8);
    float strike = glmod(stormT, 8.8) - mix(1.0, 7.3, hash11(chapter + seed * 19.0));
    float first = step(0.0, strike) * exp(-max(0.0, strike) * 9.0);
    float second = step(0.0, strike - 0.16) * exp(-max(0.0, strike - 0.16) * 18.0);
    return {sun, moon, sunY, day, twilight, warm, thunder * thunder * max(first, second * 0.74),
            mix(-0.82, 0.82, hash11(chapter + 19.71))};
}

static inline float wwStars(float2 p, float seed, float pixel) {
    float2 s = p * 136.0;
    float2 id = floor(s);
    float2 r = hash22(id + seed);
    float brightness = smoothstep(0.94, 1.0, hash21(id + 77.3));
    float d = length(fract(s) - mix(float2(0.17), float2(0.83), r));
    return brightness * (1.0 - smoothstep(0.025, max(pixel * 118.0, 0.12), d));
}

static inline float wwRidge(float x, float seed) {
    return 0.55 * valueNoise(float2(x * 2.5, seed))
         + 0.26 * valueNoise(float2(x * 6.8, seed + 13.0))
         + 0.13 * valueNoise(float2(x * 15.0, seed - 26.0))
         + 0.06 * valueNoise(float2(x * 36.0, seed + 117.0));
}

// The RGB coordinates of the soft skyline are intentionally displaced: the
// base sky/cloud plate is shaded once per pixel; the strongest dispersion is
// concentrated on its high-contrast boundaries and on the bokeh highlights.
static inline float3 wwOutdoor(float2 p, float2 split, float blur, float t, float seed,
                               constant LerpUniforms& u, WWLight l, float pixel) {
    float2 sky = p * float2(0.69, 0.67) + float2(0.0, 0.32);
    float up = saturate(sky.y);
    float toward = 1.0 / (1.0 + 5.0 * dot(sky - l.sun, sky - l.sun));
    float horizon = exp(-up * 4.1);
    // Broad Rayleigh-like blue gradient and a forward Mie lobe around the sun.
    float3 night = float3(0.016, 0.028, 0.069) + horizon * float3(0.040, 0.031, 0.043);
    float3 day = mix(float3(0.102, 0.31, 0.60), float3(0.65, 0.75, 0.80), horizon);
    float3 dusk = mix(float3(0.22, 0.23, 0.43), float3(0.81, 0.45, 0.28), toward * horizon);
    float3 col = mix(night, day, l.day);
    col = mix(col, dusk, l.twilight * (0.14 + 0.58 * horizon + 0.16 * toward));
    col += powr(toward, 3.4) * l.warm * (0.27 * l.day + 0.63 * l.twilight);
    float3 dx = sky.x - l.sun.x + float3(-split.x, 0.0, split.x);
    float3 dy = sky.y - l.sun.y + float3(-split.y, 0.0, split.y);
    float3 sunDisk = 1.0 - smoothstep(0.014, 0.024 + blur, sqrt(dx * dx + dy * dy));
    col += l.warm * sunDisk * 1.72 * smoothstep(-0.055, 0.055, l.sunY);
    if (l.day < 0.95) {
        float nightWeight = 1.0 - l.day;
        col += float3(0.49, 0.60, 0.80) * wwStars(sky, seed, pixel)
             * nightWeight * smoothstep(0.02, 0.33, up) * (1.0 - blur * 8.0);
        // Phase angle rotates the direction of incident light across a sphere.
        // A little earthshine leaves the dark side just visible at new moon.
        float2 m = (sky - l.moon) / 0.042;
        float m2 = dot(m, m);
        col += float3(0.09, 0.13, 0.26) * exp(-1.25 * m2) * nightWeight;
        if (m2 < 1.45) {
            float phase = TWO_PI * u.moonPhase;
            float inc = dot(float3(m, sqrt(max(0.0, 1.0 - m2))),
                            float3(sin(phase), 0.0, -cos(phase)));
            float disk = 1.0 - smoothstep(0.86, 1.06 + 8.0 * blur, m2);
            float maria = 0.64 + 0.36 * valueNoise(m * 6.0 + 0.25 * valueNoise(m * 17.0));
            col += disk * nightWeight * maria * float3(0.85, 0.89, 0.98)
                 * (0.041 + 0.91 * smoothstep(-0.04, 0.14, inc));
        }
    }
    if (u.clouds > 0.001 && sky.y > -0.08) {
        float2 d = float2(t * mix(0.022, 0.19, u.wind), -0.009 * t);
        float threshold = mix(0.79, 0.29, u.clouds);
        float horizonFade = smoothstep(-0.08, 0.09, sky.y);
        // Soften the planar projection at low elevations to suggest deep,
        // overlapping cloud volumes rather than streaks at the vanishing point.
        float2 q = sky / (max(sky.y, 0.0) * 0.40 + 0.74);
        float veil = wwCloudNoise(rotate(q, 0.14) * float2(2.6, 5.2) - d * 0.45 + seed);
        float cover = smoothstep(threshold - 0.06, threshold + 0.12, veil) * 0.54 * horizonFade;
        col = mix(col, mix(float3(0.037, 0.046, 0.080), float3(0.64, 0.68, 0.75), l.day), cover);

        q = sky / (max(sky.y, 0.0) * 0.50 + 0.76);
        q = rotate(q, -0.11) * float2(2.5, 6.2) - d + 90.2 + seed;
        float n = wwCloudNoise(q);
        float density = smoothstep(threshold - blur, threshold + 0.15 + blur, n) * horizonFade;
        float edge = saturate((n - valueNoise(q + float2(0.13, -0.20))) * 2.4 + 0.47);
        float3 body = mix(float3(0.046, 0.057, 0.089), float3(0.34, 0.38, 0.49), l.day);
        float3 silver = mix(float3(0.114, 0.152, 0.23), float3(0.84, 0.85, 0.87), l.day);
        silver = mix(silver, l.warm * float3(1.70, 1.25, 0.83), l.twilight * (0.20 + 0.80 * toward));
        float flash = l.flash * exp(-1.9 * abs(sky.x - l.flashX));
        col = mix(col, mix(body, silver, edge) + flash * float3(0.89, 1.02, 1.52),
                  density * mix(0.85, 1.0, u.rain));
    }

    float x = p.x;
    float farY = -0.56 + 0.61 * wwRidge(x + 0.21, seed + 1.4);
    float nearY = -0.89 + 0.67 * wwRidge(x - 0.73, seed + 41.5)
                + 0.088 * smoothstep(0.28, 1.32, abs(x));
    float farBlur = 0.034 + blur;
    float nearBlur = 0.019 + blur;
    float3 dyRGB = p.y + float3(-split.y, 0.0, split.y);
    float3 farMask = 1.0 - smoothstep(farY - farBlur, farY + farBlur, dyRGB);
    float3 nearMask = 1.0 - smoothstep(nearY - nearBlur, nearY + nearBlur, dyRGB);
    float3 farLand = mix(float3(0.025, 0.038, 0.063), float3(0.29, 0.37, 0.45), l.day);
    float3 nearLand = mix(float3(0.009, 0.015, 0.029), float3(0.081, 0.13, 0.15), l.day);
    float mist = exp(-abs(p.y - farY) * 9.0) * u.fog;
    col = mix(col, farLand + mist * mix(float3(0.08, 0.10, 0.16), float3(0.18, 0.19, 0.19), l.day), farMask);
    col = mix(col, nearLand, nearMask);

    if (p.y < -0.40 && l.day < 0.98) {
        // Valley lights naturally cluster under the lowest ridge; large,
        // defocused disks are rare and the much smaller lights carry depth.
        float2 bands = float2(30.0, 32.0);
        float2 grid = p * bands;
        float2 id = floor(grid);
        float2 r = hash22(id + seed + 54.5);
        float2 off = fract(grid) - mix(float2(0.29), float2(0.71), r);
        float3 bx = off.x + float3(-split.x, 0.0, split.x) * bands.x;
        float3 by = off.y + float3(-split.y, 0.0, split.y) * bands.y;
        float3 b = sqrt(bx * bx + by * by);
        float radius = mix(0.052, 0.27, powr(r.y, 4.0));
        float3 bokeh = 1.0 - smoothstep(radius * 0.36, radius + 0.028 + blur * 2.9, b);
        float clusters = valueNoise(id * float2(0.13, 0.27) + seed + 11.0);
        float town = exp(-abs(p.y + 0.70 + 0.055 * sin(x * 5.2)) * 15.0)
                   * smoothstep(0.30, 0.87, clusters) * smoothstep(0.33, 0.90, r.x) * (1.0 - l.day);
        float3 lamp = mix(float3(1.0, 0.46, 0.12), float3(0.84, 0.83, 0.63), r.x);
        col += bokeh * lamp * town * 1.27;
    }
    return col;
}

static inline float wwSnow(float2 p, float t, float scale, float wind,
                           float snow, float seed, float pixel) {
    float2 a = p * scale + t * float2(-0.025 - wind * 0.16, 0.42);
    a.x += 0.18 * sin(a.y * 4.0 + t * 0.67);
    float2 r = hash22(floor(a) + seed);
    float2 q = fract(a) - mix(float2(0.22), float2(0.78), r);
    float size = mix(0.022, 0.15, r.y * r.y);
    float flake = 1.0 - smoothstep(size * 0.28, size + pixel * scale, length(q));
    return flake * smoothstep(r.x * 0.9, r.x * 0.9 + 0.10, snow);
}

static inline float wwCrystal(float2 p, float scale, float seed, float pixel) {
    float2 a = p * scale;
    float2 r = hash22(floor(a) + seed);
    float2 q = fract(a) - mix(float2(0.39), float2(0.61), r);
    // Fold onto the nearest of six crystal arms. Feathered branches sprout
    // off the stem at 60 degrees, and shorten toward the tip.
    float2 v = abs(rotate(q, r.x * PI / 3.0));
    float2 f = abs(rotate(v, -PI / 3.0));
    if (f.y < v.y) v = f;
    float len = mix(0.15, 0.40, r.y);
    float aa = max(0.006, pixel * scale * 0.65);
    float stem = 1.0 - smoothstep(0.009, 0.009 + aa, v.y);
    float twigs = abs(fract((v.x - v.y * 0.58) * 15.0 + r.x) - 0.5);
    float fork = (1.0 - smoothstep(0.048, 0.048 + aa * 10.0, twigs))
               * (1.0 - smoothstep(0.01, 0.081, v.y + 0.11 * v.x));
    return max(stem, fork * 0.8) * (1.0 - smoothstep(len * 0.65, len, v.x));
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // Anchor the composition by display height, not the short axis: a very
    // wide or tall screen crops the valley horizontally, not through its sky.
    float2 p = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / u.resolution.y;
    float pixel = 2.0 / u.resolution.y;
    float t = u.time * u.speed;
    float seed = u.seed * 89.0 + 2.73;
    WWLight light = wwLight(u.hour, t, u.seed, u.thunder);

    WWGlass g = {float2(0.0), 0.0, 0.0, 0.0};
    if (u.rain > 0.001) {
        WWGlass a = wwRoll(p, t, seed, 6.6, u.rain, pixel);
        WWGlass b = wwRoll(p + 0.169, t * 1.47, seed + 11.3, 12.2, u.rain, pixel);
        WWGlass c = wwPinned(p, t, seed, u.rain, pixel);
        g = {a.bend + b.bend * (1.0 - a.bead) + c.bend * (1.0 - max(a.bead, b.bead)),
             max(max(a.bead, b.bead), c.bead), max(max(a.wet, b.wet), c.wet), a.rim + b.rim + c.rim};
    }
    float2 edgeXY = 1.0 - abs(2.0 * lerpScreenUV(pos, u.resolution) - 1.0);
    float edgeDist = min(edgeXY.x * u.resolution.x / u.resolution.y, edgeXY.y);
    float moisture = 0.0;
    if (u.fog > 0.001) {
        float n = 0.65 * valueNoise(p * 3.4 + seed) + 0.35 * valueNoise(p * 16.0 - seed);
        moisture = u.fog * saturate(0.15 + n * 0.87 + exp(-edgeDist * 6.0) * 0.41)
                 * (1.0 - 0.81 * g.wet);
    }
    float crystal = 0.0;
    float iceHaze = 0.0;
    float frost = max(u.frost, u.snow * 0.59);
    if (frost > 0.001 && edgeDist < 0.42) {
        float edgeNoise = valueNoise(p * 13.0 + seed) * 0.67 + valueNoise(p * 4.0 - seed) * 0.33;
        float ice = (1.0 - smoothstep(0.01, frost * (0.12 + edgeNoise * 0.27), edgeDist)) * frost;
        if (ice > 0.0) {
            float2 warped = p + float2(edgeNoise, -edgeNoise) * 0.07;
            crystal = max(wwCrystal(warped, 9.5, seed + 8.2, pixel),
                          wwCrystal(warped + 0.19, 21.0, seed, pixel) * 0.63) * ice;
        }
        iceHaze = ice * (0.18 + 0.38 * edgeNoise);
    }

    float blur = mix(0.011, 0.0025, g.bead) + moisture * 0.053 + iceHaze * 0.033;
    float3 col = wwOutdoor(p + g.bend, g.bend * 0.13, blur, t, seed, u, light, pixel);
    if (u.snow > 0.001) {
        float flakes = wwSnow(p, t * 0.78, 22.0, u.wind, u.snow, seed, pixel) * 0.35
                     + wwSnow(p + 0.23, t * 1.04, 13.0, u.wind, u.snow, seed + 18.6, pixel) * 0.53
                     + wwSnow(p - 0.58, t * 1.24, 7.0, u.wind, u.snow, seed + 9.1, pixel) * 0.65;
        col += flakes * mix(float3(0.23, 0.32, 0.47), float3(0.81, 0.88, 0.97), light.day);
    }
    float3 haze = mix(float3(0.064, 0.082, 0.13), float3(0.68, 0.72, 0.74), light.day);
    haze = mix(haze, light.warm * float3(1.07, 0.89, 0.75), light.twilight * 0.33);
    float flash = light.flash * exp(-abs(0.69 * p.x - light.flashX) * 1.3);
    col = mix(col, haze, saturate(moisture * 0.69 + iceHaze * 0.54));
    col *= 1.0 - 0.19 * g.bead;
    col += float3(0.49, 0.65, 0.93) * (flash * 0.26 + crystal * (0.36 + 0.40 * light.day));
    col += g.rim * (haze * (0.31 + 0.56 * light.day) + flash * float3(0.75, 0.91, 1.22));
    col *= 1.0 - 0.13 * saturate(1.0 - edgeDist);
    // Keep a little optical headroom in SDR without hard-clipping a flash.
    col /= 1.0 + 0.32 * col;
    return half4(half3(max(lerpDither(col, pos), 0.0)), 1.0h);
}
