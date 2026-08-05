import AppKit

// MARK: - Palette

/// Editor colors. Dark-only on purpose: you are staring at a shader next to it.
enum EditorTheme {
    static let background   = NSColor(srgbRed: 0.086, green: 0.090, blue: 0.110, alpha: 1)
    static let gutter       = NSColor(srgbRed: 0.063, green: 0.067, blue: 0.086, alpha: 1)
    static let gutterText   = NSColor(srgbRed: 0.365, green: 0.400, blue: 0.463, alpha: 1)
    static let plain        = NSColor(srgbRed: 0.847, green: 0.871, blue: 0.914, alpha: 1)
    static let comment      = NSColor(srgbRed: 0.400, green: 0.451, blue: 0.510, alpha: 1)
    static let keyword      = NSColor(srgbRed: 0.780, green: 0.573, blue: 0.918, alpha: 1)
    static let type         = NSColor(srgbRed: 0.510, green: 0.667, blue: 1.000, alpha: 1)
    static let prelude      = NSColor(srgbRed: 0.400, green: 0.851, blue: 0.749, alpha: 1)
    static let builtin      = NSColor(srgbRed: 0.537, green: 0.804, blue: 0.980, alpha: 1)
    static let number       = NSColor(srgbRed: 0.973, green: 0.596, blue: 0.408, alpha: 1)
    static let preprocessor = NSColor(srgbRed: 0.941, green: 0.776, blue: 0.455, alpha: 1)
    static let errorTint    = NSColor(srgbRed: 1.000, green: 0.353, blue: 0.353, alpha: 1)

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
}

// MARK: - Syntax highlighting

/// Deliberately regex-based and approximate. It has to be fast enough to run on
/// every keystroke and wrong-but-pretty beats right-but-slow for a scratchpad.
enum MetalHighlighter {

    private static let keywords = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch",
        "case", "default", "struct", "using", "namespace", "static", "inline",
        "const", "constant", "device", "thread", "threadgroup", "typedef", "true",
        "false", "fragment", "vertex", "kernel", "template", "sizeof", "enum",
    ]
    private static let types = [
        "void", "bool", "char", "short", "int", "uint", "long", "float", "half",
        "float2", "float3", "float4", "half2", "half3", "half4", "int2", "int3",
        "int4", "uint2", "uint3", "uint4", "bool2", "bool3", "bool4",
        "float2x2", "float3x3", "float4x4", "half2x2", "half3x3", "half4x4",
        "LerpUniforms", "auto", "texture2d", "sampler",
    ]
    private static let preludeSymbols = [
        "lerpUV", "lerpScreenUV", "lerpDither", "lerpMain", "rotate",
        "hash11", "hash21", "hash22", "valueNoise", "snoise",
        "glmod", "glmod2", "glmod3", "PI", "TWO_PI",
    ]
    private static let builtins = [
        "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh",
        "pow", "exp", "exp2", "log", "log2", "sqrt", "rsqrt", "abs", "sign", "floor",
        "ceil", "round", "trunc", "fract", "fmod", "mix", "clamp", "saturate",
        "smoothstep", "step", "min", "max", "length", "length_squared", "normalize",
        "dot", "cross", "distance", "reflect", "refract", "fwidth", "dfdx", "dfdy",
        "transpose", "determinant", "select", "isnan", "isinf",
    ]

    private static func wordRegex(_ words: [String]) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\b(" + words.joined(separator: "|") + ")\\b")
    }

    private static let rules: [(NSRegularExpression, NSColor)] = [
        (wordRegex(keywords), EditorTheme.keyword),
        (wordRegex(types), EditorTheme.type),
        (wordRegex(builtins), EditorTheme.builtin),
        (wordRegex(preludeSymbols), EditorTheme.prelude),
        // swiftlint:disable:next force_try
        (try! NSRegularExpression(pattern: "\\b\\d+\\.?\\d*([eE][-+]?\\d+)?[fFhHuU]?\\b"), EditorTheme.number),
        // swiftlint:disable:next force_try
        (try! NSRegularExpression(pattern: "^[ \\t]*#[a-z_]+.*$", options: [.anchorsMatchLines]), EditorTheme.preprocessor),
        // Comments last so they win over everything they contain.
        // swiftlint:disable:next force_try
        (try! NSRegularExpression(pattern: "//[^\\n]*|/\\*(?s:.)*?\\*/"), EditorTheme.comment),
    ]

    static func apply(to storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: EditorTheme.font, .foregroundColor: EditorTheme.plain], range: full)
        let text = storage.string
        for (regex, color) in rules {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
    }
}

// MARK: - Line-number gutter

final class LineNumberRulerView: NSRulerView {
    weak var editorTextView: NSTextView?
    var errorLines: Set<Int> = [] { didSet { needsDisplay = true } }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.editorTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
    }

    required init(coder: NSCoder) { fatalError("unsupported") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        EditorTheme.gutter.setFill()
        bounds.fill()
        NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1).setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let textView = editorTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let text = textView.string as NSString
        let visible = scrollView?.contentView.bounds ?? .zero
        let inset = textView.textContainerInset.height

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Line number of the first visible character.
        var lineNumber = 1
        if charRange.location > 0 {
            text.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location),
                                     options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lineNumber += 1
            }
        }

        var index = text.lineRange(for: NSRange(location: min(charRange.location, text.length), length: 0)).location
        let end = NSMaxRange(charRange)

        // `index < text.length` matters: at the very end `lineRange(for:)`
        // returns the last line again when the text has no trailing newline,
        // which would spin forever.
        while index <= end, index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            var effective = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: min(glyphIndex, max(0, layoutManager.numberOfGlyphs - 1)),
                                                          effectiveRange: &effective,
                                                          withoutAdditionalLayout: true)
            let y = fragment.minY + inset - visible.minY
            draw(number: lineNumber, atY: y, height: fragment.height)

            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= index { break }
            index = next
        }

        // The empty line after a final newline holds no characters, so it only
        // exists as the layout manager's extra fragment.
        if text.length > 0, text.hasSuffix("\n"), end >= text.length {
            let fragment = layoutManager.extraLineFragmentRect
            if fragment.height > 0 {
                draw(number: lineNumber, atY: fragment.minY + inset - visible.minY, height: fragment.height)
            }
        }
    }

    private func draw(number: Int, atY y: CGFloat, height: CGFloat) {
        let isError = errorLines.contains(number)
        if isError {
            EditorTheme.errorTint.withAlphaComponent(0.22).setFill()
            NSRect(x: 0, y: y, width: bounds.width - 1, height: max(height, 1)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTheme.gutterFont,
            .foregroundColor: isError ? EditorTheme.errorTint : EditorTheme.gutterText,
        ]
        let string = NSAttributedString(string: "\(number)", attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.width - size.width - 9,
                                y: y + max(0, (height - size.height) / 2) + 1))
    }
}

// MARK: - Text view

/// NSTextView with the two editing affordances a shader scratchpad actually
/// needs: soft tabs and newline auto-indent.
final class MetalTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if line.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("{") { indent += "    " }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }
}

// MARK: - Editor

/// Scrollable, highlighted, gutter-numbered .metal source editor.
final class ShaderEditorView: NSView {
    let textView: MetalTextView
    private let scrollView = NSScrollView()
    private let ruler: LineNumberRulerView

    /// Fires on every user edit (not on programmatic `setText`).
    var onEdit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        textView = MetalTextView(frame: NSRect(x: 0, y: 0, width: frameRect.width, height: frameRect.height),
                                 textContainer: container)
        ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
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
        textView.textColor = EditorTheme.plain
        textView.backgroundColor = EditorTheme.background
        textView.insertionPointColor = EditorTheme.prelude
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.20, green: 0.24, blue: 0.34, alpha: 1)]
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = EditorTheme.background
        scrollView.borderType = .noBorder
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redrawRuler),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
    }

    required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redrawRuler() { ruler.needsDisplay = true }

    var text: String {
        get { textView.string }
    }

    /// Replaces the whole document without reporting an edit (used when loading
    /// a file or reverting).
    func setText(_ value: String) {
        textView.string = value
        textView.undoManager?.removeAllActions()
        highlight()
        setErrorLines([])
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Replaces the buffer and reports it as an edit — the same path a
    /// keystroke takes. Used by `--selftest` to exercise hot reload.
    func replaceTextAsEdit(_ value: String) {
        textView.string = value
        highlight()
        onEdit?()
    }

    func highlight() {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        MetalHighlighter.apply(to: storage)
        if selection.location <= storage.length {
            textView.setSelectedRange(NSRange(location: selection.location,
                                              length: min(selection.length, storage.length - selection.location)))
        }
        ruler.needsDisplay = true
    }

    func setErrorLines(_ lines: Set<Int>) {
        ruler.errorLines = lines
        guard let layoutManager = textView.layoutManager else { return }
        let text = textView.string as NSString
        layoutManager.removeTemporaryAttribute(.backgroundColor,
                                               forCharacterRange: NSRange(location: 0, length: text.length))
        for line in lines {
            guard let range = characterRange(ofLine: line) else { continue }
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: EditorTheme.errorTint.withAlphaComponent(0.14)],
                forCharacterRange: range)
        }
    }

    func characterRange(ofLine line: Int) -> NSRange? {
        guard line >= 1 else { return nil }
        let text = textView.string as NSString
        var current = 1
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            if current == line { return range }
            let next = NSMaxRange(range)
            if next <= location { break }   // last line, no trailing newline
            location = next
            current += 1
        }
        // The empty line after a final newline.
        return current == line ? NSRange(location: text.length, length: 0) : nil
    }

    func scrollToLine(_ line: Int) {
        guard let range = characterRange(ofLine: line) else { return }
        textView.scrollRangeToVisible(range)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
        window?.makeFirstResponder(textView)
    }
}

extension ShaderEditorView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        highlight()
        onEdit?()
    }
}
