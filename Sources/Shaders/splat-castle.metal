// Castle — a moated castle on its island at sunset, from a drone: the lake
// lit gold, the causeway, a ring of autumn trees and fields, cut out as a
// round diorama and swept in an arc from above.
//
// Capture: "Castle" by ethan3111 (Ethan), CC BY 4.0,
// https://superspl.at/scene/d276acb9. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:castle
// lerp-camera: period=120 angle=150 arc=150 distance=4.3 height=2 lookHeight=0 fov=40 clip=0
//
// lerp-caption-title: Castle at sunset
// lerp-caption: Leeds Castle, Kent, on its lake, from a drone
// lerp-caption-credit: Ethan · CC BY 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.25 0.6 = 0 "Zoom"   (further back, the capture frays)
// lerp-param: pool       float 0 1 = 0.25  "Light pool"
// lerp-param: background color         = (0.045, 0.033, 0.03) "Background"

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
