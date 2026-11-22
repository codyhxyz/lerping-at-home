import CryptoKit
import Foundation

public enum PortableArtifactError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self { case let .invalid(message): return message }
    }
}

/// RFC 8785 (JCS): ECMAScript binary64 number spelling, UTF-16 property
/// order, and no Unicode normalization. Do not use JSONEncoder.sortedKeys:
/// its collation and number / string escaping are not JCS.
public enum PortableCanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try canonicalize(JSONEncoder().encode(value))
    }

    public static func canonicalize(_ data: Data) throws -> Data {
        var parser = Parser(bytes: Array(data))
        let result = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.next == nil else { throw parser.error }
        return Data(result)
    }

    /// Swift supplies shortest round-trip binary64 digits. Place the decimal
    /// point and spell the exponent as ECMAScript Number::toString does.
    private static func number(_ value: Double) -> [UInt8] {
        guard value != 0 else { return [48] } // includes negative zero
        let parts = String(abs(value)).split(separator: "e")
        let exponent = parts.count == 2 ? Int(parts[1])! : 0
        let mantissa = parts[0].split(separator: ".")
        var digits = Array(mantissa.joined().utf8)
        var point = mantissa[0].count + exponent
        while digits.first == 48 { digits.removeFirst(); point -= 1 }
        while digits.last == 48 { digits.removeLast() }

        var output: [UInt8] = value < 0 ? [45] : []
        if point > 0, point <= 21 {
            output += digits.prefix(point)
            if point >= digits.count { output += repeatElement(48, count: point - digits.count) }
            else { output += [46]; output += digits.dropFirst(point) }
        } else if point <= 0, point > -6 {
            output += [48, 46]
            output += repeatElement(48, count: -point)
            output += digits
        } else {
            output.append(digits[0])
            if digits.count > 1 { output += [46]; output += digits.dropFirst() }
            output.append(101)
            if point > 0 { output.append(43) }
            output += String(point - 1).utf8
        }
        return output
    }

    private static func string(_ text: String) -> [UInt8] {
        var output: [UInt8] = [34]
        let hex = Array("0123456789abcdef".utf8)
        for byte in text.utf8 {
            switch byte {
            case 8: output += [92, 98]   // \b
            case 9: output += [92, 116]  // \t
            case 10: output += [92, 110] // \n
            case 12: output += [92, 102] // \f
            case 13: output += [92, 114] // \r
            case 34, 92: output += [92, byte]
            case 0...31: output += [92, 117, 48, 48, hex[Int(byte >> 4)], hex[Int(byte & 15)]]
            default: output.append(byte)
            }
        }
        output.append(34)
        return output
    }

    /// Parse the I-JSON subset before Foundation's Codable decoder can erase
    /// duplicate keys. Swift String equality is canonical-equivalence based;
    /// the UTF-16 key arrays here deliberately compare exact code units.
    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var next: UInt8? { index < bytes.count ? bytes[index] : nil }
        var error: PortableArtifactError { .invalid("Invalid I-JSON at byte \(index)") }

        mutating func skipWhitespace() {
            while let next, next == 32 || next == 9 || next == 10 || next == 13 { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard next == byte else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> [UInt8] {
            guard depth <= 128 else { throw error }
            skipWhitespace()
            guard let next else { throw error }
            switch next {
            case 34: return PortableCanonicalJSON.string(try readString())
            case 91:
                index += 1
                var output: [UInt8] = [91]
                skipWhitespace()
                if !consume(93) {
                    repeat {
                        if output.count > 1 { output.append(44) }
                        output += try value(depth: depth + 1)
                        skipWhitespace()
                    } while consume(44)
                    guard consume(93) else { throw error }
                }
                output.append(93)
                return output
            case 123:
                index += 1
                var members: [(key: [UInt16], name: String, value: [UInt8])] = []
                var seen: Set<[UInt16]> = []
                skipWhitespace()
                if !consume(125) {
                    repeat {
                        skipWhitespace()
                        let name = try readString()
                        let key = Array(name.utf16)
                        guard seen.insert(key).inserted else { throw error }
                        skipWhitespace()
                        guard consume(58) else { throw error }
                        members.append((key, name, try value(depth: depth + 1)))
                        skipWhitespace()
                    } while consume(44)
                    guard consume(125) else { throw error }
                }
                var output: [UInt8] = [123]
                for member in members.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                    if output.count > 1 { output.append(44) }
                    output += PortableCanonicalJSON.string(member.name)
                    output.append(58)
                    output += member.value
                }
                output.append(125)
                return output
            case 45, 48...57: return try readNumber()
            case 102: return try literal("false")
            case 110: return try literal("null")
            case 116: return try literal("true")
            default: throw error
            }
        }

        mutating func literal(_ text: String) throws -> [UInt8] {
            for byte in text.utf8 where !consume(byte) { throw error }
            return Array(text.utf8)
        }

        mutating func readString() throws -> String {
            let start = index
            guard consume(34) else { throw error }
            while let next, next >= 32 {
                index += 1
                if next == 34 {
                    let token = bytes[start..<index]
                    guard String(bytes: token, encoding: .utf8) != nil else { throw error }
                    return try JSONDecoder().decode(String.self, from: Data(token))
                }
                // Skip exactly one escaped byte so an escaped quote does not
                // close the token. Codable validates escape and surrogate syntax.
                if next == 92, index < bytes.count { index += 1 }
            }
            throw error
        }

        mutating func digits() -> Bool {
            let start = index
            while let next, (48...57).contains(next) { index += 1 }
            return index > start
        }

        mutating func readNumber() throws -> [UInt8] {
            let start = index
            _ = consume(45)
            if !consume(48), !digits() { throw error }
            if consume(46), !digits() { throw error }
            if consume(101) || consume(69) {
                if !consume(43) { _ = consume(45) }
                guard digits() else { throw error }
            }
            guard let number = Double(String(decoding: bytes[start..<index], as: UTF8.self)), number.isFinite else {
                throw error
            }
            return PortableCanonicalJSON.number(number)
        }
    }
}

public struct PortableReference: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable { case piece, look, playlist }

    public let kind: Kind
    public let sha256: String
    public var description: String { "\(kind.rawValue):sha256:\(sha256)" }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "sha256", let kind = Kind(rawValue: String(parts[0])) else { return nil }
        self.init(kind: kind, sha256: String(parts[2]))
    }

    public init?(kind: Kind, sha256: String) {
        guard Self.isDigest(sha256) else { return nil }
        self.kind = kind
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let ref = Self(value) else { throw PortableArtifactError.invalid("Invalid content reference") }
        self = ref
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(description)
    }

    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    public static func digest(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: data).flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
    }
}

public enum PortableLinks {
    public static let origin = URL(string: "https://lerping.app")!

    /// Match the input bytes, not a URLComponents-normalized representation.
    public static func parse(_ text: String) -> PortableReference? {
        let prefix = "lerp://open/v1/"
        guard text.utf8.starts(with: prefix.utf8), text.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        let parts = text.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let kind = PortableReference.Kind(rawValue: String(parts[0])) else { return nil }
        return PortableReference(kind: kind, sha256: String(parts[1]))
    }

    public static func deepLink(for ref: PortableReference) -> URL {
        URL(string: "lerp://open/v1/\(ref.kind.rawValue)/\(ref.sha256)")!
    }

    public static func postcard(for ref: PortableReference) -> URL { url("p/v1", ref) }
    public static func artifact(for ref: PortableReference) -> URL { url("api/v1/artifacts", ref) }

    public static func blob(sha256: String) -> URL? {
        guard PortableReference.isDigest(sha256) else { return nil }
        return origin.appending(path: "api/v1/blobs/\(sha256)")
    }

    private static func url(_ route: String, _ ref: PortableReference) -> URL {
        origin.appending(path: "\(route)/\(ref.kind.rawValue)/\(ref.sha256)")
    }
}

public protocol PortableArtifact: Codable, Sendable {
    static var kind: PortableReference.Kind { get }
}

extension PortableArtifact {
    /// Use this at the import boundary: unlike JSONDecoder by itself, this
    /// rejects duplicate object members and invalid I-JSON before decoding.
    public static func decode(_ data: Data) throws -> Self {
        let canonical = try PortableCanonicalJSON.canonicalize(data)
        let artifact = try JSONDecoder().decode(Self.self, from: canonical)
        guard try artifact.canonicalJSON() == canonical else {
            throw PortableArtifactError.invalid("Artifact could not be represented without losing JSON fields")
        }
        return artifact
    }

    public func canonicalJSON() throws -> Data { try PortableCanonicalJSON.encode(self) }

    public func reference() throws -> PortableReference {
        PortableReference(kind: Self.kind, sha256: PortableReference.digest(try canonicalJSON()))!
    }
}

private struct ArtifactKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension Decoder {
    func strictObject<K: CodingKey & CaseIterable>(_ keys: K.Type) throws -> KeyedDecodingContainer<K> {
        let allowed = Set(keys.allCases.map(\.stringValue))
        let raw = try container(keyedBy: ArtifactKey.self)
        guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw PortableArtifactError.invalid("Unknown field at \(codingPath.map(\.stringValue).joined(separator: "."))")
        }
        return try container(keyedBy: keys)
    }
}

private extension KeyedDecodingContainer {
    func optional<T: Decodable>(_ key: Key) throws -> T? {
        try contains(key) ? decode(T.self, forKey: key) : nil // explicit null is only valid for preset
    }

    func checkHeader(_ kind: PortableReference.Kind, v: Key, kind key: Key) throws {
        guard try decode(Int.self, forKey: v) == 1, try decode(PortableReference.Kind.self, forKey: key) == kind else {
            throw PortableArtifactError.invalid("Expected v1 \(kind.rawValue)")
        }
    }
}

private func checkCredit(authors: [String]?, remixedFrom: PortableReference?, license: String?) throws {
    guard authors?.allSatisfy(ShaderMetadata.isAuthor) != false else {
        throw PortableArtifactError.invalid("Invalid artifact author")
    }
    guard remixedFrom?.kind != .playlist else {
        throw PortableArtifactError.invalid("A remix parent must be a Piece or Look")
    }
    guard license.map(SPDXExpression.isValid) != false else {
        throw PortableArtifactError.invalid("Invalid artifact license")
    }
}

public struct PortablePiece: PortableArtifact, Equatable {
    public struct Asset: Codable, Sendable, Equatable {
        public let sha256: String
        public let credit: String
        public let license: String

        public init(sha256: String, credit: String, license: String) throws {
            guard PortableReference.isDigest(sha256), !credit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  SPDXExpression.isValid(license) else { throw PortableArtifactError.invalid("Invalid asset digest or credit") }
            self.sha256 = sha256
            self.credit = credit
            self.license = license
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case sha256, credit, license }

        public init(from decoder: Decoder) throws {
            let data = try decoder.strictObject(CodingKeys.self)
            try self.init(sha256: data.decode(String.self, forKey: .sha256),
                          credit: data.decode(String.self, forKey: .credit),
                          license: data.decode(String.self, forKey: .license))
        }
    }

    public static let kind: PortableReference.Kind = .piece
    public let v = 1
    public let kind = PortablePiece.kind
    public let abi = "lerp-metal-1"
    public let source: String
    public let assets: [String: Asset]
    public let title: String?
    public let authors: [String]?
    public let remixedFrom: PortableReference?
    public let license: String?

    public init(source: String, assets: [String: Asset], title: String? = nil, authors: [String]? = nil,
                remixedFrom: PortableReference? = nil, license: String? = nil) throws {
        let prefix = "blob:sha256:"
        guard source.hasPrefix(prefix), PortableReference.isDigest(String(source.dropFirst(prefix.count))) else {
            throw PortableArtifactError.invalid("Piece source must be a blob reference")
        }
        try AssetSafety.validateAssetPaths(Set(assets.keys))
        try checkCredit(authors: authors, remixedFrom: remixedFrom, license: license)
        self.source = source
        self.assets = assets
        self.title = title
        self.authors = authors
        self.remixedFrom = remixedFrom
        self.license = license
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case v, kind, abi, source, assets, title, authors, remixedFrom, license }

    public init(from decoder: Decoder) throws {
        let data = try decoder.strictObject(CodingKeys.self)
        try data.checkHeader(Self.kind, v: .v, kind: .kind)
        guard try data.decode(String.self, forKey: .abi) == "lerp-metal-1" else {
            throw PortableArtifactError.invalid("Unsupported Piece ABI")
        }
        try self.init(source: data.decode(String.self, forKey: .source), assets: data.decode([String: Asset].self, forKey: .assets),
                      title: data.optional(.title), authors: data.optional(.authors),
                      remixedFrom: data.optional(.remixedFrom), license: data.optional(.license))
    }
}

/// Numbers are deliberately untagged: JCS spells 1.0 and 1 identically. The
/// exact Piece's schema distinguishes float and int at application time.
public enum PortableTuning: Codable, Sendable, Equatable {
    case number(Double)
    case bool(Bool)
    case color([Double])
    case animate(Animation)

    public enum Endpoint: Codable, Sendable, Equatable {
        case number(Double)
        case color([Double])

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { self = .number(number) }
            else { self = .color(try value.decode([Double].self)) }
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            try validate()
            var value = encoder.singleValueContainer()
            switch self {
            case .number(let number): try value.encode(number)
            case .color(let color): try value.encode(color)
            }
        }

        fileprivate func validate() throws {
            switch self {
            case .number(let number) where number.isFinite: return
            case .color(let color) where color.count == 4 && color.allSatisfy({ $0.isFinite && (0...1).contains($0) }): return
            default: throw PortableArtifactError.invalid("Expected a finite number or four finite RGBA components in 0...1")
            }
        }

        fileprivate func value(for parameter: LerpParam) -> LerpParamValue? {
            switch (self, parameter.type) {
            case (.number(let n), .float) where Float(n).isFinite && n >= parameter.min && n <= parameter.max:
                return .scalar(n)
            case (.number(let n), .int) where Int32(exactly: n) != nil && n >= parameter.min && n <= parameter.max:
                return .scalar(n)
            case (.color(let c), .color): return .color(SIMD4(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3])))
            default: return nil
            }
        }
    }

    public struct Animation: Codable, Sendable, Equatable {
        public let low: Endpoint
        public let high: Endpoint
        public let period: Double

        public init(low: Endpoint, high: Endpoint, period: Double) throws {
            try low.validate()
            try high.validate()
            switch (low, high) {
            case (.number, .number), (.color, .color): break
            default: throw PortableArtifactError.invalid("Animation endpoints must have the same type")
            }
            guard period.isFinite, period > 0 else { throw PortableArtifactError.invalid("Animation period must be positive and finite") }
            self.low = low
            self.high = high
            self.period = period
        }

        private enum CodingKeys: String, CodingKey, CaseIterable { case low, high, period }

        public init(from decoder: Decoder) throws {
            let data = try decoder.strictObject(CodingKeys.self)
            try self.init(low: data.decode(Endpoint.self, forKey: .low), high: data.decode(Endpoint.self, forKey: .high),
                          period: data.decode(Double.self, forKey: .period))
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case animate }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let boolean = try? value.decode(Bool.self) { self = .bool(boolean) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let color = try? value.decode([Double].self) { self = .color(color) }
        else { self = .animate(try decoder.strictObject(CodingKeys.self).decode(Animation.self, forKey: .animate)) }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        switch self {
        case .number(let number):
            var value = encoder.singleValueContainer(); try value.encode(number)
        case .bool(let boolean):
            var value = encoder.singleValueContainer(); try value.encode(boolean)
        case .color(let color):
            var value = encoder.singleValueContainer(); try value.encode(color)
        case .animate(let animation):
            var value = encoder.container(keyedBy: CodingKeys.self); try value.encode(animation, forKey: .animate)
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .number(let number): try Endpoint.number(number).validate()
        case .color(let color): try Endpoint.color(color).validate()
        case .bool, .animate: break
        }
    }
}

/// The declared parameters and presets, as returned by the existing shader parser.
public typealias ShaderParameterSchema = LerpParamParser.Output

public struct PortableLook: PortableArtifact, Equatable {
    public static let kind: PortableReference.Kind = .look
    public let v = 1
    public let kind = PortableLook.kind
    public let title: String
    public let piece: PortableReference
    public let preset: String?
    public let tuning: [String: PortableTuning]
    public let authors: [String]
    public let remixedFrom: PortableReference?
    public let license: String?

    public init(title: String, piece: PortableReference, preset: String?, tuning: [String: PortableTuning],
                authors: [String], remixedFrom: PortableReference? = nil, license: String? = nil) throws {
        guard piece.kind == .piece else { throw PortableArtifactError.invalid("Look must name an exact Piece") }
        try checkCredit(authors: authors, remixedFrom: remixedFrom, license: license)
        for (key, value) in tuning {
            guard LerpParamParser.isIdentifier(key) else { throw PortableArtifactError.invalid("Invalid tuning name: \(key)") }
            try value.validate()
        }
        self.title = title
        self.piece = piece
        self.preset = preset
        self.tuning = tuning
        self.authors = authors
        self.remixedFrom = remixedFrom
        self.license = license
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case v, kind, title, piece, preset, tuning, authors, remixedFrom, license }

    public init(from decoder: Decoder) throws {
        let data = try decoder.strictObject(CodingKeys.self)
        try data.checkHeader(Self.kind, v: .v, kind: .kind)
        try self.init(title: data.decode(String.self, forKey: .title), piece: data.decode(PortableReference.self, forKey: .piece),
                      preset: data.decode(String?.self, forKey: .preset), tuning: data.decode([String: PortableTuning].self, forKey: .tuning),
                      authors: data.decode([String].self, forKey: .authors), remixedFrom: data.optional(.remixedFrom), license: data.optional(.license))
    }

    public func encode(to encoder: Encoder) throws {
        var data = encoder.container(keyedBy: CodingKeys.self)
        try data.encode(v, forKey: .v)
        try data.encode(kind, forKey: .kind)
        try data.encode(title, forKey: .title)
        try data.encode(piece, forKey: .piece)
        try data.encode(preset, forKey: .preset) // required, including explicit null
        try data.encode(tuning, forKey: .tuning)
        try data.encode(authors, forKey: .authors)
        try data.encodeIfPresent(remixedFrom, forKey: .remixedFrom)
        try data.encodeIfPresent(license, forKey: .license)
    }

    /// The caller supplies the schema read from the verified Piece source and
    /// its address, not a shader name or a schema from a local substitute.
    public func parameterValues(for piece: PortableReference, schema: ShaderParameterSchema) throws -> LerpParameterValues {
        guard piece == self.piece, schema.errors.isEmpty else {
            throw PortableArtifactError.invalid("Look's Piece or parameter schema does not match")
        }
        var parameters: [String: LerpParam] = [:]
        for param in schema.parameters {
            guard parameters.updateValue(param, forKey: param.name) == nil,
                  param.min.isFinite, param.max.isFinite, param.min <= param.max,
                  Self.fits(param.defaultValue, parameter: param),
                  param.animation.map({ Self.fits($0, parameter: param) }) != false else {
                throw PortableArtifactError.invalid("Invalid parameter in schema: \(param.name)")
            }
        }
        var values = LerpParameterValues(schema.parameters)
        if let preset {
            let matches = schema.presets.filter { $0.name.utf8.elementsEqual(preset.utf8) }
            guard matches.count == 1, let match = matches.first else {
                throw PortableArtifactError.invalid("Exact preset not found: \(preset)")
            }
            guard match.values.allSatisfy({ name, value in
                parameters[name].map { Self.fits(value, parameter: $0) } == true
            }), match.animations.allSatisfy({ name, animation in
                match.values[name] == nil && parameters[name].map { Self.fits(animation, parameter: $0) } == true
            }) else { throw PortableArtifactError.invalid("Invalid values in preset: \(preset)") }
            values.apply(match)
        }
        for name in tuning.keys.sorted() {
            guard let param = parameters[name], param.name.utf8.elementsEqual(name.utf8) else {
                throw PortableArtifactError.invalid("Unknown parameter: \(name)")
            }
            let setting = tuning[name]!
            switch setting {
            case .animate(let animation):
                guard param.type == .float || param.type == .color,
                      let low = animation.low.value(for: param), let high = animation.high.value(for: param) else {
                    throw PortableArtifactError.invalid("Invalid animation for \(name)")
                }
                let resolved = LerpParamAnimation(low: low, high: high, period: animation.period)
                guard Self.fits(resolved, parameter: param) else {
                    throw PortableArtifactError.invalid("Invalid animation for \(name)")
                }
                values.animate(name, with: resolved)
            case .bool(let value) where param.type == .bool:
                values.set(name, to: value ? 1 : 0)
            default:
                let value: LerpParamValue?
                switch setting {
                case .number(let number): value = PortableTuning.Endpoint.number(number).value(for: param)
                case .color(let color): value = PortableTuning.Endpoint.color(color).value(for: param)
                default: value = nil
                }
                guard let value else { throw PortableArtifactError.invalid("Wrong type or out-of-range value for \(name)") }
                values.set(name, value)
            }
        }
        return values
    }

    private static func fits(_ value: LerpParamValue, parameter: LerpParam) -> Bool {
        switch (parameter.type, value) {
        case (.bool, .scalar(let n)): return n == 0 || n == 1
        case (.float, .scalar(let n)), (.int, .scalar(let n)):
            return PortableTuning.Endpoint.number(n).value(for: parameter) != nil
        case (.color, .color(let c)):
            return (0..<4).allSatisfy { c[$0].isFinite && (0...1).contains(c[$0]) }
        default: return false
        }
    }

    private static func fits(_ animation: LerpParamAnimation, parameter: LerpParam) -> Bool {
        (parameter.type == .float || parameter.type == .color) && animation.low != animation.high
            && animation.period.isFinite && animation.period >= LerpParamAnimation.minimumPeriod
            && fits(animation.low, parameter: parameter) && fits(animation.high, parameter: parameter)
    }
}

public struct PortablePlaylist: PortableArtifact, Equatable {
    public static let kind: PortableReference.Kind = .playlist
    public let v = 1
    public let kind = PortablePlaylist.kind
    public let title: String
    public let looks: [PortableReference]

    public init(title: String, looks: [PortableReference]) throws {
        guard (1...100).contains(looks.count), Set(looks).count == looks.count, looks.allSatisfy({ $0.kind == .look }) else {
            throw PortableArtifactError.invalid("Playlist must contain 1–100 distinct Look references")
        }
        self.title = title
        self.looks = looks
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case v, kind, title, looks }

    public init(from decoder: Decoder) throws {
        let data = try decoder.strictObject(CodingKeys.self)
        try data.checkHeader(Self.kind, v: .v, kind: .kind)
        try self.init(title: data.decode(String.self, forKey: .title), looks: data.decode([PortableReference].self, forKey: .looks))
    }
}

public enum PortableLineage {
    public enum Record: Sendable { case piece(PortablePiece), look(PortableLook) }
    public enum End: Equatable, Sendable { case root, missing(PortableReference), cycle(PortableReference), hopLimit(PortableReference) }

    public struct Credit: Equatable, Sendable {
        public let reference: PortableReference
        public let authors: [String]
    }

    public struct Resolution: Equatable, Sendable {
        /// Immediate parent first. Credit comes from each loaded parent record.
        public let credits: [Credit]
        public let end: End
    }

    public static let maxHops = 32

    /// `load` is the caller's verified content-addressed record store. This
    /// method never follows a URL supplied by a record and does not fetch blobs.
    public static func resolve(from parent: PortableReference?,
                               load: (PortableReference) throws -> Record?) rethrows -> Resolution {
        var credits: [Credit] = []
        var seen: Set<PortableReference> = []
        var cursor = parent
        while let ref = cursor {
            if !seen.insert(ref).inserted { return Resolution(credits: credits, end: .cycle(ref)) }
            if credits.count == maxHops { return Resolution(credits: credits, end: .hopLimit(ref)) }
            switch (ref.kind, try load(ref)) {
            case (.piece, .piece(let piece)):
                credits.append(Credit(reference: ref, authors: piece.authors ?? []))
                cursor = piece.remixedFrom
            case (.look, .look(let look)):
                credits.append(Credit(reference: ref, authors: look.authors))
                cursor = look.remixedFrom
            default: return Resolution(credits: credits, end: .missing(ref))
            }
        }
        return Resolution(credits: credits, end: .root)
    }
}
