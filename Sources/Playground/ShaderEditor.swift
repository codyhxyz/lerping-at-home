import AppKit

/// Editor colors. Dark-only and hard-coded rather than semantic: the editor sits
/// next to a live shader, and the two should not shift with the system theme.
enum EditorTheme {
    static let background = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.110, alpha: 1)
    static let chrome     = NSColor(srgbRed: 0.114, green: 0.122, blue: 0.145, alpha: 1)
    static let text       = NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1)
    static let dim        = NSColor(srgbRed: 0.365, green: 0.400, blue: 0.463, alpha: 1)
    static let error      = NSColor(srgbRed: 1.000, green: 0.353, blue: 0.353, alpha: 1)
    static let font       = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
}

/// NSTextView with the two editing affordances a shader scratchpad actually
/// needs: soft tabs and newline auto-indent.
final class MetalTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let line = text.substring(with: text.lineRange(for: NSRange(location: selectedRange().location, length: 0)))
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{") { indent += "    " }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

/// Scrollable `.metal` source editor. Lines the Metal compiler complained about
/// get a red wash, and `scrollToLine` jumps to one.
final class ShaderEditorView: NSScrollView, NSTextViewDelegate {
    let textView: MetalTextView

    /// Fires on every user edit (not on programmatic `setText`).
    var onEdit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        // An explicit TextKit 1 stack: error lines are drawn with the layout
        // manager's *temporary* attributes, which never touch the document and
        // so can't dirty the buffer or the undo stack.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = MetalTextView(frame: NSRect(origin: .zero, size: frameRect.size),
                                 textContainer: container)
        super.init(frame: frameRect)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = EditorTheme.font
        textView.textColor = EditorTheme.text
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.text
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        documentView = textView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = EditorTheme.background
        borderType = .noBorder
    }

    required init?(coder: NSCoder) { nil }

    var text: String { textView.string }

    /// Replaces the whole document without reporting an edit (loading a file,
    /// reverting, reloading from disk).
    func setText(_ value: String) {
        textView.string = value
        textView.undoManager?.removeAllActions()
        setErrorLines([])
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Replaces the buffer and reports it as an edit — the same path a keystroke
    /// takes. Used by `--selftest` to exercise hot reload.
    func replaceTextAsEdit(_ value: String) {
        textView.string = value
        onEdit?()
    }

    func setErrorLines(_ lines: Set<Int>) {
        guard let layoutManager = textView.layoutManager else { return }
        layoutManager.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        for line in lines {
            guard let range = range(ofLine: line) else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: EditorTheme.error.withAlphaComponent(0.22)],
                                                 forCharacterRange: range)
        }
    }

    func scrollToLine(_ line: Int) {
        guard let range = range(ofLine: line) else { return }
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        window?.makeFirstResponder(textView)
    }

    /// Character range of the 1-based `line`, or nil if the document is shorter.
    private func range(ofLine line: Int) -> NSRange? {
        guard line >= 1 else { return nil }
        let text = textView.string as NSString
        var location = 0
        for _ in 1..<line {
            let end = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            guard end > location, end < text.length else { return nil }
            location = end
        }
        return text.lineRange(for: NSRange(location: location, length: 0))
    }

    func textDidChange(_ notification: Notification) {
        onEdit?()
    }
}
