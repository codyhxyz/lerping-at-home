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
/// The Presets list is the one place a shader's presets are handled. A row's
/// name applies it; its tick says whether it plays in the screensaver; "+"
/// saves the values on screen as a new one. Shaders as a whole are picked and
/// switched in the toolbar's selector — presets used to be reachable from
/// there too, and from a popup here, and from the arrows, which was three ways
/// to do one thing.
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
    /// A preset's tick was clicked: put it in (`true`) or take it out of the
    /// screensaver. nil is the "Defaults" entry.
    var onPresetRotation: ((String?, Bool) -> Void)?
    /// The Presets list's "+": save the values on screen as a preset.
    var onSavePreset: (() -> Void)?
    /// A row's MIDI menu was used. The component is nil for everything that is
    /// not a colour, and names the axis for the ones that are.
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
    private let presetNote = Chrome.label("", size: 10.5)
    /// The preset the render is wearing; nil is Defaults.
    private var markedPreset: String?
    private static let presetRowHeight: CGFloat = 22
    private static let presetRowsShown = 7
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
        /// The `// lerp-animate:` toggle: lit while the parameter drifts,
        /// dim while it is held. Hidden when the look gives it no drift, and
        /// absent on the types that cannot have one.
        let animate: NSButton?
        let view: NSView
        var bindings: [MIDIBinding] = []
        init(param: LerpParam, control: NSControl, field: NSTextField?,
             midi: NSPopUpButton?, animate: NSButton?, view: NSView) {
            self.param = param; self.control = control; self.field = field
            self.midi = midi; self.animate = animate; self.view = view
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        presetStack.orientation = .vertical
        presetStack.alignment = .width
        presetStack.spacing = 0
        presetStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        presetStack.translatesAutoresizingMaskIntoConstraints = false
        presetStack.identifier = NSUserInterfaceItemIdentifier("preset-list")
        presetScroll.contentView = TopClipView()
        presetScroll.documentView = presetStack
        presetScroll.hasVerticalScroller = true
        presetScroll.autohidesScrollers = true
        presetScroll.drawsBackground = true
        presetScroll.backgroundColor = EditorTheme.background
        presetScroll.borderType = .noBorder
        presetHeight = presetScroll.heightAnchor.constraint(equalToConstant: Self.presetRowHeight + 4)
        presetHeight.isActive = true
        presetNote.identifier = NSUserInterfaceItemIdentifier("preset-note")
        presetNote.maximumNumberOfLines = 2
        presetNote.lineBreakMode = .byWordWrapping
        presetNote.setContentCompressionResistancePriority(.init(1), for: .horizontal)

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

        let heading = Chrome.label("Presets", size: 11, color: EditorTheme.text)
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        let add = Chrome.button("+", target: self, action: #selector(addPreset))
        add.toolTip = "Save the values on screen as a new preset (⇧⌘S)"
        add.identifier = NSUserInterfaceItemIdentifier("preset-add")
        let parametersHeading = Chrome.label("Parameters", size: 11, color: EditorTheme.text)
        parametersHeading.font = .systemFont(ofSize: 11, weight: .semibold)
        let body = Chrome.pane([Chrome.bar([heading, Chrome.flexible(), add], height: 30),
                                presetScroll,
                                Chrome.bar([presetNote, Chrome.flexible()], height: 26),
                                Chrome.bar([parametersHeading, Chrome.flexible()], height: 26),
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

        // Only the types `// lerp-animate:` accepts get one. It starts hidden;
        // `show(values:)` reveals it when the look on screen gives this
        // parameter a drift, which a preset can do for a parameter the file
        // itself holds still.
        var animate: NSButton?
        if param.type == .float || param.type == .color {
            let toggle = NSButton(image: NSImage(systemSymbolName: "waveform.path",
                                                 accessibilityDescription: "Animate \(param.label)")
                                      ?? NSImage(),
                                  target: self, action: #selector(animateToggled))
            toggle.setButtonType(.toggle)
            toggle.isBordered = false
            toggle.imageScaling = .scaleProportionallyDown
            toggle.identifier = control.identifier
            toggle.isHidden = true
            toggle.widthAnchor.constraint(equalToConstant: 16).isActive = true
            animate = toggle
        }

        let views: [NSView] = [name, control, field,
                               param.type == .color ? Chrome.flexible() : nil, animate, midi]
            .compactMap { $0 }
        let stack = NSStackView(views: views)
        stack.spacing = 6
        stack.alignment = .centerY
        stack.distribution = .fill
        // A hidden toggle must not leave a gap where it would be.
        stack.detachesHiddenViews = true
        control.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = Row(param: param, control: control, field: field, midi: midi,
                      animate: animate, view: stack)
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
            (row.control as? NSColorWell)?.color = NSColor(lerp: c)
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
        guard let animation = values?.animations[name] else {
            toggle.isHidden = true
            return
        }
        let on = values?.isAnimating(name) == true
        toggle.isHidden = false
        toggle.state = on ? .on : .off
        toggle.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
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

    /// Ticks each row from the screensaver's rotation.
    ///
    /// The tick is what *plays*, so a shader switched off in the selector shows
    /// every box empty — with the note saying why, and that a tick brings it
    /// back. A row whose look is not on disk (an unsaved preset, or Defaults
    /// when a named preset draws the same picture) has no tick at all. The last
    /// thing playing cannot be unticked, here as in the selector.
    func showRotation(_ selection: LerpRotationSelection, shader: String) {
        let discovered = Set(selection.discovered)
        let playing = selection.playable
        for row in presetRows {
            let entry = LerpRotationEntry(shader: shader, preset: row.preset)
            let exists = discovered.contains(entry)
            let plays = selection.plays(entry)
            // Invisible rather than hidden, so the names stay in one column.
            row.tick.alphaValue = exists ? 1 : 0
            row.tick.state = plays ? .on : .off
            let last = plays && playing.count == 1
            row.tick.isEnabled = !last
            row.tick.toolTip = !exists
                ? nil
                : last ? "The screensaver needs at least one preset, and this is the last."
                : plays ? "Plays in the screensaver. Click to take it out."
                : "Not in the screensaver. Click to put it in."
        }
        if !presetRows.contains(where: { $0.tick.alphaValue > 0 }) {
            presetNote.stringValue = "Save the shader to put it in the screensaver."
        } else if selection.isSwitchedOff(shader) {
            presetNote.stringValue = "This shader is switched off in the selector. "
                + "Tick a preset to switch it back on."
        } else {
            let looks = selection.looks(of: shader)
            presetNote.stringValue = "Ticked presets play in the screensaver: "
                + "\(looks.filter(selection.plays).count) of \(looks.count)."
        }
    }

    /// One row per preset, "Defaults" first, sized to show up to
    /// `presetRowsShown` before the list scrolls.
    private func buildPresets(_ shader: LerpShader?) {
        presetRows.forEach { $0.removeFromSuperview() }
        presetRows = []
        markedPreset = nil
        guard let shader else { return }
        let names = shader.presetChoices
        for name in names {
            let row = PresetRow(preset: name)
            row.onApply = { [weak self] in self?.choose(name) }
            row.onTick = { [weak self] on in self?.onPresetRotation?(name, on) }
            row.isMarked = name == nil
            presetStack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Self.presetRowHeight).isActive = true
            presetRows.append(row)
        }
        let shown = min(names.count, Self.presetRowsShown)
        presetHeight.constant = CGFloat(shown) * Self.presetRowHeight + 4
        presetNote.stringValue = ""
    }

    private func choose(_ name: String?) {
        showPreset(name)
        onPreset?(markedPreset)
    }

    @objc private func addPreset() { onSavePreset?() }

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
            value = .color((sender as? NSColorWell)?.color.lerpComponents ?? SIMD4<Float>(0, 0, 0, 1))
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

/// One row of the Presets list: a tick for the screensaver, and the name, which
/// applies the preset when clicked. The row the render is wearing is marked.
private final class PresetRow: NSView {
    let preset: String?
    let tick = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let name = NSButton()
    var onApply: (() -> Void)?
    var onTick: ((Bool) -> Void)?
    private static let accent = NSColor(srgbRed: 0.36, green: 0.69, blue: 1.0, alpha: 1)

    var isMarked = false {
        didSet {
            layer?.backgroundColor = isMarked ? Self.accent.withAlphaComponent(0.16).cgColor : nil
            styleName()
        }
    }

    init(preset: String?) {
        self.preset = preset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        identifier = NSUserInterfaceItemIdentifier("preset:" + (preset ?? LerpRotationEntry.defaultsName))

        tick.controlSize = .small
        tick.target = self
        tick.action = #selector(ticked)
        tick.identifier = NSUserInterfaceItemIdentifier("preset-tick")
        tick.alphaValue = 0
        tick.setContentHuggingPriority(.required, for: .horizontal)

        name.isBordered = false
        name.alignment = .left
        name.target = self
        name.action = #selector(applied)
        name.cell?.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        name.toolTip = "Wear this preset"
        styleName()

        let stack = NSStackView(views: [tick, name, NSView()])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func styleName() {
        name.attributedTitle = NSAttributedString(
            string: preset ?? LerpRotationEntry.defaultsName,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: isMarked ? .semibold : .regular),
                         .foregroundColor: isMarked ? Self.accent : EditorTheme.text])
    }

    /// Anywhere on the row but the tick applies the preset, not just the text.
    override func mouseDown(with event: NSEvent) { onApply?() }

    @objc private func applied() { onApply?() }
    @objc private func ticked() { onTick?(tick.state == .on) }
}
