// Medinet Habu — a treasury room of the mortuary temple of Ramesses III at
// Luxor, its walls carved and painted with offering scenes. The camera turns
// from the bright doorway across the reliefs. A raw reconstruction, from
// photos taken at the room's centre: the flat patches are in the source.
//
// Capture: "Medinet Habu Royal Treasure 2" by liquiduslabs (Liquidus Labs), CC BY 4.0,
// https://superspl.at/scene/06145dc7. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:medinet-habu:look
// lerp-camera: period=100 angle=0 arc=76 distance=0.3 height=1.5 lookHeight=1.6 fov=70 clip=0 bob=0.005
//
// lerp-caption-title: Medinet Habu
// lerp-caption: Treasury, mortuary temple of Ramesses III, Luxor
// lerp-caption: 20th Dynasty, c. 1185–1154 BCE
// lerp-caption-credit: Liquidus Labs · Open Heritage 3D · CC BY 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"
// lerp-param: zenith     color         = (0.03, 0.024, 0.018) "Backdrop (top)"
// lerp-param: horizon    color         = (0.05, 0.04, 0.03) "Backdrop (horizon)"
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
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
