import AppKit

/// The selector's shelves (`// lerp-category:`), run by `--rotation-selftest`.
///
/// - Every shader this repo ships names one of `LerpShaderCategory.shelves`, so
///   none of them falls through to Other by a typo or a forgotten line.
/// - The gallery draws a heading per shelf, in shelf order, each above its own
///   cards; a search hides the headings it emptied; the "+" card is last.
enum ShelfSelfTest {

    static func run(_ extraSearch: [URL]) {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if !ok { failures.append(what()) }
        }

        let shaders = PreviewMain.makeLibrary(extraSearch).library.discover()
        let unshelved = shaders.filter { $0.isBuiltIn && $0.category == LerpShaderCategory.other }
        check(unshelved.isEmpty, "built-in shaders with no known `// lerp-category:`: "
              + unshelved.map(\.name).joined(separator: ", "))

        let ordered = shaders.inShelfOrder()
        let ranks = ordered.map { LerpShaderCategory.shelves.firstIndex(of: $0.category) ?? Int.max }
        check(ranks == ranks.sorted(), "inShelfOrder is not shelf by shelf")

        let view = RotationGalleryView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                       tileSize: RotationTile.size)
        view.onOpen = { _ in }
        view.onNew = {}
        view.show(shaders: shaders, selection: LerpRotationSelection(discovered: shaders.rotationEntries()))
        view.layoutSubtreeIfNeeded()

        func heading(_ name: String) -> NSTextField? {
            RotationSelfTest.find("shelf:" + name, in: view)
        }
        func card(_ name: String) -> RotationTile? {
            RotationSelfTest.find("card:" + name, in: view)
        }
        let used = LerpShaderCategory.shelves.filter { shelf in ordered.contains { $0.category == shelf } }
        let tops = used.compactMap { heading($0).flatMap { $0.isHidden ? nil : $0.frame.minY } }
        check(tops.count == used.count, "a visible heading for each of \(used): \(tops.count)")
        check(tops == tops.sorted(), "headings are in shelf order, top to bottom")
        check(view.visibleShaders() == ordered.map(\.name), "cards are laid out shelf by shelf")

        // Each card sits below its own heading and above the next one.
        for (i, shelf) in used.enumerated() {
            guard let top = heading(shelf)?.frame.maxY else { continue }
            let next = i + 1 < used.count ? heading(used[i + 1])?.frame.minY ?? .infinity : .infinity
            for shader in ordered where shader.category == shelf {
                guard let y = card(shader.name)?.frame.minY else { continue }
                check(y > top && y < next, "\(shader.name) is not under its \(shelf) heading")
            }
        }

        // The "+" card closes the grid, under Other.
        if let plus: NSView = RotationSelfTest.find("new-look-card", in: view),
           let other = heading(LerpShaderCategory.other), let last = ordered.last.flatMap({ card($0.name) }) {
            check(!other.isHidden && plus.frame.minY > other.frame.maxY && plus.frame.minY >= last.frame.minY,
                  "the + card is last, under Other")
        } else {
            check(false, "no + card or Other heading")
        }

        // A search keeps only the shelves it left something on.
        if let fractal = ordered.first(where: { $0.category == "Fractals" }) {
            view.setFilter(fractal.name)
            view.layoutSubtreeIfNeeded()
            let shown = used.filter { heading($0)?.isHidden == false }
            check(shown.contains("Fractals") && !shown.contains("Splats"),
                  "searching \(fractal.name) shows only the shelves it matched: \(shown)")
            view.setFilter("")
        }

        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(("FAIL  " + failure + "\n").data(using: .utf8)!) }
            PreviewMain.fail("shelf self-test: \(failures.count) check\(failures.count == 1 ? "" : "s") failed")
        }
        print("OK    shelves: every shipped shader on a known shelf, headings in order over their cards, "
              + "search hides emptied shelves, + last")
    }
}
