import Foundation
import Metal

/// CPU side of shaders ported from vertexshaderart.com, where a piece is a
/// *vertex* shader that places `vertexCount` points from `vertexId` and draws
/// them as POINTS or LINES. This engine renders one fullscreen fragment
/// function and must not grow a second pipeline for it, so the vertex shader
/// is run here on the CPU instead — once per vertex per frame, from
/// `(time, seed, params)` alone — and the resulting line list is binned into a
/// screen-space tile grid that the fragment shader walks.
///
/// **Purity.** Every frame regenerates every vertex from the uniforms; nothing
/// carries over. The vertex functions are closed-form in `time`, as they are
/// upstream, so this is the whole job.
///
/// **Cost.** Binning bounds the per-pixel work by the lines that actually pass
/// through that pixel's tile rather than the piece's whole vertex count. Each
/// tile's list keeps draw order, which the shader needs: vertexshaderart draws
/// with depth test LESS and every vertex at z = 0, so the *first-drawn* line
/// covering a pixel is the one that shows.
///
/// GPU bindings (see `metalSource`):
///
///     fragment buffer 1   LerpVsaFrame      tile grid size, tile edge, line half-width
///     fragment buffer 2   LerpVsaSegment[]  endpoints in framebuffer pixels (y down) + RGB per end
///     fragment buffer 3   uint2[]           per tile: (first index, count) into buffer 4
///     fragment buffer 4   ushort[]          segment indices, ascending (draw order) within a tile
final class VertexShaderArtLines {

    /// Tile edge in framebuffer pixels: 16 up to ~1000-px-short-side
    /// drawables, growing in steps of 8 so a 5K screen has about as many tiles
    /// as a small window. That keeps the CPU's span count and the tile table it
    /// uploads roughly constant per frame, for a few more candidate lines per
    /// tile on large screens.
    static func tileSize(for resolution: SIMD2<Float>) -> Int {
        let short = max(1, min(resolution.x, resolution.y))
        let raw = Int((min(short, 8192) / 64).rounded(.up))
        return min(64, max(16, (raw + 7) / 8 * 8))
    }

    /// Must match `LerpVsaFrame` in `metalSource`.
    struct Frame {
        var tiles: SIMD2<UInt32>
        var tileSize: UInt32
        var segmentCount: UInt32
        var halfWidth: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// Must match `LerpVsaSegment` in `metalSource`.
    struct Segment {
        var ends: SIMD4<Float>     // p0.xy, p1.xy in framebuffer pixels, y down
        var color0: SIMD4<Float>
        var color1: SIMD4<Float>
    }

    /// One tile row's worth of one segment: tiles [colLo, colHi] of `row`.
    private struct Span {
        var segment: UInt16
        var row: UInt16
        var colLo: UInt16
        var colHi: UInt16
    }

    private let device: MTLDevice
    private let segmentRing: LerpBufferRing?
    private let maxSegments: Int
    private var tileRing: LerpBufferRing?
    private var tileCapacity = 0
    private var indexRing: LerpBufferRing?
    private var indexCapacity = 0

    private var spans: [Span] = []
    private var cursor: [UInt32] = []

    init(device: MTLDevice, maxSegments: Int, label: String) {
        precondition(maxSegments <= Int(UInt16.max))
        self.device = device
        self.maxSegments = maxSegments
        segmentRing = LerpBufferRing(device: device,
                                     length: maxSegments * MemoryLayout<Segment>.stride,
                                     label: label + ".segments")
    }

    /// Bins `segments` (draw order) for a drawable of `resolution` pixels and
    /// binds everything at fragment buffers 1–4.
    ///
    /// A counting sort written straight into the GPU buffers: spans are
    /// gathered once, tile counts accumulate in the tile table itself and are
    /// prefix-summed in place, then indices are scattered in draw order so each
    /// tile's list is ascending. No per-frame allocation once the rings have
    /// grown to size.
    func bind(_ segments: [Segment], halfWidth: Float, resolution: SIMD2<Float>,
              to encoder: MTLRenderCommandEncoder) {
        let segCount = min(segments.count, maxSegments)
        let ts = Self.tileSize(for: resolution)
        let tx = max(1, min(Int(UInt16.max), Int((min(max(1, resolution.x), 65536) / Float(ts)).rounded(.up))))
        let ty = max(1, min(Int(UInt16.max), Int((min(max(1, resolution.y), 65536) / Float(ts)).rounded(.up))))
        let tileCount = tx * ty

        // Reach of a line's coverage past its centreline: half-width plus the
        // 1-px radius of the antialiasing tent (`lerpVsaProfile`).
        let reach = halfWidth + 1.0

        spans.removeAll(keepingCapacity: true)
        segments.withUnsafeBufferPointer { segs in
            for n in 0..<segCount {
                Self.appendSpans(segs[n], index: UInt16(n), reach: reach, tileSize: Float(ts),
                                 tx: tx, ty: ty, into: &spans)
            }
        }

        // Grow (never shrink) the rings on demand. A ring replaced mid-flight
        // is still retained by the command buffers that reference it.
        if tileCapacity < tileCount {
            tileCapacity = tileCount
            tileRing = LerpBufferRing(device: device,
                                      length: tileCount * MemoryLayout<SIMD2<UInt32>>.stride,
                                      label: "vsa.tiles")
            cursor = [UInt32](repeating: 0, count: tileCount)
        }
        guard let segBuffer = segmentRing?.next(), let tileBuffer = tileRing?.next() else { return }

        let tiles = tileBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: tileCount)
        for i in 0..<tileCount { tiles[i] = .zero }
        var total = 0
        spans.withUnsafeBufferPointer { sp in
            for s in sp {
                let base = Int(s.row) * tx
                for c in Int(s.colLo)...Int(s.colHi) { tiles[base + c].y &+= 1 }
                total += Int(s.colHi) - Int(s.colLo) + 1
            }
        }

        let needIndices = max(1, total)
        if indexCapacity < needIndices {
            indexCapacity = needIndices + needIndices / 2
            indexRing = LerpBufferRing(device: device,
                                       length: indexCapacity * MemoryLayout<UInt16>.stride,
                                       label: "vsa.indices")
        }
        guard let indexBuffer = indexRing?.next() else { return }

        let indices = indexBuffer.contents().bindMemory(to: UInt16.self, capacity: needIndices)
        cursor.withUnsafeMutableBufferPointer { cur in
            var running: UInt32 = 0
            for i in 0..<tileCount {
                tiles[i].x = running
                cur[i] = running
                running &+= tiles[i].y
            }
            spans.withUnsafeBufferPointer { sp in
                // Spans were gathered segment by segment, so scattering them in
                // order writes every tile's list in draw order.
                for s in sp {
                    let base = Int(s.row) * tx
                    for c in Int(s.colLo)...Int(s.colHi) {
                        let slot = Int(cur[base + c])
                        indices[slot] = s.segment
                        cur[base + c] = UInt32(slot + 1)
                    }
                }
            }
        }

        segments.withUnsafeBytes { src in
            let bytes = segCount * MemoryLayout<Segment>.stride
            if bytes > 0 { segBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: bytes) }
        }

        var frame = Frame(tiles: SIMD2<UInt32>(UInt32(tx), UInt32(ty)),
                          tileSize: UInt32(ts),
                          segmentCount: UInt32(segCount),
                          halfWidth: halfWidth)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentBuffer(segBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(tileBuffer, offset: 0, index: 3)
        encoder.setFragmentBuffer(indexBuffer, offset: 0, index: 4)
    }

    /// Appends one span per tile row a segment's coverage can reach: the part
    /// of the centreline inside the row's band (widened by `reach`), widened
    /// again by `reach` in x. Conservative: never misses a covered pixel.
    @inline(__always)
    private static func appendSpans(_ s: Segment, index: UInt16, reach: Float, tileSize: Float,
                                    tx: Int, ty: Int, into spans: inout [Span]) {
        let x0 = s.ends.x, y0 = s.ends.y, x1 = s.ends.z, y1 = s.ends.w
        guard x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite else { return }
        let dx = x1 - x0, dy = y1 - y0
        // Clamp in float before converting, so a far-off-screen vertex cannot
        // overflow Int().
        @inline(__always) func cell(_ v: Float, _ n: Int) -> Int {
            Int(floor(min(max(v / tileSize, -1), Float(n))))
        }
        let rowLo = max(0, cell(min(y0, y1) - reach, ty))
        let rowHi = min(ty - 1, cell(max(y0, y1) + reach, ty))
        guard rowLo <= rowHi else { return }
        for row in rowLo...rowHi {
            let bandLo = Float(row) * tileSize - reach
            let bandHi = Float(row + 1) * tileSize + reach
            var t0: Float = 0, t1: Float = 1
            if abs(dy) > 1e-6 {
                let ta = (bandLo - y0) / dy, tb = (bandHi - y0) / dy
                t0 = max(0, min(ta, tb)); t1 = min(1, max(ta, tb))
                if t0 > t1 { continue }
            }
            let xa = x0 + dx * t0, xb = x0 + dx * t1
            let colLo = max(0, cell(min(xa, xb) - reach, tx))
            let colHi = min(tx - 1, cell(max(xa, xb) + reach, tx))
            guard colLo <= colHi else { continue }
            spans.append(Span(segment: index, row: UInt16(row), colLo: UInt16(colLo), colHi: UInt16(colHi)))
        }
    }

    static let metalSource = """
    // ---- vertexshaderart lines (VertexShaderArtData.swift) -------------------
    // Fragment buffer 1: LerpVsaFrame. Buffer 2: LerpVsaSegment[], endpoints in
    // framebuffer pixels (y down, same space as [[position]]). Buffer 3: one
    // uint2 (first, count) per F.tileSize-px tile, row-major. Buffer 4: ushort
    // segment indices, ascending within each tile — ascending is upstream draw
    // order.
    struct LerpVsaFrame {
        uint2 tiles;
        uint  tileSize;
        uint  segmentCount;
        float halfWidth;   // line half-width in pixels
        float pad0, pad1, pad2;
    };
    struct LerpVsaSegment {
        float4 ends;       // p0.xy, p1.xy
        float4 color0;     // rgb at p0 (v_color of the even vertex)
        float4 color1;     // rgb at p1
    };

    // Integral of the unit tent of radius 1 from -inf to x (a C1 ramp).
    static inline float lerpVsaTentCdf(float x) {
        float a = saturate(1.0 - abs(x));
        return x < 0.0 ? 0.5 * a * a : 1.0 - 0.5 * a * a;
    }

    // Coverage profile of a line of half-width hw at distance d: the line's
    // box cross-section filtered by a radius-1-px tent (box * tent, i.e. a
    // quadratic B-spline for a 1-px line). The tent sums to exactly 1 over
    // any row of pixel centres, so a line delivers 2 * hw of light per pixel
    // of length wherever it sits between rows: no brightness crawl as it
    // moves. The plain box filter it replaces (saturate(hw + 0.5 - d)) put a
    // 1-px line at 1.0 on one row or 0.5 + 0.5 on two, which beads shallow
    // lines into stair steps and makes them crawl as they move.
    static inline float lerpVsaProfile(float d, float hw) {
        return lerpVsaTentCdf(d + hw) - lerpVsaTentCdf(d - hw);
    }

    // Composites every line in this pixel's tile front to back in draw order
    // (vertexshaderart's depth test LESS at z = 0 keeps the first-drawn
    // fragment). Returns premultiplied rgb in .rgb and coverage in .a.
    static inline float4 lerpVsaLines(float2 p,
                                      constant LerpVsaFrame& F,
                                      device const LerpVsaSegment* segs,
                                      device const uint2* tiles,
                                      device const ushort* indices) {
        uint2 tc = min(uint2(max(p, 0.0)) / F.tileSize, F.tiles - 1u);
        uint2 h = tiles[tc.y * F.tiles.x + tc.x];
        float hw = F.halfWidth;
        float reach = hw + 1.0;   // where the profile reaches zero
        float3 acc = float3(0.0);
        float alpha = 0.0;
        for (uint i = 0u; i < h.y; i++) {
            LerpVsaSegment s = segs[indices[h.x + i]];
            float2 a = s.ends.xy, b = s.ends.zw;
            float2 pa = p - a, ba = b - a;
            float t = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
            float d = length(pa - ba * t);
            if (d >= reach) continue;
            float cov = lerpVsaProfile(d, hw);
            float3 col = saturate(mix(s.color0.rgb, s.color1.rgb, t));
            acc += (1.0 - alpha) * cov * col;
            alpha += (1.0 - alpha) * cov;
            if (alpha > 0.998) break;
        }
        return float4(acc, alpha);
    }
    """

    /// Framebuffer pixels per vertexshaderart pixel. The site sizes its canvas
    /// in CSS pixels (`twgl.resizeCanvasToDisplaySize` with no multiplier), so
    /// its "1 px" lines and point-size constants are 2 physical pixels on a
    /// Retina screen. The drawable's backing scale is not known here, so take
    /// a ~1000-px short side as one CSS pixel: a 1964-px-tall MacBook drawable
    /// gives 1.96, a 750-px snapshot gives 1. Pulse Rings uses the same rule.
    static func cssPixel(_ resolution: SIMD2<Float>) -> Float {
        max(1, min(resolution.x, resolution.y) / 1000)
    }

    static func scalar(_ params: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }
}

/// "stringart" by gman on vertexshaderart.com, CC0
/// (https://www.vertexshaderart.com/art/EgLk7JDok4GhxPeMH): 500 vertices drawn
/// as LINES, i.e. 250 strings stretched between two moving rose curves. The
/// body of `vertex(_:)` is upstream's `main()` line for line.
public final class StringArtData: LerpDataProvider {
    static let vertexCount = 500

    private let lines: VertexShaderArtLines
    private var segments: [VertexShaderArtLines.Segment] = []

    public init(device: MTLDevice) {
        lines = VertexShaderArtLines(device: device, maxSegments: Self.vertexCount / 2, label: "stringart")
        segments.reserveCapacity(Self.vertexCount / 2)
    }

    public var metalPrelude: String { VertexShaderArtLines.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let speed = VertexShaderArtLines.scalar(params, "speed", 0.3)
        let lineWidth = max(0.25, VertexShaderArtLines.scalar(params, "lineWidth", 1.0))
        // Per-launch offset into time, as every shader here does.
        let time = speed * max(0, uniforms.time) + 60 * uniforms.seed
        let res = uniforms.resolution

        segments.removeAll(keepingCapacity: true)
        let v = Self.Frame(time: time)
        var i = 0
        while i + 1 < Self.vertexCount {
            let a = v.vertex(Float(i), resolution: res)
            let b = v.vertex(Float(i + 1), resolution: res)
            segments.append(.init(ends: SIMD4(a.0.x, a.0.y, b.0.x, b.0.y),
                                  color0: SIMD4(a.1, 1), color1: SIMD4(b.1, 1)))
            i += 2
        }
        lines.bind(segments, halfWidth: 0.5 * lineWidth * VertexShaderArtLines.cssPixel(res),
                   resolution: res, to: encoder)
    }

    /// Per-frame uniforms of upstream's vertex shader, hoisted.
    struct Frame {
        let offsets: SIMD4<Float>
        let centers: SIMD4<Float>
        let mult: SIMD2<Float>

        init(time: Float) {
            let pi = Float.pi
            offsets = SIMD4(sin(time),
                            sin(time * 0.13) * pi * 2,
                            sin(time * 0.43) * 0.5 + 1,
                            cos(time * 0.17) * 0.5 + 0.5)
            centers = SIMD4(sin(time * 0.163) * 0.5,
                            cos(time * 0.267) * 0.5,
                            sin(time * 0.367) * 0.5,
                            cos(time * 0.497) * 0.5)
            mult = SIMD2(1, (sin(time * 0.1) * 0.5 + 0.5) * 3)
        }

        /// Upstream `main()` for one vertex: framebuffer position (pixels,
        /// y down) and `v_color.rgb`.
        func vertex(_ vertexId: Float, resolution: SIMD2<Float>) -> (SIMD2<Float>, SIMD3<Float>) {
            let pi = Float.pi
            let position = SIMD2<Float>(vertexId / Float(StringArtData.vertexCount),
                                        vertexId.truncatingRemainder(dividingBy: 2))
            // mix(offsets.xz, offsets.yw, position.y)
            let offset = SIMD2(offsets.x, offsets.z) * (1 - position.y)
                       + SIMD2(offsets.y, offsets.w) * position.y
            let a = mult.x * position.x * pi * 2 + offset.x
            let c = cos(a * mult.y)
            let center = SIMD2(centers.x, centers.y) * (1 - position.y)
                       + SIMD2(centers.z, centers.w) * position.y
            let xy = SIMD2(cos(a), sin(a)) * c * offset.y + center
            // gl_Position = xy * vec2(H/W, 1): one unit is H/2 pixels, y up.
            let half = 0.5 * resolution
            let px = SIMD2(half.x + xy.x * half.y, half.y - xy.y * half.y)
            return (px, StringArtData.hsv2rgb(SIMD3(position.x, 1, 1)))
        }
    }

    static func hsv2rgb(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let s = min(max(c.y, 0), 1), v = min(max(c.z, 0), 1)
        let k = SIMD3<Float>(1, 2.0 / 3.0, 1.0 / 3.0)
        var p = SIMD3<Float>(repeating: 0)
        for i in 0..<3 {
            let f = c.x + k[i]
            p[i] = abs((f - floor(f)) * 6 - 3)
        }
        let q = (p - 1).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
        return v * (SIMD3(repeating: 1) * (1 - s) + q * s)
    }
}
