// Spiral — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders

constant float3 SP_COLOR_BACK  = float3(0.000, 0.078, 0.161); // deep navy  #001429
constant float3 SP_COLOR_FRONT = float3(0.435, 0.765, 0.949); // soft ice blue

constant float SP_SCALE        = 5.5;  // ~7 visible turns at 1200x750
constant float SP_DENSITY      = 0.80;
constant float SP_DISTORTION   = 0.15;
constant float SP_STROKE_WIDTH = 0.32;
constant float SP_STROKE_TAPER = 0.0;
constant float SP_STROKE_CAP   = 0.0;
constant float SP_NOISE        = 0.4;
constant float SP_NOISE_FREQ   = 0.35;
constant float SP_SOFTNESS     = 0.12;

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution) * SP_SCALE;

    float t = 0.3 * u.time + 60.0 * u.seed;

    float l = length(uv);
    float density = clamp(SP_DENSITY, 0.0, 1.0);
    l = pow(max(l, 1e-6), density);
    float angle = atan2(uv.y, uv.x) - t;
    float angleNorm = angle / TWO_PI;

    angleNorm += 0.125 * SP_NOISE *
        snoise(16.0 * SP_NOISE_FREQ * SP_NOISE_FREQ * SP_NOISE_FREQ * uv);

    float offset = l + angleNorm;
    offset -= SP_DISTORTION * (sin(4.0 * l - 0.5 * t) * cos(PI + l + 0.5 * t));
    float stripe = fract(offset);

    float shape = 2.0 * abs(stripe - 0.5);
    float width = 1.0 - clamp(SP_STROKE_WIDTH, 0.005 * SP_STROKE_TAPER, 1.0);

    float wCap = mix(width, (1.0 - stripe) * (1.0 - step(0.5, stripe)), 1.0 - clamp(l, 0.0, 1.0));
    width = mix(width, wCap, SP_STROKE_CAP);
    width *= (1.0 - clamp(SP_STROKE_TAPER, 0.0, 1.0) * l);

    float fw = fwidth(offset);
    float fwMult = 4.0 - 3.0 * (smoothstep(0.05, 0.4, 2.0 * SP_STROKE_WIDTH) *
                                smoothstep(0.05, 0.4, 2.0 * (1.0 - SP_STROKE_WIDTH)));
    float pixelSize = mix(fwMult * fw, fwidth(shape), clamp(fw, 0.0, 1.0));
    pixelSize = mix(pixelSize, 0.002, SP_STROKE_CAP * (1.0 - clamp(l, 0.0, 1.0)));

    float res = smoothstep(width - pixelSize - SP_SOFTNESS,
                           width + pixelSize + SP_SOFTNESS, shape);

    float3 color = SP_COLOR_FRONT * res;
    float opacity = res;
    color += SP_COLOR_BACK * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
