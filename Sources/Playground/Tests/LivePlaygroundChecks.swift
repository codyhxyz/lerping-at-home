import Foundation

// Headless checks: compile with LerpCore/*.swift and Playground's
// ReactionBindings.swift SystemAudio.swift LiveInput.swift PhotoWindowImport.swift.
@main
struct LivePlaygroundChecks {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try reactions(temp)
        audio()
        try photos(temp)
        print("Playground checks passed: reaction edits, safe world input, smoothing and manual hold, bass onsets and decay, photo helper arguments")
    }

    static func reactions(_ temp: URL) throws {
        let source = "// lerp-param: hour float 0 24 = 0\r\n// unrelated\r\n"
        let added = ReactionBinding.setting("clock.hour", for: "hour", in: source)
        precondition(added == "// lerp-param: hour float 0 24 = 0\r\n// lerp-react: hour <- clock.hour\r\n// unrelated\r\n")
        precondition(ReactionBinding.setting(nil, for: "hour", in: added) == source)
        let changed = ReactionBinding.setting("clock.sun", for: "hour", in: added)
        precondition(ReactionBinding.read(changed)["hour"]?.signal == "clock.sun")
        let bindings = ReactionBinding.read("""
        // lerp-react: hour <- clock.hour 0..24 smooth=0.2
        // lerp-react: color <- music.palette0 mix=0.5
        // lerp-react: bad <- audio.bass smooth=nan
        """)
        precondition(bindings.count == 2)

        let worldURL = temp.appendingPathComponent("world.json")
        let payload = """
        {"version":1,"updatedAt":1000,"clock":{"hour":12,"sun":500},"music":{"playing":true,"palette":[[1,0,0,1]]}}
        """
        try Data(payload.utf8).write(to: worldURL)
        let world = ReactionWorld.read(at: worldURL, now: Date(timeIntervalSince1970: 1001))
        precondition(world.values["clock.hour"] == .scalar(12) && world.values["clock.sun"] == nil)
        precondition(world.values["music.playing"] == .scalar(1) && world.values["music.palette0"] == .color(SIMD4(1, 0, 0, 1)))
        precondition(ReactionWorld.read(at: worldURL, now: Date(timeIntervalSince1970: 2000)).values.isEmpty)

        let params = LerpParameterValues([
            LerpParam(name: "hour", type: .float, min: 0, max: 24, defaultValue: .scalar(0), label: "Hour"),
            LerpParam(name: "color", type: .color, min: 0, max: 1, defaultValue: .color(SIMD4(0, 0, 0, 1)), label: "Color"),
        ])
        var overlay = ReactionOverlay(bindings: bindings)
        let sampled = overlay.step(params: params, world: world, audio: nil, beat: 0, now: 1)
        precondition((0..<12).contains(sampled["hour"]?.scalarValue ?? -1))
        precondition((0..<0.5).contains(sampled["color"]?.colorValue?.x ?? -1))
        overlay.takenOver.insert("hour")
        precondition(overlay.step(params: params, world: world, audio: nil, beat: 0, now: 2)["hour"] == nil)
        precondition(overlay.step(params: params, world: .init(), audio: nil, beat: 0, now: 3).isEmpty)
    }

    static func audio() {
        let rate = 48_000.0
        let analyzer = AudioBandAnalyzer(sampleRate: rate)
        var history: [Float] = []
        let samples: [Float] = (0..<Int(rate * 3)).map { index in
            let t = Double(index) / rate
            let envelope: Double = (0.5..<1.5).contains(t) || (2..<2.1).contains(t) ? 1 : 0
            return Float(sin(t * 80 * 2 * .pi) * 0.45 * envelope)
        }
        samples.withUnsafeBufferPointer { buffer in
            analyzer.process(buffer) { _ in history.append(analyzer.latestBeat) }
        }
        func maxBeat(_ a: Double, _ b: Double) -> Float {
            let scale = rate / Double(AudioBandAnalyzer.hop)
            return history[Int(a * scale)..<Int(b * scale)].max() ?? 0
        }
        precondition(maxBeat(0, 0.45) == 0)
        precondition(maxBeat(0.49, 0.65) > 0.6 && maxBeat(1.99, 2.15) > 0.6)
        precondition(maxBeat(1.25, 1.45) < 0.04, "steady bass should settle instead of retriggering")
        precondition(maxBeat(2.8, 2.95) < 0.04, "beat envelope should release back to idle")
        precondition(history.allSatisfy { (0...1).contains($0) })
    }

    static func photos(_ temp: URL) throws {
        let input = temp.appendingPathComponent("Beach $(not-a-command).jpg")
        try Data("fixture".utf8).write(to: input)
        precondition(PhotoWindowImport.accepts(input) && !PhotoWindowImport.accepts(temp.appendingPathComponent("x.gif")))
        let scripts = temp.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        try Data("""
        set -eu
        [ "$(cat "$1")" = fixture ]
        case "$1" in /tmp/lerp-import-*/photo.jpg) ;; *) exit 1 ;; esac
        printf '%s' "$2" > result
        """.utf8).write(to: scripts.appendingPathComponent("photo-window.sh"))
        let sharp = try PhotoWindowImport.generate(photo: input, root: temp, mode: .sharp(tools: temp))
        let slug = try String(contentsOf: temp.appendingPathComponent("result"), encoding: .utf8)
        precondition(sharp == "splat-photo-" + slug && slug.hasPrefix("beach-not-a-command-"))
        try Data("depth-window:\n\t@test \"$$(cat '$(IMAGE)')\" = fixture\n\t@printf '%s' '$(NAME)' > result\n".utf8)
            .write(to: temp.appendingPathComponent("Makefile"))
        let depth = try PhotoWindowImport.generate(photo: input, root: temp, mode: .depth(model: temp))
        let depthSlug = try String(contentsOf: temp.appendingPathComponent("result"), encoding: .utf8)
        precondition(depth == "depth-window-" + depthSlug)
    }
}
