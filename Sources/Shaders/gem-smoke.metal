// Gem Smoke — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original places smoky color fields behind an uploaded glassy logo
// shape; this port uses the shader's built-in procedural "diamond" shape
// mode instead. Palette is a dark ice variant of the demo's Fire preset.

constant int    GS_COLOR_COUNT = 3;
constant float4 GS_COLORS[GS_COLOR_COUNT] = {
    float4(0.290, 0.180, 0.760, 1.0), // deep violet (outer smoke)
    float4(0.220, 0.620, 1.000, 1.0), // azure
    float4(0.910, 0.965, 1.000, 1.0), // ice white core
};
constant float4 GS_COLOR_BACK  = float4(0.010, 0.012, 0.024, 1.0); // near-black navy
constant float4 GS_COLOR_INNER = float4(0.030, 0.036, 0.062, 1.0); // gem body, slightly lifted

constant float GS_SCALE            = 0.6;
constant float GS_INNER_DISTORTION = 0.8;
constant float GS_OUTER_DISTORTION = 0.6;
constant float GS_OUTER_GLOW       = 0.75;
constant float GS_INNER_GLOW       = 1.0;
constant float GS_OFFSET           = 0.0;
constant float GS_ANGLE            = 0.0;
constant float GS_SIZE             = 0.8;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float time = 0.4 * u.time + u.seed * 80.0;

    // v_objectUV equivalent: centered, [-0.5, 0.5] short axis, zoomed by scale
    float2 objUV = lerpUV(pos, u.resolution) * (0.5 / GS_SCALE);

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
    smokeUV = rotate(smokeUV, GS_ANGLE * PI / 180.0);
    smokeUV *= mix(4.0, 1.0, GS_SIZE);

    // Two swirl paths: inner (shape-masked) and outer (free)
    float2 innerUV = smokeUV;
    float2 outerUV = smokeUV;

    innerUV.y += GS_INNER_DISTORTION * (1.0 - smoothstep(0.0, 1.0, length(0.4 * innerUV)));
    innerUV.y -= 0.4 * GS_INNER_DISTORTION;
    innerUV.y += 0.7 * GS_OFFSET * roundness;

    outerUV.y += GS_OUTER_DISTORTION * (1.0 - smoothstep(0.0, 1.0, length(0.4 * outerUV)));
    outerUV.y -= 0.4 * GS_OUTER_DISTORTION;

    float innerSwirl = GS_INNER_DISTORTION * roundness;
    float outerSwirl = GS_OUTER_DISTORTION;

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
    float outerMask = pow(GS_OUTER_GLOW, 2.0) * (1.0 - imgAlpha);
    float innerMask = (0.01 + 0.99 * GS_INNER_GLOW) * imgAlpha;

    innerShape *= innerMask;
    outerShape *= outerMask;

    // Color gradient
    float mixer = (innerShape + outerShape) * float(GS_COLOR_COUNT);
    float4 gradient = GS_COLORS[0];
    gradient.rgb *= gradient.a;

    float smokeMask = 0.0;
    for (int i = 1; i <= GS_COLOR_COUNT; i++) {
        float m = smoothstep(0.0, 1.0, clamp(mixer - float(i - 1), 0.0, 1.0));
        if (i == 1) smokeMask = m;

        float4 c = GS_COLORS[i - 1];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    // Compositing (premultiplied alpha, front-to-back)
    float3 color = gradient.rgb * smokeMask;
    float opacity = gradient.a * smokeMask;

    float innerOpacity = GS_COLOR_INNER.a * imgAlpha;
    float3 innerColor = GS_COLOR_INNER.rgb * innerOpacity;
    color += innerColor * (1.0 - opacity);
    opacity += innerOpacity * (1.0 - opacity);

    float3 backColor = GS_COLOR_BACK.rgb * GS_COLOR_BACK.a;
    color += backColor * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
