// Verifies Lerping@Home.saver loads the way legacyScreenSaver will load it:
// NSBundle -> principal class -> instantiate a ScreenSaverView.
import AppKit
import ScreenSaver

/// Reports a failed check and stops. Diagnostics go to stderr, like
/// `PreviewMain.fail`; the `OK:` progress lines stay on stdout.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: loadtest <path to Lerping@Home.saver>")
    exit(2)
}
guard let bundle = Bundle(path: arguments[1]) else {
    fail("no bundle at \(arguments[1])")
}
do {
    try bundle.loadAndReturnError()
} catch {
    fail("bundle load error: \(error)")
}
guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
    fail("principal class is \(String(describing: bundle.principalClass)), not a ScreenSaverView")
}
guard let view = principal.init(frame: NSRect(x: 0, y: 0, width: 400, height: 250), isPreview: true) else {
    fail("could not instantiate \(principal)")
}
print("OK: loaded \(principal), instantiated \(type(of: view)), hasConfigureSheet=\(view.hasConfigureSheet)")

// The Options… sheet is built entirely in code; make sure it assembles and that
// the shader rotation checklist is populated and scrollable.
_ = NSApplication.shared
guard let panel = view.configureSheet, let content = panel.contentView else {
    fail("configureSheet returned no window")
}
content.layoutSubtreeIfNeeded()
func firstSubview<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
    if let hit = root as? T { return hit }
    for sub in root.subviews { if let hit = firstSubview(sub, type) { return hit } }
    return nil
}
guard let table = firstSubview(content, NSTableView.self),
      let scroll = firstSubview(content, NSScrollView.self) else {
    fail("configure sheet has no shader rotation list")
}
let checkboxes = (0..<table.numberOfRows).compactMap {
    table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? NSButton
}
guard table.numberOfRows > 0, checkboxes.count == table.numberOfRows else {
    fail("rotation list has \(table.numberOfRows) rows, \(checkboxes.count) checkboxes")
}
guard table.frame.height > scroll.contentView.bounds.height else {
    fail("rotation list does not scroll (\(table.frame.height) <= \(scroll.contentView.bounds.height))")
}
print("OK: configure sheet \(Int(content.frame.width))x\(Int(content.frame.height)), "
      + "\(checkboxes.count) shader checkboxes, "
      + "\(table.rows(in: scroll.contentView.documentVisibleRect).length) visible, scrolls")

// The wallpaper handoff overwrites the user's desktop picture, so it has to be
// opt-in: the sheet must offer it and it must start off.
func allSubviews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + allSubviews($0) } }
let wallpaperBox = allSubviews(content).compactMap { $0 as? NSButton }.first {
    $0.title.lowercased().contains("desktop picture")
}
guard let wallpaperBox else {
    fail("configure sheet has no desktop-picture checkbox")
}
guard wallpaperBox.state == .off else {
    fail("desktop-picture checkbox defaults to on; it must be opt-in")
}
print("OK: desktop-picture handoff checkbox present and off by default")
exit(0)
