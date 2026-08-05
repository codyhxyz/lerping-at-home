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

    // MARK: Views

    let editor = ShaderEditorView(frame: NSRect(x: 0, y: 0, width: 700, height: 700))
    private(set) var metalView: LerpMetalView!
    private let splitViewController = NSSplitViewController()

    private let shaderPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let saveButton = NSButton()
    private let revertButton = NSButton()
    private let statusButton = NSButton()
    private let consoleTextView = NSTextView()
    private let consoleScrollView = NSScrollView()
    private var consoleHeight: NSLayoutConstraint!

    private let playButton = NSButton()
    private let timeSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "t 0.0s")
    private let scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fpsLabel = NSTextField(labelWithString: "— fps")

    // MARK: State

    /// Outcome of the most recent compile. Drives the status bar, and is what
    /// `--selftest` asserts on.
    enum CompileState {
        case pending
        case ok(milliseconds: Double)
        case failed([ShaderDiagnostic])
    }

    private(set) var compileState: CompileState = .pending
    private(set) var currentName = ""
    private var currentURL: URL?
    private var savedSource = ""
    private var lastCompiledSource: String?
    private var currentModDate: Date?
    private(set) var knownShaderNames: [String] = []

    private var isPaused = false
    private var lastScrub: CFTimeInterval = 0
    private var compileWork: DispatchWorkItem?
    private var uiTimer: Timer?
    private var watchTimer: Timer?
    private var firstErrorLine: Int?
    private var statusResetWork: DispatchWorkItem?

    private var isDirty: Bool { editor.text != savedSource }

    // MARK: Init

    /// Returns nil when there is no Metal device to render with.
    static func make() -> PlaygroundWindowController? {
        let repoShaders = ShaderPaths.repoShaderDirectory()
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 760, height: 760),
                                       extraSearchURLs: repoShaders.map { [$0] } ?? []) else { return nil }
        return PlaygroundWindowController(metalView: view)
    }

    private init(metalView view: LerpMetalView) {
        metalView = view

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 500)
        window.titlebarAppearsTransparent = false
        super.init(window: window)
        window.delegate = self

        buildUI()
        loadShaderList(selecting: nil)
        startTimers()

        // Assigning contentViewController resizes the window to the split
        // view's fitting size, so pick the real size afterwards. Clamped to the
        // screen so this is sane on a laptop display too.
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setContentSize(NSSize(width: min(1500, visible.width - 40),
                                     height: min(920, visible.height - 40)))
        window.center()
        window.setFrameAutosaveName(Self.windowAutosaveName)
    }

    private static let windowAutosaveName = "LerpPlaygroundWindow"
    private static let splitAutosaveName = "LerpPlaygroundSplit"

    required init?(coder: NSCoder) { nil }

    deinit {
        uiTimer?.invalidate()
        watchTimer?.invalidate()
    }

    // MARK: - UI construction

    private func buildUI() {
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = Self.splitAutosaveName

        let editorItem = NSSplitViewItem(viewController: wrap(buildEditorPane()))
        editorItem.minimumThickness = 380
        let renderItem = NSSplitViewItem(viewController: wrap(buildRenderPane()))
        renderItem.minimumThickness = 300
        splitViewController.addSplitViewItem(editorItem)
        splitViewController.addSplitViewItem(renderItem)

        window?.contentViewController = splitViewController
    }

    private func wrap(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func buildEditorPane() -> NSView {
        shaderPopUp.translatesAutoresizingMaskIntoConstraints = false
        shaderPopUp.target = self
        shaderPopUp.action = #selector(shaderPopUpChanged)
        shaderPopUp.controlSize = .small
        shaderPopUp.font = .systemFont(ofSize: 11)
        shaderPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(saveButton, title: "Save", action: #selector(saveShader))
        configure(revertButton, title: "Revert", action: #selector(revertShader))
        let newButton = NSButton()
        configure(newButton, title: "New…", action: #selector(newShader))

        let header = headerBar([shaderPopUp, newButton, saveButton, revertButton])
        shaderPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        statusButton.title = "Ready"
        statusButton.isBordered = false
        statusButton.target = self
        statusButton.action = #selector(jumpToFirstError)
        statusButton.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        statusButton.alignment = .left
        statusButton.contentTintColor = EditorTheme.gutterText
        statusButton.translatesAutoresizingMaskIntoConstraints = false

        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = EditorTheme.gutter.cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusButton)
        NSLayoutConstraint.activate([
            statusBar.heightAnchor.constraint(equalToConstant: 22),
            statusButton.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusButton.trailingAnchor.constraint(lessThanOrEqualTo: statusBar.trailingAnchor, constant: -8),
            statusButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])

        consoleTextView.isEditable = false
        consoleTextView.isSelectable = true
        consoleTextView.drawsBackground = true
        consoleTextView.backgroundColor = NSColor(srgbRed: 0.145, green: 0.078, blue: 0.086, alpha: 1)
        consoleTextView.textColor = NSColor(srgbRed: 1.0, green: 0.706, blue: 0.694, alpha: 1)
        consoleTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        consoleTextView.textContainerInset = NSSize(width: 8, height: 6)
        consoleScrollView.documentView = consoleTextView
        consoleScrollView.hasVerticalScroller = true
        consoleScrollView.drawsBackground = true
        consoleScrollView.backgroundColor = consoleTextView.backgroundColor
        consoleScrollView.borderType = .noBorder
        consoleScrollView.translatesAutoresizingMaskIntoConstraints = false
        consoleHeight = consoleScrollView.heightAnchor.constraint(equalToConstant: 0)
        consoleHeight.isActive = true

        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.onEdit = { [weak self] in self?.scheduleCompile() }

        return verticalStack([header, editor, statusBar, consoleScrollView])
    }

    private func buildRenderPane() -> NSView {
        configure(playButton, title: "Pause", action: #selector(togglePlayPause))
        playButton.widthAnchor.constraint(equalToConstant: 62).isActive = true

        for control in [timeSlider as NSView, timeLabel, scalePopUp, fpsLabel] {
            control.translatesAutoresizingMaskIntoConstraints = false
        }
        timeSlider.minValue = 0
        timeSlider.maxValue = 180
        timeSlider.doubleValue = 0
        timeSlider.isContinuous = true
        timeSlider.controlSize = .small
        timeSlider.target = self
        timeSlider.action = #selector(timeSliderChanged)
        timeSlider.widthAnchor.constraint(equalToConstant: 170).isActive = true

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timeLabel.textColor = EditorTheme.gutterText
        timeLabel.widthAnchor.constraint(equalToConstant: 62).isActive = true

        let seedButton = NSButton()
        configure(seedButton, title: "Re-roll seed", action: #selector(rerollSeed))

        scalePopUp.controlSize = .small
        scalePopUp.font = .systemFont(ofSize: 11)
        scalePopUp.target = self
        scalePopUp.action = #selector(scaleChanged)
        for title in ["100%", "75%", "50%", "25%"] { scalePopUp.addItem(withTitle: title) }
        scalePopUp.widthAnchor.constraint(equalToConstant: 78).isActive = true

        fpsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        fpsLabel.textColor = EditorTheme.gutterText
        fpsLabel.alignment = .right
        fpsLabel.widthAnchor.constraint(equalToConstant: 78).isActive = true

        let header = headerBar([playButton, timeSlider, timeLabel, seedButton, scalePopUp, spacer(), fpsLabel])

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: 60,
                                                renderScale: 1.0, shuffleInterval: .infinity)
        metalView.onCompileError = { name, message in
            FileHandle.standardError.write("compile error in \(name):\n\(message)\n".data(using: .utf8)!)
        }

        return verticalStack([header, metalView])
    }

    // MARK: Layout helpers

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        return view
    }

    private func headerBar(_ controls: [NSView]) -> NSView {
        let stack = NSStackView(views: controls)
        stack.orientation = .horizontal
        stack.spacing = 7
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(srgbRed: 0.114, green: 0.122, blue: 0.145, alpha: 1).cgColor
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            bar.heightAnchor.constraint(equalToConstant: 38),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    private func verticalStack(_ views: [NSView]) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = EditorTheme.background.cgColor
        var previous: NSView?
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                previous.map { view.topAnchor.constraint(equalTo: $0.bottomAnchor) }
                    ?? view.topAnchor.constraint(equalTo: container.topAnchor),
            ])
            previous = view
        }
        previous?.bottomAnchor.constraint(equalTo: container.bottomAnchor).isActive = true
        return container
    }

    // MARK: - Shader list

    private func loadShaderList(selecting wanted: String?) {
        let shaders = metalView.shaderLibrary.discover()
        knownShaderNames = shaders.map(\.name)

        shaderPopUp.removeAllItems()
        for shader in shaders {
            shaderPopUp.addItem(withTitle: shader.isBuiltIn ? shader.name : shader.name + "  · custom")
            shaderPopUp.lastItem?.representedObject = shader.name
        }
        guard !shaders.isEmpty else {
            setStatus("No shaders found. Use New… to create one.", tint: EditorTheme.preprocessor)
            return
        }

        let target = wanted ?? (currentName.isEmpty ? shaders[0].name : currentName)
        let shader = shaders.first { $0.name == target } ?? shaders[0]
        selectMenuItem(named: shader.name)
        if shader.name != currentName || currentURL == nil {
            open(shader)
        }
    }

    private func selectMenuItem(named name: String) {
        for item in shaderPopUp.itemArray where (item.representedObject as? String) == name {
            shaderPopUp.select(item)
            return
        }
    }

    private func open(_ shader: LerpShader) {
        currentName = shader.name
        currentURL = shader.url
        savedSource = shader.source
        editor.setText(shader.source)
        currentModDate = shader.url.flatMap(modificationDate(of:))
        metalView.config.shaderName = shader.name
        lastCompiledSource = nil
        compileNow(force: true)
        updateChrome()
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @objc private func shaderPopUpChanged() {
        guard let name = shaderPopUp.selectedItem?.representedObject as? String, name != currentName else { return }
        guard confirmDiscardIfDirty() else {
            selectMenuItem(named: currentName)
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
        guard !currentName.isEmpty else { return }
        let source = editor.text
        if !force, source == lastCompiledSource { return }
        lastCompiledSource = source

        let library = metalView.shaderLibrary
        // The cache is keyed on source, so hot reload would grow it without
        // bound; we only ever need the one pipeline that is on screen.
        library.clearPipelineCache()

        let draft = LerpShader(name: currentName, source: source, isBuiltIn: false, url: currentURL)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            _ = try library.pipeline(for: draft)
            metalView.setShader(draft)         // cache hit, cannot fail
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            compileState = .ok(milliseconds: ms)
            editor.setErrorLines([])
            firstErrorLine = nil
            showConsole(false)
            setStatus(String(format: "✓  compiled in %.0f ms", ms),
                      tint: NSColor(srgbRed: 0.42, green: 0.84, blue: 0.55, alpha: 1))
        } catch {
            let (items, raw) = ShaderDiagnostics.parse(error)
            compileState = .failed(items)
            let errors = items.filter(\.isError)
            let lines = Set(errors.map(\.line))
            editor.setErrorLines(lines)
            firstErrorLine = errors.map(\.line).min()
            consoleTextView.string = ShaderDiagnostics.summary(items: items, raw: raw)
            showConsole(true)
            let count = max(errors.count, 1)
            setStatus("✗  \(count) error\(count == 1 ? "" : "s") — last good shader still running"
                        + (firstErrorLine != nil ? "  (click to jump)" : ""),
                      tint: EditorTheme.errorTint)
        }
        if isPaused { metalView.renderOnce() }
    }

    private func showConsole(_ visible: Bool) {
        let target: CGFloat = visible ? 132 : 0
        guard consoleHeight.constant != target else { return }
        consoleHeight.constant = target
    }

    private func setStatus(_ text: String, tint: NSColor) {
        statusResetWork?.cancel()
        statusButton.title = text
        statusButton.contentTintColor = tint
        statusButton.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: tint,
                         .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)])
    }

    private func flashStatus(_ text: String) {
        setStatus(text, tint: EditorTheme.builtin)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastCompiledSource = nil
            self.compileNow(force: true)
        }
        statusResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    @objc private func jumpToFirstError() {
        guard let line = firstErrorLine else { return }
        editor.scrollToLine(line)
    }

    // MARK: - Actions

    @objc func recompile(_ sender: Any?) {
        compileNow(force: true)
    }

    @objc func saveShader(_ sender: Any?) {
        let url = currentURL ?? ShaderPaths.newShaderDirectory().appendingPathComponent(currentName + ".metal")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try editor.text.write(to: url, atomically: true, encoding: .utf8)
            savedSource = editor.text
            currentURL = url
            currentModDate = modificationDate(of: url)
            updateChrome()
            compileNow(force: true)
        } catch {
            presentError("Could not save \(url.lastPathComponent)", error.localizedDescription)
        }
    }

    @objc func revertShader(_ sender: Any?) {
        guard let url = currentURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        editor.setText(text)
        savedSource = text
        currentModDate = modificationDate(of: url)
        lastCompiledSource = nil
        compileNow(force: true)
        updateChrome()
    }

    @objc func newShader(_ sender: Any?) {
        guard confirmDiscardIfDirty() else { return }
        let directory = ShaderPaths.newShaderDirectory()

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
        currentName = ""    // force a reopen even if the name matched
        loadShaderList(selecting: stem)
        window?.makeFirstResponder(editor.textView)
    }

    @objc func nextShader(_ sender: Any?) { step(1) }
    @objc func previousShader(_ sender: Any?) { step(-1) }

    private func step(_ direction: Int) {
        guard !knownShaderNames.isEmpty, confirmDiscardIfDirty() else { return }
        let index = knownShaderNames.firstIndex(of: currentName) ?? 0
        let next = (index + direction + knownShaderNames.count) % knownShaderNames.count
        if let shader = metalView.shaderLibrary.shader(named: knownShaderNames[next]) {
            selectMenuItem(named: shader.name)
            open(shader)
        }
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
        flashStatus(String(format: "seed = %.4f", metalView.seed))
    }

    @objc private func timeSliderChanged() {
        lastScrub = CACurrentMediaTime()
        metalView.time = timeSlider.doubleValue
        if isPaused { metalView.renderOnce() }
        updateTimeLabel()
    }

    @objc private func scaleChanged() {
        let scales = [1.0, 0.75, 0.5, 0.25]
        metalView.config.renderScale = scales[min(scalePopUp.indexOfSelectedItem, scales.count - 1)]
        if isPaused { metalView.renderOnce() }
    }

    // MARK: - Chrome

    private func updateChrome() {
        let dirty = isDirty
        saveButton.isEnabled = dirty
        revertButton.isEnabled = dirty && currentURL != nil
        window?.title = "Lerping@Home Playground — \(currentName)\(dirty ? " •" : "")"
        window?.isDocumentEdited = dirty
    }

    private func updateTimeLabel() {
        timeLabel.stringValue = String(format: "t %.1fs", metalView.time)
    }

    private func startTimers() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let time = self.metalView.time
            if CACurrentMediaTime() - self.lastScrub > 0.4 {
                if time <= self.timeSlider.maxValue {
                    self.timeSlider.doubleValue = time
                } else {
                    // Past the end of the scrubber; keep the knob pinned right.
                    self.timeSlider.doubleValue = self.timeSlider.maxValue
                }
            }
            self.updateTimeLabel()
            let scale = self.metalView.window?.backingScaleFactor ?? 2
            let pixels = CGSize(width: self.metalView.bounds.width * scale * self.metalView.config.renderScale,
                                height: self.metalView.bounds.height * scale * self.metalView.config.renderScale)
            self.fpsLabel.stringValue = self.isPaused
                ? "paused"
                : String(format: "%.0f fps", self.metalView.measuredFPS)
            self.fpsLabel.toolTip = String(format: "%.0f × %.0f px", pixels.width, pixels.height)
        }

        // Pick up shaders added or edited outside the app (another editor, or
        // `git pull`). Cheap enough at this interval: a directory listing plus
        // one stat of the open file.
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollDisk()
        }
    }

    func pollDisk() {
        let names = metalView.shaderLibrary.discover().map(\.name)
        if names != knownShaderNames {
            loadShaderList(selecting: currentName.isEmpty ? nil : currentName)
        }
        guard let url = currentURL, let modified = modificationDate(of: url) else { return }
        guard modified != currentModDate else { return }
        currentModDate = modified
        guard !isDirty, let text = try? String(contentsOf: url, encoding: .utf8), text != editor.text else { return }
        editor.setText(text)
        savedSource = text
        lastCompiledSource = nil
        compileNow(force: true)
        flashStatus("Reloaded \(url.lastPathComponent) from disk")
    }

    // MARK: - Prompts

    @discardableResult
    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(currentName).metal?"
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

    // MARK: - Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) {
        pollDisk()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmDiscardIfDirty()
    }

    func showAndStart() {
        window?.makeKeyAndOrderFront(nil)
        metalView.start()
        window?.makeFirstResponder(editor.textView)
        // Default to a 50/50 split, but never fight a divider the user has
        // already dragged (NSSplitView autosaves that).
        let hasSavedSplit = UserDefaults.standard
            .object(forKey: "NSSplitView Subview Frames " + Self.splitAutosaveName) != nil
        guard !hasSavedSplit else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let width = self.window?.contentView?.bounds.width else { return }
            self.splitViewController.splitView.setPosition(width * 0.5, ofDividerAt: 0)
        }
    }
}
