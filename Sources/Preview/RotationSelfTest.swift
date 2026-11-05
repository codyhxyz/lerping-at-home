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
/// - The gallery's cards, drawer and search do what the model says, and the
///   floor still holds.
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
              + "no back-to-back repeats, * reserved, Library cards/drawer/search/floor")
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

    /// `LERP_GALLERY_SNAPSHOT=<dir>`: the Library with a drawer open, and a
    /// search, as PNGs drawn with the stills the saver bundle ships — for
    /// looking at, not for checking.
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
        window.contentView = view
        var picked = LerpRotationSelection(discovered: entries)
        let open = shaders.first { [$0].rotationEntries().count >= 8 }?.name ?? shaders[0].name
        let looks = picked.looks(of: open)
        picked.setLooks(looks.dropFirst(4), on: false)
        picked.setShader(shaders[2].name, on: false)
        view.show(shaders: shaders, selection: picked)
        for entry in entries {
            guard let shader = shaders.named(entry.shader),
                  let url = stills.existingURL(entry: entry, source: shader.source),
                  let image = RotationThumbnails.decodedImage(at: url) else { continue }
            view.show(image: image, for: entry)
        }
        view.layoutSubtreeIfNeeded()
        if let card: RotationTile = find("card:" + open, in: view) {
            _ = card.accessibilityCustomActions()?.first?.handler?()
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

    static func gallery(_ extraSearch: [URL], _ check: (Bool, @autoclosure () -> String) -> Void) {
        let shaders = PreviewMain.makeLibrary(extraSearch).library.discover()
        let entries = shaders.rotationEntries()
        guard let target = shaders.first(where: { [$0].rotationEntries().count > 3 })?.name,
              let other = shaders.first(where: { $0.name != target })?.name else {
            return check(false, "gallery: the library needs a shader with more than three looks")
        }

        let view = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                       tileSize: RotationTile.size, showsRegenerate: false)
        var published: LerpRotationSelection?
        view.onChange = { published = $0 }
        view.show(shaders: shaders, selection: LerpRotationSelection(discovered: entries))
        view.layoutSubtreeIfNeeded()

        guard let card: RotationTile = find("card:" + target, in: view) else {
            return check(false, "gallery: no card for \(target)")
        }
        let looksOf = entries.filter { $0.shader == target }
        let tilesOf = looksOf.compactMap { find("entry:" + $0.key, in: view, as: RotationTile.self) }
        check(tilesOf.count == looksOf.count, "every look has a tile")
        check(tilesOf.allSatisfy(\.isHidden), "a closed Library shows cards, not looks")
        check(card.lookCount == looksOf.count && card.summary == "all \(looksOf.count) looks",
              "the card counts its looks: \(card.summary ?? "nil")")

        // Open the drawer.
        _ = card.accessibilityCustomActions()?.first?.handler?()
        view.layoutSubtreeIfNeeded()
        check(view.expanded == target, "the count pill opens the drawer")
        check(tilesOf.allSatisfy { !$0.isHidden }, "the drawer shows the shader's looks")
        if let drawer: NSView = find("drawer", in: view) {
            check(!drawer.isHidden && drawer.frame.minY >= card.frame.maxY, "the drawer opens under its card's row")
            check(tilesOf.allSatisfy { drawer.frame.contains($0.frame) }, "the drawer holds its looks")
        } else {
            check(false, "no drawer view")
        }

        // Curate two looks in the drawer, switch the shader off and on.
        _ = tilesOf[1].accessibilityPerformPress()
        _ = tilesOf[2].accessibilityPerformPress()
        check(published.map { !$0.isPicked(looksOf[1]) && !$0.isPicked(looksOf[2]) } == true,
              "a look's tile takes that look out")
        check(card.summaryIsPartial && card.summary == "\(looksOf.count - 2) of \(looksOf.count) looks",
              "the card says it is hand-picked: \(card.summary ?? "nil")")
        _ = card.accessibilityPerformPress()
        check(published?.isSwitchedOff(target) == true && !card.isOn, "the card switches the shader off")
        _ = card.accessibilityPerformPress()
        check(published.map { $0.shaderPlays(target) && !$0.isPicked(looksOf[1]) && $0.isPicked(looksOf[3]) } == true,
              "switching it back on brings back exactly the curated looks")

        // A look of a switched-off shader, clicked, switches it back on.
        _ = card.accessibilityPerformPress()
        _ = tilesOf[1].accessibilityPerformPress()
        check(published.map { !$0.isSwitchedOff(target) && $0.plays(looksOf[1]) && !$0.plays(looksOf[2]) } == true,
              "a click on a dimmed look switches its shader on, keeping the other picks")

        // Search shows looks, grouped, and no cards.
        view.setFilter(looksOf[1].displayName)
        view.layoutSubtreeIfNeeded()
        check(card.isHidden && !tilesOf[1].isHidden, "searching shows matching looks instead of cards")
        view.setFilter("")
        check(!card.isHidden, "clearing the search brings the cards back")

        // The floor: with one look left, its shader's card is locked.
        let only = entries.first { $0.shader == other }!
        var last = LerpRotationSelection(discovered: entries)
        last.setLooks(entries.filter { $0 != only }, on: false)
        view.show(shaders: shaders, selection: last)
        let otherCard: RotationTile? = find("card:" + other, in: view)
        check(otherCard?.isLocked == true, "the card holding the last look cannot be switched off")
        published = nil
        _ = otherCard?.accessibilityPerformPress()
        check(published == nil, "a locked card does not change the rotation")
    }
}
