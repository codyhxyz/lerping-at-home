import AppKit

// MARK: - Updates from the menu bar

/// The menu-bar home for updates: a manual "Check for Updates", the
/// automatic-updates toggle, and a shortcut to the update log.
///
/// Updates are in-app, the Sparkle shape — no background daemon. (A LaunchAgent
/// briefly existed on 2026-09-16; it was ripped out the same day. Chrome and
/// Office update that way, but a personal tool should not plant invisible
/// processes.) The playground checks on launch and every four hours while it
/// runs; when GitHub is ahead it pulls the checkout and runs `make saver` in
/// the background, silently. The work itself stays in `scripts/auto-update.sh`;
/// this is the scheduler, the switch, and the button.
///
/// It lives in the playground because the playground is the only component
/// that is always a real app process — the saver runs inside `legacyScreenSaver`
/// and cannot own a status item, and its sandbox could not reach the network
/// anyway.
///
/// Automatic updates are on by default. Turning the toggle off stops the
/// background checks; it is the supported off-switch.
///
/// A copy with no checkout behind it (the standalone release app) gets no
/// status item: there is nothing `git pull` could update.
final class UpdateStatusItem: NSObject {

    /// Creates the item when this copy has a checkout to update. Nil for the
    /// standalone release app and for a copy whose checkout cannot be resolved.
    static func makeIfAppropriate() -> UpdateStatusItem? {
        UpdateSettings.registerDefaults()
        // Retire the LaunchAgent from the brief daemon experiment, when present.
        // A leftover agent would double-install beside the in-app checks.
        UpdateAgent.removeLegacyLaunchAgent()
        guard !RepoLocation.isStandalone else { return nil }
        let root: URL
        switch RepoLocation.settled() {
        case let .found(_, foundRoot, _): root = foundRoot
        case .standalone, .missing, .unset: return nil
        }
        let item = UpdateStatusItem(repoRoot: root)
        item.show()
        item.refreshFooterFromLog()
        item.beginAutomaticChecks()
        return item
    }

    private let repoRoot: URL
    private var statusItem: NSStatusItem?
    private var checkItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var footerItem: NSMenuItem?
    private var checkTimer: Timer?
    private var checkRunning = false

    private init(repoRoot: URL) { self.repoRoot = repoRoot }

    // MARK: Automatic checks

    /// On by default: a check shortly after launch, then every four hours while
    /// the app runs. Each check is skipped when the toggle is off.
    private func beginAutomaticChecks() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) {
            [weak self] _ in self?.performCheck(announce: false)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.performCheck(announce: false)
        }
    }

    // MARK: Status item

    private func show() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                            accessibilityDescription: "Lerping@Home updates")
        image?.isTemplate = true
        button.image = image

        let menu = NSMenu()

        let check = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates(_:)),
                               keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        checkItem = check

        let toggle = NSMenuItem(title: "Automatic Updates", action: #selector(toggleAutomatic(_:)),
                                keyEquivalent: "")
        toggle.target = self
        toggle.state = UpdateSettings.isEnabled ? .on : .off
        menu.addItem(toggle)
        toggleItem = toggle

        menu.addItem(.separator())

        let footer = NSMenuItem(title: "Never checked for updates", action: nil, keyEquivalent: "")
        footer.isEnabled = false
        menu.addItem(footer)
        footerItem = footer

        let log = NSMenuItem(title: "Show Update Log", action: #selector(showLog(_:)), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        item.menu = menu
        statusItem = item
    }

    // MARK: Actions

    /// Manual check: always runs, always reports.
    @objc private func checkForUpdates(_ sender: Any?) {
        performCheck(announce: true)
    }

    /// The toggle is a plain default flip — no daemon to enroll or unload.
    /// Turning it back on checks soon, so re-enabling does not wait four hours.
    @objc private func toggleAutomatic(_ sender: Any?) {
        UpdateSettings.isEnabled.toggle()
        toggleItem?.state = UpdateSettings.isEnabled ? .on : .off
        if UpdateSettings.isEnabled {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.performCheck(announce: false)
            }
        }
    }

    @objc private func showLog(_ sender: Any?) {
        let url = UpdateAgent.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.open([url], withApplicationAt: nil,
                                configuration: NSWorkspace.OpenConfiguration(),
                                completionHandler: nil)
    }

    // MARK: Checking

    /// Runs `scripts/auto-update.sh` off the main thread. `announce` is the
    /// manual check: it always runs and always reports. The automatic check
    /// runs only with the toggle on and reports by footer alone — an update
    /// that needed no decision gets no dialog.
    private func performCheck(announce: Bool) {
        guard !checkRunning else { return }
        if !announce, !UpdateSettings.isEnabled { return }
        let script = repoRoot.appendingPathComponent("scripts/auto-update.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            if announce {
                let alert = NSAlert()
                alert.messageText = "Updater not in this checkout"
                alert.informativeText = "This checkout predates scripts/auto-update.sh. " +
                    "Pull the latest and try again."
                alert.runModal()
            }
            return
        }
        checkRunning = true
        if announce {
            checkItem?.title = "Checking for Updates…"
            checkItem?.isEnabled = false
        }
        // The script appends to the log; snapshot the size so the outcome is
        // read from this run's lines only.
        let logOffset = UpdateAgent.logByteCount()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let run = UpdateAgent.run("/bin/bash", [script.path])
            let outcome = UpdateOutcome.classify(newLog: UpdateAgent.readLog(sinceByte: logOffset),
                                                processOK: run.succeeded)
            DispatchQueue.main.async {
                self.checkRunning = false
                self.checkItem?.title = "Check for Updates"
                self.checkItem?.isEnabled = true
                self.footerItem?.title = outcome.footer
                if announce { self.showOutcome(outcome) }
            }
        }
    }

    // MARK: Outcome UI

    private func showOutcome(_ outcome: UpdateOutcome) {
        let alert = NSAlert()
        switch outcome {
        case .upToDate(let build):
            alert.messageText = "Already up to date"
            alert.informativeText = "The installed saver (\(build)) matches origin/main."
        case .updated(let build):
            alert.messageText = "Saver updated"
            alert.informativeText = "The new build (\(build)) is installed and takes effect " +
                "the next time the screen saver runs."
        case .skipped(let reason):
            alert.messageText = "Update skipped"
            alert.informativeText = "\(reason)\n\nAutomatic updates will try again at the next check."
        case .failed:
            alert.messageText = "Update failed"
            alert.informativeText = "Show Update Log has the details."
        }
        alert.runModal()
    }

    /// Seeds the footer from the newest result already in the log, so a machine
    /// that has been updating does not claim it never checked.
    private func refreshFooterFromLog() {
        guard let text = try? String(contentsOf: UpdateAgent.logURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        guard let last = lines.last(where: {
            $0.contains("up to date (") || $0.contains("saver now at ")
        }) else { return }
        footerItem?.title = last.count > 20 ? String(last.dropFirst(20)) : last
    }
}

// MARK: - The toggle

/// On by default: `registerDefaults` runs before the first read, so a fresh
/// machine checks for updates without anyone writing a preference.
enum UpdateSettings {
    private static let key = "LerpAutoUpdateEnabled"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [key: true])
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

// MARK: - Running the updater

/// The update itself lives in `scripts/auto-update.sh`; this is process
/// plumbing, log reading, and cleanup of the retired LaunchAgent.
enum UpdateAgent {
    static let label = "com.hergenroeder.lerping.autoupdate"

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LerpingAutoUpdate.log")
    }

    /// Removes the LaunchAgent from the brief 2026-09-16 daemon experiment,
    /// when present. Updates are in-app now; a leftover agent would run the
    /// same script on its own schedule. Idempotent.
    static func removeLegacyLaunchAgent() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(Darwin.getuid())/\(label)"])
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    static func logByteCount() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64) ?? 0
    }

    static func readLog(sinceByte offset: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return "" }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return "" }
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) -> (succeeded: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (false, "")
        }
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output)
    }
}

// MARK: - Reading the result

/// Classified from the lines the script appended during the run — the script's
/// `say` lines are the contract, not the process exit code, because "already up
/// to date" and "skipped: dirty checkout" both exit 0.
enum UpdateOutcome {
    case upToDate(build: String)
    case updated(build: String)
    case skipped(reason: String)
    case failed

    static func classify(newLog: String, processOK: Bool) -> UpdateOutcome {
        let lines = newLog.split(separator: "\n").map(String.init)
        // A say line is "YYYY-MM-DD HH:MM:SS <message>"; the message starts at 20.
        func message(containing phrase: String) -> String? {
            lines.last(where: { $0.contains(phrase) }).map {
                $0.count > 20 ? String($0.dropFirst(20)) : $0
            }
        }
        if let found = message(containing: "saver now at ") {
            return .updated(build: found.replacingOccurrences(of: "saver now at ", with: ""))
        }
        if let found = message(containing: "up to date (") {
            let build = found.replacingOccurrences(of: "up to date (", with: "")
                .replacingOccurrences(of: ")", with: "")
            return .upToDate(build: build)
        }
        if newLog.contains("FAILED") || !processOK { return .failed }
        if let last = lines.last {
            let reason = last.count > 20 ? String(last.dropFirst(20)) : last
            return .skipped(reason: reason)
        }
        return .failed
    }

    var footer: String {
        let when = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
        switch self {
        case .upToDate(let build): return "Up to date (\(build)) · checked \(when)"
        case .updated(let build):  return "Updated to \(build) · \(when)"
        case .skipped(let reason): return "Skipped: \(reason) · \(when)"
        case .failed:              return "Last check failed · \(when)"
        }
    }
}
