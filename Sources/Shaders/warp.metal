// Warp — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Checks pattern with noise distortion + layered swirls; dark violet marble
// palette after the paper.design default preset.

// Parameters mirror the upstream <Warp> props. Upstream's `shape` enum is not
// ported — this file is always the "checks" pattern. Upstream takes a
// variable-length `colors` array (max 10); this port fixes four tunable slots.
// `scale` is in this port's units, not upstream's sizing system.
//
// lerp-param: color1          color        = (0.071, 0.071, 0.078) "Charcoal"
// lerp-param: color2          color        = (0.580, 0.439, 1.000) "Soft violet"
// lerp-param: color3          color        = (0.071, 0.071, 0.078) "Charcoal"
// lerp-param: color4          color        = (0.533, 0.220, 1.000) "Electric purple"
// lerp-param: scale           float 0.1 10 = 1.9  "Scale"
// lerp-param: proportion      float 0 1    = 0.45 "Proportion"
// lerp-param: softness        float 0 1    = 1.0  "Softness"
// lerp-param: shapeScale      float 0 1    = 0.1  "Shape scale"
// lerp-param: distortion      float 0 1    = 0.25 "Distortion"
// lerp-param: swirl           float 0 1    = 0.8  "Swirl"
// lerp-param: swirlIterations int 1 20     = 10   "Swirl iterations"
// lerp-param: speed           float 0 20   = 0.5  "Speed"
//
// Upstream presets whose shape is "checks", scale mapped into this port's
// units and speed scaled to this port's ambience (upstream × 0.5).
// lerp-preset: "Live Ink" color1=#111314, color2=#9faeab, color3=#f3fee7, color4=#f3fee7
// lerp-preset: "Live Ink" scale=2.28, proportion=0.05, softness=0, distortion=0.25
// lerp-preset: "Live Ink" swirl=0.8, swirlIterations=10, shapeScale=0.28, speed=1.25
// lerp-preset: Passion   color1=#3b1515, color2=#954751, color3=#ffc085, color4=#3b1515
// lerp-preset: Passion   scale=4.75, proportion=0.5, softness=1, distortion=0.09
// lerp-preset: Passion   swirl=0.9, swirlIterations=6, shapeScale=0.25, speed=1.5

constant int WARP_COLOR_COUNT = 4;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float3 colors[WARP_COLOR_COUNT] = { u.color1.rgb, u.color2.rgb, u.color3.rgb, u.color4.rgb };

    // ~= v_patternUV * 0.5 of the original at a 750px short axis.
    float2 uv = lerpUV(pos, u.resolution) * u.scale;

    const float firstFrameOffset = 118.0;
    float t = 0.0625 * (u.speed * u.time + firstFrameOffset + 97.0 * u.seed);

    float n1 = valueNoise(uv + t);
    float n2 = valueNoise(uv * 2.0 - t);
    float angle = n1 * TWO_PI;
    uv.x += 4.0 * u.distortion * n2 * cos(angle);
    uv.y += 4.0 * u.distortion * n2 * sin(angle);

    for (int i = 1; i < u.swirlIterations; i++) {
        float iF = float(i);
        uv.x += u.swirl / iF * cos(t + iF * 1.5 * uv.y);
        uv.y += u.swirl / iF * cos(t + iF * 1.0 * uv.x);
    }

    // Base pattern: checks.
    float2 checksUV = uv * (0.5 + 3.5 * u.shapeScale);
    float shape = 0.5 + 0.5 * sin(checksUV.x) * cos(checksUV.y);
    shape += 0.48 * sign(u.proportion - 0.5) * pow(abs(u.proportion - 0.5), 0.5);

    float mixer = shape * float(WARP_COLOR_COUNT - 1);
    float3 gradient = colors[0];
    float aa = fwidth(shape);
    for (int i = 1; i < WARP_COLOR_COUNT; i++) {
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);

        float localMixerStart = floor(m);
        float softness = 0.5 * u.softness + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa),
                                    min(1.0, 0.5 + softness + aa),
                                    m - localMixerStart);
        float stepped = localMixerStart + smoothed;

        m = mix(stepped, m, u.softness);
        gradient = mix(gradient, colors[i], m);
    }

    float3 color = gradient;
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
