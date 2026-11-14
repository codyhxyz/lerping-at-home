// Ferrofluid — a stylized damped-wave heightfield with seeded magnetic forcing,
// not a physically accurate Rosensweig-instability simulation. See FerrofluidData.
// lerp-category: Simulations
// lerp-data: ferrofluid
// lerp-param: speed float 0 4 = 1 "Motion speed"
// lerp-param: parallax float 0 2 = 1 "Head parallax"
// lerp-param: colorBack color = #080d16 "Background"
// lerp-param: colorMetal color = #8fb8cf "Metal"
// lerp-preset: Cobalt colorMetal=#719dff
// lerp-preset: Copper colorMetal=#e6a66c

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        constant LerpFerroFrame& f [[buffer(1)]], texture2d<float> grid [[texture(1)]]) {
    float2 uv = pos.xy / u.resolution;
    float3 back = u.colorBack.rgb;
    if (f.ready == 0u) return half4(half3(lerpDither(back, pos)), 1.0h);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = 1.0 / float2(grid.get_width(), grid.get_height());
    // Viewer shifts only the sampled displaced surface, never its state.
    float h0 = max(0.0, grid.sample(s, uv).r);
    // A shallow oblique projection lifts the tips toward the top of the image.
    uv.y += h0 * 0.035;
    uv += float2(u.viewer.x, -u.viewer.y) * u.parallax * h0 * 0.035;
    float h = max(0.0, grid.sample(s, uv).r);
    float hx = grid.sample(s, uv + float2(texel.x, 0)).r - grid.sample(s, uv - float2(texel.x, 0)).r;
    float hy = grid.sample(s, uv + float2(0, texel.y)).r - grid.sample(s, uv - float2(0, texel.y)).r;
    float3 n = normalize(float3(-hx * (5.0 + 8.0 * h), -hy * (5.0 + 8.0 * h), 1.0));
    float3 light = normalize(float3(-0.5, -0.6, 1.0));
    float spec = pow(max(0.0, dot(reflect(-light, n), float3(0,0,1))), 28.0);
    float rim = pow(1.0 - n.z, 2.0);
    float3 metal = back + u.colorMetal.rgb * (0.05 + 0.22 * max(0.0, dot(n, light)) + 1.2 * spec + 0.35 * rim);
    return half4(half3(lerpDither(mix(back, metal, f.fade), pos)), 1.0h);
}
