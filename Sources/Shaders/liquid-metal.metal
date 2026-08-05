// Liquid Metal — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
// The original masks the effect with a pre-processed logo image; this port
// uses the shader's built-in procedural "metaballs" shape mode instead, so a
// liquid chrome blob drifts on a dark background.

constant float3 LM_BACKGROUND = float3(0.016, 0.018, 0.024); // near-black blue
constant float4 LM_TINT = float4(0.55, 0.62, 0.70, 0.7);     // steel-blue color burn

constant float LM_SCALE      = 0.9;
constant float LM_REPETITION = 3.0;
constant float LM_SOFTNESS   = 0.5;
constant float LM_SHIFT_RED  = 0.3;
constant float LM_SHIFT_BLUE = 0.3;
constant float LM_DISTORTION = 0.15;
constant float LM_CONTOUR    = 0.5;
constant float LM_ANGLE      = 70.0;

static float lmColorChanges(float c1, float c2, float stripe_p, float3 w,
                            float blur, float bump, float tint) {
    float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, stripe_p));

    float border = w.x;
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    // u_isImage == false: no bump remap
    border = w.x + 0.4 * (1.0 - bump) * w.y;
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w.x + 0.5 * (1.0 - bump) * w.y;
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

    border = w.x + w.y;
    ch = mix(ch, c1, smoothstep(border, border + 2.0 * blur, stripe_p));

    float gradient_t = (stripe_p - w.x - w.y) / w.z;
    float gradient = mix(c1, c2, smoothstep(0.0, 1.0, gradient_t));
    ch = mix(ch, gradient, smoothstep(border, border + 0.5 * blur, stripe_p));

    // Tint applied with color-burn blending
    ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), LM_TINT.a);
    return ch;
}

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    // original: t = .3 * (u_time + 2.8); slowed + seeded for screensaver use
    float t = 0.3 * (0.5 * u.time + u.seed * 120.0 + 2.8);

    // v_objectUV equivalent -> 0..1 uv with y down (CSS-like)
    float2 objUV = lerpUV(pos, u.resolution) * (0.5 / LM_SCALE);
    float2 uv = objUV + 0.5;
    uv.y = 1.0 - uv.y;

    float cycleWidth = LM_REPETITION;
    float edge = 0.0;

    float2 rotatedUV = uv - float2(0.5);
    float rotAngle = (-LM_ANGLE + 70.0) * PI / 180.0;
    float cosA = cos(rotAngle);
    float sinA = sin(rotAngle);
    rotatedUV = float2(rotatedUV.x * cosA - rotatedUV.y * sinA,
                       rotatedUV.x * sinA + rotatedUV.y * cosA) + float2(0.5);

    // shape: metaballs
    {
        float2 shapeUV = uv - 0.5;
        shapeUV *= 1.3;
        edge = 0.0;
        for (int i = 0; i < 5; i++) {
            float fi = float(i);
            float speed = 1.5 + 2.0 / 3.0 * sin(fi * 12.345);
            float ballAngle = -fi * 1.5;
            float2 dir1 = float2(cos(ballAngle), sin(ballAngle));
            float2 dir2 = float2(cos(ballAngle + 1.57), sin(ballAngle + 1.0));
            float2 traj = 0.4 * (dir1 * sin(t * speed + fi * 1.23) + dir2 * cos(t * (speed * 0.7) + fi * 2.17));
            float d = length(shapeUV + traj);
            edge += pow(1.0 - clamp(d, 0.0, 1.0), 4.0);
        }
        edge = 1.0 - smoothstep(0.65, 0.9, edge);
        edge = pow(edge, 4.0);
    }

    edge = mix(smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge), edge, smoothstep(0.0, 0.4, LM_CONTOUR));

    float opacity = 1.0 - smoothstep(0.9 - 2.0 * fwidth(edge), 0.9, edge);
    edge = 1.8 * pow(edge, 1.5); // metaballs shape

    float diagBLtoTR = rotatedUV.x - rotatedUV.y;
    float diagTLtoBR = rotatedUV.x + rotatedUV.y;

    float3 color1 = float3(0.98, 0.98, 1.0);
    float3 color2 = float3(0.1, 0.1, 0.1 + 0.1 * smoothstep(0.7, 1.3, diagTLtoBR));

    float2 grad_uv = uv - 0.5;

    float dist = length(grad_uv + float2(0.0, 0.2 * diagBLtoTR));
    grad_uv = rotate(grad_uv, (0.25 - 0.2 * diagBLtoTR) * PI);
    float direction = grad_uv.x;

    float bump = pow(1.8 * dist, 1.2);
    bump = 1.0 - bump;
    bump *= pow(max(uv.y, 0.0), 0.3); // guarded: uv.y can go negative offscreen

    float thin_strip_1_ratio = 0.12 / cycleWidth * (1.0 - 0.4 * bump);
    float thin_strip_2_ratio = 0.07 / cycleWidth * (1.0 + 0.4 * bump);
    float wide_strip_ratio = (1.0 - thin_strip_1_ratio - thin_strip_2_ratio);

    float thin_strip_1_width = cycleWidth * thin_strip_1_ratio;
    float thin_strip_2_width = cycleWidth * thin_strip_2_ratio;

    float noise = snoise(uv - t);

    edge += (1.0 - edge) * LM_DISTORTION * noise;

    direction += diagBLtoTR;
    float contour = 0.0;
    direction -= 2.0 * noise * diagBLtoTR * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
    direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, LM_CONTOUR));
    direction -= 1.7 * edge * smoothstep(0.5, 1.0, LM_CONTOUR);
    direction += 0.2 * pow(LM_CONTOUR, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));

    bump *= clamp(pow(max(uv.y, 0.0), 0.1), 0.3, 1.0);
    direction *= (0.1 + (1.1 - edge) * bump);

    direction *= (0.4 + 0.6 * (1.0 - smoothstep(0.5, 1.0, edge)));
    direction += 0.18 * (smoothstep(0.1, 0.2, uv.y) * (1.0 - smoothstep(0.2, 0.4, uv.y)));
    direction += 0.03 * (smoothstep(0.1, 0.2, 1.0 - uv.y) * (1.0 - smoothstep(0.2, 0.4, 1.0 - uv.y)));

    direction *= (0.5 + 0.5 * pow(uv.y, 2.0));
    direction *= cycleWidth;
    direction -= t;

    float colorDispersion = clamp(1.0 - bump, 0.0, 1.0);
    float dispersionRed = colorDispersion;
    dispersionRed += 0.03 * bump * noise;
    dispersionRed += 5.0 * (smoothstep(-0.1, 0.2, uv.y) * (1.0 - smoothstep(0.1, 0.5, uv.y)))
                         * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 1.0, bump)));
    dispersionRed -= diagBLtoTR;

    float dispersionBlue = colorDispersion * 1.3;
    dispersionBlue += (smoothstep(0.0, 0.4, uv.y) * (1.0 - smoothstep(0.1, 0.8, uv.y)))
                    * (smoothstep(0.4, 0.6, bump) * (1.0 - smoothstep(0.4, 0.8, bump)));
    dispersionBlue -= 0.2 * edge;

    dispersionRed *= (LM_SHIFT_RED / 20.0);
    dispersionBlue *= (LM_SHIFT_BLUE / 20.0);

    float blur = LM_SOFTNESS / 15.0 + 0.3 * contour;

    float3 w = float3(thin_strip_1_width, thin_strip_2_width, wide_strip_ratio);
    w.y -= 0.02 * smoothstep(0.0, 1.0, edge + bump);
    float stripe_r = fract(direction + dispersionRed);
    float r = lmColorChanges(color1.r, color2.r, stripe_r, w, blur + fwidth(stripe_r), bump, LM_TINT.r);
    float stripe_g = fract(direction);
    float g = lmColorChanges(color1.g, color2.g, stripe_g, w, blur + fwidth(stripe_g), bump, LM_TINT.g);
    float stripe_b = fract(direction - dispersionBlue);
    float b = lmColorChanges(color1.b, color2.b, stripe_b, w, blur + fwidth(stripe_b), bump, LM_TINT.b);

    float3 color = float3(r, g, b);
    color *= opacity;

    color = color + LM_BACKGROUND * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
