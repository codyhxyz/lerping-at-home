// Bonsai Globe — a real bonsai, captured as Gaussian splats, sealed in a snow
// globe on a turned wooden base. After VoxelKei's Spatialography worlds,
// which keep small splat scenes inside glass spheres.
//
// The capture is cropped to a sphere when converted, so the splats fill the
// glass and nothing pokes through it. The glass itself is drawn here, in
// screen space around the subject's projected centre and radius
// (LerpSplatView): edge refraction, a fresnel rim, a window highlight, and
// three depths of falling snow.
//
// Capture: "Bonsai Tree" by garrettknelli, CC BY 4.0,
// https://superspl.at/scene/4c461e7c. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:bonsai
// lerp-camera: period=90 distance=6.6 height=0.9 lookHeight=-0.15 fov=30 clip=0
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: glass      float 1 1.6   = 1.18  "Globe size"
// lerp-param: snow       float 0 1     = 0.6   "Snow"
// lerp-param: background color         = (0.03, 0.028, 0.035) "Background"
// lerp-param: yaw        float -180 180 = 0 "Turn"
// lerp-param: pitch      float -30 30 = 0 "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"

// One layer of flakes falling through the globe: a jittered grid in globe
// space, wrapping vertically, each flake a soft disc.
static float snowLayer(float2 d, float t, float scale, float speed, float seed) {
    float2 g = d * scale;
    g.y -= t * speed;            // y is down on screen; flakes fall toward +y
    g.y = -g.y;
    float2 cell = floor(g);
    float2 f = fract(g);
    float acc = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 c = cell + float2(i, j);
            float2 h = hash22(c + seed);
            if (h.x > 0.55) continue;
            float wobble = 0.25 * sin(t * (0.6 + h.y) + h.x * 20.0);
            float2 p = float2(i, j) + float2(0.5 + wobble, 0.5) + (h - 0.5) * 0.5;
            float r = length(f - p);
            acc += smoothstep(0.09, 0.0, r) * (0.5 + 0.5 * h.y);
        }
    }
    return acc;
}

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float2 res = u.resolution;
    float2 q = (pos.xy - 0.5 * res) / res.y;
    float t = u.time * u.speed + 50.0 * u.seed;

    // Background: a dark room with a warm pool of light behind the globe.
    float R = max(V.radius * u.glass, 1.0);
    float2 d = (pos.xy - V.center) / R;          // globe space, y down
    float3 bg = u.background.rgb * (1.0 - 0.5 * dot(q, q));
    bg += float3(0.10, 0.075, 0.05) * exp(-dot(d - float2(0.0, 0.2), d - float2(0.0, 0.2)) * 0.35);

    // Plinth: a turned wooden base under the sphere.
    float baseTop = 0.80, baseBot = 1.22;
    float halfW = mix(0.78, 0.98, saturate((d.y - baseTop) / (baseBot - baseTop)));
    float inBase = step(baseTop, d.y) * step(d.y, baseBot) * step(abs(d.x), halfW);
    // Turned walnut: lit from the upper left, rounded at the sides, with a
    // faint grain and a bright lip where the glass sits.
    float across = d.x / halfW;
    float3 wood = float3(0.36, 0.20, 0.10) * (0.35 + 0.65 * sqrt(max(0.0, 1.0 - across * across)));
    wood *= 1.0 - 0.25 * saturate(across) ;
    wood *= 0.92 + 0.08 * sin(d.y * 60.0 + sin(d.x * 9.0) * 3.0);
    wood += float3(0.25, 0.18, 0.10) * smoothstep(0.03, 0.0, abs(d.y - baseTop - 0.02)) * (1.0 - abs(d.x));
    float3 color = mix(bg, wood, inBase);

    float r2 = dot(d, d);
    if (r2 < 1.0) {
        float r = sqrt(r2);
        float zf = sqrt(1.0 - r2);
        // Refraction: a thick lens bends the edge of the view inward.
        float2 bend = d * (1.0 - zf) * 0.18 * R;
        float4 s = lerpSplatSample(splat, pos.xy - bend, res);
        float3 inside = mix(bg * 0.6, float3(0.05, 0.05, 0.06), 0.4);
        float3 c = lerpSplatOver(s, inside);
        // Snow, three depths.
        float flakes = snowLayer(d, t, 9.0, 0.10, 1.0) * 0.55
                     + snowLayer(d, t, 15.0, 0.07, 7.0) * 0.35
                     + snowLayer(d, t, 24.0, 0.05, 13.0) * 0.25;
        c += u.snow * flakes * float3(0.95, 0.96, 1.0) * smoothstep(1.0, 0.85, r);
        // Glass: fresnel rim, a window highlight, a faint warm bounce.
        float fres = pow(1.0 - zf, 3.0);
        c = mix(c, float3(0.75, 0.80, 0.90), fres * 0.55);
        float2 hl = d - float2(-0.38, -0.42);
        c += float3(1.0) * smoothstep(0.20, 0.0, length(hl * float2(1.0, 1.6))) * 0.55;
        c += float3(1.0) * smoothstep(0.035, 0.0, abs(r - 0.93)) * smoothstep(0.2, -0.6, d.x + d.y) * 0.25;
        c += float3(0.35, 0.22, 0.10) * smoothstep(0.5, 1.0, d.y) * fres;
        float edge = smoothstep(1.0, 0.985, r);
        color = mix(color, c, edge);
    }
    // Contact shadow where the glass meets the base.
    color *= 1.0 - 0.35 * smoothstep(0.12, 0.0, abs(d.y - baseTop)) * step(abs(d.x), 0.8) * step(1.0, r2);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
