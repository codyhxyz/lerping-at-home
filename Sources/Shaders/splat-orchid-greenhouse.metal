// Orchid Greenhouse — beds of orchids, a curving paved path and dense ferns
// under a glass roof, filmed walking through with a 360° camera. The camera
// turns from the orchids along the path.
//
// Capture: "Orchid Greenhouse" by vice (Shachar Weis), published with no licence
// https://superspl.at/scene/2cf8a82c. Converted by `make splats`.
// Played on this machine only; `make package` leaves this look out.
//
// lerp-data: splat:orbit:orchid-greenhouse:look
//
// lerp-caption-title: Orchid Greenhouse
// lerp-caption: Captured with a DJI Osmo 360
// lerp-caption-credit: Shachar Weis
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 90  "Seconds there and back"
// lerp-param: angle      float -360 360 = 0  "Centre of the arc"
// lerp-param: arc        float 0 360 = 64  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.05 10 = 0.175  "Distance"
// lerp-param: height     float -2 4 = 0.33  "Camera height"
// lerp-param: lookHeight float -1 2 = 0.315  "Look-at height"
// lerp-param: fov        float 10 90 = 60  "Field of view"
// lerp-param: clip       float 0 10 = 0.1  "Clip in front of subject (0 off)"
// lerp-param: bob        float 0 1 = 0.008  "Rise and fall"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"
// lerp-param: caption    int 0 4 = 1  "Caption (1 frosted, 2 glass, 3 diffuse, 4 label)"
// lerp-param: zenith     color         = (0.62, 0.74, 0.86) "Backdrop (top)"
// lerp-param: horizon    color         = (0.24, 0.3, 0.18) "Backdrop (horizon)"
// lerp-param: vignette   float 0 1 = 0.25  "Vignette"

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]],
                        texture2d<half> label [[texture(2)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    // Where the capture runs out, a plain gradient: top to horizon.
    float h = pos.y / u.resolution.y;
    float3 bg = mix(u.zenith.rgb, u.horizon.rgb, smoothstep(0.0, 0.75, h));
    float3 color = lerpSplatOver(s, bg);
    float2 q = (pos.xy - 0.5 * u.resolution) / u.resolution.y;
    color *= 1.0 - u.vignette * dot(q, q);
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label, u.caption, 1.0);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
