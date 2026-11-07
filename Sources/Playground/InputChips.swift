import AppKit

/// Small pills on the player bar, one for each live input that is feeding the
/// render right now: system audio, head tracking, hands, MIDI.
///
/// These inputs are switched on from the Shader menu, and until now the only
/// sign one was running was a status message, which the next compile wrote
/// over. A camera left on, or audio quietly moving a look, had no visible
/// cause. A chip appears only while its input is live. Audio shows its levels,
/// and MIDI flashes when a message arrives. Clicking a chip turns that input
/// off; the MIDI chip opens the Shader › MIDI menu instead.
final class InputChips: NSStackView {

    enum Input: String, CaseIterable {
        case audio, head, hands, midi
    }

    /// Clicked: turn `input` off, or for MIDI show its menu under `chip`.
    var onClick: ((Input, NSView) -> Void)?
    /// The live audio levels, while audio is on.
    var audioLevels: (() -> LerpAudioLevels)?

    private var chips: [Input: InputChip] = [:]
    private var meterTimer: Timer?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 5
        setHuggingPriority(.required, for: .horizontal)
        setAccessibilityIdentifier("input-chips")
        for input in Input.allCases {
            let chip = InputChip(input)
            chip.target = self
            chip.action = #selector(clicked(_:))
            chip.isHidden = true
            chips[input] = chip
            addArrangedSubview(chip)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Shows exactly the inputs in `live`, with the given labels and tooltips.
    func show(_ live: [Input: (label: String, tip: String)]) {
        for (input, chip) in chips {
            let entry = live[input]
            if chip.isHidden != (entry == nil) { chip.isHidden = entry == nil }
            if let entry { chip.set(label: entry.label, tip: entry.tip) }
        }
        let wantsMeter = live[.audio] != nil
        if wantsMeter, meterTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tickMeter() }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
        } else if !wantsMeter, let timer = meterTimer {
            timer.invalidate()
            meterTimer = nil
            chips[.audio]?.levels = nil
        }
    }

    func isShowing(_ input: Input) -> Bool { chips[input]?.isHidden == false }

    /// A message arrived: light the MIDI chip briefly.
    func pulse(_ input: Input) { chips[input]?.pulse() }

    private func tickMeter() {
        guard window?.isVisible == true, let levels = audioLevels?() else { return }
        chips[.audio]?.levels = levels
    }

    @objc private func clicked(_ sender: InputChip) { onClick?(sender.input, sender) }

    deinit { meterTimer?.invalidate() }
}

/// One input's pill: a symbol, a word, and — for audio — four tiny bars.
private final class InputChip: PlayerPill {
    let input: InputChips.Input
    private var word = ""
    private var glow: CGFloat = 0
    private var glowTimer: Timer?
    var levels: LerpAudioLevels? { didSet { if levels != oldValue { needsDisplay = true } } }

    init(_ input: InputChips.Input) {
        self.input = input
        super.init(frame: .zero)
        setAccessibilityIdentifier("input:\(input.rawValue)")
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func set(label: String, tip: String) {
        toolTip = tip
        setAccessibilityLabel(tip)
        guard label != word else { return }
        word = label
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var symbol: String {
        switch input {
        case .audio: "speaker.wave.2.fill"
        case .head: "person.fill.viewfinder"
        case .hands: "hand.raised.fill"
        case .midi: "pianokeys"
        }
    }

    private var hasMeter: Bool { input == .audio }

    /// Live inputs share one colour so they read as a set: the inspector's
    /// drift violet, the colour that already means "something else is moving
    /// this".
    private var tint: NSColor { InspectorStyle.drift }

    private var text: NSAttributedString {
        NSAttributedString(string: word, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: hovered ? EditorTheme.text : tint])
    }

    override var intrinsicContentSize: NSSize {
        let meter: CGFloat = hasMeter ? 20 : 0
        return NSSize(width: (10 + 13 + 5 + text.size().width + meter + 11).rounded(),
                      height: PlayerStyle.height)
    }

    override func restyle() {
        title = ""
        let base: CGFloat = pressed ? 0.30 : hovered ? 0.24 : 0.15
        layer?.backgroundColor = tint.withAlphaComponent(base + glow * 0.35).cgColor
        needsDisplay = true
    }

    func pulse() {
        glow = 1
        restyle()
        glowTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            glow = max(0, glow - 0.12)
            restyle()
            if glow == 0 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glowTimer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 10
        let color = hovered ? EditorTheme.text : tint
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        // Hovering shows what a click does.
        let name = hovered && input != .midi ? "xmark" : symbol
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(in: NSRect(x: x + (13 - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        x += 13 + 5
        let label = text
        let labelSize = label.size()
        label.draw(at: NSPoint(x: x, y: (bounds.height - labelSize.height) / 2))
        x += labelSize.width + 6

        guard hasMeter else { return }
        let values: [Float] = levels.map { [$0.level, $0.bass, $0.mid, $0.treble] } ?? [0, 0, 0, 0]
        let maxHeight: CGFloat = 12
        for (index, value) in values.enumerated() {
            // Perceptual: quiet music should still visibly move the bars.
            let fraction = CGFloat(min(1, max(0, sqrt(Double(value)))))
            let height = max(2, maxHeight * fraction)
            // Buttons are flipped: the bars stand on the bottom of their track.
            let bottom = (bounds.height + maxHeight) / 2
            let bar = NSRect(x: x + CGFloat(index) * 4, y: bottom - height, width: 2.5, height: height)
            color.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bottom - maxHeight, width: bar.width, height: maxHeight),
                         xRadius: 1.25, yRadius: 1.25).fill()
            color.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
        }
    }
}
