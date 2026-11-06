import AppKit

/// The editor bar's way into the selector, and its two steps through it.
///
/// It used to be a text dropdown ("◱ fractal-multiverse · Lattice ▾") and two
/// bare ‹ › buttons. Both undersold what they lead to. The selector is a wall
/// of pictures, and a dropdown arrow promised a menu of names. The arrows walk
/// 70-odd shaders, but nothing said which one was next.
///
/// So this shows pictures too. It is one capsule of three parts, each a button:
///
/// - **‹ / ›** draw the *neighbouring* shader's still behind the chevron, so
///   the arrow shows where it goes. Pointing at one names that shader in the
///   middle part's second line.
/// - **The middle** shows the open look's own still, its name, the preset it
///   is wearing and where it sits in the list ("12 of 71"), and a grid glyph
///   for the wall of pictures it opens. A dot after the name means unsaved
///   edits.
///
/// The stills are the selector's own cache (`RotationThumbnails`). The host
/// hands them in and nothing here renders, so the toolbar never pays for a
/// GPU frame. A look with no still yet draws a quiet gradient.
final class LookSwitcher: NSView {

    let previous = StepButton(direction: -1)
    let next = StepButton(direction: 1)
    let current = CurrentLookButton()

    static let height: CGFloat = 30
    private static let radius: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.055).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.07).cgColor

        for view in [previous, current, next] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let seams = [NSBox(), NSBox()]
        for seam in seams {
            seam.boxType = .custom
            seam.borderWidth = 0
            seam.fillColor = NSColor(white: 0, alpha: 0.35)
            seam.translatesAutoresizingMaskIntoConstraints = false
            addSubview(seam)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            previous.leadingAnchor.constraint(equalTo: leadingAnchor),
            previous.widthAnchor.constraint(equalToConstant: StepButton.width),
            seams[0].leadingAnchor.constraint(equalTo: previous.trailingAnchor),
            seams[0].widthAnchor.constraint(equalToConstant: 1),
            current.leadingAnchor.constraint(equalTo: seams[0].trailingAnchor),
            seams[1].leadingAnchor.constraint(equalTo: current.trailingAnchor),
            seams[1].widthAnchor.constraint(equalToConstant: 1),
            next.leadingAnchor.constraint(equalTo: seams[1].trailingAnchor),
            next.widthAnchor.constraint(equalToConstant: StepButton.width),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for view in [previous, current, next, seams[0], seams[1]] as [NSView] {
            view.topAnchor.constraint(equalTo: topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }
        // Pointing at an arrow names where it goes, in the one place that is
        // already about "which look".
        previous.onHover = { [weak self] on in self?.current.peek = on ? self?.previous.neighbour : nil }
        next.onHover = { [weak self] on in self?.current.peek = on ? self?.next.neighbour : nil }
    }

    required init?(coder: NSCoder) { nil }

    /// What the middle shows.
    struct Look: Equatable {
        var name: String
        /// The preset worn, "Defaults", or nil when the shader has no presets.
        var preset: String?
        var position: String
        var isCustom = false
        var isEdited = false
    }

    func show(_ look: Look, still: NSImage?) {
        current.look = look
        current.still = still
        setAccessibilityLabel("\(look.name)\(look.preset.map { ", \($0)" } ?? "")")
    }
}

// MARK: - Drawing helpers

private extension NSImage {
    /// Draws this image filling `rect`, cropped to its aspect rather than
    /// squashed. The stills are portrait and the slots are not.
    func drawFilling(_ rect: NSRect, fraction: CGFloat = 1) {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let w = rect.width / scale, h = rect.height / scale
        let source = NSRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        draw(in: rect, from: source, operation: .sourceOver, fraction: fraction,
             respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

/// The still or, with none yet, a dim accent gradient in its place.
private func drawStill(_ image: NSImage?, in rect: NSRect, fraction: CGFloat = 1) {
    if let image {
        image.drawFilling(rect, fraction: fraction)
    } else {
        NSGradient(starting: InspectorStyle.accent.withAlphaComponent(0.35 * fraction),
                   ending: InspectorStyle.drift.withAlphaComponent(0.25 * fraction))?
            .draw(in: rect, angle: -60)
    }
}

/// A borderless button that knows when the pointer is over it.
class HoverButton: NSButton {
    private(set) var isHovering = false { didSet { needsDisplay = true; onHover?(isHovering) } }
    var onHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
}

// MARK: - The arrows

/// ‹ or ›, drawn over the neighbouring shader's still.
final class StepButton: HoverButton {
    static let width: CGFloat = 34
    let direction: Int
    /// The shader this arrow opens. Pointing at the arrow shows it in the
    /// middle part.
    var neighbour: String? { didSet { needsDisplay = true } }
    var still: NSImage? { didSet { needsDisplay = true } }

    init(direction: Int) {
        self.direction = direction
        super.init(frame: .zero)
        setAccessibilityLabel(direction < 0 ? "Previous shader" : "Next shader")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        // Dim at rest, so the open look in the middle leads. Pointing at it
        // brings the neighbour up to nearly full, so you see it before you
        // commit to it.
        let fraction: CGFloat = isHighlighted ? 1 : isHovering ? 0.9 : 0.4
        drawStill(still, in: bounds, fraction: fraction)
        // A scrim from the outer edge, so the chevron always has contrast.
        let scrim = NSGradient(starting: NSColor(white: 0, alpha: isHovering ? 0.35 : 0.55),
                               ending: NSColor(white: 0, alpha: isHovering ? 0.05 : 0.25))
        scrim?.draw(in: bounds, angle: direction < 0 ? 0 : 180)

        let symbol = direction < 0 ? "chevron.left" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
            .applying(.init(paletteColors: [isHovering ? .white : EditorTheme.text]))
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let nudge: CGFloat = isHighlighted ? CGFloat(direction) * 1.5 : 0
        let r = NSRect(x: (bounds.width - glyph.size.width) / 2 + nudge,
                       y: (bounds.height - glyph.size.height) / 2,
                       width: glyph.size.width, height: glyph.size.height)
        glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: nil)
    }
}

// MARK: - The middle

/// The open look: its still, name, preset and place in the list, and the grid
/// glyph for the selector it opens.
final class CurrentLookButton: HoverButton {
    var look = LookSwitcher.Look(name: "Shader", preset: nil, position: "") {
        didSet { if look != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } }
    }
    var still: NSImage? { didSet { needsDisplay = true } }
    /// A neighbour's name while an arrow is pointed at.
    var peek: String? { didSet { needsDisplay = true } }

    private static let thumb = NSSize(width: 22, height: 22)
    /// Leading inset, thumb, gap — and gap, grid glyph, trailing inset.
    private static let chrome: CGFloat = 5 + 22 + 8 + 8 + 16 + 9

    /// Wide enough for the name and the resting second line, so the bar gives
    /// the switcher its words before it gives the slack to the spacer. Sized
    /// without the hover text, so pointing at an arrow never moves anything.
    override var intrinsicContentSize: NSSize {
        let title = (look.name + (look.isEdited ? " •" : "")).size(withAttributes: [.font: Self.titleFont]).width
        let detail = detailText(peek: nil).size().width
        return NSSize(width: ceil(Self.chrome + max(title, detail)) + 4, height: NSView.noIntrinsicMetric)
    }
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    /// The second line: preset · position · custom, or where a pointed-at
    /// arrow goes.
    private func detailText(peek: String?) -> NSAttributedString {
        let truncating = Self.truncating
        if let peek {
            return NSAttributedString(string: "→ " + peek, attributes: [
                .font: Self.detailFont, .foregroundColor: InspectorStyle.accent, .paragraphStyle: truncating])
        }
        let parts = [look.preset, look.position, look.isCustom ? "custom" : nil].compactMap { $0 }
            .filter { !$0.isEmpty }
        let text = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 {
                text.append(NSAttributedString(string: "  ·  ", attributes: [
                    .font: Self.detailFont, .foregroundColor: EditorTheme.dim]))
            }
            // The preset is the second most important word here; the count
            // and "custom" are reference.
            let color = i == 0 && look.preset != nil
                ? InspectorStyle.accent.blended(withFraction: 0.35, of: EditorTheme.text) ?? EditorTheme.text
                : InspectorStyle.heading
            text.append(NSAttributedString(string: part, attributes: [
                .font: Self.detailFont, .foregroundColor: color]))
        }
        text.addAttribute(.paragraphStyle, value: truncating, range: NSRange(location: 0, length: text.length))
        return text
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || isHighlighted {
            NSColor(white: 1, alpha: isHighlighted ? 0.09 : 0.05).setFill()
            bounds.fill()
        }

        // The still, as a small rounded tile.
        let t = Self.thumb
        let thumb = NSRect(x: 5, y: ((bounds.height - t.height) / 2).rounded(), width: t.width, height: t.height)
        NSGraphicsContext.saveGraphicsState()
        let clip = NSBezierPath(roundedRect: thumb, xRadius: 5, yRadius: 5)
        clip.addClip()
        drawStill(still, in: thumb)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let edge = NSBezierPath(roundedRect: thumb.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        edge.lineWidth = 1
        edge.stroke()

        // The grid glyph at the trailing edge: this opens pictures, not a list.
        let glyphConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(.init(paletteColors: [isHovering ? EditorTheme.text : InspectorStyle.heading]))
        var trailing = bounds.maxX - 9
        if let glyph = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(glyphConfig) {
            let r = NSRect(x: trailing - glyph.size.width, y: (bounds.height - glyph.size.height) / 2,
                           width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: nil)
            trailing = r.minX - 8
        }

        // Two lines: name (and an edited dot), then preset · position — or,
        // while an arrow is pointed at, where that arrow goes.
        let textX = thumb.maxX + 8
        let width = max(0, trailing - textX)
        let truncating = Self.truncating
        let title = NSMutableAttributedString(string: look.name, attributes: [
            .font: Self.titleFont, .foregroundColor: EditorTheme.text, .paragraphStyle: truncating])
        if look.isEdited {
            title.append(NSAttributedString(string: " •", attributes: [
                .font: Self.titleFont, .foregroundColor: InspectorStyle.accent]))
        }
        let detail = detailText(peek: peek)
        let titleHeight: CGFloat = 15, detailHeight: CGFloat = 13
        let top = ((bounds.height - titleHeight - detailHeight) / 2).rounded()
        title.draw(with: NSRect(x: textX, y: top, width: width, height: titleHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        detail.draw(with: NSRect(x: textX, y: top + titleHeight, width: width, height: detailHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
