import Foundation
import Metal
import QuartzCore
import os

/// One line of a look's `// lerp-caption…:` text.
public struct LerpCaptionLine: Sendable, Equatable {
    public enum Role: Sendable { case title, body, credit }
    public let role: Role
    public let text: String
}

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

    /// The shader in a `.metal` file — its stem is the name — or nil when the
    /// file cannot be read as UTF-8.
    ///
    /// The one place a file becomes a shader. `ShaderLibrary.discover` walks the
    /// search directories with it, and so does `LerpPreview --thumbnails`, which
    /// deliberately reads a `.saver` bundle's *own* `Resources/Shaders` rather
    /// than whatever `discover` would find.
    public init?(contentsOf url: URL, isBuiltIn: Bool) {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(name: url.deletingPathExtension().lastPathComponent,
                  source: source, isBuiltIn: isBuiltIn, url: url)
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

    /// What one of this shader's looks renders with: the declared defaults,
    /// with the entry's preset applied on top when it names one this file still
    /// declares.
    ///
    /// The single answer to that question. It used to be transcribed five
    /// times — the live view, the hover preview, the thumbnail baker and the
    /// wallpaper handoff each spelled out "start from the defaults, then apply
    /// the preset." They did not all spell it the same way: the hover preview
    /// set the preset's values one at a time
    /// without the reset in front of them, which is only equivalent because of
    /// what the line above it happened to have just done. A still and the live
    /// frame it is supposed to continue are the *same* function of the same
    /// look, so there is one function.
    ///
    /// A preset name the file no longer declares yields the defaults. Callers
    /// for whom that is a lie — the shuffle, where a shader's defaults are a
    /// look in their own right and may be one the user switched off — must
    /// resolve the name themselves first; see `LerpMetalView.setEntry`.
    public func parameterValues(for entry: LerpRotationEntry) -> LerpParameterValues {
        var values = defaultParameterValues()
        if let name = entry.preset, let preset = preset(named: name) { values.apply(preset) }
        return values
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
            guard let value = LerpParamParser.directiveBody(raw, "lerp-data:") else { continue }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Text the look sets over itself, one line per directive, in file order:
    ///
    ///     // lerp-caption-title:  Seated Dari (Vairocana)
    ///     // lerp-caption:        Jade, 19th century. China, Qing dynasty
    ///     // lerp-caption-credit: Crow Museum of Asian Arts · superspl.at
    ///
    /// Only splat looks draw it today (`SplatData` renders the lines into a
    /// texture and the look's fragment shader composites it with
    /// `lerpSplatCaption`). Empty for every other shader.
    public var captionLines: [LerpCaptionLine] {
        var lines: [LerpCaptionLine] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            for (directive, role) in [("lerp-caption-title:", LerpCaptionLine.Role.title),
                                      ("lerp-caption-credit:", .credit),
                                      ("lerp-caption:", .body)] {
                if let value = LerpParamParser.directiveBody(raw, directive), !value.isEmpty {
                    lines.append(LerpCaptionLine(role: role, text: value))
                    break
                }
            }
        }
        return lines
    }

    /// How a splat look's camera is set up for its capture — numbers the look
    /// is tuned to, not things to turn while watching it:
    ///
    ///     // lerp-camera: period=120 angle=150 arc=150 distance=4.3 height=2 fov=40
    ///
    /// `SplatData` reads a name here when the look has no `// lerp-param:` of
    /// it. Empty for every other shader.
    public var cameraSettings: [String: Float] {
        var settings: [String: Float] = [:]
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            guard let body = LerpParamParser.directiveBody(raw, "lerp-camera:") else { continue }
            for pair in body.split(whereSeparator: { $0 == " " || $0 == "," }) {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Float(kv[1]) { settings[String(kv[0])] = v }
            }
        }
        return settings
    }

    /// What the shader says it needs beyond a Metal GPU, from optional comments
    /// among its first lines, lower-cased:
    ///
    ///     // lerp-requires: metal4
    ///     // lerp-requires: minecraft
    ///     // lerp-requires: minecraft mobs
    ///     // lerp-requires: minecraft world:mine
    public var requirements: [String] {
        var words: [String] = []
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            guard let value = LerpParamParser.directiveBody(raw, "lerp-requires:") else { continue }
            words += value.lowercased().split { $0 == " " || $0 == "," }.map(String.init)
        }
        return words
    }

    /// Whether the shader draws with Minecraft's textures (`MinecraftAssets.swift`).
    /// A look that draws a baked world (`world:<name>`) draws with them too.
    public var requiresMinecraft: Bool {
        requirements.contains(LerpMinecraft.requirement) || !worldNames.isEmpty
    }

    /// The baked worlds the shader names with `world:<name>`
    /// (`MinecraftWorld.swift`). A look draws at most one; naming two is a
    /// compile error.
    public var worldNames: [String] { LerpMinecraftWorld.worldNames(in: requirements) }

    /// How many float4s of per-frame plan a world look's `lerpPlan` kernel
    /// writes, from a comment among its first lines (`MinecraftWorld.swift`):
    ///
    ///     // lerp-plan: 64
    ///
    /// 0 for every other shader. Malformed or out of range (1...256) is -1,
    /// which the compile refuses.
    public var planSize: Int {
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            guard let value = LerpParamParser.directiveBody(raw, "lerp-plan:") else { continue }
            guard let n = Int(value), (1...LerpMinecraftWorld.maxPlan).contains(n) else { return -1 }
            return n
        }
        return 0
    }

    /// Whether this machine can run the shader.
    ///
    /// `metal4` means macOS 26+ on a GPU in the `.metal4` family — what Metal 4
    /// tensors and shader ML need. `minecraft` means `make minecraft` has
    /// packed the game's textures on this Mac. `ShaderLibrary.discover()`
    /// leaves out a shader that answers false, so where it cannot run it is
    /// simply absent from the rotation, the gallery and the pickers rather
    /// than present as a compile error. A file with no such line, or a
    /// requirement this build does not know, is always supported: an
    /// unrecognised word must not make a custom shader vanish without
    /// explanation.
    public func isSupported(on device: MTLDevice) -> Bool {
        for word in requirements {
            if word == "metal4" {
                guard #available(macOS 26.0, *), device.supportsFamily(.metal4) else { return false }
            }
            if word == LerpMinecraft.requirement, !LerpMinecraft.isInstalled { return false }
            if word == LerpMinecraft.mobsRequirement, !LerpMinecraft.hasMobs { return false }
            if word.hasPrefix(LerpMinecraftWorld.requirementPrefix) {
                guard LerpMinecraft.isInstalled,
                      LerpMinecraftWorld.isBaked(String(word.dropFirst(LerpMinecraftWorld.requirementPrefix.count)))
                else { return false }
            }
        }
        return true
    }
}

/// One stop in the shuffle rotation: a shader, optionally wearing one of its
/// declared `// lerp-preset:` looks.
///
/// A `nil` preset means the shader's *declared defaults*, not “the first
/// preset”. Defaults normally appear as a look in their own right. The one
/// exception is a named preset with the identical packed values: rotation keeps
/// the useful name and drops the indistinguishable “Defaults” tile.
public struct LerpRotationEntry: Hashable, Sendable {
    public let shader: String
    /// Preset name, or nil for the shader's declared defaults.
    public let preset: String?

    public init(shader: String, preset: String? = nil) {
        self.shader = shader
        self.preset = (preset?.isEmpty ?? true) ? nil : preset
    }

    /// Stable string form, for `UserDefaults` and for test hooks.
    ///
    /// Shader names are file stems, so they can never contain `/`; splitting on
    /// the *first* one therefore round-trips even a preset name that has slashes
    /// in it.
    public var key: String { preset.map { "\(shader)/\($0)" } ?? shader }

    public init(key: String) {
        if let slash = key.firstIndex(of: "/") {
            self.init(shader: String(key[key.startIndex..<slash]),
                      preset: String(key[key.index(after: slash)...]))
        } else {
            self.init(shader: key, preset: nil)
        }
    }

    /// What every surface calls a shader's un-preset look, and the one preset
    /// name that cannot be used for anything else.
    ///
    /// Written out five times before this existed: here, in the inspector's
    /// preset popup, in the Options… sheet's, in the playground's status line,
    /// and in `LerpPresetWriter.problem`, which refuses it. That last one is why
    /// the string has to be shared rather than merely consistent — the refusal
    /// and the thing being reserved are the same fact, and a rename that reached
    /// four of the five would quietly allow a preset that draws two identically
    /// captioned tiles and is unselectable in a popup.
    public static let defaultsName = "Defaults"

    /// What the Options list calls this entry underneath its shader heading.
    public var displayName: String { preset ?? Self.defaultsName }

    /// The preset name that stands for *every* look of a shader, including the
    /// ones its author has not written yet: `kleinian/*`.
    ///
    /// It only ever appears in the rotation's off set, where it records that a
    /// shader is switched off as a whole — beside, not instead of, whatever the
    /// user decided about its individual looks. That is what lets a shader go
    /// off and come back with its curation intact, and it is why the switch is
    /// a key in the one set rather than a second set: `verify-rotation.py` and
    /// every reader see one list of opinions. See `LerpRotationSelection`.
    ///
    /// Reserved for the same reason "Defaults" is: `LerpPresetWriter.problem`
    /// refuses it and the parser rejects a hand-written one, so a real preset can
    /// never be mistaken for the whole shader.
    public static let wholeShaderPreset = "*"

    /// `shader/*`: the whole of `shader`, as one key.
    public static func wholeShader(_ shader: String) -> LerpRotationEntry {
        LerpRotationEntry(shader: shader, preset: wholeShaderPreset)
    }

    /// Whether this is a `shader/*` key rather than a look.
    public var isWholeShader: Bool { preset == Self.wholeShaderPreset }
}

/// Filesystem policy shared by the saver's sandbox and the ordinary app hosts.
/// The sandbox home comes first; the passwd home follows when it differs.
public enum LerpFileLocations {
    public static var realHomeDirectory: URL? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home))
    }

    public static func homeDirectories(appending relativePath: String) -> [URL] {
        var directories = [URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(relativePath)]
        if let realHomeDirectory {
            directories.append(realHomeDirectory.appendingPathComponent(relativePath))
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0.path).inserted }
    }

    /// The first candidate that can be created and passes an actual write probe.
    public static func firstWritableDirectory(
        in candidates: [URL], onFailure: ((URL, Error) -> Void)? = nil
    ) -> URL? {
        let manager = FileManager.default
        for directory in candidates {
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let probe = directory.appendingPathComponent(".writable")
                try Data().write(to: probe)
                try? manager.removeItem(at: probe)
                return directory
            } catch {
                onFailure?(directory, error)
            }
        }
        return nil
    }

    public static func writableHomeDirectory(
        appending relativePath: String, onFailure: ((URL, Error) -> Void)? = nil
    ) -> URL? {
        firstWritableDirectory(in: homeDirectories(appending: relativePath), onFailure: onFailure)
    }
}

public enum ShaderLocations {
    /// Directories scanned for user-supplied .metal shader files, in priority order.
    /// `NSHomeDirectory()` resolves to the sandbox container inside legacyScreenSaver
    /// and to the real home directory in the preview app; we also try the real home
    /// explicitly so both hosts can share a folder when the sandbox permits it.
    public static func customShaderDirectories() -> [URL] {
        LerpFileLocations.homeDirectories(
            appending: "Library/Application Support/Lerping/Shaders")
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

    /// The `.metal` files in one directory, in name order — an empty list for a
    /// directory that is not there, which is the normal answer for a search path
    /// the user has never created.
    public static func metalFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "metal" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }
}

public extension Collection where Element == LerpShader {
    /// The shader with this name, if this list has one.
    func named(_ name: String) -> LerpShader? {
        first { $0.name == name }
    }

    /// Every distinct rotation entry these shaders offer, in list order:
    /// defaults first, then declared presets. If a named preset intentionally
    /// reproduces the defaults, its useful name replaces the indistinguishable
    /// “Defaults” tile; a shader with no presets still contributes its defaults.
    func rotationEntries() -> [LerpRotationEntry] {
        flatMap { shader in
            let named = shader.presets.map { LerpRotationEntry(shader: shader.name, preset: $0.name) }
            // Compared as looks, not bytes: a preset that only pins an
            // animated parameter at its default packs the same tail and still
            // draws different frames.
            let defaults = shader.defaultParameterValues()
            let namedDefault = named.contains {
                shader.parameterValues(for: $0).rendersSameLook(as: defaults)
            }
            return (namedDefault ? [] : [LerpRotationEntry(shader: shader.name)]) + named
        }
    }
}

enum LerpBundleResources {
    static func directories(named folder: String) -> [URL] {
        var directories: [URL] = []
        for bundle in [Bundle(for: ShaderLibrary.self), Bundle.main] {
            guard let url = bundle.resourceURL?.appendingPathComponent(folder),
                  FileManager.default.fileExists(atPath: url.path),
                  !directories.contains(url) else { continue }
            directories.append(url)
        }
        return directories
    }
}

/// Discovers shader files and compiles them into render pipelines at runtime.
/// Runtime compilation keeps built-in and custom shaders on one code path and
/// means no Metal toolchain is needed to build or extend the project.
///
/// Thread-safe: `pipeline(for:)` and `dataProvider(for:)` may be called from any
/// queue, e.g. to compile the next look in the background while this one plays.
/// The compile itself runs outside the lock, through the device's shared
/// `LerpPipelineCompiler`, so two different shaders compile in parallel and two
/// requests for the same one (two displays, or a prefetch racing the main
/// thread) compile once.
public final class ShaderLibrary: @unchecked Sendable {
    public let device: MTLDevice
    private let compiler: LerpPipelineCompiler
    private let lock = NSLock()
    private var pipelineCache: [String: MTLRenderPipelineState] = [:]
    private var dataProviders: [String: LerpDataProvider] = [:]
    /// Worlds loaded by a compile, held only until this library's provider for
    /// the look takes them (`LerpWorldProvider`), by name.
    private var worlds: [String: LerpMinecraftWorld.World] = [:]
    /// A world look's `lerpPlan` kernel, by shader name, compiled with its
    /// render pipeline from the same source.
    private var plans: [String: MTLComputePipelineState] = [:]
    private let extraSearchURLs: [URL]

    private var errors: [String: String] = [:]
    public var compileErrors: [String: String] { locked { errors } }

    /// Handed to every data provider this library makes. See `LerpRenderMode`.
    public let mode: LerpRenderMode

    public init(device: MTLDevice, extraSearchURLs: [URL] = [], mode: LerpRenderMode = .live) {
        self.device = device
        self.mode = mode
        self.compiler = LerpPipelineCompiler.shared(for: device)
        self.extraSearchURLs = extraSearchURLs
        LerpSplatAssets.addSourceRoots(extraSearchURLs)
        LerpImageAssets.addSourceRoots(extraSearchURLs)
        CritterAssets.addSourceRoots(extraSearchURLs)
    }

    /// Which compiler new pipelines go through: `mtl4` or `classic`.
    public var compilerBackend: String { compiler.backendName }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Built-in shaders ship as .metal source files in the host bundle's Resources/Shaders.
    /// `Bundle(for:)` is the .saver bundle when this code is linked into it;
    /// `Bundle.main` covers the plain executables, where the two differ.
    private func builtInDirectory() -> URL? {
        LerpBundleResources.directories(named: "Shaders").first
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

    /// All available shaders. Custom shaders with the same file stem override
    /// built-ins. A shader this device cannot run (`// lerp-requires:`) is left
    /// out, judged on whichever file won the shadowing.
    public func discover() -> [LerpShader] {
        var byName: [String: LerpShader] = [:]
        for (dir, isBuiltIn) in searchDirectories() {
            for url in ShaderLocations.metalFiles(in: dir) {
                guard let shader = LerpShader(contentsOf: url, isBuiltIn: isBuiltIn) else { continue }
                byName[shader.name] = shader
            }
        }
        return byName.values.filter { $0.isSupported(on: device) }.sorted { $0.name < $1.name }
    }

    public func shader(named name: String) -> LerpShader? {
        discover().named(name)
    }

    /// The item `offset` places from `current` in `items`, wrapping at both ends;
    /// nil for an empty list. A `current` that is nil, or that the list does not
    /// contain, counts as position 0, so stepping forward from nothing lands on
    /// the first item.
    ///
    /// This is the only place cycling wraps around. The ←/→ keys, the shuffle
    /// rotation and the playground's next/previous all used to spell the same
    /// `(i + d + n) % n` out for themselves. Generic because the shuffle now
    /// steps over `LerpRotationEntry` while the playground still steps over
    /// shader names.
    public static func step<T: Equatable>(in items: [T], after current: T?, offset: Int) -> T? {
        guard !items.isEmpty else { return nil }
        let index = current.flatMap { items.firstIndex(of: $0) } ?? 0
        return items[(((index + offset) % items.count) + items.count) % items.count]
    }

    /// The first item `accept` takes, starting `offset` places from `current`
    /// and then continuing one step at a time in the same direction, wrapping
    /// once through `items`. nil when the list is empty or nothing was accepted.
    ///
    /// Skipping over a candidate that will not load is the whole point, and it
    /// is the same rule in both places it is used: the shuffle stepping past a
    /// shader that will not compile (`LerpMetalView.loadEntry`) and the
    /// playground picking a look to open on (`OpeningShader`). Stopping at the
    /// first failure both shows the wrong thing and sticks there — the next step
    /// would set out from the same place and retry the same broken file.
    ///
    /// `accept` is called at most once per item, in walk order, and is expected
    /// to have the side effect that matters (loading the pipeline); a `true`
    /// answer means the caller is now on that item.
    public static func firstStep<T: Equatable>(in items: [T], after current: T?, offset: Int,
                                               where accept: (T) -> Bool) -> T? {
        guard !items.isEmpty else { return nil }
        let direction = offset < 0 ? -1 : 1
        var anchor = current
        for attempt in 0..<items.count {
            guard let candidate = step(in: items, after: anchor,
                                       offset: attempt == 0 ? offset : direction)
            else { return nil }
            anchor = candidate
            if accept(candidate) { return candidate }
        }
        return nil
    }

    /// Records `message` as this shader's compile error and throws it. Every
    /// refusal in here goes through this, so `compileErrors` cannot disagree
    /// with what the caller was handed.
    private func fail(_ shader: LerpShader, _ code: Int, _ message: String) throws -> Never {
        locked { errors[shader.name] = message }
        throw NSError(domain: "LerpingAtHome", code: code,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Drops every cached pipeline. Hosts that recompile the same shader name
    /// over and over (the playground's hot reload keys the cache on the edited
    /// source, so every keystroke would add an entry) call this to bound memory.
    public func clearPipelineCache() {
        locked { pipelineCache.removeAll() }
    }

    /// The `LerpDataProvider` a shader asked for, or nil if it asked for none.
    /// Instances are cached per name so the per-frame scratch buffers a provider
    /// owns are allocated once. Throws if the shader named a provider that is
    /// not registered.
    public func dataProvider(for shader: LerpShader) throws -> LerpDataProvider? {
        releaseIdleWorlds()
        let inner = try ownDataProvider(for: shader)
        guard let worldName = shader.worldNames.first else { return inner }
        // A world look: its textures and clock, wrapped round the look's own
        // provider. One per library, world and inner provider, like any
        // provider; handed the bake that is on disk now, so a re-bake (which
        // also recompiles the look, see `pipeline`) takes effect.
        let held = locked { worlds[worldName] }
        let world: LerpMinecraftWorld.World
        do {
            if let held, held.stamp == LerpMinecraftWorld.currentStamp(worldName) {
                world = held
            } else {
                world = try LerpMinecraftWorld.load(worldName, device: device)
            }
        } catch {
            try fail(shader, 4, "shader '\(shader.name)': \(error.localizedDescription)")
        }
        return locked { () -> LerpDataProvider in
            // From here the provider holds it; the compile's hold is done.
            worlds[worldName] = nil
            let key = LerpMinecraftWorld.requirementPrefix + worldName + "|" + (shader.dataProviderName ?? "")
            let plan = plans[shader.name].map { (pipeline: $0, size: shader.planSize) }
            if let cached = dataProviders[key + "|" + shader.name] as? LerpWorldProvider {
                cached.world = world
                cached.setPlan(plan, device: device)
                return cached
            }
            let made = LerpWorldProvider(world: world, inner: inner, mode: mode)
            made.setPlan(plan, device: device)
            dataProviders[key + "|" + shader.name] = made
            return made
        }
    }

    /// Lets go of the world textures of every world look that has not drawn
    /// for `LerpWorldProvider.idleRelease` seconds, so a host that rotates
    /// through many looks in one process (the screensaver) holds a world's
    /// ~100 MiB only while a look that draws it is on screen or next. Run on
    /// every look's way in (here), which is the moment another look takes
    /// over; a released world is loaded again, off the render thread, the next
    /// time its look is asked for, as the rotation does before it shows one.
    private func releaseIdleWorlds() {
        let now = CACurrentMediaTime()
        locked {
            for case let provider as LerpWorldProvider in dataProviders.values
                where now - provider.lastBind > LerpWorldProvider.idleRelease {
                provider.world = nil
            }
        }
    }

    /// The `// lerp-data:` provider alone, without a world's wrapper.
    private func ownDataProvider(for shader: LerpShader) throws -> LerpDataProvider? {
        guard let name = shader.dataProviderName else { return nil }
        let provider = locked { () -> LerpDataProvider? in
            if let cached = dataProviders[name] { return cached }
            let made = LerpDataProviders.make(named: name, device: device, mode: mode)
            dataProviders[name] = made
            return made
        }
        // The caption belongs to the shader file, not the capture, so it is
        // handed over every time a look using this provider is installed.
        (provider as? SplatData)?.caption = shader.captionLines
        (provider as? SplatData)?.camera = shader.cameraSettings
        guard let provider else {
            try fail(shader, 2, "shader '\(shader.name)' declares `// lerp-data: \(name)` but no such data provider is registered (known: \(LerpDataProviders.registeredNames.joined(separator: ", ")))")
        }
        return provider
    }

    /// Compiles (or returns a cached) pipeline for a shader, for a `.bgra8Unorm`
    /// target. Throws with the Metal compiler's diagnostics on failure.
    public func pipeline(for shader: LerpShader) throws -> MTLRenderPipelineState {
        try pipeline(for: shader, pixelFormat: .bgra8Unorm)
    }

    /// `pipeline(for:)` for a render target of any pixel format. Each format is
    /// its own pipeline and its own cache entry.
    public func pipeline(for shader: LerpShader, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        // A world look's key carries the bake, so a re-bake recompiles it
        // with the new `world.metal`.
        let worldStamp = shader.worldNames.first.map { "|" + (LerpMinecraftWorld.currentStamp($0) ?? "unbaked") } ?? ""
        let cacheKey = shader.name + "|" + String(shader.source.hashValue) + "|" + String(pixelFormat.rawValue)
            + worldStamp
        if let cached = locked({ pipelineCache[cacheKey] }) { return cached }
        let signpost = LerpSignposts.signposter.beginInterval("compile", "\(shader.name, privacy: .public)")
        defer { LerpSignposts.signposter.endInterval("compile", signpost) }

        if !shader.parameterErrors.isEmpty {
            try fail(shader, 3, "shader '\(shader.name)' has malformed parameter declarations:\n"
                + shader.parameterErrors.map { "  \($0)" }.joined(separator: "\n")
                + "\n  syntax: // lerp-param: NAME TYPE [MIN MAX] = DEFAULT \"Label\""
                + "\n          // lerp-animate: NAME LOW HIGH [period=SECONDS]")
        }

        var extra = try ownDataProvider(for: shader)?.metalPrelude ?? ""
        if shader.requiresMinecraft {
            // Loaded here, on whichever queue is compiling, so the arrays are
            // in place before the look's first frame binds them.
            do {
                extra += try LerpMinecraft.metalPrelude()
                if shader.requirements.contains(LerpMinecraft.mobsRequirement) {
                    extra += try LerpMinecraft.mobsPrelude()
                }
                try LerpMinecraft.load(device: device)
                let names = shader.worldNames
                if names.count > 1 {
                    throw LerpMinecraftWorld.Failure(message: "a look draws one world; this one names \(names.joined(separator: ", "))")
                }
                if let name = names.first {
                    let world = try LerpMinecraftWorld.load(name, device: device)
                    locked { worlds[name] = world }
                    extra += LerpMinecraftWorld.metalPrelude(for: world)
                }
            } catch {
                try fail(shader, 4, "shader '\(shader.name)': \(error.localizedDescription)")
            }
        }
        let prelude = LerpPrelude.source(parameters: shader.parameters, extra: extra)
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try compiler.pipeline(source: prelude + shader.source,
                                             label: "Lerping/" + shader.name,
                                             pixelFormat: pixelFormat)
        } catch is LerpPipelineCompiler.MissingEntryPoint {
            try fail(shader, 1, "shader '\(shader.name)' must define `fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]])`")
        } catch {
            locked { errors[shader.name] = String(describing: error) }
            throw error
        }

        // A world look's per-frame plan kernel, from the very same source.
        if shader.planSize != 0 {
            do {
                guard shader.planSize > 0, !shader.worldNames.isEmpty else {
                    throw LerpMinecraftWorld.Failure(message: "`// lerp-plan: N` takes N in 1...\(LerpMinecraftWorld.maxPlan) and needs a world (`// lerp-requires: minecraft world:NAME`)")
                }
                let library = try device.makeLibrary(source: prelude + shader.source, options: nil)
                guard let function = library.makeFunction(name: "lerpPlan") else {
                    throw LerpMinecraftWorld.Failure(message: "declares `// lerp-plan:` but defines no `kernel void lerpPlan(...)`")
                }
                let plan = try device.makeComputePipelineState(function: function)
                locked { plans[shader.name] = plan }
            } catch {
                try fail(shader, 5, "shader '\(shader.name)': \(error.localizedDescription)")
            }
        }

        locked {
            errors[shader.name] = nil
            pipelineCache[cacheKey] = pipeline
        }
        return pipeline
    }

    /// `pipeline(for:pixelFormat:)` on a background queue, for compiling a look
    /// before it is needed. `completion` runs on `queue`. The result lands in
    /// the same cache a synchronous call fills, so a later `pipeline(for:)`
    /// returns at once, and one that arrives while this compile is still
    /// running waits for it instead of starting a second.
    public func pipeline(for shader: LerpShader,
                         pixelFormat: MTLPixelFormat = .bgra8Unorm,
                         qos: DispatchQoS.QoSClass = .utility,
                         queue: DispatchQueue = .main,
                         completion: @escaping (Result<MTLRenderPipelineState, Error>) -> Void) {
        DispatchQueue.global(qos: qos).async { [self] in
            let result = Result { try pipeline(for: shader, pixelFormat: pixelFormat) }
            queue.async { completion(result) }
        }
    }
}
