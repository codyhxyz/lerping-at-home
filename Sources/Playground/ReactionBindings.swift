import Foundation
import simd

/// Playground adapter until the core renderer owns live bindings. Source
/// changes use the same editor path as presets; the overlay never edits one.
struct ReactionBinding: Equatable {
    struct Signal {
        let id: String
        let title: String
        let group: String
        var isColor: Bool { id.hasPrefix("music.palette") }

        static let all: [Self] = [
            ("Clock", "clock", [("hour", "Hour"), ("hourNorm", "Hour (normalized)"), ("sun", "Sun elevation"),
                                 ("daylight", "Daylight"), ("twilight", "Twilight"), ("moonPhase", "Moon phase"), ("season", "Season")]),
            ("Weather", "weather", [("rain", "Rain"), ("snow", "Snow"), ("wind", "Wind"), ("clouds", "Clouds"),
                                     ("fog", "Fog"), ("thunder", "Thunder"), ("temp", "Temperature"), ("precip", "Precipitation")]),
            ("Music", "audio", [("bass", "Bass"), ("beat", "Beat"), ("level", "Level"), ("mid", "Mid"), ("treble", "Treble")]),
            ("Music", "music", [("palette0", "Album Color 1"), ("palette1", "Album Color 2"),
                                 ("palette2", "Album Color 3"), ("playing", "Playing")]),
            ("My Day", "pulse", [("focus", "Focus"), ("scatter", "Scatter"), ("fatigue", "Fatigue"),
                                  ("momentum", "Momentum"), ("energy", "Energy")]),
            ("My Day", "idle", [("depth", "Idle depth")]),
        ].flatMap { group, prefix, signals in
            signals.map { Self(id: prefix + "." + $0.0, title: $0.1, group: group) }
        }
    }

    let signal: String
    var range: (Double, Double)?
    var smoothing = 0.15
    var mix = 1.0
    var title: String { Signal.all.first { $0.id == signal }?.title ?? signal }

    static func == (a: Self, b: Self) -> Bool {
        a.signal == b.signal && a.range?.0 == b.range?.0 && a.range?.1 == b.range?.1
            && a.smoothing == b.smoothing && a.mix == b.mix
    }

    private static func words(in line: String) -> [Substring]? {
        LerpParamParser.directiveBody(line[...], "lerp-react:")?.split(whereSeparator: \.isWhitespace)
    }

    static func read(_ source: String) -> [String: Self] {
        var bindings: [String: Self] = [:]
        for line in lines(in: source) {
            guard let words = words(in: line), words.count >= 3, words[1] == "<-",
                  let choice = Signal.all.first(where: { $0.id == words[2] }) else { continue }
            var binding = Self(signal: choice.id)
            // Wall-clock signals wrap at midnight; an implicit low-pass would
            // animate through noon on the way from 23:59 to 00:00.
            if ["clock.hour", "clock.hourNorm"].contains(choice.id) { binding.smoothing = 0 }
            var valid = true
            for word in words.dropFirst(3) {
                if word.hasPrefix("smooth="), let value = Double(word.dropFirst(7)), value.isFinite, value >= 0 {
                    binding.smoothing = value
                } else if choice.isColor, word.hasPrefix("mix="), let value = Double(word.dropFirst(4)), (0...1).contains(value) {
                    binding.mix = value
                } else if !choice.isColor {
                    let bounds = word.components(separatedBy: "..")
                    if bounds.count == 2, let low = Double(bounds[0]), let high = Double(bounds[1]), low.isFinite, high.isFinite {
                        binding.range = (low, high)
                    } else { valid = false }
                } else { valid = false }
            }
            if valid { bindings[String(words[0])] = binding }
        }
        return bindings
    }

    static func setting(_ signal: String?, for name: String, in source: String) -> String {
        var lines = lines(in: source)
        let needle = name[...]
        let matches = lines.indices.filter { words(in: lines[$0])?.first == needle }
        if let signal {
            let declaration = "// lerp-react: \(name) <- \(signal)"
            if let first = matches.first {
                lines[first] = declaration
                for index in matches.dropFirst().reversed() { lines.remove(at: index) }
            } else {
                let index = lines.firstIndex { LerpParamParser.directiveBody($0[...], "lerp-param:")?
                    .split(whereSeparator: \.isWhitespace).first == needle }
                lines.insert(declaration, at: index.map { $0 + 1 } ?? 0)
            }
        } else {
            for index in matches.reversed() { lines.remove(at: index) }
        }
        return lines.joined(separator: source.contains("\r\n") ? "\r\n" : "\n")
    }

    private static func lines(in source: String) -> [String] {
        source.components(separatedBy: source.contains("\r\n") ? "\r\n" : "\n")
    }

    func target(for param: LerpParam, base: LerpParamValue, signal value: LerpParamValue) -> LerpParamValue? {
        switch (param.type, value) {
        case (.color, .color(let color)):
            guard let original = base.colorValue else { return nil }
            return .color(original + (color - original) * Float(mix))
        case (.float, .scalar(let sample)), (.int, .scalar(let sample)), (.bool, .scalar(let sample)):
            guard let range else { return param.clamp(.scalar(sample)) }
            let unit = switch signal {
            case "clock.hour": sample / 24
            case "clock.sun": (sample + 1) / 2
            default: sample
            }
            return param.clamp(.scalar(range.0 + (range.1 - range.0) * unit))
        default: return nil
        }
    }
}

/// Only the fields read by the editor. Missing data is not a zero-valued
/// signal: it lets the underlying look play as authored.
struct ReactionWorld {
    var values: [String: LerpParamValue] = [:]
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Lerping/world.json")

    static func read(at url: URL = url, now: Date = Date()) -> Self {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .init() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["version"] as? Int == 1, let timestamp = json["updatedAt"] as? Double,
              (-5...300).contains(now.timeIntervalSince1970 - timestamp) else { return .init() }
        var result = Self()
        for signal in ReactionBinding.Signal.all {
            let parts = signal.id.split(separator: ".").map(String.init)
            guard let group = json[parts[0]] as? [String: Any] else { continue }
            if signal.isColor {
                guard let index = parts[1].last?.wholeNumberValue,
                      let palette = group["palette"] as? [[Float]], palette.indices.contains(index),
                      palette[index].count == 4, palette[index].allSatisfy({ (0...1).contains($0) }) else { continue }
                result.values[signal.id] = .color(SIMD4(palette[index]))
            } else if signal.id == "music.playing", let value = group[parts[1]] as? Bool {
                result.values[signal.id] = .scalar(value ? 1 : 0)
            } else if let value = group[parts[1]] as? Double {
                let range: ClosedRange<Double> = switch signal.id {
                case "clock.hour": 0...24
                case "clock.sun": -1...1
                default: 0...1
                }
                if range.contains(value) { result.values[signal.id] = .scalar(value) }
            }
        }
        return result
    }
}

struct ReactionOverlay {
    var bindings: [String: ReactionBinding] = [:]
    var takenOver: Set<String> = []
    var smoothed: [String: LerpParamValue] = [:]
    private var lastFrame: TimeInterval?

    init(bindings: [String: ReactionBinding] = [:], takenOver: Set<String> = []) {
        self.bindings = bindings
        self.takenOver = takenOver
    }

    mutating func step(params: LerpParameterValues, world: ReactionWorld, audio: LerpAudioLevels?, beat: Float,
                       now: TimeInterval) -> [String: LerpParamValue] {
        let elapsed = max(0, min(0.25, now - (lastFrame ?? now - 0.05)))
        lastFrame = now
        var live = [String: LerpParamValue]()
        for (name, binding) in bindings where !takenOver.contains(name) {
            let input: LerpParamValue?
            if binding.signal.hasPrefix("audio.") {
                input = audio.map { levels in
                    let sample = switch binding.signal {
                    case "audio.bass": levels.bass
                    case "audio.mid": levels.mid
                    case "audio.treble": levels.treble
                    case "audio.beat": beat
                    default: levels.level
                    }
                    return .scalar(Double(sample))
                }
            } else {
                input = world.values[binding.signal]
            }
            guard let input, let param = params.parameter(named: name), let base = params[name],
                  let target = binding.target(for: param, base: base, signal: input) else { continue }
            let previous = smoothed[name] ?? base
            let k = binding.smoothing == 0 ? 1 : 1 - exp(-elapsed / binding.smoothing)
            switch (previous, target) {
            case (.scalar(let a), .scalar(let b)):
                // Keep the intermediate unrounded or an integer slider can
                // get stuck at the start of its range forever.
                live[name] = .scalar(abs(b - a) < 0.00001 ? b : a + (b - a) * k)
            case (.color(let a), .color(let b)):
                live[name] = .color(simd_distance(a, b) < 0.00001 ? b : a + (b - a) * Float(k))
            default: live[name] = target
            }
        }
        smoothed = live
        return live
    }
}
