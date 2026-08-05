import AppKit
import Metal
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

    private let split = NSSplitViewController()
    private let shaderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let saveButton = NSButton(), revertButton = NSButton(), playButton = NSButton()
    private let status = NSButton()
    private let console = NSTextView()
    private let consoleScroll = NSScrollView()
    private var consoleHeight: NSLayoutConstraint!
    private let timeSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "t 0.0s")
    private let scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsLabel = NSTextField(labelWithString: "— fps")

    private var isPaused = false
    private var lastScrub: CFTimeInterval = 0
    private var lastCompiledSource: String?
    private var firstErrorLine: Int?
    private var compileWork: DispatchWorkItem?
    private var timers: [Timer] = []

    private static let windowAutosave = "LerpPlaygroundWindow"
    private static let splitAutosave = "LerpPlaygroundSplit"

    // MARK: - Init

    /// Returns nil when there is no Metal device to render with.
    static func make() -> PlaygroundWindowController? {
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 760, height: 760),
                                       extraSearchURLs: ShaderPaths.repoShaders.map { [$0] } ?? [])
        else { return nil }
        return PlaygroundWindowController(metalView: view)
    }

    private init(metalView view: LerpMetalView) {
        metalView = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 500)
        super.init(window: window)
        window.delegate = self

        buildUI()
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
        window.setFrameAutosaveName(Self.windowAutosave)
    }

    required init?(coder: NSCoder) { nil }

    deinit { timers.forEach { $0.invalidate() } }

    // MARK: - UI construction

    private func buildUI() {
        split.splitView.isVertical = true
        split.splitView.dividerStyle = .thin
        split.splitView.autosaveName = Self.splitAutosave

        for (view, minimum) in [(editorPane(), 380.0), (renderPane(), 300.0)] {
            let controller = NSViewController()
            controller.view = view
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = minimum
            split.addSplitViewItem(item)
        }
        window?.contentViewController = split
    }

    private func editorPane() -> NSView {
        shaderPopUp.target = self
        shaderPopUp.action = #selector(shaderPopUpChanged)
        shaderPopUp.controlSize = .small
        shaderPopUp.font = .systemFont(ofSize: 11)
        shaderPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        let newButton = NSButton()
        configure(newButton, title: "New…", action: #selector(newShader))
        configure(saveButton, title: "Save", action: #selector(saveShader))
        configure(revertButton, title: "Revert", action: #selector(revertShader))

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

        return pane([bar([shaderPopUp, newButton, saveButton, revertButton, flexible()]),
                     editor,
                     bar([status, flexible()], height: 22),
                     consoleScroll])
    }

    private func renderPane() -> NSView {
        configure(playButton, title: "Pause", action: #selector(togglePlayPause))
        playButton.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let seedButton = NSButton()
        configure(seedButton, title: "Re-roll seed", action: #selector(rerollSeed))

        timeSlider.maxValue = 180
        timeSlider.controlSize = .small
        timeSlider.target = self
        timeSlider.action = #selector(timeSliderChanged)
        timeSlider.widthAnchor.constraint(equalToConstant: 170).isActive = true

        scalePopUp.controlSize = .small
        scalePopUp.font = .systemFont(ofSize: 11)
        scalePopUp.target = self
        scalePopUp.action = #selector(scaleChanged)
        scalePopUp.addItems(withTitles: Self.renderScales.map(\.title))
        scalePopUp.widthAnchor.constraint(equalToConstant: 78).isActive = true

        for (label, width) in [(timeLabel, 62.0), (fpsLabel, 78.0)] {
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            label.textColor = EditorTheme.dim
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        fpsLabel.alignment = .right

        metalView.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: 60,
                                                renderScale: 1.0, shuffleInterval: .infinity)
        metalView.onCompileError = { name, message in
            FileHandle.standardError.write(Data("compile error in \(name):\n\(message)\n".utf8))
        }
        metalView.setContentHuggingPriority(.init(1), for: .vertical)

        return pane([bar([playButton, timeSlider, timeLabel, seedButton, scalePopUp,
                          flexible(), fpsLabel]),
                     metalView])
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// A control strip. One `flexible()` in `controls` decides where the slack
    /// goes — without one the stack's horizontal placement is ambiguous.
    private func bar(_ controls: [NSView], height: CGFloat = 38) -> NSView {
        let stack = NSStackView(views: controls)
        stack.distribution = .fill
        stack.spacing = 7
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = EditorTheme.chrome.cgColor
        stack.heightAnchor.constraint(equalToConstant: height).isActive = true
        return stack
    }

    private func flexible() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func pane(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width      // every row spans the pane
        stack.spacing = 0
        stack.wantsLayer = true
        stack.layer?.backgroundColor = EditorTheme.background.cgColor
        return stack
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
        select(shader.name)
        editor.setText(shader.source)
        metalView.config.shaderName = shader.name
        compileNow(force: true)
        updateChrome()
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

    // MARK: - Actions

    @objc func recompile(_ sender: Any?) { compileNow(force: true) }

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

        let alert = NSAlert()
        alert.messageText = "New shader"
        alert.informativeText = "The file name becomes the shader name.\nSaving to \(directory.path)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "aurora-veil"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let stem = ShaderScaffold.sanitize(name: field.stringValue) else {
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

    private func step(_ direction: Int) {
        guard !knownShaderNames.isEmpty, confirmDiscardIfDirty() else { return }
        let index = knownShaderNames.firstIndex(of: current.name) ?? 0
        let next = (index + direction + knownShaderNames.count) % knownShaderNames.count
        if let shader = metalView.shaderLibrary.shader(named: knownShaderNames[next]) { open(shader) }
    }

    @objc func togglePlayPause(_ sender: Any?) {
        isPaused.toggle()
        if isPaused {
            metalView.stop()
            metalView.renderOnce()
        } else {
            metalView.start()
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
        if isPaused { metalView.renderOnce() }
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
            // Leave the knob alone briefly after a drag so it doesn't fight the
            // user, and pin it right once the clock runs past the scrubber.
            if CACurrentMediaTime() - lastScrub > 0.4 {
                timeSlider.doubleValue = min(metalView.time, timeSlider.maxValue)
            }
            timeLabel.stringValue = String(format: "t %.1fs", metalView.time)
            fpsLabel.stringValue = isPaused ? "paused" : String(format: "%.0f fps", metalView.measuredFPS)
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

    private func presentError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    func windowDidBecomeKey(_ notification: Notification) { pollDisk() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscardIfDirty() }

    func showAndStart() {
        window?.makeKeyAndOrderFront(nil)
        metalView.start()
        window?.makeFirstResponder(editor.textView)
        // Default to a 50/50 split, but never fight a divider the user has
        // already dragged (NSSplitView autosaves that).
        guard UserDefaults.standard
            .object(forKey: "NSSplitView Subview Frames " + Self.splitAutosave) == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let width = window?.contentView?.bounds.width else { return }
            split.splitView.setPosition(width * 0.5, ofDividerAt: 0)
        }
    }
}
