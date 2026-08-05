// Color Panels — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// Pseudo-3D semi-transparent panels rotating around a central axis.
// Palette follows the paper.design demo defaults (7 colors on black).

constant int    CP_COLOR_COUNT = 7;
constant float4 CP_COLORS[CP_COLOR_COUNT] = {
    float4(1.000, 0.616, 0.000, 1.0), // #ff9d00 amber
    float4(0.992, 0.310, 0.188, 1.0), // #fd4f30 coral
    float4(0.502, 0.608, 1.000, 1.0), // #809bff periwinkle
    float4(0.427, 0.180, 1.000, 1.0), // #6d2eff violet
    float4(0.200, 0.227, 1.000, 1.0), // #333aff ultramarine
    float4(0.945, 0.361, 1.000, 1.0), // #f15cff orchid
    float4(1.000, 0.835, 0.341, 1.0), // #ffd557 gold
};
constant float3 CP_BACKGROUND = float3(0.004, 0.004, 0.010); // near-black

constant float CP_SCALE    = 1.0;
constant float CP_DENSITY  = 3.0;
constant float CP_ANGLE1   = 0.0;
constant float CP_ANGLE2   = 0.0;
constant float CP_LENGTH   = 1.5;
constant float CP_BLUR     = 0.0;
constant float CP_FADE_IN  = 1.0;
constant float CP_FADE_OUT = 0.3;
constant float CP_GRADIENT = 0.0;
constant float CP_Z_LIMIT  = 0.5;

// 7 colors -> 14 panels, density normalizer 1.17 (from the original's table)
constant int   CP_PANELS       = 14;
constant float CP_DENSITY_NORM = 1.17;

static float2 cpGetPanel(float angle, float2 uv, float invLength, float aa) {
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
    float left  = -0.5 + zOffset * CP_ANGLE1;
    float right =  0.5 - zOffset * CP_ANGLE2;
    float blurX = aa + 2.0 * panelMap * CP_BLUR;

    float leftEdge1  = left - blurX;
    float leftEdge2  = left + 0.25 * blurX;
    float rightEdge1 = right - 0.25 * blurX;
    float rightEdge2 = right + blurX;

    float panel = smoothstep(leftEdge1, leftEdge2, x) * (1.0 - smoothstep(rightEdge1, rightEdge2, x));
    panel *= mix(0.0, panel, smoothstep(0.0, 0.01 / max(CP_SCALE, 1e-6), panelMap));

    // u_edges = false branch
    float midScreen = abs(sinA);
    if (midScreen < 0.07) {
        panel *= (midScreen * 15.0);
    }

    return float2(panel, panelMap);
}

static float4 cpBlendColor(float4 colorA, float panelMask, float panelMap) {
    float fade = 1.0 - smoothstep(0.97 - 0.97 * CP_FADE_IN, 1.0, panelMap);
    fade *= smoothstep(-0.2 * (1.0 - CP_FADE_OUT), CP_FADE_OUT, panelMap);

    float3 blendedRGB = mix(float3(0.0), colorA.rgb, fade);
    float blendedAlpha = mix(0.0, colorA.a, fade);

    return float4(blendedRGB, blendedAlpha) * panelMask;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // v_objectUV equivalent: centered, [-0.5, 0.5] short axis, zoomed by scale
    float2 uv = lerpUV(pos, u.resolution) * (0.5 / CP_SCALE);
    uv *= 1.25;

    // original: t = .02 * u_time at demo speed 0.5; seed shifts the phase
    float t = fract(0.02 * (0.5 * u.time + u.seed * 400.0));
    bool reverseTime = (t < 0.5);

    float3 color = float3(0.0);
    float opacity = 0.0;

    float aa = 0.005 / CP_SCALE;
    float invLength = 1.5 / max(CP_LENGTH, 0.001);
    float panelGrad = 1.0 - clamp(CP_GRADIENT, 0.0, 1.0);
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
        float angleNorm = densityFract / CP_DENSITY;
        if (densityFract >= 0.5 || angleNorm >= 0.3) continue;

        float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) * clamp(densityFract / 0.01, 0.0, 1.0);
        float smoothAngle = clamp((0.3 - angleNorm) / 0.05, 0.0, 1.0);
        if (smoothDensity * smoothAngle < 0.001) continue;

        if (angleNorm > 0.5) {
            angleNorm = 0.5;
        }
        float2 panel = cpGetPanel(angleNorm * TWO_PI + PI, uv, invLength, aa);
        if (panel.x <= 0.001) continue;
        float panelMask = panel.x * smoothDensity * smoothAngle;
        float panelMap = panel.y;

        int colorIdx = idx % CP_COLOR_COUNT;
        int nextColorIdx = (idx + 1) % CP_COLOR_COUNT;

        float4 colorA = CP_COLORS[colorIdx];
        float4 colorB = CP_COLORS[nextColorIdx];
        colorA.rgb *= colorA.a;
        colorB.rgb *= colorB.a;

        colorA = mix(colorA, colorB, max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
        float4 blended = cpBlendColor(colorA, panelMask, panelMap);
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
        float angleNorm = -densityFract / CP_DENSITY;
        if (densityFract >= 0.5 || angleNorm < -0.3) continue;

        float smoothDensity = clamp((0.5 - densityFract) / 0.1, 0.0, 1.0) * clamp(densityFract / 0.01, 0.0, 1.0);
        float smoothAngle = clamp((angleNorm + 0.3) / 0.05, 0.0, 1.0);
        if (smoothDensity * smoothAngle < 0.001) continue;

        float2 panel = cpGetPanel(angleNorm * TWO_PI + PI, uv, invLength, aa);
        float panelMask = panel.x * smoothDensity * smoothAngle;
        if (panelMask <= 0.001) continue;
        float panelMap = panel.y;

        int colorIdx = (CP_COLOR_COUNT - (idx % CP_COLOR_COUNT)) % CP_COLOR_COUNT;
        int nextColorIdx = (colorIdx + 1) % CP_COLOR_COUNT;

        float4 colorA = CP_COLORS[colorIdx];
        float4 colorB = CP_COLORS[nextColorIdx];
        colorA.rgb *= colorA.a;
        colorB.rgb *= colorB.a;

        colorA = mix(colorA, colorB, max(0.0, smoothstep(0.0, 0.45, panelMap) - panelGrad));
        float4 blended = cpBlendColor(colorA, panelMask, panelMap);
        color = blended.rgb + color * (1.0 - blended.a);
        opacity = blended.a + opacity * (1.0 - blended.a);
    }

    color = color + CP_BACKGROUND * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
