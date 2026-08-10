import AppKit

// MARK: - Which checkout this copy edits

/// Where this copy of the playground finds the repo whose `.metal` files it
/// edits.
///
/// The playground is a repo tool: Save writes the real source file, and the
/// bundle deliberately ships no `Resources/Shaders` of its own. The staging
/// build — explicit `make playground-build`, never the normal launch target —
/// finds the checkout by walking up from its own executable, which is what
/// `ShaderLocations` in LerpCore has always done and still does.
///
/// A copy installed into `~/Applications` cannot: nothing above it is a
/// checkout. And it has to live there, because Spotlight only *offers* apps
/// from `/Applications`, `/System/Applications` and `~/Applications` — a bundle
/// in `build/` is indexed and openable but never comes back for "lerp". So
/// `make install-playground` records the checkout it was installed from in the
/// installed copy's own `Info.plist`, and that record is read first.
///
/// The order, and why:
///
/// 1. `LERP_REPO_ROOT` in the environment — an explicit answer for one launch.
///    Used by the self-test below, and by anyone pointing a copy at a second
///    checkout for an afternoon.
/// 2. `LerpRepoRoot` in the bundle's `Info.plist`, written by
///    `make install-playground`. Deliberately above the user's own pick:
///    re-running the install target is how an installed copy gets re-pointed,
///    and a folder picked months ago must not quietly outrank it.
/// 3. Walking up from the executable: the in-repo build, unchanged — but only
///    for a copy with no install record. See `resolve`.
/// 4. `LerpRepoRoot` in `UserDefaults` — the folder the user chose the last time
///    the recorded one had gone missing.
///
/// A record that does not resolve is *reported*, never silently skipped. The
/// failure this type exists to prevent is an installed copy coming up with an
/// empty shader picker and no explanation.
enum RepoLocation {

    /// The key, in the bundle's Info.plist and in UserDefaults. One string, so
    /// the Makefile's `plutil -replace` and a `defaults write` name the same
    /// thing.
    static let key = "LerpRepoRoot"
    static let environmentKey = "LERP_REPO_ROOT"

    /// Which of the four answers we took, in the words the UI uses.
    enum Origin: String {
        case environment
        case installRecord
        case userChoice
        case buildTree

        /// For `--shaders` and the install target's own check.
        var tag: String {
            switch self {
            case .environment:   return "$\(RepoLocation.environmentKey)"
            case .installRecord: return "\(RepoLocation.key) in the app bundle's Info.plist"
            case .userChoice:    return "\(RepoLocation.key) in this app's preferences"
            case .buildTree:     return "the build tree this copy is running from"
            }
        }

        /// For the alert, where it has to finish "The folder …".
        var phrase: String {
            switch self {
            case .environment:   return "named by \(RepoLocation.environmentKey)"
            case .installRecord: return "recorded when this copy was installed"
            case .userChoice:    return "you chose the last time this came up"
            case .buildTree:     return "this copy is running from"
            }
        }
    }

    enum Outcome {
        /// `shaders` is the directory to hand `ShaderLibrary`; `root` is the
        /// checkout it sits in, which is what the title bar names.
        case found(shaders: URL, root: URL, origin: Origin)
        /// Something told us where the repo was, and it is not there.
        case missing(recorded: URL, origin: Origin)
        /// Nothing told us, and we are not inside a checkout either.
        case unset
    }

    // MARK: Resolution

    /// True for a directory holding at least one `.metal` file.
    ///
    /// Stricter than "is a directory" on purpose: it is what stops the folder
    /// picker below from accepting the wrong folder and leaving the user with an
    /// app that opens onto nothing.
    static func holdsShaders(_ url: URL) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .contains { $0.hasSuffix(".metal") } == true
    }

    /// The shader directory under a repo root, or nil if that is not a checkout.
    ///
    /// Accepts the root (`…/lerping-at-home`) and the shader folder itself
    /// (`…/lerping-at-home/Sources/Shaders`), because both are reasonable things
    /// to point at and there is no reason to be strict about which.
    static func shaderDirectory(under root: URL) -> URL? {
        [root.appendingPathComponent("Sources/Shaders"), root]
            .first(where: holdsShaders)?
            .standardizedFileURL
    }

    /// The repo root a shader directory belongs to: two levels up from
    /// `Sources/Shaders`, or the directory itself if it was pointed at directly.
    private static func repoRoot(of shaders: URL) -> URL {
        shaders.pathComponents.suffix(2) == ["Sources", "Shaders"]
            ? shaders.deletingLastPathComponent().deletingLastPathComponent()
            : shaders
    }

    /// The whole decision, as a function of its four inputs — so the self-test
    /// can drive every branch of it against real directories it made itself,
    /// including the ones that fail.
    ///
    /// In one breath: `LERP_REPO_ROOT` decides everything; failing that a
    /// recorded install decides, and if that folder is gone only the user's own
    /// pick may answer for it; a copy with *no* install record edits the checkout
    /// it is sitting in, and failing that the folder the user picked.
    ///
    /// The one asymmetry there is deliberate and both halves of it matter:
    ///
    /// - A stale install record must not fall through to the build tree. The
    ///   build tree is found partly from the *working directory*, so it would
    ///   otherwise mean an installed copy editing one checkout from Spotlight
    ///   (cwd `/`, no answer, alert) and a different one from a terminal — Save
    ///   writing to a file that depends on how the app was launched.
    /// - The build tree must outrank the user's pick when there is no install
    ///   record, or a folder picked once by a copy that had been moved out of
    ///   its tree would outrank the tree forever after it was put back.
    ///
    /// `buildTree` is already a shader directory (that is what
    /// `ShaderLocations.repoShaderDirectory()` returns); the other three are repo
    /// roots as recorded.
    static func resolve(environment: String?, installRecord: String?, userChoice: String?,
                        buildTree: URL?) -> Outcome {
        func found(_ raw: String?, _ origin: Origin) -> Outcome? {
            guard let raw = cleaned(raw), let shaders = shaderDirectory(under: URL(fileURLWithPath: raw))
            else { return nil }
            return .found(shaders: shaders, root: repoRoot(of: shaders), origin: origin)
        }

        // An explicit environment override is the whole answer, right or wrong:
        // falling back from it would mean silently editing a checkout other than
        // the one that was asked for.
        if let raw = cleaned(environment) {
            return found(raw, .environment)
                ?? .missing(recorded: URL(fileURLWithPath: raw), origin: .environment)
        }

        // A copy that was told which checkout it is for. The path that is gone is
        // the one useful fact in the failure, so it goes in the message.
        if let record = cleaned(installRecord) {
            return found(record, .installRecord)
                ?? found(userChoice, .userChoice)
                ?? .missing(recorded: URL(fileURLWithPath: record), origin: .installRecord)
        }

        if let shaders = buildTree, holdsShaders(shaders) {
            return .found(shaders: shaders, root: repoRoot(of: shaders), origin: .buildTree)
        }
        if let picked = found(userChoice, .userChoice) { return picked }
        if let choice = cleaned(userChoice) {
            return .missing(recorded: URL(fileURLWithPath: choice), origin: .userChoice)
        }
        return .unset
    }

    private static func cleaned(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: The live answer

    /// Written into the installed copy's Info.plist by `make install-playground`.
    static var installRecord: String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    /// The folder the user picked after the recorded one went missing. This app's
    /// own preference domain, so the installed copy and the in-repo build — which
    /// have different bundle identifiers — cannot overwrite each other's answer.
    static var userChoice: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Resolved once per launch and then held, so the shader library, the
    /// rotation gallery, the New Shader destination and the title bar can never
    /// end up on different answers.
    private nonisolated(unsafe) static var cached: Outcome?

    @discardableResult
    static func settled() -> Outcome {
        if let cached { return cached }
        let outcome = resolve(environment: ProcessInfo.processInfo.environment[environmentKey],
                              installRecord: installRecord,
                              userChoice: userChoice,
                              buildTree: ShaderLocations.repoShaderDirectory())
        cached = outcome
        return outcome
    }

    /// Takes the folder the user picked. Remembers it only if it really is one —
    /// returns false otherwise, and the caller asks again rather than starting up
    /// onto an empty picker.
    static func adopt(root: URL) -> Bool {
        guard let shaders = shaderDirectory(under: root) else { return false }
        let settled = repoRoot(of: shaders)
        userChoice = settled.path
        cached = .found(shaders: shaders, root: settled, origin: .userChoice)
        return true
    }

    /// What to hand `ShaderLibrary(extraSearchURLs:)`. Empty when unresolved,
    /// which only the self-test and `--shaders` can now reach: the app asks the
    /// user before it builds a window.
    static var searchURLs: [URL] {
        if case let .found(shaders, _, _) = settled() { return [shaders] }
        return []
    }

    /// The checkout, for anything that wants to name it.
    static var root: URL? {
        if case let .found(_, root, _) = settled() { return root }
        return nil
    }

    /// True for the compile-only in-repo staging build. The title bar uses this:
    /// a copy that had to be *told* where the repo is says which
    /// one it found, and the build sitting in the repo says nothing new.
    static var isBuildTree: Bool {
        if case let .found(_, _, origin) = settled() { return origin == .buildTree }
        return false
    }

    // MARK: What to say when it fails

    /// The message for an outcome that is not `.found`, or nil for one that is.
    /// One text, used by the alert and by `--shaders`, so the app and the command
    /// line cannot describe the same problem differently.
    static func problem(_ outcome: Outcome) -> (title: String, detail: String)? {
        switch outcome {
        case .found:
            return nil
        case let .missing(recorded, origin):
            return ("Shader folder not found",
                    """
                    \(PlaygroundMain.name) edits the .metal files in a Lerping@Home \
                    checkout — it carries none of its own.

                    The folder \(origin.phrase):

                        \(recorded.path)

                    is not there any more. Choose the checkout (the folder holding \
                    Sources/Shaders) to carry on.
                    """)
        case .unset:
            return ("Shader folder not found",
                    """
                    \(PlaygroundMain.name) edits the .metal files in a Lerping@Home \
                    checkout — it carries none of its own.

                    This copy is at

                        \(Bundle.main.bundleURL.path)

                    and nothing was recorded telling it where the checkout is. Choose \
                    the checkout (the folder holding Sources/Shaders) to carry on.
                    """)
        }
    }
}

// MARK: - Asking for it

/// The one thing an installed copy must never do is open onto an empty shader
/// picker with no explanation, so when the recorded checkout is gone this runs
/// *before* there is a window: a named error, a folder picker, and no third
/// outcome. Choosing a folder that is not a checkout does not count as choosing.
enum ShaderFolderPrompt {

    private enum Choice {
        case folder(URL)
        /// The open panel was cancelled: back to the alert, which is where the
        /// choice between choosing and quitting is actually made.
        case again
        case quit
    }

    /// Resolves the shader folder for this launch, asking when it has to.
    /// Returns false only if the user would rather quit than point at one.
    static func settle() -> Bool {
        var note = ""
        while true {
            guard let problem = RepoLocation.problem(RepoLocation.settled()) else { return true }
            NSApp.activate(ignoringOtherApps: true)
            switch ask(problem, note: note) {
            case .quit:
                return false
            case .again:
                note = ""
            case let .folder(root):
                if RepoLocation.adopt(root: root) { return true }
                note = "“\(root.lastPathComponent)” holds no .metal files and no "
                     + "Sources/Shaders folder, so it is not a Lerping@Home checkout."
            }
        }
    }

    /// The alert, then the open panel.
    private static func ask(_ problem: (title: String, detail: String), note: String) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = problem.title
        alert.informativeText = note.isEmpty ? problem.detail : note + "\n\n" + problem.detail
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return .quit }

        let panel = NSOpenPanel()
        panel.title = "Choose the Lerping@Home checkout"
        panel.prompt = "Use This Folder"
        panel.message = "The folder holding Sources/Shaders."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return .again }
        return .folder(url)
    }
}
