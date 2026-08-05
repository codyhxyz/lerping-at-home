import AppKit
import Metal

/// LerpPreview — development host for Lerping@Home shaders.
///
///   LerpPreview                     open a live preview window
///   LerpPreview --list              list discovered shaders
///   LerpPreview --snapshot DIR      render every shader to PNG in DIR
///       [--size WxH] [--time T] [--seed S] [--shader NAME]
///
/// Live window keys: ←/→ switch shader, space pause/resume, r reload
/// (recompiles, picks up custom-shader edits), q quit.
@main
enum PreviewMain {
    static func main() {
        let args = CommandLine.arguments
        // Search the repo's shader folder when running from a build tree, so
        // the preview works without installing anything.
        let repoShaders = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Shaders")
        let extraSearch = FileManager.default.fileExists(atPath: repoShaders.path) ? [repoShaders] : []

        if args.contains("--list") {
            guard let renderer = LerpRenderer() else { fail("no Metal device") }
            let library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearch)
            for shader in library.discover() {
                print("\(shader.name)\(shader.isBuiltIn ? "" : "  (custom)")  \(shader.url?.path ?? "")")
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
                                            time: time, seed: seed, to: url)
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
    private var paused = false
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
            let state = self.paused ? "paused" : String(format: "%.0f fps", view.measuredFPS)
            self.window?.title = "Lerping@Home Preview — \(view.currentShaderName) (\(state))"
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
            paused ? view.start() : view.stop()
            paused.toggle()
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
