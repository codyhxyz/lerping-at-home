import AppKit
import CryptoKit
import Darwin
import zlib

struct ImportReviewReference: Hashable {
    enum Kind: String, Decodable {
        case piece, look, playlist
        var fileExtension: String { "lerp" + rawValue }
    }

    let kind: Kind
    let digest: String
    var label: String { "\(kind.rawValue.capitalized) · \(digest.prefix(12))…" }
    var contentID: String { "\(kind.rawValue):sha256:\(digest)" }

    init?(kind: Kind, digest: String) {
        guard Self.isDigest(digest) else { return nil }
        self.kind = kind
        self.digest = digest
    }

    init?(contentID: String) {
        let parts = contentID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "sha256", let kind = Kind(rawValue: String(parts[0])) else { return nil }
        self.init(kind: kind, digest: String(parts[2]))
    }

    init?(url: URL) {
        let prefix = "lerp://open/v1/"
        let text = url.absoluteString
        guard text.hasPrefix(prefix) else { return nil }
        let parts = text.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = Kind(rawValue: String(parts[0])) else { return nil }
        self.init(kind: kind, digest: String(parts[1]))
    }

    var url: URL { URL(string: "lerp://open/v1/\(kind.rawValue)/\(digest)")! }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func sha256(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: data).flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
    }
}

struct ImportReviewMatch: Hashable {
    let entry: LerpRotationEntry
    let sourceDigest: String

    /// Recheck on the explicit action: disk can change while the sheet is up.
    func matches(_ shader: LerpShader) -> Bool {
        guard shader.name == entry.shader else { return false }
        if let preset = entry.preset, shader.preset(named: preset)?.name != preset { return false }
        return ImportReviewReference.sha256(Data(shader.source.utf8)) == sourceDigest
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

/// Presentation-only v1 reader. Incoming records never become shaders or
/// defaults: a match can point only at a look already installed in the library.
enum ImportReviewRequest {
    enum ReviewError: LocalizedError {
        case invalidLink, unsupportedFile, invalidFile, fileTooLarge, noLongerAvailable, rotationNotSaved

        var errorDescription: String? {
            switch self {
            case .invalidLink: return "This is not a valid Lerping v1 share link."
            case .unsupportedFile: return "Choose a .lerplook, .lerpplaylist, or .lerppiece file."
            case .invalidFile: return "This file is not a valid portable Lerping v1 record of the expected kind."
            case .fileTooLarge: return "The import review accepts regular files up to 1 MB, or Piece archives up to 64 MB."
            case .noLongerAvailable: return "An installed look changed or disappeared. Reopen the review to check it again."
            case .rotationNotSaved: return "The rotation could not be saved."
            }
        }
    }

    // Only fields used by the placard or by the local-match policy are decoded.
    // Tuning and asset values never reach the renderer or a filesystem path.
    private struct Record: Decodable {
        let v: Int
        let kind: ImportReviewReference.Kind
        let title: String?
        let authors: [String]?
        let remixedFrom: String?
        let license: String?
        let abi: String?
        let source: String?
        let piece: String?
        let preset: String?
        let looks: [String]?
        let hasAssets: Bool
        let hasTuning: Bool

        private enum CodingKeys: String, CodingKey {
            case v, kind, title, authors, remixedFrom, license, abi, source, piece, preset, looks, assets, tuning
        }
        private struct Field: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            v = try box.decode(Int.self, forKey: .v)
            kind = try box.decode(ImportReviewReference.Kind.self, forKey: .kind)
            title = try box.decodeIfPresent(String.self, forKey: .title)
            authors = try box.decodeIfPresent([String].self, forKey: .authors)
            remixedFrom = try box.decodeIfPresent(String.self, forKey: .remixedFrom)
            license = try box.decodeIfPresent(String.self, forKey: .license)
            abi = try box.decodeIfPresent(String.self, forKey: .abi)
            source = try box.decodeIfPresent(String.self, forKey: .source)
            piece = try box.decodeIfPresent(String.self, forKey: .piece)
            preset = kind == .look ? try box.decode(String?.self, forKey: .preset) : nil
            looks = try box.decodeIfPresent([String].self, forKey: .looks)
            hasAssets = kind == .piece ? !(try box.nestedContainer(keyedBy: Field.self, forKey: .assets).allKeys.isEmpty) : false
            hasTuning = kind == .look ? !(try box.nestedContainer(keyedBy: Field.self, forKey: .tuning).allKeys.isEmpty) : false
        }
    }

    static let extensions = ["lerplook", "lerpplaylist", "lerppiece"]
    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "lerp" || (url.isFileURL && extensions.contains(url.pathExtension.lowercased()))
    }

    /// Canonical v1 recipe for a saved look with no portable tuning overrides.
    /// The link is a reference, not an upload; only a recipient with the exact
    /// saved shader and preset can reconstruct it from their local library.
    static func shareLink(for entry: LerpRotationEntry, in shader: LerpShader) -> URL? {
        guard [shader].rotationEntries().contains(entry) else { return nil }
        let digest = ImportReviewReference.sha256(Data(shader.source.utf8))
        return lookReference(entry, piece: pieceReference(digest)).url
    }

    static func review(_ url: URL, shaders: [LerpShader]) throws -> ImportReviewSummary {
        if !url.isFileURL {
            guard let ref = ImportReviewReference(url: url) else { throw ReviewError.invalidLink }
            let index = LocalIndex(shaders)
            let item = index.item(ref)
            let local = item.match.flatMap { index.byName[$0.entry.shader] }
            return ImportReviewSummary(title: item.match == nil ? "Review Share Link" : item.title,
                                       authors: local?.authors ?? [], license: local?.license, items: [item])
        }
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw ReviewError.unsupportedFile }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let isPiece = ext == "lerppiece"
        let archive = try readFile(url, limit: isPiece ? 64 * 1_048_576 : 1_048_576)
        let json = isPiece ? try zipMember("piece.json", from: archive, limit: 1_048_576) : archive
        guard let record = try? JSONDecoder().decode(Record.self, from: json),
              record.v == 1, ext == record.kind.fileExtension else { throw ReviewError.invalidFile }
        if isPiece {
            let blob = try zipMember("piece.metal", from: archive, limit: 2 * 1_048_576)
            guard record.source == "blob:sha256:" + ImportReviewReference.sha256(blob) else { throw ReviewError.invalidFile }
        }
        return try review(record, index: LocalIndex(shaders))
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              (0...Int64(limit)).contains(info.st_size) else { throw ReviewError.fileTooLarge }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ReviewError.fileTooLarge }
        return data
    }

    /// Read only a named ZIP32 member into a bounded buffer. No archive path is
    /// opened or written; assets are never read. The UI checks the JSON and
    /// source CRC and digest, but does not attest the whole archive for install.
    private static func zipMember(_ name: String, from archive: Data, limit: Int) throws -> Data {
        try archive.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func u16(_ offset: Int) -> Int { Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) }
            func u32(_ offset: Int) -> Int { Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            let invalid = ReviewError.invalidFile
            let end = bytes.count - 22
            guard end >= 0, let footer = stride(from: end, through: max(0, end - 65_535), by: -1).first(where: {
                u32($0) == 0x06054b50 && u16($0 + 20) == end - $0
            }), u16(footer + 4) == 0, u16(footer + 6) == 0 else { throw invalid }
            let count = u16(footer + 10), central = u32(footer + 16)
            guard (2...6).contains(count), u16(footer + 8) == count, central <= footer,
                  u32(footer + 12) == footer - central else { throw invalid }
            var offset = central
            var result: Data?
            for _ in 0..<count {
                guard offset + 46 <= footer, u32(offset) == 0x02014b50 else { throw invalid }
                let path = offset + 46, extra = path + u16(offset + 28)
                let next = extra + u16(offset + 30) + u16(offset + 32)
                guard next <= footer else { throw invalid }
                defer { offset = next }
                guard bytes[path..<extra].elementsEqual(name.utf8) else { continue }
                let flags = u16(offset + 8), method = u16(offset + 10), local = u32(offset + 42)
                let packed = u32(offset + 20), length = u32(offset + 24)
                guard result == nil, flags & ~0x80e == 0, u16(offset + 34) == 0,
                      (1...limit).contains(length), packed > 0, local + 30 <= central,
                      u32(local) == 0x04034b50, u16(local + 6) == flags, u16(local + 8) == method else { throw invalid }
                let localPath = local + 30, payload = localPath + u16(local + 26)
                let start = payload + u16(local + 28)
                guard start + packed <= central, bytes[localPath..<payload].elementsEqual(name.utf8) else { throw invalid }
                let input = bytes.bindMemory(to: UInt8.self).baseAddress! + start
                let data: Data
                if method == 0, length == packed {
                    data = Data(bytes: input, count: length)
                } else if method == 8 {
                    var inflater = z_stream()
                    guard inflateInit2_(&inflater, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid }
                    defer { inflateEnd(&inflater) }
                    var buffer = Data(count: length + 1)
                    let status = buffer.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
                        inflater.next_in = UnsafeMutablePointer(mutating: input)
                        inflater.avail_in = UInt32(packed)
                        inflater.next_out = out.bindMemory(to: UInt8.self).baseAddress!
                        inflater.avail_out = UInt32(length + 1)
                        return inflate(&inflater, Z_FINISH)
                    }
                    guard status == Z_STREAM_END, inflater.total_out == length, inflater.total_in == packed else { throw invalid }
                    buffer.removeLast()
                    data = buffer
                } else { throw invalid }
                let checksum = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    crc32(0, raw.bindMemory(to: UInt8.self).baseAddress, UInt32(length))
                }
                guard checksum == u32(offset + 16) else { throw invalid }
                result = data
            }
            guard offset == footer, let result else { throw invalid }
            return result
        }
    }

    private static func review(_ record: Record, index: LocalIndex) throws -> ImportReviewSummary {
        let items: [ImportReviewSummary.Item]
        switch record.kind {
        case .piece:
            let prefix = "blob:sha256:"
            guard record.abi == "lerp-metal-1", let source = record.source, source.hasPrefix(prefix),
                  ImportReviewReference.isDigest(String(source.dropFirst(prefix.count))) else { throw ReviewError.invalidFile }
            let installed = index.bySource[String(source.dropFirst(prefix.count))] ?? []
            let match = !record.hasAssets && installed.count == 1 ? installed.first?.match(preset: nil) : nil
            items = [item(title: record.title ?? "Piece", match: match,
                          missing: record.hasAssets ? "Required asset blobs are not available for review." : "No unique installed source match.")]
        case .look:
            guard let title = record.title, record.authors != nil,
                  let ref = record.piece.flatMap(ImportReviewReference.init(contentID:)), ref.kind == .piece else { throw ReviewError.invalidFile }
            let match = record.hasTuning ? nil : index.byPiece[ref]?.match(preset: record.preset)
            items = [item(title: title, match: match, missing: record.hasTuning
                          ? "Contains custom tuning; not an installed saved look." : "Missing \(ref.label) or its preset.")]
        case .playlist:
            guard record.title != nil, let references = record.looks, (1...100).contains(references.count),
                  Set(references).count == references.count else { throw ReviewError.invalidFile }
            items = try references.map { value in
                guard let ref = ImportReviewReference(contentID: value), ref.kind == .look else { throw ReviewError.invalidFile }
                return index.item(ref)
            }
        }
        let lineage: String?
        if let raw = record.remixedFrom {
            guard let parent = ImportReviewReference(contentID: raw), parent.kind != .playlist else { throw ReviewError.invalidFile }
            let item = index.item(parent)
            let authors = item.match.flatMap { index.byName[$0.entry.shader]?.authors } ?? []
            lineage = "Remixed from \(item.title) by \(authors.isEmpty ? "an unverified artist" : authors.joined(separator: ", "))."
        } else { lineage = nil }
        return ImportReviewSummary(title: record.title ?? record.kind.rawValue.capitalized,
                                   authors: record.authors ?? [], lineage: lineage,
                                   license: record.license, items: items)
    }

    private static func item(title: String, match: ImportReviewMatch?, missing: String) -> ImportReviewSummary.Item {
        ImportReviewSummary.Item(title: title, detail: match.map { "Installed · \($0.entry.key)" } ?? missing, match: match)
    }

    private struct LocalPiece {
        let shader: LerpShader
        let digest: String

        // Only for display; the exact source reference is what admits a local look.
        private func values(for key: String) -> [String] {
            shader.source.split(separator: "\n").compactMap {
                LerpParamParser.directiveBody($0, key)
            }
        }
        var authors: [String] { values(for: "lerp-author:") }
        var license: String? { values(for: "lerp-license:").first }

        func match(preset: String?) -> ImportReviewMatch? {
            if let preset, shader.preset(named: preset)?.name != preset { return nil }
            let entry = LerpRotationEntry(shader: shader.name, preset: preset)
            return ImportReviewMatch(entry: entry, sourceDigest: digest)
        }
    }

    private struct LocalIndex {
        let bySource: [String: [LocalPiece]]
        let byName: [String: LocalPiece]
        let byPiece: [ImportReviewReference: LocalPiece]
        let byLook: [ImportReviewReference: ImportReviewMatch]

        init(_ shaders: [LerpShader]) {
            let pieces = shaders.map { LocalPiece(shader: $0, digest: ImportReviewReference.sha256(Data($0.source.utf8))) }
            bySource = Dictionary(grouping: pieces, by: \.digest)
            byName = Dictionary(pieces.map { ($0.shader.name, $0) }, uniquingKeysWith: { first, _ in first })
            var piecesByRef: [ImportReviewReference: LocalPiece] = [:]
            var looks: [ImportReviewReference: ImportReviewMatch] = [:]
            for local in pieces {
                let piece = pieceReference(local.digest)
                if bySource[local.digest]?.count == 1 { piecesByRef[piece] = local }
                for entry in [local.shader].rotationEntries() {
                    looks[lookReference(entry, piece: piece)] = local.match(preset: entry.preset)
                }
            }
            byPiece = piecesByRef
            byLook = looks
        }

        func item(_ ref: ImportReviewReference) -> ImportReviewSummary.Item {
            let match = byLook[ref] ?? byPiece[ref]?.match(preset: nil)
            return ImportReviewRequest.item(title: match.map { lookTitle($0.entry) } ?? ref.label, match: match,
                                            missing: "Missing locally. No download or installation was attempted.")
        }
    }

    private static func lookTitle(_ entry: LerpRotationEntry) -> String {
        entry.preset.map { "\(entry.shader) · \($0)" } ?? entry.shader
    }

    // The key set is fixed ASCII and the values are strings, empty collections,
    // null, or the integer 1. This has no floating point or user-supplied keys.
    private static func reference(_ kind: ImportReviewReference.Kind, of fields: [String: Any]) -> ImportReviewReference {
        let bytes = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        return ImportReviewReference(kind: kind, digest: ImportReviewReference.sha256(bytes))!
    }

    private static func pieceReference(_ digest: String) -> ImportReviewReference {
        reference(.piece, of: ["v": 1, "kind": "piece", "abi": "lerp-metal-1",
                               "assets": [String: String](), "source": "blob:sha256:\(digest)"])
    }

    private static func lookReference(_ entry: LerpRotationEntry, piece: ImportReviewReference) -> ImportReviewReference {
        reference(.look, of: ["v": 1, "kind": "look", "piece": piece.contentID, "title": lookTitle(entry),
                              "preset": entry.preset as Any? ?? NSNull(), "tuning": [String: String](), "authors": [String]()])
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
