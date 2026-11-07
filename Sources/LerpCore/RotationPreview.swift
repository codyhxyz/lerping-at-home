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
/// the still and the first live frame cannot drift apart — its size included.
/// The view draws the still's 240×360 pixels and the layer scales them into
/// the tile, exactly as the still itself is scaled, because a look is a
/// function of its resolution too: drawn at the tile's own 176×264,
/// game-of-life played a different board from the one on the card, and
/// dot-grid, the ditherers and pulse-rings a different pattern.
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

    /// The still's recipe: its `time`, `seed` and size are the numbers that
    /// decide whether the first live frame matches the picture it replaces.
    public let recipe: RotationThumbnails.Recipe

    /// How long the pointer has to rest on a tile before it starts playing.
    private let delay: TimeInterval = 0.11

    private var view: LerpMetalView?
    private var madeView = false
    private weak var current: RotationTile?
    private weak var wanted: RotationTile?
    private var pending: DispatchWorkItem?

    public init(recipe: RotationThumbnails.Recipe = RotationThumbnails.Recipe()) {
        self.recipe = recipe
    }

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

    /// The pixels the playing preview draws, or nil when nothing is playing.
    /// For the self-test, which checks they are the still's.
    public var renderSize: CGSize? { current == nil ? nil : view?.renderSize }

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
        // `.still`, as `RotationThumbnails`' renderers are — the fixture critter
        // and no caption — so the first frame is the still it replaces.
        guard let made = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 120, height: 180),
                                       mode: .still)
        else { return nil }
        var config = LerpMetalView.Config(shaderName: nil, renderScale: 1.0,
                                          shuffleInterval: .infinity)
        config.drawableSize = CGSize(width: recipe.width, height: recipe.height)
        made.config = config
        made.onCompileError = { _, _ in }   // a broken shader shows its still, silently
        view = made
        return made
    }
}
