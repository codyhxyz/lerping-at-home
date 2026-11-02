import Foundation
import Metal
import os

/// Turns a shader's full MSL source into a render pipeline. One per `MTLDevice`
/// per process, shared by every `ShaderLibrary` on that device.
///
/// ## Why shared
///
/// The saver gets one `LerpSaverView`, and so one `LerpMetalView` and one
/// `ShaderLibrary`, per display. They start together and usually ask for the
/// same look, so without a shared compiler two displays meant two identical
/// compiles racing each other. Here the second caller waits for the first and
/// gets the same pipeline object. Only *pipelines* are shared, through weak
/// references: data providers stay per library, because they carry per-view
/// state (ring buffers, `heatmap`'s cache keyed on seed and drawable size) that
/// two views must not share.
///
/// ## Two backends
///
/// - **Metal 4** (macOS 26+, `MTLGPUFamily.metal4`): `MTL4Compiler`, optionally
///   with a runtime pipeline archive (`LerpPipelineArchiveStore`, off by
///   default; read its header for the measurements behind that). The pipeline
///   it returns is an ordinary `MTLRenderPipelineState`, drawn with the classic
///   `MTLRenderCommandEncoder` like any other: only the compiler moved, the
///   command model did not. Speed is the same as classic, cold or warm; what
///   moving buys is the Metal 4 compiler and its task model, not milliseconds.
/// - **Classic**: `makeLibrary(source:)` plus `makeRenderPipelineState`, exactly
///   the calls this project always made. Used below macOS 26, on GPUs without
///   the Metal 4 family, when `LERP_PIPELINE_COMPILER=classic`, and as the
///   fallback whenever the Metal 4 path fails for a reason that is not the
///   shader's own compile error.
///
/// Thread-safe: any thread may call `pipeline(source:label:pixelFormat:)`.
final class LerpPipelineCompiler: @unchecked Sendable {

    /// The shader has no `lerpVertex` or no `lerpMain`. Thrown instead of a
    /// Metal error so `ShaderLibrary` can word it the way it always has.
    struct MissingEntryPoint: Error {}

    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "compile")

    /// Set to `classic` to force the pre-Metal-4 path, for comparison or as a
    /// kill switch. Anything else (or unset) picks the best available.
    static let compilerOverrideVariable = "LERP_PIPELINE_COMPILER"

    private static let registryLock = NSLock()
    private static var registry: [UInt64: LerpPipelineCompiler] = [:]

    /// The compiler for `device`, created on first use.
    static func shared(for device: MTLDevice) -> LerpPipelineCompiler {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[device.registryID] { return existing }
        let made = LerpPipelineCompiler(device: device)
        registry[device.registryID] = made
        return made
    }

    let device: MTLDevice
    /// `LerpMTL4Backend`, typed `AnyObject` so the stored property needs no
    /// availability annotation on a macOS 14 deployment target.
    private let mtl4: AnyObject?

    /// Which backend new compiles go through, for logs and measurements.
    var backendName: String { mtl4 == nil ? "classic" : "mtl4" }

    private let lock = NSLock()
    /// Every pipeline some caller still holds, by `memoKey`. Weak, so
    /// `ShaderLibrary.clearPipelineCache` still releases memory: once no
    /// library caches a pipeline, it falls out of here too.
    private let memo = NSMapTable<NSString, AnyObject>.strongToWeakObjects()
    private var inFlight: [String: InFlight] = [:]

    private final class InFlight {
        let done = DispatchGroup()
        var result: Result<MTLRenderPipelineState, Error>?
        init() { done.enter() }
    }

    private init(device: MTLDevice) {
        self.device = device
        // Lets the compiler service use more CPU threads when several compiles
        // overlap: the thumbnail workers, or a background prefetch running
        // beside a foreground compile.
        device.shouldMaximizeConcurrentCompilation = true

        var backend: AnyObject?
        var archive = "off"
        let forcedClassic = ProcessInfo.processInfo.environment[Self.compilerOverrideVariable] == "classic"
        if !forcedClassic, #available(macOS 26.0, *), device.supportsFamily(.metal4) {
            do {
                let store = LerpPipelineArchiveStore.make(for: device)
                backend = try LerpMTL4Backend(device: device, store: store)
                archive = store?.directory.path ?? "off"
            } catch {
                Self.log.error("MTL4Compiler unavailable, using classic compile: \(String(describing: error), privacy: .public)")
            }
        }
        self.mtl4 = backend
        Self.log.notice("""
            pipeline compiler: \(backend == nil ? "classic" : "mtl4", privacy: .public) \
            archive=\(archive, privacy: .public) gpu=\(device.name, privacy: .public)
            """)
    }

    /// The pipeline for `source`, compiled now or handed over from whoever is
    /// already compiling or holding it.
    func pipeline(source: String, label: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = Self.memoKey(source: source, label: label, pixelFormat: pixelFormat) as NSString

        lock.lock()
        if let held = memo.object(forKey: key) as? MTLRenderPipelineState {
            lock.unlock()
            return held
        }
        if let pending = inFlight[key as String] {
            lock.unlock()
            pending.done.wait()
            return try pending.result!.get()
        }
        let mine = InFlight()
        inFlight[key as String] = mine
        lock.unlock()

        let result = Result { try compile(source: source, label: label, pixelFormat: pixelFormat) }

        lock.lock()
        inFlight[key as String] = nil
        if case .success(let pipeline) = result { memo.setObject(pipeline, forKey: key) }
        mine.result = result
        lock.unlock()
        mine.done.leave()
        return try result.get()
    }

    private func compile(source: String, label: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

        if #available(macOS 26.0, *), let backend = mtl4 as? LerpMTL4Backend {
            do {
                let (pipeline, archive) = try backend.pipeline(source: source, label: label,
                                                               pixelFormat: pixelFormat,
                                                               options: Self.compileOptions())
                Self.log.notice("""
                    compiled \(label, privacy: .public) via mtl4 archive=\(archive, privacy: .public) \
                    in \(elapsed(), format: .fixed(precision: 1), privacy: .public) ms
                    """)
                return pipeline
            } catch let failure as LerpMTL4Backend.SourceError {
                // The shader's own compile error. The classic compiler would
                // say the same thing, slower; hand it straight back.
                throw failure.underlying
            } catch is MissingEntryPoint {
                throw MissingEntryPoint()
            } catch {
                Self.log.error("""
                    mtl4 pipeline failed for \(label, privacy: .public), retrying classic: \
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
        let pipeline = try classicPipeline(source: source, label: label, pixelFormat: pixelFormat)
        Self.log.notice("""
            compiled \(label, privacy: .public) via classic \
            in \(elapsed(), format: .fixed(precision: 1), privacy: .public) ms
            """)
        return pipeline
    }

    /// The path this project always took, unchanged apart from the pixel format
    /// becoming a parameter.
    private func classicPipeline(source: String, label: String, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: Self.compileOptions())
        guard let vertexFn = library.makeFunction(name: "lerpVertex"),
              let fragmentFn = library.makeFunction(name: "lerpMain") else { throw MissingEntryPoint() }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func compileOptions() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        }
        return options
    }

    /// In-process identity of a compile request. FNV-1a of the source plus its
    /// length: the same source compiled for the same target is one pipeline.
    static func memoKey(source: String, label: String, pixelFormat: MTLPixelFormat) -> String {
        String(format: "%016llx-%ld-%lu|", LerpHash.fnv1a(source), source.utf8.count, pixelFormat.rawValue) + label
    }
}

// MARK: - Metal 4

@available(macOS 26.0, *)
final class LerpMTL4Backend {

    /// A compile error in the shader source itself, as opposed to anything the
    /// Metal 4 machinery or the archive did.
    struct SourceError: Error { let underlying: Error }

    private let device: MTLDevice
    /// For archive hits and for when there is no store. Pipelines that need
    /// capturing get a compiler of their own, so each archive file holds
    /// exactly one shader and can be invalidated alone.
    private let compiler: MTL4Compiler
    private let store: LerpPipelineArchiveStore?

    init(device: MTLDevice, store: LerpPipelineArchiveStore?) throws {
        self.device = device
        let descriptor = MTL4CompilerDescriptor()
        descriptor.label = "Lerping"
        self.compiler = try device.makeCompiler(descriptor: descriptor)
        self.store = store
    }

    /// The pipeline, and what the archive contributed: `hit`, `miss` (compiled
    /// and captured for next time), `stale` (archive did not have it; replaced),
    /// `error` (archive unreadable; replaced) or `off` (no store).
    ///
    /// A hit is looked up with `MTL4Archive.makeRenderPipelineState`, not by
    /// passing the archive to the compiler in `lookupArchives`. Measured on an
    /// M5 under macOS 27 with the system shader cache warm: 0.7–0.9 ms through
    /// the archive directly, 6–12 ms through `lookupArchives`, and 1.6 ms for a
    /// plain compile that the system cache answers. The direct call also throws
    /// on a miss, which is what lets a stale archive be noticed and rewritten
    /// instead of silently costing a full compile on every launch.
    func pipeline(source: String, label: String, pixelFormat: MTLPixelFormat,
                  options: MTLCompileOptions) throws -> (MTLRenderPipelineState, String) {
        let archiveURL = store?.url(source: source, pixelFormat: pixelFormat)
        var archive: MTL4Archive?
        var status = store == nil ? "off" : "miss"
        if let archiveURL, FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                archive = try device.makeArchive(url: archiveURL)
            } catch {
                LerpPipelineCompiler.log.error("""
                    discarding unreadable pipeline archive \(archiveURL.lastPathComponent, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """)
                store?.discard(archiveURL)
                status = "error"
            }
        }

        // A miss with a store compiles through a compiler of its own, whose
        // serializer captures exactly this pipeline, so each archive file holds
        // one shader and can be invalidated alone.
        var compiler = self.compiler
        var serializer: MTL4PipelineDataSetSerializer?
        if archive == nil, archiveURL != nil, let (capturing, made) = makeCapturingCompiler() {
            compiler = made
            serializer = capturing
        }

        // The source is compiled to a library even on a hit: the archive is
        // looked up by the functions' compiled identity.
        var library = try makeLibrary(source: source, label: label, options: options, compiler: compiler)
        if let archive {
            do {
                let pipeline = try archive.makeRenderPipelineState(
                    descriptor: Self.descriptor(library: library, label: label, pixelFormat: pixelFormat))
                return (pipeline, "hit")
            } catch {
                // Not in there, or unusable. Fail open: compile, and replace
                // the archive. Rare, so rebuilding the library is acceptable.
                if let archiveURL { store?.discard(archiveURL) }
                status = "stale"
                if let (capturing, made) = makeCapturingCompiler() {
                    compiler = made
                    serializer = capturing
                    library = try makeLibrary(source: source, label: label, options: options, compiler: made)
                }
            }
        }

        let pipeline = try compiler.makeRenderPipelineState(
            descriptor: Self.descriptor(library: library, label: label, pixelFormat: pixelFormat))
        if let serializer, let archiveURL, let store {
            store.write(serializer, to: archiveURL, keepingAlive: compiler)
        }
        return (pipeline, status)
    }

    private func makeLibrary(source: String, label: String, options: MTLCompileOptions,
                             compiler: MTL4Compiler) throws -> MTLLibrary {
        let descriptor = MTL4LibraryDescriptor()
        descriptor.source = source
        descriptor.options = options
        descriptor.name = label
        let library: MTLLibrary
        do {
            library = try compiler.makeLibrary(descriptor: descriptor)
        } catch {
            throw SourceError(underlying: error)
        }
        let names = Set(library.functionNames)
        guard names.contains("lerpVertex"), names.contains("lerpMain") else {
            throw LerpPipelineCompiler.MissingEntryPoint()
        }
        return library
    }

    private func makeCapturingCompiler() -> (MTL4PipelineDataSetSerializer, MTL4Compiler)? {
        let serializerDescriptor = MTL4PipelineDataSetSerializerDescriptor()
        serializerDescriptor.configuration = .captureBinaries
        let serializer = device.makePipelineDataSetSerializer(descriptor: serializerDescriptor)
        let descriptor = MTL4CompilerDescriptor()
        descriptor.label = "Lerping (capturing)"
        descriptor.pipelineDataSetSerializer = serializer
        guard let compiler = try? device.makeCompiler(descriptor: descriptor) else { return nil }
        return (serializer, compiler)
    }

    private static func descriptor(library: MTLLibrary, label: String,
                                   pixelFormat: MTLPixelFormat) -> MTL4RenderPipelineDescriptor {
        let descriptor = MTL4RenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunctionDescriptor = function("lerpVertex", in: library)
        descriptor.fragmentFunctionDescriptor = function("lerpMain", in: library)
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        return descriptor
    }

    private static func function(_ name: String, in library: MTLLibrary) -> MTL4LibraryFunctionDescriptor {
        let function = MTL4LibraryFunctionDescriptor()
        function.name = name
        function.library = library
        return function
    }
}

// MARK: - Archive store

/// Where Metal 4 pipeline archives live: one file per compiled source, under
///
///     <Caches>/<defaults module>/Pipelines/<environment>/<source>.mtl4a
///
/// `<Caches>` is the sandbox container's inside `legacyScreenSaver` and the real
/// `~/Library/Caches` in the playground and the preview app, chosen by the same
/// write probe the thumbnail cache uses.
///
/// - **Keyed, not validated.** `<environment>` hashes the OS build and the GPU,
///   `<source>` hashes the exact MSL handed to the compiler (prelude included)
///   and the pixel format. Anything that would change the binary changes the
///   path, so a stale archive is never looked up; it is just never read again.
/// - **Bounded.** Environments other than the current one are deleted when the
///   store opens, and the current one keeps the `capacity` most recently used
///   files. The playground's hot reload compiles a new source on every edit, and
///   each of those would otherwise be kept forever.
/// - **Fail open.** Every error here means "compile without an archive", never
///   "fail the compile".
///
/// ## Off unless asked for
///
/// Measured on an M5 under macOS 27 (31 built-in shaders, fresh process each,
/// bundled host so the system shader cache can be controlled):
///
/// | | total | median/shader |
/// |---|---|---|
/// | classic, system cache cold | 1.4–2.0 s | 39–55 ms |
/// | classic, system cache warm | 14–31 ms | 0.2–0.4 ms |
/// | Metal 4, no archive, cold / warm | 1.5–2.1 s (one 3.0 s outlier) / 16–22 ms | 38–54 / 0.2–0.4 ms |
/// | Metal 4, capturing into an empty archive | 1.8–2.7 s | 49–72 ms |
/// | Metal 4, warm archive, system cache warm | 25–82 ms | 0.3–0.4 ms |
/// | Metal 4, warm archive, system cache cold | 1.05–1.3 s | 27–32 ms |
///
/// Metal already keeps a persistent per-host shader cache (in
/// `$DARWIN_USER_CACHE_DIR/<bundle id>/com.apple.metal`, and it is there and
/// warm inside `legacyScreenSaver`'s sandbox), which makes a warm compile cost
/// about 0.2 ms on either compiler. That cache and this archive go cold for the
/// same reasons — a new OS build, a changed source — so the one row the
/// archive wins (warm archive, cold system cache) is rare. Meanwhile capturing
/// costs 10–15% on every miss, a capturing compile is *not* written to the
/// system cache, and every capture leaves a ~370 KB `gpuarchiver-*` scratch
/// directory in `com.apple.gpuarchiver` that the system does not reclaim. Under
/// the playground's hot reload, every edit is a capture.
///
/// So the archive ships disabled. `LERP_PIPELINE_ARCHIVE=on` enables it at the
/// default location below; an absolute path enables it there.
@available(macOS 26.0, *)
final class LerpPipelineArchiveStore: @unchecked Sendable {

    /// `on` enables archives in the default location; an absolute path enables
    /// them in that directory. Unset or anything else: no archive.
    static let directoryOverrideVariable = "LERP_PIPELINE_ARCHIVE"

    /// Bumped if the layout or anything the key leaves out ever changes.
    private static let formatVersion = "1"
    static let capacity = 200

    let directory: URL
    private let queue = DispatchQueue(label: "com.hergenroeder.lerping.pipeline-archive", qos: .utility)

    private init(directory: URL) {
        self.directory = directory
    }

    static func make(for device: MTLDevice) -> LerpPipelineArchiveStore? {
        let setting = ProcessInfo.processInfo.environment[directoryOverrideVariable] ?? ""
        let isDefaultLocation = setting == "on"
        guard isDefaultLocation || setting.hasPrefix("/") else { return nil }
        let root: URL?
        if !isDefaultLocation {
            root = LerpFileLocations.firstWritableDirectory(in: [URL(fileURLWithPath: setting)])
        } else {
            root = LerpFileLocations.writableHomeDirectory(
                appending: "Library/Caches/" + LerpDefaults.module + "/Pipelines")
        }
        guard let root else {
            LerpPipelineCompiler.log.error("pipeline archive unavailable: no writable Caches directory")
            return nil
        }
        let environment = String(format: "%016llx", LerpHash.fnv1a(environmentKey(for: device)))
        let directory = root.appendingPathComponent(environment, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            LerpPipelineCompiler.log.error("""
                pipeline archive unavailable at \(directory.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
        let store = LerpPipelineArchiveStore(directory: directory)
        // Only in a directory this code owns: an override may point anywhere.
        if isDefaultLocation {
            store.queue.async { store.removeOtherEnvironments(in: root, keeping: environment) }
        }
        return store
    }

    /// What a compiled binary depends on besides its source: the OS build
    /// (which carries the compiler and the GPU driver) and the GPU.
    static func environmentKey(for device: MTLDevice) -> String {
        [formatVersion,
         ProcessInfo.processInfo.operatingSystemVersionString,
         device.name,
         device.architecture.name].joined(separator: "|")
    }

    func url(source: String, pixelFormat: MTLPixelFormat) -> URL {
        let name = String(format: "%016llx-%ld-%lu.mtl4a",
                          LerpHash.fnv1a(source), source.utf8.count, pixelFormat.rawValue)
        let url = directory.appendingPathComponent(name)
        queue.async { // Recently used is what `prune` keeps.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return url
    }

    func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Flushes `serializer` to `url` off the caller's thread. Written beside
    /// the target and renamed over it, so another process (the second display's
    /// host, the playground) never maps a half-written file.
    func write(_ serializer: MTL4PipelineDataSetSerializer, to url: URL, keepingAlive compiler: MTL4Compiler) {
        queue.async { [self] in
            withExtendedLifetime(compiler) {
                let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
                do {
                    try serializer.serializeAsArchiveAndFlush(url: temporary)
                    if rename(temporary.path, url.path) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    LerpPipelineCompiler.log.error("""
                        could not write pipeline archive \(url.lastPathComponent, privacy: .public): \
                        \(String(describing: error), privacy: .public)
                        """)
                    return
                }
                prune()
            }
        }
    }

    private func prune() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              case let archives = files.filter({ $0.pathExtension == "mtl4a" }),
              archives.count > Self.capacity else { return }
        let byAge = archives.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in byAge.prefix(archives.count - Self.capacity) { try? manager.removeItem(at: file) }
    }

    private func removeOtherEnvironments(in root: URL, keeping current: String) {
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent != current && !entry.lastPathComponent.hasPrefix(".") {
            try? manager.removeItem(at: entry)
        }
    }
}
