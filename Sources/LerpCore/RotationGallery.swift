import AppKit

/// The shader Library: one card per shader, a picture of it you click to open
/// and whose badge switches it in or out of the screensaver.
///
/// A list of names tells you nothing — there is no way to find out what
/// `voronoi` is except to wait for it to come round. Here each shader is a
/// portrait still of itself, the on/off state is the difference between a lit
/// card with an accent frame and a dimmed one behind a scrim, and pointing at a
/// card starts it *moving* — from the still's own instant, so the picture
/// carries on rather than restarting.
///
/// This lives in `LerpCore` because it has two hosts and they cannot see each
/// other's sources: the playground's toolbar popover (`ShaderPicker`), which
/// writes the screensaver's rotation as you click, and the screensaver's own
/// Options… sheet in `Sources/Saver`, which shows it read-only. It owns no
/// policy of its own — every toggle goes out through `onChange`, every "open
/// this one" through `onOpen`, the one card that is not a shader through
/// `onNew`, and what is on comes back in through `show(shaders:selection:)`.

// MARK: - Shared card behaviour

extension NSView {
    /// The pointer tracking every card in the grid uses — a look's tile and the
    /// "+" card alike, which is why it is here rather than written out in both.
    ///
    /// `.inVisibleRect` keeps the tracking rect in step with the scroll view by
    /// itself, so a card that scrolls out from under a stationary pointer is
    /// exited rather than left thinking it is still hovered.
    func installGridTracking() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self))
    }
}

// MARK: - One look

/// A single look. Drawn rather than assembled out of an image view and two
/// labels: the whole tile is one hit target and one appearance, and drawing it
/// in one place is what makes the off state read as *off* at a glance instead of
/// as a slightly different shade of on.
public final class RotationTile: NSView {

    // A click on the picture opens; the badge in its corner is the rotation
    // toggle. There used to be a second mode with those inverted, for a
    // separate rotation window — one grid with two meanings for a click was
    // half of what made the playground hard to read, and the window is gone.
    // A shader that is out of the rotation is drawn dimmed but opens on exactly
    // the same click: not shuffling it is no reason to be unable to edit it.

    /// The default card size. The Options… sheet and the toolbar popover ask
    /// `size(width:)` for narrower ones; nothing else about the card changes.
    public static let size = size(width: 134)

    /// 2:3, which is what "vertical profile" means here and what the stills are
    /// rendered at. It is also why a live preview can be laid straight over a
    /// still without either being cropped or squashed.
    private static let imageAspect: CGFloat = 1.5
    /// Caption block under the picture: two lines plus the padding around them.
    private static let captionHeight: CGFloat = 41
    private static let accent = NSColor(srgbRed: 0.36, green: 0.69, blue: 1.0, alpha: 1)

    /// The picture's rounded corner, and the dark it sits on until a still
    /// arrives. Not private because `NewLookCard` — the one card in the grid
    /// that is not a look — has to be cut from exactly these, or it reads as a
    /// tile that failed to line up rather than as a different kind of thing.
    static let cornerRadius: CGFloat = 7
    static let pictureBacking = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1)

    /// A tile `width` points across, tall enough for a 2:3 still and the two
    /// caption lines. Derived rather than tabulated, so a narrower gallery
    /// cannot crop its own captions.
    public static func size(width: CGFloat) -> NSSize {
        NSSize(width: width,
               height: (4 + ((width - 8) * imageAspect).rounded() + captionHeight).rounded())
    }

    public let entry: LerpRotationEntry
    public let shaderTitle: String

    /// Put this look in or take it out of the screensaver's rotation.
    public var onToggle: ((LerpRotationEntry) -> Void)?
    /// The badge was clicked. Where set, it replaces `onToggle` for the mouse —
    /// the gallery uses it to offer a shader's presets — and the gallery
    /// enforces the floor itself.
    public var onBadge: ((RotationTile) -> Void)?
    /// Open this look in the editor.
    public var onOpen: ((LerpRotationEntry) -> Void)?
    /// The pointer arrived (`true`) or left (`false`). The gallery answers by
    /// lending this tile the one shared live view — see `RotationPreviewPlayer`.
    public var onHover: ((RotationTile, Bool) -> Void)?

    public var image: NSImage? { didSet { needsDisplay = true } }
    public var isOn = true { didSet { if isOn != oldValue { redraw() } } }
    /// Off while the gallery is inactive — a pinned shader means the rotation
    /// does not apply, so its tiles must not answer a click either.
    public var isLive = true { didSet { redraw() } }
    /// On, and the only look left in the rotation, so it cannot be turned off.
    ///
    /// This is where "the rotation is never empty" is enforced, and it is the
    /// only place. Everything downstream used to defend the same invariant by
    /// quietly reading an empty selection as *all* of them — which meant the one
    /// way to be sure a look never played was the one way that turned it back
    /// on. Stopping the last tick here costs one disabled control and buys the
    /// right to take every one of those widenings out.
    public var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            updateToolTip()
            redraw()
        }
    }
    /// Whether a click on this tile can change the rotation. Locking stops a
    /// look being turned *off*; it never stops it being opened or pointed at,
    /// so hovering and `onOpen` deliberately test `isLive` instead.
    public var isToggleable: Bool { isLive && !isLocked }
    /// "voronoi · Molten". The same words `accessibilityLabel` says, so a
    /// pointer and a screen reader name a tile identically.
    private var lookLabel: String {
        summary.map { $0.isEmpty ? shaderTitle : shaderTitle + " · " + $0 }
            ?? entry.shader + " · " + entry.displayName
    }

    // MARK: Standing for a whole shader

    /// Set on the one card per shader the Library shows. The caption becomes
    /// the shader's name over this line — "4 of 11 presets" — and the badge
    /// means the whole shader.
    public var summary: String? {
        didSet { if summary != oldValue { updateToolTip(); redraw() } }
    }
    /// The summary describes a hand-picked subset, and is drawn amber so a
    /// curated shader reads as curated from across the room.
    public var summaryIsPartial = false { didSet { if summaryIsPartial != oldValue { redraw() } } }
    private static let partialInk = NSColor(srgbRed: 0.91, green: 0.66, blue: 0.37, alpha: 1)
    /// The look the editor currently has open, in the picker. Marked so the
    /// popover answers "where am I?" as well as "what is there?".
    public var isCurrent = false { didSet { if isCurrent != oldValue { redraw() } } }
    private var isHot = false { didSet { if isHot != oldValue { redraw() } } }

    /// True while the shared live view is parented in this tile.
    public private(set) var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            chrome?.isHidden = !isPlaying
            redraw()
        }
    }

    private var preview: NSView?
    private var chrome: Overlay?

    public init(entry: LerpRotationEntry, shaderTitle: String, size: NSSize = RotationTile.size) {
        self.entry = entry
        self.shaderTitle = shaderTitle
        super.init(frame: NSRect(origin: .zero, size: size))
        updateToolTip()
    }

    /// The padlock drawn on the one look that cannot be turned off. Small, in
    /// the corner opposite the tick, so the tile still reads as "in" first and
    /// "and it has to stay in" second.
    private func drawLock(in frame: NSRect) {
        let side: CGFloat = 15
        let box = NSRect(x: frame.minX + 6, y: frame.minY + 6, width: side, height: side)
        NSColor(white: 0, alpha: 0.5).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let body = NSRect(x: box.minX + 3.5, y: box.midY - 0.5, width: side - 7, height: 6)
        Self.accent.setFill()
        NSBezierPath(roundedRect: body, xRadius: 1.4, yRadius: 1.4).fill()
        let shackle = NSBezierPath()
        shackle.appendArc(withCenter: NSPoint(x: box.midX, y: body.minY),
                          radius: 2.6, startAngle: 0, endAngle: 180)
        shackle.lineWidth = 1.5
        Self.accent.setStroke()
        shackle.stroke()
    }

    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    private func redraw() {
        needsDisplay = true
        chrome?.needsDisplay = true
    }

    /// The one place the tooltip is written, so a tile that was locked and
    /// then unlocked cannot be left saying the wrong thing.
    private func updateToolTip() {
        toolTip = lookLabel
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installGridTracking()
    }

    /// `isLive`, not `isToggleable`: the last look in the rotation is locked
    /// against being switched off, but pointing at it must still play it.
    public override func mouseEntered(with event: NSEvent) {
        isHot = isLive
        guard isLive else { return }
        onHover?(self, true)
    }

    public override func mouseExited(with event: NSEvent) {
        isHot = false
        onHover?(self, false)
    }

    /// The badge toggles; anywhere else opens. Opening is not gated on
    /// `isToggleable` — the last shader left in the rotation is locked against
    /// being switched off, not against being edited.
    public override func mouseDown(with event: NSEvent) {
        guard isLive, event.clickCount == 1 else { return }
        if badgeHitRect.contains(convert(event.locationInWindow, from: nil)) {
            if let onBadge { onBadge(self) } else if isToggleable { onToggle?(entry) }
        } else {
            onOpen?(entry)
        }
    }

    // MARK: The live preview

    /// Where the shared live view goes, and where the still is drawn — the same
    /// rectangle, so one replaces the other exactly.
    public var pictureFrame: NSRect { Self.pictureFrame(in: bounds) }

    /// The same rectangle for anything the grid lays out at a tile's size —
    /// which is `NewLookCard` and nothing else. It has no still to draw and
    /// still has to draw it in the same place.
    static func pictureFrame(in bounds: NSRect) -> NSRect {
        let width = bounds.width - 8
        return NSRect(x: 4, y: 4, width: width, height: (width * imageAspect).rounded())
    }

    /// The hover halo is drawn 2.5 points *outside* the picture, so the overlay
    /// has to be bigger than the picture or it would clip the one piece of
    /// chrome that says the pointer is here.
    private static let chromeInset: CGFloat = 4

    /// Takes the shared live view in, under the chrome overlay so the frame, the
    /// badge, the halo and the scrim still read over a moving picture.
    public func attachPreview(_ view: NSView) {
        let overlay = chrome ?? makeChrome()
        overlay.isHidden = false
        view.frame = pictureFrame
        addSubview(view, positioned: .below, relativeTo: overlay)
        preview = view
        isPlaying = true
    }

    public func detachPreview() {
        preview?.removeFromSuperview()
        preview = nil
        isPlaying = false
    }

    private var chromeFrame: NSRect {
        pictureFrame.insetBy(dx: -Self.chromeInset, dy: -Self.chromeInset)
    }

    private func makeChrome() -> Overlay {
        let overlay = Overlay(frame: chromeFrame)
        overlay.tile = self
        addSubview(overlay)
        chrome = overlay
        return overlay
    }

    public override func layout() {
        super.layout()
        preview?.frame = pictureFrame
        chrome?.frame = chromeFrame
    }

    /// Everything that is drawn *over* the picture, as a view rather than as more
    /// lines in `draw`, because while a preview is playing the picture is a
    /// `CAMetalLayer` subview and anything the tile draws itself is underneath
    /// it. Both states call `drawChrome`, so there is one appearance and not two.
    ///
    /// It never takes a click: the tile owns the whole hit target, including the
    /// badge, so the decision about what a click means stays in `mouseDown`.
    private final class Overlay: NSView {
        weak var tile: RotationTile?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            tile?.drawChrome(in: bounds.insetBy(dx: RotationTile.chromeInset,
                                                dy: RotationTile.chromeInset))
        }
    }

    // MARK: Accessibility

    /// A card is a button that happens to be a picture. Pressing it opens; the
    /// badge's toggle is its show-menu action, so both are reachable without a
    /// mouse.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? {
        lookLabel + (isOn ? "" : " (not in the screensaver)")
    }
    public override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    public override func isAccessibilityEnabled() -> Bool { isLive }
    public override func accessibilityPerformPress() -> Bool {
        guard isLive else { return false }
        onOpen?(entry)
        return true
    }
    public override func accessibilityPerformShowMenu() -> Bool {
        guard isToggleable else { return false }
        onToggle?(entry)
        return true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let frame = pictureFrame
        let path = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)

        // The picture. Stills are rendered at exactly the tile's 2:3, so this
        // neither crops nor squashes them.
        Self.pictureBacking.setFill()
        path.fill()
        if let image {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let waiting = NSAttributedString(string: "rendering…", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: EditorTheme.dim,
            ])
            waiting.draw(at: NSPoint(x: frame.midX - waiting.size().width / 2,
                                     y: frame.midY - waiting.size().height / 2))
        }

        // While a preview is playing the overlay draws these instead, on top of
        // the live layer.
        if !isPlaying { drawChrome(in: frame) }
        drawCaption(below: frame)
    }

    /// The scrim, the frame, the hover halo, the current-look mark and the badge
    /// — everything that belongs over the picture, wherever the picture came from.
    private func drawChrome(in frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame, xRadius: Self.cornerRadius,
                                yRadius: Self.cornerRadius)

        // Off looks off: a scrim over the picture, not a tint of it. Lifted while
        // a preview is playing — you pointed at it to see it, and the grey frame
        // and the hollow badge still say it is out of the rotation.
        if !isOn {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075,
                    alpha: isPlaying ? 0.30 : 0.74).setFill()
            frame.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // …and the frame says which it is from across the room.
        if isOn {
            Self.accent.setStroke()
            path.lineWidth = 3
        } else {
            NSColor(srgbRed: 0.24, green: 0.27, blue: 0.33, alpha: 1).setStroke()
            path.lineWidth = 1
        }
        path.stroke()
        if isHot { Self.drawHalo(around: frame) }

        // The look the editor has open, in the corner the badge does not use. A
        // dark disc under an accent core, so it reads over a pale still as well
        // as over a dark one — half these looks are nearly white.
        if isCurrent {
            let dot = NSRect(x: frame.minX + 6, y: frame.minY + 6, width: 14, height: 14)
            NSColor(srgbRed: 0.04, green: 0.07, blue: 0.11, alpha: 0.88).setFill()
            NSBezierPath(ovalIn: dot).fill()
            Self.accent.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: 3.5, dy: 3.5)).fill()
        }

        drawBadge()
        if isLocked { drawLock(in: frame) }
        // `drawCaption` is deliberately not called here: it sits below the
        // picture rather than over it, so `draw` calls it for both states.
    }

    /// Where the badge is. It is the rotation toggle, so it is also a hit target
    /// and gets a little slack around it — 20 points is a small thing to ask
    /// someone to hit.
    public var badgeRect: NSRect {
        let frame = pictureFrame, side: CGFloat = 20
        return NSRect(x: frame.maxX - side - 6, y: frame.minY + 6, width: side, height: side)
    }

    private var badgeHitRect: NSRect { badgeRect.insetBy(dx: -6, dy: -6) }

    /// Filled tick when in, empty ring when out. The redundant signal, for
    /// anyone who cannot rely on the frame colour — and the control itself.
    private func drawBadge() {
        let box = badgeRect
        let circle = NSBezierPath(ovalIn: box)
        if isOn {
            Self.accent.setFill()
            circle.fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: box.minX + 5.5, y: box.midY + 0.5))
            tick.line(to: NSPoint(x: box.midX - 0.5, y: box.maxY - 6))
            tick.line(to: NSPoint(x: box.maxX - 4.5, y: box.minY + 6))
            tick.lineWidth = 2.2
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            NSColor(srgbRed: 0.05, green: 0.09, blue: 0.14, alpha: 1).setStroke()
            tick.stroke()
        } else {
            NSColor(white: 0, alpha: 0.45).setFill()
            circle.fill()
            NSColor(srgbRed: 0.44, green: 0.48, blue: 0.55, alpha: 1).setStroke()
            circle.lineWidth = 1.4
            circle.stroke()
        }
    }

    private func drawCaption(below frame: NSRect) {
        var strong: NSColor = isOn ? EditorTheme.text : NSColor(srgbRed: 0.44, green: 0.47, blue: 0.53, alpha: 1)
        var weak: NSColor = isOn ? EditorTheme.dim : NSColor(srgbRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)
        if isCurrent { strong = Self.accent }
        if isOn, summaryIsPartial { weak = Self.partialInk }
        // A shader's card is captioned with the shader, over what of it is in.
        let (title, subtitle) = summary.map { (shaderTitle, $0) } ?? (entry.displayName, shaderTitle)
        Self.drawCaption(title, over: subtitle, below: frame,
                         width: bounds.width, strong: strong, weak: weak,
                         emphasised: isCurrent)
    }

    /// The caption block, for anything the grid lays out at a tile's size. The
    /// `NewLookCard` has one line where a look has two and would otherwise be
    /// carrying its own copy of these baselines — captions a point out of step
    /// across a row are the sort of thing nobody can name and everybody sees.
    /// An empty `subtitle` simply leaves the second line blank.
    static func drawCaption(_ title: String, over subtitle: String, below picture: NSRect,
                            width: CGFloat, strong: NSColor, weak: NSColor,
                            emphasised: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center

        let box = NSRect(x: 4, y: picture.maxY + 6, width: width - 8, height: 15)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: emphasised ? .semibold : .medium),
            .foregroundColor: strong, .paragraphStyle: style,
        ]).draw(in: box)
        NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: weak, .paragraphStyle: style,
        ]).draw(in: box.offsetBy(dx: 0, dy: 15))
    }

    /// The pointer-is-here halo, outside the picture rather than on it. Static
    /// alongside the rest of the shared card drawing: the "+" card lights up
    /// under the pointer the way its neighbours do, and one halo drawn twice is
    /// one halo that drifts.
    static func drawHalo(around frame: NSRect) {
        NSColor(white: 1, alpha: 0.16).setStroke()
        let halo = NSBezierPath(roundedRect: frame.insetBy(dx: -2.5, dy: -2.5),
                                xRadius: cornerRadius + 2, yRadius: cornerRadius + 2)
        halo.lineWidth = 2
        halo.stroke()
    }

}

// MARK: - The one card that is not a look

/// The "+" card at the head of the grid: make a shader that does not exist yet.
///
/// This is where New… went, and the grid is where it belongs. Wanting a new
/// shader is what happens at the end of looking through the ones there are and
/// not finding it, so the affordance wants to be under the pointer at that
/// moment — in the grid you are already reading — rather than on a toolbar you
/// stopped looking at when you opened the picker.
///
/// It borrows `RotationTile`'s metrics and nothing else. Sharing the geometry is
/// what makes it sit *in* the grid rather than beside it; sharing the tile would
/// have meant giving it an entry, an on/off state, a badge and a place in every
/// count — and it is not a look. It is never in the rotation, never one of the
/// "N of M looks", never what the arrows step onto, never the last look the
/// rotation cannot let go of. Keeping all of that impossible is worth a second
/// small view.
public final class NewLookCard: NSView {

    /// The card was clicked. What that means is entirely the host's: this view
    /// knows there is such a thing as making a shader and nothing whatever
    /// about how.
    public var onPress: (() -> Void)?

    private var isHot = false { didSet { if isHot != oldValue { needsDisplay = true } } }

    public init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        toolTip = "New shader"
    }

    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installGridTracking()
    }

    public override func mouseEntered(with event: NSEvent) { isHot = true }
    public override func mouseExited(with event: NSEvent) { isHot = false }

    /// First click only. The host answers this by putting up a modal prompt for
    /// the name, which swallows the second click of a double — but if it ever
    /// arrived first it would ask for two shaders, and the second question would
    /// be unexplainable.
    public override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onPress?()
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { "New shader" }
    public override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let frame = RotationTile.pictureFrame(in: bounds)
        let path = NSBezierPath(roundedRect: frame, xRadius: RotationTile.cornerRadius,
                                yRadius: RotationTile.cornerRadius)
        RotationTile.pictureBacking.setFill()
        path.fill()

        // A dashed edge where every neighbour has a solid one. The tiles use
        // their frame to say in or out of the rotation, so this card cannot use
        // a solid frame of either weight without joining that conversation — and
        // an outline that is not quite drawn is the plainest way to say there is
        // no picture here because there is no shader yet.
        let ink = isHot ? EditorTheme.text : EditorTheme.dim
        path.setLineDash([5, 4], count: 2, phase: 0)
        path.lineWidth = 1.5
        ink.setStroke()
        path.stroke()

        // The plus, at the size a still's subject would be: two bars, so it is a
        // mark on the card rather than a glyph in a font that would sit on the
        // caption's baseline grid and read as a third line of text.
        let arm: CGFloat = min(frame.width, frame.height) * 0.22
        let thickness: CGFloat = 3
        ink.setFill()
        NSBezierPath(roundedRect: NSRect(x: frame.midX - arm, y: frame.midY - thickness / 2,
                                         width: arm * 2, height: thickness),
                     xRadius: thickness / 2, yRadius: thickness / 2).fill()
        NSBezierPath(roundedRect: NSRect(x: frame.midX - thickness / 2, y: frame.midY - arm,
                                         width: thickness, height: arm * 2),
                     xRadius: thickness / 2, yRadius: thickness / 2).fill()

        if isHot { RotationTile.drawHalo(around: frame) }

        // One line, where a look has a name over its shader's. There is no
        // second thing to say and inventing one would only make the card look
        // like a look.
        RotationTile.drawCaption("New Shader…", over: "", below: frame,
                                 width: bounds.width,
                                 strong: isHot ? EditorTheme.text : EditorTheme.dim,
                                 weak: EditorTheme.dim, emphasised: false)
    }
}

// MARK: - The gallery

/// Search bar, a scrolling Library of shader cards on named shelves, and a
/// status line.
///
/// # Shelves
///
/// The cards sit under a heading per `// lerp-category:` — Scenes, Splats,
/// Fractals and so on (`LerpShaderCategory`) — because a hundred cards in one
/// grid is a wall to scroll past, not a choice. A search keeps the shelves and
/// hides the ones it emptied. The "+" card sits on the last shelf, Other, which
/// is where a shader made with it lands.
///
/// # One card per shader, and nothing else
///
/// This is the selector: you pick a *shader* here, and switch whole shaders in
/// or out of the screensaver. One shader's presets are picked and curated in the
/// inspector's Presets list, beside the parameters they are made of.
///
/// It used to do both. A "Looks" pill on every card opened a drawer of that
/// shader's presets as tiles, and typing swapped the cards for matching
/// presets, so the same presets sat behind three controls — the drawer, the
/// toolbar arrows and the inspector's popup — each with its own idea of what a
/// click meant. One noun per surface is the fix: shaders here, presets there.
///
/// A card's frame says whether the shader plays; its caption says how much of
/// it ("all 5 presets", or "4 of 11 presets" in amber when hand-picked). A click
/// opens the shader, and the badge switches it — keeping the hand-picking,
/// because a switch is a `shader/*` key beside the per-preset ones (see
/// `LerpRotationSelection`).
///
/// Typing filters the cards by shader name *and* by preset name. A card that is
/// showing only because one of its presets matched says which, and opens
/// wearing it: a search for "Molten" is a search for that preset.
public final class RotationGalleryView: NSView, NSSearchFieldDelegate {

    /// The user changed the rotation. The selection is the new one, in full.
    public var onChange: ((LerpRotationSelection) -> Void)?
    /// The user asked to edit a shader, wearing the given preset: a click on a
    /// card, or ⏎ on the filter field. nil in a host that has no editor to open
    /// one in — the screensaver's Options… sheet — where a click does nothing.
    public var onOpen: ((LerpRotationEntry) -> Void)?
    /// The user asked for a shader that does not exist yet, from the "+" card at
    /// the head of the grid.
    ///
    /// Setting this is what puts the card there, the way `onOpen` is what makes
    /// cards openable: a host that cannot scaffold and open a `.metal` file must
    /// not offer a card that says it can. The screensaver's Options… sheet has
    /// no editor at all.
    public var onNew: (() -> Void)? {
        didSet {
            guard onNew != nil, newCard == nil else { return }
            let card = NewLookCard(size: tileSize)
            // Through `self` rather than capturing the closure, so a host that
            // sets `onNew` twice does not leave the card calling the first one.
            card.onPress = { [weak self] in self?.onNew?() }
            card.identifier = NSUserInterfaceItemIdentifier("new-look-card")
            canvas.addSubview(card)
            newCard = card
            addHeading(LerpShaderCategory.other)
            canvas.needsLayout = true
        }
    }

    public private(set) var shaders: [LerpShader] = []
    public private(set) var selection = LerpRotationSelection(discovered: [])
    public var entries: [LerpRotationEntry] { selection.discovered }
    /// The (shader, preset) the host's editor has open. Its shader's card is
    /// marked.
    public private(set) var currentEntry: LerpRotationEntry?

    /// The one live view the grid lends to the card under the pointer.
    public let preview = RotationPreviewPlayer()
    /// Off for a host that would rather not spend a GPU on hover.
    public var previewsOnHover = true

    private let search = NSSearchField()
    private let countLabel = Chrome.label("", size: 11, color: EditorTheme.text)
    private let note = Chrome.label("", size: 11)
    private let progress = NSProgressIndicator()
    private let scroll = NSScrollView()
    private let canvas = Canvas()
    private let tileSize: NSSize
    /// "Screensaver:", All and None. Hidden together where the gallery is
    /// read-only.
    private var bulk: [NSView] = []
    /// Held by reference rather than found by title: this one is switched off
    /// whenever pressing it would clear the rotation, and a lookup that missed
    /// would leave the floor unenforced with no sign of it.
    private var deselectAllButton: NSButton?
    private var selectAllButton: NSButton?

    /// One card per shader.
    private var cards: [String: RotationTile] = [:]
    /// Present only where the host offered `onNew`. Deliberately not in `cards`
    /// — everything that iterates those is about shaders.
    private var newCard: NewLookCard?
    /// Laid out shelf by shelf (`inShelfOrder`), so the grid, ⏎ and the
    /// playground's ‹ › all agree on what comes next.
    private var order: [String] = []
    /// Each shader's shelf, read once per `show`.
    private var shelf: [String: String] = [:]
    /// One heading per shelf that has a card on it.
    private var headings: [String: NSTextField] = [:]
    private var filter = ""
    private var isSearching: Bool { !filter.isEmpty }

    /// Off when the rotation does not apply — the saver's Options… sheet greys
    /// the whole gallery out while a single shader is pinned.
    public private(set) var isActive = true
    private var inactiveNote: String?

    /// Whether clicking changes the rotation.
    ///
    /// False in the saver's Options… sheet, which shows the rotation but does
    /// not own it: the playground is the rotation's only writer, because the
    /// sheet runs sandboxed and can only reach Apple's container rather than the
    /// ByHost file the saver reads. A gallery that accepted clicks it could not
    /// persist where the saver would look for them is worse than one that does
    /// not accept them.
    ///
    /// Distinct from `isActive`, which greys the gallery out entirely: a
    /// read-only gallery is still legible, still scrolls, still previews on
    /// hover and still shows which shaders are in.
    public var isEditable = true {
        didSet {
            bulk.forEach { $0.isHidden = !isEditable }
            guard !isEditable else { return }
            cards.values.forEach { $0.toolTip = Self.readOnlyNote }
        }
    }

    /// Said once, where a click would otherwise have gone.
    public static let readOnlyNote = "Edit the rotation in LerpPlayground."

    /// The one predicate every mutator asks. `isActive` is "the rotation does
    /// not apply right now"; `isEditable` is "this gallery never writes". Both
    /// have to be true before the selection moves.
    private var canEdit: Bool { isActive && isEditable }

    /// The scroll view's document. Always exactly as wide as what is visible:
    /// it takes its width from the clip view on every pass rather than trusting
    /// autoresizing, which starts from a zero frame and can leave the canvas
    /// wider than the window — a grid that scrolls sideways and clips its last
    /// column.
    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        var onLayout: ((CGFloat) -> CGFloat)?
        override func layout() {
            super.layout()
            let width = superview?.bounds.width ?? bounds.width
            guard let height = onLayout?(width) else { return }
            if abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 {
                setFrameSize(NSSize(width: width, height: height))
            }
        }
    }

    public convenience override init(frame frameRect: NSRect) {
        self.init(frame: frameRect, tileSize: RotationTile.size)
    }

    /// - Parameter tileSize: how big one card is drawn. The Options… sheet has
    ///   less room than the playground's popover and asks for a smaller one.
    public init(frame frameRect: NSRect, tileSize: NSSize) {
        self.tileSize = tileSize
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = EditorTheme.background.cgColor
        identifier = NSUserInterfaceItemIdentifier("rotation-gallery")
        build()
    }

    public required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Construction

    private func build() {
        search.placeholderString = "Search"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("rotation-search")
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 130).isActive = true

        countLabel.identifier = NSUserInterfaceItemIdentifier("rotation-count")

        // Over the shaders on screen, so with a filter up they are "all the dark
        // ones" rather than a button that quietly ignores the search.
        let label = Chrome.label("Screensaver:", size: 11)
        let all = Chrome.button("All", target: self, action: #selector(selectAllShaders))
        let none = Chrome.button("None", target: self, action: #selector(deselectAllShaders))
        all.identifier = NSUserInterfaceItemIdentifier("rotation-all")
        none.identifier = NSUserInterfaceItemIdentifier("rotation-none")
        selectAllButton = all
        deselectAllButton = none
        bulk = [label, all, none]

        let bar = Chrome.bar([search, Chrome.flexible(), progress, countLabel] + bulk)

        canvas.onLayout = { [weak self] width in self?.reflow(width: width) ?? 0 }
        canvas.autoresizingMask = [.width]
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        // Scrolling moves cards under a stationary pointer. `.inVisibleRect`
        // tracking keeps the enter/exit bookkeeping honest, but a preview that
        // carries on animating while the grid slides past it is still wrong, so
        // the scroll ends it outright.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        note.identifier = NSUserInterfaceItemIdentifier("rotation-note")
        let footer = Chrome.bar([note, Chrome.flexible()], height: 24)

        let stack = Chrome.pane([bar, scroll, footer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: Model in

    /// Rebuilds the grid for `shaders`. Cards for shaders that are still there,
    /// with the same cover, keep their images, so a shader being edited redraws
    /// one card rather than blanking the whole gallery.
    ///
    /// The selection is re-made against these shaders' presets, so a host that
    /// read it against a slightly older list cannot leave a key in it that
    /// nothing on screen can show.
    public func show(shaders: [LerpShader], selection: LerpRotationSelection) {
        // A card that is about to be taken away must not still be holding the
        // shared live view.
        preview.stop()
        self.shaders = shaders
        self.selection = LerpRotationSelection(discovered: shaders.rotationEntries(),
                                               disabled: selection.disabled)
        let names = Set(shaders.map(\.name))
        for (name, card) in cards where !names.contains(name) || cover(of: name) != card.entry {
            card.removeFromSuperview()
            cards[name] = nil
        }

        let shelved = shaders.inShelfOrder()
        order = shelved.map(\.name)
        shelf = Dictionary(uniqueKeysWithValues: shelved.map { ($0.name, $0.category) })
        var shelves = Set(shelf.values)
        if onNew != nil { shelves.insert(LerpShaderCategory.other) }
        for (name, heading) in headings where !shelves.contains(name) {
            heading.removeFromSuperview()
            headings[name] = nil
        }
        shelves.forEach(addHeading)
        for shader in shaders where cards[shader.name] == nil {
            let name = shader.name
            guard let cover = cover(of: name) else { continue }
            let card = RotationTile(entry: cover, shaderTitle: shader.cardTitle, size: tileSize)
            card.summary = ""
            card.onToggle = { [weak self] _ in self?.toggleShader(name) }
            card.onBadge = { [weak self] tile in self?.badgeClicked(name, tile) }
            card.onOpen = { [weak self] _ in self?.openCard(name) }
            card.onHover = { [weak self] tile, inside in self?.hovered(tile, inside) }
            card.identifier = NSUserInterfaceItemIdentifier("card:" + name)
            card.isLive = isActive
            if !isEditable { card.toolTip = Self.readOnlyNote }
            canvas.addSubview(card)
            cards[name] = card
        }
        refresh()
        canvas.needsLayout = true
    }

    private func addHeading(_ name: String) {
        guard headings[name] == nil else { return }
        let heading = Chrome.label(name, size: 13, color: EditorTheme.text)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.identifier = NSUserInterfaceItemIdentifier("shelf:" + name)
        canvas.addSubview(heading)
        headings[name] = heading
    }

    /// The preset a shader's card shows and opens: its first, in display order.
    public func cover(of shader: String) -> LerpRotationEntry? {
        entries.first { $0.shader == shader }
    }

    /// A still arrived. Only covers are drawn; any other preset's still is
    /// simply not shown.
    public func show(image: NSImage, for entry: LerpRotationEntry) {
        if let card = cards[entry.shader], card.entry == entry { card.image = image }
    }

    /// Drops every still, so the next run redraws them all.
    public func clearImages() {
        cards.values.forEach { $0.image = nil }
    }

    /// Marks the shader the host's editor has open.
    public func showCurrent(_ entry: LerpRotationEntry?) {
        currentEntry = entry
        for (name, card) in cards { card.isCurrent = name == entry?.shader }
    }

    public func showProgress(done: Int, total: Int) {
        progress.isHidden = done >= total
        progress.maxValue = Double(max(total, 1))
        progress.doubleValue = Double(done)
        // Only while there is something to say: a count of the library at
        // rest is just more text in the bar.
        countLabel.stringValue = done >= total ? "" : "Rendering \(done) of \(total)…"
    }

    /// Starts one thumbnail run and wires its images and progress into this
    /// gallery. Only the covers are rendered, because only covers are drawn.
    public func populate(
        using thumbnails: RotationThumbnails,
        jobs: [RotationThumbnails.Job],
        onImage: ((LerpRotationEntry, NSImage) -> Void)? = nil,
        onFinished: @escaping () -> Void = {}
    ) {
        let covers = Set(order.compactMap(cover(of:)))
        let jobs = jobs.filter { covers.contains($0.entry) }
        showProgress(done: 0, total: jobs.count)
        thumbnails.start(
            jobs,
            onImage: { [weak self] entry, image in
                guard let self else { return }
                self.show(image: image, for: entry)
                onImage?(entry, image)
            },
            onProgress: { [weak self] done, total in
                self?.showProgress(done: done, total: total)
            },
            onFinished: onFinished)
    }

    /// Greys the whole gallery out — what the Options… sheet does when a shader
    /// is pinned and the rotation therefore does not apply. `inactive` replaces
    /// the status line while it is off.
    public func setActive(_ active: Bool, note inactive: String? = nil) {
        isActive = active
        inactiveNote = inactive
        if !active { preview.stop() }
        search.isEnabled = active
        cards.values.forEach { $0.isLive = active }
        alphaValue = active ? 1 : 0.55
        refresh()
    }

    /// Puts the caret in the filter field. The popover calls it as it opens, so
    /// typing is the first thing that works — which is the one thing the text
    /// dropdown it replaced did better than a grid of pictures.
    public func focusSearch() {
        window?.makeFirstResponder(search)
    }

    // MARK: Hover

    /// The pointer arrived on, or left, a card.
    private func hovered(_ tile: RotationTile, _ inside: Bool) {
        guard previewsOnHover else { return }
        guard inside else { return preview.leave(tile) }
        guard isActive, let shader = shaders.named(tile.entry.shader) else { return }
        preview.want(tile, shader: shader)
    }

    @objc private func scrolled() { preview.stop() }

    @objc private func windowResignedKey() { preview.stop() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification,
                                                  object: nil)
        guard let window else { return preview.stop() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: window)
    }

    // MARK: Model out

    /// Said out loud when a click is refused. Cleared by the next one that is
    /// not, so it reads as a response rather than as a state.
    private var refusal: String?
    public static let floorNote = "At least one must stay in the screensaver."

    private func refuse(_ why: String) {
        refusal = why
        refresh()
        NSSound.beep()
    }

    /// The one way the selection changes: apply, refuse if the rotation would
    /// be left empty, publish.
    ///
    /// The floor is enforced here and only here, for this view. Everything that
    /// reads the selection takes it literally — there is no code left that turns
    /// an empty rotation into a full one, because that is the behaviour that
    /// made a deselected look play — so an empty rotation has to be
    /// unreachable, and this is where it becomes unreachable.
    private func change(refusing why: String = floorNote,
                        _ edit: (inout LerpRotationSelection) -> Void) {
        guard canEdit else { return refuse(Self.readOnlyNote) }
        let next = selection.applying(edit)
        guard !next.playable.isEmpty else { return refuse(why) }
        selection = next
        commit()
    }

    private func toggleShader(_ name: String) {
        let on = !selection.shaderPlays(name)
        change { $0.setShader(name, on: on) }
    }

    /// The badge. A shader with one preset just switches; one with several
    /// offers a menu — the whole shader on top, then each preset — because
    /// this badge is the one place anything is put in or out of the
    /// screensaver. Items that would leave it with nothing to play are off.
    private func badgeClicked(_ name: String, _ tile: RotationTile) {
        guard canEdit else { return refuse(Self.readOnlyNote) }
        let looks = selection.looks(of: name)
        guard looks.count > 1 else {
            return tile.isToggleable ? toggleShader(name) : refuse(Self.floorNote)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let plays = selection.shaderPlays(name)
        let whole = NSMenuItem(title: "In Screensaver", action: #selector(menuToggledShader(_:)),
                               keyEquivalent: "")
        whole.target = self
        whole.representedObject = name
        whole.state = plays ? .on : .off
        whole.isEnabled = !(plays && wouldEmpty { $0.setShader(name, on: false) })
        menu.addItem(whole)
        menu.addItem(.separator())
        for look in looks {
            let item = NSMenuItem(title: look.displayName, action: #selector(menuToggledLook(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = look
            let on = selection.plays(look)
            item.state = on ? .on : .off
            item.isEnabled = !(on && wouldEmpty { $0.setLook(look, on: false) })
            menu.addItem(item)
        }
        let badge = tile.badgeRect
        menu.popUp(positioning: nil, at: NSPoint(x: badge.minX, y: badge.maxY + 4), in: tile)
    }

    @objc private func menuToggledShader(_ item: NSMenuItem) {
        guard let name = item.representedObject as? String else { return }
        toggleShader(name)
    }

    @objc private func menuToggledLook(_ item: NSMenuItem) {
        guard let look = item.representedObject as? LerpRotationEntry else { return }
        let on = !selection.plays(look)
        change { $0.setLook(look, on: on) }
    }

    /// Opens a card: its matched preset while a search found it by one, its
    /// cover otherwise.
    private func openCard(_ name: String) {
        guard let target = target(of: name) else { return }
        onOpen?(target)
    }

    @objc private func selectAllShaders() {
        let shown = visibleShaders()
        change { selection in shown.forEach { selection.setShader($0, on: true) } }
    }

    /// Disabled outright when it would empty the rotation — which, with no
    /// filter up, it always would. Refusing here rather than "succeeding" and
    /// having the saved set silently mean *all of them* is the whole of this
    /// control: a control that cannot do the wrong thing beats a control that
    /// does the opposite of what it says.
    @objc private func deselectAllShaders() {
        let shown = visibleShaders()
        change { selection in
            shown.forEach { selection.setShader($0, on: false) }
        }
    }

    @objc private func searchChanged() {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        preview.stop()          // the card it was on may be about to be hidden
        refresh()
        canvas.needsLayout = true
    }

    /// Typeahead. The dropdown this grid replaced had one thing over it — you
    /// could type the first few letters of a shader and hit return — so the
    /// filter field keeps it: ⏎ opens the first card still showing.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy selector: Selector) -> Bool {
        guard control === search, selector == #selector(NSResponder.insertNewline(_:)),
              onOpen != nil, let first = visibleShaders().first else { return false }
        openCard(first)
        return true
    }

    private func commit() {
        refusal = nil
        refresh()
        onChange?(selection)
    }

    // MARK: Presentation

    private func contains(_ text: String) -> Bool {
        text.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func nameMatches(_ name: String) -> Bool {
        contains(name) || shaders.named(name).map { contains($0.displayName) } == true
    }

    /// While searching, the preset that put a card on screen when its shader's
    /// own name did not.
    public func matchedPreset(of name: String) -> LerpRotationEntry? {
        guard isSearching, !nameMatches(name) else { return nil }
        return selection.looks(of: name).first { $0.preset != nil && contains($0.displayName) }
    }

    private func isShown(_ name: String) -> Bool {
        !isSearching || nameMatches(name) || matchedPreset(of: name) != nil
    }

    /// What a click on a card opens.
    private func target(of name: String) -> LerpRotationEntry? {
        matchedPreset(of: name) ?? cover(of: name)
    }

    /// The shaders on screen, in grid order.
    public func visibleShaders() -> [String] { order.filter(isShown) }

    /// "4 of 11 presets" while only some play, and nothing otherwise: the
    /// badge already says on or off.
    private func summary(of name: String) -> (text: String, partial: Bool) {
        let looks = selection.looks(of: name)
        let playing = looks.filter(selection.plays).count
        guard playing > 0, playing < looks.count else { return ("", false) }
        return ("\(playing) of \(looks.count) presets", true)
    }

    /// Whether `edit` would leave nothing to play — what locks a control.
    private func wouldEmpty(_ edit: (inout LerpRotationSelection) -> Void) -> Bool {
        selection.applying(edit).playable.isEmpty
    }

    /// Pushes the model into every card, and writes the status line.
    ///
    /// Visibility is settled here rather than in `reflow`, because "the filter
    /// hid it" is a fact about the model and has to be true the moment the
    /// filter changes — not on the next layout pass.
    private func refresh() {
        let playable = selection.playable
        for (name, card) in cards {
            let plays = selection.shaderPlays(name)
            if let hit = matchedPreset(of: name) {
                card.summary = "▸ " + hit.displayName
                card.summaryIsPartial = false
            } else {
                let summary = summary(of: name)
                card.summary = summary.text
                card.summaryIsPartial = summary.partial
            }
            card.isOn = plays
            card.isCurrent = name == currentEntry?.shader
            card.isLocked = plays && wouldEmpty { $0.setShader(name, on: false) }
            card.isHidden = !isShown(name)
        }
        // The "+" card sits out the filter: it is not a shader, so there is
        // nothing about it to match, and a card that disappeared as you typed
        // would be gone at exactly the moment a search came up empty and making
        // one was the answer. It does go when the whole gallery goes — a greyed
        // out grid with one live control left in it reads as broken.
        newCard?.isHidden = !isActive
        let occupied = Set(visibleShaders().compactMap { shelf[$0] })
        for (name, heading) in headings {
            heading.isHidden = !(occupied.contains(name)
                || (name == LerpShaderCategory.other && newCard?.isHidden == false))
        }
        // None goes with them: a button that would clear the rotation is off,
        // not silently ignored.
        let shown = visibleShaders()
        selectAllButton?.isEnabled = isActive
        deselectAllButton?.isEnabled = isActive
            && !wouldEmpty { selection in shown.forEach { selection.setShader($0, on: false) } }
        // Inactive: the status line's job is to say why nothing here applies,
        // not to report a count that has no effect.
        if !isActive, let inactiveNote {
            note.stringValue = inactiveNote
            return
        }
        let shaderCount = Set(playable.map(\.shader)).count
        if entries.isEmpty {
            note.stringValue = "No shaders found."
        } else if playable.isEmpty {
            // Only reachable by hand-editing the defaults: every control here
            // refuses to get there.
            note.stringValue = "Nothing is in the screensaver."
        } else {
            note.stringValue = "\(shaderCount) of \(shaders.count) shaders in the screensaver"
        }
        if let refusal { note.stringValue += " · " + refusal }
    }

    // MARK: Layout

    private static let pad: CGFloat = 16
    private static let gap: CGFloat = 10

    private static let headingHeight: CGFloat = 20
    /// Above a heading that follows a shelf, so the heading reads as the start
    /// of the next shelf rather than a caption under the last one.
    private static let shelfGap: CGFloat = 22

    /// Lays the grid out for a given width and returns the height it needs:
    /// each shelf still showing as a heading over rows of its cards, the "+"
    /// card last on Other.
    @discardableResult
    private func reflow(width: CGFloat) -> CGFloat {
        let tile = tileSize
        let usable = max(tile.width, width - 2 * Self.pad)
        let perRow = max(1, Int((usable + Self.gap) / (tile.width + Self.gap)))
        var groups: [(name: String, items: [NSView])] = []
        for name in order {
            guard let card = cards[name], !card.isHidden else { continue }
            let home = shelf[name] ?? LerpShaderCategory.other
            if groups.last?.name == home { groups[groups.count - 1].items.append(card) }
            else { groups.append((home, [card])) }
        }
        if let newCard, !newCard.isHidden {
            if groups.last?.name == LerpShaderCategory.other { groups[groups.count - 1].items.append(newCard) }
            else { groups.append((LerpShaderCategory.other, [newCard])) }
        }

        var y = Self.pad
        for (index, group) in groups.enumerated() {
            if index > 0 { y += Self.shelfGap }
            if let heading = headings[group.name] {
                heading.frame = NSRect(x: Self.pad, y: y, width: usable, height: Self.headingHeight)
            }
            y += Self.headingHeight + 6
            for (i, view) in group.items.enumerated() {
                view.setFrameSize(tile)
                view.setFrameOrigin(NSPoint(
                    x: Self.pad + CGFloat(i % perRow) * (tile.width + Self.gap),
                    y: y + CGFloat(i / perRow) * (tile.height + Self.gap)))
            }
            let rows = (group.items.count + perRow - 1) / perRow
            y += CGFloat(rows) * (tile.height + Self.gap) - Self.gap
        }
        let height = y + Self.pad
        return max(height, scroll.contentView.bounds.height)
    }

    public override func layout() {
        super.layout()
        canvas.needsLayout = true
    }

    /// Clears the popover's transient search when it closes.
    public func setFilter(_ text: String) {
        search.stringValue = text
        searchChanged()
    }
}
