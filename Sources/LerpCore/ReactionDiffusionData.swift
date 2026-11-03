import Foundation
import Metal

/// CPU side of `reaction-diffusion`: a Gray-Scott simulation, stepped in
/// bounded epochs and handed to the fragment shader as one texel per cell.
///
/// The model is the one Karl Sims explains in his reaction-diffusion tutorial
/// (https://www.karlsims.com/rd.html): two chemicals A and B on a grid, where
/// each step
///
///     A' = A + (Da ∇²A − A·B² + f·(1 − A))
///     B' = B + (Db ∇²B + A·B² − (k + f)·B)
///
/// with Da = 1, Db = 0.5, Δt = 1, and ∇² the 3×3 kernel with −1 at the centre,
/// 0.2 on the edges and 0.05 on the corners. f (feed) and k (kill) choose the
/// pattern: coral, dividing spots, fingerprints, worms. Written from that
/// description; no code is taken from anywhere.
///
/// **Purity.** Generation N of a simulation is only defined through N − 1, so
/// the picture cannot be computed for an arbitrary time directly. Following
/// `LifeData`, the clock is cut into epochs of `epochSteps` steps, each one
/// reseeded from `(seed, epoch)`. Reaching any time costs at most one epoch of
/// steps from that epoch's seed. Everything kept between frames — the current
/// grid and a few checkpoints along the epoch — is a cache whose key is the
/// whole input (`Key`), so it changes how long a frame takes and never what it
/// shows: `--snapshot --time 60` is the same image whether or not t = 0…59 were
/// rendered first. `LerpPreview --rd-selftest` checks exactly that.
///
/// **Cost.** The grid has a fixed number of cells on the screen's short axis
/// (`rows`), so the pattern scale — and the work — do not grow with the
/// display. The step is temporally blocked across cores: each band copies its
/// rows plus `blockSteps` halo rows on either side, advances `blockSteps`
/// steps privately, and writes back only its own rows, so threads meet once
/// per block instead of once per step. Every cell is still computed by the
/// same expression from the same inputs, so the result is bit-identical to
/// plain stepping (the self-test checks that too), and the number of bands
/// can follow the machine without moving a pixel.
public final class ReactionDiffusionData: LerpDataProvider {

    // MARK: - Tunables

    /// Cells across the screen's short axis. Spots and stripes are 10–14 cells
    /// apart at these diffusion rates, so this shows a dozen or so across.
    static let rows = 144
    /// Long-axis cap, so a 32:9 display does not quadruple the catch-up cost.
    static let maxAspect: Float = 2.5

    /// Steps in one epoch, counted from the reseed. Bounds the worst-case
    /// catch-up: a cold frame at the end of an epoch replays all of them.
    static let epochSteps = 4800
    /// Steps already run when an epoch first appears, so t = 0 (and the
    /// gallery's stills at t = 6) show young colonies rather than specks.
    static let prerollSteps = 900
    /// The last `dissolveSteps` raise the kill rate by up to `dissolveKill`,
    /// so the pattern starves and recedes on its own before the reseed.
    static let dissolveSteps = 700
    static let dissolveKill: Float = 0.010
    /// Fractions of the visible epoch spent fading in and out.
    static let fadeIn: Float = 0.010
    static let fadeOut: Float = 0.030
    /// Where a paused clock (speed 0) holds: a well-developed moment.
    static let pausedPhase: Float = 0.40

    /// A copy of the grid is kept every this many steps, so scrubbing backwards
    /// replays at most this far instead of from the reseed.
    static let checkpointInterval = 600
    static let blockSteps = 8

    static let diffusionA: Float = 1.0
    static let diffusionB: Float = 0.5

    // MARK: - Timeline

    /// Where the clock sits: which epoch, and between which two steps.
    struct Moment: Equatable {
        var epoch: Int
        /// The frame shows B between state `step` and `step + 1`.
        var step: Int
        var fraction: Float
        var visibility: Float
    }

    static func moment(time: Float, speed: Float) -> Moment {
        let visible = Double(epochSteps - prerollSteps)
        guard speed > 0 else {
            return Moment(epoch: 0, step: prerollSteps + Int(Double(pausedPhase) * visible),
                          fraction: 0, visibility: 1)
        }
        let cycle = Double(max(0, time)) * Double(speed) / visible
        let epoch = Int(cycle.rounded(.down))
        let phase = cycle - Double(epoch)
        let position = phase * visible
        var step = prerollSteps + Int(position.rounded(.down))
        var fraction = Float(position - position.rounded(.down))
        if step >= epochSteps { step = epochSteps - 1; fraction = 1 }
        let p = Float(phase)
        let visibility = smoothstep(0, fadeIn, p) * (1 - smoothstep(1 - fadeOut, 1, p))
        return Moment(epoch: epoch, step: step, fraction: fraction, visibility: visibility)
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    /// k + f for the step that takes state `n` to `n + 1`.
    static func killPlusFeed(step n: Int, feed: Float, kill: Float) -> Float {
        let ramp = smoothstep(Float(epochSteps - dissolveSteps), Float(epochSteps), Float(n))
        return feed + kill + dissolveKill * ramp
    }

    // MARK: - GPU-visible frame block (fragment buffer 1)

    /// Must match `LerpRDFrame` in `metalSource`.
    struct Frame {
        var mix: Float
        var visibility: Float
        var epoch: Float
        var pad: Float = 0
        var grid: SIMD2<Float>
    }

    // MARK: - State (a cache whose key is its whole input)

    struct Key: Hashable {
        var seed: UInt32
        var cols: Int
        var rows: Int
        var epoch: Int
        var feed: UInt32
        var kill: UInt32
        var colonies: Int
    }

    private let device: MTLDevice?
    private var key: Key?
    private var feed: Float = 0
    private var kill: Float = 0

    private var grid = GrayScottGrid(cols: 0, rows: 0)
    /// Steps applied since the reseed.
    private(set) var step = 0
    /// B one step before `step`, valid when `previousValid`.
    private var previousB: [Float] = []
    private var previousValid = false
    private var checkpoints: [Int: (a: [Float], b: [Float])] = [:]

    private var textures: [MTLTexture] = []
    private var textureIndex = 0
    private var uploaded: (key: Key, step: Int)?
    private var texels: [UInt16] = []

    public init(device: MTLDevice) {
        self.device = device
    }

    /// CPU-only instance for the self-test.
    init() {
        self.device = nil
    }

    // MARK: - LerpDataProvider

    public var metalPrelude: String { ReactionDiffusionData.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let (wanted, moment) = prepare(uniforms: uniforms, params: params)
        guard let texture = upload(key: wanted) else { return }
        // The epoch only varies the shading, so it is folded small enough for
        // the shader's float hashes to stay precise.
        var frame = Frame(mix: moment.fraction, visibility: moment.visibility,
                          epoch: Float(moment.epoch % 256),
                          grid: SIMD2<Float>(Float(wanted.cols), Float(wanted.rows)))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 1)
    }

    /// Brings the grid to the frame's moment: on return the grid holds state
    /// `moment.step + 1` and `previousB` holds B at `moment.step`.
    @discardableResult
    func prepare(uniforms: LerpUniforms, params: LerpParameterValues?) -> (Key, Moment) {
        let feed = min(0.12, max(0.001, scalar(params, "feed", 0.0545)))
        let kill = min(0.08, max(0.001, scalar(params, "kill", 0.062)))
        let colonies = min(64, max(1, Int(scalar(params, "seeds", 8).rounded())))
        let speed = max(0, scalar(params, "speed", 16))
        let (cols, rows) = Self.dimensions(for: uniforms.resolution)
        let moment = Self.moment(time: uniforms.time, speed: speed)

        let wanted = Key(seed: uniforms.seed.bitPattern, cols: cols, rows: rows,
                         epoch: moment.epoch, feed: feed.bitPattern, kill: kill.bitPattern,
                         colonies: colonies)
        if key != wanted {
            key = wanted
            self.feed = feed
            self.kill = kill
            checkpoints.removeAll()
            reseed(wanted)
        }
        advance(to: moment.step + 1)
        return (wanted, moment)
    }

    static func dimensions(for resolution: SIMD2<Float>) -> (cols: Int, rows: Int) {
        let w = max(1, resolution.x), h = max(1, resolution.y)
        let aspect = min(maxAspect, max(w, h) / min(w, h))
        let long = Int((Float(rows) * aspect).rounded())
        return w >= h ? (long, rows) : (rows, long)
    }

    private func scalar(_ params: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }

    // MARK: - Stepping

    private func advance(to target: Int) {
        if step > target || (step == target && !previousValid) {
            if let best = checkpoints.keys.filter({ $0 < target }).max(),
               let saved = checkpoints[best] {
                grid.load(a: saved.a, b: saved.b)
                step = best
            } else if let key {
                reseed(key)
            }
            previousValid = false
        }
        while step < target {
            if step == target - 1 {
                grid.copyB(into: &previousB)
                run(1)
                previousValid = true
                continue
            }
            let nextCheckpoint = (step / Self.checkpointInterval + 1) * Self.checkpointInterval
            run(min(target - 1, nextCheckpoint) - step)
            previousValid = false
            if step % Self.checkpointInterval == 0, checkpoints[step] == nil {
                checkpoints[step] = grid.snapshot()
            }
        }
    }

    private func run(_ count: Int) {
        let (feed, kill, first) = (self.feed, self.kill, step)
        grid.advance(count, feed: feed, bands: Self.bands) {
            Self.killPlusFeed(step: first + $0, feed: feed, kill: kill)
        }
        step += count
    }

    /// Bands follow the machine; results do not depend on it.
    static let bands = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))

    // MARK: - Initial conditions

    /// A = 1 everywhere; B = 1 in a few ragged colonies, scattered so no two
    /// start crowded together. All of it from `(seed, epoch)` alone.
    private func reseed(_ key: Key) {
        grid.reset(cols: key.cols, rows: key.rows)
        step = 0
        previousValid = false
        uploaded = nil
        let salt = key.seed &+ UInt32(truncatingIfNeeded: key.epoch &* 0x9E37_79B9)
        let cols = key.cols, rows = key.rows
        let spacing = 0.55 * (Float(cols * rows) / Float(key.colonies)).squareRoot()

        var centres: [(Float, Float)] = []
        var attempt: UInt32 = 0
        while centres.count < key.colonies {
            var best: (Float, Float) = (0, 0)
            var bestDistance: Float = -1
            // Best of a few candidates: a cheap blue-noise scatter.
            for _ in 0..<12 {
                attempt &+= 1
                let x = Self.hash(attempt, 1, salt) * Float(cols)
                let y = Self.hash(attempt, 2, salt) * Float(rows)
                var nearest = Float.greatestFiniteMagnitude
                for (cx, cy) in centres {
                    var dx = abs(x - cx), dy = abs(y - cy)
                    dx = min(dx, Float(cols) - dx)
                    dy = min(dy, Float(rows) - dy)
                    nearest = min(nearest, (dx * dx + dy * dy).squareRoot())
                }
                if nearest > bestDistance { best = (x, y); bestDistance = nearest }
                if nearest >= spacing { break }
            }
            centres.append(best)
        }

        // Each colony is a short wandering stroke of small blots. A round seed
        // grows into concentric rings for the first thousand steps; a crooked
        // one breaks symmetry at once and looks like the pattern it will be.
        for (index, centre) in centres.enumerated() {
            let i = UInt32(index) &* 16
            var (x, y) = centre
            var heading = Self.hash(i, 3, salt) * 2 * .pi
            let blots = 2 + Int(Self.hash(i, 4, salt) * 7)
            for blot in 0..<blots {
                let j = i &+ UInt32(blot)
                stamp(x: x, y: y, radius: 1.4 + 1.6 * Self.hash(j, 5, salt), salt: salt)
                heading += (Self.hash(j, 6, salt) - 0.5) * 2.2
                x += 2.6 * cos(heading)
                y += 2.6 * sin(heading)
            }
        }
    }

    /// Plants B in a ragged disc, wrapping at the edges.
    private func stamp(x cx: Float, y cy: Float, radius: Float, salt: UInt32) {
        let cols = grid.cols, rows = grid.rows
        let reach = Int(radius * 1.3) + 1
        let ox = Int(cx.rounded(.down)), oy = Int(cy.rounded(.down))
        for dy in -reach...reach {
            for dx in -reach...reach {
                let x = ((ox + dx) % cols + cols) % cols
                let y = ((oy + dy) % rows + rows) % rows
                let fx = Float(ox + dx) + 0.5 - cx, fy = Float(oy + dy) + 0.5 - cy
                let ragged = 0.75 + 0.5 * Self.hash(UInt32(x), UInt32(y), salt ^ 0x5BD1_E995)
                if (fx * fx + fy * fy).squareRoot() <= radius * ragged { grid.plant(x: x, y: y) }
            }
        }
    }

    private static func hash(_ x: UInt32, _ y: UInt32, _ salt: UInt32) -> Float {
        var h = x &* 0x27D4_EB2D ^ y &* 0x1656_67B1 ^ salt &* 0x9E37_79B9
        h ^= h >> 15
        h = h &* 0x2545_F491
        h ^= h >> 13
        h = h &* 0x85EB_CA6B
        h ^= h >> 16
        return Float(h) / Float(UInt32.max)
    }

    // MARK: - Texture

    /// One texel per cell, rg16Unorm: R = B at `step − 1`, G = B at `step`. The
    /// shader blends the two by the clock's fraction, so motion stays smooth at
    /// a few steps per second. Three textures in rotation, so the CPU never
    /// writes one an in-flight frame is still sampling.
    private func upload(key: Key) -> MTLTexture? {
        guard let device else { return nil }
        if textures.first.map({ $0.width != key.cols || $0.height != key.rows }) ?? true {
            textures = (0..<3).compactMap { index in
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rg16Unorm, width: key.cols, height: key.rows, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .shared
                let texture = device.makeTexture(descriptor: descriptor)
                texture?.label = "reaction-diffusion.grid[\(index)]"
                return texture
            }
            uploaded = nil
            guard textures.count == 3 else { textures = []; return nil }
        }
        if let uploaded, uploaded.key == key, uploaded.step == step {
            return textures[textureIndex]
        }
        textureIndex = (textureIndex + 1) % textures.count
        let texture = textures[textureIndex]
        let count = key.cols * key.rows
        if texels.count != count * 2 { texels = [UInt16](repeating: 0, count: count * 2) }
        grid.withB { current in
            previousB.withUnsafeBufferPointer { previous in
                texels.withUnsafeMutableBufferPointer { out in
                    for i in 0..<count {
                        out[2 * i] = Self.unorm16(previous[i])
                        out[2 * i + 1] = Self.unorm16(current[i])
                    }
                }
            }
        }
        texels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, key.cols, key.rows), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: key.cols * 4)
        }
        uploaded = (key, step)
        return texture
    }

    @inline(__always) private static func unorm16(_ value: Float) -> UInt16 {
        UInt16(min(1, max(0, value)) * 65535 + 0.5)
    }

    // MARK: - Runnable checks

    /// Invoked by `LerpPreview --rd-selftest`, which adds an image-level check
    /// on top. Returns a description of the first failure, or nil.
    public static func selfTest() -> String? {
        // 1. Blocked stepping is bit-identical to plain stepping, across a
        //    partial block, several band counts and the dissolve ramp.
        for bands in [1, 3, 5] {
            var blocked = GrayScottGrid(cols: 40, rows: 29)
            for i in 0..<40 { blocked.plant(x: (i * 7) % 40, y: (i * 11) % 29) }
            var plain = blocked
            let kf: (Int) -> Float = { killPlusFeed(step: epochSteps - 30 + $0, feed: 0.04, kill: 0.06) }
            blocked.advance(29, feed: 0.04, bands: bands, killPlusFeed: kf)
            for n in 0..<29 { plain.referenceStep(feed: 0.04, killPlusFeed: kf(n)) }
            guard blocked.snapshot() == plain.snapshot() else {
                return "blocked stepping (\(bands) bands) differs from plain stepping"
            }
        }

        // 2. Timeline: epochs tile the clock, the fade is closed at the seams.
        let speed: Float = 16
        let epochSeconds = Float(epochSteps - prerollSteps) / speed
        let start = moment(time: 0, speed: speed)
        guard start.step == prerollSteps, start.visibility == 0,
              moment(time: epochSeconds * 1.5, speed: speed).epoch == 1,
              moment(time: 0, speed: 0) == moment(time: 999, speed: 0)
        else { return "timeline is wrong" }

        // 3. Purity at the provider level: one moment reached cold, reached by
        //    rendering every frame before it, and reached by scrubbing back
        //    from later in the epoch, is the same grid.
        let resolution = SIMD2<Float>(1200, 750)
        func state(after times: [Float]) -> [Float] {
            let provider = ReactionDiffusionData()
            for t in times {
                provider.prepare(uniforms: LerpUniforms(resolution: resolution, time: t, seed: 0.31),
                                 params: nil)
            }
            var b: [Float] = []
            provider.grid.copyB(into: &b)
            return b + provider.previousB
        }
        let cold = state(after: [60])
        let warm = state(after: stride(from: 0, through: 60, by: 1.0 / 7).map { Float($0) } + [60])
        let back = state(after: [200, 61, 60])
        guard cold == warm else { return "t=60 differs after rendering t=0…60 first" }
        guard cold == back else { return "t=60 differs after scrubbing back from t=200" }
        return nil
    }

    /// Wall time of the worst cold frame: a fresh provider asked for the last
    /// moment of an epoch, i.e. a full epoch of steps.
    public static func worstCaseCatchUp(resolution: SIMD2<Float>) -> Double {
        let provider = ReactionDiffusionData()
        let speed: Float = 16
        let end = Float(epochSteps - prerollSteps) / speed - 0.01
        let start = CFAbsoluteTimeGetCurrent()
        provider.prepare(uniforms: LerpUniforms(resolution: resolution, time: end, seed: 0.5),
                         params: nil)
        return CFAbsoluteTimeGetCurrent() - start
    }

    /// CPU cost of a frame in steady playback: stepping plus texture upload,
    /// at 60 fps for `seconds` from t = 100 (after one warm frame). Returns
    /// (mean, max) in milliseconds.
    public static func steadyFrameCost(device: MTLDevice, resolution: SIMD2<Float>,
                                       params: LerpParameterValues?,
                                       seconds: Float = 10) -> (mean: Double, max: Double) {
        let provider = ReactionDiffusionData(device: device)
        func frame(_ t: Float) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            let (key, _) = provider.prepare(
                uniforms: LerpUniforms(resolution: resolution, time: t, seed: 0.5), params: params)
            _ = provider.upload(key: key)
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        _ = frame(100)
        let costs = (1...Int(seconds * 60)).map { frame(100 + Float($0) / 60) }
        return (costs.reduce(0, +) / Double(costs.count), costs.max() ?? 0)
    }

    // MARK: - MSL

    static let metalSource = """
    // ---- lerp-data: reaction-diffusion ------------------------------------
    // Fragment texture 1 (rg16Unorm, one texel per cell, toroidal): R = B at
    // the step before the clock, G = B at the step after. Fragment buffer 1:
    // how far between them the clock sits, the epoch fade, the epoch number
    // (mod 256, for shading variety only), and the grid size in cells.
    struct LerpRDFrame {
        float  mix;
        float  visibility;
        float  epoch;
        float  pad;
        float2 grid;
    };
    constexpr sampler lerpRDSampler(coord::normalized, address::repeat, filter::linear);
    """
}

// MARK: - Grid

/// The two chemical fields, double-buffered, plus per-band scratch for the
/// temporally blocked step. Plain value semantics over arrays; the stepping
/// itself works through raw pointers so the row loop vectorizes.
struct GrayScottGrid {
    private(set) var cols: Int
    private(set) var rows: Int
    private var a: [Float]
    private var b: [Float]
    private var nextA: [Float]
    private var nextB: [Float]
    private var scratch: [Float] = []

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        a = [Float](repeating: 1, count: cols * rows)
        b = [Float](repeating: 0, count: cols * rows)
        nextA = a
        nextB = b
    }

    mutating func reset(cols: Int, rows: Int) {
        if cols != self.cols || rows != self.rows {
            self = GrayScottGrid(cols: cols, rows: rows)
            return
        }
        a.withUnsafeMutableBufferPointer { $0.update(repeating: 1) }
        b.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    mutating func plant(x: Int, y: Int) {
        a[y * cols + x] = 0
        b[y * cols + x] = 1
    }

    func snapshot() -> (a: [Float], b: [Float]) { (a, b) }

    mutating func load(a: [Float], b: [Float]) {
        self.a = a
        self.b = b
    }

    func copyB(into destination: inout [Float]) { destination = b }

    func withB<R>(_ body: (UnsafeBufferPointer<Float>) -> R) -> R {
        b.withUnsafeBufferPointer(body)
    }

    /// Advances `count` steps. `killPlusFeed(i)` is k + f for the i-th of them.
    mutating func advance(_ count: Int, feed: Float, bands requested: Int,
                          killPlusFeed: (Int) -> Float) {
        let cols = self.cols, rows = self.rows
        let block = ReactionDiffusionData.blockSteps
        // Steady playback advances a step or so per frame: a few tens of
        // microseconds, cheaper on this thread than waking workers (and immune
        // to one of them being descheduled). Catch-up is what goes wide.
        let bands = count < block ? 1 : max(1, min(requested, rows))
        let bandRows = (rows + bands - 1) / bands + 2 * block
        let plane = bandRows * cols
        if scratch.count < bands * 4 * plane {
            scratch = [Float](repeating: 0, count: bands * 4 * plane)
        }

        var done = 0
        while done < count {
            let steps = min(block, count - done)
            let rates = (0..<steps).map { killPlusFeed(done + $0) }
            a.withUnsafeBufferPointer { srcA in
            b.withUnsafeBufferPointer { srcB in
            nextA.withUnsafeMutableBufferPointer { dstA in
            nextB.withUnsafeMutableBufferPointer { dstB in
            scratch.withUnsafeMutableBufferPointer { work in
                let io = BlockIO(srcA: srcA.baseAddress!, srcB: srcB.baseAddress!,
                                 dstA: dstA.baseAddress!, dstB: dstB.baseAddress!,
                                 work: work.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    io.run(band: band, of: bands, steps: steps, cols: cols, rows: rows,
                           plane: plane, feed: feed, rates: rates)
                }
            }}}}}
            swap(&a, &nextA)
            swap(&b, &nextB)
            done += steps
        }
    }

    /// One whole-grid step with no blocking or threads: the definition the
    /// blocked path is tested against.
    mutating func referenceStep(feed: Float, killPlusFeed: Float) {
        let cols = self.cols, rows = self.rows
        a.withUnsafeBufferPointer { srcA in
        b.withUnsafeBufferPointer { srcB in
        nextA.withUnsafeMutableBufferPointer { dstA in
        nextB.withUnsafeMutableBufferPointer { dstB in
            let pa = srcA.baseAddress!, pb = srcB.baseAddress!
            for y in 0..<rows {
                let up = ((y + rows - 1) % rows) * cols, row = y * cols, down = ((y + 1) % rows) * cols
                GrayScottGrid.row(cols: cols, feed: feed, killPlusFeed: killPlusFeed,
                         aUp: pa + up, a: pa + row, aDown: pa + down,
                         bUp: pb + up, b: pb + row, bDown: pb + down,
                         outA: dstA.baseAddress! + row, outB: dstB.baseAddress! + row)
            }
        }}}}
        swap(&a, &nextA)
        swap(&b, &nextB)
    }

    /// One row of one step. Wraps horizontally; the caller supplies the rows
    /// above and below, so it serves both the toroidal grid and band scratch.
    @inline(__always)
    static func row(cols: Int, feed: Float, killPlusFeed kf: Float,
                    aUp: UnsafePointer<Float>, a: UnsafePointer<Float>, aDown: UnsafePointer<Float>,
                    bUp: UnsafePointer<Float>, b: UnsafePointer<Float>, bDown: UnsafePointer<Float>,
                    outA: UnsafeMutablePointer<Float>, outB: UnsafeMutablePointer<Float>) {
        let da = ReactionDiffusionData.diffusionA, db = ReactionDiffusionData.diffusionB
        @inline(__always) func cell(_ x: Int, _ l: Int, _ r: Int) {
            let lapA = 0.2 * (aUp[x] + aDown[x] + a[l] + a[r])
                     + 0.05 * (aUp[l] + aUp[r] + aDown[l] + aDown[r]) - a[x]
            let lapB = 0.2 * (bUp[x] + bDown[x] + b[l] + b[r])
                     + 0.05 * (bUp[l] + bUp[r] + bDown[l] + bDown[r]) - b[x]
            let av = a[x], bv = b[x]
            let reaction = av * bv * bv
            outA[x] = av + da * lapA - reaction + feed * (1 - av)
            outB[x] = bv + db * lapB + reaction - kf * bv
        }
        cell(0, cols - 1, 1)
        for x in 1..<(cols - 1) { cell(x, x - 1, x + 1) }
        cell(cols - 1, cols - 2, 0)
    }
}

/// Raw pointers for one block of steps. Each band reads the shared source
/// planes, writes only its own rows of the destination planes, and works in
/// its own slice of scratch, so the bands never touch the same memory.
private struct BlockIO: @unchecked Sendable {
    let srcA: UnsafePointer<Float>
    let srcB: UnsafePointer<Float>
    let dstA: UnsafeMutablePointer<Float>
    let dstB: UnsafeMutablePointer<Float>
    let work: UnsafeMutablePointer<Float>

    func run(band: Int, of bands: Int, steps: Int, cols: Int, rows: Int,
             plane: Int, feed: Float, rates: [Float]) {
        let y0 = band * rows / bands, y1 = (band + 1) * rows / bands
        let height = y1 - y0 + 2 * steps
        let base = work + band * 4 * plane
        var a = base, b = base + plane, nextA = base + 2 * plane, nextB = base + 3 * plane
        for j in 0..<height {
            let source = ((y0 - steps + j) % rows + rows) % rows * cols
            (a + j * cols).update(from: srcA + source, count: cols)
            (b + j * cols).update(from: srcB + source, count: cols)
        }
        // After step s only rows s..<(height − s) are still exact; after the
        // last one that is precisely this band's own rows.
        for s in 1...steps {
            for j in s..<(height - s) {
                GrayScottGrid.row(cols: cols, feed: feed, killPlusFeed: rates[s - 1],
                         aUp: a + (j - 1) * cols, a: a + j * cols, aDown: a + (j + 1) * cols,
                         bUp: b + (j - 1) * cols, b: b + j * cols, bDown: b + (j + 1) * cols,
                         outA: nextA + j * cols, outB: nextB + j * cols)
            }
            swap(&a, &nextA)
            swap(&b, &nextB)
        }
        (dstA + y0 * cols).update(from: a + steps * cols, count: (y1 - y0) * cols)
        (dstB + y0 * cols).update(from: b + steps * cols, count: (y1 - y0) * cols)
    }
}
