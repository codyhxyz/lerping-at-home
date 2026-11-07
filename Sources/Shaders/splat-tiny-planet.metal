// Tiny Planet — a grass-covered globe with digitised trees growing out of it
// in every direction, rendered in 3ds Max and Corona, trained as splats and
// spun slowly.
//
// Capture: "Tiny Planet – Still Life" by sa3d (Stéphane Agullo), CC BY 4.0,
// https://superspl.at/scene/d59f99ee. Converted by `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:orbit:tiny-planet
// lerp-camera: period=100 angle=-135 arc=360 distance=5 height=1 lookHeight=0 fov=30 clip=0
//
// lerp-caption-title: Tiny Planet – Still Life
// lerp-caption: Digitised trees on a synthetic planet
// lerp-caption-credit: Stéphane Agullo · CC BY 4.0
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 0.6 = 0 "Zoom"
// lerp-param: pool       float 0 1 = 0.2  "Light pool"
// lerp-param: background color         = (0.03, 0.032, 0.035) "Background"

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
