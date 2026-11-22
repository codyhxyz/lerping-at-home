import AppKit

struct ImportReviewMatch: Hashable {
    let entry: LerpRotationEntry
    let sourceDigest: String

    /// Recheck on the explicit action: disk can change while the sheet is up.
    func matches(_ shader: LerpShader) -> Bool {
        guard shader.name == entry.shader else { return false }
        return PortableReference.digest(Data(shader.source.utf8)) == sourceDigest
    }
}

struct ImportReviewSummary {
    struct Item {
        var title: String
        var detail: String
        var match: ImportReviewMatch?
    }

    var title: String
    var authors: [String] = []
    var lineage: String?
    var license: String?
    var items: [Item]

    var matches: [ImportReviewMatch] {
        var seen = Set<ImportReviewMatch>()
        return items.compactMap(\.match).filter { seen.insert($0).inserted }
    }
}

/// Review never fetches, installs, or runs incoming content. Safe actions only
/// refer to exact looks already in the installed catalog.
enum ImportReviewRequest {
    enum ReviewError: LocalizedError {
        case invalidLink, unsupportedFile, invalidArchive, noLongerAvailable, rotationNotSaved

        var errorDescription: String? {
            switch self {
            case .invalidLink: return "This is not a valid Lerping v1 share link."
            case .unsupportedFile: return "Choose a .lerplook, .lerpplaylist, or .lerppiece file."
            case .invalidArchive: return "The Piece archive does not match its source or asset references."
            case .noLongerAvailable: return "An installed look changed or disappeared. Reopen the review to check it again."
            case .rotationNotSaved: return "The rotation could not be saved."
            }
        }
    }

    static let extensions = ["lerplook", "lerpplaylist", "lerppiece"]

    private static func reference(for url: URL) -> PortableReference? {
        PortableLinks.parse(url.absoluteString) ?? PortableLinks.parsePostcard(url.absoluteString)
    }

    static func accepts(_ url: URL) -> Bool {
        if url.isFileURL { return extensions.contains(url.pathExtension.lowercased()) }
        return url.scheme?.lowercased() == "lerp" || reference(for: url) != nil
    }

    static func review(_ url: URL, shaders: [LerpShader]) throws -> ImportReviewSummary {
        let index = LocalIndex(shaders)
        if !url.isFileURL {
            guard let ref = reference(for: url) else { throw ReviewError.invalidLink }
            switch index.records[ref] {
            case .piece(let piece): return index.summary(piece)
            case .look(let look): return index.summary(look)
            case nil: return ImportReviewSummary(title: "Review Share Link", items: [index.unavailable(ref)])
            }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "lerplook":
            return index.summary(try PortableLook.decode(AssetSafety.readFile(url, limit: 1_048_576)))
        case "lerpplaylist":
            let playlist = try PortablePlaylist.decode(AssetSafety.readFile(url, limit: 1_048_576))
            return ImportReviewSummary(title: playlist.title, items: playlist.looks.map { ref in
                if case .look(let look) = index.records[ref] { return index.lookItem(look) }
                return index.unavailable(ref)
            })
        case "lerppiece":
            let archive = try AssetSafety.preflightPieceArchive(at: url)
            guard let json = try archive.decodedMember("piece.json", limit: 1_048_576),
                  let source = try archive.decodedMember("piece.metal", limit: 2_097_152) else { throw ReviewError.invalidArchive }
            let piece = try PortablePiece.decode(json)
            guard piece.source == "blob:sha256:\(PortableReference.digest(source))",
                  Set(piece.assets.keys) == archive.paths.subtracting(["piece.json", "piece.metal"]) else {
                throw ReviewError.invalidArchive
            }
            for (path, asset) in piece.assets {
                guard let bytes = try archive.decodedMember(path),
                      PortableReference.digest(bytes) == asset.sha256 else { throw ReviewError.invalidArchive }
            }
            return index.summary(piece)
        default: throw ReviewError.unsupportedFile
        }
    }

    private struct LocalIndex {
        let bySource: [String: PortableInstalledPiece]
        let byReference: [PortableReference: PortableInstalledPiece]
        let records: [PortableReference: PortableLineage.Record]

        init(_ shaders: [LerpShader]) {
            let pieces = shaders.compactMap { try? PortableInstalledPiece($0) }
            var sources: [String: PortableInstalledPiece] = [:]
            var refs: [PortableReference: PortableInstalledPiece] = [:]
            var records: [PortableReference: PortableLineage.Record] = [:]
            // A portable source alone does not distinguish two installed copies.
            for group in Dictionary(grouping: pieces, by: { $0.piece.source }).values where group.count == 1 {
                let local = group[0]
                sources[local.piece.source] = local
                refs[local.reference] = local
                records[local.reference] = .piece(local.piece)
                for entry in [local.shader].rotationEntries() {
                    guard let look = try? local.look(for: entry), let ref = try? look.reference() else { continue }
                    records[ref] = .look(look)
                }
            }
            bySource = sources
            byReference = refs
            self.records = records
        }

        func summary(_ piece: PortablePiece) -> ImportReviewSummary {
            let local = piece.assets.isEmpty ? bySource[piece.source] : nil
            let title = piece.title ?? local?.shader.displayName ?? "Piece"
            let match = local.map { ImportReviewMatch(entry: LerpRotationEntry(shader: $0.shader.name, preset: nil),
                                                     sourceDigest: $0.sourceDigest) }
            return ImportReviewSummary(title: title, authors: piece.authors ?? local?.metadata.authors ?? [],
                                       lineage: lineage(piece.remixedFrom ?? local?.metadata.remixedFrom),
                                       license: piece.license ?? local?.metadata.license,
                                       items: [item(title, match, missing: "No exact installed source-only Piece.")])
        }

        func summary(_ look: PortableLook) -> ImportReviewSummary {
            ImportReviewSummary(title: look.title, authors: look.authors, lineage: lineage(look.remixedFrom),
                                license: look.license, items: [lookItem(look)])
        }

        func lookItem(_ look: PortableLook) -> ImportReviewSummary.Item {
            guard let local = byReference[look.piece] else {
                return item(look.title, nil, missing: "The exact Piece is not installed.")
            }
            guard let entry = try? local.entry(matching: look) else {
                return item(look.title, nil, missing: "The tuning or preset does not match a saved look.")
            }
            return item(look.title, ImportReviewMatch(entry: entry, sourceDigest: local.sourceDigest))
        }

        func unavailable(_ ref: PortableReference) -> ImportReviewSummary.Item {
            item("\(ref.kind.rawValue.capitalized) · \(ref.sha256.prefix(12))…", nil,
                 missing: "Missing locally. No download or installation was attempted.")
        }

        private func item(_ title: String, _ match: ImportReviewMatch?, missing: String = "") -> ImportReviewSummary.Item {
            .init(title: title, detail: match.map { "Installed · \($0.entry.key)" } ?? missing, match: match)
        }

        private func lineage(_ parent: PortableReference?) -> String? {
            guard let parent else { return nil }
            let resolution = PortableLineage.resolve(from: parent) { records[$0] }
            var trail = resolution.credits.map { credit in
                let who = credit.authors.isEmpty ? "uncredited" : credit.authors.joined(separator: ", ")
                return "\(credit.reference.kind.rawValue) \(credit.reference.sha256.prefix(12))… (\(who))"
            }
            switch resolution.end {
            case .root: break
            case .missing(let ref): trail.append("\(ref.kind.rawValue) \(ref.sha256.prefix(12))… (not installed)")
            case .cycle: trail.append("cycle detected")
            case .hopLimit: trail.append("more ancestors not shown")
            }
            return "Remixed from " + trail.joined(separator: " → ")
        }
    }
}

/// A read-only review; neither opening the sheet nor closing it writes anything.
enum ImportSheet {
    enum Action { case close, preview(ImportReviewMatch), add([ImportReviewMatch]) }

    static func present(_ summary: ImportReviewSummary, on window: NSWindow, then done: @escaping (Action) -> Void) {
        let alert = NSAlert()
        alert.messageText = placard(summary.title, limit: 120)
        alert.informativeText = "Quarantine review. Only matching installed looks can be used. Nothing from this import will be installed or run."
        alert.addButton(withTitle: "Close").keyEquivalent = "\r"
        let matches = summary.matches
        if !matches.isEmpty {
            alert.addButton(withTitle: matches.count == 1 ? "Preview Safe Look" : "Preview First Safe Look")
            alert.addButton(withTitle: "Add Eligible Looks to Rotation")
        }
        let text = (["Artist: " + (summary.authors.isEmpty ? "Not provided" : summary.authors.joined(separator: ", ")),
                     summary.lineage, "License: " + (summary.license ?? "Not provided"), "",
                     "\(matches.count) eligible · \(summary.items.filter { $0.match == nil }.count) unavailable"]
                    .compactMap { $0 }.map { placard($0, limit: 300) }
                    + summary.items.map { "\n\(placard($0.title, limit: 120))\n\(placard($0.detail, limit: 160))" })
                    .joined(separator: "\n")
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 460, height: 180)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isRichText = false
            view.isAutomaticLinkDetectionEnabled = false
            view.textContainerInset = NSSize(width: 9, height: 9)
            view.font = .systemFont(ofSize: 12)
            view.string = text
            view.scrollToBeginningOfDocument(nil)
        }
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { response in
            if let first = matches.first, response == .alertSecondButtonReturn { done(.preview(first)) }
            else if !matches.isEmpty, response == .alertThirdButtonReturn { done(.add(matches)) }
            else { done(.close) }
        }
    }

    static func preview(_ entry: LerpRotationEntry, of shader: LerpShader, on window: NSWindow,
                        then done: @escaping () -> Void) throws {
        let frame = NSRect(x: 0, y: 0, width: 460, height: 295)
        guard let render = LerpMetalView(frame: frame, mode: .still) else { throw PreviewError.unavailable }
        render.config = LerpMetalView.Config(shaderName: nil, renderScale: 1, shuffleInterval: .infinity)
        guard render.show(entry, of: shader) else { throw PreviewError.unavailable }
        let alert = NSAlert()
        alert.messageText = "Safe Preview · \(entry.key)"
        alert.informativeText = "A preview of the installed look. Your workspace and rotation are unchanged."
        alert.accessoryView = render
        alert.addButton(withTitle: "Done")
        alert.beginSheetModal(for: window) { _ in
            render.stop()
            done()
        }
        render.start()
        render.renderOnce()
    }

    private enum PreviewError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The installed look could not be rendered." }
    }

    /// Keep untrusted placard text on one line and prevent bidi formatting
    /// controls from impersonating the sheet’s own labels or status.
    private static func placard(_ raw: String, limit: Int) -> String {
        let scalars = raw.unicodeScalars.prefix(limit).map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return String(scalar)
        }
        return scalars.joined()
    }
}
