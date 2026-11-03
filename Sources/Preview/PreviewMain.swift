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
///       [--hdr [--hdr-format exr|heic|avif|png] [--edr-peak P]]
///                                   extended-range stills through the EDR
///                                   path (default exr, peak 4× SDR white)
///   LerpPreview --thumbnails SAVER  bake the Options… gallery's stills into
///                                   a .saver bundle
///   LerpPreview --bench             per-shader GPU cost table (Markdown)
///       [--size WxH] [--frames N] [--shader NAME] [--looks]
///
/// `--gputrace PATH.gputrace` (or `LERP_GPUTRACE=PATH`) records a Metal
/// capture: of every frame `--snapshot` draws, or of the live window's first
/// `LERP_GPUTRACE_FRAMES` frames (default 3). Open it in Xcode.
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
        GPUTrace.prepare(args)

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

        if args.contains("--physarum-selftest") {
            if let failure = PhysarumData.selfTest() { fail("physarum self-test: \(failure)") }
            print("OK    physarum: warm == cold at t=60 and after scrubbing back; 1, 7, 16 workers agree")
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

        if args.contains("--bench") {
            bench(args: args, extraSearch: extraSearch)
            return
        }

        if let index = args.firstIndex(of: "--snapshot") {
            let outDir = args.count > index + 1 && !args[index + 1].hasPrefix("--")
                ? args[index + 1] : "build/snapshots"
            snapshotAll(outDir: outDir, args: args, extraSearch: extraSearch)
            return
        }

        runApp(extraSearch: extraSearch, args: args)
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

        let (width, height) = size(args, default: (1200, 750))
        let time = Float(flagValue(args, "--time") ?? "3.0") ?? 3.0
        let seed = Float(flagValue(args, "--seed") ?? "0.5") ?? 0.5
        let only = flagValue(args, "--shader")
        // `--hdr` writes extended-range stills through the EDR path instead.
        let hdrPeak: Float? = args.contains("--hdr")
            ? Float(flagValue(args, "--edr-peak") ?? "") ?? LerpEDR.defaultPeak : nil
        let ext = hdrPeak == nil ? "png" : (flagValue(args, "--hdr-format") ?? "exr")

        let outURL = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        var shaders = library.discover()
        if let only { shaders = shaders.filter { $0.name == only } }
        guard !shaders.isEmpty else { fail("no shaders found\(only.map { " named \($0)" } ?? "")") }

        GPUTrace.start(device: renderer.device)
        var failed = false
        for shader in shaders {
            let url = outURL.appendingPathComponent(shader.name + "." + ext)
            let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                            width: width, height: height,
                                            time: time, seed: seed,
                                            params: parameterValues(for: shader, args: args),
                                            hdrPeak: hdrPeak,
                                            to: url)
            if let error = result.error {
                failed = true
                print("FAIL  \(shader.name): \(error)")
            } else {
                let peak = hdrPeak == nil ? "" : String(format: " peak=%.2f", result.peak)
                print(String(format: "OK    %-16s luma=%.3f%@  %@", (shader.name as NSString).utf8String!,
                             result.meanLuminance, peak, url.path))
            }
        }
        GPUTrace.stop()
        exit(failed ? 1 : 0)
    }

    static func size(_ args: [String], default fallback: (Int, Int)) -> (Int, Int) {
        guard let size = flagValue(args, "--size") else { return fallback }
        let parts = size.lowercased().split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return fallback }
        return (width, height)
    }

    // MARK: - GPU cost table

    /// What each look costs the GPU at a given size, offscreen: the number the
    /// screensaver logs once per look switch (`LerpGPUCost`), measured for all
    /// of them at once instead of over a week of real sessions.
    ///
    /// Every frame is its own command buffer through `LerpRenderer.encodePass`,
    /// the path the live view draws with, timed by the GPU's own
    /// `gpuStartTime`/`gpuEndTime`. The clock advances 1/60 s a frame from the
    /// gallery's t=6, so a shader whose cost moves with time is sampled across
    /// two seconds of itself. The first frames are thrown away: they pay for
    /// residency and clock ramp-up, not for the shader.
    static func bench(args: [String], extraSearch: [URL]) {
        let (renderer, library) = makeLibrary(extraSearch)
        let (width, height) = size(args, default: (3840, 2160))
        let frames = max(1, Int(flagValue(args, "--frames") ?? "") ?? 120)
        let warmup = 10
        let only = flagValue(args, "--shader")

        var shaders = library.discover()
        if let only { shaders = shaders.filter { $0.name == only } }
        guard !shaders.isEmpty else { fail("no shaders found\(only.map { " named \($0)" } ?? "")") }
        let looks: [(entry: LerpRotationEntry, shader: LerpShader)] = args.contains("--looks")
            ? RotationThumbnails.jobs(for: shaders).map { ($0.entry, $0.shader) }
            : shaders.map { (LerpRotationEntry(shader: $0.name), $0) }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
            fail("could not allocate a \(width)x\(height) target")
        }

        var rows: [(summary: LerpGPUCost.Summary, compileMs: Double)] = []
        var failed = false
        for look in looks {
            let compileStart = CFAbsoluteTimeGetCurrent()
            let pipeline: MTLRenderPipelineState
            let data: LerpDataProvider?
            do {
                pipeline = try library.pipeline(for: look.shader)
                data = try library.dataProvider(for: look.shader)
            } catch {
                failed = true
                print("FAIL  \(look.shader.name): \(error)")
                continue
            }
            // Zero for every preset after a shader's first look: the pipeline
            // is cached, which is also what the live view gets.
            let compileMs = (CFAbsoluteTimeGetCurrent() - compileStart) * 1000
            let values = look.shader.parameterValues(for: look.entry)
            var buffers: [MTLCommandBuffer] = []
            for frame in 0..<(warmup + frames) {
                let uniforms = LerpUniforms(resolution: SIMD2<Float>(Float(width), Float(height)),
                                            time: 6 + Float(frame) / 60, seed: 0.37)
                guard let buffer = renderer.encodePass(target: target, pipeline: pipeline,
                                                       uniforms: uniforms, params: values, data: data)
                else { fail("could not encode a frame of \(look.entry.key)") }
                buffer.commit()
                buffers.append(buffer)
            }
            buffers.forEach { $0.waitUntilCompleted() }
            // Queued back to back, so they overlap on the GPU; count what each
            // added, exactly as the live meter does (see `LerpGPUCost.busyMs`).
            // The warm-up frames are measured too, only so the first counted
            // frame has a predecessor to be measured against.
            var previousEnd: CFTimeInterval = 0
            let samples = buffers.filter { $0.status == .completed }.map { buffer in
                defer { previousEnd = max(previousEnd, buffer.gpuEndTime) }
                return LerpGPUCost.busyMs(start: buffer.gpuStartTime, end: buffer.gpuEndTime,
                                          previousEnd: previousEnd)
            }.dropFirst(warmup)
            rows.append((LerpGPUCost.summarize(look: look.entry.key, samplesMs: Array(samples),
                                               width: width, height: height, seconds: 0),
                         compileMs))
        }

        let budget = 1000.0 / 60
        print("GPU time per frame at \(width)x\(height), \(frames) frames per look after "
              + "\(warmup) warm-up, \(renderer.device.name). Sorted by p95.\n")
        print("| look | mean ms | p95 ms | max ms | % of 60 fps budget | compile ms |")
        print("|---|---:|---:|---:|---:|---:|")
        for row in rows.sorted(by: { $0.summary.p95Ms > $1.summary.p95Ms }) {
            let s = row.summary
            print(String(format: "| %@ | %.3f | %.3f | %.3f | %.0f%% | %.0f |",
                         s.look, s.meanMs, s.p95Ms, s.maxMs, 100 * s.meanMs / budget, row.compileMs))
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
        // Same `// lerp-requires:` rule as `discover()`: a look this GPU cannot
        // run gets no still here, and is not offered by the gallery either.
        let device = MTLCreateSystemDefaultDevice()
        let shaders = ShaderLocations.metalFiles(in: shaderDir)
            .compactMap { LerpShader(contentsOf: $0, isBuiltIn: true) }
            .filter { shader in device.map { shader.isSupported(on: $0) } ?? true }
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

    static func runApp(extraSearch: [URL], args: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewAppDelegate(extraSearch: extraSearch, args: args)
        app.delegate = delegate
        app.run()
    }
}

final class PreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var metalView: LerpMetalView?
    private var titleTimer: Timer?
    private let extraSearch: [URL]
    private let args: [String]

    init(extraSearch: [URL], args: [String]) {
        self.extraSearch = extraSearch
        self.args = args
    }

    /// Live-window flags, for side-by-side comparisons between two processes:
    ///   --shader NAME     pin a shader (default: first discovered)
    ///   --seed S          fixed u.seed
    ///   --time T          start the shader clock at T
    ///   --epoch E         with --time: clock = T + (now - E), E in Unix
    ///                     seconds, so two windows launched apart stay in sync
    ///   --frame X,Y,W,H   window content rect in screen points
    ///   --label TEXT      prefix for the titlebar
    ///   --edr [--edr-peak P]  EDR output, highlights lifted to at most P×
    ///                     SDR white (default 4; 0 = all the screen offers)
    func applicationDidFinishLaunching(_ notification: Notification) {
        let flag = { PreviewMain.flagValue(self.args, $0) }
        let rect = flag("--frame").map { $0.split(separator: ",").compactMap { Double($0) } }
            .flatMap { $0.count == 4 ? NSRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        guard let view = LerpMetalView(frame: NSRect(origin: .zero, size: rect?.size ?? NSSize(width: 960, height: 600)),
                                      extraSearchURLs: extraSearch) else {
            PreviewMain.fail("no Metal device")
        }
        view.config = LerpMetalView.Config(shaderName: flag("--shader"), framesPerSecond: 60,
                                          renderScale: 1.0, shuffleInterval: .infinity)
        view.onCompileError = { name, error in
            print("compile error in \(name):\n\(error)")
        }
        if args.contains("--edr") {
            view.config.extendedDynamicRange = true
            if let peak = flag("--edr-peak").flatMap(Float.init) { view.config.edrPeak = max(0, peak) }
        }
        if let seed = flag("--seed").flatMap(Float.init) { view.seed = seed }
        let label = flag("--label").map { $0 + " — " } ?? ""

        let window = NSWindow(contentRect: view.frame,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = label + "Lerping@Home Preview"
        window.contentView = view
        if let rect { window.setFrameOrigin(rect.origin) } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        // A comparison window launched from a script should be seen, not stacked
        // behind whatever app has focus — but without taking the keyboard from it.
        if rect != nil { window.orderFrontRegardless() }
        window.isReleasedWhenClosed = false

        self.window = window
        self.metalView = view
        if let name = flag("--shader") {
            guard let shader = view.shaderLibrary.shader(named: name) else { PreviewMain.fail("no shader named \(name)") }
            view.setShader(shader)
        }
        view.start()
        let start = flag("--time").flatMap(Double.init)
        let epoch = flag("--epoch").flatMap(Double.init)
        if let start { view.time = start + (epoch.map { Date().timeIntervalSince1970 - $0 } ?? 0) }
        // Occlusion pauses each window's clock separately, so two synced
        // windows drift apart whenever one is covered. Re-pin to the shared
        // epoch whenever that has happened.
        let resync = { [weak view] in
            guard let view, let start, let epoch, view.isRunning else { return }
            let due = start + Date().timeIntervalSince1970 - epoch
            if abs(view.time - due) > 0.05 { view.time = due }
        }
        if GPUTrace.start(device: view.shaderLibrary.device) {
            let frames = Double(ProcessInfo.processInfo.environment["LERP_GPUTRACE_FRAMES"] ?? "") ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, frames) / 60) { GPUTrace.stop() }
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }

        titleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let view = self.metalView else { return }
            resync()
            let range = view.isEDRActive
                ? String(format: "EDR %.1fx of %.1fx", view.edrHeadroomInUse,
                         LerpEDR.potentialHeadroom(of: self.window?.screen))
                : view.config.extendedDynamicRange
                    ? "SDR, EDR held back: \(LerpEDR.blocker(on: self.window?.screen) ?? "pending")"
                    : "SDR"
            self.window?.title = label + "\(view.currentShaderName) · \(range) (\(view.statusText))"
        }
        titleTimer?.tolerance = 0.5

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

/// `MTLCaptureManager` to a `.gputrace` file, without Xcode attached.
///
/// Outside Xcode, Metal offers the `.gpuTraceDocument` destination only to a
/// process that had `MTL_CAPTURE_ENABLED=1` in its environment when Metal
/// loaded, so `prepare` sets it before anything has asked for a device. The
/// capture is scoped to the device, which takes in every queue on it — the live
/// view's renderer is private to the view and does not need to be reachable.
enum GPUTrace {
    private static var path: String?
    private static var capturing = false

    static func prepare(_ args: [String]) {
        path = PreviewMain.flagValue(args, "--gputrace")
            ?? ProcessInfo.processInfo.environment["LERP_GPUTRACE"].flatMap { $0.isEmpty ? nil : $0 }
        if path != nil { setenv("MTL_CAPTURE_ENABLED", "1", 1) }
    }

    @discardableResult
    static func start(device: MTLDevice) -> Bool {
        guard let path, !capturing else { return false }
        let manager = MTLCaptureManager.shared()
        guard manager.supportsDestination(.gpuTraceDocument) else {
            PreviewMain.fail("this process cannot write .gputrace files (MTL_CAPTURE_ENABLED was not honoured)")
        }
        let url = URL(fileURLWithPath: path)
        // The capture will not overwrite, and a stale trace is worse than none.
        try? FileManager.default.removeItem(at: url)
        let descriptor = MTLCaptureDescriptor()
        descriptor.captureObject = device
        descriptor.destination = .gpuTraceDocument
        descriptor.outputURL = url
        do {
            try manager.startCapture(with: descriptor)
        } catch {
            PreviewMain.fail("could not start GPU capture: \(error)")
        }
        capturing = true
        return true
    }

    static func stop() {
        guard capturing else { return }
        MTLCaptureManager.shared().stopCapture()
        capturing = false
        FileHandle.standardError.write(("GPU trace written to \(path ?? "")\n").data(using: .utf8)!)
    }
}
