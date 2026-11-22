import Foundation
import CoreGraphics
import ImageIO
import os

/// A small handoff to the sandboxed saver. All I/O happens here in Pulse,
/// never in a render callback. A failed weather request doesn't stop the clock.
final class WorldUpdater {
    private static let log = Logger(subsystem: "com.hergenroeder.lerping", category: "world")
    private let folder: URL
    private let clock = WorldClock()
    private let weather: WorldWeatherCache
    private let music: WorldMusicMonitor
    private var ledger: CritterLedger?
    private var idleSeconds: Double = 0

    init(folder: URL) {
        self.folder = folder
        let settings = WorldSettings.load(from: folder)
        weather = WorldWeatherCache(folder: folder, enabled: settings.weatherEnabled ?? true,
                                    location: settings.location)
        music = WorldMusicMonitor(folder: folder, settings: settings)
    }

    static var folder: URL {
        if let path = ProcessInfo.processInfo.environment["LERP_WORLD_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Lerping", isDirectory: true)
    }

    func start() {
        // A daemon can start while a song is already playing. Local state is
        // event-driven; it becomes known on the next playback notification.
        music.start { [weak self] in self?.publish() }
    }

    func tick(now: Date, ledger: CritterLedger?, idleSeconds: Double) {
        self.ledger = ledger
        self.idleSeconds = idleSeconds
        weather.refresh(now: now) { [weak self] in self?.publish() }
        music.tick(now: now)
        publish(now: now)
    }

    private func publish(now: Date = Date()) {
        let snapshot = WorldSnapshot(now: now, clock: clock.snapshot(now: now, location: weather.location),
                                     weather: weather.snapshot(now: now), music: music.snapshot(),
                                     ledger: ledger, idleSeconds: idleSeconds)
        do { try writeWorldJSON(snapshot, to: folder.appendingPathComponent("world.json")) }
        catch { Self.log.error("world.json write failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Same snapshot calculation as the daemon; no LaunchAgent, watcher, or
    /// disk writes. A valid cached Connect sample may supply the music state.
    static func probe(folder: URL, ledger: CritterLedger?, idleSeconds: Double) async throws -> Data {
        let settings = WorldSettings.load(from: folder)
        let weather = WorldWeatherCache(folder: folder, enabled: settings.weatherEnabled ?? true,
                                        location: settings.location)
        let before = Date()
        let reading = await weather.probe(now: before)
        let now = Date()
        let location = weather.location
        let music = WorldMusicMonitor.probe(folder: folder, settings: settings, now: now)
        return try worldEncoder().encode(WorldSnapshot(now: now,
            clock: WorldClock().snapshot(now: now, location: location), weather: reading, music: music,
            ledger: ledger, idleSeconds: idleSeconds))
    }
}

func worldUnit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }

func worldEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}

func writeWorldJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try worldEncoder().encode(value).write(to: url, options: .atomic)
}

struct WorldSnapshot: Encodable {
    struct Vitals: Encodable {
        let focus, scatter, fatigue, momentum, energy: Double
    }
    struct Idle: Encodable {
        // Contract fields are unit values. Full scale is 60 idle minutes;
        // depth is deliberately quicker, reaching 1 after 30 minutes.
        let minutes, depth: Double
    }
    let version = 1
    let updatedAt: Double
    let clock: WorldClock.Reading
    let weather: WorldWeather
    let music: WorldMusic
    let pulse: Vitals
    let idle: Idle

    init(now: Date, clock: WorldClock.Reading, weather: WorldWeather, music: WorldMusic,
         ledger: CritterLedger?, idleSeconds: Double) {
        updatedAt = now.timeIntervalSince1970
        self.clock = clock
        self.weather = weather
        self.music = music
        let v = ledger.map { CritterVitals(ledger: $0, now: now) } ?? CritterVitals()
        let energy = worldUnit(Double(v.energy))
        let calm = worldUnit(Double(v.calm))
        pulse = Vitals(focus: worldUnit(calm * Double(v.todayStreak) / 90), scatter: 1 - calm,
                       fatigue: 1 - energy, momentum: worldUnit(Double(v.makeShare) * Double(v.todayHours) / 3),
                       energy: energy)
        idle = Idle(minutes: worldUnit(idleSeconds / 3600), depth: worldUnit(idleSeconds / 1800))
    }
}

struct WorldSettings: Decodable {
    // Optional ~/Library/Application Support/Lerping/world-config.json, read
    // on launch. Coordinates override the timezone's reference city. Set
    // weatherEnabled=false to prevent weather requests. For an installed
    // agent, spotAPIBridge and spotAPIPython can point to absolute paths to
    // the checkout helper and an interpreter with SpotAPI installed. Connect
    // is off unless spotAPIWatchConnect=true; no passwords/cookies in JSON.
    var latitude: Double?
    var longitude: Double?
    var weatherEnabled: Bool?
    var spotAPIBridge: String?
    var spotAPIPython: String?
    var spotAPIWatchConnect: Bool?
    var spotAPIProfile: String?

    static func load(from folder: URL) -> Self {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: folder.appendingPathComponent("world-config.json")))) ?? Self()
    }

    var location: WorldLocation? {
        guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        return WorldLocation(latitude: latitude, longitude: longitude)
    }
}

struct WorldLocation: Codable, Equatable {
    let latitude, longitude: Double

    /// IANA zone.tab is shipped with macOS. Use its reference city, not a
    /// guessed IP location. Generic zones (e.g. UTC) don't imply any weather.
    static func reference(for zone: TimeZone) -> Self? {
        guard let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) else { return nil }
        return reference(zone: zone.identifier, in: table)
    }

    static func reference(zone: String, in table: String) -> Self? {
        for line in table.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == zone else { continue }
            let iso = fields[1]
            guard let split = iso.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }),
                  let lat = angle(iso[..<split], degrees: 2), let lon = angle(iso[split...], degrees: 3)
            else { return nil }
            return Self(latitude: lat, longitude: lon)
        }
        return nil
    }

    private static func angle(_ field: Substring, degrees: Int) -> Double? {
        let digits = field.dropFirst()
        guard digits.count == degrees + 2 || digits.count == degrees + 4,
              let d = Double(digits.prefix(degrees)), let m = Double(digits.dropFirst(degrees).prefix(2)),
              let s = digits.count == degrees + 4 ? Double(digits.suffix(2)) : 0 else { return nil }
        return (d + m / 60 + s / 3600) * (field.first == "-" ? -1 : 1)
    }
}

struct WorldClock {
    struct Reading: Encodable {
        let hour, hourNorm, sun, daylight, twilight, moonPhase, season: Double
    }

    func snapshot(now: Date, location: WorldLocation?, zone: TimeZone = .autoupdatingCurrent) -> Reading {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let civil = calendar.dateComponents([.hour, .minute, .second], from: now)
        let hour = Double(civil.hour ?? 0) + Double(civil.minute ?? 0) / 60 + Double(civil.second ?? 0) / 3600
        let yearDays = Double(calendar.range(of: .day, in: .year, for: now)?.count ?? 365)
        let day = Double(calendar.ordinality(of: .day, in: .year, for: now) ?? 1)
        // NOAA's fractional-year solar declination and equation of time. The
        // UTC offset is evaluated for the date (including daylight saving).
        // https://gml.noaa.gov/grad/solcalc/solareqns.PDF
        let gamma = 2 * Double.pi * (day - 1 + (hour - 12) / 24) / yearDays
        let (c1, s1, c2, s2, c3, s3) = (cos(gamma), sin(gamma), cos(2 * gamma), sin(2 * gamma), cos(3 * gamma), sin(3 * gamma))
        let equation = 229.18 * (0.000075 + 0.001868 * c1 - 0.032077 * s1 - 0.014615 * c2 - 0.040849 * s2)
        let declination = 0.006918 - 0.399912 * c1 + 0.070257 * s1 - 0.006758 * c2 + 0.000907 * s2 - 0.002697 * c3 + 0.00148 * s3
        let utcOffset = Double(zone.secondsFromGMT(for: now)) / 60
        let longitude = location?.longitude ?? (utcOffset - zone.daylightSavingTimeOffset(for: now) / 60) / 4
        let latitude = (location?.latitude ?? 40) * .pi / 180
        let angle = (hour * 60 + equation + 4 * longitude - utcOffset - 720) * .pi / 720
        let elevation = asin(min(1, max(-1, sin(latitude) * sin(declination)
            + cos(latitude) * cos(declination) * cos(angle)))) * 180 / .pi
        func ramp(_ low: Double, _ high: Double) -> Double {
            let x = worldUnit((elevation - low) / (high - low))
            return x * x * (3 - 2 * x)
        }
        let daylight = ramp(-6, 6)
        let twilight = ramp(-18, -3) * (1 - ramp(-3, 6))
        // Mean synodic phase (new=0, full=.5), anchored to the 2000-01-06
        // 18:14 UTC new moon. Intentional approximation, not an ephemeris.
        let lunations = (now.timeIntervalSince1970 - 947182440) / (29.530588853 * 86400)
        let season = (day - 1 + hour / 24) / yearDays
        return Reading(hour: hour, hourNorm: hour / 24, sun: elevation / 90, daylight: daylight,
                       twilight: twilight, moonPhase: lunations - floor(lunations), season: season)
    }
}
