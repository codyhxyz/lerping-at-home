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
    private var parametersMoved: Bool {
        guard let compiled, let live = metalView.parameterValues else { return false }
        return live.values != compiled.parameterValues(for: currentEntry).values
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
    /// Opens the shader picker. Where a plain `NSPopUpButton` listing 123 look
    /// *names* used to be — see `ShaderPicker` for why a grid of stills replaced
    /// it, and for what the dropdown did better and had to be kept.
    private let shaderButton = NSButton()
    private let saveButton = NSButton(), revertButton = NSButton(), playButton = NSButton()
    private let status = NSButton()
    private let console = NSTextView()
    private let consoleScroll = NSScrollView()
    private var consoleHeight: NSLayoutConstraint!
    private let timeSlider = NSSlider()
    private let timeField = NSTextField(string: "0:00.0")
    private let windowLabel = NSTextField(labelWithString: "")
    private let pager = NSSegmentedControl()
    private let scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsLabel = NSTextField(labelWithString: "— fps")

    let inspector = ParameterPanel(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
    let midiPanel = MIDIPanel(frame: .zero)
    private var inspectorItem: NSSplitViewItem!

    /// Parameter values the user has moved away from the declared defaults.
    /// Held here rather than only in the view because every recompile calls
    /// `setShader`, which resets the view's copy — without this, typing one
    /// character in the editor would snap every slider back.
    private var parameterState: [String: LerpParamValue] = [:]
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
    private var lastScrub: CFTimeInterval = 0
    private var lastCompiledSource: String?
    private var firstErrorLine: Int?
    private var compileWork: DispatchWorkItem?
    private var timers: [Timer] = []

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
        Chrome.configure(shaderButton, title: "Shader", target: self,
                         action: #selector(showShaderPicker))
        shaderButton.alignment = .left
        // The title carries a shader name *and* a preset name, either of which
        // can be long, so it gives way rather than pushing New…, Save and Revert
        // off the bar.
        shaderButton.cell?.lineBreakMode = .byTruncatingTail
        shaderButton.setContentHuggingPriority(.init(1), for: .horizontal)
        shaderButton.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        shaderButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 178).isActive = true
        shaderButton.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
        shaderButton.toolTip = "Pick a look to edit, by picture"
        shaderButton.identifier = NSUserInterfaceItemIdentifier("shader-picker-button")

        // The picker's list, one step at a time, without opening the picker —
        // the same ⇧⌘[ / ⇧⌘] the Shader menu carries, so an arrow loads a look by
        // exactly the path a click in the popover takes. For walking neighbours;
        // the grid is still how you get to a look you can picture.
        //
        // The list is the picker's, which means *looks* and not shaders: a
        // shader's presets are the looks worth comparing side by side, and
        // stepping over shader names skipped every one of them. Walking all 123
        // in the order the grid shows them is the whole point of a next button.
        let previousButton = Chrome.button("‹", target: self, action: #selector(previousLook))
        let nextButton = Chrome.button("›", target: self, action: #selector(nextLook))
        previousButton.toolTip = "Previous look (⇧⌘[)"
        nextButton.toolTip = "Next look (⇧⌘])"

        // No New… here any more: making a shader is something you do *among the
        // looks*, so it is the first card in the picker's grid — where you are
        // already looking when you want one that does not exist yet. File → New
        // Shader… (⌘N) is unchanged.
        Chrome.configure(saveButton, title: "Save", target: self, action: #selector(saveShader))
        saveButton.toolTip = "Save the edits and the look on screen back into the .metal file (⌘S). "
            + "Save the look under a new name with Shader → Save Look as Preset… (⇧⌘S)."
        Chrome.configure(revertButton, title: "Revert", target: self, action: #selector(revertShader))

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

        return Chrome.pane([Chrome.bar([shaderButton, previousButton, nextButton,
                                        saveButton, revertButton,
                                        Chrome.flexible()]),
                            editor,
                            Chrome.bar([status, Chrome.flexible()], height: 22),
                            consoleScroll])
    }

    /// Render settings on top, the picture, then the transport seated under it
    /// spanning the picture's own width.
    ///
    /// Seed and render scale used to sit in the same strip as the scrubber,
    /// which made the scrubber as wide as whatever was left over. They are
    /// settings of the render, not transport, so they stay above; play, scrub
    /// and the clock go below, where a player's controls go.
    private func renderPane() -> NSView {
        Chrome.configure(playButton, title: "Pause", target: self, action: #selector(togglePlayPause))
        playButton.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let seedButton = Chrome.button("Seed", target: self, action: #selector(rerollSeed))

        // Momentary, because a page is an action and not a state.
        pager.segmentStyle = .rounded
        pager.controlSize = .small
        pager.trackingMode = .momentary
        pager.segmentCount = 2
        for (index, label) in ["‹", "›"].enumerated() {
            pager.setLabel(label, forSegment: index)
            pager.setWidth(23, forSegment: index)
        }
        pager.target = self
        pager.action = #selector(pageWindow)
        pager.toolTip = "Jump back or forward one minute"

        timeSlider.controlSize = .small
        timeSlider.isContinuous = true
        timeSlider.target = self
        timeSlider.action = #selector(timeSliderChanged)
        timeSlider.toolTip = "Scrub this minute; type the clock to jump anywhere"
        // No width constraint: the scrubber is what absorbs the pane's slack,
        // so it spans the render however wide the render is.
        timeSlider.setContentHuggingPriority(.init(1), for: .horizontal)
        timeSlider.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        timeField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timeField.alignment = .right
        timeField.controlSize = .small
        timeField.target = self
        timeField.action = #selector(timeFieldChanged)
        timeField.toolTip = "Absolute time. Type 90, 90.5 or 1:30.5 to jump there."
        timeField.widthAnchor.constraint(equalToConstant: 68).isActive = true

        windowLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        windowLabel.textColor = EditorTheme.dim
        windowLabel.alignment = .right
        windowLabel.toolTip = "The minute shown by the scrubber"
        // First thing to give way when the pane gets narrow: it is an
        // annotation, and the field beside it carries the number that matters.
        windowLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        scalePopUp.controlSize = .small
        scalePopUp.font = .systemFont(ofSize: 11)
        scalePopUp.target = self
        scalePopUp.action = #selector(scaleChanged)
        scalePopUp.addItems(withTitles: Self.renderScales.map(\.title))
        scalePopUp.widthAnchor.constraint(equalToConstant: 78).isActive = true

        fpsLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        fpsLabel.textColor = EditorTheme.dim
        fpsLabel.alignment = .right
        fpsLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true

        metalView.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: 60,
                                                renderScale: 1.0, shuffleInterval: .infinity)
        metalView.onCompileError = { name, message in
            FileHandle.standardError.write(Data("compile error in \(name):\n\(message)\n".utf8))
        }
        metalView.setContentHuggingPriority(.init(1), for: .vertical)

        syncTransport()
        return Chrome.pane([Chrome.bar([seedButton, scalePopUp,
                                        Chrome.flexible(), fpsLabel]),
                            metalView,
                            Chrome.bar([playButton, pager, timeField, timeSlider, windowLabel],
                                       height: 34)])
    }

    // MARK: - Transport

    /// Time here is endless: the shaders do not loop, so a slider from zero to
    /// “the end” either lies or loses precision as the app runs. The scrubber is
    /// therefore a one-minute local ruler; its editable clock is the unbounded
    /// navigation. Users choose a moment, not a unit conversion.
    private static let timelineWindow = 60.0

    /// Derived, never stored: the window is always the one containing the
    /// clock. That is what keeps the thumb, the readout and the window from
    /// ever disagreeing — there is no second source of truth to drift.
    var windowStart: Double {
        max(0, ((metalView.time - 1e-9) / Self.timelineWindow).rounded(.down)
            * Self.timelineWindow)
    }

    /// Brings the scrubber, its window and the clock readout in step with
    /// `metalView.time`. Cheap enough to call from the 0.2 s poll.
    private func syncTransport() {
        let start = windowStart
        if timeSlider.minValue != start || timeSlider.maxValue != start + Self.timelineWindow {
            timeSlider.minValue = start
            timeSlider.maxValue = start + Self.timelineWindow
            windowLabel.stringValue = "\(Self.clock(start))–\(Self.clock(start + Self.timelineWindow))"
        }
        // Leave the thumb alone briefly after a drag so it doesn't fight the
        // user, and pin it right once the clock runs on past the scrubber.
        if CACurrentMediaTime() - lastScrub > 0.4 { timeSlider.doubleValue = metalView.time }
        refreshClock()
    }

    /// The readout is absolute time, always — it is the one thing that must not
    /// be relative to the window.
    private func refreshClock() {
        guard timeField.currentEditor() == nil else { return }   // not while it is being typed in
        timeField.stringValue = Self.clock(metalView.time, decimals: 1)
    }

    /// Moves the clock and its visible one-minute window.
    func seek(to seconds: Double) {
        metalView.time = max(0, seconds)
        lastScrub = 0            // an explicit jump wants the thumb to follow now
        syncTransport()
        if isPaused { metalView.renderOnce() }
    }

    /// `1:30.5`, or `1:30` with no decimals. Minutes are unbounded — a shader
    /// left running for an hour reads `60:00`, not a wrapped clock.
    static func clock(_ seconds: Double, decimals: Int = 0) -> String {
        let minutes = Int(seconds / 60)
        let rest = seconds - Double(minutes) * 60
        return decimals > 0 ? String(format: "%d:%04.1f", minutes, rest)
                            : String(format: "%d:%02d", minutes, Int(rest.rounded()))
    }

    /// `90`, `90.5`, `1:30` and `1:30.5` all mean the same instant. nil for
    /// anything else, which puts the real time back rather than jumping to 0.
    static func seconds(fromClock text: String) -> Double? {
        let parts = text.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.count {
        case 1:  return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default: return nil
        }
    }

    /// Parameter controls above, MIDI strip below. Both are driven entirely by
    /// callbacks, so neither knows about the metal view or the shader library.
    private func inspectorPane() -> NSView {
        inspector.onChange = { [weak self] name, value in self?.setParameter(name, value) }
        inspector.onPreset = { [weak self] name in self?.applyPreset(name) }
        inspector.onMIDICommand = { [weak self] name, component, command in
            self?.midiCommand(name, component, command)
        }
        midiPanel.onAction = { [weak self] action in self?.mappingCommand(action) }
        inspector.setContentHuggingPriority(.init(1), for: .vertical)
        midiPanel.heightAnchor.constraint(equalToConstant: 82).isActive = true
        return Chrome.pane([inspector, midiPanel])
    }

    // MARK: - Shader list

    /// Takes note of what is on disk, and refreshes the picker if it happens to
    /// be open. Never changes what is in the editor.
    @discardableResult
    private func refreshList(_ shaders: [LerpShader]) -> [LerpShader] {
        knownShaderNames = shaders.map(\.name)
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

    /// The toolbar button says which look is open, the way the dropdown's
    /// selected item used to — plus the preset, which the dropdown could not say
    /// at all, and a chevron so it reads as something that opens.
    private func updateShaderButton() {
        let name = current.name.isEmpty ? "Shader" : current.name
        let preset = currentPreset.map { " · " + $0 } ?? ""
        let custom = customShaderNames.contains(current.name) ? "  · custom" : ""
        let title = "◱  " + name + preset + custom + "  ▾"
        if shaderButton.title != title { shaderButton.title = title }
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

    /// Both grids mark the look the editor has open, so "where am I in these
    /// 123 pictures" is answerable without reading captions.
    private func showCurrentEverywhere() {
        rotation?.showCurrent(currentEntry)
        picker?.gallery.showCurrent(currentEntry)
    }

    /// Opens a look — a (shader, preset) pair — from either grid: the gallery
    /// window's double-click or the toolbar popover's click. The same `open` the
    /// launch path takes, plus the unsaved-changes prompt and bringing the
    /// editor back to the front, since the click may have come from another
    /// window entirely.
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
            _ = try library.pipeline(for: draft)
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
            inspector.rebuild(shader: shader)
            // A rebuild leaves the popup on "Defaults"; the look on screen has
            // not changed, so put the label back on it rather than letting the
            // one control that names the look be the one that lies about it.
            inspector.showPreset(currentPreset)
            inspector.showsMIDIControls = midi.isAvailable
            refreshBindingLabels()
        }
        for (name, value) in parameterState { metalView.setParameter(name, value) }
        inspector.show(values: metalView.parameterValues)
    }

    /// The one place a parameter changes, whatever moved it — mouse, typed
    /// number, preset or knob.
    func setParameter(_ name: String, _ value: LerpParamValue) {
        parameterState[name] = value
        metalView.setParameter(name, value)
        // A moved value is an unsaved change to the look, so Save has to light
        // up on it exactly as it does on a keystroke in the editor.
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
        inspector.show(values: metalView.parameterValues)
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
    }

    /// A device appeared or went away. Auto-select the bank that was made for
    /// it, which is the whole point of storing the device ID in the preset.
    private func midiSourcesChanged() {
        if let match = mappings.first(where: { preset in
            !preset.deviceID.isEmpty && midi.sources.contains { $0.id == preset.deviceID }
        }), match.name != activeMapping?.name {
            select(mapping: match.name)
        }
        refreshMappingList()
    }

    private func refreshMappingList() {
        midiPanel.showDevices(midi.summary)
        midiPanel.showMappings(mappings.map(\.name), selected: activeMapping?.name,
                               enabled: midi.isAvailable)
        guard midi.isAvailable else {
            midiPanel.showStatus(midi.unavailableReason ?? "", tint: EditorTheme.error)
            return
        }
        let count = activeMapping?.bindings.count ?? 0
        midiPanel.showStatus(activeMapping == nil
            ? "No mapping yet — use a parameter's Learn…"
            : "\(count) binding\(count == 1 ? "" : "s")")
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

    private func refreshMappingUI() {
        refreshMappingList()
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
            midiPanel.showStatus("Could not save mapping: \(error.localizedDescription)",
                                 tint: EditorTheme.error)
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
            preset.bind(MIDIBinding(paramID: target.param, channel: nil, cc: message.cc,
                                    component: component))
            commit(preset)
            midiPanel.showStatus("Learned CC\(message.cc) → \(target.param)"
                                    + (component.map { " \($0.label)" } ?? ""),
                                 tint: EditorTheme.text)
            return
        }
        guard let routed = router.route(channel: message.channel, cc: message.cc, value: message.value),
              let param = shownParameters.first(where: { $0.name == routed.binding.paramID }),
              let value = resolve(routed.update, for: param, binding: routed.binding) else { return }
        setParameter(param.name, value)
        inspector.show(values: metalView.parameterValues)
        midiPanel.showStatus("\(routed.binding.shortLabel) → \(param.name) = \(value.literal)")
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
        (parameterState[param.name] ?? param.defaultValue).colorValue
            ?? param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1)
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
        let current = (parameterState[param.name] ?? param.defaultValue).scalarValue ?? 0
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
            midiPanel.showStatus(learnTarget == nil
                ? "Learn cancelled"
                : "Learning \(name)\(component.map { " \($0.label)" } ?? "") — move a knob",
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
                midiPanel.showStatus("14-bit needs CC 0–31, not \(binding.shortLabel)",
                                     tint: EditorTheme.error)
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
            midiPanel.showStatus(String(format: "%@ → %@ over %.2f–%.2f", binding.shortLabel, name,
                                        scoped.range.lowerBound, scoped.range.upperBound))
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

    private func mappingCommand(_ action: MIDIPanel.Action) {
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

    /// The gallery window, once it has been asked for. Built lazily: it renders
    /// 123 stills, and an app that never opens it should never pay for them.
    private(set) var rotation: RotationWindowController?

    /// The screensaver's rotation, as this window sees it. Written by the
    /// gallery — the entire point of that feature — and *read* by `openingEntry`
    /// on launch, which is the one place this app looks at the rotation without
    /// being asked to.
    var rotationDefaults: UserDefaults?

    /// The toolbar's picker popover, once it has been asked for. Same reason as
    /// the gallery window: 123 stills is not a bill an app that never opens it
    /// should pay.
    private(set) var picker: ShaderPicker?

    /// The saved rotation as the popover last read it. A badge click writes
    /// against this rather than against nothing, so it cannot undo an Options…
    /// sheet pressed in the meantime — the same protection the gallery window
    /// has had, which this surface was missing. Set on every load of the
    /// popover, on every write from it, and whenever the gallery writes.
    private var rotationBase: LerpRotationState?

    /// One cache of stills for both grids. They show the same 123 looks, and
    /// `RotationThumbnails.start` supersedes the run in flight — two instances
    /// would mean two copies of 123 decoded images, and one instance driven by
    /// two hosts would mean whichever asked second silently stopping the first
    /// one's deliveries. So there is one instance, and each host hands the
    /// images it receives to the other; whichever run is live feeds both.
    private lazy var thumbnails = RotationThumbnails(searchURLs: RepoLocation.searchURLs)

    /// The gallery window, built on first use. Deliberately does not load until
    /// it is shown.
    @discardableResult
    func rotationGallery() -> RotationWindowController {
        if let rotation { return rotation }
        let made = RotationWindowController(searchURLs: RepoLocation.searchURLs,
                                            defaults: rotationDefaults, hidden: hidden,
                                            thumbnails: thumbnails)
        made.onOpen = { [weak self] entry in self?.openEntry(entry) }
        made.onChange = { [weak self] enabled, base in
            self?.rotationBase = base
            self?.picker?.showEnabled(enabled)
        }
        made.onImage = { [weak self] entry, image in self?.picker?.showImage(image, for: entry) }
        made.showCurrent(currentEntry)
        rotation = made
        return made
    }

    /// Shader → Screensaver Rotation… (⌥⌘R), forwarded by the app delegate when
    /// the gallery itself is key. The only entry point: the picker popover's
    /// corner badges toggle the rotation, so the toolbar carries no button for
    /// it, but Select All / Deselect All and the wider grid live only here.
    @objc func showRotationGallery(_ sender: Any?) {
        let gallery = rotationGallery()
        gallery.load(shaders: metalView.shaderLibrary.discover())
        gallery.showCurrent(currentEntry)
        gallery.show()
    }

    /// The picker, built on first use.
    @discardableResult
    func shaderPicker() -> ShaderPicker {
        if let picker { return picker }
        let made = ShaderPicker(thumbnails: thumbnails)
        made.onOpen = { [weak self] entry in self?.openEntry(entry) }
        // The "+" card at the head of the grid, which is where the toolbar's
        // New… button went. Straight into the same action File → New Shader…
        // (⌘N) sends, unsaved-edits prompt and all: a second way in must not
        // become a second flow, or one of them will be the one that forgets to
        // ask.
        made.onNew = { [weak self] in self?.newShader(nil) }
        made.onChange = { [weak self] enabled in self?.persistRotation(enabled) }
        made.onImage = { [weak self] entry, image in
            self?.rotation?.gallery.show(image: image, for: entry)
        }
        picker = made
        return made
    }

    /// The toolbar button, and the Shader menu's Open Look… item.
    @objc func showShaderPicker(_ sender: Any?) {
        preparePicker().present(from: shaderButton)
    }

    /// Prepares the picker before putting its popover on screen.
    @discardableResult
    func preparePicker() -> ShaderPicker {
        let picker = shaderPicker()
        loadPicker(picker, shaders: metalView.shaderLibrary.discover())
        return picker
    }

    private func loadPicker(_ picker: ShaderPicker, shaders: [LerpShader]) {
        let entries = shaders.rotationEntries()
        let saved = RotationStore.resolved(discovered: entries, from: rotationDefaults)
        rotationBase = saved.base
        picker.prepare(shaders: shaders, enabled: saved.looks, current: currentEntry)
    }

    /// A badge in the picker was clicked. Writes the screensaver's rotation the
    /// same way the gallery window's click does — through `RotationStore`, into
    /// the saver's own ByHost domain — and brings the gallery window's copy of
    /// the grid up to date if it happens to be open.
    private func persistRotation(_ enabled: Set<LerpRotationEntry>) {
        let entries = metalView.shaderLibrary.discover().rotationEntries()
        let written = RotationStore.save(enabled, entries: entries,
                                         base: rotationBase, to: rotationDefaults)
        rotationBase = written
        rotation?.showEnabled(enabled, base: written)
    }

    /// A shader was saved, or changed on disk. Both grids key their stills on
    /// each shader's source, so handing them the fresh list is all it takes for
    /// the edited shader's tiles — and only those — to be drawn again.
    private func refreshRotation(_ shaders: [LerpShader]) {
        rotation?.load(shaders: shaders)
        if let picker, picker.isShown { loadPicker(picker, shaders: shaders) }
    }

    // MARK: - Actions

    @objc func recompile(_ sender: Any?) { compileNow(force: true) }

    @objc func toggleInspector(_ sender: Any?) {
        inspectorItem.animator().isCollapsed.toggle()
    }

    @objc func nextMapping(_ sender: Any?) {
        if midiPanel.cycleMapping() == nil { NSSound.beep() }
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
            setStatus("✓  saved — “\(currentPreset ?? LerpRotationEntry.defaultsName)” is unchanged: every control is at "
                        + "\(current.name)'s declared default, and a preset records only what differs",
                      tint: EditorTheme.dim)
            return true
        }
    }

    /// The buffer onto disk, and nothing else. The file half of `saveShader`,
    /// separate because the preset flows write the buffer *after* splicing into
    /// it and must not be handed back to the folding above.
    @discardableResult
    private func writeBuffer() -> Bool {
        let url = ShaderPaths.saveURL(for: current)
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
        let overrides: [(param: LerpParam, value: LerpParamValue)]
        switch liveValues() {
        case .ready(let values): overrides = values
        case .unavailable: return NSSound.beep()
        case .cannot(let title, let detail): return presentError(title, detail)
        }
        guard let compiled else { return }

        let detail = "The values on screen become a `// lerp-preset:` block in "
            + "\(current.name).metal. A new name adds a look; an existing name is "
            + "replaced after confirmation."
            + (isDirty ? "\n\nYour unsaved edits are saved with it: a preset can only name parameters "
                            + "the file itself declares." : "")
        guard let name = prompt("Save look as preset", detail, currentPreset ?? "",
                                placeholder: "Lagoon") else { return }
        if let problem = LerpPresetWriter.problem(withName: name) {
            return presentError("“\(name)” cannot be a preset name", problem)
        }
        let clash = compiled.preset(named: name)
        if let clash {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Replace preset “\(clash.name)”?"
            alert.informativeText = "This replaces its saved values and keeps its current rotation setting."
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
    private enum LiveValues {
        case ready([(param: LerpParam, value: LerpParamValue)])
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
        let overrides = LerpPresetWriter.overrides(in: values)
        guard !overrides.isEmpty else {
            return .cannot(title: "Nothing to save as a preset", detail: compiled.parameters.isEmpty
                ? "\(current.name) declares no `// lerp-param:` parameters, so there is nothing a "
                    + "preset could set. Add one to the file and the inspector grows a control for it."
                : "Every control is at \(current.name)'s declared default, and a preset records only "
                    + "what differs from them. A look that sets nothing is the Defaults look — pick it "
                    + "in the inspector and the file is already saying it.")
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
    /// look can honestly mean; the status line says how many lines moved, and
    /// ⌘Z takes the buffer back.
    @discardableResult
    private func writeDefaults(_ overrides: [(param: LerpParam, value: LerpParamValue)]) -> Bool {
        let declared = compiled?.parameters.count ?? overrides.count
        editor.replaceTextAsEdit(ParamScaffold.settingDefaults(overrides, in: editor.text))
        guard writeBuffer() else { return false }
        // The round trip in public, as in `writePreset`: the file has been
        // re-read and recompiled, and this puts the freshly declared defaults
        // on screen — so a write that did not take cannot look like one that did.
        applyPreset(nil)
        setStatus("✓  saved \(overrides.count) of \(declared)"
                    + " parameter\(declared == 1 ? "" : "s") as \(current.name)'s defaults",
                  tint: EditorTheme.text)
        return true
    }

    /// Splices `overrides` into the buffer as the preset `name`, saves the file
    /// and puts the window back on that preset. The tail both preset paths
    /// share, so ⌘S over a modified preset and ⇧⌘S write the same block by the
    /// same route and report it in the same words.
    @discardableResult
    private func writePreset(named name: String,
                             _ overrides: [(param: LerpParam, value: LerpParamValue)],
                             replacing existing: LerpPreset?) -> Bool {
        let declared = compiled?.parameters.count ?? overrides.count
        let declaration = LerpPresetWriter.declaration(name: name, overrides: overrides)

        // Reported as an edit rather than pushed in silently: this is exactly
        // the block you would have typed, ⌘Z still undoes it, and the file that
        // gets written is the buffer you can see.
        let updated = existing.map {
            PresetScaffold.replacing($0.name, with: declaration, in: editor.text)
        } ?? PresetScaffold.inserting(declaration, into: editor.text)
        editor.replaceTextAsEdit(updated)
        guard writeBuffer() else { return false }
        // `writeBuffer` has already re-read the directory and handed the fresh
        // list to both grids, so the new look has a tile by the time we get
        // here. Wearing it goes through the inspector's popup like every other
        // preset change — that is what makes `currentPreset`, the toolbar
        // button, the remembered look and both grids' current marks agree — and
        // it is also the round trip proving itself in public: `writeBuffer`
        // recompiled the freshly written source before `applyPreset` reads the
        // updated preset, so a failed write cannot be reported as success.
        inspector.choosePreset(name)
        setStatus("✓  \(existing == nil ? "saved" : "updated") preset “\(name)” — "
                    + "\(overrides.count) of \(declared)"
                    + " parameter\(declared == 1 ? "" : "s")",
                  tint: EditorTheme.text)
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
        compileNow(force: true)
        applyPreset(currentPreset)      // reloads the look, and updates the chrome on its way out
    }

    @objc func newShader(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let directory = ShaderPaths.newShaderDirectory
        guard let typed = prompt("New shader",
                                 "The file name becomes the shader name.\nSaving to \(directory.path)",
                                 "", placeholder: "aurora-veil") else { return }
        guard let stem = ShaderScaffold.sanitize(name: typed) else {
            presentError("Invalid name", "Use letters, numbers and dashes, e.g. aurora-veil.")
            return
        }
        let url = directory.appendingPathComponent(stem + ".metal")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            presentError("\(stem).metal already exists", "Pick a different name or edit the existing shader.")
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

    @objc func nextLook(_ sender: Any?) { step(1) }
    @objc func previousLook(_ sender: Any?) { step(-1) }

    /// Steps through *looks* — every (shader, preset) pair — in the order the
    /// picker grid lists them, not through shader names. A shader's presets are
    /// exactly the things worth flipping between to compare, and a walk over
    /// names jumped past all of them: on a shader with six presets, five of its
    /// seven looks were unreachable from the arrows.
    ///
    /// Deliberately not `metalView.showNextShader` — that only swaps the
    /// pipeline, and the playground additionally has to prompt about unsaved
    /// edits and load the new file's source into the editor. It shares the
    /// wrap-around, which is the part that was worth having once.
    ///
    /// Straight through `openEntry`, so this is the popover's click and nothing
    /// beside it: it already refuses to re-open the look on screen — which is
    /// what a one-look list wraps onto, and re-opening would throw away every
    /// slider moved off it to arrive back where it started — and it already asks
    /// about unsaved edits only when it is really going to discard them.
    private func step(_ direction: Int) {
        let looks = metalView.shaderLibrary.discover().rotationEntries()
        guard let next = ShaderLibrary.step(in: looks, after: currentEntry,
                                            offset: direction) else { return }
        openEntry(next)
    }

    @objc func togglePlayPause(_ sender: Any?) {
        if isPaused {
            metalView.start()
        } else {
            metalView.stop()
            metalView.renderOnce()
        }
        playButton.title = isPaused ? "Play" : "Pause"
    }

    @objc func rerollSeed(_ sender: Any?) {
        metalView.seed = Float.random(in: 0..<1)
        if isPaused { metalView.renderOnce() }
        setStatus(String(format: "seed = %.4f", metalView.seed), tint: EditorTheme.dim)
    }

    @objc private func timeSliderChanged() {
        lastScrub = CACurrentMediaTime()
        metalView.time = timeSlider.doubleValue
        refreshClock()          // not the whole transport: the window is mid-drag
        if isPaused { metalView.renderOnce() }
    }

    /// One minute back or forward. Because the window is derived from the
    /// clock, paging *is* seeking — there is no separate "where the scrubber is
    /// looking" that could disagree with where the shader is.
    @objc private func pageWindow(_ sender: NSSegmentedControl) {
        seek(to: metalView.time
             + (sender.selectedSegment == 0 ? -Self.timelineWindow : Self.timelineWindow))
    }

    @objc private func timeFieldChanged(_ sender: NSTextField) {
        guard let seconds = Self.seconds(fromClock: sender.stringValue) else {
            return refreshClock()      // unparseable: put the real time back
        }
        window?.makeFirstResponder(nil)
        seek(to: seconds)
    }

    /// Fraction of native. Goes one step further down than the saver's copy of
    /// this menu: a quarter-scale render is a useful thing to edit against when
    /// a shader is expensive, and it is not a thing anybody wants left on their
    /// screen all night.
    private static let renderScales: Chrome.Choices =
        [("100%", 1.0), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25)]

    @objc private func scaleChanged() {
        metalView.config.renderScale = Chrome.value(of: scalePopUp, in: Self.renderScales,
                                                    default: 0)
        if isPaused { metalView.renderOnce() }
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
    /// title bar, and `isDocumentEdited` is the flag the close prompt reads —
    /// and that prompt deliberately does not fire over moved sliders, because
    /// browsing looks with the inspector open would then question every step.
    private func updateChrome() {
        let dirty = isDirty, unsaved = hasUnsavedChanges
        saveButton.isEnabled = unsaved
        revertButton.isEnabled = unsaved && current.url != nil
        updateShaderButton()
        let title = "Lerping@Home Playground — \(current.name)\(dirty ? " •" : "")" + Self.repoSuffix
        if window?.title != title { window?.title = title }
        window?.isDocumentEdited = dirty
    }

    private func startTimers() {
        timers.append(.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            syncTransport()
            fpsLabel.stringValue = metalView.statusText
        })

        // Pick up shaders added or edited outside the app (another editor, or
        // `git pull`). Cheap enough at this interval: one directory listing.
        timers.append(.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollDisk()
        })
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

    /// Asked about the *text*, and answered by ⌘S.
    ///
    /// Moved sliders are deliberately not a reason to ask: switching looks is
    /// how this window is browsed, and a prompt on every step of it would be
    /// unusable. But once the question has been raised by an edit to the text,
    /// Save here means what Save means everywhere else in the window — the whole
    /// of what is on screen, look included. Nothing it does can ask a second
    /// question, so a close cannot stall behind one.
    @discardableResult
    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(current.name).metal?"
        alert.informativeText = "Your edits will be lost if you don't save them."
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        terminationApproved = confirmDiscardIfDirty()
        return terminationApproved
    }

    func approveTermination() -> Bool {
        if terminationApproved { return true }
        terminationApproved = confirmDiscardIfDirty()
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
        default: return true
        }
    }
}
