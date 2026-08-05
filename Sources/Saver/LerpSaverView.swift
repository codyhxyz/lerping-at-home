import AppKit
import ScreenSaver

/// Thin ScreenSaverView shim around LerpMetalView, with the known
/// legacyScreenSaver workarounds baked in:
///
/// - Since Sonoma the system never calls `stopAnimation` and never destroys
///   instances; we listen for the distributed `com.apple.screensaver.willstop`
///   notification and terminate the host process ourselves (the Aerial
///   workaround), but only when we're the real fullscreen saver, never the
///   System Settings preview.
/// - `isPreview` is unreliable on recent macOS, so a small frame also counts
///   as preview.
/// - We ignore `animateOneFrame` entirely; LerpMetalView drives its own
///   CADisplayLink with a capped frame rate.
@objc(LerpSaverView)
public final class LerpSaverView: ScreenSaverView {

    private static let defaultsModule = "com.hergenroeder.lerping"

    private var metalView: LerpMetalView?
    private var effectiveIsPreview = false
    private var configPanel: NSPanel?
    private var shaderPopup: NSPopUpButton?
    private var fpsPopup: NSPopUpButton?
    private var scalePopup: NSPopUpButton?
    private var freezePopup: NSPopUpButton?

    private static let freezeChoices: [(title: String, minutes: Double)] = [
        ("Never", 0), ("After 5 minutes", 5), ("After 15 minutes", 15), ("After 30 minutes", 30),
    ]

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        effectiveIsPreview = isPreview || frame.width < 600
        wantsLayer = true
        setUpMetalView()
        observeWillStop()
    }

    required init?(coder: NSCoder) { nil }

    private static func defaults() -> ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: defaultsModule)
    }

    private func currentConfig() -> LerpMetalView.Config {
        let defaults = Self.defaults()
        let shader = defaults?.string(forKey: "shader")
        let fps = (defaults?.object(forKey: "fps") as? Int) ?? 30
        let renderScale = (defaults?.object(forKey: "renderScale") as? Double) ?? 1.0
        let shuffleMinutes = (defaults?.object(forKey: "shuffleMinutes") as? Double) ?? 5
        let freezeMinutes = (defaults?.object(forKey: "freezeAfterMinutes") as? Double) ?? 30
        return LerpMetalView.Config(
            shaderName: (shader == nil || shader == "Shuffle") ? nil : shader,
            framesPerSecond: fps,
            renderScale: renderScale,
            shuffleInterval: shuffleMinutes * 60,
            freezeAfter: freezeMinutes * 60)
    }

    private func setUpMetalView() {
        guard let view = LerpMetalView(frame: bounds) else { return }
        view.config = currentConfig()
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        metalView = view
    }

    private func observeWillStop() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screensaver.willstop"),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.metalView?.stop()
                if !self.effectiveIsPreview {
                    // legacyScreenSaver never tears us down (rdar since Sonoma);
                    // exiting is the only reliable way to release the GPU.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        exit(0)
                    }
                }
            }
    }

    // MARK: - ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        metalView?.config = currentConfig()
        metalView?.start()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        metalView?.stop()
    }

    public override func animateOneFrame() {
        // Rendering is driven by LerpMetalView's display link.
    }

    // MARK: - Configure sheet

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 225),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Lerping@Home"

        let defaults = Self.defaults()
        let library = metalView?.shaderLibrary
        let shaderNames = library?.discover().map(\.name) ?? []

        let shaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shaderPopup.addItem(withTitle: "Shuffle")
        shaderPopup.addItems(withTitles: shaderNames)
        let selected = defaults?.string(forKey: "shader") ?? "Shuffle"
        shaderPopup.selectItem(withTitle: shaderNames.contains(selected) ? selected : "Shuffle")

        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["24", "30", "60"])
        fpsPopup.selectItem(withTitle: String((defaults?.object(forKey: "fps") as? Int) ?? 30))

        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scalePopup.addItems(withTitles: ["100%", "75%", "50%"])
        let scale = (defaults?.object(forKey: "renderScale") as? Double) ?? 1.0
        scalePopup.selectItem(at: scale >= 0.99 ? 0 : (scale >= 0.74 ? 1 : 2))

        let freezePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        freezePopup.addItems(withTitles: Self.freezeChoices.map(\.title))
        let freezeMinutes = (defaults?.object(forKey: "freezeAfterMinutes") as? Double) ?? 30
        let freezeIndex = Self.freezeChoices.firstIndex { $0.minutes == freezeMinutes } ?? 3
        freezePopup.selectItem(at: freezeIndex)

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }

        let grid = NSGridView(views: [
            [label("Shader:"), shaderPopup],
            [label("Frame rate:"), fpsPopup],
            [label("Render scale:"), scalePopup],
            [label("Still image:"), freezePopup],
        ])
        grid.column(at: 0).width = 100
        grid.translatesAutoresizingMaskIntoConstraints = false

        let ok = NSButton(title: "OK", target: self, action: #selector(configureSheetOK))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(configureSheetCancel))
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        self.configPanel = panel
        self.shaderPopup = shaderPopup
        self.fpsPopup = fpsPopup
        self.scalePopup = scalePopup
        self.freezePopup = freezePopup
        return panel
    }

    @objc private func configureSheetOK() {
        if let defaults = Self.defaults() {
            let shader = shaderPopup?.titleOfSelectedItem ?? "Shuffle"
            defaults.set(shader, forKey: "shader")
            defaults.set(Int(fpsPopup?.titleOfSelectedItem ?? "30") ?? 30, forKey: "fps")
            let scale: Double
            switch scalePopup?.indexOfSelectedItem ?? 0 {
            case 1: scale = 0.75
            case 2: scale = 0.5
            default: scale = 1.0
            }
            defaults.set(scale, forKey: "renderScale")
            let freezeIndex = freezePopup?.indexOfSelectedItem ?? 3
            defaults.set(Self.freezeChoices[max(0, min(freezeIndex, Self.freezeChoices.count - 1))].minutes,
                         forKey: "freezeAfterMinutes")
            defaults.synchronize()
        }
        metalView?.config = currentConfig()
        endConfigureSheet()
    }

    @objc private func configureSheetCancel() {
        endConfigureSheet()
    }

    private func endConfigureSheet() {
        guard let panel = configPanel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        configPanel = nil
    }
}
