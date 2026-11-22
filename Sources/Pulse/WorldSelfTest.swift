import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Fixtures only: no accounts, location requests, preferences or disk writes.
enum WorldSelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if !condition() { print("world FAIL: \(name)"); failures += 1 }
        }
        let zone = TimeZone(secondsFromGMT: 0)!
        let day = ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z")!
        let table = "# coordinates\nUS\t+404251-0740023\tAmerica/New_York\nAU\t-3352+15113\tAustralia/Sydney\n"
        let ny = WorldLocation.reference(zone: "America/New_York", in: table)
        check("timezone latitude/longitude", abs((ny?.latitude ?? 0) - 40.7142) < 0.001 && abs((ny?.longitude ?? 0) + 74.0064) < 0.001)
        check("southern hemisphere", (WorldLocation.reference(zone: "Australia/Sydney", in: table)?.latitude ?? 0) < -33)
        check("UTC does not imply a city", WorldLocation.reference(zone: "UTC", in: table) == nil)
        let origin = WorldLocation(latitude: 0, longitude: 0)
        let clock = WorldClock()
        let noon = clock.snapshot(now: day, location: origin, zone: zone)
        let night = clock.snapshot(now: day.addingTimeInterval(-43200), location: origin, zone: zone)
        check("equinox sun, noon and midnight", noon.hour == 12 && noon.hourNorm == 0.5 && noon.sun > 0.96 && night.sun < -0.96)
        check("daylight response", noon.daylight == 1 && night.daylight == 0 && night.twilight == 0)
        let newMoon = clock.snapshot(now: Date(timeIntervalSince1970: 947182440), location: origin, zone: zone)
        check("clock phase and season", newMoon.moonPhase == 0 && (0..<1).contains(noon.moonPhase)
              && (0.2...0.25).contains(noon.season))

        let forecast = """
        {"current":{"time":10000,"interval":900,"weather_code":95,"temperature_2m":12,"precipitation":2,
                    "rain":1,"showers":1,"snowfall":0,"cloud_cover":90,"wind_speed_10m":50},
         "hourly":{"time":[7200,10800],"visibility":[12000,1000]}}
        """
        guard let forecast = try? JSONDecoder().decode(OpenMeteoReading.self, from: Data(forecast.utf8)) else {
            print("world FAIL: weather fixture decode")
            return false
        }
        let weather = forecast.observation(at: origin)
        check("weather mapping", weather.weather.label == "Thunderstorm" && weather.weather.thunder == 0.75
              && weather.weather.fog > 0.75 && weather.weather.rain > 0.65 && weather.weather.clouds == 0.9 && weather.weather.snow == 0)
        check("weather freshness and location", weather.isFresh(at: Date(timeIntervalSince1970: 11000), for: origin)
              && !weather.isFresh(at: Date(timeIntervalSince1970: 40000), for: origin)
              && !weather.isFresh(at: Date(timeIntervalSince1970: 11000), for: WorldLocation(latitude: 1, longitude: 1)))

        let playing = WorldTrack.local(["Player State": "Playing", "Name": "A", "Track ID": "spotify:track:1",
                                        "Artwork URL": "https://i.scdn.co/image/art"], source: "spotify", previous: nil)
        let paused = WorldTrack.local(["Player State": "Paused"], source: "spotify", previous: playing)
        let changed = WorldTrack.local(["Player State": "Playing", "Name": "B", "Track ID": "spotify:track:2"], source: "spotify", previous: paused)
        let stopped = WorldTrack.local(["Player State": "Stopped"], source: "spotify", previous: paused)
        check("pause keeps metadata, new track clears old art, stop clears metadata", playing?.music.playing == true
              && paused?.music.playing == false && paused?.music.title == "A" && paused?.imageURL != nil
              && changed?.imageURL == nil && stopped?.music.title == "")
        check("untrusted artwork URLs are ignored", WorldArtwork.url("file:///tmp/x") == nil
              && WorldArtwork.url("https://i.scdn.co.evil.example/image/foo") == nil)
        let apple = fixtureArtwork().flatMap { image in
            WorldTrack.local(["Player State": "Playing", "Name": "Music fixture", "Artwork Data": image],
                             source: "apple-music", previous: nil)
        }
        let palette = apple?.imageData.flatMap { WorldArtwork.palette($0) }
        check("Apple Music artwork data decodes to three luminance-ordered colors", apple?.music.playing == true
              && palette == [[1, 1, 1, 1], [1, 0, 0, 1], [0, 0, 0, 1]])

        let snapshot = WorldSnapshot(now: day, clock: noon, weather: weather.weather, music: .init(), ledger: nil, idleSeconds: 900)
        check("normalized idle signals", snapshot.idle.depth == 0.5 && snapshot.idle.minutes == 0.25)
        let json = (try? worldEncoder().encode(snapshot)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        check("world v1 top-level schema", json?["version"] as? Int == 1
              && Set(json?.keys.map { $0 } ?? []) == ["version", "updatedAt", "clock", "weather", "music", "pulse", "idle"])
        if failures == 0 { print("world selftest: clock, weather, Now Playing, artwork, and schema OK") }
        return failures == 0
    }

    private static func fixtureArtwork() -> Data? {
        let size = 48
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, rgb) in [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (1.0, 1.0, 1.0)].enumerated() {
            ctx.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            ctx.fill(CGRect(x: 16 * i, y: 0, width: 16, height: size))
        }
        let data = NSMutableData()
        guard let image = ctx.makeImage(),
              let dst = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? data as Data : nil
    }
}
