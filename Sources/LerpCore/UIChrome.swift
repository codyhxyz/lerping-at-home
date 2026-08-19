import AppKit

/// Colours and the handful of AppKit idioms shared by every host that draws
/// shader UI: the playground's editor panes and the rotation gallery, which the
/// screensaver's own Options… sheet now embeds.
///
/// This lived in `Sources/Playground/ShaderEditor.swift` while the gallery was
/// the playground's alone. It moved here rather than being copied because
/// `Sources/Saver` cannot import `Sources/Playground`, and two divergent copies
/// of the same colours is how the same gallery ends up looking like two
/// different features.

/// Editor colors. Dark-only and hard-coded rather than semantic: these panes sit
/// next to a live shader, and the two should not shift with the system theme.
public enum EditorTheme {
    public static let background = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.110, alpha: 1)
    public static let chrome     = NSColor(srgbRed: 0.114, green: 0.122, blue: 0.145, alpha: 1)
    public static let text       = NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1)
    public static let dim        = NSColor(srgbRed: 0.365, green: 0.400, blue: 0.463, alpha: 1)
    public static let error      = NSColor(srgbRed: 1.000, green: 0.353, blue: 0.353, alpha: 1)
    public static let font       = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
}

/// The handful of AppKit idioms every pane repeats. Stock controls in stack
/// views — the point of these is that there is one copy of the spacing/colour
/// decisions, not that they add any behaviour.
public enum Chrome {

    public static func configure(_ button: NSButton, title: String, target: AnyObject?, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.target = target
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    public static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton()
        configure(button, title: title, target: target, action: action)
        return button
    }

    public static func label(_ text: String, size: CGFloat = 11,
                             color: NSColor = EditorTheme.dim) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// A control strip. One `flexible()` in `controls` decides where the slack
    /// goes — without one the stack's horizontal placement is ambiguous.
    public static func bar(_ controls: [NSView], height: CGFloat = 38) -> NSView {
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

    public static func flexible() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    public static func pane(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width      // every row spans the pane
        stack.spacing = 0
        stack.wantsLayer = true
        stack.layer?.backgroundColor = EditorTheme.background.cgColor
        return stack
    }

    /// A popup's menu, in menu order: the titles it shows and the value each one
    /// stores. Titles, value → index and index → value all come out of the one
    /// table, because spelling the same three-row menu out three times is how a
    /// popup ends up one item off from what it saves.
    ///
    /// Both hosts have such a menu — the saver's Options… sheet for render scale
    /// and the still-image timer, the playground's toolbar for render scale —
    /// and both had their own arithmetic for reading one back. The *tables*
    /// stay where they are, because they honestly differ; only the three lines
    /// that get them wrong are shared.
    public typealias Choices = [(title: String, value: Double)]

    /// Where `value` sits in the menu, or `fallback` for a value the menu does
    /// not offer (only reachable by hand-editing the defaults).
    public static func index(of value: Double, in choices: Choices, default fallback: Int) -> Int {
        choices.firstIndex { $0.value == value } ?? fallback
    }

    /// The value a popup is sitting on, clamped to the menu.
    public static func value(of popup: NSPopUpButton?, in choices: Choices,
                             default fallback: Int) -> Double {
        let index = popup?.indexOfSelectedItem ?? fallback
        return choices[max(0, min(index, choices.count - 1))].value
    }

    /// Fills a popup with `choices` and puts it on the item holding `value`.
    public static func fill(_ popup: NSPopUpButton, with choices: Choices,
                            selecting value: Double, default fallback: Int) {
        popup.removeAllItems()
        popup.addItems(withTitles: choices.map(\.title))
        popup.selectItem(at: index(of: value, in: choices, default: fallback))
    }
}
