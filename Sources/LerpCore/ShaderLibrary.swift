import Foundation
import Metal

public struct LerpShader: Sendable {
    public let name: String        // file stem, e.g. "neuro-noise"
    public let source: String
    public let isBuiltIn: Bool
    public let url: URL?

    /// Tunable parameters the file declares with `// lerp-param:`, in
    /// declaration order. Empty for a shader that declares none — which is
    /// every shader that has not been given any, and which compiles and renders
    /// through exactly the path it always did.
    public let parameters: [LerpParam]
    /// Named presets the file declares with `// lerp-preset:`.
    public let presets: [LerpPreset]
    /// Malformed parameter/preset declarations. `pipeline(for:)` refuses to
    /// compile a shader that has any, so a typo surfaces as an error rather
    /// than a silently-wrong render.
    public let parameterErrors: [LerpParamError]

    public init(name: String, source: String, isBuiltIn: Bool, url: URL?) {
        self.name = name
        self.source = source
        self.isBuiltIn = isBuiltIn
        self.url = url
        let parsed = LerpParamParser.parse(source: source)
        self.parameters = parsed.parameters
        self.presets = parsed.presets
        self.parameterErrors = parsed.errors
    }

    public var displayName: String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Fresh parameter values at the shader's declared defaults.
    public func defaultParameterValues() -> LerpParameterValues {
        LerpParameterValues(parameters)
    }

    public func preset(named name: String) -> LerpPreset? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Name of the `LerpDataProvider` this shader asks for, declared as a
    /// comment among its first lines:
    ///
    ///     // lerp-data: pipes
    ///
    /// nil for every shader that does not need CPU-side data, which is the
    /// default and the path all the built-in shaders take.
    public var dataProviderName: String? {
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("//") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.lowercased().hasPrefix("lerp-data:") else { continue }
            let value = body.dropFirst("lerp-data:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

public enum ShaderLocations {
    /// Directories scanned for user-supplied .metal shader files, in priority order.
    /// `NSHomeDirectory()` resolves to the sandbox container inside legacyScreenSaver
    /// and to the real home directory in the preview app; we also try the real home
    /// explicitly so both hosts can share a folder when the sandbox permits it.
    public static func customShaderDirectories() -> [URL] {
        var dirs: [URL] = []
        let suffix = "Library/Application Support/Lerping/Shaders"
        dirs.append(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(suffix))
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            let realHome = URL(fileURLWithPath: String(cString: home))
            dirs.append(realHome.appendingPathComponent(suffix))
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.path).inserted }
    }

    /// The repo's `Sources/Shaders` directory, when a development host is running
    /// out of a build tree — nil for an installed screensaver, which reads its
    /// shaders from the bundle instead.
    ///
    /// The working directory comes first, because that is how `make preview` and
    /// `make playground` run us. Failing that we walk up from the executable, so
    /// `build/LerpPreview` still finds the repo when it is launched from Finder
    /// or from any other directory.
    public static func repoShaderDirectory() -> URL? {
        var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        for _ in 0..<6 {
            dir.deleteLastPathComponent()
            roots.append(dir)
        }
        return roots.map { $0.appendingPathComponent("Sources/Shaders") }
            .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }?
            .standardizedFileURL
    }

    /// `repoShaderDirectory()` shaped for `ShaderLibrary(extraSearchURLs:)`.
    public static func repoSearchURLs() -> [URL] {
        repoShaderDirectory().map { [$0] } ?? []
    }
}

public extension Collection where Element == LerpShader {
    /// The shader with this name, if this list has one.
    func named(_ name: String) -> LerpShader? {
        first { $0.name == name }
    }
}

/// Discovers shader files and compiles them into render pipelines at runtime.
/// Runtime compilation keeps built-in and custom shaders on one code path and
/// means no Metal toolchain is needed to build or extend the project.
public final class ShaderLibrary {
    public let device: MTLDevice
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    private var dataProviders: [String: LerpDataProvider] = [:]
    private let extraSearchURLs: [URL]

    public private(set) var compileErrors: [String: String] = [:]

    public init(device: MTLDevice, extraSearchURLs: [URL] = []) {
        self.device = device
        self.extraSearchURLs = extraSearchURLs
    }

    /// Built-in shaders ship as .metal source files in the host bundle's Resources/Shaders.
    /// `Bundle(for:)` is the .saver bundle when this code is linked into it;
    /// `Bundle.main` covers the plain executables, where the two differ.
    private func builtInDirectory() -> URL? {
        for bundle in [Bundle(for: ShaderLibrary.self), Bundle.main] {
            if let url = bundle.resourceURL?.appendingPathComponent("Shaders"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func metalFiles(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// Every directory scanned, in *ascending* priority: a file found later
    /// replaces one of the same name found earlier.
    private func searchDirectories() -> [(url: URL, isBuiltIn: Bool)] {
        var dirs: [(url: URL, isBuiltIn: Bool)] = []
        // Lowest: the copy that ships inside the host bundle.
        if let builtIn = builtInDirectory() { dirs.append((builtIn, true)) }
        // Above it: a dev host pointing at a source tree. Reversed, so the
        // caller's first entry is the one that wins.
        dirs += extraSearchURLs.reversed().map { (url: $0, isBuiltIn: true) }
        // Highest: the user's drop folder, so a custom file shadows a built-in.
        dirs += ShaderLocations.customShaderDirectories().map { (url: $0, isBuiltIn: false) }
        return dirs
    }

    /// All available shaders. Custom shaders with the same file stem override built-ins.
    public func discover() -> [LerpShader] {
        var byName: [String: LerpShader] = [:]
        for (dir, isBuiltIn) in searchDirectories() {
            for url in metalFiles(in: dir) {
                let name = url.deletingPathExtension().lastPathComponent
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                byName[name] = LerpShader(name: name, source: source, isBuiltIn: isBuiltIn, url: url)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public func shader(named name: String) -> LerpShader? {
        discover().named(name)
    }

    /// The name `offset` places from `current` in `names`, wrapping at both ends;
    /// nil for an empty list. A `current` the list does not contain counts as
    /// position 0, so stepping forward from nothing lands on the first name.
    ///
    /// This is the only place shader cycling wraps around. The ←/→ keys, the
    /// shuffle rotation and the playground's next/previous all used to spell the
    /// same `(i + d + n) % n` out for themselves.
    public static func name(in names: [String], after current: String, offset: Int) -> String? {
        guard !names.isEmpty else { return nil }
        let index = names.firstIndex(of: current) ?? 0
        return names[(((index + offset) % names.count) + names.count) % names.count]
    }

    /// Records `message` as this shader's compile error and throws it. Every
    /// refusal in here goes through this, so `compileErrors` cannot disagree
    /// with what the caller was handed.
    private func fail(_ shader: LerpShader, _ code: Int, _ message: String) throws -> Never {
        compileErrors[shader.name] = message
        throw NSError(domain: "LerpingAtHome", code: code,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Drops every cached pipeline. Hosts that recompile the same shader name
    /// over and over (the playground's hot reload keys the cache on the edited
    /// source, so every keystroke would add an entry) call this to bound memory.
    public func clearPipelineCache() {
        pipelineCache.removeAll()
    }

    /// The `LerpDataProvider` a shader asked for, or nil if it asked for none.
    /// Instances are cached per name so the per-frame scratch buffers a provider
    /// owns are allocated once. Throws if the shader named a provider that is
    /// not registered.
    public func dataProvider(for shader: LerpShader) throws -> LerpDataProvider? {
        guard let name = shader.dataProviderName else { return nil }
        if let cached = dataProviders[name] { return cached }
        guard let provider = LerpDataProviders.make(named: name, device: device) else {
            try fail(shader, 2, "shader '\(shader.name)' declares `// lerp-data: \(name)` but no such data provider is registered (known: \(LerpDataProviders.registeredNames.joined(separator: ", ")))")
        }
        dataProviders[name] = provider
        return provider
    }

    /// Compiles (or returns a cached) pipeline for a shader. Throws with the
    /// Metal compiler's diagnostics on failure.
    public func pipeline(for shader: LerpShader) throws -> MTLRenderPipelineState {
        let cacheKey = shader.name + "|" + String(shader.source.hashValue)
        if let cached = pipelineCache[cacheKey] { return cached }

        if !shader.parameterErrors.isEmpty {
            try fail(shader, 3, "shader '\(shader.name)' has malformed parameter declarations:\n"
                + shader.parameterErrors.map { "  \($0)" }.joined(separator: "\n")
                + "\n  syntax: // lerp-param: NAME TYPE [MIN MAX] = DEFAULT \"Label\"")
        }

        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        }
        let prelude = LerpPrelude.source(parameters: shader.parameters,
                                         extra: try dataProvider(for: shader)?.metalPrelude ?? "")
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: prelude + shader.source, options: options)
        } catch {
            compileErrors[shader.name] = String(describing: error)
            throw error
        }
        guard let vertexFn = library.makeFunction(name: "lerpVertex"),
              let fragmentFn = library.makeFunction(name: "lerpMain") else {
            try fail(shader, 1, "shader '\(shader.name)' must define `fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]])`")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Lerping/" + shader.name
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        compileErrors[shader.name] = nil
        pipelineCache[cacheKey] = pipeline
        return pipeline
    }
}
