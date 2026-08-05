// Color Panels — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Pseudo-3D semi-transparent panels rotating around a central axis.
// Palette follows the paper.design demo defaults (7 colors on black).

// Parameters mirror the upstream <ColorPanels> props. Upstream's `edges`
// boolean is not ported — this file always takes the `edges = false` branch.
// The z clip plane and the 14-panel/density-normalizer table stay fixed:
// upstream derives them from the colour count, which is fixed here at seven.
//
// lerp-param: color1    color          = (1.000, 0.616, 0.000, 1.0) "Amber"
// lerp-param: color2    color          = (0.992, 0.310, 0.188, 1.0) "Coral"
// lerp-param: color3    color          = (0.502, 0.608, 1.000, 1.0) "Periwinkle"
// lerp-param: color4    color          = (0.427, 0.180, 1.000, 1.0) "Violet"
// lerp-param: color5    color          = (0.200, 0.227, 1.000, 1.0) "Ultramarine"
// lerp-param: color6    color          = (0.945, 0.361, 1.000, 1.0) "Orchid"
// lerp-param: color7    color          = (1.000, 0.835, 0.341, 1.0) "Gold"
// lerp-param: colorBack color          = (0.004, 0.004, 0.010) "Background"
// lerp-param: scale     float 0.01 4   = 1.0  "Scale"
// lerp-param: density   float 0.25 7   = 3.0  "Density"
// lerp-param: angle1    float -1 1     = 0.0  "Angle 1"
// lerp-param: angle2    float -1 1     = 0.0  "Angle 2"
// lerp-param: length    float 0 3      = 1.5  "Length"
// lerp-param: blur      float 0 0.5    = 0.0  "Blur"
// lerp-param: fadeIn    float 0 1      = 1.0  "Fade in"
// lerp-param: fadeOut   float 0 1      = 0.3  "Fade out"
// lerp-param: gradient  float 0 1      = 0.0  "Gradient"
// lerp-param: speed     float 0 4      = 0.5  "Speed"
//
// Upstream presets (their palettes padded out to this port's seven slots).
// lerp-preset: Glass    colorBack=#ffffff, color1=#00cfff, color2=#ff2d55, color3=#34c759
// lerp-preset: Glass    color4=#af52de, color5=#00cfff, color6=#ff2d55, color7=#34c759
// lerp-preset: Glass    angle1=0.3, angle2=0.3, length=1, blur=0.25, fadeIn=0.85
// lerp-preset: Glass    fadeOut=0.3, gradient=0, density=1.6, speed=1
// lerp-preset: Gradient colorBack=#8ffff2, color1=#f2ff00, color2=#5a0283, color3=#005eff
// lerp-preset: Gradient color4=#f2ff00, color5=#5a0283, color6=#005eff, color7=#f2ff00
// lerp-preset: Gradient angle1=0.4, angle2=0.4, length=3, blur=0.5, fadeIn=1
// lerp-preset: Gradient fadeOut=0.39, gradient=0.78, density=1.65, scale=1.72, speed=0.5
// lerp-preset: Opening  colorBack=#570044, color1=#00ffff, color2=#00ffff, color3=#00ffff
// lerp-preset: Opening  color4=#00ffff, color5=#00ffff, color6=#00ffff, color7=#00ffff
// lerp-preset: Opening  angle1=-1, angle2=-1, length=0.52, blur=0, fadeIn=0
// lerp-preset: Opening  fadeOut=1, gradient=0, density=2.21, scale=2.32, speed=2

constant int CP_COLOR_COUNT = 7;
constant float CP_Z_LIMIT  = 0.5;

// 7 colors -> 14 panels, density normalizer 1.17 (from the original's table)
constant int   CP_PANELS       = 14;
constant float CP_DENSITY_NORM = 1.17;

static float2 cpGetPanel(float angle, float2 uv, float invLength, float aa,
                         constant LerpUniforms& u) {
    float sinA = sin(angle);
    float cosA = cos(angle);

    float denom = sinA - uv.y * cosA;
    if (abs(denom) < 0.01) return float2(0.0);

    float z = uv.y / denom;
    if (z <= 0.0 || z > CP_Z_LIMIT) return float2(0.0);

    float zRatio = z / CP_Z_LIMIT;
    float panelMap = 1.0 - zRatio;
    float x = uv.x * (cosA * z + 1.0) * invLength;

    float zOffset = zRatio - 0.5;
    float left  = -0.5 + zOffset * u.angle1;
    float right =  0.5 - zOffset * u.angle2;
    float blurX = aa + 2.0 * panelMap * u.blur;

    float leftEdge1  = left - blurX;
    float leftEdge2  = left + 0.25 * blurX;
    float rightEdge1 = right - 0.25 * blurX;
    float rightEdge2 = right + blurX;

    float panel = smoothstep(leftEdge1, leftEdge2, x) * (1.0 - smoothstep(rightEdge1, rightEdge2, x));
    panel *= mix(0.0, panel, smoothstep(0.0, 0.01 / max(u.scale, 1e-6), panelMap));

    // u_edges = false branch
    float midScreen = abs(sinA);
    if (midScreen < 0.07) {
        panel *= (midScreen * 15.0);
    }

    return float2(panel, panelMap);
}

static float4 cpBlendColor(float4 colorA, float panelMask, float panelMap,
                           constant LerpUniforms& u) {
    float fade = 1.0 - smoothstep(0.97 - 0.97 * u.fadeIn, 1.0, panelMap);
    fade *= smoothstep(-0.2 * (1.0 - u.fadeOut), u.fadeOut, panelMap);

    float3 blendedRGB = mix(float3(0.0), colorA.rgb, fade);
    float blendedAlpha = mix(0.0, colorA.a, fade);

    return float4(blendedRGB, blendedAlpha) * panelMask;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[CP_COLOR_COUNT] = {
        u.color1, u.color2, u.color3, u.color4, u.color5, u.color6, u.color7,
    };

    // v_objectUV equivalent: centered, [-0.5, 0.5] short axis, zoomed by scale
    float2 uv = lerpUV(pos, u.resolution) * (0.5 / u.scale);
    uv *= 1.25;

    // original: t = .02 * u_time at demo speed 0.5; seed shifts the phase
    float t = fract(0.02 * (u.speed * u.time + u.seed * 400.0));
    bool reverseTime = (t < 0.5);

    float3 color = float3(0.0);
    float opacity = 0.0;

    float aa = 0.005 / u.scale;
    float invLength = 1.5 / max(u.length, 0.001);
    float panelGrad = 1.0 - clamp(u.gradient, 0.0, 1.0);
    float fPanelsNumber = float(CP_PANELS);

    // The original iterates two "sets" and skips the inactive one; exactly one
    // set runs per frame, chosen by reverseTime.
    int set = reverseTime ? 1 : 0;

    // Forward-rotating panels
    for (int i = 0; i < CP_PANELS; i++) {
        int idx = CP_PANELS - 1 - i;

        float offset = float(idx) / fPanelsNumber;
        if (set == 1) {
            offset += 0.5;
        }

        float densityFract = CP_DENSITY_NORM * fract(t + offset);
        float angleNorm = densityFract / u.density;
        if (densityFract >= 0.5 || angleNorm >= 0.3) continue;

        float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) * clamp(densityFract / 0.01, 0.0, 1.0);
        float smoothAngle = clamp((0.3 - angleNorm) / 0.05, 0.0, 1.0);
        if (smoothDensity * smoothAngle < 0.001) continue;

        if (angleNorm > 0.5) {
            angleNorm = 0.5;
        }
        float2 panel = cpGetPanel(angleNorm * TWO_PI + PI, uv, invLength, aa, u);
        if (panel.x <= 0.001) continue;
        float panelMask = panel.x * smoothDensity * smoothAngle;
        float panelMap = panel.y;

        int colorIdx = idx % CP_COLOR_COUNT;
        int nextColorIdx = (idx + 1) % CP_COLOR_COUNT;

        float4 colorA = colors[colorIdx];
        float4 colorB = colors[nextColorIdx];
        colorA.rgb *= colorA.a;
        colorB.rgb *= colorB.a;

        colorA = mix(colorA, colorB, max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
        float4 blended = cpBlendColor(colorA, panelMask, panelMap, u);
        color = blended.rgb + color * (1.0 - blended.a);
        opacity = blended.a + opacity * (1.0 - blended.a);
    }

    // Backward-rotating panels
    for (int i = 0; i < CP_PANELS; i++) {
        int idx = CP_PANELS - 1 - i;

        float offset = float(idx) / fPanelsNumber;
        if (set == 0) {
            offset += 0.5;
        }

        float densityFract = CP_DENSITY_NORM * fract(-t + offset);
        float angleNorm = -densityFract / u.density;
        if (densityFract >= 0.5 || angleNorm < -0.3) continue;

        float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) * clamp(densityFract / 0.01, 0.0, 1.0);
        float smoothAngle = clamp((angleNorm + 0.3) / 0.05, 0.0, 1.0);
        if (smoothDensity * smoothAngle < 0.001) continue;

        float2 panel = cpGetPanel(angleNorm * TWO_PI + PI, uv, invLength, aa, u);
        float panelMask = panel.x * smoothDensity * smoothAngle;
        if (panelMask <= 0.001) continue;
        float panelMap = panel.y;

        int colorIdx = (CP_COLOR_COUNT - (idx % CP_COLOR_COUNT)) % CP_COLOR_COUNT;
        int nextColorIdx = (colorIdx + 1) % CP_COLOR_COUNT;

        float4 colorA = colors[colorIdx];
        float4 colorB = colors[nextColorIdx];
        colorA.rgb *= colorA.a;
        colorB.rgb *= colorB.a;

        colorA = mix(colorA, colorB, max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
        float4 blended = cpBlendColor(colorA, panelMask, panelMap, u);
        color = blended.rgb + color * (1.0 - blended.a);
        opacity = blended.a + opacity * (1.0 - blended.a);
    }

    color = color + u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
