import Foundation
import Metal

/// CPU side of the `heatmap` shader.
///
/// Upstream (paper-design/shaders, Apache-2.0) does not feed `heatmap` a raw
/// picture: `toProcessedHeatmap` runs a **CPU pre-pass** first, box-blurring the
/// source silhouette at three radii and packing the results into one RGB image —
///
///     R = contour     small radius, 1 pass  (a barely-softened silhouette)
///     G = outer blur  0.15 x the shape box, 3 passes
///     B = inner blur  0.12 x that radius,   3 passes
///
/// — which the fragment shader then flows heat through. A screensaver has no
/// image to supply, so this provider *draws* the silhouette (a seeded Lissajous
/// ribbon) and runs upstream's pre-pass on it verbatim: the same integral-image
/// box blur, the same radii expressed as the same fractions of the shape box,
/// the same channel packing. Everything downstream of the texture is upstream's
/// algorithm, unmodified.
///
/// **Purity.** Upstream's input image is static — every bit of motion in
/// `heatmap` comes from the fragment shader's clock — and so is this
/// silhouette: the texture is a function of `(seed, drawable aspect)` and of
/// nothing else, `u.time` included. It is therefore generated once per distinct
/// (seed, size) and reused, which is not accumulated state: regenerating it on
/// every frame would produce the identical bytes, and a fresh
/// `--snapshot --time 60` process reproduces the same image as any other route
/// to t = 60. Texture dimensions are quantised so that dragging a window resize
/// does not thrash the generator.
public final class HeatmapData: LerpDataProvider {

    // MARK: - Geometry

    /// Processed-texture texels across the drawable's short axis. The texture is
    /// generated at the drawable's aspect ratio and sampled 1:1 in screen UV, so
    /// there is no image box to fit and no frame to fade — the blur padding runs
    /// off the edge of the screen instead of ending inside it.
    static let shortSide = 768
    /// Cap for the long axis, so an ultrawide drawable cannot balloon the
    /// pre-pass. Past this the far sides simply sit at the background colour.
    static let maxLongSide = 1792
    /// Side of the silhouette's bounding square, as a fraction of the short
    /// axis — i.e. how much of the screen the emblem fills. Upstream pads its
    /// 1000px image by 375px a side, a ratio this cannot quite afford and still
    /// fill the frame; the outer glow instead runs off the top and bottom edges,
    /// which is what a full-screen composition wants anyway.
    static let shapeFraction: Float = 0.66

    /// Blur radii, as upstream's fractions of the shape box.
    static let maxBlurFraction: Float = 0.15      // toProcessedHeatmap: maxBlur
    static let innerBlurFraction: Float = 0.12    // of maxBlur
    static let contourFraction: Float = 0.005     // upstream: radius 5 at 1000px

    /// Curve samples stamped along the ribbon. Consecutive stamps land well
    /// under a texel apart at this count, so taking the max coverage is an
    /// exact antialiased union of the discs.
    static let curveSamples = 6000

    /// Lissajous frequency pairs, all coprime so the curve closes at 2 pi. Kept
    /// to low orders: past about 7 the strands sit closer together than the
    /// outer blur is wide and the figure reads as a solid lump.
    static let lissajous: [(Int, Int)] = [(3, 2), (5, 2), (7, 2), (4, 3), (5, 3), (5, 4)]

    // MARK: - State (GPU scratch only — carries no simulation state)

    private struct Key: Hashable {
        var seed: UInt32
        var width: Int
        var height: Int
    }

    private let device: MTLDevice
    private var texture: MTLTexture?
    private var key: Key?

    public init(device: MTLDevice) {
        self.device = device
    }

    // MARK: - LerpDataProvider

    public var metalPrelude: String { HeatmapData.metalSource }

    /// Texture size for a drawable: short axis fixed, long axis following the
    /// aspect ratio, rounded to a multiple of 64 so small resizes reuse the
    /// texture that is already built.
    static func dimensions(for resolution: SIMD2<Float>) -> (width: Int, height: Int) {
        let w = max(1, resolution.x), h = max(1, resolution.y)
        let long = Int((Float(shortSide) * max(w, h) / min(w, h) / 64).rounded()) * 64
        let clamped = min(maxLongSide, max(shortSide, long))
        return w >= h ? (clamped, shortSide) : (shortSide, clamped)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        let size = HeatmapData.dimensions(for: uniforms.resolution)
        let wanted = Key(seed: uniforms.seed.bitPattern, width: size.width, height: size.height)
        if key != wanted || texture == nil {
            texture = HeatmapData.makeProcessedTexture(device: device, key: wanted)
            key = texture == nil ? nil : wanted
        }
        guard let texture else { return }
        encoder.setFragmentTexture(texture, index: 1)
    }

    // MARK: - The pre-pass

    private static func makeProcessedTexture(device: MTLDevice, key: Key) -> MTLTexture? {
        let width = key.width, height = key.height
        let count = width * height

        let shapeBox = Int(Float(min(width, height)) * shapeFraction)
        let maxBlur = Int((Float(shapeBox) * maxBlurFraction).rounded())
        let innerBlurRadius = max(1, Int((Float(maxBlur) * innerBlurFraction).rounded()))
        let contourRadius = max(1, Int((Float(shapeBox) * contourFraction).rounded()))

        var gray = [UInt8](repeating: 255, count: count)
        var contour = [UInt8](repeating: 0, count: count)
        var bigBlur = [UInt8](repeating: 0, count: count)
        var innerBlur = [UInt8](repeating: 0, count: count)
        var scratch = [UInt8](repeating: 0, count: count)
        var integral = [UInt32](repeating: 0, count: count)
        var rgba = [UInt8](repeating: 255, count: count * 4)

        gray.withUnsafeMutableBufferPointer { g in
            drawSilhouette(into: g.baseAddress!, width: width, height: height,
                           box: shapeBox, seed: Float(bitPattern: key.seed))

            contour.withUnsafeMutableBufferPointer { c in
            bigBlur.withUnsafeMutableBufferPointer { b in
            innerBlur.withUnsafeMutableBufferPointer { i in
            scratch.withUnsafeMutableBufferPointer { s in
            integral.withUnsafeMutableBufferPointer { sums in
                let src = g.baseAddress!, sc = s.baseAddress!, sm = sums.baseAddress!
                multiPassBlur(src, into: c.baseAddress!, scratch: sc, sums: sm,
                              width: width, height: height, radius: contourRadius, passes: 1)
                multiPassBlur(src, into: b.baseAddress!, scratch: sc, sums: sm,
                              width: width, height: height, radius: maxBlur, passes: 3)
                multiPassBlur(src, into: i.baseAddress!, scratch: sc, sums: sm,
                              width: width, height: height, radius: innerBlurRadius, passes: 3)

                rgba.withUnsafeMutableBufferPointer { out in
                    let o = out.baseAddress!
                    let cc = c.baseAddress!, bb = b.baseAddress!, ii = i.baseAddress!
                    for p in 0..<count {
                        o[p * 4 + 0] = cc[p]
                        o[p * 4 + 1] = bb[p]
                        o[p * 4 + 2] = ii[p]
                        o[p * 4 + 3] = 255
                    }
                }
            }}}}}
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "heatmap.processed"
        rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: width * 4)
        }
        return texture
    }

    /// Stand-in for `u_image`: a Lissajous ribbon, dark on white, drawn into the
    /// centred `box` x `box` square. Upstream draws its source image onto a white
    /// canvas the same way, so the polarity downstream is unchanged — the shape
    /// is the dark region, the padding is the bright one.
    ///
    /// The frequency pair, the phase and the width modulation all come from the
    /// seed, so each launch gets a different figure; nothing here reads the clock.
    private static func drawSilhouette(into gray: UnsafeMutablePointer<UInt8>,
                                       width: Int, height: Int, box: Int, seed: Float) {
        var rng = makeRNG(seed: seed)
        let (a, b) = lissajous[rng.below(lissajous.count)]
        let phase = rng.unit() * Double.pi
        let taperFreq = Double(2 + rng.below(2))
        let taperPhase = rng.unit() * 2.0 * Double.pi

        let half = 0.5 * Double(box)
        let amplitude = half * 0.88
        // Denser figures need a thinner ribbon or the strands merge.
        let stroke = half * (0.125 - 0.007 * Double(max(a, b)))
        let cx = 0.5 * Double(width), cy = 0.5 * Double(height)

        for i in 0..<curveSamples {
            let th = 2.0 * Double.pi * Double(i) / Double(curveSamples)
            let x = cx + amplitude * sin(Double(a) * th + phase)
            let y = cy + amplitude * sin(Double(b) * th)
            let r = stroke * (0.85 + 0.35 * sin(taperFreq * th + taperPhase))
            stampDisc(gray, width: width, height: height, cx: x, cy: y, radius: r)
        }
    }

    /// Darkens an antialiased disc into the grayscale buffer, keeping the
    /// darkest value written so far — i.e. the union of every disc.
    private static func stampDisc(_ gray: UnsafeMutablePointer<UInt8>,
                                  width: Int, height: Int,
                                  cx: Double, cy: Double, radius: Double) {
        let x0 = max(0, Int((cx - radius - 1).rounded(.down)))
        let x1 = min(width - 1, Int((cx + radius + 1).rounded(.up)))
        let y0 = max(0, Int((cy - radius - 1).rounded(.down)))
        let y1 = min(height - 1, Int((cy + radius + 1).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return }
        let outer = (radius + 1.0) * (radius + 1.0)

        for py in y0...y1 {
            let dy = Double(py) + 0.5 - cy
            let row = py * width
            for px in x0...x1 {
                let dx = Double(px) + 0.5 - cx
                let d2 = dx * dx + dy * dy
                if d2 > outer { continue }
                let coverage = min(1.0, max(0.0, radius + 0.5 - d2.squareRoot()))
                let value = UInt8(255.0 * (1.0 - coverage))
                if value < gray[row + px] { gray[row + px] = value }
            }
        }
    }

    /// Upstream's `blurGray`: a box blur summed from an integral image, so the
    /// cost does not grow with the radius. Window edges are clipped to the image
    /// and the divisor is the clipped area, which keeps the uniform bright
    /// border bright all the way out to the texture edge.
    private static func blurGray(_ src: UnsafePointer<UInt8>,
                                 _ dst: UnsafeMutablePointer<UInt8>,
                                 _ sums: UnsafeMutablePointer<UInt32>,
                                 width: Int, height: Int, radius: Int) {
        guard radius > 0 else {
            dst.update(from: src, count: width * height)
            return
        }
        for y in 0..<height {
            let row = y * width
            var rowSum: UInt32 = 0
            for x in 0..<width {
                rowSum &+= UInt32(src[row + x])
                sums[row + x] = rowSum &+ (y > 0 ? sums[row - width + x] : 0)
            }
        }
        for y in 0..<height {
            let y1 = max(0, y - radius), y2 = min(height - 1, y + radius)
            let rowA = y2 * width, rowC = (y1 - 1) * width, out = y * width
            let rows = UInt32(y2 - y1 + 1)
            for x in 0..<width {
                let x1 = max(0, x - radius), x2 = min(width - 1, x + radius)
                let a = sums[rowA + x2]
                let b = x1 > 0 ? sums[rowA + x1 - 1] : 0
                let c = y1 > 0 ? sums[rowC + x2] : 0
                let d = (x1 > 0 && y1 > 0) ? sums[rowC + x1 - 1] : 0
                let area = UInt32(x2 - x1 + 1) &* rows
                let total = a &- b &- c &+ d
                dst[out + x] = UInt8(min(255, (total &+ area / 2) / area))
            }
        }
    }

    /// Upstream's `multiPassBlurGray`: repeated box blurs, which converge on a
    /// Gaussian. Ping-pongs between `dst` and `scratch` so the result always
    /// lands in `dst`.
    private static func multiPassBlur(_ src: UnsafePointer<UInt8>,
                                      into dst: UnsafeMutablePointer<UInt8>,
                                      scratch: UnsafeMutablePointer<UInt8>,
                                      sums: UnsafeMutablePointer<UInt32>,
                                      width: Int, height: Int, radius: Int, passes: Int) {
        blurGray(src, dst, sums, width: width, height: height, radius: radius)
        guard passes > 1 else { return }
        for pass in 1..<passes {
            if pass % 2 == 1 {
                blurGray(dst, scratch, sums, width: width, height: height, radius: radius)
            } else {
                blurGray(scratch, dst, sums, width: width, height: height, radius: radius)
            }
        }
        if (passes - 1) % 2 == 1 {
            dst.update(from: scratch, count: width * height)
        }
    }

    // MARK: - Seeded RNG

    /// `LerpSplitMix64` stirred by this provider's own recipe. Not shared with
    /// the other providers' stirring, deliberately: two of them handed the same
    /// `u.seed` must not draw the same numbers, and the existing figures were
    /// rendered from exactly these constants.
    private static func makeRNG(seed: Float) -> LerpSplitMix64 {
        var rng = LerpSplitMix64(
            state: UInt64(seed.bitPattern) &* LerpSplitMix64.gamma ^ 0xD1B5_4A32_D192_ED03)
        _ = rng.next()
        return rng
    }

    // MARK: - MSL declarations

    static let metalSource = """
    // ---- lerp-data: heatmap -----------------------------------------------
    // Fragment texture 1: the pre-processed silhouette, built on the CPU by
    // Sources/LerpCore/HeatmapData.swift the way upstream's toProcessedHeatmap
    // pre-processes an input picture:
    //
    //   R = contour     silhouette, box-blurred at a small radius
    //   G = outer blur  box-blurred at 0.15 x the shape box, 3 passes
    //   B = inner blur  box-blurred at 0.12 x that radius, 3 passes
    //   A = 1
    //
    // Bright is background and dark is shape, matching upstream's white canvas.
    // The texture is generated at the drawable's aspect ratio, so it is sampled
    // straight with screen UV (y down) and clamped: outside it the border stays
    // bright, which is exactly the "no shape here" case.
    constexpr sampler lerpHeatmapSampler(coord::normalized,
                                         address::clamp_to_edge,
                                         filter::linear);
    """
}
