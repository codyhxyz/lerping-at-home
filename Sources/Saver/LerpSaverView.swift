import AppKit
import Darwin
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

    /// The ByHost preferences module the saver reads and the Options… sheet writes.
    static let defaultsModule = LerpDefaults.module
    /// The production module, not `defaultsModule` — see `LerpMetalView.log`
    /// for why the subsystem must not move when the domain does.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "saver")

    /// Which commit this bundle was built from, stamped into `Info.plist` by
    /// `make saver-build` and logged on every init.
    ///
    /// `git describe --always --dirty`, not a hash of the source tree. The
    /// source-tree digest that used to live here existed to feed `make doctor`,
    /// which compared it against the working tree and announced "up to date".
    /// It said exactly that while this bug reproduced, because the thing it
    /// checked — do these bytes match those bytes — was never the thing in
    /// doubt. A commit id plus a dirty flag is legible to a human reading the
    /// log, is greppable against `git log`, and makes no claim about
    /// correctness. See AGENTS.md.
    static let buildRevision: String = {
        Bundle(for: LerpSaverView.self).object(forInfoDictionaryKey: "LerpBuild")
            as? String ?? "unstamped"
    }()

    private var metalView: LerpMetalView?
    private var effectiveIsPreview = false
    private var configPanel: NSPanel?
    private var shaderPopup: NSPopUpButton?
    private var presetPopup: NSPopUpButton?
    private var fpsPopup: NSPopUpButton?
    private var scalePopup: NSPopUpButton?
    private var freezePopup: NSPopUpButton?

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
    private static let thumbnailCacheName =
        LerpDefaults.module + "/RotationThumbnails"

    /// The two popups whose items carry a number. See `Chrome.Choices` for why
    /// index ↔ value goes through one table.
    private static let freezeChoices: Chrome.Choices = [        // minutes
        ("Never", 0), ("After 5 minutes", 5), ("After 15 minutes", 15), ("After 30 minutes", 30),
    ]
    /// Fraction of native. Stops at 50%: the playground's copy of this menu goes
    /// down to 25% because a quarter-scale render is a useful thing to *edit*
    /// against, and a visibly soft screensaver is not a useful thing to leave
    /// running all night.
    private static let renderScales: Chrome.Choices = [
        ("100%", 1.0), ("75%", 0.75), ("50%", 0.5),
    ]

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        effectiveIsPreview = isPreview || frame.width < 600
        wantsLayer = true
        setUpMetalView()
        observeScreenSaverLifecycle()
        Self.log.notice("""
            init frame=\(Int(frame.width))x\(Int(frame.height)) isPreview=\(isPreview) \
            effectiveIsPreview=\(self.effectiveIsPreview) \
            build=\(Self.buildRevision, privacy: .public)
            """)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        lifecycleObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        hostWatch?.invalidate()
    }

    /// The saver's *own* settings — the pinned shader, frame rate, render scale,
    /// freeze delay. Inside `legacyScreenSaver` this is Apple's sandbox
    /// container, which is where the Options… sheet writes them and the only
    /// place it can. Nothing else writes these keys, so there is no second
    /// opinion about them to reconcile.
    ///
    /// The rotation is deliberately *not* here. See `savedRotation`.
    private static func defaults() -> ScreenSaverDefaults? {
        ScreenSaverDefaults(forModuleWithName: defaultsModule)
    }

    /// The user's rotation, read from the file the playground writes.
    ///
    /// This used to be loaded into the `ScreenSaverDefaults` above with
    /// `register(defaults:)`. That is the *lowest*-precedence domain, so
    /// anything ever written into Apple's container outranked the file the user
    /// actually edits — and to stop that, `defaults()` had to compare revision
    /// numbers between the two stores and delete container keys when the file
    /// looked newer. Two stores for one truth, refereed at every read.
    ///
    /// The container half is gone: the Options… sheet's gallery no longer
    /// writes (see `configureSheet`), so the ByHost file is the only place a
    /// rotation exists. Reading it by path rather than through `UserDefaults`
    /// removes the last way the two could disagree — no precedence order, no
    /// registration domain, and no `cfprefsd` cache between the bytes the
    /// playground wrote and the bytes this process parses.
    ///
    /// App Sandbox blocks CFPreferences from seeing that domain, but the host
    /// explicitly permits read-only file access, which is why this works at all.
    static func savedRotation(discovered: [LerpRotationEntry]) -> LerpRotationState {
        LerpRotation.read(plist: rotationPlist(), discovered: discovered)
    }

    private static func rotationPlist() -> [String: Any]? {
        guard let home = LerpFileLocations.realHomeDirectory else { return nil }
        var host = UUID().uuid
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&host, &timeout) == 0 else { return nil }
        let url = home.appendingPathComponent("Library/Preferences/ByHost")
            .appendingPathComponent("\(defaultsModule).\(UUID(uuid: host).uuidString).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

    private func discoveredShaders() -> [LerpShader] {
        metalView?.shaderLibrary.discover() ?? []
    }

    private func currentConfig() -> LerpMetalView.Config {
        let all = discoveredShaders().rotationEntries()
        var config = Settings.load(from: Self.defaults()).config
        let state = Self.savedRotation(discovered: all)
        config.enabledEntries = LerpRotation.enabled(discovered: all, in: state)
        // What this host believes it is allowed to play, recorded from inside
        // the real host rather than inferred from the file a harness read.
        // `enabledEntries == nil` is the widest possible answer -- every look --
        // and is worth seeing spelled out, because a settings read that quietly
        // failed and a user who has genuinely chosen nothing look identical
        // from outside and are not the same thing at all.
        let chosen = config.enabledEntries
        Self.log.notice("""
            rotation resolved: \(chosen.map { "\($0.count)" } ?? "nil (all)", privacy: .public) \
            of \(all.count) discovered, \(state.summary, privacy: .public), \
            pinned=\(config.shaderName ?? "no", privacy: .public)
            """)
        return config
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
                Self.log.notice("notification \(name, privacy: .public)")
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
        Self.log.notice("[\(self.instanceID)] start rendering (\(reason, privacy: .public))")
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
        stopRendering()
        Self.log.notice("[\(self.instanceID)] session end (\(reason, privacy: .public)) — display link torn down, window retained")
    }

    private func stopRendering() {
        rendering = false
        metalView?.stop()
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
        Self.log.notice("[\(self.instanceID)] parked at 1 fps — \(reason, privacy: .public)")
    }

    private func unpark(_ reason: String) {
        // Also resets the grace period: whatever just happened is a fresh
        // reason to believe this host might be the one on screen.
        renderingSince = CACurrentMediaTime()
        guard let parked = parkedReason else { return }
        parkedReason = nil
        metalView?.unpark()
        Self.log.notice("[\(self.instanceID)] resumed — \(reason, privacy: .public) (was parked: \(parked, privacy: .public))")
    }

    /// Seconds since the last input event of any kind in this session. Verified
    /// to work and advance inside legacyScreenSaver's sandbox.
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
    /// Swift. Confirmed against a live dictionary.
    private static func sessionIsOnConsole() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session["kCGSSessionOnConsoleKey"] as? NSNumber
        else { return true }   // unreadable: assume we are, and keep drawing
        return onConsole.boolValue
    }

    // MARK: - ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        Self.log.notice("[\(self.instanceID)] startAnimation preview=\(self.effectiveIsPreview) sessionActive=\(Self.sessionActive) window=\(self.window != nil) level=\(self.window?.level.rawValue ?? 0) size=\(Int(self.bounds.width))x\(Int(self.bounds.height))")
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
        Self.log.notice("[\(self.instanceID)] stopAnimation preview=\(self.effectiveIsPreview) parked=\(self.parkedReason ?? "no", privacy: .public)")
        if effectiveIsPreview {
            stopRendering()
        } else {
            // Kept wired up for the macOS versions that do honour it; on 14+ the
            // notification path is what actually fires.
            endSession("stopAnimation")
        }
    }

    public override func animateOneFrame() {
        // Rendering is driven by LerpMetalView's display link.
    }

    // MARK: - The desktop picture, and why the saver no longer sets it

    /// There used to be a `setWallpaperOnStop` option here: when the screensaver
    /// stopped, render the frame it ended on and hand it to
    /// `NSWorkspace.setDesktopImageURL` so the desktop, lock screen and login
    /// window all matched. It is deleted, and this comment is what replaces it,
    /// because the feature is the direct cause of the bug report that led here —
    /// "one of the shaders I've taken out of rotation shows up on my lock
    /// screen" — and it could not be repaired in place.
    ///
    /// Four properties, each fatal on its own:
    ///
    /// 1. **It could not write where the answer has to live.** Inside
    ///    `legacyScreenSaver` this process is sandboxed, so
    ///    `~/Library/Application Support/Lerping/wallpaper/` resolves to Apple's
    ///    container. macOS's wallpaper store then held absolute paths into a
    ///    container that is not ours and can be reset from under us.
    /// 2. **`setDesktopImageURL` reaches one space per screen.** The user's
    ///    machine had 454 spaces across 5 displays. Each was pinned to whatever
    ///    happened to be playing the moment that space was last refreshed, so the
    ///    store fragmented across four different stills instead of converging.
    /// 3. **Every still was uniquely named** (`<shader>-<uuid>-<n>.png`, because
    ///    rewriting a URL does not refresh the picture) **and then garbage
    ///    collected** by a 120-second age sweep — which deleted files the store
    ///    was still pointing at. 173 of the user's references were to PNGs that
    ///    no longer existed.
    /// 4. **The flag lived in the container and its consequences did not.** The
    ///    container was emptied at some point; the option read `false` again;
    ///    and the pointers it had already planted in macOS's permanent store
    ///    stayed exactly where they were. Nothing in this codebase would ever
    ///    revisit them. The lock screen froze in mid-August on `neuro-noise` —
    ///    a shader the user had switched off — and stayed there.
    ///
    /// The shape of the mistake is general: **a screensaver is an ephemeral,
    /// sandboxed guest, and it was making permanent, global, un-owned
    /// mutations.** The failure was silent, unbounded in time, and invisible to
    /// every rotation fix, because the wallpaper was a *frozen copy* of a
    /// decision rather than a view onto the live one.
    ///
    /// If the desktop picture should follow a shader again, it belongs in
    /// `LerpPlayground`: unsandboxed, so it can write the real home; user-driven,
    /// so the change is a visible action rather than a side effect of walking
    /// away from the machine; and able to rewrite
    /// `com.apple.wallpaper/Store/Index.plist` and restart `WallpaperAgent`,
    /// which is the only thing that reaches every space at once.

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
        let settings = Settings.load(from: Self.defaults())

        let shaderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        shaderPopup.addItem(withTitle: Settings.shuffleTitle)
        shaderPopup.addItems(withTitles: shaderNames)
        shaderPopup.selectItem(withTitle: shaderNames.contains(settings.shader)
                               ? settings.shader : Settings.shuffleTitle)
        shaderPopup.target = self
        shaderPopup.action = #selector(shaderModeChanged)

        // Pinning is (shader, preset) too, so a pin can reach any of the 123
        // looks and not just the 31 sets of defaults.
        let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)

        // Rotation subset. Unset defaults mean "everything", so an upgrade (or a
        // fresh install) starts with every entry checked.
        rotationShaders = shaders
        rotationEntries = entries
        let state = Self.savedRotation(discovered: entries)
        rotationEnabled = Set(LerpMetalView.Config.rotation(
            of: LerpRotation.enabled(discovered: entries, in: state), from: entries))

        // The gallery, showing what is in the rotation and not editing it.
        //
        // It used to be editable, and that made this sheet the rotation's second
        // writer. The playground writes the user's ByHost plist; this sheet runs
        // sandboxed inside `legacyScreenSaver` and can only write Apple's
        // container. Two stores holding one truth needed a revision number, a
        // stale-writer three-way merge, and a newer-than comparison on every
        // read to decide which store won — roughly a hundred lines whose entire
        // job was to arbitrate a disagreement that only existed because both
        // halves were allowed to write.
        //
        // So this half stopped. The rotation now has exactly one writer and one
        // store, which is what makes "the saver plays what the playground says"
        // true by construction rather than by merge.
        let gallery = RotationGalleryView(
            frame: NSRect(x: 0, y: 0, width: Self.sheetWidth - 40, height: Self.sheetGalleryHeight),
            tileSize: RotationTile.size(width: Self.sheetTileWidth),
            showsRegenerate: false)
        gallery.translatesAutoresizingMaskIntoConstraints = false
        gallery.wantsLayer = true
        gallery.layer?.cornerRadius = 6
        gallery.layer?.masksToBounds = true
        gallery.show(shaders: shaders, enabled: rotationEnabled)
        gallery.isEditable = false
        rotationGallery = gallery

        let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fpsPopup.addItems(withTitles: ["24", "30", "60"])
        fpsPopup.selectItem(withTitle: String(settings.fps))

        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        Chrome.fill(scalePopup, with: Self.renderScales,
                    selecting: settings.renderScale, default: 0)

        let freezePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        Chrome.fill(freezePopup, with: Self.freezeChoices,
                    selecting: settings.freezeMinutes, default: 3)

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
            [label("Still image:"), freezePopup, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
        ])
        grid.column(at: 0).width = 92
        grid.column(at: 2).leadingPadding = 26
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let inRotation = NSTextField(labelWithString: "In rotation — edit in LerpPlayground")
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
        reloadPresetPopup(selecting: settings.preset)
        updateRotationControls()
        // `fittingSize` sizes the gallery to its floor, so the difference is
        // what the gallery is short of the height it wants to open at.
        panel.setContentSize(NSSize(
            width: Self.sheetWidth,
            height: content.fittingSize.height + Self.sheetGalleryHeight - Self.sheetGalleryFloor))
        panel.minSize = NSSize(width: 620, height: 460)
        startRotationStills(shaders)
        Self.log.notice("options: sheet built in \(Int((CFAbsoluteTimeGetCurrent() - sheetStarted) * 1000)) ms, \(entries.count) looks, \(self.rotationEnabled.count) in rotation")
        return panel
    }

    // MARK: - Rotation stills

    /// Starts filling the gallery in. Returns immediately, always: opening
    /// Options… must not wait on 123 pictures, and inside legacyScreenSaver it
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
        gallery.populate(using: thumbnails, jobs: jobs, onFinished: { [weak self] in
            guard let self else { return }
            let seconds = CFAbsoluteTimeGetCurrent() - started
            Self.log.notice("""
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

    // MARK: - Rotation list

    private var isShuffleMode: Bool { (shaderPopup?.indexOfSelectedItem ?? 0) == 0 }

    /// The shader the popup is pinned to, or nil in shuffle mode.
    private var pinnedShader: LerpShader? {
        guard !isShuffleMode, let title = shaderPopup?.titleOfSelectedItem else { return nil }
        return rotationShaders.named(title)
    }

    /// The preset popup's first item, which means "the shader's declared
    /// defaults" — the same thing a `nil` preset means everywhere else, under
    /// the same name every other surface gives it.
    private static let defaultsTitle = LerpRotationEntry.defaultsName

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
            settings.fps = Int(fpsPopup?.titleOfSelectedItem ?? "30") ?? 30
            settings.renderScale = Chrome.value(of: scalePopup, in: Self.renderScales, default: 0)
            settings.freezeMinutes = Chrome.value(of: freezePopup, in: Self.freezeChoices, default: 3)
            settings.save(to: defaults)
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

    /// `shuffleTitle`, or the name of the single pinned shader.
    var shader = shuffleTitle
    /// Preset for the pinned shader, or nil for its declared defaults.
    var preset: String?
    var fps = 30
    var renderScale = 1.0
    /// No UI offers this one; it is read but never written back.
    var shuffleMinutes = 5.0
    var freezeMinutes = 30.0
    /// The shuffle rotation. Not loaded from here and never saved from here:
    /// `LerpSaverView.savedRotation` reads it out of the ByHost plist the
    /// playground writes. Set by `currentConfig` after this struct is built.
    var enabledEntries: Set<LerpRotationEntry>?

    static func load(from defaults: UserDefaults?) -> Settings {
        var settings = Settings()
        guard let defaults else { return settings }
        settings.shader = defaults.string(forKey: shaderKey) ?? settings.shader
        settings.preset = defaults.string(forKey: presetKey)
        settings.fps = (defaults.object(forKey: fpsKey) as? Int) ?? settings.fps
        settings.renderScale = (defaults.object(forKey: renderScaleKey) as? Double) ?? settings.renderScale
        settings.shuffleMinutes = (defaults.object(forKey: shuffleMinutesKey) as? Double) ?? settings.shuffleMinutes
        settings.freezeMinutes = (defaults.object(forKey: freezeMinutesKey) as? Double) ?? settings.freezeMinutes
        return settings
    }

    /// Writes back everything the Options sheet still controls — which is the
    /// pinned look and the three render settings, and deliberately not the
    /// rotation. See `configureSheet` for why this sheet stopped writing that.
    func save(to defaults: UserDefaults) {
        defaults.set(shader, forKey: Self.shaderKey)
        if let preset {
            defaults.set(preset, forKey: Self.presetKey)
        } else {
            defaults.removeObject(forKey: Self.presetKey)
        }
        defaults.set(fps, forKey: Self.fpsKey)
        defaults.set(renderScale, forKey: Self.renderScaleKey)
        defaults.set(freezeMinutes, forKey: Self.freezeMinutesKey)
        defaults.synchronize()
        LerpSaverView.log.notice("options: saved pinned=\(shader, privacy: .public) fps=\(fps)")
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
