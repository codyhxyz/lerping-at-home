import AppKit
import Metal

/// LerpPlayground — live shader scratchpad for Lerping@Home.
///
///   make playground             build, install, restart, and open the canonical app
///   make playground-build       compile only; never launch this staging bundle
///   make install-playground     install and stop any older running copy
///   open -a LerpPlayground      launch it, or raise the copy already running
///   LerpPlayground --shaders    print which checkout this copy reads, and what
///                               it found there
///   LerpPlayground --capture P  open exactly the way a launch does, say what it
///                               chose and why, and leave a PNG of the window
///                               at P. Changes nothing.
///
/// Left pane edits a `.metal` file, right pane renders it through the exact
/// same LerpCore path the screensaver uses. Edits recompile ~300 ms after you
/// stop typing; a shader that fails to compile leaves the last good pipeline
/// on screen and reports the diagnostics in the console below the editor.
///
/// It ships as a bundled app because macOS deduplicates launches by its bundle
/// identifier and the Dock, ⌘-Tab and preferences all key on it. The build-tree
/// bundle is staging only; normal commands install and run the single canonical
/// copy in ~/Applications, so a successful build cannot leave an older app
/// serving the user.
///
/// The shader list still comes from a checkout — the staging build can walk up
/// from its executable, while the copy in ~/Applications reads the checkout
/// `make install-playground` recorded in its Info.plist. See
/// `RepoLocation`, which is also what puts a named error and a folder picker on
/// screen when that checkout has moved.
@main
enum PlaygroundMain {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--quit-bundle-id"),
           let identifier = CommandLine.arguments.dropFirst(index + 1).first {
            quitRunningInstance(identifier)
        } else if let index = CommandLine.arguments.firstIndex(of: "--fail-if-running-bundle-id"),
                  let identifier = CommandLine.arguments.dropFirst(index + 1).first {
            failIfRunning(identifier)
        } else if CommandLine.arguments.contains("--shaders") {
            reportShaders()
        } else if let index = CommandLine.arguments.firstIndex(of: "--capture") {
            let next = CommandLine.arguments.dropFirst(index + 1).first
            let path = next.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "build/opening.png"
            boot(OpeningCaptureDelegate(path: path), policy: .accessory)
        } else {
            handOffToRunningInstance()
            boot(PlaygroundAppDelegate())
        }
    }

    /// Asks a running copy to terminate, then waits until it really has. The
    /// target's app delegate protects unsaved editor text; cancelling that prompt
    /// makes deployment fail instead of replacing the bundle under an old process.
    private static func quitRunningInstance(_ identifier: String) -> Never {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != me }) else { exit(0) }
        guard let url = running.bundleURL,
              Bundle(url: url)?.object(forInfoDictionaryKey: "LerpSafeDeploymentQuit") as? Bool == true
        else {
            running.activate(options: [.activateAllWindows])
            FileHandle.standardError.write(Data(
                "\(identifier) is an older running build; close it once before deployment\n".utf8))
            exit(1)
        }
        guard running.terminate() else {
            FileHandle.standardError.write(Data("could not ask \(identifier) to quit\n".utf8))
            exit(1)
        }
        let deadline = Date().addingTimeInterval(60)
        while !running.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard running.isTerminated else {
            FileHandle.standardError.write(Data(
                "\(identifier) is still running; deployment stopped to protect unsaved edits\n".utf8))
            exit(1)
        }
        exit(0)
    }

    /// Staging bundles should never run. Refuse deployment rather than guessing
    /// whether a historical build can protect unsaved editor text on termination.
    private static func failIfRunning(_ identifier: String) -> Never {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != me }
        if running {
            FileHandle.standardError.write(Data(
                "staging playground \(identifier) is running; close it before deployment\n".utf8))
        }
        exit(running ? 1 : 0)
    }

    /// `--shaders`: which checkout this copy resolved, how, and what is in it.
    ///
    /// `make install-playground` runs it on the copy it just installed, because
    /// "the app opened" is not the claim worth checking — "the app found the 30
    /// shaders in your repo" is. It is also the first thing to run when an
    /// installed copy comes up wrong, and it exits non-zero when it does.
    private static func reportShaders() -> Never {
        let outcome = RepoLocation.settled()
        guard case let .found(shaders, _, origin) = outcome else {
            let problem = RepoLocation.problem(outcome)!
            FileHandle.standardError.write(Data("\(problem.title)\n\(problem.detail)\n".utf8))
            exit(1)
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("no Metal device\n".utf8))
            exit(1)
        }
        let names = ShaderLibrary(device: device, extraSearchURLs: [shaders]).discover().map(\.name)
        print("shaders: \(shaders.path)")
        print("via:     \(origin.tag)")
        print("count:   \(names.count)")
        print(names.joined(separator: " "))
        exit(names.isEmpty ? 1 : 0)
    }

    /// The app's name as the menu bar, the Dock and ⌘-Tab know it — from the
    /// bundle, so there is one place it is written down.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// Single instance, enforced here rather than only relied on from
    /// LaunchServices.
    ///
    /// `open -a` already refuses to start a second copy of a bundled app and
    /// sends a re-open to the first instead, which is why `make playground`
    /// goes through it. But running `LerpPlayground.app/Contents/MacOS/
    /// LerpPlayground` by hand never reaches LaunchServices, so the same rule
    /// is applied here: if another process is registered under this bundle
    /// identifier, raise it and get out of the way.
    private static func handOffToRunningInstance() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != me }) else { return }
        running.activate(options: [.activateAllWindows])
        exit(0)
    }

    /// `NSApplication.delegate` is weak, so the delegate needs an owner that
    /// outlives `run()`.
    private nonisolated(unsafe) static var appDelegate: NSApplicationDelegate?

    /// Starts AppKit with the playground's appearance and hands over to `delegate`.
    ///
    /// The app is `.regular` — Dock tile, menu bar, ⌘-Tab. `--selftest` passes
    /// `.accessory` so a test run has none of those and cannot take the
    /// foreground away from whatever the user is doing.
    static func boot(_ delegate: NSApplicationDelegate,
                     policy: NSApplication.ActivationPolicy = .regular) -> Never {
        appDelegate = delegate
        let app = NSApplication.shared
        app.setActivationPolicy(policy)
        app.appearance = NSAppearance(named: .darkAqua)
        app.delegate = delegate
        app.run()
        exit(0)
    }
}

final class PlaygroundAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PlaygroundWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        // Before any window: a copy whose checkout has moved says so and offers
        // the picker, rather than opening onto an empty shader list. Quitting is
        // the user's other option, and it is a real one — there is nothing this
        // app can do without a checkout.
        guard ShaderFolderPrompt.settle() else { exit(0) }

        guard let controller = PlaygroundWindowController.make() else {
            let alert = NSAlert()
            alert.messageText = "No Metal device"
            alert.informativeText = "\(PlaygroundMain.name) needs a Metal-capable GPU."
            alert.runModal()
            exit(1)
        }
        self.controller = controller
        controller.showAndStart()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One window is the whole app, so closing it quits — rather than leaving a
    /// live process with nothing on screen, which is the state that made the
    /// old build feel like it was multiplying.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Deployments request a normal app termination, never kill the editor. The
    /// controller uses the same Save / Discard / Cancel prompt as closing its
    /// window, so Cancel leaves the process and installed bundle untouched.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller?.approveTermination() == false ? .terminateCancel : .terminateNow
    }

    /// A Dock click, or the re-open LaunchServices sends instead of launching a
    /// second copy. Either way the answer is the window that already exists.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        controller?.raise()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// The rotation gallery has a window of its own, so when *it* is key the
    /// editor's window controller is not in the responder chain and the menu
    /// item would grey out. NSApp asks its delegate last; this is that.
    @objc func showRotationGallery(_ sender: Any?) {
        controller?.showRotationGallery(sender)
    }
}

// MARK: - `--capture`

/// `--capture PATH`: build the real window the way `applicationDidFinishLaunching`
/// does, against the real screensaver rotation and the real last-opened memory,
/// and report what it opened on and why.
///
/// This exists because "the playground opens on a look you actually shuffle
/// through" is a claim about the machine it is running on — the rotation is in
/// the user's ByHost domain, not in the repo — and `make playground-test` cannot
/// assert it without reading their settings. `--shaders` is the same shape of
/// tool for the same reason: not a claim the suite can make, so the app makes it
/// about itself.
///
/// It disturbs nothing:
///
/// - The screensaver's rotation is **read** and never written, like on every
///   other launch.
/// - The last-opened memory is put back exactly as it was found, so running this
///   neither creates a memory nor destroys one — it only reports through which
///   of the two doors the window came.
/// - `.accessory` with a hidden window: no Dock tile, no ⌘-Tab entry, no stolen
///   focus, and no window on top of whatever you are doing. The window is real
///   and rendering — see `PlaygroundWindowController.hide` — it is just at zero
///   opacity, which is also why the render pane comes out empty in the PNG. The
///   PNG is of the chrome: the shader popup, the inspector and its preset.
final class OpeningCaptureDelegate: NSObject, NSApplicationDelegate {
    private let path: String
    private var controller: PlaygroundWindowController?
    private var previousMemory: LerpRotationEntry?

    init(path: String) { self.path = path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        previousMemory = OpeningShader.remembered()

        guard let controller = PlaygroundWindowController.make(hidden: true) else {
            FileHandle.standardError.write(Data("no Metal device\n".utf8))
            finish(1)
        }
        self.controller = controller
        controller.showAndStart()
        // Long enough for the display link to have produced frames, so the fps
        // line in the report means something.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in report() }
    }

    private func report() {
        guard let controller else { finish(1) }
        let library = controller.metalView.shaderLibrary
        let discovered = library.discover()
        let all = discovered.rotationEntries()
        let enabled = RotationStore.rotation(discovered: all, from: RotationStore.saverDefaults())
        let opened = controller.currentEntry
        // The memory beats the rotation, so a remembered look that came back is
        // the memory's doing even when the rotation would also have allowed it.
        let resumed = previousMemory != nil && previousMemory?.shader == opened.shader

        print("opened:   \(opened.key)")
        print("from:     " + (resumed ? "the look this app last had open"
                                      : "a draw from the enabled rotation"))
        print("memory:   \(previousMemory?.key ?? "nothing — this is a first launch")")
        print("rotation: \(enabled.count) of \(all.count) looks enabled, "
              + "across \(Set(enabled.map(\.shader)).count) of \(discovered.count) shaders")
        print("in it:    \(enabled.contains(opened))")
        print("fps:      \(controller.metalView.statusText)")

        // The preset, proved by the bytes rather than by the label: the tail of
        // the uniform block is literally what the fragment shader is handed.
        if let shader = discovered.named(opened.shader) {
            let defaults = shader.defaultParameterValues().packedTail
            let live = controller.metalView.parameterValues?.packedTail ?? []
            let differing = zip(defaults, live).filter { $0 != $1 }.count
                + abs(defaults.count - live.count)
            print("preset:   \(opened.preset ?? "(shader defaults)")"
                  + " — \(differing) of \(max(defaults.count, live.count)) packed bytes"
                  + " differ from \(shader.name)'s defaults")
        }

        if let view = controller.window?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]),
               (try? data.write(to: URL(fileURLWithPath: path))) != nil {
                print("wrote:    \(path)")
            }
        }
        finish(opened.shader.isEmpty ? 1 : 0)
    }

    /// Puts the last-opened memory back the way it was found, then goes.
    private func finish(_ status: Int32) -> Never {
        if let previousMemory {
            OpeningShader.remember(previousMemory)
        } else {
            OpeningShader.forget()
        }
        controller?.window?.orderOut(nil)
        exit(status)
    }
}

// MARK: - Menu

/// Built in code because the project has no Xcode project and therefore no nib.
/// The Edit menu is not optional garnish — without it the text view loses
/// undo/copy/paste/find. Items with unqualified selectors are dispatched up the
/// responder chain to `PlaygroundWindowController`.
enum MainMenu {

    static func build() -> NSMenu {
        let name = PlaygroundMain.name
        let main = NSMenu()

        main.addItem(submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Shader…", Selector(("newShader:")), "n"),
            .separator(),
            item("Save", Selector(("saveShader:")), "s"),
            item("Revert to Saved", Selector(("revertShader:")), ""),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find("Find…", .showFindInterface, "f"),
            find("Find Next", .nextMatch, "g"),
            find("Find Previous", .previousMatch, "G"),
        ]))

        main.addItem(submenu("Shader", [
            item("Open Look…", #selector(PlaygroundWindowController.showShaderPicker(_:)), "o"),
            // Beside Open Look… because it is the same noun: one picks a look to
            // edit, the other makes the edit into a look. ⇧⌘S is Save As
            // everywhere on the platform and is what this is — the buffer's Save
            // is ⌘S in the File menu, and this saves it *plus* a name for the
            // values the file cannot otherwise remember.
            item("Save Look as Preset…", #selector(PlaygroundWindowController.savePreset(_:)), "s",
                 [.command, .shift]),
            .separator(),
            item("Recompile", Selector(("recompile:")), "r"),
            item("Play / Pause", Selector(("togglePlayPause:")), "\\"),
            item("Re-roll Seed", Selector(("rerollSeed:")), "r", [.command, .shift]),
            .separator(),
            item("Next Look", Selector(("nextLook:")), "]", [.command, .shift]),
            item("Previous Look", Selector(("previousLook:")), "[", [.command, .shift]),
            .separator(),
            item("Jump to First Error", Selector(("jumpToFirstError")), "e"),
            .separator(),
            item("Show / Hide Inspector", #selector(PlaygroundWindowController.toggleInspector(_:)), "i"),
            item("Next MIDI Mapping", #selector(PlaygroundWindowController.nextMapping(_:)), "m",
                 [.command, .option]),
            .separator(),
            item("Screensaver Rotation…", #selector(PlaygroundWindowController.showRotationGallery(_:)),
                 "r", [.command, .option]),
        ]))

        main.addItem(submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ]))

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        return entry
    }

    /// The find commands share one selector and are told apart by the item's tag.
    /// An uppercase key means the shortcut wants shift.
    private static func find(_ title: String, _ action: NSTextFinder.Action, _ key: String) -> NSMenuItem {
        let entry = item(title, #selector(NSTextView.performTextFinderAction(_:)), key.lowercased(),
                         key.first?.isUppercase == true ? [.command, .shift] : .command)
        entry.tag = action.rawValue
        return entry
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
