import Foundation
import Metal

public struct LerpShader: Sendable {
    public let name: String        // file stem, e.g. "neuro-noise"
    public let source: String
    public let isBuiltIn: Bool
    public let url: URL?

    public var displayName: String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
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
    private func builtInDirectory() -> URL? {
        let bundle = Bundle(for: ShaderLibrary.self)
        if let url = bundle.resourceURL?.appendingPathComponent("Shaders"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Shaders"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private func metalFiles(in dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    /// All available shaders. Custom shaders with the same file stem override built-ins.
    public func discover() -> [LerpShader] {
        var byName: [String: LerpShader] = [:]

        var builtInDirs = extraSearchURLs
        if let builtIn = builtInDirectory() { builtInDirs.append(builtIn) }
        for dir in builtInDirs {
            for url in metalFiles(in: dir) {
                let name = url.deletingPathExtension().lastPathComponent
                guard byName[name] == nil,
                      let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                byName[name] = LerpShader(name: name, source: source, isBuiltIn: true, url: url)
            }
        }
        for dir in ShaderLocations.customShaderDirectories() {
            for url in metalFiles(in: dir) {
                let name = url.deletingPathExtension().lastPathComponent
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                byName[name] = LerpShader(name: name, source: source, isBuiltIn: false, url: url)
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    public func shader(named name: String) -> LerpShader? {
        discover().first { $0.name == name }
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
            let message = "shader '\(shader.name)' declares `// lerp-data: \(name)` but no such data provider is registered (known: \(LerpDataProviders.registeredNames.joined(separator: ", ")))"
            compileErrors[shader.name] = message
            throw NSError(domain: "LerpingAtHome", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        dataProviders[name] = provider
        return provider
    }

    /// Compiles (or returns a cached) pipeline for a shader. Throws with the
    /// Metal compiler's diagnostics on failure.
    public func pipeline(for shader: LerpShader) throws -> MTLRenderPipelineState {
        let cacheKey = shader.name + "|" + String(shader.source.hashValue)
        if let cached = pipelineCache[cacheKey] { return cached }

        let options = MTLCompileOptions()
        if #available(macOS 15.0, *) {
            options.mathMode = .fast
        }
        let prelude = LerpPrelude.source(extra: try dataProvider(for: shader)?.metalPrelude ?? "")
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: prelude + shader.source, options: options)
        } catch {
            compileErrors[shader.name] = String(describing: error)
            throw error
        }
        guard let vertexFn = library.makeFunction(name: "lerpVertex"),
              let fragmentFn = library.makeFunction(name: "lerpMain") else {
            let message = "shader '\(shader.name)' must define `fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]])`"
            compileErrors[shader.name] = message
            throw NSError(domain: "LerpingAtHome", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
