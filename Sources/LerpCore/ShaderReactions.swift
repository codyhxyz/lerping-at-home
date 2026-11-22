import Foundation

/// A source binding: native scalar units unless output endpoints are supplied;
/// then the source's full domain maps linearly to those endpoints. Reversed
/// endpoints invert a binding. Palette bindings blend with the underlying look.
public struct LerpParamReaction: Sendable, Equatable {
    public let paramName: String
    public let signal: String
    public let min, max, smooth, mix: Double?

    public init(paramName: String, signal: String, min: Double? = nil, max: Double? = nil,
                smooth: Double? = nil, mix: Double? = nil) {
        self.paramName = paramName
        self.signal = signal
        self.min = min
        self.max = max
        self.smooth = smooth
        self.mix = mix
    }

    var body: String {
        var parts = [paramName, "<-", signal]
        if let min, let max { parts.append("\(min)..\(max)") }
        if let smooth { parts.append("smooth=\(smooth)") }
        if let mix { parts.append("mix=\(mix)") }
        return parts.joined(separator: " ")
    }

    static func parse(_ text: String, line: Int, parameters: [LerpParam]) throws -> Self {
        func error(_ message: String) -> LerpParamError {
            LerpParamError(line: line, message: message, text: text)
        }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 3, tokens[1] == "<-" else {
            throw error("expected lerp-react: parameter <- signal [min..max] [smooth=seconds] or [mix=0..1]")
        }
        let (name, signal) = (tokens[0], tokens[2])
        guard let parameter = parameters.first(where: { $0.name == name }) else {
            throw error("unknown reaction parameter '\(name)'")
        }
        let isColor = LerpSignalValues.colorNames.contains(signal)
        guard isColor || LerpSignalValues.scalarDomain(for: signal) != nil else {
            throw error("unknown reaction signal '\(signal)'")
        }
        guard isColor == parameter.type.isColor else {
            throw error("reaction signal '\(signal)' and parameter '\(name)' must both be colors or both scalars")
        }
        var low: Double?, high: Double?, smooth: Double?, mix: Double?
        for token in tokens.dropFirst(3) {
            if token.hasPrefix("smooth=") {
                guard !isColor, smooth == nil, let value = Double(token.dropFirst(7)),
                      value.isFinite, value >= 0 else { throw error("invalid or duplicate smoothing duration '\(token)'") }
                smooth = value
            } else if token.hasPrefix("mix=") {
                guard isColor, mix == nil, let value = Double(token.dropFirst(4)),
                      (0...1).contains(value) else { throw error("invalid or duplicate palette mix '\(token)'") }
                mix = value
            } else {
                let range = token.components(separatedBy: "..")
                guard !isColor, low == nil, range.count == 2,
                      let a = Double(range[0]), let b = Double(range[1]),
                      Float(a).isFinite, Float(b).isFinite else { throw error("invalid or duplicate reaction range '\(token)'") }
                (low, high) = (a, b)
            }
        }
        return Self(paramName: name, signal: signal, min: low, max: high, smooth: smooth, mix: mix)
    }

    func target(in signals: LerpSignalValues, base: LerpParamValue) -> LerpParamValue? {
        if let color = base.colorValue, let target = signals.color(for: signal) {
            return .color(color + (target - color) * Float(mix ?? 1))
        }
        guard let value = signals.scalar(for: signal) else { return nil }
        guard let min, let max, let domain = LerpSignalValues.scalarDomain(for: signal) else {
            return .scalar(value)
        }
        let t = (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)
        return .scalar(min + (max - min) * t)
    }
}

/// One envelope history per live look, not per renderer (views share renderers).
/// Offscreen calls pass no history, so explicit fixtures are order-independent.
public final class LerpReactionSmoothing {
    private struct Sample {
        let reaction: LerpParamReaction
        let time: Float
        let value: Double
    }

    private var samples: [String: Sample] = [:]

    func reset(_ name: String) { samples.removeValue(forKey: name) }

    func resolve(_ target: Double, for reaction: LerpParamReaction, at time: Float,
                 updateHistory: Bool = true) -> Double {
        guard let seconds = reaction.smooth, seconds > 0 else { return target }
        let key = reaction.paramName
        var value = target
        if let old = samples[key], old.reaction == reaction, time >= old.time {
            let weight = -expm1(-Double(time - old.time) / seconds)
            value = old.value + (target - old.value) * weight
        }
        if updateHistory { samples[key] = Sample(reaction: reaction, time: time, value: value) }
        return value
    }
}

public enum LerpReactionWriter {
    /// Replace the binding in place, insert it after its parameter declaration,
    /// or remove it. Preserve all unrelated text and the final newline.
    public static func writing(_ reaction: LerpParamReaction?, for name: String,
                               in source: String) throws -> String {
        let separator = source.contains("\r\n") && !source.replacingOccurrences(of: "\r\n", with: "").contains("\n")
            ? "\r\n" : "\n"
        var lines = source.components(separatedBy: separator)
        let indices = lines.indices.filter { index in
            LerpParamParser.directiveBody(lines[index], LerpParamParser.reactDirective)?
                .split(whereSeparator: \.isWhitespace).first == Substring(name)
        }
        guard let reaction else {
            for index in indices.reversed() { lines.remove(at: index) }
            return lines.joined(separator: separator)
        }
        let declarations = LerpParamParser.parse(source: lines.joined(separator: "\n")).parameters
        guard let declaration = declarations.first(where: { $0.name == name }),
              reaction.paramName == name, (reaction.min == nil) == (reaction.max == nil) else {
            throw LerpParamError(line: 0, message: "invalid reaction for '\(name)'", text: reaction.body)
        }
        let index = indices.first ?? declaration.line
        _ = try LerpParamReaction.parse(reaction.body,
                                       line: indices.first.map { $0 + 1 } ?? index + 1,
                                       parameters: declarations)
        let styleLine = lines[indices.first ?? (declaration.line - 1)]
        let newLine = styleLine.prefix(while: { $0 == " " || $0 == "\t" })
            + "// \(LerpParamParser.reactDirective) \(reaction.body)"
        if indices.isEmpty { lines.insert(String(newLine), at: index) }
        else {
            lines[index] = String(newLine)
            for duplicate in indices.dropFirst().reversed() { lines.remove(at: duplicate) }
        }
        return lines.joined(separator: separator)
    }
}
