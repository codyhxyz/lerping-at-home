import Foundation
import Metal
import simd

/// CPU side of the `maze` shader: an homage to Microsoft's 3D Maze screensaver
/// (ssmaze, Windows 95). A perfect maze is carved, a walker solves it with the
/// right-hand rule, and the camera follows that walk at eye height.
///
/// Where the original snapped through each move — step, stop, rotate 90°,
/// step — the walk here is one continuous path. Every cell is crossed from the
/// midpoint of the edge it was entered by to the midpoint of the edge it is
/// left by: a straight run is a line, a turn is a quarter circle round the
/// inside corner, and a dead end is the only place the walker stops, easing in
/// to the cell centre, turning round on the spot and easing back out. Speed is
/// continuous everywhere, including into and out of every stop, and so is the
/// rate of turn: the camera looks along a lightly filtered heading
/// (`Walk.heading(at:)`) rather than snapping into each quarter circle. The
/// camera stays level at eye height: no head bob.
///
/// The original's spinning polyhedra are kept, and so is what they did: walk
/// through one and the world turns upside down until you walk through another.
/// Here the roll is animated rather than instant.
///
/// **Purity.** Maze `n` is a pure function of `(seed, n, size)`, and its walk
/// of `speed` as well. Mazes differ in how long they take to solve, so which
/// maze is playing at time `t` depends on the durations of all the mazes
/// before it. Those durations are memoised under a key that is the whole input
/// (seed, size, speed); a cold process derives the same table from scratch —
/// a few hundred integer steps per maze — so `--snapshot --time T` is the
/// same image whether or not anything ran first.
///
/// **What the GPU sees.** Walls are slabs centred on the grid lines, so each
/// grid *vertex* owns exactly the geometry inside the unit square around it: a
/// post, plus up to four half-length wall arms reaching the square's edges.
/// That is the dual of the `pipes` trick — the shader steps the ray square by
/// square and intersects one cross-shaped record per square.
///
/// Vertex record, one `uint` per grid vertex, `(w + 1) × (h + 1)` of them:
///
///     bit 0   wall arm toward +x
///     bit 1   wall arm toward −x
///     bit 2   wall arm toward +z
///     bit 3   wall arm toward −z
///     bit 4   the whole wall from this vertex to the next one along +x is a
///             feature wall (tiles or a bricked-up arch)
///     bit 5   likewise for the wall along +z
///
/// Feature walls are only ever placed on walls bordering a cell the walker
/// passes through, so every one of them is seen.
public final class MazeData: LerpDataProvider {

    // MARK: - Tunables

    static let minSize = 4
    static let maxSize = 40
    /// Standing at the start, fading in, before the first step.
    static let introSeconds: Float = 1.8
    static let fadeInSeconds: Float = 1.2
    /// Standing in front of the goal before the fade, and the fade itself.
    static let outroSeconds: Float = 2.6
    static let fadeOutSeconds: Float = 1.1
    /// How far into the goal cell the walker stops, from its entry edge.
    static let goalStop: Float = 0.1
    /// Turning round at a dead end, in seconds at unit speed.
    static let uTurnSeconds: Float = 1.7
    /// Time the view takes to roll over after touching a polyhedron.
    static let flipSeconds: Float = 1.3
    /// Half-width of the heading filter; see `Walk.heading(at:)`.
    static let headLead: Float = 0.18
    static let maxObjects = 8

    // MARK: - GPU-visible frame block (fragment buffer 1)

    /// Must match `LerpMazeFrame` in `metalSource`.
    struct Frame {
        var dim = SIMD4<UInt32>(repeating: 0)        // x, y = cells; z = object count; w = style
        var camera = SIMD4<Float>(repeating: 0)      // x, z, yaw, roll
        var motion = SIMD4<Float>(repeating: 0)      // fade, distance walked, goal approach, time in maze
        var goal = SIMD4<Float>(repeating: 0)        // x, z, per-maze salt, outro progress
        var objects: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                      SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
            = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    }

    // MARK: - Directions
    //
    // Heading k points along yaw k·π/2 with forward = (cos yaw, sin yaw) in
    // (x, z). k + 1 is a right turn: facing +x, the camera's right is +z.

    private static let step: [(Int, Int)] = [(1, 0), (0, 1), (-1, 0), (0, -1)]

    // MARK: - Maze

    struct Maze {
        let w: Int, h: Int
        /// Wall on grid line x between z and z+1; (w+1) × h, index x * h + z.
        var vwall: [Bool]
        /// Wall on grid line z between x and x+1; w × (h+1), index x * (h+1) + z.
        var hwall: [Bool]
        /// Feature walls, same layout as `vwall` / `hwall`.
        var vfeat: [Bool]
        var hfeat: [Bool]

        init(w: Int, h: Int) {
            self.w = w; self.h = h
            vwall = [Bool](repeating: true, count: (w + 1) * h)
            hwall = [Bool](repeating: true, count: w * (h + 1))
            vfeat = [Bool](repeating: false, count: (w + 1) * h)
            hfeat = [Bool](repeating: false, count: w * (h + 1))
        }

        /// Marks the wall on side `k` of cell (x, z) as a feature wall.
        mutating func feature(_ x: Int, _ z: Int, _ k: Int) {
            switch k & 3 {
            case 0: vfeat[(x + 1) * h + z] = true
            case 1: hfeat[x * (h + 1) + z + 1] = true
            case 2: vfeat[x * h + z] = true
            default: hfeat[x * (h + 1) + z] = true
            }
        }

        func open(_ x: Int, _ z: Int, _ k: Int) -> Bool {
            switch k & 3 {
            case 0: return x + 1 < w && !vwall[(x + 1) * h + z]
            case 1: return z + 1 < h && !hwall[x * (h + 1) + z + 1]
            case 2: return x > 0 && !vwall[x * h + z]
            default: return z > 0 && !hwall[x * (h + 1) + z]
            }
        }

        mutating func carve(_ x: Int, _ z: Int, _ k: Int) {
            switch k & 3 {
            case 0: vwall[(x + 1) * h + z] = false
            case 1: hwall[x * (h + 1) + z + 1] = false
            case 2: vwall[x * h + z] = false
            default: hwall[x * (h + 1) + z] = false
            }
        }

        /// The cross-shaped vertex records the shader reads.
        func vertexRecords(into out: inout [UInt32]) {
            let vw = w + 1
            for j in 0...h {
                for i in 0...w {
                    var r: UInt32 = 0
                    if i < w, hwall[i * (h + 1) + j] {
                        r |= 1
                        if hfeat[i * (h + 1) + j] { r |= 16 }
                    }
                    if i > 0, hwall[(i - 1) * (h + 1) + j] { r |= 2 }
                    if j < h, vwall[i * h + j] {
                        r |= 4
                        if vfeat[i * h + j] { r |= 32 }
                    }
                    if j > 0, vwall[i * h + j - 1] { r |= 8 }
                    out[j * vw + i] = r
                }
            }
        }
    }

    /// Recursive backtracker: long, winding corridors with few branches, which
    /// is what makes a wall-follower's walk worth watching.
    static func carve(w: Int, h: Int, rng: inout LerpSplitMix64) -> Maze {
        var maze = Maze(w: w, h: h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [(Int, Int)] = [(rng.below(w), rng.below(h))]
        seen[stack[0].0 * h + stack[0].1] = true
        var options = [Int]()
        options.reserveCapacity(4)
        while let (x, z) = stack.last {
            options.removeAll(keepingCapacity: true)
            for k in 0..<4 {
                let nx = x + step[k].0, nz = z + step[k].1
                if nx >= 0, nz >= 0, nx < w, nz < h, !seen[nx * h + nz] { options.append(k) }
            }
            if options.isEmpty { stack.removeLast(); continue }
            let k = options[rng.below(options.count)]
            maze.carve(x, z, k)
            let nx = x + step[k].0, nz = z + step[k].1
            seen[nx * h + nz] = true
            stack.append((nx, nz))
        }
        return maze
    }

    // MARK: - Walk

    enum Ease { case linear, fromRest, toRest, inOut }

    struct Segment {
        var t0: Float = 0
        var duration: Float = 0
        var ease: Ease = .linear
        /// Distance walked at the start of this segment, and its length.
        var s0: Float = 0
        var length: Float = 0
        /// Straight line from `a` to `b`, or — when `radius > 0` — an arc about
        /// `a` from angle `angle0` to `angle1`.
        var a = SIMD2<Float>(0, 0)
        var b = SIMD2<Float>(0, 0)
        var radius: Float = 0
        var angle0: Float = 0, angle1: Float = 0
        var yaw0: Float = 0, yaw1: Float = 0

        func eased(_ u: Float) -> Float {
            switch ease {
            case .linear: return u
            case .fromRest: return u * u
            case .toRest: return 1 - (1 - u) * (1 - u)
            case .inOut: return u * u * (3 - 2 * u)
            }
        }
    }

    struct Pose { var position: SIMD2<Float>; var yaw: Float; var walked: Float }

    struct Flip { var cell: SIMD2<Float>; var time: Float }

    struct Walk {
        var segments: [Segment] = []
        /// Every cell the walker passes through, in order, revisits included.
        var route: [(Int, Int)] = []
        var flips: [Flip] = []
        var goal = SIMD2<Float>(0, 0)
        var goalYaw: Float = 0
        /// When the walker stops in front of the goal, and the maze's end.
        var arrival: Float = 0
        var duration: Float = 0

        func pose(at t: Float) -> Pose {
            guard !segments.isEmpty else { return Pose(position: goal, yaw: goalYaw, walked: 0) }
            // Binary search for the segment containing t.
            var lo = 0, hi = segments.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if segments[mid].t0 <= t { lo = mid } else { hi = mid - 1 }
            }
            let s = segments[lo]
            let u = s.duration > 0 ? min(max((t - s.t0) / s.duration, 0), 1) : 1
            let e = s.eased(u)
            let yaw = s.yaw0 + (s.yaw1 - s.yaw0) * e
            let position: SIMD2<Float>
            if s.radius > 0 {
                let ang = s.angle0 + (s.angle1 - s.angle0) * e
                position = s.a + s.radius * SIMD2<Float>(cos(ang), sin(ang))
            } else {
                position = s.a + (s.b - s.a) * e
            }
            return Pose(position: position, yaw: yaw, walked: s.s0 + s.length * e)
        }

        /// The heading the camera looks along: the path's own heading, tent-
        /// filtered over ±`headLead` seconds. On the path itself the turn
        /// rate steps from 0 to 2·speed rad/s the instant a quarter circle
        /// begins (4.4 rad/s for Labyrinth, a visible kick at every corner);
        /// filtered, it ramps up over 2·headLead and the head starts into a
        /// turn a moment before the feet do, as a walker's does. Yaw is kept
        /// unwrapped by `solve`, so averaging angles is safe. 256 midpoint
        /// samples put the quadrature error under 0.005 px at 2704 wide
        /// (48 samples: 0.13 px, which would show as a faint wobble).
        func heading(at t: Float) -> Float {
            let n = 256
            let centre = pose(at: t).yaw
            var sum: Float = 0, weights: Float = 0
            for i in 0..<n {
                let x = (Float(i) + 0.5) / Float(n) * 2 - 1
                let w = 1 - abs(x)
                sum += w * (pose(at: t + x * MazeData.headLead).yaw - centre)
                weights += w
            }
            return centre + sum / weights
        }
    }

    /// Solves `maze` from one corner to the opposite one with the right-hand
    /// rule and turns the walk into timed path segments at `speed` cells/s.
    static func solve(_ maze: Maze, start: (Int, Int), goal: (Int, Int),
                     speed v: Float, flipBudget: Int, rng: inout LerpSplitMix64) -> Walk {
        // 1. The cell sequence. Start facing whichever way the rule would take
        //    first, as though the walker had arrived with its hand on the wall.
        var cells: [(Int, Int)] = [start]
        var headings: [Int] = []
        var (x, z) = start
        var k = (0..<4).first { maze.open(x, z, $0) } ?? 0
        k = (k + 3) & 3   // so the first right-hand probe tries `k` itself
        let limit = 4 * maze.w * maze.h + 8
        while (x, z) != goal, cells.count < limit {
            for turn in [1, 0, 3, 2] {
                let d = (k + turn) & 3
                if maze.open(x, z, d) {
                    k = d
                    x += step[d].0; z += step[d].1
                    cells.append((x, z)); headings.append(d)
                    break
                }
            }
        }

        // 2. Segments.
        var w = Walk()
        w.route = cells
        var t: Float = 0, s: Float = 0
        let half: Float = 0.5
        func centre(_ c: (Int, Int)) -> SIMD2<Float> { SIMD2(Float(c.0) + 0.5, Float(c.1) + 0.5) }
        func dir(_ k: Int) -> SIMD2<Float> { SIMD2(Float(step[k].0), Float(step[k].1)) }
        func yawOf(_ k: Int) -> Float { Float(k) * .pi / 2 }

        var yaw = yawOf(headings.first ?? 0)
        func push(_ seg: Segment) {
            var seg = seg
            seg.t0 = t; seg.s0 = s
            w.segments.append(seg)
            t += seg.duration; s += seg.length
        }
        func line(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ ease: Ease) {
            let len = simd_length(b - a)
            let dur = (ease == .linear ? len : 2 * len) / v
            push(Segment(duration: dur, ease: ease, length: len, a: a, b: b, yaw0: yaw, yaw1: yaw))
        }

        // Intro: stand still at the start.
        push(Segment(duration: introSeconds, a: centre(start), b: centre(start), yaw0: yaw, yaw1: yaw))

        guard let firstHeading = headings.first else {
            w.goal = centre(goal); w.goalYaw = yaw
            w.arrival = t; w.duration = t + outroSeconds
            return w
        }
        line(centre(start), centre(start) + dir(firstHeading) * half, .fromRest)

        // Cells we may hang a polyhedron in: crossed straight or a dead end,
        // first visit only, away from both ends of the walk.
        var candidates: [(cell: (Int, Int), time: Float)] = []
        var visited = Set<Int>()
        visited.insert(start.0 * maze.h + start.1)

        for i in 1..<cells.count {
            let c = centre(cells[i])
            let kin = headings[i - 1]
            let entry = c - dir(kin) * half
            let firstVisit = visited.insert(cells[i].0 * maze.h + cells[i].1).inserted
            if i == cells.count - 1 {
                // The goal: walk a little way in and stop facing it.
                line(entry, entry + dir(kin) * goalStop, .toRest)
                break
            }
            let kout = headings[i]
            let turn = (kout - kin) & 3
            switch turn {
            case 0:
                let mid = t + half / v
                line(entry, c + dir(kout) * half, .linear)
                if firstVisit, i > 2, i < cells.count - 3 { candidates.append((cells[i], mid)) }
            case 1, 3:
                // Quarter circle about the inside corner.
                let sign: Float = turn == 1 ? 1 : -1
                let corner = c - dir(kin) * half + dir(kout) * half
                let a0 = atan2(-dir(kout).y, -dir(kout).x)
                let a1 = a0 + sign * .pi / 2
                let len = Float.pi / 4
                push(Segment(duration: len / v, length: len, a: corner, radius: half,
                             angle0: a0, angle1: a1, yaw0: yaw, yaw1: yaw + sign * .pi / 2))
                yaw += sign * .pi / 2
            default:
                // Dead end: ease in to the centre, turn round, ease back out.
                line(entry, c, .toRest)
                if firstVisit, i > 2, i < cells.count - 3 { candidates.append((cells[i], t)) }
                let spin = uTurnSeconds / max(0.35, v).squareRoot()
                push(Segment(duration: spin, ease: .inOut, a: c, b: c, yaw0: yaw, yaw1: yaw + .pi))
                yaw += .pi
                line(c, c + dir(kout) * half, .fromRest)
            }
        }

        w.goal = centre(goal)
        w.goalYaw = yaw
        w.arrival = t
        w.duration = t + outroSeconds

        // 3. Polyhedra: spread along the walk, no two too close in time so
        //    every roll gets to finish.
        if flipBudget > 0, !candidates.isEmpty {
            var picks: [(cell: (Int, Int), time: Float)] = []
            var pool = candidates
            while picks.count < flipBudget, !pool.isEmpty {
                let p = pool.remove(at: rng.below(pool.count))
                if picks.allSatisfy({ abs($0.time - p.time) > flipSeconds * 2.5 }) { picks.append(p) }
            }
            picks.sort { $0.time < $1.time }
            w.flips = picks.map { Flip(cell: centre($0.cell), time: $0.time) }
        }
        return w
    }

    // MARK: - Timeline

    private struct Key: Equatable {
        var seed: UInt32
        var size: Int
        var speed: Float
        var flips: Bool
    }

    private struct Built {
        var index: Int
        var maze: Maze
        var walk: Walk
        /// Which masonry this maze is built from, 0…3.
        var style: Int
        /// Per-maze salt in [0, 1) for the shader's feature-wall choices.
        var salt: Float
    }

    /// Masonry styles; consecutive mazes always differ.
    static let styleCount = 4
    /// Chance that a wall beside the walker's route is a feature wall.
    static let featureChance = 0.08

    private var key: Key?
    /// Start time of maze n, for every n built so far; `starts.count - 1`
    /// mazes have known durations.
    private var starts: [Float] = [0]
    private var current: Built?

    private static func rng(seed: UInt32, index: Int) -> LerpSplitMix64 {
        var rng = LerpSplitMix64(state: (UInt64(seed) &* LerpSplitMix64.gamma)
                                    ^ (UInt64(bitPattern: Int64(index)) &* 0xA24B_AED4_963E_E407)
                                    ^ 0x6D61_7A65_5F6C_6572)
        _ = rng.next()
        return rng
    }

    private static func build(key: Key, index: Int) -> Built {
        var rng = rng(seed: key.seed, index: index)
        let n = key.size
        let maze = carve(w: n, h: n, rng: &rng)
        // Opposite corners, chosen per maze.
        let corner = rng.below(4)
        let start = (corner & 1 == 0 ? 0 : n - 1, corner & 2 == 0 ? 0 : n - 1)
        let goal = (n - 1 - start.0, n - 1 - start.1)
        let budget = key.flips ? min(maxObjects, max(1, n * n / 48)) : 0
        let walk = solve(maze, start: start, goal: goal, speed: key.speed,
                        flipBudget: budget, rng: &rng)

        // Feature walls, only where the walker will see them. Skip the start
        // and goal cells, and give each cell at most one.
        var maze2 = maze
        var seen = Set<Int>()
        for cell in walk.route.dropFirst().dropLast() where seen.insert(cell.0 * n + cell.1).inserted {
            for k in 0..<4 where !maze.open(cell.0, cell.1, k) {
                if rng.unit() < featureChance { maze2.feature(cell.0, cell.1, k); break }
            }
        }

        let style = (Int(key.seed % UInt32(styleCount)) + index) % styleCount
        let salt = Float(rng.next() >> 40) / Float(1 << 24)
        return Built(index: index, maze: maze2, walk: walk, style: style, salt: salt)
    }

    /// Which maze is playing at `t`, and how far into it.
    private func locate(_ t: Float, key: Key) -> (Int, Float) {
        if self.key != key {
            self.key = key
            starts = [0]
            current = nil
        }
        // Extend the start table until it covers t. Bounded: a 40×40 maze at
        // top speed still takes over a minute, so a day of runtime is under
        // two thousand entries.
        while starts.last! <= t {
            let index = starts.count - 1
            let built = MazeData.build(key: key, index: index)
            starts.append(starts.last! + built.walk.duration)
            current = built
        }
        // Largest n with starts[n] <= t.
        var lo = 0, hi = starts.count - 2
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        return (lo, t - starts[lo])
    }

    // MARK: - State (GPU scratch and a pure memo — no simulation state)

    private let ring: LerpBufferRing?
    private var records: [UInt32]

    public init(device: MTLDevice) {
        let capacity = (MazeData.maxSize + 1) * (MazeData.maxSize + 1)
        records = [UInt32](repeating: 0, count: capacity)
        ring = LerpBufferRing(device: device,
                              length: capacity * MemoryLayout<UInt32>.stride,
                              count: 3,
                              label: "maze.vertices")
    }

    public var metalPrelude: String { MazeData.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        func scalar(_ name: String, _ fallback: Float) -> Float {
            guard let value = params?[name]?.scalarValue else { return fallback }
            return Float(value)
        }
        let size = min(MazeData.maxSize, max(MazeData.minSize, Int(scalar("size", 12).rounded())))
        let speed = min(4, max(0.25, scalar("speed", 1.3)))
        let key = Key(seed: uniforms.seed.bitPattern, size: size, speed: speed,
                      flips: scalar("flips", 1) != 0)

        let t = max(0, uniforms.time)
        let (index, local) = locate(t, key: key)
        if current?.index != index {
            current = MazeData.build(key: key, index: index)
        }
        guard let built = current else { return }
        let walk = built.walk
        let pose = walk.pose(at: local)

        // Rolls already begun; each is a half turn.
        var roll: Float = 0
        for flip in walk.flips where local > flip.time {
            let u = min(1, (local - flip.time) / MazeData.flipSeconds)
            roll += .pi * u * u * (3 - 2 * u)
        }

        let fadeIn = min(1, local / MazeData.fadeInSeconds)
        let fadeOut = min(1, max(0, (walk.duration - local) / MazeData.fadeOutSeconds))
        let fade = fadeIn * fadeIn * (3 - 2 * fadeIn) * fadeOut

        // 0 → 1 over the last few cells before the goal, held through the outro.
        let approach = min(1, max(0, 1 - (walk.arrival - local) / 3.0))
        let flash = max(0, local - walk.arrival) / MazeData.outroSeconds

        var frame = Frame()
        frame.dim = SIMD4(UInt32(size), UInt32(size), UInt32(walk.flips.count), UInt32(built.style))
        frame.camera = SIMD4(pose.position.x, pose.position.y, walk.heading(at: local), roll)
        frame.motion = SIMD4(fade, pose.walked, approach, local)
        frame.goal = SIMD4(walk.goal.x, walk.goal.y, built.salt, min(1, flash))
        withUnsafeMutableBytes(of: &frame.objects) { raw in
            let slots = raw.bindMemory(to: SIMD4<Float>.self)
            for (i, flip) in walk.flips.prefix(MazeData.maxObjects).enumerated() {
                // Shrinks away as the walker reaches it; gone once touched.
                let remaining = flip.time - local
                let scale = min(1, max(0, remaining / 0.45))
                slots[i] = SIMD4(flip.cell.x, flip.cell.y, scale, Float(i) * 1.7)
            }
        }
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)

        built.maze.vertexRecords(into: &records)
        guard let buffer = ring?.next() else { return }
        let count = (size + 1) * (size + 1)
        records.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!,
                                         byteCount: count * MemoryLayout<UInt32>.stride)
        }
        encoder.setFragmentBuffer(buffer, offset: 0, index: 2)
    }

    // MARK: - MSL declarations

    static let metalSource = """
    // ---- lerp-data: maze --------------------------------------------------
    // Fragment buffer 1: LerpMazeFrame. Fragment buffer 2: vertex records, one
    // uint per grid vertex, indexed j * (dim.x + 1) + i.
    //
    // World space: cell (i, j) spans [i, i+1] x [j, j+1] in (x, z); y is up,
    // floor at 0. Walls are slabs centred on grid lines. Vertex (i, j) sits at
    // (i, j) and owns the square [i-0.5, i+0.5] x [j-0.5, j+0.5]: a post plus
    // up to four half-length arms, bit 0 +x, 1 -x, 2 +z, 3 -z. Bit 4 / 5: the
    // whole wall from this vertex along +x / +z is a feature wall.
    struct LerpMazeFrame {
        uint4  dim;         // x, y = cells across / deep; z = polyhedron count; w = masonry style
        float4 camera;      // x, z, yaw (forward = (cos, sin) in xz), roll
        float4 motion;      // fade, distance walked, goal approach 0..1, seconds into maze
        float4 goal;        // x, z, per-maze salt 0..1, outro progress 0..1
        float4 objects[8];  // x, z, scale (0 = touched), spin phase
    };
    """
}
