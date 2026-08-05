// Gem Smoke — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original places smoky color fields behind an uploaded glassy logo
// shape; this port uses the shader's built-in procedural "diamond" shape
// mode instead. Palette is a dark ice variant of the demo's Fire preset.

// Parameters mirror the upstream <GemSmoke> props. Upstream's `shape` enum is
// not ported — this file is always the "diamond" shape. Upstream takes a
// variable-length `colors` array (max 6); this port fixes three tunable slots.
//
// lerp-param: color1          color        = (0.290, 0.180, 0.760, 1.0) "Outer smoke"
// lerp-param: color2          color        = (0.220, 0.620, 1.000, 1.0) "Azure"
// lerp-param: color3          color        = (0.910, 0.965, 1.000, 1.0) "Ice white core"
// lerp-param: colorBack       color        = (0.010, 0.012, 0.024, 1.0) "Background"
// lerp-param: colorInner      color        = (0.030, 0.036, 0.062, 1.0) "Gem body"
// lerp-param: scale           float 0.1 4  = 0.6  "Scale"
// lerp-param: innerDistortion float 0 1    = 0.8  "Inner distortion"
// lerp-param: outerDistortion float 0 1    = 0.6  "Outer distortion"
// lerp-param: outerGlow       float 0 1    = 0.75 "Outer glow"
// lerp-param: innerGlow       float 0 1    = 1.0  "Inner glow"
// lerp-param: offset          float -1 1   = 0.0  "Offset"
// lerp-param: angle           float 0 360  = 0.0  "Angle"
// lerp-param: size            float 0.1 1  = 0.8  "Size"
// lerp-param: speed           float 0 4    = 0.4  "Speed"
//
// Upstream presets, speed scaled to this port's ambience (upstream × 0.4).
// lerp-preset: Fire        colorBack=#000000, colorInner=#000000, color1=#fe5b16
// lerp-preset: Fire        color2=#f7ff61, color3=#ffffff, outerGlow=1, innerGlow=0.65
// lerp-preset: Fire        innerDistortion=0.6, outerDistortion=0.8, offset=0, angle=0
// lerp-preset: Fire        size=0.8, speed=0.4, scale=0.6
// lerp-preset: Fluorescent colorBack=#000000, colorInner=#000000, color1=#2fb64c
// lerp-preset: Fluorescent color2=#cdff61, color3=#ffffff, outerGlow=0, innerGlow=1
// lerp-preset: Fluorescent innerDistortion=1, outerDistortion=0.8, offset=0, angle=0
// lerp-preset: Fluorescent size=0.8, speed=0.4, scale=0.6
// lerp-preset: Infrared    colorBack=#cd28dc, colorInner=#00000000, color1=#ff9900
// lerp-preset: Infrared    color2=#fff67a, color3=#0077ff, outerGlow=1, innerGlow=1
// lerp-preset: Infrared    innerDistortion=1, outerDistortion=1, offset=0.2, angle=0
// lerp-preset: Infrared    size=1, speed=0.2, scale=0.6

constant int GS_COLOR_COUNT = 3;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float4 colors[GS_COLOR_COUNT] = { u.color1, u.color2, u.color3 };

    float time = u.speed * u.time + u.seed * 80.0;

    // v_objectUV equivalent: centered, [-0.5, 0.5] short axis, zoomed by scale
    float2 objUV = lerpUV(pos, u.resolution) * (0.5 / u.scale);

    float roundness = 0.0;
    float imgAlpha = 0.0;

    // u_isImage == false, shape: diamond
    {
        float2 uv = objUV + 0.5;
        uv.y = 1.0 - uv.y;

        float2 shapeUV = uv - 0.5;
        shapeUV = rotate(shapeUV, 0.25 * PI);
        shapeUV *= 1.42;
        shapeUV += 0.5;
        float2 mask = min(shapeUV, 1.0 - shapeUV);
        float2 pixel_thickness = float2(0.15);
        float maskX = smoothstep(0.0, pixel_thickness.x, mask.x);
        float maskY = smoothstep(0.0, pixel_thickness.y, mask.y);
        maskX = pow(maskX, 0.25);
        maskY = pow(maskY, 0.25);
        float edge = clamp(1.0 - maskX * maskY, 0.0, 1.0);

        imgAlpha = 1.0 - smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge);
        roundness = 1.0 - edge;
    }

    // Smoke UV setup
    float2 smokeUV = objUV;
    smokeUV = rotate(smokeUV, u.angle * PI / 180.0);
    smokeUV *= mix(4.0, 1.0, u.size);

    // Two swirl paths: inner (shape-masked) and outer (free)
    float2 innerUV = smokeUV;
    float2 outerUV = smokeUV;

    innerUV.y += u.innerDistortion * (1.0 - smoothstep(0.0, 1.0, length(0.4 * innerUV)));
    innerUV.y -= 0.4 * u.innerDistortion;
    innerUV.y += 0.7 * u.offset * roundness;

    outerUV.y += u.outerDistortion * (1.0 - smoothstep(0.0, 1.0, length(0.4 * outerUV)));
    outerUV.y -= 0.4 * u.outerDistortion;

    float innerSwirl = u.innerDistortion * roundness;
    float outerSwirl = u.outerDistortion;

    for (int i = 1; i < 5; i++) {
        float fi = float(i);

        float stretchIn = max(length(dfdx(innerUV)), length(dfdy(innerUV)));
        float dampenIn = 1.0 / (1.0 + stretchIn * 8.0);
        float sIn = innerSwirl * dampenIn;
        innerUV.x += sIn / fi * cos(time + fi * 2.9 * innerUV.y);
        innerUV.y += sIn / fi * cos(time + fi * 1.5 * innerUV.x);

        float stretchOut = max(length(dfdx(outerUV)), length(dfdy(outerUV)));
        float dampenOut = 1.0 / (1.0 + stretchOut * 8.0);
        float sOut = outerSwirl * dampenOut;
        outerUV.x += sOut / fi * cos(time + fi * 2.9 * outerUV.y);
        outerUV.y += sOut / fi * cos(time + fi * 1.5 * outerUV.x);
    }

    // Smoke shapes from swirl fields
    float innerShape = exp(-1.5 * dot(innerUV, innerUV));
    float outerShape = exp(-1.5 * dot(outerUV, outerUV));

    // Visibility masks
    float outerMask = pow(u.outerGlow, 2.0) * (1.0 - imgAlpha);
    float innerMask = (0.01 + 0.99 * u.innerGlow) * imgAlpha;

    innerShape *= innerMask;
    outerShape *= outerMask;

    // Color gradient
    float mixer = (innerShape + outerShape) * float(GS_COLOR_COUNT);
    float4 gradient = colors[0];
    gradient.rgb *= gradient.a;

    float smokeMask = 0.0;
    for (int i = 1; i <= GS_COLOR_COUNT; i++) {
        float m = smoothstep(0.0, 1.0, clamp(mixer - float(i - 1), 0.0, 1.0));
        if (i == 1) smokeMask = m;

        float4 c = colors[i - 1];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    // Compositing (premultiplied alpha, front-to-back)
    float3 color = gradient.rgb * smokeMask;
    float opacity = gradient.a * smokeMask;

    float innerOpacity = u.colorInner.a * imgAlpha;
    float3 innerColor = u.colorInner.rgb * innerOpacity;
    color += innerColor * (1.0 - opacity);
    opacity += innerOpacity * (1.0 - opacity);

    float3 backColor = u.colorBack.rgb * u.colorBack.a;
    color += backColor * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
