import AppKit

/// The two directions a `color` parameter travels between the model and the
/// colour well that edits it. Written out three times in this file before they
/// were named — once per reading site and once for the write — and the three
/// have to agree about the colour space or a colour survives a round trip
/// through the inspector changed.
extension NSColor {
    /// This colour's components as a `color` parameter stores them, or nil when
    /// it cannot be expressed in sRGB. Callers choose their own fallback,
    /// because they do not agree on one: a control that is being read wants the
    /// parameter's declared default, a control that is being *changed* wants
    /// black rather than to silently reinstate a default the user just left.
    var lerpComponents: SIMD4<Float>? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return SIMD4<Float>(Float(srgb.redComponent), Float(srgb.greenComponent),
                            Float(srgb.blueComponent), Float(srgb.alphaComponent))
    }

    convenience init(lerp c: SIMD4<Float>) {
        self.init(srgbRed: CGFloat(c.x), green: CGFloat(c.y),
                  blue: CGFloat(c.z), alpha: CGFloat(c.w))
    }
}

/// The inspector: the open shader's Presets list over one stock control per
/// `// lerp-param:` it declares.
///
/// The Presets list switches between the open shader's presets, and "+" saves
/// the values on screen as a new one. That is all it does. Whether a preset
/// plays in the screensaver is decided in one place only — the selector's
/// badge menu — not here beside the parameters.
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
    /// The Presets list's "+": save the values on screen as a preset.
    var onSavePreset: (() -> Void)?
    /// The Parameters heading's Randomize: throw every held parameter to a
    /// random spot in its declared range.
    var onRandomize: (() -> Void)?
    /// A row's MIDI menu was used — its right-click menu, or the CC tag a bound
    /// row shows. The component is nil for everything that is not a colour,
    /// and names the axis for the ones that are.
    var onMIDICommand: ((String, ColorComponent?, MIDICommand) -> Void)?
    /// A row's animation toggle was clicked: true to let the parameter drift
    /// again, false to hold it where it is on screen.
    var onAnimate: ((String, Bool) -> Void)?

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

    /// The Presets list. One row per preset, "Defaults" (nil) first.
    private let presetStack = NSStackView()
    private let presetScroll = NSScrollView()
    private var presetHeight: NSLayoutConstraint!
    private var presetRows: [PresetRow] = []
    /// The preset the render is wearing; nil is Defaults.
    private var markedPreset: String?
    private static let presetRowHeight: CGFloat = 26
    private static let presetRowsShown = 7
    private let scroll = NSScrollView()
    private let rowStack = NSStackView()
    private let empty = Chrome.label("", size: 11.5)
    private lazy var randomize = InspectorHeaderButton(
        symbol: "dice", title: "Randomize", accessibility: "Randomize parameters",
        target: self, action: #selector(randomizeParameters))
    private let presetCount = InspectorHeading.count()
    private let parameterCount = InspectorHeading.count()
    private var rows: [String: Row] = [:]
    /// Set while `show(values:)` is pushing values into controls, so the
    /// controls' own actions don't echo back out as user edits.
    private var isPushing = false
    /// Whether Core MIDI is up. Off, the rows carry no MIDI menu at all rather
    /// than offering one that then fails. On, every row can be right-clicked to
    /// Learn, and only a row that is *bound* shows anything: its CC tag.
    var showsMIDIControls = false { didSet { refreshMIDIVisibility() } }

    private final class TopClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    /// Label, control, optional numeric echo, MIDI tag and right-click menu,
    /// and what those menus are currently describing — a scalar has at most
    /// one binding, a colour up to one per OKLCH axis.
    private final class Row {
        let param: LerpParam
        let control: NSControl
        let field: NSTextField?
        /// The CC tag. Hidden until the parameter is bound: most people never
        /// plug in a controller, and a "—" on every row was a column of noise.
        let midi: NSPopUpButton?
        /// The same commands, on right-click anywhere on the row. This is how
        /// an unbound parameter gets learned.
        let contextMenu = NSMenu()
        let label: NSTextField
        /// The `// lerp-animate:` toggle: lit while the parameter drifts,
        /// dim while it is held. Hidden when the look gives it no drift, and
        /// absent on the types that cannot have one.
        let animate: NSButton?
        let view: NSView
        var bindings: [MIDIBinding] = []
        init(param: LerpParam, label: NSTextField, control: NSControl, field: NSTextField?,
             midi: NSPopUpButton?, animate: NSButton?, view: NSView) {
            self.param = param; self.label = label; self.control = control; self.field = field
            self.midi = midi; self.animate = animate; self.view = view
            contextMenu.title = param.name     // `menuNeedsUpdate` finds the row by it
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        presetStack.orientation = .vertical
        presetStack.alignment = .width
        presetStack.spacing = 1
        presetStack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 6, right: 7)
        presetStack.translatesAutoresizingMaskIntoConstraints = false
        presetStack.identifier = NSUserInterfaceItemIdentifier("preset-list")
        presetScroll.contentView = TopClipView()
        presetScroll.documentView = presetStack
        presetScroll.hasVerticalScroller = true
        presetScroll.autohidesScrollers = true
        presetScroll.drawsBackground = true
        presetScroll.backgroundColor = EditorTheme.background
        presetScroll.borderType = .noBorder
        presetHeight = presetScroll.heightAnchor.constraint(equalToConstant: Self.presetRowHeight + 6)
        presetHeight.isActive = true

        rowStack.orientation = .vertical
        rowStack.alignment = .width
        rowStack.spacing = 1
        rowStack.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 10, right: 7)
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

        let add = InspectorHeaderButton(symbol: "plus", title: nil, accessibility: "New preset",
                                        target: self, action: #selector(addPreset))
        add.toolTip = "New preset (⇧⌘S)"
        add.identifier = NSUserInterfaceItemIdentifier("preset-add")
        // Beside the parameters it moves, not over the render: it is an edit to
        // these sliders, so it sits on their heading the way "+" sits on the
        // presets'.
        randomize.toolTip = "Randomize parameters (⇧⌘R)"
        randomize.identifier = NSUserInterfaceItemIdentifier("parameters-randomize")
        let body = Chrome.pane([InspectorHeading.make("Presets", count: presetCount,
                                                      accessories: [add], hairline: false),
                                presetScroll,
                                InspectorHeading.make("Parameters", count: parameterCount,
                                                      accessories: [randomize], hairline: true),
                                scroll])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            presetStack.topAnchor.constraint(equalTo: presetScroll.contentView.topAnchor),
            presetStack.leadingAnchor.constraint(equalTo: presetScroll.contentView.leadingAnchor),
            presetStack.trailingAnchor.constraint(equalTo: presetScroll.contentView.trailingAnchor),
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

        buildPresets(shader)
        randomize.isEnabled = !parameters.isEmpty
        parameterCount.stringValue = parameters.isEmpty ? "" : "\(parameters.count)"

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
        let name = Chrome.label(param.label, size: 11.5, color: EditorTheme.text)
        name.toolTip = "\(param.name) — \(param.type.rawValue)"
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        var field: NSTextField?
        let control: NSControl
        switch param.type {
        case .float, .int:
            let slider = NSSlider()
            slider.cell = InspectorSliderCell()
            slider.minValue = param.min
            slider.maxValue = param.max
            slider.isContinuous = true
            slider.controlSize = .small
            if param.type == .int, param.max - param.min <= 24 {
                slider.numberOfTickMarks = Int(param.max - param.min) + 1
                slider.allowsTickMarkValuesOnly = true
            }
            slider.heightAnchor.constraint(equalToConstant: 18).isActive = true
            control = slider
        case .bool:
            let toggle = NSSwitch()
            toggle.controlSize = .mini
            control = toggle
        case .color:
            let well = InspectorSwatch()
            well.colorWellStyle = .minimal
            well.isContinuous = true
            // `color` parameters carry alpha, so the picker has to offer it.
            well.supportsAlpha = true
            well.heightAnchor.constraint(equalToConstant: 18).isActive = true
            control = well
        }
        if param.type != .bool {
            // The number beside a slider, the hex beside a colour: both can be
            // typed into.
            let echo = NSTextField.inspectorValue()
            if param.type == .color {
                echo.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                echo.textColor = EditorTheme.text.withAlphaComponent(0.8)
            }
            echo.target = self
            echo.action = #selector(fieldChanged)
            field = echo
        }
        control.target = self
        control.action = #selector(controlChanged)
        control.identifier = NSUserInterfaceItemIdentifier(param.name)
        field?.identifier = control.identifier

        // Every row gets the same menu, colours included — a colour's axes are
        // a submenu inside it rather than a different kind of control. It is
        // the row's right-click menu always, and this tag's menu once bound.
        let midi = NSPopUpButton(frame: .zero, pullsDown: true)
        midi.controlSize = .mini
        midi.font = .monospacedSystemFont(ofSize: 9.5, weight: .regular)
        midi.identifier = control.identifier
        midi.isHidden = true
        midi.setContentHuggingPriority(.required, for: .horizontal)

        // Only the types `// lerp-animate:` accepts get one. It starts hidden;
        // `show(values:)` reveals it when the look on screen gives this
        // parameter a drift, which a preset can do for a parameter the file
        // itself holds still.
        var animate: NSButton?
        if param.type == .float || param.type == .color {
            let symbol = NSImage(systemSymbolName: "waveform.path",
                                 accessibilityDescription: "Animate \(param.label)")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            let toggle = NSButton(image: symbol ?? NSImage(),
                                  target: self, action: #selector(animateToggled))
            toggle.setButtonType(.toggle)
            toggle.isBordered = false
            toggle.imageScaling = .scaleNone
            toggle.identifier = control.identifier
            toggle.isHidden = true
            toggle.setContentHuggingPriority(.required, for: .horizontal)
            toggle.widthAnchor.constraint(equalToConstant: 16).isActive = true
            animate = toggle
        }

        // The name and its drift toggle share one fixed column, so the toggle
        // appearing never shifts the slider or the value out of line with the
        // rows above and below.
        let nameColumn = NSStackView(views: [name, animate, Chrome.flexible()].compactMap { $0 })
        nameColumn.spacing = 3
        nameColumn.alignment = .centerY
        nameColumn.detachesHiddenViews = true
        nameColumn.widthAnchor.constraint(equalToConstant: InspectorStyle.labelWidth).isActive = true

        let views: [NSView] = [nameColumn, control,
                               param.type == .bool ? Chrome.flexible() : nil, field, midi]
            .compactMap { $0 }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
        // A hidden tag must not leave a gap where it would be.
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        if param.type != .bool { control.setContentHuggingPriority(.init(1), for: .horizontal) }

        let container = InspectorHoverView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: InspectorStyle.rowHeight),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        let row = Row(param: param, label: name, control: control, field: field, midi: midi,
                      animate: animate, view: container)
        row.contextMenu.delegate = self
        rows[param.name] = row          // `setBinding` looks the row up to read its colour
        setBinding([], for: param.name)
        return row
    }

    private func refreshMIDIVisibility() {
        for row in rows.values { refreshMIDI(row) }
    }

    /// The tag shows only on a bound row; the right-click menu is on every row
    /// whenever MIDI is up. The echo field keeps its own text menu.
    private func refreshMIDI(_ row: Row) {
        row.midi?.isHidden = !showsMIDIControls || row.bindings.isEmpty
        let menu = showsMIDIControls ? row.contextMenu : nil
        for view in [row.view, row.label, row.control] { view.menu = menu }
        row.label.toolTip = "\(row.param.name) — \(row.param.type.rawValue)"
            + (showsMIDIControls && row.bindings.isEmpty ? "\nRight-click to map a MIDI knob" : "")
    }

    // MARK: - Values in

    /// Pushes `values` into the controls without reporting them as edits. This
    /// is how preset application, defaults and inbound MIDI all reach the UI.
    ///
    /// Pass the *live* values (`LerpMetalView.liveParameterValues`), so an
    /// animating parameter's control shows where it is on its curve and its
    /// toggle shows that it is drifting.
    func show(values: LerpParameterValues?) {
        isPushing = true
        defer { isPushing = false }
        for (name, row) in rows {
            push((values?[name] ?? nil) ?? row.param.defaultValue, into: row)
            showAnimation(of: row, in: values)
        }
    }

    /// The per-frame half of `show(values:)`: moves only the controls of
    /// parameters that are drifting, so the sliders visibly follow the
    /// animation. A row being typed into is left alone.
    func showLive(values: LerpParameterValues?) {
        guard let values, !values.activeAnimations.isEmpty else { return }
        isPushing = true
        defer { isPushing = false }
        for (name, row) in rows where values.isAnimating(name) {
            guard row.field?.currentEditor() == nil, let value = values[name] else { continue }
            push(value, into: row)
        }
    }

    private func push(_ value: LerpParamValue, into row: Row) {
        switch (row.param.type, value) {
        case (.color, .color(let c)):
            let color = NSColor(lerp: c)
            (row.control as? NSColorWell)?.color = color
            if row.field?.currentEditor() == nil { row.field?.stringValue = color.lerpHex }
        case (.bool, .scalar(let v)):
            (row.control as? NSSwitch)?.state = v != 0 ? .on : .off
        case (_, .scalar(let v)):
            row.control.doubleValue = v
            row.field?.stringValue = format(v, row.param)
        default:
            break
        }
    }

    /// The toggle's visibility, lit/dim state and the words that explain it.
    private func showAnimation(of row: Row, in values: LerpParameterValues?) {
        guard let toggle = row.animate else { return }
        let name = row.param.name
        let animation = values?.animations[name]
        let on = animation != nil && values?.isAnimating(name) == true
        ((row.control as? NSSlider)?.cell as? InspectorSliderCell)?.isDrifting = on
        (row.control as? InspectorSwatch)?.isDrifting = on
        guard let animation else {
            toggle.isHidden = true
            return
        }
        toggle.isHidden = false
        toggle.state = on ? .on : .off
        toggle.contentTintColor = on ? InspectorStyle.drift : EditorTheme.dim
        let range = "\(animation.low.literal)–\(animation.high.literal) over "
            + "\(LerpParamValue.scalar(animation.period).literal) s"
        toggle.toolTip = on
            ? "Animating \(range). Click to hold it where it is — moving the control, "
                + "or a MIDI knob bound to it, takes control too."
            : "Held. Click to let it drift \(range) again."
    }

    /// Marks `name` without applying anything — the display half of
    /// `choosePreset`, for when the values are already right and only the mark
    /// is behind.
    ///
    /// `rebuild` throws the list away and marks "Defaults", so without this
    /// every recompile that changes a declaration would leave the list claiming
    /// the shader is at its defaults while the render and the toolbar button
    /// say it is wearing a preset. A name the rebuilt list no longer has falls
    /// back to "Defaults", which by then is the truth: a preset the file stopped
    /// declaring is not being rendered either.
    func showPreset(_ name: String?) {
        markedPreset = presetRows.contains { $0.preset == name } ? name : nil
        presetRows.forEach { $0.isMarked = $0.preset == markedPreset }
    }

    /// One row per preset, "Defaults" first, sized to show up to
    /// `presetRowsShown` before the list scrolls.
    private func buildPresets(_ shader: LerpShader?) {
        presetRows.forEach { $0.removeFromSuperview() }
        presetRows = []
        markedPreset = nil
        presetCount.stringValue = ""
        guard let shader else { return }
        let names = shader.presetChoices
        for name in names {
            let row = PresetRow(preset: name)
            row.onApply = { [weak self] in self?.choose(name) }
            row.isMarked = name == nil
            presetStack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Self.presetRowHeight).isActive = true
            presetRows.append(row)
        }
        let shown = min(names.count, Self.presetRowsShown)
        presetHeight.constant = CGFloat(shown) * (Self.presetRowHeight + 1) + 6
        presetCount.stringValue = names.isEmpty ? "" : "\(names.count)"
    }

    private func choose(_ name: String?) {
        showPreset(name)
        onPreset?(markedPreset)
    }

    @objc private func addPreset() { onSavePreset?() }
    @objc private func randomizeParameters() { onRandomize?() }

    /// A fixed number of decimals per parameter, chosen from its range, so the
    /// digits in a column line up and a value does not change width as it moves.
    private func format(_ value: Double, _ param: LerpParam) -> String {
        guard param.type != .int else { return String(Int(value.rounded())) }
        let span = param.max - param.min
        let decimals = span < 10 ? 2 : span < 100 ? 1 : 0
        return String(format: "%.\(decimals)f", value)
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
        populate(row.contextMenu, row: row)
        refreshMIDI(row)
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
        if menu === row.contextMenu {
            menu.addItem(.sectionHeader(title: bindings.isEmpty ? "MIDI" : "MIDI · \(title(for: bindings))"))
        } else {
            // A pull-down shows its first item as its title.
            menu.addItem(withTitle: title(for: bindings), action: nil, keyEquivalent: "")
        }

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
        // Unbound, Learn is the only thing that can do anything; a column of
        // greyed-out modes would just be more to read past.
        guard binding != nil else { return [item("Learn…", name, component, .learn)] }
        var items = [item("Learn…", name, component, .learn),
                     item("Clear", name, component, .clear)]
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
        (row.control as? NSColorWell)?.color.lerpComponents
            ?? row.param.defaultValue.colorValue ?? SIMD4<Float>(0, 0, 0, 1)
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
            let color = (sender as? NSColorWell)?.color
            value = .color(color?.lerpComponents ?? SIMD4<Float>(0, 0, 0, 1))
            row.field?.stringValue = color?.lerpHex ?? ""
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
        guard let name = sender.identifier?.rawValue, let row = rows[name] else { return }
        if row.param.type == .color {
            guard let well = row.control as? NSColorWell else { return }
            let alpha = well.color.lerpComponents?.w ?? 1
            guard let typed = NSColor.lerp(hex: sender.stringValue, alpha: alpha) else {
                sender.stringValue = well.color.lerpHex
                return
            }
            well.color = NSColor(lerp: typed)
            sender.stringValue = well.color.lerpHex
            onChange?(name, row.param.clamp(.color(typed)))
            return
        }
        guard let typed = Double(sender.stringValue) else {
            sender.stringValue = format(row.control.doubleValue, row.param)
            return
        }
        let clamped = row.param.clamp(.scalar(typed))
        guard case .scalar(let v) = clamped else { return }
        row.control.doubleValue = v
        sender.stringValue = format(v, row.param)
        onChange?(name, clamped)
    }

    @objc private func animateToggled(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, rows[name] != nil else { return }
        // A borderless button flips its own state on click; the controller
        // pushes the result back through `show(values:)`, tint and tooltip
        // included.
        onAnimate?(name, sender.state == .on)
    }

    @objc private func midiCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? MIDICommandBox else { return }
        onMIDICommand?(box.name, box.component, box.command)
    }

    /// Applies a preset by name — "Defaults" for none — and marks it: after
    /// Save as Preset has written and re-read it, when a look is opened wearing
    /// one, and for ⌥⌘[ / ⌥⌘].
    func choosePreset(_ title: String) {
        choose(title == LerpRotationEntry.defaultsName ? nil : title)
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

extension LerpShader {
    /// What the Presets list offers and ⌥⌘[ / ⌥⌘] step through: "Defaults"
    /// (nil) and then each declared preset — except that Defaults is left out
    /// when a named preset already draws the same picture, exactly as the
    /// rotation leaves it out (`rotationEntries`), so the list and the
    /// screensaver agree about how many presets a shader has.
    var presetChoices: [String?] {
        let defaults = LerpRotationEntry(shader: name)
        let hasDefaults = presets.isEmpty || [self].rotationEntries().contains(defaults)
        return (hasDefaults ? [nil] : []) + presets.map(\.name)
    }
}

/// One row of the Presets list: the name, which applies the preset when clicked.
/// The row the render is wearing is marked.
private final class PresetRow: InspectorHoverView {
    let preset: String?
    private let name = NSButton()
    /// A radio-style mark: hollow on every row, filled on the one the render
    /// is wearing, so the list reads as "one of these" before anything is read.
    private let dot = NSView()
    var onApply: (() -> Void)?

    var isMarked = false { didSet { refresh() } }

    init(preset: String?) {
        self.preset = preset
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("preset:" + (preset ?? LerpRotationEntry.defaultsName))

        name.isBordered = false
        name.alignment = .left
        name.target = self
        name.action = #selector(applied)
        name.cell?.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.borderWidth = 1
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 7),
                                     dot.heightAnchor.constraint(equalToConstant: 7)])

        let stack = NSStackView(views: [dot, name, Chrome.flexible()])
        stack.orientation = .horizontal
        stack.spacing = 9
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 9, bottom: 0, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func refresh() {
        let accent = InspectorStyle.accent
        layer?.backgroundColor = isMarked ? accent.withAlphaComponent(0.15).cgColor
            : isHovered ? InspectorStyle.hover.cgColor : nil
        dot.layer?.backgroundColor = isMarked ? accent.cgColor : nil
        dot.layer?.borderColor = (isMarked ? accent : EditorTheme.dim.withAlphaComponent(isHovered ? 1 : 0.6)).cgColor
        // "Defaults" is the file's own values rather than a named look, and is
        // set a shade back from the presets the user and the file named.
        let color = isMarked || isHovered ? EditorTheme.text
            : preset == nil ? InspectorStyle.heading : EditorTheme.text.withAlphaComponent(0.85)
        name.attributedTitle = NSAttributedString(
            string: preset ?? LerpRotationEntry.defaultsName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: isMarked ? .semibold : .regular),
                         .foregroundColor: color])
    }

    /// Anywhere on the row applies the preset, not just the text.
    override func mouseDown(with event: NSEvent) { onApply?() }

    @objc private func applied() { onApply?() }
}
