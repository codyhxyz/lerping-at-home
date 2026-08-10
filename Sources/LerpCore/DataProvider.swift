import Foundation
import Metal

/// Optional per-frame CPU-computed data for shaders that need more than the
/// 16-byte `LerpUniforms` block — a segment list, a lookup table, an occupancy
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
}

public extension LerpDataProvider {
    func bind(to encoder: MTLRenderCommandEncoder,
              uniforms: LerpUniforms,
              params: LerpParameterValues?) {
        bind(to: encoder, uniforms: uniforms)
    }
}

/// Name → provider registry. Built-ins are registered here; a host can add more
/// before creating a `ShaderLibrary`.
public enum LerpDataProviders {
    public typealias Factory = (MTLDevice) -> LerpDataProvider

    nonisolated(unsafe) private static var factories: [String: Factory] = [
        "heatmap": { HeatmapData(device: $0) },
        "life": { LifeData(device: $0) },
        "pipes": { PipesData(device: $0) },
    ]
    private static let lock = NSLock()

    public static func register(_ name: String, factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[name] = factory
    }

    public static func make(named name: String, device: MTLDevice) -> LerpDataProvider? {
        lock.lock()
        let factory = factories[name]
        lock.unlock()
        return factory?(device)
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
