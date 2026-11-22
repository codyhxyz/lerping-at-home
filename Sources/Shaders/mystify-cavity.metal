// Mystify Cavity — moving polygon traces in a screen-anchored room.
// All positions are functions of time and seed: scrubbing does not depend on
// previous frames. Inspired by Mystify, not a reconstruction of its physics.
// The camera and room follow Window Room's fixed-glass convention.
// lerp-category: Sound & Flow
// lerp-param: parallax float 0 2 = 1 "Head parallax"
// lerp-param: depth float 2 8 = 4 "Room depth"
// lerp-param: speed float 0 2 = 0.6 "Speed"
// lerp-param: trails int 2 12 = 8 "Traces"
// lerp-preset: Electric depth=4, speed=0.8, trails=10
// lerp-preset: Quiet depth=6, speed=0.25, trails=6

static float mcSegment(float2 p, float2 a, float2 b) {
    float2 v = b - a;
    return length(p - a - v * clamp(dot(p-a, v) / max(dot(v,v), 1e-6), 0.0, 1.0));
}
static float2 mcVertex(int i, float t, float2 extent) {
    float k = float(i);
    return extent * float2(0.72 * sin(t * (0.37 + k*0.031) + k*1.57),
                           0.72 * sin(t * (0.29 + k*0.023) + k*1.91 + 1.0));
}
fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
    float2 uv = lerpUV(pos, u.resolution);
    float m = min(u.resolution.x, u.resolution.y);
    float2 extent = u.resolution / m;
    float F = 3.6;
    float3 e = lerpViewerEye(u, F, u.parallax);
    e.z = min(e.z, 0.45 * F);
    float3 ro = float3(e.xy, e.z-F);
    float3 ray = float3(uv-e.xy, F-e.z);
    float2 safeXY = select(ray.xy, float2(1e-6), abs(ray.xy) < 1e-6);
    float2 side = (copysign(extent, safeXY)-ro.xy)/safeXY;
    float wall = min(min(side.x, side.y), (u.depth-ro.z)/ray.z);
    float3 hit = ro + ray * wall;
    float shade = 0.009 + 0.013 * exp(-hit.z * 0.5);
    float3 color = float3(shade*0.65, shade*0.8, shade*1.4);
    // Room edges provide a stationary depth reference, with pixel-scale AA.
    float3 boundary = float3(abs(abs(hit.x)-extent.x), abs(abs(hit.y)-extent.y), abs(hit.z-u.depth));
    // One distance is zero on every wall; the second-smallest finds its edges.
    float edge = max(min(boundary.x, boundary.y), min(max(boundary.x, boundary.y), boundary.z));
    color += float3(0.05, 0.11, 0.17) * (1.0-smoothstep(0.0, 0.014, edge));
    float time = u.time*u.speed + u.seed*31.0;
    for (int j=0; j<12; ++j) {
        if (j >= int(u.trails)) break;
        float fj = float(j);
        float z = 0.35 + (u.depth-0.7) * (fj+0.5)/float(u.trails);
        float s = (z-ro.z)/ray.z;
        if (s >= wall) continue;
        float2 p = (ro + ray*s).xy;
        float tt = time - fj*0.19;
        float dist = 100.0;
        for (int i=0; i<4; ++i)
            dist = min(dist, mcSegment(p, mcVertex(i,tt,extent), mcVertex((i+1)%4,tt,extent)));
        float px = 2.0*s/m;
        float line = 1.0-smoothstep(0.0, px*1.6, dist);
        float glow = exp(-dist/(0.018 + px*2.0))*0.16;
        float3 hue = 0.55 + 0.45*cos(float3(0.0, 2.1, 4.2) + fj*0.72 + time*0.12);
        color += hue * (line*0.7 + glow) * (1.0 - 0.45*fj/float(u.trails));
    }
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
