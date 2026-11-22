import AppKit

final class DiscoverController: NSWindowController, NSWindowDelegate {
    private final class TopClipView: NSClipView {
        override var isFlipped: Bool { true }
    }

    private let scroll = NSScrollView()
    private let shelves = NSStackView()
    private let thumbnails = RotationThumbnails(searchURLs: RepoLocation.searchURLs)
    private lazy var preview = RotationPreviewPlayer(recipe: thumbnails.recipe)
    private let mood = NSSegmentedControl(labels: ["Any mood"] + EditorialCatalog.Mood.allCases.map(\.rawValue),
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let motion = NSSegmentedControl(labels: ["Any motion"] + EditorialCatalog.Motion.allCases.map(\.rawValue),
                                             trackingMode: .selectOne, target: nil, action: nil)
    private let brightness = NSSegmentedControl(labels: ["Any brightness"] + EditorialCatalog.Brightness.allCases.map(\.rawValue),
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private var installed: [LerpRotationEntry: LerpShader] = [:]
    private var tiles: [LerpRotationEntry: RotationTile] = [:]
    private var rotationButtons: [LerpRotationEntry: NSButton] = [:]
    private var selection: LerpRotationSelection?

    var onOpen: ((LerpRotationEntry) -> Void)?
    var onAdd: ((LerpRotationEntry) throws -> LerpRotationSelection)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 810, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Discover"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 400)
        super.init(window: window)
        window.delegate = self
        window.center()
        build(window)
        NotificationCenter.default.addObserver(self, selector: #selector(stopHover),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    required init?(coder: NSCoder) { nil }

    func present(shaders: [LerpShader], selection: LerpRotationSelection) {
        let entries = Set(shaders.rotationEntries())
        let builtIns = Dictionary(uniqueKeysWithValues: shaders.filter(\.isBuiltIn).map { ($0.name, $0) })
        installed = Dictionary(uniqueKeysWithValues: EditorialCatalog.shelves.flatMap(\.pieces).compactMap { piece in
            guard entries.contains(piece.entry), let shader = builtIns[piece.entry.shader] else { return nil }
            return (piece.entry, shader)
        })
        self.selection = selection
        rebuild()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func showSelection(_ selection: LerpRotationSelection) {
        self.selection = selection
        for (entry, button) in rotationButtons {
            let plays = selection.plays(entry)
            button.title = plays ? "In Rotation" : "Add to Rotation"
            button.isEnabled = !plays
        }
    }

    private func build(_ window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.addArrangedSubview(heading())
        root.addArrangedSubview(NSBox.separator())
        scroll.contentView = TopClipView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        shelves.translatesAutoresizingMaskIntoConstraints = false
        shelves.orientation = .vertical
        shelves.alignment = .leading
        shelves.spacing = 32
        document.addSubview(shelves)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            shelves.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            shelves.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            shelves.topAnchor.constraint(equalTo: document.topAnchor, constant: 22),
            shelves.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
        ])
        root.addArrangedSubview(scroll)
        window.contentView = root
    }

    private func heading() -> NSView {
        let title = label("Discover", size: 25, weight: .semibold, ink: .labelColor)
        let deck = label("Selected works from the built-in collection.", size: 13)
        let filters = NSStackView(views: [mood, motion, brightness])
        filters.spacing = 10
        for (control, name) in [(mood, "Mood"), (motion, "Motion"), (brightness, "Brightness")] {
            control.segmentStyle = .capsule
            control.controlSize = .small
            control.selectedSegment = 0
            control.target = self
            control.action = #selector(changeFilters)
            control.setAccessibilityLabel(name)
        }
        let stack = NSStackView(views: [title, deck, filters])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: deck)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 16, right: 24)
        return stack
    }

    @objc private func changeFilters() { rebuild() }

    private func rebuild() {
        stopHover()
        for view in shelves.arrangedSubviews { view.removeFromSuperview() }
        tiles.removeAll()
        rotationButtons.removeAll()
        var jobs: [RotationThumbnails.Job] = []
        for shelf in EditorialCatalog.shelves {
            let cards = shelf.pieces.compactMap { piece -> NSView? in
                guard let shader = installed[piece.entry], matchesFilters(piece) else { return nil }
                jobs.append(.init(entry: piece.entry, shader: shader))
                return card(piece, shader: shader)
            }
            guard !cards.isEmpty else { continue }
            let row = NSStackView(views: cards)
            row.alignment = .top
            row.spacing = 28
            let subtitle = label(shelf.placard, size: 12)
            let section = NSStackView(views: [label(shelf.title, size: 18, weight: .semibold, ink: .labelColor),
                                             subtitle, row])
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 5
            section.setCustomSpacing(13, after: subtitle)
            shelves.addArrangedSubview(section)
        }
        if jobs.isEmpty {
            shelves.addArrangedSubview(label("No installed works match these filters.", size: 13))
        }
        if let selection { showSelection(selection) }
        thumbnails.start(jobs, onImage: { [weak self] entry, image in self?.tiles[entry]?.image = image },
                         onProgress: { _, _ in }, onFinished: {})
        scroll.documentView?.layoutSubtreeIfNeeded()
        scroll.documentView?.scrollToBeginningOfDocument(nil)
    }

    private func matchesFilters(_ piece: EditorialCatalog.Piece) -> Bool {
        func matches(_ control: NSSegmentedControl, _ value: String) -> Bool {
            control.selectedSegment <= 0 || control.label(forSegment: control.selectedSegment) == value
        }
        return matches(mood, piece.mood.rawValue) && matches(motion, piece.motion.rawValue)
            && matches(brightness, piece.brightness.rawValue)
    }

    private func card(_ piece: EditorialCatalog.Piece, shader: LerpShader) -> NSView {
        let size = RotationTile.size(width: 150)
        let tile = RotationTile(entry: piece.entry, shaderTitle: piece.title, size: size, showsRotationBadge: false)
        tile.summary = ""
        tile.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        tile.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        tile.onOpen = { [weak self] entry in self?.open(entry) }
        tile.onHover = { [weak self] tile, inside in
            guard let self else { return }
            if inside, tile.window?.isKeyWindow == true { preview.want(tile, shader: shader) }
            else { preview.leave(tile) }
        }
        tiles[piece.entry] = tile

        let tags = [piece.mood.rawValue, piece.motion.rawValue, piece.brightness.rawValue].joined(separator: " · ")
        let note = NSTextField(wrappingLabelWithString: piece.placard)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 160
        let open = Chrome.button("Open in Tune", target: self, action: #selector(openCard(_:)))
        let add = Chrome.button("Add to Rotation", target: self, action: #selector(addCard(_:)))
        open.identifier = NSUserInterfaceItemIdentifier(piece.entry.key)
        rotationButtons[piece.entry] = add
        let details = NSStackView(views: [note, label(tags, size: 10), open, add])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 7
        details.setCustomSpacing(13, after: details.arrangedSubviews[1])
        details.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let card = NSStackView(views: [tile, details])
        card.alignment = .centerY
        card.spacing = 10
        return card
    }

    @objc private func openCard(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let entry = tiles.keys.first(where: { $0.key == key }) else { return }
        open(entry)
    }

    private func open(_ entry: LerpRotationEntry) {
        close()
        onOpen?(entry)
    }

    @objc private func addCard(_ sender: NSButton) {
        guard let entry = rotationButtons.first(where: { $0.value === sender })?.key else { return }
        do {
            if let selection = try onAdd?(entry) { showSelection(selection) }
        } catch {
            guard let window else { return }
            let alert = NSAlert(error: error)
            alert.beginSheetModal(for: window)
        }
    }

    @objc private func stopHover() { preview.stop() }
    func windowDidResignKey(_ notification: Notification) { stopHover() }
    func windowWillClose(_ notification: Notification) { stopHover(); thumbnails.cancel() }

    private func label(_ title: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       ink: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = Chrome.label(title, size: size, color: ink)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}
