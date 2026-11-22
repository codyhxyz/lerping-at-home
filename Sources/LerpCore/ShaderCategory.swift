import Foundation

/// The shelf a shader sits on in the selector, declared in its own file:
///
///     // lerp-category: Atmosphere
///
/// A hundred cards in one undivided grid is a wall; a handful of named shelves
/// is something you can scan. The category is the file's to say, like its
/// caption and its data provider, so a look moved or added keeps its place
/// without a table somewhere else to update.
///
/// Every shipped shader names one of `shelves` (`LerpPreview
/// --rotation-selftest` checks). A shader that names none — one the user just
/// made — or a word not on the list sits on the last shelf, `other`, rather
/// than vanishing or inventing a shelf for one typo.
public enum LerpShaderCategory {
    /// In selector order, grouped by what the look feels like rather than
    /// how it is rendered.
    public static let shelves = ["Atmosphere", "Living Worlds", "Windows", "Sound & Flow", "Meditative"]
    public static let other = "Other"

    public static let directive = "lerp-category:"

    /// Where `name` sits among the shelves; `other` and anything unknown last.
    static func rank(_ name: String) -> Int {
        shelves.firstIndex(of: name) ?? shelves.count
    }
}

extension LerpShader {
    /// The shelf this shader declares, as one of `LerpShaderCategory.shelves`,
    /// or `LerpShaderCategory.other`.
    public var category: String {
        for raw in source.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let value = LerpParamParser.directiveBody(raw, LerpShaderCategory.directive) else { continue }
            return LerpShaderCategory.shelves.first {
                $0.caseInsensitiveCompare(value) == .orderedSame
            } ?? LerpShaderCategory.other
        }
        return LerpShaderCategory.other
    }

    /// The name on its card. The `splat-` prefix identifies the capture
    /// format, not the subject in the window, so leave it off the card.
    public var cardTitle: String {
        guard name.hasPrefix("splat-"), name.count > 6 else { return displayName }
        return displayName.split(separator: " ").dropFirst().joined(separator: " ")
    }
}

extension Array where Element == LerpShader {
    /// Shelf by shelf, keeping the library's own order within each: the order
    /// the selector draws cards in, and so the order ‹ › steps through.
    public func inShelfOrder() -> [LerpShader] {
        // Ranked once each: `category` reads the whole file.
        enumerated()
            .map { (rank: LerpShaderCategory.rank($0.element.category), index: $0.offset, shader: $0.element) }
            .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
            .map(\.shader)
    }
}
