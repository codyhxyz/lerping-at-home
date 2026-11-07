// Milano apartment — a basement kitchen and dining room: a long wooden
// table and bentwood chairs, kitchen units along both walls, barred windows
// high up. The camera circles part-way round the table.
//
// Capture: "Milano Subterranean Apartment" by argenzio (Corridori Ruggero), CC BY-NC 4.0,
// https://superspl.at/scene/15b6b784. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:milano-apartment:look
//
// lerp-caption-title: Milano Subterranean Apartment
// lerp-caption: From 1,480 frames of 360° video
// lerp-caption-credit: Corridori Ruggero · CC BY-NC 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 80  "Seconds there and back"
// lerp-param: angle      float -360 360 = 0  "Centre of the arc"
// lerp-param: arc        float 0 360 = 44  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.05 10 = 1.7  "Distance"
// lerp-param: height     float -2 4 = 1.35  "Camera height"
// lerp-param: lookHeight float -1 2 = 0.8  "Look-at height"
// lerp-param: fov        float 10 90 = 65  "Field of view"
// lerp-param: clip       float 0 10 = 0  "Clip in front of subject (0 off)"
// lerp-param: bob        float 0 1 = 0.02  "Rise and fall"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"
// lerp-param: zenith     color         = (0.036, 0.03, 0.024) "Backdrop (top)"
// lerp-param: horizon    color         = (0.06, 0.05, 0.04) "Backdrop (horizon)"
// lerp-param: vignette   float 0 1 = 0.3  "Vignette"

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
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
