import Darwin
import Foundation
import Metal
import zlib

/// Isolated format and bounds tests; no shader execution, network or defaults writes.
enum PortableArtifactsSelfTest {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private static let hash = String(repeating: "a", count: 64)
    private static let pieceRef = PortableReference(kind: .piece, sha256: hash)!
    private static let lookRef = PortableReference(kind: .look, sha256: hash)!

    static func run() {
        do {
            try metadata()
            try canonicalJSON()
            try artifacts()
            try lineage()
            try links()
            try assets()
            print("OK    artifacts: metadata, RFC 8785 and SHA-256, strict v1 models and Look application, lineage, links, ZIP/DEFLATE and splat/path bounds")
        } catch { PreviewMain.fail("artifacts self-test: \(error)") }
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    private static func rejects<T>(_ message: String, _ operation: () throws -> T) throws {
        do { _ = try operation() } catch { return }
        throw Failure(description: "accepted \(message)")
    }

    private static func metadata() throws {
        let authored = String(repeating: "é", count: 60) // exactly 120 UTF-8 bytes
        let original = """
            // lerp-author: Ada
        \t// lerp-author: \(authored)
        // lerp-remixed-from: \(lookRef)
        // lerp-license: (MIT OR Apache-2.0) AND GPL-2.0-only WITH Classpath-exception-2.0
        // lerp-tags: space-travel, night, 3d
        // lerp-mood: meditative
        // lerp-motion: gentle
        // lerp-brightness: balanced
        // lerp-param: drift float 0 1 = 0.5
        constant int x = 1; // lerp-author: Not an author
        // lerp-unknown: ignored
        """
        let meta = ShaderMetadata.parse(source: original.replacingOccurrences(of: "\n", with: "\r\n"))
        try expect(meta.diagnostics.isEmpty && meta.authors == ["Ada", authored], "metadata whole-line/CRLF or byte boundary")
        try expect(meta.remixedFrom == lookRef && meta.license?.contains("WITH Classpath-exception-2.0") == true
                   && meta.tags == ["space-travel", "night", "3d"] && meta.mood == "meditative"
                   && meta.motion == .gentle && meta.brightness == .balanced, "metadata values not retained")
        let invalid = """
        // lerp-author: \(authored)z
        // lerp-author: no\u{0085}name
        // lerp-remixed-from: playlist:sha256:\(hash)
        // lerp-license: Apache-2.0 AND (MIT OR)
        // lerp-tags: \((0...16).map { "tag-\($0)" }.joined(separator: ","))
        // lerp-mood: -loud
        // lerp-motion: hyper
        // lerp-brightness: vivid
        // lerp-mood: calm
        // lerp-author missing-colon
        // lerp-param: drift float 0 1 = 0.5
        """
        let bad = ShaderMetadata.parse(source: invalid)
        try expect(bad.diagnostics.map(\.line) == Array(1...10) && bad.authors.isEmpty, "wrong metadata diagnostics: \(bad.diagnostics)")
        try expect(LerpParamParser.parse(source: invalid).errors.isEmpty, "invalid editorial metadata broke legacy parsing")
        try expect(SPDXExpression.isValid("DocumentRef-Foo:LicenseRef-proprietary OR GPL-2.0+")
                   && !SPDXExpression.isValid("Imaginary-1.0") && !SPDXExpression.isValid("(MIT) WITH Classpath-exception-2.0")
                   && !SPDXExpression.isValid("MIT WITH Imaginary"), "SPDX grammar or identifier registry")
    }

    private static func canonicalJSON() throws {
        func canonical(_ text: String) throws -> String {
            String(decoding: try PortableCanonicalJSON.canonicalize(Data(text.utf8)), as: UTF8.self)
        }
        let input = #"{"string":"\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/", "numbers":[333333333.33333329,1E30,4.50,2e-3,0.000000000000000000000000001],"literals":[null,true,false]}"#
        let expected = #"{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}"#
        try expect(try canonical(input) == expected, "RFC 8785 §3.2.2 example")
        // RFC 8785 Appendix B binary64 boundary and tie cases.
        let vectors: [(UInt64, String)] = [
            (0x8000000000000000, "0"), (0x0000000000000001, "5e-324"),
            (0x7fefffffffffffff, "1.7976931348623157e+308"), (0x4340000000000000, "9007199254740992"),
            (0x4430000000000000, "295147905179352830000"), (0x44b52d02c7e14af5, "9.999999999999997e+22"),
            (0x44b52d02c7e14af6, "1e+23"), (0x44b52d02c7e14af7, "1.0000000000000001e+23"),
            (0x444b1ae4d6e2ef4e, "999999999999999700000"), (0x444b1ae4d6e2ef4f, "999999999999999900000"),
            (0x444b1ae4d6e2ef50, "1e+21"), (0x3eb0c6f7a0b5ed8c, "9.999999999999997e-7"),
            (0x3eb0c6f7a0b5ed8d, "0.000001"), (0x43143ff3c1cb0959, "1424953923781206.2")
        ]
        for (bits, json) in vectors {
            let result = try PortableCanonicalJSON.encode(Double(bitPattern: bits))
            try expect(result == Data(json.utf8), "incorrect JCS binary64 case: \(json) -> \(String(decoding: result, as: UTF8.self))")
        }
        let unicode = try canonical(#"{"\ufb33":1,"\ud83d\ude00":2,"\u00e9":3,"e\u0301":4}"#)
        try expect(Data(unicode.utf8) == Data("{\"e\u{301}\":4,\"é\":3,\"😀\":2,\"דּ\":1}".utf8), "JCS UTF-16 sorting / non-normalization")
        for bad in [#"{"a":1,"\u0061":2}"#, #""\ud800""#, #""\uDEAD""#, "1e999", "01", "1.", "[0,]", "{\"a\":0,}", "true false"] {
            try rejects("invalid I-JSON \(bad)") { try canonical(bad) }
        }
        try rejects("invalid UTF-8") { try PortableCanonicalJSON.canonicalize(Data([34, 255, 34])) }
        try expect(PortableReference.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 known vector")
    }

    private static func artifacts() throws {
        let piece = try PortablePiece(source: "blob:sha256:" + hash, assets: [:])
        let canonical = try piece.canonicalJSON()
        try expect(try piece.reference().sha256 == "9c0783c0efc3244aaac8273a97b2293a8e49d4659dad13b8dc5bdf12c966605e", "Piece fixture digest changed")
        try expect(try PortablePiece.decode(canonical) == piece, "Piece Codable round trip")
        let text = String(decoding: canonical, as: UTF8.self)
        try rejects("wrong Piece ABI") { try PortablePiece.decode(Data(text.replacingOccurrences(of: "metal-1", with: "metal-2").utf8)) }
        try rejects("wrong Piece version") { try PortablePiece.decode(Data(text.replacingOccurrences(of: #""v":1"#, with: #""v":2"#).utf8)) }
        try rejects("non-blob Piece source") { try PortablePiece(source: pieceRef.description, assets: [:]) }
        let asset = try PortablePiece.Asset(sha256: hash, credit: "A photo by Morgan", license: "CC-BY-4.0")
        let withAsset = try PortablePiece(source: piece.source, assets: ["assets/image.png": asset], title: "Study", authors: ["Morgan"])
        try expect(try PortablePiece.decode(withAsset.canonicalJSON()) == withAsset, "licensed asset failed round trip")
        try rejects("asset with invalid license") { try PortablePiece.Asset(sha256: hash, credit: "Morgan", license: "Whatever") }
        try rejects("asset with traversal path") { try PortablePiece(source: piece.source, assets: ["../image.png": asset]) }

        let schema = LerpParamParser.parse(source: """
        // lerp-param: gain float 0 1 = 0.5
        // lerp-param: slices int -2147483648 2147483648 = 4
        // lerp-param: toggle bool = false
        // lerp-param: tint color = #00FF00
        // lerp-param: pad float 0 1 = 0
        // lerp-animate: gain 0.2 0.8
        // lerp-preset: "Night café" gain=0.8, pad=1
        """)
        try expect(schema.errors.isEmpty, "malformed schema fixture: \(schema.errors)")
        func look(_ values: [String: PortableTuning] = [:], _ preset: String? = nil) throws -> PortableLook {
            try PortableLook(title: "Night", piece: pieceRef, preset: preset, tuning: values, authors: ["Remixer"], remixedFrom: lookRef, license: "MIT")
        }
        let drift = try PortableTuning.Animation(low: .number(0.1), high: .number(0.6), period: 60)
        let lookRecord = try look(["gain": .animate(drift), "slices": .number(7), "toggle": .bool(true), "tint": .color([1, 0, 0.25, 1])], "Night café")
        let decoded = try PortableLook.decode(lookRecord.canonicalJSON())
        try expect(decoded == lookRecord && (try decoded.reference()) == lookRecord.reference(), "Look types or identity changed on round trip")
        let applied = try decoded.parameterValues(for: pieceRef, schema: schema)
        try expect(applied["slices"] == .scalar(7) && applied["toggle"] == .scalar(1) && applied["tint"] == .color(SIMD4(1, 0, 0.25, 1))
                   && applied["pad"] == .scalar(1) && applied.activeAnimations["gain"]?.period == 60, "exact preset or tuning not applied")
        let pinned = try look(["gain": .number(1)]).parameterValues(for: pieceRef, schema: schema)
        try expect(!pinned.isAnimating("gain") && pinned["gain"] == .scalar(1), "held float did not pin declared drift")
        try rejects("wrong Piece") { try decoded.parameterValues(for: PortableReference(kind: .piece, sha256: String(repeating: "b", count: 64))!, schema: schema) }
        for miss in ["Defaults", "night café", "Night cafe\u{301}"] {
            try rejects("missing / non-exact preset \(miss)") { try look([:], miss).parameterValues(for: pieceRef, schema: schema) }
        }
        for (key, bad): (String, PortableTuning) in [
            ("unbound", .number(1)), ("gain", .bool(true)), ("gain", .number(1.001)), ("gain", .number(.infinity)),
            ("toggle", .number(1)), ("slices", .number(4.5)), ("slices", .number(2_147_483_648)),
            ("slices", .animate(drift)), ("tint", .color([1, 0, 1])), ("tint", .color([1.1, 0, 0, 1])),
            ("tint", .color([1, .nan, 0, 1])), ("tint", .animate(drift))
        ] {
            try rejects("invalid tuning for \(key)") { try look([key: bad]).parameterValues(for: pieceRef, schema: schema) }
        }
        let fast = try PortableTuning.Animation(low: .number(0.1), high: .number(0.9), period: 1)
        try rejects("animation too fast for shader schema") { try look(["gain": .animate(fast)]).parameterValues(for: pieceRef, schema: schema) }
        let unsafe = LerpParamParser.parse(source: "// lerp-param: n int 0 1e30 = 1e29")
        try rejects("unpackable int from source schema") { try look().parameterValues(for: pieceRef, schema: unsafe) }
        let nullPreset = String(decoding: try look().canonicalJSON(), as: UTF8.self)
        try expect(nullPreset.contains(#""preset":null"#), "Defaults preset must encode as explicit null")
        for bad in [nullPreset.replacingOccurrences(of: #""preset":null,"#, with: ""),
                    nullPreset.replacingOccurrences(of: #""preset":null"#, with: #""preset":null,"preset":"Night""#),
                    nullPreset.replacingOccurrences(of: #""v":1"#, with: #""v":1,"extra":0"#),
                    nullPreset.replacingOccurrences(of: #""license":"MIT""#, with: #""license":null"#),
                    nullPreset.replacingOccurrences(of: #""tuning":{}"#, with: #""tuning":{"gain":{"animate":{"low":0,"high":1,"period":0}}}"#),
                    nullPreset.replacingOccurrences(of: #""tuning":{}"#, with: #""tuning":{"gain":{"animate":{"low":0,"high":[0,0,0,1],"period":20}}}"#),
                    nullPreset.replacingOccurrences(of: #""tuning":{}"#, with: #""tuning":{"gain":{"animate":{"low":false,"high":1,"period":20}}}"#)] {
            try rejects("malformed Look: \(bad)") { try PortableLook.decode(Data(bad.utf8)) }
        }
        let alternate = PortableReference(kind: .look, sha256: String(repeating: "b", count: 64))!
        let playlist = try PortablePlaylist(title: "Evening", looks: [alternate, lookRef])
        try expect(try PortablePlaylist.decode(playlist.canonicalJSON()).looks == [alternate, lookRef], "Playlist ordering lost")
        try expect(try playlist.reference().kind == .playlist, "wrong Playlist content kind")
        for looks in [[], [lookRef, lookRef], [pieceRef], (0...100).map { reference(.look, $0) }] {
            try rejects("invalid Playlist") { try PortablePlaylist(title: "Evening", looks: looks) }
        }
    }

    private static func reference(_ kind: PortableReference.Kind, _ number: Int) -> PortableReference {
        PortableReference(kind: kind, sha256: String(format: "%064x", number))!
    }

    private static func lineage() throws {
        let parent = try PortablePiece(source: "blob:sha256:" + hash, assets: [:], authors: ["Original artist"], remixedFrom: lookRef)
        let grandparent = try PortableLook(title: "Night", piece: pieceRef, preset: nil, tuning: [:], authors: ["Earlier author"], remixedFrom: pieceRef)
        let cycle = PortableLineage.resolve(from: pieceRef) { $0 == pieceRef ? .piece(parent) : .look(grandparent) }
        try expect(cycle.credits.map(\.authors) == [["Original artist"], ["Earlier author"]] && cycle.end == .cycle(pieceRef), "credit must come from parent and stop at visited ref")
        var count = 0
        let long = try PortableLineage.resolve(from: reference(.piece, 0)) { _ in
            count += 1
            return .piece(try PortablePiece(source: "blob:sha256:" + hash, assets: [:], remixedFrom: reference(.piece, count)))
        }
        try expect(count == 32 && long.credits.count == 32 && long.end == .hopLimit(reference(.piece, 32)), "lineage loaded more than 32 parents")
        let missing = PortableLineage.resolve(from: lookRef) { _ in nil }
        try expect(missing.credits.isEmpty && missing.end == .missing(lookRef), "missing parent supplied credit")
        try expect(PortableLineage.resolve(from: nil) { _ in nil }.end == .root, "empty parent isn't a root")
    }

    private static func links() throws {
        for ref in [pieceRef, lookRef, reference(.playlist, 3)] {
            try expect(PortableLinks.parse(PortableLinks.deepLink(for: ref).absoluteString) == ref, "valid deep-link rejected")
            try expect(PortableLinks.postcard(for: ref).absoluteString == "https://lerping.app/p/v1/\(ref.kind.rawValue)/\(ref.sha256)", "wrong postcard origin or route")
            try expect(PortableLinks.artifact(for: ref).absoluteString == "https://lerping.app/api/v1/artifacts/\(ref.kind.rawValue)/\(ref.sha256)", "wrong artifact origin or route")
        }
        try expect(PortableLinks.blob(sha256: hash)?.absoluteString == "https://lerping.app/api/v1/blobs/\(hash)"
                   && PortableLinks.blob(sha256: "../escape") == nil, "wrong blob URL construction")
        for bad in ["lerp://user@open/v1/look/\(hash)", "lerp://open:443/v1/look/\(hash)",
                    "lerp://open@evil/v1/look/\(hash)", "lerp://open.evil/v1/look/\(hash)",
                    "lerp://open/v1/look/\(hash)?", "lerp://open/v1/look/\(hash)#",
                    "lerp://open/v1/look/\(hash)/", "lerp://open/v1/look//\(hash)",
                    "lerp://open/v1/%6cook/\(hash)", "lerp://open/v1/look/%61\(hash.dropFirst())",
                    "lerp://open/v1/look/\(hash.uppercased())", "lerp://open/v1/look/z\(hash.dropFirst())",
                    "lerp://open/v1/look/\(hash.dropFirst())", "lerp://open/v1/look/\(hash)\n",
                    "lerp://open/v1/album/\(hash)", "lerp://open/v2/look/\(hash)", "lerp://open/v1/loоk/\(hash)",
                    "lerp://open/v1/./look/\(hash)", "lerp://open\\evil/v1/look/\(hash)"] {
            try expect(PortableLinks.parse(bad) == nil, "accepted hostile URL \(bad.debugDescription)")
        }
    }

    private static func assets() throws {
        let strict = AssetSafetyLimits.portableIngress, bundled = AssetSafetyLimits.bundledLegacy
        try expect(strict.maxArchiveBytes == 64 << 20 && strict.maxDecodedBytes == 128 << 20 && strict.maxSplats == 1_000_000
                   && strict.maxPathKeyframes == 4_096 && bundled.maxArchiveBytes == 256 << 20 && bundled.maxDecodedBytes == 512 << 20
                   && bundled.maxSplats == 8_000_000 && bundled.maxPathKeyframes == 16_384, "asset policy ceilings")
        try expect(try AssetSafety.splatPayloadSize(count: strict.maxSplats, positionBytes: 12, coefficients: 15, paletteCount: strict.maxSplats) == 71_000_000, "strict splat size calculation")
        try expect(try AssetSafety.splatPayloadSize(count: bundled.maxSplats, positionBytes: 6, coefficients: 0, paletteCount: 0, limits: bundled) == 136_000_000, "bundled splat size calculation")
        for (n, p, c, palette, limits) in [(1_000_001, 6, 0, 0, strict), (8_000_001, 6, 0, 0, bundled),
                                           (8_000_000, 12, 15, 8_000_000, bundled), (0, 6, 0, 0, strict),
                                           (1, 12, 16, 1, strict), (1, 12, 15, 2, strict), (Int.max, 6, Int.max, Int.max, strict)] {
            try rejects("unsafe splat layout") { try AssetSafety.splatPayloadSize(count: n, positionBytes: p, coefficients: c, paletteCount: palette, limits: limits) }
        }

        let payload = Data("hello".utf8), deflate = storedDeflate(payload)
        try expect(try AssetSafety.inflateRaw(deflate, range: 0..<deflate.count, expectedBytes: 5) == payload, "raw DEFLATE exact output")
        for size in [0, 4, 6, strict.maxDecodedBytes + 1] {
            try rejects("wrong decompressed length \(size)") { try AssetSafety.inflateRaw(deflate, range: 0..<deflate.count, expectedBytes: size) }
        }
        try rejects("truncated DEFLATE") { try AssetSafety.inflateRaw(deflate, range: 0..<(deflate.count - 1), expectedBytes: 5) }
        try rejects("trailing DEFLATE") { try AssetSafety.inflateRaw(deflate + deflate, range: 0..<(deflate.count * 2), expectedBytes: 5) }

        func path(_ count: Int, times: [Double]? = nil, fov: Double = 60, extraPositions: Int = 0) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["duration": Double(count), "frameRate": 30, "loopMode": "repeat",
                "smoothness": 1, "up": [0, 1, 0], "times": times ?? (0..<count).map(Double.init),
                "position": Array(repeating: [0, 0, 3], count: count + extraPositions),
                "target": Array(repeating: [0, 0, 0], count: count), "fov": Array(repeating: fov, count: count)])
        }
        try expect(try LerpSplatPath.decode(path(strict.maxPathKeyframes)).times.count == strict.maxPathKeyframes, "strict boundary path rejected")
        let overStrict = try path(strict.maxPathKeyframes + 1)
        try rejects("too many ingress keyframes") { try LerpSplatPath.decode(overStrict) }
        try expect(try LerpSplatPath.decode(overStrict, limits: bundled).times.count == strict.maxPathKeyframes + 1, "bundled path tier not applied")
        try rejects("too many bundled keyframes") { try LerpSplatPath.decode(path(bundled.maxPathKeyframes + 1), limits: bundled) }
        for invalid in [try path(2, times: [1, 1]), try path(2, times: [1, 0]), try path(2, times: [0, 1e99]),
                        try path(2, times: [0, 61]), try path(2, fov: 0), try path(2, fov: 180), try path(2, extraPositions: 1), try path(0)] {
            try rejects("invalid camera path") { try LerpSplatPath.decode(invalid) }
        }

        let mandatory = [Member("piece.json", Data("{}".utf8)), Member("piece.metal", payload, deflated: true, descriptor: true)]
        let valid = try AssetSafety.preflightPieceArchive(zip(mandatory + [Member("assets/image.png", payload)]))
        try expect(valid.paths == ["piece.json", "piece.metal", "assets/image.png"] && (try valid.decodedMember("piece.metal")) == payload
                   && (try valid.decodedMember("missing")) == nil, "ZIP whitelist or bounded member read")
        for extra in [[Member("../piece.metal", payload)], [Member("piece.json", payload)], [Member("assets\\image.png", payload)],
                      [Member("assets/capture.path.json", payload)], [Member("assets/image.depth.png", payload)],
                      [Member("assets/capture.lsplat", payload), Member("assets/image.png", payload)],
                      [Member("assets/image.png", payload, attributes: 0xa1ff << 16)],
                      [Member("assets/image.png", payload, localName: "../outside")],
                      [Member("assets/image.png", payload, deflated: true, declaredSize: strict.maxDecodedBytes)]] {
            try rejects("unsafe ZIP member \(extra.map(\.name))") { try AssetSafety.preflightPieceArchive(zip(mandatory + extra)) }
        }
        try rejects("memberless ZIP") { try AssetSafety.preflightPieceArchive(zip([mandatory[0]])) }
        let bomb = try AssetSafety.preflightPieceArchive(zip(mandatory + [Member("assets/image.png", payload, deflated: true, declaredSize: 1)]))
        try rejects("DEFLATE output beyond ZIP header declaration") { try bomb.decodedMember("assets/image.png") }
        let corrupt = try AssetSafety.preflightPieceArchive(zip(mandatory + [Member("assets/image.png", payload, crcOverride: 0)]))
        try rejects("corrupt member CRC") { try corrupt.decodedMember("assets/image.png") }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lerp-artifacts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("test.lsplat")
        // Sparse file: exercise the on-disk size boundary without allocating it.
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(strict.maxArchiveBytes + 1))
        try handle.close()
        try rejects("oversized ZIP on disk") { try AssetSafety.preflightPieceArchive(at: file) }
        try rejects("external file used bundled limits") { try AssetSafety.readSplatFile(.external(file)) }
        let pipe = temp.appending(path: "named-pipe")
        try expect(pipe.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0, "could not create FIFO fixture")
        try rejects("non-regular asset file") { try AssetSafety.preflightPieceArchive(at: pipe) }
        try checkoutBounds(temp)
        if let device = MTLCreateSystemDefaultDevice() {
            let good = lsplat(count: 1, planes: Data(repeating: 0, count: 23))
            try good.write(to: file)
            try expect(try LerpSplatAsset.load(.external(file), device: device).count == 1, "valid LSPL did not reach GPU")
            let nan = Data([0, 0, 0xc0, 0x7f]) + Data(repeating: 0, count: 19)
            for bad in [lsplat(count: 1_000_001, planes: Data()), lsplat(count: 1, planes: nan), good + Data([0]),
                        lsplat(count: 1, planes: Data(repeating: 0, count: 24))] {
                try bad.write(to: file)
                try rejects("unsafe LSPL reached GPU") { try LerpSplatAsset.load(.external(file), device: device) }
            }
        }
    }

    private static func checkoutBounds(_ temp: URL) throws {
        let shaders = temp.appending(path: "Sources/Shaders")
        let catalog = temp.appending(path: "Sources/Splats")
        let splats = temp.appending(path: "build/splats")
        for dir in [shaders, catalog, splats, temp.appending(path: ".git")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let known = "selftest-catalogued-capture", custom = "selftest-uncatalogued-capture", alias = "selftest-symlink-capture"
        let manifest = "{\"captures\":{\"\(known)\":{\"title\":\"Test capture\"},\"\(alias)\":{\"title\":\"Symlink\"}}}"
        try Data(manifest.utf8).write(to: catalog.appending(path: "captures.json"))
        let strict = AssetSafetyLimits.portableIngress
        for name in [known, custom] {
            let file = splats.appending(path: name + ".path.json")
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(strict.maxPathBytes + 1))
            try handle.close()
        }
        try FileManager.default.createSymbolicLink(at: splats.appending(path: alias + ".path.json"),
                                                   withDestinationURL: splats.appending(path: custom + ".path.json"))
        LerpSplatAssets.addSourceRoots([shaders])
        guard let builtIn = LerpSplatAssets.location(for: known, extension: "path.json"),
              let uncatalogued = LerpSplatAssets.location(for: custom, extension: "path.json"),
              let symlinked = LerpSplatAssets.location(for: alias, extension: "path.json") else {
            throw Failure(description: "missing checkout path fixtures")
        }
        try expect(LerpSplatAssets.location(for: "../splats/" + known, extension: "path.json") == nil, "capture name traversed directories")
        let (_, tier) = try AssetSafety.readSplatFile(builtIn, isPath: true)
        try expect(tier.maxPathKeyframes == AssetSafetyLimits.bundledLegacy.maxPathKeyframes, "known checkout lost legacy bounds")
        for strictLocation in [uncatalogued, symlinked, .external(builtIn.url)] {
            try rejects("untrusted path used checkout limits") { try AssetSafety.readSplatFile(strictLocation, isPath: true) }
        }
        // If real build assets are present, also exercise the bundle vs repo
        // lookup precedence in a standalone executable (case-insensitive APFS).
        if let shaders = ShaderLocations.repoShaderDirectory() {
            let repo = shaders.deletingLastPathComponent().deletingLastPathComponent()
            let capture = repo.appending(path: "build/splats/trogir-square.lsplat")
            if FileManager.default.fileExists(atPath: capture.path) {
                try expect(LerpSplatAssets.location(for: "trogir-square")?.cataloguedCheckout == true,
                           "bare preview resource shadowed the built-in checkout capture")
            }
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
    }

    private static func storedDeflate(_ data: Data) -> Data {
        var result = Data([1]) // final, uncompressed DEFLATE block
        let n = UInt16(data.count)
        append(n, to: &result)
        append(~n, to: &result)
        return result + data
    }

    private static func lsplat(count: UInt32, planes: Data) -> Data {
        let deflated = storedDeflate(planes)
        var file = Data("LSPL".utf8)
        for word in [1, count, 1, 0, 0, 0, 0, 0, 0, UInt32(deflated.count), 0] { append(word, to: &file) }
        return file + deflated
    }

    private struct Member {
        let name: String
        let data: Data
        var deflated: Bool
        var descriptor: Bool
        var attributes: UInt32
        var localName: String?
        var declaredSize: Int?
        var crcOverride: UInt32?

        init(_ name: String, _ data: Data, deflated: Bool = false, descriptor: Bool = false, attributes: UInt32 = 0,
             localName: String? = nil, declaredSize: Int? = nil, crcOverride: UInt32? = nil) {
            (self.name, self.data, self.deflated, self.descriptor, self.attributes, self.localName, self.declaredSize, self.crcOverride)
                = (name, data, deflated, descriptor, attributes, localName, declaredSize, crcOverride)
        }
    }

    private static func zip(_ entries: [Member]) -> Data {
        var file = Data(), central = Data()
        for entry in entries {
            let payload = entry.deflated ? storedDeflate(entry.data) : entry.data
            let crc = entry.crcOverride ?? entry.data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                UInt32(crc32(0, b.bindMemory(to: UInt8.self).baseAddress, UInt32(b.count)))
            }
            let sizes = [crc, UInt32(payload.count), UInt32(entry.declaredSize ?? entry.data.count)]
            let local = Array((entry.localName ?? entry.name).utf8), name = Array(entry.name.utf8)
            let flags: UInt16 = entry.descriptor ? 8 : 0, method: UInt16 = entry.deflated ? 8 : 0
            let offset = UInt32(file.count)
            append(UInt32(0x04034b50), to: &file)
            for word: UInt16 in [20, flags, method, 0, 0] { append(word, to: &file) }
            for word in sizes { append(entry.descriptor ? 0 : word, to: &file) }
            append(UInt16(local.count), to: &file); append(UInt16(0), to: &file)
            file.append(contentsOf: local); file += payload
            if entry.descriptor {
                append(UInt32(0x08074b50), to: &file)
                for word in sizes { append(word, to: &file) }
            }

            append(UInt32(0x02014b50), to: &central)
            for word: UInt16 in [0x314, 20, flags, method, 0, 0] { append(word, to: &central) }
            for word in sizes { append(word, to: &central) }
            for word: UInt16 in [UInt16(name.count), 0, 0, 0, 0] { append(word, to: &central) }
            append(entry.attributes, to: &central); append(offset, to: &central)
            central.append(contentsOf: name)
        }
        let start = UInt32(file.count)
        file += central
        append(UInt32(0x06054b50), to: &file)
        for word: UInt16 in [0, 0, UInt16(entries.count), UInt16(entries.count)] { append(word, to: &file) }
        append(UInt32(central.count), to: &file); append(start, to: &file); append(UInt16(0), to: &file)
        return file
    }
}
