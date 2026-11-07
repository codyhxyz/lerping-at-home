import AppKit

/// The render on a whole screen, the way a video player's full-screen button
/// does it, until Esc: a look seen at the size the screensaver will show it,
/// with nothing of the editor around it.
///
/// The window's own `LerpMetalView` moves here rather than a second view being
/// made, so what fills the screen is exactly what the pane was drawing — the
/// same parameters, MIDI, hands and audio, on the same clock. A second view
/// would be a second renderer to keep in step, and a picture that could be
/// quietly different from the one being tuned.
///
/// Not `NSView.enterFullScreenMode`: it puts a view back with `addSubview`,
/// which takes it out of the pane's stack and drops its constraints. The view
/// sits in a `stage` instead, and leaves and returns to that.
final class FullScreenPreview {

    /// Where the view lives in the window. Shows a note while the view is away,
    /// which is only visible when the preview is on a different display.
    let stage = NSView()
    private let view: NSView
    private var window: PreviewWindow?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    /// The look's name, preset and "Esc to return" over the picture: shown on
    /// entering, on changing look, and when the mouse moves — then gone, like
    /// a video player's title.
    private let hud = PreviewHUD()
    private var hudFade: DispatchWorkItem?
    /// The look's still behind the stage's note, so the empty pane left behind
    /// on the other display still says what is playing.
    private let backdrop = StillBackdrop()
    private let note = NSTextField(labelWithString: "Previewing full screen · Esc to return")
    private var described: (name: String, preset: String?)?
    private var previousOptions: NSApplication.PresentationOptions = []

    var isShown: Bool { window != nil }
    /// After the view has moved either way — for the host to redraw a paused
    /// frame into a drawable that has just changed size.
    var onChange: (() -> Void)?

    init(view: NSView) {
        self.view = view
        Self.pin(backdrop, in: stage)

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        pill.layer?.cornerRadius = 15
        pill.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 12, weight: .medium)
        note.textColor = EditorTheme.text
        note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(note)
        stage.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: 30),
            note.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 16),
            note.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -16),
            note.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        Self.pin(view, in: stage)
    }

    func show(on screen: NSScreen) {
        guard window == nil else { return }
        let preview = PreviewWindow(contentRect: screen.frame, styleMask: .borderless,
                                    backing: .buffered, defer: false)
        preview.setFrame(screen.frame, display: false)
        preview.backgroundColor = .black
        preview.isReleasedWhenClosed = false
        preview.onExit = { [weak self] in self?.hide() }
        preview.contentView = NSView()
        preview.contentView?.wantsLayer = true
        preview.acceptsMouseMovedEvents = true
        window = preview

        view.removeFromSuperview()
        Self.pin(view, in: preview.contentView!)
        hud.place(in: preview.contentView!)

        previousOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        preview.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)

        // Temporary, so it never outlives your attention: switching to another
        // app ends it rather than leaving a black screen behind that app.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hide() })
        // Opening a shader from the keyboard can hand the key back to the
        // playground window behind; take it straight back.
        if let home = stage.window {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: home, queue: .main
            ) { [weak preview] _ in preview?.makeKey() })
        }
        // Esc wherever the key is, so it cannot land in the editor instead.
        // Plain typing is swallowed too — it would edit a buffer nobody can
        // see — while ⌘ shortcuts still reach the menus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isShown else { return event }
            if event.keyCode == 53 { hide(); return nil }
            return event.modifierFlags.contains(.command) ? event : nil
        }
        // Moving the mouse brings the title back, the way it brings back the
        // controls in a video player.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            if self?.isShown == true { self?.flashHUD() }
            return event
        }
        flashHUD()
        onChange?()
    }

    func hide() {
        guard let preview = window else { return }
        window = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil
        mouseMonitor.map(NSEvent.removeMonitor)
        mouseMonitor = nil
        hudFade?.cancel()
        hud.removeFromSuperview()

        view.removeFromSuperview()
        Self.pin(view, in: stage)
        preview.orderOut(nil)
        NSApp.presentationOptions = previousOptions
        stage.window?.makeKeyAndOrderFront(nil)
        onChange?()
    }

    func toggle(on screen: NSScreen) { isShown ? hide() : show(on: screen) }

    /// What is playing. A different look while full screen (⇧⌘] works there)
    /// shows the title again; a still arriving only updates the picture.
    func describe(name: String, preset: String?, still: NSImage?) {
        let changed = described.map { $0.name != name || $0.preset != preset } ?? true
        described = (name, preset)
        hud.show(name: name, preset: preset, still: still)
        backdrop.still = still
        note.stringValue = "Showing full screen: \(name)\(preset.map { " · \($0)" } ?? "")  ·  Esc to return"
        if changed, isShown { flashHUD() }
    }

    private func flashHUD() {
        hudFade?.cancel()
        if hud.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                hud.animator().alphaValue = 1
            }
        }
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.8
                self?.hud.animator().alphaValue = 0
            }
        }
        hudFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: fade)
    }

    private static func pin(_ view: NSView, in host: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

/// Borderless, so it has to be told it may take the keyboard. It never
/// becomes main, which keeps the playground window main:
/// menu commands with no target still find the window controller, so ⇧⌘[ / ]
/// change shader and ⌘\ pauses while the preview is up.
private final class PreviewWindow: NSWindow {
    var onExit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Double-click leaves full screen in every video player.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onExit?() } else { super.mouseDown(with: event) }
    }
}

/// The title card over the full-screen picture: the look's still, its name,
/// its preset, and how to get out.
private final class PreviewHUD: NSView {
    private let image = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.62).cgColor
        layer?.cornerRadius = 14
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        alphaValue = 0
        setAccessibilityIdentifier("preview-hud")

        image.imageScaling = .scaleAxesIndependently
        image.wantsLayer = true
        image.layer?.cornerRadius = 7
        image.layer?.masksToBounds = true
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.textColor = .white
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = NSColor(white: 1, alpha: 0.62)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let row = NSStackView(views: [image, text])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 18)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 72),
            image.heightAnchor.constraint(equalToConstant: 45),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(name: String, preset: String?, still: NSImage?) {
        self.name.stringValue = name
        detail.stringValue = (preset.map { "\($0)  ·  " } ?? "") + "Esc to return"
        image.image = still
        image.isHidden = still == nil
    }

    /// Bottom left, clear of the picture's middle, where a player puts its title.
    func place(in host: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 40),
            bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -40),
        ])
    }
}

/// The look's still, dimmed and cropped to fill, behind the stage's note.
private final class StillBackdrop: NSView {
    var still: NSImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        EditorTheme.background.setFill()
        bounds.fill()
        guard let still, still.size.width > 0, still.size.height > 0 else { return }
        let scale = max(bounds.width / still.size.width, bounds.height / still.size.height)
        let size = NSSize(width: still.size.width * scale, height: still.size.height * scale)
        still.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 0.32)
    }
}
