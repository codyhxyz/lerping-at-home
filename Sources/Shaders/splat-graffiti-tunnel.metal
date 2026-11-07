// Graffiti Tunnel — Leake Street, London, under the railway: painted walls
// and ceiling, lit from above. The camera stands in the walkway and sweeps
// from the lit exit, across a mural, back along the wall.
//
// Capture: "The Graffiti Tunnel, London, UK" by mlodyginesik (Radoslaw Boratynski), published with no licence
// https://superspl.at/scene/6713317b. Converted by `make splats`.
// Played on this machine only; `make package` leaves this look out.
//
// lerp-category: Splats
// lerp-data: splat:orbit:graffiti-tunnel:look
// lerp-camera: period=90 angle=-15 arc=70 distance=1.375 height=-0.1 lookHeight=0 fov=62 clip=1.25 bob=0.03
//
// lerp-caption-title: The Graffiti Tunnel
// lerp-caption: Leake Street, London
// lerp-caption-credit: Radoslaw Boratynski
//
// lerp-param: speed      float 0 3 = 1  "Speed"
// lerp-param: parallax   float 0 2 = 1  "Head parallax"
// lerp-param: yaw        float -180 180 = 0  "Turn"
// lerp-param: pitch      float -30 30 = 0  "Tilt"
// lerp-param: magnify    float -0.5 1 = 0 "Zoom"
// lerp-param: zenith     color         = (0.03, 0.04, 0.13) "Backdrop (top)"
// lerp-param: horizon    color         = (0.12, 0.09, 0.14) "Backdrop (horizon)"
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
