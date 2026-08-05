import AppKit
import OSLog
import ScreenSaver

/// Thin ScreenSaverView shim around LerpMetalView, with the known
/// legacyScreenSaver workarounds baked in:
///
/// - The system never destroys instances, and `NSWindow.didChangeOcclusionState`
///   never fires for a host parked at the desktop-wallpaper layer — so neither of
///   the view's own "stop burning power" paths is reachable there, and such a
///   host renders full-screen behind the desktop forever (measured: 5.5% CPU).
///   The real saver therefore renders only between the distributed
///   `com.apple.screensaver` start and stop notifications and at no other time.
///   We never terminate the host: a retained window with an intact backing store
///   costs nothing (measured: 0.00 s over 30 s) and keeps the lock screen
///   deterministic — it shows the frame we stopped on instead of racing an
///   `exit(0)` against the lock UI.
/// - `startAnimation`/`stopAnimation` are still wired up but are not the primary
///   signal. `stopAnimation` does fire on macOS 27, ~400 ms after `didstop`.
/// - `isPreview` is unreliable on recent macOS, so a small frame also counts
///   as preview. Preview instances keep the classic startAnimation/stopAnimation
///   contract and ignore the distributed notifications entirely, so a real
///   screensaver cycle cannot freeze the System Settings thumbnail.
/// - We ignore `animateOneFrame` entirely; LerpMetalView drives its own
///   CADisplayLink with a capped frame rate.
@objc(LerpSaverView)
public final class LerpSaverView: ScreenSaverView, NSTableViewDataSource, NSTableViewDelegate {

    private static let defaultsModule = "com.hergenroeder.lerping"
    static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "saver")

    private var metalView: LerpMetalView?
    private var effectiveIsPreview = false
    private var configPanel: NSPanel?
    private var shaderPopup: NSPopUpButton?
    private var fpsPopup: NSPopUpButton?
    private var scalePopup: NSPopUpButton?
    private var freezePopup: NSPopUpButton?
    private var wallpaperCheckbox: NSButton?

    /// True between a screensaver start notification and the matching stop.
    ///
    /// Process-wide, not per-instance, on purpose: legacyScreenSaver builds a
    /// second `LerpSaverView` 130-165 ms *after* `didstart` lands (observed twice
    /// on macOS 27), so a per-instance flag would leave that one dark for the
    /// whole session if it is the one the host actually displays. A session is a
    /// fact about the host, not about any one view.
    private static var sessionActive = false
    /// Instances that have started rendering for the current session, so the
    /// second start is a no-op instead of a double display link.
    private var rendering = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let instanceID = LerpSaverView.nextInstanceID()
    private static var instanceCounter = 0
    private static func nextInstanceID() -> Int {
        instanceCounter += 1
        return instanceCounter
    }

    // Rotation list state, live only while the configure sheet is open.
    private var rotationNames: [String] = []
    private var rotationEnabled: Set<String> = []
    private var rotationTable: NSTableView?
    private var rotationLabel: NSTextField?
    private var rotationNote: NSTextField?
    private var rotationButtons: [NSButton] = []

    /// A popup's menu, in menu order: the titles it shows and the value each one
    /// stores. Titles, value → index and index → value all come out of the one
    /// table, because spelling the same three-row menu out three times is how a
    /// popup ends up one item off from what it saves.
    private typealias Choices = [(title: String, value: Double)]

    private static let freezeChoices: Choices = [        // minutes
        ("Never", 0), ("After 5 minutes", 5), ("After 15 minutes", 15), ("After 30 minutes", 30),
    ]
    private static let renderScales: Choices = [         // fraction of native
        ("100%", 1.0), ("75%", 0.75), ("50%", 0.5),
    ]

    /// Where `value` sits in the menu, or `fallback` for a value the menu does
    /// not offer (only reachable by hand-editing the defaults).
    private static func index(of value: Double, in choices: Choices, default fallback: Int) -> Int {
        choices.firstIndex { $0.value == value } ?? fallback
    }

    /// The value a popup is sitting on, clamped to the menu.
    private static func value(of popup: NSPopUpButton?, in choices: Choices, default fallback: Int) -> Double {
        let index = popup?.indexOfSelectedItem ?? fallback
        return choices[max(0, min(index, choices.count - 1))].value
    }

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        effectiveIsPreview = isPreview || frame.width < 600
        wantsLayer = true
        setUpMetalView()
        observeScreenSaverLifecycle()
        Self.log.info("init frame=\(Int(frame.width))x\(Int(frame.height)) isPreview=\(isPreview) effectiveIsPreview=\(self.effectiveIsPreview)")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        lifecycleObservers.forEach(DistributedNotificationCenter.default().removeObserver)
    }

    private static func defaults() -> ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: defaultsModule)
    }

    private func discoveredShaderNames() -> [String] {
        metalView?.shaderLibrary.discover().map(\.name) ?? []
    }

    private func currentConfig() -> LerpMetalView.Config {
        Settings.load(from: Self.defaults(), discovered: discoveredShaderNames()).config
    }

    private func setUpMetalView() {
        guard let view = LerpMetalView(frame: bounds) else { return }
        // Assign first: currentConfig() discovers shaders through this view.
        metalView = view
        view.config = currentConfig()
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    // MARK: - Session lifecycle

    /// Distributed notifications posted by the screensaver engine. Verified on
    /// macOS 27: didstart → screenIsLocked → willstop → didstop → screenIsUnlocked.
    /// `didstop` is observed purely as a backstop in case `willstop` is missed;
    /// whichever lands first wins and the other is a no-op.
    private func observeScreenSaverLifecycle() {
        // The System Settings thumbnail lives in its own host and is driven by
        // startAnimation/stopAnimation. It must not react to the real saver's
        // session, or opening System Settings during a screensaver cycle would
        // leave the thumbnail frozen forever.
        guard !effectiveIsPreview else { return }
        let center = DistributedNotificationCenter.default()
        func observe(_ name: String, _ handler: @escaping (LerpSaverView, String) -> Void) {
            let token = center.addObserver(forName: Notification.Name(name),
                                           object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Self.log.info("notification \(name, privacy: .public)")
                handler(self, name)
            }
            lifecycleObservers.append(token)
        }
        observe("com.apple.screensaver.willstart") { view, reason in view.beginSession(reason) }
        observe("com.apple.screensaver.didstart") { view, reason in view.beginSession(reason) }
        observe("com.apple.screensaver.willstop") { view, reason in view.endSession(reason) }
        observe("com.apple.screensaver.didstop") { view, reason in view.endSession(reason) }
    }

    private func beginSession(_ reason: String) {
        Self.sessionActive = true
        startRendering(reason)
    }

    private func startRendering(_ reason: String) {
        guard !rendering else { return }
        rendering = true
        Self.log.info("[\(self.instanceID)] start rendering (\(reason, privacy: .public))")
        metalView?.config = currentConfig()
        metalView?.start()
    }

    /// Stops rendering. The window, its layer and the last presented drawable
    /// all stay alive, so whatever is on screen (lock screen, desktop) keeps
    /// showing the frame we ended on instead of black.
    private func endSession(_ reason: String) {
        Self.sessionActive = false
        guard rendering else { return }
        rendering = false
        // Read the exact frame the view is on *before* stopping it.
        let frame = capturedFrame()
        metalView?.stop()
        Self.log.info("[\(self.instanceID)] session end (\(reason, privacy: .public)) — display link torn down, window retained")
        if let frame { publishWallpaper(frame) }
    }

    // MARK: - ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        Self.log.info("[\(self.instanceID)] startAnimation preview=\(self.effectiveIsPreview) sessionActive=\(Self.sessionActive) window=\(self.window != nil) level=\(self.window?.level.rawValue ?? 0) size=\(Int(self.bounds.width))x\(Int(self.bounds.height))")
        // The System Settings thumbnail is driven entirely by this call.
        if effectiveIsPreview {
            startRendering("startAnimation/preview")
            return
        }
        // Real saver: rendering is gated on the screensaver notifications, not on
        // this call. legacyScreenSaver also calls startAnimation on hosts that are
        // never visible (the desktop-wallpaper layer), and those hosts never get a
        // stop of any kind — that was the ~5% CPU / ~50% GPU burn. The one
        // exception is an instance built after `didstart` already landed: the
        // session is genuinely running, so it may draw.
        if Self.sessionActive { startRendering("startAnimation/in-session") }
    }

    public override func stopAnimation() {
        super.stopAnimation()
        Self.log.info("[\(self.instanceID)] stopAnimation preview=\(self.effectiveIsPreview)")
        if effectiveIsPreview {
            rendering = false
            metalView?.stop()
        } else {
            // Kept wired up for the macOS versions that do honour it; on 14+ the
            // notification path is what actually fires.
            endSession("stopAnimation")
        }
    }

    public override func animateOneFrame() {
        // Rendering is driven by LerpMetalView's display link.
    }

    // MARK: - Wallpaper handoff

    /// The exact state a wallpaper still has to reproduce.
    private struct CapturedFrame {
        let shaderName: String
        let time: Float
        let seed: Float
    }

    private func capturedFrame() -> CapturedFrame? {
        let enabled = Self.defaults()?.bool(forKey: Settings.wallpaperKey) ?? false
        // legacyScreenSaver builds two view instances per host and only ever puts
        // one of them in a window. The windowless one has a shader and a clock but
        // has never drawn a pixel, so it must not publish anything.
        guard enabled, window != nil, let view = metalView, !view.currentShaderName.isEmpty else {
            Self.log.info("[\(self.instanceID)] wallpaper skipped: enabled=\(enabled) window=\(self.window != nil) shader='\(self.metalView?.currentShaderName ?? "", privacy: .public)'")
            return nil
        }
        return CapturedFrame(shaderName: view.currentShaderName,
                             time: Float(view.time),
                             seed: view.seed)
    }

    /// Directory for generated stills.
    ///
    /// `NSHomeDirectory()` first, because inside legacyScreenSaver that is the
    /// sandbox container and the container is the only place the saver can write:
    /// the real `~/Library/Application Support/Lerping/` is denied outright
    /// ("You don't have permission to save the file"), same as the custom shader
    /// directory. Verified on macOS 27 that `NSWorkspace.setDesktopImageURL`
    /// accepts a container URL and that `wallpaperexportd` mirrors it out to
    /// `/var/db/Wallpapers/<uuid>/Wallpaper.png` for the login window.
    ///
    /// The real home is kept as a second candidate so an unsandboxed host of this
    /// code lands somewhere sensible.
    static func wallpaperDirectoryCandidates() -> [URL] {
        let suffix = "Library/Application Support/Lerping/wallpaper"
        var dirs = [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(suffix)]
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            dirs.append(URL(fileURLWithPath: String(cString: home)).appendingPathComponent(suffix))
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.path).inserted }
    }

    /// First candidate we can actually create and write into. Returns nil (and
    /// logs) when the sandbox denies every one of them.
    static func writableWallpaperDirectory() -> URL? {
        let manager = FileManager.default
        for dir in wallpaperDirectoryCandidates() {
            do {
                try manager.createDirectory(at: dir, withIntermediateDirectories: true)
                let probe = dir.appendingPathComponent(".writable")
                try Data().write(to: probe)
                try? manager.removeItem(at: probe)
                return dir
            } catch {
                log.error("wallpaper dir unusable \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    /// Renders the frame the saver ended on at each screen's native resolution,
    /// writes it to a brand-new file (rewriting the same URL does not refresh the
    /// desktop picture) and hands it to NSWorkspace.
    private func publishWallpaper(_ frame: CapturedFrame) {
        // NSScreen is main-thread state; snapshot what we need here.
        let targets: [(screen: NSScreen, pixels: CGSize)] = NSScreen.screens.map { screen in
            let scale = screen.backingScaleFactor
            return (screen, CGSize(width: max(1, screen.frame.width * scale),
                                   height: max(1, screen.frame.height * scale)))
        }
        guard !targets.isEmpty, let directory = Self.writableWallpaperDirectory() else { return }
        let shaderName = frame.shaderName, time = frame.time, seed = frame.seed
        let stamp = UUID().uuidString.prefix(8)

        DispatchQueue.global(qos: .utility).async {
            // A private renderer/library: the view's own are main-thread state.
            guard let renderer = LerpRenderer() else {
                Self.log.error("wallpaper: no Metal device")
                return
            }
            let library = ShaderLibrary(device: renderer.device)
            guard let shader = library.shader(named: shaderName) else {
                Self.log.error("wallpaper: shader \(shaderName, privacy: .public) not found")
                return
            }

            var written: [(NSScreen, URL)] = []
            for (index, target) in targets.enumerated() {
                let url = directory.appendingPathComponent("\(shaderName)-\(stamp)-\(index).png")
                let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                                 width: Int(target.pixels.width),
                                                 height: Int(target.pixels.height),
                                                 time: time, seed: seed, to: url)
                if let error = result.error {
                    Self.log.error("wallpaper: render failed: \(error, privacy: .public)")
                } else {
                    Self.log.info("wallpaper: wrote \(url.path, privacy: .public) \(Int(target.pixels.width))x\(Int(target.pixels.height)) luma=\(result.meanLuminance)")
                    written.append((target.screen, url))
                }
            }
            guard !written.isEmpty else { return }

            DispatchQueue.main.async {
                var applied: Set<String> = []
                for (screen, url) in written {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                        applied.insert(url.lastPathComponent)
                        Self.log.info("wallpaper: set on \(screen.localizedName, privacy: .public)")
                    } catch {
                        Self.log.error("wallpaper: setDesktopImageURL failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                guard !applied.isEmpty else { return }
                Self.pruneWallpapers(in: directory, keeping: applied)
            }
        }
    }

    /// Bounds the directory. Every frame needs a brand-new filename (rewriting a
    /// URL does not refresh the desktop picture), so old ones have to go.
    ///
    /// Age-based rather than "delete everything I did not just write": with more
    /// than one display macOS can run more than one saver host, and a strict
    /// keep-set would let one host delete the still another host had just handed
    /// to the wallpaper agent.
    static func pruneWallpapers(in directory: URL, keeping: Set<String>, olderThan age: TimeInterval = 120) {
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for url in contents where url.pathExtension.lowercased() == "png" && !keeping.contains(url.lastPathComponent) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? manager.removeItem(at: url)
        }
    }

    // MARK: - Configure sheet

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
                            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Lerping@Home"

        let shaderNames = discoveredShaderNames()
        let settings = Settings.load(from: Self.defaults(), discovered: shaderNames)

        let shaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shaderPopup.addItem(withTitle: Settings.shuffleTitle)
        shaderPopup.addItems(withTitles: shaderNames)
        shaderPopup.selectItem(withTitle: shaderNames.contains(settings.shader)
                               ? settings.shader : Settings.shuffleTitle)
        shaderPopup.target = self
        shaderPopup.action = #selector(shaderModeChanged)

        // Rotation subset. Unset defaults mean "everything", so an upgrade (or a
        // fresh install) starts with every shader checked.
        rotationNames = shaderNames
        rotationEnabled = Set(LerpMetalView.Config.rotation(of: settings.enabledShaders,
                                                           from: shaderNames))

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 20
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shader")))
        table.dataSource = self
        table.delegate = self
        rotationTable = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 230),
            scroll.heightAnchor.constraint(equalToConstant: 200),
        ])

        func listButton(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            return button
        }
        let selectAll = listButton("Select All", #selector(selectAllShaders))
        let deselectAll = listButton("Deselect All", #selector(deselectAllShaders))
        rotationButtons = [selectAll, deselectAll]
        let listControls = NSStackView(views: [selectAll, deselectAll])
        listControls.spacing = 8

        // Always-present status line: keeps the sheet a fixed height and says
        // out loud what an empty selection will do.
        let note = NSTextField(labelWithString: "")
        note.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 230).isActive = true
        rotationNote = note

        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["24", "30", "60"])
        fpsPopup.selectItem(withTitle: String(settings.fps))

        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scalePopup.addItems(withTitles: Self.renderScales.map(\.title))
        scalePopup.selectItem(at: Self.index(of: settings.renderScale,
                                             in: Self.renderScales, default: 0))

        let freezePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        freezePopup.addItems(withTitles: Self.freezeChoices.map(\.title))
        freezePopup.selectItem(at: Self.index(of: settings.freezeMinutes,
                                              in: Self.freezeChoices, default: 3))

        // Off unless the user says otherwise: replacing someone's desktop picture
        // behind their back is not a reasonable default.
        let wallpaperCheck = NSButton(checkboxWithTitle: "Set desktop picture to the last frame",
                                      target: nil, action: nil)
        wallpaperCheck.state = settings.setsWallpaper ? .on : .off
        wallpaperCheck.toolTip = "When the screensaver stops, render the frame it ended on and "
            + "make it the desktop picture, so the desktop, lock screen and login window all match."

        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }

        let inRotation = label("In rotation:")
        rotationLabel = inRotation

        let grid = NSGridView(views: [
            [label("Shader:"), shaderPopup],
            [inRotation, scroll],
            [NSGridCell.emptyContentView, listControls],
            [NSGridCell.emptyContentView, note],
            [label("Frame rate:"), fpsPopup],
            [label("Render scale:"), scalePopup],
            [label("Still image:"), freezePopup],
            [label("On stop:"), wallpaperCheck],
        ])
        grid.column(at: 0).width = 100
        grid.rowAlignment = .firstBaseline
        grid.row(at: 1).topPadding = 6
        grid.row(at: 1).yPlacement = .top
        grid.row(at: 2).yPlacement = .center
        grid.row(at: 3).bottomPadding = 6
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
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        self.configPanel = panel
        self.shaderPopup = shaderPopup
        self.fpsPopup = fpsPopup
        self.scalePopup = scalePopup
        self.freezePopup = freezePopup
        self.wallpaperCheckbox = wallpaperCheck
        updateRotationControls()
        // Grow the sheet to whatever the rotation list needs.
        let fitting = content.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 360), height: max(fitting.height, 300)))
        return panel
    }

    // MARK: - Rotation list

    private var isShuffleMode: Bool { (shaderPopup?.indexOfSelectedItem ?? 0) == 0 }

    @objc private func shaderModeChanged() {
        updateRotationControls()
    }

    @objc private func selectAllShaders() {
        rotationEnabled = Set(rotationNames)
        updateRotationControls()
    }

    @objc private func deselectAllShaders() {
        rotationEnabled.removeAll()
        updateRotationControls()
    }

    @objc private func rotationCheckboxToggled(_ sender: NSButton) {
        guard rotationNames.indices.contains(sender.tag) else { return }
        let name = rotationNames[sender.tag]
        if sender.state == .on {
            rotationEnabled.insert(name)
        } else {
            rotationEnabled.remove(name)
        }
        updateRotationControls()
    }

    /// The list only applies to shuffle mode; pinning one shader greys it out.
    private func updateRotationControls() {
        let active = isShuffleMode
        rotationTable?.isEnabled = active
        rotationTable?.reloadData()
        rotationButtons.forEach { $0.isEnabled = active }
        rotationLabel?.textColor = active ? .labelColor : .disabledControlTextColor
        rotationNote?.textColor = active ? .secondaryLabelColor : .disabledControlTextColor
        if rotationNames.isEmpty {
            rotationNote?.stringValue = "No shaders found."
        } else if !active {
            rotationNote?.stringValue = "Rotation applies to Shuffle."
        } else if rotationEnabled.isEmpty {
            rotationNote?.stringValue = "Nothing checked — using all \(rotationNames.count)."
        } else {
            rotationNote?.stringValue = "\(rotationEnabled.count) of \(rotationNames.count) shaders in rotation."
        }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rotationNames.count }

    public func tableView(_ tableView: NSTableView,
                          viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        guard rotationNames.indices.contains(row) else { return nil }
        let name = rotationNames[row]
        let check = NSButton(checkboxWithTitle: name,
                             target: self,
                             action: #selector(rotationCheckboxToggled(_:)))
        check.tag = row
        check.state = rotationEnabled.contains(name) ? .on : .off
        check.isEnabled = isShuffleMode
        return check
    }

    @objc private func configureSheetOK() {
        if let defaults = Self.defaults() {
            var settings = Settings()
            settings.shader = shaderPopup?.titleOfSelectedItem ?? Settings.shuffleTitle
            settings.enabledShaders = rotationEnabled
            settings.fps = Int(fpsPopup?.titleOfSelectedItem ?? "30") ?? 30
            settings.renderScale = Self.value(of: scalePopup, in: Self.renderScales, default: 0)
            settings.freezeMinutes = Self.value(of: freezePopup, in: Self.freezeChoices, default: 3)
            settings.setsWallpaper = wallpaperCheckbox?.state == .on
            settings.save(to: defaults, rotation: rotationNames)
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
        rotationTable = nil
        rotationLabel = nil
        rotationNote = nil
        rotationButtons = []
        wallpaperCheckbox = nil
    }
}

/// Everything the saver persists: the key strings, the defaults, and the round
/// trip through `ScreenSaverDefaults`, in one place.
///
/// These keys used to be read once in `currentConfig()`, read a second time
/// with the same literals to populate the Options sheet, and written back from
/// a third set in `configureSheetOK` — three places for a renamed key to turn
/// into a setting that silently stops applying.
private struct Settings {

    /// The `shader` value — and the Options popup's first item — that means
    /// "shuffle the rotation" rather than pinning one shader.
    static let shuffleTitle = "Shuffle"

    private static let shaderKey = "shader"
    private static let fpsKey = "fps"
    private static let renderScaleKey = "renderScale"
    private static let shuffleMinutesKey = "shuffleMinutes"
    private static let freezeMinutesKey = "freezeAfterMinutes"
    /// Names the user wants in the shuffle rotation.
    private static let enabledShadersKey = "enabledShaders"
    /// Every shader that existed the last time the rotation was saved. Anything
    /// discovered later counts as new and joins the rotation automatically.
    private static let knownShadersKey = "knownShaders"
    /// Opt-in: hand the last rendered frame off to the desktop picture.
    static let wallpaperKey = "setWallpaperOnStop"

    /// `shuffleTitle`, or the name of the single pinned shader.
    var shader = shuffleTitle
    var fps = 30
    var renderScale = 1.0
    /// No UI offers this one; it is read but never written back.
    var shuffleMinutes = 5.0
    var freezeMinutes = 30.0
    var setsWallpaper = false
    /// The shuffle rotation — see `LerpMetalView.Config.rotation(of:from:)` for
    /// what nil and empty both mean.
    var enabledShaders: Set<String>?

    static func load(from defaults: UserDefaults?, discovered: [String]) -> Settings {
        var settings = Settings()
        guard let defaults else { return settings }
        settings.shader = defaults.string(forKey: shaderKey) ?? settings.shader
        settings.fps = (defaults.object(forKey: fpsKey) as? Int) ?? settings.fps
        settings.renderScale = (defaults.object(forKey: renderScaleKey) as? Double) ?? settings.renderScale
        settings.shuffleMinutes = (defaults.object(forKey: shuffleMinutesKey) as? Double) ?? settings.shuffleMinutes
        settings.freezeMinutes = (defaults.object(forKey: freezeMinutesKey) as? Double) ?? settings.freezeMinutes
        settings.setsWallpaper = defaults.bool(forKey: wallpaperKey)
        settings.enabledShaders = savedRotation(discovered: discovered, defaults: defaults)
        return settings
    }

    /// Writes back everything the Options sheet controls. `rotation` is the full
    /// shader list the sheet offered, in display order; an empty one leaves the
    /// saved rotation alone, so a host that discovered nothing cannot wipe it.
    func save(to defaults: UserDefaults, rotation: [String]) {
        defaults.set(shader, forKey: Self.shaderKey)
        if !rotation.isEmpty {
            defaults.set(LerpMetalView.Config.rotation(of: enabledShaders, from: rotation),
                         forKey: Self.enabledShadersKey)
            defaults.set(rotation, forKey: Self.knownShadersKey)
        }
        defaults.set(fps, forKey: Self.fpsKey)
        defaults.set(renderScale, forKey: Self.renderScaleKey)
        defaults.set(freezeMinutes, forKey: Self.freezeMinutesKey)
        defaults.set(setsWallpaper, forKey: Self.wallpaperKey)
        defaults.synchronize()
    }

    /// What these settings ask the view to render.
    var config: LerpMetalView.Config {
        var config = LerpMetalView.Config(
            shaderName: shader == Self.shuffleTitle ? nil : shader,
            framesPerSecond: fps,
            renderScale: renderScale,
            shuffleInterval: shuffleMinutes * 60,
            freezeAfter: freezeMinutes * 60)
        config.enabledShaderNames = enabledShaders
        return config
    }

    /// The shuffle rotation implied by saved defaults, or nil for "every shader".
    ///
    /// - Nothing ever saved (including every install that predates this setting):
    ///   nil, i.e. the full rotation. Never an empty one.
    /// - Saved names that no longer exist are dropped.
    /// - Shaders discovered since the last save default to enabled, so dropping a
    ///   new .metal file into the bundle does not silently do nothing.
    /// - An empty result is reported as nil (all shaders) rather than a black
    ///   screen. The sheet also refuses to persist an empty set, so this only
    ///   fires for hand-edited defaults or a rotation gone entirely stale.
    private static func savedRotation(discovered: [String], defaults: UserDefaults?) -> Set<String>? {
        guard let saved = defaults?.stringArray(forKey: enabledShadersKey) else { return nil }
        let all = Set(discovered)
        // No roster saved: take the saved list at face value, nothing is "new".
        let known = Set(defaults?.stringArray(forKey: knownShadersKey) ?? discovered)
        let enabled = all.intersection(saved).union(all.subtracting(known))
        return enabled.isEmpty ? nil : enabled
    }
}
