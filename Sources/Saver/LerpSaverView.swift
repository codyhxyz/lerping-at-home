import AppKit
import ScreenSaver

/// Thin ScreenSaverView shim around LerpMetalView, with the known
/// legacyScreenSaver workarounds baked in:
///
/// - Since Sonoma the system never calls `stopAnimation` and never destroys
///   instances; we listen for the distributed `com.apple.screensaver.willstop`
///   notification and terminate the host process ourselves (the Aerial
///   workaround), but only when we're the real fullscreen saver, never the
///   System Settings preview.
/// - `isPreview` is unreliable on recent macOS, so a small frame also counts
///   as preview.
/// - We ignore `animateOneFrame` entirely; LerpMetalView drives its own
///   CADisplayLink with a capped frame rate.
@objc(LerpSaverView)
public final class LerpSaverView: ScreenSaverView, NSTableViewDataSource, NSTableViewDelegate {

    private static let defaultsModule = "com.hergenroeder.lerping"

    /// Names the user wants in the shuffle rotation.
    private static let enabledShadersKey = "enabledShaders"
    /// Every shader that existed the last time the rotation was saved. Anything
    /// discovered later counts as new and joins the rotation automatically.
    private static let knownShadersKey = "knownShaders"

    private var metalView: LerpMetalView?
    private var effectiveIsPreview = false
    private var configPanel: NSPanel?
    private var shaderPopup: NSPopUpButton?
    private var fpsPopup: NSPopUpButton?
    private var scalePopup: NSPopUpButton?
    private var freezePopup: NSPopUpButton?

    // Rotation list state, live only while the configure sheet is open.
    private var rotationNames: [String] = []
    private var rotationEnabled: Set<String> = []
    private var rotationTable: NSTableView?
    private var rotationLabel: NSTextField?
    private var rotationNote: NSTextField?
    private var rotationButtons: [NSButton] = []

    private static let freezeChoices: [(title: String, minutes: Double)] = [
        ("Never", 0), ("After 5 minutes", 5), ("After 15 minutes", 15), ("After 30 minutes", 30),
    ]

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        effectiveIsPreview = isPreview || frame.width < 600
        wantsLayer = true
        setUpMetalView()
        observeWillStop()
    }

    required init?(coder: NSCoder) { nil }

    private static func defaults() -> ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: defaultsModule)
    }

    private func discoveredShaderNames() -> [String] {
        metalView?.shaderLibrary.discover().map(\.name) ?? []
    }

    /// The shuffle rotation implied by saved defaults, or nil for "every shader".
    ///
    /// - Nothing ever saved (including every install that predates this setting):
    ///   nil, i.e. the full rotation. Never an empty one.
    /// - Saved names that no longer exist are dropped.
    /// - Shaders discovered since the last save default to enabled, so dropping a
    ///   new .metal file into the bundle does not silently do nothing.
    /// - An empty result is reported as nil (all shaders) rather than a black
    ///   screen. The sheet also refuses to persist an empty set, so this only
    ///   fires for hand-edited defaults or a rotation gone entirely stale.
    static func enabledShaders(discovered: [String], defaults: UserDefaults?) -> Set<String>? {
        guard let saved = defaults?.stringArray(forKey: enabledShadersKey) else { return nil }
        let all = Set(discovered)
        // No roster saved: take the saved list at face value, nothing is "new".
        let known = Set(defaults?.stringArray(forKey: knownShadersKey) ?? discovered)
        let enabled = all.intersection(saved).union(all.subtracting(known))
        return enabled.isEmpty ? nil : enabled
    }

    private func currentConfig() -> LerpMetalView.Config {
        let defaults = Self.defaults()
        let shader = defaults?.string(forKey: "shader")
        let fps = (defaults?.object(forKey: "fps") as? Int) ?? 30
        let renderScale = (defaults?.object(forKey: "renderScale") as? Double) ?? 1.0
        let shuffleMinutes = (defaults?.object(forKey: "shuffleMinutes") as? Double) ?? 5
        let freezeMinutes = (defaults?.object(forKey: "freezeAfterMinutes") as? Double) ?? 30
        var config = LerpMetalView.Config(
            shaderName: (shader == nil || shader == "Shuffle") ? nil : shader,
            framesPerSecond: fps,
            renderScale: renderScale,
            shuffleInterval: shuffleMinutes * 60,
            freezeAfter: freezeMinutes * 60)
        config.enabledShaderNames = Self.enabledShaders(discovered: discoveredShaderNames(),
                                                        defaults: defaults)
        return config
    }

    private func setUpMetalView() {
        guard let view = LerpMetalView(frame: bounds) else { return }
        // Assign first: currentConfig() discovers shaders through this view.
        metalView = view
        view.config = currentConfig()
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func observeWillStop() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.metalView?.stop()
                if !self.effectiveIsPreview {
                    // legacyScreenSaver never tears us down (rdar since Sonoma);
                    // exiting is the only reliable way to release the GPU.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        exit(0)
                    }
                }
            }
    }

    // MARK: - ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        metalView?.config = currentConfig()
        metalView?.start()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        metalView?.stop()
    }

    public override func animateOneFrame() {
        // Rendering is driven by LerpMetalView's display link.
    }

    // MARK: - Configure sheet

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Lerping@Home"

        let defaults = Self.defaults()
        let shaderNames = discoveredShaderNames()

        let shaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shaderPopup.addItem(withTitle: "Shuffle")
        shaderPopup.addItems(withTitles: shaderNames)
        let selected = defaults?.string(forKey: "shader") ?? "Shuffle"
        shaderPopup.selectItem(withTitle: shaderNames.contains(selected) ? selected : "Shuffle")
        shaderPopup.target = self
        shaderPopup.action = #selector(shaderModeChanged)

        // Rotation subset. Unset defaults mean "everything", so an upgrade (or a
        // fresh install) starts with every shader checked.
        rotationNames = shaderNames
        rotationEnabled = Self.enabledShaders(discovered: shaderNames, defaults: defaults)
            ?? Set(shaderNames)

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shader")))
        table.dataSource = self
        table.delegate = self
        rotationTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 230),
            scroll.heightAnchor.constraint(equalToConstant: 200),
        ])

        func listButton(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            return button
        }
        let selectAll = listButton("Select All", #selector(selectAllShaders))
        let deselectAll = listButton("Deselect All", #selector(deselectAllShaders))
        rotationButtons = [selectAll, deselectAll]
        let listControls = NSStackView(views: [selectAll, deselectAll])
        listControls.spacing = 8

        // Always-present status line: keeps the sheet a fixed height and says
        // out loud what an empty selection will do.
        let note = NSTextField(labelWithString: "")
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        rotationNote = note

        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["24", "30", "60"])
        fpsPopup.selectItem(withTitle: String((defaults?.object(forKey: "fps") as? Int) ?? 30))

        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scalePopup.addItems(withTitles: ["100%", "75%", "50%"])
        let scale = (defaults?.object(forKey: "renderScale") as? Double) ?? 1.0
        scalePopup.selectItem(at: scale >= 0.99 ? 0 : (scale >= 0.74 ? 1 : 2))

        let freezePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        freezePopup.addItems(withTitles: Self.freezeChoices.map(\.title))
        let freezeMinutes = (defaults?.object(forKey: "freezeAfterMinutes") as? Double) ?? 30
        let freezeIndex = Self.freezeChoices.firstIndex { $0.minutes == freezeMinutes } ?? 3
        freezePopup.selectItem(at: freezeIndex)

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }

        let inRotation = label("In rotation:")
        rotationLabel = inRotation

        let grid = NSGridView(views: [
            [label("Shader:"), shaderPopup],
            [inRotation, scroll],
            [NSGridCell.emptyContentView, listControls],
            [NSGridCell.emptyContentView, note],
            [label("Frame rate:"), fpsPopup],
            [label("Render scale:"), scalePopup],
            [label("Still image:"), freezePopup],
        ])
        grid.column(at: 0).width = 100
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).topPadding = 6
        grid.row(at: 1).yPlacement = .top
        grid.row(at: 2).yPlacement = .center
        grid.row(at: 3).bottomPadding = 6
        grid.translatesAutoresizingMaskIntoConstraints = false

        let ok = NSButton(title: "OK", target: self, action: #selector(configureSheetOK))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(configureSheetCancel))
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        self.configPanel = panel
        self.shaderPopup = shaderPopup
        self.fpsPopup = fpsPopup
        self.scalePopup = scalePopup
        self.freezePopup = freezePopup
        updateRotationControls()
        // Grow the sheet to whatever the rotation list needs.
        let fitting = content.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 360), height: max(fitting.height, 300)))
        return panel
    }

    // MARK: - Rotation list

    private var isShuffleMode: Bool { (shaderPopup?.indexOfSelectedItem ?? 0) == 0 }

    @objc private func shaderModeChanged() {
        updateRotationControls()
    }

    @objc private func selectAllShaders() {
        rotationEnabled = Set(rotationNames)
        updateRotationControls()
    }

    @objc private func deselectAllShaders() {
        rotationEnabled.removeAll()
        updateRotationControls()
    }

    @objc private func rotationCheckboxToggled(_ sender: NSButton) {
        guard rotationNames.indices.contains(sender.tag) else { return }
        let name = rotationNames[sender.tag]
        if sender.state == .on {
            rotationEnabled.insert(name)
        } else {
            rotationEnabled.remove(name)
        }
        updateRotationControls()
    }

    /// The list only applies to shuffle mode; pinning one shader greys it out.
    private func updateRotationControls() {
        let active = isShuffleMode
        rotationTable?.isEnabled = active
        rotationTable?.reloadData()
        rotationButtons.forEach { $0.isEnabled = active }
        rotationLabel?.textColor = active ? .labelColor : .disabledControlTextColor
        rotationNote?.textColor = active ? .secondaryLabelColor : .disabledControlTextColor
        if rotationNames.isEmpty {
            rotationNote?.stringValue = "No shaders found."
        } else if !active {
            rotationNote?.stringValue = "Rotation applies to Shuffle."
        } else if rotationEnabled.isEmpty {
            rotationNote?.stringValue = "Nothing checked — using all \(rotationNames.count)."
        } else {
            rotationNote?.stringValue = "\(rotationEnabled.count) of \(rotationNames.count) shaders in rotation."
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rotationNames.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard rotationNames.indices.contains(row) else { return nil }
        let name = rotationNames[row]
        let check = NSButton(checkboxWithTitle: name,
                             target: self,
                             action: #selector(rotationCheckboxToggled(_:)))
        check.tag = row
        check.state = rotationEnabled.contains(name) ? .on : .off
        check.isEnabled = isShuffleMode
        return check
    }

    @objc private func configureSheetOK() {
        if let defaults = Self.defaults() {
            let shader = shaderPopup?.titleOfSelectedItem ?? "Shuffle"
            defaults.set(shader, forKey: "shader")
            if !rotationNames.isEmpty {
                // Never persist an empty rotation: nothing checked means "all",
                // which is what the sheet's note promises.
                let enabled = rotationEnabled.isEmpty ? Set(rotationNames) : rotationEnabled
                defaults.set(rotationNames.filter(enabled.contains), forKey: Self.enabledShadersKey)
                defaults.set(rotationNames, forKey: Self.knownShadersKey)
            }
            defaults.set(Int(fpsPopup?.titleOfSelectedItem ?? "30") ?? 30, forKey: "fps")
            let scale: Double
            switch scalePopup?.indexOfSelectedItem ?? 0 {
            case 1: scale = 0.75
            case 2: scale = 0.5
            default: scale = 1.0
            }
            defaults.set(scale, forKey: "renderScale")
            let freezeIndex = freezePopup?.indexOfSelectedItem ?? 3
            defaults.set(Self.freezeChoices[max(0, min(freezeIndex, Self.freezeChoices.count - 1))].minutes,
                         forKey: "freezeAfterMinutes")
            defaults.synchronize()
        }
        metalView?.config = currentConfig()
        endConfigureSheet()
    }

    @objc private func configureSheetCancel() {
        endConfigureSheet()
    }

    private func endConfigureSheet() {
        guard let panel = configPanel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        configPanel = nil
        rotationTable = nil
        rotationLabel = nil
        rotationNote = nil
        rotationButtons = []
    }
}
