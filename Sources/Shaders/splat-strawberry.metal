// Strawberry — a photoreal Gaussian splat capture on a turntable, the
// "inventory item" idea: one real object turning slowly in the dark.
//
// Capture: "Strawberry" by danylyon (Dany Bittel), CC BY 4.0,
// https://superspl.at/scene/84df8849 — 90 views of 88-image focus stacks.
// Decimated to 700k splats and converted by `make splats`
// (Sources/Splats/captures.json); drawn by SplatData.swift.
//
// lerp-category: Splats
// lerp-data: splat:orbit:strawberry
// lerp-camera: period=70 angle=0 arc=360 distance=5.6 height=0.9 lookHeight=0.0 fov=30 clip=0
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: deform     int 0 4       = 0     "Deform (1 ripple, 2 wall, 3 twist, 4 dissolve)"
// lerp-param: amount     float 0 1     = 0.12  "Deform amount"
// lerp-param: frequency  float 0 20    = 6     "Deform frequency"
// lerp-param: cycle      float 6 120   = 28    "Dissolve cycle (s)"
// lerp-param: pool       float 0 1     = 0.5   "Light pool"
// lerp-param: background color         = (0.035, 0.03, 0.03) "Background"
// lerp-param: yaw        float -180 180 = 0 "Turn"
// lerp-param: pitch      float -30 30 = 0 "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"
//
// dnbt777's "you can just deform gaussian splats": the berry wrung about its
// own axis and let go.
// lerp-preset: Wrung   deform=3, amount=0.35

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    float2 q = (pos.xy - 0.5 * u.resolution) / u.resolution.y;
    float3 bg = u.background.rgb * (1.0 - 0.6 * dot(q, q));
    // A soft pool of light under the subject.
    float2 d = (pos.xy - V.center) / max(V.radius, 1.0);
    bg += u.pool * u.background.rgb * 3.0 * exp(-dot(d - float2(0.0, 0.9), d - float2(0.0, 0.9)) * 0.9);
    float3 color = lerpSplatOver(s, bg);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
