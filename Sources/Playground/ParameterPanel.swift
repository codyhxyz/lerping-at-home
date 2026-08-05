import AppKit

/// The inspector: one stock control per `// lerp-param:` the open shader
/// declares, plus a popup for its `// lerp-preset:` blocks.
///
/// Everything here is built from `LerpShader.parameters` at rebuild time. There
/// is no per-shader knowledge in this file and no table of names — a shader that
/// gains a parameter gains a row the moment it recompiles, and one that declares
/// none gets the empty state.
final class ParameterPanel: NSView {

    /// A control moved. The value is already clamped to the declared range.
    var onChange: ((String, LerpParamValue) -> Void)?
    /// A preset was picked. nil is the "Defaults" entry.
    var onPreset: ((String?) -> Void)?
    /// A row's MIDI menu was used. The component is nil for everything that is
    /// not a colour, and names the axis for the ones that are.
    var onMIDICommand: ((String, ColorComponent?, MIDICommand) -> Void)?

    enum MIDICommand {
        case learn
        case clear
        /// Every axis of a colour at once, from the row's top-level menu.
        case clearAll
        case mode(MIDIBindingMode)
        /// Open the min/max editor for this binding.
        case range
    }

    private(set) var parameters: [LerpParam] = []

    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scroll = NSScrollView()
    private let rowStack = NSStackView()
    private let empty = Chrome.label("", size: 11.5)
    private var rows: [String: Row] = [:]
    /// Set while `show(values:)` is pushing values into controls, so the
    /// controls' own actions don't echo back out as user edits.
    private var isPushing = false
    /// Shown when MIDI is unavailable: the per-row menus are hidden entirely
    /// rather than offered and then failing.
    var showsMIDIControls = false { didSet { refreshMIDIVisibility() } }

    private final class TopClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    /// Label, control, optional numeric echo, MIDI menu, and what that menu is
    /// currently describing — a scalar has at most one binding, a colour up to
    /// one per OKLCH axis.
    private final class Row {
        let param: LerpParam
        let control: NSControl
        let field: NSTextField?
        let midi: NSPopUpButton?
        let view: NSView
        var bindings: [MIDIBinding] = []
        init(param: LerpParam, control: NSControl, field: NSTextField?,
             midi: NSPopUpButton?, view: NSView) {
            self.param = param; self.control = control; self.field = field
            self.midi = midi; self.view = view
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        presetPopUp.controlSize = .small
        presetPopUp.font = .systemFont(ofSize: 11)
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged)
        presetPopUp.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 5
        rowStack.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 10, right: 9)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.setHuggingPriority(.defaultHigh, for: .vertical)

        // AppKit parks a document view shorter than its clip view at the bottom
        // of it. A flipped clip view is the fix: rows start at the top and grow
        // downward, which is what every other inspector on the platform does.
        scroll.contentView = TopClipView()
        scroll.documentView = rowStack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background
        scroll.borderType = .noBorder

        empty.alignment = .center
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 0

        let body = Chrome.pane([Chrome.bar([Chrome.label("Preset"), presetPopUp,
                                            Chrome.flexible()], height: 32),
                                scroll])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Building

    /// Throws away every control and builds the panel from `shader`. Called when
    /// the open shader changes *and* when a recompile changes the declarations,
    /// so editing a `// lerp-param:` line is reflected as soon as it compiles.
    func rebuild(shader: LerpShader?) {
        parameters = shader?.parameters ?? []
        rows.removeAll()
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        presetPopUp.removeAllItems()
        presetPopUp.addItem(withTitle: "Defaults")
        for preset in shader?.presets ?? [] { presetPopUp.addItem(withTitle: preset.name) }
        presetPopUp.selectItem(at: 0)
        presetPopUp.isEnabled = !(shader?.presets.isEmpty ?? true)

        guard !parameters.isEmpty else {
            empty.stringValue = shader.map {
                "\($0.name) declares no parameters.\n\nAdd one to the .metal file:"
                    + "\n// lerp-param: swirl float 0 1 = 0.35 \"Swirl\""
            } ?? "No shader open."
            rowStack.addArrangedSubview(empty)
            return
        }
        for param in parameters {
            let row = makeRow(param)
            rows[param.name] = row
            rowStack.addArrangedSubview(row.view)
        }
        refreshMIDIVisibility()
    }

    private func makeRow(_ param: LerpParam) -> Row {
        let name = Chrome.label(param.label, size: 11, color: EditorTheme.text)
        name.toolTip = "\(param.name) — \(param.type.rawValue)"
        name.widthAnchor.constraint(equalToConstant: 96).isActive = true

        var field: NSTextField?
        let control: NSControl
        switch param.type {
        case .float, .int:
            let slider = NSSlider()
            slider.minValue = param.min
            slider.maxValue = param.max
            slider.isContinuous = true
            slider.controlSize = .small
            if param.type == .int, param.max - param.min <= 24 {
                slider.numberOfTickMarks = Int(param.max - param.min) + 1
                slider.allowsTickMarkValuesOnly = true
            }
            let echo = NSTextField(string: "")
            echo.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            echo.alignment = .right
            echo.controlSize = .small
            echo.widthAnchor.constraint(equalToConstant: 48).isActive = true
            echo.target = self
            echo.action = #selector(fieldChanged)
            field = echo
            control = slider
        case .bool:
            control = NSSwitch()
        case .color:
            let well = NSColorWell()
            well.isContinuous = true
            // `color` parameters carry alpha, so the picker has to offer it.
            well.supportsAlpha = true
            well.widthAnchor.constraint(equalToConstant: 46).isActive = true
            well.heightAnchor.constraint(equalToConstant: 20).isActive = true
            control = well
        }
        control.target = self
        control.action = #selector(controlChanged)
        control.identifier = NSUserInterfaceItemIdentifier(param.name)
        field?.identifier = control.identifier

        // Every row gets the same menu now, colours included — a colour's axes
        // are a submenu inside it rather than a different kind of control.
        let midi = NSPopUpButton(frame: .zero, pullsDown: true)
        midi.controlSize = .small
        midi.font = .systemFont(ofSize: 10)
        midi.identifier = control.identifier
        midi.widthAnchor.constraint(equalToConstant: 68).isActive = true

        let views: [NSView] = [name, control, field,
                               param.type == .color ? Chrome.flexible() : nil, midi]
            .compactMap { $0 }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        control.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = Row(param: param, control: control, field: field, midi: midi, view: stack)
        rows[param.name] = row          // `setBinding` looks the row up to read its colour
        setBinding([], for: param.name)
        return row
    }

    private func refreshMIDIVisibility() {
        for row in rows.values { row.midi?.isHidden = !showsMIDIControls }
    }

    // MARK: - Values in

    /// Pushes `values` into the controls without reporting them as edits. This
    /// is how preset application, defaults and inbound MIDI all reach the UI.
    func show(values: LerpParameterValues?) {
        isPushing = true
        defer { isPushing = false }
        for (name, row) in rows {
            let value = (values?[name] ?? nil) ?? row.param.defaultValue
            switch (row.param.type, value) {
            case (.color, .color(let c)):
                (row.control as? NSColorWell)?.color = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y),
                                                               blue: CGFloat(c.z), alpha: CGFloat(c.w))
            case (.bool, .scalar(let v)):
                (row.control as? NSSwitch)?.state = v != 0 ? .on : .off
            case (_, .scalar(let v)):
                row.control.doubleValue = v
                row.field?.stringValue = format(v, row.param)
            default:
                break
            }
        }
    }

    private func format(_ value: Double, _ param: LerpParam) -> String {
        param.type == .int ? String(Int(value.rounded())) : String(format: "%.3g", value)
    }

    /// Shows what a parameter is currently bound to. An empty list clears the
    /// title back to "—".
    ///
    /// A scalar has at most one binding and gets the menu it always had. A
    /// colour can have up to four — one per OKLCH axis — and gets the *same*
    /// menu once per axis, hung off a submenu. There is no second menu builder:
    /// `axisItems` is what makes both.
    func setBinding(_ bindings: [MIDIBinding], for name: String) {
        guard let row = rows[name], let button = row.midi else { return }
        row.bindings = bindings
        let menu = button.menu ?? NSMenu()
        menu.delegate = self
        // Looked up in `menuNeedsUpdate` so the near-grey note is recomputed
        // from the colour that is on screen when the menu opens, not from
        // whatever it was when the row was last rebuilt. A popup's menu never
        // shows its own title, so this is free.
        menu.title = name
        populate(menu, row: row)
        if button.menu !== menu { button.menu = menu }
        button.toolTip = bindings.isEmpty
            ? "Not mapped to MIDI"
            : bindings.map { "\($0.shortLabel) → \(name)\($0.component.map { c in " \(c.label)" } ?? "")" }
                .joined(separator: "\n")
    }

    private func populate(_ menu: NSMenu, row: Row) {
        let name = row.param.name, bindings = row.bindings
        menu.removeAllItems()
        // Without this AppKit enables anything whose target answers the action,
        // which would offer Clear and the modes on an unbound parameter.
        menu.autoenablesItems = false
        // A pull-down shows its first item as its title.
        menu.addItem(withTitle: title(for: bindings), action: nil, keyEquivalent: "")

        guard row.param.type == .color else {
            for entry in axisItems(name, nil, bindings.first) { menu.addItem(entry) }
            return
        }
        let color = currentColor(of: row)
        for component in ColorComponent.allCases {
            let binding = bindings.first { $0.component == component }
            let entry = NSMenuItem(title: axisTitle(component, binding, color: color),
                                   action: nil, keyEquivalent: "")
            entry.state = binding != nil ? .on : .off
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for sub in axisItems(name, component, binding) { submenu.addItem(sub) }
            entry.submenu = submenu
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let clearAll = item("Clear All", name, nil, .clearAll)
        clearAll.isEnabled = !bindings.isEmpty
        menu.addItem(clearAll)
    }

    /// The pull-down's own title. One binding shows its CC; several show how
    /// many, because three CCs do not fit in the control and the tooltip has
    /// the detail.
    private func title(for bindings: [MIDIBinding]) -> String {
        switch bindings.count {
        case 0: "—"
        case 1: bindings[0].shortLabel
        default: "\(bindings.count) CCs"
        }
    }

    /// The body of the menu for one axis — identical for a scalar (whose only
    /// axis is nil) and for each of a colour's four.
    private func axisItems(_ name: String, _ component: ColorComponent?,
                           _ binding: MIDIBinding?) -> [NSMenuItem] {
        var items = [item("Learn…", name, component, .learn),
                     item("Clear", name, component, .clear)]
        items[1].isEnabled = binding != nil
        items.append(.separator())
        for mode in MIDIBindingMode.choices {
            let entry = item(mode.label, name, component, .mode(mode))
            entry.isEnabled = binding != nil
            entry.state = binding?.mode.matchesChoice(mode) == true ? .on : .off
            items.append(entry)
        }
        items.append(.separator())
        // Task-2 range scoping lives here rather than in a pair of always-
        // visible fields: it is a thing you set once per binding, and the title
        // reports the current scope so nothing has to be opened to read it.
        let scope = item(rangeTitle(binding), name, component, .range)
        scope.isEnabled = binding != nil
        items.append(scope)
        return items
    }

    private func rangeTitle(_ binding: MIDIBinding?) -> String {
        guard let binding, binding.isScoped else { return "Range…" }
        return String(format: "Range… (%.2f–%.2f)", binding.range.lowerBound, binding.range.upperBound)
    }

    /// "Hue — CC21", or "Hue (near-grey — lifts chroma)" when the colour has no
    /// hue worth turning. The parenthetical is the disclosure that stops the
    /// chroma floor being something the app does behind the user's back.
    private func axisTitle(_ component: ColorComponent, _ binding: MIDIBinding?,
                           color: SIMD4<Float>) -> String {
        var title = component.label
        if component == .hue, ColorProjection.isNearGrey(color) {
            title += " — near-grey, lifts chroma"
        }
        return title + (binding.map { " · \($0.shortLabel)" } ?? "")
    }

    private func currentColor(of row: Row) -> SIMD4<Float> {
        guard let color = (row.control as? NSColorWell)?.color.usingColorSpace(.sRGB) else {
            return row.param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1)
        }
        return SIMD4<Float>(Float(color.redComponent), Float(color.greenComponent),
                            Float(color.blueComponent), Float(color.alphaComponent))
    }

    private func item(_ title: String, _ name: String, _ component: ColorComponent?,
                      _ command: MIDICommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(midiCommand), keyEquivalent: "")
        item.target = self
        item.representedObject = MIDICommandBox(name: name, component: component, command: command)
        return item
    }

    private final class MIDICommandBox {
        let name: String, component: ColorComponent?, command: MIDICommand
        init(name: String, component: ColorComponent?, command: MIDICommand) {
            self.name = name; self.component = component; self.command = command
        }
    }

    // MARK: - Values out

    @objc private func controlChanged(_ sender: NSControl) {
        guard !isPushing,
              let name = sender.identifier?.rawValue, let row = rows[name] else { return }
        let value: LerpParamValue
        switch row.param.type {
        case .color:
            let color = (sender as? NSColorWell)?.color.usingColorSpace(.sRGB) ?? .black
            value = .color(SIMD4<Float>(Float(color.redComponent), Float(color.greenComponent),
                                        Float(color.blueComponent), Float(color.alphaComponent)))
        case .bool:
            value = .scalar((sender as? NSSwitch)?.state == .on ? 1 : 0)
        case .float, .int:
            value = .scalar(sender.doubleValue)
        }
        let clamped = row.param.clamp(value)
        if case .scalar(let v) = clamped {
            row.field?.stringValue = format(v, row.param)
            if row.param.type == .int { row.control.doubleValue = v }
        }
        onChange?(name, clamped)
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        guard let name = sender.identifier?.rawValue, let row = rows[name],
              let typed = Double(sender.stringValue) else { return }
        let clamped = row.param.clamp(.scalar(typed))
        guard case .scalar(let v) = clamped else { return }
        row.control.doubleValue = v
        sender.stringValue = format(v, row.param)
        onChange?(name, clamped)
    }

    @objc private func presetChanged() {
        onPreset?(presetPopUp.indexOfSelectedItem <= 0 ? nil : presetPopUp.titleOfSelectedItem)
    }

    @objc private func midiCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MIDICommandBox else { return }
        onMIDICommand?(box.name, box.component, box.command)
    }

    // MARK: - Test hooks

    /// The live control for a parameter, so `--selftest` can move it exactly the
    /// way a mouse would rather than calling through a side door.
    func control(named name: String) -> NSControl? { rows[name]?.control }
    func fieldText(named name: String) -> String? { rows[name]?.field?.stringValue }
    func bindingLabel(named name: String) -> String? { rows[name]?.midi?.itemTitle(at: 0) }
    var rowNames: [String] { parameters.map(\.name) }
    var presetTitles: [String] { presetPopUp.itemTitles }
    var isEmptyStateVisible: Bool { empty.superview != nil }

    /// Drives a control the way AppKit does on a real interaction.
    func act(on control: NSControl) {
        control.sendAction(control.action, to: control.target)
    }

    func choosePreset(_ title: String) {
        presetPopUp.selectItem(withTitle: title)
        presetChanged()
    }

    /// Titles of the axis submenu for a colour row, so `--selftest` can assert
    /// the component sub-choice is offered and says what it is doing.
    func midiMenuTitles(named name: String, component: ColorComponent? = nil) -> [String] {
        guard let row = rows[name], let menu = row.midi?.menu else { return [] }
        guard let component else { return menu.items.map(\.title) }
        return menu.items.first { $0.title.hasPrefix(component.label) }?
            .submenu?.items.map(\.title) ?? []
    }

    /// Fires the menu item AppKit would have fired, so the test drives the same
    /// path a click does.
    func chooseMIDIMenuItem(named name: String, component: ColorComponent?, title: String) -> Bool {
        guard let row = rows[name], let menu = row.midi?.menu else { return false }
        let container = component.flatMap { c in
            menu.items.first { $0.title.hasPrefix(c.label) }?.submenu
        } ?? menu
        guard let item = container.items.first(where: { $0.title == title }), item.isEnabled,
              let action = item.action else { return false }
        _ = perform(action, with: item)
        return true
    }
}

/// The near-grey note on a colour's Hue axis has to describe the colour that is
/// on screen *now*, and a menu is the one piece of UI that can be rebuilt at the
/// moment it is looked at.
extension ParameterPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let row = rows[menu.title] else { return }
        populate(menu, row: row)
    }
}
