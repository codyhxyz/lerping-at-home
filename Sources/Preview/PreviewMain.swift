import AppKit
import Metal

/// LerpPreview — development host for Lerping@Home shaders.
///
///   LerpPreview                     open a live preview window
///   LerpPreview --list              list discovered shaders
///   LerpPreview --params [NAME]     print declared parameters and presets
///   LerpPreview --snapshot DIR      render every shader to PNG in DIR
///       [--size WxH] [--time T] [--seed S] [--shader NAME]
///       [--preset NAME] [--param name=value ...]
///   LerpPreview --thumbnails SAVER  bake the Options… gallery's stills into
///                                   a .saver bundle
///
/// Live window keys: ←/→ switch shader, space pause/resume, r reload
/// (recompiles, picks up custom-shader edits), q quit.
@main
enum PreviewMain {
    static func main() {
        let args = CommandLine.arguments
        // Search the repo's shader folder when running from a build tree, so
        // the preview works without installing anything.
        let extraSearch = ShaderLocations.repoSearchURLs()

        if args.contains("--life-selftest") {
            guard LifeData.selfTest() else { fail("Game of Life rule self-test failed") }
            let library = makeLibrary(extraSearch).library
            guard let shader = library.shader(named: "game-of-life"),
                  [shader].rotationEntries().count == 10,
                  (try? library.pipeline(for: shader)) != nil
            else { fail("Game of Life must compile and expose exactly ten distinct stories") }
            print("OK    Game of Life rules, canonical patterns, and 10-story rotation")
            return
        }

        if args.contains("--list") {
            for shader in makeLibrary(extraSearch).library.discover() {
                print("\(shader.name)\(shader.isBuiltIn ? "" : "  (custom)")  \(shader.url?.path ?? "")")
            }
            return
        }

        if args.contains("--params") {
            let library = makeLibrary(extraSearch).library
            let only = flagValue(args, "--params").flatMap { $0.hasPrefix("--") ? nil : $0 }
            for shader in library.discover() where only == nil || shader.name == only {
                printParameters(of: shader)
            }
            return
        }

        if let index = args.firstIndex(of: "--thumbnails") {
            guard args.count > index + 1, !args[index + 1].hasPrefix("--") else {
                fail("--thumbnails needs the path to a .saver bundle")
            }
            bakeThumbnails(into: URL(fileURLWithPath: args[index + 1]))
            return
        }

        if let index = args.firstIndex(of: "--snapshot") {
            let outDir = args.count > index + 1 && !args[index + 1].hasPrefix("--")
                ? args[index + 1] : "build/snapshots"
            snapshotAll(outDir: outDir, args: args, extraSearch: extraSearch)
            return
        }

        runApp(extraSearch: extraSearch)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }

    /// A renderer and a library over it, or the one error every mode reports the
    /// same way. Four subcommands opened these two lines; a machine with no GPU
    /// should not be told four different things about it.
    static func makeLibrary(_ extraSearch: [URL]) -> (renderer: LerpRenderer, library: ShaderLibrary) {
        guard let renderer = LerpRenderer() else { fail("no Metal device") }
        return (renderer, ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearch))
    }

    static func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    /// Every value of a repeatable flag, e.g. `--param a=1 --param b=2`.
    static func flagValues(_ args: [String], _ flag: String) -> [String] {
        var out: [String] = []
        for (index, arg) in args.enumerated() where arg == flag && args.count > index + 1 {
            out.append(args[index + 1])
        }
        return out
    }

    // MARK: - Parameter listing

    static func printParameters(of shader: LerpShader) {
        guard !shader.parameters.isEmpty || !shader.presets.isEmpty || !shader.parameterErrors.isEmpty else { return }
        print(shader.name)
        for error in shader.parameterErrors {
            print("  ERROR \(error)")
        }
        for param in shader.parameters {
            let range = param.type == .float || param.type == .int
                ? String(format: "  [%g … %g]", param.min, param.max) : ""
            print("  \(param.name)  \(param.type.rawValue) = \(param.defaultValue.literal)\(range)  \"\(param.label)\"")
        }
        for preset in shader.presets {
            let body = preset.values.keys.sorted()
                .map { "\($0)=\(preset.values[$0]!.literal)" }.joined(separator: ", ")
            print("  preset \(preset.name): \(body)")
        }
        print("")
    }

    /// Builds the values for a snapshot: declared defaults, then `--preset`,
    /// then any `--param name=value` on top.
    static func parameterValues(for shader: LerpShader, args: [String]) -> LerpParameterValues {
        var values = shader.defaultParameterValues()
        if let presetName = flagValue(args, "--preset") {
            guard let preset = shader.preset(named: presetName) else {
                fail("shader '\(shader.name)' has no preset named '\(presetName)'"
                     + (shader.presets.isEmpty ? "" : " (has: \(shader.presets.map(\.name).joined(separator: ", ")))"))
            }
            values.apply(preset)
        }
        for override in flagValues(args, "--param") {
            let parts = override.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("--param expects name=value, got '\(override)'") }
            guard let param = shader.parameters.first(where: { $0.name == parts[0] }) else {
                fail("shader '\(shader.name)' has no parameter '\(parts[0])'"
                     + (shader.parameters.isEmpty ? "" : " (has: \(shader.parameters.map(\.name).joined(separator: ", ")))"))
            }
            let raw = parts[1]
            if param.type == .color {
                guard case .color(let color)? = try? LerpParamParser.parseColor(raw, line: 0, text: override) else {
                    fail("'\(raw)' is not a colour (use #RRGGBB, #RRGGBBAA or (r,g,b[,a]))")
                }
                values.set(param.name, .color(color))
            } else if let number = Double(raw) {
                values.set(param.name, to: number)
            } else if let flag = LerpParamParser.boolean(raw) {
                values.set(param.name, to: flag)
            } else {
                fail("'\(raw)' is not a number or bool")
            }
        }
        return values
    }

    // MARK: - Snapshot mode

    static func snapshotAll(outDir: String, args: [String], extraSearch: [URL]) {
        let (renderer, library) = makeLibrary(extraSearch)

        var width = 1200, height = 750
        if let size = flagValue(args, "--size") {
            let parts = size.lowercased().split(separator: "x")
            if parts.count == 2, let parsedW = Int(parts[0]), let parsedH = Int(parts[1]) {
                width = parsedW; height = parsedH
            }
        }
        let time = Float(flagValue(args, "--time") ?? "3.0") ?? 3.0
        let seed = Float(flagValue(args, "--seed") ?? "0.5") ?? 0.5
        let only = flagValue(args, "--shader")

        let outURL = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        var shaders = library.discover()
        if let only { shaders = shaders.filter { $0.name == only } }
        guard !shaders.isEmpty else { fail("no shaders found\(only.map { " named \($0)" } ?? "")") }

        var failed = false
        for shader in shaders {
            let url = outURL.appendingPathComponent(shader.name + ".png")
            let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                            width: width, height: height,
                                            time: time, seed: seed,
                                            params: parameterValues(for: shader, args: args),
                                            to: url)
            if let error = result.error {
                failed = true
                print("FAIL  \(shader.name): \(error)")
            } else {
                print(String(format: "OK    %-16s luma=%.3f  %@", (shader.name as NSString).utf8String!, result.meanLuminance, url.path))
            }
        }
        exit(failed ? 1 : 0)
    }

    // MARK: - Baking the Options… gallery into a .saver bundle

    /// Renders one still per (shader, preset) into `<bundle>/Contents/Resources/
    /// Thumbnails`, using the exact cache the screensaver's Options… sheet reads
    /// at runtime — same recipe, same content-addressed filenames.
    ///
    /// The shader list comes from the bundle's *own* `Resources/Shaders`, not
    /// from `ShaderLibrary.discover()`. That is the point: the stills baked into
    /// a bundle have to be the stills for the shaders in that bundle, whatever
    /// happens to be in the repo or in the user's drop folder at the time. It is
    /// also what makes `make install` correct — it bakes custom shaders into the
    /// installed copy first, then runs this over the result, so a custom shader
    /// gets a tile like every other look.
    ///
    /// Incremental for free: a still whose file is already there is a hit, so a
    /// rebuild that changed one `.metal` redraws one shader's looks and nothing
    /// else, and a rebuild that changed none redraws nothing.
    static func bakeThumbnails(into bundle: URL) {
        let resources = bundle.appendingPathComponent("Contents/Resources")
        let shaderDir = resources.appendingPathComponent("Shaders")
        let shaders = ShaderLocations.metalFiles(in: shaderDir)
            .compactMap { LerpShader(contentsOf: $0, isBuiltIn: true) }
        guard !shaders.isEmpty else {
            fail("no .metal files in \(shaderDir.path) — is that a Lerping@Home.saver bundle?")
        }
        let cache = RotationThumbnails(
            searchURLs: [shaderDir],
            directory: resources.appendingPathComponent(RotationThumbnails.bundledFolder))
        let jobs = RotationThumbnails.jobs(for: shaders)
        let started = CFAbsoluteTimeGetCurrent()
        let result = cache.renderMissing(jobs)
        let seconds = CFAbsoluteTimeGetCurrent() - started
        for failure in result.failed { print("FAIL  \(failure)") }
        print(String(format: "OK    %d gallery stills for %d shaders in %.2f s "
                     + "(%d rendered, %d already there) -> %@",
                     jobs.count, shaders.count, seconds, result.rendered, result.cached,
                     cache.cacheDirectory.path))
        exit(result.failed.isEmpty ? 0 : 1)
    }

    // MARK: - Live preview app

    static func runApp(extraSearch: [URL]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewAppDelegate(extraSearch: extraSearch)
        app.delegate = delegate
        app.run()
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var metalView: LerpMetalView?
    private var titleTimer: Timer?
    private let extraSearch: [URL]

    init(extraSearch: [URL]) {
        self.extraSearch = extraSearch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 960, height: 600),
                                      extraSearchURLs: extraSearch) else {
            PreviewMain.fail("no Metal device")
        }
        view.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: 60,
                                          renderScale: 1.0, shuffleInterval: .infinity)
        view.onCompileError = { name, error in
            print("compile error in \(name):\n\(error)")
        }

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Lerping@Home Preview"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false

        self.window = window
        self.metalView = view
        view.start()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.metalView else { return }
            self.window?.title = "Lerping@Home Preview — \(view.currentShaderName) (\(view.statusText))"
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let view = metalView else { return false }
        switch event.keyCode {
        case 123: view.showNextShader(-1); return true // left arrow
        case 124: view.showNextShader(1); return true  // right arrow
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case " ":
            view.isRunning ? view.stop() : view.start()
            return true
        case "r":
            // Rediscover + recompile current shader (picks up file edits).
            let name = view.currentShaderName
            if let shader = view.shaderLibrary.shader(named: name) {
                view.setShader(shader)
            }
            return true
        case "q":
            NSApp.terminate(nil)
            return true
        default:
            return false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
