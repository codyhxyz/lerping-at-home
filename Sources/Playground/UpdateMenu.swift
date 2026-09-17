import AppKit

// MARK: - Updates from the menu bar

/// The menu-bar home for updates: a manual "Check for Updates", the
/// automatic-updates toggle, and a shortcut to the update log.
///
/// It lives in the playground because the playground is the only component
/// that is always a real app process — the saver runs inside `legacyScreenSaver`
/// and cannot own a status item. The work itself stays in
/// `scripts/auto-update.sh` and the `install-auto-update` /
/// `uninstall-auto-update` targets; this is the switch and the button.
///
/// Automatic updates are on by default: the first launch with a checkout
/// enrolls the daily LaunchAgent, and every launch after that makes sure the
/// agent is still there and still points at this checkout. Turning the toggle
/// off unloads the agent; the toggle is the supported off-switch — a hand-run
/// `launchctl bootout` gets healed on the next launch, by design.
///
/// A copy with no checkout behind it (the standalone release app) gets no
/// status item: there is nothing `git pull` could update.
final class UpdateStatusItem: NSObject {

    /// Creates the item when this copy has a checkout to update, and reconciles
    /// the LaunchAgent with the toggle. Nil for the standalone release app and
    /// for a copy whose checkout cannot be resolved.
    static func makeIfAppropriate() -> UpdateStatusItem? {
        UpdateSettings.registerDefaults()
        guard !RepoLocation.isStandalone else { return nil }
        let root: URL
        switch RepoLocation.settled() {
        case let .found(_, foundRoot, _): root = foundRoot
        case .standalone, .missing, .unset: return nil
        }
        let item = UpdateStatusItem(repoRoot: root)
        item.show()
        item.refreshFooterFromLog()
        // Shelling out to make hitches for a beat; launch does not need it.
        DispatchQueue.global(qos: .utility).async { item.reconcile() }
        return item
    }

    private let repoRoot: URL
    private var statusItem: NSStatusItem?
    private var checkItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var footerItem: NSMenuItem?
    private var checkRunning = false

    private init(repoRoot: URL) { self.repoRoot = repoRoot }

    // MARK: Agent reconciliation

    /// Automatic updates are on by default, so "enabled" both enrolls the
    /// agent the first time and repairs it afterwards — a checkout that moved
    /// gets its agent re-pointed, because the installed plist names the
    /// update script by absolute path.
    private func reconcile() {
        if UpdateSettings.isEnabled {
            UpdateAgent.install(repoRoot: repoRoot)
        } else {
            UpdateAgent.uninstall(repoRoot: repoRoot)
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

    @objc private func checkForUpdates(_ sender: Any?) {
        guard !checkRunning else { return }
        let script = repoRoot.appendingPathComponent("scripts/auto-update.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            let alert = NSAlert()
            alert.messageText = "Updater not in this checkout"
            alert.informativeText = "This checkout predates scripts/auto-update.sh. " +
                "Pull the latest and try again."
            alert.runModal()
            return
        }
        checkRunning = true
        checkItem?.title = "Checking for Updates…"
        checkItem?.isEnabled = false
        // The script appends to the log; snapshot the size so the outcome is
        // read from this run's lines only, not a concurrent daily run's.
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
                self.showOutcome(outcome)
            }
        }
    }

    @objc private func toggleAutomatic(_ sender: Any?) {
        let enable = !UpdateSettings.isEnabled
        toggleItem?.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if enable {
                UpdateAgent.install(repoRoot: self.repoRoot)
            } else {
                UpdateAgent.uninstall(repoRoot: self.repoRoot)
            }
            let ok = UpdateAgent.isLoaded == enable
            DispatchQueue.main.async {
                if ok { UpdateSettings.isEnabled = enable }
                self.toggleItem?.state = UpdateSettings.isEnabled ? .on : .off
                self.toggleItem?.isEnabled = true
                if !ok {
                    let alert = NSAlert()
                    alert.messageText = enable ? "Could not enable automatic updates"
                                               : "Could not disable automatic updates"
                    alert.informativeText = "The LaunchAgent did not change state. " +
                        "Pull the latest checkout and try again."
                    alert.runModal()
                }
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
    /// the daily agent has been updating does not claim it never checked.
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
/// machine has automatic updates without anyone writing a preference.
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

// MARK: - The agent

/// Thin wrapper over the Makefile targets, so the install/uninstall knowledge
/// lives in one place. `make` is at a fixed path because a GUI app's PATH is
/// whatever launchd felt like.
enum UpdateAgent {
    static let label = "com.hergenroeder.lerping.autoupdate"

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LerpingAutoUpdate.log")
    }

    /// Idempotent: the target boots out whatever is there, then bootstraps.
    static func install(repoRoot: URL) {
        _ = run("/usr/bin/make", ["-C", repoRoot.path, "install-auto-update"])
    }

    /// Idempotent: bootout of an absent agent and removal of a missing plist
    /// are both tolerated by the target.
    static func uninstall(repoRoot: URL) {
        _ = run("/usr/bin/make", ["-C", repoRoot.path, "uninstall-auto-update"])
    }

    static var isLoaded: Bool {
        run("/bin/launchctl", ["print", "gui/\(Darwin.getuid())/\(label)"]).succeeded
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
