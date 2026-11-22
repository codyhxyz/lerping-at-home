import AppKit
import QuartzCore
import simd

/// `u.viewer` from the pointer, for when there is no camera to follow the
/// head: none attached, access refused, or one that would not start. The
/// pointer stands in for the head — move it right and the eye moves right — so
/// a window look still looks round its depth instead of sitting flat.
///
/// Over the playground's render (pane or full-screen preview) the pointer is
/// measured from that view's centre; with Desktop Mode on, anywhere else it is
/// measured from the centre of the screen it is on. Anywhere else again — the
/// editor, the inspector — the view eases back to straight on, so typing does
/// not leave the scene peering in from one side. While a button is down the
/// view holds: a drag on the render is orbiting the camera, not leaning.
///
/// While the camera is following the head, moving the pointer where it steers
/// takes the view over (`steering(over:head:)`): the eye goes where the
/// pointer says, and once the pointer has been still for `hold` seconds the
/// view glides back to the head.
///
/// Main thread only: it is polled from the render's display link, and from
/// each Desktop Mode window's, all on the main run loop. The easing is by
/// elapsed time, so being asked several times a frame changes nothing.
final class PointerViewer {
    /// The pointer at the edge of the view's short side reads as the head
    /// moved this far across, in `LerpViewer` units (fractions of the viewing
    /// distance): a clear lean, well inside what the head tracker measures.
    static let reach: Float = 0.4
    /// Time constant of the easing, seconds: quick enough to feel attached,
    /// slow enough that a pointer jump does not snap the scene.
    static let response: Double = 0.12

    /// Pointer still this long, seconds, and the head has the view back.
    static let hold: Double = 1.5
    /// How long the glide back to the head takes, seconds.
    static let release: Double = 0.5

    private var value = SIMD3<Float>(repeating: 0)
    private var stamp: CFTimeInterval = 0

    // Taking over from the head.
    private var lastPoint: NSPoint?
    /// When the pointer stops steering and the glide back to the head begins.
    private var releaseAt: CFTimeInterval = -.infinity
    private var shown = SIMD3<Float>(repeating: 0)

    /// The eye while the camera follows the head: the head's, unless the
    /// pointer has just moved over the render (or, with Desktop Mode on, over
    /// the bare desktop), in which case the pointer's. Depth stays the head's
    /// either way, so taking over does not zoom.
    func steering(over view: NSView, desktop: Bool, head: LerpViewer) -> LerpViewer {
        let point = NSEvent.mouseLocation
        return steering(head: head, point: point, buttonDown: NSEvent.pressedMouseButtons != 0,
                        now: CACurrentMediaTime(),
                        steers: { Self.steers(at: point, over: view, desktop: desktop) },
                        target: { self.target(over: view, desktop: desktop) })
    }

    /// `steering(over:desktop:head:)` with its inputs passed in. `steers` is
    /// asked only when the pointer has moved; `target` is where the pointer
    /// puts the eye, or nil to hold.
    func steering(head: LerpViewer, point: NSPoint, buttonDown: Bool, now: CFTimeInterval,
                  steers: () -> Bool, target: () -> SIMD3<Float>?) -> LerpViewer {
        let headEye = SIMD3(head.offset.x, head.offset.y, head.offset.z)

        if point != lastPoint {
            if lastPoint != nil, !buttonDown {
                if steers() {
                    if now >= releaseAt {
                        // Pick up from what is on screen, so the take-over is seamless.
                        value = shown
                        stamp = now
                    }
                    releaseAt = now + Self.hold
                } else {
                    // Off the render (into the editor, onto another app's
                    // window): it is not steering any more, so the head has
                    // the view back now rather than after the pointer rests.
                    releaseAt = min(releaseAt, now)
                }
            }
            lastPoint = point
        }

        // How much of x/y is the pointer's: 1 while it steers, then a
        // smoothstep down to 0 over `release`, which starts and lands flat.
        let share: Float
        if now < releaseAt {
            share = 1
            let dt = now - stamp
            stamp = now
            if let target = target() {
                let k = Float(1 - exp(-dt / Self.response))
                value += (target - value) * k
            }
        } else {
            let f = Float(min(1, (now - releaseAt) / Self.release))
            share = 1 - f * f * (3 - 2 * f)
        }
        shown = headEye + (value - headEye) * share
        shown.z = headEye.z
        return LerpViewer(x: shown.x, y: shown.y, z: shown.z)
    }

    /// Whether a pointer moved to `point` is steering the view: over the
    /// render, or with Desktop Mode on over the desktop itself — not over an
    /// app's window, the Dock or the menu bar, where it is just being used.
    private static func steers(at point: NSPoint, over view: NSView, desktop: Bool) -> Bool {
        if let window = view.window, window.isVisible,
           window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point) { return true }
        guard desktop, let primary = NSScreen.screens.first else { return false }
        let flipped = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[CFString: Any]] ?? []
        return !windows.contains { info in
            guard (info[kCGWindowLayer] as? Int ?? 0) >= 0,
                  let bounds = info[kCGWindowBounds] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return rect.contains(flipped)
        }
    }

    func current(over view: NSView, desktop: Bool) -> LerpViewer {
        let now = CACurrentMediaTime()
        let dt = stamp == 0 ? 0 : now - stamp
        stamp = now
        if let target = target(over: view, desktop: desktop) {
            let k = Float(1 - exp(-dt / Self.response))
            value += (target - value) * k
        }
        return LerpViewer(x: value.x, y: value.y, z: value.z)
    }

    /// Where the pointer puts the eye, or nil to hold still (a button is down).
    private func target(over view: NSView, desktop: Bool) -> SIMD3<Float>? {
        guard NSEvent.pressedMouseButtons == 0 else { return nil }
        let point = NSEvent.mouseLocation
        if let window = view.window, window.isVisible {
            let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
            if rect.contains(point) { return Self.offset(of: point, in: rect) }
        }
        if desktop, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return Self.offset(of: point, in: screen.frame)
        }
        return SIMD3(repeating: 0)
    }

    static func offset(of point: NSPoint, in rect: NSRect) -> SIMD3<Float> {
        let half = max(1, min(rect.width, rect.height) / 2)
        let limit = HeadPoseEstimator.lateral
        let x = Float((point.x - rect.midX) / half) * Self.reach
        let y = Float((point.y - rect.midY) / half) * Self.reach
        return SIMD3(simd_clamp(x, -limit, limit), simd_clamp(y, -limit, limit), 0)
    }
}
