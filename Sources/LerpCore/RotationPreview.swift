import AppKit

/// The one live view the gallery lends to whichever tile the pointer is over.
///
/// ## Why one view and not one per tile
///
/// There are 123 looks. A `LerpMetalView` owns a `CAMetalLayer`, a display link
/// and a `ShaderLibrary`, so 123 of them is 123 drawables and 123 display links
/// for a grid in which at most one tile is ever under the pointer. So there is
/// exactly one, and it is *reparented* into the hovered tile: added as a subview
/// of the tile, sized to the tile's picture, and taken away again when the
/// pointer leaves. The tile's baked still stays underneath it the whole time and
/// is simply uncovered on the way out.
///
/// ## Why it resumes rather than restarts
///
/// A frame in this project is a pure function of (shader source, parameters,
/// time, seed) — the property `RotationThumbnails` already relies on to cache
/// stills on disk and to bake them into the `.saver`. That is also what makes
/// "carry on from the still" possible rather than merely desirable: the stills
/// are rendered at `Recipe.time` and `Recipe.seed`, so a live view started at the
/// *same* time and seed with the same parameters draws, as its first frame, the
/// picture that was already on screen. The animation starts moving; nothing
/// jumps. Start it at zero instead and every tile would flash to a different
/// composition the moment you touched it.
///
/// The recipe is taken from `RotationThumbnails.Recipe` rather than copied, so
/// the still and the first live frame cannot drift apart.
///
/// ## What it has to survive
///
/// - **A pointer swept across twenty tiles.** Installing a preview costs a
///   pipeline compile, so the install is debounced: the tile the pointer left
///   stops immediately, and the tile it landed on starts only if the pointer is
///   still there `delay` later. Sweeping the grid therefore compiles once.
/// - **Scrolling with the pointer down over a tile.** The gallery stops the
///   player when its clip view moves; the tracking areas are `.inVisibleRect`,
///   so a tile scrolled out from under the pointer is not left playing.
/// - **The window losing key.** Tracking is `.activeInKeyWindow`, and the
///   gallery stops the player on `didResignKey` as well — a screensaver preview
///   animating in a background window is exactly the power drain the rest of
///   this project is careful about.
public final class RotationPreviewPlayer {

    /// The still's recipe. Only `time` and `seed` are read; they are the two
    /// numbers that decide whether the first live frame matches the picture it
    /// replaces.
    public var recipe: RotationThumbnails.Recipe

    /// How long the pointer has to rest on a tile before it starts playing.
    /// Settable so `--selftest` can drive the same code path without waiting.
    public var delay: TimeInterval = 0.11

    /// A thumbnail-sized preview does not need 60 Hz, and a gallery is not what
    /// anyone opened this app to watch.
    public var framesPerSecond = 30

    private var view: LerpMetalView?
    private var madeView = false
    private weak var current: RotationTile?
    private weak var wanted: RotationTile?
    private var pending: DispatchWorkItem?

    public init(recipe: RotationThumbnails.Recipe = RotationThumbnails.Recipe()) {
        self.recipe = recipe
    }

    // MARK: - What is playing

    public var isPlaying: Bool { current != nil }
    public var playingEntry: LerpRotationEntry? { current?.entry }
    public var playingTile: RotationTile? { current }
    /// The live view, once one has been made. nil before the first hover, and on
    /// a machine with no Metal device.
    public var liveView: LerpMetalView? { view }

    // MARK: - Driving it

    /// The pointer is over `tile`. Starts it playing once the pointer has stayed
    /// put for `delay`; whatever was playing stops now.
    public func want(_ tile: RotationTile, shader: LerpShader) {
        guard current !== tile else { return }
        pending?.cancel()
        wanted = tile
        detach()
        let work = DispatchWorkItem { [weak self, weak tile] in
            guard let self, let tile, self.wanted === tile else { return }
            self.install(tile, shader: shader)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pointer left `tile`. Ignored when it is not the tile we are showing
    /// or about to show — AppKit can deliver the exit of the tile you left after
    /// the enter of the one you arrived on, and that must not cancel the arrival.
    public func leave(_ tile: RotationTile) {
        guard wanted === tile || current === tile else { return }
        stop()
    }

    /// Everything stops and the still comes back.
    public func stop() {
        pending?.cancel()
        pending = nil
        wanted = nil
        detach()
    }

    // MARK: - Internals

    private func install(_ tile: RotationTile, shader: LerpShader) {
        pending = nil
        guard tile.window != nil, tile.isLive, !tile.isHidden else { return }
        guard let view = makeView() else { return }
        detach()

        // Pinned, so the shuffle in `tick` can never step this view off the look
        // the pointer is on.
        view.config.shaderName = shader.name
        // The whole look in one step — the same `(shader, parameters)` the
        // still was baked from, which is what makes the swap invisible. This
        // used to be `setShader` followed by the preset's values set one at a
        // time, a second hand-written copy of "defaults, then the preset" that
        // was only correct because of the reset `setShader` happened to do
        // first, repacked the uniform block once per parameter, and left
        // `currentEntry` naming the defaults look while a preset was on screen.
        guard view.show(tile.entry, of: shader) else { return }
        view.seed = recipe.seed
        view.time = CFTimeInterval(recipe.time)

        tile.attachPreview(view)
        view.start()
        // The first frame now rather than on the next display-link tick, so the
        // still is replaced by its own continuation and not by one blank frame.
        view.renderOnce()
        current = tile
    }

    private func detach() {
        view?.stop()
        view?.removeFromSuperview()
        current?.detachPreview()
        current = nil
    }

    /// Built on the first hover, never before: a gallery nobody points at should
    /// not cost a Metal device. nil — and remembered as nil — when there is none.
    private func makeView() -> LerpMetalView? {
        if let view { return view }
        guard !madeView else { return nil }
        madeView = true
        guard let made = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 180))
        else { return nil }
        made.config = LerpMetalView.Config(shaderName: nil, framesPerSecond: framesPerSecond,
                                           renderScale: 1.0, shuffleInterval: .infinity)
        made.onCompileError = { _, _ in }   // a broken shader shows its still, silently
        view = made
        return made
    }
}
