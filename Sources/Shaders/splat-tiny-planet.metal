// Tiny Planet — a grass-covered globe with digitised trees growing out of it
// in every direction, rendered in 3ds Max and Corona and trained as splats.
// The camera and the scene are the author's, as SuperSplat plays them when the
// scene opens: the fly-through low over the grass and in among the trees at a
// 120° lens, against the scene's flat grey.
//
// Capture: "Tiny Planet – Still Life" by sa3d (Stéphane Agullo), CC BY 4.0,
// https://superspl.at/scene/d59f99ee. Converted, with its camera path, by
// `make splats`.
//
// lerp-category: Splats
// lerp-data: splat:path:tiny-planet
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
// lerp-param: background color         = (0.157, 0.157, 0.157) "Background"

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]],
                        texture2d<half> label [[texture(2)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    float3 bg = u.background.rgb;   // the scene's own flat grey, no vignette
    float3 color = lerpSplatOver(s, bg);
    color = lerpSplatCaption(color, bg, pos.xy, u.resolution, V, splat, label);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
