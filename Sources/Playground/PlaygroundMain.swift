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
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = PlaygroundAppDelegate()
        app.delegate = delegate
        app.run()
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
/// undo/copy/paste/find.
enum MainMenu {

    static func build() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let main = NSMenu()

        main.addItem(submenu(name, [
            .item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator,
            .item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            .item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator,
            .item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            .item("New Shader…", Selector(("newShader:")), "n"),
            .separator,
            .item("Save", Selector(("saveShader:")), "s"),
            .item("Revert to Saved", Selector(("revertShader:")), ""),
            .separator,
            .item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu("Edit", [
            .item("Undo", Selector(("undo:")), "z"),
            .item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator,
            .item("Cut", #selector(NSText.cut(_:)), "x"),
            .item("Copy", #selector(NSText.copy(_:)), "c"),
            .item("Paste", #selector(NSText.paste(_:)), "v"),
            .item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            .finder("Find…", .showFindInterface, "f"),
            .finder("Find Next", .nextMatch, "g"),
            .finder("Find Previous", .previousMatch, "G"),
        ]))

        main.addItem(submenu("Shader", [
            .item("Recompile", Selector(("recompile:")), "r"),
            .item("Play / Pause", Selector(("togglePlayPause:")), "\\"),
            .item("Re-roll Seed", Selector(("rerollSeed:")), "r", [.command, .shift]),
            .separator,
            .item("Next Shader", Selector(("nextShader:")), "]", [.command, .shift]),
            .item("Previous Shader", Selector(("previousShader:")), "[", [.command, .shift]),
            .separator,
            .item("Jump to First Error", Selector(("jumpToFirstError")), "e"),
        ]))

        main.addItem(submenu("Window", [
            .item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ]))

        return main
    }

    // MARK: Tiny menu DSL

    enum Entry {
        case separator
        case item(String, Selector, String, NSEvent.ModifierFlags = .command)
        case finder(String, NSTextFinder.Action, String)

        var menuItem: NSMenuItem {
            switch self {
            case .separator:
                return .separator()
            case let .item(title, action, key, modifiers):
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                return item
            case let .finder(title, action, key):
                let item = NSMenuItem(title: title,
                                      action: #selector(NSTextView.performTextFinderAction(_:)),
                                      keyEquivalent: key.lowercased())
                item.keyEquivalentModifierMask = key.first?.isUppercase == true
                    ? [.command, .shift] : .command
                item.tag = action.rawValue
                return item
            }
        }
    }

    private static func submenu(_ title: String, _ entries: [Entry]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for entry in entries { menu.addItem(entry.menuItem) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}
