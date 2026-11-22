import Foundation

struct WorldWeather: Codable {
    let rain, snow, clouds, wind, fog, thunder, temp, precip: Double
    let label: String

    static let unavailable = Self(rain: 0, snow: 0, clouds: 0, wind: 0, fog: 0,
                                  thunder: 0, temp: 0.5, precip: 0, label: "Unavailable")
}

struct WorldWeatherObservation: Codable {
    let location: WorldLocation
    let observedAt: Double
    let weather: WorldWeather

    func isFresh(at now: Date, for location: WorldLocation) -> Bool {
        let age = now.timeIntervalSince1970 - observedAt
        return self.location == location && (-900...21600).contains(age)
    }
}

struct OpenMeteoReading: Decodable {
    struct Current: Decodable {
        let time: Double
        let interval, weather_code: Int
        let temperature_2m, precipitation, rain, showers, snowfall, cloud_cover, wind_speed_10m: Double
    }
    struct Hourly: Decodable {
        let time: [Double]
        let visibility: [Double?]
    }
    let current: Current
    let hourly: Hourly?

    func observation(at location: WorldLocation) -> WorldWeatherObservation {
        let c = current
        let code = c.weather_code
        // Measurements are accumulated for `interval` seconds; normalize on
        // hourly rates. WMO codes add a floor for light/modelled precipitation.
        let hour = 3600 / Double(max(1, c.interval))
        let wet = [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99].contains(code)
        let snowy = [71, 73, 75, 77, 85, 86].contains(code)
        let foggy = code == 45 || code == 48
        let storm = [95, 96, 99].contains(code)
        let label: String
        switch code {
        case 0: label = "Clear"
        case 1, 2: label = "Partly cloudy"
        case 3: label = "Overcast"
        case 45, 48: label = "Fog"
        case 51, 53, 55: label = "Drizzle"
        case 56, 57, 66, 67: label = "Freezing rain"
        case 61, 63, 65, 80, 81, 82: label = "Rain"
        case 71, 73, 75, 77, 85, 86: label = "Snow"
        case 95, 96, 99: label = "Thunderstorm"
        default: label = "Unknown"
        }
        let visibility = hourly.flatMap { h -> Double? in
            guard let index = h.time.indices.min(by: { abs(h.time[$0] - c.time) < abs(h.time[$1] - c.time) }),
                  abs(h.time[index] - c.time) <= 3600, h.visibility.indices.contains(index) else { return nil }
            return h.visibility[index]
        }
        let rain = worldUnit(max(wet ? 0.12 : 0, (c.rain + c.showers) * hour / 12))
        let snow = worldUnit(max(snowy ? 0.12 : 0, c.snowfall * hour / 4))
        let weather = WorldWeather(rain: rain, snow: snow, clouds: worldUnit(c.cloud_cover / 100),
            wind: worldUnit(c.wind_speed_10m / 75),
            fog: max(foggy ? 0.55 : 0, visibility.map { worldUnit(1 - $0 / 5000) } ?? 0),
            thunder: storm ? (code == 95 ? 0.75 : 1) : 0, temp: worldUnit((c.temperature_2m + 20) / 65),
            precip: worldUnit(max(rain, snow, c.precipitation * hour / 12)), label: label)
        return WorldWeatherObservation(location: location, observedAt: c.time, weather: weather)
    }
}

/// Memory-first, with an atomic disk cache across restarts. A failed fetch
/// leaves the last observation intact and will not retry on every minute tick.
final class WorldWeatherCache {
    private let enabled: Bool
    private let override: WorldLocation?
    private let url: URL
    private var zone = TimeZone.autoupdatingCurrent.identifier
    private(set) var location: WorldLocation?
    private var cached: WorldWeatherObservation?
    private var lastAttempt: Date?
    private var inFlight = false

    init(folder: URL, enabled: Bool, location: WorldLocation?) {
        self.enabled = enabled
        override = location
        self.location = location ?? WorldLocation.reference(for: .autoupdatingCurrent)
        url = folder.appendingPathComponent("world-weather.json")
        if enabled, let data = try? Data(contentsOf: url) {
            cached = try? JSONDecoder().decode(WorldWeatherObservation.self, from: data)
        }
    }

    func snapshot(now: Date) -> WorldWeather {
        guard enabled, let location, let cached, cached.isFresh(at: now, for: location) else { return .unavailable }
        return cached.weather
    }

    func probe(now: Date) async -> WorldWeather {
        guard enabled, let location else { return .unavailable }
        if let cached, cached.isFresh(at: now, for: location), now.timeIntervalSince1970 - cached.observedAt < 3600 {
            return cached.weather
        }
        if let reading = await Self.fetch(location), reading.isFresh(at: Date(), for: location) {
            return reading.weather
        }
        return snapshot(now: Date())
    }

    func refresh(now: Date, onChange: @escaping () -> Void) {
        let currentZone = TimeZone.autoupdatingCurrent
        if currentZone.identifier != zone {
            zone = currentZone.identifier
            location = override ?? WorldLocation.reference(for: currentZone)
            lastAttempt = nil
        }
        guard enabled, let location, !inFlight else { return }
        if let lastAttempt, (0..<3600).contains(now.timeIntervalSince(lastAttempt)) { return }
        if let cached, cached.isFresh(at: now, for: location), now.timeIntervalSince1970 - cached.observedAt < 3600 { return }
        lastAttempt = now
        inFlight = true
        Task { @MainActor [weak self] in
            let reading = await Self.fetch(location)
            guard let self else { return }
            self.inFlight = false
            guard let reading, self.location == location, reading.isFresh(at: Date(), for: location) else { return }
            self.cached = reading
            try? writeWorldJSON(reading, to: self.url)
            onChange()
        }
    }

    private static func fetch(_ location: WorldLocation) async -> WorldWeatherObservation? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,precipitation,rain,showers,snowfall,weather_code,cloud_cover,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "visibility"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ]
        guard let url = components.url, let data = await WorldDownload.get(url, byteLimit: 64 * 1024),
              let reading = try? JSONDecoder().decode(OpenMeteoReading.self, from: data) else { return nil }
        return reading.observation(at: location)
    }
}

/// External data stays bounded and never follows redirects (including artwork
/// URLs from distributed notifications, which aren't authenticated IPC).
final class WorldDownload: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func get(_ url: URL, byteLimit: Int) async -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: WorldDownload(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Int64(byteLimit) else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < byteLimit else { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
