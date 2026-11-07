import AppKit

/// Click and drag on the render to turn a look that turns (`LerpTurn`).
///
/// A press only becomes a drag once the pointer has travelled a few points,
/// so a click stays a click and a double-click still leaves full screen. Until
/// then nothing changes; from then on the pointer is a closed hand until the
/// button comes up.
///
/// It follows the render view rather than any one window: `FullScreenPreview`
/// moves that view instead of making another, so dragging works the same in
/// the pane and full screen with nothing registered twice. It knows nothing of
/// parameters — it reports how far the hand moved, in degrees, and whether to
/// start at all is the window controller's call: on a look that declares no
/// `yaw`/`pitch`, a drag never starts.
///
/// A local event monitor rather than `NSPanGestureRecognizer`: AppKit runs
/// gesture recognizers only for events that come from the window server, so
/// a recognizer here could not be exercised by driving the window controller
/// headlessly with synthesized events. The monitor sees the same events,
/// never consumes one, and can be.
final class DragToTurn {
    /// Whether the look on screen turns. Asked when a press becomes a drag.
    var canTurn: () -> Bool = { false }
    /// Degrees the hand moved since the last call: right and up are positive.
    var onTurn: ((_ yaw: Double, _ pitch: Double) -> Void)?

    /// Points the pointer travels before a press on the render is a drag.
    private static let slop: CGFloat = 3

    private let view: NSView
    private var monitor: Any?
    /// Where the button went down on the render, and where it was last seen,
    /// in the view's own coordinates; nil while no press began on it.
    private var pressed: NSPoint?
    private var last = NSPoint.zero
    private var turning = false

    init(view: NSView) {
        self.view = view
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    deinit { monitor.map(NSEvent.removeMonitor) }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            release()
            guard let window = view.window, event.window === window,
                  let content = window.contentView,
                  content.hitTest(content.convert(event.locationInWindow, from: nil)) === view
            else { return }
            pressed = view.convert(event.locationInWindow, from: nil)
            last = pressed!
        case .leftMouseDragged:
            guard let pressed, event.window === view.window else { return }
            let here = view.convert(event.locationInWindow, from: nil)
            if !turning {
                guard hypot(here.x - pressed.x, here.y - pressed.y) >= Self.slop, canTurn() else { return }
                turning = true
                NSCursor.closedHand.push()
            }
            let side = min(view.bounds.width, view.bounds.height)
            let moved = CGSize(width: here.x - last.x, height: here.y - last.y)
            last = here
            guard side > 0, moved != .zero else { return }
            let scale = LerpTurn.degreesPerShortSide / side
            // A view's y runs up unless it is flipped; up is positive here.
            onTurn?(moved.width * scale, (view.isFlipped ? -moved.height : moved.height) * scale)
        default:
            release()
        }
    }

    private func release() {
        pressed = nil
        if turning { NSCursor.pop() }
        turning = false
    }
}
