// Vesta — the sunlit face of the asteroid Vesta, reconstructed from NASA
// Dawn imagery. Only the hemisphere Dawn photographed in daylight was
// captured, so the camera swings across that face rather than round it.
//
// Capture: "Dawn @ Vesta" by dtdtdt, CC BY 4.0,
// https://superspl.at/scene/61f1a877. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:vesta
//
// lerp-caption-title: Vesta
// lerp-caption: The asteroid belt's second-largest body, from NASA Dawn imagery
// lerp-caption-credit: dtdtdt · CC BY 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: period     float 10 300 = 80  "Seconds there and back"
// lerp-param: angle      float -360 360 = 8  "Centre of the arc"
// lerp-param: arc        float 0 360 = 46  "Arc swept (360 = full turn)"
// lerp-param: distance   float 0.5 10 = 5.8  "Distance"
// lerp-param: height     float -2 4 = 0.3  "Camera height"
// lerp-param: lookHeight float -1 2 = 0  "Look-at height"
// lerp-param: fov        float 10 90 = 30  "Field of view"
// lerp-param: clip       float 0 10 = 0  "Clip in front of subject (0 off)"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"
// lerp-param: pool       float 0 1 = 0  "Light pool"
// lerp-param: background color         = (0, 0, 0) "Background"

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
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
