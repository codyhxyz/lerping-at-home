import Darwin
import Foundation
import Security
import zlib

public struct AssetSafetyLimits: Sendable {
    public let maxArchiveBytes: Int
    public let maxDecodedBytes: Int
    public let maxSplats: Int
    public let maxPathKeyframes: Int
    // A path has seven floats per key plus its time and modest JSON overhead.
    var maxPathBytes: Int { maxPathKeyframes * 1024 }

    public static let portableIngress = Self(maxArchiveBytes: 64 * 1024 * 1024, maxDecodedBytes: 128 * 1024 * 1024,
                                             maxSplats: 1_000_000, maxPathKeyframes: 4_096)
    static let bundledLegacy = Self(maxArchiveBytes: 256 * 1024 * 1024, maxDecodedBytes: 512 * 1024 * 1024,
                                    maxSplats: 8_000_000, maxPathKeyframes: 16_384)
}

public enum AssetSafety {
    private static let portable = AssetSafetyLimits.portableIngress

    public static let assetPaths: Set<String> = [
        "assets/capture.lsplat", "assets/capture.path.json", "assets/image.png", "assets/image.depth.png"
    ]

    public static func validateAssetPaths(_ paths: Set<String>) throws {
        let capture = paths.contains("assets/capture.lsplat")
        let image = paths.contains("assets/image.png")
        guard paths.isSubset(of: assetPaths), !(capture && image),
              !paths.contains("assets/capture.path.json") || capture,
              !paths.contains("assets/image.depth.png") || image else {
            throw PortableArtifactError.invalid("Unexpected or incompatible Piece asset paths")
        }
    }

    /// Check the opened file before reading it, and cap the read even if the
    /// file grows or is replaced behind the URL while it is being read.
    static func readFile(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL else { throw PortableArtifactError.invalid("Asset must be a local file") }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { throw PortableArtifactError.invalid("Unable to open asset file") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw PortableArtifactError.invalid("Asset must be a regular file")
        }
        let length = Int(info.st_size)
        guard length <= limit else { throw PortableArtifactError.invalid("Asset file exceeds \(limit) bytes") }
        let data = try file.read(upToCount: length) ?? Data()
        guard data.count == length, try file.read(upToCount: 1)?.isEmpty != false else {
            throw PortableArtifactError.invalid("Asset file changed while it was read")
        }
        return data
    }

    /// Larger local assets must be a catalogued checkout capture or a regular
    /// file sealed in this app/saver's own code signature. A bare external URL
    /// cannot claim checkout provenance, even if its basename matches.
    static func readSplatFile(_ location: LerpSplatAssets.Location, isPath: Bool = false) throws -> (Data, AssetSafetyLimits) {
        let url = location.url
        let bundle = Bundle(for: ShaderLibrary.self)
        if let resources = bundle.resourceURL,
           ["app", "saver"].contains(bundle.bundleURL.pathExtension) {
            let directory = resources.appendingPathComponent("Splats").standardizedFileURL
            let file = url.standardizedFileURL
            if file.deletingLastPathComponent() == directory, file.resolvingSymlinksInPath() == file,
               let info = try? file.resourceValues(forKeys: [.isRegularFileKey]), info.isRegularFile == true {
                var code: SecStaticCode?
                let flags = SecCSFlags(rawValue: 0)
                if SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, flags, &code) == errSecSuccess,
                   let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources)), nil) == errSecSuccess {
                    let limits = AssetSafetyLimits.bundledLegacy
                    let data = try readFile(file, limit: isPath ? limits.maxPathBytes : limits.maxArchiveBytes)
                    let path = "Resources/Splats/" + file.lastPathComponent
                    guard SecCodeValidateFileResource(code, path as CFString, data as CFData, flags) == errSecSuccess else {
                        throw PortableArtifactError.invalid("Splat file does not match its bundle resource seal")
                    }
                    return (data, limits)
                }
            }
        }
        let limits: AssetSafetyLimits
        if location.cataloguedCheckout, url.resolvingSymlinksInPath().path == url.path,
           (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            limits = .bundledLegacy
        } else {
            limits = portable
        }
        return (try readFile(url, limit: isPath ? limits.maxPathBytes : limits.maxArchiveBytes), limits)
    }

    static func splatPayloadSize(count: Int, positionBytes: Int, coefficients: Int, paletteCount: Int,
                                 limits: AssetSafetyLimits = .portableIngress) throws -> Int {
        // SH orders 1, 2 and 3 have 3, 8 and 15 view-dependent coefficients.
        let withSH = [3, 8, 15].contains(coefficients)
        guard (1...limits.maxSplats).contains(count), positionBytes == 6 || positionBytes == 12,
              (coefficients == 0 && paletteCount == 0) || (withSH && (1...count).contains(paletteCount)) else {
            throw PortableArtifactError.invalid("Invalid splat count or palette layout")
        }
        let bytes = count * (positionBytes + 11) + (withSH ? count * 3 + paletteCount * coefficients * 3 : 0)
        guard bytes <= limits.maxDecodedBytes else { throw PortableArtifactError.invalid("Splat payload exceeds decoded byte limit") }
        return bytes
    }

    /// LSPL and ZIP both use raw DEFLATE, without a zlib wrapper. Stop at the
    /// known output size instead of letting a decompressor grow its buffer.
    static func inflateRaw(_ data: Data, range: Range<Int>, expectedBytes: Int,
                           limits: AssetSafetyLimits = .portableIngress) throws -> Data {
        guard (0...limits.maxDecodedBytes).contains(expectedBytes), range.lowerBound >= 0, range.upperBound <= data.count,
              !range.isEmpty, range.count <= limits.maxArchiveBytes else {
            throw PortableArtifactError.invalid("Invalid compressed or decoded asset size")
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PortableArtifactError.invalid("Unable to start asset decompression")
        }
        defer { inflateEnd(&stream) }
        // One stack byte allows zlib to consume a pending end marker after
        // filling the exact buffer, but never to expand the output allocation.
        var output = Data(count: expectedBytes)
        let status: Int32 = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                let start = input.bindMemory(to: UInt8.self).baseAddress! + range.lowerBound
                stream.next_in = UnsafeMutablePointer(mutating: start)
                stream.avail_in = UInt32(range.count)
                if expectedBytes > 0 {
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress!
                    stream.avail_out = UInt32(expectedBytes)
                    let status = inflate(&stream, Z_FINISH)
                    if status != Z_BUF_ERROR || stream.avail_out != 0 { return status }
                }
                var sentinel: UInt8 = 0
                return withUnsafeMutablePointer(to: &sentinel) { byte in
                    stream.next_out = byte
                    stream.avail_out = 1
                    return inflate(&stream, Z_FINISH)
                }
            }
        }
        guard status == Z_STREAM_END, stream.total_out == expectedBytes, stream.total_in == range.count else {
            throw PortableArtifactError.invalid("Truncated, oversized or trailing compressed asset data")
        }
        return output
    }

    /// A preflighted ZIP32 archive. Read only the validated members through
    /// this value; there is no filesystem extraction or path rewriting.
    public struct PieceArchive: Sendable {
        fileprivate struct Member: Sendable {
            let path: String
            let method: Int
            let crc: UInt32
            let decodedSize: Int
            let range: Range<Int>
        }

        private let data: Data
        private let members: [String: Member]

        fileprivate init(data: Data, members: [String: Member]) {
            self.data = data
            self.members = members
        }

        public var paths: Set<String> { Set(members.keys) }

        public func decodedMember(_ path: String, limit: Int? = nil) throws -> Data? {
            guard let member = members[path] else { return nil }
            if let limit, member.decodedSize > limit {
                throw PortableArtifactError.invalid("Piece archive member exceeds \(limit) bytes")
            }
            let result: Data
            if member.method == 0 {
                let start = data.startIndex
                result = data.subdata(in: (start + member.range.lowerBound)..<(start + member.range.upperBound))
            } else {
                result = try AssetSafety.inflateRaw(data, range: member.range, expectedBytes: member.decodedSize)
            }
            let crc = result.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                crc32(0, bytes.bindMemory(to: UInt8.self).baseAddress, UInt32(bytes.count))
            }
            guard crc == member.crc else { throw PortableArtifactError.invalid("Invalid ZIP member checksum") }
            return result
        }
    }

    public static func preflightPieceArchive(at url: URL) throws -> PieceArchive {
        try preflightPieceArchive(readFile(url, limit: portable.maxArchiveBytes))
    }

    public static func preflightPieceArchive(_ data: Data) throws -> PieceArchive {
        guard (22...portable.maxArchiveBytes).contains(data.count) else {
            throw PortableArtifactError.invalid("Invalid Piece archive size")
        }
        let members = try data.withUnsafeBytes { try ZIP($0).preflight() }
        return PieceArchive(data: data, members: members)
    }

    /// Read central directory metadata and match each local header. Only
    /// single-disk ZIP32, stored or raw DEFLATE, with regular file members.
    private struct ZIP {
        let bytes: UnsafeRawBufferPointer
        let invalid = PortableArtifactError.invalid("Malformed or unsupported Piece ZIP archive")

        init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

        func u16(_ i: Int) -> Int {
            Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt16.self)))
        }
        func u32(_ i: Int) -> Int {
            Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self)))
        }

        struct Entry {
            let path: String
            let flags: Int
            let method: Int
            let crc: Int
            let compressed: Int
            let decoded: Int
            let local: Int
        }

        func preflight() throws -> [String: PieceArchive.Member] {
            let end = bytes.count - 22
            let footer = stride(from: end, through: max(0, end - 65_535), by: -1).first {
                u32($0) == 0x06054b50 && u16($0 + 20) == end - $0
            }
            guard let footer, u16(footer + 4) == 0, u16(footer + 6) == 0 else { throw invalid }
            let count = u16(footer + 10), central = u32(footer + 16)
            guard (2...4).contains(count), u16(footer + 8) == count, central <= footer,
                  u32(footer + 12) == footer - central else { throw invalid }
            let required: Set<String> = ["piece.json", "piece.metal"]
            let allowed = required.union(AssetSafety.assetPaths)
            var entries: [Entry] = [], paths: Set<String> = []
            var cursor = central, totalDecoded = 0
            for _ in 0..<count {
                guard cursor + 46 <= footer, u32(cursor) == 0x02014b50 else { throw invalid }
                let flags = u16(cursor + 8), method = u16(cursor + 10)
                let compressed = u32(cursor + 20), decoded = u32(cursor + 24)
                let name = cursor + 46, extra = name + u16(cursor + 28), comment = extra + u16(cursor + 30)
                let next = comment + u16(cursor + 32), local = u32(cursor + 42)
                let attrs = u32(cursor + 38), fileType = (attrs >> 16) & 0xf000
                let allowedFlags = method == 8 ? 0x80e : 0x808 // UTF-8, data descriptor, deflate levels
                guard next <= footer, local < central, u16(cursor + 34) == 0,
                      flags & ~allowedFlags == 0, method == 0 || method == 8,
                      (method != 0 || compressed == decoded), (method != 8 || compressed > 0),
                      fileType == 0 || fileType == 0x8000, attrs & 0x10 == 0,
                      compressed <= AssetSafety.portable.maxArchiveBytes, decoded <= AssetSafety.portable.maxDecodedBytes - totalDecoded,
                      let path = String(bytes: bytes[name..<extra], encoding: .utf8),
                      path.utf8.allSatisfy({ $0 < 128 }), allowed.contains(path), paths.insert(path).inserted else { throw invalid }
                try checkExtras(extra..<comment)
                totalDecoded += decoded
                entries.append(Entry(path: path, flags: flags, method: method, crc: u32(cursor + 16),
                                     compressed: compressed, decoded: decoded, local: local))
                cursor = next
            }
            guard cursor == footer, required.isSubset(of: paths) else { throw invalid }
            try AssetSafety.validateAssetPaths(paths.subtracting(required))

            var members: [String: PieceArchive.Member] = [:]
            cursor = 0
            let ordered = entries.sorted { $0.local < $1.local }
            for (index, entry) in ordered.enumerated() {
                let end = index + 1 == ordered.count ? central : ordered[index + 1].local
                guard entry.local == cursor, cursor + 30 <= end, u32(cursor) == 0x04034b50,
                      u16(cursor + 6) == entry.flags, u16(cursor + 8) == entry.method else { throw invalid }
                let name = cursor + 30, extra = name + u16(cursor + 26), payload = extra + u16(cursor + 28)
                let payloadEnd = payload + entry.compressed
                guard payloadEnd <= end, bytes[name..<extra].elementsEqual(entry.path.utf8) else { throw invalid }
                try checkExtras(extra..<payload)
                let crc = u32(cursor + 14), compressed = u32(cursor + 18), decoded = u32(cursor + 22)
                if entry.flags & 8 == 0 {
                    guard crc == entry.crc, compressed == entry.compressed, decoded == entry.decoded,
                          payloadEnd == end else { throw invalid }
                } else {
                    guard (crc == 0 || crc == entry.crc), (compressed == 0 || compressed == entry.compressed),
                          (decoded == 0 || decoded == entry.decoded) else { throw invalid }
                    var descriptor = payloadEnd
                    if end - payloadEnd == 16, u32(payloadEnd) == 0x08074b50 { descriptor += 4 }
                    guard end - descriptor == 12, u32(descriptor) == entry.crc,
                          u32(descriptor + 4) == entry.compressed, u32(descriptor + 8) == entry.decoded else { throw invalid }
                }
                members[entry.path] = PieceArchive.Member(path: entry.path, method: entry.method, crc: UInt32(entry.crc),
                                                          decodedSize: entry.decoded, range: payload..<payloadEnd)
                cursor = end
            }
            return members
        }

        private func checkExtras(_ range: Range<Int>) throws {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                guard cursor + 4 <= range.upperBound else { throw invalid }
                let tag = u16(cursor)
                // Conventional timestamps and UID/GID only: no alternate
                // paths, ZIP64 sizes, or Unix link metadata.
                guard tag == 0x5455 || tag == 0x7875 || tag == 0x000a else { throw invalid }
                cursor += 4 + u16(cursor + 2)
                guard cursor <= range.upperBound else { throw invalid }
            }
        }
    }
}
