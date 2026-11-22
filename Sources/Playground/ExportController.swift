import AppKit
import UniformTypeIdentifiers

/// Retain one per editor window. The source is sampled only after the save
/// panel is confirmed; the worker never reads AppKit or the editor again.
@MainActor
final class ExportController: NSObject {
    private enum Aspect: Int, CaseIterable {
        case landscape, square, portrait

        var size: (width: Int, height: Int) {
            switch self {
            case .landscape: return (1920, 1080)
            case .square: return (1080, 1080)
            case .portrait: return (1080, 1920)
            }
        }

        var label: String {
            switch self {
            case .landscape: return "16:9 · 1920 × 1080"
            case .square: return "1:1 · 1080 × 1080"
            case .portrait: return "9:16 · 1080 × 1920"
            }
        }
    }

    private var busy = false
    private var cancellation: LerpLoopExport.Cancellation?
    private var parentCloseObserver: NSObjectProtocol?
    var onStatus: (String) -> Void = { _ in }
    var isPresenting: Bool { busy }

    deinit {
        cancellation?.cancel()
        parentCloseObserver.map(NotificationCenter.default.removeObserver)
    }

    func present(for source: LerpMetalView, in parent: NSWindow, placard: LerpMuseumPlacard? = nil) {
        guard !busy, parent.attachedSheet == nil, source.currentShader != nil else { return }
        busy = true
        let options = Options()
        chooseOptions(options, for: source, in: parent, placard: placard)
    }

    private func chooseOptions(_ options: Options, for source: LerpMetalView, in parent: NSWindow,
                               placard: LerpMuseumPlacard?) {
        let alert = NSAlert()
        alert.messageText = "Export a 10-second loop"
        alert.informativeText = "H.264 MP4, 30 fps, SDR. Audio is not recorded."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.accessoryView = options.view
        alert.beginSheetModal(for: parent) { [weak self, weak source, weak parent] choice in
            guard let self else { return }
            guard choice == .alertFirstButtonReturn, let source, let parent else { self.busy = false; return }
            guard let mode = options.loopMode else {
                let warning = NSAlert()
                warning.messageText = "Enter a valid length"
                warning.informativeText = "A cycle must be positive. A crossfade must be longer than zero and at most 10 seconds."
                warning.beginSheetModal(for: parent) { [weak self, weak source, weak parent] _ in
                    guard let self else { return }
                    guard let source, let parent else { self.busy = false; return }
                    self.chooseOptions(options, for: source, in: parent, placard: placard)
                }
                return
            }
            self.chooseDestination(for: source, in: parent, aspect: options.aspect, mode: mode,
                                   includePlacard: options.includePlacard, placard: placard)
        }
    }

    private func chooseDestination(for source: LerpMetalView, in parent: NSWindow, aspect: Aspect,
                                   mode: LerpLoopExport.Mode, includePlacard: Bool, placard: LerpMuseumPlacard?) {
        let save = NSSavePanel()
        save.allowedContentTypes = [.mpeg4Movie]
        save.canCreateDirectories = true
        save.nameFieldStringValue = "\(source.currentShader?.name ?? "Lerp")-loop.mp4"
        save.beginSheetModal(for: parent) { [weak self, weak source, weak parent] reply in
            guard let self else { return }
            guard reply == .OK, let destination = save.url, let parent, let source,
                  let shader = source.currentShader, let parameters = source.parameterValues else {
                self.busy = false
                return
            }
            let look = LerpLoopExport.Look(shader: shader, parameters: parameters, seed: source.seed, startTime: source.time)
            let credit = includePlacard ? (placard ?? LerpMuseumPlacard(shader: shader, preset: source.currentEntry?.preset)) : nil
            self.write(look, to: destination, in: parent, aspect: aspect, mode: mode, placard: credit)
        }
    }

    private func write(_ look: LerpLoopExport.Look, to destination: URL, in parent: NSWindow,
                       aspect: Aspect, mode: LerpLoopExport.Mode, placard: LerpMuseumPlacard?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 119),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Export Loop"
        panel.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 119))
        panel.contentView = host

        let label = NSTextField(labelWithString: "Preparing render…")
        label.frame = NSRect(x: 20, y: 83, width: 340, height: 19)
        host.addSubview(label)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 55, width: 340, height: 14))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.maxValue = Double(LerpLoopExport.frameCount)
        bar.setAccessibilityLabel("Frames exported")
        host.addSubview(bar)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelExport(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 264, y: 14, width: 100, height: 29)
        host.addSubview(cancel)

        parent.beginSheet(panel)
        let size = aspect.size
        let job = LerpLoopExport.start(look: look, width: size.width, height: size.height, mode: mode,
                                       placard: placard, to: destination, progress: { count in
            DispatchQueue.main.async {
                bar.doubleValue = Double(count)
                if cancel.isEnabled {
                    label.stringValue = count == LerpLoopExport.frameCount ? "Finishing MP4…" : "Rendering \(count) / \(LerpLoopExport.frameCount)"
                }
            }
        }) { [weak self, weak parent] result in
            DispatchQueue.main.async {
                if let parent, panel.sheetParent === parent { parent.endSheet(panel) }
                self?.parentCloseObserver.map(NotificationCenter.default.removeObserver)
                self?.parentCloseObserver = nil
                self?.cancellation = nil
                self?.busy = false
                switch result {
                case .success(let url): self?.onStatus("Exported \(url.lastPathComponent)")
                case .failure(LerpLoopExport.Failure.cancelled): self?.onStatus("Loop export cancelled")
                case .failure(let error):
                    guard let parent, parent.isVisible else { return }
                    NSAlert(error: error).beginSheetModal(for: parent)
                }
            }
        }
        cancellation = job
        parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                      object: parent, queue: .main) { _ in job.cancel() }
    }

    @objc private func cancelExport(_ sender: NSButton) {
        sender.isEnabled = false
        cancellation?.cancel()
    }

    @MainActor
    private final class Options: NSObject {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 355, height: 151))
        let aspectMenu = NSPopUpButton(frame: NSRect(x: 128, y: 120, width: 222, height: 26), pullsDown: false)
        let modeMenu = NSPopUpButton(frame: NSRect(x: 128, y: 88, width: 222, height: 26), pullsDown: false)
        let seconds = NSTextField(frame: NSRect(x: 128, y: 58, width: 72, height: 23))
        let secondsLabel = NSTextField(labelWithString: "")
        let note = NSTextField(wrappingLabelWithString: "")
        let placard = NSButton(checkboxWithTitle: "Include museum placard", target: nil, action: nil)

        override init() {
            super.init()
            func addLabel(_ text: String, y: CGFloat) {
                let field = NSTextField(labelWithString: text)
                field.frame = NSRect(x: 4, y: y, width: 119, height: 19)
                view.addSubview(field)
            }
            addLabel("Aspect", y: 124)
            addLabel("Loop mode", y: 92)
            secondsLabel.frame = NSRect(x: 4, y: 60, width: 119, height: 19)
            aspectMenu.addItems(withTitles: Aspect.allCases.map(\.label))
            modeMenu.addItems(withTitles: ["Crossfade loop", "Periodic"])
            modeMenu.target = self
            modeMenu.action = #selector(modeChanged)
            note.frame = NSRect(x: 4, y: 24, width: 344, height: 29)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            placard.frame = NSRect(x: 4, y: 0, width: 344, height: 20)
            [aspectMenu, modeMenu, secondsLabel, seconds, note, placard].forEach(view.addSubview)
            modeChanged()
        }

        var aspect: Aspect { Aspect(rawValue: aspectMenu.indexOfSelectedItem) ?? .landscape }
        var includePlacard: Bool { placard.state == .on }
        var loopMode: LerpLoopExport.Mode? {
            guard let n = try? Double(seconds.stringValue.trimmingCharacters(in: .whitespaces), format: .number),
                  n.isFinite, n > 0 else { return nil }
            if modeMenu.indexOfSelectedItem == 1 { return .periodic(periodSeconds: n) }
            return n <= LerpLoopExport.duration ? .crossfade(windowSeconds: n) : nil
        }

        @objc private func modeChanged() {
            if modeMenu.indexOfSelectedItem == 1 {
                secondsLabel.stringValue = "Cycle (seconds)"
                seconds.stringValue = "10"
                note.stringValue = "Samples one cycle. Seamless only if the entire look, including drifts, repeats on this period."
            } else {
                secondsLabel.stringValue = "Fade (seconds)"
                seconds.stringValue = "2"
                note.stringValue = "Blends the tail into an earlier time in the look. Does not require a known period."
            }
            seconds.setAccessibilityLabel(secondsLabel.stringValue)
        }
    }
}
