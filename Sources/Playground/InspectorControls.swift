import AppKit

/// The inspector's look. These controls are stock AppKit controls underneath —
/// target/action, `doubleValue`, tick snapping, the colour panel and
/// accessibility are all AppKit's — and only the drawing is replaced, because
/// the stock light-chrome knobs and bezelled fields sat on the dark pane like
/// controls from a different app.
///
/// One accent, used for one meaning: "this is the value". A second colour,
/// `drift`, means "this value is moving on its own" (`// lerp-animate:`), so a
/// drifting parameter reads as different at a glance rather than only through
/// a small icon.
enum InspectorStyle {
    static let accent   = NSColor(srgbRed: 0.36, green: 0.69, blue: 1.00, alpha: 1)
    static let drift    = NSColor(srgbRed: 0.69, green: 0.56, blue: 1.00, alpha: 1)
    static let track    = NSColor(white: 1, alpha: 0.09)
    static let hover    = NSColor(white: 1, alpha: 0.035)
    static let well     = NSColor(white: 1, alpha: 0.05)
    static let hairline = NSColor(white: 1, alpha: 0.07)
    static let heading  = NSColor(srgbRed: 0.53, green: 0.57, blue: 0.64, alpha: 1)

    /// The fixed columns every parameter row shares, so values line up down
    /// the panel whether or not a row has a drift toggle beside its name.
    static let labelWidth: CGFloat = 100
    static let valueWidth: CGFloat = 58
    static let rowHeight: CGFloat = 26
}

// MARK: - Slider

/// A thin track, a fill from the origin to the knob, and a small round knob.
/// The fill starts at zero when the declared range spans it, so a bipolar
/// parameter reads as "how far, which way" rather than "how far from the
/// minimum". Integer sliders draw their stops as notches in the track.
final class InspectorSliderCell: NSSliderCell {
    /// Drawn in the drift colour while the parameter animates.
    var isDrifting = false { didSet { controlView?.needsDisplay = true } }

    private static let trackHeight: CGFloat = 4
    private static let knobRadius: CGFloat = 6

    /// Where the fill starts.
    private var origin: Double { (minValue < 0 && maxValue > 0) ? 0 : minValue }

    /// The knob centre for `value`. The knob travels inside the bar, so its
    /// centre is inset half a knob from either end — the same geometry AppKit
    /// tracks the mouse with, which is what keeps the knob under the cursor.
    func centerX(for value: Double, flipped: Bool) -> CGFloat {
        let bar = barRect(flipped: flipped)
        let half = knobThickness / 2
        let span = maxValue - minValue
        let t = span > 0 ? CGFloat((value - minValue) / span) : 0
        return bar.minX + half + max(0, min(1, t)) * (bar.width - 2 * half)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let flipped = controlView.isFlipped
        let midY = cellFrame.midY.rounded(.down) + 0.5
        let bar = barRect(flipped: flipped)
        let tint = isDrifting ? InspectorStyle.drift : InspectorStyle.accent
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let h = Self.trackHeight

        let track = NSRect(x: bar.minX, y: midY - h / 2, width: bar.width, height: h)
        InspectorStyle.track.withAlphaComponent(0.09 * alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        let knobX = centerX(for: doubleValue, flipped: flipped)
        let startX = origin == minValue ? bar.minX : centerX(for: origin, flipped: flipped)
        let fill = NSRect(x: min(startX, knobX), y: track.minY,
                          width: abs(knobX - startX), height: h)
        if fill.width > 0.5 {
            let path = NSBezierPath(roundedRect: fill, xRadius: h / 2, yRadius: h / 2)
            if isDrifting {
                NSGradient(starting: InspectorStyle.accent.withAlphaComponent(0.75 * alpha),
                           ending: tint.withAlphaComponent(alpha))?.draw(in: path, angle: 0)
            } else {
                tint.withAlphaComponent(alpha).setFill()
                path.fill()
            }
        }
        if origin != minValue {
            // The zero a bipolar fill grows from.
            NSColor(white: 1, alpha: 0.35 * alpha).setFill()
            NSRect(x: startX - 0.5, y: midY - h, width: 1, height: h * 2).fill()
        }

        // Stops, for an integer slider: notches cut into the track.
        if numberOfTickMarks > 1 {
            for i in 0..<numberOfTickMarks {
                let x = centerX(for: tickMarkValue(at: i), flipped: flipped)
                let under = x >= min(startX, knobX) && x <= max(startX, knobX) && fill.width > 0.5
                (under ? NSColor(white: 0, alpha: 0.45) : NSColor(white: 1, alpha: 0.28 * alpha)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 1.25, y: midY - 1.25, width: 2.5, height: 2.5)).fill()
            }
        }

        // The knob. Larger while it is held, so the hand can feel it took.
        let r = isHighlighted ? Self.knobRadius + 1 : Self.knobRadius
        let knob = NSRect(x: knobX - r, y: midY - r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: flipped ? 1 : -1)
        shadow.set()
        EditorTheme.text.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
        tint.withAlphaComponent(alpha).setStroke()
        let ring = NSBezierPath(ovalIn: knob.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func drawKnob(_ knobRect: NSRect) {}
}

// MARK: - Value field

/// The numeric echo beside a slider, or a colour's hex. Reads as a value, not a
/// form field: no bezel, a faint well, text centred vertically, and the field
/// editor placed exactly where the text was so typing does not jump.
final class InspectorFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        var r = rect.insetBy(dx: 4, dy: 0)
        let h = ceil(font?.boundingRectForFont.height ?? r.height)
        if h < r.height {
            r.origin.y += ((r.height - h) / 2).rounded(.down)
            r.size.height = h
        }
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { centered(rect) }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }
}

extension NSTextField {
    static func inspectorValue() -> NSTextField {
        let field = NSTextField(string: "")
        field.cell = InspectorFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.textColor = EditorTheme.text
        field.alignment = .right
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 5
        field.layer?.backgroundColor = InspectorStyle.well.cgColor
        field.widthAnchor.constraint(equalToConstant: InspectorStyle.valueWidth).isActive = true
        field.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return field
    }
}

// MARK: - Colour

/// A colour well drawn as a plain swatch that fills the control column, with a
/// checkerboard under any transparency. Clicking it is still NSColorWell's
/// click: the popover, and from it the full colour panel.
final class InspectorSwatch: NSColorWell {
    /// Ringed in the drift colour while the colour animates.
    var isDrifting = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if color.alphaComponent < 1 {
            NSColor(white: 0.85, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.6, alpha: 1).setFill()
            let s: CGFloat = 5
            var y = rect.minY, row = 0
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? 0 : s)
                while x < rect.maxX { NSRect(x: x, y: y, width: s, height: s).fill(); x += 2 * s }
                y += s; row += 1
            }
        }
        color.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        let stroke: NSColor = isActive ? InspectorStyle.accent
            : isDrifting ? InspectorStyle.drift : NSColor(white: 1, alpha: 0.14)
        stroke.setStroke()
        path.lineWidth = isActive || isDrifting ? 1.5 : 1
        path.stroke()
    }

    override func activate(_ exclusive: Bool) { super.activate(exclusive); needsDisplay = true }
    override func deactivate() { super.deactivate(); needsDisplay = true }
}

extension NSColor {
    /// "#RRGGBB". Alpha is left to the swatch's checkerboard: two more digits
    /// do not fit the column, and the colour is what is being read here.
    var lerpHex: String {
        guard let c = lerpComponents else { return "—" }
        func byte(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.x), byte(c.y), byte(c.z))
    }

    /// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA", with or without the "#". A
    /// form without alpha keeps `alpha`, so retyping the hex the field shows
    /// does not make a translucent colour opaque.
    static func lerp(hex: String, alpha: Float) -> SIMD4<Float>? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        let n = s.count == 6 ? (v << 8) | 0xFF : v
        var c = SIMD4<Float>(Float((n >> 24) & 0xFF), Float((n >> 16) & 0xFF),
                             Float((n >> 8) & 0xFF), Float(n & 0xFF)) / 255
        if s.count == 6 { c.w = alpha }
        return c
    }
}

// MARK: - Rows and headings

/// A row that lights faintly under the pointer, so it is clear which
/// parameter a right-click or a scroll is about to act on.
class InspectorHoverView: NSView {
    var hoverColor: NSColor? = InspectorStyle.hover
    private(set) var isHovered = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// Subclasses that have their own selected state draw it here.
    func refresh() {
        layer?.backgroundColor = isHovered ? hoverColor?.cgColor : nil
    }
}

/// A borderless button for a section heading: an SF Symbol, an optional
/// word, dim until the pointer is over it.
final class InspectorHeaderButton: NSButton {
    private var hovered = false { didSet { restyle() } }

    convenience init(symbol: String, title: String?, accessibility: String,
                     target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(config)
        imagePosition = title == nil ? .imageOnly : .imageLeading
        self.title = title ?? ""
        isBordered = false
        bezelStyle = .regularSquare
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 5
        setContentHuggingPriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        if title == nil { widthAnchor.constraint(equalToConstant: 24).isActive = true }
        restyle()
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if !title.isEmpty { size.width += 12 }
        return size
    }

    override var isEnabled: Bool { didSet { restyle() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func restyle() {
        let color = !isEnabled ? EditorTheme.dim.withAlphaComponent(0.5)
            : hovered ? EditorTheme.text : InspectorStyle.heading
        contentTintColor = color
        if !title.isEmpty {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color])
        }
        layer?.backgroundColor = hovered && isEnabled ? NSColor(white: 1, alpha: 0.07).cgColor : nil
    }
}

enum InspectorHeading {
    /// A section heading: a small tracked caps title, an optional count, and
    /// its actions at the trailing edge. A hairline above separates it from
    /// the section before, rather than a filled bar, so the headings recede
    /// and the values lead.
    static func make(_ title: String, count: NSTextField?, accessories: [NSView],
                     hairline: Bool) -> NSView {
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: title.uppercased(),
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .kern: 0.9, .foregroundColor: InspectorStyle.heading]))
        let views: [NSView] = [label, count, Chrome.flexible()].compactMap { $0 } + accessories
        let stack = NSStackView(views: views)
        stack.distribution = .fill
        stack.spacing = 6
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 13, bottom: 0, right: 8)
        stack.heightAnchor.constraint(equalToConstant: 32).isActive = true
        guard hairline else { return stack }
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = InspectorStyle.hairline
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(line)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: stack.topAnchor),
            line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -10),
        ])
        return stack
    }

    /// The dim count beside a heading's title.
    static func count() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        field.textColor = EditorTheme.dim
        return field
    }
}
