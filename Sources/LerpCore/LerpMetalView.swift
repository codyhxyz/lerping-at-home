import AppKit
import Metal
import os
import QuartzCore

/// CAMetalLayer-backed view that renders one Lerping@Home shader with strict power
/// discipline: capped frame rate, full pause when the window is occluded,
/// optional reduced internal resolution, and a frozen clock while paused.
public final class LerpMetalView: NSView {

    /// Same subsystem the saver logs under, so one `log show` predicate covers
    /// the whole story of a session. Used only where a silent answer would be
    /// indistinguishable from a broken one.
    static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "rotation")

    public struct Config {
        /// Shader name to render, or nil for shuffle mode.
        public var shaderName: String?
        /// Preset to put the pinned shader in, or nil for its declared defaults.
        /// Ignored in shuffle mode, where every rotation entry carries its own.
        public var presetName: String?
        /// Rotation entries — (shader, preset) pairs — eligible for shuffle. See
        /// `Config.rotation(of:from:)` for what nil, empty and stale sets mean.
        public var enabledEntries: Set<LerpRotationEntry>?
        public var framesPerSecond: Int
        /// 1.0 = native. 0.5 renders quarter the pixels and upscales — usually
        /// indistinguishable for noise-type shaders, ~4x cheaper.
        public var renderScale: Double
        public var shuffleInterval: TimeInterval
        /// Stop rendering after this many seconds and hold the last frame
        /// (GPU drops to zero). 0 = never. Resets each start().
        public var freezeAfter: TimeInterval

        public init(shaderName: String? = nil,
                    presetName: String? = nil,
                    framesPerSecond: Int = 30,
                    renderScale: Double = 1.0,
                    shuffleInterval: TimeInterval = 300,
                    freezeAfter: TimeInterval = 0) {
            self.shaderName = shaderName
            self.presetName = presetName
            self.framesPerSecond = framesPerSecond
            self.renderScale = renderScale
            self.shuffleInterval = shuffleInterval
            self.freezeAfter = freezeAfter
        }

        /// Which of `available` a set of enabled entries actually selects.
        ///
        /// The one statement of the policy, and it is now a short one: a `nil`
        /// set means nobody has ever chosen, so every look is in. Anything else
        /// is taken **literally**.
        ///
        /// It used to say more. An empty set, and a set whose every entry had
        /// gone stale, both widened to the full library — as did a rotation
        /// that resolved but would not compile, and a `knownEntries` roster
        /// that had fallen behind. Each of those was defending something real
        /// (an empty rotation is a black screensaver, which has shipped twice)
        /// and each defended it by doing the opposite of what the user asked:
        /// the one action that reliably brought a deselected look back was
        /// deselecting enough of them.
        ///
        /// So the invariant moved to where it can be kept honestly — the
        /// gallery will not let you turn off the last look — and every widening
        /// downstream of it is gone. What this returns is what plays.
        public static func rotation(of enabled: Set<LerpRotationEntry>?,
                                    from available: [LerpRotationEntry]) -> [LerpRotationEntry] {
            guard let enabled else { return available }
            return available.filter(enabled.contains)
        }
    }

    /// Each field is re-applied only when it actually moved. The drawable is the
    /// expensive one: a host that reassigns the whole struct to change the frame
    /// rate must not make the layer throw its textures away and build new ones.
    /// (`updateDrawableSize` also no-ops on an unchanged size, but this keeps the
    /// work off the assignment path entirely.)
    public var config = Config() {
        didSet {
            if config.framesPerSecond != oldValue.framesPerSecond { applyFrameRate() }
            if config.renderScale != oldValue.renderScale { updateDrawableSize() }
            if config.enabledEntries != oldValue.enabledEntries
                || config.shaderName != oldValue.shaderName
                || config.presetName != oldValue.presetName {
                rotationChanged()
            }
        }
    }

    public private(set) var currentShaderName: String = ""
    /// The rotation entry on screen: the shader plus the preset it is wearing,
    /// or nil before anything has been loaded. Written only by `show`, beside
    /// the parameters that make it true, so it cannot name a look the view is
    /// not rendering.
    public private(set) var currentEntry: LerpRotationEntry?
    public var onCompileError: ((String, String) -> Void)?

    private let renderer: LerpRenderer
    private let library: ShaderLibrary
    private var pipeline: MTLRenderPipelineState?
    private var dataProvider: LerpDataProvider?
    /// Values for the current shader's `// lerp-param:` declarations — the
    /// shader's declared defaults, wearing `currentEntry`'s preset. Written
    /// whole by `show`, never patched afterwards, so with no host UI driving it
    /// the view renders exactly the look `currentEntry` names.
    public private(set) var parameterValues: LerpParameterValues?
    private var displayLink: CADisplayLink?
    private var shuffleOrder: [LerpRotationEntry] = []
    private var lastShuffleSwitch: CFTimeInterval = 0

    /// Per-launch random seed handed to shaders as `u.seed`. Settable so a host
    /// (the playground) can re-roll it; the screensaver never touches it.
    public var seed = Float.random(in: 0..<1)
    private var elapsed: CFTimeInterval = 0
    private var resumeStamp: CFTimeInterval = 0
    private var running = false
    private var frozen = false
    private var parked = false
    private var freezeBaseline: CFTimeInterval = 0

    /// When a frame this view drew was last actually scanned out to a display,
    /// on `CACurrentMediaTime()`'s clock. Zero if that has never happened.
    ///
    /// `CAMetalDrawable.presentedTime` is the only thing available from inside a
    /// screensaver host that says "this reached a screen" rather than "AppKit
    /// believes this window is fine". Measured on macOS 27, with this view's
    /// exact shape — a CAMetalLayer-backed subview of a layer-backed parent:
    /// 299 non-zero times out of 300 frames in a window that is on screen,
    /// 0 out of 300 in a window that is not.
    ///
    /// Evidence in one direction only. A layer that is visible but composited
    /// rather than handed to a display plane can report zero as well (measured:
    /// four such windows at once, and only the frontmost kept reporting), so a
    /// recent non-zero time proves this host is being shown and its absence
    /// proves nothing at all. Callers must not invert it.
    private let displayed = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)
    public var lastDisplayedFrameTime: CFTimeInterval { displayed.withLock { $0 } }

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
        parked = false
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
        parked = false
        pauseClock()
        tearDownDisplayLink()
    }

    /// Whether the display link has been taken away by `park()`.
    public var isParked: Bool { parked }

    /// Whether `freezeAfter` has already put the view on its last frame. A host
    /// policing its own power has nothing left to do here.
    public var isFrozen: Bool { frozen }

    /// Gives up the display link but keeps animating, so the caller can drive
    /// the view by hand with `renderOnce()` at whatever rate it likes.
    ///
    /// Unlike occlusion, this deliberately leaves the clock running: a host
    /// that turns out to have been parked by mistake should come back to a
    /// picture that has moved on, not to the frame it was parked at. And unlike
    /// `stop()`, it leaves `running` set, so the freeze timer and the shuffle
    /// keep their place.
    public func park() {
        guard running, !parked else { return }
        parked = true
        tearDownDisplayLink()
    }

    public func unpark() {
        guard parked else { return }
        parked = false
        guard running else { return }
        installDisplayLink()
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
        if let name = config.shaderName, available.named(name) != nil {
            // Pinned. A preset the file no longer declares falls back to the
            // shader's defaults rather than to some other shader — the rotation
            // is not involved, so there is no selection to contradict.
            setEntry(LerpRotationEntry(shader: name, preset: config.presetName),
                     from: available, allowingDefaultsFallback: true)
        } else {
            refreshShuffleOrder(available)
            lastShuffleSwitch = CACurrentMediaTime()
            advanceShuffle(by: 0)
            // There used to be a fallback here: if nothing in the rotation
            // compiled, widen to *every* entry and try again. It is gone, and
            // deliberately.
            //
            // It could only help in one situation — every look the user chose
            // is individually broken while some look they rejected is fine —
            // and it cost the thing this whole feature is for: the one report
            // that got this called a failure was a deselected shader playing
            // anyway. Nothing the user switched off may be put on their screen,
            // and "we had nothing else to show" is not an exception to that.
            //
            // Nor is it much of a rescue in practice. Every shader compiles
            // through the same device and the same prelude, so a failure broad
            // enough to take out a hundred looks takes out the other fourteen
            // too. `loadEntry` has already tried every enabled entry in turn by
            // the time we get here; if none of them built, there is no shader
            // to show and the honest answer is to show none — loudly, so the
            // next person to look has something to go on.
            if pipeline == nil {
                Self.log.error("""
                nothing to render: \(self.shuffleOrder.count, privacy: .public) look(s) in the \
                rotation of \(available.rotationEntries().count, privacy: .public) discovered, \
                and none of them could be built. Not widening to the looks that were switched \
                off. Compile errors: \
                \(self.library.compileErrors.keys.sorted().joined(separator: ", "), privacy: .public)
                """)
            }
        }
    }

    /// Rebuilds `shuffleOrder` from the rotation `config` currently asks for.
    ///
    /// Called before every step of the shuffle, not once at startup. That is the
    /// whole of the deselection bug: `legacyScreenSaver` builds a host and never
    /// destroys it, and `start()` only reaches `selectInitialShader` while
    /// `pipeline` is nil — so a shuffle order computed during the first session
    /// of the day survived every later one. Deselecting a look in Options…
    /// wrote the defaults correctly, the next session re-read them correctly,
    /// and the view then went on shuffling the list it had built before the
    /// click. The look came back minutes later and the settings all said it
    /// should not have.
    ///
    /// Reshuffles only when the eligible *set* changes, so this can be called on
    /// every advance without the order being re-rolled underneath the user.
    ///
    /// An empty rotation leaves the order empty, and `loadEntry` then does
    /// nothing at all — so whatever is already on screen stays there. That is
    /// the last valid pick, and it is the right answer: the alternatives are a
    /// black screen or the full library, and the full library is how a
    /// deselected look reached the screen in the first place. Unreachable
    /// through the gallery, which will not let the last look be switched off.
    private func refreshShuffleOrder(_ available: [LerpShader]) {
        let picked = Config.rotation(of: config.enabledEntries, from: available.rotationEntries())
        guard Set(picked) != Set(shuffleOrder) else { return }
        shuffleOrder = picked.shuffled()
    }

    /// The looks this view will actually shuffle through, as it would compute
    /// them right now. The rotation is a function of `config` plus what is on
    /// disk and is never cached across a change to either, so this is the whole
    /// truth about what can appear — which is what makes "a deselected look
    /// cannot play" a thing a test in another module can check rather than a
    /// claim in a comment.
    public var rotationNow: [LerpRotationEntry] {
        guard config.shaderName == nil else { return [] }
        return Config.rotation(of: config.enabledEntries,
                               from: library.discover().rotationEntries())
    }

    /// Steps the shuffle rotation. `by: 0` loads the rotation's first entry.
    ///
    /// Public because it is the one thing about the shuffle a host cannot
    /// observe by waiting: the interval is minutes long, and the check that
    /// matters — that a hundred advances never leave the enabled set — is not
    /// one anybody can sit through. The interval timer calls exactly this, so a
    /// test that drives it is driving the real path rather than a copy of it.
    public func advanceShuffle(by offset: Int) {
        let available = library.discover()
        refreshShuffleOrder(available)
        loadEntry(after: currentEntry, offset: offset, in: shuffleOrder, from: available)
    }

    /// The rotation, or the pin, changed under us.
    ///
    /// Nothing to do before the first pipeline exists — `start()` will run
    /// `selectInitialShader` and pick from the new rotation anyway. After that,
    /// a look that has just been deselected has to leave the screen now: the
    /// user pressed OK on a sheet that says this look is out, and making them
    /// wait out the rest of a five-minute interval to find out whether it took
    /// is how a setting stops being believed.
    private func rotationChanged() {
        guard pipeline != nil else { return }
        guard config.shaderName == nil else {
            // Newly pinned: honour it immediately, the same way a fresh start
            // would have.
            let available = library.discover()
            if let name = config.shaderName, available.named(name) != nil {
                setEntry(LerpRotationEntry(shader: name, preset: config.presetName),
                         from: available, allowingDefaultsFallback: true)
            }
            return
        }
        let available = library.discover()
        refreshShuffleOrder(available)
        guard let current = currentEntry, !shuffleOrder.contains(current) else { return }
        lastShuffleSwitch = CACurrentMediaTime()
        loadEntry(after: nil, offset: 0, in: shuffleOrder, from: available)
    }

    /// Loads the first entry that compiles, starting `offset` places from
    /// `current` and then continuing in the same direction, wrapping once
    /// through `order`. Returns false only when nothing at all could be loaded.
    ///
    /// Skipping over a shader that will not compile is the whole point: a failed
    /// `setEntry` leaves the previous pipeline bound and `currentEntry`
    /// unchanged, so stopping at the first failure both shows the wrong shader
    /// and sticks there — the next step would set out from the same place and
    /// retry the same broken file.
    @discardableResult
    private func loadEntry(after current: LerpRotationEntry?, offset: Int,
                           in order: [LerpRotationEntry], from available: [LerpShader]) -> Bool {
        guard !order.isEmpty else { return false }
        let step = offset < 0 ? -1 : 1
        var anchor = current
        for attempt in 0..<order.count {
            guard let candidate = ShaderLibrary.step(in: order, after: anchor,
                                                     offset: attempt == 0 ? offset : step)
            else { return false }
            anchor = candidate
            if setEntry(candidate, from: available) {
                // The one fact that settles "why is that look on my screen?".
                // Everything else about the rotation is inspectable at rest --
                // the defaults on disk, the tests, `rotationNow` -- but which
                // entry actually went up, in the real host, was not recorded
                // anywhere, so three separate "this is fixed" claims rested on
                // a harness rather than on the screensaver that ran.
                //
                // `.notice`, not `.info`, and that distinction is the whole
                // point: os_log's info level is memory-only. It never reaches
                // the on-disk store, so it ages out of the ring buffer within
                // minutes and `log show` returns nothing for it afterwards.
                // A screensaver is watched at the exact moments nobody is at a
                // terminal, so a diagnostic that only survives a few minutes is
                // no diagnostic at all -- it read as "the saver never ran".
                Self.log.notice("""
                    playing \(candidate.key, privacy: .public) \
                    (\(self.shuffleOrder.count) in rotation of \(available.rotationEntries().count) discovered)
                    """)
                return true
            }
        }
        return false
    }

    /// Compiles the entry's shader and puts it in the entry's preset.
    ///
    /// `allowingDefaultsFallback` decides what a preset the file no longer
    /// declares means, and the two answers are not interchangeable:
    ///
    /// - **Pinned** (true): fall back to the shader's declared defaults. The
    ///   user asked for this shader by name and there is no rotation to
    ///   contradict, so showing it at its defaults beats showing nothing.
    /// - **Shuffling** (false): refuse, and let `loadEntry` move to the next
    ///   entry. A shader's defaults are a rotation entry in their own right and
    ///   may well be one the user switched off — `spiral/Swirl` in, `spiral`
    ///   out is a real selection somebody made — so quietly substituting them
    ///   for a missing preset puts a deselected look on screen. It also lied
    ///   about it: `currentEntry` said "defaults", which is what the wallpaper
    ///   handoff then rendered.
    @discardableResult
    private func setEntry(_ entry: LerpRotationEntry, from available: [LerpShader],
                          allowingDefaultsFallback: Bool = false) -> Bool {
        guard let shader = available.named(entry.shader) else { return false }
        let preset = entry.preset.flatMap { shader.preset(named: $0) }
        if entry.preset != nil, preset == nil, !allowingDefaultsFallback { return false }
        // The look as this file can still render it. A preset name the shader
        // no longer declares has by now been either refused (shuffling) or
        // forgiven (pinned), and forgiving it means the defaults look — so hand
        // `show` the defaults look, rather than one that names a preset which
        // will not be on screen.
        return show(LerpRotationEntry(shader: shader.name, preset: preset?.name), of: shader)
    }

    /// Puts one complete look on screen.
    ///
    /// The only place `pipeline`, `dataProvider`, `parameterValues`,
    /// `currentShaderName` and `currentEntry` are assigned. They are five facts
    /// about one look, and writing them anywhere else is what let half a look
    /// exist: this used to be `setShader`, which reset the parameters to the
    /// shader's defaults and set `currentEntry` to the defaults entry, leaving
    /// every caller to put the preset back afterwards. Of the four callers, two
    /// did it differently and one did not do it at all — and because the reset
    /// is silent, a caller that forgot showed a look nothing in the logs
    /// disagreed with. There is nothing left to forget.
    ///
    /// `entry` must name a preset this shader actually declares, or none;
    /// `setEntry` is where that is decided, because what an unknown preset name
    /// means depends on whether the shader was pinned or shuffled to.
    @discardableResult
    public func show(_ entry: LerpRotationEntry, of shader: LerpShader) -> Bool {
        do {
            pipeline = try library.pipeline(for: shader)
            dataProvider = try library.dataProvider(for: shader)
            parameterValues = shader.parameterValues(for: entry)
            currentShaderName = shader.name
            currentEntry = entry
            return true
        } catch {
            onCompileError?(shader.name, String(describing: error))
            return false
        }
    }

    /// The shader at its declared defaults — which is a look in its own right,
    /// and the one `show` renders for an entry with no preset. Kept because the
    /// playground's hot reload and the preview app step over *shaders*, not
    /// looks, and neither has a rotation entry to hand.
    @discardableResult
    public func setShader(_ shader: LerpShader) -> Bool {
        show(LerpRotationEntry(shader: shader.name), of: shader)
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
        currentEntry = LerpRotationEntry(shader: currentShaderName, preset: preset.name)
        return true
    }

    /// Steps to the next (or, for a negative `direction`, previous) discovered
    /// shader, skipping any that fail to compile. Shader-level on purpose: this
    /// is the ←/→ keys, which walk the shader list at its defaults rather than
    /// the shuffle's much longer (shader, preset) rotation.
    public func showNextShader(_ direction: Int = 1) {
        let available = library.discover()
        loadEntry(after: LerpRotationEntry(shader: currentShaderName), offset: direction,
                  in: available.map { LerpRotationEntry(shader: $0.name) }, from: available)
    }

    // MARK: - Display link

    private func installDisplayLink() {
        guard displayLink == nil, window != nil, !frozen, !parked else { return }
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

        drawFrame(at: time)
    }

    private func drawFrame(at time: CFTimeInterval) {
        guard let pipeline else { return }
        // Counted here rather than in `tick`, so the readout tells the truth
        // about a parked view too: parked, the display link is gone and the
        // host draws by hand, and an FPS frozen at the rate it used to run is
        // exactly the number nobody should be shown.
        frameCount += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1.0 {
            measuredFPS = Double(frameCount) / (now - fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }
        autoreleasepool {
            guard let drawable = metalLayer.nextDrawable() else { return }
            // Note the lock, not self: this fires on a Metal thread once per
            // frame, and a screensaver has no business retaining its view
            // thirty times a second.
            drawable.addPresentedHandler { [displayed] drawable in
                guard drawable.presentedTime > 0 else { return }
                displayed.withLock { $0 = CACurrentMediaTime() }
            }
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
