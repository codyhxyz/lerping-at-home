import AppKit
import QuartzCore
import simd

/// `u.viewer` from the pointer, for whenever no camera is seeing a face: no
/// camera, access refused, the camera paused, or nobody in front of it. The
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

    private var value = SIMD3<Float>(repeating: 0)
    private var stamp: CFTimeInterval = 0

    /// Starts from where the tracked head was, so losing the face hands over
    /// to the pointer without a jump.
    func follow(_ viewer: LerpViewer) {
        value = SIMD3(viewer.offset.x, viewer.offset.y, viewer.offset.z)
        stamp = CACurrentMediaTime()
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
