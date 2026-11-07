import AppKit
import Metal
import os
import QuartzCore

/// CAMetalLayer-backed view that renders one Lerping@Home shader.
///
/// It draws at the panel's own refresh rate, as macOS's own screensavers and
/// any other app do — there is no frame-rate setting, because the system
/// offers none. Below that it gives way only to a look too heavy for the panel
/// (`paceIfNeeded`). Power and heat are macOS's to manage: its Low Power Mode
/// throttle reaches this display link like every other app's, and a GPU it
/// slows for heat shows up to the pacer as slower frames. It pauses fully when the window is occluded or the view
/// hidden, can render at a reduced internal resolution, and freezes its clock
/// while paused.
public final class LerpMetalView: NSView {

    /// Same subsystem the saver logs under, so one `log show` predicate covers
    /// the whole story of a session. Used only where a silent answer would be
    /// indistinguishable from a broken one.
    ///
    /// Deliberately the *production* module rather than `LerpDefaults.module`,
    /// even in a host that has been sent at a scratch domain: the subsystem is
    /// the thing you have to know in advance to type a `log show` predicate,
    /// and one that moves with an environment variable is one that returns
    /// nothing and reads as "the saver never ran". Which domain was actually in
    /// use is reported in the `rotation resolved` line instead, where it costs
    /// nothing to find. This was spelled as a literal here and taken from
    /// `LerpDefaults.module` in the saver, so the two halves of one session
    /// landed in two different subsystems.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "rotation")

    public struct Config {
        /// Shader name to render, or nil for shuffle mode.
        public var shaderName: String?
        /// Preset to put the pinned shader in, or nil for its declared defaults.
        /// Ignored in shuffle mode, where every rotation entry carries its own.
        public var presetName: String?
        /// Rotation entries — (shader, preset) pairs — eligible for shuffle. See
        /// `Config.rotation(of:from:)` for what nil, empty and stale sets mean.
        public var enabledEntries: Set<LerpRotationEntry>?
        /// 1.0 = native. 0.5 renders quarter the pixels and upscales — usually
        /// indistinguishable for noise-type shaders, ~4x cheaper.
        public var renderScale: Double
        /// Draw exactly this many pixels whatever size the view is, and let the
        /// layer scale them to fit; `renderScale` is then ignored. For a view
        /// that has to continue a picture drawn at a known size — the gallery's
        /// hover preview, over a still. Many looks are not resolution
        /// independent: game-of-life sizes its cells in pixels, dot-grid and the
        /// ditherers their dots, so the same (shader, time, seed) at 176×264 is
        /// a different board, grid or pattern from the one at 240×360.
        public var drawableSize: CGSize?
        public var shuffleInterval: TimeInterval
        /// Stop rendering after this many seconds and hold the last frame
        /// (GPU drops to zero). 0 = never. Resets each start().
        public var freezeAfter: TimeInterval
        /// Ask for EDR output: highlights lifted above SDR white into the
        /// screen's headroom. A request, not a guarantee — `isEDRActive` says
        /// whether it is engaged. Off unless a host turns it on.
        public var extendedDynamicRange = false
        /// The most the highlights are lifted, as a multiple of SDR white,
        /// further capped by what the screen offers. 0 = no cap of our own.
        public var edrPeak: Float = LerpEDR.defaultPeak

        public init(shaderName: String? = nil,
                    presetName: String? = nil,
                    renderScale: Double = 1.0,
                    shuffleInterval: TimeInterval = 300,
                    freezeAfter: TimeInterval = 0) {
            self.shaderName = shaderName
            self.presetName = presetName
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
            if config.renderScale != oldValue.renderScale
                || config.drawableSize != oldValue.drawableSize { updateDrawableSize() }
            if config.extendedDynamicRange != oldValue.extendedDynamicRange { refreshDynamicRange(force: true) }
            if config.enabledEntries != oldValue.enabledEntries
                || config.shaderName != oldValue.shaderName
                || config.presetName != oldValue.presetName {
                rotationChanged(releasedPin: oldValue.shaderName != nil && config.shaderName == nil)
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
    /// Polled once per drawn frame for the `audio*` uniforms. Nil — the saver,
    /// and the playground until its toggle is turned on — means every frame
    /// renders with `.silent`, byte-for-byte what it rendered before the
    /// fields existed.
    public var audioLevels: (() -> LerpAudioLevels)?
    /// Polled once per drawn frame for `u.viewer`, the same way. Nil — the
    /// saver, and the playground until Track Head is on — means `.centered`,
    /// which every look renders exactly as it did before the field existed.
    public var viewer: (() -> LerpViewer)?

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
    /// The rate the current look has been paced down to, or nil for the
    /// panel's rate. See `paceIfNeeded`.
    private var pacedFPS: Int?
    private var lastPaceCheck: CFTimeInterval = 0
    private var lastPaceChange: CFTimeInterval = 0
    /// The order the current cycle is played in — one look per shader —
    /// re-derived from `LerpRotationSchedule` rather than remembered. Kept as a
    /// field only because `loadEntry` needs a list to step through when a look
    /// will not compile.
    private var shuffleOrder: [LerpRotationEntry] = []
    /// Every look the rotation may play, from the same refresh as
    /// `shuffleOrder`. "Is the look on screen still wanted?" is asked of this,
    /// not of the order: the order holds one look per shader per cycle, so a
    /// look that is still on can be absent from it.
    private var shuffleLooks: Set<LerpRotationEntry> = []
    /// Manual nudges from `advanceShuffle(by:)`, added to the clock's slot
    /// number. Stays zero in the screensaver, which lets the clock alone decide
    /// — that is the whole point of the schedule.
    private var shuffleOffset = 0
    /// Fires at the next slot boundary.
    ///
    /// Deliberately *not* the display link. The advance used to live in
    /// `tick()`, which meant `park()` — the power-saving path the screensaver
    /// spends most of its life in — silently stopped the rotation for hours at
    /// a time. A run-loop timer keeps its own time regardless of whether
    /// anything is being drawn, and the schedule it fires into is absolute, so
    /// even a timer that is late or missed entirely lands on the right look.
    private var shuffleTimer: Timer?
    /// Whether the look on screen was put there by the schedule rather than by
    /// an explicit `show`. A view the schedule is driving asks it what is due
    /// when it resumes; a view a host pointed at a look keeps that look across
    /// stop/start.
    private var followsSchedule = false

    // MARK: Switching state
    //
    // A look change used to compile on the main thread, inside the timer that
    // fired it — hundreds of milliseconds of a frozen picture in the middle of
    // a screensaver — and then cut. Now the next look is compiled on
    // `compileQueue` ahead of its boundary (`prefetch`), the switch itself
    // resolves there too (`requestEntry`), and the old look dissolves into the
    // new one over `LerpCrossfade.duration` instead of cutting.

    /// One look's GPU-side state, as `drawFrame` needs it.
    private struct Look {
        let pipeline: MTLRenderPipelineState
        let data: LerpDataProvider?
        let params: LerpParameterValues?
    }

    /// Serial, so a burst of requests compiles one shader at a time and a
    /// prefetch queued behind a switch never races it for the same file.
    private static let compileQueue = DispatchQueue(label: "com.hergenroeder.lerping.compile",
                                                    qos: .utility)
    /// Bumped by every switch request and every direct `show`; a background
    /// result that comes back to an older number has been overtaken.
    private var switchToken = 0
    /// Set while a request is replacing a look that must not be drawn again —
    /// one that has just left the rotation. Frames are held, not drawn, until
    /// the replacement is in, so a switched-off look never animates on.
    private var holdingFrame = false
    /// Where the ←/→ keys step from while their last press is still resolving,
    /// so two quick presses move two places rather than one.
    private var pendingBrowse: LerpRotationEntry?
    /// Whether the look on screen has been drawn at least once. A look nobody
    /// has seen is cut away from, not faded from.
    private var drewCurrentLook = false
    /// When (on the shader clock) the look on screen came in: its caption
    /// shows for `LerpCaptionSchedule.hold` seconds of it, then fades.
    private var lookStart: CFTimeInterval = 0
    /// How far a host's `captionHeld` has brought the caption up, 0…1, and
    /// when that was last moved (wall clock).
    private var captionReveal: Double = 0
    private var captionRevealStamp: CFTimeInterval = 0
    /// The look being faded out, and when (on the shader clock) it started.
    private var fadingOut: Look?
    private var fadeStart: CFTimeInterval = 0
    /// The outgoing look's render target. Exists only mid-fade.
    private var fadeScratch: MTLTexture?
    /// Second instances of data providers, for a fade between two looks of the
    /// same shader. `ShaderLibrary` hands out one provider per name, and a
    /// provider caches by its inputs (`life`'s board, `heatmap`'s texture), so
    /// binding one instance for two looks in the same frame would make the
    /// second bind overwrite what the first pass reads.
    private var spareProviders: [String: LerpDataProvider] = [:]

    /// Per-launch random seed handed to shaders as `u.seed`. Settable so a host
    /// (the playground) can re-roll it; the screensaver never touches it.
    public var seed = Float.random(in: 0..<1)

    // MARK: EDR state — see `LerpEDR`

    /// Whether EDR output is engaged right now: `config.extendedDynamicRange`
    /// asked for it and `LerpEDR.blocker(on:)` found nothing against it at the
    /// last check. That is not the same as the request: unplugging, Low Power
    /// Mode or moving to an SDR screen drops back to the 8-bit path, and
    /// undoing it comes back, within one `LerpEDR.recheckInterval`.
    public private(set) var isEDRActive = false
    /// The headroom the last EDR frame actually used, for a host's readout.
    /// 1.0 while EDR is not active.
    public private(set) var edrHeadroomInUse: Float = 1.0
    /// The look on screen, kept so a range switch can recompile *this* source
    /// for the other pixel format — the playground's draft is not on disk.
    private var currentShader: LerpShader?
    private var edrPostPipeline: MTLRenderPipelineState?
    private var edrSource: MTLTexture?
    private var edrCheckedAt: CFTimeInterval = 0
    private var edrLoggedHeadroom: Float = 0
    /// The format the current look is compiled for. A host that pre-compiles a
    /// draft to check it passes this, so the view's own compile is a cache hit.
    public var shaderPixelFormat: MTLPixelFormat {
        isEDRActive ? LerpEDR.shaderPixelFormat : .bgra8Unorm
    }

    /// Re-decides `isEDRActive`, at most once per `LerpEDR.recheckInterval`
    /// unless forced. Polled from `drawFrame` rather than driven by power and
    /// screen notifications: one cheap check covers every reason the answer
    /// can change, including ones with no notification at all.
    private func refreshDynamicRange(force: Bool = false) {
        let now = CACurrentMediaTime()
        // No window, no screen to ask: decide when there is one.
        guard let window, force || now - edrCheckedAt >= LerpEDR.recheckInterval else { return }
        let first = edrCheckedAt == 0
        edrCheckedAt = now
        var blocker = config.extendedDynamicRange ? LerpEDR.blocker(on: window.screen) : "not requested"
        if blocker == nil, edrPostPipeline == nil {
            do {
                edrPostPipeline = try LerpEDR.makePostPipeline(device: renderer.device)
            } catch {
                blocker = "post pass failed to compile: \(error)"
            }
        }
        let active = blocker == nil
        if active != isEDRActive {
            isEDRActive = active
            LerpEDR.configure(metalLayer, edr: active)
            edrSource = nil
            endCrossfade()
            edrHeadroomInUse = 1.0
            edrLoggedHeadroom = 0
            if let shader = currentShader {
                // The pipeline must match the layer, so a failure leaves none
                // rather than one for the wrong format.
                pipeline = try? library.pipeline(for: shader, pixelFormat: shaderPixelFormat)
            }
        } else if !force, !first {
            return
        }
        Self.log.notice("""
            edr: active=\(active, privacy: .public) \
            why=\(blocker ?? "requested and allowed", privacy: .public) \
            potential=\(LerpEDR.potentialHeadroom(of: window.screen), privacy: .public) \
            current=\(LerpEDR.currentHeadroom(of: window.screen), privacy: .public) \
            peak=\(self.config.edrPeak, privacy: .public)
            """)
    }
    private var elapsed: CFTimeInterval = 0
    private var resumeStamp: CFTimeInterval = 0
    private var running = false
    private var frozen = false
    private var parked = false
    /// Whether the window has *told* us it is covered, and whether the view
    /// has been told it is hidden. Both are learned only from the event, never
    /// by reading `occlusionState` or `isHidden` up front: the screensaver host
    /// that is visibly on screen reports its own window as not visible for the
    /// whole session (see "Hosts that are never shown" in LerpSaverView), so a
    /// view that asked would black out the real screensaver.
    private var occluded = false
    private var toldHidden = false
    private var canBeSeen: Bool { !occluded && !toldHidden }
    /// The clock has been banked by `visibilityChanged` and must be resumed,
    /// exactly once, before it advances again. Without it a second "not
    /// visible" — or a `stop()` while covered — banked the same interval twice
    /// and the animation jumped forward on return.
    private var clockHeld = false
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

    /// The pixels each frame is drawn at — the view's backing size times
    /// `config.renderScale`. For a readout beside a playback-resolution menu, so
    /// lowering it visibly does something even when the frame rate is
    /// already at the display's cap.
    public var renderSize: CGSize { metalLayer.drawableSize }

    /// `.still` for a view that continues a gallery still — no host-only
    /// inputs and no caption, exactly as the still was drawn. See
    /// `LerpRenderMode`.
    public init?(frame: NSRect, extraSearchURLs: [URL] = [], mode: LerpRenderMode = .live) {
        guard let renderer = LerpRenderer() else { return nil }
        self.renderer = renderer
        self.library = ShaderLibrary(device: renderer.device, extraSearchURLs: extraSearchURLs,
                                     mode: mode)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) { nil }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = renderer.device
        LerpEDR.configure(layer, edr: false)
        layer.isOpaque = true
        return layer
    }

    public var shaderLibrary: ShaderLibrary { library }

    /// The shader clock in seconds (`u.time`). Assigning scrubs the animation;
    /// the clock continues from the new value. Combine with `renderOnce()` to
    /// scrub while paused.
    private func runningTime(at now: CFTimeInterval) -> CFTimeInterval {
        elapsed + (now - resumeStamp)
    }

    public var time: CFTimeInterval {
        get { running && !clockHeld ? runningTime(at: CACurrentMediaTime()) : elapsed }
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
        clockHeld = false
        freezeBaseline = elapsed
        resumeClock()
        fpsWindowStart = resumeStamp
        // Before the first look compiles, so it compiles once, for the right format.
        refreshDynamicRange(force: true)

        if pipeline == nil {
            selectInitialShader()
        } else if followsSchedule
                    || (config.shaderName != nil && pin(in: library.discover()) == nil) {
            // (The second case: the pinned shader left the disk since this view
            // last ran, so there is no pin to keep and the schedule takes over.)
            // A view that already has a pipeline is one `legacyScreenSaver`
            // built for an earlier session and never destroyed. It used to
            // resume on whatever look it was showing hours ago and count five
            // fresh minutes from here, which is why a rotation could run all
            // week without ever getting past its first few entries. The
            // schedule is absolute, so the right thing to do on resume is
            // simply to ask what is due.
            //
            // Only when the schedule is what put the look there, though. A
            // view a host pointed at a look — the hover preview, the
            // playground's editor, the preview app, a pinned screensaver —
            // keeps that look across stop/start; asking the schedule here is
            // what made every hovered tile play the same wrong look.
            playScheduledEntry()
        }
        guard window != nil else { return }
        // Started while covered or hidden: hold the clock where it is and
        // leave the link down until the event that says otherwise.
        visibilityChanged()
    }

    public func stop() {
        guard running else { return }
        running = false
        parked = false
        if !clockHeld { pauseClock() }
        clockHeld = false
        cancelShuffleTimer()
        tearDownDisplayLink()
        // A fade in progress keeps its place on the paused clock, but its
        // scratch texture is per-frame and the next frame rebuilds it.
        fadeScratch = nil
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
    ///
    /// The shuffle timer is deliberately left armed. Parking means "nobody can
    /// see this right now", which is a statement about the display and not
    /// about the passage of time: the look that is due at 03:00 is due whether
    /// or not anyone was watching at 02:55, and a host that unparks has to come
    /// back showing it. Tearing the rotation down here is exactly the bug this
    /// arrangement exists to prevent — see `shuffleTimer`.
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
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        guard let window else {
            tearDownDisplayLink()
            return
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification,
                                               object: window)
        // The rate is the panel's, so a move to a screen with another refresh
        // rate (120 Hz built-in to a 60 Hz external, or back) re-asks.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenChanged),
                                               name: NSWindow.didChangeScreenNotification,
                                               object: window)
        updateDrawableSize()
        refreshDynamicRange(force: true)
        // What the last window said about itself says nothing about this one.
        occluded = false
        visibilityChanged()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        toldHidden = true
        visibilityChanged()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        toldHidden = false
        visibilityChanged()
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
        shuffleTimer?.invalidate()
    }

    // MARK: - Shader selection

    /// Honours `config`'s pinned (shader, preset), if it names one that is on
    /// disk. Returns false when nothing is pinned or the pin has gone.
    ///
    /// A preset the file no longer declares falls back to the shader's defaults
    /// rather than to some other shader — the rotation is not involved, so there
    /// is no selection to contradict. That is the whole difference between a pin
    /// and a shuffle step, and it is stated once: both the first load and a
    /// later change to `config` come through here.
    @discardableResult
    private func showPinned(from available: [LerpShader]) -> Bool {
        guard let name = pin(in: available) else { return false }
        return setEntry(LerpRotationEntry(shader: name, preset: config.presetName),
                        from: available, allowingDefaultsFallback: true)
    }

    /// The shader `config` pins, if it is on disk; nil means the schedule
    /// decides. A pin whose shader has gone — renamed, deleted, no longer
    /// building for this OS — is no pin at all. It used to be half of one: too
    /// pinned for the shuffle timer to arm, too absent to show, so the saver
    /// put up whatever was due at the start of the session and never moved
    /// again, while Options… (which cannot select a name that is not there)
    /// said "Shuffle". Every "is this view pinned?" question asks this.
    private func pin(in available: [LerpShader]) -> String? {
        guard let name = config.shaderName, available.named(name) != nil else { return nil }
        return name
    }

    private func selectInitialShader() {
        let available = library.discover()
        guard !available.isEmpty else { return }
        if pin(in: available) != nil {
            showPinned(from: available)
        } else {
            playScheduledEntry()
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
                nothing to render: \(self.shuffleLooks.count, privacy: .public) look(s) in the \
                rotation of \(available.rotationEntries().count, privacy: .public) discovered, \
                and none of them could be built. Not widening to the looks that were switched \
                off. Compile errors: \
                \(self.library.compileErrors.keys.sorted().joined(separator: ", "), privacy: .public)
                """)
            }
        }
    }

    /// Rebuilds `shuffleOrder` from the rotation `config` currently asks for,
    /// and returns the position in it that the clock says is due.
    ///
    /// Recomputed on every step, not once at startup. That is the whole of the
    /// deselection bug: `legacyScreenSaver` builds a host and never destroys
    /// it, and `start()` only reaches `selectInitialShader` while `pipeline` is
    /// nil — so a shuffle order computed during the first session of the day
    /// survived every later one. Deselecting a look in Options… wrote the
    /// defaults correctly, the next session re-read them correctly, and the
    /// view then went on shuffling the list it had built before the click. The
    /// look came back minutes later and the settings all said it should not
    /// have.
    ///
    /// The order is now a pure function of the cycle number rather than a
    /// remembered `shuffled()`, so recomputing it costs nothing and cannot
    /// re-roll under the user: within one pass, the same cycle always produces
    /// the same list. See `LerpRotationSchedule`.
    ///
    /// An empty rotation leaves the order empty, and `loadEntry` then does
    /// nothing at all — so whatever is already on screen stays there. That is
    /// the last valid pick, and it is the right answer: the alternatives are a
    /// black screen or the full library, and the full library is how a
    /// deselected look reached the screen in the first place. Unreachable
    /// through the gallery, which will not let the last look be switched off.
    @discardableResult
    private func refreshShuffleOrder(_ available: [LerpShader]) -> Int {
        let picked = pickedLooks(available)
        shuffleLooks = Set(picked)
        let scheduled = LerpRotationSchedule.rotation(picked, at: Date(),
                                                      interval: config.shuffleInterval,
                                                      offset: shuffleOffset)
        shuffleOrder = scheduled.order
        return scheduled.index
    }

    /// Puts the look the schedule names on screen and arms the clock for the
    /// next one. The single path by which the rotation ever moves.
    private func playScheduledEntry() {
        let available = library.discover()
        let index = refreshShuffleOrder(available)
        // The look on screen may fade out only if it is still one the user
        // wants. One that has left the rotation is cut away from instead.
        let stillWanted = currentEntry.map(shuffleLooks.contains) ?? false
        loadEntry(after: nil, offset: index, in: shuffleOrder, from: available,
                  fadingOutAllowed: stillWanted)
        // After `show` above cleared it: the schedule put this look up, so a
        // later resume asks the schedule again rather than keeping it.
        followsSchedule = true
        armShuffleTimer(available)
    }

    /// Arms the rotation clock for the next slot boundary.
    ///
    /// Fires once rather than repeating: each firing re-derives the boundary
    /// from the absolute schedule, so a timer that ran late does not push every
    /// later look late behind it. `.common` mode so a tracking run loop — a
    /// menu held open, a window being dragged — does not hold the rotation.
    private func armShuffleTimer(_ available: [LerpShader]) {
        cancelShuffleTimer()
        // Counted in looks, not in the order's length: a rotation of one
        // shader with several looks on still moves.
        guard running, !frozen, pin(in: available) == nil, shuffleLooks.count > 1,
              let next = LerpRotationSchedule.nextBoundary(after: Date(),
                                                           interval: config.shuffleInterval)
        else { return }
        // Weakly, so the run loop holding this timer is not what keeps a view
        // alive: legacyScreenSaver already never destroys one.
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            self?.playScheduledEntry()
        }
        // A timer only ever fires late, never early, and the schedule asks the
        // clock what is due when it does — so a second of slack lets the
        // system coalesce this wake-up with others at no cost to which look
        // plays.
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        shuffleTimer = timer
        prefetch(slotAfter: next, from: available)
    }

    /// Compiles, off the main thread, the look the schedule will ask for at
    /// `boundary`, so that when the timer fires the switch is a cache hit.
    ///
    /// Asked of the schedule exactly as the timer will ask it — same entries,
    /// same offset — but at the middle of the next slot, which no rounding at
    /// the boundary can land on the wrong side of. Walks past a look that will
    /// not build the same way `loadEntry` will, so what gets warmed is the look
    /// that will actually play. A wrong guess (the rotation changed in
    /// between) costs one compile that the switch would have paid anyway.
    private func prefetch(slotAfter boundary: Date, from available: [LerpShader]) {
        let interval = config.shuffleInterval
        let upcoming = LerpRotationSchedule.rotation(pickedLooks(available),
                                                     at: boundary.addingTimeInterval(interval / 2),
                                                     interval: interval, offset: shuffleOffset)
        let library = self.library
        let format = shaderPixelFormat
        Self.compileQueue.async {
            _ = ShaderLibrary.firstStep(in: upcoming.order, after: nil, offset: upcoming.index) {
                guard let look = Self.resolve($0, from: available, allowingDefaultsFallback: false)
                else { return false }
                return (try? library.pipeline(for: look.shader, pixelFormat: format)) != nil
            }
            LerpCrossfade.prepare(device: library.device, pixelFormat: format)
        }
    }

    private func cancelShuffleTimer() {
        shuffleTimer?.invalidate()
        shuffleTimer = nil
    }

    /// The looks this view will actually shuffle through, as it would compute
    /// them right now. The rotation is a function of `config` plus what is on
    /// disk and is never cached across a change to either, so this is the whole
    /// truth about what can appear — which is what makes "a deselected look
    /// cannot play" a thing a test in another module can check rather than a
    /// claim in a comment.
    public var rotationNow: [LerpRotationEntry] {
        let available = library.discover()
        guard pin(in: available) == nil else { return [] }
        return pickedLooks(available)
    }

    /// What `config` selects from these shaders — the one spelling of it in
    /// this view, for the schedule, the prefetch and `rotationNow` alike.
    private func pickedLooks(_ available: [LerpShader]) -> [LerpRotationEntry] {
        Config.rotation(of: config.enabledEntries, from: available.rotationEntries())
    }

    /// Steps the shuffle rotation. `by: 0` loads the rotation's first entry.
    ///
    /// Public because it is the one thing about the shuffle a host cannot
    /// observe by waiting: the interval is minutes long, and the check that
    /// matters — that a hundred advances never leave the enabled set — is not
    /// one anybody can sit through.
    ///
    /// Expressed as a nudge to the schedule's slot number rather than as a step
    /// from whatever is on screen, so that stepping by hand and waiting for the
    /// clock go through exactly the same arithmetic. `by: 0` re-asserts the
    /// look that is due right now, which is what a resume wants.
    public func advanceShuffle(by offset: Int) {
        shuffleOffset &+= offset
        playScheduledEntry()
    }

    /// The rotation, or the pin, changed under us.
    ///
    /// Nothing to do before the first pipeline exists — `start()` will run
    /// `selectInitialShader` and pick from the new rotation anyway. After that,
    /// a look that has just been deselected has to leave the screen now: the
    /// user pressed OK on a sheet that says this look is out, and making them
    /// wait out the rest of a five-minute interval to find out whether it took
    /// is how a setting stops being believed.
    private func rotationChanged(releasedPin: Bool) {
        if releasedPin {
            // Back to Shuffle: the schedule owns the screen again. Said here,
            // before the early return below, because the saver assigns its
            // config to a view that is still stopped (and that is the normal
            // case: legacyScreenSaver reuses yesterday's view). Missing this was
            // a saver that, once pinned and then unpinned, kept the old pin up
            // for every later session — `start()` resumes the schedule only for
            // a view the schedule is driving, and nothing else ever said so.
            followsSchedule = true
        }
        guard pipeline != nil else { return }
        let available = library.discover()
        guard pin(in: available) == nil else {
            // Newly pinned: honour it immediately, the same way a fresh start
            // would have — and by the same call, so the two cannot disagree
            // about what a pin means. A pin has no rotation to keep time for.
            cancelShuffleTimer()
            showPinned(from: available)
            return
        }
        if releasedPin, running {
            // Show what is due now rather than the old pin for up to a whole
            // interval; `start()` does the same for a stopped view.
            playScheduledEntry()
            return
        }
        let index = refreshShuffleOrder(available)
        // The interval may have changed with the selection, so the boundary
        // this view is waiting on has to be recomputed either way.
        armShuffleTimer(available)
        guard let current = currentEntry, !shuffleLooks.contains(current) else { return }
        // The look on screen has just been switched off, so it goes now rather
        // than at the next boundary. It is replaced by whatever the schedule
        // says is due, which keeps this view in step with every other one
        // instead of starting a private five minutes from the click. Cut, not
        // faded: a look the user switched off does not get another 1.5 s.
        loadEntry(after: nil, offset: index, in: shuffleOrder, from: available,
                  fadingOutAllowed: false)
        followsSchedule = true
    }

    /// Loads the first entry that compiles, starting `offset` places from
    /// `current` and then continuing in the same direction, wrapping once
    /// through `order`. Returns false only when nothing at all could be loaded.
    ///
    /// The walk itself is `ShaderLibrary.firstStep`, which is also how the
    /// playground picks the look it opens on — see there for why a candidate
    /// that will not build is stepped over rather than stopped at. What is left
    /// here is what the screensaver does with the answer.
    ///
    /// Synchronous only for the very first look, when there is nothing on
    /// screen to keep showing and the callers want to know at once whether
    /// anything built. Every later switch goes through `requestEntry`, which
    /// walks the same way off the main thread and returns before it lands;
    /// `fadingOutAllowed` says whether the look it replaces may dissolve out.
    @discardableResult
    private func loadEntry(after current: LerpRotationEntry?, offset: Int,
                           in order: [LerpRotationEntry], from available: [LerpShader],
                           fadingOutAllowed: Bool = false) -> Bool {
        guard pipeline == nil else {
            requestEntry(after: current, offset: offset, in: order, from: available,
                         fadingOutAllowed: fadingOutAllowed)
            return true
        }
        guard let candidate = ShaderLibrary.firstStep(in: order, after: current, offset: offset,
                                                      where: { setEntry($0, from: available) })
        else { return false }
        logPlaying(candidate, of: available, crossfade: false)
        return true
    }

    /// `loadEntry`'s walk, run on `compileQueue`, landing back on the main
    /// thread as one `install`.
    ///
    /// Until it lands, the look already on screen keeps playing — unless it is
    /// one that must not (`fadingOutAllowed` false: it has left the rotation),
    /// in which case frames are held rather than drawn, which is what the
    /// synchronous version did for the length of its compile. A request that
    /// comes back after a newer one, or after a direct `show`, is dropped.
    private func requestEntry(after current: LerpRotationEntry?, offset: Int,
                              in order: [LerpRotationEntry], from available: [LerpShader],
                              fadingOutAllowed: Bool) {
        switchToken &+= 1
        let token = switchToken
        holdingFrame = !fadingOutAllowed
        let library = self.library
        let format = shaderPixelFormat
        // A switch somebody is waiting on runs at user-initiated priority; the
        // queue's own utility QoS is for prefetches, which nobody is.
        Self.compileQueue.async(qos: .userInitiated, flags: .enforceQoS) { [weak self] in
            var failures: [(shader: String, error: String)] = []
            var found: (candidate: LerpRotationEntry, entry: LerpRotationEntry,
                        shader: LerpShader, pipeline: MTLRenderPipelineState)?
            _ = ShaderLibrary.firstStep(in: order, after: current, offset: offset) { candidate in
                guard let look = Self.resolve(candidate, from: available,
                                              allowingDefaultsFallback: false)
                else { return false }
                do {
                    let pipeline = try library.pipeline(for: look.shader, pixelFormat: format)
                    _ = try library.dataProvider(for: look.shader)
                    found = (candidate, look.entry, look.shader, pipeline)
                    return true
                } catch {
                    failures.append((look.shader.name, String(describing: error)))
                    return false
                }
            }
            if found != nil, fadingOutAllowed {
                LerpCrossfade.prepare(device: library.device, pixelFormat: format)
            }
            let (result, errors) = (found, failures)
            DispatchQueue.main.async {
                guard let self, token == self.switchToken else { return }
                self.holdingFrame = false
                self.pendingBrowse = nil
                for failure in errors { self.onCompileError?(failure.shader, failure.error) }
                // Nothing built: whatever is on screen stays, as it always has.
                guard let found = result else { return }
                // EDR may have flipped while this compiled; never install a
                // pipeline for the other format.
                guard let compiled = format == self.shaderPixelFormat ? found.pipeline
                        : try? self.library.pipeline(for: found.shader, pixelFormat: self.shaderPixelFormat)
                else { return }
                let faded = self.install(found.entry, of: found.shader, pipeline: compiled,
                                         allowFade: fadingOutAllowed)
                self.logPlaying(found.candidate, of: available, crossfade: faded)
            }
        }
    }

    private func logPlaying(_ candidate: LerpRotationEntry, of available: [LerpShader],
                            crossfade: Bool) {
        // The one fact that settles "why is that look on my screen?".
        // Everything else about the rotation is inspectable at rest -- the
        // defaults on disk, the tests, `rotationNow` -- but which entry actually
        // went up, in the real host, was not recorded anywhere, so three
        // separate "this is fixed" claims rested on a harness rather than on the
        // screensaver that ran.
        //
        // `.notice`, not `.info`, and that distinction is the whole point:
        // os_log's info level is memory-only. It never reaches the on-disk
        // store, so it ages out of the ring buffer within minutes and `log show`
        // returns nothing for it afterwards. A screensaver is watched at the
        // exact moments nobody is at a terminal, so a diagnostic that only
        // survives a few minutes is no diagnostic at all -- it read as "the
        // saver never ran".
        //
        // `verify-rotation.py` matches the text up to the closing parenthesis;
        // anything after it is free.
        Self.log.notice("""
            playing \(candidate.key, privacy: .public) \
            (\(self.shuffleLooks.count) in rotation of \(available.rotationEntries().count) discovered)\
            \(crossfade ? " crossfade" : "", privacy: .public)
            """)
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
        guard let look = Self.resolve(entry, from: available,
                                      allowingDefaultsFallback: allowingDefaultsFallback)
        else { return false }
        return show(look.entry, of: look.shader)
    }

    /// `setEntry`'s decision without its side effect, so `requestEntry` and
    /// `prefetch` can make it off the main thread and reach the same answer.
    private static func resolve(_ entry: LerpRotationEntry, from available: [LerpShader],
                                allowingDefaultsFallback: Bool)
        -> (entry: LerpRotationEntry, shader: LerpShader)? {
        guard let shader = available.named(entry.shader) else { return nil }
        let preset = entry.preset.flatMap { shader.preset(named: $0) }
        if entry.preset != nil, preset == nil, !allowingDefaultsFallback { return nil }
        // The look as this file can still render it. A preset name the shader
        // no longer declares has by now been either refused (shuffling) or
        // forgiven (pinned), and forgiving it means the defaults look — so hand
        // `show` the defaults look, rather than one that names a preset which
        // will not be on screen.
        return (LerpRotationEntry(shader: shader.name, preset: preset?.name), shader)
    }

    /// Puts one complete look on screen, at once, with no fade: a host that
    /// points the view at a look (a hovered tile, the editor, a hot reload)
    /// wants to see that look now. Overrides any switch still resolving.
    ///
    /// `install` is the only place `pipeline`, `dataProvider`, `parameterValues`,
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
        // A host pointed this view at a look, so the schedule no longer owns
        // what is on screen. `playScheduledEntry` sets this back after its own
        // `show`, which is the one path where the schedule is the host.
        followsSchedule = false
        do {
            let compiled = try library.pipeline(for: shader, pixelFormat: shaderPixelFormat)
            _ = try library.dataProvider(for: shader)
            switchToken &+= 1
            holdingFrame = false
            pendingBrowse = nil
            install(entry, of: shader, pipeline: compiled, allowFade: false)
            return true
        } catch {
            onCompileError?(shader.name, String(describing: error))
            return false
        }
    }

    /// Writes the five facts of one look, from an already-compiled pipeline,
    /// and either starts a crossfade from the look it replaces or cuts.
    /// Returns whether it is fading.
    ///
    /// A fade needs a look worth fading from — one that has actually been
    /// drawn, that is not the incoming look itself, and that the caller says
    /// may still be seen — and the composite pipeline, which is built off the
    /// main thread beside the incoming look and is never waited for here.
    @discardableResult
    private func install(_ entry: LerpRotationEntry, of shader: LerpShader,
                         pipeline compiled: MTLRenderPipelineState, allowFade: Bool) -> Bool {
        let fade = allowFade && drewCurrentLook && entry != currentEntry
            && LerpCrossfade.pipeline(device: renderer.device,
                                      pixelFormat: shaderPixelFormat) != nil
        var data = try? library.dataProvider(for: shader)    // cached by now
        if fade, let outgoing = pipeline {
            fadingOut = Look(pipeline: outgoing, data: dataProvider, params: parameterValues)
            fadeStart = time
            if let shared = data, shared === dataProvider, let name = shader.dataProviderName {
                data = spareProvider(named: name) ?? shared
            }
        } else {
            endCrossfade()
        }
        pipeline = compiled
        dataProvider = data
        parameterValues = shader.parameterValues(for: entry)
        currentShader = shader
        currentShaderName = shader.name
        currentEntry = entry
        lookStart = time
        renderer.gpuCost.begin(look: entry.key)
        // Every look starts at the panel's rate and earns a lower one only
        // by being measured too slow for it.
        if pacedFPS != nil {
            pacedFPS = nil
            applyFrameRate()
        }
        lastPaceChange = CACurrentMediaTime()
        drewCurrentLook = false
        return fade
    }

    /// A second provider of this name, made on first need and kept per view.
    private func spareProvider(named name: String) -> LerpDataProvider? {
        if let spare = spareProviders[name] { return spare }
        let made = LerpDataProviders.make(named: name, device: renderer.device, mode: library.mode)
        spareProviders[name] = made
        return made
    }

    private func endCrossfade() {
        fadingOut = nil
        fadeScratch = nil
        // Crossfade frames drew two looks; they say nothing about this one.
        renderer.gpuCost.restartRecent()
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

    /// Starts or stops one parameter's `// lerp-animate:` drift. False when the
    /// look on screen gives it none.
    @discardableResult
    public func setParameterAnimating(_ name: String, _ on: Bool) -> Bool {
        parameterValues?.setAnimating(name, on) ?? false
    }

    /// Gives one parameter `animation` as its drift and starts it. How a host
    /// puts back a worn preset's `name=animate(…)` after `setShader` has reset
    /// the view to the shader's defaults.
    @discardableResult
    public func animateParameter(_ name: String, with animation: LerpParamAnimation) -> Bool {
        parameterValues?.animate(name, with: animation) ?? false
    }

    /// The parameter values as the frame at the current clock draws them —
    /// animated parameters at their place on the curve. What a host's
    /// controls should show; `parameterValues` is what they hold.
    public var liveParameterValues: LerpParameterValues? {
        parameterValues?.resolved(time: Float(time), seed: seed)
    }

    /// Steps to the next (or, for a negative `direction`, previous) discovered
    /// shader, skipping any that fail to compile. Shader-level on purpose: this
    /// is the ←/→ keys, which walk the shader list at its defaults rather than
    /// the shuffle's much longer (shader, preset) rotation.
    ///
    /// Crossfades like the rotation does, and like it never compiles on the
    /// main thread once something is on screen.
    public func showNextShader(_ direction: Int = 1) {
        let available = library.discover()
        let order = available.map { LerpRotationEntry(shader: $0.name) }
        let from = pendingBrowse ?? LerpRotationEntry(shader: currentShaderName)
        if pipeline != nil {
            // What `show` would have done: a key press is a host choosing.
            followsSchedule = false
            pendingBrowse = ShaderLibrary.step(in: order, after: from, offset: direction)
        }
        loadEntry(after: from, offset: direction, in: order, from: available,
                  fadingOutAllowed: true)
    }

    // MARK: - Display link

    private func installDisplayLink() {
        guard displayLink == nil, window != nil, !frozen, !parked, canBeSeen else { return }
        let link = self.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        applyFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func tearDownDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// The panel's refresh rate, lowered by the pacer, as a range the display
    /// link can pace against.
    ///
    /// `NSView.displayLink` rather than `CAMetalDisplayLink`, on purpose. Both
    /// are display-synced and take a `preferredFrameRateRange`, and this one
    /// already follows the view from screen to screen. What
    /// `CAMetalDisplayLink` adds is drawables handed to the callback against a
    /// presentation deadline — a latency tool — and it takes drawable
    /// acquisition away from the layer, which `renderOnce()` needs: the parked
    /// saver, the paused playground and every scrub draw by hand, outside any
    /// display-link callback. Measured cadence with this link at a 30 fps cap
    /// on a 120 Hz panel: 33.33 ms mean, 0.02 ms standard deviation.
    ///
    /// The range lets the system drop a few frames below the cap under load
    /// rather than skip to a half rate; the preferred rate is the cap itself.
    private func applyFrameRate() {
        let fps = Float(currentFPS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: min(max(10, fps - 6), fps),
                                                                maximum: fps,
                                                                preferred: fps)
    }

    /// The panel's refresh rate: the most the display link can deliver, and
    /// what it is asked for unless the pacer lowers it.
    private var panelFPS: Int { max(window?.screen?.maximumFramesPerSecond ?? 60, 1) }

    /// The rate the display link is asking for right now.
    private var currentFPS: Int { min(panelFPS, pacedFPS ?? panelFPS) }

    /// Rates that divide the panel's refresh exactly, at or below `ceiling`,
    /// fastest first: on a 120 Hz panel 60, 40, 30, 24, 20, 15. Each frame then
    /// stays on screen for the same whole number of refreshes.
    private func cleanRates(atMost ceiling: Int) -> [Int] {
        let panel = panelFPS
        return stride(from: min(ceiling, panel), through: 15, by: -1).filter { panel % $0 == 0 }
    }

    /// Keeps a look that cannot hold its frame rate from juddering.
    ///
    /// A look whose GPU time overruns the frame does not run at a lower rate,
    /// it runs at an irregular one: most frames on time, some a refresh late,
    /// and motion that steps unevenly. Once a second this reads the p95 of the
    /// look's last ~2 s of frames (`LerpGPUCost.recentP95`) and, if it uses
    /// more than 85% of the frame, steps down to the next rate that divides
    /// the panel's refresh, where every frame lasts the same number of
    /// refreshes. It steps back up, at most every 10 s, when the faster rate
    /// would still leave 40% headroom. Every new look starts back at the
    /// panel's rate. Crossfades are skipped: they draw two looks.
    private func paceIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastPaceCheck >= 1.0 else { return }
        lastPaceCheck = now
        guard fadingOut == nil, let p95 = renderer.gpuCost.recentP95() else { return }
        let capped = panelFPS
        let fps = currentFPS
        let rates = cleanRates(atMost: capped)
        var next: Int?
        if p95 > 0.85 * 1000.0 / Double(fps) {
            next = rates.first { $0 < fps && p95 <= 0.85 * 1000.0 / Double($0) } ?? rates.last
        } else if fps < capped, now - lastPaceChange >= 10,
                  let faster = rates.last(where: { $0 > fps }), p95 <= 0.6 * 1000.0 / Double(faster) {
            next = faster
        }
        guard let next, next != fps else { return }
        pacedFPS = next >= capped ? nil : next
        lastPaceChange = now
        renderer.gpuCost.restartRecent()
        applyFrameRate()
        Self.log.notice("pace: \(self.currentEntry?.key ?? "?", privacy: .public) p95=\(String(format: "%.2f", p95), privacy: .public)ms → \(next) fps")
    }

    /// A new screen may refresh at a different rate; any pacing was measured
    /// against the old one, so it starts over too.
    @objc private func screenChanged(_ note: Notification) {
        pacedFPS = nil
        applyFrameRate()
    }

    @objc private func occlusionChanged(_ note: Notification) {
        occluded = !(window?.occlusionState.contains(.visible) ?? false)
        visibilityChanged()
    }

    /// Covered or hidden pauses the clock and takes the display link away —
    /// a hard zero frames, not a slow rate — but deliberately leaves `running`
    /// set: the view is still animating as far as its host is concerned, it
    /// just has nothing to draw to. Unlike `park()`, the clock holds too, so
    /// the animation picks up where the user last saw it.
    private func visibilityChanged() {
        guard running else { return }
        if canBeSeen {
            if clockHeld {
                clockHeld = false
                resumeClock()
            }
            installDisplayLink()
        } else {
            if !clockHeld {
                clockHeld = true
                pauseClock()
            }
            tearDownDisplayLink()
        }
    }

    private func updateDrawableSize() {
        guard window != nil else { return }
        let scale = (window?.backingScaleFactor ?? 2.0) * config.renderScale
        let size = config.drawableSize ?? CGSize(width: max(1, bounds.width * scale),
                                                 height: max(1, bounds.height * scale))
        if metalLayer.drawableSize != size {
            metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
            metalLayer.drawableSize = size
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard running, pipeline != nil else { return }
        // Animate to when this frame will be on screen, not to when the
        // callback happened to run. The callback lands a variable few ms into
        // the frame (main-thread work, a timer, the run loop), and sampling
        // the clock there turned that jitter into uneven animation steps:
        // judder on every smooth camera move. `targetTimestamp` advances by
        // exactly one refresh interval per frame. It is on the same clock as
        // `CACurrentMediaTime()`, and never behind it, so the crossfade's
        // start (taken from `time`) still precedes the first faded frame.
        let target = link.targetTimestamp
        let time = runningTime(at: target > 0 ? max(target, CACurrentMediaTime()) : CACurrentMediaTime())
        paceIfNeeded()

        if config.freezeAfter > 0, time - freezeBaseline > config.freezeAfter {
            frozen = true
            // "Still image after N minutes" is a promise about what is on
            // screen, so the rotation stops with the picture. Nothing re-arms
            // this until `start()` runs again, which is the only thing that
            // clears `frozen`.
            cancelShuffleTimer()
            tearDownDisplayLink()   // hold the last presented frame, GPU idle
            endCrossfade()
            return
        }

        // The shuffle deliberately does not live here. It used to, and a
        // display link is exactly the wrong clock for it: `park()` takes the
        // link away for hours at a time and the rotation went with it. See
        // `shuffleTimer`.
        drawFrame(at: time)
    }

    private func drawFrame(at time: CFTimeInterval) {
        refreshDynamicRange()
        // Held: the look on screen has left the rotation and its replacement
        // is still compiling. Not drawing keeps it from animating on.
        guard let pipeline, !holdingFrame else { return }
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
            let uniforms = liveUniforms(width: Int(metalLayer.drawableSize.width),
                                        height: Int(metalLayer.drawableSize.height), at: time)
            applyCaptionOpacity(at: time)
            if isEDRActive, let post = edrPostPipeline {
                drawEDR(drawable: drawable, pipeline: pipeline, post: post, uniforms: uniforms)
            } else {
                let overlay = encodeOutgoing(at: time, like: drawable.texture)
                renderer.draw(drawable: drawable, pipeline: pipeline, uniforms: uniforms,
                              params: parameterValues, data: dataProvider, overlay: overlay)
            }
            drewCurrentLook = true
        }
    }

    /// Shader into an rgba16Float scratch texture, then `LerpEDR`'s expand pass
    /// into the drawable, on one command buffer.
    private func drawEDR(drawable: CAMetalDrawable, pipeline: MTLRenderPipelineState,
                         post: MTLRenderPipelineState, uniforms: LerpUniforms) {
        let target = drawable.texture
        if edrSource?.width != target.width || edrSource?.height != target.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: LerpEDR.shaderPixelFormat,
                width: target.width, height: target.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            edrSource = renderer.device.makeTexture(descriptor: descriptor)
        }
        guard let source = edrSource else { return }
        // Mid-crossfade, the outgoing look is blended onto the float source,
        // before the expand pass, so both looks get the same highlight lift.
        let overlay = encodeOutgoing(at: time, like: source)
        guard let commandBuffer = renderer.encodePass(target: source, pipeline: pipeline,
                                                      uniforms: uniforms,
                                                      params: parameterValues,
                                                      data: dataProvider) else { return }
        if let overlay { LerpCrossfade.encode(overlay, onto: source, in: commandBuffer) }
        // Read every frame: macOS ramps the headroom up after EDR content
        // appears and moves it with the brightness slider.
        let available = LerpEDR.currentHeadroom(of: window?.screen)
        let headroom = config.edrPeak > 0 ? min(config.edrPeak, available) : available
        edrHeadroomInUse = headroom
        if abs(headroom - edrLoggedHeadroom) >= 0.5 {
            edrLoggedHeadroom = headroom
            Self.log.notice("edr: headroom in use=\(headroom, privacy: .public) available=\(available, privacy: .public)")
        }
        LerpEDR.encodeExpand(into: commandBuffer, source: source, target: target,
                             pipeline: post, params: LerpEDR.Params(headroom: headroom))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// This frame's uniforms for a target of the given size: the clock, the
    /// seed, and whatever live input a host is feeding. The one place they are
    /// built, so the incoming look and a crossfade's outgoing one always see
    /// the same frame.
    private func liveUniforms(width: Int, height: Int, at time: CFTimeInterval) -> LerpUniforms {
        LerpUniforms(resolution: SIMD2<Float>(Float(width), Float(height)),
                     time: Float(time), seed: seed,
                     audio: audioLevels?() ?? .silent,
                     viewer: viewer?() ?? .centered)
    }

    /// Keeps a captioned look's label up while a host holds it
    /// (`captionHeld`), and otherwise lets it go after the look's first
    /// seconds (`LerpCaptionSchedule`).
    public var captionHeld = false

    private func applyCaptionOpacity(at time: CFTimeInterval) {
        guard let splat = dataProvider as? SplatData else { return }
        // A still is drawn without its caption (`RotationThumbnails`), so the
        // view that continues one is too.
        guard library.mode == .live else { splat.captionOpacity = 0; return }
        let now = CACurrentMediaTime()
        let dt = captionRevealStamp > 0 ? min(0.1, now - captionRevealStamp) : 0
        captionRevealStamp = now
        captionReveal += ((captionHeld ? 1 : 0) - captionReveal) * min(1, dt / LerpCaptionSchedule.reveal)
        let scheduled = LerpCaptionSchedule.opacity(age: time - lookStart)
        splat.captionOpacity = Float(max(scheduled, captionReveal))
    }

    /// Mid-fade: renders the outgoing look into the scratch texture, in its
    /// own command buffer ahead of the frame's, and returns it as the overlay
    /// for `renderer.draw`. nil — and the fade over — once it has run its
    /// length, or if the clock has been put back before it began.
    ///
    /// The outgoing look gets uniforms of its own, built exactly as the
    /// incoming look's are, so it keeps animating on the same clock and seed
    /// it was playing on rather than freezing on its last frame.
    private func encodeOutgoing(at time: CFTimeInterval,
                                like target: MTLTexture) -> LerpCrossfade.Overlay? {
        guard let outgoing = fadingOut else { return nil }
        let progress = (time - fadeStart) / LerpCrossfade.duration
        guard progress >= 0, progress < 1,
              let composite = LerpCrossfade.pipeline(device: renderer.device,
                                                     pixelFormat: target.pixelFormat)
        else { endCrossfade(); return nil }
        if fadeScratch?.width != target.width || fadeScratch?.height != target.height
            || fadeScratch?.pixelFormat != target.pixelFormat {
            fadeScratch = LerpCrossfade.makeScratch(device: renderer.device, like: target)
        }
        let uniforms = liveUniforms(width: target.width, height: target.height, at: time)
        guard let scratch = fadeScratch,
              let commandBuffer = renderer.encodePass(target: scratch, pipeline: outgoing.pipeline,
                                                      uniforms: uniforms, params: outgoing.params,
                                                      data: outgoing.data)
        else { endCrossfade(); return nil }
        commandBuffer.label = "Lerping/crossfade.outgoing"
        commandBuffer.commit()
        return LerpCrossfade.Overlay(texture: scratch, pipeline: composite,
                                     opacity: Float(1 - LerpCrossfade.weight(at: progress)))
    }
}
