// Growing Neural Cellular Automata — Mordvintsev et al. (2020).
// Uses their released ex3_planarian weights; see third_party/growing-ca.
// lerp-category: Living Worlds
// lerp-data: neural-ca
// lerp-requires: metal4

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]],
                        constant LerpNeuralCAFrame& f [[buffer(1)]],
                        texture2d<float> grid [[texture(1)]]) {
    float3 color = float3(0.035, 0.04, 0.055);
    if (f.ready != 0) {
        float2 p = (pos.xy - 0.5 * u.resolution) / min(u.resolution.x, u.resolution.y) + 0.5;
        if (all(p >= 0.0) && all(p < 1.0)) {
            constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
            float4 v = grid.sample(s, p);
            color = mix(color, saturate(v.rgb), saturate(v.a));
        }
    }
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
