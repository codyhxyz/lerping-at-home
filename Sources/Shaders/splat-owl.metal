// Owl — a carved wooden owl on an ivy-covered stump, cut out of its lawn as
// a round plinth of grass and turned slowly. "Ripple" sends rings across the
// grass (louder bass, bigger rings, where the host feeds audio).
//
// Capture: "Owl Wood Sculpture" by pierrecharpentierdesign, CC BY 4.0,
// https://superspl.at/scene/ac4eb719. Converted by `make splats`.
//
// lerp-data: splat:orbit:owl
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 300  = 90  "Seconds a turn"
// lerp-param: angle      float -360 360 = 0  "Start angle"
// lerp-param: arc        float 0 360   = 360  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10  = 5.6  "Distance"
// lerp-param: height     float -2 4    = 1.4  "Camera height"
// lerp-param: lookHeight float -1 2    = 0.25  "Look-at height"
// lerp-param: fov        float 10 90   = 30   "Field of view"
// lerp-param: clip       float 0 10    = 0     "Clip in front of subject (0 off)"
// lerp-param: deform     int 0 4       = 0     "Deform (1 ripple, 2 wall, 3 twist, 4 dissolve)"
// lerp-param: amount     float 0 1     = 0.05  "Deform amount"
// lerp-param: frequency  float 0 20    = 4     "Deform frequency"
// lerp-param: cycle      float 6 120   = 28    "Dissolve cycle (s)"
// lerp-param: pool       float 0 1     = 0.0   "Light pool"
// lerp-param: parallax   float 0 2     = 1     "Head parallax"
// lerp-param: background color         = (0.02, 0.025, 0.03) "Background"
//
// lerp-preset: Ripple  deform=1, amount=0.09, frequency=3

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
