import AppKit

/// LerpPlayground — live shader scratchpad for Lerping@Home.
///
///   make playground             build the .app and open it
///   make playground-test        build and run the scripted UI self-test
///   open -a LerpPlayground      launch it, or raise the copy already running
///
/// Left pane edits a `.metal` file, right pane renders it through the exact
/// same LerpCore path the screensaver uses. Edits recompile ~300 ms after you
/// stop typing; a shader that fails to compile leaves the last good pipeline
/// on screen and reports the diagnostics in the console below the editor.
///
/// It ships as `build/LerpPlayground.app`, not as a bare executable, because
/// everything an app is expected to do needs a bundle identifier: macOS
/// deduplicates launches by it, `open -a` resolves by it, and the Dock, ⌘-Tab
/// and preferences all key on it. Without one, every launch was another
/// process with another window and no way to raise the one already open.
///
/// The shader list still comes from the repo — `ShaderLocations` walks up from
/// the executable, which reaches the repo root from inside the bundle too, so
/// launching from Finder or the Dock works the same as from the shell.
@main
enum PlaygroundMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            PlaygroundSelfTest.run()
        } else {
            handOffToRunningInstance()
            boot(PlaygroundAppDelegate())
        }
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
            item("Recompile", Selector(("recompile:")), "r"),
            item("Play / Pause", Selector(("togglePlayPause:")), "\\"),
            item("Re-roll Seed", Selector(("rerollSeed:")), "r", [.command, .shift]),
            .separator(),
            item("Next Shader", Selector(("nextShader:")), "]", [.command, .shift]),
            item("Previous Shader", Selector(("previousShader:")), "[", [.command, .shift]),
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
