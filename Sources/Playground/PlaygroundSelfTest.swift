import AppKit
import Metal
import MIDIDeps
import ScreenSaver

/// `LerpPlayground --selftest` — drives the real window through the loop the
/// app exists for: load a shader, watch it render, edit it, break it, fix it,
/// then work its parameter inspector and its MIDI mapping the same way.
///
/// It is a UI test, not a unit test: it opens the actual window, uses the actual
/// `LerpMetalView` display link, moves the actual `NSSlider`s, and — where the
/// machine has Core MIDI — creates a real virtual MIDI source and sends real CC
/// messages through Core MIDI into the running app.
///
/// The behaviours it exists to protect are the compiler diagnostics mapping back
/// to the shader file's own line numbers, the last-good pipeline surviving a
/// broken edit, the inspector being built from the declarations rather than any
/// table of names, and parameter values surviving a recompile.
///
/// None of that is allowed to cost the user a window. `make playground-test`
/// runs out of `LerpPlaygroundSelfTest.app`, which has a bundle identifier of
/// its own — so the single-instance check can never confuse it with the real
/// app, and it never activates one — as an `.accessory` (no Dock tile, no menu
/// bar, no ⌘-Tab) whose window is real and rendering but at zero opacity. See
/// `PlaygroundWindowController.hide`.
enum PlaygroundSelfTest {

    /// How long the whole script gets. The scripted part takes ~15 s; the rest
    /// is slack for a slow MIDI round trip on a busy machine.
    static let budget: TimeInterval = 90

    static func run() -> Never {
        setbuf(stdout, nil)   // unbuffered, so a hang still shows how far we got
        // Last resort, in the kernel rather than in this process's run loop: a
        // test run must never leave a process behind, not even if the main
        // thread is wedged behind a modal or a Core MIDI call that never
        // returns, in which case none of the Swift below ever runs again.
        alarm(UInt32(budget) + 30)
        PlaygroundMain.boot(SelfTestDelegate(), policy: .accessory)
    }
}

final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlaygroundWindowController!
    private var failures = 0
    private var checks = 0
    private var originalSource = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The window now picks what to open from the screensaver's rotation, so
        // the rotation has to be settled *before* it is built — and it has to be
        // one this test wrote, in a ByHost domain of the test's own. Same class,
        // same call, same keys, nobody's screensaver. See `RotationStore.
        // testModule` for why this is not the live one.
        //
        // The last-opened memory goes too: it beats the rotation by design, and
        // a run that inherited the shader the *previous* run happened to end on
        // would be testing nothing and would drift.
        OpeningShader.forget()
        let rotationDefaults = RotationStore.saverDefaults(module: Self.testModule)
        seedOpeningRotation(into: rotationDefaults)

        guard let controller = PlaygroundWindowController.make(hidden: true,
                                                               rotationDefaults: rotationDefaults)
        else {
            print("FAIL  no Metal device")
            exit(1)
        }
        self.controller = controller
        controller.showAndStart()
        // Deliberately no `NSApp.activate`: the window is invisible, so taking
        // the foreground for it would be taking it from the user for nothing.
        originalSource = controller.editor.text
        armWatchdog()

        // Timings are wall-clock on purpose — the point is to observe the real
        // 0.3 s edit debounce and the real display link, not to mock them.
        let script: [(TimeInterval, () -> Void)] = [
            (0.2, loaded), (1.8, rendering),
            (2.0, editValid), (2.9, editApplied),
            (3.1, editBroken), (4.0, errorReported), (5.3, stillRenderingWhileBroken),
            (5.5, restore), (6.3, recovered),
            (6.4, scaffold), (6.6, picksUpFilesOnDisk), (6.7, repoLocationChecks),
            // Inspector, then MIDI, then the end of the run. Everything from
            // here chains off the step before it rather than off the clock:
            // these steps wait on a recompile debounce and on messages that
            // leave through Core MIDI and come back when they come back.
            (6.8, inspectorChecks),
        ]
        for (delay, step) in script {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
        }
    }

    /// The script is a chain of callbacks, and several of its steps bail out
    /// early when the machine has nothing to test them with (no Core MIDI, no
    /// colour parameter). Any one of those that forgets to hand on would leave
    /// the run sitting there holding a window open, so the run has an end
    /// whether or not the script reaches it.
    private func armWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + PlaygroundSelfTest.budget) { [self] in
            check("the run finished inside its \(Int(PlaygroundSelfTest.budget)) s budget", false,
                  "stalled after \(checks) checks")
            finish()
        }
    }

    /// Runs `step` as soon as `condition` holds, or once `timeout` has elapsed —
    /// so a slow round trip costs time rather than a false failure, and the
    /// assertion in `step` is still the thing that decides pass or fail.
    private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval,
                      then step: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            guard !condition(), Date() < deadline else { return step() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
    }

    // MARK: Assertions

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks += 1
        failures += passed ? 0 : 1
        print("\(passed ? "ok   " : "FAIL ") \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private var isCompiled: Bool {
        if case .ok = controller.compileState { return true }
        return false
    }

    private var stateDetail: String {
        switch controller.compileState {
        case .pending: return "pending"
        case let .ok(ms): return String(format: "ok in %.0f ms", ms)
        case let .failed(items): return items.map(\.display).joined(separator: " / ")
        }
    }

    // MARK: Steps

    private func loaded() {
        check("window opened with a shader", controller.window?.isVisible == true
                && controller.editor.text.contains("lerpMain"), controller.currentName)
        check("initial compile succeeded", isCompiled, stateDetail)
        openedFromRotation()
    }

    // MARK: What the window opens on

    /// The line `editValid` inverts. Named here because two things depend on it:
    /// the edit itself, and the choice of shader to seed the opening rotation
    /// with — a shader without this line would make the hot-reload checks below
    /// assert on an edit that never happened.
    private static let editTarget = "return half4(half3(color), 1.0h);"

    /// The looks the window is allowed to open on, and the shader they belong to.
    private var openingCandidates: [LerpRotationEntry] = []
    private var openingShader: LerpShader?

    /// Writes the rotation the window will open from, before the window exists.
    ///
    /// Two deliberate choices. **Not the first shader on disk**: opening on that
    /// is exactly the behaviour this replaced, and a rotation seeded with it
    /// could not tell the two apart. **Presets only, no defaults entry**: a
    /// rotation entry is a (shader, preset) pair, so whichever one is drawn has
    /// a preset to apply, and "the preset was applied" becomes assertable
    /// against the packed uniform bytes rather than against a popup title.
    private func seedOpeningRotation(into defaults: UserDefaults?) {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let discovered = ShaderLibrary(device: device,
                                       extraSearchURLs: RepoLocation.searchURLs).discover()
        guard let shader = discovered.dropFirst().first(where: {
            !$0.presets.isEmpty && $0.source.contains(Self.editTarget)
        }) else { return }
        openingShader = shader
        openingCandidates = shader.presets.map {
            LerpRotationEntry(shader: shader.name, preset: $0.name)
        }
        RotationStore.save(Set(openingCandidates), entries: discovered.rotationEntries(),
                           to: defaults)
    }

    /// The regression this whole feature is: the window used to open on whatever
    /// came first alphabetically, which for this repo is `aurora` — a look the
    /// user may well have taken out of their rotation on purpose.
    private func openedFromRotation() {
        guard let shader = openingShader, !openingCandidates.isEmpty else {
            return check("a rotation to open from was seeded", false,
                         "no shader on disk has presets and the line the edit checks need")
        }
        let opened = controller.currentEntry
        check("the window opened on a look that is in the enabled rotation",
              openingCandidates.contains(opened),
              "\(opened.key) — enabled: \(openingCandidates.map(\.key).joined(separator: ", "))")
        check("…and not simply on the first shader on disk",
              opened.shader != controller.knownShaderNames.first,
              "opened \(opened.shader), first on disk is \(controller.knownShaderNames.first ?? "nothing")")

        // The entry's preset, proved by the bytes the fragment shader is handed
        // rather than by the label above them.
        var expected = shader.defaultParameterValues()
        if let name = opened.preset, let preset = shader.preset(named: name) { expected.apply(preset) }
        let live = controller.metalView.parameterValues?.packedTail
        check("the entry's preset was applied, not just named",
              live == expected.packedTail && live != shader.defaultParameterValues().packedTail,
              "\(opened.key): \(live?.count ?? -1) packed bytes, "
                + "\(zip(live ?? [], shader.defaultParameterValues().packedTail).filter { $0 != $1 }.count)"
                + " of them away from defaults")
        check("the inspector's preset popup says which look that is",
              controller.currentPreset == opened.preset, controller.currentPreset ?? "Defaults")

        // Reading a rotation is not writing one. Launching the app must leave
        // the screensaver's settings exactly as it found them.
        check("launching did not write the rotation it read",
              Set(persistedRotation()) == Set(openingCandidates.map(\.key)),
              persistedRotation().sorted().joined(separator: " "))
    }

    /// Every fallback `OpeningShader.choose` has to survive, driven directly
    /// because none of them can be arranged by launching the app: a tree where
    /// nothing compiles, a rotation naming shaders that are all gone, no
    /// screensaver defaults at all.
    private func openingPolicyUnits() {
        let discovered = controller.metalView.shaderLibrary.discover()
        let all = discovered.rotationEntries()
        guard all.count > 6, let first = all.first else { return }
        let opensEverything: (LerpRotationEntry) -> Bool = { _ in true }
        func choose(_ defaults: UserDefaults?, remembered: LerpRotationEntry? = nil,
                    opens: @escaping (LerpRotationEntry) -> Bool = { _ in true },
                    from index: Int = 0) -> LerpRotationEntry? {
            OpeningShader.choose(discovered: discovered, rotation: defaults, remembered: remembered,
                                 opens: opens, randomIndex: { _ in index })
        }

        check("no readable screensaver defaults still opens a look",
              choose(nil) == first, choose(nil)?.key ?? "nothing")

        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        guard let scratch = UserDefaults(suiteName: Self.scratchSuite) else { return }

        // Every fallback that means "all of them" goes through
        // `Config.rotation`, so these check the wiring, not a second copy of the
        // policy. An empty selection first…
        // A roster that covers today's looks with none of them selected. That is
        // "the user switched everything off", not "nobody has chosen", and it is
        // no longer read as the whole library — but the editor still has to open
        // onto a file, so it opens onto the first one there is.
        scratch.set([String](), forKey: RotationStore.enabledEntriesKey)
        scratch.set(all.map(\.key), forKey: RotationStore.knownEntriesKey)
        check("an empty enabled set still opens onto a file, without widening to all of them",
              choose(scratch, from: 3) == first, choose(scratch, from: 3)?.key ?? "nothing")

        // …then a rotation whose every entry has been deleted from disk. The
        // roster still names today's looks and switches all of them off, so this
        // is a rotation that resolves to nothing — unreachable through the
        // gallery, and the editor still has to open onto a file.
        scratch.set(["gone/One", "gone/Two"], forKey: RotationStore.enabledEntriesKey)
        scratch.set(all.map(\.key) + ["gone/One", "gone/Two"], forKey: RotationStore.knownEntriesKey)
        check("a rotation that resolves to no looks at all still opens onto a file",
              choose(scratch, from: 2) == first, choose(scratch, from: 2)?.key ?? "nothing")

        // …and the case that is genuinely "nobody has chosen": a roster that
        // does not cover today's looks, so they are new and every one is in.
        scratch.set(["gone/One", "gone/Two"], forKey: RotationStore.enabledEntriesKey)
        scratch.set(["gone/One", "gone/Two"], forKey: RotationStore.knownEntriesKey)
        check("a rotation naming only looks that have gone opens from all of them",
              choose(scratch, from: 2) == all[2], choose(scratch, from: 2)?.key ?? "nothing")
        scratch.set(all.map(\.key) + ["gone/One", "gone/Two"], forKey: RotationStore.knownEntriesKey)

        // A real subset, drawn at random: every draw has to land inside it. This
        // is the claim the feature makes, so it is checked against the real RNG
        // rather than against an injected index.
        let subset = Array(all.suffix(4))
        RotationStore.save(Set(subset), entries: all, to: scratch)
        let draws = (0..<300).compactMap {
            _ in OpeningShader.choose(discovered: discovered, rotation: scratch,
                                      remembered: nil, opens: opensEverything)
        }
        check("300 random draws all landed inside the enabled rotation",
              draws.count == 300 && draws.allSatisfy(subset.contains),
              "\(Set(draws.map(\.key)).count) distinct of \(subset.count) enabled")
        check("the draw is a draw — it does not always give the same look",
              Set(draws.map(\.key)).count > 1, Set(draws.map(\.key)).sorted().joined(separator: " "))

        // A broken shader is stepped over, not stopped on. `opens` says no to
        // everything up to the last enabled look.
        let survivor = subset[subset.count - 1]
        check("a look that will not compile is stepped past, not opened",
              choose(scratch, opens: { $0 == survivor }, from: 0) == survivor,
              choose(scratch, opens: { $0 == survivor }, from: 0)?.key ?? "nothing")
        // The one that used to widen. `first` is outside the enabled set and is
        // the *only* thing that compiles, and it still must not be opened: an
        // editor opens onto one of your own looks, broken, rather than onto a
        // working look you deliberately took out.
        check("an enabled set where nothing compiles opens a broken enabled look, "
              + "not a working deselected one",
              choose(scratch, opens: { $0 == first }, from: 0) == subset[0],
              choose(scratch, opens: { $0 == first }, from: 0)?.key ?? "nothing")
        check("a tree where nothing at all compiles still opens onto a file",
              choose(scratch, opens: { _ in false }, from: 0) == subset[0],
              "so the editor and its diagnostics are there to fix it with")
        check("no shaders at all is the only answer that is nothing",
              OpeningShader.choose(discovered: [], rotation: scratch, remembered: nil,
                                   opens: opensEverything) == nil)

        // The last-opened memory beats the rotation — that is what makes the
        // randomness free, because it can only fire when there is no place to
        // lose. `subset` is the enabled set, so a remembered look outside it is
        // the case that matters: you were editing something you had deselected.
        let outsider = all.first { !subset.contains($0) && $0.preset != nil } ?? first
        check("a remembered look wins over the rotation, even one not in it",
              choose(scratch, remembered: outsider) == outsider,
              choose(scratch, remembered: outsider)?.key ?? "nothing")
        check("a remembered shader that has been deleted falls back to the rotation",
              subset.contains(choose(scratch, remembered: LerpRotationEntry(key: "gone/One"),
                                     from: 1) ?? first))
        check("a remembered look whose preset the file dropped opens its defaults",
              choose(scratch, remembered: LerpRotationEntry(shader: outsider.shader,
                                                            preset: "no such preset"))
                  == LerpRotationEntry(shader: outsider.shader))
        check("a remembered shader that will not compile falls back to the rotation",
              subset.contains(choose(scratch, remembered: outsider,
                                     opens: { $0 != outsider }, from: 1) ?? first))

        // And the memory itself: the playground's own preferences, never the
        // screensaver's ByHost domain.
        check("the last-opened memory is not one of the rotation's keys",
              !RotationStore.allKeys.contains(OpeningShader.lastOpenedKey),
              OpeningShader.lastOpenedKey)
        check("the window remembered the look it is showing",
              OpeningShader.remembered() == controller.currentEntry,
              OpeningShader.remembered()?.key ?? "nothing")

        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        secondLaunchResumes(among: all)
    }

    /// The one link the checks above cannot reach: that the *window* consults
    /// the memory on the way up. Builds a second one — hidden, never shown,
    /// never started, thrown away at the end of the check — with a remembered
    /// look planted in front of it.
    ///
    /// The look planted is deliberately one the seeded rotation does not
    /// contain, so opening on it can only be the memory: a draw would never have
    /// offered it. That is also the case that matters in real use, where the
    /// shader you were up to at midnight is quite likely one you took out of the
    /// screensaver precisely because you are still working on it.
    private func secondLaunchResumes(among all: [LerpRotationEntry]) {
        guard let wanted = all.first(where: { $0.preset != nil && !openingCandidates.contains($0) })
        else { return }
        OpeningShader.remember(wanted)
        guard let second = PlaygroundWindowController
            .make(hidden: true, rotationDefaults: RotationStore.saverDefaults(module: Self.testModule))
        else { return check("a second launch reopens the look you left", false, "no Metal device") }
        check("a second launch reopens the look you left, not another draw",
              second.currentEntry == wanted,
              "\(second.currentEntry.key), wanted \(wanted.key)")
        second.window?.orderOut(nil)
    }

    private func rendering() {
        let fps = controller.metalView.measuredFPS
        check("live view is drawing frames", fps > 1, String(format: "%.0f fps", fps))
    }

    private func editValid() {
        // A real edit: invert the shader's output. Compiles, looks different.
        controller.editor.replaceTextAsEdit(originalSource.replacingOccurrences(
            of: Self.editTarget,
            with: "return half4(half3(1.0 - color), 1.0h);"))
    }

    private func editApplied() {
        check("hot reload recompiled the edit", isCompiled, stateDetail)
        check("editor holds the edited source", controller.editor.text.contains("1.0 - color"))

        // The edit inverted the output, so the pixels must move a long way.
        // Proves the buffer really is what reaches the GPU, not just that
        // something compiled.
        let before = meanLuma(of: originalSource)
        let after = meanLuma(of: controller.editor.text)
        check("rendered pixels changed", abs(before - after) > 0.2,
              String(format: "luma %.3f → %.3f", before, after))
    }

    /// Renders a source string offscreen through the same LerpCore path the
    /// live view uses, and returns its mean luminance.
    private func meanLuma(of source: String) -> Double {
        let library = controller.metalView.shaderLibrary
        guard let renderer = LerpRenderer(device: library.device) else { return -1 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-selftest-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let shader = LerpShader(name: "selftest", source: source, isBuiltIn: false, url: nil)
        let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                         width: 320, height: 200, time: 3, seed: 0.5, to: url)
        return result.error == nil ? result.meanLuminance : -1
    }

    private func editBroken() {
        // Break line 3 exactly, so we can assert the reported line number.
        controller.editor.replaceTextAsEdit("""
        // deliberately broken shader (selftest)
        fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
            float3 color = thisFunctionDoesNotExist(pos, u);
            return half4(half3(color), 1.0h);
        }
        """)
    }

    private func errorReported() {
        guard case let .failed(items) = controller.compileState else {
            check("broken source reported as an error", false, stateDetail)
            return
        }
        check("broken source reported as an error", !items.isEmpty, stateDetail)
        // The prelude's trailing `#line 1` is what makes program_source line
        // numbers land on the shader file's own lines. This is that assertion.
        let first = items.first(where: \.isError)
        check("error line number is right", first?.line == 3,
              "expected 3, got \(first.map { String($0.line) } ?? "none")")
        check("app did not crash on a bad shader", controller.window?.isVisible == true)
    }

    private func stillRenderingWhileBroken() {
        let fps = controller.metalView.measuredFPS
        check("last good pipeline still rendering", fps > 1, String(format: "%.0f fps", fps))
    }

    private func restore() {
        controller.editor.replaceTextAsEdit(originalSource)
    }

    private func recovered() {
        check("recovered after fixing the source", isCompiled, stateDetail)
        check("editor is back to the on-disk source", controller.editor.text == originalSource)
    }

    /// The New-shader template has to be valid the moment it is written, so
    /// compile it the same way the app would.
    private func scaffold() {
        let stem = "selftest-scaffold"
        let draft = LerpShader(name: stem, source: ShaderScaffold.template(for: stem),
                               isBuiltIn: false, url: nil)
        do {
            _ = try controller.metalView.shaderLibrary.pipeline(for: draft)
            check("new-shader template compiles", true)
        } catch {
            let (items, raw) = ShaderDiagnostics.parse(error)
            check("new-shader template compiles", false, ShaderDiagnostics.summary(items: items, raw: raw))
        }
        check("name sanitizer", ShaderScaffold.sanitize(name: "  My Cool Shader!! ") == "my-cool-shader",
              ShaderScaffold.sanitize(name: "  My Cool Shader!! ") ?? "nil")
        check("new shaders target the repo's Sources/Shaders",
              ShaderPaths.newShaderDirectory.lastPathComponent == "Shaders",
              ShaderPaths.newShaderDirectory.path)
    }

    /// The picker has to notice shaders that appear while the app is running —
    /// a `git pull`, another editor, or a concurrent agent adding files. Uses
    /// the user drop folder so the repo's Sources/Shaders is never written to.
    private func picksUpFilesOnDisk() {
        let stem = "zz-selftest-temp"
        let url = ShaderPaths.customDirectory.appendingPathComponent(stem + ".metal")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try FileManager.default.createDirectory(at: ShaderPaths.customDirectory,
                                                    withIntermediateDirectories: true)
            try ShaderScaffold.template(for: stem).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            check("new file on disk appears in the picker", false, error.localizedDescription)
            return
        }
        let openShader = controller.currentName
        controller.pollDisk()
        check("new file on disk appears in the picker", controller.knownShaderNames.contains(stem))
        check("editor kept its shader while the list changed",
              controller.currentName == openShader && controller.editor.text == originalSource,
              controller.currentName)

        try? FileManager.default.removeItem(at: url)
        controller.pollDisk()
        check("deleted file leaves the picker", !controller.knownShaderNames.contains(stem))
    }

    // MARK: Which checkout this copy edits

    /// `RepoLocation.resolve` decides where an installed copy reads shaders
    /// from, and — more to the point — what it does when that answer has gone
    /// stale. Driven here against real directories rather than mocks, including
    /// the ones that must fail: an app in ~/Applications whose checkout moved has
    /// to say so, and the check that it says so belongs in the suite rather than
    /// in whoever remembers to move a folder by hand.
    private func repoLocationChecks() {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-repo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        /// A believable checkout: `root/Sources/Shaders/x.metal`.
        func checkout(_ name: String) -> URL {
            let root = scratch.appendingPathComponent(name)
            let shaders = root.appendingPathComponent("Sources/Shaders")
            try? FileManager.default.createDirectory(at: shaders, withIntermediateDirectories: true)
            try? "// \(name)".write(to: shaders.appendingPathComponent("x.metal"),
                                    atomically: true, encoding: .utf8)
            return root
        }
        let installed = checkout("installed"), picked = checkout("picked")
        let gone = scratch.appendingPathComponent("gone")
        let empty = scratch.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        func resolve(env: String? = nil, record: String? = nil, choice: String? = nil,
                     tree: URL? = nil) -> RepoLocation.Outcome {
            RepoLocation.resolve(environment: env, installRecord: record,
                                 userChoice: choice, buildTree: tree)
        }
        func found(_ outcome: RepoLocation.Outcome) -> (URL, RepoLocation.Origin)? {
            if case let .found(shaders, _, origin) = outcome { return (shaders, origin) }
            return nil
        }
        func missing(_ outcome: RepoLocation.Outcome) -> (URL, RepoLocation.Origin)? {
            if case let .missing(recorded, origin) = outcome { return (recorded, origin) }
            return nil
        }

        let shaders = installed.appendingPathComponent("Sources/Shaders")
        check("a recorded checkout resolves to its Sources/Shaders",
              found(resolve(record: installed.path))?.0.path == shaders.path,
              found(resolve(record: installed.path))?.0.path ?? "not found")
        check("pointing straight at a folder of .metal files works too",
              found(resolve(record: shaders.path))?.0.path == shaders.path)
        check("a folder that is neither is refused",
              found(resolve(record: empty.path)) == nil)

        // The install record outranks the user's pick on purpose: re-running
        // `make install-playground` is how a copy gets re-pointed, and a folder
        // picked months ago must not quietly win over it.
        check("the install record beats a stale user choice",
              found(resolve(record: installed.path, choice: picked.path))?.1 == .installRecord)
        check("a checkout that moved falls back to the folder the user picked",
              found(resolve(record: gone.path, choice: picked.path)).map {
                  $0.0.path.hasPrefix(picked.path) && $0.1 == .userChoice } == true)

        // The whole point. An installed copy has no build tree above it, so this
        // is the state the user hits when they move their repo — and it must
        // carry the path that is gone, because that is the one useful fact in it.
        let stale = resolve(record: gone.path)
        check("a checkout that moved, with nothing else to fall back on, is an error",
              missing(stale)?.0.path == gone.path, missing(stale)?.1.rawValue ?? "not missing")
        check("that error names the missing folder in the words the alert uses",
              RepoLocation.problem(stale).map { $0.detail.contains(gone.path) } == true)
        check("so does having been told nothing at all",
              RepoLocation.problem(resolve()) != nil)

        // A stale record must not quietly fall through to a build tree: that is
        // found partly from the working directory, so it would mean an installed
        // copy editing one checkout when launched from Spotlight and another
        // when launched from a terminal.
        check("a stale install record does not fall through to a build tree",
              missing(resolve(record: gone.path,
                              tree: picked.appendingPathComponent("Sources/Shaders")))?.1
                  == .installRecord)
        // The other way round, though: a copy sitting in a checkout with nothing
        // recorded edits that checkout, even if it once had to be pointed
        // somewhere by hand.
        check("the build tree still outranks a folder picked back when there was none",
              found(resolve(choice: picked.path, tree: shaders))?.1 == .buildTree)
        check("and is used when the picked folder has gone too",
              found(resolve(choice: gone.path, tree: shaders))?.1 == .buildTree)

        // An explicit override is the whole answer, right or wrong: quietly
        // falling back to the build tree would mean editing a checkout other
        // than the one that was asked for.
        check("LERP_REPO_ROOT outranks the build tree",
              found(resolve(env: installed.path, tree: RepoLocation.searchURLs.first))?.1 == .environment)
        check("a bad LERP_REPO_ROOT is an error, not a silent fallback",
              missing(resolve(env: gone.path, tree: RepoLocation.searchURLs.first))?.1 == .environment)

        // And this run itself. `make playground-test` runs out of build/ and so
        // resolves by walking up; running the same executable out of an
        // installed copy resolves the checkout its Info.plist records. Either
        // way there is exactly one answer and it is really on disk, which is the
        // claim — the detail says which way it got there.
        let origin: String
        if case let .found(_, _, found) = RepoLocation.settled() { origin = found.tag } else { origin = "nothing" }
        check("this copy resolved exactly one shader folder, and it is on disk",
              RepoLocation.searchURLs.count == 1
                && RepoLocation.holdsShaders(RepoLocation.searchURLs[0]),
              "\(origin) → \(RepoLocation.root?.path ?? "no checkout")")
        check("every failure has something to say", [stale, resolve(), resolve(env: gone.path)]
                .allSatisfy { RepoLocation.problem($0)?.title.isEmpty == false })
    }

    // MARK: Parameter inspector

    /// Every assertion below is against a shader picked for *having* parameters,
    /// never for being that shader — the panel is built from whatever the file
    /// declares, so the test reads the declarations too instead of hardcoding
    /// names it expects.
    private var subject: LerpShader!
    private var scalarParam: LerpParam!
    private var colorParam: LerpParam!

    /// Opening a shader compiles synchronously, and so does moving a control,
    /// so these run back to back. Only the edit at the end has to wait.
    private func inspectorChecks() {
        let shaders = controller.metalView.shaderLibrary.discover()
        // A colour parameter as well as a scalar one, so the colour bindings
        // below have something real to drive.
        guard let shader = shaders.first(where: { shader in
            shader.parameters.contains { $0.type == .float }
                && shader.parameters.contains { $0.type == .color }
                && !shader.presets.isEmpty
        }) ?? shaders.first(where: { shader in
            shader.parameters.contains { $0.type == .float } && !shader.presets.isEmpty
        }) else {
            check("a shader with parameters and presets exists", false)
            return endMIDI()
        }
        subject = shader
        scalarParam = shader.parameters.first { $0.type == .float && $0.min < $0.max }
        // The most chromatic colour the shader declares: the one a hue knob has
        // the most to say about, and the one worth rendering to look at.
        colorParam = shader.parameters.filter { $0.type == .color }
            .max { a, b in chroma(of: a) < chroma(of: b) }
        controller.openShader(named: shader.name)

        panelMatchesDeclarations()
        moveSlider()
        sliderApplied()
        choosePreset()
        presetApplied()
        declareNewParameter()
    }

    private func panelMatchesDeclarations() {
        guard subject != nil else { return }
        let panel = controller.inspector
        check("inspector has one row per declared parameter",
              panel.rowNames == subject.parameters.map(\.name),
              "\(panel.rowNames.count) rows vs \(subject.parameters.count) declared")
        check("preset popup lists Defaults plus every declared preset",
              panel.presetTitles == ["Defaults"] + subject.presets.map(\.name),
              panel.presetTitles.joined(separator: ", "))
        check("controls match the declared types", subject.parameters.allSatisfy { param in
            switch param.type {
            case .float, .int: panel.control(named: param.name) is NSSlider
            case .bool:        panel.control(named: param.name) is NSSwitch
            case .color:       panel.control(named: param.name) is NSColorWell
            }
        })
        check("sliders honour the declared range", subject.parameters.allSatisfy { param in
            guard let slider = panel.control(named: param.name) as? NSSlider else { return true }
            return slider.minValue == param.min && slider.maxValue == param.max
        })
        check("panel starts at the declared defaults", subject.parameters.allSatisfy {
            controller.metalView.parameterValues?[$0.name] == $0.defaultValue
        })
    }

    private var tailBeforeSlider: [UInt8] = []

    /// Moves the real control the way a mouse would: set the value, fire the
    /// action. Nothing here reaches past the UI into the model.
    private func moveSlider() {
        guard let param = scalarParam,
              let slider = controller.inspector.control(named: param.name) as? NSSlider else { return }
        tailBeforeSlider = controller.metalView.parameterValues?.packedTail ?? []
        slider.doubleValue = param.max
        controller.inspector.act(on: slider)
    }

    private func sliderApplied() {
        guard let param = scalarParam else { return }
        let value = controller.metalView.parameterValues?[param.name]?.scalarValue ?? .nan
        check("moving a slider reaches the live parameter values", value == param.max,
              "\(param.name) = \(value), max \(param.max)")
        check("the bytes handed to the GPU changed",
              controller.metalView.parameterValues?.packedTail != tailBeforeSlider)
        check("the numeric field follows the slider",
              controller.inspector.fieldText(named: param.name) != nil)

        // The uniform block is what the fragment shader reads, so proving a
        // changed default changes the picture proves the whole chain from a
        // parameter to pixels. (The live view has no readback, so the pixel end
        // of it is measured through the same offscreen renderer as the earlier
        // hot-reload check.)
        let dark = meanLuma(of: sourceWithDefault(param.name, param.min))
        let bright = meanLuma(of: sourceWithDefault(param.name, param.max))
        check("a parameter's value changes the rendered picture", abs(dark - bright) > 0.01,
              String(format: "%@ %g → %g gives luma %.3f → %.3f",
                     param.name, param.min, param.max, dark, bright))
    }

    /// Rewrites one `// lerp-param:` line's default, found through the parser
    /// rather than by matching text.
    private func sourceWithDefault(_ name: String, _ value: Double) -> String {
        var lines = subject.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let param = subject.parameters.first(where: { $0.name == name }),
              param.line >= 1, param.line <= lines.count,
              let equals = lines[param.line - 1].firstIndex(of: "=") else { return subject.source }
        lines[param.line - 1] = String(lines[param.line - 1][..<equals])
            + "= \(value) \"\(param.label)\""
        return lines.joined(separator: "\n")
    }

    private func choosePreset() {
        guard let preset = subject?.presets.first else { return }
        controller.inspector.choosePreset(preset.name)
    }

    private func presetApplied() {
        guard let preset = subject?.presets.first else { return }
        let values = controller.metalView.parameterValues
        check("preset set every value it declares",
              preset.values.allSatisfy { values?[$0.key] == $0.value },
              preset.name)
        check("preset returned everything else to its default",
              subject.parameters.filter { preset.values[$0.name] == nil }
                  .allSatisfy { values?[$0.name] == $0.defaultValue })
    }

    /// A shader edited to declare a *new* parameter has to grow a row when it
    /// recompiles — this is the case that would break if the panel were built
    /// once and cached.
    /// One of each declarable type, so the bool and colour rows get built for
    /// real even when no shipped shader happens to declare one.
    private static let injected = """
    // lerp-param: zzSelfTest float 0 1 = 0.5 "Self test"
    // lerp-param: zzSelfTestFlag bool = true "Self test flag"
    // lerp-param: zzSelfTestTint color = #40c0ff "Self test tint"

    """

    private func declareNewParameter() {
        controller.editor.replaceTextAsEdit(Self.injected + subject.source)
        // Waits out the editor's real 0.3 s debounce and the real recompile.
        wait(until: { [self] in controller.inspector.rowNames.contains("zzSelfTest") },
             timeout: 5, then: panelRebuiltAfterEdit)
    }

    private func panelRebuiltAfterEdit() {
        guard let param = scalarParam else { return }
        let panel = controller.inspector
        check("newly declared parameters appear in the panel",
              ["zzSelfTest", "zzSelfTestFlag", "zzSelfTestTint"].allSatisfy(panel.rowNames.contains),
              panel.rowNames.joined(separator: ", "))
        check("a declared bool builds a switch and a colour builds a colour well",
              panel.control(named: "zzSelfTestFlag") is NSSwitch
                  && panel.control(named: "zzSelfTestTint") is NSColorWell)
        check("a declared bool starts at its declared default",
              (panel.control(named: "zzSelfTestFlag") as? NSSwitch)?.state == .on)
        check("a control the user moved survives the recompile",
              controller.metalView.parameterValues?[param.name]?.scalarValue == param.max
                  || controller.parameterState[param.name] != nil,
              "\(controller.metalView.parameterValues?[param.name]?.scalarValue ?? .nan)")

        // The buffer is now dirty, so the preset has to come from the editor's
        // own source rather than from the file on disk.
        if let preset = subject.presets.first {
            controller.inspector.choosePreset(preset.name)
            check("presets still apply while the buffer has unsaved edits",
                  preset.values.allSatisfy { controller.metalView.parameterValues?[$0.key] == $0.value })
        }
        openParameterless()
        emptyState()
        midiSetUp()
    }

    private static let parameterlessShader = "zz-selftest-noparams"

    private func openParameterless() {
        let url = ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal")
        try? FileManager.default.createDirectory(at: ShaderPaths.customDirectory,
                                                 withIntermediateDirectories: true)
        try? ShaderScaffold.template(for: Self.parameterlessShader)
            .write(to: url, atomically: true, encoding: .utf8)
        controller.pollDisk()
        controller.openShader(named: Self.parameterlessShader)
    }

    private func emptyState() {
        check("a shader with no parameters shows the empty state",
              controller.inspector.rowNames.isEmpty && controller.inspector.isEmptyStateVisible,
              controller.currentName)
        try? FileManager.default.removeItem(at: ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal"))
        controller.openShader(named: subject.name)
    }

    // MARK: MIDI

    /// A mapping bank of our own, so the test never edits one the user made.
    private static let testMapping = "zz-selftest-midi"
    private var sender: MIDIManager?
    private var senderID = ""
    private var boundParam: LerpParam!

    /// A virtual MIDI source in a *second* `MIDIManager`, so the messages reach
    /// the app the way a plugged-in controller's would: out through Core MIDI
    /// and back in through the playground's own input connection. Nothing here
    /// calls the router directly.
    private func midiSetUp() {
        check("MIDI subsystem started", controller.midi.isAvailable,
              controller.midi.unavailableReason ?? controller.midi.summary)
        guard controller.midi.isAvailable else {
            print("skip  MIDI learn and routing  — no Core MIDI on this machine")
            return endMIDI()
        }
        boundParam = scalarParam
        let manager = MIDIManager(clientName: "LerpSelfTest", model: "Lerping@Home",
                                  manufacturer: "Lerping@Home")
        do {
            try manager.start()
            try manager.addOutput(name: "Lerp Selftest Source", tag: "out", uniqueID: .adHoc)
        } catch {
            check("virtual MIDI source created", false, "\(error)")
            return endMIDI()
        }
        senderID = manager.managedOutputs["out"]?.uniqueID.map { String(describing: $0) } ?? ""
        sender = manager
        check("virtual MIDI source created", !senderID.isEmpty, senderID)
        wait(until: { [self] in controller.midi.sources.contains { $0.id == senderID } },
             timeout: 5, then: midiLearn)
    }

    private func send(cc: UInt7, _ value: UInt8, channel: UInt4 = 0) {
        do {
            try sender?.managedOutputs["out"]?
                .send(event: .cc(cc, value: .midi1(UInt7(value)), channel: channel))
        } catch {
            check("sending CC\(cc)", false, "\(error)")
        }
    }

    private func midiLearn() {
        check("the playground sees the virtual source",
              controller.midi.sources.contains { $0.id == senderID }, controller.midi.summary)
        // A bank of our own, so learn never writes into one the user made.
        controller.createMapping(named: Self.testMapping, deviceID: senderID)
        controller.learnTarget = (boundParam.name, nil)
        send(cc: 21, 0)     // the next CC captures its own identity
        wait(until: { [self] in controller.activeMapping?.binding(for: boundParam.name) != nil },
             timeout: 5, then: midiRouted)
    }

    private func midiRouted() {
        let binding = controller.activeMapping?.binding(for: boundParam.name)
        check("learn captured the inbound CC", binding?.cc == 21, binding?.shortLabel ?? "nothing bound")
        check("the learned binding is on disk", MIDIMappingStore.load().contains {
            $0.name == Self.testMapping && $0.binding(for: boundParam.name)?.cc == 21
        })
        check("the row shows what it is bound to",
              controller.inspector.bindingLabel(named: boundParam.name) == "CC21",
              controller.inspector.bindingLabel(named: boundParam.name) ?? "nil")
        send(cc: 21, 127)   // full-scale: the parameter should hit its declared max
        wait(until: { [self] in
            controller.metalView.parameterValues?[boundParam.name]?.scalarValue == boundParam.max
        }, timeout: 5, then: midiApplied)
    }

    private func midiApplied() {
        let value = controller.metalView.parameterValues?[boundParam.name]?.scalarValue ?? .nan
        check("a CC moved the live parameter", abs(value - boundParam.max) < 1e-6,
              "\(boundParam.name) = \(value), max \(boundParam.max)")
        check("the inspector shows the MIDI-driven value",
              Double(controller.inspector.fieldText(named: boundParam.name) ?? "") == boundParam.max,
              controller.inspector.fieldText(named: boundParam.name) ?? "nil")
        // An unmapped knob must not touch anything.
        send(cc: 99, 0)
        wait(until: { false }, timeout: 0.4, then: { [self] in
            check("an unmapped CC changed nothing",
                  controller.metalView.parameterValues?[boundParam.name]?.scalarValue == boundParam.max)
            colorLearn()
        })
    }

    // MARK: Colour over MIDI

    /// A colour bound to one CC, learned through the row's own menu and driven
    /// through Core MIDI — the case that did not exist before, end to end.
    private var colorBefore = SIMD4<Float>()

    private func colorLearn() {
        guard let param = colorParam else {
            print("skip  colour bindings  — the subject shader declares no colour")
            return endMIDI()
        }
        colorBefore = liveColor(param.name)
        // Through the panel's own callback, i.e. the path a click on the Hue
        // submenu's "Learn…" takes.
        controller.midiCommand(param.name, .hue, .learn)
        send(cc: 22, 0)
        wait(until: { [self] in
            controller.activeMapping?.binding(for: param.name, component: .hue) != nil
        }, timeout: 5, then: colorLearned)
    }

    private func colorLearned() {
        guard let param = colorParam else { return endMIDI() }
        let binding = controller.activeMapping?.binding(for: param.name, component: .hue)
        check("learn on a colour's Hue axis captured the CC",
              binding?.cc == 22 && binding?.component == .hue,
              binding?.shortLabel ?? "nothing bound")
        check("the colour row's title names the axis it drives",
              controller.inspector.bindingLabel(named: param.name) == "CC22 H",
              controller.inspector.bindingLabel(named: param.name) ?? "nil")
        check("a colour row offers all four OKLCH axes",
              ColorComponent.allCases.allSatisfy { component in
                  controller.inspector.midiMenuTitles(named: param.name)
                      .contains { $0.hasPrefix(component.label) }
              },
              controller.inspector.midiMenuTitles(named: param.name).joined(separator: " / "))
        check("each axis carries the same menu a scalar row has",
              ["Learn…", "Clear", "Toggle"].allSatisfy(
                  controller.inspector.midiMenuTitles(named: param.name, component: .hue).contains))
        check("the learned colour binding is on disk", MIDIMappingStore.load().contains {
            $0.name == Self.testMapping
                && $0.binding(for: param.name, component: .hue)?.cc == 22
        })
        // Full scale is half a turn from the base hue, which is the furthest
        // the knob goes and so the largest visible change.
        send(cc: 22, 127)
        wait(until: { [self] in liveColor(param.name) != colorBefore }, timeout: 5, then: colorApplied)
    }

    private func colorApplied() {
        guard let param = colorParam else { return endMIDI() }
        let now = liveColor(param.name)
        check("a CC moved the live colour", now != colorBefore,
              "\(describe(colorBefore)) → \(describe(now))")
        check("the knob only moved hue — lightness held", holdsLightness(colorBefore, now),
              String(format: "L %.4f → %.4f", lightness(colorBefore), lightness(now)))
        check("the colour the knob produced is inside sRGB", inGamut(now), describe(now))
        check("the colour well followed the knob",
              (controller.inspector.control(named: param.name) as? NSColorWell) != nil
                  && liveColor(param.name) == now)

        // Second CC, second axis, same parameter: the composition case.
        controller.midiCommand(param.name, .lightness, .learn)
        send(cc: 23, 0)
        wait(until: { [self] in
            controller.activeMapping?.binding(for: param.name, component: .lightness) != nil
        }, timeout: 5, then: colorSecondAxis)
    }

    private var hueBeforeSecondAxis = 0.0

    private func colorSecondAxis() {
        guard let param = colorParam else { return endMIDI() }
        let bindings = controller.activeMapping?.bindings(for: param.name) ?? []
        check("two CCs can drive two axes of one colour", bindings.count == 2,
              bindings.map(\.shortLabel).joined(separator: " + "))
        check("the row's title says how many knobs are on it",
              controller.inspector.bindingLabel(named: param.name) == "2 CCs",
              controller.inspector.bindingLabel(named: param.name) ?? "nil")
        hueBeforeSecondAxis = Oklch.lch(fromSRGB: rgb(liveColor(param.name))).h
        send(cc: 23, 100)
        wait(until: { [self] in lightness(liveColor(param.name)) > 0.7 }, timeout: 5,
             then: colorComposed)
    }

    private func colorComposed() {
        guard let param = colorParam else { return endMIDI() }
        let now = liveColor(param.name)
        let hue = Oklch.lch(fromSRGB: rgb(now)).h
        check("the lightness knob moved lightness", lightness(now) > 0.7,
              String(format: "L %.3f", lightness(now)))
        // The point of a component selector: two knobs on one colour do not
        // fight. Moving L must not drag H with it.
        check("moving one axis left the other where it was",
              abs(hue - hueBeforeSecondAxis) < 1.0,
              String(format: "H %.1f° → %.1f°", hueBeforeSecondAxis, hue))
        check("the composed colour is still inside sRGB", inGamut(now), describe(now))
        colorMenu(param)
        endMIDI()
    }

    /// The menu itself, driven by firing the items AppKit would fire. Nothing
    /// here reaches past the UI: if an item is disabled or unwired, these fail.
    private func colorMenu(_ param: LerpParam) {
        // Task 2's editor is a menu item rather than two more fields per row,
        // so the scope has to be legible from the item's title.
        var preset = controller.activeMapping!
        preset.bind(preset.binding(for: param.name, component: .hue)!.withRange(low: 0.25, high: 0.75))
        controller.applyMapping(preset)
        check("the range editor reports its scope in the menu",
              controller.inspector.midiMenuTitles(named: param.name, component: .hue)
                  .contains("Range… (0.25–0.75)"),
              controller.inspector.midiMenuTitles(named: param.name, component: .hue)
                  .last ?? "no items")

        check("Clear on one axis leaves the other bound",
              controller.inspector.chooseMIDIMenuItem(named: param.name, component: .hue,
                                                      title: "Clear")
                  && controller.activeMapping?.binding(for: param.name, component: .hue) == nil
                  && controller.activeMapping?.binding(for: param.name, component: .lightness) != nil,
              (controller.activeMapping?.bindings(for: param.name) ?? [])
                  .map(\.shortLabel).joined(separator: " + "))
        check("Clear All takes every axis at once",
              controller.inspector.chooseMIDIMenuItem(named: param.name, component: nil,
                                                      title: "Clear All")
                  && controller.activeMapping?.bindings(for: param.name).isEmpty == true)
    }

    // MARK: Colour helpers

    private func liveColor(_ name: String) -> SIMD4<Float> {
        controller.metalView.parameterValues?[name]?.colorValue ?? SIMD4<Float>()
    }

    private func chroma(of param: LerpParam) -> Double {
        param.defaultValue.colorValue.map { Oklch.lch(fromSRGB: rgb($0)).c } ?? 0
    }

    private func rgb(_ c: SIMD4<Float>) -> SIMD3<Double> {
        SIMD3(Double(c.x), Double(c.y), Double(c.z))
    }

    private func lightness(_ c: SIMD4<Float>) -> Double { Oklch.lch(fromSRGB: rgb(c)).l }

    /// The composition guarantee: a hue knob leaves perceptual lightness alone.
    /// The tolerance is 8-bit quantisation, not slack — the colour makes a round
    /// trip through `SIMD4<Float>` and the shader's uniform block.
    private func holdsLightness(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        abs(lightness(a) - lightness(b)) < 0.005
    }

    private func inGamut(_ c: SIMD4<Float>) -> Bool {
        c.min() >= 0 && c.max() <= 1
    }

    private func describe(_ c: SIMD4<Float>) -> String {
        String(format: "(%.3f, %.3f, %.3f, %.3f)", c.x, c.y, c.z, c.w)
    }

    private func endMIDI() {
        routerUnits()
        colorProjectionUnits()
        bindingPersistenceUnits()
        mappingBankUnits()
        transportChecks()
        appCitizenshipChecks()
        renderColorSweep()
        captureUI()
        rotationUnits()
        deselectionUnits()
        auroraAcceptance()
        renameUnits()
        staleWriterUnits()
        openingPolicyUnits()
        rotationGalleryChecks()      // async; chains on to finish()
    }

    // MARK: The screensaver rotation

    /// A scratch preferences domain for the pure policy checks, so they can
    /// describe defaults that no user has (a rotation gone entirely stale, a
    /// pre-preset `enabledShaders` list) without inventing them in the user's.
    private static let scratchSuite = "zz-selftest-rotation"
    private var scratch: UserDefaults!

    /// The ByHost domain the gallery checks write to. Never the user's.
    private static let testModule = RotationStore.testModule

    private func rotationEntriesNow() -> [LerpRotationEntry] {
        controller.metalView.shaderLibrary.discover().rotationEntries()
    }

    /// The load/save policy, against defaults dictionaries this test writes by
    /// hand. Every one of these is an invariant the saver already keeps and the
    /// playground must not break — an empty rotation is a black screensaver.
    private func rotationUnits() {
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        scratch = UserDefaults(suiteName: Self.scratchSuite)
        let all = rotationEntriesNow()
        check("the rotation is (shader, preset) pairs, not just shaders",
              all.count > controller.metalView.shaderLibrary.discover().count,
              "\(all.count) looks across \(controller.metalView.shaderLibrary.discover().count) shaders")
        guard all.count > 4, let scratch else { return }

        check("nothing saved means every look",
              RotationStore.load(discovered: all, from: scratch) == nil
                  && RotationStore.rotation(discovered: all, from: scratch).count == all.count)

        // A real subset survives the round trip untouched.
        let subset = Set(all.prefix(3))
        RotationStore.save(subset, entries: all, to: scratch)
        check("a saved subset comes back exactly",
              RotationStore.load(discovered: all, from: scratch) == subset,
              (RotationStore.load(discovered: all, from: scratch) ?? []).map(\.key).sorted().joined(separator: " "))
        check("it is written under the keys the saver reads",
              scratch.stringArray(forKey: "enabledEntries")?.count == 3
                  && scratch.stringArray(forKey: "knownEntries")?.count == all.count
                  && scratch.stringArray(forKey: "enabledShaders") != nil
                  && scratch.stringArray(forKey: "knownShaders") != nil,
              RotationStore.allKeys.joined(separator: ", "))

        // A look discovered since the last save joins on its own, so a new
        // .metal file — or a new preset on one that was already there — is not
        // silently left out.
        let older = Array(all.dropLast(2))
        RotationStore.save(Set(older.prefix(3)), entries: older, to: scratch)
        let afterDiscovery = RotationStore.load(discovered: all, from: scratch) ?? []
        check("looks discovered since the last save join automatically",
              all.suffix(2).allSatisfy(afterDiscovery.contains) && afterDiscovery.count == 5,
              "\(afterDiscovery.count) enabled")

        // A rotation naming only looks that are gone, and nothing else in the
        // domain at all. The roster is what makes this readable: today's looks
        // are not in it, so they are *new*, and new looks are in. Note the route
        // — the full rotation comes back because nobody has ever said no to
        // these, not because the answer came out awkward and something widened
        // it. Every key first, because a leftover record from the saves above
        // would make this a different question (one `staleWriterUnits` asks).
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        scratch.set(["gone/One", "gone/Two"], forKey: "enabledEntries")
        scratch.set(["gone/One", "gone/Two"], forKey: "knownEntries")
        check("a rotation naming only looks that have gone means every look",
              RotationStore.rotation(discovered: all, from: scratch).count == all.count,
              "\(RotationStore.load(discovered: all, from: scratch)?.count ?? -1)")

        // …and the case that is *not* the same: a roster that does cover today's
        // looks and switches every one of them off. That is a user saying no to
        // all of them, and it is taken at its word rather than inverted into
        // yes. Unreachable through the gallery — see `galleryFloorChecks` — and
        // this is the check that the store no longer rewrites it if it is
        // reached by hand.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        scratch.set(["gone/One", "gone/Two"], forKey: "enabledEntries")
        scratch.set(all.map(\.key) + ["gone/One", "gone/Two"], forKey: "knownEntries")
        check("a roster that switches every look off is taken literally, not inverted",
              RotationStore.load(discovered: all, from: scratch)?.isEmpty == true
                  && RotationStore.rotation(discovered: all, from: scratch).isEmpty,
              "\(RotationStore.rotation(discovered: all, from: scratch).count) would play")

        // Deselecting everything persists as nothing selected. The floor is the
        // gallery's, and it is the only one.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        RotationStore.save([], entries: all, to: scratch)
        check("an empty selection is saved as an empty selection",
              scratch.stringArray(forKey: "enabledEntries")?.isEmpty == true
                  && RotationStore.rotation(discovered: all, from: scratch).isEmpty,
              "\(scratch.stringArray(forKey: "enabledEntries")?.count ?? -1) keys written")

        // The rule the schema turns on, stated on its own: a writer that never
        // mentions a look says nothing about it, and nothing is not consent.
        // This is what stops a roster that has fallen behind — an older build, a
        // renamed preset, a `defaults write` — from switching a deselected look
        // back on, which it did for years by reading absence as "new".
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        let denied = all[1]
        RotationStore.save(Set(all).subtracting([denied]), entries: all, to: scratch)
        scratch.set(all.filter { $0 != denied }.map(\.key), forKey: "knownEntries")
        scratch.set(all.filter { $0 != denied }.map(\.key), forKey: "enabledEntries")
        check("an explicit no survives a writer that has never heard of that look",
              RotationStore.load(discovered: all, from: scratch)?.contains(denied) == false,
              denied.key)
        // …and is revoked by an explicit yes, which is the only thing that may.
        scratch.set(all.map(\.key), forKey: "knownEntries")
        scratch.set(all.map(\.key), forKey: "enabledEntries")
        check("…and an explicit yes is what revokes it",
              RotationStore.load(discovered: all, from: scratch)?.contains(denied) == true,
              denied.key)

        // The pre-preset format: a set of shader *names*. Every look of a shader
        // that was in it joins, because the user picked those shaders.
        let legacyShader = all[0].shader
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        scratch.set([legacyShader], forKey: "enabledShaders")
        scratch.set(all.map(\.shader), forKey: "knownShaders")
        let migrated = RotationStore.load(discovered: all, from: scratch) ?? []
        check("a rotation saved before presets existed still migrates",
              !migrated.isEmpty && migrated.allSatisfy { $0.shader == legacyShader }
                  && migrated.count == all.filter { $0.shader == legacyShader }.count,
              "\(migrated.count) looks of \(legacyShader)")

        // …and `Config.rotation` is the one place the policy lives; this is the
        // same call the saver makes. Two answers, and no third: nil is "nobody
        // has chosen" and means all of them, anything else is taken literally.
        check("only a nil selection means every look; a set is taken literally",
              LerpMetalView.Config.rotation(of: nil, from: all).count == all.count
                  && LerpMetalView.Config.rotation(of: [], from: all).isEmpty
                  && LerpMetalView.Config.rotation(of: subset, from: all).count == 3)
        check("an entirely stale set does not widen either — it selects nothing",
              LerpMetalView.Config.rotation(
                  of: [LerpRotationEntry(key: "gone/One")], from: all).isEmpty)
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
    }

    // MARK: A deselected look cannot play

    /// A throwaway directory of `.metal` files, so the checks below can describe
    /// a shader library exactly — three looks that compile, one that never will
    /// — without touching the repo or the user's drop folder.
    ///
    /// `LerpMetalView(frame:extraSearchURLs:)` still scans the bundle and the
    /// user's folder as well, so these are *extra* shaders rather than the only
    /// ones. That is on purpose: the claims below are about what the rotation
    /// excludes, and they are stronger when there is more around to be wrongly
    /// included.
    private func writeShaders(_ files: [String: String]) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lerp-selftest-shaders-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, source) in files {
                try source.write(to: directory.appendingPathComponent(name + ".metal"),
                                 atomically: true, encoding: .utf8)
            }
        } catch { return nil }
        return directory
    }

    /// A shader that compiles, with `presets` declared on it.
    private static func shaderSource(presets: [String]) -> String {
        var text = "// lerp-param: tint float 0 1 = 0.5 \"Tint\"\n"
        for (index, name) in presets.enumerated() {
            text += "// lerp-preset: \(name) tint=\(Double(index + 1) / Double(presets.count + 1))\n"
        }
        return text + """
        fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
            float2 uv = lerpScreenUV(pos, u.resolution);
            return half4(half3(half(u.tint * uv.x), half(uv.y), half(u.seed)), 1.0h);
        }
        """
    }

    /// The regression this whole file's rotation section exists for.
    ///
    /// `legacyScreenSaver` builds a host and never destroys it, so one
    /// `LerpMetalView` outlives many screensaver sessions and many trips through
    /// the Options… sheet. The shuffle order used to be built once, the first
    /// time a pipeline was compiled, and nothing rebuilt it — so deselecting a
    /// look wrote the defaults correctly, the next session read them correctly,
    /// and the view went on shuffling the list it had built before the click.
    /// The look came back minutes later with every setting saying it should not
    /// have. That is the bug; these are the checks that it cannot come back.
    private func deselectionUnits() {
        let names = ["zz-selftest-a", "zz-selftest-b", "zz-selftest-c"]
        var files: [String: String] = [:]
        for name in names { files[name] = Self.shaderSource(presets: ["One", "Two"]) }
        guard let directory = writeShaders(files) else {
            return check("a throwaway shader directory could be written", false)
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                                       extraSearchURLs: [directory]) else {
            return check("a second Metal view for the rotation checks", false, "no device")
        }

        let all = view.shaderLibrary.discover().rotationEntries()
        let mine = all.filter { names.contains($0.shader) }
        guard mine.count == 9 else {
            return check("the throwaway shaders were discovered", false,
                         "\(mine.count) of 9 looks, from \(all.count) in total")
        }

        // Start the view on the *full* rotation and let it build a pipeline —
        // this is the state a long-lived host is in when the user goes to
        // System Settings and starts unticking things.
        view.config.shuffleInterval = 3600
        view.config.enabledEntries = Set(all)
        view.start()
        check("the view picked a look to start on", view.currentEntry != nil,
              view.currentEntry?.key ?? "nothing")

        // Now deselect: everything belonging to the first shader, plus whatever
        // happens to be on screen, so the check covers both "never pick it
        // again" and "stop showing it now".
        let banned = Set(all.filter { $0.shader == names[0] })
            .union([view.currentEntry].compactMap { $0 })
        let kept = Set(all).subtracting(banned)
        view.config.enabledEntries = kept

        check("deselecting the look on screen takes it off the screen now, "
              + "not at the end of the interval",
              view.currentEntry.map { !banned.contains($0) } ?? false,
              view.currentEntry?.key ?? "nothing")
        check("the rotation the view reports is exactly what is enabled",
              Set(view.rotationNow) == kept,
              "\(view.rotationNow.count) looks for \(kept.count) enabled")

        // Five hundred advances through the real interval path. The shuffle is
        // random, so one advance proves nothing; the claim is that *no* number
        // of them can reach a deselected look.
        var seen: Set<LerpRotationEntry> = []
        for _ in 0..<500 {
            view.advanceShuffle(by: 1)
            if let entry = view.currentEntry { seen.insert(entry) }
        }
        let escaped = seen.intersection(banned)
        check("500 shuffle advances never reached a deselected look",
              escaped.isEmpty, escaped.map(\.key).sorted().prefix(4).joined(separator: ", "))
        check("…and they did move around inside the enabled set",
              seen.count > 3 && seen.isSubset(of: kept),
              "\(seen.count) distinct looks, all enabled: \(seen.isSubset(of: kept))")

        // A shader pinned by name is a different contract — the rotation does
        // not apply to it — but it must not leave a stale order behind either.
        view.config.shaderName = names[0]
        check("pinning a deselected shader is still allowed, because pinning is not the rotation",
              view.currentShaderName == names[0], view.currentShaderName)
        view.config.shaderName = nil
        view.advanceShuffle(by: 1)
        check("un-pinning returns to the enabled rotation, not to the pinned shader",
              view.currentEntry.map(kept.contains) ?? false,
              view.currentEntry?.key ?? "nothing")
        view.stop()

        compileFallbackUnits()
    }

    /// The other way a deselected look used to reach the screen.
    ///
    /// `selectInitialShader` had a fallback: if nothing in the enabled rotation
    /// compiled, widen to *every* look rather than present nothing. It is gone.
    /// A user who has switched a look off has not asked to see it when the
    /// alternative is inconvenient, and the widening was never much of a rescue
    /// anyway — every shader builds through the same device and the same
    /// prelude, so a failure broad enough to take out the whole rotation takes
    /// out the rest too.
    private func compileFallbackUnits() {
        let broken = "this is not Metal source and never will be"
        guard let directory = writeShaders(["zz-selftest-broken": broken,
                                            "zz-selftest-fine": Self.shaderSource(presets: ["One"])])
        else { return check("a throwaway shader directory for the compile check", false) }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                                       extraSearchURLs: [directory]) else { return }

        let all = view.shaderLibrary.discover().rotationEntries()
        let brokenEntry = LerpRotationEntry(shader: "zz-selftest-broken")
        guard all.contains(brokenEntry), all.count > 2 else {
            return check("the deliberately broken shader was discovered", false, "\(all.count) looks")
        }

        // A rotation of exactly one look, which cannot be built. It resolves —
        // the entry exists, so this is not the "entirely stale means all" case
        // — it simply will not compile.
        view.config.enabledEntries = [brokenEntry]
        view.start()
        check("a rotation whose only look will not compile renders nothing, "
              + "rather than something the user switched off",
              view.currentEntry == nil, view.currentEntry?.key ?? "nothing")
        check("…and the compile failure was reported rather than swallowed",
              view.shaderLibrary.compileErrors["zz-selftest-broken"] != nil)
        view.stop()

        // With one buildable look in the rotation beside it, the broken one is
        // stepped over — which is the behaviour the widening was confused with.
        guard let fine = all.first(where: { $0.shader == "zz-selftest-fine" }) else { return }
        guard let second = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                                         extraSearchURLs: [directory]) else { return }
        second.config.enabledEntries = [brokenEntry, fine]
        second.start()
        check("a broken look in the rotation is stepped over, not stopped on",
              second.currentEntry == fine, second.currentEntry?.key ?? "nothing")
        second.stop()
    }

    // MARK: The report, as a test

    /// The user's actual complaint, turned into an assertion.
    ///
    /// `aurora`, `aurora/Ember` and `aurora/Quiet` are switched off, and then
    /// every route by which the old code could put one of them on screen is
    /// taken in turn. Each check asserts on **the entry the view actually
    /// chose**, not on what is in the saved array — the saved array was always
    /// right, which is exactly why the bug survived three rounds of looking at
    /// it.
    ///
    /// The routes, and what each of them used to do:
    ///
    /// 1. The initial pick, from a rotation read out of a real ByHost domain.
    /// 2. Two hundred shuffle advances. The order was built once and never
    ///    rebuilt, so a host that outlived the click kept the old list.
    /// 3. The first pick failing to compile. Widened to the whole library.
    /// 4. A rotation whose saved entries have all gone stale. Widened.
    /// 5. A roster that has fallen behind. Anything missing from it auto-joined.
    /// 6. A preset renamed. Old key dropped, new key auto-joined.
    private func auroraAcceptance() {
        let banned = ["aurora", "aurora/Ember", "aurora/Quiet"].map(LerpRotationEntry.init(key:))
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        guard let scratch = UserDefaults(suiteName: Self.scratchSuite) else { return }
        defer { UserDefaults().removePersistentDomain(forName: Self.scratchSuite) }

        // A view over the repo's own shaders, so this is the user's library and
        // `aurora` is the real one, first alphabetically as it always was.
        guard let view = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                                       extraSearchURLs: RepoLocation.searchURLs) else { return }
        let all = view.shaderLibrary.discover().rotationEntries()
        guard banned.allSatisfy(all.contains) else {
            return check("aurora's three looks are on disk to be switched off", false,
                         "\(all.filter { $0.shader == "aurora" }.count) found")
        }
        let kept = Set(all).subtracting(banned)

        /// Every look the view chose over `advances` steps, starting from a
        /// fresh pick. Asserting on the chosen entry is the whole point.
        func chosen(_ configure: (inout LerpMetalView.Config) -> Void,
                    advances: Int = 200) -> Set<LerpRotationEntry> {
            var config = LerpMetalView.Config(shuffleInterval: 3600)
            configure(&config)
            view.config = config
            view.stop()
            view.advanceShuffle(by: 0)
            var seen: Set<LerpRotationEntry> = []
            if let entry = view.currentEntry { seen.insert(entry) }
            for _ in 0..<advances {
                view.advanceShuffle(by: 1)
                if let entry = view.currentEntry { seen.insert(entry) }
            }
            return seen
        }

        func assertNoAurora(_ what: String, _ seen: Set<LerpRotationEntry>,
                            expectMovement: Bool = true) {
            let escaped = seen.filter { $0.shader == "aurora" }
            check("no aurora look is ever chosen — \(what)", escaped.isEmpty,
                  escaped.map(\.key).sorted().joined(separator: ", "))
            if expectMovement {
                check("…and \(what) did play looks that are in the rotation",
                      !seen.isEmpty && seen.isSubset(of: kept), "\(seen.count) distinct looks")
            }
        }

        // 1 & 2 — the rotation as the saver reads it, from a real ByHost-shaped
        // domain, over 200 advances.
        RotationStore.save(kept, entries: all, to: scratch)
        let saved = RotationStore.load(discovered: all, from: scratch)
        check("the saved rotation resolves without aurora",
              saved?.isDisjoint(with: banned) == true && saved?.count == kept.count,
              "\(saved?.count ?? -1) of \(all.count)")
        assertNoAurora("initial pick and 200 advances", chosen { $0.enabledEntries = saved })

        // 3 — the first pick will not compile. A broken file shadowing a real
        // shader by stem, so the rotation resolves and then fails to build.
        let victim = all.first { $0.shader != "aurora" && $0.preset == nil }?.shader ?? "spiral"
        if let broken = writeShaders([victim: "not Metal, and never was"]) {
            defer { try? FileManager.default.removeItem(at: broken) }
            if let shadowed = LerpMetalView(frame: NSRect(x: 0, y: 0, width: 64, height: 64),
                                            extraSearchURLs: [broken] + RepoLocation.searchURLs) {
                var config = LerpMetalView.Config(shuffleInterval: 3600)
                // Only the broken shader's looks are enabled, so the *only*
                // thing that can compile is something the user switched off.
                config.enabledEntries = Set(all.filter { $0.shader == victim })
                shadowed.config = config
                shadowed.start()
                check("a rotation that resolves but will not compile plays nothing, "
                      + "not the looks that were switched off",
                      shadowed.currentEntry == nil,
                      shadowed.currentEntry?.key ?? "nothing")
                check("…and it is not aurora that turns up",
                      shadowed.currentShaderName != "aurora", shadowed.currentShaderName)
                shadowed.stop()
            }
        }

        // 4 — every saved entry has gone stale, and the roster went with them.
        // The full rotation does come back, and it must come back because these
        // looks are *new to the roster*, not because something widened.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        scratch.set(["gone/One"], forKey: RotationStore.enabledEntriesKey)
        scratch.set(["gone/One"], forKey: RotationStore.knownEntriesKey)
        check("an entirely stale rotation lights every look up, aurora included, "
              + "because nobody has said no to any of them",
              RotationStore.rotation(discovered: all, from: scratch).count == all.count)

        // 5 — a roster that has fallen behind while aurora is explicitly off.
        // This is the one the old scheme could not express: `aurora` absent from
        // `knownEntries` used to mean "new", and new means in.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        RotationStore.save(kept, entries: all, to: scratch)
        let short = all.filter { $0.shader != "aurora" }
        scratch.set(short.map(\.key), forKey: RotationStore.knownEntriesKey)
        scratch.set(kept.map(\.key).sorted(), forKey: RotationStore.enabledEntriesKey)
        let behind = RotationStore.load(discovered: all, from: scratch) ?? []
        check("a roster that has fallen behind does not re-add a look the user switched off",
              behind.isDisjoint(with: banned),
              behind.filter { $0.shader == "aurora" }.map(\.key).joined(separator: ", "))
        assertNoAurora("a stale roster", chosen { $0.enabledEntries = behind })

        // 6 — aurora's presets renamed. Same shader, same positions, new
        // spellings: the decision has to travel with them.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        RotationStore.save(kept, entries: all, to: scratch)
        let renamed = all.map { entry -> LerpRotationEntry in
            guard entry.shader == "aurora", let preset = entry.preset else { return entry }
            return LerpRotationEntry(shader: "aurora", preset: preset + " II")
        }
        let afterRename = RotationStore.load(discovered: renamed, from: scratch) ?? []
        check("renaming aurora's presets does not put aurora back in the rotation",
              afterRename.allSatisfy { $0.shader != "aurora" },
              afterRename.filter { $0.shader == "aurora" }.map(\.key).joined(separator: ", "))
        assertNoAurora("aurora's presets renamed",
                       chosen { $0.enabledEntries = afterRename })

        // …and the mirror image, so this is not just "aurora never plays": with
        // aurora back in, it does.
        RotationStore.allKeys.forEach(scratch.removeObject(forKey:))
        let withAurora = chosen { $0.enabledEntries = Set(all) }
        check("with aurora selected it does play, so the checks above mean something",
              withAurora.contains { $0.shader == "aurora" },
              "\(withAurora.count) distinct looks and no aurora among them")
        view.stop()
    }

    // MARK: Renaming a preset

    /// Renaming a preset used to do two bad things at once: the old key went
    /// stale and fell out of `enabledEntries`, and the new key was in nobody's
    /// roster so it counted as newly discovered and joined the rotation. Net
    /// effect, a look the user had deliberately switched off came back on
    /// because somebody edited a comment. It has destroyed a real selection
    /// twice.
    private func renameUnits() {
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        guard let scratch = UserDefaults(suiteName: Self.scratchSuite) else { return }
        defer { UserDefaults().removePersistentDomain(forName: Self.scratchSuite) }

        func entries(_ presets: [String]) -> [LerpRotationEntry] {
            [LerpRotationEntry(shader: "zz-rename")]
                + presets.map { LerpRotationEntry(shader: "zz-rename", preset: $0) }
        }
        let before = entries(["Default", "SineWave", "Bugs"])
        let off = LerpRotationEntry(shader: "zz-rename", preset: "SineWave")
        RotationStore.save(Set(before).subtracting([off]), entries: before, to: scratch)
        check("the look starts out switched off",
              RotationStore.load(discovered: before, from: scratch)?.contains(off) == false)

        // The rename itself: same position in the file, new spelling.
        let after = entries(["Default", "Sine Wave", "Bugs"])
        let renamed = LerpRotationEntry(shader: "zz-rename", preset: "Sine Wave")
        let reloaded = RotationStore.load(discovered: after, from: scratch) ?? []
        check("renaming a preset does not switch a deselected look back on",
              !reloaded.contains(renamed),
              reloaded.map(\.key).sorted().joined(separator: " "))
        check("…and leaves every other look of that shader alone",
              reloaded == Set(after).subtracting([renamed]),
              "\(reloaded.count) of \(after.count) enabled")

        // The behaviour that must survive: a genuinely new preset still joins.
        let added = entries(["Default", "Sine Wave", "Bugs", "Fresh"])
        let fresh = LerpRotationEntry(shader: "zz-rename", preset: "Fresh")
        check("a genuinely new preset still joins the rotation on its own",
              RotationStore.load(discovered: added, from: scratch)?.contains(fresh) == true)

        // …and so does a genuinely new shader.
        let newShader = added + [LerpRotationEntry(shader: "zz-brand-new")]
        check("a genuinely new shader still joins the rotation on its own",
              RotationStore.load(discovered: newShader, from: scratch)?
                  .contains(LerpRotationEntry(shader: "zz-brand-new")) == true)

        // A rename and an addition in the same edit: the rename is still a
        // rename, and the addition is still an addition.
        let both = entries(["Default", "Sine Wave", "Beetles", "Fresh"])
        let bugsOff = entries(["Default", "SineWave", "Bugs"])
        RotationStore.save(Set(bugsOff).subtracting([LerpRotationEntry(shader: "zz-rename", preset: "Bugs")]),
                           entries: bugsOff,
                           base: RotationStore.state(discovered: bugsOff, from: scratch),
                           to: scratch)
        let mixed = RotationStore.load(discovered: both, from: scratch) ?? []
        check("a rename beside an addition keeps the rename off and lets the addition in",
              !mixed.contains(LerpRotationEntry(shader: "zz-rename", preset: "Beetles"))
                  && mixed.contains(LerpRotationEntry(shader: "zz-rename", preset: "Fresh")),
              mixed.map(\.key).sorted().joined(separator: " "))

        // The pairing rule itself, stated once so a future edit to it has
        // something to fail against.
        check("a name in both lists is itself, not a rename",
              LerpRotation.renamePairs(from: ["A", "B"], to: ["A", "B"]).isEmpty)
        check("a preset only removed is not a rename of nothing",
              LerpRotation.renamePairs(from: ["A", "B"], to: ["A"]).isEmpty)
        check("a preset only added is not a rename of nothing",
              LerpRotation.renamePairs(from: ["A"], to: ["A", "B"]).isEmpty)
        check("a rename at the same position is paired",
              LerpRotation.renamePairs(from: ["A", "B"], to: ["A", "Bee"])
                  .map { $0.old + "->" + $0.new } == ["B->Bee"])
    }

    // MARK: Two writers

    /// The saver's Options… sheet and the playground's gallery write the same
    /// ByHost domain, and neither used to know the other existed. A sheet opened
    /// before a click in the playground would, on OK, write back the selection
    /// it had read minutes earlier and quietly undo it — with nothing in the
    /// stored state to say which write was newer.
    private func staleWriterUnits() {
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        guard let scratch = UserDefaults(suiteName: Self.scratchSuite) else { return }
        defer { UserDefaults().removePersistentDomain(forName: Self.scratchSuite) }

        let all = rotationEntriesNow()
        guard all.count > 6 else { return }
        let mine = all[1], theirs = all[2]

        RotationStore.save(Set(all), entries: all, to: scratch)
        let base = RotationStore.state(discovered: all, from: scratch)
        check("a write is stamped with a revision and a writer",
              base.revision > 0 && !base.writer.isEmpty, base.summary)

        // Somebody else switches `theirs` off while this caller holds `base`.
        RotationStore.save(Set(all).subtracting([theirs]), entries: all, base: base, to: scratch)
        let newer = RotationStore.state(discovered: all, from: scratch)
        check("the second write moved the revision on", newer.revision > base.revision,
              "\(base.revision) → \(newer.revision)")

        // Now the stale caller saves what it read, minus one look of its own.
        RotationStore.save(Set(all).subtracting([mine]), entries: all, base: base, to: scratch)
        let merged = RotationStore.load(discovered: all, from: scratch) ?? []
        check("a stale writer's own change still lands", !merged.contains(mine), mine.key)
        check("a stale writer cannot undo a newer click it never saw",
              !merged.contains(theirs), theirs.key)
        check("…and touches nothing else", merged == Set(all).subtracting([mine, theirs]),
              "\(merged.count) of \(all.count) enabled")

        // An up-to-date writer is not merged against anything: it says what the
        // rotation is, in full.
        let fresh = RotationStore.state(discovered: all, from: scratch)
        RotationStore.save(Set(all), entries: all, base: fresh, to: scratch)
        check("an up-to-date writer replaces the selection outright",
              RotationStore.load(discovered: all, from: scratch) == Set(all))

        // An older build writes only the v1 keys. The v2 record must notice and
        // step aside rather than silently outranking it forever.
        scratch.set(all.dropLast(3).map(\.key), forKey: RotationStore.enabledEntriesKey)
        scratch.set(all.map(\.key), forKey: RotationStore.knownEntriesKey)
        check("a write by an older build that only knows the v1 keys still wins",
              RotationStore.load(discovered: all, from: scratch) == Set(all.dropLast(3)),
              "\(RotationStore.load(discovered: all, from: scratch)?.count ?? -1) of \(all.count)")
    }

    private var coldSeconds = 0.0
    private var galleryEntries: [LerpRotationEntry] = []

    /// The gallery itself, pointed at a ByHost domain of the test's own.
    ///
    /// The claim under test is "a click lands in a ByHost screensaver domain,
    /// through the very call `LerpSaverView` makes, under the keys it reads" —
    /// and every part of that is true of `testModule`. What is *not* worth
    /// testing is the last mile of the string: pointing this at the user's live
    /// rotation buys one constant's worth of confidence and risks their
    /// settings. The production wiring is checked below without writing a thing:
    /// the app's own default is built from `RotationStore.module`.
    private func rotationGalleryChecks() {
        controller.rotationDefaults = RotationStore.saverDefaults(module: Self.testModule)
        check("the gallery writes a ByHost screensaver domain, not the app's own preferences",
              controller.rotationDefaults.map { $0 is ScreenSaverDefaults } == true
                  && RotationStore.module == "com.hergenroeder.lerping"
                  && RotationStore.module != Bundle.main.bundleIdentifier
                  && !RotationStore.isLiveModule(Self.testModule),
              controller.rotationDefaults.map { String(describing: type(of: $0)) } ?? "nil"
                  + " for " + Self.testModule)

        // Start from a known rotation rather than from whatever was there.
        galleryEntries = rotationEntriesNow()
        RotationStore.save(Set(galleryEntries), entries: galleryEntries,
                           to: controller.rotationDefaults)

        // A cold cache, so the render path is exercised on every run and the
        // warm check below has something to be warmer than.
        let gallery = controller.rotationGallery()
        gallery.window?.setContentSize(NSSize(width: 1200, height: 940))
        gallery.evictThumbnails()
        let started = CFAbsoluteTimeGetCurrent()
        gallery.onLoaded = { [self] in
            coldSeconds = CFAbsoluteTimeGetCurrent() - started
            galleryLoaded()
        }
        gallery.show()
        gallery.reload(shaders: controller.metalView.shaderLibrary.discover())
        // Belt and braces: the watchdog would catch a stall, but a run that
        // never renders should say so as a check rather than as a timeout.
        wait(until: { [self] in coldSeconds > 0 }, timeout: 60) { [self] in
            if coldSeconds == 0 {
                check("every rotation still rendered", false, "gallery never finished loading")
                finish()
            }
        }
    }

    private func galleryLoaded() {
        guard let controllerWindow = controller.rotation else { return finish() }
        let gallery = controllerWindow.gallery
        let stats = controllerWindow.thumbnailStats
        check("the gallery has one tile per rotation entry",
              gallery.tileEntries.count == galleryEntries.count
                  && Set(gallery.tileEntries) == Set(galleryEntries),
              "\(gallery.tileEntries.count) tiles for \(galleryEntries.count) looks")
        check("every tile got a still", stats.rendered + stats.disk + stats.memory == galleryEntries.count
                  && stats.failed.isEmpty,
              stats.failed.isEmpty
                ? String(format: "%d rendered, %d off disk, in %.2f s", stats.rendered, stats.disk, coldSeconds)
                : stats.failed.prefix(3).joined(separator: " / "))
        check("the tiles are portrait, so a look reads as a look",
              RotationTile.size.height > RotationTile.size.width,
              "\(Int(RotationTile.size.width))×\(Int(RotationTile.size.height))")
        check("every tile actually holds an image",
              gallery.tileEntries.allSatisfy { gallery.tile(for: $0)?.image != nil },
              "\(gallery.tileEntries.filter { gallery.tile(for: $0)?.image == nil }.count) blank")
        print(String(format: "     cold gallery: %d stills in %.2f s (%d rendered, %d cached)",
                     galleryEntries.count, coldSeconds, stats.rendered, stats.disk))

        toggleChecks(gallery)
        groupChecks(gallery)
        filterChecks(gallery)
        captureRotationUI()
        warmCacheCheck()
    }

    /// What is on disk in the test's ByHost domain right now, read straight out
    /// of cfprefsd rather than through any `UserDefaults` this process holds —
    /// so a value that only ever reached an in-memory cache cannot pass.
    private func persistedRotation() -> [String] {
        (CFPreferencesCopyValue(RotationStore.enabledEntriesKey as CFString,
                                Self.testModule as CFString,
                                kCFPreferencesCurrentUser,
                                kCFPreferencesCurrentHost) as? [String]) ?? []
    }

    private func toggleChecks(_ gallery: RotationGalleryView) {
        guard let victim = galleryEntries.first(where: { $0.preset != nil }) ?? galleryEntries.first
        else { return }
        gallery.click(victim)
        check("clicking a tile takes its look out of the rotation",
              gallery.tile(for: victim)?.isOn == false && !gallery.enabled.contains(victim))
        // Through cfprefsd, in the screensaver's domain, under the screensaver's key.
        let persisted = persistedRotation()
        check("the click reached the screensaver's own ByHost defaults",
              !persisted.contains(victim.key) && persisted.count == galleryEntries.count - 1,
              "\(persisted.count) of \(galleryEntries.count) keys, \(victim.key) removed")
        // …and the screensaver's own resolution of them agrees.
        check("the saver's rotation policy resolves the change",
              !RotationStore.rotation(discovered: galleryEntries,
                                      from: controller.rotationDefaults).contains(victim))

        gallery.click(victim)
        check("clicking it again puts it back",
              gallery.tile(for: victim)?.isOn == true
                  && persistedRotation().contains(victim.key),
              victim.key)
    }

    private func groupChecks(_ gallery: RotationGalleryView) {
        // A shader with more than one look, so "the heading owns the group"
        // means something.
        guard let name = Dictionary(grouping: galleryEntries, by: \.shader)
            .first(where: { $0.value.count > 1 })?.key else { return }
        let group = galleryEntries.filter { $0.shader == name }
        check("a shader heading exists for every shader",
              gallery.header(for: name) != nil, name)

        gallery.clickHeader(name)
        check("a heading takes its whole group out at once",
              group.allSatisfy { !gallery.enabled.contains($0) }
                  && group.allSatisfy { !persistedRotation().contains($0.key) },
              "\(group.count) looks of \(name)")
        check("the heading shows the group is empty",
              gallery.header(for: name)?.state == .off)

        // One back in makes it partial, not on.
        gallery.click(group[0])
        check("a heading goes mixed when part of its group is in",
              gallery.header(for: name)?.state == .mixed,
              "\(gallery.header(for: name)?.state.rawValue ?? -99)")

        gallery.clickHeader(name)
        check("a heading puts its whole group back",
              group.allSatisfy(gallery.enabled.contains)
                  && gallery.header(for: name)?.state == .on
                  && group.allSatisfy { persistedRotation().contains($0.key) })
    }

    private func filterChecks(_ gallery: RotationGalleryView) {
        guard let name = galleryEntries.first?.shader else { return }
        gallery.setFilter(name)
        let expected = galleryEntries.filter {
            ($0.shader + " " + ($0.preset ?? "defaults")).range(of: name, options: .caseInsensitive) != nil
        }
        check("the filter narrows the grid to what matches",
              gallery.visibleTileCount == expected.count && gallery.visibleTileCount < galleryEntries.count,
              "\(gallery.visibleTileCount) shown for “\(name)”, expected \(expected.count)")
        check("the status line says what the filter is doing",
              gallery.noteText.contains("\(expected.count) shown"), gallery.noteText)

        // Select All with a filter up acts on what is on screen, which is the
        // only reading of the button that is not a trap.
        gallery.setFilter(name)
        gallery.clickDeselectAll()
        check("Deselect All with a filter up only clears what is shown",
              expected.allSatisfy { !gallery.enabled.contains($0) }
                  && gallery.enabled.count == galleryEntries.count - expected.count,
              "\(gallery.enabled.count) still in")
        gallery.clickSelectAll()
        check("Select All puts them back",
              gallery.enabled.count == galleryEntries.count)

        gallery.setFilter("")
        check("clearing the filter shows every look again",
              gallery.visibleTileCount == galleryEntries.count,
              "\(gallery.visibleTileCount)")

        // The one thing that must never happen, through the UI this time — and
        // it is now refused rather than inverted.
        gallery.clickDeselectAll()
        check("Deselect All with no filter refuses, and says why",
              gallery.enabled.count == galleryEntries.count
                  && persistedRotation().count == galleryEntries.count
                  && gallery.noteText.contains("at least one look"),
              gallery.noteText)
        gallery.clickSelectAll()
        galleryFloorChecks(gallery)
    }

    /// The floor: the rotation can be taken down to one look and no further.
    ///
    /// This is the single place the "never empty" invariant is kept, and
    /// everything that used to keep it downstream — an empty selection meaning
    /// all of them, a stale selection meaning all of them, a rotation that would
    /// not compile meaning all of them — has been deleted in favour of it. So it
    /// has to hold through the controls a user actually touches.
    private func galleryFloorChecks(_ gallery: RotationGalleryView) {
        guard let survivor = galleryEntries.first, galleryEntries.count > 3 else { return }
        let group = galleryEntries.filter { $0.shader == survivor.shader }

        // Down to one shader's group, so the group *is* the whole rotation and
        // its heading is now an emptying control rather than an adding one.
        for entry in galleryEntries where entry.shader != survivor.shader
            && gallery.enabled.contains(entry) { gallery.click(entry) }
        check("the rotation can be taken down to a single shader",
              gallery.enabled == Set(group), "\(gallery.enabled.count) left")
        gallery.clickHeader(survivor.shader)
        check("a shader heading that owns the whole rotation cannot empty it",
              gallery.enabled == Set(group), "\(gallery.enabled.count) left")

        // …and down to one look.
        for entry in group where entry != survivor { gallery.click(entry) }
        check("the rotation can be taken all the way down to one look",
              gallery.enabled == [survivor], "\(gallery.enabled.count) left")

        // …and no further, by any route.
        gallery.click(survivor)
        check("clicking the last look does not take it out",
              gallery.enabled == [survivor], "\(gallery.enabled.count) left")
        check("the last tile says it cannot be pressed",
              gallery.tile(for: survivor)?.isLocked == true
                  && gallery.tile(for: survivor)?.isToggleable == false
                  && gallery.tile(for: survivor)?.isAccessibilityEnabled() == false)
        check("…and it refuses the press rather than pretending to take it",
              gallery.tile(for: survivor)?.accessibilityPerformPress() == false)
        gallery.clickDeselectAll()
        check("Deselect All cannot empty it either",
              gallery.enabled == [survivor], "\(gallery.enabled.count) left")
        check("the refusal is said out loud, not just beeped",
              gallery.noteText.contains("at least one look"), gallery.noteText)

        // What reached the screensaver's own defaults is one look, and the
        // rotation it resolves to is that one look — not the whole library.
        check("one look is what landed in the ByHost domain",
              persistedRotation() == [survivor.key],
              persistedRotation().sorted().joined(separator: " "))
        check("…and one look is what the screensaver would shuffle through",
              RotationStore.rotation(discovered: galleryEntries,
                                     from: controller.rotationDefaults) == [survivor],
              "\(RotationStore.rotation(discovered: galleryEntries, from: controller.rotationDefaults).count)")

        gallery.clickSelectAll()
        check("Select All puts the whole rotation back",
              gallery.enabled.count == galleryEntries.count)
    }

    /// The second load: a brand-new cache with nothing in memory, over the same
    /// directory on disk. Every still must come off the disk and none may be
    /// rendered again — that is what "cached" has to mean.
    private func warmCacheCheck() {
        guard let window = controller.rotation else { return finish() }
        let shaders = controller.metalView.shaderLibrary.discover()
        let byName = Dictionary(uniqueKeysWithValues: shaders.map { ($0.name, $0) })
        let jobs = galleryEntries.compactMap { entry in
            byName[entry.shader].map { RotationThumbnails.Job(entry: entry, shader: $0) }
        }
        let fresh = RotationThumbnails(searchURLs: ShaderLocations.repoSearchURLs(),
                                       directory: window.cacheDirectory)
        let started = CFAbsoluteTimeGetCurrent()
        var landed = 0
        fresh.start(jobs, onImage: { _, _ in landed += 1 }, onProgress: { _, _ in }) { [self] in
            let warm = CFAbsoluteTimeGetCurrent() - started
            check("a second load resolves every still from the disk cache",
                  fresh.diskHits == jobs.count && fresh.rendered == 0 && landed == jobs.count,
                  "\(fresh.diskHits) off disk, \(fresh.rendered) re-rendered")
            check("the warm load is far cheaper than the cold one", warm < coldSeconds,
                  String(format: "cold %.2f s, warm %.2f s", coldSeconds, warm))
            print(String(format: "     warm gallery: %d stills in %.2f s (all from %@)",
                         jobs.count, warm, window.cacheDirectory.path))
            editedShaderCheck(fresh)
        }
    }

    /// Editing a shader has to invalidate that shader's stills and *only* that
    /// shader's — the whole reason the cache key carries a source hash.
    private func editedShaderCheck(_ cache: RotationThumbnails) {
        let shaders = controller.metalView.shaderLibrary.discover()
        guard let edited = shaders.first(where: { !$0.presets.isEmpty }) else { return finish() }
        let others = shaders.filter { $0.name != edited.name }
        let before = cache.key(entry: LerpRotationEntry(shader: edited.name), source: edited.source)
        let after = cache.key(entry: LerpRotationEntry(shader: edited.name),
                              source: edited.source + "\n// touched by the self-test\n")
        check("editing a shader invalidates its own stills", before != after, edited.name)
        check("…and no other shader's", others.allSatisfy { other in
            cache.key(entry: LerpRotationEntry(shader: other.name), source: other.source)
                == cache.key(entry: LerpRotationEntry(shader: other.name), source: other.source)
        })
        check("a preset's still is keyed apart from its shader's defaults",
              edited.presets.allSatisfy { preset in
                  cache.key(entry: LerpRotationEntry(shader: edited.name, preset: preset.name),
                            source: edited.source) != before
              }, edited.name)
        check("the cache lives outside the repo, under ~/Library/Caches",
              cache.cacheDirectory.path.contains("/Library/Caches/")
                  && !cache.cacheDirectory.path.contains(FileManager.default.currentDirectoryPath),
              cache.cacheDirectory.path)
        check("the still hash is stable across processes, not per-launch",
              RotationThumbnails.hash("lerping") == "4d064d192fb42960",
              RotationThumbnails.hash("lerping"))
        handOffRotation()
        finish()
    }

    /// True when the run was asked to *leave* the rotation it clicked behind
    /// instead of wiping the test domain. Off by default and off in
    /// `make playground-test`; it exists so the round trip can be finished
    /// outside this process — click here, then load the real `.saver` bundle in
    /// another one, point it at the same domain, and see what its own Options
    /// sheet comes up checked.
    ///
    ///     LERP_SELFTEST_KEEP_ROTATION=1 build/LerpPlaygroundSelfTest.app/…/LerpPlaygroundSelfTest --selftest
    ///     LERP_DEFAULTS_MODULE=com.hergenroeder.lerping.uitest \
    ///         LOADTEST_DUMP_ROTATION=1 build/loadtest build/Lerping@Home.saver
    ///
    /// It used to hand off through the *user's* live domain, which made the
    /// round trip real at the price of leaving a stranger's rotation in someone's
    /// screensaver whenever a run was interrupted. Both ends take a module now,
    /// so the round trip is just as real and lands nowhere near it.
    private var keepsRotation: Bool {
        ProcessInfo.processInfo.environment["LERP_SELFTEST_KEEP_ROTATION"] != nil
    }

    /// Clicks the gallery down to a small, distinctive rotation and leaves it in
    /// the test's ByHost domain for another process to read.
    private func handOffRotation() {
        guard keepsRotation, let gallery = controller.rotation?.gallery else { return }
        gallery.setFilter("")
        gallery.clickDeselectAll()
        // Deselect-all is saved as *all*, by design; clicking three back on is
        // what makes the rotation a set someone chose.
        let picked = Array(galleryEntries.filter { $0.preset != nil }.prefix(3))
        picked.forEach(gallery.click)
        print("HANDOFF wrote \(picked.count) looks to \(Self.testModule) (ByHost):")
        persistedRotation().sorted().forEach { print("HANDOFF   \($0)") }
    }

    /// The gallery, drawn into a PNG so its layout and its on/off states can be
    /// looked at rather than only counted. Half the tiles are switched off first,
    /// because "off is unmistakable" is a claim about a picture.
    private func captureRotationUI() {
        guard let gallery = controller.rotation?.gallery,
              let window = controller.rotation?.window else { return }
        for (index, entry) in galleryEntries.enumerated() where index % 2 == 1 {
            gallery.click(entry)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: "build/rotation-gallery.png")
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                print("     wrote \(url.path)")
            }
        }
        gallery.clickSelectAll()
    }

    // MARK: Being an app

    /// The menu bar is built in code rather than loaded from a nib, so nothing
    /// but this notices when a standard item loses its selector or its key. It
    /// is also the only place the bundle's name reaches the user directly.
    private func appCitizenshipChecks() {
        guard let appMenu = MainMenu.build().items.first?.submenu else {
            return check("there is an application menu", false)
        }
        func item(_ action: Selector) -> NSMenuItem? { appMenu.items.first { $0.action == action } }

        check("the application menu is named after the bundle",
              appMenu.title == PlaygroundMain.name
                  && PlaygroundMain.name == Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
              appMenu.title)
        check("it has the standard About item",
              item(#selector(NSApplication.orderFrontStandardAboutPanel(_:)))?.title
                  == "About \(PlaygroundMain.name)")
        let quit = item(#selector(NSApplication.terminate(_:)))
        check("⌘Q quits", quit?.keyEquivalent == "q" && quit?.keyEquivalentModifierMask == .command,
              quit?.title ?? "no Quit item")
        // One window is the whole app, so there is no state in which it is
        // running with nothing on screen for a later launch to be confused by.
        check("closing the window quits",
              PlaygroundAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))

        // The gallery is reachable from the menu bar, and — because it opens a
        // window of its own, from which the editor's controller is not in the
        // responder chain — from the app delegate too, or the item would grey
        // out exactly when the gallery is in front.
        let shaderMenu = MainMenu.build().items.first { $0.title == "Shader" }?.submenu
        let open = shaderMenu?.items.first {
            $0.action == #selector(PlaygroundWindowController.showRotationGallery(_:))
        }
        check("the menu bar can open the rotation gallery",
              open?.title == "Screensaver Rotation…" && open?.keyEquivalent == "r"
                  && open?.keyEquivalentModifierMask == [.command, .option],
              open?.title ?? "no such item")
        check("both the window controller and the app delegate answer it",
              controller.responds(to: #selector(PlaygroundWindowController.showRotationGallery(_:)))
                  && PlaygroundAppDelegate().responds(
                        to: #selector(PlaygroundAppDelegate.showRotationGallery(_:))))
    }

    // MARK: The time scrubber

    /// The scrubber spans a window of the timeline rather than a fixed [0,180],
    /// because these shaders never repeat and so have no end to scale to. The
    /// regression this protects is the one that made it worth rebuilding: past
    /// the window's edge the thumb used to pin and the readout used to lie.
    private func transportChecks() {
        let controller = self.controller!
        let span = controller.windowSpan
        check("the scrubber spans a window, not the whole timeline", span > 0 && span <= 1800,
              "\(span) s")

        // The view's clock is live wall time, so it moves between the seek and
        // the read. A quarter of a second is far tighter than the failure being
        // guarded against, which parks the thumb 220 s from the truth.
        func at(_ seconds: Double, _ reading: Double) -> Bool { abs(reading - seconds) < 0.25 }

        controller.seek(to: 12)
        check("the window contains the clock near the start",
              controller.windowStart == 0
                  && controller.scrubberBounds == 0 ... span
                  && at(12, controller.scrubberPosition),
              "\(controller.scrubberBounds) thumb \(controller.scrubberPosition)")

        // Far past the old hard-coded maximum: the case that was broken.
        controller.seek(to: 400)
        check("the window advances when the clock passes its edge",
              controller.windowStart == (400 / span).rounded(.down) * span
                  && controller.scrubberBounds.lowerBound <= 400
                  && controller.scrubberBounds.upperBound >= 400,
              "window \(controller.scrubberBounds)")
        check("the thumb tracks true time past the window edge",
              at(400, controller.scrubberPosition), "\(controller.scrubberPosition)")
        check("the readout shows absolute time, not the window's edge",
              at(400, PlaygroundWindowController.seconds(fromClock: controller.clockText) ?? -1),
              controller.clockText)

        // …and much further out, where the old slider had nothing left to say.
        controller.seek(to: 9000)
        check("an hour and a half in, the readout is still true",
              at(9000, PlaygroundWindowController.seconds(fromClock: controller.clockText) ?? -1)
                  && at(9000, controller.scrubberPosition),
              "\(controller.clockText) / thumb \(controller.scrubberPosition)")
        check("drag precision does not decay with elapsed time",
              controller.scrubberBounds.upperBound - controller.scrubberBounds.lowerBound == span,
              "still \(span) s across the scrubber at t=9000")

        // Navigating back to an early moment after running long.
        controller.seek(to: 12)
        check("you can go back and inspect an early moment",
              controller.windowStart == 0 && at(12, controller.scrubberPosition),
              "\(controller.scrubberBounds) thumb \(controller.scrubberPosition)")

        check("typed times parse in every form a person writes them",
              PlaygroundWindowController.seconds(fromClock: "90") == 90
                  && PlaygroundWindowController.seconds(fromClock: "90.5") == 90.5
                  && PlaygroundWindowController.seconds(fromClock: "1:30") == 90
                  && PlaygroundWindowController.seconds(fromClock: "1:30.5") == 90.5
                  && PlaygroundWindowController.seconds(fromClock: "nope") == nil)
        check("the clock formats past an hour without wrapping",
              PlaygroundWindowController.clock(9000) == "150:00"
                  && PlaygroundWindowController.clock(12.5, decimals: 1) == "0:12.5",
              PlaygroundWindowController.clock(9000))

        controller.seek(to: 0)
        check("the window never runs off the front of the timeline",
              controller.windowStart == 0, "\(controller.windowStart)")
    }

    /// The two things every MIDI integration gets wrong, checked as pure logic
    /// because no controller sends all three encodings.
    private func routerUnits() {
        check("two's complement encoder decodes both directions",
              MIDIRelativeEncoding.twosComplement.delta(1) == 1
                  && MIDIRelativeEncoding.twosComplement.delta(127) == -1
                  && MIDIRelativeEncoding.twosComplement.delta(0) == 0)
        check("binary offset encoder decodes both directions",
              MIDIRelativeEncoding.binaryOffset.delta(65) == 1
                  && MIDIRelativeEncoding.binaryOffset.delta(63) == -1
                  && MIDIRelativeEncoding.binaryOffset.delta(64) == 0)
        check("sign/magnitude encoder decodes both directions",
              MIDIRelativeEncoding.signMagnitude.delta(3) == 3
                  && MIDIRelativeEncoding.signMagnitude.delta(0x43) == -3)

        // 14-bit CC is two messages — MSB on n, LSB on n + 32 — and the library
        // hands them over separately. This is the coalescing.
        let router = MIDIRouter()
        router.load([MIDIBinding(paramID: "p", channel: nil, cc: 7, mode: .abs14(lsbCC: 39))])
        let msb = position(router.route(channel: 0, cc: 7, value: 64))
        let lsb = position(router.route(channel: 0, cc: 39, value: 100))
        check("14-bit MSB alone sweeps the range", abs((msb ?? -1) - 8192.0 / 16383) < 1e-9,
              "\(msb ?? -1)")
        check("14-bit LSB refines the value it follows",
              abs((lsb ?? -1) - 8292.0 / 16383) < 1e-9, "\(lsb ?? -1)")
        check("an omni binding matches any channel",
              position(router.route(channel: 9, cc: 7, value: 127)) != nil)
        check("an unmapped CC routes to nothing",
              router.route(channel: 0, cc: 8, value: 64) == nil)

        router.load([MIDIBinding(paramID: "p", channel: 3, cc: 1, mode: .toggle)])
        check("a toggle fires on press and ignores release",
              router.route(channel: 3, cc: 1, value: 127) != nil
                  && router.route(channel: 3, cc: 1, value: 0) == nil)
        check("a channel-specific binding ignores other channels",
              router.route(channel: 4, cc: 1, value: 127) == nil)
    }

    private func position(_ result: (binding: MIDIBinding, update: MIDIRouter.Update)?) -> Double? {
        if case .absolute(let value)? = result?.update { return value }
        return nil
    }

    // MARK: The colour projection, measured

    /// Every `color` default every installed shader declares. The claims below
    /// are about *this repo's palettes*, not about a colour someone picked to
    /// make the assertion pass.
    private func allShaderColors() -> [(String, SIMD4<Float>)] {
        controller.metalView.shaderLibrary.discover().flatMap { shader in
            shader.parameters.filter { $0.type == .color }.compactMap { param in
                param.defaultValue.colorValue.map { ("\(shader.name).\(param.name)", $0) }
            }
        }
    }

    /// The claim most likely to be wrong, checked numerically: a CC swept 0→127
    /// on `.hue` produces 128 colours that are all inside sRGB, all at the base
    /// colour's lightness, and spaced roughly evenly in perception.
    private func colorProjectionUnits() {
        let colors = allShaderColors()
        check("shaders declare colours to test the projection against", colors.count > 20,
              "\(colors.count) colour parameters")
        guard !colors.isEmpty else { return }

        var outOfGamut: [String] = []
        var lightnessDrift = 0.0, worstDriftName = ""
        var centreError = 0.0, worstCentreName = ""
        var liftedError = 0.0, worstLiftedName = ""
        var stepRatios: [Double] = []
        var deadKnobs: [String] = []

        for (name, base) in colors {
            let l0 = Oklch.lch(fromSRGB: rgb(base)).l
            var sweep: [SIMD4<Float>] = []
            for value in 0 ... 127 {
                let color = ColorProjection.apply(.hue, position: Double(value) / 127,
                                                  to: base, base: base)
                sweep.append(color)
                // Tolerance exactly 0: `maxChroma` returns a chroma it verified,
                // so "nearly in gamut" is not a thing that should happen here.
                if !Oklch.isInGamut(rgb(color), tolerance: 0) {
                    outOfGamut.append("\(name)@\(value) \(describe(color))")
                }
                let drift = abs(Oklch.lch(fromSRGB: rgb(color)).l - l0)
                if drift > lightnessDrift { lightnessDrift = drift; worstDriftName = name }
            }
            // Knob centre is the palette exactly as the author wrote it —
            // except on the near-greys, where the chroma floor deliberately
            // lifts it. Those are counted apart so the cost of the floor is a
            // number in the output rather than slack in a tolerance.
            let centre = ColorProjection.apply(.hue, position: 0.5, to: base, base: base)
            let error = Double((0..<3).map { abs(centre[$0] - base[$0]) }.max() ?? 0)
            if ColorProjection.isNearGrey(base) {
                if error > liftedError { liftedError = error; worstLiftedName = name }
            } else if error > centreError {
                centreError = error; worstCentreName = name
            }

            var steps: [Double] = []
            for i in 1 ..< sweep.count {
                let a = Oklch.lab(fromSRGB: rgb(sweep[i - 1])), b = Oklch.lab(fromSRGB: rgb(sweep[i]))
                let d = a - b
                steps.append((d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
            }
            if let hi = steps.max(), let lo = steps.min(), lo > 1e-9 { stepRatios.append(hi / lo) }
            // The near-grey rule: a knob is never allowed to sit there doing
            // nothing. Even pure black has to move, or Learn has to have sent
            // the user to a different axis.
            let spread = spanOfSweep(sweep)
            if spread < 0.004 && ColorProjection.defaultComponent(for: base) == .hue {
                deadKnobs.append(String(format: "%@ (spread %.5f)", name, spread))
            }
        }

        check("a 0→127 hue sweep is inside sRGB at every position, for every shader colour",
              outOfGamut.isEmpty,
              outOfGamut.isEmpty ? "\(colors.count) colours × 128 positions"
                                 : outOfGamut.prefix(3).joined(separator: ", "))
        check("a hue knob holds the colour's lightness", lightnessDrift < 1e-6,
              String(format: "worst drift %.2e on %@", lightnessDrift, worstDriftName))
        check("knob centre reproduces the shader author's colour exactly", centreError < 1e-6,
              String(format: "worst %.2e on %@ (%d colours)", centreError, worstCentreName,
                     colors.filter { !ColorProjection.isNearGrey($0.1) }.count))
        // The whole price of not letting a knob do nothing, in one number.
        check("the near-grey chroma floor costs almost nothing at centre", liftedError < 0.012,
              String(format: "worst %.4f on %@ (%d near-grey colours)", liftedError, worstLiftedName,
                     colors.filter { ColorProjection.isNearGrey($0.1) }.count))

        let sorted = stepRatios.sorted()
        let median = sorted[sorted.count / 2]
        check("perceptual step size is roughly even across the sweep", median < 3,
              String(format: "median max/min %.2f, p90 %.2f, worst %.2f",
                     median, sorted[Int(Double(sorted.count - 1) * 0.9)], sorted.last ?? 0))
        check("no hue knob is silently dead", deadKnobs.isEmpty,
              deadKnobs.isEmpty ? "chroma floor \(ColorProjection.hueChromaFloor) lifts the near-greys"
                                : deadKnobs.joined(separator: ", "))

        // The three colours a floor cannot rescue — pure black and pure white,
        // where the gamut at that lightness is a single point — have to be
        // sent to an axis that does have range.
        let degenerate = colors.filter { Oklch.safeChroma(lightness: Oklch.lch(fromSRGB: rgb($0.1)).l) <= 1e-6 }
        check("colours with no chroma available default to the lightness axis",
              degenerate.allSatisfy { ColorProjection.defaultComponent(for: $0.1) == .lightness },
              "\(degenerate.count) such colours: \(degenerate.map(\.0).joined(separator: ", "))")

        // The other three axes, on one colour, so the switch has no dead arm.
        let sample = colors.first { !ColorProjection.isNearGrey($0.1) }?.1 ?? SIMD4<Float>(0.4, 0.2, 0.7, 1)
        let dark = ColorProjection.apply(.lightness, position: 0.15, to: sample, base: sample)
        let light = ColorProjection.apply(.lightness, position: 0.85, to: sample, base: sample)
        check("the lightness axis spans dark to light",
              lightness(dark) < 0.2 && lightness(light) > 0.8
                  && Oklch.isInGamut(rgb(dark), tolerance: 0) && Oklch.isInGamut(rgb(light), tolerance: 0),
              String(format: "L %.3f → %.3f", lightness(dark), lightness(light)))
        let grey = ColorProjection.apply(.chroma, position: 0, to: sample, base: sample)
        let vivid = ColorProjection.apply(.chroma, position: 1, to: sample, base: sample)
        check("the chroma axis spans grey to the most saturated colour in gamut",
              Oklch.lch(fromSRGB: rgb(grey)).c < 1e-3
                  && Oklch.lch(fromSRGB: rgb(vivid)).c > Oklch.lch(fromSRGB: rgb(sample)).c
                  && Oklch.isInGamut(rgb(vivid), tolerance: 0),
              String(format: "C %.4f → %.4f", Oklch.lch(fromSRGB: rgb(grey)).c,
                     Oklch.lch(fromSRGB: rgb(vivid)).c))
        check("the alpha axis writes alpha and nothing else",
              ColorProjection.apply(.alpha, position: 0.25, to: sample, base: sample).w == 0.25
                  && abs(ColorProjection.apply(.alpha, position: 0.25, to: sample, base: sample).x
                         - sample.x) < 0.004)

        // Absolute knobs must be idempotent: the same CC twice is the same
        // colour, not a colour that has drifted twice as far.
        let once = ColorProjection.apply(.hue, position: 0.8, to: sample, base: sample)
        let twice = ColorProjection.apply(.hue, position: 0.8, to: once, base: sample)
        check("an absolute hue knob does not compound its own output",
              (0..<4).allSatisfy { abs(once[$0] - twice[$0]) < 0.004 },
              "\(describe(once)) vs \(describe(twice))")

        // And the inverse the relative encoders need has to agree with it.
        check("position(of:) inverts apply(_:position:)",
              abs(ColorProjection.position(of: .hue, in: once, base: sample) - 0.8) < 0.01,
              String(format: "%.4f", ColorProjection.position(of: .hue, in: once, base: sample)))
    }

    /// Largest gap between any two colours of a sweep, in Oklab.
    private func spanOfSweep(_ sweep: [SIMD4<Float>]) -> Double {
        let labs = sweep.map { Oklch.lab(fromSRGB: rgb($0)) }
        var widest = 0.0
        for a in labs {
            let d = a - labs[0]
            widest = max(widest, (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot())
        }
        return widest
    }

    // MARK: Persistence

    /// Mapping files written before colours were bindable have to keep loading,
    /// and the new field has to survive the trip.
    private func bindingPersistenceUnits() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()

        let colored = MIDIBinding(paramID: "colorBack", channel: 3, cc: 22,
                                  mode: .relative(.binaryOffset), range: 0.25 ... 0.75,
                                  component: .chroma)
        guard let data = try? encoder.encode(colored),
              let back = try? decoder.decode(MIDIBinding.self, from: data) else {
            return check("a colour binding round-trips through JSON", false, "encode failed")
        }
        check("a colour binding round-trips through JSON", back == colored,
              String(data: data, encoding: .utf8) ?? "")

        // A binding with no component encodes with no `component` key at all,
        // which is *exactly* the bytes an older build wrote. Proving that is
        // proving the old format still loads.
        let scalar = MIDIBinding(paramID: "swirl", channel: nil, cc: 7)
        let scalarJSON = (try? encoder.encode(scalar)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check("a scalar binding writes no colour field", !scalarJSON.contains("component"), scalarJSON)

        let legacy = Data(scalarJSON.utf8)
        let decoded = try? decoder.decode(MIDIBinding.self, from: legacy)
        check("old-format JSON with no component still decodes",
              decoded?.component == nil && decoded?.cc == 7 && decoded?.range == 0 ... 1,
              scalarJSON)

        // …and through the store, as a whole bank file on disk.
        let name = "zz-selftest-legacy"
        let legacyPreset = """
        {"bindings":[{"cc":9,"mode":{"abs7":{}},"paramID":"swirl","range":[0,1]}],\
        "deviceID":"","name":"\(name)"}
        """
        let url = MIDIMappingStore.directory.appendingPathComponent("zz-selftest-legacy.json")
        try? FileManager.default.createDirectory(at: MIDIMappingStore.directory,
                                                 withIntermediateDirectories: true)
        try? Data(legacyPreset.utf8).write(to: url)
        let loaded = MIDIMappingStore.load().first { $0.name == name }
        check("a mapping file written by the old build still loads",
              loaded?.binding(for: "swirl")?.cc == 9 && loaded?.binding(for: "swirl")?.component == nil,
              loaded.map { "\($0.bindings.count) bindings" } ?? "not loaded")
        MIDIMappingStore.delete(name)

        // Range scoping is modelled, persisted and honoured; this is the
        // honouring, which the new min/max editor is the front end for.
        let router = MIDIRouter()
        router.load([MIDIBinding(paramID: "p", channel: nil, cc: 11, range: 0.25 ... 0.75)])
        let scoped = controller.scopedValue(cc: 11, value: 127, on: router)
        let scopedLow = controller.scopedValue(cc: 11, value: 0, on: router)
        check("a scoped binding sweeps only its slice of the range",
              abs((scoped ?? -1) - 0.75) < 1e-6 && abs((scopedLow ?? -1) - 0.25) < 1e-6,
              "\(scopedLow ?? -1) … \(scoped ?? -1)")
        check("min and max survive a round trip out of the editor",
              MIDIBinding(paramID: "p", channel: nil, cc: 1).withRange(low: 0.9, high: 0.1).range
                  == 0.1 ... 0.9,
              "reversed input is put back in order rather than trapping")
    }

    // MARK: Mapping banks

    /// Two banks whose names slug to the same file name used to silently
    /// clobber each other. Both have to survive.
    private func mappingBankUnits() {
        let first = "ZZ Selftest Bank", second = "zz selftest bank"
        check("both names really do slug to one file name",
              ShaderScaffold.sanitize(name: first) == ShaderScaffold.sanitize(name: second),
              ShaderScaffold.sanitize(name: first) ?? "nil")

        var a = MappingPreset(name: first, deviceID: "")
        a.bind(MIDIBinding(paramID: "alpha", channel: nil, cc: 1))
        var b = MappingPreset(name: second, deviceID: "")
        b.bind(MIDIBinding(paramID: "beta", channel: nil, cc: 2))
        try? MIDIMappingStore.save(a)
        try? MIDIMappingStore.save(b)

        let loaded = MIDIMappingStore.load()
        check("two banks that slug alike both survive being saved",
              loaded.contains { $0.name == first && $0.binding(for: "alpha")?.cc == 1 }
                  && loaded.contains { $0.name == second && $0.binding(for: "beta")?.cc == 2 },
              loaded.map(\.name).joined(separator: " / "))
        check("they landed in two different files",
              MIDIMappingStore.existingURL(for: first) != MIDIMappingStore.existingURL(for: second),
              [first, second].compactMap { MIDIMappingStore.existingURL(for: $0)?.lastPathComponent }
                  .joined(separator: " / "))

        // Saving again must reuse each bank's own file rather than making a
        // third one — the disambiguation is sticky, not a counter that climbs.
        let before = MIDIMappingStore.existingURL(for: second)
        try? MIDIMappingStore.save(b)
        check("re-saving a disambiguated bank keeps its file",
              MIDIMappingStore.existingURL(for: second) == before,
              MIDIMappingStore.existingURL(for: second)?.lastPathComponent ?? "gone")

        check("deleting one leaves the other alone", {
            MIDIMappingStore.delete(first)
            let rest = MIDIMappingStore.load()
            return !rest.contains { $0.name == first } && rest.contains { $0.name == second }
        }())
        check("the UI refuses a name that differs only in case",
              MIDIMappingStore.nameIsTaken("ZZ SELFTEST BANK", in: MIDIMappingStore.load()))
        MIDIMappingStore.delete(second)
    }

    // MARK: Look at it

    /// Renders the subject shader with its colour parameter driven to several
    /// knob positions, so the claim "the composition does not break" can be
    /// checked by looking rather than only by arithmetic.
    private func renderColorSweep() {
        guard let param = colorParam, let subject,
              let base = param.defaultValue.colorValue else { return }
        let library = controller.metalView.shaderLibrary
        guard let renderer = LerpRenderer(device: library.device) else { return }
        let directory = URL(fileURLWithPath: "build/color-sweep")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var rendered = 0
        for value in stride(from: 0, through: 127, by: 127 / 5) {
            let color = ColorProjection.apply(.hue, position: Double(value) / 127,
                                              to: base, base: base)
            var values = LerpParameterValues(subject.parameters)
            values.set(param.name, .color(color))
            let url = directory.appendingPathComponent(
                String(format: "%@-%@-cc%03d.png", subject.name, param.name, value))
            let result = LerpSnapshot.render(shader: subject, library: library, renderer: renderer,
                                             width: 480, height: 300, time: 6, seed: 0.5,
                                             params: values, to: url)
            if result.error == nil { rendered += 1 }
        }
        check("rendered a hue sweep of \(subject.name).\(param.name) to look at", rendered == 6,
              "\(rendered)/6 in \(directory.path)")
        print("     wrote \(directory.path)/")
    }

    /// Draws the window's AppKit hierarchy into a PNG so the inspector's layout
    /// can actually be looked at. `cacheDisplay` is the view drawing itself, so
    /// this needs no screen-recording permission; the render pane is a live
    /// `CAMetalLayer` and comes out empty, which is the one thing this cannot show.
    private func captureUI() {
        guard let view = controller.window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: "build/playground-ui.png")
        guard let data = rep.representation(using: .png, properties: [:]),
              (try? data.write(to: url)) != nil else { return }
        print("     wrote \(url.path)")
    }

    /// The only way out. Reached on success, on a failed check, and from the
    /// watchdog — and it takes the window down before it goes, so a run that
    /// ends badly leaves no more behind than one that ends well.
    private func finish() {
        MIDIMappingStore.delete(Self.testMapping)
        try? FileManager.default.removeItem(at: ShaderPaths.customDirectory
            .appendingPathComponent(Self.parameterlessShader + ".metal"))
        UserDefaults().removePersistentDomain(forName: Self.scratchSuite)
        // The window opened dozens of shaders on the way through, and the last
        // one is now remembered. It is the test bundle's own preferences and not
        // the app's, but leaving it behind would make the next run open on
        // wherever this one ended rather than on its seeded rotation.
        OpeningShader.forget()
        // The test's own ByHost domain goes with the run — unless it was asked
        // to leave it for another process. The user's is never touched: nothing
        // in this file opens `RotationStore.module` for writing. See
        // `RotationStore.testModule`.
        if keepsRotation {
            print("HANDOFF the rotation above was left in \(Self.testModule); "
                  + "`defaults -currentHost delete \(Self.testModule)` clears it")
        } else {
            RotationStore.deleteDomain(Self.testModule)
        }
        sender = nil                      // takes the virtual MIDI source with it
        controller?.rotation?.close(cancellingWork: true)
        controller?.window?.orderOut(nil)
        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
