import Foundation
import Metal

/// Optional per-frame CPU-computed data for shaders that need more than the
/// fixed `LerpUniforms` block — a segment list, a lookup table, an occupancy
/// grid. A shader opts in with a comment on any of its first lines:
///
///     // lerp-data: pipes
///
/// `LerpUniforms` stays at fragment buffer index 0 and providers own indices
/// 1 and up, so a shader that declares no provider compiles and renders through
/// exactly the same path it always did.
///
/// **Purity contract.** A rendered frame in this project is a pure function of
/// (shader, time, seed): `LerpPreview --snapshot --time 60` must reproduce the
/// same image whether or not t = 0…59 were rendered first. A provider therefore
/// has to *derive* its data from `uniforms` every frame. Accumulating state
/// across frames breaks the snapshot suite, the playground's time scrubber, and
/// thumbnail generation.
public protocol LerpDataProvider: AnyObject {

    /// MSL spliced into the prelude when compiling a shader that declares this
    /// provider — the struct definitions and accessors the shader needs to read
    /// the data. It lands before the prelude's `#line 1`, so shader diagnostics
    /// keep pointing at the shader file's own line numbers.
    var metalPrelude: String { get }

    /// Called once per frame while encoding, right after `LerpUniforms` is bound
    /// at index 0. Compute this frame's data from `uniforms` and bind it at
    /// fragment buffer/texture indices 1 and up.
    func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms)

    /// As above, plus the values of whatever the shader declared with
    /// `// lerp-param:` — for a provider whose data depends on them, the way
    /// `life`'s board is sized by `size` and stepped at `speed`. Parameters are
    /// part of the same purity contract, so this changes nothing about the rule
    /// above: derive from `(uniforms, params)`, never accumulate.
    ///
    /// Defaulted to the two-argument form, so a provider that ignores parameters
    /// implements only that one and is called exactly as it always was.
    func bind(to encoder: MTLRenderCommandEncoder,
              uniforms: LerpUniforms,
              params: LerpParameterValues?)

    /// Called once per frame *before* the render pass opens, on the same
    /// command buffer, so a provider can run GPU work whose results the
    /// fragment shader then reads — compute kernels stepping a simulation, via
    /// `LerpGPUSimulation`. Whatever this encodes is ordered ahead of the
    /// `bind` that follows. Same purity contract: derive from
    /// `(uniforms, params)`, never accumulate.
    ///
    /// Defaulted to do nothing, so providers that only bind encode exactly as
    /// they always did.
    func encodeCompute(into commandBuffer: MTLCommandBuffer,
                       uniforms: LerpUniforms,
                       params: LerpParameterValues?)
}

public extension LerpDataProvider {
    func bind(to encoder: MTLRenderCommandEncoder,
              uniforms: LerpUniforms,
              params: LerpParameterValues?) {
        bind(to: encoder, uniforms: uniforms)
    }

    func encodeCompute(into commandBuffer: MTLCommandBuffer,
                       uniforms: LerpUniforms,
                       params: LerpParameterValues?) {}
}

/// Whether a frame may show what only this host, at this moment, can see.
///
/// `.live` is the look as it plays: the critter drawn from this Mac's ledger at
/// this hour, a splat's caption coming up as the look comes in. `.still` is the
/// look as a picture of itself — a pure function of (shader, parameters, time,
/// seed) and nothing else — which is what a gallery still is, and therefore
/// what the gallery's hover preview has to be too: it is the still set moving,
/// and a still drawn from inputs the preview does not share is a still the
/// preview cannot continue.
///
/// That mismatch is the bug this exists to end. The playground drew the
/// critter's still from the live ledger and clock, cached it under a key that
/// knew nothing about either, and kept it; pointing at the card then played a
/// different creature in a different sky. Bumping the recipe version cleared it
/// each time, until the hour moved on. With one mode passed to both the still
/// and the preview, they cannot read different inputs.
public enum LerpRenderMode: Sendable {
    case live
    case still
}

/// Name → provider registry. Built-ins are registered here; a host can add more
/// before creating a `ShaderLibrary`. A factory is told the library's
/// `LerpRenderMode`; one that reads nothing beyond `(uniforms, params)` — every
/// provider but the critter — ignores it.
public enum LerpDataProviders {
    public typealias Factory = (MTLDevice, LerpRenderMode) -> LerpDataProvider

    nonisolated(unsafe) private static var factories: [String: Factory] = [
        "critter": { CritterData(device: $0, mode: $1) },
        "heatmap": { d, _ in HeatmapData(device: d) },
        "ink-fluid": { d, _ in InkFluidData(device: d) },
        "life": { d, _ in LifeData(device: d) },
        "maze": { d, _ in MazeData(device: d) },
        "neural-field": { d, _ in NeuralFieldData(device: d) },
        "physarum": { d, _ in PhysarumData(device: d) },
        "pipes": { d, _ in PipesData(device: d) },
        "polytope-4d": { d, _ in Polytope4DData(device: d) },
        "reaction-diffusion": { d, _ in ReactionDiffusionData(device: d) },
        "sandpile": { d, _ in SandpileData(device: d) },
        "string-art": { d, _ in StringArtData(device: d) },
    ]
    private static let lock = NSLock()

    public static func register(_ name: String, factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[name] = factory
    }

    public static func make(named name: String, device: MTLDevice,
                            mode: LerpRenderMode = .live) -> LerpDataProvider? {
        lock.lock()
        let factory = factories[name]
        lock.unlock()
        if let factory { return factory(device, mode) }
        // `splat:<move>:<capture>[:look]` — one provider class, parameterised by name.
        if name.hasPrefix("splat:") { return SplatData(device: device, spec: name) }
        // `image:<name>` — a photo and its depth (`ImageData.swift`).
        if name.hasPrefix("image:") { return LerpImageData(device: device, spec: name) }
        return nil
    }

    public static var registeredNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return factories.keys.sorted()
    }
}

/// Small helper for providers that rewrite a buffer every frame: hands out one
/// of `count` buffers in rotation so the CPU is never scribbling on memory the
/// GPU is still reading from an in-flight frame.
public final class LerpBufferRing {
    private let buffers: [MTLBuffer]
    private var index = 0

    public init?(device: MTLDevice, length: Int, count: Int = 3, label: String) {
        var made: [MTLBuffer] = []
        for i in 0..<count {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            buffer.label = "\(label)[\(i)]"
            made.append(buffer)
        }
        self.buffers = made
    }

    /// Next buffer in the rotation, ready to be overwritten.
    public func next() -> MTLBuffer {
        let buffer = buffers[index]
        index = (index + 1) % buffers.count
        return buffer
    }
}
