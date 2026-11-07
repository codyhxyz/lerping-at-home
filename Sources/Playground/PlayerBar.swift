import AppKit

/// The controls in the strip under the picture, drawn as one family: every
/// one is 26 points tall and fully rounded, on the same faint fill, with the
/// inspector's accent meaning "on" and its heading grey meaning "not chosen".
///
/// The strip used to be a stock push button reading "Pause", a line of
/// readout text (fps, pixel size, EDR headroom), a stock popup reading
/// "Full", a blue checkbox and a borderless icon — five controls in four
/// visual languages. These replace them with a round play button, a frame
/// rate, a labelled Low / Med / High switch, an HDR pill and a round
/// full-screen button.
enum PlayerStyle {
    static let height: CGFloat = 26
    static let fill = NSColor(white: 1, alpha: 0.07)
    static let fillHover = NSColor(white: 1, alpha: 0.12)
    static let fillPressed = NSColor(white: 1, alpha: 0.18)
    static let selected = NSColor(white: 1, alpha: 0.16)

    /// A small tracked caps caption, the inspector's section-heading look.
    static func caption(_ text: String) -> NSTextField {
        NSTextField(labelWithAttributedString: NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .kern: 0.9, .foregroundColor: InspectorStyle.heading]))
    }
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
    fileprivate var hovered = false { didSet { if hovered != oldValue { restyle() } } }
    /// Held down, from mouse-down until the tracking loop returns.
    fileprivate var pressed = false { didSet { if pressed != oldValue { restyle() } } }

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

/// A row of mutually exclusive choices in one pill track, the chosen one
/// lifted out on its own inner pill. Sends its action when the choice changes.
final class PlayerSegments: NSView {
    private(set) var selectedIndex = 0
    weak var target: AnyObject?
    var action: Selector?
    private var segments: [Segment] = []

    init(_ titles: [String], accessibility: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PlayerStyle.fill.cgColor
        layer?.cornerRadius = PlayerStyle.height / 2
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibility)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: PlayerStyle.height),
        ])
        for (index, title) in titles.enumerated() {
            let segment = Segment(title)
            segment.target = self
            segment.action = #selector(picked(_:))
            segment.tag = index
            stack.addArrangedSubview(segment)
            segments.append(segment)
        }
        setContentHuggingPriority(.required, for: .horizontal)
        select(0)
    }

    required init?(coder: NSCoder) { nil }

    func select(_ index: Int) {
        selectedIndex = max(0, min(index, segments.count - 1))
        for segment in segments { segment.isChosen = segment.tag == selectedIndex }
    }

    @objc private func picked(_ sender: Segment) {
        guard sender.tag != selectedIndex else { return }
        select(sender.tag)
        displayIfNeeded()       // the choice shows before a paused frame is redrawn
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    private final class Segment: NSButton {
        private let word: String
        private var hovered = false { didSet { if hovered != oldValue { restyle() } } }
        var isChosen = false { didSet { restyle() } }

        init(_ word: String) {
            self.word = word
            super.init(frame: .zero)
            isBordered = false
            bezelStyle = .regularSquare
            wantsLayer = true
            layer?.cornerRadius = (PlayerStyle.height - 4) / 2
            focusRingType = .none
            setAccessibilityRole(.radioButton)
            restyle()
        }

        required init?(coder: NSCoder) { nil }

        override var intrinsicContentSize: NSSize {
            NSSize(width: max(40, (attributedTitle.size().width + 20).rounded()),
                   height: PlayerStyle.height - 4)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                                   .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }

        override func accessibilityValue() -> Any? { isChosen ? 1 : 0 }

        private func restyle() {
            layer?.backgroundColor = isChosen ? PlayerStyle.selected.cgColor : nil
            attributedTitle = NSAttributedString(string: word, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isChosen ? .semibold : .medium),
                .foregroundColor: isChosen || hovered ? EditorTheme.text : InspectorStyle.heading])
        }
    }
}
