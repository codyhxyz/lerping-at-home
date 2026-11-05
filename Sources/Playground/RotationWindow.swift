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
/// asking to go and edit a look, and `onChange`, a click that changed the
/// rotation. The editor window is what writes it — for this grid and the
/// toolbar popover's alike — so there is one save path in the playground, and
/// it is also what brings the other grid up to date.
final class RotationWindowController: NSWindowController, NSWindowDelegate {

    let gallery = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
    private let thumbnails: RotationThumbnails
    private let defaults: UserDefaults?
    /// What the gallery was last built from, so an edit somewhere else in the
    /// app can be recognised as one shader changing rather than a reload.
    private var sourceFingerprint = ""

    /// A look was double-clicked: go and open it in the editor.
    var onOpen: ((LerpRotationEntry) -> Void)?
    /// The rotation changed here. The host saves it and shows it in the
    /// popover, which draws the same looks.
    var onChange: ((LerpRotationSelection) -> Void)?
    /// A still landed. Handed on so the popover's copy of the grid can show it
    /// too — the two share one `RotationThumbnails`, and a `start` supersedes
    /// the run in flight, so whichever run is live has to feed both.
    var onImage: ((LerpRotationEntry, NSImage) -> Void)?

    /// `defaults` is injected because this window edits the screensaver's
    /// ByHost domain rather than the playground's own preferences.
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
            // Capture mode builds real, laid-out views without showing them.
            window.hideForCapture()
        } else {
            window.setFrameAutosaveName("LerpRotationWindow")
        }

        gallery.onChange = { [weak self] selection in self?.onChange?(selection) }
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
        let fingerprint = RotationThumbnails.fingerprint(for: shaders)
        guard force || fingerprint != sourceFingerprint else { return }
        sourceFingerprint = fingerprint

        gallery.show(shaders: shaders,
                     selection: RotationStore.selection(discovered: shaders.rotationEntries(),
                                                        from: defaults))

        gallery.populate(
            using: thumbnails,
            jobs: RotationThumbnails.jobs(for: shaders),
            onImage: { [weak self] entry, image in self?.onImage?(entry, image) })
    }

    /// Someone else changed the rotation — the toolbar popover shows the same
    /// looks. Straight into the tiles, without going back out through
    /// `onChange`, because whoever changed it has already saved it.
    ///
    func showSelection(_ selection: LerpRotationSelection) {
        guard !gallery.entries.isEmpty else { return }
        gallery.show(shaders: gallery.shaders, selection: selection)
    }

    /// Marks the look the editor has open.
    func showCurrent(_ entry: LerpRotationEntry?) { gallery.showCurrent(entry) }

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
