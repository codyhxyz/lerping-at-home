import Foundation
import Metal
import os

/// GPU side of `sandpile`: the Abelian sandpile model (Bak, Tang & Wiesenfeld,
/// 1987), stepped by a compute kernel through `LerpGPUSimulation`. It is the
/// worked example of a GPU-stepped data provider.
///
/// Grains are fed into one to three sources. Any cell holding four or more
/// topples, sending one grain to each neighbour; grains that fall off the edge
/// are lost. Each step topples every unstable cell at once, `h / 4` times
/// ("multi-toppling"), so a pile of millions of grains spreads in thousands of
/// steps instead of millions. The model is *Abelian*: the configuration it
/// settles to does not depend on the order of topplings, so this parallel
/// schedule reaches the same famous fractal a one-at-a-time schedule would.
/// All state is integers, so every GPU produces the same bits.
///
/// One epoch is one story: feed, let the last avalanches settle, hold the
/// finished pattern, fade, and reseed from `(seed, epoch)`. Its length in steps
/// depends only on the parameters, so the clock maps to `(epoch, step)` with no
/// history, and reaching any time costs at most one epoch of steps.
public final class SandpileData: LerpDataProvider {

    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "sandpile")

    /// The share of an epoch spent holding the settled pattern, then fading.
    static let holdShare: Float = 0.2
    /// Steps allowed for the pile to settle, as a multiple of rows². Measured
    /// with every grain dropped on one cell at once (the slowest case): 160
    /// rows settle by step 8,000 and 300 rows by step 28,000, about 0.31·rows².
    /// Pouring the same grains over time, or into several sources, settles
    /// sooner, so this bounds every story.
    static let settlePerRowSquared: Float = 0.34
    /// The clock runs steps ∝ phase², because a pile's radius grows with the
    /// square root of its steps: this makes the front advance at a steady pace
    /// instead of racing out and then crawling.
    static let clockExponent: Float = 2
    static let maxCellsPerAxis = 1024
    /// Generations per dispatch of the blocked kernel. 64×64-cell tiles (a
    /// 32×32 threadgroup, four cells a thread) with an 8-cell halo leave a
    /// 48×48 core, so 1.8 cells are stepped for every one written.
    /// Measured on an M5 at 330×220 cells, 19,304 steps from cold: one step
    /// per dispatch 174 ms GPU + 17–28 ms CPU encode; 32-cell tiles 161 ms +
    /// 1.7 ms; these 64-cell tiles 70–130 ms + ~2 ms. Every variant was
    /// checked bit-identical against the plain kernel.
    static let blockSteps = 8

    let simulation: LerpGPUSimulation?
    private var fragmentFrame = Frame(generation: 0, ready: 0, phase: 0, fade: 1)
    private(set) var lastTexture: MTLTexture?
    /// Bound when the simulation is unavailable, so the fragment shader never
    /// reads an unbound texture; `ready = 0` tells it to draw the fallback.
    private let placeholder: MTLTexture?

    /// Mirrors `struct LerpSandpileFrame` in `metalPrelude`.
    struct Frame {
        var generation: UInt32
        var ready: UInt32
        var phase: Float
        var fade: Float
    }

    public init(device: MTLDevice) {
        do {
            simulation = try LerpGPUSimulation(
                device: device, label: "sandpile", source: Self.kernels,
                planes: [.init("grains", pixelFormat: .rgba32Uint)],
                seed: [.init("sandpileSeed")],
                step: [.init("sandpileStep")],
                blockedStep: .init("sandpileSteps", stepsPerDispatch: Self.blockSteps,
                                   tileSide: 64, halo: Self.blockSteps, threadgroupSide: 32))
        } catch {
            Self.log.error("sandpile kernels failed to build: \(String(describing: error), privacy: .public)")
            simulation = nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Uint,
                                                                  width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        placeholder = device.makeTexture(descriptor: descriptor)
    }

    // MARK: - LerpDataProvider

    public var metalPrelude: String {
        """
        // ---- lerp-data: sandpile ----------------------------------------------
        // Fragment texture 1: R grains, G generation of the cell's last topple.
        // Fragment buffer 1: this frame's place in the story.
        struct LerpSandpileFrame {
            uint  generation; // steps since the epoch began
            uint  ready;      // 0: no simulation on this GPU; draw a fallback
            float phase;      // 0..1 through the epoch
            float fade;       // 1 normally, falling to 0 just before reseeding
        };
        """
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        var frame = fragmentFrame
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.size, index: 1)
        encoder.setFragmentTexture(lastTexture ?? placeholder, index: 1)
    }

    public func encodeCompute(into commandBuffer: MTLCommandBuffer, uniforms: LerpUniforms,
                              params: LerpParameterValues?) {
        let plan = Plan(uniforms: uniforms, params: params)
        guard let simulation,
              let textures = simulation.advance(commandBuffer, to: plan.step, of: plan.key) else {
            lastTexture = nil
            fragmentFrame = Frame(generation: 0, ready: 0, phase: plan.phase, fade: 1)
            return
        }
        lastTexture = textures[0]
        fragmentFrame = Frame(generation: UInt32(plan.step), ready: 1,
                              phase: plan.phase, fade: plan.fade)
    }

    // MARK: - The clock

    /// Where a frame sits in its story, from `(uniforms, params)` alone.
    struct Plan {
        var key: LerpGPUSimulation.Key
        var step: Int
        var phase: Float
        var fade: Float

        init(uniforms: LerpUniforms, params: LerpParameterValues?) {
            func scalar(_ name: String, _ fallback: Float) -> Float {
                params?[name]?.scalarValue.map(Float.init) ?? fallback
            }
            let rows = min(SandpileData.maxCellsPerAxis, max(32, Int(scalar("cells", 220).rounded())))
            let aspect = max(0.25, uniforms.resolution.x / max(1, uniforms.resolution.y))
            let cols = min(SandpileData.maxCellsPerAxis, max(32, Int((Float(rows) * aspect).rounded(.up))))
            let feed = max(1, Int(scalar("feed", 24).rounded()))
            let fill = min(1, max(0.1, scalar("fill", 0.92)))
            let rate = max(0, scalar("speed", 240))

            // A settled pile averages about 2.1 grains a cell, so a disc of
            // radius r takes ~2.1·πr² grains. Everything here is sized by the
            // short side alone, so the epoch length — and with it the clock —
            // does not move with the window's shape.
            let radius = 0.5 * fill * Float(rows)
            let grains = 2.125 * Float.pi * radius * radius
            let feedSteps = max(1, Int(grains / Float(feed)))
            let active = feedSteps + Int(SandpileData.settlePerRowSquared * Float(rows * rows))
            // Seconds of clock per epoch, at `rate` steps a second on average.
            let length = Float(active) / (1 - SandpileData.holdShare)

            // The seed picks where in a story the clock starts, as every
            // look's seed offsets its phase: an activation opens on a pile
            // already growing rather than on an empty screen. The 0.38 lands
            // the gallery's fixed seed (0.37, t = 6) on the settled fractal.
            let start = (uniforms.seed + 0.38).truncatingRemainder(dividingBy: 1)
            let position = rate > 0 ? max(0, uniforms.time) * rate / length + start : start
            let epoch = Int(position.rounded(.down))
            phase = position - Float(epoch)
            let progress = min(1, phase / (1 - SandpileData.holdShare))
            step = min(active, Int((pow(progress, SandpileData.clockExponent) * Float(active)).rounded(.down)))
            fade = min(1, max(0, (1 - phase) / 0.06))

            // Sources split the feed, so the total stays `grains` however
            // many there are. Count and placement come from (seed, epoch).
            let salt = uniforms.seed.bitPattern &+ UInt32(truncatingIfNeeded: epoch &* 0x9E3779B9)
            let requested = Int(scalar("sources", 0).rounded())
            let roll = LerpGPUSimulation.hashBits(17, 3, salt) % 10
            let count = requested > 0 ? min(3, requested) : (roll < 5 ? 1 : roll < 8 ? 2 : 3)
            // Three piles merge into a broader blob than one, so they get a
            // little less sand to stay on screen.
            let perSource = max(1, feed / count)
            let totalFeedSteps = count == 3 ? feedSteps * 85 / 100 : feedSteps
            var config: [Float] = [Float(totalFeedSteps), Float(perSource), 0, Float(count)]
            for (x, y) in Self.sources(count: count, cols: cols, rows: rows, salt: salt) {
                config += [Float(x), Float(y)]
            }
            key = LerpGPUSimulation.Key(seed: uniforms.seed, epoch: epoch,
                                        width: cols, height: rows, config: config)
        }

        /// One source sits at the centre; two or three spread along the long
        /// axis (or around it), nudged a little by the seed so no two stories
        /// share a geometry.
        static func sources(count: Int, cols: Int, rows: Int, salt: UInt32) -> [(Int, Int)] {
            func jitter(_ i: UInt32) -> Float {
                Float(LerpGPUSimulation.hashBits(i, 91, salt) >> 8) / 16_777_216 - 0.5
            }
            let cx = Float(cols) / 2, cy = Float(rows) / 2
            let spread = min(Float(cols) * 0.22, Float(rows) * 0.42)
            var points: [(Float, Float)]
            switch count {
            case 1:
                points = [(cx, cy)]
            case 2:
                let angle = 0.6 * jitter(1)
                points = [(cx - spread * cos(angle), cy - spread * sin(angle)),
                          (cx + spread * cos(angle), cy + spread * sin(angle))]
            default:
                let turn = Float.pi * 2 / 3, start = Float.pi / 2 + 0.5 * jitter(2)
                points = (0..<3).map { i in
                    let a = start + Float(i) * turn
                    return (cx + 0.6 * spread * cos(a), cy + 0.6 * spread * sin(a))
                }
            }
            return points.enumerated().map { i, p in
                let nudge = Float(rows) * 0.04
                let x = Int((p.0 + nudge * jitter(UInt32(10 + i))).rounded())
                let y = Int((p.1 + nudge * jitter(UInt32(20 + i))).rounded())
                return (min(cols - 1, max(0, x)), min(rows - 1, max(0, y)))
            }
        }
    }

    // MARK: - Kernels

    /// config[0] = (feed steps, grains per source per step, unused, source count)
    /// config[1], config[2].xy = source cells (x, y) pairs.
    static let kernels = """
    kernel void sandpileSeed(texture2d<uint, access::read>  prev [[texture(0)]],
                             texture2d<uint, access::write> next [[texture(1)]],
                             constant LerpSimFrame& f [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= f.size.x || gid.y >= f.size.y) return;
        next.write(uint4(0u), gid);
    }

    static inline uint spTopples(texture2d<uint, access::read> t, int2 p, int2 size) {
        if (p.x < 0 || p.y < 0 || p.x >= size.x || p.y >= size.y) return 0u;
        return t.read(uint2(p)).r >> 2;
    }

    kernel void sandpileStep(texture2d<uint, access::read>  prev [[texture(0)]],
                             texture2d<uint, access::write> next [[texture(1)]],
                             constant LerpSimFrame& f [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= f.size.x || gid.y >= f.size.y) return;
        int2 p = int2(gid), size = int2(f.size);
        uint4 cell = prev.read(gid);
        uint topples = cell.r >> 2;
        uint grains = (cell.r & 3u)
            + spTopples(prev, p + int2(1, 0), size) + spTopples(prev, p - int2(1, 0), size)
            + spTopples(prev, p + int2(0, 1), size) + spTopples(prev, p - int2(0, 1), size);

        if (f.step <= uint(f.config[0].x)) {
            uint count = uint(f.config[0].w);
            float2 sources[3] = { f.config[1].xy, f.config[1].zw, f.config[2].xy };
            for (uint i = 0; i < count; ++i) {
                if (all(uint2(sources[i]) == gid)) grains += uint(f.config[0].y);
            }
        }
        next.write(uint4(grains, topples > 0u ? f.step : cell.g, 0u, 0u), gid);
    }

    // `sandpileStep`, f.count times per dispatch, in a 64×64-cell tile worked
    // by a 32×32 threadgroup, four cells a thread (LerpGPUSimulation.
    // BlockedStep). Bit-for-bit the same as f.count plain steps: integer
    // arithmetic, the same feed rule, and cells off the grid held at zero
    // exactly as the plain kernel treats them. Only the 48×48 core is
    // written; the 8-cell halo is where the tile's edge leaks in.
    #define SP_SIDE 64
    #define SP_HALO 8
    #define SP_CORE 48
    kernel void sandpileSteps(texture2d<uint, access::read>  prev [[texture(0)]],
                              texture2d<uint, access::write> next [[texture(1)]],
                              constant LerpSimFrame& f [[buffer(0)]],
                              uint2 tid [[thread_position_in_threadgroup]],
                              uint2 group [[threadgroup_position_in_grid]]) {
        threadgroup uint tile[SP_SIDE][SP_SIDE];
        int2 size = int2(f.size);
        int2 origin = int2(group) * SP_CORE - SP_HALO;
        uint count = uint(f.config[0].w), perSource = uint(f.config[0].y);
        uint feedSteps = uint(f.config[0].x);
        float2 sources[3] = { f.config[1].xy, f.config[1].zw, f.config[2].xy };

        int2 q[4];
        uint h[4], last[4], feed[4];
        bool inside[4];
        for (int k = 0; k < 4; ++k) {
            q[k] = int2(tid) + int2(k & 1, k >> 1) * (SP_SIDE / 2);
            int2 p = origin + q[k];
            inside[k] = p.x >= 0 && p.y >= 0 && p.x < size.x && p.y < size.y;
            uint4 cell = inside[k] ? prev.read(uint2(p)) : uint4(0u);
            h[k] = cell.r;
            last[k] = cell.g;
            feed[k] = 0u;
            for (uint i = 0; i < count; ++i) {
                if (inside[k] && all(int2(sources[i]) == p)) feed[k] += perSource;
            }
            tile[q[k].y][q[k].x] = h[k];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint i = 0; i < f.count; ++i) {
            uint step = f.step + i;
            uint nh[4];
            for (int k = 0; k < 4; ++k) {
                int x = q[k].x, y = q[k].y;
                uint inflow = 0u;
                if (x > 0)           inflow += tile[y][x - 1] >> 2;
                if (x < SP_SIDE - 1) inflow += tile[y][x + 1] >> 2;
                if (y > 0)           inflow += tile[y - 1][x] >> 2;
                if (y < SP_SIDE - 1) inflow += tile[y + 1][x] >> 2;
                nh[k] = inside[k] ? (h[k] & 3u) + inflow + (step <= feedSteps ? feed[k] : 0u) : 0u;
                if (h[k] >= 4u) last[k] = step;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (int k = 0; k < 4; ++k) {
                h[k] = nh[k];
                tile[q[k].y][q[k].x] = nh[k];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        for (int k = 0; k < 4; ++k) {
            int2 c = q[k] - SP_HALO;
            if (inside[k] && c.x >= 0 && c.y >= 0 && c.x < SP_CORE && c.y < SP_CORE) {
                next.write(uint4(h[k], last[k], 0u, 0u), uint2(origin + q[k]));
            }
        }
    }
    """
}
