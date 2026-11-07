import AppKit
import CoreAudio
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import os

// LerpPulse — the critter's heartbeat monitor. A LaunchAgent
// (com.hergenroeder.lerping.pulse) that wakes once a minute, asks how long
// since the last input, whether the screen is locked, what kind of app is in
// front and whether something is being watched or a call is on, and hands that
// to `CritterLedger.fold`. See Sources/LerpCore/CritterLedger.swift for what is
// kept and why it is only per-day totals; everything that decides what a
// minute means lives there, where `LerpPreview --critter-selftest` can reach
// it. This file is only the system probes and the timer.
//
//     LerpPulse            run (what launchd does)
//     LerpPulse --report   print the critter's vitals from the current ledger
//     LerpPulse --probe    print what one sample would see right now
//
// Nothing here needs a privacy permission: idle time comes from the HID
// system's registry entry, lock state from the window server's session
// dictionary, the front app from NSWorkspace, display-sleep assertions from
// the power manager, and whether the microphone is running from a CoreAudio
// device property (which reads no audio).

@main
enum PulseMain {
    static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "pulse")

    static func main() {
        guard let url = CritterLedger.url else {
            FileHandle.standardError.write(Data("LerpPulse: no home directory\n".utf8))
            exit(1)
        }
        if CommandLine.arguments.contains("--report") { report(url) }
        if CommandLine.arguments.contains("--probe") { probe() }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let pulse = Pulse(url: url)
        pulse.start()
        log.notice("started ledger=\(url.path, privacy: .public)")
        app.run()
    }

    static func report(_ url: URL) -> Never {
        let ledger: CritterLedger
        switch CritterLedger.read(from: url) {
        case .missing:
            print("No ledger at \(url.path) — the critter has not been born yet.")
            exit(1)
        case .unreadable(let reason):
            print("The ledger at \(url.path) cannot be read: \(reason)")
            exit(1)
        case .loaded(let l):
            ledger = l
        }
        let now = Date()
        let today = ledger.days[CritterLedger.dayKey(now)] ?? CritterDay()
        print(CritterVitals(ledger: ledger, now: now).summary)
        print("ledger: \(url.path), \(ledger.days.count) days, last sample "
              + "\(Int(now.timeIntervalSince1970 - ledger.live.sampledAt)) s ago, "
              + "today \(today.activeMinutes) min (\(today.passiveMinutes) watching) / "
              + "\(today.breaks) breaks / \(today.switches) switches")
        exit(0)
    }

    static func probe() -> Never {
        let front = NSWorkspace.shared.frontmostApplication
        print("idle \(Pulse.hidIdleSeconds().map { String(format: "%.0f s", $0) } ?? "?"), "
              + "locked \(Pulse.screenLocked()), "
              + "front \(front.map { "\($0.bundleIdentifier ?? "?") → \(Pulse.kind(of: $0)?.rawValue ?? "ignored")" } ?? "none"), "
              + "watching \(Pulse.watchedKind()?.rawValue ?? "nothing"), "
              + "microphone \(Pulse.microphoneInUse() ? "in use" : "idle")")
        exit(0)
    }
}

final class Pulse {
    private let url: URL
    /// nil while the file on disk cannot be read or moved aside: then nothing
    /// is written, and opening is retried each minute.
    private var ledger: CritterLedger?
    private var switches = CritterSwitchCounter(front: .other, at: Date().timeIntervalSince1970)
    private var timer: Timer?

    init(url: URL) {
        self.url = url
        open()
    }

    private func open() {
        switch CritterLedger.openForWriting(at: url, now: Date()) {
        case .existing(let l):
            ledger = l
        case .fresh(let l):
            ledger = l
            PulseMain.log.notice("no ledger yet: a critter is born")
        case .quarantined(let l, let aside, let reason):
            ledger = l
            PulseMain.log.error("""
                ledger unreadable (\(reason, privacy: .public)); moved to \
                \(aside.path, privacy: .public), starting a new one
                """)
        case .refused(let reason):
            ledger = nil
            PulseMain.log.fault("ledger unreadable and left in place, not writing: \(reason, privacy: .public)")
        }
    }

    func start() {
        let t = Date().timeIntervalSince1970
        let front = NSWorkspace.shared.frontmostApplication.flatMap(Self.kind(of:)) ?? .other
        switches = CritterSwitchCounter(front: front, at: t)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let kind = Self.kind(of: app)
            else { return }
            self.switches.activate(kind, at: Date().timeIntervalSince1970)
        }
        // A restarted agent ticks at once; `fold` ignores it if the last
        // sample was under 45 s ago.
        tick()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if ledger == nil { open() }
        guard var ledger else { return }
        let now = Date()
        switches.settle(at: now.timeIntervalSince1970)
        let onCall = Self.microphoneInUse()
        let folded = ledger.fold(now: now,
                                 idleSeconds: Self.hidIdleSeconds() ?? 0,
                                 locked: Self.screenLocked(),
                                 kind: onCall ? .chat : switches.front,
                                 switches: switches.pending,
                                 passive: onCall ? .chat : Self.watchedKind())
        guard folded else { return }
        switches.clear()
        ledger.prune(now: now)
        self.ledger = ledger
        do { try ledger.save(to: url) } catch {
            PulseMain.log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: System probes

    /// Seconds since the last keyboard, mouse or trackpad event, from the HID
    /// system's `HIDIdleTime` (nanoseconds). No Input Monitoring needed.
    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        if let number = value as? NSNumber { return number.doubleValue / 1e9 }
        if let data = value as? Data, data.count >= 8 {
            return Double(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 1e9
        }
        return nil
    }

    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (session[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    /// The kind of app keeping the display awake — a player or browser showing
    /// a film, a video call — or nil. Assertions held by anything that is not
    /// an ordinary windowed app (caffeinate, keep-awake menu-bar utilities)
    /// are ignored: they say nothing about anyone watching. If the app in
    /// front is one of the holders, it wins.
    static func watchedKind() -> CritterKind? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }
        let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
        var holders: [NSRunningApplication] = []
        for (pid, assertions) in byProcess {
            for a in assertions {
                guard let type = a["AssertType"] as? String, displayTypes.contains(type),
                      (a["AssertLevel"] as? Int ?? 255) != 0 else { continue }
                let candidates = [a["AssertionOnBehalfOfPID"] as? Int, pid.intValue].compactMap { $0 }
                for p in candidates where p != Int(getpid()) {
                    if let app = owningApp(pid_t(p)) { holders.append(app); break }
                }
            }
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let chosen = holders.first { $0.processIdentifier == frontPID } ?? holders.first
        return chosen.flatMap(kind(of:))
    }

    /// The regular app a process belongs to: itself, or — for a helper inside
    /// an app bundle (Chrome's renderer, Electron's GPU process) — the app
    /// whose bundle contains it.
    static func owningApp(_ pid: pid_t) -> NSRunningApplication? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if app.activationPolicy == .regular { return app }
        }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard let r = path.range(of: ".app/") else { return nil }
        let appPath = String(path[..<r.lowerBound]) + ".app"
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.bundleURL?.path == appPath
        }
    }

    /// Whether the default input device is running for anyone — a call, a
    /// voice memo. Reads a device property; no audio, no permission.
    static func microphoneInUse() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr, device != 0
        else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    // MARK: Kinds of app

    private static let makeIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm", "dev.zed.Zed",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.anthropic.claudefordesktop", "org.blenderfoundation.blender", "com.figma.Desktop",
        "md.obsidian", "com.logseq.logseq", "com.apple.Notes", "notion.id", "com.apple.iWork.Pages",
        "com.apple.iWork.Keynote", "com.apple.iWork.Numbers", "com.hergenroeder.lerping.playground",
        "com.apple.dt.Xcode", "com.apple.FinalCut", "com.apple.logic10", "com.apple.garageband10",
        "com.tldraw.desktop",
    ]
    private static let chatIDs: Set<String> = [
        "com.apple.MobileSMS", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "us.zoom.xos", "ru.keepcoder.Telegram", "net.whatsapp.WhatsApp", "com.microsoft.teams2",
        "com.facebook.archon", "org.whispersystems.signal-desktop",
    ]
    private static let browseIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.brave.Browser", "com.microsoft.edgemac", "com.openai.atlas", "com.vivaldi.Vivaldi",
        "app.zen-browser.zen", "com.google.Chrome.canary",
    ]
    private static let playIDs: Set<String> = [
        "com.apple.TV", "com.apple.Music", "com.spotify.client", "com.netflix.Netflix",
        "com.valvesoftware.steam", "com.colliderli.iina", "org.videolan.vlc", "com.apple.podcasts",
    ]

    private static var kindCache: [String: CritterKind] = [:]

    /// The kind of an app, or nil for one that should not count as a switch:
    /// anything that is not an ordinary windowed app — launchers, password
    /// managers, menu-bar popovers, agents.
    static func kind(of app: NSRunningApplication) -> CritterKind? {
        guard app.activationPolicy == .regular else { return nil }
        guard let id = app.bundleIdentifier else { return .other }
        if let cached = kindCache[id] { return cached }
        let kind = classify(id: id, url: app.bundleURL)
        kindCache[id] = kind
        return kind
    }

    /// Explicit lists first, then the app's own App Store category. Only
    /// categories that are about making something count as `make`;
    /// `productivity` (Mail, Calendar, Reminders, Preview…) is `other`.
    static func classify(id: String, url: URL?) -> CritterKind {
        if makeIDs.contains(id) { return .make }
        if chatIDs.contains(id) { return .chat }
        if browseIDs.contains(id) { return .browse }
        if playIDs.contains(id) { return .play }
        guard let url, let info = Bundle(url: url)?.infoDictionary,
              let category = info["LSApplicationCategoryType"] as? String else { return .other }
        switch category.replacingOccurrences(of: "public.app-category.", with: "") {
        case let c where c.hasSuffix("-games") || c == "games" || c == "entertainment": return .play
        case "developer-tools", "graphics-design", "music", "video", "photography":
            return .make
        case "social-networking": return .chat
        default: return .other
        }
    }
}
