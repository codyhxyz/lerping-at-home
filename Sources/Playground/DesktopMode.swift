import AppKit

/// Shader › Desktop Mode: the look the playground has open, playing behind
/// the desktop icons on every screen — over the desktop picture, under every
/// window — for as long as the toggle is on and the playground is running.
///
/// **Windows, not wallpaper.** Nothing here touches the desktop picture: no
/// `NSWorkspace.setDesktopImageURL`, no `com.apple.wallpaper` plists, no
/// aerials, no `killall`. Each screen gets one borderless window at the level
/// just under the desktop icons, and those windows belong to this process, so
/// quitting — or crashing — takes them with it and leaves the desktop exactly
/// as it was. That is the whole reason this lives in the playground and not
/// in the saver: the saver is a sandboxed, ephemeral guest of
/// `legacyScreenSaver`, and a guest making permanent global mutations is what
/// pinned the lock screen to a removed shader for three weeks (see the comment
/// where the desktop-picture code used to be, in `LerpSaverView`).
///
/// **One look, mirrored.** Each desktop window has its own `LerpMetalView` —
/// one view cannot be on two screens — and every tick they are brought in step
/// with the playground's view: the shader as it compiled (unsaved edits
/// included), the preset it wears, and every parameter value, drift and
/// taken-over drift. Whatever moved them — a slider, a preset, a MIDI knob,
/// a hand, a hot reload — the desktop follows, because it reads the view
/// rather than listening to each of the things that write it. Live inputs are
/// forwarded the same way: the desktop sees the playground's head tracker and
/// system audio, through the same `LiveInput`s.
///
/// **What it costs.** `AmbientSurfacePolicy` holds covered, sleeping or
/// power-constrained windows on their last frame. A held window does not
/// read live inputs, and the mirror timer stops when all windows are held.
///
/// Not final only so a headless harness can keep its windows transparent and
/// its GPU idle (`makeWindow`, `heldBackReason`).
@MainActor
class DesktopMode {

    /// Just under the desktop icons: above the desktop picture, below Finder's
    /// icons and every ordinary window.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

    /// The playground's own view: what the desktop mirrors.
    private let source: LerpMetalView
    /// The head tracker, if Track Head is on. Asked rather than told, so the
    /// window controller's start and stop stay the only place one is made.
    var headTracker: () -> HeadTracker? = { nil }
    /// A passing note on the playground's status line.
    var onStatus: (String) -> Void = { _ in }
    /// Optional hook for pausing/resuming the editor-owned audio tap while
    /// neither the editor nor an active desktop window needs it. Desktop
    /// rendering itself never reads audio or camera when held.
    var setAudioInputNeeded: (Bool) -> Void = { _ in }
    private var audioInputNeeded = true

    private(set) var isOn = false
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    private let policy = AmbientSurfacePolicy.shared
    private var timer: Timer?
    private var mirrors: [CGDirectDisplayID: Mirror] = [:]
    /// Why the desktop is holding still, or nil while it plays.
    private var heldBack: String?
    /// The tracker this paused, and only that one: a tracker turned off and on
    /// again in the meantime is a different object and is not ours to resume.
    private weak var pausedTracker: HeadTracker?

    /// How often the desktop checks the playground's view for a change. A
    /// dragged slider reaches the desktop within this.
    private static let syncInterval: TimeInterval = 0.1

    /// `owner` is the playground window: closing it quits the app, and the
    /// desktop windows must not be what keeps it alive.
    init(source: LerpMetalView, owner: NSWindow?) {
        self.source = source
        ownerObserver = owner.map {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: $0, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.turnOff() } }
        }
    }

    private var ownerObserver: NSObjectProtocol?

    deinit {
        ownerObserver.map(NotificationCenter.default.removeObserver)
        timer?.invalidate()
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        let windows = Array(windows.values)
        DispatchQueue.main.async {
            for window in windows {
                window.view?.stop()
                window.close()
            }
        }
    }

    /// The menu item. Says what happened on the status line.
    func toggle() {
        if isOn {
            turnOff()
            onStatus("Desktop Mode off")
        } else {
            turnOn()
            let look = source.currentEntry.map { entry in
                entry.shader + (entry.preset.map { " · \($0)" } ?? "")
            } ?? "the open look"
            let screens = windows.count == 1 ? "" : " on \(windows.count) screens"
            onStatus("Desktop Mode on: \(look) behind your windows\(screens)"
                     + (heldBack.map { " (holding still: \($0))" } ?? ""))
        }
    }

    func turnOn() {
        guard !isOn else { return }
        isOn = true
        heldBack = heldBackReason()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileScreens() }
            },
            // Any window: the desktop's own, and whichever window the
            // playground's view is in now (its pane, or the full-screen preview).
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
            center.addObserver(forName: AmbientSurfacePolicy.didChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
        // The window server can lose a desktop-level window's place across
        // display sleep; put it back.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windows.values.forEach { $0.level = Self.level; $0.orderFrontRegardless() }
                    self?.refresh()
                }
            })
        }
        reconcileScreens()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        timer?.invalidate()
        timer = nil
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in observers {
            center.removeObserver(observer)
            workspace.removeObserver(observer)
        }
        observers = []
        for window in windows.values { close(window) }
        windows = [:]
        mirrors.removeAll()
        heldBack = nil
        if !audioInputNeeded {
            audioInputNeeded = true
            setAudioInputNeeded(true)
        }
        // Whatever this paused goes back to how the user left it.
        if let tracker = pausedTracker, tracker === headTracker() { tracker.resume() }
        pausedTracker = nil
    }

    // MARK: - Screens

    /// One window per screen, each covering the whole of it, menu bar and all.
    private func reconcileScreens() {
        guard isOn else { return }
        var seen = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            guard let id = Self.displayID(of: screen) else { continue }
            seen.insert(id)
            if let window = windows[id] {
                if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
            } else if let window = makeWindow(for: screen) {
                windows[id] = window
                window.orderFrontRegardless()
            }
        }
        for (id, window) in windows where !seen.contains(id) {
            windows[id] = nil
            mirrors[id] = nil
            close(window)
        }
        refresh()
    }

    /// A desktop window for `screen`, not yet ordered in. Nil when Metal will
    /// not make a view.
    func makeWindow(for screen: NSScreen) -> DesktopWindow? {
        guard let view = LerpMetalView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                       extraSearchURLs: RepoLocation.searchURLs) else { return nil }
        // Never the schedule: until a look is given it, the view has none, and
        // `refresh` will not start a view with nothing to show (a bare
        // `start()` would pick from the screensaver rotation instead).
        view.config = LerpMetalView.Config(shaderName: nil, renderScale: source.config.renderScale,
                                           shuffleInterval: .infinity)
        view.config.extendedDynamicRange = source.config.extendedDynamicRange
        view.config.edrPeak = source.config.edrPeak
        view.onCompileError = { name, message in
            FileHandle.standardError.write(Data("desktop mode: compile error in \(name):\n\(message)\n".utf8))
        }
        // Read through the playground's view, so turning Track Head or system
        // audio on or off there reaches the desktop with no wiring of its own.
        view.viewer = { [weak source] in source?.viewer?() ?? .centered }
        view.audioLevels = { [weak source] in source?.audioLevels?() ?? .silent }
        // In step with the views already up, or with the playground's.
        let clock = windows.values.first?.view ?? source
        view.seed = clock.seed
        view.time = clock.time

        let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless,
                                   backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = Self.level
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        // ⌘H hides the playground, not its desktop.
        window.canHide = false
        window.isMovable = false
        window.animationBehavior = .none
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        return window
    }

    private func close(_ window: DesktopWindow) {
        window.view?.stop()
        window.orderOut(nil)
        window.close()
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        AmbientSurfacePolicy.displayID(of: screen)
    }

    // MARK: - Mirroring

    /// Everything that makes the look *that* look, short of its parameter
    /// values: the source as compiled — which may be an unsaved draft — and
    /// the preset it wears.
    private struct LookKey: Equatable {
        var shader: String
        var source: String
        var entry: LerpRotationEntry
    }

    private struct Mirror {
        var look: LookKey?
        var values: LerpParameterValues?
    }

    /// Held windows keep their own last frame. On waking, each catches up
    /// against what *it* last mirrored, not what another screen has seen.
    private func sync(_ view: LerpMetalView, display: CGDirectDisplayID) {
        guard let shader = source.currentShader, let entry = source.currentEntry else { return }
        var mirror = mirrors[display] ?? Mirror()
        let key = LookKey(shader: shader.name, source: shader.source, entry: entry)
        if key != mirror.look {
            if key.source != mirror.look?.source || key.shader != mirror.look?.shader {
                view.shaderLibrary.clearPipelineCache()
            }
            mirror.look = key
            mirror.values = nil
            mirrors[display] = mirror
            guard view.show(entry, of: shader) else { return }
        } else if view.currentShader?.source != key.source || view.currentEntry != entry {
            return // The current snapshot failed to compile on this display.
        }
        if let values = source.parameterValues, mirror.values.map({ !Self.same(values, $0) }) ?? true {
            Self.copy(values, into: view)
            mirror.values = values
        }
        mirrors[display] = mirror
        if view.captionHeld != source.captionHeld { view.captionHeld = source.captionHeld }
    }

    /// Makes `view`'s values exactly `values`: the same held values, the same
    /// drifts, and the same of them taken over. `show` has already given the
    /// view the look's own drifts; any the playground added go on first, then
    /// the values (which pins whatever is animated), then each drift is let
    /// go or held as it is in the playground.
    static func copy(_ values: LerpParameterValues, into view: LerpMetalView) {
        for (name, animation) in values.animations where view.parameterValues?.animations[name] != animation {
            view.animateParameter(name, with: animation)
        }
        for (name, value) in values.values { view.setParameter(name, value) }
        for name in values.animations.keys { view.setParameterAnimating(name, values.isAnimating(name)) }
    }

    /// Whether two sets of values are the same state — held values, drifts and
    /// which drifts are held — not merely the same frame.
    static func same(_ a: LerpParameterValues, _ b: LerpParameterValues) -> Bool {
        a.parameters == b.parameters && a.values == b.values
            && a.animations == b.animations && a.pinned == b.pinned
    }

    // MARK: - Power

    /// Why the desktop should hold still right now, or nil to play.
    func heldBackReason() -> String? { policy.systemHold?.rawValue }

    private func decision(for window: DesktopWindow, display: CGDirectDisplayID) -> AmbientSurfacePolicy.Decision {
        policy.decision(display: display, visible: window.occlusionState.contains(.visible))
    }

    private func refresh() {
        guard isOn else { return }
        let reason = heldBackReason()
        if reason != heldBack {
            heldBack = reason
            onStatus(reason.map { "Desktop Mode holding still: \($0)" } ?? "Desktop Mode playing again")
        }
        var shouldPoll = false
        for (display, window) in windows {
            guard let view = window.view else { continue }
            let decision = decision(for: window, display: display)
            guard reason == nil, decision.hold == nil else { view.stop(); continue }
            shouldPoll = true
            let scale = decision.renderScale(source.config.renderScale)
            let edr = decision.extendedDynamicRange(source.config.extendedDynamicRange)
            if view.config.renderScale != scale { view.config.renderScale = scale }
            if view.config.extendedDynamicRange != edr { view.config.extendedDynamicRange = edr }
            sync(view, display: display)
            if view.currentEntry != nil { view.start() }
        }
        updateInputs()
        if shouldPoll, timer == nil {
            let timer = Timer(timeInterval: Self.syncInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !shouldPoll {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Camera

    /// Whether any desktop window can be seen right now and is playing.
    var desktopIsVisible: Bool {
        heldBack == nil && windows.contains { decision(for: $0.value, display: $0.key).hold == nil }
    }

    /// The camera stays on only while something it steers is on screen: a
    /// desktop window, or the playground's own view (in its pane or the
    /// full-screen preview). Under a full-screen app, on a locked or sleeping
    /// screen, it is let go — the green light goes off — and taken back when
    /// either comes into view again. The playground's own Track Head start
    /// and stop are untouched; this only pauses the tracker they made.
    private func updateInputs() {
        let editor = source.window
        let editorVisible = editor?.occlusionState.contains(.visible) == true
            && !policy.isDisplayAsleep(editor?.screen.flatMap(Self.displayID))
        let wanted = desktopIsVisible || editorVisible
        if wanted != audioInputNeeded {
            audioInputNeeded = wanted
            setAudioInputNeeded(wanted)
        }
        guard let tracker = headTracker() else {
            pausedTracker = nil
            return
        }
        // Track Head was turned off and on again: that tracker is running
        // because the user just asked, and the old one is not ours to resume.
        if let paused = pausedTracker, paused !== tracker { pausedTracker = nil }
        if !wanted, pausedTracker == nil {
            tracker.stop()
            pausedTracker = tracker
            onStatus("Camera paused: nothing that follows your head is on screen")
        } else if wanted, pausedTracker != nil {
            pausedTracker = nil
            tracker.resume()
            onStatus("Camera back on")
        }
    }
}

/// A desktop window: never key, never main, never moved, and drawn exactly
/// over its screen, menu bar included.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// A borderless window may cover the menu bar; do not let AppKit nudge it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var view: LerpMetalView? { contentView as? LerpMetalView }
}
