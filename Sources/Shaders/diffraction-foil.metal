// Diffraction Foil — an artistic, non-spectral approximation: a grooved,
// gently buckled surface carries view-dependent cosine colour bands. Head or
// pointer tracking changes their angle; with no tracker, a slow deterministic
// light drift keeps the saver and stills alive without inventing a head pose.
// lerp-category: Sound & Flow
// lerp-param: speed float 0 2 = 0.35 "Speed"
// lerp-param: parallax float 0 2 = 1.0 "Viewer response"
// lerp-param: grooves float 1 12 = 6.0 "Groove density"
// lerp-param: intensity float 0 2 = 1.0 "Intensity"
// lerp-preset: Satin grooves=3.0, intensity=0.8

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 p = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / min(u.resolution.x, u.resolution.y);
    float t = u.time * u.speed + u.seed * 6.2831853;
    float2 eye = clamp(u.viewer.xy * u.parallax, float2(-1.5), float2(1.5));
    float fold = sin(p.x * 2.3 + 0.55 * sin(p.y * 2.0) + t * 0.15);
    float slope = cos(p.x * 2.3 + 0.55 * sin(p.y * 2.0) + t * 0.15);
    float phase = u.grooves * (0.50 * p.x + 0.16 * fold + 0.10 * p.y) + eye.x * 3.0 + eye.y * 1.5 + 0.35 * sin(t * 0.22);
    float3 rainbow = 0.5 + 0.5 * cos(phase + float3(0.0, 2.094, 4.189));
    float sheen = pow(max(0.0, 0.5 + 0.5 * cos(1.7 * p.y + 1.2 * slope - eye.x * 2.0 + t * 0.12)), 5.0);
    float grooves = 0.75 + 0.25 * cos(35.0 * p.x + 5.0 * fold);
    // Fade subpixel grooves rather than flickering at small gallery sizes.
    grooves = mix(grooves, 0.75, smoothstep(0.6, 2.0, fwidth(35.0 * p.x + 5.0 * fold)));
    float3 col = float3(0.004, 0.006, 0.012) + u.intensity * grooves * (0.05 + 0.85 * sheen) * rainbow;
    col *= exp(-0.24 * dot(p, p));
    return half4(half3(lerpDither(1.0 - exp(-col), pos)), 1.0h);
}
