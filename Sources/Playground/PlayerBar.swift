import AppKit

/// The controls in the strip under the picture, drawn as one family: every
/// one is 26 points tall and fully rounded, on the same faint fill, with the
/// inspector's accent meaning "on" and its heading grey meaning "not chosen".
///
/// The strip used to be a stock push button reading "Pause", a line of
/// readout text (fps, pixel size, EDR headroom), a stock popup reading
/// "Full", a blue checkbox and a borderless icon — five controls in four
/// visual languages. These replace them with a round play button, a frame
/// rate, a resolution pill that opens a menu, an HDR pill and a round
/// full-screen button.
enum PlayerStyle {
    static let height: CGFloat = 26
    static let fill = NSColor(white: 1, alpha: 0.07)
    static let fillHover = NSColor(white: 1, alpha: 0.12)
    static let fillPressed = NSColor(white: 1, alpha: 0.18)
}

/// A borderless button with a pill or circle behind it. Shared hover and
/// press handling for everything in the strip.
///
/// Every visual change is made here, the moment the mouse does something, and
/// before the action runs. A click flips the *cell's* state, not through
/// `NSButton.state`'s setter, so a `didSet` on `state` alone never saw it: the
/// HDR pill stayed blue until the pointer left it. And the cell's own
/// highlight is not this view's `isHighlighted` either, so pressing showed
/// nothing at all.
class PlayerPill: NSButton {
    fileprivate(set) var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    /// Held down, from mouse-down until the tracking loop returns.
    fileprivate(set) var pressed = false { didSet { if pressed != oldValue { restyle() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = PlayerStyle.height / 2
        focusRingType = .none
        setContentHuggingPriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: PlayerStyle.height).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var state: NSControl.StateValue { didSet { restyle() } }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)      // tracks until mouse-up; sends the action
        pressed = false
    }

    /// The new state is on screen before the action does any work — a frame
    /// redrawn while paused, say — so the click answers at once.
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        restyle()
        displayIfNeeded()
        return super.sendAction(action, to: target)
    }

    func restyle() {
        layer?.backgroundColor = (pressed ? PlayerStyle.fillPressed
            : hovered ? PlayerStyle.fillHover : PlayerStyle.fill).cgColor
    }
}

/// A round button holding one SF Symbol: play / pause, full screen.
final class PlayerIconButton: PlayerPill {
    private let pointSize: CGFloat

    init(symbol: String, accessibility: String, pointSize: CGFloat = 11,
         target: AnyObject?, action: Selector) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        widthAnchor.constraint(equalToConstant: PlayerStyle.height).isActive = true
        setSymbol(symbol, accessibility: accessibility)
    }

    required init?(coder: NSCoder) { nil }

    func setSymbol(_ symbol: String, accessibility: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .bold))
        setAccessibilityLabel(accessibility)
        restyle()
    }

    override func restyle() {
        super.restyle()
        contentTintColor = hovered ? EditorTheme.text : EditorTheme.text.withAlphaComponent(0.85)
    }
}

/// An on/off pill with a word in it — HDR. Accent when on, grey when off,
/// so it reads as a switch rather than as a button.
final class PlayerToggle: PlayerPill {
    private let word: String

    init(_ word: String, target: AnyObject?, action: Selector) {
        self.word = word
        super.init(frame: .zero)
        setButtonType(.pushOnPushOff)
        title = word
        self.target = target
        self.action = action
        setAccessibilityRole(.checkBox)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (attributedTitle.size().width + 24).rounded(), height: PlayerStyle.height)
    }

    override func restyle() {
        let on = state == .on
        layer?.backgroundColor = (on
            ? InspectorStyle.accent.withAlphaComponent(pressed ? 0.34 : hovered ? 0.28 : 0.22)
            : pressed ? PlayerStyle.fillPressed : hovered ? PlayerStyle.fillHover : PlayerStyle.fill).cgColor
        attributedTitle = NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: on ? InspectorStyle.accent : InspectorStyle.heading])
    }
}

/// One choice out of a few, as one pill: "Resolution  High ⌄". Clicking it
/// opens a menu of the choices with the current one checked, the way a popup
/// button does, and sends the action only when the choice changes.
///
/// It replaced a Low / Med / High segmented track. That put three words on the
/// bar all the time for a decision made once in a while, and its own caption
/// beside it made a fourth.
final class PlayerChoice: PlayerPill {
    private(set) var selectedIndex = 0
    private let caption: String
    private let titles: [String]
    weak var choiceTarget: AnyObject?
    var choiceAction: Selector?

    init(_ caption: String, choices titles: [String]) {
        self.caption = caption
        self.titles = titles
        super.init(frame: .zero)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(caption)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func select(_ index: Int) {
        selectedIndex = max(0, min(index, titles.count - 1))
        setAccessibilityValue(titles[selectedIndex])
        invalidateIntrinsicContentSize()
        restyle()
    }

    private var label: NSAttributedString {
        let text = NSMutableAttributedString(string: caption.uppercased() + "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .kern: 0.8,
            .foregroundColor: InspectorStyle.heading,
            .baselineOffset: 0.5])
        text.append(NSAttributedString(string: titles[selectedIndex], attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: hovered ? EditorTheme.text : EditorTheme.text.withAlphaComponent(0.88)]))
        return text
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (label.size().width + 14 + 22).rounded(), height: PlayerStyle.height)
    }

    override func restyle() {
        super.restyle()
        title = ""
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = label
        let size = text.size()
        text.draw(at: NSPoint(x: 13, y: (bounds.height - size.height) / 2))
        let color = hovered ? EditorTheme.text : InspectorStyle.heading
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(.init(paletteColors: [color]))
        if let chevron = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            chevron.draw(in: NSRect(x: bounds.maxX - 13 - chevron.size.width,
                                    y: (bounds.height - chevron.size.height) / 2,
                                    width: chevron.size.width, height: chevron.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = .systemFont(ofSize: 12)
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == selectedIndex ? .on : .off
            menu.addItem(item)
        }
        // Like a popup button: the chosen item opens over the pill.
        menu.popUp(positioning: menu.item(at: selectedIndex),
                   at: NSPoint(x: 6, y: bounds.height - 4), in: self)
        pressed = false
        hovered = bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard sender.tag != selectedIndex else { return }
        select(sender.tag)
        displayIfNeeded()       // the choice shows before a paused frame is redrawn
        if let choiceAction { NSApp.sendAction(choiceAction, to: choiceTarget, from: self) }
    }
}

/// A word in a pill: Save and Revert on the editor's bar. Shown only when
/// there is something to save, so Save is drawn as the thing to do — accent
/// filled, with the same dot the switcher uses for unsaved edits — and Revert
/// as the quiet way out beside it.
final class PlayerTextButton: PlayerPill {
    private let word: String
    private let prominent: Bool

    init(_ word: String, prominent: Bool, target: AnyObject?, action: Selector) {
        self.word = word
        self.prominent = prominent
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setAccessibilityLabel(word)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (label.size().width + (prominent ? 34 : 26)).rounded(), height: PlayerStyle.height)
    }

    private var label: NSAttributedString {
        NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: prominent ? NSColor.white
                : hovered ? EditorTheme.text : EditorTheme.text.withAlphaComponent(0.75)])
    }

    override func restyle() {
        title = ""
        if prominent {
            let alpha: CGFloat = !isEnabled ? 0.35 : pressed ? 0.75 : hovered ? 1 : 0.88
            layer?.backgroundColor = InspectorStyle.accent.withAlphaComponent(alpha).cgColor
        } else {
            super.restyle()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = label
        let size = text.size()
        var x = (bounds.width - size.width) / 2
        if prominent {
            x += 4
            NSColor.white.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 10, y: bounds.midY - 2.5, width: 5, height: 5)).fill()
        }
        text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
    }
}
