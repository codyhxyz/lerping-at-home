import AppKit

/// The rotation gallery: every look the screensaver can shuffle through, as a
/// picture you click to put it in or take it out.
///
/// The screensaver's own Options… sheet lists the same 114 looks as a checkbox
/// per row, which tells you their names and nothing else — there is no way to
/// find out what `voronoi/Molten` is except to wait for it to come round. Here
/// each look is a portrait still of itself, grouped under its shader, and the
/// on/off state is the difference between a lit tile with an accent frame and a
/// dimmed one behind a scrim. Clicking a tile writes the new rotation straight
/// through to the screensaver's own defaults — there is no OK button, because
/// there is nothing to confirm.

// MARK: - One look

/// A single look. Drawn rather than assembled out of an image view and two
/// labels: the whole tile is one hit target and one appearance, and drawing it
/// in one place is what makes the off state read as *off* at a glance instead of
/// as a slightly different shade of on.
final class RotationTile: NSView {

    static let size = NSSize(width: 134, height: 240)
    /// 2:3, which is what "vertical profile" means here and what the stills are
    /// rendered at.
    private static let imageAspect: CGFloat = 1.5
    private static let accent = NSColor(srgbRed: 0.36, green: 0.69, blue: 1.0, alpha: 1)

    let entry: LerpRotationEntry
    let shaderTitle: String
    var onToggle: ((LerpRotationEntry) -> Void)?

    var image: NSImage? { didSet { needsDisplay = true } }
    var isOn = true { didSet { if isOn != oldValue { needsDisplay = true } } }
    private var isHot = false { didSet { if isHot != oldValue { needsDisplay = true } } }

    init(entry: LerpRotationEntry, shaderTitle: String) {
        self.entry = entry
        self.shaderTitle = shaderTitle
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        toolTip = entry.shader + (entry.preset.map { " · " + $0 } ?? " · defaults")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHot = true }
    override func mouseExited(with event: NSEvent) { isHot = false }

    override func mouseDown(with event: NSEvent) {
        onToggle?(entry)
    }

    /// Where the still goes. The rest of the tile is the caption.
    private var imageRect: NSRect {
        let width = bounds.width - 8
        return NSRect(x: 4, y: 4, width: width, height: (width * Self.imageAspect).rounded())
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = imageRect
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

        // Off looks off: a scrim over the picture, not a tint of it.
        if !isOn {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075, alpha: 0.74).setFill()
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

        drawBadge(in: frame)
        drawCaption(below: frame)
    }

    /// Filled tick when in, empty ring when out. The redundant signal, for
    /// anyone who cannot rely on the frame colour.
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
        let strong: NSColor = isOn ? EditorTheme.text : NSColor(srgbRed: 0.44, green: 0.47, blue: 0.53, alpha: 1)
        let weak: NSColor = isOn ? EditorTheme.dim : NSColor(srgbRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .center

        let box = NSRect(x: 4, y: frame.maxY + 6, width: bounds.width - 8, height: 15)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: strong, .paragraphStyle: style,
        ]).draw(in: box)
        NSAttributedString(string: shaderTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: weak, .paragraphStyle: style,
        ]).draw(in: box.offsetBy(dx: 0, dy: 15))
    }
}

// MARK: - The gallery

/// Search bar, a scrolling grid of tiles grouped by shader, and a status line.
///
/// It owns no policy: every toggle goes out through `onChange`, and what is on
/// comes back in through `show(enabled:)`. The window controller is what talks
/// to `RotationStore`.
final class RotationGalleryView: NSView {

    /// The user changed the rotation. The set is the new one, in full.
    var onChange: ((Set<LerpRotationEntry>) -> Void)?
    /// The Regenerate button.
    var onRegenerate: (() -> Void)?

    private(set) var shaders: [LerpShader] = []
    private(set) var entries: [LerpRotationEntry] = []
    private(set) var enabled: Set<LerpRotationEntry> = []

    private let search = NSSearchField()
    private let countLabel = Chrome.label("", size: 11, color: EditorTheme.text)
    private let note = Chrome.label("", size: 11)
    private let progress = NSProgressIndicator()
    private let scroll = NSScrollView()
    private let canvas = Canvas()

    private var tiles: [LerpRotationEntry: RotationTile] = [:]
    private var headers: [String: NSButton] = [:]
    private var headerCounts: [String: NSTextField] = [:]
    /// Laid out in shader order, so the grid and the model cannot disagree.
    private var order: [String] = []
    private var filter = ""

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = EditorTheme.background.cgColor
        build()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: Construction

    private func build() {
        search.placeholderString = "Filter shaders and presets"
        search.controlSize = .small
        search.font = .systemFont(ofSize: 11)
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.isHidden = true
        progress.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let bar = Chrome.bar([
            search,
            Chrome.button("Select All", target: self, action: #selector(selectAllLooks)),
            Chrome.button("Deselect All", target: self, action: #selector(deselectAllLooks)),
            Chrome.button("Regenerate", target: self, action: #selector(regenerate)),
            Chrome.flexible(), progress, countLabel,
        ])

        canvas.onLayout = { [weak self] width in self?.reflow(width: width) ?? 0 }
        canvas.autoresizingMask = [.width]
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = EditorTheme.background
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

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
    func show(shaders: [LerpShader], enabled: Set<LerpRotationEntry>) {
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
                canvas.addSubview(box)
                headers[shader.name] = box

                let count = Chrome.label("", size: 10.5)
                canvas.addSubview(count)
                headerCounts[shader.name] = count
            }
            for entry in [shader].rotationEntries() where tiles[entry] == nil {
                let tile = RotationTile(entry: entry, shaderTitle: shader.displayName)
                tile.onToggle = { [weak self] in self?.toggle($0) }
                tile.identifier = NSUserInterfaceItemIdentifier("entry:" + entry.key)
                canvas.addSubview(tile)
                tiles[entry] = tile
            }
        }
        refresh()
        canvas.needsLayout = true
    }

    /// A still arrived.
    func show(image: NSImage, for entry: LerpRotationEntry) {
        tiles[entry]?.image = image
    }

    /// Drops every still, so the next run redraws them all.
    func clearImages() {
        tiles.values.forEach { $0.image = nil }
    }

    func showProgress(done: Int, total: Int) {
        progress.isHidden = done >= total
        progress.maxValue = Double(max(total, 1))
        progress.doubleValue = Double(done)
        countLabel.stringValue = done >= total
            ? "\(entries.count) looks"
            : "rendering \(done) of \(total)…"
    }

    // MARK: Model out

    private func toggle(_ entry: LerpRotationEntry) {
        if enabled.contains(entry) { enabled.remove(entry) } else { enabled.insert(entry) }
        commit()
    }

    /// A shader heading owns its whole group: if every look under it is in, it
    /// takes them all out, otherwise it puts them all in. Read off the group
    /// rather than off the checkbox's own next state — same rule the saver's
    /// Options sheet uses, for the same reason.
    @objc private func groupToggled(_ sender: NSButton) {
        let name = (sender.identifier?.rawValue ?? "").replacingOccurrences(of: "shader:", with: "")
        let group = entries.filter { $0.shader == name }
        guard !group.isEmpty else { return }
        if group.allSatisfy(enabled.contains) {
            enabled.subtract(group)
        } else {
            enabled.formUnion(group)
        }
        commit()
    }

    /// Acts on what is on screen. With no filter that is everything, which is
    /// what the saver's sheet does; with one it is the far more useful "all the
    /// dark ones" rather than a button that quietly ignores the search.
    @objc private func selectAllLooks() {
        enabled.formUnion(visibleEntries())
        commit()
    }

    @objc private func deselectAllLooks() {
        enabled.subtract(visibleEntries())
        commit()
    }

    @objc private func regenerate() {
        onRegenerate?()
    }

    @objc private func searchChanged() {
        filter = search.stringValue.trimmingCharacters(in: .whitespaces)
        refresh()
        canvas.needsLayout = true
    }

    private func commit() {
        refresh()
        onChange?(enabled)
    }

    // MARK: Presentation

    private func matches(_ entry: LerpRotationEntry) -> Bool {
        guard !filter.isEmpty else { return true }
        let haystack = entry.shader + " " + (entry.preset ?? "defaults")
        return haystack.range(of: filter, options: .caseInsensitive) != nil
    }

    func visibleEntries() -> [LerpRotationEntry] { entries.filter(matches) }

    /// Pushes the model into every tile and heading, and writes the status line.
    ///
    /// Visibility is settled here rather than in `reflow`, because "the filter
    /// hid it" is a fact about the model and has to be true the moment the
    /// filter changes — not on the next layout pass.
    private func refresh() {
        for (entry, tile) in tiles {
            tile.isOn = enabled.contains(entry)
            tile.isHidden = !matches(entry)
        }
        for name in order {
            let group = entries.filter { $0.shader == name }
            let on = group.filter(enabled.contains).count
            headers[name]?.state = on == 0 ? .off : (on == group.count ? .on : .mixed)
            headerCounts[name]?.stringValue = "\(on)/\(group.count)"
            let shown = group.contains(where: matches)
            headers[name]?.isHidden = !shown
            headerCounts[name]?.isHidden = !shown
        }
        let shaderCount = Set(enabled.map(\.shader)).count
        if entries.isEmpty {
            note.stringValue = "No shaders found."
        } else if enabled.isEmpty {
            // Same rule as the Options sheet: an empty rotation is a black
            // screensaver, so an empty selection is saved as all of them.
            note.stringValue = "Nothing selected — saved as all \(entries.count) looks."
        } else {
            note.stringValue = "\(enabled.count) of \(entries.count) looks, "
                + "across \(shaderCount) of \(shaders.count) shaders."
        }
        if !filter.isEmpty {
            note.stringValue += "  Filter “\(filter)”: \(visibleEntries().count) shown."
        }
        if progress.isHidden { countLabel.stringValue = "\(entries.count) looks" }
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
        let tile = RotationTile.size
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

    override func layout() {
        super.layout()
        canvas.needsLayout = true
    }

    // MARK: Test hooks

    /// The tiles, in rotation order — what `--selftest` counts against
    /// `rotationEntries()`.
    var tileEntries: [LerpRotationEntry] { entries.filter { tiles[$0] != nil } }
    func tile(for entry: LerpRotationEntry) -> RotationTile? { tiles[entry] }
    func header(for shader: String) -> NSButton? { headers[shader] }
    var noteText: String { note.stringValue }
    var visibleTileCount: Int { tiles.values.filter { !$0.isHidden }.count }

    /// Clicks a tile the way a mouse would — through the tile's own handler, so
    /// a tile that is not wired up fails the test.
    func click(_ entry: LerpRotationEntry) {
        guard let tile = tiles[entry] else { return }
        tile.onToggle?(tile.entry)
    }

    /// Fires a shader heading through its own target/action.
    func clickHeader(_ shader: String) {
        guard let box = headers[shader] else { return }
        _ = box.target?.perform(box.action, with: box)
    }

    func setFilter(_ text: String) {
        search.stringValue = text
        searchChanged()
    }

    func clickSelectAll() { selectAllLooks() }
    func clickDeselectAll() { deselectAllLooks() }
}

// MARK: - The window

/// A window of its own for the gallery: it is a different job from editing a
/// shader, it wants the width, and the playground's three-pane layout has no
/// room to spare.
final class RotationWindowController: NSWindowController, NSWindowDelegate {

    let gallery = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
    private let thumbnails: RotationThumbnails
    private let defaults: UserDefaults?
    private let searchURLs: [URL]
    /// What the gallery was last built from, so an edit somewhere else in the
    /// app can be recognised as one shader changing rather than a reload.
    private var sourceFingerprint = ""

    /// Timings for the report and for `--selftest`.
    private(set) var lastLoadSeconds: Double = 0
    var thumbnailStats: (memory: Int, disk: Int, rendered: Int, failed: [String]) {
        (thumbnails.memoryHits, thumbnails.diskHits, thumbnails.rendered, thumbnails.failed)
    }

    /// `defaults` is injected so `--selftest` can point the whole thing at a
    /// scratch domain instead of the user's screensaver settings.
    init(searchURLs: [URL], defaults: UserDefaults?, hidden: Bool,
         thumbnails: RotationThumbnails? = nil) {
        self.searchURLs = searchURLs
        self.defaults = defaults
        self.thumbnails = thumbnails ?? RotationThumbnails(searchURLs: searchURLs)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Rotation — what the screensaver shuffles through"
        window.minSize = NSSize(width: 620, height: 420)
        super.init(window: window)
        window.delegate = self
        window.contentView = gallery
        if hidden {
            // Same trick as the playground's own self-test window: real, laid
            // out and drawing, but not on the user's screen. See
            // `PlaygroundWindowController.hide`.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        } else {
            window.setFrameAutosaveName("LerpRotationWindow")
        }

        gallery.onChange = { [weak self] enabled in self?.persist(enabled) }
        gallery.onRegenerate = { [weak self] in
            guard let self else { return }
            self.thumbnails.evictAll()
            self.gallery.clearImages()
            self.load(shaders: self.gallery.shaders, force: true)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Builds the gallery from `shaders` and starts filling the stills in.
    /// A no-op when nothing about the shaders has changed since the last call.
    func load(shaders: [LerpShader], force: Bool = false) {
        let fingerprint = shaders.map { $0.name + ":" + RotationThumbnails.hash($0.source) }
            .joined(separator: ",")
        guard force || fingerprint != sourceFingerprint else { return }
        sourceFingerprint = fingerprint

        let entries = shaders.rotationEntries()
        gallery.show(shaders: shaders,
                     enabled: Set(LerpMetalView.Config.rotation(
                        of: RotationStore.load(discovered: entries, from: defaults),
                        from: entries)))

        let byName = Dictionary(uniqueKeysWithValues: shaders.map { ($0.name, $0) })
        let jobs = entries.compactMap { entry in
            byName[entry.shader].map { RotationThumbnails.Job(entry: entry, shader: $0) }
        }
        let started = CFAbsoluteTimeGetCurrent()
        gallery.showProgress(done: 0, total: jobs.count)
        thumbnails.start(jobs,
                         onImage: { [weak self] entry, image in
                             self?.gallery.show(image: image, for: entry)
                         },
                         onProgress: { [weak self] done, total in
                             self?.gallery.showProgress(done: done, total: total)
                         },
                         onFinished: { [weak self] in
                             self?.lastLoadSeconds = CFAbsoluteTimeGetCurrent() - started
                             self?.onLoaded?()
                         })
    }

    /// Fired when every still for the current run has landed. `--selftest` waits
    /// on it; nothing else does.
    var onLoaded: (() -> Void)?

    /// Rebuilds every still whether or not anything changed — the Regenerate
    /// button, and what `--selftest` uses to get a genuinely cold run.
    func reload(shaders: [LerpShader]) { load(shaders: shaders, force: true) }

    /// Throws the whole cache away, on disk and in memory.
    func evictThumbnails() {
        thumbnails.evictAll()
        gallery.clearImages()
    }

    var cacheDirectory: URL { thumbnails.cacheDirectory }

    /// The whole point of the feature: a click writes the screensaver's own
    /// rotation, in the screensaver's own domain, immediately.
    private func persist(_ enabled: Set<LerpRotationEntry>) {
        RotationStore.save(enabled, entries: gallery.entries, to: defaults)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close(cancellingWork: Bool) {
        if cancellingWork { thumbnails.cancel() }
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        thumbnails.cancel()
    }
}
