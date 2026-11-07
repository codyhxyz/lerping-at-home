// Office lobby — a multi-level lobby in afternoon sun: a glass entrance,
// long window shadows across the floor, tiered wooden seating under a steel
// stair. The camera stands still and turns slowly across the room.
// Reconstructed from an iPhone capture by spAItial's Echo-3 model.
//
// Capture: "Sunlit Office Lobby, Multi-level" by spaitial (spAItial), published with no licence
// https://superspl.at/scene/942c5f7e. Converted by `make splats`.
// Played on this machine only; `make package` leaves this look out.
//
// lerp-data: splat:orbit:office-lobby:look
//
// lerp-caption-title: Sunlit Office Lobby
// lerp-caption: Tiered wooden seating, floor-to-ceiling windows, afternoon sun
// lerp-caption-credit: spAItial
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 90  "Seconds there and back"
// lerp-param: angle      float -360 360 = 0  "Centre of the arc"
// lerp-param: arc        float 0 360 = 90  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.05 10 = 0.25  "Distance"
// lerp-param: height     float -2 4 = 0.4  "Camera height"
// lerp-param: lookHeight float -1 2 = 0.385  "Look-at height"
// lerp-param: fov        float 10 90 = 62  "Field of view"
// lerp-param: clip       float 0 10 = 0  "Clip in front of subject (0 off)"
// lerp-param: bob        float 0 1 = 0.01  "Rise and fall"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"
// lerp-param: caption    int 0 4 = 2  "Caption (1 frosted, 2 glass, 3 diffuse, 4 label)"
// lerp-param: zenith     color         = (0.9, 0.86, 0.8) "Backdrop (top)"
// lerp-param: horizon    color         = (0.78, 0.6, 0.42) "Backdrop (horizon)"
// lerp-param: vignette   float 0 1 = 0.2  "Vignette"

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
