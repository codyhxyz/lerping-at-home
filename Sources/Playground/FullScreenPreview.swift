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
    private var previousOptions: NSApplication.PresentationOptions = []

    var isShown: Bool { window != nil }
    /// After the view has moved either way — for the host to redraw a paused
    /// frame into a drawable that has just changed size.
    var onChange: (() -> Void)?

    init(view: NSView) {
        self.view = view
        let note = Chrome.label("Previewing full screen · Esc to return", size: 11.5)
        note.alignment = .center
        note.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
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
        window = preview

        view.removeFromSuperview()
        Self.pin(view, in: preview.contentView!)

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
        onChange?()
    }

    func hide() {
        guard let preview = window else { return }
        window = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        keyMonitor.map(NSEvent.removeMonitor)
        keyMonitor = nil

        view.removeFromSuperview()
        Self.pin(view, in: stage)
        preview.orderOut(nil)
        NSApp.presentationOptions = previousOptions
        stage.window?.makeKeyAndOrderFront(nil)
        onChange?()
    }

    func toggle(on screen: NSScreen) { isShown ? hide() : show(on: screen) }

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
