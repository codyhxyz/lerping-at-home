// Trogir — the main square of a medieval Dalmatian town, captured as
// Gaussian splats: the loggia, café tables under furled umbrellas, and the
// bell tower of St Lawrence's cathedral. The camera stands in the square and
// sweeps an arc, eased at each end, inside the part of the square that was
// photographed; a capture only holds up near where its photos were taken.
//
// Capture: "Main square, Trogir" by tosolini, CC BY 4.0,
// https://superspl.at/scene/89f82474 — the 720k-splat level of its streamed
// level-of-detail set. Converted by `make splats`.
//
// lerp-data: splat:orbit:trogir-square:look
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 300  = 90    "Seconds there and back"
// lerp-param: angle      float -360 360 = -25  "Centre of the arc"
// lerp-param: arc        float 0 360   = 60    "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10  = 1.5   "Distance"
// lerp-param: height     float -2 4    = 0.3   "Camera height"
// lerp-param: lookHeight float -1 2    = 0.9   "Look-at height"
// lerp-param: fov        float 10 90   = 62    "Field of view"
// lerp-param: clip       float 0 10    = 1.3   "Clip in front of subject (0 off)"
// lerp-param: bob        float 0 1     = 0.05  "Rise and fall"
// lerp-param: zenith     color         = (0.06, 0.07, 0.13) "Sky (top)"
// lerp-param: horizon    color         = (0.32, 0.24, 0.24) "Sky (horizon)"
// lerp-param: vignette   float 0 1     = 0.3   "Vignette"
// lerp-param: yaw        float -30 30 = 0 "Turn"
// lerp-param: pitch      float -20 20 = 0 "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    // Where the capture has no sky, a plain one: zenith to horizon.
    float h = pos.y / u.resolution.y;
    float3 sky = mix(u.zenith.rgb, u.horizon.rgb, smoothstep(0.0, 0.75, h));
    float3 color = lerpSplatOver(s, sky);
    float2 q = (pos.xy - 0.5 * u.resolution) / u.resolution.y;
    color *= 1.0 - u.vignette * dot(q, q);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
