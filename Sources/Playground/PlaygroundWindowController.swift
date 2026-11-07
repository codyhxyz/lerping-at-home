import AppKit
import Metal
import MIDIDeps
import QuartzCore

extension NSWindow {
    /// Takes the window off the user's screen without taking it off *a* screen.
    ///
    /// Moving it beyond the displays would be simpler, but AppKit stops the
    /// display link on a window that is on no screen — measured: zero frames —
    /// and "the live view is drawing frames" is one of the checks `--capture`
    /// exists to make. So it stays where it is, fully composited and really
    /// rendering, at zero opacity: invisible, click-through, out of ⌘-Tab and
    /// Mission Control, and out of the Window menu.
    ///
    /// Both of the playground's windows do this in capture mode, and both have
    /// to do it the same way or the run is not the launch it claims to
    /// reproduce.
    func hideForCapture() {
        alphaValue = 0
        ignoresMouseEvents = true
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
    }
}

/// The playground window: `.metal` source on the left, a live `LerpMetalView`
/// on the right, and a debounced recompile in between.
///
/// Everything that actually renders comes from LerpCore — `ShaderLibrary` does
/// the runtime compile (same code path as the screensaver) and `LerpMetalView`
/// owns the display link. This class is only the shell around them.
final class PlaygroundWindowController: NSWindowController, NSWindowDelegate {

    /// Outcome of the most recent compile. Drives the status bar and Save Look.
    enum CompileState {
        case pending
        case ok(milliseconds: Double)
        case failed([ShaderDiagnostic])
    }

    let editor = ShaderEditorView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
    private(set) var metalView: LerpMetalView!
    private var compileState: CompileState = .pending
    private var knownShaderNames: [String] = []
    /// The same list as shaders, for the switcher's neighbours and their stills.
    private var knownShaders: [LerpShader] = []

    /// The open shader *as it is on disk*. `editor.text` is the working copy, so
    /// the two differing is exactly what "unsaved changes" means.
    private var current = LerpShader(name: "", source: "", isBuiltIn: false, url: nil)
    /// The preset the open shader is wearing, or nil for its declared defaults.
    /// Set by `applyPreset` — which is where every preset change goes, whatever
    /// asked for it — and cleared by opening a shader.
    private var currentPreset: String?
    /// The open shader *and* the look it is in: a rotation entry, the same pair
    /// the screensaver shuffles over. What the window opened on, and what it
    /// will be remembered as.
    var currentEntry: LerpRotationEntry {
        LerpRotationEntry(shader: current.name, preset: currentPreset)
    }
    private var isDirty: Bool { editor.text != current.source }
    /// The other half of "unsaved": the inspector against what the buffer says
    /// this look *is* — its declared defaults with the worn preset over them.
    ///
    /// A moved slider is an edit to the same file the text is in, because that
    /// is where a look's values live: the `// lerp-preset:` block this look is
    /// wearing. Only `isDirty` existed for a long time, so the one control that
    /// says "there is something to save" was answering a question about the
    /// text while the user was changing the values — Save sat disabled with a
    /// preset visibly modified on screen.
    ///
    /// Measured against `compiled` rather than `current`, because the values on
    /// screen are values *of* the parameters the buffer declares; a slider the
    /// file on disk has never heard of is still a slider that has moved.
    ///
    /// Compared as looks (`rendersSameLook`), so taking control of an animated
    /// parameter is a change, and handing it back undoes the change whatever
    /// the slider was left at.
    private var parametersMoved: Bool {
        guard let compiled, let live = metalView.parameterValues else { return false }
        return !live.rendersSameLook(as: compiled.parameterValues(for: currentEntry))
    }
    /// What Save writes, and therefore what the Save button and ⌘S report. One
    /// predicate so an enabled control and a working command cannot disagree.
    private var hasUnsavedChanges: Bool { isDirty || parametersMoved }
    /// Closing the last window asks first; the automatic app termination that
    /// follows must not ask a second time.
    private var terminationApproved = false
    /// The shader as it was at the last successful compile — i.e. what is on the
    /// GPU, and therefore what the inspector is showing controls for.
    private var compiled: LerpShader?

    private let split = NSSplitViewController()
    /// Opens the shader picker. Where a plain `NSPopUpButton` listing every look
    /// *names* used to be — see `ShaderPicker` for why a grid of stills replaced
    /// it, and for what the dropdown did better and had to be kept.
    /// The selector's button and its ‹ › — see `LookSwitcher`.
    private let switcher = LookSwitcher()
    private let saveButton = NSButton(), revertButton = NSButton()
    private lazy var playButton = PlayerIconButton(symbol: "pause.fill", accessibility: "Pause",
                                                   target: self, action: #selector(togglePlayPause))
    private let status = NSButton()
    private let console = NSTextView()
    private let consoleScroll = NSScrollView()
    private var consoleHeight: NSLayoutConstraint!
    private let fpsLabel = NSTextField(labelWithString: "— fps")
    /// Playback resolution: Low / Med / High under a "Resolution" caption, so
    /// it says what it is choosing rather than showing a bare "Full".
    private let resolutionControl = PlayerSegments(PlaygroundWindowController.renderScales.map(\.title),
                                                   accessibility: "Resolution")
    /// Matches the saver: on by default, at the saver's own peak, and engaged
    /// only where `LerpEDR.blocker` allows, so what you tune here is what the
    /// screensaver will show. A toggle and nothing more — there was a peak
    /// slider beside it, which is not a control anyone reaches for.
    private lazy var edrToggle = PlayerToggle("HDR", target: self, action: #selector(edrChanged))
    /// The render on a whole screen until Esc. Its button is the last thing on
    /// the strip under the picture, where every video player keeps it.
    private var preview: FullScreenPreview!

    let inspector = ParameterPanel(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
    private var inspectorItem: NSSplitViewItem!

    /// Parameter values the user has moved away from the declared defaults.
    /// Held here rather than only in the view because every recompile calls
    /// `setShader`, which resets the view's copy — without this, typing one
    /// character in the editor would snap every slider back.
    private var parameterState: [String: LerpParamValue] = [:]
    /// Which animated parameters the user has taken control of (false) or
    /// handed back (true), for the same reason `parameterState` exists. Only
    /// the *choice* is kept: the drift itself is re-read from the buffer on
    /// every compile, so editing a `// lerp-animate:` line shows at once.
    /// Empty means every parameter does what the worn look says.
    private var animationState: [String: Bool] = [:]
    /// What the inspector currently has controls for.
    private var shownParameters: [LerpParam] = []
    /// What the inspector's preset popup currently lists. Tracked beside the
    /// parameters because the popup is rebuilt from the same call and goes stale
    /// the same way: a shader that gains a preset — by an edit here, by Save
    /// Look as Preset…, or by a `git pull` the disk poll picks up — has to gain
    /// the popup entry, and until this was compared the panel only noticed
    /// changes to `// lerp-param:` lines.
    private var shownPresets: [LerpPreset] = []
    private var shownShaderName: String?

    let midi = MIDIController()
    private let router = MIDIRouter()
    private var mappings: [MappingPreset] = []
    private var activeMapping: MappingPreset?
    /// The whole of MIDI learn: when this is set, the next inbound CC binds
    /// itself to that parameter instead of being routed. The component is the
    /// axis to bind on a colour, and nil on everything else.
    private var learnTarget: (param: String, component: ColorComponent?)?

    /// The view owns the play/pause state; keeping a copy here is how the two
    /// drift apart.
    private var isPaused: Bool { !metalView.isRunning }
    private var lastCompiledSource: String?
    private var firstErrorLine: Int?
    private var compileWork: DispatchWorkItem?
    private var timers: [Timer] = []
    /// The `SystemAudioTap` feeding the `audio*` uniforms, while Shader › React
    /// to System Audio is on. Typed loosely only because the class is 14.2+.
    /// Off at every launch and never persisted: listening to what the Mac is
    /// playing is something you turn on, each time.
    private var audioTap: AnyObject?
    /// The camera feeding `u.viewer`, while Shader › Track Head with Camera is
    /// on. Off at every launch and never persisted, like `audioTap`.
    private var headTracker: HeadTracker?
    /// The camera, while Shader › MIDI › Control with Hands is on. Off at every
    /// launch for the same reason as system audio. Its gestures arrive as CCs
    /// through `receive`, exactly like a knob's.
    private var hands: HandControl?
    /// Drag, pinch and scroll on the render, for looks that declare
    /// `yaw`/`pitch`/`magnify`.
    private var gestures: RenderGestures!

    private static let windowAutosave = "LerpPlaygroundWindow"
    /// Bumped when the inspector added a third pane: an autosaved two-subview
    /// layout cannot describe the new one.
    private static let splitAutosave = "LerpPlaygroundSplit3"

    // MARK: - Init

    /// Capture mode builds a real laid-out window without showing or saving it.
    private let hidden: Bool

    /// Returns nil when there is no Metal device to render with.
    static func make(hidden: Bool = false) -> PlaygroundWindowController? {
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 760, height: 760),
                                       extraSearchURLs: RepoLocation.searchURLs)
        else { return nil }
        return PlaygroundWindowController(metalView: view, hidden: hidden,
                                          rotationDefaults: RotationStore.saverDefaults())
    }

    private init(metalView view: LerpMetalView, hidden: Bool, rotationDefaults: UserDefaults?) {
        metalView = view
        self.hidden = hidden
        self.rotationDefaults = rotationDefaults
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 500)
        super.init(window: window)
        window.delegate = self
        if hidden { window.hideForCapture() }

        buildUI()
        startMIDI()
        let shaders = refreshList(metalView.shaderLibrary.discover())
        if let entry = openingEntry(among: shaders), let shader = shaders.named(entry.shader) {
            open(shader, preset: entry.preset)
        } else {
            setStatus("No shaders found. Use New… to create one.", tint: EditorTheme.error)
        }
        startTimers()
        NotificationCenter.default.addObserver(self, selector: #selector(rotationChangedElsewhere(_:)),
                                               name: RotationStore.changedElsewhere, object: nil)

        // Assigning contentViewController resizes the window to the split view's
        // fitting size, so pick the real size afterwards. Clamped to the screen
        // so this is sane on a laptop display too.
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setContentSize(NSSize(width: min(1500, visible.width - 40),
                                     height: min(920, visible.height - 40)))
        window.center()
        if !hidden { window.setFrameAutosaveName(Self.windowAutosave) }
    }

    required init?(coder: NSCoder) { nil }

    deinit { timers.forEach { $0.invalidate() } }

    // MARK: - UI construction

    private func buildUI() {
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = hidden ? nil : Self.splitAutosave

        for (view, minimum) in [(editorPane(), 340.0), (renderPane(), 280.0), (inspectorPane(), 296.0)] {
            let controller = NSViewController()
            controller.view = view
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = minimum
            split.addSplitViewItem(item)
        }
        // The inspector keeps its width when the window resizes, and folds away
        // entirely for anyone who only wants the editor and the render.
        inspectorItem = split.splitViewItems[2]
        inspectorItem.canCollapse = true
        inspectorItem.maximumThickness = 460
        inspectorItem.holdingPriority = .init(260)
        window?.contentViewController = split
    }

    private func editorPane() -> NSView {
        switcher.current.target = self
        switcher.current.action = #selector(showShaderPicker)
        switcher.current.toolTip = "Shaders (⌘O)"
        switcher.current.identifier = NSUserInterfaceItemIdentifier("shader-picker-button")
        // The name and preset can both be long, so the switcher gives way
        // rather than pushing Save and Revert off the bar.
        switcher.current.setContentHuggingPriority(.defaultLow, for: .horizontal)
        switcher.current.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        switcher.setContentHuggingPriority(.defaultLow, for: .horizontal)
        switcher.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        switcher.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        switcher.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true

        // The selector's cards, one step at a time, without opening it — the
        // same ⇧⌘[ / ⇧⌘] the Shader menu carries, so an arrow opens a shader by
        // exactly the path a click on its card takes.
        //
        // Shaders, not presets. Presets have their own control — the inspector's
        // Presets list, and ⌥⌘[ / ⌥⌘] — so the arrows no longer have to walk all
        // ~280 shader×preset pairs to reach the next shader.
        switcher.previous.target = self
        switcher.previous.action = #selector(previousShader)
        switcher.next.target = self
        switcher.next.action = #selector(nextShader)

        // No New… here any more: making a shader is something you do *among the
        // looks*, so it is the first card in the picker's grid — where you are
        // already looking when you want one that does not exist yet. File → New
        // Shader… (⌘N) is unchanged.
        Chrome.configure(saveButton, title: "Save", target: self, action: #selector(saveShader))
        saveButton.toolTip = "Save (⌘S)"
        Chrome.configure(revertButton, title: "Revert", target: self, action: #selector(revertShader))
        revertButton.toolTip = "Discard changes"

        status.isBordered = false
        status.target = self
        status.action = #selector(jumpToFirstError)
        status.cell?.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setStatus("Ready", tint: EditorTheme.dim)

        console.isEditable = false
        console.drawsBackground = true
        console.backgroundColor = NSColor(srgbRed: 0.145, green: 0.078, blue: 0.086, alpha: 1)
        console.textColor = NSColor(srgbRed: 1.0, green: 0.706, blue: 0.694, alpha: 1)
        console.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        console.textContainerInset = NSSize(width: 8, height: 6)
        consoleScroll.documentView = console
        consoleScroll.hasVerticalScroller = true
        consoleScroll.drawsBackground = true
        consoleScroll.backgroundColor = console.backgroundColor
        consoleScroll.borderType = .noBorder
        consoleHeight = consoleScroll.heightAnchor.constraint(equalToConstant: 0)
        consoleHeight.isActive = true

        editor.onEdit = { [weak self] in self?.scheduleCompile() }
        editor.setContentHuggingPriority(.init(1), for: .vertical)

        return Chrome.pane([Chrome.bar([switcher,
                                        saveButton, revertButton,
                                        Chrome.flexible()]),
                            editor,
                            Chrome.bar([status, Chrome.flexible()], height: 22),
                            consoleScroll])
    }

    /// The picture, then one strip under it: play / pause and the frame rate on
    /// the left; resolution, HDR and full screen on the right. Every control in
    /// it is one family (`PlayerBar.swift`) — round or pill, the same height,
    /// the same fill — and the pixel size and EDR headroom readouts are gone:
    /// the frame rate is the one number worth watching while you work.
    ///
    /// There used to be a strip above the picture holding a Seed button, an
    /// unlabelled 100/75/50/25% menu, the HDR box and an HDR peak slider. Seed
    /// became Randomize on the inspector's Parameters heading, next to the
    /// values it changes; the peak slider is gone; the menu came down here,
    /// reading Full / 1/2 / 1/4 like Premiere's rather than 100% / 75%.
    private func renderPane() -> NSView {
        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        fpsLabel.textColor = InspectorStyle.heading
        fpsLabel.toolTip = "Frame rate"
        fpsLabel.lineBreakMode = .byTruncatingTail
        fpsLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        resolutionControl.target = self
        resolutionControl.action = #selector(resolutionChanged)
        resolutionControl.select(Self.renderScales.firstIndex { $0.scale == 1 } ?? 0)
        resolutionControl.toolTip = "Lower resolution draws fewer pixels for a smoother frame rate"
        let resolutionCaption = PlayerStyle.caption("Resolution")

        edrToggle.state = .on
        edrToggle.toolTip = "Brighter highlights on an HDR screen, as the screensaver shows them"

        // As fast as the screen goes, like any other app: 120 on a ProMotion
        // panel, 60 on a 60 Hz one (the display link never exceeds the panel).
        // It used to ask for 60, the screensaver's rate, which held the editor
        // to half speed on the screen it is mostly used on. A look too heavy
        // for the panel's rate is still paced down to a clean divisor of it.
        metalView.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: 120,
                                                renderScale: 1.0, shuffleInterval: .infinity)
        // The view keeps two drawables, sized for the screensaver at 30–60 fps
        // where a third was only memory. At 120 fps a second frame in flight
        // is the normal case, and two would make the CPU wait on the display;
        // three is Core Animation's own default.
        (metalView.layer as? CAMetalLayer)?.maximumDrawableCount = 3
        metalView.config.extendedDynamicRange = true
        metalView.onCompileError = { name, message in
            FileHandle.standardError.write(Data("compile error in \(name):\n\(message)\n".utf8))
        }
        preview = FullScreenPreview(view: metalView)
        gestures = RenderGestures(view: metalView)
        gestures.accepts = { [weak self] name in
            guard let self else { return false }
            return LerpTurn.parameter(name, in: shownParameters) != nil
        }
        gestures.onMove = { [weak self] moves in self?.nudge(moves) }
        preview.stage.setContentHuggingPriority(.init(1), for: .vertical)
        preview.onChange = { [weak self] in
            guard let self, isPaused else { return }
            metalView.renderOnce()
        }
        let fullScreen = PlayerIconButton(symbol: "arrow.up.left.and.arrow.down.right",
                                          accessibility: "Preview Full Screen", pointSize: 10,
                                          target: self, action: #selector(togglePreview(_:)))
        fullScreen.toolTip = "Full screen (⌃⌘F)"
        playButton.toolTip = "Play / Pause (⌘\\)"

        // Play / Pause is the only control over time. There used to be a
        // one-minute scrubber, a typed clock, minute-paging arrows and a
        // "0:00–1:00" label; nobody needs to seek a screensaver.
        return Chrome.pane([preview.stage,
                            playerBar([playButton, gap(4), fpsLabel, Chrome.flexible(),
                                       resolutionCaption, resolutionControl, gap(6),
                                       edrToggle, fullScreen])])
    }

    /// The parameter controls, driven entirely by callbacks, so they know
    /// nothing of the metal view or the shader library. MIDI has no strip of
    /// its own here: Learn is each row's right-click menu, a bound row shows
    /// its CC, and banks live in Shader › MIDI.
    private func inspectorPane() -> NSView {
        inspector.onChange = { [weak self] name, value in self?.setParameter(name, value) }
        inspector.onPreset = { [weak self] name in self?.applyPreset(name) }
        inspector.onSavePreset = { [weak self] in self?.savePreset(nil) }
        inspector.onRandomize = { [weak self] in self?.randomizeParameters(nil) }
        inspector.onAnimate = { [weak self] name, on in self?.setAnimating(name, on) }
        inspector.onMIDICommand = { [weak self] name, component, command in
            self?.midiCommand(name, component, command)
        }
        inspector.setContentHuggingPriority(.init(1), for: .vertical)
        return Chrome.pane([inspector])
    }

    // MARK: - Shader list

    /// Takes note of what is on disk, and refreshes the picker if it happens to
    /// be open. Never changes what is in the editor.
    @discardableResult
    private func refreshList(_ shaders: [LerpShader]) -> [LerpShader] {
        knownShaderNames = shaders.map(\.name)
        knownShaders = shaders
        // Read off the discovered list rather than off `current`, because
        // `saveShader` rebuilds the open shader as `isBuiltIn: false` whether or
        // not it came from the drop folder — so `current` is not a witness to
        // where the file lives, and the directory it was found in is.
        customShaderNames = Set(shaders.filter { !$0.isBuiltIn }.map(\.name))
        updateShaderButton()
        if let picker, picker.isShown { loadPicker(picker, shaders: shaders) }
        return shaders
    }

    private var customShaderNames: Set<String> = []

    /// The switcher says which shader is open, which of its presets it is
    /// wearing and where it sits in the list, with pictures of it and of the
    /// shaders either side. Cheap to call on every keystroke: nothing is
    /// recomputed unless one of the things it shows has changed.
    private func updateShaderButton() {
        let custom = customShaderNames.contains(current.name)
        let stamp = [current.name, currentPreset ?? "\u{2}", "\(isDirty)", "\(custom)",
                     "\(stillsArrived)"].joined(separator: "\u{1}")
            + knownShaderNames.joined(separator: ",")
        guard stamp != switcherStamp else { return }
        switcherStamp = stamp

        let names = knownShaderNames
        let index = names.firstIndex(of: current.name)
        let hasPresets = !(compiled ?? current).presets.isEmpty
        let look = LookSwitcher.Look(
            name: current.name.isEmpty ? "Shader" : current.name,
            preset: hasPresets ? currentPreset ?? LerpRotationEntry.defaultsName : nil,
            position: index.map { "\($0 + 1) of \(names.count)" } ?? "",
            isCustom: custom, isEdited: isDirty)
        // The preset's own still when there is one, else the shader's cover:
        // the selector only renders covers until its cards are opened up.
        let cover = [current].rotationEntries().first
        switcher.show(look, still: still(for: currentEntry, source: current.source)
                          ?? cover.flatMap { still(for: $0, source: current.source) })

        for (button, offset) in [(switcher.previous, -1), (switcher.next, 1)] {
            let name = names.count > 1
                ? ShaderLibrary.step(in: names, after: current.name, offset: offset) : nil
            let shader = name.flatMap { knownShaders.named($0) }
            button.neighbour = name
            button.isEnabled = name != nil
            button.still = shader.flatMap { shader in
                [shader].rotationEntries().first.flatMap { still(for: $0, source: shader.source) }
            }
            button.toolTip = name.map { (offset < 0 ? "Previous: " : "Next: ") + $0
                + (offset < 0 ? " (⇧⌘[)" : " (⇧⌘])") }
        }
    }

    private var switcherStamp = ""

    // MARK: - Switcher stills

    /// The switcher's pictures: the selector's own stills, decoded off the main
    /// thread the first time each is wanted. A look with none on disk yet
    /// (a new or just-edited shader) draws a placeholder until the selector
    /// has rendered it.
    private var stills: [String: NSImage] = [:]
    private var stillsPending: Set<String> = []
    /// Bumped when a still lands, so `updateShaderButton` redraws for it.
    private var stillsArrived = 0

    private func still(for entry: LerpRotationEntry, source: String) -> NSImage? {
        let thumbnails = self.thumbnails
        let key = thumbnails.key(entry: entry, source: source)
        if let image = stills[key] ?? thumbnails.image(entry: entry, source: source) { return image }
        guard !stillsPending.contains(key) else { return nil }
        stillsPending.insert(key)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = thumbnails.existingURL(entry: entry, source: source)
                .flatMap(RotationThumbnails.decodedImage(at:))
            DispatchQueue.main.async {
                guard let self, let image else { return }
                // Three are on screen at a time. Walking the whole list should
                // not keep seventy decoded stills alive.
                if self.stills.count > 24 { self.stills.removeAll() }
                self.stills[key] = image
                self.stillsPending.remove(key)
                self.stillsArrived += 1
                self.updateShaderButton()
            }
        }
        return nil
    }

    /// What this window opens on, and the only place the screensaver's rotation
    /// is read. Read-only: nothing on this path writes the saver's domain.
    ///
    /// The compile probe is memoised per shader because a rotation is
    /// (shader, preset) pairs — `swirl` and `swirl/Candy` are one compile, and
    /// a shader with five presets would otherwise be built five times over on
    /// the walk. `pipeline(for:)` caches its successes, so the winner is
    /// compiled once here and once more by `open`, which clears the cache first
    /// to keep hot reload from growing it.
    private func openingEntry(among shaders: [LerpShader]) -> LerpRotationEntry? {
        var verdicts: [String: Bool] = [:]
        let library = metalView.shaderLibrary
        func opens(_ entry: LerpRotationEntry) -> Bool {
            if let known = verdicts[entry.shader] { return known }
            let verdict = shaders.named(entry.shader)
                .map { (try? library.pipeline(for: $0)) != nil } ?? false
            verdicts[entry.shader] = verdict
            return verdict
        }
        return OpeningShader.choose(discovered: shaders, rotation: rotationDefaults,
                                    remembered: OpeningShader.remembered(), opens: opens)
    }

    /// Opens a shader, optionally wearing one of its presets — i.e. opens a
    /// rotation entry, which is what the screensaver shuffles over and what
    /// `openingEntry` hands back.
    ///
    /// The preset goes on through the inspector's own popup rather than straight
    /// into the view, so the control says what the render is doing. A preset the
    /// file no longer declares is simply not applied: the shader's defaults are
    /// a look in their own right, not a failure.
    private func open(_ shader: LerpShader, preset: String? = nil) {
        current = shader
        parameterState.removeAll()      // a new shader starts at its own defaults
        animationState.removeAll()
        currentPreset = nil
        editor.setText(shader.source)
        metalView.config.shaderName = shader.name
        compileNow(force: true)
        if let wanted = preset, let declared = shader.preset(named: wanted),
           compiled?.name == shader.name {
            inspector.choosePreset(declared.name)
        }
        updateChrome()
        rememberCurrent()
        showCurrentEverywhere()
    }

    /// The selector marks the shader the editor has open, so "where am I in
    /// these pictures" is answerable without reading captions; the Presets list
    /// marks the preset.
    private func showCurrentEverywhere() {
        picker?.gallery.showCurrent(currentEntry)
        inspector.showPreset(currentPreset)
    }

    /// Opens a (shader, preset) pair: a card in the selector, an arrow, or the
    /// launch path's choice. The same `open` the launch path takes, plus the
    /// unsaved-changes prompt and bringing the editor back to the front.
    func openEntry(_ entry: LerpRotationEntry) {
        guard entry != currentEntry else { return raise() }
        guard confirmDiscardIfDirty(),
              let shader = metalView.shaderLibrary.shader(named: entry.shader) else { return }
        open(shader, preset: entry.preset)
        raise()
    }

    /// Records the look on screen as where to come back to. The playground's own
    /// preferences — never the screensaver's.
    private func rememberCurrent() {
        guard !current.name.isEmpty else { return }
        OpeningShader.remember(currentEntry)
    }

    // MARK: - Compilation / hot reload

    private func scheduleCompile() {
        updateChrome()
        compileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.compileNow() }
        compileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Compiles the editor buffer and swaps the live pipeline. On failure the
    /// previously compiled pipeline stays bound, so the render pane keeps
    /// running the last good version of the shader.
    private func compileNow(force: Bool = false) {
        guard !current.name.isEmpty else { return }
        let source = editor.text
        guard force || source != lastCompiledSource else { return }
        lastCompiledSource = source

        let library = metalView.shaderLibrary
        // The cache is keyed on source, so hot reload would grow it without
        // bound; we only ever need the one pipeline that is on screen.
        library.clearPipelineCache()

        let draft = LerpShader(name: current.name, source: source, isBuiltIn: false, url: current.url)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            // Compile *before* handing the shader to the view: a throw here
            // leaves the view's existing pipeline untouched.
            _ = try library.pipeline(for: draft, pixelFormat: metalView.shaderPixelFormat)
            metalView.setShader(draft)         // cache hit, cannot fail
            compiled = draft
            syncParameters(draft)
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            compileState = .ok(milliseconds: ms)
            firstErrorLine = nil
            editor.setErrorLines([])
            setConsole("")
            setStatus(String(format: "✓  compiled in %.0f ms", ms),
                      tint: NSColor(srgbRed: 0.42, green: 0.84, blue: 0.55, alpha: 1))
        } catch {
            let (items, raw) = ShaderDiagnostics.parse(error)
            compileState = .failed(items)
            let lines = items.filter(\.isError).map(\.line)
            firstErrorLine = lines.min()
            editor.setErrorLines(Set(lines))
            setConsole(ShaderDiagnostics.summary(items: items, raw: raw))
            let count = max(lines.count, 1)
            setStatus("✗  \(count) error\(count == 1 ? "" : "s") — last good shader still running"
                        + (firstErrorLine != nil ? "  (click to jump)" : ""),
                      tint: EditorTheme.error)
        }
        if isPaused { metalView.renderOnce() }
    }

    /// Shows the diagnostics console, or collapses it when `text` is empty.
    private func setConsole(_ text: String) {
        console.string = text
        consoleHeight.constant = text.isEmpty ? 0 : 132
    }

    private func setStatus(_ text: String, tint: NSColor) {
        status.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: tint,
                         .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)])
    }

    // MARK: - Parameters

    /// Brings the inspector and the live values in step with what just compiled.
    /// `setShader` has already reset the view to the shader's declared defaults,
    /// so anything the user moved is pushed back in here.
    private func syncParameters(_ shader: LerpShader) {
        if shader.name != shownShaderName || shader.parameters != shownParameters
            || shader.presets != shownPresets {
            shownShaderName = shader.name
            shownParameters = shader.parameters
            shownPresets = shader.presets
            let declared = Set(shader.parameters.map(\.name))
            parameterState = parameterState.filter { declared.contains($0.key) }
            animationState = animationState.filter { declared.contains($0.key) }
            inspector.rebuild(shader: shader)
            // A rebuild marks "Defaults"; the preset on screen has not changed,
            // so put the mark back on it rather than letting the one control
            // that names the preset be the one that lies about it.
            inspector.showPreset(currentPreset)
            inspector.showsMIDIControls = midi.isAvailable
            refreshBindingLabels()
        }
        for (name, value) in parameterState { metalView.setParameter(name, value) }
        // Pushing the values back pinned every animated one (a set value is a
        // held value), and `setShader` dropped the worn preset's own drifts.
        // Both come back from the buffer — the look's drift, as the text now
        // declares it — and then the user's own take-control choices on top.
        let look = shader.parameterValues(for: currentEntry)
        for (name, animation) in look.animations {
            metalView.animateParameter(name, with: animation)
            metalView.setParameterAnimating(name, animationState[name] ?? look.isAnimating(name))
        }
        inspector.show(values: metalView.liveParameterValues)
    }

    /// The one place a parameter changes, whatever moved it — mouse, typed
    /// number, preset or knob. On a parameter that is animating this takes
    /// control of it: the drift stops for it until its toggle hands it back.
    func setParameter(_ name: String, _ value: LerpParamValue) {
        parameterState[name] = value
        metalView.setParameter(name, value)
        if metalView.parameterValues?.animations[name] != nil {
            animationState[name] = false
            inspector.show(values: metalView.liveParameterValues)
        }
        // A moved value is an unsaved change to the look, so Save has to light
        // up on it exactly as it does on a keystroke in the editor.
        updateChrome()
        if isPaused { metalView.renderOnce() }
    }

    /// A gesture on the render: moves each named parameter by its delta
    /// exactly as its slider would. One the look does not declare is simply
    /// not moved — a look with only `yaw` spins on a fixed horizon.
    private func nudge(_ moves: [(parameter: String, delta: Double)]) {
        for (name, delta) in moves {
            guard delta != 0, let param = LerpTurn.parameter(name, in: shownParameters),
                  let now = currentValue(of: param).scalarValue else { continue }
            setParameter(name, .scalar(LerpTurn.moved(param, from: now, by: delta)))
        }
        inspector.show(values: metalView.liveParameterValues)
    }

    /// The Parameters heading's Randomize, and Shader → Randomize Parameters:
    /// every held parameter to a uniformly random value in its declared range.
    ///
    /// A parameter that is drifting is left drifting — its own curve is already
    /// moving it, and taking control of every one would freeze a look that is
    /// meant to move. Colours keep their alpha. Like any moved value this is an
    /// unsaved change to the look; Save or "+" keeps it, Revert drops it.
    @objc func randomizeParameters(_ sender: Any?) {
        guard let values = metalView.parameterValues, !inspector.parameters.isEmpty else {
            return NSSound.beep()
        }
        var moved = 0
        for param in inspector.parameters where !values.isAnimating(param.name) {
            let value: LerpParamValue
            switch param.type {
            case .float:
                value = .scalar(param.max > param.min ? .random(in: param.min...param.max) : param.min)
            case .int:
                let low = Int(param.min.rounded(.up)), high = Int(param.max.rounded(.down))
                value = .scalar(Double(high > low ? .random(in: low...high) : low))
            case .bool:
                value = .scalar(Bool.random() ? 1 : 0)
            case .color:
                let alpha = values[param.name]?.colorValue?.w ?? param.defaultValue.colorValue?.w ?? 1
                value = .color(SIMD4<Float>(.random(in: 0...1), .random(in: 0...1),
                                            .random(in: 0...1), alpha))
            }
            let clamped = param.clamp(value)
            parameterState[param.name] = clamped
            metalView.setParameter(param.name, clamped)
            moved += 1
        }
        guard moved > 0 else {
            NSSound.beep()
            return setStatus("Every parameter is drifting", tint: EditorTheme.dim)
        }
        inspector.show(values: metalView.liveParameterValues)
        updateChrome()
        if isPaused { metalView.renderOnce() }
    }

    /// The inspector's animation toggle. Holding a parameter holds it where
    /// it is on screen *now* — the value on its curve, not the declared
    /// default it was drifting away from — so nothing jumps.
    func setAnimating(_ name: String, _ on: Bool) {
        if on {
            metalView.setParameterAnimating(name, true)
        } else if let here = metalView.liveParameterValues?[name] {
            parameterState[name] = here
            metalView.setParameter(name, here)
        }
        animationState[name] = on
        inspector.show(values: metalView.liveParameterValues)
        updateChrome()
        if isPaused { metalView.renderOnce() }
    }

    /// nil applies the shader's declared defaults.
    func applyPreset(_ name: String?) {
        defer {
            rememberCurrent()
            updateChrome()
            showCurrentEverywhere()
        }
        guard let shader = compiled else { return }
        let preset = name.flatMap { shader.preset(named: $0) }
        let entry = LerpRotationEntry(shader: shader.name, preset: preset?.name)
        guard metalView.show(entry, of: shader) else { return }
        currentPreset = preset?.name
        adoptViewValues()
    }

    /// Takes whatever the view now holds as the user's chosen state.
    private func adoptViewValues() {
        parameterState = metalView.parameterValues?.values ?? [:]
        animationState.removeAll()      // the look's own drifts, untouched
        inspector.show(values: metalView.liveParameterValues)
        if isPaused { metalView.renderOnce() }
    }

    // MARK: - MIDI

    private func startMIDI() {
        midi.onSourcesChanged = { [weak self] in self?.midiSourcesChanged() }
        midi.onMessage = { [weak self] message in self?.receive(message) }
        midi.start()
        mappings = MIDIMappingStore.load()
        activeMapping = mappings.first
        router.load(activeMapping?.bindings ?? [])
        inspector.showsMIDIControls = midi.isAvailable
        midiSourcesChanged()
        NSApp.mainMenu?.items.lazy.compactMap(\.submenu)
            .compactMap { $0.items.first { $0.identifier == MainMenu.midiMenuID } }
            .first?.submenu?.delegate = self
    }

    /// A device appeared or went away. Auto-select the bank that was made for
    /// it, which is the whole point of storing the device ID in the preset.
    private func midiSourcesChanged() {
        if let match = mappings.first(where: { preset in
            !preset.deviceID.isEmpty && midi.sources.contains { $0.id == preset.deviceID }
        }), match.name != activeMapping?.name {
            select(mapping: match.name)
        }
    }

    /// Adds an empty mapping bank and makes it live.
    func createMapping(named name: String, deviceID: String) {
        commit(MappingPreset(name: name, deviceID: deviceID))
    }

    /// Bank names have to stay tellable apart in the popup, so "My Bank" and
    /// "my bank" are refused rather than allowed to exist side by side looking
    /// like a duplicate. (Banks copied in by hand can still collide on the
    /// *file* name; `MIDIMappingStore` disambiguates that end.)
    private func claimBankName(_ name: String, excluding: String? = nil) -> Bool {
        guard MIDIMappingStore.nameIsTaken(name, in: mappings, excluding: excluding) else { return true }
        presentError("A mapping called “\(name)” already exists",
                     "Mapping names have to differ by more than capitalisation. Pick another.")
        return false
    }

    private func select(mapping name: String) {
        guard let preset = mappings.first(where: { $0.name == name }) else { return }
        activeMapping = preset
        router.load(preset.bindings)     // switching banks is exactly this
        refreshMappingUI()
    }

    private func refreshBindingLabels() {
        for param in shownParameters {
            inspector.setBinding(activeMapping?.bindings(for: param.name) ?? [], for: param.name)
        }
    }

    /// The bank list and device line are Shader › MIDI, which is built when
    /// it opens; the binding tags on the rows are all there is to redraw.
    private func refreshMappingUI() {
        refreshBindingLabels()
    }

    /// Saves `preset`, makes it live and redraws everything that shows it.
    private func commit(_ preset: MappingPreset) {
        if let index = mappings.firstIndex(where: { $0.name == preset.name }) {
            mappings[index] = preset
        } else {
            mappings.append(preset)
        }
        activeMapping = preset
        router.load(preset.bindings)
        do {
            try MIDIMappingStore.save(preset)
        } catch {
            setStatus("Could not save mapping: \(error.localizedDescription)", tint: EditorTheme.error)
        }
        refreshMappingUI()
    }

    func receive(_ message: MIDIController.Message) {
        if let target = learnTarget {
            learnTarget = nil
            var preset = activeMapping
                ?? MappingPreset(name: message.sourceName.isEmpty ? "Default" : message.sourceName,
                                 deviceID: message.sourceID)
            let component = learnComponent(target)
            // Omni by default: most controllers sit on a channel the user has
            // never chosen, and a binding that only works on one is a trap.
            // A source with a channel of its own (hands) says so in the message.
            let binding = MIDIBinding(paramID: target.param, channel: message.learnChannel,
                                      cc: message.cc, mode: message.learnMode, component: component)
            preset.bind(binding)
            commit(preset)
            setStatus("Learned \(binding.shortLabel) → \(target.param)", tint: EditorTheme.text)
            return
        }
        guard let routed = router.route(channel: message.channel, cc: message.cc, value: message.value),
              let param = shownParameters.first(where: { $0.name == routed.binding.paramID }),
              let value = resolve(routed.update, for: param, binding: routed.binding) else {
            // Only while no hand axis is bound at all: with Y bound, a drag's
            // sideways ticks would otherwise flash this over every Y update.
            if message.sourceID == HandControl.sourceID,
               activeMapping?.bindings.contains(where: { HandControl.Axis(channel: $0.channel, cc: $0.cc) != nil }) != true {
                setStatus("\(HandControl.Axis(channel: message.channel, cc: message.cc)?.label ?? "Hand") "
                          + "is not bound here — right-click a parameter, Learn…, then pinch and move",
                          tint: EditorTheme.dim)
            }
            return
        }
        // A knob is a hand on the control: bound to an animated parameter, it
        // takes control of it exactly as dragging the slider does.
        // No status echo per tick: the slider moving is the readout, and the
        // status line is where compile results are read.
        setParameter(param.name, value)
        inspector.show(values: metalView.liveParameterValues)
    }

    /// The axis a Learn binds. The menu says which one when the user picked it
    /// from a colour's submenu; when it did not — a scalar, or a colour learned
    /// from somewhere that has no opinion — the colour's own content decides,
    /// so a near-black background gets the axis that has range on it.
    private func learnComponent(_ target: (param: String, component: ColorComponent?)) -> ColorComponent? {
        if let component = target.component { return component }
        guard let param = shownParameters.first(where: { $0.name == target.param }),
              param.type == .color else { return nil }
        return ColorProjection.defaultComponent(for: currentColor(of: param))
    }

    private func currentColor(of param: LerpParam) -> SIMD4<Float> {
        currentValue(of: param).colorValue
            ?? param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1)
    }

    /// What `param` is on screen now — for an animating parameter, its place
    /// on the curve, so a relative knob or a toggle picks up from where the
    /// drift had taken it instead of jumping back to the held value.
    private func currentValue(of param: LerpParam) -> LerpParamValue {
        metalView.liveParameterValues?[param.name] ?? parameterState[param.name] ?? param.defaultValue
    }

    /// Turns "the knob did this" into a value for this particular parameter.
    ///
    /// Colours and scalars take the same three shapes of update and the same
    /// range scoping; all that differs is what a "position" means once it has
    /// been mapped into the binding's slice of the travel.
    private func resolve(_ update: MIDIRouter.Update, for param: LerpParam,
                         binding: MIDIBinding) -> LerpParamValue? {
        let low = Double(binding.range.lowerBound), high = Double(binding.range.upperBound)
        guard param.type != .color else {
            let component = binding.component ?? .hue
            let base = param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1)
            let current = currentColor(of: param)
            let position: Double
            switch update {
            case .absolute(let p):
                position = low + p * (high - low)
            case .delta(let ticks):
                let here = ColorProjection.position(of: component, in: current, base: base)
                position = min(max(here + Double(ticks) * (high - low) / 128, low), high)
            case .toggle:
                let here = ColorProjection.position(of: component, in: current, base: base)
                position = here > (low + high) / 2 ? low : high
            }
            return param.clamp(.color(ColorProjection.apply(component, position: position,
                                                            to: current, base: base)))
        }
        let current = currentValue(of: param).scalarValue ?? 0
        let span = param.max - param.min
        let scaledLow = param.min + low * span, scaledHigh = param.min + high * span
        switch update {
        case .absolute(let position):
            return param.clamp(.scalar(scaledLow + position * (scaledHigh - scaledLow)))
        case .delta(let ticks):
            // One tick is one step for an int, and 1/128 of the travel for a
            // float — the resolution an absolute knob would have given.
            let step = param.type == .float ? (scaledHigh - scaledLow) / 128 : 1
            return param.clamp(.scalar(current + Double(ticks) * step))
        case .toggle:
            return param.clamp(.scalar(current > (scaledLow + scaledHigh) / 2 ? scaledLow : scaledHigh))
        }
    }

    func midiCommand(_ name: String, _ component: ColorComponent?,
                     _ command: ParameterPanel.MIDICommand) {
        switch command {
        case .learn:
            // Arming the same axis twice disarms it, so a Learn started by
            // accident does not sit there waiting to eat the next knob.
            let armed = learnTarget?.param == name && learnTarget?.component == component
            learnTarget = armed ? nil : (name, component)
            setStatus(learnTarget == nil
                ? "Learn cancelled"
                : "Learning \(name)\(component.map { " \($0.label)" } ?? "")"
                    + (hands == nil ? " — move a knob" : " — move a knob, or pinch and move a hand"),
                      tint: EditorTheme.text)
        case .clear:
            guard var preset = activeMapping else { return }
            preset.unbind(name, component: component)
            commit(preset)
        case .clearAll:
            guard var preset = activeMapping else { return }
            preset.unbind(name)
            commit(preset)
        case .mode(let mode):
            guard var preset = activeMapping,
                  let binding = preset.binding(for: name, component: component) else { return }
            guard let updated = binding.withMode(mode) else {
                setStatus("14-bit needs CC 0–31, not \(binding.shortLabel)", tint: EditorTheme.error)
                return
            }
            preset.bind(updated)
            commit(preset)
        case .range:
            guard var preset = activeMapping,
                  let binding = preset.binding(for: name, component: component),
                  let scoped = promptForRange(binding) else { return }
            preset.bind(scoped)
            commit(preset)
            setStatus(String(format: "%@ → %@ over %.2f–%.2f", binding.shortLabel, name,
                             scoped.range.lowerBound, scoped.range.upperBound), tint: EditorTheme.dim)
        }
    }

    /// Two fields behind a menu item, rather than two more controls on every
    /// row. Scoping a knob is something you do once per binding and then read
    /// off the menu item's own title, so it does not earn permanent space.
    private func promptForRange(_ binding: MIDIBinding) -> MIDIBinding? {
        let alert = NSAlert()
        alert.messageText = "Knob range for \(binding.shortLabel)"
        alert.informativeText = "The slice of \(binding.paramID)'s range this knob sweeps, "
            + "as fractions of full travel. 0 and 1 is the whole of it."
        let low = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        let high = NSTextField(frame: NSRect(x: 0, y: 0, width: 70, height: 22))
        low.stringValue = String(format: "%g", binding.range.lowerBound)
        high.stringValue = String(format: "%g", binding.range.upperBound)
        let row = NSStackView(views: [Chrome.label("Min", size: 11), low,
                                      Chrome.label("Max", size: 11), high])
        row.spacing = 6
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = row
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Full Travel")
        alert.window.initialFirstResponder = low
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return binding.withRange(low: Float(low.stringValue) ?? binding.range.lowerBound,
                                     high: Float(high.stringValue) ?? binding.range.upperBound)
        case .alertThirdButtonReturn:
            return binding.withRange(low: 0, high: 1)
        default:
            return nil
        }
    }

    /// What Shader › MIDI's bank commands do.
    enum MappingAction: Equatable { case select(String), new, rename, delete }

    private func mappingCommand(_ action: MappingAction) {
        switch action {
        case .select(let name):
            select(mapping: name)
        case .new:
            guard let name = prompt("New mapping", "Name this bank of MIDI mappings.",
                                    midi.sources.first?.name ?? "Mapping"),
                  claimBankName(name) else { return }
            createMapping(named: name, deviceID: midi.sources.first?.id ?? "")
        case .rename:
            guard var preset = activeMapping,
                  let name = prompt("Rename mapping", "Mapping files are named after the mapping.",
                                    preset.name), name != preset.name,
                  claimBankName(name, excluding: preset.name) else { return }
            MIDIMappingStore.delete(preset.name)
            mappings.removeAll { $0.name == preset.name }
            preset.name = name
            commit(preset)
        case .delete:
            guard let preset = activeMapping else { return }
            MIDIMappingStore.delete(preset.name)
            mappings.removeAll { $0.name == preset.name }
            activeMapping = mappings.first
            router.load(activeMapping?.bindings ?? [])
            refreshMappingUI()
        }
    }

    // MARK: - Screensaver rotation

    /// The screensaver's rotation, as this window sees it. Written by the
    /// selector's badges, and *read* by
    /// `openingEntry` on launch, which is the one place this app looks at the
    /// rotation without being asked to.
    var rotationDefaults: UserDefaults?

    /// The toolbar's selector popover, once it has been asked for. Built
    /// lazily: it renders a still per shader, and an app that never opens it
    /// should never pay for them.
    private(set) var picker: ShaderPicker?

    private lazy var thumbnails = RotationThumbnails(searchURLs: RepoLocation.searchURLs)

    /// The selector, built on first use.
    @discardableResult
    func shaderPicker() -> ShaderPicker {
        if let picker { return picker }
        let made = ShaderPicker(thumbnails: thumbnails)
        made.onOpen = { [weak self] entry in self?.openEntry(entry) }
        // The "+" card at the head of the grid. Straight into the same action
        // File → New Shader… (⌘N) sends, unsaved-edits prompt and all: a second
        // way in must not become a second flow, or one of them will be the one
        // that forgets to ask.
        made.onNew = { [weak self] in self?.newShader(nil) }
        made.onChange = { [weak self] selection in self?.persistRotation(selection) }
        picker = made
        return made
    }

    /// The toolbar button, and the Shader menu's Open Shader… item.
    @objc func showShaderPicker(_ sender: Any?) {
        preparePicker().present(from: switcher)
    }

    /// Prepares the picker before putting its popover on screen.
    @discardableResult
    func preparePicker() -> ShaderPicker {
        let picker = shaderPicker()
        loadPicker(picker, shaders: metalView.shaderLibrary.discover())
        return picker
    }

    private func loadPicker(_ picker: ShaderPicker, shaders: [LerpShader]) {
        picker.prepare(shaders: shaders,
                       selection: RotationStore.selection(discovered: shaders.rotationEntries(),
                                                          from: rotationDefaults),
                       current: currentEntry)
    }

    /// What the screensaver plays, read fresh from the store.
    private func storedSelection() -> LerpRotationSelection {
        let entries = metalView.shaderLibrary.discover().rotationEntries()
        return RotationStore.selection(discovered: entries, from: rotationDefaults)
    }

    /// The one place the playground writes the rotation: through
    /// `RotationStore`, into the saver's own ByHost domain, the moment you
    /// click. The selector's badges are the only control that changes it.
    private func persistRotation(_ selection: LerpRotationSelection) {
        RotationStore.save(selection, to: rotationDefaults)
    }

    /// A Shortcuts action wrote the rotation (see `RotationIntents.swift`).
    /// The selector holds the selection in memory, so it is handed what is now
    /// on disk — otherwise its next click would save its stale copy straight
    /// over the action's change.
    @objc private func rotationChangedElsewhere(_ note: Notification) {
        picker?.showSelection(storedSelection())
    }

    /// A shader was saved, or changed on disk. The selector keys its stills on
    /// each shader's source, so handing it the fresh list is all it takes for
    /// the edited shader's card — and only that one — to be drawn again.
    private func refreshRotation(_ shaders: [LerpShader]) {
        if let picker, picker.isShown { loadPicker(picker, shaders: shaders) }
    }

    // MARK: - Actions

    @objc func recompile(_ sender: Any?) { compileNow(force: true) }

    @objc func toggleInspector(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }

    /// Steps to the next bank. The wrap is `ShaderLibrary.step`, which is
    /// where every cycle in this project lives.
    @objc func nextMapping(_ sender: Any?) {
        let names = mappings.map(\.name)
        guard names.count > 1,
              let next = ShaderLibrary.step(in: names, after: activeMapping?.name, offset: 1)
        else { return NSSound.beep() }
        select(mapping: next)
        setStatus("MIDI mapping: \(next)", tint: EditorTheme.dim)
    }

    @objc func newMapping(_ sender: Any?) { mappingCommand(.new) }
    @objc func renameMapping(_ sender: Any?) { mappingCommand(.rename) }
    @objc func deleteMapping(_ sender: Any?) { mappingCommand(.delete) }
    @objc private func chooseMapping(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        mappingCommand(.select(name))
    }

    @objc func jumpToFirstError() {
        if let line = firstErrorLine { editor.scrollToLine(line) }
    }

    /// File → Save (⌘S) and the toolbar's Save button: everything the window is
    /// showing that the file does not yet say.
    ///
    /// That is two kinds of change, because the window makes two kinds — the
    /// text and the values — and they both end up in the same `.metal` file.
    /// Values that have moved away from a preset are that preset's new values,
    /// so Save updates the block in place; the edit goes into the buffer where
    /// it can be read and ⌘Z'd, exactly as Save Look as Preset… does it.
    ///
    /// Save never asks anything. The look on screen has somewhere in the file it
    /// came from and that is where it goes back: a worn preset's block, or —
    /// with nothing worn — the `// lerp-param:` defaults, which are the Defaults
    /// look's values in the same way. Naming a *new* look is Save As, and Save
    /// As is ⇧⌘S.
    @discardableResult
    @objc func saveShader(_ sender: Any?) -> Bool {
        guard parametersMoved else { return writeBuffer() }
        // `liveValues` compiles first, so the look is written back into the text
        // that is about to be saved rather than into whatever the debounce was
        // still holding.
        switch liveValues() {
        case .ready(let overrides):
            guard let worn = currentPreset else { return writeDefaults(overrides) }
            // A preset the buffer has stopped declaring — its block deleted by
            // hand while it is on — is written back rather than lost: the window
            // says that look is open, so Save is what makes the file say it too.
            return writePreset(named: compiled?.preset(named: worn)?.name ?? worn, overrides,
                               replacing: compiled?.preset(named: worn))
        case .unavailable:
            return writeBuffer()
        case .cannot:
            guard writeBuffer() else { return false }
            guard !compileFailed else { return true }   // the console is already saying it
            setStatus("✓  saved", tint: EditorTheme.dim)
            return true
        }
    }

    /// The buffer onto disk, and nothing else. The file half of `saveShader`,
    /// separate because the preset flows write the buffer *after* splicing into
    /// it and must not be handed back to the folding above.
    @discardableResult
    private func writeBuffer() -> Bool {
        let url = ShaderPaths.saveURL(for: current)
        // The file changed on disk while this buffer had edits — a pull, a
        // fast-forward of this checkout, another editor. `pollDisk` will not
        // reload over unsaved edits, so without this ⌘S silently wrote the
        // buffer over whatever had landed.
        if url == current.url,
           let onDisk = try? String(contentsOf: url, encoding: .utf8),
           onDisk != current.source, onDisk != editor.text {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(url.lastPathComponent) changed on disk since you opened it."
            alert.informativeText = "Saving replaces the version on disk with yours."
            alert.addButton(withTitle: "Save Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try editor.text.write(to: url, atomically: true, encoding: .utf8)
            current = LerpShader(name: current.name, source: editor.text, isBuiltIn: false, url: url)
            compileNow(force: true)
            let shaders = refreshList(metalView.shaderLibrary.discover())
            refreshRotation(shaders)
            // Last, not first: "is there anything to save" is asked of the
            // shader that just compiled, and the button's `· custom` tag of the
            // list that was just re-read.
            updateChrome()
            return true
        } catch {
            presentError("Could not save \(url.lastPathComponent)", error.localizedDescription)
            return false
        }
    }

    /// Shader → Save Look as Preset… (⇧⌘S): the values on screen, written back
    /// into the shader file as a named `// lerp-preset:` block. Reusing a name
    /// updates that preset in place.
    ///
    /// ## Why it writes the file, edits and all
    ///
    /// The values on screen belong to the parameters the *editor buffer*
    /// declares, not to the ones the file on disk does. Add a
    /// `// lerp-param: swirl …` line, drag the new slider, and a preset written
    /// into the file alone would say `swirl=0.4` about a parameter that file has
    /// never heard of — which is not a bad preset, it is a `parameterErrors`
    /// entry, and `pipeline(for:)` refuses to compile a shader that has one. The
    /// preset and the edits that justify it are one change, so this splices the
    /// block into the buffer and then goes through `writeBuffer`, the same and
    /// only path that puts a buffer on disk. The prompt says so when there are
    /// unsaved edits; it is not done quietly.
    ///
    /// For the same reason a buffer that does not compile is refused. What is on
    /// screen then is the last pipeline that *did*, so its values are not a
    /// description of what the editor now says, and saving them would write a
    /// preset about a shader nobody has seen render.
    ///
    /// Reusing a name replaces the existing declaration after confirmation. The
    /// rotation entry keeps the same key, so its enabled/disabled choice stays
    /// intact while its values change.
    @objc func savePreset(_ sender: Any?) {
        let overrides: LookOverrides
        switch liveValues() {
        case .ready(let values): overrides = values
        case .unavailable: return NSSound.beep()
        case .cannot(let title, let detail): return presentError(title, detail)
        }
        guard let compiled else { return }

        let detail = isDirty ? "Your code changes will be saved too." : ""
        guard let name = prompt("New Preset", detail, currentPreset ?? "",
                                placeholder: "Lagoon") else { return }
        if let problem = LerpPresetWriter.problem(withName: name) {
            return presentError("“\(name)” cannot be a preset name", problem)
        }
        let clash = compiled.preset(named: name)
        if let clash {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace “\(clash.name)”?"
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        writePreset(named: clash?.name ?? name, overrides, replacing: clash)
    }

    /// What both save commands ask about the look on screen, and the words for
    /// the answer when there is nothing writable to say.
    ///
    /// They differ only in what a refusal costs them. ⇧⌘S is *about* the values,
    /// so it stops and shows the reason. ⌘S also has text to write, and an
    /// editor that will not save your typing because the shader does not compile
    /// yet is an editor with a bug in it — so it writes the text either way and
    /// keeps the reason to a status line.
    /// What the look on screen says that its file does not: held values
    /// (`name=value`, which also pins an animated parameter) and drifts other
    /// than the declared one (`name=animate(…)`). See `LerpPresetWriter`.
    struct LookOverrides {
        var values: [(param: LerpParam, value: LerpParamValue)]
        var animations: [(param: LerpParam, animation: LerpParamAnimation)]
        var count: Int { values.count + animations.count }
        var isEmpty: Bool { values.isEmpty && animations.isEmpty }
    }

    private enum LiveValues {
        case ready(LookOverrides)
        /// The compile on screen is not of the text in the editor: a race, not
        /// a decision anybody made, and nothing worth a sentence.
        case unavailable
        case cannot(title: String, detail: String)
    }

    /// The values on screen as preset assignments, or why they are not a
    /// description of anything.
    ///
    /// The compile in front is what makes the buffer's parameters the ones the
    /// values belong to: whatever the 300 ms debounce is still holding is
    /// compiled now, so `compiled` is the text about to be written.
    private func liveValues() -> LiveValues {
        compileWork?.cancel()
        compileNow()
        if compileFailed {
            return .cannot(title: "\(current.name).metal does not compile",
                           detail: "What is on screen is the last version that did, so its values are "
                               + "not a description of what the editor now says. Fix the errors "
                               + "in the console first — ⌘E jumps to the first one.")
        }
        guard let compiled, compiled.name == current.name, compiled.source == editor.text,
              let values = metalView.parameterValues else { return .unavailable }

        // Both of these would come back from the parser as `preset … sets
        // nothing`, so they are refused here, where the reason can be said in
        // words rather than as a compile error on a line the user never typed.
        let overrides = LookOverrides(values: LerpPresetWriter.overrides(in: values),
                                      animations: LerpPresetWriter.animationOverrides(in: values))
        guard !overrides.isEmpty else {
            if compiled.parameters.isEmpty {
                return .cannot(title: "\(current.name) has no controls to save",
                               detail: "A preset is a set of control values, and this look has no "
                                   + "controls. Add a `// lerp-param:` line to the file to give it one.")
            }
            let axes = LerpTurn.axes(of: compiled.parameters)
            let how = axes.yaw != nil || axes.pitch != nil
                ? "Move a slider in the inspector, or drag the render to turn it"
                : "Move a slider in the inspector"
            return .cannot(title: "Change a control first",
                           detail: "Every control is still at its default, so this preset would be "
                               + "identical to Defaults. \(how), then save again.")
        }
        return .ready(overrides)
    }

    private var compileFailed: Bool {
        if case .failed = compileState { return true }
        return false
    }

    /// The Defaults look, saved: the values on screen become the `= DEFAULT` of
    /// the `// lerp-param:` lines that declare them.
    ///
    /// Which is a real edit to every look in the file — a preset only records
    /// what it *differs* from the defaults in, so moving a default moves every
    /// preset that stays silent about that parameter. That is the same thing
    /// editing the declaration by hand does, and it is what saving the Defaults
    /// look can honestly mean; ⌘Z takes the buffer back.
    ///
    /// The one thing it cannot save is a parameter you took control of from
    /// its `// lerp-animate:`. The Defaults look's drift *is* that line, and
    /// rewriting someone's declarations to delete it is not what Save is for —
    /// so the held value becomes the default and the drift resumes. A preset
    /// (⇧⌘S) is the way to keep it still.
    @discardableResult
    private func writeDefaults(_ overrides: LookOverrides) -> Bool {
        editor.replaceTextAsEdit(ParamScaffold.settingDefaults(overrides.values, in: editor.text))
        guard writeBuffer() else { return false }
        // The round trip in public, as in `writePreset`: the file has been
        // re-read and recompiled, and this puts the freshly declared defaults
        // on screen — so a write that did not take cannot look like one that did.
        applyPreset(nil)
        setStatus("✓  saved", tint: EditorTheme.text)
        return true
    }

    /// Splices `overrides` into the buffer as the preset `name`, saves the file
    /// and puts the window back on that preset. The tail both preset paths
    /// share, so ⌘S over a modified preset and ⇧⌘S write the same block by the
    /// same route and report it in the same words.
    @discardableResult
    private func writePreset(named name: String,
                             _ overrides: LookOverrides,
                             replacing existing: LerpPreset?) -> Bool {
        let declaration = LerpPresetWriter.declaration(name: name, overrides: overrides.values,
                                                       animations: overrides.animations)

        // Reported as an edit rather than pushed in silently: this is exactly
        // the block you would have typed, ⌘Z still undoes it, and the file that
        // gets written is the buffer you can see.
        let updated = existing.map {
            PresetScaffold.replacing($0.name, with: declaration, in: editor.text)
        } ?? PresetScaffold.inserting(declaration, into: editor.text)
        editor.replaceTextAsEdit(updated)
        guard writeBuffer() else { return false }
        // `writeBuffer` has already re-read the directory and recompiled, so
        // the new preset has a row in the Presets list by the time we get
        // here. Wearing it goes through that list like every other preset
        // change — that is what makes `currentPreset`, the toolbar button, the
        // remembered look and the selector's current mark agree — and
        // it is also the round trip proving itself in public: `writeBuffer`
        // recompiled the freshly written source before `applyPreset` reads the
        // updated preset, so a failed write cannot be reported as success.
        inspector.choosePreset(name)
        setStatus("✓  saved “\(name)”", tint: EditorTheme.text)
        return true
    }

    /// Puts the whole look back to what the file says, which is both halves of
    /// it: the text, and then the values, because a preset the sliders have been
    /// dragged around is as much a departure from the saved file as a typed
    /// character is — and Revert enables on it, so it has to undo it.
    @objc func revertShader(_ sender: Any?) {
        guard let url = current.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        current = LerpShader(name: current.name, source: text, isBuiltIn: current.isBuiltIn, url: url)
        editor.setText(text)
        parameterState.removeAll()      // else `syncParameters` pushes the moved values straight back
        animationState.removeAll()
        compileNow(force: true)
        applyPreset(currentPreset)      // reloads the look, and updates the chrome on its way out
    }

    @objc func newShader(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let directory = ShaderPaths.newShaderDirectory
        guard let typed = prompt("New Shader", "", "", placeholder: "aurora-veil") else { return }
        guard let stem = ShaderScaffold.sanitize(name: typed) else {
            presentError("Invalid name", "Use letters, numbers and dashes, e.g. aurora-veil.")
            return
        }
        let url = directory.appendingPathComponent(stem + ".metal")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            presentError("“\(stem)” already exists", "Pick a different name.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try ShaderScaffold.template(for: stem).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError("Could not create \(url.lastPathComponent)", error.localizedDescription)
            return
        }
        if let made = refreshList(metalView.shaderLibrary.discover()).first(where: { $0.name == stem }) {
            open(made)
        }
        window?.makeFirstResponder(editor.textView)
    }

    @objc func nextShader(_ sender: Any?) { step(1) }
    @objc func previousShader(_ sender: Any?) { step(-1) }
    @objc func nextPreset(_ sender: Any?) { stepPreset(1) }
    @objc func previousPreset(_ sender: Any?) { stepPreset(-1) }

    /// Steps through shaders in the order the selector shows them, opening
    /// each at its cover — the preset its card's picture shows, so the arrow
    /// lands on what the card promised.
    ///
    /// Deliberately not `metalView.showNextShader` — that only swaps the
    /// pipeline, and the playground additionally has to prompt about unsaved
    /// edits and load the new file's source into the editor. It shares the
    /// wrap-around, which is the part that was worth having once.
    ///
    /// Straight through `openEntry`, so this is the card's click and nothing
    /// beside it: it already refuses to re-open what is on screen — which is
    /// what a one-shader list wraps onto — and it asks about unsaved edits only
    /// when it is really going to discard them.
    private func step(_ direction: Int) {
        let shaders = metalView.shaderLibrary.discover()
        guard let next = ShaderLibrary.step(in: shaders.map(\.name), after: current.name,
                                            offset: direction),
              let shader = shaders.named(next),
              let cover = [shader].rotationEntries().first else { return }
        openEntry(cover)
    }

    /// ⌥⌘[ / ⌥⌘]: the open shader's presets, in the order the Presets list
    /// shows them.
    private func stepPreset(_ direction: Int) {
        guard let shader = compiled, shader.presetChoices.count > 1 else { return NSSound.beep() }
        let names = shader.presetChoices
        guard let next = ShaderLibrary.step(in: names, after: currentPreset,
                                            offset: direction) else { return }
        inspector.choosePreset(next ?? LerpRotationEntry.defaultsName)
    }

    /// On the screen the playground window is on, which is the one you are
    /// looking at.
    @objc func togglePreview(_ sender: Any?) {
        guard let screen = window?.screen ?? NSScreen.main else { return NSSound.beep() }
        preview.toggle(on: screen)
    }

    /// The icon changes first, so the button answers before a heavy shader
    /// has drawn its paused frame.
    @objc func togglePlayPause(_ sender: Any?) {
        let pausing = !isPaused
        playButton.setSymbol(pausing ? "play.fill" : "pause.fill",
                             accessibility: pausing ? "Play" : "Pause")
        playButton.displayIfNeeded()
        if pausing {
            metalView.stop()
            metalView.renderOnce()
        } else {
            metalView.start()
        }
        refreshReadout()
    }

    @objc private func edrChanged() {
        metalView.config.extendedDynamicRange = edrToggle.state == .on
        if isPaused { metalView.renderOnce() }
        refreshReadout()
    }

    /// Fraction of native. ¼ is lower than the saver offers: a useful thing
    /// to edit an expensive shader against, not a thing anybody wants left on
    /// their screen all night.
    private static let renderScales: [(title: String, scale: Double)] =
        [("Low", 0.25), ("Med", 0.5), ("High", 1.0)]

    @objc private func resolutionChanged() {
        let index = max(0, min(resolutionControl.selectedIndex, Self.renderScales.count - 1))
        metalView.config.renderScale = Self.renderScales[index].scale
        if isPaused { metalView.renderOnce() }
        refreshReadout()
    }

    /// "60 fps", or "Paused".
    private func refreshReadout() {
        let text = metalView.isRunning ? metalView.statusText : "Paused"
        if fpsLabel.stringValue != text { fpsLabel.stringValue = text }
    }

    /// The strip under the picture: a little taller than a toolbar so the
    /// round controls have room, with the same edge insets as the bars above.
    private func playerBar(_ views: [NSView]) -> NSView {
        let bar = Chrome.bar(views, height: 42)
        (bar as? NSStackView)?.spacing = 6
        return bar
    }

    /// Extra room between two groups in a stack, on top of its spacing.
    private func gap(_ width: CGFloat) -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    // MARK: - System audio

    @objc func toggleSystemAudio(_ sender: Any?) {
        guard #available(macOS 14.2, *) else {
            return setStatus("System audio needs macOS 14.2 or later", tint: EditorTheme.error)
        }
        if audioTap != nil { return stopSystemAudio(nil) }
        let tap = SystemAudioTap()
        do {
            try tap.start()
        } catch {
            return setStatus("System audio unavailable: \(error)", tint: EditorTheme.error)
        }
        tap.onRestart = { [weak self] error in
            if let error { self?.stopSystemAudio("System audio stopped: \(error)") }
        }
        audioTap = tap
        let levels = tap.levels
        metalView.audioLevels = { levels.current }
        // A denied or not-yet-answered prompt is not an error here: the tap
        // runs and hands back silence, so the uniforms simply stay at 0.
        setStatus("Listening to system audio (u.audioLevel / audioBass / audioMid / audioTreble)",
                  tint: EditorTheme.dim)
    }

    private func stopSystemAudio(_ reason: String?) {
        if #available(macOS 14.2, *) { (audioTap as? SystemAudioTap)?.stop() }
        audioTap = nil
        metalView.audioLevels = nil
        liveInputStopped("System audio", reason: reason)
    }

    /// The shared end of turning a live input off, once the view has stopped
    /// polling it: redraw a paused frame without it, and say so.
    private func liveInputStopped(_ input: String, reason: String?) {
        if isPaused { metalView.renderOnce() }
        setStatus(reason ?? "\(input) off", tint: reason == nil ? EditorTheme.dim : EditorTheme.error)
    }

    /// The shared start of a camera input: ask once, and say where the switch
    /// is when the answer was no. Both head tracking and hand control go
    /// through here, so there is one prompt and one wording for a refusal.
    private func withCamera(_ start: @escaping () -> Void) {
        HeadTracker.requestAccess { [weak self] granted in
            guard granted else {
                self?.setStatus("Camera access is off for LerpPlayground: System Settings › "
                                + "Privacy & Security › Camera", tint: EditorTheme.error)
                return
            }
            start()
        }
    }

    // MARK: - Head tracking

    @objc func toggleHeadTracking(_ sender: Any?) {
        if headTracker != nil { return stopHeadTracking(nil) }
        withCamera { [weak self] in
            guard let self, self.headTracker == nil else { return }
            let tracker = HeadTracker()
            do {
                try tracker.start()
            } catch {
                return self.setStatus("Head tracking unavailable: \(error)", tint: EditorTheme.error)
            }
            self.headTracker = tracker
            let viewer = tracker.viewer
            self.metalView.viewer = { viewer.current }
            let ignored = LerpViewer.isUsed(by: self.metalView.parameterValues) ? ""
                : ". This look ignores it; looks with a `\(LerpViewer.gainParameter)` parameter respond"
            self.setStatus("Tracking your head with \(tracker.cameraName) (u.viewer)\(ignored)",
                           tint: EditorTheme.dim)
        }
    }

    @objc func recenterHead(_ sender: Any?) {
        guard let headTracker else { return }
        headTracker.recenter()
        setStatus("Head recentred: where you are now is straight on", tint: EditorTheme.dim)
    }

    private func stopHeadTracking(_ reason: String?) {
        headTracker?.stop()
        headTracker = nil
        metalView.viewer = nil
        liveInputStopped("Head tracking", reason: reason)
    }

    // MARK: - Hands

    @objc func toggleHandControl(_ sender: Any?) {
        if hands != nil { return stopHandControl(nil) }
        withCamera { [weak self] in self?.startHandControl() }
    }

    /// Everything but the camera question, which `withCamera` has asked.
    func startHandControl() {
        guard hands == nil else { return }
        do {
            let control = HandControl()
            control.onMessage = { [weak self] message in self?.receive(message) }
            control.learning = { [weak self] in self?.learnTarget?.param }
            control.describe = { [weak self] axis in self?.handReadout(axis) }
            // What it is waiting for is drawn over the render; here only
            // matters that it stopped: no camera, or a page that failed.
            control.onStatus = { [weak self, weak control] status, active in
                guard let self, !active, self.hands === control else { return }
                self.stopHandControl("Hand control stopped: \(status)")
            }
            try control.start(over: metalView)
            hands = control
        } catch {
            return setStatus("Hand control unavailable: \(error)", tint: EditorTheme.error)
        }
        setStatus("Hand control on: hold up an open hand, then pinch to grab", tint: EditorTheme.dim)
    }

    /// What `axis` drives in the active mapping, for the label beside the hand:
    /// a scalar as its value, a colour as how far round its bound axis it is.
    private func handReadout(_ axis: HandControl.Axis) -> HandControl.Readout? {
        guard let binding = activeMapping?.bindings.first(where: {
                  HandControl.Axis(channel: $0.channel, cc: $0.cc) == axis }),
              let param = shownParameters.first(where: { $0.name == binding.paramID }) else { return nil }
        if param.type == .color {
            let component = binding.component ?? .hue
            let position = ColorProjection.position(of: component, in: currentColor(of: param),
                                                    base: param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1))
            return .init(param: "\(param.name) \(component.label)",
                         value: String(format: "%.0f%%", position * 100), fraction: position)
        }
        let value = currentValue(of: param).scalarValue ?? 0
        let span = param.max - param.min
        return .init(param: param.name,
                     value: param.type == .float ? String(format: "%.2f", value) : String(Int(value)),
                     fraction: span > 0 ? min(max((value - param.min) / span, 0), 1) : 0)
    }

    private func stopHandControl(_ reason: String?) {
        hands?.stop()
        hands = nil
        liveInputStopped("Hand control", reason: reason)
    }

    // MARK: - Chrome and polling

    /// Which checkout this window is editing, in the title — but only for a copy
    /// that had to be *told*, which is the installed one. The in-repo build finds
    /// the checkout it is sitting in and there is only ever one answer, so its
    /// title is exactly what it always was.
    ///
    /// The suffix confirms which checkout the canonical installed copy edits.
    /// Staging is never launched by a normal target, so this is no longer a way
    /// to distinguish two intentionally running copies.
    private static let repoSuffix: String =
        RepoLocation.isBuildTree ? "" : (RepoLocation.root.map { "  ·  \($0.lastPathComponent)" } ?? "")

    /// Called from every edit path, including one per moved slider and one per
    /// inbound MIDI tick, so the two assignments that AppKit would redisplay for
    /// are made only when the string actually changed.
    ///
    /// The title's dot stays the *text's*: it is the file's name that is in the
    /// title bar. `isDocumentEdited` follows everything unsaved, because that is
    /// what closing the window asks about; switching looks still asks about the
    /// text alone, so browsing with the inspector open is not questioned at
    /// every step.
    private func updateChrome() {
        let dirty = isDirty, unsaved = hasUnsavedChanges
        saveButton.isEnabled = unsaved
        revertButton.isEnabled = unsaved && current.url != nil
        // Only there when they would do something: two greyed-out buttons
        // permanently on the bar are noise, not information.
        if saveButton.isHidden == unsaved { saveButton.isHidden = !unsaved }
        if revertButton.isHidden == revertButton.isEnabled { revertButton.isHidden = !revertButton.isEnabled }
        updateShaderButton()
        let title = "Lerping@Home Playground — \(current.name)\(dirty ? " •" : "")" + Self.repoSuffix
        if window?.title != title { window?.title = title }
        // What the close prompt asks about, so the dot in the close button
        // and the question it leads to agree.
        window?.isDocumentEdited = unsaved
    }

    private func startTimers() {
        timers.append(.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            refreshReadout()
        })

        // Animated parameters' controls follow the drift. A no-op unless
        // something is animating; the drift is slow, so 20 Hz is smooth.
        timers.append(.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, inspector.window?.isVisible == true else { return }
            inspector.showLive(values: metalView.liveParameterValues)
        })

        // Pick up shaders added or edited outside the app (another editor, or
        // `git pull`). Cheap enough at this interval: one directory listing.
        timers.append(.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollDisk()
        })
        // Status readouts and a disk poll: none of it is due at an exact
        // instant, so let the system coalesce the wake-ups (Apple's guidance
        // is about a tenth of the interval).
        timers.forEach { $0.tolerance = $0.timeInterval / 10 }
    }

    func pollDisk() {
        let shaders = metalView.shaderLibrary.discover()
        if shaders.map(\.name) != knownShaderNames { refreshList(shaders) }
        // The gallery keys its stills on each shader's source text, so this is
        // what makes an edit — here or in another editor — redraw exactly the
        // tiles that changed and none of the others.
        refreshRotation(shaders)
        // Reload the open file when it changed underneath us, but never clobber
        // unsaved edits.
        guard let fresh = shaders.first(where: { $0.name == current.name }),
              fresh.source != current.source, !isDirty else { return }
        current = fresh
        editor.setText(fresh.source)
        compileNow(force: true)   // has the last word on the status line
    }

    // MARK: - Prompts and window lifecycle

    /// Asked about the *text* while browsing, and about everything unsaved on
    /// the way out; answered by ⌘S either way.
    ///
    /// Moved sliders are deliberately not a reason to ask when switching looks
    /// (`includingLook: false`): that is how this window is browsed, and a
    /// prompt on every step of it would be unusable. Closing the window or
    /// quitting is different: nothing comes after it to carry the values, so
    /// it asks about `hasUnsavedChanges`, the same predicate that lights Save.
    /// It used to ask about the text alone, so a deploy's `--quit-bundle-id`
    /// (which goes through `approveTermination`) quit a window whose Save
    /// button was lit, and the moved look went with it.
    ///
    /// Save here means what Save means everywhere else in the window — the whole
    /// of what is on screen, look included.
    @discardableResult
    private func confirmDiscardIfDirty(includingLook: Bool = false) -> Bool {
        guard includingLook ? hasUnsavedChanges : isDirty else { return true }
        let alert = NSAlert()
        if isDirty {
            alert.messageText = "Save changes to \(current.name).metal?"
            alert.informativeText = "Your edits will be lost if you don't save them."
        } else {
            alert.messageText = "Save the changed \(currentPreset ?? "Defaults") look of \(current.name)?"
            alert.informativeText = "The values you moved will be lost if you don't save them."
        }
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveShader(nil)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// One-field modal prompt. Returns nil on cancel or an empty answer.
    private func prompt(_ title: String, _ detail: String, _ value: String,
                        placeholder: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let answer = field.stringValue.trimmingCharacters(in: .whitespaces)
        return answer.isEmpty ? nil : answer
    }

    private func presentError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    func windowDidBecomeKey(_ notification: Notification) { pollDisk() }

    /// File › Ask to Save Before Closing. Off by default: the prompt stood in
    /// the way of every close, every quit and every deploy's graceful quit,
    /// over a moved slider as readily as over typed code. Off, closing and
    /// quitting simply go ahead and unsaved changes are let go.
    static let askBeforeClosingKey = "AskToSaveBeforeClosing"
    private var asksBeforeClosing: Bool {
        UserDefaults.standard.bool(forKey: Self.askBeforeClosingKey)
    }

    @objc func toggleAskBeforeClosing(_ sender: Any?) {
        UserDefaults.standard.set(!asksBeforeClosing, forKey: Self.askBeforeClosingKey)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        preview.hide()
        guard asksBeforeClosing else { terminationApproved = true; return true }
        terminationApproved = confirmDiscardIfDirty(includingLook: true)
        return terminationApproved
    }

    func approveTermination() -> Bool {
        if terminationApproved || !asksBeforeClosing { return true }
        terminationApproved = confirmDiscardIfDirty(includingLook: true)
        return terminationApproved
    }

    /// Brings the running playground back to the front — what a second launch
    /// does instead of opening a second window, and what a Dock click does.
    func raise() {
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showAndStart() {
        window?.makeKeyAndOrderFront(nil)
        metalView.start()
        window?.makeFirstResponder(editor.textView)
        // Editor / render / inspector, but never fight a divider the user has
        // already dragged (NSSplitView autosaves that).
        guard UserDefaults.standard
            .object(forKey: "NSSplitView Subview Frames " + Self.splitAutosave) == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let width = window?.contentView?.bounds.width else { return }
            split.splitView.setPosition(width * 0.40, ofDividerAt: 0)
            split.splitView.setPosition(width - 330, ofDividerAt: 1)
        }
    }
}

/// The File menu asks the same questions the toolbar does, so it asks them of
/// the same two properties: ⌘S and Revert to Saved are live exactly when their
/// buttons are. Without this AppKit enables anything this object responds to,
/// and ⌘S with nothing to save rewrote the file it had just read and reported
/// the recompile as though something had happened.
extension PlaygroundWindowController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(saveShader(_:)): return saveButton.isEnabled
        case #selector(revertShader(_:)): return revertButton.isEnabled
        case #selector(toggleHandControl(_:)):
            item.state = hands == nil ? .off : .on
            return true
        case #selector(toggleSystemAudio(_:)):
            item.state = audioTap == nil ? .off : .on
            if #available(macOS 14.2, *) { return true } else { return false }
        case #selector(toggleHeadTracking(_:)):
            item.state = headTracker == nil ? .off : .on
            return true
        case #selector(recenterHead(_:)): return headTracker != nil
        case #selector(newMapping(_:)): return midi.isAvailable
        case #selector(renameMapping(_:)), #selector(deleteMapping(_:)): return activeMapping != nil
        case #selector(nextMapping(_:)): return mappings.count > 1
        case #selector(toggleAskBeforeClosing(_:)):
            item.state = asksBeforeClosing ? .on : .off
            return true
        case #selector(togglePreview(_:)):
            item.title = preview.isShown ? "Exit Full Screen Preview" : "Preview Full Screen"
            return true
        default: return true
        }
    }
}

/// Shader › MIDI. Its fixed commands are built with the main menu, so their
/// key equivalents work whether or not it has been opened; what is connected
/// and which bank is live are read here, each time it opens.
extension PlaygroundWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        while let first = menu.items.first, first.tag == MainMenu.midiDynamicTag {
            menu.removeItem(first)
        }
        let device = NSMenuItem(title: midi.isAvailable
                                    ? (hands == nil ? midi.summary : midi.summary + " · Hands")
                                    : "MIDI off: \(midi.unavailableReason ?? "Core MIDI unavailable")",
                                action: nil, keyEquivalent: "")
        device.isEnabled = false
        var items = [device, .separator()]
        if mappings.isEmpty {
            let none = NSMenuItem(title: "No mappings — right-click a parameter to Learn",
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        }
        for preset in mappings {
            let count = preset.bindings.count
            let entry = NSMenuItem(title: preset.name, action: #selector(chooseMapping(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.name
            entry.state = preset.name == activeMapping?.name ? .on : .off
            entry.toolTip = "\(count) binding\(count == 1 ? "" : "s")"
            items.append(entry)
        }
        items.append(.separator())
        for (index, item) in items.enumerated() {
            item.tag = MainMenu.midiDynamicTag
            menu.insertItem(item, at: index)
        }
    }
}
