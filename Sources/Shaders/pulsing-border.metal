// Pulsing Border — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Luminous colour trails chasing each other around a rounded frame, with a
// noisy smoke bloom and a slow heartbeat. The original's noise-texture
// randomizer is replaced with the prelude's hash22 / valueNoise.

// Parameters mirror the upstream <PulsingBorder> props. Upstream's four
// per-side margins collapse to one `margin` here, and its `aspectRatio` enum
// is not ported (the frame always follows the canvas). Upstream takes a
// variable-length `colors` array (max 5); this port fixes four tunable slots.
//
// lerp-param: color1    color     = (0.941, 0.216, 0.639, 1.0) "Magenta"
// lerp-param: color2    color     = (0.192, 0.847, 0.976, 1.0) "Cyan"
// lerp-param: color3    color     = (1.000, 0.706, 0.243, 1.0) "Amber"
// lerp-param: color4    color     = (0.553, 0.302, 1.000, 1.0) "Violet"
// lerp-param: colorBack color     = (0.008, 0.010, 0.024) "Background"
// lerp-param: spots     int 1 4   = 4    "Spots"
// lerp-param: roundness float 0 1 = 0.55 "Roundness"
// lerp-param: thickness float 0 1 = 0.22 "Thickness"
// lerp-param: softness  float 0 1 = 0.55 "Softness"
// lerp-param: margin    float 0 1 = 0.12 "Margin"
// lerp-param: intensity float 0 1 = 0.22 "Intensity"
// lerp-param: bloom     float 0 1 = 0.12 "Bloom"
// lerp-param: spotSize  float 0 1 = 0.4  "Spot size"
// lerp-param: pulse     float 0 1 = 0.25 "Pulse"
// lerp-param: smoke     float 0 1 = 0.6  "Smoke"
// lerp-param: smokeSize float 0 1 = 0.55 "Smoke size"
// lerp-param: speed     float 0 2 = 0.22 "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 0.22).
// lerp-preset: Circle  colorBack=#000000, color1=#0dc1fd, color2=#d915ef, color3=#ff3f2ecc
// lerp-preset: Circle  color4=#0dc1fd, roundness=1, thickness=0, softness=0.75
// lerp-preset: Circle  intensity=0.2, bloom=0.45, spots=3, spotSize=0.4, pulse=0.5
// lerp-preset: Circle  smoke=1, smokeSize=0, margin=0, speed=0.22
// lerp-preset: "Northern lights" colorBack=#0c182c, color1=#4c4794, color2=#774a7d
// lerp-preset: "Northern lights" color3=#12694a, color4=#0aff78, roundness=0, thickness=1
// lerp-preset: "Northern lights" softness=1, intensity=0.1, bloom=0.2, spots=4
// lerp-preset: "Northern lights" spotSize=0.25, pulse=0, smoke=0.32, smokeSize=0.5, speed=0.04
// lerp-preset: "Solid line" colorBack=#000000, color1=#81adec, color2=#81adec
// lerp-preset: "Solid line" color3=#81adec, color4=#81adec, roundness=0, thickness=0.05
// lerp-preset: "Solid line" softness=0, intensity=0, bloom=0.15, spots=4, spotSize=1
// lerp-preset: "Solid line" pulse=0, smoke=0, smokeSize=0, margin=0, speed=0.22

constant int SPB_COLOR_COUNT = 4;

static float spbBeat(float time) {
    float first = pow(abs(sin(time * TWO_PI)), 10.0);
    float second = pow(abs(sin((time - 0.15) * TWO_PI)), 10.0);
    return clamp(first + 0.6 * second, 0.0, 1.0);
}

static float spbRoundedBox(float2 uv, float2 halfSize, float sdf,
                           float cornerDistance, float thickness, float softness) {
    float borderDistance = abs(sdf);
    float aa = 2.0 * fwidth(sdf);
    float lo = min(mix(thickness, -thickness, softness), thickness + aa);
    float hi = max(mix(thickness, -thickness, softness), thickness + aa);
    float border = 1.0 - smoothstep(lo, hi, borderDistance);

    float corners = 0.0;
    corners = mix(1.0, corners, smoothstep(0.0, 1.0, length((uv + halfSize) / thickness)));
    corners = mix(1.0, corners, smoothstep(0.0, 1.0, length((uv - float2(-halfSize.x, halfSize.y)) / thickness)));
    corners = mix(1.0, corners, smoothstep(0.0, 1.0, length((uv - float2(halfSize.x, -halfSize.y)) / thickness)));
    corners = mix(1.0, corners, smoothstep(0.0, 1.0, length((uv - halfSize) / thickness)));

    float cornerAA = fwidth(cornerDistance);
    float cornerFade = smoothstep(0.0, mix(cornerAA, thickness, softness), cornerDistance);
    cornerFade *= corners;

    return border + cornerFade;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // v_responsiveUV: centered, [-0.5, 0.5] on the short axis.
    float4 colors[SPB_COLOR_COUNT] = { u.color1, u.color2, u.color3, u.color4 };

    float2 borderUV = lerpUV(pos, u.resolution) * 0.5;
    float2 patternUV = lerpUV(pos, u.resolution) * 3.0;

    // Original: t = 1.2 * (u_time + 109). Slowed for ambience.
    float t = 1.2 * (u.speed * u.time + 109.0 + 37.0 * u.seed);
    float pulse = u.pulse * spbBeat(0.09 * u.time);

    float canvasRatio = u.resolution.x / max(u.resolution.y, 1.0);
    float2 halfSize = float2(0.5 * max(canvasRatio, 1.0), 0.5 / min(canvasRatio, 1.0));

    float thickness = 0.5 * u.thickness * min(halfSize.x, halfSize.y);
    halfSize *= (1.0 - 2.0 * u.margin);
    halfSize -= mix(thickness, 0.0, u.softness);

    float radius = mix(0.0, min(halfSize.x, halfSize.y), u.roundness);
    float2 d = abs(borderUV) - halfSize + radius;
    float outsideDistance = length(max(d, 0.0001)) - radius;
    float insideDistance = min(max(d.x, d.y), 0.0001);
    float cornerDistance = abs(min(max(d.x, d.y) - 0.45 * radius, 0.0));
    float sdf = outsideDistance + insideDistance;

    float borderThickness = mix(thickness, 3.0 * thickness, u.softness);
    float border = spbRoundedBox(borderUV, halfSize, sdf, cornerDistance, borderThickness, u.softness);
    border = pow(border, 1.0 + u.softness);

    float2 smokeUV = 0.3 * u.smokeSize * patternUV;
    float smoke = clamp(3.0 * valueNoise(2.7 * smokeUV + 0.5 * t), 0.0, 1.0);
    smoke -= valueNoise(3.4 * smokeUV - 0.5 * t);
    float smokeThickness = clamp(thickness + 0.2, 0.1, 0.4);
    smoke *= spbRoundedBox(borderUV, halfSize, sdf, cornerDistance, smokeThickness, 1.0);
    smoke = 30.0 * smoke * smoke;
    smoke *= mix(0.0, 0.5, pow(u.smoke, 2.0));
    smoke *= mix(1.0, pulse, u.pulse);
    border += clamp(smoke, 0.0, 1.0);
    border = clamp(border, 0.0, 1.0);

    float3 blendColor = float3(0.0);
    float blendAlpha = 0.0;
    float3 addColor = float3(0.0);
    float addAlpha = 0.0;

    float bloom = 4.0 * u.bloom;
    float intensity = 1.0 + (1.0 + 4.0 * u.softness) * u.intensity;
    float angle = atan2(borderUV.y, borderUV.x) / TWO_PI;

    for (int colorIdx = 0; colorIdx < SPB_COLOR_COUNT; colorIdx++) {
        float ci = float(colorIdx);
        float3 c = colors[colorIdx].rgb * colors[colorIdx].a;
        float a = colors[colorIdx].a;

        for (int spotIdx = 0; spotIdx < u.spots; spotIdx++) {
            float si = float(spotIdx);
            float2 randVal = hash22(float2(si * 10.0 + 2.0, 40.0 + ci));

            float spotTime = (0.1 + 0.15 * abs(sin(si * (2.0 + ci)) * cos(si * (2.0 + 2.5 * ci)))) * t
                           + randVal.x * 3.0;
            spotTime *= mix(1.0, -1.0, step(0.5, randVal.y));

            float mask = 0.5 + 0.5 * mix(sin(t + si * (5.0 - 1.5 * ci)),
                                         cos(t + si * (3.0 + 1.3 * ci)),
                                         step(glmod(ci, 2.0), 0.5));

            float p = clamp(2.0 * u.pulse - randVal.x, 0.0, 1.0);
            mask = mix(mask, pulse, p);

            float atg = fract(angle + spotTime);
            float spotSize = 0.05 + 0.6 * pow(u.spotSize, 2.0) + 0.05 * randVal.x;
            spotSize = mix(spotSize, 0.1, p);
            float sector = smoothstep(0.5 - spotSize, 0.5, atg) * (1.0 - smoothstep(0.5, 0.5 + spotSize, atg));

            sector *= mask * border * intensity;
            sector = clamp(sector, 0.0, 1.0);

            float3 srcColor = c * sector;
            float srcAlpha = a * sector;

            blendColor += (1.0 - blendAlpha) * srcColor;
            blendAlpha = blendAlpha + (1.0 - blendAlpha) * srcAlpha;
            addColor += srcColor;
            addAlpha += srcAlpha;
        }
    }

    float3 accumColor = mix(blendColor, addColor, bloom);
    float accumAlpha = clamp(mix(blendAlpha, addAlpha, bloom), 0.0, 1.0);

    // accumColor is premultiplied; composite over the opaque background.
    float3 color = clamp(accumColor, 0.0, 1.0) + (1.0 - accumAlpha) * u.colorBack.rgb;
    color = clamp(color, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
