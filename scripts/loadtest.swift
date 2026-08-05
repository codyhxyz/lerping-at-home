// Verifies Lerping@Home.saver loads the way legacyScreenSaver will load it:
// NSBundle -> principal class -> instantiate a ScreenSaverView -> build the
// real Options… sheet and work it.
//
// This links AppKit and ScreenSaver and nothing else — no LerpCore — so it can
// see no type the saver defines. Everything below is reached the way another
// process would reach it: by view identifier, by KVC, and by pressing tiles
// through the accessibility API, which is what a tile is for.
//
//   loadtest <path to Lerping@Home.saver>
//
// Environment:
//   LOADTEST_DUMP_ROTATION=1   print the checked rotation keys, one per line
//   LERP_DEFAULTS_MODULE=…     point the saver at another ByHost domain. Set,
//                              and only when set, the run also presses OK and
//                              checks what was written. Never do that against
//                              the user's live domain — the guard below refuses.
import AppKit
import ScreenSaver

/// Reports a failed check and stops. Diagnostics go to stderr, like
/// `PreviewMain.fail`; the `OK:` progress lines stay on stdout.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
let liveModule = "com.hergenroeder.lerping"
let module = environment["LERP_DEFAULTS_MODULE"] ?? liveModule
/// Whether this run is allowed to press OK. Writing the rotation is a real part
/// of the sheet and worth testing — but never in the domain someone's
/// screensaver actually reads.
let mayWrite = module != liveModule

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("usage: loadtest <path to Lerping@Home.saver>")
    exit(2)
}
let bundlePath = arguments[1]
guard let bundle = Bundle(path: bundlePath) else {
    fail("no bundle at \(bundlePath)")
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

_ = NSApplication.shared

// MARK: - Finding things in a sheet built by code we cannot see

func allSubviews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + allSubviews($0) } }

func firstSubview<T: NSView>(_ root: NSView, _ type: T.Type) -> T? {
    if let hit = root as? T { return hit }
    for sub in root.subviews { if let hit = firstSubview(sub, type) { return hit } }
    return nil
}

func identifier(_ view: NSView) -> String { view.identifier?.rawValue ?? "" }

/// Views tagged with `prefix`, in the order they were added — which for the
/// gallery's canvas is shader heading, its count, then that shader's tiles.
func tagged(_ root: NSView, _ prefix: String) -> [NSView] {
    allSubviews(root).filter { identifier($0).hasPrefix(prefix) }
}

func named(_ root: NSView, _ id: String) -> NSView? {
    allSubviews(root).first { identifier($0) == id }
}

/// Spins the main run loop until `condition` holds. The gallery fills in from
/// background queues and delivers on the main queue, so a test that does not
/// run a run loop sees an empty gallery and learns nothing.
@discardableResult
func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        usleep(2000)
    }
    return condition()
}

/// The cache the sheet writes when the bundle did not already have a still.
/// Emptied before the cold open so "it came out of the bundle" is a thing this
/// test can actually observe rather than assume.
let runtimeCache = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Caches/com.hergenroeder.lerping/RotationThumbnails")
func pngCount(_ directory: URL) -> Int {
    ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "png" }.count
}
try? FileManager.default.removeItem(at: runtimeCache)

let bundledStills = URL(fileURLWithPath: bundlePath)
    .appendingPathComponent("Contents/Resources/Thumbnails")
let bundledCount = pngCount(bundledStills)
guard bundledCount > 0 else {
    fail("no stills baked into \(bundledStills.path) — `make saver` must render the gallery's "
         + "pictures into the bundle, because the sandboxed Options… sheet cannot render them itself")
}

// MARK: - Cold open

let coldStarted = CFAbsoluteTimeGetCurrent()
guard let panel = view.configureSheet, let content = panel.contentView else {
    fail("configureSheet returned no window")
}
let coldBuild = CFAbsoluteTimeGetCurrent() - coldStarted
content.layoutSubtreeIfNeeded()

guard let gallery = named(content, "rotation-gallery") else {
    fail("configure sheet has no rotation gallery")
}
guard let scroll = firstSubview(gallery, NSScrollView.self),
      let canvas = scroll.documentView else {
    fail("the rotation gallery does not scroll")
}
guard let note = named(content, "rotation-note") as? NSTextField,
      let counter = named(content, "rotation-count") as? NSTextField,
      let search = named(content, "rotation-search") as? NSSearchField else {
    fail("the gallery is missing its search field, its count or its status line")
}

// Opening Options… must not wait on 114 pictures. The tiles go up first and the
// stills land afterwards; this is the number that says so.
guard coldBuild < 1.0 else {
    fail(String(format: "the sheet took %.2f s to build — it is waiting on the stills", coldBuild))
}

let headings = tagged(canvas, "shader:")
let tiles = tagged(canvas, "entry:")
let counts = tagged(canvas, "count:")
guard !headings.isEmpty, !tiles.isEmpty else {
    fail("the gallery has \(headings.count) shader headings and \(tiles.count) tiles")
}

// Every look is a picture you can click, and it says as much to anything that
// asks: a tile is a checkbox with a value and a press.
let notCheckboxes = tiles.filter { $0.accessibilityRole() != .checkBox || $0.accessibilityValue() == nil }
guard notCheckboxes.isEmpty else {
    fail("\(notCheckboxes.count) tiles are not checkboxes to the accessibility API, "
         + "so they can neither be read nor pressed: "
         + notCheckboxes.prefix(3).map(identifier).joined(separator: ", "))
}
// Tiles are portrait — a look reads as a look, not as a filmstrip frame.
guard let tile = tiles.first, tile.frame.height > tile.frame.width else {
    fail("tiles are \(Int(tiles[0].frame.width))×\(Int(tiles[0].frame.height)), not portrait")
}
guard canvas.frame.height > scroll.contentView.bounds.height else {
    fail("the gallery does not scroll (\(canvas.frame.height) <= \(scroll.contentView.bounds.height))")
}

// The grid is grouped: a shader heading, then that shader's looks under it. A
// flat wall of 114 pictures would be as unusable as the flat list of 114
// checkboxes this replaced.
var groups: [(shader: String, entries: [String])] = []
for subview in allSubviews(canvas) {
    let id = identifier(subview)
    if id.hasPrefix("shader:") {
        guard let box = subview as? NSButton, box.allowsMixedState else {
            fail("shader heading '\(id)' cannot show a partial group")
        }
        groups.append((String(id.dropFirst("shader:".count)), []))
    } else if id.hasPrefix("entry:") {
        let key = String(id.dropFirst("entry:".count))
        guard var group = groups.popLast() else { fail("entry '\(key)' appears before any shader heading") }
        let owner = key.split(separator: "/", maxSplits: 1).first.map(String.init) ?? key
        guard owner == group.shader else {
            fail("entry '\(key)' is filed under shader heading '\(group.shader)'")
        }
        group.entries.append(key)
        groups.append(group)
    }
}
guard groups.count >= 20 else { fail("only \(groups.count) shader headings in the gallery") }
let entryKeys = groups.flatMap(\.entries)
guard entryKeys.count == Set(entryKeys).count else { fail("duplicate rotation entries in the gallery") }
guard entryKeys.count > groups.count else {
    fail("\(entryKeys.count) rotation entries for \(groups.count) shaders — presets are not in the gallery")
}
// Every shader contributes its declared defaults, so a shader that declares no
// presets at all still takes its turn.
for group in groups {
    guard group.entries.contains(group.shader) else {
        fail("shader '\(group.shader)' has no defaults entry, so it can drop out of the rotation")
    }
}
guard let bare = groups.first(where: { $0.entries.count == 1 }) else {
    fail("no shader in the gallery has a defaults-only group; 'pipes' declares no presets and should")
}
guard counts.count == groups.count else {
    fail("\(counts.count) n/m counts for \(groups.count) shader headings")
}
print("OK: configure sheet \(Int(content.frame.width))x\(Int(content.frame.height)), "
      + "\(groups.count) shader headings, \(entryKeys.count) rotation entries "
      + "(defaults-only: \(bare.shader)), tiles \(Int(tile.frame.width))×\(Int(tile.frame.height)) portrait, "
      + String(format: "built in %.0f ms, scrolls %d pt", coldBuild * 1000, Int(canvas.frame.height)))

// MARK: - The stills

func stillsMissing() -> Int { (gallery.value(forKey: "stillsMissing") as? Int) ?? -1 }
let fillStarted = CFAbsoluteTimeGetCurrent()
guard pump(until: { stillsMissing() == 0 }, timeout: 120) else {
    fail("\(stillsMissing()) of \(tiles.count) tiles never got a picture — "
         + ((view.value(forKey: "rotationStillsSummary") as? String) ?? "no summary"))
}
let coldFill = CFAbsoluteTimeGetCurrent() - fillStarted
guard let summary = view.value(forKey: "rotationStillsSummary") as? String else {
    fail("the saver does not report where the gallery's stills came from")
}
func stat(_ name: String) -> Int {
    for field in summary.split(separator: " ") where field.hasPrefix(name + "=") {
        return Int(field.dropFirst(name.count + 1)) ?? -1
    }
    return -1
}
guard stat("failed") == 0 else { fail("stills failed to render: \(summary)") }
// The whole reason `make saver` bakes them in: inside legacyScreenSaver's
// sandbox the GPU does no work at all for a shader that shipped in the bundle.
// Anything the bundle did not have — a custom shader, an edited one — is drawn
// at runtime and lands in the writable cache, and that is the only thing that
// may be there afterwards.
let rendered = stat("rendered")
guard stat("bundle") >= min(bundledCount, entryKeys.count) else {
    fail("only \(stat("bundle")) of \(entryKeys.count) stills came out of the bundle's "
         + "\(bundledCount): \(summary)")
}
guard pngCount(runtimeCache) == rendered, rendered == entryKeys.count - stat("bundle") else {
    fail("\(rendered) stills were rendered and \(pngCount(runtimeCache)) written to "
         + "\(runtimeCache.path); expected \(entryKeys.count - stat("bundle")) of each")
}
print(String(format: "OK: %d stills in %.2f s — %@", tiles.count, coldFill, summary))

// MARK: - What came up checked

func isOn(_ view: NSView) -> Bool { (view.accessibilityValue() as? Int) == 1 }
let checked = tiles.filter(isOn).map { String(identifier($0).dropFirst("entry:".count)) }
guard !checked.isEmpty else { fail("the rotation came up empty; it must never be able to") }
print("OK: \(checked.count) of \(entryKeys.count) entries checked, "
      + "across \(Set(checked.map { $0.split(separator: "/")[0] }).count) of \(groups.count) shaders")
if environment["LOADTEST_DUMP_ROTATION"] != nil {
    checked.forEach { print("ROTATION \($0)") }
}

// A heading says how much of its group is in, in two ways that have to agree:
// its own tri-state box and the n/m beside it.
for group in groups {
    guard let box = named(canvas, "shader:" + group.shader) as? NSButton,
          let count = named(canvas, "count:" + group.shader) as? NSTextField else {
        fail("shader '\(group.shader)' has no heading or no count")
    }
    let on = group.entries.filter { key in tiles.first { identifier($0) == "entry:" + key }.map(isOn) == true }.count
    let expected: NSControl.StateValue = on == 0 ? .off : (on == group.entries.count ? .on : .mixed)
    guard box.state == expected, count.stringValue == "\(on)/\(group.entries.count)" else {
        fail("'\(group.shader)': \(on) of \(group.entries.count) tiles on, but the heading says "
             + "\(box.state.rawValue) / “\(count.stringValue)”")
    }
}
let mixedGroups = groups.filter { group in
    let on = group.entries.filter { key in tiles.first { identifier($0) == "entry:" + key }.map(isOn) == true }.count
    return on > 0 && on < group.entries.count
}
print("OK: every shader heading agrees with its own tiles "
      + "(\(mixedGroups.count) partial: \(mixedGroups.map(\.shader).prefix(4).joined(separator: ", ")))")

// MARK: - A picture of it

// `screencapture` is blocked by TCC here and the sheet is never on screen
// anyway, so the sheet draws itself into a bitmap. This is the only check whose
// result is a thing to look at rather than a number — and it is taken here,
// before anything below has clicked anything, so what it shows is the rotation
// the user actually has: the looks that are out are the ones they took out.
content.layoutSubtreeIfNeeded()
if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
    content.cacheDisplay(in: content.bounds, to: rep)
    // One file per domain: the run against a throwaway domain sees a rotation
    // with nothing saved in it, i.e. everything on, and must not overwrite the
    // picture of the real one.
    let url = URL(fileURLWithPath: mayWrite
                  ? "build/configure-sheet-\(module).png"
                  : "build/configure-sheet.png")
    if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
        print("OK: wrote \(url.path)")
    }
}

// MARK: - Working it

func button(_ title: String, in root: NSView = content) -> NSButton? {
    allSubviews(root).compactMap { $0 as? NSButton }.first { $0.title == title }
}
func press(_ control: NSControl?) {
    guard let control, let action = control.action else { return }
    _ = control.target?.perform(action, with: control)
}

// A tile is pressed the way a mouse presses it: through its own handler.
guard let victim = tiles.first(where: isOn) else { fail("nothing is checked to switch off") }
let victimKey = String(identifier(victim).dropFirst("entry:".count))
guard victim.accessibilityPerformPress(), !isOn(victim) else {
    fail("pressing the tile for '\(victimKey)' did not take it out of the rotation")
}
guard note.stringValue.contains("\(checked.count - 1) of \(entryKeys.count) looks") else {
    fail("after switching one look off the status line reads “\(note.stringValue)”")
}
_ = victim.accessibilityPerformPress()
guard isOn(victim) else { fail("pressing '\(victimKey)' again did not put it back") }

// Deselect All has to be safe: an empty rotation is a black screensaver, and
// the sheet says out loud that it will be saved as all of them.
press(button("Deselect All"))
guard tiles.allSatisfy({ !isOn($0) }), note.stringValue.contains("saved as all") else {
    fail("Deselect All left \(tiles.filter(isOn).count) on and said “\(note.stringValue)”")
}
press(button("Select All"))
guard tiles.allSatisfy(isOn) else { fail("Select All missed \(tiles.filter { !isOn($0) }.count) looks") }

// Search narrows the grid, and Select All / Deselect All then act on what is
// shown — a button that quietly ignored the search would be a trap.
let filterName = groups[0].shader
search.stringValue = filterName
press(search)
let shown = tiles.filter { !$0.isHidden }
/// What the gallery searches: the shader's name and the preset's, with a
/// defaults entry searchable as "defaults".
func haystack(_ key: String) -> String {
    let parts = key.split(separator: "/", maxSplits: 1)
    return parts[0] + " " + (parts.count > 1 ? parts[1] : "defaults")
}
let expectedShown = entryKeys.filter {
    haystack($0).range(of: filterName, options: .caseInsensitive) != nil
}
guard shown.count == expectedShown.count, shown.count < tiles.count,
      note.stringValue.contains("\(shown.count) shown") else {
    fail("filtering on “\(filterName)” showed \(shown.count) of \(tiles.count) tiles, "
         + "expected \(expectedShown.count); status line “\(note.stringValue)”")
}
press(button("Deselect All"))
guard shown.allSatisfy({ !isOn($0) }), tiles.filter(isOn).count == tiles.count - shown.count else {
    fail("Deselect All with a filter up cleared \(tiles.filter { !isOn($0) }.count) tiles, "
         + "expected the \(shown.count) shown")
}
press(button("Select All"))
search.stringValue = ""
press(search)
guard tiles.filter({ !$0.isHidden }).count == tiles.count, tiles.allSatisfy(isOn) else {
    fail("clearing the filter left \(tiles.filter { $0.isHidden }.count) tiles hidden")
}
print("OK: tiles toggle, headings, search and Select/Deselect All all drive the same set "
      + "(status line: “\(note.stringValue)”, counter: “\(counter.stringValue)”)")

// A heading owns its whole group.
guard let multi = groups.first(where: { $0.entries.count > 1 }),
      let heading = named(canvas, "shader:" + multi.shader) as? NSButton else {
    fail("no shader in the gallery declares any presets")
}
press(heading)
let groupTiles = multi.entries.compactMap { key in tiles.first { identifier($0) == "entry:" + key } }
guard groupTiles.allSatisfy({ !isOn($0) }), heading.state == .off else {
    fail("a heading did not take its whole group out")
}
_ = groupTiles[0].accessibilityPerformPress()
guard heading.state == .mixed else { fail("a part-selected group's heading is not mixed") }
press(heading)
guard groupTiles.allSatisfy(isOn), heading.state == .on else {
    fail("a heading did not put its whole group back")
}
print("OK: the '\(multi.shader)' heading owns its \(multi.entries.count) looks, and goes mixed for a partial one")

// MARK: - The rest of the sheet

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
func galleryIsLive() -> Bool { tiles.allSatisfy { $0.isAccessibilityEnabled() } }
guard presetMenu.numberOfItems == 1, !presetMenu.isEnabled, galleryIsLive() else {
    fail("in Shuffle mode the Preset popup must be Defaults-only and off, and the gallery on")
}
// Pin a shader that has presets; the Preset popup must fill in and the gallery
// must grey out, because the rotation no longer applies to anything.
let pinTitle = shaderMenu.itemTitles.first { $0.lowercased() == multi.shader } ?? multi.shader
shaderMenu.selectItem(withTitle: pinTitle)
press(shaderMenu)
guard presetMenu.numberOfItems == multi.entries.count, presetMenu.isEnabled else {
    fail("pinning '\(pinTitle)' gave \(presetMenu.numberOfItems) preset choices, "
         + "expected \(multi.entries.count) (enabled=\(presetMenu.isEnabled))")
}
guard !galleryIsLive(), gallery.alphaValue < 1,
      note.stringValue.contains("Shuffle"), button("Select All")?.isEnabled == false else {
    fail("pinning a shader left the gallery live: alpha \(gallery.alphaValue), "
         + "status line “\(note.stringValue)”")
}
guard !tiles[0].accessibilityPerformPress() else {
    fail("a tile in a greyed-out gallery still answered a press")
}
shaderMenu.selectItem(withTitle: "Shuffle")
press(shaderMenu)
guard galleryIsLive(), !presetMenu.isEnabled, button("Select All")?.isEnabled == true else {
    fail("going back to Shuffle did not re-enable the gallery")
}
print("OK: pinning '\(pinTitle)' offers its \(multi.entries.count) presets and greys out the gallery")

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

// MARK: - Reopening

// The stills stay decoded on the view, not on the sheet, so the second open is
// instant. Cancel first — which is also the only check that Cancel works.
press(button("Cancel"))
let warmStarted = CFAbsoluteTimeGetCurrent()
guard let second = view.configureSheet, let secondContent = second.contentView else {
    fail("the sheet could not be opened a second time")
}
let warmBuild = CFAbsoluteTimeGetCurrent() - warmStarted
secondContent.layoutSubtreeIfNeeded()
guard let secondGallery = named(secondContent, "rotation-gallery") else {
    fail("the second sheet has no gallery")
}
guard pump(until: { (secondGallery.value(forKey: "stillsMissing") as? Int) == 0 }, timeout: 30) else {
    fail("reopening left \((secondGallery.value(forKey: "stillsMissing") as? Int) ?? -1) tiles blank")
}
let warmFill = CFAbsoluteTimeGetCurrent() - warmStarted
let warmSummary = (view.value(forKey: "rotationStillsSummary") as? String) ?? ""
guard warmSummary.contains("rendered=0"), warmSummary.contains("memory=\(entryKeys.count)") else {
    fail("reopening did not come out of memory: \(warmSummary)")
}
print(String(format: "OK: reopened in %.0f ms, filled in %.0f ms — %@",
             warmBuild * 1000, warmFill * 1000, warmSummary))

// MARK: - Writing it back

// Pressing OK is the other half of the sheet, and it is only ever exercised
// against a throwaway ByHost domain. See the guard on `mayWrite`.
if mayWrite {
    let secondTiles = tagged(secondContent, "entry:")
    guard let sacrifice = secondTiles.first(where: isOn) else { fail("nothing checked to drop") }
    let droppedKey = String(identifier(sacrifice).dropFirst("entry:".count))
    _ = sacrifice.accessibilityPerformPress()
    press(button("OK", in: secondContent))
    let written = (CFPreferencesCopyValue("enabledEntries" as CFString, module as CFString,
                                          kCFPreferencesCurrentUser,
                                          kCFPreferencesCurrentHost) as? [String]) ?? []
    guard written.count == secondTiles.count - 1, !written.contains(droppedKey) else {
        fail("OK wrote \(written.count) of \(secondTiles.count) keys to \(module) "
             + "(dropped '\(droppedKey)' still present: \(written.contains(droppedKey)))")
    }
    let roster = (CFPreferencesCopyValue("knownEntries" as CFString, module as CFString,
                                         kCFPreferencesCurrentUser,
                                         kCFPreferencesCurrentHost) as? [String]) ?? []
    guard roster.count == secondTiles.count else {
        fail("OK wrote a roster of \(roster.count) for \(secondTiles.count) looks, so a look "
             + "discovered later could not tell itself apart from one that was deselected")
    }
    print("OK: OK wrote \(written.count) of \(secondTiles.count) looks to \(module) (ByHost), "
          + "roster \(roster.count)")
} else {
    print("OK: read-only run against \(module) — nothing was written "
          + "(set LERP_DEFAULTS_MODULE to exercise OK)")
}
exit(0)
