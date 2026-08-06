import AppKit

/// The toolbar's shader picker: the same grid of stills the rotation gallery
/// draws, in a popover hung off the button where a plain text dropdown used to be.
///
/// ## Why not keep the dropdown
///
/// The dropdown listed 114 looks as 114 lines of text. Names are not what a look
/// is — `voronoi/Molten` tells you nothing — and the gallery had already solved
/// that problem next door with a picture per look. Two lists of the same thing,
/// one of which you can actually read, is one too many.
///
/// ## Why not merge it into the gallery either
///
/// They are different questions asked of the same set. The gallery asks *which
/// of these should the screensaver shuffle through*; the picker asks *which one
/// do I want to edit*. So this is the same tile component with its primary
/// action inverted — a click opens, the corner badge toggles the rotation — and
/// `RotationTile.Mode` is the whole of the difference. See the comment on that
/// type for the reasoning; the short version is that each surface makes its own
/// job one click and the other one deliberate.
///
/// A look that is *out* of the rotation is drawn dimmed and opens on exactly the
/// same click as any other. Not shuffling a look is no reason to be unable to
/// edit it — quite the opposite, since the usual reason a look is out of the
/// rotation is that you are still working on it.
///
/// ## What the dropdown did better, and is kept
///
/// Typing. A menu gives you type-select for free and a grid of pictures does
/// not, so the popover opens with the caret already in the filter field and ⏎
/// opens the first look still showing. That is `RotationGalleryView`'s doing —
/// see `control(_:textView:doCommandBy:)` — and it is the reason the popover
/// beats the carousel that was the other idea on the table: 114 items is too
/// many to walk past one at a time, and a carousel has nowhere to type.
final class ShaderPicker: NSObject, NSPopoverDelegate {

    /// Narrower than the gallery window's tile, because this is a popover and
    /// not a window: small enough that two or three shaders' groups sit side by
    /// side on a band, big enough that a still is still a picture of something.
    static let tileWidth: CGFloat = 96
    static let contentSize = NSSize(width: 900, height: 620)

    let gallery = RotationGalleryView(
        frame: NSRect(origin: .zero, size: ShaderPicker.contentSize),
        tileSize: RotationTile.size(width: ShaderPicker.tileWidth),
        showsRegenerate: false,
        mode: .picker)

    /// Open this look in the editor.
    var onOpen: ((LerpRotationEntry) -> Void)?
    /// The rotation was changed from here. The host writes it and tells the
    /// gallery window, which is showing the same looks.
    var onChange: ((Set<LerpRotationEntry>) -> Void)?
    /// A still landed. See `RotationWindowController.onImage`: one
    /// `RotationThumbnails` feeds both grids, so whichever run is live delivers
    /// to both.
    var onImage: ((LerpRotationEntry, NSImage) -> Void)?

    private let thumbnails: RotationThumbnails
    private let popover = NSPopover()
    private var loadedFingerprint = ""

    init(thumbnails: RotationThumbnails) {
        self.thumbnails = thumbnails
        super.init()
        let controller = NSViewController()
        controller.view = gallery
        popover.contentViewController = controller
        popover.contentSize = Self.contentSize
        // Transient: clicking anywhere else, or Escape, puts it away. Picking a
        // shader is a glance and a click, not a mode.
        popover.behavior = .transient
        popover.delegate = self
        gallery.onOpen = { [weak self] entry in
            self?.close()
            self?.onOpen?(entry)
        }
        gallery.onChange = { [weak self] enabled in self?.onChange?(enabled) }
    }

    // MARK: - Content

    /// Fills the grid in and starts the stills. Separate from `present` so the
    /// content can be built, driven and looked at without a popover on anyone's
    /// screen — which is exactly what `--selftest` does.
    func prepare(shaders: [LerpShader], enabled: Set<LerpRotationEntry>,
                 current: LerpRotationEntry?) {
        gallery.show(shaders: shaders, enabled: enabled)
        gallery.showCurrent(current)
        let fingerprint = shaders.map { $0.name + ":" + RotationThumbnails.hash($0.source) }
            .joined(separator: ",")
        guard fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        let jobs = RotationThumbnails.jobs(for: shaders)
        gallery.showProgress(done: 0, total: jobs.count)
        thumbnails.start(jobs,
                         onImage: { [weak self] entry, image in
                             self?.gallery.show(image: image, for: entry)
                             self?.onImage?(entry, image)
                         },
                         onProgress: { [weak self] done, total in
                             self?.gallery.showProgress(done: done, total: total)
                         },
                         onFinished: {})
    }

    /// Someone else changed the rotation. Straight into the tiles; nothing goes
    /// back out through `onChange`.
    func showEnabled(_ enabled: Set<LerpRotationEntry>) {
        guard !gallery.entries.isEmpty else { return }
        gallery.show(shaders: gallery.shaders, enabled: enabled)
    }

    func showImage(_ image: NSImage, for entry: LerpRotationEntry) {
        gallery.show(image: image, for: entry)
    }

    // MARK: - Presentation

    var isShown: Bool { popover.isShown }

    /// Test hook: what the popover would put on screen, without putting it
    /// there. `--selftest` cannot present one — an `NSPopover` is a real window
    /// and that run is deliberately invisible — so this is how a popover wired
    /// to the wrong view, or left modal, is still caught.
    var popoverWiring: (content: NSView?, behavior: NSPopover.Behavior, size: NSSize) {
        (popover.contentViewController?.view, popover.behavior, popover.contentSize)
    }

    func present(from view: NSView) {
        guard !popover.isShown else { return close() }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        // The caret goes in the filter field, so the first thing that works is
        // typing — the one habit the dropdown this replaced was better at.
        gallery.focusSearch()
    }

    func close() {
        gallery.preview.stop()
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        // Nothing may be left animating behind a popover that is gone.
        gallery.preview.stop()
        gallery.setFilter("")
    }
}
