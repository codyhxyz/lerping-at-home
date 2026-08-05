import AppKit
import Metal
import MIDIDeps
import QuartzCore

/// The playground window: `.metal` source on the left, a live `LerpMetalView`
/// on the right, and a debounced recompile in between.
///
/// Everything that actually renders comes from LerpCore — `ShaderLibrary` does
/// the runtime compile (same code path as the screensaver) and `LerpMetalView`
/// owns the display link. This class is only the shell around them.
final class PlaygroundWindowController: NSWindowController, NSWindowDelegate {

    /// Outcome of the most recent compile. Drives the status bar, and is what
    /// `--selftest` asserts on.
    enum CompileState {
        case pending
        case ok(milliseconds: Double)
        case failed([ShaderDiagnostic])
    }

    let editor = ShaderEditorView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
    private(set) var metalView: LerpMetalView!
    private(set) var compileState: CompileState = .pending
    private(set) var knownShaderNames: [String] = []

    /// The open shader *as it is on disk*. `editor.text` is the working copy, so
    /// the two differing is exactly what "unsaved changes" means.
    private var current = LerpShader(name: "", source: "", isBuiltIn: false, url: nil)
    var currentName: String { current.name }
    private var isDirty: Bool { editor.text != current.source }
    /// The shader as it was at the last successful compile — i.e. what is on the
    /// GPU, and therefore what the inspector is showing controls for.
    private(set) var compiled: LerpShader?

    private let split = NSSplitViewController()
    private let shaderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
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
    private let spanPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsLabel = NSTextField(labelWithString: "— fps")

    let inspector = ParameterPanel(frame: NSRect(x: 0, y: 0, width: 320, height: 700))
    let midiPanel = MIDIPanel(frame: .zero)
    private var inspectorItem: NSSplitViewItem!

    /// Parameter values the user has moved away from the declared defaults.
    /// Held here rather than only in the view because every recompile calls
    /// `setShader`, which resets the view's copy — without this, typing one
    /// character in the editor would snap every slider back.
    private(set) var parameterState: [String: LerpParamValue] = [:]
    /// What the inspector currently has controls for.
    private var shownParameters: [LerpParam] = []
    private var shownShaderName: String?

    let midi = MIDIController()
    private let router = MIDIRouter()
    private(set) var mappings: [MappingPreset] = []
    private(set) var activeMapping: MappingPreset?
    /// The whole of MIDI learn: when this is set, the next inbound CC binds
    /// itself to that parameter instead of being routed. The component is the
    /// axis to bind on a colour, and nil on everything else.
    var learnTarget: (param: String, component: ColorComponent?)?

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

    /// True for the `--selftest` window: a real, laid-out, rendering window
    /// that is not on the user's screen, not in their way and not in their
    /// saved layout. See `hide()`.
    private let hidden: Bool

    /// Returns nil when there is no Metal device to render with.
    static func make(hidden: Bool = false) -> PlaygroundWindowController? {
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 760, height: 760),
                                       extraSearchURLs: ShaderLocations.repoSearchURLs())
        else { return nil }
        return PlaygroundWindowController(metalView: view, hidden: hidden)
    }

    private init(metalView view: LerpMetalView, hidden: Bool) {
        metalView = view
        self.hidden = hidden
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 500)
        super.init(window: window)
        window.delegate = self
        if hidden { hide(window) }

        buildUI()
        startMIDI()
        let shaders = refreshList(metalView.shaderLibrary.discover())
        if let first = shaders.first {
            open(first)
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

    /// Takes the window off the user's screen without taking it off *a* screen.
    ///
    /// Moving it beyond the displays would be simpler, but AppKit stops the
    /// display link on a window that is on no screen — measured: zero frames —
    /// and "the live view is drawing frames" is one of the checks this window
    /// exists to make. So it stays where it is, fully composited and really
    /// rendering, at zero opacity: invisible, click-through, out of ⌘-Tab and
    /// Mission Control, and out of the Window menu.
    private func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
    }

    required init?(coder: NSCoder) { nil }

    deinit { timers.forEach { $0.invalidate() } }

    // MARK: - UI construction

    private func buildUI() {
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        // The self-test gets the built-in layout every time rather than one it
        // saved on a previous run, so what it lays out is what it asserts on.
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
        shaderPopUp.target = self
        shaderPopUp.action = #selector(shaderPopUpChanged)
        shaderPopUp.controlSize = .small
        shaderPopUp.font = .systemFont(ofSize: 11)
        shaderPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let newButton = Chrome.button("New…", target: self, action: #selector(newShader))
        Chrome.configure(saveButton, title: "Save", target: self, action: #selector(saveShader))
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

        return Chrome.pane([Chrome.bar([shaderPopUp, newButton, saveButton, revertButton, Chrome.flexible()]),
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
        pager.toolTip = "Jump back or forward one window"

        timeSlider.controlSize = .small
        timeSlider.isContinuous = true
        timeSlider.target = self
        timeSlider.action = #selector(timeSliderChanged)
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
        windowLabel.toolTip = "The stretch of the timeline the scrubber covers"
        // First thing to give way when the pane gets narrow: it is an
        // annotation, and the field beside it carries the number that matters.
        windowLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        for (popUp, titles, action) in [(scalePopUp, Self.renderScales.map(\.title), #selector(scaleChanged)),
                                        (spanPopUp, Self.timeSpans.map(\.title), #selector(spanChanged))] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11)
            popUp.target = self
            popUp.action = action
            popUp.addItems(withTitles: titles)
        }
        scalePopUp.widthAnchor.constraint(equalToConstant: 78).isActive = true
        spanPopUp.widthAnchor.constraint(equalToConstant: 88).isActive = true
        spanPopUp.selectItem(at: Self.timeSpans.firstIndex { $0.seconds == windowSpan } ?? 0)
        spanPopUp.toolTip = "How much time the scrubber spans, and so how fine a drag is"

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
        return Chrome.pane([Chrome.bar([seedButton, scalePopUp, spanPopUp,
                                        Chrome.flexible(), fpsLabel]),
                            metalView,
                            Chrome.bar([playButton, pager, timeField, timeSlider, windowLabel],
                                       height: 34)])
    }

    // MARK: - Transport

    /// The scrubber covers a fixed span of the timeline rather than [0, some
    /// number someone picked]. Shaders here are fbm/noise driven with time
    /// feeding unbounded coordinates — they never repeat, so there is no
    /// natural end to scale to, and the old `maxValue = 180` meant that past
    /// three minutes the thumb sat pinned at the right edge reporting 180 while
    /// the shader was at 400.
    ///
    /// A fixed span also keeps drag precision constant: one pixel is always the
    /// same number of seconds, whether you are at t=12 or t=9000.
    private static let timeSpans: [(title: String, seconds: Double)] =
        [("Span 30s", 30), ("Span 1m", 60), ("Span 3m", 180), ("Span 10m", 600), ("Span 30m", 1800)]

    /// Three minutes over a scrubber that is usually 400–800 px wide is roughly
    /// a quarter-second per pixel: fine enough to land on a moment, long enough
    /// that watching a shader does not page constantly. The popup is there for
    /// when it is the wrong answer.
    private(set) var windowSpan: Double = 180

    /// Derived, never stored: the window is always the one containing the
    /// clock. That is what keeps the thumb, the readout and the window from
    /// ever disagreeing — there is no second source of truth to drift.
    var windowStart: Double {
        max(0, ((metalView.time - 1e-9) / windowSpan).rounded(.down) * windowSpan)
    }

    /// Brings the scrubber, its window and the clock readout in step with
    /// `metalView.time`. Cheap enough to call from the 0.2 s poll.
    private func syncTransport() {
        let start = windowStart
        if timeSlider.minValue != start || timeSlider.maxValue != start + windowSpan {
            timeSlider.minValue = start
            timeSlider.maxValue = start + windowSpan
            windowLabel.stringValue = "\(Self.clock(start))–\(Self.clock(start + windowSpan))"
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

    /// Moves the clock, and with it the window. Every deliberate jump goes
    /// through here: the pager, the typed field, and `--selftest`.
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

    /// Rebuilds the picker from `shaders`. Never changes what is in the editor.
    @discardableResult
    private func refreshList(_ shaders: [LerpShader]) -> [LerpShader] {
        knownShaderNames = shaders.map(\.name)
        shaderPopUp.removeAllItems()
        for shader in shaders {
            shaderPopUp.addItem(withTitle: shader.isBuiltIn ? shader.name : shader.name + "  · custom")
            shaderPopUp.lastItem?.representedObject = shader.name
        }
        select(current.name)
        return shaders
    }

    private func select(_ name: String) {
        if let item = shaderPopUp.itemArray.first(where: { $0.representedObject as? String == name }) {
            shaderPopUp.select(item)
        }
    }

    private func open(_ shader: LerpShader) {
        current = shader
        parameterState.removeAll()      // a new shader starts at its own defaults
        select(shader.name)
        editor.setText(shader.source)
        metalView.config.shaderName = shader.name
        compileNow(force: true)
        updateChrome()
    }

    /// Opens a shader by name, discarding nothing — the caller is responsible
    /// for the unsaved-changes prompt. Used by the menu-free paths (`--selftest`).
    func openShader(named name: String) {
        guard let shader = metalView.shaderLibrary.shader(named: name) else { return }
        open(shader)
    }

    @objc private func shaderPopUpChanged() {
        guard let name = shaderPopUp.selectedItem?.representedObject as? String, name != current.name
        else { return }
        guard confirmDiscardIfDirty() else {
            select(current.name)
            return
        }
        if let shader = metalView.shaderLibrary.shader(named: name) { open(shader) }
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
        if shader.name != shownShaderName || shader.parameters != shownParameters {
            shownShaderName = shader.name
            shownParameters = shader.parameters
            let declared = Set(shader.parameters.map(\.name))
            parameterState = parameterState.filter { declared.contains($0.key) }
            inspector.rebuild(shader: shader)
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
        if isPaused { metalView.renderOnce() }
    }

    /// nil applies the shader's declared defaults.
    func applyPreset(_ name: String?) {
        guard let name else {
            for param in shownParameters { metalView.setParameter(param.name, param.defaultValue) }
            adoptViewValues()
            return
        }
        // `LerpMetalView.applyPreset` reads the shader off disk, which is only
        // the same thing as the editor buffer while there are no unsaved edits.
        // While editing, apply the preset the buffer itself declares.
        if !isDirty, metalView.applyPreset(named: name) {
            adoptViewValues()
        } else if let preset = compiled?.preset(named: name) {
            for param in shownParameters { metalView.setParameter(param.name, param.defaultValue) }
            for (key, value) in preset.values { metalView.setParameter(key, value) }
            adoptViewValues()
        }
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
        refreshMappingList()
        refreshBindingLabels()
    }

    private func refreshBindingLabels() {
        for param in shownParameters {
            inspector.setBinding(activeMapping?.bindings(for: param.name) ?? [], for: param.name)
        }
    }

    /// Test hook: the same "save it and make it live" path the menus take.
    func applyMapping(_ preset: MappingPreset) { commit(preset) }

    /// Test hooks: what the scrubber is actually showing, read off the real
    /// `NSSlider` rather than recomputed.
    var scrubberBounds: ClosedRange<Double> { timeSlider.minValue ... timeSlider.maxValue }
    var scrubberPosition: Double { timeSlider.doubleValue }
    var clockText: String { timeField.stringValue }

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
        refreshMappingList()
        refreshBindingLabels()
    }

    func receive(_ message: MIDIController.Message) {
        if let target = learnTarget {
            learnTarget = nil
            var preset = activeMapping
                ?? MappingPreset(name: message.sourceName.isEmpty ? "Default" : message.sourceName,
                                 deviceID: message.sourceID)
            // Omni by default: most controllers sit on a channel the user has
            // never chosen, and a binding that only works on one is a trap.
            preset.bind(MIDIBinding(paramID: target.param, channel: nil, cc: message.cc,
                                    component: learnComponent(target)))
            commit(preset)
            midiPanel.showStatus("Learned CC\(message.cc) → \(target.param)"
                                    + (learnComponent(target).map { " \($0.label)" } ?? ""),
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

    /// Test hook: what a CC does to a plain 0…1 float through `router`, so the
    /// range scoping the new min/max editor writes can be asserted against the
    /// real `resolve`, not a copy of it.
    func scopedValue(cc: UInt7, value: UInt8, on router: MIDIRouter) -> Double? {
        guard let routed = router.route(channel: 0, cc: cc, value: value) else { return nil }
        let param = LerpParam(name: routed.binding.paramID, type: .float, min: 0, max: 1,
                              defaultValue: .scalar(0), label: routed.binding.paramID)
        return resolve(routed.update, for: param, binding: routed.binding)?.scalarValue
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
            refreshMappingList()
            refreshBindingLabels()
        }
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

    @objc func saveShader(_ sender: Any?) {
        let url = current.url ?? ShaderPaths.newShaderDirectory.appendingPathComponent(current.name + ".metal")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try editor.text.write(to: url, atomically: true, encoding: .utf8)
            current = LerpShader(name: current.name, source: editor.text, isBuiltIn: false, url: url)
            updateChrome()
            compileNow(force: true)
        } catch {
            presentError("Could not save \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    @objc func revertShader(_ sender: Any?) {
        guard let url = current.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        current = LerpShader(name: current.name, source: text, isBuiltIn: current.isBuiltIn, url: url)
        editor.setText(text)
        compileNow(force: true)
        updateChrome()
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

    @objc func nextShader(_ sender: Any?) { step(1) }
    @objc func previousShader(_ sender: Any?) { step(-1) }

    /// Deliberately not `metalView.showNextShader` — that only swaps the
    /// pipeline, and the playground additionally has to prompt about unsaved
    /// edits and load the new file's source into the editor. It shares the
    /// wrap-around, which is the part that was worth having once.
    private func step(_ direction: Int) {
        guard confirmDiscardIfDirty(),
              let next = ShaderLibrary.name(in: knownShaderNames, after: current.name,
                                            offset: direction),
              let shader = metalView.shaderLibrary.shader(named: next) else { return }
        open(shader)
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

    /// One window back or forward. Because the window is derived from the
    /// clock, paging *is* seeking — there is no separate "where the scrubber is
    /// looking" that could disagree with where the shader is.
    @objc private func pageWindow(_ sender: NSSegmentedControl) {
        seek(to: metalView.time + (sender.selectedSegment == 0 ? -windowSpan : windowSpan))
    }

    @objc private func timeFieldChanged(_ sender: NSTextField) {
        guard let seconds = Self.seconds(fromClock: sender.stringValue) else {
            return refreshClock()      // unparseable: put the real time back
        }
        window?.makeFirstResponder(nil)
        seek(to: seconds)
    }

    @objc private func spanChanged() {
        let index = min(max(spanPopUp.indexOfSelectedItem, 0), Self.timeSpans.count - 1)
        windowSpan = Self.timeSpans[index].seconds
        lastScrub = 0
        syncTransport()
    }

    private static let renderScales: [(title: String, value: Double)] =
        [("100%", 1.0), ("75%", 0.75), ("50%", 0.5), ("25%", 0.25)]

    @objc private func scaleChanged() {
        let index = min(max(scalePopUp.indexOfSelectedItem, 0), Self.renderScales.count - 1)
        metalView.config.renderScale = Self.renderScales[index].value
        if isPaused { metalView.renderOnce() }
    }

    // MARK: - Chrome and polling

    private func updateChrome() {
        let dirty = isDirty
        saveButton.isEnabled = dirty
        revertButton.isEnabled = dirty && current.url != nil
        window?.title = "Lerping@Home Playground — \(current.name)\(dirty ? " •" : "")"
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
        // Reload the open file when it changed underneath us, but never clobber
        // unsaved edits.
        guard let fresh = shaders.first(where: { $0.name == current.name }),
              fresh.source != current.source, !isDirty else { return }
        current = fresh
        editor.setText(fresh.source)
        compileNow(force: true)   // has the last word on the status line
    }

    // MARK: - Prompts and window lifecycle

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
        case .alertFirstButtonReturn: saveShader(nil); return true
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

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfDirty() }

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
