import AppKit

/// The rotation gallery: every look the screensaver can shuffle through, as a
/// picture you click to put it in or take it out — and, since it is the only
/// place in the project where all 114 looks are visible at once, also the way to
/// *find* a look and go and edit it.
///
/// A list of 114 checkboxes tells you their names and nothing else — there is no
/// way to find out what `voronoi/Molten` is except to wait for it to come round.
/// Here each look is a portrait still of itself, grouped under its shader, the
/// on/off state is the difference between a lit tile with an accent frame and a
/// dimmed one behind a scrim, and pointing at a tile starts it *moving* — from
/// the still's own instant, so the picture carries on rather than restarting.
///
/// This lives in `LerpCore` because it has three hosts and they cannot see each
/// other's sources: the playground's `RotationWindowController`, which writes
/// the screensaver's defaults as you click; the playground's toolbar popover
/// (`ShaderPicker`), which replaced a plain text dropdown with the same tiles;
/// and the screensaver's own Options… sheet in `Sources/Saver`, which collects
/// the same set and writes it on OK. It owns no policy of its own — every toggle
/// goes out through `onChange`, every "open this one" through `onOpen`, and what
/// is on comes back in through `show(shaders:enabled:)`.

// MARK: - One look

/// A single look. Drawn rather than assembled out of an image view and two
/// labels: the whole tile is one hit target and one appearance, and drawing it
/// in one place is what makes the off state read as *off* at a glance instead of
/// as a slightly different shade of on.
public final class RotationTile: NSView {

    /// What a click on the picture means. The two hosts invert each other, on
    /// purpose, because they are asking different questions.
    ///
    /// - `.rotation` — the gallery window and the Options… sheet. A single click
    ///   *toggles* the look in or out of the rotation: that is the whole job of
    ///   those two surfaces and it is worth one click. A double-click opens the
    ///   look in the editor.
    /// - `.picker` — the playground's toolbar popover. There a click *opens*,
    ///   because choosing what to edit is the job, and the badge in the picture's
    ///   corner is the rotation toggle. A look that is out of the rotation is
    ///   drawn dimmed but is opened by exactly the same click: not shuffling a
    ///   look is no reason to be unable to edit it.
    public enum Mode { case rotation, picker }

    /// The tile the playground's gallery window uses. The Options… sheet asks
    /// `size(width:)` for a narrower one, and so does the toolbar popover;
    /// nothing else about the tile changes.
    public static let size = size(width: 134)

    /// 2:3, which is what "vertical profile" means here and what the stills are
    /// rendered at. It is also why a live preview can be laid straight over a
    /// still without either being cropped or squashed.
    private static let imageAspect: CGFloat = 1.5
    /// Caption block under the picture: two lines plus the padding around them.
    private static let captionHeight: CGFloat = 41
    private static let accent = NSColor(srgbRed: 0.36, green: 0.69, blue: 1.0, alpha: 1)

    /// A tile `width` points across, tall enough for a 2:3 still and the two
    /// caption lines. Derived rather than tabulated, so a narrower gallery
    /// cannot crop its own captions.
    public static func size(width: CGFloat) -> NSSize {
        NSSize(width: width,
               height: (4 + ((width - 8) * imageAspect).rounded() + captionHeight).rounded())
    }

    public let entry: LerpRotationEntry
    public let shaderTitle: String
    public var mode: Mode = .rotation { didSet { updateToolTip() } }

    /// Put this look in or take it out of the screensaver's rotation.
    public var onToggle: ((LerpRotationEntry) -> Void)?
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
            toolTip = isLocked
                ? label + " — the rotation must keep at least one look, and this is the last one"
                : label
            redraw()
        }
    }
    /// Whether a click on this tile can change the rotation. Locking stops a
    /// look being turned *off*; it never stops it being opened or pointed at,
    /// so hovering and `onOpen` deliberately test `isLive` instead.
    public var isToggleable: Bool { isLive && !isLocked }
    private var label: String { entry.shader + (entry.preset.map { " · " + $0 } ?? " · defaults") }
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

    private func updateToolTip() {
        let look = entry.shader + (entry.preset.map { " · " + $0 } ?? " · defaults")
        toolTip = look + (mode == .picker
            ? " — click to open it; the badge puts it in or out of the rotation"
            : " — click to put it in or out of the rotation; double-click to open it")
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // `.inVisibleRect` keeps the tracking rect in step with the scroll view
        // by itself, so a tile that scrolls out from under a stationary pointer
        // is exited rather than left thinking it is still hovered.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self))
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

    /// The inverted primary actions, in one place.
    ///
    /// The double-click in `.rotation` mode has one wrinkle worth stating: the
    /// first click of it has already fired `onToggle`, because a single click has
    /// to be instant — waiting out the double-click interval before honouring
    /// every click would make the gallery's whole point feel laggy. So the second
    /// click reports itself as `.open`, and the gallery puts the toggle back
    /// before opening. Toggling is its own inverse, so the rotation ends exactly
    /// where it started and opening a look never silently changes it.
    public override func mouseDown(with event: NSEvent) {
        guard isLive else { return }
        switch mode {
        case .rotation:
            // Opening is not gated on `isToggleable` — the last look left in the
            // rotation is locked against being switched off, not against being
            // edited.
            if event.clickCount == 1 { if isToggleable { onToggle?(entry) } }
            else if event.clickCount == 2 { onOpen?(entry) }
        case .picker:
            let point = convert(event.locationInWindow, from: nil)
            if badgeHitRect.contains(point) {
                if isToggleable { onToggle?(entry) }
            } else {
                onOpen?(entry)
            }
        }
    }

    // MARK: The live preview

    /// Where the shared live view goes, and where the still is drawn — the same
    /// rectangle, so one replaces the other exactly.
    public var pictureFrame: NSRect {
        let width = bounds.width - 8
        return NSRect(x: 4, y: 4, width: width, height: (width * Self.imageAspect).rounded())
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

    /// A tile is a checkbox that happens to be a picture — or, in the picker, a
    /// button that happens to be a picture — and it says so. That is what makes
    /// the gallery usable without sight of it, and it is also the handle
    /// `make test-load` presses the sheet's tiles through, because the loadtest
    /// links AppKit and ScreenSaver and nothing else and so cannot see this type
    /// at all. A test that drives the UI the way an assistive client does is
    /// testing the thing users get.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? {
        mode == .picker ? .button : .checkBox
    }
    public override func accessibilityLabel() -> String? {
        entry.shader + " · " + entry.displayName
            + (mode == .picker && !isOn ? " (not in the rotation)" : "")
    }
    public override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    /// Reflects whether the *primary* action works. In the picker that is
    /// opening, which a locked tile still does; in the gallery it is toggling,
    /// which it does not.
    public override func isAccessibilityEnabled() -> Bool {
        mode == .picker ? isLive : isToggleable
    }
    public override func accessibilityPerformPress() -> Bool {
        guard isLive else { return false }
        if mode == .picker {
            onOpen?(entry)
        } else {
            guard isToggleable else { return false }
            onToggle?(entry)
        }
        return true
    }
    /// The non-primary action of each mode, so both are reachable without a
    /// mouse: opening from the gallery, and toggling the rotation from the picker.
    public override func accessibilityPerformShowMenu() -> Bool {
        guard isLive else { return false }
        if mode == .picker {
            guard isToggleable else { return false }
            onToggle?(entry)
        } else {
            onOpen?(entry)
        }
        return true
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let frame = pictureFrame
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)

        // The picture. Stills are rendered at exactly the tile's 2:3, so this
        // neither crops nor squashes them.
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 1).setFill()
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
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)

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
        if isHot {
            NSColor(white: 1, alpha: 0.16).setStroke()
            let halo = NSBezierPath(roundedRect: frame.insetBy(dx: -2.5, dy: -2.5),
                                    xRadius: 9, yRadius: 9)
            halo.lineWidth = 2
            halo.stroke()
        }

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

        drawBadge(in: frame)
        if isLocked { drawLock(in: frame) }
        // `drawCaption` is deliberately not called here: it sits below the
        // picture rather than over it, so `draw` calls it for both states.
    }

    /// Where the badge is. In `.picker` mode it is the rotation toggle, so it is
    /// also a hit target and gets a little slack around it — 20 points is a small
    /// thing to ask someone to hit.
    private var badgeRect: NSRect {
        let frame = pictureFrame, side: CGFloat = 20
        return NSRect(x: frame.maxX - side - 6, y: frame.minY + 6, width: side, height: side)
    }

    private var badgeHitRect: NSRect { badgeRect.insetBy(dx: -6, dy: -6) }

    /// Filled tick when in, empty ring when out. The redundant signal, for
    /// anyone who cannot rely on the frame colour — and, in the picker, the
    /// control itself.
    private func drawBadge(in frame: NSRect) {
        let side: CGFloat = 20
        let box = NSRect(x: frame.maxX - side - 6, y: frame.minY + 6, width: side, height: side)
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
        let title = entry.displayName
        var strong: NSColor = isOn ? EditorTheme.text : NSColor(srgbRed: 0.44, green: 0.47, blue: 0.53, alpha: 1)
        let weak: NSColor = isOn ? EditorTheme.dim : NSColor(srgbRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)
        if isCurrent { strong = Self.accent }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center

        let box = NSRect(x: 4, y: frame.maxY + 6, width: bounds.width - 8, height: 15)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: isCurrent ? .semibold : .medium),
            .foregroundColor: strong, .paragraphStyle: style,
        ]).draw(in: box)
        NSAttributedString(string: shaderTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: weak, .paragraphStyle: style,
        ]).draw(in: box.offsetBy(dx: 0, dy: 15))
    }

    // MARK: Test hooks

    /// Drives the pointer the way AppKit does — a real enter/exit event through
    /// the tile's own handler, so a tile whose tracking is not wired up fails.
    public func synthesizeHover(_ inside: Bool) {
        guard let event = NSEvent.enterExitEvent(
            with: inside ? .mouseEntered : .mouseExited,
            location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if inside { mouseEntered(with: event) } else { mouseExited(with: event) }
    }

    /// A real click, at a real point, with a real click count — so the badge/body
    /// split and the single/double split are both exercised rather than assumed.
    @discardableResult
    public func synthesizeClick(at point: NSPoint, clickCount: Int) -> Bool {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown, location: convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1) else { return false }
        mouseDown(with: event)
        return true
    }

    /// The middle of the picture — a point that is the tile's body in either
    /// mode, never the badge.
    public var bodyPoint: NSPoint { NSPoint(x: pictureFrame.midX, y: pictureFrame.midY) }
    public var badgePoint: NSPoint { NSPoint(x: badgeRect.midX, y: badgeRect.midY) }
}

// MARK: - The gallery

/// Search bar, a scrolling grid of tiles grouped by shader, and a status line.
public final class RotationGalleryView: NSView, NSSearchFieldDelegate {

    /// The user changed the rotation. The set is the new one, in full.
    public var onChange: ((Set<LerpRotationEntry>) -> Void)?
    /// The user asked to edit a look: double-click in the gallery, a click in
    /// the picker, or ⏎ on the filter field. nil in a host that has no editor to
    /// open one in — the screensaver's Options… sheet — and the tiles simply do
    /// not offer it there.
    public var onOpen: ((LerpRotationEntry) -> Void)?
    /// The Regenerate button, when the host asked for one.
    public var onRegenerate: (() -> Void)?

    public private(set) var shaders: [LerpShader] = []
    public private(set) var entries: [LerpRotationEntry] = []
    public private(set) var enabled: Set<LerpRotationEntry> = []
    /// The look the host's editor has open, marked in the grid.
    public private(set) var currentEntry: LerpRotationEntry?

    /// What a click means here. See `RotationTile.Mode`.
    public let mode: RotationTile.Mode

    /// The one live view the grid lends to the tile under the pointer.
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
    private let showsRegenerate: Bool
    private var buttons: [NSButton] = []
    /// Held by reference rather than found by title: this one is switched off
    /// whenever pressing it would clear the rotation, and a lookup that missed
    /// would leave the floor unenforced with no sign of it.
    private var deselectAllButton: NSButton?

    private var tiles: [LerpRotationEntry: RotationTile] = [:]
    private var headers: [String: NSButton] = [:]
    private var headerCounts: [String: NSTextField] = [:]
    /// Laid out in shader order, so the grid and the model cannot disagree.
    private var order: [String] = []
    private var filter = ""

    /// Off when the rotation does not apply — the saver's Options… sheet greys
    /// the whole gallery out while a single shader is pinned.
    public private(set) var isActive = true
    private var inactiveNote: String?

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        var onLayout: ((CGFloat) -> CGFloat)?
        override func layout() {
            super.layout()
            guard let height = onLayout?(bounds.width) else { return }
            if abs(frame.height - height) > 0.5 {
                setFrameSize(NSSize(width: bounds.width, height: height))
            }
        }
    }

    public convenience override init(frame frameRect: NSRect) {
        self.init(frame: frameRect, tileSize: RotationTile.size, showsRegenerate: true)
    }

    /// - Parameters:
    ///   - tileSize: how big one look is drawn. The Options… sheet has less
    ///     room than the playground's window and asks for a smaller tile; so
    ///     does the toolbar popover.
    ///   - showsRegenerate: the playground offers Regenerate because it edits
    ///     shaders; nothing in the Options… sheet can change what a still shows.
    ///   - mode: what a click on a tile does. Defaulted so the Options… sheet,
    ///     which is the surface whose behaviour must not change, needs no edit.
    public init(frame frameRect: NSRect, tileSize: NSSize, showsRegenerate: Bool,
                mode: RotationTile.Mode = .rotation) {
        self.tileSize = tileSize
        self.showsRegenerate = showsRegenerate
        self.mode = mode
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
        search.placeholderString = mode == .picker
            ? "Type to filter — ⏎ opens the first"
            : "Filter shaders and presets"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.delegate = self
        search.identifier = NSUserInterfaceItemIdentifier("rotation-search")
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 130).isActive = true

        countLabel.identifier = NSUserInterfaceItemIdentifier("rotation-count")
        var controls: [NSView] = [search]
        if mode == .picker {
            // The picker inverts the primary action, so it says so once, here,
            // rather than leaving it to be discovered by clicking something.
            controls.append(Chrome.label("Click opens · badge toggles rotation", size: 11))
        } else {
            let selectAll = Chrome.button("Select All", target: self, action: #selector(selectAllLooks))
            let deselectAll = Chrome.button("Deselect All", target: self,
                                            action: #selector(deselectAllLooks))
            deselectAllButton = deselectAll
            buttons = [selectAll, deselectAll]
            controls += [selectAll, deselectAll]
            if showsRegenerate {
                let regenerate = Chrome.button("Regenerate", target: self, action: #selector(regenerate))
                buttons.append(regenerate)
                controls.append(regenerate)
            }
        }
        controls += [Chrome.flexible(), progress, countLabel]
        let bar = Chrome.bar(controls)

        canvas.onLayout = { [weak self] width in self?.reflow(width: width) ?? 0 }
        canvas.autoresizingMask = [.width]
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        // Scrolling moves tiles under a stationary pointer. `.inVisibleRect`
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

    /// Rebuilds the grid for `shaders`. Tiles for looks that are still there
    /// keep their images, so a shader being edited redraws one row rather than
    /// blanking the whole gallery.
    public func show(shaders: [LerpShader], enabled: Set<LerpRotationEntry>) {
        // A tile that is about to be taken away must not still be holding the
        // shared live view.
        preview.stop()
        self.shaders = shaders
        self.entries = shaders.rotationEntries()
        self.enabled = enabled
        let live = Set(entries)

        for (entry, tile) in tiles where !live.contains(entry) {
            tile.removeFromSuperview()
            tiles[entry] = nil
        }
        let names = Set(shaders.map(\.name))
        for (name, header) in headers where !names.contains(name) {
            header.removeFromSuperview()
            headerCounts[name]?.removeFromSuperview()
            headers[name] = nil
            headerCounts[name] = nil
        }

        order = shaders.map(\.name)
        for shader in shaders {
            if headers[shader.name] == nil {
                let box = NSButton(checkboxWithTitle: shader.displayName, target: self,
                                   action: #selector(groupToggled(_:)))
                box.allowsMixedState = true
                box.font = .systemFont(ofSize: 12, weight: .semibold)
                box.identifier = NSUserInterfaceItemIdentifier("shader:" + shader.name)
                box.isEnabled = isActive
                canvas.addSubview(box)
                headers[shader.name] = box

                // Tagged so `make test-load` can check the n/m beside a heading
                // says the same thing the heading's own tri-state does.
                let count = Chrome.label("", size: 10.5)
                count.identifier = NSUserInterfaceItemIdentifier("count:" + shader.name)
                canvas.addSubview(count)
                headerCounts[shader.name] = count
            }
            for entry in [shader].rotationEntries() where tiles[entry] == nil {
                let tile = RotationTile(entry: entry, shaderTitle: shader.displayName, size: tileSize)
                tile.mode = mode
                tile.onToggle = { [weak self] in self?.toggle($0) }
                tile.onOpen = { [weak self] in self?.open($0) }
                tile.onHover = { [weak self] tile, inside in self?.hovered(tile, inside) }
                tile.identifier = NSUserInterfaceItemIdentifier("entry:" + entry.key)
                tile.isLive = isActive
                canvas.addSubview(tile)
                tiles[entry] = tile
            }
        }
        refresh()
        canvas.needsLayout = true
    }

    /// A still arrived.
    public func show(image: NSImage, for entry: LerpRotationEntry) {
        tiles[entry]?.image = image
    }

    /// Drops every still, so the next run redraws them all.
    public func clearImages() {
        tiles.values.forEach { $0.image = nil }
    }

    /// Marks the look the host's editor has open.
    public func showCurrent(_ entry: LerpRotationEntry?) {
        currentEntry = entry
        for (key, tile) in tiles { tile.isCurrent = key == entry }
    }

    public func showProgress(done: Int, total: Int) {
        progress.isHidden = done >= total
        progress.maxValue = Double(max(total, 1))
        progress.doubleValue = Double(done)
        countLabel.stringValue = done >= total
            ? "\(entries.count) looks"
            : "rendering \(done) of \(total)…"
    }

    /// Greys the whole gallery out — what the Options… sheet does when a shader
    /// is pinned and the rotation therefore does not apply. `inactive` replaces
    /// the status line while it is off.
    public func setActive(_ active: Bool, note inactive: String? = nil) {
        isActive = active
        inactiveNote = inactive
        if !active { preview.stop() }
        search.isEnabled = active
        buttons.forEach { $0.isEnabled = active }
        headers.values.forEach { $0.isEnabled = active }
        tiles.values.forEach { $0.isLive = active }
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

    /// The pointer arrived on, or left, a tile.
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

    /// The floor, and the only place it is enforced: taking `victims` out must
    /// leave at least one look in.
    ///
    /// Everything that reads this selection now takes it literally — there is no
    /// longer any code that turns an empty rotation into a full one, because
    /// that is the behaviour that made a deselected look play. The price of
    /// deleting those widenings is that an empty selection has to be
    /// unreachable, and this is where it becomes unreachable.
    private func wouldEmpty(_ victims: some Sequence<LerpRotationEntry>) -> Bool {
        enabled.subtracting(victims).isEmpty
    }

    /// Said out loud when a click is refused. Cleared by the next one that is
    /// not, so it reads as a response rather than as a state.
    private var refusal: String?
    private static let floorNote = "The rotation must keep at least one look."

    private func refuse(_ why: String) {
        refusal = why
        refresh()
        NSSound.beep()
    }

    private func toggle(_ entry: LerpRotationEntry) {
        if enabled.contains(entry) {
            guard !wouldEmpty([entry]) else { return refuse(Self.floorNote) }
            enabled.remove(entry)
        } else {
            enabled.insert(entry)
        }
        commit()
    }

    /// Opening from the gallery arrives on the *second* click of a double-click,
    /// and the first one already toggled — see `RotationTile.mouseDown`. Undoing
    /// it here rather than in the tile keeps that a model operation: toggling is
    /// its own inverse, so the rotation is exactly where it was and the host is
    /// told about it either way.
    private func open(_ entry: LerpRotationEntry) {
        if mode == .rotation { toggle(entry) }
        onOpen?(entry)
    }

    /// A shader heading owns its whole group: if every look under it is in, it
    /// takes them all out, otherwise it puts them all in. Read off the group
    /// rather than off the checkbox's own next state — a three-state box's idea
    /// of what comes next is not what we mean.
    @objc private func groupToggled(_ sender: NSButton) {
        guard isActive else { return }
        let name = (sender.identifier?.rawValue ?? "").replacingOccurrences(of: "shader:", with: "")
        let group = entries.filter { $0.shader == name }
        guard !group.isEmpty else { return }
        if group.allSatisfy(enabled.contains) {
            guard !wouldEmpty(group) else {
                // Put the box back where it was: it is a checkbox, and it has
                // already flipped itself by the time we are called.
                refresh()
                return refuse("\(name) is the whole rotation. " + Self.floorNote)
            }
            enabled.subtract(group)
        } else {
            enabled.formUnion(group)
        }
        commit()
    }

    /// Acts on what is on screen. With no filter that is everything; with one it
    /// is the far more useful "all the dark ones" rather than a button that
    /// quietly ignores the search.
    @objc private func selectAllLooks() {
        guard isActive else { return }
        enabled.formUnion(visibleEntries())
        commit()
    }

    /// Disabled outright when it would empty the rotation — which, with no
    /// filter up, it always would. Refusing here rather than "succeeding" and
    /// having the saved set silently mean *all of them* is the whole of this
    /// change: a control that cannot do the wrong thing beats a control that
    /// does the opposite of what it says.
    @objc private func deselectAllLooks() {
        guard isActive else { return }
        let victims = visibleEntries()
        guard !wouldEmpty(victims) else {
            return refuse(filter.isEmpty
                          ? Self.floorNote + " Filter first, then deselect what you filtered."
                          : "That would clear the whole rotation. " + Self.floorNote)
        }
        enabled.subtract(victims)
        commit()
    }

    @objc private func regenerate() {
        onRegenerate?()
    }

    @objc private func searchChanged() {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        preview.stop()          // the tile it was on may be about to be hidden
        refresh()
        canvas.needsLayout = true
    }

    /// Typeahead. The dropbox this grid replaced had one thing over it — you
    /// could type the first few letters of a shader and hit return — so the
    /// filter field keeps it: ⏎ opens the first look still showing.
    public func control(_ control: NSControl, textView: NSTextView,
                        doCommandBy selector: Selector) -> Bool {
        guard control === search, selector == #selector(NSResponder.insertNewline(_:)),
              let first = visibleEntries().first, onOpen != nil else { return false }
        onOpen?(first)
        return true
    }

    private func commit() {
        refusal = nil
        refresh()
        onChange?(enabled)
    }

    // MARK: Presentation

    private func matches(_ entry: LerpRotationEntry) -> Bool {
        guard !filter.isEmpty else { return true }
        let haystack = entry.shader + " " + (entry.preset ?? "defaults")
        return haystack.range(of: filter, options: .caseInsensitive) != nil
    }

    public func visibleEntries() -> [LerpRotationEntry] { entries.filter(matches) }

    /// Pushes the model into every tile and heading, and writes the status line.
    ///
    /// Visibility is settled here rather than in `reflow`, because "the filter
    /// hid it" is a fact about the model and has to be true the moment the
    /// filter changes — not on the next layout pass.
    private func refresh() {
        // The one look that cannot be turned off, when there is only one left.
        let lastOne = enabled.count == 1 ? enabled.first : nil
        for (entry, tile) in tiles {
            tile.isOn = enabled.contains(entry)
            tile.isCurrent = entry == currentEntry
            tile.isLocked = entry == lastOne
            tile.isHidden = !matches(entry)
        }
        // Deselect All goes with them: a button that would clear the rotation is
        // off, not silently ignored.
        deselectAllButton?.isEnabled = isActive && !wouldEmpty(visibleEntries())
        deselectAllButton?.toolTip = deselectAllButton?.isEnabled == true ? nil : Self.floorNote
        for name in order {
            let group = entries.filter { $0.shader == name }
            let on = group.filter(enabled.contains).count
            headers[name]?.state = on == 0 ? .off : (on == group.count ? .on : .mixed)
            headerCounts[name]?.stringValue = "\(on)/\(group.count)"
            let shown = group.contains(where: matches)
            headers[name]?.isHidden = !shown
            headerCounts[name]?.isHidden = !shown
        }
        if progress.isHidden { countLabel.stringValue = "\(entries.count) looks" }
        // Inactive: the status line's job is to say why nothing here applies,
        // not to report a count that has no effect.
        if !isActive, let inactiveNote {
            note.stringValue = inactiveNote
            return
        }
        let shaderCount = Set(enabled.map(\.shader)).count
        if entries.isEmpty {
            note.stringValue = "No shaders found."
        } else if enabled.isEmpty {
            // Only reachable by hand-editing the defaults: the tiles and the
            // Deselect All button both refuse to get here. Said plainly rather
            // than papered over, because the thing this used to say — that an
            // empty selection is saved as all of them — was the sentence that
            // made deselecting a look unreliable.
            note.stringValue = "No looks selected. The screensaver has nothing to show."
        } else {
            note.stringValue = "\(enabled.count) of \(entries.count) looks, "
                + "across \(shaderCount) of \(shaders.count) shaders."
        }
        if !filter.isEmpty {
            note.stringValue += "  Filter “\(filter)”: \(visibleEntries().count) shown."
        }
        // Why the last tile will not budge, said before it is pressed rather
        // than only after. A control that refuses is only fair if the reason is
        // already on screen — the tooltip is not enough, because a tile that
        // does not respond reads as broken long before anyone hovers it.
        if let refusal {
            note.stringValue += "  " + refusal
        } else if enabled.count == 1 {
            note.stringValue += "  " + Self.floorNote
        }
    }

    // MARK: Layout

    private static let pad: CGFloat = 16
    private static let gap: CGFloat = 10
    private static let groupGapX: CGFloat = 30
    private static let groupGapY: CGFloat = 22
    private static let headerHeight: CGFloat = 26
    /// A shader's looks stay on one line up to this many, so a group reads as a
    /// single strip of that shader rather than as a paragraph.
    private static let maxPerGroupRow = 6

    /// Lays the grid out for a given width and returns the height it needs.
    ///
    /// The unit that flows is the *group*, not the tile: a heading and its
    /// shader's looks are one block, and blocks pack across the window until the
    /// next one will not fit. Flowing tiles instead would put one shader per
    /// band and leave two thirds of a wide window empty, because no shader here
    /// has more than five looks.
    ///
    /// Hand-rolled because that is not a shape any stock container makes
    /// cheaply, and because 114 tiles want a flat view tree.
    @discardableResult
    private func reflow(width: CGFloat) -> CGFloat {
        let tile = tileSize
        let usable = max(tile.width, width - 2 * Self.pad)
        let perRow = max(1, min(Self.maxPerGroupRow,
                                Int((usable + Self.gap) / (tile.width + Self.gap))))
        var x = Self.pad
        var bandTop = Self.pad
        var bandHeight: CGFloat = 0

        for name in order {
            let group = entries.filter { $0.shader == name && matches($0) }
            guard !group.isEmpty, let header = headers[name] else { continue }
            let count = headerCounts[name]
            header.sizeToFit()
            count?.sizeToFit()

            let columns = min(group.count, perRow)
            let rows = (group.count + columns - 1) / columns
            let tilesWidth = CGFloat(columns) * (tile.width + Self.gap) - Self.gap
            // A long shader name must not run under its neighbour, so a
            // one-tile group is as wide as its own heading when it has to be.
            let blockWidth = max(tilesWidth,
                                 header.frame.width + 6 + (count?.frame.width ?? 0))
            let blockHeight = Self.headerHeight
                + CGFloat(rows) * (tile.height + Self.gap) - Self.gap

            if x > Self.pad && x + blockWidth > width - Self.pad {
                bandTop += bandHeight + Self.groupGapY
                x = Self.pad
                bandHeight = 0
            }

            header.setFrameOrigin(NSPoint(x: x - 2, y: bandTop))
            count?.setFrameOrigin(NSPoint(x: x - 2 + header.frame.width + 6, y: bandTop + 3))
            for (index, entry) in group.enumerated() {
                let view = tiles[entry]
                view?.setFrameSize(tile)
                view?.setFrameOrigin(NSPoint(
                    x: x + CGFloat(index % columns) * (tile.width + Self.gap),
                    y: bandTop + Self.headerHeight
                        + CGFloat(index / columns) * (tile.height + Self.gap)))
            }

            bandHeight = max(bandHeight, blockHeight)
            x += blockWidth + Self.groupGapX
        }
        return max(bandTop + bandHeight + Self.pad, scroll.contentView.bounds.height)
    }

    public override func layout() {
        super.layout()
        canvas.needsLayout = true
    }

    // MARK: Test hooks

    /// The tiles, in rotation order — what `--selftest` counts against
    /// `rotationEntries()`.
    public var tileEntries: [LerpRotationEntry] { entries.filter { tiles[$0] != nil } }
    public func tile(for entry: LerpRotationEntry) -> RotationTile? { tiles[entry] }
    public func header(for shader: String) -> NSButton? { headers[shader] }
    public var noteText: String { note.stringValue }
    public var visibleTileCount: Int { tiles.values.filter { !$0.isHidden }.count }
    public var filterText: String { search.stringValue }

    /// `make test-load` links AppKit and the ScreenSaver framework and nothing
    /// else, so it cannot name a single type in this file. These two are
    /// reachable by KVC from a process holding only an `NSView`, which is how it
    /// checks that the sheet's stills actually arrived.
    @objc public var stillsShown: Int { tiles.values.filter { $0.image != nil }.count }
    @objc public var stillsMissing: Int { tiles.values.filter { $0.image == nil }.count }

    /// Clicks a tile the way a mouse would — through the tile's own handler, so
    /// a tile that is not wired up fails the test.
    public func click(_ entry: LerpRotationEntry) {
        guard let tile = tiles[entry] else { return }
        tile.synthesizeClick(at: tile.bodyPoint, clickCount: 1)
    }

    /// The second click of a double-click on the picture: what "go to this look"
    /// is in the gallery.
    public func doubleClick(_ entry: LerpRotationEntry) {
        guard let tile = tiles[entry] else { return }
        tile.synthesizeClick(at: tile.bodyPoint, clickCount: 1)
        tile.synthesizeClick(at: tile.bodyPoint, clickCount: 2)
    }

    /// A click on the corner badge: what "in or out of the rotation" is in the
    /// picker.
    public func clickBadge(_ entry: LerpRotationEntry) {
        guard let tile = tiles[entry] else { return }
        tile.synthesizeClick(at: tile.badgePoint, clickCount: 1)
    }

    public func hoverEnter(_ entry: LerpRotationEntry) { tiles[entry]?.synthesizeHover(true) }
    public func hoverExit(_ entry: LerpRotationEntry) { tiles[entry]?.synthesizeHover(false) }

    /// Scrolls the grid the way a scroller does — through the clip view, so the
    /// bounds notification the hover handling listens for is the real one.
    /// False when the grid had nowhere to go, which a test has to know about
    /// rather than read as a pass.
    @discardableResult
    public func scrollBy(_ delta: CGFloat) -> Bool {
        let clip = scroll.contentView
        let before = clip.bounds.origin
        // Clamped here rather than left to the clip view: `scroll(to:)` takes a
        // point at its word, and a large negative one leaves the grid off the
        // top of its own scroller.
        let limit = max(0, canvas.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: before.x, y: min(max(0, before.y + delta), limit)))
        scroll.reflectScrolledClipView(clip)
        return clip.bounds.origin != before
    }

    /// Fires a shader heading through its own target/action.
    public func clickHeader(_ shader: String) {
        guard let box = headers[shader] else { return }
        _ = box.target?.perform(box.action, with: box)
    }

    public func setFilter(_ text: String) {
        search.stringValue = text
        searchChanged()
    }

    /// ⏎ in the filter field, through the very delegate callback AppKit calls.
    @discardableResult
    public func pressReturnInSearch() -> Bool {
        control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    public func clickSelectAll() { selectAllLooks() }
    public func clickDeselectAll() { deselectAllLooks() }
}
