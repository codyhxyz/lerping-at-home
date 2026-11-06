import AppKit
import Foundation

/// `LerpPreview --rotation-selftest`: the rotation's selection, storage,
/// schedule and Library gallery, checked against the real shader library.
///
/// - A shader switched off keeps its hand-picked looks and gets them back when
///   switched on; a look added later stays out of a switched-off shader.
/// - `shader/*` survives a write and a read, and nothing under it plays.
/// - The schedule gives every shader the same airtime whatever its preset
///   count, still walks every look, never repeats a look back to back, and is a
///   pure function of the clock.
/// - `*` cannot be a preset name.
/// - The Library is cards only — one per shader, no per-preset tiles — its
///   badge and All / None switch shaders keeping their picks, search finds a
///   shader by a preset's name and opens it wearing that preset, and the floor
///   still holds.
///
/// Writes only a scratch defaults domain, never the user's rotation.
enum RotationSelfTest {

    static func run(_ extraSearch: [URL]) {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if !ok { failures.append(what()) }
        }

        selection(check)
        storage(check)
        schedule(check)
        reserved(check)
        gallery(extraSearch, check)
        if let dir = ProcessInfo.processInfo.environment["LERP_GALLERY_SNAPSHOT"] {
            snapshot(extraSearch, to: URL(fileURLWithPath: dir))
        }

        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(("FAIL  " + failure + "\n").data(using: .utf8)!) }
            PreviewMain.fail("rotation self-test: \(failures.count) check\(failures.count == 1 ? "" : "s") failed")
        }
        print("OK    rotation: shader switch keeps picks, shader/* round trip, per-shader airtime, "
              + "no back-to-back repeats, * reserved, Library cards/search/floor")
    }

    // MARK: - Fixtures

    static func look(_ shader: String, _ preset: String? = nil) -> LerpRotationEntry {
        LerpRotationEntry(shader: shader, preset: preset)
    }

    /// Three shaders with one, seven and two looks: the shape that made a
    /// flat look shuffle give `sierpinski-pyramid` 3.5× `torque`'s airtime.
    static let fixture: [LerpRotationEntry] =
        [look("solo")]
        + [look("many")] + (1...6).map { look("many", "P\($0)") }
        + [look("pair"), look("pair", "Other")]

    // MARK: - Selection

    static func selection(_ check: (Bool, @autoclosure () -> String) -> Void) {
        var s = LerpRotationSelection(discovered: fixture)
        check(s.playable == fixture, "nothing off means everything plays")

        // Curate, switch off, switch on.
        s.setLook(look("many", "P1"), on: false)
        s.setLook(look("many", "P2"), on: false)
        let curated = s.playable
        s.setShader("many", on: false)
        check(!s.shaderPlays("many"), "a switched-off shader plays nothing")
        check(s.playable.allSatisfy { $0.shader != "many" }, "no look of a switched-off shader is playable")
        check(s.isPicked(look("many", "P3")) && !s.isPicked(look("many", "P1")),
              "switching a shader off keeps its per-look picks")
        s.setShader("many", on: true)
        check(s.playable == curated, "switching it back on restores exactly the curated looks")

        // A click on a look of a switched-off shader switches the shader on.
        s.setShader("many", on: false)
        s.setLook(look("many", "P1"), on: true)
        check(!s.isSwitchedOff("many") && s.plays(look("many", "P1")) && !s.plays(look("many", "P2")),
              "turning a look on in a switched-off shader switches the shader on, other picks intact")

        // Switching on a shader with nothing picked brings everything in.
        var empty = LerpRotationSelection(discovered: fixture)
        empty.setLooks(empty.looks(of: "pair"), on: false)
        empty.setShader("pair", on: true)
        check(empty.looks(of: "pair").allSatisfy(empty.plays),
              "switching on a shader with nothing picked brings all its looks in")

        // A look added later joins an on shader and stays out of an off one.
        var off = LerpRotationSelection(discovered: fixture)
        off.setShader("pair", on: false)
        let grown = fixture + [look("pair", "Newer"), look("solo", "Newer")]
        let later = LerpRotationSelection(discovered: grown, disabled: off.disabled)
        check(!later.plays(look("pair", "Newer")), "a new preset of a switched-off shader stays off")
        check(later.plays(look("solo", "Newer")), "a new preset of an on shader joins")

        // Keys that mean nothing today are dropped; `/*` of a live shader is kept.
        let stale = LerpRotationSelection(discovered: fixture,
                                          disabled: [look("gone"), .wholeShader("gone"),
                                                     .wholeShader("solo"), look("many", "Vanished")])
        check(stale.disabled == [.wholeShader("solo")], "only keys for what is on disk survive")
        check(LerpRotationEntry(key: "solo/*") == .wholeShader("solo") && LerpRotationEntry.wholeShader("solo").key == "solo/*",
              "shader/* round-trips through its key")
    }

    // MARK: - Storage

    static func storage(_ check: (Bool, @autoclosure () -> String) -> Void) {
        guard !LerpDefaults.isProduction else {
            return check(false, "storage: run with \(LerpDefaults.moduleOverrideVariable) set to a scratch domain")
        }
        let suite = LerpDefaults.module + ".rotation-selftest.\(getpid())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return check(false, "storage: could not open scratch defaults \(suite)")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        var s = LerpRotationSelection(discovered: fixture)
        s.setLook(look("many", "P4"), on: false)
        s.setShader("pair", on: false)
        let written = LerpRotation.write(s, writer: "selftest", to: defaults)
        check(written.disabled == s.disabled, "write stores the selection's off set as it stands")
        let stored = defaults.dictionary(forKey: LerpRotation.stateKey)?["disabled"] as? [String] ?? []
        check(stored == ["many/P4", "pair/*"], "the plist holds plain keys, shader/* among them: \(stored)")

        let read = LerpRotation.read(defaults, discovered: fixture)
        check(LerpRotation.playable(discovered: fixture, in: read) == s.playable,
              "what is read back plays exactly what was written")
        check(LerpRotation.enabled(discovered: fixture, in: read) == Set(s.playable),
              "LerpRotation.enabled honours shader/*")

        // A rename of a curated preset carries the opinion; the switch stays.
        let renamed = fixture.map { $0 == look("many", "P4") ? look("many", "Four") : $0 }
        let after = LerpRotation.selection(discovered: renamed,
                                           in: LerpRotation.read(defaults, discovered: renamed))
        check(!after.isPicked(look("many", "Four")) && after.isSwitchedOff("pair"),
              "a renamed preset keeps its opinion and shader/* survives reconciling")
    }

    // MARK: - Schedule

    static func schedule(_ check: (Bool, @autoclosure () -> String) -> Void) {
        let interval: TimeInterval = 300
        func due(_ entries: [LerpRotationEntry], _ slot: Int) -> LerpRotationEntry {
            let at = Date(timeIntervalSinceReferenceDate: Double(slot) * interval + 1)
            let r = LerpRotationSchedule.rotation(entries, at: at, interval: interval)
            return r.order[r.index]
        }

        // 3 shaders × 7 × 2 = 42 cycles is a whole number of passes for each.
        let slots = 3 * 7 * 2 * 3
        let played = (0..<slots).map { due(fixture, $0) }
        var perShader: [String: Int] = [:]
        for entry in played { perShader[entry.shader, default: 0] += 1 }
        check(Set(perShader.values).count == 1,
              "every shader gets the same airtime whatever its look count: \(perShader)")
        check(Set(played) == Set(fixture), "every look is played")
        check(zip(played, played.dropFirst()).allSatisfy { $0 != $1 }, "no look plays twice in a row")
        for cycle in 0..<(slots / 3) {
            let pass = played[(cycle * 3)..<(cycle * 3 + 3)].map(\.shader)
            if Set(pass).count != 3 { check(false, "cycle \(cycle) does not visit each shader once: \(pass)") }
        }
        let many = played.filter { $0.shader == "many" }
        for pass in 0..<(many.count / 7) where Set(many[(pass * 7)..<(pass * 7 + 7)]).count != 7 {
            check(false, "pass \(pass) through many's looks repeats one")
        }
        check((0..<50).map { due(fixture, $0) } == Array(played.prefix(50)), "the schedule is a pure function of the clock")

        // One shader with several looks on still rotates through them.
        let single = fixture.filter { $0.shader == "many" }
        let singlePlays = (0..<14).map { due(single, $0) }
        check(Set(singlePlays) == Set(single) && zip(singlePlays, singlePlays.dropFirst()).allSatisfy { $0 != $1 },
              "a one-shader rotation steps through its looks")

        // Negative slots (a manual nudge before the reference date) still land.
        let earlier = (-30..<0).map { due(fixture, $0) }
        check(earlier.allSatisfy(fixture.contains), "slots before the reference date resolve")
    }

    // MARK: - Reserved name

    static func reserved(_ check: (Bool, @autoclosure () -> String) -> Void) {
        check(LerpPresetWriter.problem(withName: "*") != nil, "the preset writer refuses *")
        let parsed = LerpParamParser.parse(source: """
            // lerp-param: level float 0 1 = 0.5
            // lerp-preset: * level=0.2
            """)
        check(parsed.errors.contains { $0.message.contains("reserved") } && parsed.presets.isEmpty,
              "the parser rejects a hand-written * preset")
    }

    // MARK: - Snapshot

    /// `LERP_GALLERY_SNAPSHOT=<dir>`: the Library, and a search, as PNGs drawn
    /// with the stills the saver bundle ships — for looking at, not for
    /// checking.
    static func snapshot(_ extraSearch: [URL], to dir: URL) {
        let shaders = PreviewMain.makeLibrary(extraSearch).library.discover()
        let entries = shaders.rotationEntries()
        let bundled = URL(fileURLWithPath: "build/Lerping@Home.saver/Contents/Resources/Thumbnails")
        let stills = RotationThumbnails(searchURLs: extraSearch,
                                        directory: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("lerp-gallery-snapshot"),
                                        readOnlyDirectories: [bundled])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = RotationGalleryView(frame: window.contentLayoutRect)
        view.onOpen = { _ in }
        view.onNew = {}
        window.contentView = view
        var picked = LerpRotationSelection(discovered: entries)
        let open = shaders.first { [$0].rotationEntries().count >= 8 }?.name ?? shaders[0].name
        picked.setLooks(picked.looks(of: open).dropFirst(4), on: false)
        picked.setShader(shaders[2].name, on: false)
        view.show(shaders: shaders, selection: picked)
        view.showCurrent(picked.looks(of: open).first)
        for entry in entries {
            guard let shader = shaders.named(entry.shader),
                  let url = stills.existingURL(entry: entry, source: shader.source),
                  let image = RotationThumbnails.decodedImage(at: url) else { continue }
            view.show(image: image, for: entry)
        }
        func save(_ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
        }
        save("library.png")
        view.setFilter("Day")
        save("search.png")
        print("wrote \(dir.path)/library.png, search.png")
    }

    // MARK: - Gallery

    static func find<T: NSView>(_ id: String, in view: NSView, as _: T.Type = T.self) -> T? {
        if view.identifier?.rawValue == id, let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(id, in: sub, as: T.self) { return hit } }
        return nil
    }

    static func all<T: NSView>(in view: NSView, as _: T.Type = T.self) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(in: $0, as: T.self) }
    }

    static func gallery(_ extraSearch: [URL], _ check: (Bool, @autoclosure () -> String) -> Void) {
        let shaders = PreviewMain.makeLibrary(extraSearch).library.discover()
        let entries = shaders.rotationEntries()
        guard let target = shaders.first(where: { [$0].rotationEntries().count > 3 })?.name,
              let other = shaders.first(where: { $0.name != target })?.name else {
            return check(false, "gallery: the library needs a shader with more than three presets")
        }

        let view = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                       tileSize: RotationTile.size)
        var published: LerpRotationSelection?
        var opened: LerpRotationEntry?
        view.onChange = { published = $0 }
        view.onOpen = { opened = $0 }
        view.show(shaders: shaders, selection: LerpRotationSelection(discovered: entries))
        view.layoutSubtreeIfNeeded()

        let tiles: [RotationTile] = all(in: view)
        check(tiles.count == shaders.count, "one card per shader and nothing else: \(tiles.count) tiles for \(shaders.count) shaders")
        check(find("drawer", in: view, as: NSView.self) == nil, "there is no drawer")
        check(find("rotation-all", in: view, as: NSButton.self) != nil
              && find("rotation-none", in: view, as: NSButton.self) != nil, "the header has All and None")

        guard let card: RotationTile = find("card:" + target, in: view) else {
            return check(false, "gallery: no card for \(target)")
        }
        let looksOf = entries.filter { $0.shader == target }
        check(card.summary == "all \(looksOf.count) presets", "the card counts its presets: \(card.summary ?? "nil")")

        // Pressing a card opens its cover; the badge (show-menu) switches it.
        _ = card.accessibilityPerformPress()
        check(opened == looksOf.first && published == nil, "pressing a card opens its cover and changes nothing")

        // Curation made elsewhere (the inspector) shows on the card, and the
        // badge keeps it across off and on.
        var curated = LerpRotationSelection(discovered: entries)
        curated.setLook(looksOf[1], on: false)
        curated.setLook(looksOf[2], on: false)
        view.show(shaders: shaders, selection: curated)
        check(card.summaryIsPartial && card.summary == "\(looksOf.count - 2) of \(looksOf.count) presets",
              "the card says it is hand-picked: \(card.summary ?? "nil")")
        _ = card.accessibilityPerformShowMenu()
        check(published?.isSwitchedOff(target) == true && !card.isOn, "the badge switches the shader off")
        _ = card.accessibilityPerformShowMenu()
        check(published.map { $0.shaderPlays(target) && !$0.isPicked(looksOf[1]) && $0.isPicked(looksOf[3]) } == true,
              "switching it back on brings back exactly the curated presets")

        // A preset ticked in a switched-off shader switches it back on.
        var off = published!
        off.setShader(target, on: false)
        off.setLook(looksOf[1], on: true)
        check(!off.isSwitchedOff(target) && off.plays(looksOf[1]) && !off.plays(looksOf[2]),
              "ticking a preset of a switched-off shader switches it on, keeping the other picks")

        // Search by a preset's name shows that shader's card, which opens wearing it.
        guard let preset = looksOf.dropFirst().first(where: { look in
            look.preset != nil && !target.localizedCaseInsensitiveContains(look.displayName)
        }) else { return check(false, "gallery: \(target) has no preset to search for") }
        view.setFilter(preset.displayName)
        view.layoutSubtreeIfNeeded()
        check(!card.isHidden && card.summary == "▸ " + preset.displayName,
              "searching a preset's name shows its shader's card, saying which: \(card.summary ?? "nil")")
        opened = nil
        _ = card.accessibilityPerformPress()
        check(opened == preset || opened?.shader == target, "a card found by a preset opens wearing it")
        view.setFilter(target)
        check(!card.isHidden && card.summary?.hasPrefix("▸") == false, "searching a shader's name shows its card")
        view.setFilter("")
        check(tiles.allSatisfy { !$0.isHidden }, "clearing the search brings every card back")

        // All / None act on the shaders on screen, at the shader level.
        view.show(shaders: shaders, selection: curated)
        view.setFilter(target)
        find("rotation-none", in: view, as: NSButton.self)?.performClick(nil)
        check(published.map { $0.isSwitchedOff(target) && $0.shaderPlays(other) } == true,
              "None switches off just the shaders the filter shows")
        find("rotation-all", in: view, as: NSButton.self)?.performClick(nil)
        check(published.map { !$0.isSwitchedOff(target) && !$0.isPicked(looksOf[1]) } == true,
              "All switches them back on, keeping their picks")
        view.setFilter("")
        check(find("rotation-none", in: view, as: NSButton.self)?.isEnabled == false,
              "None over every shader would empty the rotation, so it is off")

        // The floor: with one preset left, its shader's card is locked.
        let only = entries.first { $0.shader == other }!
        var last = LerpRotationSelection(discovered: entries)
        last.setLooks(entries.filter { $0 != only }, on: false)
        view.show(shaders: shaders, selection: last)
        let otherCard: RotationTile? = find("card:" + other, in: view)
        check(otherCard?.isLocked == true, "the card holding the last preset cannot be switched off")
        published = nil
        _ = otherCard?.accessibilityPerformShowMenu()
        check(published == nil, "a locked card does not change the rotation")
    }
}
