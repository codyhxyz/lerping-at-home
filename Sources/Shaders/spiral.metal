// Spiral — ported from paper-design/shaders (Apache-2.0)
// https://github.com/paper-design/shaders
//
// Parameters mirror the upstream <Spiral> props. `scale` is in this port's own
// units (upstream's scale is part of a sizing system this project doesn't
// have); everything else matches upstream's ranges. Defaults are this port's
// screensaver tuning, not upstream's — see the presets for upstream's looks.
//
// lerp-param: colorBack      color       = (0.000, 0.078, 0.161) "Background"
// lerp-param: colorFront     color       = (0.435, 0.765, 0.949) "Stroke"
// lerp-param: scale          float 0.5 16 = 5.5  "Scale"
// lerp-param: density        float 0 1   = 0.8   "Density"
// lerp-param: distortion     float 0 1   = 0.15  "Distortion"
// lerp-param: strokeWidth    float 0 1   = 0.32  "Stroke width"
// lerp-param: strokeTaper    float 0 1   = 0.0   "Stroke taper"
// lerp-param: strokeCap      float 0 1   = 0.0   "Stroke cap"
// lerp-param: noise          float 0 1   = 0.4   "Noise"
// lerp-param: noiseFrequency float 0 1   = 0.35  "Noise frequency"
// lerp-param: softness       float 0 1   = 0.12  "Softness"
// lerp-param: speed          float 0 2   = 0.3   "Speed"
//
// Upstream presets, with speed and scale mapped into this port's units.
// lerp-preset: Jungle  colorBack=#a0ef2a, colorFront=#288b18, scale=7.15, speed=0.225
// lerp-preset: Jungle  density=0.5, distortion=0, strokeWidth=0.5, strokeTaper=0, strokeCap=0
// lerp-preset: Jungle  noise=1, noiseFrequency=0.25, softness=0
// lerp-preset: Droplet colorBack=#effafe, colorFront=#bf40a0, density=0.9, speed=0.3
// lerp-preset: Droplet distortion=0, strokeWidth=0.75, strokeTaper=0.18, strokeCap=1
// lerp-preset: Droplet noise=0.74, noiseFrequency=0.33, softness=0.02
// lerp-preset: Swirl   colorBack=#b3e6d9, colorFront=#1a2b4d, scale=2.475, speed=0.3
// lerp-preset: Swirl   density=0.2, distortion=0, strokeWidth=0.5, strokeTaper=0, strokeCap=0
// lerp-preset: Swirl   noise=0, noiseFrequency=0.3, softness=0.5

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution) * u.scale;

    float t = u.speed * u.time + 60.0 * u.seed;

    float l = length(uv);
    float density = clamp(u.density, 0.0, 1.0);
    l = pow(max(l, 1e-6), density);
    float angle = atan2(uv.y, uv.x) - t;
    float angleNorm = angle / TWO_PI;

    angleNorm += 0.125 * u.noise *
        snoise(16.0 * u.noiseFrequency * u.noiseFrequency * u.noiseFrequency * uv);

    float offset = l + angleNorm;
    offset -= u.distortion * (sin(4.0 * l - 0.5 * t) * cos(PI + l + 0.5 * t));
    float stripe = fract(offset);

    float shape = 2.0 * abs(stripe - 0.5);
    float width = 1.0 - clamp(u.strokeWidth, 0.005 * u.strokeTaper, 1.0);

    float wCap = mix(width, (1.0 - stripe) * (1.0 - step(0.5, stripe)), 1.0 - clamp(l, 0.0, 1.0));
    width = mix(width, wCap, u.strokeCap);
    width *= (1.0 - clamp(u.strokeTaper, 0.0, 1.0) * l);

    float fw = fwidth(offset);
    float fwMult = 4.0 - 3.0 * (smoothstep(0.05, 0.4, 2.0 * u.strokeWidth) *
                                smoothstep(0.05, 0.4, 2.0 * (1.0 - u.strokeWidth)));
    float pixelSize = mix(fwMult * fw, fwidth(shape), clamp(fw, 0.0, 1.0));
    pixelSize = mix(pixelSize, 0.002, u.strokeCap * (1.0 - clamp(l, 0.0, 1.0)));

    float res = smoothstep(width - pixelSize - u.softness,
                           width + pixelSize + u.softness, shape);

    float3 color = u.colorFront.rgb * res;
    float opacity = res;
    color += u.colorBack.rgb * (1.0 - opacity);

    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
