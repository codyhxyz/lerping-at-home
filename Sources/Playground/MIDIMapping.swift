import Foundation
import MIDIDeps

/// The mapping layer: which knob drives which `// lerp-param:`, how its numbers
/// are interpreted, and where that survives a relaunch.
///
/// `swift-midi` hands us decoded `MIDIEvent`s and stops there — no MIDI library
/// still maintained for macOS models user-editable controller mappings, so this
/// file is the part that has to exist. It is deliberately small: a struct per
/// binding, a struct per preset, JSON on disk, and one dictionary keyed on the
/// packed (channel, CC) pair so dispatch is a single lookup per message.

// MARK: - How a controller encodes movement

/// Endless/relative encoders send "moved by n", and three mutually incompatible
/// encodings of that are in the wild. Controllers do not advertise which one
/// they use and many are configurable, so this is per-binding and guessing is
/// not an option — two's complement is the most common and the default.
enum MIDIRelativeEncoding: String, Codable, Hashable, CaseIterable {
    /// 1…63 = +1…+63, 65…127 = −63…−1. (Akai, Novation, most DAW modes.)
    case twosComplement
    /// 64 = no movement, 65+ = up, 63− = down. (Also called "binary offset".)
    case binaryOffset
    /// Bit 6 is the sign, bits 0–5 the magnitude. (Some Behringer/Doepfer.)
    case signMagnitude

    var label: String {
        switch self {
        case .twosComplement: "Relative (two's complement)"
        case .binaryOffset:   "Relative (binary offset)"
        case .signMagnitude:  "Relative (sign/magnitude)"
        }
    }

    /// Ticks moved, signed. 0 means "no movement", which every encoding can send.
    func delta(_ raw: UInt8) -> Int {
        switch self {
        case .twosComplement: raw < 64 ? Int(raw) : Int(raw) - 128
        case .binaryOffset:   Int(raw) - 64
        case .signMagnitude:  (raw & 0x40) != 0 ? -Int(raw & 0x3F) : Int(raw & 0x3F)
        }
    }
}

enum MIDIBindingMode: Codable, Hashable {
    /// One CC, 0…127 straight onto the range.
    case abs7
    /// MSB on the bound CC, LSB on `lsbCC` (always CC + 32), coalesced into
    /// 0…16383. Only legal for CCs 0…31, which is where the MIDI spec puts the
    /// coarse half of the 14-bit pairs.
    case abs14(lsbCC: UInt7)
    /// Endless encoder: each message nudges the current value.
    case relative(MIDIRelativeEncoding)
    /// Button: any value of 64 or more flips the parameter. Presses below that
    /// (i.e. note-off style releases) are ignored so a press/release pair is one
    /// toggle, not two.
    case toggle

    var label: String {
        switch self {
        case .abs7:              "Absolute (7-bit)"
        case .abs14:             "Absolute (14-bit pair)"
        case .relative(let e):   e.label
        case .toggle:            "Toggle"
        }
    }

    /// The menu offers one entry per *kind*; `abs14`'s companion CC is derived
    /// from the bound CC rather than chosen.
    static let choices: [MIDIBindingMode] = [
        .abs7, .abs14(lsbCC: 0), .relative(.twosComplement),
        .relative(.binaryOffset), .relative(.signMagnitude), .toggle
    ]

    func matchesChoice(_ other: MIDIBindingMode) -> Bool {
        switch (self, other) {
        case (.abs7, .abs7), (.abs14, .abs14), (.toggle, .toggle): true
        case let (.relative(a), .relative(b)): a == b
        default: false
        }
    }
}

// MARK: - Model

struct MIDIBinding: Codable, Hashable {
    /// The `// lerp-param:` name. Bindings outlive the shader that was open when
    /// they were made, so a preset can cover several shaders at once.
    var paramID: String
    /// nil is omni — matches every channel. That is what Learn records, because
    /// most controllers are on a channel the user has never thought about.
    var channel: UInt4?
    var cc: UInt7
    var mode: MIDIBindingMode = .abs7
    /// The slice of the parameter's declared range the knob sweeps, normalised
    /// 0…1. Full travel by default.
    var range: ClosedRange<Float> = 0 ... 1
    /// Which axis of a `color` parameter this CC drives. nil on every other
    /// type, and nil in every mapping file written before colours were
    /// bindable — `Optional` is what keeps those files decoding.
    ///
    /// This is the whole of the colour feature's model. One CC on `.hue` is the
    /// simple case; three CCs on `.hue`, `.chroma` and `.lightness` of the same
    /// `paramID` is the rich case; they run the identical code.
    var component: ColorComponent?

    var shortLabel: String {
        "CC\(cc)" + (channel.map { " c\(Int($0) + 1)" } ?? "")
            + (component.map { " " + $0.shortLabel } ?? "")
    }

    /// True when the knob is scoped to less than the parameter's whole range,
    /// which is the only time the editor's min/max fields are worth showing off.
    var isScoped: Bool { range != 0 ... 1 }

    /// The same binding in another mode, or nil when the mode cannot apply —
    /// 14-bit needs a CC in 0…31 so CC + 32 is a legal LSB partner.
    func withMode(_ mode: MIDIBindingMode) -> MIDIBinding? {
        var copy = self
        if case .abs14 = mode {
            guard cc <= 31 else { return nil }
            copy.mode = .abs14(lsbCC: UInt7(UInt8(cc) + 32))
        } else {
            copy.mode = mode
        }
        return copy
    }

    /// Range with the two ends kept in order and inside 0…1, so a typo in the
    /// editor cannot produce a `ClosedRange` that traps on construction.
    func withRange(low: Float, high: Float) -> MIDIBinding {
        var copy = self
        let a = Swift.min(Swift.max(low, 0), 1), b = Swift.min(Swift.max(high, 0), 1)
        copy.range = Swift.min(a, b) ... Swift.max(a, b)
        return copy
    }
}

/// One switchable bank of mappings, normally one per controller.
struct MappingPreset: Codable {
    var name: String
    /// Core MIDI `uniqueID` of the endpoint this bank was made for, as a string.
    /// Empty matches any device. Used to auto-select on connect.
    var deviceID: String
    var bindings: [MIDIBinding] = []

    /// Every CC pointed at this parameter, in component order so a colour's
    /// H/C/L/α always read the same way round.
    func bindings(for paramID: String) -> [MIDIBinding] {
        bindings.filter { $0.paramID == paramID }
            .sorted { order($0.component) < order($1.component) }
    }

    func binding(for paramID: String, component: ColorComponent?) -> MIDIBinding? {
        bindings.first { $0.paramID == paramID && $0.component == component }
    }

    private func order(_ component: ColorComponent?) -> Int {
        component.flatMap { ColorComponent.allCases.firstIndex(of: $0) } ?? -1
    }

    /// Learn semantics: one *axis* of a parameter has at most one binding, and
    /// one CC drives at most one axis, so setting either identity displaces the
    /// other. Keying on the axis rather than on the parameter is the whole of
    /// what lets three CCs share a colour — a scalar has exactly one axis (nil),
    /// so it behaves exactly as it did.
    mutating func bind(_ binding: MIDIBinding) {
        bindings.removeAll {
            ($0.paramID == binding.paramID && $0.component == binding.component)
                || ($0.cc == binding.cc && $0.channel == binding.channel)
        }
        bindings.append(binding)
    }

    /// Drops every axis of a parameter — "Clear" on a colour row that has three
    /// knobs on it means all three.
    mutating func unbind(_ paramID: String) {
        bindings.removeAll { $0.paramID == paramID }
    }

    mutating func unbind(_ paramID: String, component: ColorComponent?) {
        bindings.removeAll { $0.paramID == paramID && $0.component == component }
    }
}

// MARK: - Dispatch

/// Turns an inbound CC into "what to do to which parameter" in one dictionary
/// lookup. Main-thread only; `MIDIController` hops messages over before routing.
final class MIDIRouter {

    enum Update {
        /// Position within the binding's range, 0…1.
        case absolute(Double)
        /// Signed encoder ticks.
        case delta(Int)
        case toggle
    }

    /// Packed (channel, CC). Channel 16 is the omni slot, which is one above the
    /// last real channel and so can never collide with one.
    private static func key(_ channel: UInt4?, _ cc: UInt7) -> UInt16 {
        (UInt16(channel.map { UInt8($0) } ?? 16) << 8) | UInt16(UInt8(cc))
    }

    private var table: [UInt16: MIDIBinding] = [:]
    /// LSB key → the MSB key that owns it, for 14-bit pairs.
    private var lsbOwner: [UInt16: UInt16] = [:]
    /// Halves of a 14-bit value seen so far, keyed on the MSB key.
    private var halves: [UInt16: (msb: UInt8, lsb: UInt8)] = [:]

    /// Swapping mapping presets is exactly this call — one table rebuild.
    func load(_ bindings: [MIDIBinding]) {
        table.removeAll(keepingCapacity: true)
        lsbOwner.removeAll(keepingCapacity: true)
        halves.removeAll(keepingCapacity: true)
        for binding in bindings {
            let key = Self.key(binding.channel, binding.cc)
            table[key] = binding
            if case .abs14(let lsbCC) = binding.mode {
                lsbOwner[Self.key(binding.channel, lsbCC)] = key
            }
        }
    }

    func route(channel: UInt4, cc: UInt7, value: UInt8) -> (binding: MIDIBinding, update: Update)? {
        let exact = Self.key(channel, cc), omni = Self.key(nil, cc)
        if let key = table[exact] != nil ? exact : (table[omni] != nil ? omni : nil),
           let binding = table[key] {
            switch binding.mode {
            case .abs7:
                return (binding, .absolute(Double(value) / 127))
            case .abs14:
                // A fresh MSB zeroes the LSB, per the MIDI 1.0 spec: a controller
                // that only ever sends the coarse half still sweeps the range.
                halves[key] = (msb: value, lsb: 0)
                return (binding, .absolute(Double(UInt16(value) << 7) / 16383))
            case .relative(let encoding):
                let delta = encoding.delta(value)
                return delta == 0 ? nil : (binding, .delta(delta))
            case .toggle:
                return value >= 64 ? (binding, .toggle) : nil
            }
        }
        // The fine half of a 14-bit pair, which arrives as its own CC message.
        if let key = lsbOwner[exact] ?? lsbOwner[omni], let binding = table[key] {
            let msb = halves[key]?.msb ?? 0
            halves[key] = (msb: msb, lsb: value)
            let combined = (UInt16(msb) << 7) | UInt16(value)
            return (binding, .absolute(Double(combined) / 16383))
        }
        return nil
    }
}

// MARK: - Persistence

/// Mapping presets live beside the custom shaders, one JSON file each, so they
/// can be copied between machines the same way a shader can.
///
/// The file name is a slug of the bank name, and a slug is lossy: "My Bank",
/// "my bank" and "my-bank!" all sanitise to `my-bank`, so naming a second bank
/// any of those used to overwrite the first without a word. The fix is to stop
/// treating the slug as the bank's identity. **The name inside the JSON is the
/// identity**; the file name is only a hint, and a colliding one gets a numeric
/// suffix. Nothing on disk needs moving for that, which is what makes it a
/// migration with no data loss: an existing `my-bank.json` is still found, by
/// what is written in it.
enum MIDIMappingStore {

    static var directory: URL {
        ShaderPaths.customDirectory      // …/Application Support/Lerping/Shaders
            .deletingLastPathComponent()
            .appendingPathComponent("MIDI")
    }

    private static func jsonURLs() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func decode(_ url: URL) -> MappingPreset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MappingPreset.self, from: data)
    }

    private static func name(inFileAt url: URL) -> String? {
        decode(url)?.name
    }

    /// The file this bank is already stored in, found by what it says its name
    /// is rather than by recomputing a slug that may not be the one it got.
    static func existingURL(for name: String) -> URL? {
        jsonURLs().first { Self.name(inFileAt: $0) == name }
    }

    /// Where this bank should be written. Its current file if it has one, else
    /// the slug — with `-2`, `-3`, … appended until the name lands on a file
    /// that is either free or already this bank's.
    static func fileURL(for name: String) -> URL {
        if let existing = existingURL(for: name) { return existing }
        let stem = ShaderScaffold.sanitize(name: name) ?? "mapping"
        var candidate = stem
        var suffix = 1
        while true {
            let url = directory.appendingPathComponent(candidate + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { return url }
            suffix += 1
            candidate = "\(stem)-\(suffix)"
        }
    }

    static func load() -> [MappingPreset] {
        jsonURLs().compactMap(decode)
    }

    static func save(_ preset: MappingPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
    }

    static func delete(_ name: String) {
        guard let url = existingURL(for: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether a bank called this already exists, ignoring case — the check the
    /// New/Rename prompts make before they let a name through. Two banks whose
    /// names differ only in case would now survive on disk, but they would be
    /// indistinguishable in the popup, so they are refused with a message
    /// instead.
    static func nameIsTaken(_ name: String, in presets: [MappingPreset], excluding: String? = nil) -> Bool {
        presets.contains {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame && $0.name != excluding
        }
    }
}
