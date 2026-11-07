import AppKit
import CoreGraphics
import IOKit
import os

// LerpPulse — the critter's heartbeat monitor. A LaunchAgent
// (com.hergenroeder.lerping.pulse) that wakes once a minute, asks how long
// since the last input, whether the screen is locked and what kind of app is in
// front, and folds that minute into the ledger the `critter` look reads. See
// Sources/LerpCore/CritterLedger.swift for what is kept and why it is only
// per-day totals.
//
//     LerpPulse            run (what launchd does)
//     LerpPulse --report   print the critter's vitals from the current ledger
//
// Nothing here needs a privacy permission: idle time comes from the HID
// system's registry entry, lock state from the window server's session
// dictionary, and the front app from NSWorkspace.

@main
enum PulseMain {
    static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "pulse")

    static func main() {
        guard let url = CritterLedger.url else {
            FileHandle.standardError.write(Data("LerpPulse: no home directory\n".utf8))
            exit(1)
        }
        if CommandLine.arguments.contains("--report") {
            guard let ledger = CritterLedger.load(from: url) else {
                print("No ledger at \(url.path) — the critter has not been born yet.")
                exit(1)
            }
            let today = ledger.days[CritterLedger.dayKey(Date())] ?? CritterDay()
            print(CritterVitals(ledger: ledger, now: Date()).summary)
            print("ledger: \(url.path), \(ledger.days.count) days, last sample "
                  + "\(Int(Date().timeIntervalSince1970 - ledger.live.sampledAt)) s ago, "
                  + "today \(today.activeMinutes) min / \(today.breaks) breaks / "
                  + "\(today.switches) switches")
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let pulse = Pulse(url: url)
        pulse.start()
        log.notice("started ledger=\(url.path, privacy: .public)")
        app.run()
    }
}

final class Pulse {
    private let url: URL
    private var ledger: CritterLedger
    private var switchesThisMinute = 0
    private var frontKind: CritterKind = .other
    private var kindCache: [String: CritterKind] = [:]
    private var timer: Timer?

    init(url: URL) {
        self.url = url
        ledger = CritterLedger.load(from: url)
            ?? CritterLedger(born: Date().timeIntervalSince1970)
    }

    func start() {
        if let front = NSWorkspace.shared.frontmostApplication { frontKind = kind(of: front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.switchesThisMinute += 1
            self.frontKind = self.kind(of: app)
        }
        tick()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let t = now.timeIntervalSince1970
        var live = ledger.live
        let key = CritterLedger.dayKey(now)
        var day = ledger.days[key] ?? CritterDay()

        // Minutes nobody sampled — the Mac was asleep or this agent was not
        // running — were not minutes of use.
        if live.sampledAt > 0 {
            let missed = Int((t - live.sampledAt) / 60) - 1
            if missed > 0 {
                live.idleRun += missed
                closeStreakIfBreak(&live, &day)
            }
        }

        let idle = Self.hidIdleSeconds() ?? 0
        let active = !Self.screenLocked() && idle < 90
        if active {
            if live.streakStart == nil { live.streakStart = t }
            live.idleRun = 0
            live.lastActive = t
            day.activeMinutes += 1
            let hour = Calendar.current.component(.hour, from: now)
            day.hours[hour] += 1
            if hour < 5 { day.lateMinutes += 1 }
            day.kinds[frontKind.rawValue, default: 0] += 1
            day.switches += switchesThisMinute
            let streak = Int((t - (live.streakStart ?? t)) / 60) + 1
            day.longestStreak = max(day.longestStreak, streak)
            live.recentSwitches.append(switchesThisMinute)
            if live.recentSwitches.count > 60 {
                live.recentSwitches.removeFirst(live.recentSwitches.count - 60)
            }
        } else {
            live.idleRun += 1
            closeStreakIfBreak(&live, &day)
        }
        switchesThisMinute = 0
        live.sampledAt = t
        ledger.live = live
        ledger.days[key] = day
        ledger.prune(now: now)
        do { try ledger.save(to: url) } catch {
            PulseMain.log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Five idle minutes end a run of use; a run of 20+ minutes that ends that
    /// way counts as a break taken.
    private func closeStreakIfBreak(_ live: inout CritterLive, _ day: inout CritterDay) {
        guard live.idleRun >= 5, let start = live.streakStart else { return }
        let end = live.lastActive ?? start
        let minutes = Int((end - start) / 60) + 1
        live.lastStreakMinutes = minutes
        live.lastStreakEnded = end
        live.streakStart = nil
        if minutes >= 20 { day.breaks += 1 }
        PulseMain.log.info("run ended: \(minutes) min")
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

    private func kind(of app: NSRunningApplication) -> CritterKind {
        guard let id = app.bundleIdentifier else { return .other }
        if let cached = kindCache[id] { return cached }
        let kind = Self.classify(id: id, url: app.bundleURL)
        kindCache[id] = kind
        return kind
    }

    static func classify(id: String, url: URL?) -> CritterKind {
        if makeIDs.contains(id) { return .make }
        if chatIDs.contains(id) { return .chat }
        if browseIDs.contains(id) { return .browse }
        if playIDs.contains(id) { return .play }
        guard let url, let info = Bundle(url: url)?.infoDictionary,
              let category = info["LSApplicationCategoryType"] as? String else { return .other }
        switch category.replacingOccurrences(of: "public.app-category.", with: "") {
        case let c where c.hasSuffix("-games") || c == "games" || c == "entertainment": return .play
        case "developer-tools", "graphics-design", "music", "video", "photography", "productivity":
            return .make
        case "social-networking": return .chat
        default: return .other
        }
    }
}
