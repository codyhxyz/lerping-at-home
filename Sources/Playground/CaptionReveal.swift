import AppKit

/// Brings a captioned look's label back on request. A look shows its caption
/// for its first few seconds and then plays textless (`LerpCaptionSchedule`);
/// here the pointer moving over the render holds it up again, the way a video
/// player's controls come back, until the pointer has rested for `linger`
/// seconds or left. Shader › Show Captions (`pinned`) holds it up for good.
final class CaptionReveal: NSResponder {
    static let linger: TimeInterval = 2.5
    private static let pinnedKey = "showCaptions"

    private let view: LerpMetalView
    private var idle: Timer?
    private var moving = false { didSet { update() } }

    var pinned: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pinnedKey); update() }
    }

    init(view: LerpMetalView) {
        self.view = view
        super.init()
        // `.inVisibleRect` keeps the area the view's size through a resize
        // and through Preview Full Screen, which moves this same view.
        view.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [.mouseMoved, .mouseEnteredAndExited,
                                                      .activeInKeyWindow, .inVisibleRect],
                                            owner: self, userInfo: nil))
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { idle?.invalidate() }

    override func mouseMoved(with event: NSEvent) { nudge() }
    override func mouseEntered(with event: NSEvent) { nudge() }
    override func mouseExited(with event: NSEvent) {
        idle?.invalidate()
        moving = false
    }

    private func nudge() {
        if !moving { moving = true }
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: Self.linger, repeats: false) { [weak self] _ in
            self?.moving = false
        }
    }

    private func update() { view.captionHeld = moving || pinned }
}
