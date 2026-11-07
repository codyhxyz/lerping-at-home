import AppKit

/// The strip under the editor and the error list that opens above it.
///
/// It used to be one monospace line that every message in the app wrote over —
/// "✓ compiled in 12 ms", then "Learned CC 21 → speed", then the camera — and a
/// pink text dump below it. So the one thing you most need while typing, whether
/// the shader compiles, was replaced by whatever happened last and stayed
/// replaced until the next keystroke.
///
/// Now the two are kept apart:
/// - The **compile pill** on the left always shows whether the buffer compiles,
///   with a green or red dot.
/// - **Notes** appear to its right and fade away. A note can be sticky while it
///   describes something still going on, like MIDI Learn waiting for a knob.
/// - **Errors** are rows with a line badge. A click jumps to that line.
final class StatusStrip: NSView {

    enum Compile: Equatable {
        case idle(String)
        case compiled(milliseconds: Double)
        case failed(errors: Int)
        case problem(String)
    }

    enum Tone { case info, success, error }

    /// Called with a 1-based line when an error row or the failed pill is clicked.
    var onJump: ((Int) -> Void)?

    /// The bar itself, for the editor pane's stack.
    let bar = NSView()
    /// The list of diagnostics, collapsed to nothing while the shader compiles.
    let errors = DiagnosticList()

    private let pill = CompilePill()
    private let note = NSTextField(labelWithString: "")
    private let noteIcon = NSImageView()
    private var noteFade: DispatchWorkItem?
    private(set) var compile: Compile = .idle("Ready")
    private(set) var noteText: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = EditorTheme.chrome.cgColor
        bar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        bar.setAccessibilityIdentifier("status-strip")

        pill.target = self
        pill.action = #selector(pillClicked)
        pill.setAccessibilityIdentifier("compile-status")

        note.font = .systemFont(ofSize: 11)
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        note.setContentHuggingPriority(.init(1), for: .horizontal)
        note.setAccessibilityIdentifier("status-note")
        noteIcon.imageScaling = .scaleProportionallyDown
        noteIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let noteGroup = NSStackView(views: [noteIcon, note])
        noteGroup.spacing = 5
        noteGroup.alphaValue = 0
        noteGroup.identifier = NSUserInterfaceItemIdentifier("note-group")
        noteGroup.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [pill, noteGroup, Chrome.flexible()])
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])

        errors.onJump = { [weak self] line in self?.onJump?(line) }
        show(compile)
    }

    required init?(coder: NSCoder) { nil }

    private var noteGroup: NSView { note.superview! }

    // MARK: - Compile state

    func show(_ state: Compile) {
        compile = state
        pill.state(state)
        pill.toolTip = switch state {
        case .failed: "Jump to the first error (⌘E)"
        default: nil
        }
    }

    /// The compiler's findings, or none. With nothing parseable the raw log is
    /// shown as one row, so a linker error is never swallowed.
    func showDiagnostics(_ items: [ShaderDiagnostic], raw: String) {
        errors.show(items, raw: raw)
    }

    @objc private func pillClicked() {
        if case .failed = compile, let line = errors.firstErrorLine { onJump?(line) }
    }

    // MARK: - Notes

    /// A message beside the compile pill. It fades after a few seconds unless
    /// `sticky`. The next note replaces it either way.
    func note(_ text: String, tone: Tone = .info, sticky: Bool = false) {
        noteFade?.cancel()
        noteText = text
        note.stringValue = text
        note.toolTip = text
        let (symbol, color): (String, NSColor) = switch tone {
        case .info: ("info.circle.fill", EditorTheme.text.withAlphaComponent(0.8))
        case .success: ("checkmark.circle.fill", StatusStrip.green)
        case .error: ("exclamationmark.triangle.fill", EditorTheme.error)
        }
        note.textColor = tone == .error ? EditorTheme.error : EditorTheme.text.withAlphaComponent(0.85)
        noteIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        noteIcon.contentTintColor = color
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            noteGroup.animator().alphaValue = 1
        }
        guard !sticky else { return }
        // Long enough to read a sentence; errors are given longer because they
        // usually say what to do next.
        let seconds = tone == .error ? 8.0 : max(3.5, min(7, Double(text.count) / 14))
        let fade = DispatchWorkItem { [weak self] in self?.clearNote() }
        noteFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: fade)
    }

    func clearNote() {
        noteFade?.cancel()
        noteText = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.6
            noteGroup.animator().alphaValue = 0
        }
    }

    static let green = NSColor(srgbRed: 0.42, green: 0.84, blue: 0.55, alpha: 1)
}

// MARK: - Compile pill

/// A dot and a few words in a rounded capsule: green when the buffer compiles,
/// red when it does not, grey before anything has been tried.
private final class CompilePill: NSButton {
    private var dot = EditorTheme.dim
    private var words = ""
    private var tint = EditorTheme.dim
    private var fill = NSColor.clear
    private var clickable = false
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        focusRingType = .none
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    func state(_ state: StatusStrip.Compile) {
        switch state {
        case .idle(let text):
            (dot, words, tint, fill, clickable) = (EditorTheme.dim, text, EditorTheme.dim, .clear, false)
        case .compiled(let ms):
            (dot, tint) = (StatusStrip.green, StatusStrip.green)
            words = String(format: "Compiled · %.0f ms", ms)
            fill = StatusStrip.green.withAlphaComponent(0.10)
            clickable = false
        case .failed(let count):
            (dot, tint) = (EditorTheme.error, EditorTheme.error)
            words = "\(count) error\(count == 1 ? "" : "s")"
            fill = EditorTheme.error.withAlphaComponent(0.13)
            clickable = true
        case .problem(let text):
            (dot, words, tint, fill, clickable) = (EditorTheme.error, text, EditorTheme.error,
                                                   EditorTheme.error.withAlphaComponent(0.13), false)
        }
        setAccessibilityLabel(words)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var attributed: NSAttributedString {
        NSAttributedString(string: words, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributed.size().width) + 30, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() {
        if clickable { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let capsule = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2,
                                 yRadius: capsule.height / 2)
        (clickable && (hovered || isHighlighted) ? fill.withAlphaComponent(fill.alphaComponent * 1.8)
            : fill).setFill()
        shape.fill()

        let dotRect = NSRect(x: 9, y: bounds.midY - 3.5, width: 7, height: 7)
        // A soft halo so the dot reads as a light, not a bullet.
        if fill != .clear {
            dot.withAlphaComponent(0.28).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -2, dy: -2)).fill()
        }
        dot.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let text = attributed
        let size = text.size()
        text.draw(at: NSPoint(x: 22, y: bounds.midY - size.height / 2))
    }
}

// MARK: - Diagnostics

/// One row per compiler diagnostic: a line badge, the severity's colour, the
/// message. Errors first in source order, each followed by its notes, as the
/// compiler printed them.
final class DiagnosticList: NSView {

    var onJump: ((Int) -> Void)?
    private(set) var firstErrorLine: Int?
    private(set) var rowCount = 0

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var height: NSLayoutConstraint!

    static let background = NSColor(srgbRed: 0.118, green: 0.078, blue: 0.090, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        setAccessibilityIdentifier("diagnostics")

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        // A hairline in the error colour, so the list reads as attached to the
        // pill above rather than as a second editor.
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = EditorTheme.error.withAlphaComponent(0.35).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    func show(_ items: [ShaderDiagnostic], raw: String) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        firstErrorLine = items.filter(\.isError).map(\.line).min()
        var rows: [NSView] = items.map { DiagnosticRow($0, target: self) }
        if items.isEmpty, !raw.isEmpty { rows = [RawLogRow(raw)] }
        for row in rows {
            stack.addArrangedSubview(row)
            // `.width` alignment leaves a borderless button at its intrinsic
            // width, which for these is nothing.
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: stack.edgeInsets.left).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -stack.edgeInsets.right).isActive = true
        }
        rowCount = rows.count
        isHidden = rows.isEmpty
        stack.layoutSubtreeIfNeeded()
        let content = stack.fittingSize.height
        height.constant = rows.isEmpty ? 0 : min(150, max(34, content + 1))
    }

    @objc fileprivate func rowClicked(_ sender: DiagnosticRow) { onJump?(sender.line) }
}

private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// "L14  use of undeclared identifier 'fbm'", clickable.
private final class DiagnosticRow: NSButton {
    let line: Int
    private let diagnostic: ShaderDiagnostic
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }

    init(_ diagnostic: ShaderDiagnostic, target: DiagnosticList) {
        self.diagnostic = diagnostic
        line = diagnostic.line
        super.init(frame: .zero)
        isBordered = false
        title = ""
        focusRingType = .none
        self.target = target
        action = #selector(DiagnosticList.rowClicked(_:))
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        toolTip = "\(diagnostic.severity.capitalized) on line \(diagnostic.line), column \(diagnostic.column)"
            + " — click to jump\n\(diagnostic.message)"
        setAccessibilityLabel("Line \(diagnostic.line): \(diagnostic.message)")
        setAccessibilityIdentifier("diagnostic:\(diagnostic.line)")
    }

    required init?(coder: NSCoder) { nil }

    private var color: NSColor {
        switch diagnostic.severity {
        case "error": EditorTheme.error
        case "warning": NSColor(srgbRed: 1.0, green: 0.74, blue: 0.33, alpha: 1)
        default: EditorTheme.dim
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            NSColor(white: 1, alpha: isHighlighted ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let isNote = diagnostic.severity == "note"
        let indent: CGFloat = isNote ? 18 : 0

        // Line badge.
        let badgeText = NSAttributedString(string: "\(diagnostic.line)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: isNote ? EditorTheme.dim : color])
        let badgeSize = badgeText.size()
        let badge = NSRect(x: 4 + indent, y: bounds.midY - 8,
                           width: max(30, ceil(badgeSize.width) + 12), height: 16)
        color.withAlphaComponent(isNote ? 0.10 : 0.17).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
        badgeText.draw(at: NSPoint(x: badge.midX - badgeSize.width / 2,
                                   y: badge.midY - badgeSize.height / 2))

        // Message, truncated to the row.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let message = NSAttributedString(string: diagnostic.message, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: isNote ? EditorTheme.dim : EditorTheme.text.withAlphaComponent(0.92),
            .paragraphStyle: paragraph])
        let x = badge.maxX + 9
        let height = message.size().height
        message.draw(in: NSRect(x: x, y: bounds.midY - height / 2,
                                width: bounds.width - x - 8, height: height))
    }
}

/// The compiler's log as it came, when it has no line numbers in it.
private final class RawLogRow: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = NSColor(srgbRed: 1.0, green: 0.706, blue: 0.694, alpha: 1)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
