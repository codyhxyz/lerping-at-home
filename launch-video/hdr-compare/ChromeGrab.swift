import AppKit

/// Opens one real titled window at a time with a magenta content view, makes it
/// key, and screenshots it twice with `screencapture -l` (with and without the
/// system shadow). The magenta is keyed out later: what is left is the genuine
/// macOS titlebar, traffic lights, corners and shadow, and the key's alpha is
/// exactly where window content goes.
///
///   ChromeGrab OUTDIR WIDTHxHEIGHT "Title A" "Title B" ...
@main
enum ChromeGrab {
    static func main() {
        let args = CommandLine.arguments
        let out = args[1]
        let size = args[2].split(separator: "x").compactMap { Double($0) }
        let titles = Array(args[3...])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Delegate(out: out, size: NSSize(width: size[0], height: size[1]), titles: titles)
        app.delegate = delegate
        app.run()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    let out: String, size: NSSize, titles: [String]
    init(out: String, size: NSSize, titles: [String]) { self.out = out; self.size = size; self.titles = titles }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        grab(0)
    }

    func grab(_ i: Int) {
        guard i < titles.count else { NSApp.terminate(nil); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = titles[i]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor
        window.contentView = view
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        // The app is launched with `open` so macOS lets it become active (an
        // inactive window has grey traffic lights). Screen recording permission
        // belongs to the terminal, so the capture runs there: publish the window
        // id, wait for grab.sh to write window<i>.done.
        let done = "\(out)/window\(i).done"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.activate()
            try? "\(window.windowNumber)".write(toFile: "\(self.out)/window\(i).id", atomically: true, encoding: .utf8)
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
                guard FileManager.default.fileExists(atPath: done) else { return }
                t.invalidate()
                window.close()
                self.grab(i + 1)
            }
        }
    }
}
