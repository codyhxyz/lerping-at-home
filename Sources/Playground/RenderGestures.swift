import AppKit

/// The render as something to hold (`LerpTurn`): drag to turn the look,
/// pinch — or scroll, with two fingers or a wheel — to bring it nearer.
///
/// Each gesture moves one of the look's own parameters by a delta in that
/// parameter's units (`yaw`/`pitch` in degrees, `magnify` in stops) and says
/// nothing else; what a parameter does, and whether the look has it at all,
/// is the window controller's and the look's business. A gesture on a look
/// that does not declare its parameter never starts, so the event goes on
/// exactly as if nothing were listening.
///
/// - **Drag.** A press only becomes a drag once the pointer has travelled a
///   few points, so a click stays a click and a double-click still leaves
///   full screen; from then on the pointer is a closed hand until the button
///   comes up.
/// - **Pinch** on a trackpad: fingers apart brings the scene nearer, at the
///   rate the pinch itself scales — spread to twice the span, twice the size.
/// - **Scroll**: the way a web 3D viewer reads it, so Natural Scrolling means
///   here what it means there — content-up is nearer. A trackpad's smooth
///   deltas and its momentum after the fingers lift pass straight through; a
///   wheel's notches step.
///
/// It follows the render view rather than any one window: `FullScreenPreview`
/// moves that view instead of making another, so every gesture works the same
/// in the pane and full screen with nothing registered twice. It is a local
/// event monitor rather than gesture recognizers because AppKit runs those
/// only for events that come from the window server, and this has to be
/// provable by driving the window controller headlessly with synthesized
/// events. The monitor sees the same events and never consumes one.
final class RenderGestures {
    /// Whether the look on screen declares the parameter a gesture moves.
    var accepts: (_ parameter: String) -> Bool = { _ in false }
    /// Parameters to move, each by a delta in its own units.
    var onMove: ((_ moves: [(parameter: String, delta: Double)]) -> Void)?

    /// Points the pointer travels before a press on the render is a drag.
    private static let slop: CGFloat = 3
    /// A trackpad's two-finger scroll: a long, deliberate swipe is about a stop.
    private static let stopsPerScrollPoint = 1.0 / 240
    /// A wheel's notch (one line, more when the wheel is spun fast).
    private static let stopsPerScrollLine = 0.1

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
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify]
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
            guard isOverView(event) else { return }
            pressed = view.convert(event.locationInWindow, from: nil)
            last = pressed!
        case .leftMouseDragged:
            drag(event)
        case .leftMouseUp:
            release()
        case .scrollWheel, .magnify:
            guard let stops = Self.zoomStops(event), stops != 0, isOverView(event),
                  accepts(LerpTurn.magnifyParameter) else { return }
            onMove?([(LerpTurn.magnifyParameter, stops)])
        default:
            break
        }
    }

    private func drag(_ event: NSEvent) {
        guard let pressed, event.window === view.window else { return }
        let here = view.convert(event.locationInWindow, from: nil)
        if !turning {
            guard hypot(here.x - pressed.x, here.y - pressed.y) >= Self.slop,
                  accepts(LerpTurn.yawParameter) || accepts(LerpTurn.pitchParameter) else { return }
            turning = true
            NSCursor.closedHand.push()
        }
        let side = min(view.bounds.width, view.bounds.height)
        let moved = CGSize(width: here.x - last.x, height: here.y - last.y)
        last = here
        guard side > 0, moved != .zero else { return }
        let scale = LerpTurn.degreesPerShortSide / side
        // A view's y runs up unless it is flipped; up is positive here.
        let up = view.isFlipped ? -moved.height : moved.height
        onMove?([(LerpTurn.yawParameter, moved.width * scale), (LerpTurn.pitchParameter, up * scale)])
    }

    /// How many stops nearer a scroll or a pinch asks for; nil for any other
    /// event. Content-up and fingers-apart are positive.
    static func zoomStops(_ event: NSEvent) -> Double? {
        switch event.type {
        case .scrollWheel:
            let perUnit = event.hasPreciseScrollingDeltas ? stopsPerScrollPoint : stopsPerScrollLine
            return event.scrollingDeltaY * perUnit
        case .magnify:
            return event.magnification > -1 ? log2(1 + event.magnification) : nil
        default:
            return nil
        }
    }

    /// Whether `event` lands on the render itself — not on a control laid
    /// over it, and not in another window.
    private func isOverView(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window, let content = window.contentView else { return false }
        return content.hitTest(content.convert(event.locationInWindow, from: nil)) === view
    }

    private func release() {
        pressed = nil
        if turning { NSCursor.pop() }
        turning = false
    }
}
