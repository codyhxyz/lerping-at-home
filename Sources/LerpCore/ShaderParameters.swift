import Foundation

/// Per-shader tunable parameters, declared in the `.metal` file itself.
///
/// A shader declares a parameter with a comment directive anywhere in the file:
///
///     // lerp-param: distortion float 0 1 = 0.8 "Distortion"
///     // lerp-param: colorCount int 1 5 = 5 "Color count"
///     // lerp-param: mirrored bool = false "Mirrored"
///     // lerp-param: colorBack color = #06111C "Background"
///
/// and named presets the same way:
///
///     // lerp-preset: Lagoon      distortion=0.8, swirl=0.35
///     // lerp-preset: "Deep Sea"  distortion=0.2, colorBack=#000308
///
/// The declared parameters are appended to `struct LerpUniforms` in the
/// generated prelude, so the shader reads them as `u.distortion`, `u.colorBack`
/// and so on with **no change to the `lerpMain` signature**. `LerpUniforms`
/// stays at fragment buffer index 0 and data providers keep index 1 and up, so
/// parameters and providers compose and a shader that declares neither is bound
/// exactly as it always was.
///
/// The `.metal` file therefore remains the single source of truth: a custom
/// shader dropped into `~/Library/Application Support/Lerping/Shaders` carries
/// its parameters and presets with it, with no sidecar file to install.

// MARK: - Model

public enum LerpParamType: String, Sendable, CaseIterable {
    /// Continuous value. MSL type `float`.
    case float
    /// Whole number — loop counts, palette sizes. MSL type `int`.
    case int
    /// Toggle. MSL type `int`, always 0 or 1 (MSL `bool` is one byte, which
    /// makes the uniform layout fiddly for no benefit).
    case bool
    /// RGBA colour, components 0…1. MSL type `float4`.
    case color

    /// MSL type name emitted into the generated `LerpUniforms`.
    var mslType: String { self == .color ? "float4" : (self == .float ? "float" : "int") }

    var isColor: Bool { self == .color }
}

public enum LerpParamValue: Sendable, Equatable {
    case scalar(Double)
    case color(SIMD4<Float>)

    public var scalarValue: Double? {
        if case .scalar(let v) = self { return v }
        return nil
    }

    public var colorValue: SIMD4<Float>? {
        if case .color(let v) = self { return v }
        return nil
    }

    /// How the value is written back out in a `lerp-param:`/`lerp-preset:` line.
    ///
    /// Every spelling this produces re-parses to a value that **packs to the
    /// same bytes**. `LerpParamLayout` stores floats and colour components as
    /// `Float`, and that block is literally what the fragment shader is handed,
    /// so two spellings that agree there are the same look and nothing
    /// downstream can tell them apart.
    ///
    /// That guarantee is not decoration. This used to be plain `%g` — six
    /// significant digits against a `Float`'s seven-and-a-bit — which is fine
    /// for the error messages that were its only caller and not fine at all now
    /// that something writes a *file* with it: the playground saves the values
    /// on screen as a `// lerp-preset:` block through here (see
    /// `LerpPresetWriter`). Checked by writing every one of the tree's 122 parameterized looks
    /// back out with a colour well's worth of precision on it — six digits loses
    /// the last bit of the mantissa often enough to change the colour on the
    /// screen, and the tuple form needs up to nine.
    ///
    /// The short spelling is still tried first, so a value that arrived as
    /// `#ff7a1a` or as a typed `0.35` is written the way a human wrote it and
    /// the `.metal` files stay readable. Only a value that cannot survive that
    /// pays for the long form.
    public var literal: String {
        switch self {
        case .scalar(let v):
            return Self.shortest(v)
        case .color(let c):
            // Hex whenever every component lands exactly on an 8-bit step,
            // which is what a colour that came from `#rrggbb` — or from a
            // colour well the user picked a web colour in — does. That is the
            // form every shader in the tree uses, and it survives the round
            // trip by construction.
            if let hex = Self.hex(c) { return hex }
            return "(" + [c.x, c.y, c.z, c.w].map { Self.shortest(Double($0)) }
                                             .joined(separator: ", ") + ")"
        }
    }

    /// The shortest text that parses back to the same `Float`: a whole number
    /// as itself, then `%g`, then `Float`'s own description — which is by
    /// definition the shortest decimal that round-trips, and nine digits at
    /// worst.
    private static func shortest(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        let short = String(format: "%g", value)
        if let parsed = Double(short), Float(parsed) == Float(value) { return short }
        return String(Float(value))
    }

    /// `#rrggbb`, or `#rrggbbaa` when the colour is not opaque — nil when any
    /// component sits between two 8-bit steps and hex would round it.
    private static func hex(_ c: SIMD4<Float>) -> String? {
        guard let red = Self.byte(c.x), let green = Self.byte(c.y),
              let blue = Self.byte(c.z), let alpha = Self.byte(c.w) else { return nil }
        return String(format: "#%02x%02x%02x", red, green, blue)
            + (alpha == 255 ? "" : String(format: "%02x", alpha))
    }

    /// The 8-bit step this component sits exactly on, or nil if it is between
    /// two. "Exactly" is measured the way `LerpParamParser.parseColor` will read
    /// it back — `Float(byte) / 255` — rather than by rounding and hoping.
    private static func byte(_ component: Float) -> UInt8? {
        guard component >= 0, component <= 1 else { return nil }
        let byte = UInt8((component * 255).rounded())
        return Float(byte) / 255 == component ? byte : nil
    }
}

public struct LerpParam: Sendable, Equatable {
    public let name: String
    public let type: LerpParamType
    /// Slider bounds. Meaningless (0/1) for `color`.
    public let min: Double
    public let max: Double
    public let defaultValue: LerpParamValue
    public let label: String
    /// 1-based line in the shader file the declaration came from.
    public let line: Int

    public init(name: String, type: LerpParamType, min: Double, max: Double,
                defaultValue: LerpParamValue, label: String, line: Int = 0) {
        self.name = name
        self.type = type
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.label = label
        self.line = line
    }

    /// Clamps to the declared range and snaps int/bool to whole numbers.
    /// Colours are clamped per component to 0…1.
    public func clamp(_ value: LerpParamValue) -> LerpParamValue {
        switch (type, value) {
        case (.color, .color(let c)):
            return .color(SIMD4<Float>(Swift.min(Swift.max(c.x, 0), 1),
                                       Swift.min(Swift.max(c.y, 0), 1),
                                       Swift.min(Swift.max(c.z, 0), 1),
                                       Swift.min(Swift.max(c.w, 0), 1)))
        case (.bool, .scalar(let v)):
            return .scalar(v != 0 ? 1 : 0)
        case (.int, .scalar(let v)):
            return .scalar(Swift.min(Swift.max(v.rounded(), min), max))
        case (.float, .scalar(let v)):
            return .scalar(Swift.min(Swift.max(v, min), max))
        default:
            return defaultValue      // type mismatch: fall back rather than emit garbage
        }
    }
}

public struct LerpPreset: Sendable, Equatable {
    public let name: String
    /// Only the parameters the preset overrides; the rest keep their defaults.
    public let values: [String: LerpParamValue]
    public let line: Int

    public init(name: String, values: [String: LerpParamValue], line: Int = 0) {
        self.name = name
        self.values = values
        self.line = line
    }
}

/// A malformed `// lerp-param:` / `// lerp-preset:` line. Compiling a shader
/// that has any of these fails with all of them listed, rather than silently
/// ignoring the typo and rendering with the wrong value.
public struct LerpParamError: Error, Sendable, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public let text: String

    public var description: String { "line \(line): \(message)  —  \(text)" }
}

// MARK: - Uniform-block layout

/// Byte layout of the fragment buffer 0 payload: the fixed 16-byte
/// `LerpUniforms` header followed by the shader's declared parameters.
///
/// Fields are emitted colours first (`float4`, 16-byte aligned, and the header
/// is exactly 16 bytes so the first one lands flush), then every scalar
/// (`float`/`int`, 4 bytes each) in declaration order. Fixing the order this
/// way makes the offsets computable with two multiplications and keeps the
/// Swift packer and the generated MSL struct trivially in step.
public enum LerpParamLayout {
    public static let headerSize: Int = {
        let stride = MemoryLayout<LerpUniforms>.stride
        precondition(stride == 16, "Swift LerpUniforms must match Metal's 16-byte fixed header")
        return stride
    }()

    /// Declaration order rearranged into memory order.
    public static func fieldOrder(_ params: [LerpParam]) -> [LerpParam] {
        params.filter(\.type.isColor) + params.filter { !$0.type.isColor }
    }

    /// Size in bytes of the parameter block that follows the 16-byte header,
    /// rounded up to a multiple of 16 (the alignment `float4` forces).
    public static func tailSize(_ params: [LerpParam]) -> Int {
        guard !params.isEmpty else { return 0 }
        let colors = params.filter(\.type.isColor).count
        let scalars = params.count - colors
        let raw = colors * 16 + scalars * 4
        return (raw + 15) / 16 * 16
    }

    /// Offset of each parameter measured from the start of the tail (i.e. from
    /// byte 16 of the buffer).
    public static func tailOffsets(_ params: [LerpParam]) -> [String: Int] {
        var offsets: [String: Int] = [:]
        var cursor = 0
        for param in fieldOrder(params) {
            offsets[param.name] = cursor
            cursor += param.type.isColor ? 16 : 4
        }
        return offsets
    }

    /// The generated MSL field declarations, in memory order.
    public static func mslFields(_ params: [LerpParam]) -> String {
        fieldOrder(params).map { param in
            let type = param.type.mslType.padding(toLength: 6, withPad: " ", startingAt: 0)
            let note = param.type == .bool ? "  // 0 or 1" : ""
            return "    \(type) \(param.name);\(note)"
        }.joined(separator: "\n")
    }
}

// MARK: - Live values

/// The current value of every parameter a shader declares, plus the packed
/// bytes the renderer appends to `LerpUniforms`. Starts at the declared
/// defaults, so constructing one and doing nothing else reproduces exactly what
/// the shader looked like before it had parameters.
public struct LerpParameterValues: Sendable {
    public let parameters: [LerpParam]
    public private(set) var values: [String: LerpParamValue]
    /// Bytes that follow the 16-byte `LerpUniforms` header. Empty when the
    /// shader declares no parameters — the renderer then takes the old path.
    public private(set) var packedTail: [UInt8]

    public init(_ parameters: [LerpParam]) {
        self.parameters = parameters
        self.values = Self.declaredDefaults(parameters)
        self.packedTail = []
        repack()
    }

    /// Every parameter at the value its declaration gives it — the state this
    /// starts in, and the state a preset is applied *on top of*.
    private static func declaredDefaults(_ parameters: [LerpParam]) -> [String: LerpParamValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.defaultValue) })
    }

    public subscript(name: String) -> LerpParamValue? { values[name] }

    public func parameter(named name: String) -> LerpParam? {
        parameters.first { $0.name == name }
    }

    @discardableResult
    public mutating func set(_ name: String, _ value: LerpParamValue) -> Bool {
        guard let param = parameter(named: name) else { return false }
        values[name] = param.clamp(value)
        repack()
        return true
    }

    @discardableResult
    public mutating func set(_ name: String, to number: Double) -> Bool {
        set(name, .scalar(number))
    }

    /// Applies a preset on top of the *defaults* — parameters the preset does
    /// not mention go back to their declared default, which is what "switch to
    /// this preset" means everywhere else.
    public mutating func apply(_ preset: LerpPreset) {
        values = Self.declaredDefaults(parameters)
        for (name, value) in preset.values {
            guard let param = parameter(named: name) else { continue }
            values[name] = param.clamp(value)
        }
        repack()
    }

    private mutating func repack() {
        let size = LerpParamLayout.tailSize(parameters)
        var bytes = [UInt8](repeating: 0, count: size)
        guard size > 0 else { packedTail = bytes; return }
        let offsets = LerpParamLayout.tailOffsets(parameters)
        for param in parameters {
            guard let offset = offsets[param.name] else { continue }
            let value = values[param.name] ?? param.defaultValue
            switch (param.type, value) {
            case (.color, .color(let c)):
                withUnsafeBytes(of: c) { bytes.replaceSubrange(offset..<(offset + 16), with: $0) }
            case (.float, .scalar(let v)):
                withUnsafeBytes(of: Float(v)) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
            case (.int, .scalar(let v)), (.bool, .scalar(let v)):
                withUnsafeBytes(of: Int32(v.rounded())) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
            default:
                break
            }
        }
        packedTail = bytes
    }
}

// MARK: - Parser

public enum LerpParamParser {
    public struct Output: Sendable {
        public var parameters: [LerpParam] = []
        public var presets: [LerpPreset] = []
        public var errors: [LerpParamError] = []
    }

    public static let paramDirective = "lerp-param:"
    public static let presetDirective = "lerp-preset:"

    /// The text after `// <directive>` on this line, or nil when the line does
    /// not carry that directive.
    ///
    /// The one statement of what a directive line looks like — leading
    /// whitespace, `//`, optional whitespace, the directive case-insensitively,
    /// and the rest. `parse` reads lines through it, and so does the
    /// playground's preset writer when it looks for where a file's existing
    /// declarations end (`PresetScaffold.inserting`). A file is therefore
    /// scanned for directives by exactly the rule that will later parse them,
    /// rather than by a second almost-identical one that drifts.
    public static func directiveBody(_ raw: some StringProtocol, _ directive: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("//") else { return nil }
        let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard body.lowercased().hasPrefix(directive) else { return nil }
        return String(body.dropFirst(directive.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Scans the whole file (not just the header) for parameter and preset
    /// directives. Anything that is not a `// lerp-…:` comment is ignored, so
    /// this is safe to run over arbitrary Metal source.
    public static func parse(source: String) -> Output {
        var out = Output()
        var presetOrder: [String] = []
        var presetValues: [String: [String: LerpParamValue]] = [:]
        var presetLine: [String: Int] = [:]

        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = index + 1

            if let text = directiveBody(raw, paramDirective) {
                do {
                    let param = try parseParam(text, line: line)
                    if param.name == "resolution" || param.name == "time" || param.name == "seed" {
                        throw fail(line, text, "`\(param.name)` is a built-in uniform field and cannot be a parameter name")
                    }
                    if out.parameters.contains(where: { $0.name == param.name }) {
                        throw fail(line, text, "duplicate parameter name `\(param.name)`")
                    }
                    out.parameters.append(param)
                } catch let error as LerpParamError {
                    out.errors.append(error)
                } catch {
                    out.errors.append(LerpParamError(line: line, message: "\(error)", text: text))
                }
            } else if let text = directiveBody(raw, presetDirective) {
                do {
                    let (name, values) = try parsePreset(text, line: line)
                    if presetValues[name] == nil {
                        presetOrder.append(name)
                        presetLine[name] = line
                    }
                    presetValues[name, default: [:]].merge(values) { _, new in new }
                } catch let error as LerpParamError {
                    out.errors.append(error)
                } catch {
                    out.errors.append(LerpParamError(line: line, message: "\(error)", text: text))
                }
            }
        }

        // Presets are validated against the declared parameters once all of
        // both have been seen, so declaration order in the file doesn't matter.
        for name in presetOrder {
            let values = presetValues[name] ?? [:]
            let line = presetLine[name] ?? 0
            var checked: [String: LerpParamValue] = [:]
            for (key, value) in values {
                guard let param = out.parameters.first(where: { $0.name == key }) else {
                    out.errors.append(LerpParamError(line: line,
                        message: "preset `\(name)` sets `\(key)`, which is not a declared parameter",
                        text: key + "=" + value.literal))
                    continue
                }
                let typeMatches = param.type.isColor ? (value.colorValue != nil) : (value.scalarValue != nil)
                guard typeMatches else {
                    out.errors.append(LerpParamError(line: line,
                        message: "preset `\(name)` gives `\(key)` a value of the wrong type for a \(param.type.rawValue) parameter",
                        text: key + "=" + value.literal))
                    continue
                }
                checked[key] = param.clamp(value)
            }
            out.presets.append(LerpPreset(name: name, values: checked, line: line))
        }
        out.errors.sort { $0.line < $1.line }
        return out
    }

    static func fail(_ line: Int, _ text: String, _ message: String) -> LerpParamError {
        LerpParamError(line: line, message: message, text: text)
    }

    /// The spellings a `bool` may be written in, as the 1/0 it is stored as.
    ///
    /// One table, because there is one language. A declaration and a preset are
    /// two directives in the same file talking about the same parameter, and
    /// they used to read booleans by two different rules: `// lerp-param:
    /// mirrored bool = on` was accepted and `// lerp-preset: P mirrored=on`
    /// three lines below it was a parse error that said `on` was not a bool.
    static func boolean(_ text: String) -> Double? {
        switch text.lowercased() {
        case "true", "1", "yes", "on":   return 1
        case "false", "0", "no", "off":  return 0
        default:                         return nil
        }
    }

    /// `NAME TYPE [MIN MAX] = DEFAULT ["Label"]`
    static func parseParam(_ text: String, line: Int) throws -> LerpParam {
        // Peel the optional trailing quoted label first so it can contain
        // anything, including `=` and digits.
        var head = text
        var label: String?
        if let open = text.firstIndex(of: "\""), let close = text.lastIndex(of: "\""), open < close {
            label = String(text[text.index(after: open)..<close])
            head = String(text[text.startIndex..<open])
        } else if text.contains("\"") {
            throw fail(line, text, "unterminated label — labels are wrapped in double quotes")
        }

        guard let equals = head.firstIndex(of: "=") else {
            throw fail(line, text, "missing `= DEFAULT` (syntax: NAME TYPE [MIN MAX] = DEFAULT \"Label\")")
        }
        let declText = String(head[head.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let defaultText = String(head[head.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        let decl = declText.split(whereSeparator: \.isWhitespace).map(String.init)

        guard decl.count >= 2 else {
            throw fail(line, text, "expected at least NAME and TYPE before `=` (syntax: NAME TYPE [MIN MAX] = DEFAULT \"Label\")")
        }
        let name = decl[0]
        guard isIdentifier(name) else {
            throw fail(line, text, "`\(name)` is not a valid parameter name (letters, digits and `_`, not starting with a digit)")
        }
        guard let type = LerpParamType(rawValue: decl[1].lowercased()) else {
            throw fail(line, text, "unknown type `\(decl[1])` — expected one of \(LerpParamType.allCases.map(\.rawValue).joined(separator: ", "))")
        }

        var min = 0.0, max = 1.0
        switch type {
        case .float, .int:
            guard decl.count == 4 else {
                throw fail(line, text, "a \(type.rawValue) parameter needs MIN and MAX: `\(name) \(type.rawValue) <min> <max> = <default>`")
            }
            guard let parsedMin = Double(decl[2]), let parsedMax = Double(decl[3]) else {
                throw fail(line, text, "MIN and MAX must be numbers, got `\(decl[2])` and `\(decl[3])`")
            }
            guard parsedMin <= parsedMax else {
                throw fail(line, text, "MIN (\(parsedMin)) is greater than MAX (\(parsedMax))")
            }
            min = parsedMin; max = parsedMax
        case .bool, .color:
            guard decl.count == 2 else {
                throw fail(line, text, "a \(type.rawValue) parameter takes no MIN/MAX: `\(name) \(type.rawValue) = <default>`")
            }
        }

        guard !defaultText.isEmpty else { throw fail(line, text, "missing default value after `=`") }
        let value: LerpParamValue
        switch type {
        case .color:
            value = try parseColor(defaultText, line: line, text: text)
        case .bool:
            guard let flag = boolean(defaultText) else {
                throw fail(line, text, "a bool default must be `true` or `false`, got `\(defaultText)`")
            }
            value = .scalar(flag)
        case .int:
            guard let number = Double(defaultText), number == number.rounded() else {
                throw fail(line, text, "an int default must be a whole number, got `\(defaultText)`")
            }
            guard number >= min, number <= max else {
                throw fail(line, text, "default \(defaultText) is outside the declared range \(min)…\(max)")
            }
            value = .scalar(number)
        case .float:
            guard let number = Double(defaultText) else {
                throw fail(line, text, "a float default must be a number, got `\(defaultText)`")
            }
            guard number >= min, number <= max else {
                throw fail(line, text, "default \(defaultText) is outside the declared range \(min)…\(max)")
            }
            value = .scalar(number)
        }

        return LerpParam(name: name, type: type, min: min, max: max,
                         defaultValue: value, label: label ?? humanize(name), line: line)
    }

    /// `NAME key=value, key=value` — NAME may be `"quoted with spaces"`.
    /// Repeating the same NAME on later lines merges into one preset, so a long
    /// preset can be split across several comment lines.
    static func parsePreset(_ text: String, line: Int) throws -> (String, [String: LerpParamValue]) {
        var name = ""
        var rest = Substring(text)
        if text.hasPrefix("\"") {
            guard let close = text.dropFirst().firstIndex(of: "\"") else {
                throw fail(line, text, "unterminated preset name — expected a closing double quote")
            }
            name = String(text[text.index(after: text.startIndex)..<close])
            rest = text[text.index(after: close)...]
        } else {
            guard let space = text.firstIndex(where: \.isWhitespace) else {
                throw fail(line, text, "a preset needs at least one `name=value` assignment")
            }
            name = String(text[text.startIndex..<space])
            rest = text[space...]
        }
        guard !name.isEmpty else { throw fail(line, text, "preset name is empty") }

        var values: [String: LerpParamValue] = [:]
        for assignment in splitTopLevel(String(rest), on: ",") {
            let piece = assignment.trimmingCharacters(in: .whitespaces)
            if piece.isEmpty { continue }
            guard let equals = piece.firstIndex(of: "=") else {
                throw fail(line, text, "`\(piece)` is not a `name=value` assignment")
            }
            let key = String(piece[piece.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let raw = String(piece[piece.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard isIdentifier(key) else { throw fail(line, text, "`\(key)` is not a valid parameter name") }
            guard !raw.isEmpty else { throw fail(line, text, "`\(key)=` has no value") }
            if raw.hasPrefix("#") || raw.hasPrefix("(") {
                values[key] = try parseColor(raw, line: line, text: text)
            } else if let flag = boolean(raw) {
                values[key] = .scalar(flag)
            } else if let number = Double(raw) {
                values[key] = .scalar(number)
            } else {
                throw fail(line, text, "`\(raw)` is not a number, bool or colour")
            }
        }
        guard !values.isEmpty else { throw fail(line, text, "preset `\(name)` sets nothing") }
        return (name, values)
    }

    /// `#RGB`, `#RRGGBB`, `#RRGGBBAA`, or `(r, g, b[, a])` with components 0…1.
    /// The float form exists so a palette that was hardcoded as float literals
    /// can become a parameter without any rounding through 8-bit hex.
    static func parseColor(_ text: String, line: Int, text full: String) throws -> LerpParamValue {
        if text.hasPrefix("(") {
            guard text.hasSuffix(")") else { throw fail(line, full, "colour `\(text)` is missing its closing `)`") }
            let inner = String(text.dropFirst().dropLast())
            let parts = splitTopLevel(inner, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 || parts.count == 4 else {
                throw fail(line, full, "colour `\(text)` needs 3 or 4 components")
            }
            let numbers = parts.compactMap(Double.init)
            guard numbers.count == parts.count else {
                throw fail(line, full, "colour `\(text)` has a non-numeric component")
            }
            return .color(SIMD4<Float>(Float(numbers[0]), Float(numbers[1]), Float(numbers[2]),
                                       Float(numbers.count == 4 ? numbers[3] : 1.0)))
        }
        guard text.hasPrefix("#") else {
            throw fail(line, full, "colour `\(text)` must be `#RGB`, `#RRGGBB`, `#RRGGBBAA` or `(r, g, b[, a])`")
        }
        var hex = String(text.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, hex.allSatisfy(\.isHexDigit) else {
            throw fail(line, full, "colour `\(text)` must be `#RGB`, `#RRGGBB` or `#RRGGBBAA`")
        }
        var bytes: [Float] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(Float(UInt8(hex[index..<next], radix: 16) ?? 0) / 255.0)
            index = next
        }
        return .color(SIMD4<Float>(bytes[0], bytes[1], bytes[2], bytes.count == 4 ? bytes[3] : 1.0))
    }

    /// Splits on a separator that is not inside parentheses, so the float
    /// colour form `(0.1, 0.2, 0.3)` survives a comma-separated preset list.
    static func splitTopLevel(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == separator && depth == 0 {
                parts.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// `colorBack` → "Color Back", `distortion` → "Distortion".
    static func humanize(_ name: String) -> String {
        var out = ""
        for (index, character) in name.enumerated() {
            if character == "_" { out.append(" "); continue }
            if index > 0, character.isUppercase, out.last?.isLowercase == true { out.append(" ") }
            out.append(index == 0 ? Character(character.uppercased()) : character)
        }
        return out
    }
}

// MARK: - Writer

/// The other direction: live parameter values back out as the `// lerp-preset:`
/// lines the parser above reads. What the playground's "Save Look as Preset…"
/// writes into a `.metal` file.
///
/// It lives in this file, directly under the parser, because the two are one
/// contract read from two ends. A writer kept next to the UI that calls it is a
/// second, quieter definition of the syntax, and the two only have to disagree
/// once — about a quote, about a rounding — for a shader to stop compiling with
/// an error that points at a line nobody typed.
///
/// The round trip is exact in the sense that renders. Write a preset from what
/// is on screen, parse the file back, and `LerpShader.parameterValues(for:)`
/// returns a `LerpParameterValues` whose `packedTail` is byte-for-byte the one
/// the fragment shader was being handed — that is what
/// `LerpParamValue.literal`'s spelling rule buys, and it is the same "differing
/// packed bytes" test `--capture` already uses to prove a preset is really on.
public enum LerpPresetWriter {

    /// Why `name` cannot be used, or nil when it can.
    ///
    /// Three of these are limits of the declaration syntax and one is a limit of
    /// the UI, which is worth saying out loud:
    ///
    /// - Empty is `preset name is empty` from the parser, and a name that is
    ///   only spaces is the same thing after trimming.
    /// - A double quote cannot be written at all. `parsePreset` reads a quoted
    ///   name up to the *next* quote, so `Sea "Deep"` would either truncate or
    ///   fail to terminate depending on where the quote fell.
    /// - Tabs and newlines cannot survive a line-oriented comment directive.
    /// - "Defaults" is refused because it is already taken by the look every
    ///   shader has: `LerpRotationEntry.displayName` calls the no-preset entry
    ///   "Defaults", and the inspector's popup puts it at index 0 and reads
    ///   index 0 as "no preset". A preset actually called that would draw two
    ///   identically captioned tiles in both grids and be unselectable in the
    ///   popup, because picking it would select the item above it.
    ///
    /// Case is not compared here — that is the *shader's* question, since
    /// `LerpShader.preset(named:)` matches case-insensitively — except against
    /// "Defaults", which is reserved whatever its capitalisation for the same
    /// reason.
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return "A preset needs a name — the picker and the rotation gallery caption every look with it."
        }
        if trimmed.contains("\"") {
            return "A preset name cannot contain a double quote: the declaration wraps names in quotes, "
                + "so there is no way to write one that survives being read back."
        }
        if trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "A preset name cannot contain tabs or line breaks — a declaration is one comment line."
        }
        let reserved = LerpRotationEntry.defaultsName
        if trimmed.caseInsensitiveCompare(reserved) == .orderedSame {
            return "“\(reserved)” is the name every shader's *un*-preset look already goes by, "
                + "so a preset called that would be two looks with one caption. Pick another."
        }
        return nil
    }

    /// The parameters whose live value is not the declared default, in
    /// declaration order.
    ///
    /// A preset is an **overlay**, not a snapshot. `LerpParameterValues.apply`
    /// starts from the declared defaults and then sets only what the preset
    /// names, so a parameter written at its own default is a line that says
    /// nothing — and worse than nothing, because it freezes today's default into
    /// a file whose author may move it tomorrow, at which point the preset
    /// quietly stops following. The shaders in the tree are written this way by
    /// hand (`aurora`'s Quiet names four of eleven parameters); this is the same
    /// thing done from the sliders.
    public static func overrides(in values: LerpParameterValues)
        -> [(param: LerpParam, value: LerpParamValue)] {
        values.parameters.compactMap { param in
            guard let value = values[param.name], value != param.defaultValue else { return nil }
            return (param, value)
        }
    }

    /// The `// lerp-preset:` lines that declare `name` as these overrides.
    ///
    /// Wrapped across several lines rather than run out to any width, because a
    /// repeated name merges into one preset (`parsePreset`'s doc says so, and
    /// every multi-line preset in `Sources/Shaders` relies on it) and because a
    /// 300-column comment in a file people read in a 700-point editor pane is
    /// not a saving. `columns` is the budget for the whole line, prefix
    /// included; one assignment always goes on a line even if it blows it, since
    /// the alternative is a line with nothing on it.
    public static func declaration(name: String,
                                   overrides: [(param: LerpParam, value: LerpParamValue)],
                                   wrappingAt columns: Int = 92) -> [String] {
        let prefix = "// " + LerpParamParser.presetDirective + " " + quoted(name) + "  "
        var lines: [String] = []
        var current: [String] = []
        for (param, value) in overrides {
            let assignment = param.name + "=" + literal(value, as: param.type)
            if !current.isEmpty,
               prefix.count + (current + [assignment]).joined(separator: ", ").count > columns {
                lines.append(prefix + current.joined(separator: ", "))
                current = []
            }
            current.append(assignment)
        }
        if !current.isEmpty { lines.append(prefix + current.joined(separator: ", ")) }
        return lines
    }

    /// Quoted only when it has to be, so `Ember` is written `Ember` and
    /// `Sine Wave` is written `"Sine Wave"` — which is how the files already
    /// read. Anything else that would need quoting has been refused by
    /// `problem(withName:)`.
    static func quoted(_ name: String) -> String {
        name.contains(where: \.isWhitespace) ? "\"\(name)\"" : name
    }

    /// `LerpParamValue.literal`, except that a `bool` is written `true`/`false`
    /// rather than as the `1`/`0` it is stored as. The parser takes either; a
    /// file that declares `// lerp-param: mirrored bool = false` and then sets
    /// `mirrored=1` two lines down reads like two different settings.
    static func literal(_ value: LerpParamValue, as type: LerpParamType) -> String {
        guard type == .bool, let number = value.scalarValue else { return value.literal }
        return number != 0 ? "true" : "false"
    }
}
