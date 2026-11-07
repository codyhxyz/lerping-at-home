// Sandō — a dolly zoom down a shrine approach, from VoxelKei's observation
// that Gaussian splats can keep a photograph's composition *and* its
// telephoto compression while staying three-dimensional. The lens swings
// from wide to long while the camera backs away by r / tan(fov / 2), so the
// pair of komainu guarding the path hold their size and the lanterns and the
// hall behind them slide forward and stack up.
//
// Backing away takes the camera far outside where the capture was
// photographed, through trees and floaters it never saw properly; everything
// nearer than `clip` in front of the subject is therefore not drawn.
//
// Capture: "Saka Shrine" by kotohibi, CC BY 4.0,
// https://superspl.at/scene/3f8c617d — 1,255 photos; the 750k-splat level of
// its streamed level-of-detail set. Converted by `make splats`.
//
// lerp-data: splat:dolly:saka-shrine
//
// lerp-param: speed      float 0 3     = 1     "Speed"
// lerp-param: period     float 10 300  = 60    "Seconds wide-long-wide"
// lerp-param: angle      float -360 360 = 130  "Direction"
// lerp-param: wideFov    float 20 110  = 75    "Wide field of view"
// lerp-param: longFov    float 2 40    = 10    "Long field of view"
// lerp-param: framing    float 0.3 4   = 1.5   "Framing (subject radii)"
// lerp-param: distance   float 0.5 10  = 3     "Reference distance"
// lerp-param: height     float -2 4    = 0.15  "Camera height (at reference distance)"
// lerp-param: lookHeight float -1 2    = 0.4   "Look-at height"
// lerp-param: clip       float 0 10    = 1.2   "Clip in front of subject"
// lerp-param: drift      float 0 40    = 0     "Sideways drift (degrees)"
// lerp-param: zenith     color         = (0.42, 0.58, 0.80) "Sky (top)"
// lerp-param: horizon    color         = (0.80, 0.86, 0.92) "Sky (horizon)"
// lerp-param: vignette   float 0 1     = 0.25  "Vignette"
// lerp-param: yaw        float -30 30 = 0 "Turn"
// lerp-param: pitch      float -15 15 = 0 "Tilt"
// lerp-param: magnify    float 0 0.5 = 0 "Zoom"   (back, it sees past the capture)
//
// lerp-preset: Drifting  drift=12, period=80

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    // Where the capture has no sky, a plain one: zenith to horizon.
    float h = pos.y / u.resolution.y;
    float3 sky = mix(u.zenith.rgb, u.horizon.rgb, smoothstep(0.0, 0.75, h));
    float3 color = lerpSplatOver(s, sky);
    float2 q = (pos.xy - 0.5 * u.resolution) / u.resolution.y;
    color *= 1.0 - u.vignette * dot(q, q);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
