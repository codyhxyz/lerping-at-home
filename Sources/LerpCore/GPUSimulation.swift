import Foundation
import Metal

/// A deterministic simulation stepped by compute kernels on the GPU, for data
/// providers whose state has no closed form: cellular automata, sandpiles,
/// reaction-diffusion, fluids. It is `LifeData`'s bounded-epoch contract with
/// the inner loop moved to the GPU, so a provider supplies the kernels and the
/// clock and this object does the rest:
///
/// - **State** is one or more *planes*: textures of a fixed size per key,
///   normally held twice and ping-ponged. A pass reads the current textures
///   and writes the next ones of the planes it declares, which then swap.
/// - **Seeding** runs the `seed` passes once, producing generation 0 from
///   nothing but the key — `(seed, epoch, grid, config)` — so reseeding is how
///   every epoch begins and how any cached state is thrown away.
/// - **Stepping** runs the `step` passes once per generation. `advance` brings
///   the state to exactly the generation asked for, catching up from what is
///   cached when the key matches and the target is ahead, and reseeding
///   otherwise. The cache key is the whole input, which is what makes stepping
///   cached state legal under the purity contract (see `PORTING.md`).
///
/// **Determinism.** Every dispatch of a pass is a pure function of the
/// previous textures and the `LerpSimFrame` constants, and passes are encoded
/// in order on one serial compute encoder, so generation N is the same bytes
/// whether it was reached in one frame or over ten thousand. That holds as long
/// as kernels keep to the rules in `docs/metal-capabilities.md`: each thread
/// writes only its own texels of ping-ponged planes, and nothing accumulates
/// floats with atomics (whose order the GPU does not fix). Integer atomics are
/// order-independent and allowed, into a plane with `pingPong: false`.
///
/// **Never ahead of the GPU.** The CPU writes nothing the GPU reads except
/// `setBytes` constants, so there is no ring buffer to manage. The one thing
/// the CPU tracks is which generation the textures hold; a command buffer
/// that errors (a GPU restart, a watchdog) clears that, and the next frame
/// reseeds instead of building on bytes that may never have been written.
public final class LerpGPUSimulation {

    /// One state texture. `extent` nil means the key's grid size; a fixed
    /// extent suits state that is not per-cell, such as an agent list stored
    /// one agent per texel.
    ///
    /// `pingPong: false` holds a single texture, bound at both its current and
    /// its next index and never swapped: scratch that a pass rebuilds every
    /// step, or a target of integer atomics (`atomic: true` adds
    /// `.shaderAtomic` usage), such as physarum's deposit map. Clear it in a
    /// pass before anything reads it; it carries no generation of its own.
    public struct Plane {
        public var pixelFormat: MTLPixelFormat
        public var extent: (width: Int, height: Int)?
        public var label: String
        public var pingPong: Bool
        public var atomic: Bool

        public init(_ label: String, pixelFormat: MTLPixelFormat,
                    extent: (width: Int, height: Int)? = nil,
                    pingPong: Bool = true, atomic: Bool = false) {
            self.label = label
            self.pixelFormat = pixelFormat
            self.extent = extent
            self.pingPong = pingPong
            self.atomic = atomic
        }
    }

    /// One kernel dispatch, `repeats` times in a row (a Jacobi solve, say),
    /// over the extent of plane `domain`. Kernel bindings, every time:
    ///
    ///     texture(i)          current texture of plane i   (access::read)
    ///     texture(planes + i) next texture of plane i      (access::write)
    ///     buffer(0)           constant LerpSimFrame&
    ///
    /// `writes` lists the planes the pass produces (nil: all of them). Only
    /// those swap after it, so the pass must write every texel of each and
    /// must not write the others; a plane it leaves alone keeps its current
    /// texture. Fluids are the case this is for: a pressure solve repeats one
    /// pass forty times without copying velocity and dye through each time.
    public struct Pass {
        public var kernel: String
        public var domain: Int
        public var repeats: Int
        public var writes: [Int]?

        public init(_ kernel: String, domain: Int = 0, repeats: Int = 1, writes: [Int]? = nil) {
            self.kernel = kernel
            self.domain = domain
            self.repeats = max(1, repeats)
            self.writes = writes
        }
    }

    /// Several generations in one dispatch ("temporal blocking"), for a step
    /// that is one local stencil pass. Stepping a small grid is bound by
    /// dispatch overhead, not arithmetic — a 330×220 sandpile costs ~14 µs a
    /// step whatever the kernel does — and catching up to an arbitrary time
    /// can take tens of thousands of steps. A blocked kernel loads a
    /// `tileSide`² tile of cells into threadgroup memory (worked by a
    /// `threadgroupSide`² threadgroup, so a thread may own several cells),
    /// runs `f.count` steps there, and writes back only the inner
    /// `core = tileSide - 2·halo` square, whose cells the tile edge cannot
    /// have reached yet. Dispatches are laid out so those cores tile the
    /// grid: threadgroup (i, j) covers cells from `(i, j)·core - halo`.
    ///
    /// It replaces the whole step sequence and writes every plane (all swap
    /// after each dispatch), so it suits a step that is one local stencil.
    /// It must produce bit-for-bit what the plain `step` passes produce; those
    /// stay the reference and the fallback, used whenever the device cannot
    /// run a threadgroup that large or `blockingEnabled` is off.
    public struct BlockedStep {
        public var kernel: String
        public var stepsPerDispatch: Int
        public var tileSide: Int
        public var halo: Int
        public var threadgroupSide: Int

        public var core: Int { tileSide - 2 * halo }

        /// `halo` must be at least the reach of `stepsPerDispatch` steps (one
        /// cell a step for a 3×3 or 5-point stencil). `threadgroupSide`
        /// defaults to `tileSide`: one thread per cell.
        public init(_ kernel: String, stepsPerDispatch: Int, tileSide: Int, halo: Int,
                    threadgroupSide: Int? = nil) {
            precondition(stepsPerDispatch >= 1 && halo >= stepsPerDispatch && tileSide > 2 * halo,
                         "a blocked step needs halo >= stepsPerDispatch and room for a core")
            self.kernel = kernel
            self.stepsPerDispatch = stepsPerDispatch
            self.tileSide = tileSide
            self.halo = halo
            self.threadgroupSide = threadgroupSide ?? tileSide
        }
    }

    /// Everything a generation depends on besides its index. Providers derive
    /// `epoch` from the clock exactly as `LifeData` does and put every
    /// parameter that changes the simulation in `config` (at most 16 floats,
    /// handed to the kernels as `f.config[0...3]`).
    public struct Key: Hashable {
        public var seed: UInt32
        public var epoch: Int
        public var width: Int
        public var height: Int
        public var config: [UInt32]

        public init(seed: Float, epoch: Int, width: Int, height: Int, config: [Float] = []) {
            precondition(config.count <= 16, "LerpGPUSimulation.Key holds at most 16 config floats")
            self.seed = seed.bitPattern
            self.epoch = epoch
            self.width = width
            self.height = height
            self.config = config.map(\.bitPattern)
        }
    }

    /// Mirrors `struct LerpSimFrame` in `kernelHeader`: 96 bytes.
    struct Frame {
        var size: SIMD2<UInt32>
        var seed: UInt32
        var epoch: UInt32
        var step: UInt32
        var pass: UInt32
        var iteration: UInt32
        var count: UInt32 = 1
        var config: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    /// What every simulation's kernel source is compiled after: the shared
    /// Lerping helpers (hashes, noise, `glmod`), the frame constants, and an
    /// integer hash that is identical on every GPU, for seeding.
    public static let kernelHeader = """
        // ---- LerpGPUSimulation --------------------------------------------------
        struct LerpSimFrame {
            uint2  size;      // grid cells of this key (plane extents may differ)
            uint   seed;      // bit pattern of u.seed
            uint   epoch;     // which bounded story this is
            uint   step;      // generation being produced: 0 while seeding
                              // (a blocked step: the first of `count`)
            uint   pass;      // index of this pass within seed or step
            uint   iteration; // 0..<repeats within this pass
            uint   count;     // generations this dispatch produces: 1, or up
                              // to stepsPerDispatch for a BlockedStep
            float4 config[4]; // provider-defined; part of the cache key
        };

        // Integer hash to [0, 1): the same bits on every GPU and on the CPU
        // (`LerpGPUSimulation.hash`), unlike the float hashes in the prelude.
        static inline uint lerpSimHashBits(uint x, uint y, uint salt) {
            uint h = (x * 0x27D4EB2Du) ^ (y * 0x165667B1u) ^ (salt * 0x9E3779B9u);
            h ^= h >> 15; h *= 0x2545F491u;
            h ^= h >> 13; h *= 0x85EBCA6Bu;
            h ^= h >> 16;
            return h;
        }
        static inline float lerpSimHash(uint x, uint y, uint salt) {
            return float(lerpSimHashBits(x, y, salt) >> 8) * (1.0 / 16777216.0);
        }
        """

    /// The CPU twin of `lerpSimHashBits`.
    public static func hashBits(_ x: UInt32, _ y: UInt32, _ salt: UInt32) -> UInt32 {
        var h = (x &* 0x27D4EB2D) ^ (y &* 0x165667B1) ^ (salt &* 0x9E3779B9)
        h ^= h >> 15; h = h &* 0x2545F491
        h ^= h >> 13; h = h &* 0x85EBCA6B
        h ^= h >> 16
        return h
    }

    public let device: MTLDevice
    public let label: String
    private let planes: [Plane]
    private let seedPasses: [(Pass, MTLComputePipelineState)]
    private let stepPasses: [(Pass, MTLComputePipelineState)]
    private let blocked: (BlockedStep, MTLComputePipelineState)?

    /// Whether `advance` may use the blocked step. On by default; turning it
    /// off is for checking the blocked kernel against the plain passes.
    public var blockingEnabled = true
    /// Whether this device can run the blocked step at all.
    public var supportsBlocking: Bool { blocked != nil }

    private var key: Key?
    /// The generation `current` holds; meaningful only while `key` is set.
    public private(set) var generation = 0
    /// Per plane: the texture holding the current generation, and its partner.
    private var current: [MTLTexture] = []
    private var next: [MTLTexture] = []

    /// Set from a command buffer's completion handler, on a Metal thread.
    private let invalidation = NSLock()
    private var invalidated = false

    /// Compiles `source` (after `kernelHeader`) and builds every pass's
    /// pipeline. Throws with the compiler's diagnostics, so a provider can log
    /// them and fall back; nothing is allocated until the first `advance`.
    public init(device: MTLDevice, label: String, source: String,
                planes: [Plane], seed: [Pass], step: [Pass],
                blockedStep: BlockedStep? = nil) throws {
        precondition(!planes.isEmpty && !seed.isEmpty && !step.isEmpty)
        precondition(MemoryLayout<Frame>.size == 96, "Frame must match struct LerpSimFrame")
        self.device = device
        self.label = label
        self.planes = planes
        let full = LerpPrelude.helpers + "\n\n" + Self.kernelHeader + "\n\n#line 1\n" + source
        let library = try device.makeLibrary(source: full, options: LerpPipelineCompiler.compileOptions())
        var built: [String: MTLComputePipelineState] = [:]
        func pipeline(_ kernel: String) throws -> MTLComputePipelineState {
            if let made = built[kernel] { return made }
            guard let function = library.makeFunction(name: kernel) else {
                throw NSError(domain: "LerpingAtHome", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "\(label): no kernel named \(kernel)"])
            }
            let descriptor = MTLComputePipelineDescriptor()
            descriptor.label = "Lerping/\(label).\(kernel)"
            descriptor.computeFunction = function
            let made = try device.makeComputePipelineState(descriptor: descriptor,
                                                           options: [], reflection: nil)
            built[kernel] = made
            return made
        }
        func pipelines(_ passes: [Pass]) throws -> [(Pass, MTLComputePipelineState)] {
            try passes.map { pass in
                precondition(planes.indices.contains(pass.domain), "pass \(pass.kernel) has no plane \(pass.domain)")
                return (pass, try pipeline(pass.kernel))
            }
        }
        self.seedPasses = try pipelines(seed)
        self.stepPasses = try pipelines(step)
        // A blocked kernel that fails to build, or needs a bigger threadgroup
        // than this GPU runs, costs speed and nothing else: the plain passes
        // produce the same bits.
        if let blockedStep, let made = try? pipeline(blockedStep.kernel),
           made.maxTotalThreadsPerThreadgroup >= blockedStep.threadgroupSide * blockedStep.threadgroupSide {
            self.blocked = (blockedStep, made)
        } else {
            self.blocked = nil
        }
    }

    /// The textures holding the current generation, one per plane, in plane
    /// order — what a provider binds for the fragment shader. Empty until the
    /// first successful `advance`.
    public var textures: [MTLTexture] { key == nil ? [] : current }

    /// Encodes into `commandBuffer` whatever brings the state to generation
    /// `target` of `wanted`, and returns the textures that will then hold it
    /// (nil if they could not be allocated). Encodes nothing when the state is
    /// already there. Call it before the command buffer's render pass, from one
    /// thread at a time — the render thread, in practice.
    ///
    /// The work is bounded by the provider, not here: `target` is at most one
    /// epoch's worth of steps, so a cold start or a scrub backwards costs at
    /// most that many dispatches, and steady playback costs a few per frame.
    @discardableResult
    public func advance(_ commandBuffer: MTLCommandBuffer, to target: Int, of wanted: Key) -> [MTLTexture]? {
        invalidation.lock()
        if invalidated { key = nil; invalidated = false }
        invalidation.unlock()

        guard allocate(for: wanted) else { key = nil; return nil }
        let reseed = key != wanted || target < generation
        let steps = max(0, target - (reseed ? 0 : generation))
        guard reseed || steps > 0 else { return current }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "Lerping/\(label) \(reseed ? "seed+" : "")\(steps) steps"

        var frame = Frame(size: SIMD2(UInt32(wanted.width), UInt32(wanted.height)),
                          seed: wanted.seed, epoch: UInt32(truncatingIfNeeded: wanted.epoch),
                          step: 0, pass: 0, iteration: 0,
                          config: Self.packConfig(wanted.config))
        if reseed {
            encode(seedPasses, step: 0, frame: &frame, on: encoder)
            generation = 0
        }
        if blockingEnabled, let (spec, pipeline) = blocked {
            var remaining = steps
            frame.pass = 0
            frame.iteration = 0
            encoder.setComputePipelineState(pipeline)
            let groups = MTLSize(width: (wanted.width + spec.core - 1) / spec.core,
                                 height: (wanted.height + spec.core - 1) / spec.core, depth: 1)
            let threads = MTLSize(width: spec.threadgroupSide, height: spec.threadgroupSide, depth: 1)
            while remaining > 0 {
                let count = min(spec.stepsPerDispatch, remaining)
                frame.step = UInt32(truncatingIfNeeded: generation + 1)
                frame.count = UInt32(count)
                encoder.setTextures(current, range: 0..<current.count)
                encoder.setTextures(next, range: current.count..<(2 * current.count))
                encoder.setBytes(&frame, length: MemoryLayout<Frame>.size, index: 0)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
                swap(&current, &next)
                generation += count
                remaining -= count
            }
            frame.count = 1
        } else {
            for _ in 0..<steps {
                generation += 1
                encode(stepPasses, step: generation, frame: &frame, on: encoder)
            }
        }
        encoder.endEncoding()
        key = wanted

        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard buffer.status == .error, let self else { return }
            self.invalidation.lock()
            self.invalidated = true
            self.invalidation.unlock()
        }
        return current
    }

    /// Drops the cached state; the next `advance` reseeds.
    public func reset() { key = nil }

    private func encode(_ passes: [(Pass, MTLComputePipelineState)], step: Int,
                        frame: inout Frame, on encoder: MTLComputeCommandEncoder) {
        frame.step = UInt32(truncatingIfNeeded: step)
        for (index, (pass, pipeline)) in passes.enumerated() {
            frame.pass = UInt32(index)
            let domain = current[pass.domain]
            let width = pipeline.threadExecutionWidth
            let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            let groups = MTLSize(width: (domain.width + width - 1) / width,
                                 height: (domain.height + height - 1) / height, depth: 1)
            encoder.setComputePipelineState(pipeline)
            for iteration in 0..<pass.repeats {
                frame.iteration = UInt32(iteration)
                encoder.setTextures(current, range: 0..<current.count)
                encoder.setTextures(next, range: current.count..<(2 * current.count))
                encoder.setBytes(&frame, length: MemoryLayout<Frame>.size, index: 0)
                // Whole threadgroups only, so this runs on every GPU the saver
                // supports; kernels bounds-check against their texture.
                encoder.dispatchThreadgroups(groups,
                                             threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
                for plane in pass.writes ?? Array(current.indices) {
                    swap(&current[plane], &next[plane])
                }
            }
        }
    }

    /// (Re)creates the ping-pong textures when the key's grid changes size.
    private func allocate(for wanted: Key) -> Bool {
        let extents = planes.map { $0.extent ?? (wanted.width, wanted.height) }
        if current.count == planes.count,
           zip(current, extents).allSatisfy({ $0.width == $1.0 && $0.height == $1.1 }) {
            return true
        }
        current = []; next = []; key = nil
        for (plane, extent) in zip(planes, extents) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: plane.pixelFormat, width: max(1, extent.0), height: max(1, extent.1),
                mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            if plane.atomic { descriptor.usage.insert(.shaderAtomic) }
            descriptor.storageMode = .private
            guard let a = device.makeTexture(descriptor: descriptor),
                  let b = plane.pingPong ? device.makeTexture(descriptor: descriptor) : a else {
                current = []; next = []
                return false
            }
            a.label = "Lerping/\(label).\(plane.label)[0]"
            if plane.pingPong { b.label = "Lerping/\(label).\(plane.label)[1]" }
            current.append(a)
            next.append(b)
        }
        return true
    }

    private static func packConfig(_ bits: [UInt32]) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
        var f = [Float](repeating: 0, count: 16)
        for (i, b) in bits.prefix(16).enumerated() { f[i] = Float(bitPattern: b) }
        return (SIMD4(f[0], f[1], f[2], f[3]), SIMD4(f[4], f[5], f[6], f[7]),
                SIMD4(f[8], f[9], f[10], f[11]), SIMD4(f[12], f[13], f[14], f[15]))
    }
}
