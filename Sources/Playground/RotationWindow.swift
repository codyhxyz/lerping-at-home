import AppKit

/// A window of its own for the rotation gallery: it is a different job from
/// editing a shader, it wants the width, and the playground's three-pane layout
/// has no room to spare.
///
/// The gallery itself (`RotationGalleryView`) and its stills
/// (`RotationThumbnails`) live in `LerpCore`, because the screensaver's own
/// Options… sheet draws the same gallery and cannot see `Sources/Playground`.
/// What stays here is the part that is the playground's alone: a window, and
/// `RotationStore` — writing the screensaver's rotation the moment you click,
/// with no OK button, because there is nothing to confirm.
///
/// Two things leave through callbacks rather than being done here, because both
/// belong to the editor window and not to this one: `onOpen`, a double-click
/// asking to go and edit a look, and `onChange`, so the toolbar popover showing
/// the same 123 tiles can be kept in step with what was just clicked.
final class RotationWindowController: NSWindowController, NSWindowDelegate {

    let gallery = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
    private let thumbnails: RotationThumbnails
    private let defaults: UserDefaults?
    /// What the gallery was last built from, so an edit somewhere else in the
    /// app can be recognised as one shader changing rather than a reload.
    private var sourceFingerprint = ""
    /// The saved rotation as this window last saw it. A click writes against it
    /// rather than against nothing, so a gallery left open all afternoon cannot
    /// undo an Options… sheet that was pressed while it sat there. Updated on
    /// every load *and* every write, so this window is only ever one click
    /// behind at worst.
    private var base: LerpRotationState?

    /// A look was double-clicked: go and open it in the editor.
    var onOpen: ((LerpRotationEntry) -> Void)?
    /// The rotation changed here. The editor's popover shows the same set, and
    /// takes the state written with it so its own writes stay unstale too.
    var onChange: ((Set<LerpRotationEntry>, LerpRotationState?) -> Void)?
    /// A still landed. Handed on so the popover's copy of the grid can show it
    /// too — the two share one `RotationThumbnails`, and a `start` supersedes
    /// the run in flight, so whichever run is live has to feed both.
    var onImage: ((LerpRotationEntry, NSImage) -> Void)?

    /// Timings for the report and for `--selftest`.
    private(set) var lastLoadSeconds: Double = 0
    var thumbnailStats: (memory: Int, disk: Int, rendered: Int, failed: [String]) {
        (thumbnails.memoryHits, thumbnails.diskHits, thumbnails.rendered, thumbnails.failed)
    }

    /// What the screensaver's saved rotation comes to for these looks, and the
    /// state it was read from — the one spelling of it the playground uses, so
    /// the gallery window and the toolbar popover cannot come up disagreeing
    /// about what is in.
    ///
    /// The state comes back alongside because both surfaces write, and a writer
    /// that does not know what it read cannot merge against a newer one. Every
    /// caller of this is a window with a checkbox in it, so every caller needs
    /// it; handing back only the set is what let the popover write blind.
    static func enabled(for entries: [LerpRotationEntry],
                        in defaults: UserDefaults?)
        -> (looks: Set<LerpRotationEntry>, base: LerpRotationState) {
        let state = RotationStore.state(discovered: entries, from: defaults)
        return (Set(LerpMetalView.Config.rotation(
                        of: LerpRotation.enabled(discovered: entries, in: state),
                        from: entries)),
                state)
    }

    /// `defaults` is injected so `--selftest` can point the whole thing at a
    /// throwaway ByHost domain instead of the user's screensaver settings.
    init(searchURLs: [URL], defaults: UserDefaults?, hidden: Bool,
         thumbnails: RotationThumbnails? = nil) {
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

        gallery.onChange = { [weak self] enabled in
            self?.persist(enabled)
            self?.onChange?(enabled, self?.base)
        }
        gallery.onOpen = { [weak self] entry in self?.onOpen?(entry) }
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
        let saved = Self.enabled(for: entries, in: defaults)
        base = saved.base
        gallery.show(shaders: shaders, enabled: saved.looks)

        let started = CFAbsoluteTimeGetCurrent()
        gallery.populate(
            using: thumbnails,
            jobs: RotationThumbnails.jobs(for: shaders),
            onImage: { [weak self] entry, image in self?.onImage?(entry, image) },
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

    /// Someone else changed the rotation — the toolbar popover shows the same
    /// looks. Straight into the tiles, without going back out through
    /// `onChange`, because whoever changed it has already saved it.
    ///
    /// `base` is the state they wrote, adopted as this window's own. Without it
    /// this window would go on writing against the revision it read at load, so
    /// every later click here would take the stale-writer branch — correct, but
    /// only by way of the merge, for the rest of the session. Adopted before the
    /// guard: a gallery that has not loaded its tiles yet still has a base.
    func showEnabled(_ enabled: Set<LerpRotationEntry>, base: LerpRotationState?) {
        if let base { self.base = base }
        guard !gallery.entries.isEmpty else { return }
        gallery.show(shaders: gallery.shaders, enabled: enabled)
    }

    /// Marks the look the editor has open.
    func showCurrent(_ entry: LerpRotationEntry?) { gallery.showCurrent(entry) }

    /// The whole point of the feature: a click writes the screensaver's own
    /// rotation, in the screensaver's own domain, immediately.
    private func persist(_ enabled: Set<LerpRotationEntry>) {
        base = RotationStore.save(enabled, entries: gallery.entries, base: base, to: defaults)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close(cancellingWork: Bool) {
        if cancellingWork { thumbnails.cancel() }
        gallery.preview.stop()
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        thumbnails.cancel()
        gallery.preview.stop()
    }
}
