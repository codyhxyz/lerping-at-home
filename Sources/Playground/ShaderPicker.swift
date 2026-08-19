import AppKit

/// The toolbar's shader picker: the same grid of stills the rotation gallery
/// draws, in a popover hung off the button where a plain text dropdown used to be.
///
/// ## Why not keep the dropdown
///
/// The dropdown listed 123 looks as 123 lines of text. Names are not what a look
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
/// beats the carousel that was the other idea on the table: 123 items is too
/// many to walk past one at a time, and a carousel has nowhere to type.
///
/// ## Where New… went
///
/// The editor toolbar's New… button is the first card in this grid — see
/// `NewLookCard`. Asking for a shader that does not exist is what you do at the
/// end of looking through the ones that do, and that search happens in here; a
/// button on the bar behind the popover is a button you have to dismiss this to
/// reach, having just proved you needed it. Nothing else changes: the card runs
/// the same `newShader` the File menu's ⌘N runs, and it is not a look, so it
/// never joins the rotation, the counts, or the arrows.
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
    /// The "+" card was clicked: make a shader there is no look for yet.
    var onNew: (() -> Void)?
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
    /// Everything the grid is currently drawn from: the shaders, the rotation,
    /// and which look is open. See `prepare` for why the grid is keyed on all
    /// three rather than on the shaders alone.
    private var loadedStamp = ""

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
        gallery.onNew = { [weak self] in
            self?.close()
            // Same close a chosen look gets, but the answer to this one is a
            // modal alert asking for the name. Entering a modal loop in the same
            // turn strands the popover on screen behind the alert until it is
            // dismissed, because the close is an animation and the modal loop
            // does not run it — so the close gets this turn and the question is
            // asked on the next one.
            DispatchQueue.main.async { self?.onNew?() }
        }
    }

    // MARK: - Content

    /// Fills the grid and starts its stills before presentation.
    ///
    /// A no-op when the shaders, the rotation and the open look are all as they
    /// were. That guard is not an optimisation — it is what makes the popover
    /// usable at all.
    ///
    /// `PlaygroundWindowController.pollDisk` runs every 1.5 s, and while the
    /// popover is up it called this every time. `RotationGalleryView.show`
    /// begins by stopping the shared preview player, because the tiles it is
    /// about to rebuild may be the one holding the live view — so pointing at a
    /// tile started a preview that was torn down again a second and a half
    /// later, for ever, and the rotation state on screen was re-read from disk
    /// underneath the pointer just as often. The gallery *window* never had this
    /// because its own `load` is fingerprinted; this is the same guard, widened
    /// to the two other things the grid draws from.
    func prepare(shaders: [LerpShader], enabled: Set<LerpRotationEntry>,
                 current: LerpRotationEntry?) {
        let fingerprint = RotationThumbnails.fingerprint(for: shaders)
        let stamp = [fingerprint,
                     enabled.map(\.key).sorted().joined(separator: ","),
                     current?.key ?? ""].joined(separator: "\u{1}")
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp

        gallery.show(shaders: shaders, enabled: enabled)
        gallery.showCurrent(current)
        guard fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        gallery.populate(
            using: thumbnails,
            jobs: RotationThumbnails.jobs(for: shaders),
            onImage: { [weak self] entry, image in self?.onImage?(entry, image) })
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
