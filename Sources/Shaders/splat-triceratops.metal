// Triceratops — a fossil skull, captured as Gaussian splats, on a turntable.
// The "Fossil bloom" preset is the dissolve: every splat drifts off on its
// own heading, from the jaw up, then the skull reassembles.
//
// Capture: "Burke Museum Triceratops Skull" by lukeshea, CC BY 4.0,
// https://superspl.at/scene/811dd9ed. Converted by `make splats`.
//
// lerp-data: splat:orbit:triceratops
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 300  = 80  "Seconds a turn"
// lerp-param: angle      float -360 360 = 0  "Start angle"
// lerp-param: arc        float 0 360   = 360  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10  = 4.8  "Distance"
// lerp-param: height     float -2 4    = 0.7  "Camera height"
// lerp-param: lookHeight float -1 2    = 0  "Look-at height"
// lerp-param: fov        float 10 90   = 32   "Field of view"
// lerp-param: clip       float 0 10    = 0     "Clip in front of subject (0 off)"
// lerp-param: deform     int 0 4       = 0     "Deform (1 ripple, 2 wall, 3 twist, 4 dissolve)"
// lerp-param: amount     float 0 1     = 0.08  "Deform amount"
// lerp-param: frequency  float 0 20    = 6     "Deform frequency"
// lerp-param: cycle      float 6 120   = 28    "Dissolve cycle (s)"
// lerp-param: pool       float 0 1     = 0.4   "Light pool"
// lerp-param: background color         = (0.03, 0.028, 0.026) "Background"
//
// lerp-preset: "Fossil bloom"  deform=4, amount=0.03, cycle=26

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
