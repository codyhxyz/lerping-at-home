import Darwin
import Foundation

/// The versioned file exchanged with LerpPulse. A missing group is unavailable,
/// not a reading of zero (a clear sky and a disconnected sensor are different).
public struct LerpWorldSnapshot: Codable, Sendable, Equatable {
    public struct Clock: Codable, Sendable, Equatable {
        public var hour, hourNorm, sun, daylight, twilight, moonPhase, season: Double

        /// Approximate solar elevation (NOAA fractional-year equations) and
        /// lunar phase (mean synodic month from the January 2000 new moon).
        /// Without coordinates, assume 40° N at the zone's standard meridian;
        /// that fallback is atmosphere, not a local ephemeris.
        public static func calculate(at date: Date, latitude: Double? = nil,
                                     longitude: Double? = nil, timeZone: TimeZone = .current) -> Clock {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
            let days = Double(calendar.range(of: .day, in: .year, for: date)?.count ?? 365)
            let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
            let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
                + Double(parts.second ?? 0) / 3600
            let year = 2 * Double.pi / days * (day - 1 + (hour - 12) / 24)
            let equation = 229.18 * (0.000075 + 0.001868 * cos(year) - 0.032077 * sin(year)
                - 0.014615 * cos(2 * year) - 0.040849 * sin(2 * year))
            let declination = 0.006918 - 0.399912 * cos(year) + 0.070257 * sin(year)
                - 0.006758 * cos(2 * year) + 0.000907 * sin(2 * year)
                - 0.002697 * cos(3 * year) + 0.001480 * sin(3 * year)
            let zoneHours = Double(timeZone.secondsFromGMT(for: date)) / 3600
            let standardMeridian = (zoneHours - timeZone.daylightSavingTimeOffset(for: date) / 3600) * 15
            let lat = (latitude.flatMap { (-90...90).contains($0) ? $0 : nil } ?? 40) * .pi / 180
            let lon = longitude.flatMap { (-180...180).contains($0) ? $0 : nil } ?? standardMeridian
            let angle = (hour * 15 + equation / 4 + lon - zoneHours * 15 - 180) * .pi / 180
            let elevation = asin(max(-1, min(1, sin(lat) * sin(declination)
                + cos(lat) * cos(declination) * cos(angle))))
            let degrees = elevation * 180 / .pi
            let lunations = (date.timeIntervalSince1970 - 947_182_440) / (29.530588853 * 86_400)
            return Clock(hour: hour, hourNorm: hour / 24, sun: elevation / (.pi / 2),
                         daylight: ramp(degrees, from: -6, to: 6),
                         twilight: ramp(degrees, from: -18, to: -3) * (1 - ramp(degrees, from: -3, to: 6)),
                         moonPhase: lunations - floor(lunations), season: (day - 1 + hour / 24) / days)
        }

        private static func ramp(_ x: Double, from low: Double, to high: Double) -> Double {
            let t = max(0, min(1, (x - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
    }

    public struct Weather: Codable, Sendable, Equatable {
        public var rain, snow, clouds, wind, fog, thunder, temp, precip: Double
        public var label: String
    }

    public struct Music: Codable, Sendable, Equatable {
        public var playing: Bool
        public var title, artist, album, source, trackUri: String?
        public var palette: [[Float]]?
    }

    public struct Pulse: Codable, Sendable, Equatable {
        public var focus, scatter, fatigue, momentum, energy: Double
    }

    public struct Idle: Codable, Sendable, Equatable {
        public var minutes, depth: Double
    }

    public var version: Int = 1
    /// Unix seconds. The producer replaces the whole file atomically.
    public var updatedAt: Double
    public var clock: Clock?
    public var weather: Weather?
    public var music: Music?
    public var pulse: Pulse?
    public var idle: Idle?

    public static var url: URL? {
        (LerpFileLocations.realHomeDirectory ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("Library/Application Support/Lerping/world.json")
    }

    /// A single open reads either generation of an atomically replaced file.
    /// Allow missed hourly weather polls, but not yesterday's cached readings.
    public static func read(from url: URL, now: Date = Date(),
                            maxAge: TimeInterval = 2 * 3600) -> LerpWorldSnapshot? {
        guard url.isFileURL else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let limit = 64 * 1024
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let snapshot = try? JSONDecoder().decode(Self.self, from: data), snapshot.version == 1,
              (-60...max(0, maxAge)).contains(now.timeIntervalSince1970 - snapshot.updatedAt)
        else { return nil }
        return snapshot
    }
}

public struct LerpSignalValues: Sendable {
    public static let scalarNames = [
        "clock.hour", "clock.hourNorm", "clock.sun", "clock.daylight", "clock.twilight", "clock.moonPhase", "clock.season",
        "weather.rain", "weather.snow", "weather.clouds", "weather.wind", "weather.fog", "weather.thunder", "weather.temp", "weather.precip",
        "audio.level", "audio.bass", "audio.mid", "audio.treble", "audio.beat", "music.playing",
        "pulse.focus", "pulse.scatter", "pulse.fatigue", "pulse.momentum", "pulse.energy", "idle.depth",
    ]
    public static let colorNames = ["music.palette0", "music.palette1", "music.palette2"]
    public static let names = scalarNames + colorNames

    public var world: LerpWorldSnapshot?
    public var clock: LerpWorldSnapshot.Clock?
    public var audio: LerpAudioLevels?
    public var overrides: [String: LerpParamValue]

    public init(world: LerpWorldSnapshot? = nil, clock: LerpWorldSnapshot.Clock? = nil,
                audio: LerpAudioLevels? = nil, overrides: [String: LerpParamValue] = [:]) {
        self.world = world
        self.clock = clock
        self.audio = audio
        self.overrides = overrides
    }

    static func permitsLive(mode: LerpRenderMode, bundleIdentifier: String?) -> Bool {
        mode == .live && bundleIdentifier != nil
    }

    public static func live(mode: LerpRenderMode, at date: Date = Date(),
                            url: URL? = LerpWorldSnapshot.url) -> Self {
        guard permitsLive(mode: mode, bundleIdentifier: Bundle.main.bundleIdentifier) else { return Self() }
        return Self(world: url.flatMap { LerpWorldSnapshot.read(from: $0, now: date) },
                    clock: .calculate(at: date))
    }

    public static func scalarDomain(for name: String) -> ClosedRange<Double>? {
        switch name {
        case "clock.hour": return 0...24
        case "clock.sun": return -1...1
        default: return scalarNames.contains(name) ? 0...1 : nil
        }
    }

    public func scalar(for name: String) -> Double? {
        guard let domain = Self.scalarDomain(for: name) else { return nil }
        let c = world?.clock ?? clock
        let value: Double?
        if let explicit = overrides[name] { value = explicit.scalarValue }
        else {
            switch name {
            case "clock.hour": value = c?.hour
            case "clock.hourNorm": value = c?.hourNorm
            case "clock.sun": value = c?.sun
            case "clock.daylight": value = c?.daylight
            case "clock.twilight": value = c?.twilight
            case "clock.moonPhase": value = c?.moonPhase
            case "clock.season": value = c?.season
            case "weather.rain": value = world?.weather?.rain
            case "weather.snow": value = world?.weather?.snow
            case "weather.clouds": value = world?.weather?.clouds
            case "weather.wind": value = world?.weather?.wind
            case "weather.fog": value = world?.weather?.fog
            case "weather.thunder": value = world?.weather?.thunder
            case "weather.temp": value = world?.weather?.temp
            case "weather.precip": value = world?.weather?.precip
            case "music.playing": value = world?.music.map { $0.playing ? 1 : 0 }
            case "audio.level": value = audio.map { Double($0.level) }
            case "audio.bass": value = audio.map { Double($0.bass) }
            case "audio.mid": value = audio.map { Double($0.mid) }
            case "audio.treble": value = audio.map { Double($0.treble) }
            case "audio.beat": value = audio.map { Double($0.beat) }
            case "pulse.focus": value = world?.pulse?.focus
            case "pulse.scatter": value = world?.pulse?.scatter
            case "pulse.fatigue": value = world?.pulse?.fatigue
            case "pulse.momentum": value = world?.pulse?.momentum
            case "pulse.energy": value = world?.pulse?.energy
            case "idle.depth": value = world?.idle?.depth
            default: return nil
            }
        }
        guard let value, value.isFinite else { return nil }
        return max(domain.lowerBound, min(domain.upperBound, value))
    }

    public func color(for name: String) -> SIMD4<Float>? {
        guard let index = Self.colorNames.firstIndex(of: name) else { return nil }
        let color: SIMD4<Float>
        if let explicit = overrides[name] {
            guard let c = explicit.colorValue else { return nil }
            color = c
        } else {
            guard let music = world?.music, music.playing, let palette = music.palette,
                  palette.indices.contains(index), palette[index].count == 4 else { return nil }
            let rgba = palette[index]
            color = SIMD4(rgba[0], rgba[1], rgba[2], rgba[3])
        }
        guard (0..<4).allSatisfy({ (0...1).contains(color[$0]) }) else { return nil }
        return color
    }

    /// Explicit audio fixtures also drive shaders using the direct uniforms.
    func applyingAudioOverrides(to audio: LerpAudioLevels) -> LerpAudioLevels {
        func value(_ name: String, _ fallback: Float) -> Float {
            guard overrides[name] != nil, let scalar = scalar(for: name) else { return fallback }
            return Float(scalar)
        }
        return LerpAudioLevels(level: value("audio.level", audio.level), bass: value("audio.bass", audio.bass),
                               mid: value("audio.mid", audio.mid), treble: value("audio.treble", audio.treble),
                               beat: value("audio.beat", audio.beat))
    }
}
