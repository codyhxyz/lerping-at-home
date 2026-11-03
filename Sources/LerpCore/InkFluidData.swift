import Foundation
import Metal

/// CPU side of `ink-fluid`: runs `InkFluidSolver` (Stam's stable fluids) on a
/// coarse grid and hands the fragment shader two consecutive steps of dye plus
/// the flow between them, which it upsamples and interpolates.
///
/// A fluid is an iterative simulation with no closed form, so this follows the
/// bounded-epoch pattern `LifeData` established: the tank is reseeded from
/// `(seed, epoch)` every `epochSteps` steps, which caps the work to reach any
/// clock time at one epoch's worth of steps, and a cached solver is only ever
/// stepped forward while its complete input key — seed, epoch, grid size and
/// every parameter the solver reads — still matches. Going backwards, or any key
/// change, rebuilds from the epoch's empty tank. So `--snapshot --time 60` is
/// the same image whether or not t = 0…59 were rendered first.
///
/// Fixed timestep: the clock maps to a step index (`stepsPerSecond × speed`),
/// never to a dt, so frame rate cannot change the simulation. The fraction
/// between two steps is not simulated; the shader motion-compensates between
/// the two uploaded states instead.
///
/// The grid is sized from the drawable's *aspect*, not its pixel count, so a
/// gallery thumbnail and a full-screen frame of the same shape run the very
/// same simulation.
public final class InkFluidData: LerpDataProvider {

    // MARK: - Tunables

    /// Cells along the drawable's long axis.
    static let longAxisCells = 160
    static let minShortAxisCells = 48
    /// Simulation steps per second of clock at `speed` 1.
    static let stepsPerSecond: Double = 20
    /// Steps per reseeded story: 36 s at `speed` 1. Also the worst-case
    /// catch-up — reaching the last frame of an epoch from nothing.
    static let epochSteps = 720
    /// Uploaded states kept on the GPU. A frame binds two; each frame uploads
    /// at most two; at most `maximumDrawableCount` (2) frames are in flight —
    /// so a slot is never rewritten while a queued frame can still read it.
    static let slotCount = 8

    // MARK: - GPU-visible frame block (fragment buffer 1)

    /// Must match `LerpInkFrame` in `metalSource`.
    struct Frame {
        var dims: SIMD2<Float>
        var fraction: Float     // 0…1 between the two bound steps
        var visibility: Float   // fades to 0 at the epoch boundary
        var phase: Float        // 0…1 through the epoch
        var pad0: Float = 0
        var pad1: Float = 0
        var pad2: Float = 0
    }

    // MARK: - Cache (its key is the whole input)

    struct Key: Hashable {
        var seed: UInt32
        var epoch: Int
        var width: Int
        var height: Int
        var settings: InkFluidSolver.Settings
    }

    struct Slot {
        var dye: MTLTexture
        var velocity: MTLTexture
        var key: Key?
        var step = -1
    }

    private let device: MTLDevice
    private var key: Key?
    private var solver: InkFluidSolver?
    private var slots: [Slot] = []
    private var nextSlot = 0
    private var dyeScratch: [Float16] = []
    private var velocityScratch: [Float16] = []

    public init(device: MTLDevice) {
        self.device = device
    }

    public var metalPrelude: String { InkFluidData.metalSource }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let speed = Double(min(2, max(0.25, scalar(params, "speed", 1))))
        let (width, height) = Self.dimensions(for: uniforms.resolution)
        let clock = Self.clock(time: uniforms.time, speed: speed)
        let wanted = Key(seed: uniforms.seed.bitPattern, epoch: clock.epoch,
                         width: width, height: height,
                         settings: Self.settings(params))

        guard let older = state(clock.step, key: wanted),
              let newer = state(clock.step + 1, key: wanted) else { return }

        var frame = Frame(dims: SIMD2<Float>(Float(width), Float(height)),
                          fraction: clock.fraction,
                          visibility: Self.visibility(phase: clock.phase),
                          phase: clock.phase)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setFragmentTexture(older.dye, index: 1)
        encoder.setFragmentTexture(newer.dye, index: 2)
        encoder.setFragmentTexture(newer.velocity, index: 3)
    }

    // MARK: - Clock

    struct Clock {
        var epoch: Int
        var step: Int        // the earlier of the two bound steps
        var fraction: Float
        var phase: Float
    }

    static func clock(time: Float, speed: Double) -> Clock {
        let total = Double(max(0, time)) * stepsPerSecond * speed
        let epochLength = Double(epochSteps)
        let epoch = Int((total / epochLength).rounded(.down))
        let local = total - Double(epoch) * epochLength
        let step = min(epochSteps - 1, Int(local.rounded(.down)))
        return Clock(epoch: epoch, step: step,
                     fraction: Float(min(1, max(0, local - Double(step)))),
                     phase: Float(local / epochLength))
    }

    /// The tank has cleared by the end of a story (`InkFluidSolver.dyeKeep`);
    /// this takes the last of it to exactly black so the reseed cannot show.
    static func visibility(phase: Float) -> Float {
        let x = min(1, max(0, (phase - 0.94) / 0.055))
        return 1 - x * x * (3 - 2 * x)
    }

    static func dimensions(for resolution: SIMD2<Float>) -> (Int, Int) {
        let w = max(1, resolution.x), h = max(1, resolution.y)
        let long = longAxisCells
        let short = min(long, max(minShortAxisCells, Int((Float(long) * min(w, h) / max(w, h)).rounded())))
        return w >= h ? (long, short) : (short, long)
    }

    static func settings(_ params: LerpParameterValues?) -> InkFluidSolver.Settings {
        func value(_ name: String, _ fallback: Float, _ lo: Float, _ hi: Float) -> Float {
            let raw = params?[name]?.scalarValue.map(Float.init) ?? fallback
            return min(hi, max(lo, raw))
        }
        // Fallbacks match the shader's declared defaults.
        let viscosity = value("viscosity", 0.05, 0, 1)
        return InkFluidSolver.Settings(viscosity: 0.5 * viscosity,
                                       stir: value("stir", 1, 0, 2),
                                       vorticity: 0.6 * value("curl", 0.55, 0, 1))
    }

    private func scalar(_ params: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let value = params?[name]?.scalarValue else { return fallback }
        return Float(value)
    }

    static func solverSeed(seed: Float, epoch: Int) -> UInt64 {
        (UInt64(seed.bitPattern) &* LerpSplitMix64.gamma)
            ^ (UInt64(bitPattern: Int64(epoch)) &* 0xD1B5_4A32_D192_ED03)
    }

    /// A fresh solver for `key`, at step 0 of its epoch.
    static func makeSolver(_ key: Key) -> InkFluidSolver {
        InkFluidSolver(width: key.width, height: key.height,
                       seed: solverSeed(seed: Float(bitPattern: key.seed), epoch: key.epoch),
                       epochSteps: epochSteps, settings: key.settings)
    }

    // MARK: - States on the GPU

    /// The uploaded slot holding `step` of `key`, stepping (or rebuilding) the
    /// solver to reach it if no slot does yet.
    private func state(_ step: Int, key wanted: Key) -> Slot? {
        if let hit = slots.first(where: { $0.key == wanted && $0.step == step }) { return hit }

        if key != wanted || solver == nil || solver!.step > step {
            solver = Self.makeSolver(wanted)
            key = wanted
        }
        guard let solver else { return nil }
        while solver.step < step { solver.advance() }
        return upload(solver, key: wanted)
    }

    private func upload(_ solver: InkFluidSolver, key: Key) -> Slot? {
        let w = solver.width, h = solver.height
        if slots.isEmpty || slots[0].dye.width != w || slots[0].dye.height != h {
            slots = (0..<Self.slotCount).compactMap { _ in
                guard let dye = Self.makeTexture(device, .rgba16Float, w, h, "ink.dye"),
                      let velocity = Self.makeTexture(device, .rg16Float, w, h, "ink.velocity")
                else { return nil }
                return Slot(dye: dye, velocity: velocity)
            }
            nextSlot = 0
            guard slots.count == Self.slotCount else { slots = []; return nil }
        }
        if dyeScratch.count != w * h * 4 {
            dyeScratch = [Float16](repeating: 0, count: w * h * 4)
            velocityScratch = [Float16](repeating: 0, count: w * h * 2)
        }

        let index = nextSlot
        nextSlot = (nextSlot + 1) % slots.count
        let region = MTLRegionMake2D(0, 0, w, h)
        dyeScratch.withUnsafeMutableBufferPointer { out in
            solver.writeDyes(into: out.baseAddress!)
            slots[index].dye.replace(region: region, mipmapLevel: 0,
                                     withBytes: out.baseAddress!, bytesPerRow: w * 8)
        }
        velocityScratch.withUnsafeMutableBufferPointer { out in
            solver.writeVelocity(into: out.baseAddress!)
            slots[index].velocity.replace(region: region, mipmapLevel: 0,
                                          withBytes: out.baseAddress!, bytesPerRow: w * 4)
        }
        slots[index].key = key
        slots[index].step = solver.step
        return slots[index]
    }

    private static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat,
                                    _ width: Int, _ height: Int, _ label: String) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = label
        return texture
    }

    // MARK: - Determinism check

    /// Reaching a clock time by stepping through every frame before it must
    /// give bit-for-bit the state that reaching it cold gives. Returns the two
    /// digests (cold, warm) for `time`, warm having visited every 1/60 s first.
    public static func determinismDigests(time: Float, seed: Float,
                                          resolution: SIMD2<Float> = SIMD2(1200, 750),
                                          params: LerpParameterValues? = nil) -> (UInt64, UInt64) {
        let speed = Double(min(2, max(0.25, params?["speed"]?.scalarValue.map(Float.init) ?? 1)))
        let (w, h) = dimensions(for: resolution)
        let settings = settings(params)
        func keyed(_ t: Float) -> (Key, Int) {
            let c = clock(time: t, speed: speed)
            return (Key(seed: seed.bitPattern, epoch: c.epoch, width: w, height: h,
                        settings: settings), c.step + 1)
        }

        let (coldKey, target) = keyed(time)
        let cold = makeSolver(coldKey)
        while cold.step < target { cold.advance() }

        var warm: InkFluidSolver?
        var warmKey: Key?
        var frame = 0
        while true {
            let t = min(time, Float(frame) / 60)
            let (k, s) = keyed(t)
            if warmKey != k || warm == nil || warm!.step > s { warm = makeSolver(k); warmKey = k }
            while warm!.step < s { warm!.advance() }
            if t >= time { break }
            frame += 1
        }
        return (cold.digest(), warm!.digest())
    }

    // MARK: - MSL

    static let metalSource = """
    // ---- lerp-data: ink-fluid ----------------------------------------------
    // Fragment buffer 1: LerpInkFrame. Fragment textures, one texel per fluid
    // cell, row 0 at the BOTTOM of the tank (y up, like lerpUV):
    //   1  rgba16Float  dyes 1, 2, 3 and |curl| at the earlier step
    //   2  rgba16Float  the same at the later step
    //   3  rg16Float    flow at the later step, in cells per step
    struct LerpInkFrame {
        float2 dims;        // grid cells, x and y
        float  fraction;    // 0..1 from the earlier step to the later
        float  visibility;  // 1, falling to 0 at the end of each epoch
        float  phase;       // 0..1 through the epoch
        float  pad0, pad1, pad2;
    };

    constexpr sampler lerpInkSampler(coord::normalized,
                                     address::clamp_to_edge,
                                     filter::linear);
    """
}
