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
/// and slow drift on a float or colour the same way — see
/// `LerpParamAnimation` for the curve and the purity rule it keeps:
///
///     // lerp-animate: distortion 0.6 0.9 period=180
///     // lerp-preset:  Still      distortion=0.8          (pins it)
///     // lerp-preset:  Restless   distortion=animate(0.2, 1, period=60)
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
    /// The file's `// lerp-animate:` for this parameter, or nil when it holds
    /// still. Part of the declaration — and therefore of the Defaults look —
    /// exactly as `defaultValue` is.
    public let animation: LerpParamAnimation?

    public init(name: String, type: LerpParamType, min: Double, max: Double,
                defaultValue: LerpParamValue, label: String, line: Int = 0,
                animation: LerpParamAnimation? = nil) {
        self.name = name
        self.type = type
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.label = label
        self.line = line
        self.animation = animation
    }

    /// This declaration with `animation` attached. The parser reads
    /// `// lerp-animate:` lines after every `// lerp-param:`, so the two may
    /// come in either order in the file.
    func withAnimation(_ animation: LerpParamAnimation?) -> LerpParam {
        LerpParam(name: name, type: type, min: min, max: max, defaultValue: defaultValue,
                  label: label, line: line, animation: animation)
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

/// A parameter that drifts on its own, declared beside its `// lerp-param:`:
///
///     // lerp-animate: foldRotation 0.2 0.6 period=180
///
/// ## Purity
///
/// The value is a closed-form function of `(time, seed, declaration)` —
/// `value(for:time:seed:)` — evaluated afresh for every frame, never stepped
/// or accumulated. `LerpRenderer.encodePass` is the one place that evaluates
/// it, from the very `LerpUniforms` the frame is drawn with, so `--snapshot
/// --time T`, the scrubber, the gallery's stills and the desktop handoff all
/// land on the same value at T no matter what was rendered before, and a data
/// provider's `params` overload sees the animated value, not the slider's.
///
/// ## The curve
///
/// Two sines, the second `goldenRatio` times faster than the first and a third
/// its weight. The ratio is irrational, so the sum never repeats and does not
/// read as a pendulum; both terms are smooth and dwell at their turning points,
/// so the motion eases in and out on its own. Their weights sum to 1, which
/// makes LOW…HIGH an *envelope*: the main swing alone covers the middle three
/// quarters of it, and the extremes are touched only when the two waves agree.
/// Phases come from `u.seed` and from the parameter's name, so every
/// activation starts somewhere different and two parameters with the same
/// period do not move in lock-step.
public struct LerpParamAnimation: Sendable, Equatable {
    /// One end of the drift. A scalar for a `float`, a colour for a `color`.
    public let low: LerpParamValue
    public let high: LerpParamValue
    /// Seconds for one swing of the main wave.
    public let period: Double

    /// What `period=` is when the declaration does not say.
    public static let defaultPeriod: Double = 120
    /// Faster than this is not drift, it is motion — and motion belongs in the
    /// shader, written against `u.time`, where it can be shaped properly.
    public static let minimumPeriod: Double = 10

    static let goldenRatio = 1.6180339887498949
    static let secondWeight = 0.25

    public init(low: LerpParamValue, high: LerpParamValue, period: Double = defaultPeriod) {
        self.low = low
        self.high = high
        self.period = period
    }

    /// 0…1: where between `low` and `high` this parameter is at `time`.
    ///
    /// Computed in `Double` from the `Float` time and seed the frame's uniforms
    /// carry, so every host that draws the same frame computes it from the same
    /// two numbers.
    public func position(name: String, time: Float, seed: Float) -> Double {
        let hash = LerpHash.fnv1a(name)
        let phaseA = Double(hash & 0xFFFF) / 65536
        let phaseB = Double((hash >> 16) & 0xFFFF) / 65536
        let s = Double(seed)
        let cycles = Double(time) / period
        let a = sin(2 * .pi * (cycles + Self.fract(s * 7 + phaseA)))
        let b = sin(2 * .pi * (cycles * Self.goldenRatio + Self.fract(s * 13 + phaseB)))
        let wave = (1 - Self.secondWeight) * a + Self.secondWeight * b
        return Swift.min(Swift.max(0.5 + 0.5 * wave, 0), 1)
    }

    /// The value `param` has at `time` under this animation, clamped to its
    /// declared range like any other value it can hold.
    public func value(for param: LerpParam, time: Float, seed: Float) -> LerpParamValue {
        let t = position(name: param.name, time: time, seed: seed)
        switch (low, high) {
        case (.scalar(let a), .scalar(let b)):
            return param.clamp(.scalar(a + (b - a) * t))
        case (.color(let a), .color(let b)):
            return param.clamp(.color(a + (b - a) * Float(t)))
        default:
            return param.defaultValue
        }
    }

    /// How it is written inside a preset: `animate(0.2, 0.6, period=180)`.
    public var presetLiteral: String {
        "animate(\(low.literal), \(high.literal), period=\(LerpParamValue.scalar(period).literal))"
    }

    /// How it is written on a `// lerp-animate:` line, after the name.
    public var declarationLiteral: String {
        "\(low.literal) \(high.literal) period=\(LerpParamValue.scalar(period).literal)"
    }

    private static func fract(_ x: Double) -> Double { x - x.rounded(.down) }
}

public struct LerpPreset: Sendable, Equatable {
    public let name: String
    /// Only the parameters the preset overrides; the rest keep their defaults.
    /// A parameter the file animates that is named here is **pinned** at this
    /// value: setting a value is a statement about what it is.
    public let values: [String: LerpParamValue]
    /// Parameters this preset sets animating, with the drift it runs —
    /// `name=animate` (the file's own `// lerp-animate:`) or
    /// `name=animate(LOW, HIGH[, period=S])`. Never shares a key with `values`.
    public let animations: [String: LerpParamAnimation]
    public let line: Int

    public init(name: String, values: [String: LerpParamValue],
                animations: [String: LerpParamAnimation] = [:], line: Int = 0) {
        self.name = name
        self.values = values
        self.animations = animations
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

/// Byte layout of the fragment buffer 0 payload: the fixed `LerpUniforms`
/// header (`headerSize` bytes) followed by the shader's declared parameters.
///
/// Fields are emitted colours first (`float4`, 16-byte aligned, and the header
/// is a multiple of 16 bytes so the first one lands flush), then every scalar
/// (`float`/`int`, 4 bytes each) in declaration order. Fixing the order this
/// way makes the offsets computable with two multiplications and keeps the
/// Swift packer and the generated MSL struct trivially in step.
public enum LerpParamLayout {
    /// Members of the fixed header, which a `// lerp-param:` may not reuse.
    public static let builtInFields: Set<String> = [
        "resolution", "time", "seed", "audioLevel", "audioBass", "audioMid", "audioTreble",
        "viewer",
    ]

    public static let headerSize: Int = {
        let stride = MemoryLayout<LerpUniforms>.stride
        // A multiple of 16 is what lets the first `float4` parameter sit
        // flush against the header; growing the head means padding it to one.
        precondition(stride == 48, "Swift LerpUniforms must match Metal's 48-byte fixed header")
        return stride
    }()

    /// Declaration order rearranged into memory order.
    public static func fieldOrder(_ params: [LerpParam]) -> [LerpParam] {
        params.filter(\.type.isColor) + params.filter { !$0.type.isColor }
    }

    /// Size in bytes of the parameter block that follows the fixed header,
    /// rounded up to a multiple of 16 (the alignment `float4` forces).
    public static func tailSize(_ params: [LerpParam]) -> Int {
        guard !params.isEmpty else { return 0 }
        let colors = params.filter(\.type.isColor).count
        let scalars = params.count - colors
        let raw = colors * 16 + scalars * 4
        return (raw + 15) / 16 * 16
    }

    /// Offset of each parameter measured from the start of the tail (i.e. from
    /// byte `headerSize` of the buffer).
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
    /// Each parameter's held value. For a parameter that is animating this is
    /// the value it returns to when pinned, not what is on screen — that is
    /// `resolved(time:seed:)`.
    public private(set) var values: [String: LerpParamValue]
    /// Bytes that follow the fixed `LerpUniforms` header. Empty when the
    /// shader declares no parameters — the renderer then takes the old path.
    /// Packs the held `values`; `LerpRenderer` binds `resolved(time:seed:)`'s.
    public private(set) var packedTail: [UInt8]
    /// The drift each parameter runs in this look when it is not pinned: the
    /// file's `// lerp-animate:`, or the worn preset's `name=animate(…)`.
    public private(set) var animations: [String: LerpParamAnimation]
    /// Parameters with an animation that are being held at their value
    /// instead — by a preset that set them, or by a person who moved them.
    public private(set) var pinned: Set<String> = []

    public init(_ parameters: [LerpParam]) {
        self.parameters = parameters
        self.values = Self.declaredDefaults(parameters)
        self.animations = Self.declaredAnimations(parameters)
        self.packedTail = []
        repack()
    }

    /// Every parameter at the value its declaration gives it — the state this
    /// starts in, and the state a preset is applied *on top of*.
    private static func declaredDefaults(_ parameters: [LerpParam]) -> [String: LerpParamValue] {
        Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.defaultValue) })
    }

    private static func declaredAnimations(_ parameters: [LerpParam]) -> [String: LerpParamAnimation] {
        Dictionary(uniqueKeysWithValues: parameters.compactMap { param in
            param.animation.map { (param.name, $0) }
        })
    }

    public subscript(name: String) -> LerpParamValue? { values[name] }

    public func parameter(named name: String) -> LerpParam? {
        parameters.first { $0.name == name }
    }

    /// Sets a held value. On a parameter that is animating this **pins** it —
    /// a value somebody chose is a value they want to see — so a dragged
    /// slider, a MIDI knob and `--param` all take control the same way.
    /// `setAnimating(_:true)` hands it back.
    @discardableResult
    public mutating func set(_ name: String, _ value: LerpParamValue) -> Bool {
        guard let param = parameter(named: name) else { return false }
        values[name] = param.clamp(value)
        if animations[name] != nil { pinned.insert(name) }
        repack()
        return true
    }

    @discardableResult
    public mutating func set(_ name: String, to number: Double) -> Bool {
        set(name, .scalar(number))
    }

    /// Whether `name` is drifting right now: it has an animation in this look
    /// and nothing has pinned it.
    public func isAnimating(_ name: String) -> Bool {
        animations[name] != nil && !pinned.contains(name)
    }

    /// The animations that are running, keyed by parameter.
    public var activeAnimations: [String: LerpParamAnimation] {
        animations.filter { !pinned.contains($0.key) }
    }

    /// Starts or stops `name`'s drift. Stopping leaves it at its held value,
    /// so a caller that wants it to stay where it was on screen sets that
    /// value (which pins it) instead. False when this look gives `name` no
    /// animation to run.
    @discardableResult
    public mutating func setAnimating(_ name: String, _ on: Bool) -> Bool {
        guard animations[name] != nil else { return false }
        if on { pinned.remove(name) } else { pinned.insert(name) }
        return true
    }

    /// These values as the frame at `(time, seed)` sees them: every animating
    /// parameter replaced by its value on the curve, and repacked. Pure — the
    /// same three inputs give the same bytes whatever was asked before — and
    /// `self` unchanged when nothing animates, so a look without
    /// `// lerp-animate:` binds exactly the bytes it always did.
    public func resolved(time: Float, seed: Float) -> LerpParameterValues {
        let active = activeAnimations
        guard !active.isEmpty else { return self }
        var copy = self
        for param in parameters {
            guard let animation = active[param.name] else { continue }
            copy.values[param.name] = animation.value(for: param, time: time, seed: seed)
        }
        copy.repack()
        return copy
    }

    /// Whether two sets of values draw the same frames: the same drift on the
    /// same parameters, and the same bytes everywhere else. A held value under
    /// an animation is never seen, so it is not compared.
    public func rendersSameLook(as other: LerpParameterValues) -> Bool {
        activeAnimations == other.activeAnimations
            && resolved(time: 0, seed: 0).packedTail == other.resolved(time: 0, seed: 0).packedTail
    }

    /// Applies a preset on top of the *defaults* — parameters the preset does
    /// not mention go back to their declared default, which is what "switch to
    /// this preset" means everywhere else. That includes animation: a
    /// parameter the file animates keeps animating unless the preset names it.
    public mutating func apply(_ preset: LerpPreset) {
        values = Self.declaredDefaults(parameters)
        animations = Self.declaredAnimations(parameters)
        pinned = []
        for (name, value) in preset.values {
            guard let param = parameter(named: name) else { continue }
            values[name] = param.clamp(value)
            if animations[name] != nil { pinned.insert(name) }
        }
        for (name, animation) in preset.animations where parameter(named: name) != nil {
            animations[name] = animation
        }
        repack()
    }

    /// Sets `name` drifting with `animation`, replacing whatever drift this
    /// look gave it — what a preset's `name=animate(…)` does, for a host that
    /// has one in hand (`LerpPreview --param name=animate(…)`).
    @discardableResult
    public mutating func animate(_ name: String, with animation: LerpParamAnimation) -> Bool {
        guard parameter(named: name) != nil else { return false }
        animations[name] = animation
        pinned.remove(name)
        return true
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
    public static let animateDirective = "lerp-animate:"

    /// One assignment in a `// lerp-preset:` line: a value, which pins, or
    /// `animate` / `animate(…)`, which sets the parameter drifting.
    public enum PresetSetting: Sendable, Equatable {
        case value(LerpParamValue)
        case animate(AnimateSpec)

        var literal: String {
            switch self {
            case .value(let value): return value.literal
            case .animate(let spec): return spec.literal
            }
        }
    }

    /// An animation as written, before it is checked against the parameter it
    /// names: `// lerp-animate:`'s bounds and options, or a preset's
    /// `animate(…)`. Anything left nil is taken from the file's
    /// `// lerp-animate:` for that parameter, then from the built-in default.
    public struct AnimateSpec: Sendable, Equatable {
        public var low: LerpParamValue?
        public var high: LerpParamValue?
        public var period: Double?

        var literal: String {
            var parts: [String] = []
            if let low, let high { parts += [low.literal, high.literal] }
            if let period { parts.append("period=\(LerpParamValue.scalar(period).literal)") }
            return parts.isEmpty ? "animate" : "animate(" + parts.joined(separator: ", ") + ")"
        }
    }

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
        var presetValues: [String: [String: PresetSetting]] = [:]
        var presetLine: [String: Int] = [:]
        var animateLines: [(line: Int, text: String, name: String, spec: AnimateSpec)] = []

        for (index, raw) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = index + 1

            if let text = directiveBody(raw, paramDirective) {
                do {
                    let param = try parseParam(text, line: line)
                    if LerpParamLayout.builtInFields.contains(param.name) {
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
                    // Reserved for `shader/*` — see `LerpRotationEntry.wholeShaderPreset`.
                    if name == LerpRotationEntry.wholeShaderPreset {
                        throw fail(line, text, "`\(name)` is reserved: in the rotation it means every look of the shader")
                    }
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
            } else if let text = directiveBody(raw, animateDirective) {
                do {
                    let (name, spec) = try parseAnimateLine(text, line: line)
                    animateLines.append((line, text, name, spec))
                } catch let error as LerpParamError {
                    out.errors.append(error)
                } catch {
                    out.errors.append(LerpParamError(line: line, message: "\(error)", text: text))
                }
            }
        }

        // Animations are attached once every parameter has been seen, so a
        // `// lerp-animate:` may sit above or below the `// lerp-param:` it
        // names.
        var animated: Set<String> = []
        for entry in animateLines {
            guard let index = out.parameters.firstIndex(where: { $0.name == entry.name }) else {
                out.errors.append(fail(entry.line, entry.text,
                    "`\(entry.name)` is not a declared parameter — `// lerp-animate:` names a `// lerp-param:` in this file"))
                continue
            }
            guard animated.insert(entry.name).inserted else {
                out.errors.append(fail(entry.line, entry.text, "duplicate `// lerp-animate:` for `\(entry.name)`"))
                continue
            }
            do {
                let animation = try resolveAnimation(entry.spec, for: out.parameters[index], fallback: nil)
                out.parameters[index] = out.parameters[index].withAnimation(animation)
            } catch let message as AnimateProblem {
                out.errors.append(fail(entry.line, entry.text, message.text))
            } catch {
                out.errors.append(fail(entry.line, entry.text, "\(error)"))
            }
        }

        // Presets are validated against the declared parameters once all of
        // both have been seen, so declaration order in the file doesn't matter.
        for name in presetOrder {
            let settings = presetValues[name] ?? [:]
            let line = presetLine[name] ?? 0
            var checked: [String: LerpParamValue] = [:]
            var animations: [String: LerpParamAnimation] = [:]
            for (key, setting) in settings {
                guard let param = out.parameters.first(where: { $0.name == key }) else {
                    out.errors.append(LerpParamError(line: line,
                        message: "preset `\(name)` sets `\(key)`, which is not a declared parameter",
                        text: key + "=" + setting.literal))
                    continue
                }
                switch setting {
                case .value(let value):
                    let typeMatches = param.type.isColor ? (value.colorValue != nil) : (value.scalarValue != nil)
                    guard typeMatches else {
                        out.errors.append(LerpParamError(line: line,
                            message: "preset `\(name)` gives `\(key)` a value of the wrong type for a \(param.type.rawValue) parameter",
                            text: key + "=" + value.literal))
                        continue
                    }
                    checked[key] = param.clamp(value)
                case .animate(let spec):
                    do {
                        animations[key] = try resolveAnimation(spec, for: param, fallback: param.animation)
                    } catch let problem as AnimateProblem {
                        out.errors.append(LerpParamError(line: line,
                            message: "preset `\(name)`: \(problem.text)", text: key + "=" + spec.literal))
                    } catch {
                        out.errors.append(LerpParamError(line: line, message: "\(error)",
                                                         text: key + "=" + spec.literal))
                    }
                }
            }
            out.presets.append(LerpPreset(name: name, values: checked, animations: animations, line: line))
        }
        out.errors.sort { $0.line < $1.line }
        return out
    }

    // MARK: Animation

    /// Why an `AnimateSpec` cannot animate the parameter it names — said
    /// without a line, because the same check serves a `// lerp-animate:`
    /// line, a preset's `animate(…)` and `LerpPreview --param`.
    public struct AnimateProblem: Error, CustomStringConvertible {
        public let text: String
        public var description: String { text }
    }

    /// `NAME LOW HIGH [period=SECONDS]` — the body of a `// lerp-animate:`
    /// line. Space-separated like the `// lerp-param:` it sits next to; a
    /// `(r, g, b)` colour bound keeps its own spaces.
    static func parseAnimateLine(_ text: String, line: Int) throws -> (String, AnimateSpec) {
        let syntax = "(syntax: // lerp-animate: NAME LOW HIGH [period=SECONDS])"
        let tokens = splitTopLevel(text.replacingOccurrences(of: "\t", with: " "), on: " ").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let name = tokens.first else { throw fail(line, text, "missing parameter name \(syntax)") }
        guard isIdentifier(name) else {
            throw fail(line, text, "`\(name)` is not a valid parameter name \(syntax)")
        }
        let spec = try parseAnimateArguments(Array(tokens.dropFirst()), line: line, text: text)
        guard spec.low != nil else {
            throw fail(line, text, "`\(name)` needs LOW and HIGH bounds to drift between \(syntax)")
        }
        return (name, spec)
    }

    /// Bounds and `key=value` options, in any order: `0.2 0.6 period=180`, or
    /// the comma-split inside of a preset's `animate(…)`. Bounds come in a
    /// pair or not at all.
    static func parseAnimateArguments(_ arguments: [String], line: Int, text: String) throws -> AnimateSpec {
        var spec = AnimateSpec()
        var bounds: [LerpParamValue] = []
        for argument in arguments {
            if let equals = argument.firstIndex(of: "=") {
                let key = argument[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                var raw = argument[argument.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                guard key == "period" else {
                    throw fail(line, text, "unknown animation option `\(key)` — the only option is `period=SECONDS`")
                }
                if raw.hasSuffix("s") { raw.removeLast() }
                guard let seconds = Double(raw), seconds.isFinite else {
                    throw fail(line, text, "`period=` takes a number of seconds, got `\(argument)`")
                }
                guard seconds >= LerpParamAnimation.minimumPeriod else {
                    throw fail(line, text, "period \(LerpParamValue.scalar(seconds).literal) s is under the "
                        + "\(Int(LerpParamAnimation.minimumPeriod)) s floor — animation is slow drift; "
                        + "faster motion belongs in the shader, against `u.time`")
                }
                spec.period = seconds
            } else if argument.hasPrefix("#") || argument.hasPrefix("(") {
                bounds.append(try parseColor(argument, line: line, text: text))
            } else if let number = Double(argument), number.isFinite {
                bounds.append(.scalar(number))
            } else {
                throw fail(line, text, "`\(argument)` is not a number, a colour or `period=SECONDS`")
            }
        }
        switch bounds.count {
        case 0: break
        case 2: spec.low = bounds[0]; spec.high = bounds[1]
        default:
            throw fail(line, text, "an animation takes two bounds, LOW and HIGH — got \(bounds.count)")
        }
        return spec
    }

    /// `spec` checked against the parameter it animates, with anything it
    /// leaves out taken from `fallback` (the file's `// lerp-animate:`) and
    /// then from the defaults.
    ///
    /// Only `float` and `color` animate. An `int` would step from value to
    /// value — a palette count jumping is a cut, not a drift — and a `bool`
    /// would flicker; both are refused rather than quietly rounded.
    public static func resolveAnimation(_ spec: AnimateSpec, for param: LerpParam,
                                        fallback: LerpParamAnimation?) throws -> LerpParamAnimation {
        guard param.type == .float || param.type == .color else {
            throw AnimateProblem(text: "`\(param.name)` is a\(param.type == .int ? "n" : "") \(param.type.rawValue) "
                + "parameter, and only float and color parameters can animate — an int would step "
                + "and a bool would flicker")
        }
        guard let low = spec.low ?? fallback?.low, let high = spec.high ?? fallback?.high else {
            throw AnimateProblem(text: "`\(param.name)=animate` needs bounds — the file has no "
                + "`// lerp-animate:` for it to borrow them from; write `animate(LOW, HIGH)`")
        }
        let period = spec.period ?? fallback?.period ?? LerpParamAnimation.defaultPeriod
        switch (param.type, low, high) {
        case (.float, .scalar(let a), .scalar(let b)):
            guard a != b else {
                throw AnimateProblem(text: "LOW and HIGH are both \(low.literal), so `\(param.name)` would not move")
            }
            for bound in [a, b] where bound < param.min || bound > param.max {
                throw AnimateProblem(text: "bound \(LerpParamValue.scalar(bound).literal) is outside "
                    + "`\(param.name)`'s declared range \(LerpParamValue.scalar(param.min).literal)…"
                    + "\(LerpParamValue.scalar(param.max).literal)")
            }
        case (.color, .color(let a), .color(let b)):
            guard a != b else {
                throw AnimateProblem(text: "LOW and HIGH are the same colour, so `\(param.name)` would not move")
            }
            for c in [a, b] where [c.x, c.y, c.z, c.w].contains(where: { $0 < 0 || $0 > 1 }) {
                throw AnimateProblem(text: "colour bound \(LerpParamValue.color(c).literal) has a component outside 0…1")
            }
        default:
            throw AnimateProblem(text: "`\(param.name)` is a \(param.type.rawValue) parameter, so its bounds must be "
                + (param.type == .color ? "colours" : "numbers"))
        }
        return LerpParamAnimation(low: low, high: high, period: period)
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
    static func parsePreset(_ text: String, line: Int) throws -> (String, [String: PresetSetting]) {
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

        var values: [String: PresetSetting] = [:]
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
            values[key] = try parseSetting(raw, line: line, text: text)
        }
        guard !values.isEmpty else { throw fail(line, text, "preset `\(name)` sets nothing") }
        return (name, values)
    }

    /// The right-hand side of one preset assignment: a colour, a bool, a
    /// number — or `animate` / `animate(LOW, HIGH, period=S)`, where every
    /// argument is optional and the file's `// lerp-animate:` fills the gaps.
    public static func parseSetting(_ raw: String, line: Int, text: String) throws -> PresetSetting {
        if raw.lowercased() == "animate" { return .animate(AnimateSpec()) }
        if raw.lowercased().hasPrefix("animate(") {
            guard raw.hasSuffix(")") else {
                throw fail(line, text, "`\(raw)` is missing its closing `)`")
            }
            let inner = String(raw.dropFirst("animate(".count).dropLast())
            let arguments = splitTopLevel(inner, on: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .animate(try parseAnimateArguments(arguments, line: line, text: text))
        }
        if raw.hasPrefix("#") || raw.hasPrefix("(") {
            return .value(try parseColor(raw, line: line, text: text))
        } else if let flag = boolean(raw) {
            return .value(.scalar(flag))
        } else if let number = Double(raw) {
            return .value(.scalar(number))
        }
        throw fail(line, text, "`\(raw)` is not a number, bool, colour or `animate(…)`")
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
        if trimmed == LerpRotationEntry.wholeShaderPreset {
            return "“\(trimmed)” stands for every look of a shader at once in the rotation, "
                + "so it cannot also be the name of one of them. Pick another."
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
    ///
    /// Animation follows the same overlay rule. A parameter the file animates
    /// that is being *held* is written with its value, because a value is what
    /// pins it — even when that value is the declared default. One that is
    /// animating is never written here: see `animationOverrides(in:)`.
    public static func overrides(in values: LerpParameterValues)
        -> [(param: LerpParam, value: LerpParamValue)] {
        values.parameters.compactMap { param in
            guard !values.isAnimating(param.name), let value = values[param.name] else { return nil }
            guard value != param.defaultValue || param.animation != nil else { return nil }
            return (param, value)
        }
    }

    /// The parameters drifting with something other than what the file's
    /// `// lerp-animate:` gives them — a different range or period, or a
    /// drift on a parameter the file holds still — in declaration order. One
    /// animating exactly as declared says nothing and is left out.
    public static func animationOverrides(in values: LerpParameterValues)
        -> [(param: LerpParam, animation: LerpParamAnimation)] {
        values.parameters.compactMap { param in
            guard values.isAnimating(param.name), let animation = values.animations[param.name],
                  animation != param.animation else { return nil }
            return (param, animation)
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
                                   animations: [(param: LerpParam, animation: LerpParamAnimation)] = [],
                                   wrappingAt columns: Int = 92) -> [String] {
        let prefix = "// " + LerpParamParser.presetDirective + " " + quoted(name) + "  "
        var lines: [String] = []
        var current: [String] = []
        let assignments = overrides.map { $0.param.name + "=" + literal($0.value, as: $0.param.type) }
            + animations.map { $0.param.name + "=" + $0.animation.presetLiteral }
        for assignment in assignments {
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
