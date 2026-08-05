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
// the rotation checklist is populated, grouped and scrollable.
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
// Each row is a checkbox in a container (the container is what indents the
// preset rows), tagged with an identifier of "shader:<name>" or "entry:<key>".
let checkboxes = (0..<table.numberOfRows).compactMap {
    table.view(atColumn: 0, row: $0, makeIfNecessary: true).flatMap { firstSubview($0, NSButton.self) }
}
guard table.numberOfRows > 0, checkboxes.count == table.numberOfRows else {
    fail("rotation list has \(table.numberOfRows) rows, \(checkboxes.count) checkboxes")
}
guard table.frame.height > scroll.contentView.bounds.height else {
    fail("rotation list does not scroll (\(table.frame.height) <= \(scroll.contentView.bounds.height))")
}

// The list rotates (shader, preset) pairs, so it has to be grouped: a shader
// heading, then that shader's looks indented under it. A flat list of every
// pair would be unusable, and a list of bare shader names would hide two thirds
// of what the rotation can draw.
let ids = checkboxes.map { $0.identifier?.rawValue ?? "" }
guard ids.allSatisfy({ $0.hasPrefix("shader:") || $0.hasPrefix("entry:") }) else {
    fail("rotation rows are not tagged as shader headings or entries: "
         + ids.filter { !$0.hasPrefix("shader:") && !$0.hasPrefix("entry:") }.prefix(3).joined(separator: ", "))
}
var groups: [(shader: String, entries: [String])] = []
for (id, box) in zip(ids, checkboxes) {
    if id.hasPrefix("shader:") {
        groups.append((String(id.dropFirst("shader:".count)), []))
        guard box.allowsMixedState else { fail("shader heading '\(id)' cannot show a partial group") }
        continue
    }
    let key = String(id.dropFirst("entry:".count))
    guard var group = groups.popLast() else { fail("entry '\(key)' appears before any shader heading") }
    let owner = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? key
    guard owner == group.shader else {
        fail("entry '\(key)' is filed under shader heading '\(group.shader)'")
    }
    group.entries.append(key)
    groups.append(group)
}
guard groups.count >= 20 else { fail("only \(groups.count) shader headings in the rotation list") }
let entryKeys = groups.flatMap(\.entries)
guard entryKeys.count == Set(entryKeys).count else { fail("duplicate rotation entries in the list") }
guard entryKeys.count > groups.count else {
    fail("\(entryKeys.count) rotation entries for \(groups.count) shaders — presets are not in the list")
}
// Every shader contributes its declared defaults, so a shader that declares no
// presets at all still takes its turn.
for group in groups {
    guard group.entries.contains(group.shader) else {
        fail("shader '\(group.shader)' has no defaults entry, so it can drop out of the rotation")
    }
}
guard let bare = groups.first(where: { $0.entries.count == 1 }) else {
    fail("no shader in the list has a defaults-only group; 'pipes' declares no presets and should")
}
print("OK: configure sheet \(Int(content.frame.width))x\(Int(content.frame.height)), "
      + "\(groups.count) shader headings, \(entryKeys.count) rotation entries "
      + "(defaults-only: \(bare.shader)), "
      + "\(table.rows(in: scroll.contentView.documentVisibleRect).length) rows visible, scrolls")

// What the sheet came up with checked, which is the saved rotation after
// whatever migration it needed. Set LOADTEST_DUMP_ROTATION to have the keys
// themselves printed, one per line — that is how the migration from a
// pre-preset `enabledShaders` list is checked against real saved defaults.
let checked = zip(ids, checkboxes)
    .filter { $0.0.hasPrefix("entry:") && $0.1.state == .on }
    .map { String($0.0.dropFirst("entry:".count)) }
guard !checked.isEmpty else { fail("the rotation came up empty; it must never be able to") }
print("OK: \(checked.count) of \(entryKeys.count) entries checked, "
      + "across \(Set(checked.map { $0.split(separator: "/")[0] }).count) of \(groups.count) shaders")
if ProcessInfo.processInfo.environment["LOADTEST_DUMP_ROTATION"] != nil {
    checked.forEach { print("ROTATION \($0)") }
}

func allSubviews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + allSubviews($0) } }

// Pinning reaches a preset, not just a shader: the sheet needs a second popup
// beside the shader one.
let popups = allSubviews(content).compactMap { $0 as? NSPopUpButton }
guard popups.count >= 5 else {
    fail("configure sheet has \(popups.count) popups, expected shader, preset, fps, scale, still")
}
guard let shaderMenu = popups.first(where: { $0.itemTitles.first == "Shuffle" }) else {
    fail("no Shader popup offering Shuffle")
}
guard let presetMenu = popups.first(where: { $0.itemTitles.first == "Defaults" }) else {
    fail("no Preset popup")
}
guard shaderMenu.numberOfItems == groups.count + 1 else {
    fail("Shader popup has \(shaderMenu.numberOfItems) items for \(groups.count) shaders + Shuffle")
}
guard presetMenu.numberOfItems == 1, !presetMenu.isEnabled, table.isEnabled else {
    fail("in Shuffle mode the Preset popup must be Defaults-only and off, and the rotation list on")
}
// Pin a shader that has presets; the Preset popup must fill in and the rotation
// list must grey out.
guard let pinnable = groups.first(where: { $0.entries.count > 1 }) else {
    fail("no shader in the list declares any presets")
}
let pinTitle = shaderMenu.itemTitles.first { $0.lowercased() == pinnable.shader } ?? pinnable.shader
shaderMenu.selectItem(withTitle: pinTitle)
_ = shaderMenu.target?.perform(shaderMenu.action, with: shaderMenu)
guard presetMenu.numberOfItems == pinnable.entries.count, presetMenu.isEnabled else {
    fail("pinning '\(pinTitle)' gave \(presetMenu.numberOfItems) preset choices, "
         + "expected \(pinnable.entries.count) (enabled=\(presetMenu.isEnabled))")
}
guard !table.isEnabled else { fail("pinning a shader left the rotation list enabled") }
shaderMenu.selectItem(withTitle: "Shuffle")
_ = shaderMenu.target?.perform(shaderMenu.action, with: shaderMenu)
guard table.isEnabled, !presetMenu.isEnabled else {
    fail("going back to Shuffle did not re-enable the rotation list")
}
print("OK: pinning '\(pinTitle)' offers its \(pinnable.entries.count) presets and greys out the rotation list")

// The wallpaper handoff overwrites the user's desktop picture, so it has to be
// opt-in: the sheet must offer it and it must start off.
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
