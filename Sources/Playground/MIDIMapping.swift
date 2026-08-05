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

    var shortLabel: String {
        "CC\(cc)" + (channel.map { " c\(Int($0) + 1)" } ?? "")
    }

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
}

/// One switchable bank of mappings, normally one per controller.
struct MappingPreset: Codable {
    var name: String
    /// Core MIDI `uniqueID` of the endpoint this bank was made for, as a string.
    /// Empty matches any device. Used to auto-select on connect.
    var deviceID: String
    var bindings: [MIDIBinding] = []

    func binding(for paramID: String) -> MIDIBinding? {
        bindings.first { $0.paramID == paramID }
    }

    /// Learn semantics: one parameter has at most one binding, and one CC drives
    /// at most one parameter, so setting either identity displaces the other.
    mutating func bind(_ binding: MIDIBinding) {
        bindings.removeAll { $0.paramID == binding.paramID
            || ($0.cc == binding.cc && $0.channel == binding.channel) }
        bindings.append(binding)
    }

    mutating func unbind(_ paramID: String) {
        bindings.removeAll { $0.paramID == paramID }
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

    var bindingCount: Int { table.count }

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
enum MIDIMappingStore {

    static var directory: URL {
        ShaderPaths.customDirectory      // …/Application Support/Lerping/Shaders
            .deletingLastPathComponent()
            .appendingPathComponent("MIDI")
    }

    static func fileURL(for name: String) -> URL {
        directory.appendingPathComponent((ShaderScaffold.sanitize(name: name) ?? "mapping") + ".json")
    }

    static func load() -> [MappingPreset] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(MappingPreset.self, from: data)
            }
    }

    static func save(_ preset: MappingPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
    }

    static func delete(_ name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }
}
