// Pulsing Border — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Luminous colour trails chasing each other around a rounded frame, with a
// noisy smoke bloom and a slow heartbeat. The original's noise-texture
// randomizer is replaced with the prelude's hash22 / valueNoise.

constant int SPB_COLOR_COUNT = 4;
constant float4 SPB_COLORS[SPB_COLOR_COUNT] = {
    float4(0.941, 0.216, 0.639, 1.0), // magenta
    float4(0.192, 0.847, 0.976, 1.0), // cyan
    float4(1.000, 0.706, 0.243, 1.0), // amber
    float4(0.553, 0.302, 1.000, 1.0), // violet
};
constant float3 SPB_COLOR_BACK = float3(0.008, 0.010, 0.024); // near-black

constant int   SPB_SPOTS      = 4;
constant float SPB_ROUNDNESS  = 0.55;
constant float SPB_THICKNESS  = 0.22;
constant float SPB_SOFTNESS   = 0.55;
constant float SPB_MARGIN     = 0.12;
constant float SPB_INTENSITY  = 0.22;
constant float SPB_BLOOM      = 0.12;
constant float SPB_SPOT_SIZE  = 0.4;
constant float SPB_PULSE      = 0.25;
constant float SPB_SMOKE      = 0.6;
constant float SPB_SMOKE_SIZE = 0.55;

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
    float2 borderUV = lerpUV(pos, u.resolution) * 0.5;
    float2 patternUV = lerpUV(pos, u.resolution) * 3.0;

    // Original: t = 1.2 * (u_time + 109). Slowed for ambience.
    float t = 1.2 * (0.22 * u.time + 109.0 + 37.0 * u.seed);
    float pulse = SPB_PULSE * spbBeat(0.09 * u.time);

    float canvasRatio = u.resolution.x / max(u.resolution.y, 1.0);
    float2 halfSize = float2(0.5 * max(canvasRatio, 1.0), 0.5 / min(canvasRatio, 1.0));

    float thickness = 0.5 * SPB_THICKNESS * min(halfSize.x, halfSize.y);
    halfSize *= (1.0 - 2.0 * SPB_MARGIN);
    halfSize -= mix(thickness, 0.0, SPB_SOFTNESS);

    float radius = mix(0.0, min(halfSize.x, halfSize.y), SPB_ROUNDNESS);
    float2 d = abs(borderUV) - halfSize + radius;
    float outsideDistance = length(max(d, 0.0001)) - radius;
    float insideDistance = min(max(d.x, d.y), 0.0001);
    float cornerDistance = abs(min(max(d.x, d.y) - 0.45 * radius, 0.0));
    float sdf = outsideDistance + insideDistance;

    float borderThickness = mix(thickness, 3.0 * thickness, SPB_SOFTNESS);
    float border = spbRoundedBox(borderUV, halfSize, sdf, cornerDistance, borderThickness, SPB_SOFTNESS);
    border = pow(border, 1.0 + SPB_SOFTNESS);

    float2 smokeUV = 0.3 * SPB_SMOKE_SIZE * patternUV;
    float smoke = clamp(3.0 * valueNoise(2.7 * smokeUV + 0.5 * t), 0.0, 1.0);
    smoke -= valueNoise(3.4 * smokeUV - 0.5 * t);
    float smokeThickness = clamp(thickness + 0.2, 0.1, 0.4);
    smoke *= spbRoundedBox(borderUV, halfSize, sdf, cornerDistance, smokeThickness, 1.0);
    smoke = 30.0 * smoke * smoke;
    smoke *= mix(0.0, 0.5, pow(SPB_SMOKE, 2.0));
    smoke *= mix(1.0, pulse, SPB_PULSE);
    border += clamp(smoke, 0.0, 1.0);
    border = clamp(border, 0.0, 1.0);

    float3 blendColor = float3(0.0);
    float blendAlpha = 0.0;
    float3 addColor = float3(0.0);
    float addAlpha = 0.0;

    float bloom = 4.0 * SPB_BLOOM;
    float intensity = 1.0 + (1.0 + 4.0 * SPB_SOFTNESS) * SPB_INTENSITY;
    float angle = atan2(borderUV.y, borderUV.x) / TWO_PI;

    for (int colorIdx = 0; colorIdx < SPB_COLOR_COUNT; colorIdx++) {
        float ci = float(colorIdx);
        float3 c = SPB_COLORS[colorIdx].rgb * SPB_COLORS[colorIdx].a;
        float a = SPB_COLORS[colorIdx].a;

        for (int spotIdx = 0; spotIdx < SPB_SPOTS; spotIdx++) {
            float si = float(spotIdx);
            float2 randVal = hash22(float2(si * 10.0 + 2.0, 40.0 + ci));

            float spotTime = (0.1 + 0.15 * abs(sin(si * (2.0 + ci)) * cos(si * (2.0 + 2.5 * ci)))) * t
                           + randVal.x * 3.0;
            spotTime *= mix(1.0, -1.0, step(0.5, randVal.y));

            float mask = 0.5 + 0.5 * mix(sin(t + si * (5.0 - 1.5 * ci)),
                                         cos(t + si * (3.0 + 1.3 * ci)),
                                         step(glmod(ci, 2.0), 0.5));

            float p = clamp(2.0 * SPB_PULSE - randVal.x, 0.0, 1.0);
            mask = mix(mask, pulse, p);

            float atg = fract(angle + spotTime);
            float spotSize = 0.05 + 0.6 * pow(SPB_SPOT_SIZE, 2.0) + 0.05 * randVal.x;
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
    float3 color = clamp(accumColor, 0.0, 1.0) + (1.0 - accumAlpha) * SPB_COLOR_BACK;
    color = clamp(color, 0.0, 1.0);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
