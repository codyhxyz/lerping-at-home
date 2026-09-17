import AppKit

// MARK: - Updates from the menu bar

/// The menu-bar home for updates: a manual "Check for Updates", the
/// automatic-updates toggle, and a shortcut to the update log.
///
/// Updates are in-app, the Sparkle shape — no background daemon. (A LaunchAgent
/// briefly existed on 2026-09-16; it was ripped out the same day. Chrome and
/// Office update that way, but a personal tool should not plant invisible
/// processes.) The playground checks on launch and every four hours while it
/// runs; when a newer GitHub Release exists it downloads the prebuilt saver
/// zip and installs it, silently. The work itself stays in
/// `scripts/release-update.sh`; this is the scheduler, the switch, and the
/// button.
///
/// Delivery is prebuilt artifacts from GitHub Releases — the standard shape —
/// not a source rebuild on the machine: no checkout update, no compiler
/// needed. The release tag is the version; the bundle's LerpBuild stamp must
/// equal it, and the signature must verify, or the install is refused.
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
    /// the app runs. Each check is skipped when the toggle is off. Installing
    /// a release never touches the playground itself: replacing it unattended
    /// could discard unsaved editor state.
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

    /// Runs `scripts/release-update.sh` off the main thread. `announce` is the
    /// manual check: it always runs and always reports. The automatic check
    /// runs only with the toggle on and reports by footer alone — an update
    /// that needed no decision gets no dialog. The outcome comes from the
    /// script's single `LERP_RESULT=` stdout line.
    private func performCheck(announce: Bool) {
        guard !checkRunning else { return }
        if !announce, !UpdateSettings.isEnabled { return }
        let script = repoRoot.appendingPathComponent("scripts/release-update.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            if announce {
                let alert = NSAlert()
                alert.messageText = "Updater not in this checkout"
                alert.informativeText = "This checkout predates scripts/release-update.sh. " +
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let run = UpdateAgent.run("/bin/bash", [script.path])
            let outcome = UpdateOutcome.from(resultLine(in: run.output))
            DispatchQueue.main.async {
                self.checkRunning = false
                self.checkItem?.title = "Check for Updates"
                self.checkItem?.isEnabled = true
                self.footerItem?.title = outcome.footer
                if announce { self.showOutcome(outcome) }
            }
        }
    }

    /// The script's one stdout line; progress goes to the log (and to stderr
    /// in a terminal), so anything else captured here is ignored.
    private func resultLine(in output: String) -> String {
        output.split(separator: "\n").first(where: { $0.hasPrefix("LERP_RESULT=") })
            .map(String.init) ?? ""
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
        case .failed(let reason):
            alert.messageText = "Update failed"
            alert.informativeText = "\(reason)\n\nShow Update Log has the details."
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

/// The update itself lives in `scripts/release-update.sh`; this is process
/// plumbing, the log location, and cleanup of the retired LaunchAgent.
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

/// Parsed from the script's single `LERP_RESULT=` stdout line — the contract
/// in scripts/release-update.sh. The footer still seeds from the log, whose
/// "up to date (…)" / "saver now at …" lines the new script kept.
enum UpdateOutcome {
    case upToDate(build: String)
    case updated(build: String)
    case skipped(reason: String)
    case failed(reason: String)

    /// `LERP_RESULT=up-to-date BUILD=v1.2.3`, `LERP_RESULT=updated BUILD=…`,
    /// `LERP_RESULT=skipped REASON=…`, `LERP_RESULT=failed REASON=…`.
    /// Anything unrecognized is a failure: the script always prints exactly
    /// one well-formed line, so a missing one means it never got there.
    static func from(_ line: String) -> UpdateOutcome {
        let fields = line.split(separator: " ")
        func token(for key: String) -> String {
            fields.first(where: { $0.hasPrefix(key + "=") })
                .map { String($0.dropFirst(key.count + 1)) } ?? ""
        }
        // REASON is always the last field and may contain spaces: everything
        // after "REASON=" belongs to it. BUILD tags never contain spaces.
        func rest(for key: String) -> String {
            guard let range = line.range(of: key + "=") else { return "" }
            return String(line[range.upperBound...])
        }
        switch token(for: "LERP_RESULT") {
        case "up-to-date": return .upToDate(build: token(for: "BUILD"))
        case "updated":    return .updated(build: token(for: "BUILD"))
        case "skipped":    return .skipped(reason: rest(for: "REASON"))
        case "failed":     return .failed(reason: rest(for: "REASON"))
        default:           return .failed(reason: "the updater produced no result")
        }
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
