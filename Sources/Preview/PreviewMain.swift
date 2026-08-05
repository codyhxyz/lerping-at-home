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

        if args.contains("--list") {
            guard let renderer = LerpRenderer() else { fail("no Metal device") }
            let library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearch)
            for shader in library.discover() {
                print("\(shader.name)\(shader.isBuiltIn ? "" : "  (custom)")  \(shader.url?.path ?? "")")
            }
            return
        }

        if args.contains("--params") {
            guard let renderer = LerpRenderer() else { fail("no Metal device") }
            let library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearch)
            let only = flagValue(args, "--params").flatMap { $0.hasPrefix("--") ? nil : $0 }
            for shader in library.discover() where only == nil || shader.name == only {
                printParameters(of: shader)
            }
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
            } else if let boolean = ["true": 1.0, "false": 0.0][raw.lowercased()] {
                values.set(param.name, to: boolean)
            } else {
                fail("'\(raw)' is not a number or bool")
            }
        }
        return values
    }

    // MARK: - Snapshot mode

    static func snapshotAll(outDir: String, args: [String], extraSearch: [URL]) {
        guard let renderer = LerpRenderer() else { fail("no Metal device") }
        let library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearch)

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
