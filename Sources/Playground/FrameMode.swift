import AppKit

/// A normal, independent borderless window on one display. Unlike Desktop
/// Mode it never reads the editor's view, and unlike full-screen preview it
/// never takes it away or changes application presentation options.
@MainActor
final class FrameMode {
    struct Look {
        var entry: LerpRotationEntry
        var placard: LerpMuseumPlacard? = nil
    }

    enum Failure: LocalizedError {
        case noDisplay, noMetal, invalidSequence, missingLook(String), compile(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "That display is no longer available."
            case .noMetal: return "Metal is unavailable."
            case .invalidSequence: return "Choose at least one committed look and a positive dwell time."
            case .missingLook(let key): return "The committed look \(key) was not found."
            case .compile(let key): return "The frame could not load \(key)."
            }
        }
    }

    private struct Resolved {
        let entry: LerpRotationEntry
        let shader: LerpShader
        let placard: LerpMuseumPlacard
    }

    private let policy = AmbientSurfacePolicy.shared
    private let extraSearchURLs: [URL]
    private var window: FrameWindow?
    private var view: LerpMetalView?
    private var placard: FramePlacard?
    private var reveal: TransientOverlay?
    private var observers: [NSObjectProtocol] = []
    private var turn: Timer?
    private var looks: [Resolved] = []
    private var index = 0
    private var dwell: TimeInterval = 0
    private var nextLookAt: TimeInterval = 0
    private var preferredEDR = true
    private(set) var displayID: CGDirectDisplayID?
    var isOn: Bool { window != nil }
    var onStop: () -> Void = {}
    var onCompileError: (String, String) -> Void = { _, _ in }

    init(extraSearchURLs: [URL] = RepoLocation.searchURLs) {
        self.extraSearchURLs = extraSearchURLs
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        turn?.invalidate()
        if let window, let view {
            DispatchQueue.main.async {
                view.stop()
                window.close()
            }
        }
    }

    /// `nil` uses the supplied editor display, then AppKit's selected display.
    /// Entries resolve from the shader library on entry; editor drafts and
    /// subsequent disk edits cannot alter a frame that is already playing.
    func start(_ sequence: [Look], on display: CGDirectDisplayID? = nil,
               selectedScreen: NSScreen? = nil, dwell seconds: TimeInterval = 60,
               extendedDynamicRange: Bool = true) throws {
        guard !sequence.isEmpty, seconds.isFinite, seconds > 0 else { throw Failure.invalidSequence }
        guard let id = display ?? (selectedScreen ?? NSScreen.main).flatMap(AmbientSurfacePolicy.displayID),
              let screen = Self.screen(with: id) else { throw Failure.noDisplay }
        guard let view = LerpMetalView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       extraSearchURLs: extraSearchURLs, mode: .still) else { throw Failure.noMetal }
        let library = view.shaderLibrary
        let shaders = library.discover()
        let resolved = try sequence.map { look in
            let entry = look.entry
            guard let shader = shaders.first(where: { $0.name == entry.shader }),
                  entry.preset.map({ name in shader.presets.contains { $0.name.utf8.elementsEqual(name.utf8) } }) ?? true else {
                throw Failure.missingLook(entry.key)
            }
            return Resolved(entry: entry, shader: shader,
                            placard: look.placard ?? LerpMuseumPlacard(shader: shader, preset: entry.preset))
        }

        view.config = LerpMetalView.Config(shuffleInterval: .infinity)
        view.onCompileError = { [weak self] in self?.onCompileError($0, $1) }
        guard view.show(resolved[0].entry, of: resolved[0].shader) else {
            throw Failure.compile(resolved[0].entry.key)
        }
        stop()
        looks = resolved
        index = 0
        dwell = seconds
        nextLookAt = seconds
        preferredEDR = extendedDynamicRange
        displayID = id
        self.view = view

        let window = FrameWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .normal
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        window.animationBehavior = .none
        window.onExit = { [weak self] in self?.stop() }
        window.onReveal = { [weak self] in self?.revealPlacard() }
        let host = NSView(frame: view.frame)
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        let placard = FramePlacard(in: host)
        placard.describe(resolved[0].placard)
        self.placard = placard
        let reveal = TransientOverlay(view: placard, linger: 4)
        reveal.setPaused(true)
        self.reveal = reveal
        window.contentView = host
        self.window = window

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: AmbientSurfacePolicy.didChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.screenChanged() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.windowWillClose() }
            },
        ]
        revealPlacard()
        // No makeKey: the editor can keep the keyboard on another display.
        window.orderFrontRegardless()
        refresh()
    }

    /// Also bound to Space in the frame window. Escape closes only this window.
    func revealPlacard() { reveal?.flash() }

    func stop() {
        guard let window else { return }
        tearDown()
        window.close()
        onStop()
    }

    private func windowWillClose() {
        guard window != nil else { return }
        tearDown()
        onStop()
    }

    private func tearDown() {
        window = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        turn?.invalidate()
        turn = nil
        reveal?.reset()
        reveal = nil
        placard = nil
        view?.stop()
        view = nil
        looks.removeAll()
        displayID = nil
    }

    private static func screen(with id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { AmbientSurfacePolicy.displayID(of: $0) == id }
    }

    private func screenChanged() {
        guard let window, let displayID else { return }
        guard let screen = Self.screen(with: displayID) else { stop(); return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        refresh()
    }

    private func refresh() {
        guard let window, let view else { return }
        let decision = policy.decision(display: displayID, visible: window.occlusionState.contains(.visible))
        reveal?.setPaused(decision.hold != nil)
        guard decision.hold == nil else {
            view.stop()
            turn?.invalidate()
            turn = nil
            return
        }
        let scale = decision.renderScale(1)
        let edr = decision.extendedDynamicRange(preferredEDR)
        if view.config.renderScale != scale { view.config.renderScale = scale }
        if view.config.extendedDynamicRange != edr { view.config.extendedDynamicRange = edr }
        view.start()
        scheduleTurn()
    }

    private func scheduleTurn() {
        guard looks.count > 1, turn == nil, let view else { return }
        // Dwell is on the shader's clock, which is held while the frame is.
        let timer = Timer(timeInterval: max(0.01, nextLookAt - view.time), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        turn = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advance() {
        turn = nil
        guard let window, let view, !looks.isEmpty,
              policy.decision(display: displayID, visible: window.occlusionState.contains(.visible)).hold == nil else {
            refresh()
            return
        }
        for offset in 1..<looks.count {
            let next = (index + offset) % looks.count
            let look = looks[next]
            if view.show(look.entry, of: look.shader) {
                index = next
                placard?.describe(look.placard)
                revealPlacard()
                break
            }
        }
        nextLookAt = view.time + dwell
        scheduleTurn()
    }
}

private final class FrameWindow: NSWindow {
    var onExit: (() -> Void)?
    var onReveal: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { onExit?(); return }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                if !event.isARepeat { onReveal?() }
                return
            }
        }
        super.sendEvent(event)
    }
}

private final class FramePlacard: NSView {
    private let title = NSTextField(labelWithString: "")
    private let artist = NSTextField(labelWithString: "")
    private let remix = NSTextField(labelWithString: "")

    init(in host: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.68).cgColor
        layer?.cornerRadius = 10
        setAccessibilityIdentifier("frame-placard")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        for label in [artist, remix] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = NSColor(white: 1, alpha: 0.78)
        }
        for label in [title, artist, remix] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [title, artist, remix])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        host.addSubview(self, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 40),
            bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -40),
            trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func describe(_ placard: LerpMuseumPlacard) {
        title.stringValue = placard.title
        artist.stringValue = placard.artist
        remix.stringValue = placard.remixLine ?? ""
        remix.isHidden = placard.remixLine == nil
    }
}
