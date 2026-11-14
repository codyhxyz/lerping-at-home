// Laser Interferometer — artistic interference rings, not a physical optical
// simulation. Two drifting path-length fields create fine fringes inside a
// softly bounded beam, with a subdued red instrument-room background.
// lerp-category: Abstract
// lerp-param: speed float 0 2 = 0.35 "Speed"
// lerp-param: density float 2 35 = 16 "Fringe density"
// lerp-param: intensity float 0 2 = 1 "Intensity"
// lerp-preset: Wide density=8, speed=0.2

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 p = (2.0 * float2(pos.x, u.resolution.y - pos.y) - u.resolution) / min(u.resolution.x, u.resolution.y);
    float t = u.time * u.speed + u.seed * 6.2831853;
    float2 center = float2(0.12 * sin(t * 0.25), 0.10 * cos(t * 0.19));
    float2 q = p - center;
    float phase = u.density * (dot(q, q) + 0.35 * q.x + 0.10 * sin(2.0 * q.y + t * 0.3)) + t * 0.4;
    float fringe = 0.5 + 0.5 * cos(phase);
    fringe = mix(fringe, 0.5, smoothstep(0.8, 3.0, fwidth(phase)));
    float beam = exp(-2.2 * dot(q, q));
    float3 col = float3(0.006, 0.002, 0.004) + u.intensity * beam * (0.03 + 0.8 * pow(fringe, 3.0)) * float3(1.0, 0.085, 0.035);
    return half4(half3(lerpDither(1.0 - exp(-col), pos)), 1.0h);
}
