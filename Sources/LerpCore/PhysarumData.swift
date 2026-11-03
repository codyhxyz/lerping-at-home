import Foundation
import Metal

// MARK: - The simulation (pure CPU, no Metal)

/// Inputs that shape a physarum trajectory. Everything a step reads that is
/// not the state itself lives here, so this, plus the grid, the seed and the
/// epoch, is the complete cache key for `PhysarumData`.
struct PhysarumSettings: Hashable {
    /// Half-angle between the forward sensor and each side sensor, radians.
    var sensorAngle: Float = 0.3927        // 22.5°
    /// How far ahead the sensors sit, in cells.
    var sensorDistance: Float = 9
    /// How far an agent turns in one step when a side sensor wins, radians.
    var turnAngle: Float = 0.7854          // 45°
    /// Fraction of the trail lost per step, after diffusion.
    var decay: Float = 0.10
    /// Agents per grid cell.
    var population: Float = 0.15
    /// Initial layout: 0 uniform soup, 1 one central spore, 2 colonies around
    /// food sources that keep laying trail.
    var start: Int = 0
    /// Ceiling on the trail, in units of the grid's mean density.
    var saturation: Float = 2

    /// Mean trail density at equilibrium: what every agent lays per step,
    /// spread over every cell, divided by the fraction lost per step.
    var meanDensity: Float { population * PhysarumSim.depositAmount / decay }
}

/// Jeff Jones' agent model of *Physarum polycephalum* transport networks
/// ("Characteristics of pattern formation and evolution in approximations of
/// Physarum transport networks", Artificial Life 16(2), 2010), in the
/// synchronous form Sage Jenson describes: every agent senses the trail at
/// three points ahead of it, turns toward the strongest, moves one cell and
/// deposits; the whole trail then diffuses through a 3×3 kernel and decays.
///
/// Departures from the published model, each for a reason given where it is
/// implemented: the kernel is binomial (1-2-1) rather than a flat mean, which
/// is rounder on a square grid; agents ignore sensor differences below a small
/// threshold; deposits are splatted bilinearly; and how much an agent lays
/// falls off as the trail under it nears a ceiling (`saturation`), which stops
/// the network collapsing into a few loops within seconds.
///
/// Written so each phase could become one compute kernel without changing a
/// result:
///
///   1. `senseAndMove` — one thread per agent. Reads the trail, writes only
///      that agent's own position, heading and landing cell. Its random
///      choice is a hash of (agent, step, salt), never a shared stream.
///   2. `deposit` — integer counts per cell, in 1/256ths of an agent.
///      Addition of integers commutes, so the order agents land in (serial
///      here, `atomic_fetch_add` on a GPU) cannot change a single bit.
///   3. `diffuse` — one thread per cell, a pure function of the previous
///      trail and the counts.
///
/// Phases 1 and 3 run across cores with `concurrentPerform`. Each output
/// element is computed by exactly one worker with the same arithmetic in the
/// same order however the work is chunked, so a step is bit-identical on one
/// core or ten.
///
/// Jones' model also lets at most one agent occupy a cell and picks a new
/// random heading when a move is blocked. That rule depends on the order in
/// which agents move, so it is left out here, as it is in Jenson's GPU
/// version; the trail alone is what organises the network.
final class PhysarumSim {
    let cols: Int
    let rows: Int
    let settings: PhysarumSettings
    private(set) var step = 0

    /// Trail deposited per agent per step.
    static let depositAmount: Float = 5
    /// Cells an agent moves per step.
    static let stepSize: Float = 1
    /// Smallest difference between two sensors an agent responds to, as a
    /// fraction of the mean trail density.
    static let sensitivity: Float = 0.01

    // Agents, structure-of-arrays. Heading is a unit vector, turned by a
    // rotation matrix, so no step needs a sin or cos.
    private var px: [Float], py: [Float]
    private var hx: [Float], hy: [Float]
    /// Where each agent lands this step, for the deposit: the top-left cell
    /// of the four it straddles (x | y << 16) and its offset into them in
    /// sixteenths (x | y << 8).
    private var foot: [UInt32]
    private var offset: [UInt16]

    // The trail. `trail` is this step; `previous` is the step before it,
    // kept for the renderer to interpolate between.
    private(set) var trail: [Float]
    private(set) var previous: [Float]
    private var counts: [UInt32]
    private var scratch: [Float]
    /// Cells of the food sources in the colonies start, each of which lays
    /// `foodCount` agents' worth of trail every step.
    private var food: [Int32] = []
    static let colonyCount = 10
    static let foodCount: UInt32 = 4
    /// Deposit counts are in 1/256ths of an agent (a 16 × 16 splat).
    static let countsPerAgent: UInt32 = 256
    private let salt: UInt32

    var agentCount: Int { px.count }

    init(cols: Int, rows: Int, settings: PhysarumSettings, seed: UInt32, epoch: Int) {
        self.cols = cols
        self.rows = rows
        self.settings = settings
        let cellCount = cols * rows
        let n = max(1, Int((Float(cellCount) * settings.population).rounded()))
        px = [Float](repeating: 0, count: n); py = px
        hx = px; hy = px
        foot = [UInt32](repeating: 0, count: n)
        offset = [UInt16](repeating: 0, count: n)
        trail = [Float](repeating: 0, count: cellCount)
        previous = trail
        scratch = trail
        counts = [UInt32](repeating: 0, count: cellCount)

        var rng = LerpSplitMix64(state: UInt64(seed) &* LerpSplitMix64.gamma
                                 ^ UInt64(bitPattern: Int64(epoch)) &* 0xD1B5_4A32_D192_ED03
                                 ^ 0x5068_7973_6172_756D)          // "Physarum"
        _ = rng.next()
        salt = UInt32(truncatingIfNeeded: rng.next())
        place(&rng)
    }

    private func place(_ rng: inout LerpSplitMix64) {
        let w = Float(cols), h = Float(rows)
        let short = min(w, h)

        // Colonies: a handful of food sources scattered over the grid, each
        // seeded with its share of the agents and kept stocked with trail.
        // A lone spore is placed at random too: on a torus its growth front
        // meets itself on the far side, and that seam should cross the
        // picture somewhere new each time rather than frame it.
        var centres: [(Float, Float)] = [(Float(rng.unit()) * w, Float(rng.unit()) * h)]
        if settings.start == 2 {
            centres = (0..<Self.colonyCount).map { _ in
                (Float(rng.unit()) * w, Float(rng.unit()) * h)
            }
            let radius = 2
            for (x, y) in centres {
                for dy in -radius...radius {
                    for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                        let cx = (Int(x) + dx + cols) % cols, cy = (Int(y) + dy + rows) % rows
                        food.append(Int32(cy * cols + cx))
                    }
                }
            }
        }

        for i in 0..<px.count {
            let a = Float(rng.unit()) * 2 * .pi
            let heading = Float(rng.unit()) * 2 * .pi
            var x: Float, y: Float
            switch settings.start {
            case 1:
                // A spore: one dense disc.
                let r = 0.12 * short * Float(rng.unit()).squareRoot()
                x = centres[0].0 + r * cos(a); y = centres[0].1 + r * sin(a)
            case 2:
                let (cx, cy) = centres[i % centres.count]
                let r = 0.03 * short * Float(rng.unit()).squareRoot()
                x = cx + r * cos(a); y = cy + r * sin(a)
            default:
                x = Float(rng.unit()) * w; y = Float(rng.unit()) * h
            }
            px[i] = wrap(x, w); py[i] = wrap(y, h)
            hx[i] = cos(heading); hy[i] = sin(heading)
        }
    }

    @inline(__always) private func wrap(_ v: Float, _ size: Float) -> Float {
        var v = v
        if v < 0 { v += size }
        if v >= size { v -= size }
        return v >= 0 && v < size ? v : 0
    }

    /// Chunks the parallel phases are split into. Results do not depend on
    /// it — `selfTest` checks 1, 7 and 16 agree bit for bit.
    var chunks = 16

    func advance() {
        senseAndMove()
        deposit()
        diffuse()
        step += 1
    }

    // MARK: Phase 1 — sense, turn, move

    /// Everything phase 1 reads besides the trail and the agents themselves.
    private struct Motor {
        var cols: Int, rows: Int
        var width: Float, height: Float
        var distance: Float
        var cosSensor: Float, sinSensor: Float
        var cosTurn: Float, sinTurn: Float
        var stepSize: Float
        var threshold: Float
        var salt: UInt32, step: UInt32
    }

    private func senseAndMove() {
        let motor = Motor(cols: cols, rows: rows, width: Float(cols), height: Float(rows),
                          distance: settings.sensorDistance,
                          cosSensor: cos(settings.sensorAngle), sinSensor: sin(settings.sensorAngle),
                          cosTurn: cos(settings.turnAngle), sinTurn: sin(settings.turnAngle),
                          stepSize: Self.stepSize,
                          threshold: Self.sensitivity * settings.meanDensity, salt: salt,
                          step: UInt32(truncatingIfNeeded: step))
        let n = px.count
        let chunks = self.chunks
        let per = (n + chunks - 1) / chunks

        trail.withUnsafeBufferPointer { trail in
        px.withUnsafeMutableBufferPointer { px in
        py.withUnsafeMutableBufferPointer { py in
        hx.withUnsafeMutableBufferPointer { hx in
        hy.withUnsafeMutableBufferPointer { hy in
        foot.withUnsafeMutableBufferPointer { foot in
        offset.withUnsafeMutableBufferPointer { offset in
            let t = trail.baseAddress!
            let x = px.baseAddress!, y = py.baseAddress!
            let dx = hx.baseAddress!, dy = hy.baseAddress!
            let f = foot.baseAddress!, o = offset.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let lo = chunk * per, hi = min(n, lo + per)
                guard lo < hi else { return }
                PhysarumSim.move(lo..<hi, motor, trail: t, x: x, y: y, dx: dx, dy: dy, foot: f, offset: o)
            }
        }}}}}}}
    }

    /// Trail in the cell under a point. Positions are in [0, size) and the
    /// sensor reach is shorter than the grid, so one shift by `size` makes
    /// truncation a floor and at most two subtractions wrap it back onto the
    /// torus.
    @inline(__always)
    private static func sense(_ trail: UnsafePointer<Float>, _ x: Float, _ y: Float,
                              _ m: Motor) -> Float {
        var ix = Int(x + m.width), iy = Int(y + m.height)
        if ix >= m.cols { ix -= m.cols }
        if ix >= m.cols { ix -= m.cols }
        if iy >= m.rows { iy -= m.rows }
        if iy >= m.rows { iy -= m.rows }
        return trail[iy * m.cols + ix]
    }

    private static func move(_ range: Range<Int>, _ m: Motor, trail: UnsafePointer<Float>,
                             x px: UnsafeMutablePointer<Float>, y py: UnsafeMutablePointer<Float>,
                             dx hx: UnsafeMutablePointer<Float>, dy hy: UnsafeMutablePointer<Float>,
                             foot: UnsafeMutablePointer<UInt32>,
                             offset: UnsafeMutablePointer<UInt16>) {
        let d = m.distance, cs = m.cosSensor, ss = m.sinSensor
        for i in range {
            let x = px[i], y = py[i]
            var dx = hx[i], dy = hy[i]
            let forward = sense(trail, x + d * dx, y + d * dy, m)
            let left = sense(trail, x + d * (dx * cs - dy * ss), y + d * (dx * ss + dy * cs), m)
            let right = sense(trail, x + d * (dx * cs + dy * ss), y + d * (dy * cs - dx * ss), m)

            // Jones' rule. Ahead wins: keep going. Ahead loses to both sides:
            // turn either way at random. Otherwise turn toward the stronger.
            // Differences under `threshold` count as ties. Without one, the
            // trail's exact-zero frontier — which a 3×3 kernel spreads one cell
            // a step along the axes but only 0.7 along the diagonals — lets
            // agents running along an axis outpace it and never turn, and
            // every colony grows into a cross.
            let towardLeft = left - forward, towardRight = right - forward
            var turn: Float = 0
            if towardLeft <= m.threshold && towardRight <= m.threshold {
                turn = 0
            } else if towardLeft > m.threshold && towardRight > m.threshold {
                turn = hash(UInt32(truncatingIfNeeded: i), m.step, m.salt) & 1 == 0 ? 1 : -1
            } else {
                turn = towardLeft > towardRight ? 1 : -1
            }
            if turn != 0 {
                let s = turn * m.sinTurn
                let ndx = dx * m.cosTurn - dy * s
                dy = dx * s + dy * m.cosTurn
                dx = ndx
                hx[i] = dx; hy[i] = dy
            }

            var nx = x + m.stepSize * dx, ny = y + m.stepSize * dy
            if nx < 0 { nx += m.width } else if nx >= m.width { nx -= m.width }
            if ny < 0 { ny += m.height } else if ny >= m.height { ny -= m.height }
            // Rounding can land exactly on the far edge; that cell is cell 0.
            if !(nx < m.width) { nx = 0 }
            if !(ny < m.height) { ny = 0 }
            px[i] = nx; py[i] = ny
            // The deposit is splatted bilinearly over the four nearest cell
            // centres, like the sensors read, in sixteenths of an agent.
            let fx = nx + m.width - 0.5, fy = ny + m.height - 0.5
            var x0 = Int(fx), y0 = Int(fy)
            let ox = Int((fx - Float(x0)) * 16 + 0.5), oy = Int((fy - Float(y0)) * 16 + 0.5)
            if x0 >= m.cols { x0 -= m.cols }
            if y0 >= m.rows { y0 -= m.rows }
            foot[i] = UInt32(x0) | UInt32(y0) << 16
            offset[i] = UInt16(ox) | UInt16(oy) << 8
        }
    }

    // MARK: Phase 2 — deposit, as integer counts

    private func deposit() {
        let cols = self.cols, rows = self.rows
        counts.withUnsafeMutableBufferPointer { counts in
            for i in counts.indices { counts[i] = 0 }
            foot.withUnsafeBufferPointer { foot in
            offset.withUnsafeBufferPointer { offset in
                for i in foot.indices {
                    let x0 = Int(foot[i] & 0xFFFF), y0 = Int(foot[i] >> 16)
                    let x1 = x0 + 1 == cols ? 0 : x0 + 1
                    let r0 = y0 * cols, r1 = (y0 + 1 == rows ? 0 : y0 + 1) * cols
                    let ox = UInt32(offset[i] & 0xFF), oy = UInt32(offset[i] >> 8)
                    counts[r0 + x0] &+= (16 - ox) * (16 - oy)
                    counts[r0 + x1] &+= ox * (16 - oy)
                    counts[r1 + x0] &+= (16 - ox) * oy
                    counts[r1 + x1] &+= ox * oy
                }
            }}
            for c in food { counts[Int(c)] &+= Self.foodCount * Self.countsPerAgent }
        }
    }

    // MARK: Phase 3 — lay the deposit, diffuse, decay

    private func diffuse() {
        let cols = self.cols, rows = self.rows
        let amount = Self.depositAmount / Float(Self.countsPerAgent)
        let keep = (1 - settings.decay) / 16
        // An agent lays less the nearer the trail under it is to the ceiling.
        // A hard clamp would do the same job but leaves flat plateaus where
        // every sensor ties, and agents then cross them in dead straight lines.
        let inverseCap = 1 / (settings.saturation * settings.meanDensity)
        let chunks = self.chunks
        let per = (rows + chunks - 1) / chunks

        // One pass per band of rows: the vertical 3-tap sum of (trail +
        // deposit) into this band's rows of scratch, then the horizontal
        // 3-tap sum of those same rows into `previous`. A band only reads the
        // trail's rows (shared, read-only) and its own scratch rows, so bands
        // never wait on one another. `previous` then becomes the trail and
        // the old trail is kept as `previous`, for the renderer to blend.
        trail.withUnsafeBufferPointer { trail in
        counts.withUnsafeBufferPointer { counts in
        scratch.withUnsafeMutableBufferPointer { mid in
        previous.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                let lo = chunk * per, hi = min(rows, lo + per)
                guard lo < hi else { return }
                for y in lo..<hi {
                    let up = (y == 0 ? rows - 1 : y - 1) * cols
                    let row = y * cols
                    let down = (y + 1 == rows ? 0 : y + 1) * cols
                    for x in 0..<cols {
                        let a = trail[up + x], b = trail[row + x], c = trail[down + x]
                        let laid = Float(counts[up + x]) * max(0, 1 - a * inverseCap)
                            + 2 * Float(counts[row + x]) * max(0, 1 - b * inverseCap)
                            + Float(counts[down + x]) * max(0, 1 - c * inverseCap)
                        mid[row + x] = a + 2 * b + c + amount * laid
                    }
                    let last = row + cols - 1
                    out[row] = (mid[last] + 2 * mid[row] + mid[row + 1]) * keep
                    for x in (row + 1)..<last {
                        out[x] = (mid[x - 1] + 2 * mid[x] + mid[x + 1]) * keep
                    }
                    out[last] = (mid[last - 1] + 2 * mid[last] + mid[row]) * keep
                }
            }
        }}}}
        swap(&trail, &previous)
    }

    // MARK: Noise

    @inline(__always) static func hash(_ a: UInt32, _ b: UInt32, _ salt: UInt32) -> UInt32 {
        var h = a &* 0x8DA6_B343 ^ b &* 0xD816_3841 ^ salt &* 0xCB1A_B31F
        h ^= h >> 16
        h = h &* 0x7FEB_352D
        h ^= h >> 15
        h = h &* 0x846C_A68B
        h ^= h >> 16
        return h
    }
}

// MARK: - The data provider

/// CPU side of `physarum`: a bounded-epoch slime-mould simulation, handed to
/// the fragment shader as a two-channel texture of trail density (R the step
/// before, G the current step, so the shader can blend between steps).
///
/// **Purity.** The simulation has no closed form, so it reseeds every
/// `epochSteps` steps from `(seed, epoch)` and is stepped forward from there.
/// A cached simulation is only advanced when its key — grid, seed, epoch and
/// every setting a step reads — still matches; otherwise, or when the clock
/// runs backward, it is rebuilt from the epoch's first step. Any frame
/// therefore costs at most `epochSteps + 1` steps from cold, and
/// `--snapshot --time 60` is the same image whether or not t < 60 was drawn.
public final class PhysarumData: LerpDataProvider {

    /// Steps in one epoch, and so the most any frame costs from cold. At the
    /// default 8 steps/s that is a minute: a network forms in the first ten
    /// seconds and spends the rest coarsening.
    static let epochSteps = 480
    /// Cells across the screen's short axis, and a ceiling on the grid's total
    /// size, so an ultrawide display costs no more than a 2:1 one.
    static let shortAxisCells = 200
    static let maxCells = 200 * 400

    /// Must match `LerpPhysarumFrame` in `metalSource`.
    struct Frame {
        var blend: Float     // 0 = R (step s), 1 = G (step s + 1)
        var fade: Float      // 0 → 1 at an epoch's start, → 0 at its end
        var phase: Float     // 0 … 1 through the epoch
        var epoch: Float
    }

    private struct Key: Hashable {
        var seed: UInt32
        var cols: Int
        var rows: Int
        var epoch: Int
        var settings: PhysarumSettings
    }

    private let device: MTLDevice
    private var key: Key?
    private var sim: PhysarumSim?
    private var textures: [MTLTexture] = []
    private var textureIndex = 0
    private var uploadedStep = -1
    private var packed: [Float16] = []

    public init(device: MTLDevice) {
        self.device = device
    }

    public var metalPrelude: String { PhysarumData.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let (cols, rows) = Self.dimensions(for: uniforms.resolution)
        let clock = Self.clock(time: uniforms.time, seed: uniforms.seed,
                               speed: Self.scalar(params, "speed", 8))
        let wanted = Key(seed: uniforms.seed.bitPattern, cols: cols, rows: rows,
                         epoch: clock.epoch, settings: Self.settings(params))
        let sim = advance(to: clock.step + 1, key: wanted)

        if textures.first?.width != cols || textures.first?.height != rows {
            textures = (0..<3).compactMap { _ in
                Self.makeTexture(device: device, width: cols, height: rows)
            }
            uploadedStep = -1
        }
        guard !textures.isEmpty else { return }
        if uploadedStep != sim.step {
            textureIndex = (textureIndex + 1) % textures.count
            upload(sim, into: textures[textureIndex])
            uploadedStep = sim.step
        }
        var frame = Frame(blend: clock.blend, fade: clock.fade,
                          phase: clock.phase, epoch: Float(clock.epoch))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentTexture(textures[textureIndex], index: 1)
    }

    /// The cached simulation at `step` of the epoch `key` names, rebuilt from
    /// the epoch's start if the key changed or the clock went backward.
    private func advance(to step: Int, key wanted: Key) -> PhysarumSim {
        if key != wanted || sim == nil || sim!.step > step {
            sim = PhysarumSim(cols: wanted.cols, rows: wanted.rows, settings: wanted.settings,
                              seed: wanted.seed, epoch: wanted.epoch)
            key = wanted
            uploadedStep = -1
        }
        let sim = self.sim!
        while sim.step < step { sim.advance() }
        return sim
    }

    // MARK: Clock

    struct Clock {
        var epoch: Int
        var step: Int       // whole steps into the epoch, 0 ..< epochSteps
        var blend: Float
        var phase: Float
        var fade: Float
    }

    /// Where `time` falls: which epoch, which step, and how far to the next.
    /// The seed shifts the clock by up to one epoch, so every activation opens
    /// somewhere different and stills at small t show a grown network.
    static func clock(time: Float, seed: Float, speed: Float) -> Clock {
        let rate = max(0, speed)
        let position = max(0, time) * rate / Float(epochSteps) + min(max(seed, 0), 1)
        let epoch = Int(position.rounded(.down))
        let phase = position - Float(epoch)
        let exact = min(Float(epochSteps) - 1e-3, phase * Float(epochSteps))
        let step = Int(exact.rounded(.down))
        let fade = rate > 0
            ? smooth(0, 0.035, phase) * (1 - smooth(0.95, 1, phase)) : 1
        return Clock(epoch: epoch, step: step, blend: exact - Float(step),
                     phase: phase, fade: fade)
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Grid and settings

    static func dimensions(for resolution: SIMD2<Float>) -> (Int, Int) {
        let w = max(1, resolution.x), h = max(1, resolution.y)
        let aspect = max(w, h) / min(w, h)
        var short = Float(shortAxisCells)
        if short * short * aspect > Float(maxCells) {
            short = (Float(maxCells) / aspect).squareRoot()
        }
        let s = max(16, Int(short.rounded()))
        let l = max(16, Int((Float(s) * aspect).rounded()))
        return w >= h ? (l, s) : (s, l)
    }

    private static func settings(_ params: LerpParameterValues?) -> PhysarumSettings {
        let degrees = Float.pi / 180
        var s = PhysarumSettings()
        s.sensorAngle = min(90, max(1, scalar(params, "sensorAngle", 22.5))) * degrees
        s.sensorDistance = min(40, max(1, scalar(params, "sensorDistance", 9)))
        s.turnAngle = min(90, max(1, scalar(params, "turnAngle", 45))) * degrees
        s.decay = min(0.5, max(0.005, scalar(params, "decay", 0.1)))
        s.population = min(0.3, max(0.02, scalar(params, "population", 0.15)))
        s.start = min(2, max(0, Int(scalar(params, "start", 0).rounded())))
        s.saturation = min(16, max(1, scalar(params, "saturation", 2)))
        return s
    }

    private static func scalar(_ params: LerpParameterValues?, _ name: String,
                               _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }

    // MARK: Texture

    private static func makeTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Float,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "physarum.trail"
        return texture
    }

    /// Trail as a fraction of its ceiling, so 1 is a saturated vein whatever
    /// the population, deposit, decay and saturation — the shader's exposure
    /// then means the same thing in every preset.
    private func upload(_ sim: PhysarumSim, into texture: MTLTexture) {
        let count = sim.cols * sim.rows
        let scale = 1 / max(sim.settings.saturation * sim.settings.meanDensity, 1e-6)
        if packed.count != count * 2 { packed = [Float16](repeating: 0, count: count * 2) }
        sim.previous.withUnsafeBufferPointer { prev in
        sim.trail.withUnsafeBufferPointer { cur in
        packed.withUnsafeMutableBufferPointer { out in
            for i in 0..<count {
                out[2 * i] = Float16(prev[i] * scale)
                out[2 * i + 1] = Float16(cur[i] * scale)
            }
        }}}
        packed.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, sim.cols, sim.rows), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: sim.cols * 4)
        }
    }

    // MARK: Self-test

    /// Determinism, run by `LerpPreview --physarum-selftest`:
    ///
    /// - a simulation stepped frame by frame through 0…t equals one built cold
    ///   at t, bit for bit;
    /// - a step is the same however the parallel phases are chunked (1, 7 or
    ///   16 workers), so running across cores cannot change a result;
    /// - two simulations from the same key agree, and a different epoch does
    ///   not;
    /// - scrubbing back (t = 59 after t = 60) equals t = 59 drawn cold.
    ///
    /// Returns a description of the first failure, or nil.
    public static func selfTest() -> String? {
        var settings = PhysarumSettings()
        settings.start = 2                      // exercises the food deposits too
        let a = PhysarumSim(cols: 96, rows: 60, settings: settings, seed: 0x1234, epoch: 3)
        let b = PhysarumSim(cols: 96, rows: 60, settings: settings, seed: 0x1234, epoch: 3)
        let c = PhysarumSim(cols: 96, rows: 60, settings: settings, seed: 0x1234, epoch: 4)
        let serial = PhysarumSim(cols: 96, rows: 60, settings: settings, seed: 0x1234, epoch: 3)
        serial.chunks = 1
        b.chunks = 7
        for _ in 0..<200 { a.advance(); b.advance(); c.advance(); serial.advance() }
        guard a.trail == b.trail, a.previous == b.previous,
              a.trail == serial.trail, a.previous == serial.previous else {
            return "the same key gave different trails with 16, 7 and 1 workers"
        }
        guard a.trail != c.trail else { return "a new epoch did not reseed" }
        guard a.trail.contains(where: { $0 > 0 }) else { return "no trail was laid" }

        guard let device = MTLCreateSystemDefaultDevice() else { return "no Metal device" }
        let resolution = SIMD2<Float>(320, 200)
        let seed: Float = 0.31
        let (cols, rows) = dimensions(for: resolution)
        let target = clock(time: 60, seed: seed, speed: 8)

        let warm = PhysarumData(device: device)
        var t: Float = 0
        while t < 60 {
            let c = clock(time: t, seed: seed, speed: 8)
            _ = warm.advance(to: c.step + 1,
                             key: Key(seed: seed.bitPattern, cols: cols, rows: rows,
                                      epoch: c.epoch, settings: settings))
            t += 1.0 / 30
        }
        let key = Key(seed: seed.bitPattern, cols: cols, rows: rows,
                      epoch: target.epoch, settings: settings)
        let warmSim = warm.advance(to: target.step + 1, key: key)
        let cold = PhysarumData(device: device).advance(to: target.step + 1, key: key)
        guard warmSim.step == cold.step, warmSim.trail == cold.trail,
              warmSim.previous == cold.previous else {
            return "t=60 differs depending on whether earlier frames were drawn"
        }

        let back = clock(time: 59, seed: seed, speed: 8)
        let backKey = Key(seed: seed.bitPattern, cols: cols, rows: rows,
                          epoch: back.epoch, settings: settings)
        let rewound = warm.advance(to: back.step + 1, key: backKey)
        let coldBack = PhysarumData(device: device).advance(to: back.step + 1, key: backKey)
        guard rewound.trail == coldBack.trail, rewound.previous == coldBack.previous else {
            return "scrubbing back to t=59 differs from drawing t=59 cold"
        }
        return nil
    }

    // MARK: MSL

    static let metalSource = """
    // ---- lerp-data: physarum ----------------------------------------------
    // Fragment buffer 1: LerpPhysarumFrame. Fragment texture 1: trail density
    // as a fraction of its ceiling (0…1), R = step s, G = step s + 1. The grid is
    // toroidal and spans the whole drawable, so sample it with repeat.
    struct LerpPhysarumFrame {
        float blend;   // how far from step s to step s + 1
        float fade;    // epoch fade in / out
        float phase;   // 0 … 1 through the epoch
        float epoch;
    };
    constexpr sampler lerpPhysarumSampler(filter::linear, address::repeat);
    """
}
