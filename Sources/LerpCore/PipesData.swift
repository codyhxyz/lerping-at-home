import Foundation
import Metal

/// CPU side of the `pipes` shader: the self-avoiding lattice walk that
/// Microsoft's 3D Pipes screensaver (sspipes) drew with OpenGL in 1994.
///
/// Geometry constants are taken from the original: a lattice of `numDiv - 1`
/// = 15 nodes across the window's long axis, `numDiv - 1 / aspect` across the
/// short one, spaced `divSize` = 7 units apart, with a pipe radius of 1 —
/// i.e. **radius = 1/7 of the lattice spacing** — and ball joints of
/// **√2 × radius**. Two to four pipes grow at once, each until it boxes itself
/// in, and after a handful of pipes the volume wipes and starts over from a
/// slightly different viewing angle.
///
/// The whole walk is regenerated from scratch every frame from `(seed, time)`;
/// nothing is carried across frames, so a frame stays a pure function of its
/// uniforms. It costs a few thousand integer steps over a ~2000-entry grid.
///
/// The GPU never sees a segment list. Each *lattice node* owns all the geometry
/// inside its own cell: a joint ball at the centre plus up to six half-length
/// stubs reaching exactly to the cell faces. A pipe between two nodes is one
/// stub from each side. That makes the scene trivially spatially indexed — the
/// shader walks the ray cell by cell and evaluates one node record per cell,
/// so cost does not grow with the number of pipes on screen.
///
/// Node record, one `uint` per lattice node:
///
///     bits  0…5   connection mask, one bit per direction (+x −x +y −y +z −z)
///     bits  6…9   material index
///     bit  10     occupied
///     bits 11…13  partial-stub direction (the growing tip)
///     bit  14     has a partial stub
///     bit  15     partial stub is *inward*: spans [0.5 − len, 0.5] from the
///                 cell face toward the centre, rather than [0, len] outward
///     bits 16…31  partial stub length, 16-bit fixed point over [0, 0.5]
public final class PipesData: LerpDataProvider {

    // MARK: - Tunables (original values noted)

    /// `NUM_DIV - 1` nodes along the window's long axis; the short axis gets
    /// the same divided by the aspect ratio. Original: NUM_DIV = 16.
    static let nodesLongAxis = 15
    /// Floor on the short axis, and ceiling on the long one, so ultrawide and
    /// very tall windows still get a sensibly shaped volume. See `dimensions`.
    static let minNodesShortAxis = 7
    static let maxNodesPerAxis = 32
    /// Pipes growing at once. Original: `ss_iRand2(2, MAX_DRAW_THREADS = 4)`.
    static let concurrentPipes = 3
    /// Pipes drawn before the volume wipes. Original: NORMAL_PIPE_COUNT = 5
    /// plus the threads already running.
    static let pipesPerCycle = 8
    /// Lattice steps per second, per pipe. The original just drew one segment
    /// per pipe per frame, so this tracked the machine; slowed to house pace.
    static let stepsPerSecond: Float = 8.0
    /// Ceiling on steps per pipe per cycle. The volume saturates at roughly 42%
    /// of nodes after about 290 steps — all eight pipes box themselves in — so
    /// this is set just past that: enough headroom for a lucky seed, not so much
    /// that the picture sits frozen waiting for the wipe.
    static let stepsPerCycle = 330
    /// Relative weight of "keep going straight" against each of the four turns.
    static let straightWeight = 5
    /// Seconds the finished volume is held before the wipe, and the wipe length.
    /// The original punched out black squares in a pseudo-random dissolve; this
    /// is a plain fade.
    static let holdSeconds: Float = 3.0
    static let fadeSeconds: Float = 0.8

    static var growSeconds: Float { Float(stepsPerCycle) / stepsPerSecond }
    static var cycleSeconds: Float { growSeconds + holdSeconds + fadeSeconds }

    // MARK: - GPU-visible frame block (fragment buffer 1)

    /// Must match `LerpPipesFrame` in `metalPrelude`.
    struct Frame {
        var dim: SIMD4<UInt32>   // xyz = lattice nodes per axis
        var fade: Float          // 1 while drawing, → 0 through the wipe
        var cycleTime: Float
        var cycleIndex: Float
        var pad: Float = 0
    }

    // MARK: - Bit layout

    private static let occupiedBit: UInt32 = 1 << 10
    private static let partialBit: UInt32 = 1 << 14
    private static let inwardBit: UInt32 = 1 << 15

    private static let delta: [(Int, Int, Int)] = [
        (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
    ]

    // MARK: - State (GPU scratch only — carries no simulation state)

    private let ring: LerpBufferRing?
    private var nodes: [UInt32]
    private var dim = SIMD3<Int>(15, 9, 15)

    public init(device: MTLDevice) {
        // Worst case over every aspect ratio: long axis capped, short axis at
        // the full count, depth fixed. ~29 KB.
        let capacity = PipesData.maxNodesPerAxis * PipesData.nodesLongAxis * PipesData.nodesLongAxis
        nodes = [UInt32](repeating: 0, count: capacity)
        ring = LerpBufferRing(device: device,
                              length: capacity * MemoryLayout<UInt32>.stride,
                              count: 3,
                              label: "pipes.nodes")
    }

    // MARK: - LerpDataProvider

    public var metalPrelude: String { PipesData.metalSource }

    /// Lattice dimensions for a window. Up to 15:7 this is exactly the
    /// original's rule — the screen's long axis gets the full 15 nodes and the
    /// short one gets 15 / aspect, which keeps the volume inside the frustum as
    /// the scene yaws. The original's own comment warns it breaks down when the
    /// aspect ratio strays far from 1, and it does: on a 32:9 display it
    /// collapses the volume to four nodes tall, a postage stamp in the middle of
    /// the screen. Past 15:7 the short axis is pinned and the long one grows
    /// instead, which keeps the frame filled.
    static func dimensions(for resolution: SIMD2<Float>) -> SIMD3<Int> {
        let w = max(1, resolution.x), h = max(1, resolution.y)
        let landscape = w >= h
        let aspect = landscape ? w / h : h / w
        let n = nodesLongAxis
        let pivot = Float(n) / Float(minNodesShortAxis)   // 15:7

        var long = n, short = minNodesShortAxis
        if aspect <= pivot {
            short = max(minNodesShortAxis, min(n, Int(Float(n) / aspect)))
        } else {
            long = min(maxNodesPerAxis, Int((Float(minNodesShortAxis) * aspect).rounded()))
        }
        return landscape ? SIMD3<Int>(long, short, n) : SIMD3<Int>(short, long, n)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        dim = PipesData.dimensions(for: uniforms.resolution)

        // Offset the clock by the seed so each activation opens on a different
        // point of the growth cycle instead of always on an empty volume.
        let cycle = PipesData.cycleSeconds
        let t = max(0, uniforms.time) + uniforms.seed * cycle
        let cycleIndex = floor(t / cycle)
        let local = t - cycleIndex * cycle

        let progress = min(local * PipesData.stepsPerSecond, Float(PipesData.stepsPerCycle))
        let fullSteps = Int(progress)
        let frac = progress - Float(fullSteps)

        let wipeStart = PipesData.growSeconds + PipesData.holdSeconds
        let fade = local <= wipeStart
            ? 1
            : max(0, 1 - (local - wipeStart) / PipesData.fadeSeconds)

        // Distinct integer stream per (seed, cycle).
        let seedBits = UInt64(uniforms.seed.bitPattern) &* 0x9E37_79B9_7F4A_7C15
        let rngSeed = seedBits ^ (UInt64(bitPattern: Int64(cycleIndex)) &* 0xD1B5_4A32_D192_ED03)

        build(fullSteps: fullSteps, frac: frac, rngSeed: rngSeed)

        var frame = Frame(dim: SIMD4<UInt32>(UInt32(dim.x), UInt32(dim.y), UInt32(dim.z), 0),
                          fade: fade,
                          cycleTime: local,
                          cycleIndex: cycleIndex)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)

        guard let buffer = ring?.next() else { return }
        nodes.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        encoder.setFragmentBuffer(buffer, offset: 0, index: 2)
    }

    // MARK: - Deterministic walk

    private struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    private struct Pipe {
        var x = 0, y = 0, z = 0
        var dir = 0
        var color: UInt32 = 0
    }

    @inline(__always) private func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (z * dim.y + y) * dim.x + x
    }

    @inline(__always) private func free(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        x >= 0 && y >= 0 && z >= 0 && x < dim.x && y < dim.y && z < dim.z
            && nodes[index(x, y, z)] & PipesData.occupiedBit == 0
    }

    /// Picks the next lattice direction for a pipe, or nil if it is boxed in.
    /// Consumes exactly one RNG draw when at least one neighbour is free, which
    /// is what lets the caller *peek* the direction for the partially-grown tip
    /// without desynchronising the next frame's regeneration. Allocation-free:
    /// this runs a few thousand times per frame.
    private func chooseDirection(_ pipe: Pipe, _ rng: inout RNG) -> Int? {
        var weights = SIMD8<Int32>(repeating: 0)
        var total = 0
        let back = pipe.dir ^ 1
        for d in 0..<6 where d != back {
            let (dx, dy, dz) = PipesData.delta[d]
            guard free(pipe.x + dx, pipe.y + dy, pipe.z + dz) else { continue }
            let weight = (d == pipe.dir) ? PipesData.straightWeight : 1
            weights[d] = Int32(weight)
            total += weight
        }
        guard total > 0 else { return nil }
        var pick = rng.below(total)
        for d in 0..<6 {
            pick -= Int(weights[d])
            if pick < 0 { return d }
        }
        return nil
    }

    /// Drops a new pipe head on a free node in a new material.
    private func spawn(_ rng: inout RNG, avoiding previousColor: UInt32) -> Pipe? {
        for _ in 0..<200 {
            let x = rng.below(dim.x), y = rng.below(dim.y), z = rng.below(dim.z)
            guard free(x, y, z) else { continue }
            // 15-of-16 draw offset off the last material, so consecutive pipes
            // never come up the same colour.
            let color = (previousColor &+ UInt32(1 + rng.below(15))) & 15
            let pipe = Pipe(x: x, y: y, z: z, dir: rng.below(6), color: color)
            // Start facing somewhere it can actually go.
            if chooseDirection(pipe, &rng) == nil { continue }
            nodes[index(x, y, z)] = PipesData.occupiedBit | (pipe.color << 6)
            return pipe
        }
        return nil
    }

    private func build(fullSteps: Int, frac: Float, rngSeed: UInt64) {
        let count = dim.x * dim.y * dim.z
        for i in 0..<count { nodes[i] = 0 }

        var rng = RNG(state: rngSeed &+ 0x1234_5678_9ABC_DEF0)
        _ = rng.next()

        var pipes = [Pipe?](repeating: nil, count: PipesData.concurrentPipes)
        var started = 0
        for i in 0..<pipes.count {
            pipes[i] = spawn(&rng, avoiding: UInt32(i))
            if pipes[i] != nil { started += 1 }
        }

        for _ in 0..<fullSteps {
            for i in 0..<pipes.count {
                guard var pipe = pipes[i] else { continue }
                guard let dir = chooseDirection(pipe, &rng) else {
                    // Boxed in. Start another pipe elsewhere until the cycle's
                    // pipe budget runs out, then leave this slot dead — which is
                    // how the volume comes to rest before the wipe.
                    if started < PipesData.pipesPerCycle {
                        pipes[i] = spawn(&rng, avoiding: pipe.color)
                        if pipes[i] != nil { started += 1 }
                    } else {
                        pipes[i] = nil
                    }
                    continue
                }
                let (dx, dy, dz) = PipesData.delta[dir]
                nodes[index(pipe.x, pipe.y, pipe.z)] |= UInt32(1 << dir)
                pipe.x += dx; pipe.y += dy; pipe.z += dz
                pipe.dir = dir
                nodes[index(pipe.x, pipe.y, pipe.z)] =
                    PipesData.occupiedBit | (pipe.color << 6) | UInt32(1 << (dir ^ 1))
                pipes[i] = pipe
            }
        }

        // The partially-extended tip. Peeking the next direction here is safe:
        // it happens after every full step has been replayed, so the draws it
        // consumes are exactly the ones the next frame's final step will make.
        for i in 0..<pipes.count {
            guard let pipe = pipes[i], let dir = chooseDirection(pipe, &rng) else { continue }
            writePartial(pipe: pipe, dir: dir, frac: frac)
        }
    }

    /// The growing tip, split across the two cells it touches so that every
    /// node's geometry still fits inside its own cell.
    private func writePartial(pipe: Pipe, dir: Int, frac: Float) {
        let quantise: (Float) -> UInt32 = { len in
            UInt32(max(0, min(65535, (len / 0.5) * 65535)).rounded()) << 16
        }
        if frac <= 0.5 {
            // Stub grows outward from the head node's centre.
            nodes[index(pipe.x, pipe.y, pipe.z)] |=
                UInt32(dir << 11) | PipesData.partialBit | quantise(frac)
        } else {
            // Head node's stub is complete; the remainder pokes back from the
            // next node's face toward its centre.
            nodes[index(pipe.x, pipe.y, pipe.z)] |= UInt32(1 << dir)
            let (dx, dy, dz) = PipesData.delta[dir]
            let nx = pipe.x + dx, ny = pipe.y + dy, nz = pipe.z + dz
            guard nx >= 0, ny >= 0, nz >= 0, nx < dim.x, ny < dim.y, nz < dim.z else { return }
            nodes[index(nx, ny, nz)] = PipesData.occupiedBit | (pipe.color << 6)
                | UInt32((dir ^ 1) << 11) | PipesData.partialBit | PipesData.inwardBit
                | quantise(frac - 0.5)
        }
    }

    // MARK: - MSL declarations

    static let metalSource = """
    // ---- lerp-data: pipes -------------------------------------------------
    // Fragment buffer 1: LerpPipesFrame. Fragment buffer 2: node records, one
    // uint per lattice node, indexed (z * dim.y + y) * dim.x + x.
    //
    // Lattice space has unit cells: cell (i,j,k) spans [i,i+1)^3 and its node
    // sits at the centre, (i+0.5, j+0.5, k+0.5). Every node owns only the
    // geometry inside its own cell — a joint ball plus half-length stubs that
    // reach the cell faces — so a ray can be marched cell by cell, evaluating
    // exactly one record per cell.
    struct LerpPipesFrame {
        uint4 dim;         // xyz = lattice nodes per axis
        float fade;        // 1 while drawing, ramps to 0 for the wipe
        float cycleTime;   // seconds since this cycle began
        float cycleIndex;  // how many wipes have happened
        float pad;
    };

    struct LerpPipesNode {
        uint  mask;        // completed connections, bit per direction (+x -x +y -y +z -z)
        uint  color;       // material index 0…15
        bool  occupied;
        bool  hasPartial;  // a growing tip touches this cell
        bool  inward;      // tip spans [0.5-len, 0.5] from the face, not [0, len]
        uint  partialDir;
        float partialLen;  // 0…0.5, in lattice units
    };

    static inline LerpPipesNode lerpPipesDecode(uint rec) {
        LerpPipesNode n;
        n.mask       = rec & 63u;
        n.color      = (rec >> 6) & 15u;
        n.occupied   = (rec & (1u << 10)) != 0u;
        n.partialDir = (rec >> 11) & 7u;
        n.hasPartial = (rec & (1u << 14)) != 0u;
        n.inward     = (rec & (1u << 15)) != 0u;
        n.partialLen = float(rec >> 16) * (0.5 / 65535.0);
        return n;
    }
    """
}
