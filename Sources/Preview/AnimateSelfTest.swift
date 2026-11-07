import Foundation
import Metal

/// `LerpPreview --animate-selftest`: the `// lerp-animate:` contract, checked
/// where it can be seen.
///
/// - The grammar refuses what it should, naming the line.
/// - The curve stays inside its bounds, moves, and moves smoothly.
/// - A frame is a pure function of (shader, time, seed, parameters): the PNG
///   for t = T is the same bytes cold, after rendering everything before it,
///   and after scrubbing back from later — and a data provider's `params`
///   overload is handed the animated value, not the held one.
/// - Presets pin, re-animate and re-bound exactly as documented, and Save Look
///   as Preset's writer round-trips every one of those states.
enum AnimateSelfTest {

    static func run(_ extraSearch: [URL]) {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            if !ok { failures.append(what()) }
        }

        grammar(check)
        curve(check)
        presets(check)
        writer(check)
        rendering(extraSearch, check)

        guard failures.isEmpty else {
            for failure in failures { FileHandle.standardError.write(("FAIL  " + failure + "\n").data(using: .utf8)!) }
            PreviewMain.fail("animate self-test: \(failures.count) check\(failures.count == 1 ? "" : "s") failed")
        }
        print("OK    lerp-animate: grammar errors, bounded smooth curve, purity cold/warm/scrubbed, "
              + "provider sees animated value, preset pin/animate/re-bound, writer round trip")
    }

    // MARK: - Grammar

    static let header = """
        // lerp-param: level  float 0 1 = 0.5 "Level"
        // lerp-param: tint   color     = #204060
        // lerp-param: count  int 1 8   = 4
        // lerp-param: flag   bool      = false
        """

    static func grammar(_ check: (Bool, @autoclosure () -> String) -> Void) {
        // Each bad line goes on line 5, right under the four declarations.
        let bad: [(line: String, expect: String)] = [
            ("// lerp-animate: count 2 6", "only float and color"),
            ("// lerp-animate: flag 0 1", "only float and color"),
            ("// lerp-animate: nope 0 1", "not a declared parameter"),
            ("// lerp-animate: level 0.2 1.5", "outside"),
            ("// lerp-animate: level 0.3 0.3", "would not move"),
            ("// lerp-animate: level 0.2 0.6 period=3", "floor"),
            ("// lerp-animate: level 0.2 0.6 period=soon", "number of seconds"),
            ("// lerp-animate: level 0.2 0.6 speed=2", "unknown animation option"),
            ("// lerp-animate: level 0.2", "two bounds"),
            ("// lerp-animate: level", "needs LOW and HIGH"),
            ("// lerp-animate: level #102030 #405060", "must be numbers"),
            ("// lerp-animate: tint 0.1 0.2", "must be colours"),
            ("// lerp-animate: tint #102030 #102030", "same colour"),
            ("// lerp-preset: P level=animate", "needs bounds"),
            ("// lerp-preset: P level=animate(0.1, 2)", "outside"),
            ("// lerp-preset: P level=animate(0.1, 0.4", "closing"),
            ("// lerp-preset: P count=animate(1, 3)", "only float and color"),
        ]
        for (line, expect) in bad {
            let parsed = LerpParamParser.parse(source: header + "\n" + line)
            check(parsed.errors.contains { $0.line == 5 && $0.message.contains(expect) },
                  "grammar: `\(line)` should fail on line 5 with “\(expect)”, got \(parsed.errors.map(\.description))")
        }

        let twice = LerpParamParser.parse(source: header
            + "\n// lerp-animate: level 0.2 0.6\n// lerp-animate: level 0.3 0.7")
        check(twice.errors.contains { $0.line == 6 && $0.message.contains("duplicate") },
              "grammar: a second lerp-animate for one parameter must be a duplicate error on its line")

        // Order-independent, colours animate, `180s` reads as seconds, and the
        // period defaults when left out.
        let good = LerpParamParser.parse(source: """
            // lerp-animate: level 0.2 0.6 period=180s
            // lerp-animate: tint (0.1, 0.2, 0.3) #405060
            \(header)
            """)
        check(good.errors.isEmpty, "grammar: valid declarations reported \(good.errors.map(\.description))")
        let level = good.parameters.first { $0.name == "level" }
        check(level?.animation == LerpParamAnimation(low: .scalar(0.2), high: .scalar(0.6), period: 180),
              "grammar: level's animation parsed as \(String(describing: level?.animation))")
        let tint = good.parameters.first { $0.name == "tint" }
        check(tint?.animation?.period == LerpParamAnimation.defaultPeriod && tint?.animation?.low.colorValue != nil,
              "grammar: tint should animate between colours with the default period")
        check(good.parameters.first { $0.name == "count" }?.animation == nil,
              "grammar: an undeclared animation must stay nil")
    }

    // MARK: - Curve

    static func curve(_ check: (Bool, @autoclosure () -> String) -> Void) {
        let param = LerpParam(name: "level", type: .float, min: 0, max: 1, defaultValue: .scalar(0.5), label: "Level")
        let animation = LerpParamAnimation(low: .scalar(0.2), high: .scalar(0.6), period: 60)
        var lowest = 1.0, highest = 0.0, steepest = 0.0
        var previous: Double?
        for step in 0...36_000 {                        // ten minutes at 60 fps
            let time = Float(step) / 60
            guard let v = animation.value(for: param, time: time, seed: 0.37).scalarValue else { continue }
            lowest = min(lowest, v); highest = max(highest, v)
            if let previous { steepest = max(steepest, abs(v - previous)) }
            previous = v
        }
        check(lowest >= 0.2 - 1e-9 && highest <= 0.6 + 1e-9,
              "curve: left its bounds, saw \(lowest)…\(highest)")
        check(highest - lowest > 0.3, "curve: barely moved over ten minutes (\(lowest)…\(highest))")
        // A 0.4 span on a 60 s period moves at most 0.2 × (0.75 + 0.25 × φ) ×
        // 2π/60 ≈ 0.024 per second, or 0.0004 a frame; five times that is a
        // jump, not drift.
        check(steepest < 0.002, "curve: jumped \(steepest) in one 1/60 s frame")

        let a = animation.value(for: param, time: 30, seed: 0.1)
        let b = animation.value(for: param, time: 30, seed: 0.6)
        check(a != b, "curve: the seed must move the phase")
        let other = LerpParam(name: "other", type: .float, min: 0, max: 1, defaultValue: .scalar(0.5), label: "Other")
        check(animation.value(for: param, time: 30, seed: 0.1) != animation.value(for: other, time: 30, seed: 0.1),
              "curve: two parameters with one period must not move in lock-step")
    }

    // MARK: - Presets

    static func presets(_ check: (Bool, @autoclosure () -> String) -> Void) {
        let shader = LerpShader(name: "animate-presets", source: """
            // lerp-param: level  float 0 1 = 0.5
            // lerp-param: other  float 0 1 = 0.5
            // lerp-animate: level 0.2 0.6 period=60
            // lerp-preset: Pinned   level=0.5
            // lerp-preset: Calm     level=animate(0.3, 0.4, period=200)
            // lerp-preset: Quick    level=animate(period=20)
            // lerp-preset: Both     other=animate(0.1, 0.9)
            // lerp-preset: Silent   other=0.25
            // lerp-preset: Redo     level=0.4
            // lerp-preset: Redo     level=animate
            """, isBuiltIn: false, url: nil)
        check(shader.parameterErrors.isEmpty, "presets: fixture reported \(shader.parameterErrors.map(\.description))")
        func look(_ preset: String?) -> LerpParameterValues {
            shader.parameterValues(for: LerpRotationEntry(shader: shader.name, preset: preset))
        }
        let declared = shader.parameters[0].animation

        let defaults = look(nil)
        check(defaults.isAnimating("level") && !defaults.isAnimating("other"),
              "presets: defaults must animate `level` only")
        check(defaults.resolved(time: 10, seed: 0.3)["level"] != defaults.resolved(time: 40, seed: 0.3)["level"],
              "presets: an animating parameter must change with time")

        let pinned = look("Pinned")
        check(!pinned.isAnimating("level"), "presets: a preset that sets a value must pin it")
        check([0, 13, 99].allSatisfy { pinned.resolved(time: $0, seed: 0.3)["level"] == .scalar(0.5) },
              "presets: a pinned parameter must hold its value at every time")
        check(!pinned.rendersSameLook(as: defaults),
              "presets: pinning at the default value is still a different look")

        let calm = look("Calm")
        check(calm.activeAnimations["level"] == LerpParamAnimation(low: .scalar(0.3), high: .scalar(0.4), period: 200),
              "presets: animate(LOW, HIGH, period=) must replace the declared drift")
        let quick = look("Quick")
        check(quick.activeAnimations["level"] == LerpParamAnimation(low: .scalar(0.2), high: .scalar(0.6), period: 20),
              "presets: animate(period=) must keep the declared bounds")
        let both = look("Both")
        check(both.isAnimating("level") && both.isAnimating("other"),
              "presets: a preset that does not name `level` keeps its declared drift, and can animate `other`")
        let silent = look("Silent")
        check(silent.activeAnimations["level"] == declared,
              "presets: a preset silent about `level` must inherit its declared drift")
        let redo = look("Redo")
        check(redo.activeAnimations["level"] == declared,
              "presets: a later `level=animate` must win over an earlier `level=0.4` in the same preset")

        // The rotation tells a pinned-at-default preset apart from Defaults —
        // and folds `Redo`, which ends up animating exactly as declared, into
        // the Defaults tile as it does any preset that reproduces the defaults.
        let pinOnly = LerpShader(name: "animate-pin-only", source: """
            // lerp-param: level  float 0 1 = 0.5
            // lerp-animate: level 0.2 0.6 period=60
            // lerp-preset: Pinned   level=0.5
            """, isBuiltIn: false, url: nil)
        check([pinOnly].rotationEntries().contains(LerpRotationEntry(shader: pinOnly.name)),
              "presets: Defaults must keep its own tile when a preset only pins the animation")
        check(![shader].rotationEntries().contains(LerpRotationEntry(shader: shader.name)),
              "presets: `Redo` reproduces the defaults, so it should replace the Defaults tile")

        // The held state: a value pins, `setAnimating` hands it back.
        var live = look(nil)
        live.set("level", to: 0.9)
        check(!live.isAnimating("level") && live.resolved(time: 5, seed: 0)["level"] == .scalar(0.9),
              "presets: set() must pin an animating parameter at the value set")
        live.setAnimating("level", true)
        check(live.isAnimating("level") && live.rendersSameLook(as: defaults),
              "presets: setAnimating(true) must restore the drift (the held value is then invisible)")
        check(!live.setAnimating("other", true), "presets: a parameter with no drift cannot be set animating")
    }

    // MARK: - Writer round trip

    static func writer(_ check: (Bool, @autoclosure () -> String) -> Void) {
        let source = """
            // lerp-param: level  float 0 1 = 0.5
            // lerp-param: other  float 0 1 = 0.5
            // lerp-param: tint   color     = #204060
            // lerp-animate: level 0.2 0.6 period=60
            """
        let shader = LerpShader(name: "animate-writer", source: source, isBuiltIn: false, url: nil)
        typealias Edit = (inout LerpParameterValues) -> Void
        let states: [(String, Edit)] = [
            ("pinned at default", { $0.setAnimating("level", false) }),
            ("pinned elsewhere", { $0.set("level", to: 0.33) }),
            ("re-bounded", { $0.animate("level", with: LerpParamAnimation(low: .scalar(0.1), high: .scalar(0.3), period: 90)) }),
            ("new drift on a still parameter", {
                $0.animate("other", with: LerpParamAnimation(low: .scalar(0.4), high: .scalar(0.7), period: 240))
                $0.set("tint", .color(SIMD4<Float>(0.5, 0.25, 0.125, 1)))
            }),
            ("colour drift", {
                $0.animate("tint", with: LerpParamAnimation(low: .color(SIMD4<Float>(0.1, 0.2, 0.3, 1)),
                                                            high: .color(SIMD4<Float>(0.3, 0.2, 0.1, 1)), period: 150))
            }),
        ]
        for (label, edit) in states {
            var live = shader.defaultParameterValues()
            edit(&live)
            let lines = LerpPresetWriter.declaration(name: "Saved",
                                                     overrides: LerpPresetWriter.overrides(in: live),
                                                     animations: LerpPresetWriter.animationOverrides(in: live))
            let reread = LerpShader(name: shader.name, source: source + "\n" + lines.joined(separator: "\n"),
                                    isBuiltIn: false, url: nil)
            check(reread.parameterErrors.isEmpty,
                  "writer (\(label)): \(lines) re-read with \(reread.parameterErrors.map(\.description))")
            let back = reread.parameterValues(for: LerpRotationEntry(shader: shader.name, preset: "Saved"))
            check(back.rendersSameLook(as: live) && back.activeAnimations == live.activeAnimations,
                  "writer (\(label)): \(lines) does not reproduce the look on screen")
        }
        // Nothing moved: nothing to write.
        let untouched = shader.defaultParameterValues()
        check(LerpPresetWriter.overrides(in: untouched).isEmpty
                && LerpPresetWriter.animationOverrides(in: untouched).isEmpty,
              "writer: the Defaults look, untouched, must have nothing to save")
    }

    // MARK: - Rendering

    /// Records the `level` each bind is handed, so the test can see what a
    /// data provider is given rather than infer it from pixels.
    final class Probe: LerpDataProvider {
        nonisolated(unsafe) static var seen: [Double] = []
        let metalPrelude = ""
        func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {}
        func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms, params: LerpParameterValues?) {
            if let level = params?["level"]?.scalarValue { Self.seen.append(level) }
        }
    }

    static func rendering(_ extraSearch: [URL], _ check: (Bool, @autoclosure () -> String) -> Void) {
        LerpDataProviders.register("animate-selftest-probe") { _, _ in Probe() }
        let shader = LerpShader(name: "animate-selftest", source: """
            // lerp-data: animate-selftest-probe
            // lerp-param: level float 0 1 = 0.5
            // lerp-param: tint  color     = #808080
            // lerp-animate: level 0.1 0.9 period=40
            // lerp-animate: tint #200000 #00c0ff period=70
            fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
                float2 uv = lerpScreenUV(pos, u.resolution);
                return half4(half3(mix(float3(u.level), u.tint.rgb, step(0.5, uv.x))), 1.0h);
            }
            """, isBuiltIn: false, url: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lerp-animate-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A fresh renderer and library per run, so "cold" really is.
        func still(after times: [Float], seed: Float = 0.31, name: String) -> Data? {
            let (renderer, library) = PreviewMain.makeLibrary(extraSearch)
            let url = dir.appendingPathComponent(name + ".png")
            for time in times {
                let result = LerpSnapshot.render(shader: shader, library: library, renderer: renderer,
                                                 width: 64, height: 32, time: time, seed: seed, to: url)
                if let error = result.error { check(false, "render: \(error)"); return nil }
            }
            return try? Data(contentsOf: url)
        }
        let cold = still(after: [60], name: "cold")
        let warm = still(after: stride(from: 0, to: 60, by: 0.25).map { Float($0) } + [60], name: "warm")
        let back = still(after: [300, 60], name: "back")
        check(cold != nil && cold == warm, "purity: t=60 changed after rendering t=0…59.75 first")
        check(cold != nil && cold == back, "purity: t=60 changed after scrubbing back from t=300")
        check(cold != still(after: [75], name: "later"), "purity: t=75 should differ from t=60 — nothing animated")
        check(cold != still(after: [60], seed: 0.77, name: "seed"), "purity: seed should move the phase")

        // The provider is handed the animated value, at this frame's time.
        Probe.seen = []
        _ = still(after: [60], name: "probe")
        let expected = shader.defaultParameterValues().resolved(time: 60, seed: 0.31)["level"]?.scalarValue
        check(Probe.seen.last != nil && Probe.seen.last == expected && expected != 0.5,
              "provider: bind saw level=\(String(describing: Probe.seen.last)), expected the animated \(String(describing: expected))")
    }
}
