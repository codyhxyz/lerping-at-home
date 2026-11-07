// Vanadinite — glossy red-orange crystals on a grey matrix, standing on
// a dark display disc, shot through crossed polarisers so the faces hold
// their colour instead of glare.
//
// Capture: "Vanadinite" by doudoid (Yann de Couëssin), CC BY 4.0,
// https://superspl.at/scene/663d6a97. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:vanadinite
// lerp-camera: period=90 angle=-20 arc=200 distance=5.8 height=1.2 lookHeight=0 fov=30 clip=0
//
// lerp-caption-title: Vanadinite
// lerp-caption: Lead chlorovanadate crystals, macro, cross-polarised
// lerp-caption-credit: Yann de Couëssin · CC BY 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"
// lerp-param: pool       float 0 1 = 0.3  "Light pool"
// lerp-param: background color         = (0.02, 0.02, 0.025) "Background"

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
