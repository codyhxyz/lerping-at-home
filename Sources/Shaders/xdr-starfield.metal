// XDR Starfield — seeded, analytically travelling stars on depth planes.
// Each plane is a world-space grid; its cells travel towards the glass, with
// a fade at each end of the loop. No frame history is needed for scrubbing.
// Head coupling follows the same fixed-glass camera as Window Room.
// lerp-category: Scenes
// lerp-param: parallax float 0 2 = 1 "Head parallax"
// lerp-param: speed float 0 2 = 0.45 "Speed"
// lerp-param: density float 0.5 2 = 1 "Density"
// lerp-param: warmth float 0 1 = 0.35 "Warmth"
// lerp-preset: Voyager speed=0.8, density=0.8, warmth=0.15
// lerp-preset: Ember speed=0.25, density=1.3, warmth=0.8

fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float m = min(u.resolution.x, u.resolution.y);
    float F = 3.6;
    float3 e = lerpViewerEye(u, F, u.parallax);
    e.z = min(e.z, F*0.45);
    float3 ro = float3(e.xy, e.z-F);
    float3 ray = float3(uv-e.xy, F-e.z);
    float3 color = float3(0.0015, 0.002, 0.006);
    for (int i=0; i<16; ++i) {
        float fi = float(i);
        float phase = fract((fi+0.5)/16.0 - u.time*u.speed*0.035 + u.seed);
        float z = 0.2 + phase*18.0;
        float s = (z-ro.z)/ray.z;
        float2 p = (ro+ray*s).xy * u.density;
        float2 cell = floor(p);
        float2 local = fract(p);
        // Keep each star away from the cell boundary, so adjacent cells never
        // need to be sampled and the footprint remains bounded.
        float h = hash11(dot(cell, float2(127.1,311.7)) + fi*41.3 + u.seed*97.0);
        float2 center = 0.25 + 0.5*float2(h, hash11(h*71.3+fi));
        float d = length(local-center);
        float px = 2.0*s*u.density/m;
        float radius = max(px*0.65, 0.008);
        float core = 1.0-smoothstep(radius, radius+px*1.2, d);
        float glow = exp(-d/max(radius*3.0, 0.001))*0.22;
        float fade = smoothstep(0.0, 0.08, phase)*(1.0-smoothstep(0.88, 1.0, phase));
        float3 tint = mix(float3(0.55,0.72,1.0), float3(1.0,0.67,0.38), u.warmth*h);
        color += tint * (core+glow) * fade * (0.2+0.8*h) / (1.0+phase*1.7);
    }
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
