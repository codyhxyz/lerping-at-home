// @TITLE@ — a photo turned into a window. Apple's SHARP guessed, from this
// one photo, the depth behind every pixel and made it Gaussian splats; the
// camera stands where the photo was taken, so a centred viewer sees the photo
// as it was, and a head moving in front of the screen (Shader › Track Head)
// looks round what is in it. The plane through the scene at @GLASS@ m is on
// the glass: it stays put, nearer things swing against the head, farther ones
// follow it. With nobody tracked it drifts by itself ("Drift").
//
// Made by `make photo-window` from @SOURCE@ on @DATE@. The splats are in
// ~/Library/Application Support/Lerping/Splats/@CAPTURE@.lsplat. They and this
// file are the user's own photo: neither belongs in git or in a package.
// SHARP's model weights are under Apple's research-only model licence.
//
// lerp-category: Splats
// lerp-data: splat:window:@CAPTURE@
//
// lerp-param: fov        float 1 170   = @FOV@ "Photo's field of view (vertical)"
// lerp-param: aspect     float 0.1 10  = @ASPECT@ "Photo's width / height"
// lerp-param: overscan   float 1 1.5   = 1.06  "Overscan"
// lerp-param: parallax   float 0 2     = 1     "Head parallax"
// lerp-param: sway       float 0 0.2   = 0.035 "Drift with nobody tracked (0 off)"
// lerp-param: period     float 10 300  = 40    "Seconds a drift"
// lerp-param: background color         = (0.0, 0.0, 0.0) "Past the photo's edge"

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpSplatView& V [[buffer(1)]],
                        texture2d<half> splat [[texture(1)]]) {
    float4 s = lerpSplatSample(splat, pos.xy, u.resolution);
    float3 color = lerpSplatOver(s, u.background.rgb);
    return half4(half3(lerpDither(color, pos)), 1.0h);
}
