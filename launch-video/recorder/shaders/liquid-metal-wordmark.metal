// Liquid Metal, image mode: paper-design/shaders' <LiquidMetal image=…> (Apache-2.0)
// https://github.com/paper-design/shaders  packages/shaders/src/shaders/liquid-metal.ts
//
// lerp-data: wordmark
//
// Lerping@Home's built-in liquid-metal.metal ports upstream's procedural
// "metaballs" shape. Upstream's real use is a logo: toProcessedLiquidMetal
// Poisson-solves the silhouette into an edge field (R = 1 at the outline, 0 at
// the deepest interior; G = opacity) and the chrome bands follow that field.
// This file is the image branch of the same shader, fed the Lerping@Home
// wordmark by the launch-video recorder (recorder/RecordMain.swift, WordmarkData).
// Render it at the wordmark's own aspect, so screen UV is image UV.
//
// lerp-param: colorBack  color        = (0.0, 0.0, 0.0) "Background"
// lerp-param: colorTint  color        = (1.0, 1.0, 1.0, 0.7) "Tint"  // neutral: upstream's bluish default burns dark phases navy over the busy grid
// lerp-param: repetition float 1 10   = 3.0  "Repetition"
// lerp-param: softness   float 0 1    = 0.5  "Softness"
// lerp-param: shiftRed   float -1 1   = 0.3  "Shift red"
// lerp-param: shiftBlue  float -1 1   = 0.3  "Shift blue"
// lerp-param: distortion float 0 1    = 0.15 "Distortion"
// lerp-param: contour    float 0 1    = 0.5  "Contour"
// lerp-param: angle      float 0 360  = 70.0 "Angle"
// lerp-param: speed      float 0 4    = 1.0  "Speed"

static float lmColorChanges(float c1, float c2, float stripe_p, float3 w,
                            float blur, float bump, float tint, float tintAlpha) {
    bump = smoothstep(0.2, 0.8, bump); // image mode
    float ch = mix(c2, c1, smoothstep(0.0, 2.0 * blur, stripe_p));

    float border = w.x;
    ch = mix(ch, c2, smoothstep(border, border + 2.0 * blur, stripe_p));

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
    ch = mix(ch, 1.0 - min(1.0, (1.0 - ch) / max(tint, 0.0001)), tintAlpha);
    return ch;
}

static float lmBlurEdge3x3(texture2d<float> tex, float2 uv, float radius, float centerSample) {
    float2 r = radius / float2(tex.get_width(), tex.get_height());
    float sum = 4.0 * centerSample;
    sum += 2.0 * tex.sample(lerpWordmarkSampler, uv + float2(0.0, -r.y)).r;
    sum += 2.0 * tex.sample(lerpWordmarkSampler, uv + float2(0.0,  r.y)).r;
    sum += 2.0 * tex.sample(lerpWordmarkSampler, uv + float2(-r.x, 0.0)).r;
    sum += 2.0 * tex.sample(lerpWordmarkSampler, uv + float2( r.x, 0.0)).r;
    sum += tex.sample(lerpWordmarkSampler, uv + float2(-r.x, -r.y)).r;
    sum += tex.sample(lerpWordmarkSampler, uv + float2( r.x, -r.y)).r;
    sum += tex.sample(lerpWordmarkSampler, uv + float2(-r.x,  r.y)).r;
    sum += tex.sample(lerpWordmarkSampler, uv + float2( r.x,  r.y)).r;
    return sum / 16.0;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        texture2d<float> processed [[texture(1)]]) {
    float t = 0.3 * (u.speed * u.time + u.seed * 120.0 + 2.8);

    float2 uv = lerpScreenUV(pos, u.resolution); // image UV: 0..1, y down
    float4 img = processed.sample(lerpWordmarkSampler, uv);

    float cycleWidth = u.repetition;

    float2 rotatedUV = uv - float2(0.5);
    float rotAngle = (-u.angle + 70.0) * PI / 180.0;
    float cosA = cos(rotAngle);
    float sinA = sin(rotAngle);
    rotatedUV = float2(rotatedUV.x * cosA - rotatedUV.y * sinA,
                       rotatedUV.x * sinA + rotatedUV.y * cosA) + float2(0.5);

    float edge = lmBlurEdge3x3(processed, uv, 6.0, img.r);
    edge = pow(edge, 1.6);
    edge *= smoothstep(0.0, 0.4, u.contour);

    float opacity = img.g;

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

    edge += (1.0 - edge) * u.distortion * noise;

    direction += diagBLtoTR;
    float contour = 0.0;
    direction -= 2.0 * noise * diagBLtoTR * (smoothstep(0.0, 1.0, edge) * (1.0 - smoothstep(0.0, 1.0, edge)));
    direction *= mix(1.0, 1.0 - edge, smoothstep(0.5, 1.0, u.contour));
    direction -= 1.7 * edge * smoothstep(0.5, 1.0, u.contour);
    direction += 0.2 * pow(u.contour, 4.0) * (1.0 - smoothstep(0.0, 1.0, edge));

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

    dispersionRed *= (u.shiftRed / 20.0);
    dispersionBlue *= (u.shiftBlue / 20.0);

    float softness = 0.05 * u.softness;
    float blur = softness + 0.5 * smoothstep(1.0, 10.0, u.repetition) * smoothstep(0.0, 1.0, edge);
    float smallCanvasT = 1.0 - smoothstep(100.0, 500.0, min(u.resolution.x, u.resolution.y));
    blur += smallCanvasT * smoothstep(0.0, 1.0, edge);
    float rExtraBlur = softness * (0.05 + 0.1 * (u.shiftRed / 20.0) * bump);
    float gExtraBlur = softness * 0.05 / max(0.001, abs(1.0 - diagBLtoTR));

    float3 w = float3(thin_strip_1_width, thin_strip_2_width, wide_strip_ratio);
    w.y -= 0.02 * smoothstep(0.0, 1.0, edge + bump);
    float stripe_r = fract(direction + dispersionRed);
    float r = lmColorChanges(color1.r, color2.r, stripe_r, w, blur + fwidth(stripe_r) + rExtraBlur, bump, u.colorTint.r, u.colorTint.a);
    float stripe_g = fract(direction);
    float g = lmColorChanges(color1.g, color2.g, stripe_g, w, blur + fwidth(stripe_g) + gExtraBlur, bump, u.colorTint.g, u.colorTint.a);
    float stripe_b = fract(direction - dispersionBlue);
    float b = lmColorChanges(color1.b, color2.b, stripe_b, w, blur + fwidth(stripe_b), bump, u.colorTint.b, u.colorTint.a);

    float3 color = float3(r, g, b);
    color *= opacity;

    color = color + u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
