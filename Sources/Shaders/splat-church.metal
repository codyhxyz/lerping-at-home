// Shenley Church — a Grade I Norman parish church, captured from a drone as
// Gaussian splats and cut from its churchyard, so it sits in the dark like a
// model on a table while the camera circles it. "Breathing" sends slow waves
// through the stone (dnbt777's deformable splats); "Wrung" twists the tower.
//
// Capture: "Shenley Church" by naturalsplats, CC BY 4.0,
// https://superspl.at/scene/aa451b94 — the 660k-splat level of its streamed
// level-of-detail set. Converted by `make splats`.
//
// lerp-data: splat:orbit:shenley-church
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 300  = 120   "Seconds a turn"
// lerp-param: angle      float -360 360 = 0    "Start angle"
// lerp-param: arc        float 0 360   = 360   "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10  = 3.4   "Distance"
// lerp-param: height     float -2 4    = 1.1   "Camera height"
// lerp-param: lookHeight float -1 2    = 0.15  "Look-at height"
// lerp-param: fov        float 10 90   = 42    "Field of view"
// lerp-param: clip       float 0 10    = 0     "Clip in front of subject (0 off)"
// lerp-param: deform     int 0 4       = 0     "Deform (1 ripple, 2 wall, 3 twist, 4 dissolve)"
// lerp-param: amount     float 0 1     = 0.02  "Deform amount"
// lerp-param: frequency  float 0 20    = 5     "Deform frequency"
// lerp-param: cycle      float 6 120   = 30    "Dissolve cycle (s)"
// lerp-param: pool       float 0 1     = 0.35  "Light pool"
// lerp-param: background color         = (0.025, 0.027, 0.035) "Background"
// lerp-param: yaw        float -180 180 = 0 "Turn"
// lerp-param: pitch      float -30 30 = 0 "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"
//
// lerp-preset: Breathing  deform=2, amount=0.02, frequency=5
// lerp-preset: Wrung      deform=3, amount=0.12

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
