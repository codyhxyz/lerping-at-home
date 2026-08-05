import AppKit

/// LerpPlayground — live shader scratchpad for Lerping@Home.
///
///   make playground             build and run
///   make playground-test        build and run the scripted UI self-test
///   build/LerpPlayground        run (discovers Sources/Shaders from the repo)
///   build/LerpPlayground --selftest
///
/// Left pane edits a `.metal` file, right pane renders it through the exact
/// same LerpCore path the screensaver uses. Edits recompile ~300 ms after you
/// stop typing; a shader that fails to compile leaves the last good pipeline
/// on screen and reports the diagnostics in the console below the editor.
@main
enum PlaygroundMain {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            PlaygroundSelfTest.run()
        } else {
            boot(PlaygroundAppDelegate())
        }
    }

    /// `NSApplication.delegate` is weak, so the delegate needs an owner that
    /// outlives `run()`.
    private nonisolated(unsafe) static var appDelegate: NSApplicationDelegate?

    /// Starts AppKit with the playground's appearance and hands over to `delegate`.
    static func boot(_ delegate: NSApplicationDelegate) -> Never {
        appDelegate = delegate
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
            alert.informativeText = "LerpPlayground needs a Metal-capable GPU."
            alert.runModal()
            exit(1)
        }
        self.controller = controller
        controller.showAndStart()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - Menu

/// Built in code because the project has no Xcode project and therefore no nib.
/// The Edit menu is not optional garnish — without it the text view loses
/// undo/copy/paste/find. Items with unqualified selectors are dispatched up the
/// responder chain to `PlaygroundWindowController`.
enum MainMenu {

    static func build() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
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
