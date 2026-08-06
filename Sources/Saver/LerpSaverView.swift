import AppKit
import OSLog
import ScreenSaver

/// Thin ScreenSaverView shim around LerpMetalView, with the known
/// legacyScreenSaver workarounds baked in:
///
/// - **It always draws.** legacyScreenSaver spawns the host process *after* the
///   `com.apple.screensaver.willstart`/`didstart` notifications have been
///   broadcast, and distributed notifications are not queued, so a fresh
///   process can never see the start of its own session. Gating rendering on
///   them produced a permanently black screensaver, twice. `startAnimation`
///   therefore renders, unconditionally.
/// - **Except when it can prove nothing it draws can be on screen.** The same
///   API also builds full-screen hosts at the desktop-wallpaper layer that are
///   never shown and never stopped; those used to render forever (measured:
///   5.5% CPU, 43-55% GPU, with the user at their desktop). See
///   "Hosts that are never shown" below for what counts as proof and why each
///   of the obvious signals — window level, `kCGWindowIsOnscreen`, occlusion —
///   does not.
/// - We never terminate the host: a retained window with an intact backing
///   store costs nothing (measured: 0.00 s over 30 s) and keeps the lock screen
///   deterministic — it shows the frame we stopped on instead of racing an
///   `exit(0)` against the lock UI.
/// - The stop notifications *are* delivered, and are the primary way a session
///   ends. `stopAnimation` also fires on macOS 27, ~400 ms after `didstop`.
/// - `isPreview` is unreliable on recent macOS, so a small frame also counts
///   as preview. Preview instances keep the classic startAnimation/stopAnimation
///   contract and ignore all of the above, so a real screensaver cycle cannot
///   freeze the System Settings thumbnail and no verdict can slow it down.
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
    /// Logged rather than obeyed — a host never sees the start of its own
    /// session — but a long-lived host does see later ones, which is what
    /// un-parks it.
    private static var sessionActive = false
    /// Instances that have started rendering for the current session, so the
    /// second start is a no-op instead of a double display link.
    private var rendering = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// See "Hosts that are never shown".
    private var hostWatch: Timer?
    private var renderingSince: CFTimeInterval = 0
    private var presenceSamples = 0
    private var parkedReason: String?
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
    /// The saved rotation as it stood when this sheet was built. `OK` merges
    /// against it, so a sheet left open while the playground's gallery is
    /// clicked writes back only what *this* sheet changed.
    private var rotationBase: LerpRotationState?

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
        hostWatch?.invalidate()
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
        // A host that was parked has just been told, by the system, that a
        // screensaver session is starting. Whatever it concluded about itself
        // during the last one no longer applies.
        unpark(reason)
        startRendering(reason)
    }

    private func startRendering(_ reason: String) {
        renderingSince = CACurrentMediaTime()
        presenceSamples = 0
        guard !rendering else { return }
        rendering = true
        Self.log.info("[\(self.instanceID)] start rendering (\(reason, privacy: .public))")
        metalView?.config = currentConfig()
        metalView?.start()
        if !effectiveIsPreview { startHostWatch() }
    }

    /// Stops rendering. The window, its layer and the last presented drawable
    /// all stay alive, so whatever is on screen (lock screen, desktop) keeps
    /// showing the frame we ended on instead of black.
    private func endSession(_ reason: String) {
        Self.sessionActive = false
        stopHostWatch()
        parkedReason = nil
        presenceSamples = 0
        guard rendering else { return }
        rendering = false
        // Read the exact frame the view is on *before* stopping it.
        let frame = capturedFrame()
        metalView?.stop()
        Self.log.info("[\(self.instanceID)] session end (\(reason, privacy: .public)) — display link torn down, window retained")
        if let frame { publishWallpaper(frame) }
    }

    // MARK: - Hosts that are never shown

    /// legacyScreenSaver builds two kinds of full-screen host and gives them no
    /// way to tell each other apart. One is the screensaver the user is looking
    /// at. The other is never displayed, never receives a stop of any kind, and
    /// used to render until the machine was rebooted — 5.5% CPU and 43-55% GPU,
    /// with the user sitting at their desktop.
    ///
    /// Measured on macOS 27, and each one rules out an obvious fix:
    ///
    /// - Both sit at window level -2147483625, the wallpaper layer. So does
    ///   WallpaperAgent's own window. Level says nothing.
    /// - The host that is *visibly rendering the screensaver* has
    ///   `kCGWindowIsOnscreen` **false** on its own window, for the whole
    ///   session: its layer is composited into a window belonging to
    ///   WallpaperAgent, and its own window is never ordered in. Sampled once a
    ///   second from outside the process, across a real 11-minute activation.
    ///   Anything keyed on the host's own window being on screen — including
    ///   `NSWindow.isVisible` and `occlusionState`, which is why occlusion
    ///   notifications never arrive either — blacks out the real screensaver.
    /// - The start notifications cannot help: the host is spawned after they
    ///   are broadcast, and they are not queued.
    ///
    /// So the saver does not try to classify itself. It draws, and it stops
    /// drawing only when it can *prove* that nothing it draws can be on screen.
    /// The three proofs below are states in which no screensaver can be
    /// displayed in this session at all, so none of them can be true of the
    /// host the user is looking at. Against them stands one piece of positive
    /// evidence — a frame of ours that actually reached a display — which
    /// overrides all three.
    ///
    /// And the penalty is one frame a second, not zero: a host parked by
    /// mistake is a slow screensaver for one second, never a black one, and the
    /// frame it draws each second is also what re-tests the verdict.

    /// Full rate for this long after `startAnimation` before any verdict. The
    /// window has to be picked up and composited by its host process first, and
    /// eight seconds of a rate we would have run anyway costs nothing.
    private static let verdictGrace: TimeInterval = 8
    /// How recent an input event has to be to count as somebody being here.
    private static let inputRecency: TimeInterval = 2
    /// …and for how many consecutive one-second samples. Any input at all ends
    /// a screensaver, so five seconds of continuous input means this host is
    /// certainly not showing one. A single stray event is not enough.
    private static let presenceSamples = 5
    /// How fresh the last scanned-out frame has to be to veto a park.
    private static let displayedRecency: TimeInterval = 2

    private func startHostWatch() {
        guard hostWatch == nil else { return }
        // Weakly, so the timer is not what keeps a view alive: legacyScreenSaver
        // already never destroys one, and a retain cycle on top of that would
        // mean `deinit` could not run even in the hosts that do.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkWhetherAnyoneCanSeeThis()
        }
        RunLoop.main.add(timer, forMode: .common)
        hostWatch = timer
    }

    private func stopHostWatch() {
        hostWatch?.invalidate()
        hostWatch = nil
    }

    private func checkWhetherAnyoneCanSeeThis() {
        guard rendering, let view = metalView else { return }
        // "Still image after N minutes" has already taken the display link
        // away and is holding the frame the user asked to keep. Parking it
        // would change nothing and drawing it once a second would undo it.
        guard !view.isFrozen else { return }
        let now = CACurrentMediaTime()

        // Positive evidence, and the only kind there is: a frame this view drew
        // was scanned out to a display within the last couple of seconds. It
        // beats every proof below, because those are arguments and this is the
        // thing itself.
        if now - view.lastDisplayedFrameTime < Self.displayedRecency {
            presenceSamples = 0
            unpark("a frame reached a display")
            return
        }

        // One frame a second while parked: enough that a host parked by mistake
        // is slow rather than frozen, and enough to keep asking the question
        // above. Costs ~1/30th of what running does.
        if parkedReason != nil { view.renderOnce() }

        let idle = Self.secondsSinceLastInput()
        presenceSamples = idle < Self.inputRecency ? presenceSamples + 1 : 0

        let proof: String?
        if Self.everyDisplayAsleep() {
            proof = "every display is asleep"
        } else if !Self.sessionIsOnConsole() {
            proof = "this session is not on the console"
        } else if presenceSamples >= Self.presenceSamples {
            proof = "somebody has been working at this machine for \(presenceSamples)s"
        } else {
            proof = nil
        }

        guard let proof, now - renderingSince > Self.verdictGrace else { return }
        park(proof)
    }

    private func park(_ reason: String) {
        guard parkedReason == nil else { return }
        parkedReason = reason
        metalView?.park()
        Self.log.info("[\(self.instanceID)] parked at 1 fps — \(reason, privacy: .public)")
    }

    private func unpark(_ reason: String) {
        // Also resets the grace period: whatever just happened is a fresh
        // reason to believe this host might be the one on screen.
        renderingSince = CACurrentMediaTime()
        guard let parked = parkedReason else { return }
        parkedReason = nil
        metalView?.unpark()
        Self.log.info("[\(self.instanceID)] resumed — \(reason, privacy: .public) (was parked: \(parked, privacy: .public))")
    }

    /// Seconds since the last input event of any kind in this session.
    /// Verified to work, and to advance, inside legacyScreenSaver's sandbox —
    /// see the `hid-idle-seconds` check in `make sandbox-probe`.
    private static func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    /// True when there is no awake display to put a screensaver on. A machine
    /// with no displays at all counts, for the same reason.
    private static func everyDisplayAsleep() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return !ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }

    /// False after a fast user switch, when this session owns no screen.
    ///
    /// The key really does carry the extra S; `kCGSessionOnConsoleKey` is a
    /// CFSTR macro for `"kCGSSessionOnConsoleKey"` and macros do not reach
    /// Swift. Confirmed against a live dictionary, and by the
    /// `session-dictionary` check in `make sandbox-probe`.
    private static func sessionIsOnConsole() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session["kCGSSessionOnConsoleKey"] as? NSNumber
        else { return true }   // unreadable: assume we are, and keep drawing
        return onConsole.boolValue
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
        // Real saver: draw, unconditionally. Gating this on `didstart` produced
        // a black screensaver, because legacyScreenSaver spawns the host *after*
        // that notification has already been broadcast — distributed
        // notifications are not queued, so a freshly spawned process can never
        // observe it. Observed on macOS 27: the visible full-screen host logs
        // `sessionActive=false` at startAnimation and only ever receives
        // willstop/didstop.
        //
        // What keeps a host that is never displayed from rendering forever is
        // not this decision but the watchdog `startRendering` arms — see
        // "Hosts that are never shown". Being wrong there costs one frame a
        // second; being wrong here costs a black screen.
        unpark("startAnimation")
        startRendering("startAnimation")
    }

    public override func stopAnimation() {
        super.stopAnimation()
        Self.log.info("[\(self.instanceID)] stopAnimation preview=\(self.effectiveIsPreview) parked=\(self.parkedReason ?? "no", privacy: .public)")
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
        rotationBase = settings.rotationBase

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
    /// What this host is doing right now, as one line.
    ///
    /// `@objc` for the same reason as `rotationStillsSummary`: the claims this
    /// file makes — that a host always draws, that one nothing can see drops to
    /// a frame a second, that a host being shown never does — are only worth
    /// anything if a harness in another process, which cannot see a single type
    /// this bundle defines, can read them back.
    @objc public var renderStateSummary: String {
        let displayed = metalView?.lastDisplayedFrameTime ?? 0
        let since = displayed > 0
            ? String(format: "%.2fs", CACurrentMediaTime() - displayed) : "never"
        return "rendering=\(rendering ? 1 : 0) parked=\(parkedReason ?? "no") "
            + String(format: "fps=%.1f ", metalView?.measuredFPS ?? 0)
            + "lastDisplayedFrame=\(since) shader=\(metalView?.currentShaderName ?? "")"
    }

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
            settings.rotationBase = rotationBase
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
    /// Opt-in: hand the last rendered frame off to the desktop picture.
    static let wallpaperKey = "setWallpaperOnStop"

    /// Which host this is, in the saved state's `writer` field. Diagnostics
    /// only — nothing branches on it — but "who turned this back on?" was not
    /// answerable at all before, and two processes write this domain.
    static let writerName = "saver"

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
    /// The persisted rotation exactly as this load found it. Carried so that
    /// `save` can tell whether anything landed in the domain while the sheet was
    /// open, and merge rather than trample if it did. See `LerpRotation.write`.
    var rotationBase: LerpRotationState?

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
        settings.rotationBase = LerpRotation.read(defaults, discovered: discovered)
        settings.enabledEntries = LerpRotation.enabled(discovered: discovered, in: defaults)
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
        let state = LerpRotation.write(enabled: enabledEntries, base: rotationBase,
                                       discovered: entries, writer: Self.writerName,
                                       to: defaults)
        defaults.set(fps, forKey: Self.fpsKey)
        defaults.set(renderScale, forKey: Self.renderScaleKey)
        defaults.set(freezeMinutes, forKey: Self.freezeMinutesKey)
        defaults.set(setsWallpaper, forKey: Self.wallpaperKey)
        defaults.synchronize()
        LerpSaverView.log.info("options: saved rotation \(state.summary, privacy: .public)")
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

}
