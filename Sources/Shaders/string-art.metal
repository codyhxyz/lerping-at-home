// String Art — ported from "stringart" by gman (Gregg Tavares) on vertexshaderart.com (CC0)
// https://www.vertexshaderart.com/art/EgLk7JDok4GhxPeMH
// Licence: "Note: All the shaders I've posted are licensed CC0" (gman's
// vertexshaderart profile), and "Any art by "gman" is CC0" in the site's
// LICENSE.md (https://github.com/greggman/vertexshaderart.com).
//
// lerp-data: string-art
//
// Upstream is a *vertex* shader: 500 vertices drawn as LINES, so 250 strings,
// each stretched from a point on one moving rose curve (even vertex) to the
// matching point on another (odd vertex), coloured by hue = vertexId / 500.
// This engine has only a fullscreen fragment function, so the vertex shader
// runs on the CPU instead (StringArtData in
// Sources/LerpCore/VertexShaderArtData.swift, upstream's main() line for line,
// regenerated from (time, seed, params) every frame), which bins the 250 lines
// into screen tiles of 16 px and up. Each pixel walks only its own tile's lines.
//
// Kept from upstream: all curve maths and rates, fit-to-height aspect, 1-px
// lines on black, per-end colours interpolated along each line, and draw order.
// vertexshaderart draws with depth test LESS and every vertex at z = 0, so the
// *first-drawn* line covering a pixel wins. Lines composite front to back in
// that order, antialiased.
//
// Antialiasing (lerpVsaProfile in VertexShaderArtData.swift): coverage is the
// line's cross-section filtered by a 1-px-radius tent, not a pixel box. A box
// put a 1-px line at full brightness on one row of pixels but at half on
// each of two rows, so shallow lines beaded into stair steps, the dense fan
// beat into moire, and both crawled as the lines moved. The tent sums to 1
// over any row of pixel centres, so each line keeps the same light per pixel
// of length wherever it falls; peak brightness swings 0.75-0.5 instead of
// 1-0.5 at 1 px wide, and barely at all at the 1.76-px width of a 2704x1756
// screen. Measured at 1352x878: mean luminance within 1% of a 16x
// supersampled render; ssaa.py flicker ratio 1.07x -> 0.96x (default) and
// 1.11x -> 1.03x (Upstream).
//
// Pixels: vertexshaderart sizes its canvas in CSS pixels, so upstream's 1-px
// lines are 2 physical pixels on a Retina screen. The port takes one CSS pixel
// as max(1, short side / 1000) framebuffer pixels (VertexShaderArtLines.cssPixel).
//
// Port additions, not in upstream: `speed` (upstream runs at 1x; slowed here)
// and the per-launch seed offset into time. `lineWidth`, in those CSS pixels,
// stands in for upstream's lineSize setting, whose NATIVE choice is 1.
// `background` is upstream's backgroundColor setting.
//
// lerp-param: speed      float 0 2    = 0.3       "Speed"
// lerp-param: lineWidth  float 0.5 4  = 1.0       "Line width"
// lerp-param: background color        = (0, 0, 0) "Background"
//
// lerp-preset: Upstream  speed=1

fragment half4 lerpMain(float4 pos [[position]],
                        constant LerpUniforms& u [[buffer(0)]],
                        constant LerpVsaFrame& F [[buffer(1)]],
                        device const LerpVsaSegment* segs [[buffer(2)]],
                        device const uint2* tiles [[buffer(3)]],
                        device const ushort* indices [[buffer(4)]]) {
    float4 lines = lerpVsaLines(pos.xy, F, segs, tiles, indices);
    float3 color = lines.rgb + (1.0 - lines.a) * u.background.rgb;
    color = lerpDither(color, pos);
    return half4(half3(color), 1.0h);
}
