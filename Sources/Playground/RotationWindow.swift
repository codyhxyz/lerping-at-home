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
final class RotationWindowController: NSWindowController, NSWindowDelegate {

    let gallery = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
    private let thumbnails: RotationThumbnails
    private let defaults: UserDefaults?
    private let searchURLs: [URL]
    /// What the gallery was last built from, so an edit somewhere else in the
    /// app can be recognised as one shader changing rather than a reload.
    private var sourceFingerprint = ""
    /// The saved rotation as this window last saw it. A click writes against it
    /// rather than against nothing, so a gallery left open all afternoon cannot
    /// undo an Options… sheet that was pressed while it sat there. Updated on
    /// every load *and* every write, so this window is only ever one click
    /// behind at worst.
    private var base: LerpRotationState?

    /// Timings for the report and for `--selftest`.
    private(set) var lastLoadSeconds: Double = 0
    var thumbnailStats: (memory: Int, disk: Int, rendered: Int, failed: [String]) {
        (thumbnails.memoryHits, thumbnails.diskHits, thumbnails.rendered, thumbnails.failed)
    }

    /// `defaults` is injected so `--selftest` can point the whole thing at a
    /// throwaway ByHost domain instead of the user's screensaver settings.
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
        base = RotationStore.state(discovered: entries, from: defaults)
        gallery.show(shaders: shaders,
                     enabled: Set(LerpMetalView.Config.rotation(
                        of: RotationStore.load(discovered: entries, from: defaults),
                        from: entries)))

        let started = CFAbsoluteTimeGetCurrent()
        gallery.showProgress(done: 0, total: entries.count)
        thumbnails.start(RotationThumbnails.jobs(for: shaders),
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
        base = RotationStore.save(enabled, entries: gallery.entries, base: base, to: defaults)
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
