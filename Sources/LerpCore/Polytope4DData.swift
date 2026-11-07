import Foundation
import Metal
import simd

/// CPU side of `polytope-4d`: regular 4D polytopes (and duoprisms) turning in
/// a double rotation, projected to 3D and then to the screen, drawn as glowing
/// tubes with beads at the vertices.
///
/// **Geometry** is mathematical fact, generated here from the textbook
/// coordinate sets (all on the unit 3-sphere):
///
///   8-cell (tesseract)  16 vertices  (±½, ±½, ±½, ±½)
///   16-cell              8 vertices  permutations of (±1, 0, 0, 0)
///   24-cell             24 vertices  the 24 Hurwitz units: 16-cell ∪ 8-cell
///   600-cell           120 vertices  the 120 unit icosians: 24-cell ∪ even
///                                    permutations of ½(±φ, ±1, ±1/φ, 0)
///   120-cell           600 vertices  the seven permutation classes of the
///                                    standard radius-√8 set, rescaled
///   p,q-duoprism       p·q vertices  (cos 2πi/p, sin 2πi/p, cos 2πj/q, sin 2πj/q)/√2,
///                                    which lies on the Clifford torus
///
/// Edges of the regular ones are the vertex pairs at the minimum distance, so
/// no edge list is typed in. Counts are checked in `selfTest()`.
///
/// **Projection.** Perspective from a 4D eye on the w axis keeps edges
/// straight. Stereographic projection from the pole w = 1 of S³ is conformal
/// and maps each great-circle edge to a circular arc in 3D; those arcs are
/// subdivided adaptively in screen space until flat to half a pixel, and cut
/// cleanly where they fade out near the pole. A 3D perspective camera then
/// takes everything to framebuffer pixels.
///
/// **Purity.** Geometry is a constant of the polytope choice (cached by that
/// key alone); the rotation, projection and every segment are recomputed from
/// `(time, seed, params)` each frame. Nothing carries over.
///
/// **Cost.** Each segment carries its own reach (tube radius + glow), and is
/// binned into screen tiles by a counting sort written straight into the GPU
/// buffers, as `VertexShaderArtLines` does. A pixel walks only its tile.
///
/// GPU bindings (see `metalPrelude`):
///
///     fragment buffer 1   LerpP4Frame   tile grid, tile edge, segment count, glow width
///     fragment buffer 2   LerpP4Seg[]   endpoints (px, y down) + per-end attributes
///     fragment buffer 3   uint2[]       per tile: (first, count) into buffer 4
///     fragment buffer 4   uint[]        segment indices, ascending within a tile
public final class Polytope4DData: LerpDataProvider {

    /// Must match `LerpP4Frame`.
    struct Frame {
        var tiles: SIMD2<UInt32>
        var tileSize: UInt32
        var segmentCount: UInt32
        var glowPx: Float
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    /// Must match `LerpP4Seg`. Per end: x = radius px, y = w cue 0…1,
    /// z = intensity, w = id (edge index, or −1 − vertex index for a bead;
    /// equal at both ends). Sub-segments of one arc share an id and are
    /// consecutive, so the shader can take the max over them instead of
    /// summing overlapping joints.
    struct Segment {
        var ends: SIMD4<Float>
        var a0: SIMD4<Float>
        var a1: SIMD4<Float>
    }

    struct Shape {
        var vertices: [SIMD4<Float>]
        var edges: [SIMD2<Int32>]
    }

    private struct Span {
        var segment: UInt32
        var row: UInt16
        var colLo: UInt16
        var colHi: UInt16
    }

    /// A projected point.
    private struct PP {
        var px: SIMD2<Float>
        var r: Float        // tube radius in px at this point
        var wcue: Float
        var fade: Float
        var radius3: Float  // |X| in 3D, for the stereographic cut
        var ok: Bool        // inside the drawable region of 3D space
    }

    static let maxSegments = 65_536

    private let device: MTLDevice
    private let segmentRing: LerpBufferRing?
    private var tileRing: LerpBufferRing?
    private var tileCapacity = 0
    private var indexRing: LerpBufferRing?
    private var indexCapacity = 0
    private var spans: [Span] = []
    private var cursor: [UInt32] = []
    private var segments: [Segment] = []
    private var projected: [PP] = []
    private var rotated: [SIMD4<Float>] = []

    private var shapeKey: SIMD3<Int32> = SIMD3(-1, -1, -1)
    private var shape = Shape(vertices: [], edges: [])

    /// Wall-clock CPU cost of the last `bind`, for benchmarking.
    public private(set) var lastBindSeconds: Double = 0

    public init(device: MTLDevice) {
        self.device = device
        segmentRing = LerpBufferRing(device: device,
                                     length: Self.maxSegments * MemoryLayout<Segment>.stride,
                                     label: "polytope4d.segments")
        segments.reserveCapacity(8192)
        spans.reserveCapacity(32768)
        // Room for the densest preset at 5K up front, so the ring does not
        // reallocate (and zero-fill) mid-run.
        indexCapacity = 1 << 18
        indexRing = LerpBufferRing(device: device,
                                   length: indexCapacity * MemoryLayout<UInt32>.stride,
                                   label: "polytope4d.indices")
    }

    public var metalPrelude: String { Self.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    // MARK: - Per frame

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let start = DispatchTime.now().uptimeNanoseconds
        defer { lastBindSeconds = Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9 }

        let res = SIMD2<Float>(max(1, uniforms.resolution.x), max(1, uniforms.resolution.y))
        buildSegments(uniforms: uniforms, params: params, resolution: res)
        let glowPx = Self.glowPx(params, res)
        upload(glowPx: glowPx, resolution: res, to: encoder)
    }

    static func scalar(_ params: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }

    static func glowPx(_ params: LerpParameterValues?, _ res: SIMD2<Float>) -> Float {
        let glow = min(1, max(0, scalar(params, "glow", 0.5)))
        return glow * 0.014 * min(res.x, res.y)
    }

    /// Fills `segments` for one frame. Separate from `bind` so the self-test
    /// can run it without an encoder.
    func buildSegments(uniforms: LerpUniforms, params: LerpParameterValues?, resolution res: SIMD2<Float>) {
        let kind = Int32(min(5, max(0, Self.scalar(params, "polytope", 0).rounded())))
        let duoP = Int32(min(32, max(3, Self.scalar(params, "duoP", 6).rounded())))
        let duoQ = Int32(min(32, max(3, Self.scalar(params, "duoQ", 6).rounded())))
        let key = SIMD3(kind, kind == 5 ? duoP : 0, kind == 5 ? duoQ : 0)
        if key != shapeKey {
            shape = Self.makeShape(kind: Int(kind), p: Int(duoP), q: Int(duoQ))
            shapeKey = key
        }

        let stereo = Self.scalar(params, "stereographic", 0) > 0.5
        let speed = max(0, Self.scalar(params, "speed", 0.5))
        let twist = max(0, Self.scalar(params, "twist", 0.62))
        let eye4 = max(1.05, Self.scalar(params, "eye4", 2.4))
        let zoom = max(0.05, Self.scalar(params, "zoom", 1.0))
        let tube = max(0, Self.scalar(params, "tube", 0.011))
        let node = max(0, Self.scalar(params, "node", 0.026))
        let depthCue = min(1, max(0, Self.scalar(params, "depthCue", 0.7)))

        let seed = uniforms.seed
        let rotation = Self.rotation(time: max(0, uniforms.time), seed: seed, speed: speed, twist: twist)

        let short = min(res.x, res.y)
        let half = 0.5 * short
        let center = 0.5 * res
        let fit = half * zoom * (stereo ? 0.6 : 0.84)
        let cam: Float = 4.5            // 3D camera distance, figure radius ~1
        let fadeIn: Float = 1.5, fadeOut: Float = 2.6
        let zNear: Float = 2.4, zFar: Float = 3.4
        let perspNorm = sqrt(eye4 * eye4 - 1)
        let maxR = 0.045 * short
        // Arcs are subdivided until flat to about a pixel and a half at 4K.
        let tol = max(0.6, short / 1400)
        // A fixed 3D tilt so the first frame is not a face-on view, then the
        // drag's turn (`LerpTurn`): the camera stays put on +z and the figure
        // turns the opposite way, which is the same picture.
        var tilt = Self.tilt
        let yaw = Self.scalar(params, LerpTurn.yawParameter, 0)
        let pitch = Self.scalar(params, LerpTurn.pitchParameter, 0)
        if yaw != 0 || pitch != 0 {
            let q = LerpTurn.orbitRotation(yaw: yaw, pitch: pitch, up: SIMD3(0, 1, 0),
                                           right: SIMD3(1, 0, 0), fwd: SIMD3(0, 0, -1))
            tilt = simd_float3x3(q.inverse) * tilt
        }

        @inline(__always) func project(_ v4: SIMD4<Float>) -> PP {
            var X: SIMD3<Float>
            var k: Float
            if stereo {
                let den = 1 - v4.w
                if den < 1e-4 { return PP(px: .zero, r: 0, wcue: 1, fade: 0, radius3: .infinity, ok: false) }
                k = 1 / den
                X = SIMD3(v4.x, v4.y, v4.z) * k
            } else {
                k = perspNorm / (eye4 - v4.w)
                X = SIMD3(v4.x, v4.y, v4.z) * k
            }
            let r3 = simd_length(X)
            let P = tilt * X
            let zc = cam - P.z
            if zc < 0.2 { return PP(px: .zero, r: 0, wcue: 1, fade: 0, radius3: r3, ok: false) }
            let persp = cam / zc
            let s = SIMD2(P.x, P.y) * (persp * fit)
            let px = SIMD2(center.x + s.x, center.y - s.y)
            let r = min(maxR, tube * k * persp * half * zoom)
            var fade: Float = 1
            if stereo {
                // Fade out far from the origin (toward the pole) and close to
                // the camera, where a short edge would sweep across the screen.
                let f = min(1, max(0, (r3 - fadeIn) / (fadeOut - fadeIn)))
                let c = min(1, max(0, (zc - zNear) / (zFar - zNear)))
                fade = (1 - f * f * (3 - 2 * f)) * (c * c * (3 - 2 * c))
            }
            let wcue = 0.5 + 0.5 * v4.w
            return PP(px: px, r: r, wcue: wcue, fade: fade, radius3: r3, ok: !stereo || fade > 0)
        }

        @inline(__always) func intensity(_ p: PP) -> Float {
            p.fade * ((1 - depthCue) + depthCue * (0.22 + 0.78 * p.wcue))
        }

        segments.removeAll(keepingCapacity: true)
        let verts = shape.vertices
        rotated.removeAll(keepingCapacity: true)
        projected.removeAll(keepingCapacity: true)
        for v in verts {
            let r = rotation * v
            rotated.append(r)
            projected.append(project(r))
        }

        @inline(__always) func emit(_ a: PP, _ b: PP, id: Float) {
            guard segments.count < Self.maxSegments else { return }
            let ia = intensity(a), ib = intensity(b)
            if ia < 0.002 && ib < 0.002 { return }
            guard a.px.x.isFinite, a.px.y.isFinite, b.px.x.isFinite, b.px.y.isFinite else { return }
            segments.append(Segment(ends: SIMD4(a.px.x, a.px.y, b.px.x, b.px.y),
                                    a0: SIMD4(a.r, a.wcue, ia, id),
                                    a1: SIMD4(b.r, b.wcue, ib, id)))
        }

        // Edges.
        let edges = shape.edges
        var stack: [(Float, PP, Float, PP, Int)] = []
        stack.reserveCapacity(32)
        for (e, edge) in edges.enumerated() {
            let ia = Int(edge.x), ib = Int(edge.y)
            let id = Float(e)
            if !stereo {
                let a = projected[ia], b = projected[ib]
                if a.ok && b.ok { emit(a, b, id: id) }
                continue
            }
            // Great-circle arc a → b on S³, slerped.
            let a4 = rotated[ia], b4 = rotated[ib]
            let cosO = min(1, max(-1, simd_dot(a4, b4)))
            let omega = acos(cosO)
            let sinO = sin(omega)
            @inline(__always) func at(_ t: Float) -> PP {
                let v = (sin((1 - t) * omega) * a4 + sin(t * omega) * b4) / sinO
                return project(v)
            }
            // Explicit stack instead of recursion: (t0, t1, depth) with cached ends.
            stack.removeAll(keepingCapacity: true)
            stack.append((0, projected[ia], 1, projected[ib], 0))
            while case let (t0, p0, t1, p1, depth)? = stack.popLast() {
                if !p0.ok && !p1.ok {
                    // Both ends beyond the cut: the arc may still dip back in.
                    if depth >= 3 { continue }
                    let tm = 0.5 * (t0 + t1)
                    let m = at(tm)
                    stack.append((tm, m, t1, p1, depth + 1))
                    stack.append((t0, p0, tm, m, depth + 1))
                    continue
                }
                if p0.ok != p1.ok {
                    // Bisect for the cut, where fade has already reached 0.
                    var lo = p0.ok ? t0 : t1, hi = p0.ok ? t1 : t0
                    for _ in 0..<8 {
                        let mid = 0.5 * (lo + hi)
                        if at(mid).ok { lo = mid } else { hi = mid }
                    }
                    var c = at(lo)
                    c.fade = 0
                    if p0.ok { stack.append((t0, p0, lo, c, depth)) }
                    else { stack.append((lo, c, t1, p1, depth)) }
                    continue
                }
                let tm = 0.5 * (t0 + t1)
                let m = at(tm)
                let chordMid = 0.5 * (p0.px + p1.px)
                let flat = m.ok
                    && simd_length(m.px - chordMid) < tol
                    && abs(m.r - 0.5 * (p0.r + p1.r)) < max(tol, 0.06 * m.r)
                if flat || depth >= 7 {
                    emit(p0, p1, id: id)
                } else {
                    stack.append((tm, m, t1, p1, depth + 1))
                    stack.append((t0, p0, tm, m, depth + 1))
                }
            }
        }

        // Beads at the vertices, after the edges.
        if node > 0 {
            let nodeScale = node / max(tube, 1e-6)
            for (i, p) in projected.enumerated() where p.ok {
                var q = p
                q.r = min(maxR * 1.6, p.r * nodeScale)
                emit(q, q, id: -1 - Float(i))
            }
        }
    }

    // MARK: - Rotation

    static let tilt: simd_float3x3 = {
        let ax: Float = 0.42, ay: Float = -0.31
        let rx = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(ax), -sin(ax)), SIMD3(0, sin(ax), cos(ax))])
        let ry = simd_float3x3(rows: [SIMD3(cos(ay), 0, sin(ay)), SIMD3(0, 1, 0), SIMD3(-sin(ay), 0, cos(ay))])
        return ry * rx
    }()

    @inline(__always) static func hash(_ x: Float) -> Float {
        let v = sin(x * 127.1 + 311.7) * 43758.5453
        return v - floor(v)
    }

    /// Rotation by `angle` in the plane of axes (i, j).
    static func planeRotation(_ i: Int, _ j: Int, _ angle: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        let c = cos(angle), s = sin(angle)
        m[i][i] = c; m[j][j] = c
        m[i][j] = s; m[j][i] = -s
        return m
    }

    /// Seeded starting orientation, then a double rotation in two completely
    /// orthogonal planes — one of them always containing w, so the figure
    /// turns inside out through itself, the other an ordinary 3D spin at
    /// `twist` times the rate. The seed picks the plane pair, phase and a
    /// slight detune of the rate ratio.
    static func rotation(time: Float, seed: Float, speed: Float, twist: Float) -> simd_float4x4 {
        var q = matrix_identity_float4x4
        let planes = [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]
        for (n, pl) in planes.enumerated() {
            let a = (hash(seed * 17.3 + Float(n) * 3.7) - 0.5) * 1.6
            q = planeRotation(pl.0, pl.1, a) * q
        }
        // Complementary pairs: (w-plane, its orthogonal complement).
        let pairs = [((0, 3), (1, 2)), ((1, 3), (0, 2)), ((2, 3), (0, 1))]
        let pick = pairs[min(2, Int(hash(seed * 5.1 + 0.3) * 3))]
        let detune = 0.9 + 0.2 * hash(seed * 9.7 + 1.1)
        let base = 0.16 * speed * time + seed * 37
        let d = planeRotation(pick.0.0, pick.0.1, base)
              * planeRotation(pick.1.0, pick.1.1, base * twist * detune + seed * 11)
        return d * q
    }

    // MARK: - Geometry

    static let phi: Float = (1 + sqrt(5)) / 2

    /// The 24 permutations of 4 indices, each flagged even or odd.
    static let permutations: [([Int], Bool)] = {
        var out: [([Int], Bool)] = []
        func go(_ prefix: [Int], _ rest: [Int]) {
            if rest.isEmpty {
                var inv = 0
                for i in 0..<4 { for j in (i + 1)..<4 where prefix[i] > prefix[j] { inv += 1 } }
                out.append((prefix, inv % 2 == 0))
                return
            }
            for (k, x) in rest.enumerated() {
                var r = rest; r.remove(at: k)
                go(prefix + [x], r)
            }
        }
        go([], [0, 1, 2, 3])
        return out
    }()

    /// Every signed (even) permutation of `base`, deduplicated.
    static func orbit(_ base: [Float], evenOnly: Bool, into set: inout [SIMD4<Float>], seen: inout Set<SIMD4<Int32>>) {
        for (perm, even) in permutations where even || !evenOnly {
            for mask in 0..<16 {
                var v = SIMD4<Float>()
                var skip = false
                for i in 0..<4 {
                    let x = base[perm[i]]
                    let neg = (mask >> i) & 1 == 1
                    if neg && x == 0 { skip = true; break }   // count each sign pattern once
                    v[i] = neg ? -x : x
                }
                if skip { continue }
                let key = SIMD4<Int32>((v * 4096).rounded(.toNearestOrEven))
                if seen.insert(key).inserted { set.append(v) }
            }
        }
    }

    static func regular(_ classes: [([Float], Bool)]) -> Shape {
        var verts: [SIMD4<Float>] = []
        var seen = Set<SIMD4<Int32>>()
        for (base, even) in classes { orbit(base, evenOnly: even, into: &verts, seen: &seen) }
        let radius = simd_length(verts[0])
        verts = verts.map { $0 / radius }
        // Edges: pairs at the minimum distance.
        var minD2 = Float.infinity
        for i in 0..<verts.count {
            for j in (i + 1)..<verts.count {
                let d = simd_length_squared(verts[i] - verts[j])
                if d > 1e-6 { minD2 = min(minD2, d) }
            }
        }
        var edges: [SIMD2<Int32>] = []
        let limit = minD2 * 1.001
        for i in 0..<verts.count {
            for j in (i + 1)..<verts.count where simd_length_squared(verts[i] - verts[j]) < limit {
                edges.append(SIMD2(Int32(i), Int32(j)))
            }
        }
        return Shape(vertices: verts, edges: edges)
    }

    static func makeShape(kind: Int, p: Int, q: Int) -> Shape {
        let h: Float = 0.5
        let f = phi, g = 1 / phi
        switch kind {
        case 1:  // 16-cell
            return regular([([1, 0, 0, 0], false)])
        case 2:  // 24-cell: Hurwitz units
            return regular([([1, 0, 0, 0], false), ([h, h, h, h], false)])
        case 3:  // 600-cell: unit icosians
            return regular([([1, 0, 0, 0], false), ([h, h, h, h], false),
                            ([h * f, h, h * g, 0], true)])
        case 4:  // 120-cell, circumradius √8
            let s5 = Float(5).squareRoot()
            return regular([([0, 0, 2, 2], false),
                            ([1, 1, 1, s5], false),
                            ([g * g, f, f, f], false),
                            ([g, g, g, f * f], false),
                            ([0, g * g, 1, f * f], true),
                            ([0, g, f, s5], true),
                            ([g, 1, f, 2], true)])
        case 5:  // p,q-duoprism on the Clifford torus
            var verts: [SIMD4<Float>] = []
            var edges: [SIMD2<Int32>] = []
            let r = 1 / Float(2).squareRoot()
            for i in 0..<p {
                for j in 0..<q {
                    let a = 2 * Float.pi * Float(i) / Float(p)
                    let b = 2 * Float.pi * Float(j) / Float(q)
                    verts.append(SIMD4(cos(a), sin(a), cos(b), sin(b)) * r)
                }
            }
            for i in 0..<p {
                for j in 0..<q {
                    let n = Int32(i * q + j)
                    edges.append(SIMD2(n, Int32(((i + 1) % p) * q + j)))
                    edges.append(SIMD2(n, Int32(i * q + (j + 1) % q)))
                }
            }
            return Shape(vertices: verts, edges: edges)
        default:  // 8-cell, the tesseract
            return regular([([h, h, h, h], false)])
        }
    }

    /// Vertex and edge counts of every shape, plus a cold-vs-warm purity check.
    public static func selfTest() -> String? {
        let expect: [(Int, Int, Int)] = [(0, 16, 32), (1, 8, 24), (2, 24, 96), (3, 120, 720), (4, 600, 1200)]
        for (k, v, e) in expect {
            let s = makeShape(kind: k, p: 0, q: 0)
            if s.vertices.count != v || s.edges.count != e {
                return "kind \(k): \(s.vertices.count) vertices / \(s.edges.count) edges, expected \(v) / \(e)"
            }
        }
        let d = makeShape(kind: 5, p: 5, q: 7)
        if d.vertices.count != 35 || d.edges.count != 70 { return "5,7-duoprism counts" }
        return nil
    }

    // MARK: - Binning and upload

    private func upload(glowPx: Float, resolution: SIMD2<Float>, to encoder: MTLRenderCommandEncoder) {
        let segCount = segments.count
        let ts = VertexShaderArtLines.tileSize(for: resolution)
        let tx = max(1, Int((resolution.x / Float(ts)).rounded(.up)))
        let ty = max(1, Int((resolution.y / Float(ts)).rounded(.up)))
        let tileCount = tx * ty

        spans.removeAll(keepingCapacity: true)
        segments.withUnsafeBufferPointer { segs in
            for n in 0..<segCount {
                let s = segs[n]
                let reach = max(s.a0.x, s.a1.x) + glowPx + 1.5
                Self.appendSpans(s.ends, index: UInt32(n), reach: reach, tileSize: Float(ts),
                                 tx: tx, ty: ty, into: &spans)
            }
        }

        if tileCapacity < tileCount {
            tileCapacity = tileCount
            tileRing = LerpBufferRing(device: device,
                                      length: tileCount * MemoryLayout<SIMD2<UInt32>>.stride,
                                      label: "polytope4d.tiles")
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

        let need = max(1, total)
        if indexCapacity < need {
            indexCapacity = need + need / 2
            indexRing = LerpBufferRing(device: device,
                                       length: indexCapacity * MemoryLayout<UInt32>.stride,
                                       label: "polytope4d.indices")
        }
        guard let indexBuffer = indexRing?.next() else { return }
        let indices = indexBuffer.contents().bindMemory(to: UInt32.self, capacity: need)
        cursor.withUnsafeMutableBufferPointer { cur in
            var running: UInt32 = 0
            for i in 0..<tileCount {
                tiles[i].x = running
                cur[i] = running
                running &+= tiles[i].y
            }
            spans.withUnsafeBufferPointer { sp in
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

        var frame = Frame(tiles: SIMD2(UInt32(tx), UInt32(ty)), tileSize: UInt32(ts),
                          segmentCount: UInt32(segCount), glowPx: glowPx)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentBuffer(segBuffer, offset: 0, index: 2)
        encoder.setFragmentBuffer(tileBuffer, offset: 0, index: 3)
        encoder.setFragmentBuffer(indexBuffer, offset: 0, index: 4)
    }

    /// One span per tile row the segment's coverage (centreline widened by
    /// `reach`) can touch. Conservative.
    @inline(__always)
    private static func appendSpans(_ e: SIMD4<Float>, index: UInt32, reach: Float, tileSize: Float,
                                    tx: Int, ty: Int, into spans: inout [Span]) {
        let x0 = e.x, y0 = e.y, x1 = e.z, y1 = e.w
        let dx = x1 - x0, dy = y1 - y0
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
    // ---- polytope-4d (Polytope4DData.swift) ---------------------------------
    // Buffer 1: LerpP4Frame. Buffer 2: LerpP4Seg[], endpoints in framebuffer
    // pixels (y down, the space of [[position]]). Buffer 3: one uint2
    // (first, count) per F.tileSize-px tile, row-major. Buffer 4: uint segment
    // indices, ascending within each tile, so sub-segments of one arc (same
    // id) are consecutive.
    struct LerpP4Frame {
        uint2 tiles;
        uint  tileSize;
        uint  segmentCount;
        float glowPx;      // halo reach past the tube surface, pixels
        float pad0, pad1, pad2;
    };
    struct LerpP4Seg {
        float4 ends;       // p0.xy, p1.xy
        float4 a0;         // at p0: radius px, w cue 0..1, intensity, id
        float4 a1;         // at p1: same; id equal. id < 0: a vertex bead
    };
    """
}

extension Polytope4DData {
    /// The last frame's segments as bytes, and their count: for checking
    /// that a frame is a pure function of its inputs.
    var debugSegmentBytes: [UInt8] { segments.withUnsafeBytes { Array($0) } }
    var debugSegmentCount: Int { segments.count }
}
