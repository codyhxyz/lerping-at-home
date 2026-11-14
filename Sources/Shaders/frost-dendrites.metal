// Frost dendrites — a stylized hex-lattice diffusion/deposition toy, not a
// physically validated snow-crystal model. See FrostData for the source and
// departures. Bounded epochs make stills independent of playback history.
// lerp-category: Simulations
// lerp-data: frost
// lerp-param: speed float 0 8 = 2 "Growth speed"
// lerp-param: colorBack color = #081c2b "Glass"
// lerp-param: colorIce color = #c8eeff "Ice"
// lerp-preset: Blue speed=2
// lerp-preset: Midnight colorBack=#080d22, colorIce=#b8caff

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        constant LerpFrostFrame& f [[buffer(1)]], texture2d<float> grid [[texture(1)]]) {
    float2 uv = pos.xy / u.resolution;
    float3 back = u.colorBack.rgb * (0.7 + 0.4 * uv.y);
    if (f.ready == 0u) return half4(half3(lerpDither(back, pos)), 1.0h);
    float2 size = float2(grid.get_width(), grid.get_height());
    // Axial coordinates: x and y lattice axes meet at 60 degrees.
    // The axial y coordinate is 2/sqrt(3) times screen y. Leave a
    // small border so the entire screen, including the linear-filter taps,
    // stays inside the simulation texture.
    float2 xy = (pos.xy - 0.5 * u.resolution) * (0.85 * size.y / u.resolution.y);
    float2 axial = float2(xy.x - xy.y * 0.57735, xy.y * 1.1547) + size * 0.5;
    constexpr sampler s(coord::normalized, address::clamp_to_zero, filter::linear);
    float ice = grid.sample(s, axial / size).r;
    float body = smoothstep(0.08, 0.65, ice);
    float glint = pow(saturate(ice), 3.0);
    float3 color = back + u.colorIce.rgb * (0.6 * body + 0.35 * glint) * f.fade;
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
