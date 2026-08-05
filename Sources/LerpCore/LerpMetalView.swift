import AppKit
import Metal
import QuartzCore

/// CAMetalLayer-backed view that renders one Lerping@Home shader with strict power
/// discipline: capped frame rate, full pause when the window is occluded,
/// optional reduced internal resolution, and a frozen clock while paused.
public final class LerpMetalView: NSView {

    public struct Config {
        /// Shader name to render, or nil for shuffle mode.
        public var shaderName: String?
        /// Names eligible for shuffle. See `Config.rotation(of:from:)` for what
        /// nil, empty and stale sets all mean.
        public var enabledShaderNames: Set<String>?
        public var framesPerSecond: Int
        /// 1.0 = native. 0.5 renders quarter the pixels and upscales — usually
        /// indistinguishable for noise-type shaders, ~4x cheaper.
        public var renderScale: Double
        public var shuffleInterval: TimeInterval
        /// Stop rendering after this many seconds and hold the last frame
        /// (GPU drops to zero). 0 = never. Resets each start().
        public var freezeAfter: TimeInterval

        public init(shaderName: String? = nil,
                    framesPerSecond: Int = 30,
                    renderScale: Double = 1.0,
                    shuffleInterval: TimeInterval = 300,
                    freezeAfter: TimeInterval = 0) {
            self.shaderName = shaderName
            self.framesPerSecond = framesPerSecond
            self.renderScale = renderScale
            self.shuffleInterval = shuffleInterval
            self.freezeAfter = freezeAfter
        }

        /// Which of `available` a set of enabled names actually selects.
        ///
        /// The one statement of the policy: nil, empty, and entirely-stale sets
        /// all mean *every* shader. An empty rotation is a black screensaver,
        /// and no setting should be able to produce one — the saver's Options
        /// sheet says so out loud, and this is what makes that true.
        public static func rotation(of enabled: Set<String>?, from available: [String]) -> [String] {
            let picked = available.filter { enabled?.contains($0) ?? true }
            return picked.isEmpty ? available : picked
        }
    }

    public var config = Config() {
        didSet {
            applyFrameRate()
            updateDrawableSize()
        }
    }

    public private(set) var currentShaderName: String = ""
    public var onCompileError: ((String, String) -> Void)?

    private let renderer: LerpRenderer
    private let library: ShaderLibrary
    private var pipeline: MTLRenderPipelineState?
    private var dataProvider: LerpDataProvider?
    /// Values for the current shader's `// lerp-param:` declarations. Reset to
    /// the shader's declared defaults on every `setShader`, so with no host UI
    /// driving it every shader renders exactly at its defaults.
    public private(set) var parameterValues: LerpParameterValues?
    private var displayLink: CADisplayLink?
    private var shuffleOrder: [String] = []
    private var lastShuffleSwitch: CFTimeInterval = 0

    /// Per-launch random seed handed to shaders as `u.seed`. Settable so a host
    /// (the playground) can re-roll it; the screensaver never touches it.
    public var seed = Float.random(in: 0..<1)
    private var elapsed: CFTimeInterval = 0
    private var resumeStamp: CFTimeInterval = 0
    private var running = false
    private var frozen = false
    private var freezeBaseline: CFTimeInterval = 0

    // Rough FPS estimate for the preview app's titlebar.
    public private(set) var measuredFPS: Double = 0
    private var frameCount = 0
    private var fpsWindowStart: CFTimeInterval = 0

    /// True between `start()` and `stop()`. Hosts with a pause button read this
    /// instead of keeping their own flag beside it, which is how the two drift.
    public var isRunning: Bool { running }

    /// The frame-rate readout a host puts in its titlebar or status bar.
    public var statusText: String {
        running ? String(format: "%.0f fps", measuredFPS) : "paused"
    }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init?(frame: NSRect, extraSearchURLs: [URL] = []) {
        guard let renderer = LerpRenderer() else { return nil }
        self.renderer = renderer
        self.library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearchURLs)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(powerStateChanged),
                                               name: .NSProcessInfoPowerStateDidChange,
                                               object: nil)
    }

    required init?(coder: NSCoder) { nil }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    public var shaderLibrary: ShaderLibrary { library }

    /// The shader clock in seconds (`u.time`). Assigning scrubs the animation;
    /// the clock continues from the new value. Combine with `renderOnce()` to
    /// scrub while paused.
    public var time: CFTimeInterval {
        get { running ? elapsed + (CACurrentMediaTime() - resumeStamp) : elapsed }
        set {
            elapsed = newValue
            resumeStamp = CACurrentMediaTime()
            freezeBaseline = newValue
        }
    }

    /// Draws exactly one frame right now, even when stopped/paused. Used by the
    /// playground so a scrub or a recompile is visible without resuming.
    public func renderOnce() {
        drawFrame(at: time)
    }

    // MARK: - Lifecycle

    /// Banks the time run since the clock last resumed, so `time` stops
    /// advancing. Paired with `resumeClock()`; between them the shader clock
    /// holds still, which is what makes a pause invisible in the animation.
    private func pauseClock() {
        elapsed += CACurrentMediaTime() - resumeStamp
    }

    private func resumeClock() {
        resumeStamp = CACurrentMediaTime()
    }

    public func start() {
        guard !running else { return }
        running = true
        frozen = false
        freezeBaseline = elapsed
        resumeClock()
        fpsWindowStart = resumeStamp

        if pipeline == nil {
            selectInitialShader()
        }
        guard window != nil else { return }
        installDisplayLink()
    }

    public func stop() {
        guard running else { return }
        running = false
        pauseClock()
        tearDownDisplayLink()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else {
            tearDownDisplayLink()
            return
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: window)
        updateDrawableSize()
        if running { installDisplayLink() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        displayLink?.invalidate()
    }

    // MARK: - Shader selection

    private func selectInitialShader() {
        let available = library.discover()
        guard !available.isEmpty else { return }
        if let name = config.shaderName, let shader = available.named(name) {
            setShader(shader)
        } else {
            let names = available.map(\.name)
            shuffleOrder = Config.rotation(of: config.enabledShaderNames, from: names).shuffled()
            lastShuffleSwitch = CACurrentMediaTime()
            advanceShuffle(by: 0)
            if pipeline == nil, shuffleOrder.count < available.count {
                // Every enabled shader failed to compile: widen to all of them
                // rather than presenting nothing.
                shuffleOrder = names.shuffled()
                advanceShuffle(by: 0)
            }
        }
    }

    /// Steps the shuffle rotation. `by: 0` loads the rotation's first entry.
    private func advanceShuffle(by offset: Int) {
        loadShader(after: currentShaderName, offset: offset, in: shuffleOrder)
    }

    /// Loads the first shader that compiles, starting `offset` places from
    /// `current` and then continuing in the same direction, wrapping once
    /// through `order` (the discovery order when nil). Returns false only when
    /// nothing at all could be loaded.
    ///
    /// Skipping over a shader that will not compile is the whole point: a failed
    /// `setShader` leaves the previous pipeline bound and `currentShaderName`
    /// unchanged, so stopping at the first failure both shows the wrong shader
    /// and sticks there — the next step would set out from the same place and
    /// retry the same broken file.
    @discardableResult
    private func loadShader(after current: String, offset: Int, in order: [String]? = nil) -> Bool {
        let available = library.discover()
        let names = order ?? available.map(\.name)
        guard !names.isEmpty else { return false }
        let step = offset < 0 ? -1 : 1
        var anchor = current
        for attempt in 0..<names.count {
            guard let candidate = ShaderLibrary.name(in: names, after: anchor,
                                                     offset: attempt == 0 ? offset : step)
            else { return false }
            anchor = candidate
            if let shader = available.named(candidate), setShader(shader) { return true }
        }
        return false
    }

    @discardableResult
    public func setShader(_ shader: LerpShader) -> Bool {
        do {
            pipeline = try library.pipeline(for: shader)
            dataProvider = try library.dataProvider(for: shader)
            parameterValues = shader.defaultParameterValues()
            currentShaderName = shader.name
            return true
        } catch {
            onCompileError?(shader.name, String(describing: error))
            return false
        }
    }

    /// Overrides one declared parameter of the current shader. No-op if the
    /// shader does not declare it. Rendering picks the new value up on the next
    /// frame; call `renderOnce()` to see it while paused.
    @discardableResult
    public func setParameter(_ name: String, _ value: LerpParamValue) -> Bool {
        parameterValues?.set(name, value) ?? false
    }

    /// Switches the current shader to one of its declared `// lerp-preset:`
    /// blocks. Parameters the preset does not mention return to their defaults.
    @discardableResult
    public func applyPreset(named name: String) -> Bool {
        guard let shader = library.shader(named: currentShaderName),
              let preset = shader.preset(named: name) else { return false }
        parameterValues?.apply(preset)
        return true
    }

    /// Steps to the next (or, for a negative `direction`, previous) discovered
    /// shader, skipping any that fail to compile.
    public func showNextShader(_ direction: Int = 1) {
        loadShader(after: currentShaderName, offset: direction)
    }

    // MARK: - Display link

    private func installDisplayLink() {
        guard displayLink == nil, window != nil, !frozen else { return }
        let link = self.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        applyFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func applyFrameRate() {
        var fps = Float(max(1, min(config.framesPerSecond, 120)))
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            fps = min(fps, 20)
        }
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(max(10, fps - 6), fps),
                                                                maximum: fps,
                                                                preferred: fps)
    }

    @objc private func powerStateChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.applyFrameRate()
        }
    }

    /// Occlusion pauses the clock and the display link but deliberately leaves
    /// `running` set: the view is still animating as far as its host is
    /// concerned, it just has nothing to draw to.
    @objc private func occlusionChanged(_ note: Notification) {
        guard running else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        if visible {
            resumeClock()
            installDisplayLink()
        } else {
            pauseClock()
            tearDownDisplayLink()   // hard 0 fps while covered
        }
    }

    private func updateDrawableSize() {
        guard window != nil else { return }
        let scale = (window?.backingScaleFactor ?? 2.0) * config.renderScale
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
            metalLayer.drawableSize = size
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard running, pipeline != nil else { return }
        let now = CACurrentMediaTime()
        let time = elapsed + (now - resumeStamp)

        if config.freezeAfter > 0, time - freezeBaseline > config.freezeAfter {
            frozen = true
            tearDownDisplayLink()   // hold the last presented frame, GPU idle
            return
        }

        // Shuffle rotation.
        if config.shaderName == nil, shuffleOrder.count > 1,
           now - lastShuffleSwitch > config.shuffleInterval {
            lastShuffleSwitch = now
            advanceShuffle(by: 1)
        }

        frameCount += 1
        if now - fpsWindowStart >= 1.0 {
            measuredFPS = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }

        drawFrame(at: time)
    }

    private func drawFrame(at time: CFTimeInterval) {
        guard let pipeline else { return }
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable() else { return }
            let uniforms = LerpUniforms(
                resolution: SIMD2<Float>(Float(metalLayer.drawableSize.width),
                                         Float(metalLayer.drawableSize.height)),
                time: Float(time),
                seed: seed)
            renderer.draw(drawable: drawable, pipeline: pipeline, uniforms: uniforms,
                          params: parameterValues, data: dataProvider)
        }
    }
}
