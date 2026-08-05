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
public final class LerpSaverView: ScreenSaverView {

    /// The ByHost preferences module the saver reads and the Options… sheet
    /// writes.
    ///
    /// Overridable by environment variable *only* so a test host can be pointed
    /// at a throwaway domain of the same shape — `make test-load` presses OK on
    /// the real sheet, and pressing OK on a real sheet against the user's live
    /// rotation is not a test, it is a bug waiting for a badly-timed kill. The
    /// screensaver itself is never launched with this set, so the default is
    /// what every real host uses.
    static let defaultsModule =
        ProcessInfo.processInfo.environment["LERP_DEFAULTS_MODULE"] ?? "com.hergenroeder.lerping"
    static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "saver")

    private var metalView: LerpMetalView?
    private var effectiveIsPreview = false
    private var configPanel: NSPanel?
    private var shaderPopup: NSPopUpButton?
    private var presetPopup: NSPopUpButton?
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

    // Rotation state, live only while the configure sheet is open.
    private var rotationShaders: [LerpShader] = []
    private var rotationEntries: [LerpRotationEntry] = []
    private var rotationEnabled: Set<LerpRotationEntry> = []
    private var rotationGallery: RotationGalleryView?
    private var rotationLabel: NSTextField?

    /// Stills for the Options… gallery, kept on the view rather than on the
    /// sheet: legacyScreenSaver builds the view once and the sheet every time
    /// Options… is pressed, so this is what makes the second open instant.
    private lazy var thumbnails = RotationThumbnails(
        searchURLs: [],
        directory: RotationThumbnails.writableCacheDirectory(named: Self.thumbnailCacheName),
        readOnlyDirectories: RotationThumbnails.bundledDirectories())

    /// Under `Library/Caches` — of the sandbox container inside
    /// legacyScreenSaver, of the real home anywhere else. See
    /// `RotationThumbnails.writableCacheDirectory`.
    private static let thumbnailCacheName = "com.hergenroeder.lerping/RotationThumbnails"

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

    private func discoveredShaders() -> [LerpShader] {
        metalView?.shaderLibrary.discover() ?? []
    }

    private func currentConfig() -> LerpMetalView.Config {
        Settings.load(from: Self.defaults(), discovered: discoveredShaders().rotationEntries()).config
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

    /// The exact state a wallpaper still has to reproduce. The rotation entry
    /// rather than a bare shader name: the still is rendered in a second process
    /// from scratch, so it has to be told which preset was on screen or it
    /// reproduces the defaults instead.
    private struct CapturedFrame {
        let entry: LerpRotationEntry
        let time: Float
        let seed: Float
    }

    private func capturedFrame() -> CapturedFrame? {
        let enabled = Self.defaults()?.bool(forKey: Settings.wallpaperKey) ?? false
        // legacyScreenSaver builds two view instances per host and only ever puts
        // one of them in a window. The windowless one has a shader and a clock but
        // has never drawn a pixel, so it must not publish anything.
        guard enabled, window != nil, let view = metalView, let entry = view.currentEntry,
              !entry.shader.isEmpty else {
            Self.log.info("[\(self.instanceID)] wallpaper skipped: enabled=\(enabled) window=\(self.window != nil) shader='\(self.metalView?.currentShaderName ?? "", privacy: .public)'")
            return nil
        }
        return CapturedFrame(entry: entry, time: Float(view.time), seed: view.seed)
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
        let entry = frame.entry, time = frame.time, seed = frame.seed
        let shaderName = entry.shader
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
            // Same (shader, time, seed, params) the view was rendering, so the
            // still is the frame the saver stopped on and not a different look.
            var values = shader.defaultParameterValues()
            if let name = entry.preset, let preset = shader.preset(named: name) {
                values.apply(preset)
            }

            var written: [(NSScreen, URL)] = []
            for (index, target) in targets.enumerated() {
                let url = directory.appendingPathComponent("\(shaderName)-\(stamp)-\(index).png")
                let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                                 width: Int(target.pixels.width),
                                                 height: Int(target.pixels.height),
                                                 time: time, seed: seed, params: values, to: url)
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

    /// How wide one look is drawn in the sheet. Narrower than the playground's
    /// 134, because the sheet is a sheet: at this width two shaders' worth of
    /// looks sit side by side in the default 900-point panel, which is what
    /// keeps a 31-shader gallery to a scroll rather than a trek.
    private static let sheetTileWidth: CGFloat = 102
    private static let sheetWidth: CGFloat = 900
    /// How much of the sheet the gallery gets when it opens. The sheet is
    /// resizable and the gallery reflows, so this is a starting point rather
    /// than a shape — `sheetGalleryFloor` is the constraint that actually holds.
    private static let sheetGalleryHeight: CGFloat = 430
    private static let sheetGalleryFloor: CGFloat = 260

    public override var configureSheet: NSWindow? {
        let sheetStarted = CFAbsoluteTimeGetCurrent()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 640),
                            styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        panel.title = "Lerping@Home"

        let shaders = discoveredShaders()
        let shaderNames = shaders.map(\.name)
        let entries = shaders.rotationEntries()
        let settings = Settings.load(from: Self.defaults(), discovered: entries)

        let shaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shaderPopup.addItem(withTitle: Settings.shuffleTitle)
        shaderPopup.addItems(withTitles: shaderNames)
        shaderPopup.selectItem(withTitle: shaderNames.contains(settings.shader)
                               ? settings.shader : Settings.shuffleTitle)
        shaderPopup.target = self
        shaderPopup.action = #selector(shaderModeChanged)

        // Pinning is (shader, preset) too, so a pin can reach any of the 114
        // looks and not just the 31 sets of defaults.
        let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)

        // Rotation subset. Unset defaults mean "everything", so an upgrade (or a
        // fresh install) starts with every entry checked.
        rotationShaders = shaders
        rotationEntries = entries
        rotationEnabled = Set(LerpMetalView.Config.rotation(of: settings.enabledEntries, from: entries))

        // The gallery. Built from the same `rotationEntries()` the shuffle
        // itself walks, so it cannot show a look the rotation does not offer.
        // Nothing here waits on a picture: the tiles go up now and fill in as
        // the stills land — see `startRotationStills`.
        let gallery = RotationGalleryView(
            frame: NSRect(x: 0, y: 0, width: Self.sheetWidth - 40, height: Self.sheetGalleryHeight),
            tileSize: RotationTile.size(width: Self.sheetTileWidth),
            showsRegenerate: false)
        gallery.translatesAutoresizingMaskIntoConstraints = false
        gallery.wantsLayer = true
        gallery.layer?.cornerRadius = 6
        gallery.layer?.masksToBounds = true
        gallery.show(shaders: shaders, enabled: rotationEnabled)
        // The sheet has an OK button, so unlike the playground's gallery this
        // one only collects; `configureSheetOK` is what writes.
        gallery.onChange = { [weak self] enabled in self?.rotationEnabled = enabled }
        rotationGallery = gallery

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

        // Two label/control pairs per row rather than one. Six stacked rows of
        // settings above a gallery makes the gallery the afterthought; three
        // short ones make it the page.
        let grid = NSGridView(views: [
            [label("Shader:"), shaderPopup, label("Frame rate:"), fpsPopup],
            [label("Preset:"), presetPopup, label("Render scale:"), scalePopup],
            [label("Still image:"), freezePopup, label("On stop:"), wallpaperCheck],
        ])
        grid.column(at: 0).width = 92
        grid.column(at: 2).leadingPadding = 26
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let inRotation = NSTextField(labelWithString: "In rotation")
        inRotation.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        inRotation.translatesAutoresizingMaskIntoConstraints = false
        rotationLabel = inRotation

        let ok = NSButton(title: "OK", target: self, action: #selector(configureSheetOK))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(configureSheetCancel))
        let buttons = NSStackView(views: [cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(grid)
        content.addSubview(inRotation)
        content.addSubview(gallery)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),

            inRotation.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            inRotation.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),

            gallery.topAnchor.constraint(equalTo: inRotation.bottomAnchor, constant: 7),
            gallery.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            gallery.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            gallery.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.sheetGalleryFloor),

            buttons.topAnchor.constraint(equalTo: gallery.bottomAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        self.configPanel = panel
        self.shaderPopup = shaderPopup
        self.presetPopup = presetPopup
        self.fpsPopup = fpsPopup
        self.scalePopup = scalePopup
        self.freezePopup = freezePopup
        self.wallpaperCheckbox = wallpaperCheck
        reloadPresetPopup(selecting: settings.preset)
        updateRotationControls()
        // `fittingSize` sizes the gallery to its floor, so the difference is
        // what the gallery is short of the height it wants to open at.
        panel.setContentSize(NSSize(
            width: Self.sheetWidth,
            height: content.fittingSize.height + Self.sheetGalleryHeight - Self.sheetGalleryFloor))
        panel.minSize = NSSize(width: 620, height: 460)
        startRotationStills(shaders)
        Self.log.info("options: sheet built in \(Int((CFAbsoluteTimeGetCurrent() - sheetStarted) * 1000)) ms, \(entries.count) looks, \(self.rotationEnabled.count) in rotation")
        return panel
    }

    // MARK: - Rotation stills

    /// Starts filling the gallery in. Returns immediately, always: opening
    /// Options… must not wait on 114 pictures, and inside legacyScreenSaver it
    /// must not wait on a GPU either.
    ///
    /// Where the pictures come from, cheapest first:
    ///
    /// 1. **Memory**, if the sheet has been opened before in this process. That
    ///    is why `thumbnails` hangs off the view and not off the sheet.
    /// 2. **The bundle** — `Contents/Resources/Thumbnails`, rendered by
    ///    `make saver` (and again by `make install`, after any custom shaders
    ///    have been baked in). Inside the sandbox this is the whole gallery,
    ///    every time, with no GPU work at all. The filenames carry a hash of
    ///    each shader's source, so a baked still can never be a stale one: a
    ///    `.metal` that has changed simply misses and is drawn instead.
    /// 3. **The container cache**, for whatever the bundle did not have.
    /// 4. **The GPU**, in parallel, for whatever nothing had.
    private func startRotationStills(_ shaders: [LerpShader]) {
        guard let gallery = rotationGallery else { return }
        let jobs = RotationThumbnails.jobs(for: shaders)
        let started = CFAbsoluteTimeGetCurrent()
        gallery.showProgress(done: 0, total: jobs.count)
        thumbnails.start(jobs,
                         onImage: { [weak self] entry, image in
                             self?.rotationGallery?.show(image: image, for: entry)
                         },
                         onProgress: { [weak self] done, total in
                             self?.rotationGallery?.showProgress(done: done, total: total)
                         },
                         onFinished: { [weak self] in
                             guard let self else { return }
                             let seconds = CFAbsoluteTimeGetCurrent() - started
                             Self.log.info("""
                             options: \(jobs.count) stills in \(String(format: "%.2f", seconds)) s \
                             — \(self.thumbnails.memoryHits) memory, \
                             \(self.thumbnails.bundledHits) bundle, \
                             \(self.thumbnails.diskHits - self.thumbnails.bundledHits) cache, \
                             \(self.thumbnails.rendered) rendered, \
                             \(self.thumbnails.failed.count) failed \
                             (cache: \(self.thumbnails.cacheDirectory.path, privacy: .public))
                             """)
                         })
    }

    /// Where the Options… gallery's stills came from, as one line.
    ///
    /// `@objc` because it is read by KVC from two processes that cannot see a
    /// single type this bundle defines: `make test-load`, and the sandboxed
    /// probe app that establishes what legacyScreenSaver's sandbox actually
    /// permits. "The bundle covered all of it and the GPU did nothing" is the
    /// claim the whole design rests on, so it has to be observable from outside.
    @objc public var rotationStillsSummary: String {
        "memory=\(thumbnails.memoryHits) bundle=\(thumbnails.bundledHits) "
            + "cache=\(thumbnails.diskHits - thumbnails.bundledHits) "
            + "rendered=\(thumbnails.rendered) failed=\(thumbnails.failed.count) "
            + "cache-dir=\(thumbnails.cacheDirectory.path)"
    }

    // MARK: - Rotation list

    private var isShuffleMode: Bool { (shaderPopup?.indexOfSelectedItem ?? 0) == 0 }

    /// The shader the popup is pinned to, or nil in shuffle mode.
    private var pinnedShader: LerpShader? {
        guard !isShuffleMode, let title = shaderPopup?.titleOfSelectedItem else { return nil }
        return rotationShaders.named(title)
    }

    /// The preset popup's first item, which means "the shader's declared
    /// defaults" — the same thing a `nil` preset means everywhere else.
    private static let defaultsTitle = "Defaults"

    /// Rebuilds the preset popup for whatever shader is pinned. Greyed out in
    /// shuffle mode, where each rotation entry brings its own preset.
    private func reloadPresetPopup(selecting preset: String?) {
        guard let popup = presetPopup else { return }
        let shader = pinnedShader
        popup.removeAllItems()
        popup.addItem(withTitle: Self.defaultsTitle)
        popup.addItems(withTitles: shader?.presets.map(\.name) ?? [])
        popup.selectItem(withTitle: preset.flatMap { name in
            shader?.preset(named: name)?.name
        } ?? Self.defaultsTitle)
        popup.isEnabled = shader != nil && (shader?.presets.isEmpty == false)
    }

    /// The preset the popup is on, or nil for the shader's defaults.
    private var selectedPreset: String? {
        guard let popup = presetPopup, popup.indexOfSelectedItem > 0 else { return nil }
        return popup.titleOfSelectedItem
    }

    @objc private func shaderModeChanged() {
        reloadPresetPopup(selecting: nil)
        updateRotationControls()
    }

    /// The gallery only applies to shuffle mode; pinning one shader greys it
    /// out. Select All, Deselect All, the search field, the group headings and
    /// the status line all belong to the gallery — this is the whole of what the
    /// sheet still has to say about them.
    private func updateRotationControls() {
        let active = isShuffleMode
        rotationLabel?.textColor = active ? .labelColor : .disabledControlTextColor
        rotationGallery?.setActive(active, note: rotationEntries.isEmpty
                                   ? "No shaders found."
                                   : "Rotation applies to Shuffle.")
    }

    @objc private func configureSheetOK() {
        if let defaults = Self.defaults() {
            var settings = Settings()
            settings.shader = shaderPopup?.titleOfSelectedItem ?? Settings.shuffleTitle
            settings.preset = selectedPreset
            settings.enabledEntries = rotationEnabled
            settings.fps = Int(fpsPopup?.titleOfSelectedItem ?? "30") ?? 30
            settings.renderScale = Self.value(of: scalePopup, in: Self.renderScales, default: 0)
            settings.freezeMinutes = Self.value(of: freezePopup, in: Self.freezeChoices, default: 3)
            settings.setsWallpaper = wallpaperCheckbox?.state == .on
            settings.save(to: defaults, entries: rotationEntries)
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
        // Whatever stills were still coming are no longer wanted. The decoded
        // ones stay in `thumbnails`, which is what makes reopening instant.
        thumbnails.cancel()
        configPanel = nil
        rotationGallery = nil
        rotationLabel = nil
        rotationShaders = []
        rotationEntries = []
        presetPopup = nil
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
    /// Preset for the pinned shader. Absent means its declared defaults.
    private static let presetKey = "preset"
    private static let fpsKey = "fps"
    private static let renderScaleKey = "renderScale"
    private static let shuffleMinutesKey = "shuffleMinutes"
    private static let freezeMinutesKey = "freezeAfterMinutes"
    /// `LerpRotationEntry.key`s the user wants in the shuffle rotation.
    private static let enabledEntriesKey = "enabledEntries"
    /// Every entry that existed the last time the rotation was saved. Anything
    /// discovered later counts as new and joins the rotation automatically —
    /// including a preset added to a shader that was already there.
    private static let knownEntriesKey = "knownEntries"
    /// The pre-preset shape of the same two keys: sets of shader *names*, from
    /// before the rotation counted presets. Read for migration, and still
    /// written, so a downgrade to an older build finds a sensible subset.
    private static let enabledShadersKey = "enabledShaders"
    private static let knownShadersKey = "knownShaders"
    /// Opt-in: hand the last rendered frame off to the desktop picture.
    static let wallpaperKey = "setWallpaperOnStop"

    /// `shuffleTitle`, or the name of the single pinned shader.
    var shader = shuffleTitle
    /// Preset for the pinned shader, or nil for its declared defaults.
    var preset: String?
    var fps = 30
    var renderScale = 1.0
    /// No UI offers this one; it is read but never written back.
    var shuffleMinutes = 5.0
    var freezeMinutes = 30.0
    var setsWallpaper = false
    /// The shuffle rotation — see `LerpMetalView.Config.rotation(of:from:)` for
    /// what nil and empty both mean.
    var enabledEntries: Set<LerpRotationEntry>?

    static func load(from defaults: UserDefaults?, discovered: [LerpRotationEntry]) -> Settings {
        var settings = Settings()
        guard let defaults else { return settings }
        settings.shader = defaults.string(forKey: shaderKey) ?? settings.shader
        settings.preset = defaults.string(forKey: presetKey)
        settings.fps = (defaults.object(forKey: fpsKey) as? Int) ?? settings.fps
        settings.renderScale = (defaults.object(forKey: renderScaleKey) as? Double) ?? settings.renderScale
        settings.shuffleMinutes = (defaults.object(forKey: shuffleMinutesKey) as? Double) ?? settings.shuffleMinutes
        settings.freezeMinutes = (defaults.object(forKey: freezeMinutesKey) as? Double) ?? settings.freezeMinutes
        settings.setsWallpaper = defaults.bool(forKey: wallpaperKey)
        settings.enabledEntries = savedRotation(discovered: discovered, defaults: defaults)
        return settings
    }

    /// Writes back everything the Options sheet controls. `entries` is the full
    /// rotation the sheet offered, in display order; an empty one leaves the
    /// saved rotation alone, so a host that discovered nothing cannot wipe it.
    func save(to defaults: UserDefaults, entries: [LerpRotationEntry]) {
        defaults.set(shader, forKey: Self.shaderKey)
        if let preset {
            defaults.set(preset, forKey: Self.presetKey)
        } else {
            defaults.removeObject(forKey: Self.presetKey)
        }
        if !entries.isEmpty {
            let picked = LerpMetalView.Config.rotation(of: enabledEntries, from: entries)
            defaults.set(picked.map(\.key), forKey: Self.enabledEntriesKey)
            defaults.set(entries.map(\.key), forKey: Self.knownEntriesKey)
            // A shader counts as in the pre-preset rotation when any of its
            // looks is, so the old keys keep saying something true.
            defaults.set(Self.shaderNames(of: picked), forKey: Self.enabledShadersKey)
            defaults.set(Self.shaderNames(of: entries), forKey: Self.knownShadersKey)
        }
        defaults.set(fps, forKey: Self.fpsKey)
        defaults.set(renderScale, forKey: Self.renderScaleKey)
        defaults.set(freezeMinutes, forKey: Self.freezeMinutesKey)
        defaults.set(setsWallpaper, forKey: Self.wallpaperKey)
        defaults.synchronize()
    }

    /// The shaders these entries name, once each, in order.
    private static func shaderNames(of entries: [LerpRotationEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.shader).filter { seen.insert($0).inserted }
    }

    /// What these settings ask the view to render.
    var config: LerpMetalView.Config {
        let pinned = shader == Self.shuffleTitle ? nil : shader
        var config = LerpMetalView.Config(
            shaderName: pinned,
            presetName: pinned == nil ? nil : preset,
            framesPerSecond: fps,
            renderScale: renderScale,
            shuffleInterval: shuffleMinutes * 60,
            freezeAfter: freezeMinutes * 60)
        config.enabledEntries = enabledEntries
        return config
    }

    /// The shuffle rotation implied by saved defaults, or nil for "every entry".
    ///
    /// - Nothing ever saved (including every install that predates this setting):
    ///   nil, i.e. the full rotation. Never an empty one.
    /// - Saved entries that no longer exist are dropped.
    /// - Entries discovered since the last save default to enabled, so dropping a
    ///   new .metal file into the bundle — or adding a preset to one that is
    ///   already there — does not silently do nothing.
    /// - A rotation saved before presets counted holds a set of shader *names*.
    ///   Every look of a shader that was in it joins: the user picked those
    ///   shaders, and the presets are more of the same shaders, not new ones.
    /// - An empty result is reported as nil (all entries) rather than a black
    ///   screen. The sheet also refuses to persist an empty set, so this only
    ///   fires for hand-edited defaults or a rotation gone entirely stale.
    private static func savedRotation(discovered: [LerpRotationEntry],
                                      defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        guard let defaults else { return nil }
        let all = Set(discovered)
        if let saved = defaults.stringArray(forKey: enabledEntriesKey) {
            // No roster saved: take the saved list at face value, nothing is "new".
            let known = Set((defaults.stringArray(forKey: knownEntriesKey) ?? discovered.map(\.key))
                .map(LerpRotationEntry.init(key:)))
            let enabled = all.intersection(saved.map(LerpRotationEntry.init(key:)))
                .union(all.subtracting(known))
            return enabled.isEmpty ? nil : enabled
        }
        guard let legacy = defaults.stringArray(forKey: enabledShadersKey) else { return nil }
        let shaders = Set(discovered.map(\.shader))
        let knownShaders = Set(defaults.stringArray(forKey: knownShadersKey) ?? Array(shaders))
        let picked = shaders.intersection(legacy).union(shaders.subtracting(knownShaders))
        let enabled = all.filter { picked.contains($0.shader) }
        return enabled.isEmpty ? nil : enabled
    }
}
