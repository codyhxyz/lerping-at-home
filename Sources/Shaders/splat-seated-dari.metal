// Seated Dari — a small jade figure of the Buddha Vairocana, seated in
// meditation, turned slowly in the dark like a piece in a museum case. The
// look sets the museum's label over it; its presets try the label's other
// treatments: frosted panel, a diffuse haze, and bare type.
//
// Capture: "Seated Dari" by crowmuseum (Crow Museum of Asian Arts), published with no licence
// https://superspl.at/scene/e43c3c94. Converted by `make splats`.
// Played on this machine only; `make package` leaves this look out.
//
// lerp-data: splat:orbit:seated-dari
//
// lerp-caption-title: Seated Dari (Vairocana)
// lerp-caption: Jade, 19th century. China, Qing dynasty (1644–1911)
// lerp-caption-credit: Crow Museum of Asian Arts
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 80  "Seconds a turn"
// lerp-param: angle      float -360 360 = 0  "Start angle"
// lerp-param: arc        float 0 360 = 360  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10 = 5.2  "Distance"
// lerp-param: height     float -2 4 = 1  "Camera height"
// lerp-param: lookHeight float -1 2 = 0  "Look-at height"
// lerp-param: fov        float 10 90 = 30  "Field of view"
// lerp-param: clip       float 0 10 = 0  "Clip in front of subject (0 off)"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: caption    int 0 4 = 2  "Caption (1 frosted, 2 glass, 3 diffuse, 4 label)"
// lerp-param: pool       float 0 1 = 0.35  "Light pool"
// lerp-param: background color         = (0.03, 0.03, 0.035) "Background"
//
// lerp-preset: Frosted  caption=1
// lerp-preset: Diffuse  caption=3
// lerp-preset: Label    caption=4

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]],
                        texture2d<half> label [[texture(2)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    float2 q = (pos.xy - 0.5 * u.resolution) / u.resolution.y;
    float3 bg = u.background.rgb * (1.0 - 0.6 * dot(q, q));
    // A soft pool of light under the subject.
    float2 d = (pos.xy - V.center) / max(V.radius, 1.0);
    bg += u.pool * u.background.rgb * 3.0 * exp(-dot(d - float2(0.0, 0.9), d - float2(0.0, 0.9)) * 0.9);
    float3 color = lerpSplatOver(s, bg);
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label, u.caption, 1.0);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
