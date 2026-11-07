// Lake Maggiore — an autumn forest path, walked with a 360° camera. The
// camera stands on the path and drifts a little sideways, so the trunks
// slide past one another.
//
// Capture: "Lake Maggiore, Autumn forest" by argenzio (Corridori Ruggero), CC BY-NC 4.0,
// https://superspl.at/scene/cf199d86. Converted by `make splats`.
//
// lerp-data: splat:orbit:lake-maggiore:look
//
// lerp-caption-title: Lake Maggiore, autumn forest
// lerp-caption: A woodland path, from 928 frames of 360° video
// lerp-caption-credit: Corridori Ruggero · CC BY-NC 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 80  "Seconds there and back"
// lerp-param: angle      float -360 360 = -1  "Centre of the arc"
// lerp-param: arc        float 0 360 = 9  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.05 10 = 2  "Distance"
// lerp-param: height     float -2 4 = 0.66  "Camera height"
// lerp-param: lookHeight float -1 2 = 0.36  "Look-at height"
// lerp-param: fov        float 10 90 = 55  "Field of view"
// lerp-param: clip       float 0 10 = 1.75  "Clip in front of subject (0 off)"
// lerp-param: bob        float 0 1 = 0.01  "Rise and fall"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: caption    int 0 4 = 3  "Caption (1 frosted, 2 glass, 3 diffuse, 4 label)"
// lerp-param: zenith     color         = (0.72, 0.77, 0.8) "Backdrop (top)"
// lerp-param: horizon    color         = (0.15, 0.12, 0.08) "Backdrop (horizon)"
// lerp-param: vignette   float 0 1 = 0.35  "Vignette"

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
