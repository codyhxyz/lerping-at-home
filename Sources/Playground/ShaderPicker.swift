import AppKit

/// The selector: the toolbar's shader button opens this popover, a Library of
/// one card per shader.
///
/// ## One job per control
///
/// The playground navigates with three controls and each has one job:
///
/// - **This popover** picks a shader, and switches whole shaders in or out of
///   the screensaver (the badge on each card; All / None in the header).
/// - **‹ ›** beside the button step to the previous or next shader without
///   opening this.
/// - **The inspector's Presets list** picks one of the open shader's presets,
///   ticks each in or out of the screensaver, and saves new ones.
///
/// It used to be messier: every card had a "Looks" drawer of preset tiles,
/// the arrows walked all ~280 shader×preset pairs, the inspector had its own
/// preset popup, and a separate Rotation window drew the same grid with the
/// click meaning "toggle" instead of "open". Four ways to the same presets, two
/// meanings for one click. Shaders here, presets in the inspector.
///
/// A shader that is *out* of the rotation is drawn dimmed and opens on exactly
/// the same click as any other. Not shuffling a shader is no reason to be
/// unable to edit it.
///
/// ## Typing
///
/// A menu gives you type-select for free and a grid of pictures does not, so
/// the popover opens with the caret already in the filter field and ⏎ opens the
/// first card still showing. The filter matches preset names too, and a card
/// found that way opens wearing the preset — see `RotationGalleryView`.
///
/// ## New…
///
/// The first card in the grid is "+": asking for a shader that does not exist
/// is what you do at the end of looking through the ones that do. It runs the
/// same `newShader` the File menu's ⌘N runs, and it is not a shader, so it
/// never joins the rotation, the counts, or the arrows.
final class ShaderPicker: NSObject, NSPopoverDelegate {

    /// Narrower than the default card, because this is a popover and
    /// not a window: small enough that two or three shaders' groups sit side by
    /// side on a band, big enough that a still is still a picture of something.
    static let tileWidth: CGFloat = 96
    static let contentSize = NSSize(width: 900, height: 620)

    let gallery = RotationGalleryView(
        frame: NSRect(origin: .zero, size: ShaderPicker.contentSize),
        tileSize: RotationTile.size(width: ShaderPicker.tileWidth))

    /// Open this shader, wearing this preset, in the editor.
    var onOpen: ((LerpRotationEntry) -> Void)?
    /// The "+" card was clicked: make a shader there is no look for yet.
    var onNew: (() -> Void)?
    /// The rotation was changed from here. The host writes it.
    var onChange: ((LerpRotationSelection) -> Void)?

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
        gallery.onChange = { [weak self] selection in self?.onChange?(selection) }
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
    func prepare(shaders: [LerpShader], selection: LerpRotationSelection,
                 current: LerpRotationEntry?) {
        let fingerprint = RotationThumbnails.fingerprint(for: shaders)
        let stamp = [fingerprint,
                     selection.disabled.map(\.key).sorted().joined(separator: ","),
                     current?.key ?? ""].joined(separator: "\u{1}")
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp

        gallery.show(shaders: shaders, selection: selection)
        gallery.showCurrent(current)
        guard fingerprint != loadedFingerprint else { return }
        loadedFingerprint = fingerprint
        gallery.populate(using: thumbnails, jobs: RotationThumbnails.jobs(for: shaders))
    }

    /// Shader → Regenerate Stills: throws every still away and draws them
    /// again, for when something the stills depend on changed outside the
    /// shaders' own source — the prelude, the renderer.
    func regenerate(shaders: [LerpShader]) {
        thumbnails.evictAll()
        gallery.clearImages()
        loadedFingerprint = ""
        loadedStamp = ""
        gallery.show(shaders: shaders, selection: gallery.selection)
        loadedFingerprint = RotationThumbnails.fingerprint(for: shaders)
        gallery.populate(using: thumbnails, jobs: RotationThumbnails.jobs(for: shaders))
    }

    /// Someone else changed the rotation. Straight into the tiles; nothing goes
    /// back out through `onChange`.
    func showSelection(_ selection: LerpRotationSelection) {
        guard !gallery.entries.isEmpty else { return }
        gallery.show(shaders: gallery.shaders, selection: selection)
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
