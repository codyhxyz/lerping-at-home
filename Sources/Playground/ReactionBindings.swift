import Foundation

/// Labels and display state for the Playground reaction menu.
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

}
