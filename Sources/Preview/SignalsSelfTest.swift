import Foundation

/// CPU fixtures plus an actual Metal render across the fixed/parameter ABI.
enum SignalsSelfTest {
    static func run() {
        do { try checkAll() }
        catch { PreviewMain.fail("signals: \(error)") }
        print("signals: parser/writer, mapping, palette, pin/override, smoothing, clock, world file and Metal snapshot purity passed")
    }

    static func checkAll() throws {
        func check(_ ok: Bool, _ description: String) {
            if !ok { PreviewMain.fail("signals: \(description)") }
        }
        func near(_ actual: Double?, _ expected: Double) -> Bool {
            actual.map { abs($0 - expected) < 1e-5 } == true
        }
        let source = """
            // lerp-react: level <- clock.hour 0.2..0.8 smooth=2
            // lerp-param: level float 0 1 = 0.1
            // lerp-param: tint color = #000000
            // lerp-react: tint <- music.palette1 mix=0.5
            // lerp-preset: Held level=0.1
            fragment half4 lerpMain(float4 p [[position]], constant LerpUniforms& u [[buffer(0)]]) {
                return half4(u.level, u.tint.g, u.audioBeat + u.viewer.x, 1);
            }
            """
        let parsed = LerpParamParser.parse(source: source)
        check(parsed.errors.isEmpty && parsed.parameters[0].reaction?.smooth == 2, "forward reaction")
        for bad in ["missing <- weather.rain", "level <- unknown", "tint <- audio.bass",
                    "level <- weather.rain 0..nan", "level <- audio.level smooth=-1",
                    "tint <- music.palette0 mix=2", "level <- weather.snow"] {
            let invalid = LerpParamParser.parse(source: source + "\n// lerp-react: " + bad)
            check(invalid.errors.count == 1 && invalid.errors[0].line == 9, "line diagnostics: \(bad)")
        }
        let updated = try LerpReactionWriter.writing(.init(paramName: "level", signal: "weather.rain"),
                                                     for: "level", in: source + "\n")
        check(updated.hasSuffix("\n") && LerpParamParser.parse(source: updated).parameters[0].reaction?.signal == "weather.rain",
              "writer replacement and newline")
        let removed = try LerpReactionWriter.writing(nil, for: "level", in: updated)
        check(LerpParamParser.parse(source: removed).parameters[0].reaction == nil, "writer removal")
        let added = try LerpReactionWriter.writing(parsed.parameters[0].reaction, for: "level", in: removed)
        check(LerpParamParser.parse(source: added).parameters[0].reaction == parsed.parameters[0].reaction, "writer insertion")

        let values = LerpParameterValues(parsed.parameters)
        let signals = LerpSignalValues(overrides: ["clock.hour": .scalar(12), "music.palette1": .color(SIMD4(1, 0.6, 0, 1))])
        let reacted = values.reacting(to: signals, at: 0)
        check(near(reacted["level"]?.scalarValue, 0.5), "hour-to-range mapping")
        let negativeSun = LerpSignalValues(overrides: ["clock.sun": .scalar(-0.5)])
        let reversed = LerpParamReaction(paramName: "level", signal: "clock.sun", min: 1, max: 0)
        check(near(reversed.target(in: negativeSun, base: .scalar(0))?.scalarValue, 0.75), "signed domain and inversion")
        check(reacted["tint"]?.colorValue == SIMD4(0.5, 0.3, 0, 1), "palette mixing")
        check(near(values.reacting(to: .init(), at: 0)["level"]?.scalarValue, 0.1), "missing signal fallback")
        var held = values
        held.apply(parsed.presets[0])
        check(!held.rendersSameLook(as: values), "preset pin distinct from defaults")
        check(near(held.reacting(to: signals, at: 0)["level"]?.scalarValue, 0.1), "preset pin")
        held.set("level", to: 0.2)
        check(near(held.reacting(to: signals, at: 0)["level"]?.scalarValue, 0.2) && !held.isReacting("level"), "manual pin")
        held.setReacting("level", true)
        check(near(held.reacting(to: signals, at: 0)["level"]?.scalarValue, 0.5), "return to signal")
        let smoother = LerpReactionSmoothing()
        _ = values.reacting(to: .init(overrides: ["clock.hour": .scalar(0)]), at: 0, smoothing: smoother)
        check(near(values.reacting(to: signals, at: 2, smoothing: smoother)["level"]?.scalarValue,
                   0.5 - 0.3 / exp(1.0)), "live exponential smoothing")
        check(near(values.reacting(to: signals, at: 1, smoothing: smoother)["level"]?.scalarValue, 0.5), "rewind resets smoothing")
        let flags = PreviewMain.signalOverrides(["--signal", "weather.rain=0.9", "--signal", "clock.hour=21.5",
                                                 "--signal", "music.palette0=#ff0000"])
        check(flags["weather.rain"] == .scalar(0.9) && flags["clock.hour"] == .scalar(21.5)
              && flags["music.palette0"] == .color(SIMD4(1, 0, 0, 1)), "repeatable CLI flags")

        let calendar = ISO8601DateFormatter()
        let now = calendar.date(from: "2026-03-20T12:00:00Z")!
        let utc = TimeZone(secondsFromGMT: 0)!
        let noon = LerpWorldSnapshot.Clock.calculate(at: now, latitude: 0, longitude: 0, timeZone: utc)
        let night = LerpWorldSnapshot.Clock.calculate(at: now.addingTimeInterval(-12 * 3600),
                                                      latitude: 0, longitude: 0, timeZone: utc)
        check(noon.hour == 12 && noon.hourNorm == 0.5 && noon.sun > 0.95 && noon.daylight == 1,
              "equinox noon")
        check(night.sun < -0.95 && night.daylight == 0 && night.twilight == 0, "equinox midnight")
        let moon = LerpWorldSnapshot.Clock.calculate(at: Date(timeIntervalSince1970: 947_182_440 + 14.7652944265 * 86_400))
        check(near(moon.moonPhase, 0.5) && (0...1).contains(moon.season), "moon and season domains")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lerp-signals-selftest-\(getpid())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("world.json")
        check(LerpWorldSnapshot.read(from: url, now: now) == nil, "missing world")
        let world = LerpWorldSnapshot(updatedAt: now.timeIntervalSince1970, clock: noon,
            weather: .init(rain: 0.8, snow: 0, clouds: 0.9, wind: 0.2, fog: 0, thunder: 0.3, temp: 0.5, precip: 0.8, label: "Rain"),
            music: .init(playing: true, title: "Track", artist: "Artist", album: "Album", source: "Fixture", trackUri: "test:track",
                         palette: [[0.1, 0.2, 0.3, 1]]),
            pulse: .init(focus: 0.3, scatter: 0.4, fatigue: 0.1, momentum: 0.2, energy: 0.5), idle: .init(minutes: 0.1, depth: 0.2))
        try JSONEncoder().encode(world).write(to: url, options: .atomic)
        check(LerpWorldSnapshot.read(from: url, now: now) == world, "world round trip")
        check(near(LerpSignalValues(world: world).scalar(for: "weather.rain"), 0.8), "world lookup")
        check(LerpWorldSnapshot.read(from: url, now: now.addingTimeInterval(3 * 3600)) == nil, "stale world")
        check(LerpSignalValues.live(mode: .still, at: now, url: url).scalar(for: "clock.hour") == nil, "still ignores disk and clock")
        check(!LerpSignalValues.permitsLive(mode: .live, bundleIdentifier: nil), "unbundled host ignores live inputs")
        try Data("{broken".utf8).write(to: url, options: .atomic)
        check(LerpWorldSnapshot.read(from: url, now: now) == nil, "corrupt world")
        var future = world
        future.version = 2
        try JSONEncoder().encode(future).write(to: url, options: .atomic)
        check(LerpWorldSnapshot.read(from: url, now: now) == nil, "unknown world version")

        let shader = LerpShader(name: "signals-selftest", source: source, isBuiltIn: false, url: nil)
        let (renderer, library) = PreviewMain.makeLibrary([])
        func picture(_ name: String, _ overrides: [String: LerpParamValue] = [:],
                     params: LerpParameterValues? = nil) throws -> Data {
            let target = dir.appendingPathComponent(name + ".png")
            let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                             width: 8, height: 8, time: 2, seed: 0.5, params: params,
                                             viewer: LerpViewer(x: 0.2), signalOverrides: overrides, to: target)
            check(result.error == nil, "Metal snapshot: \(result.error ?? "")")
            return try Data(contentsOf: target)
        }
        var fixtures = signals.overrides
        fixtures["audio.beat"] = .scalar(0.4)
        let baseline = try picture("baseline")
        let reactive = try picture("reactive", fixtures)
        let repeated = try picture("repeated")
        check(baseline != reactive && baseline == repeated, "snapshot purity and explicit fixtures")
        var expected = values
        expected.set("level", to: 0.5)
        expected.set("tint", .color(SIMD4(0.5, 0.3, 0, 1)))
        let pinned = try picture("pinned", ["audio.beat": .scalar(0.4)], params: expected)
        let noBeat = try picture("no-beat", signals.overrides)
        check(reactive == pinned && noBeat != reactive, "Metal scalar/color tail and beat uniform")
    }
}
