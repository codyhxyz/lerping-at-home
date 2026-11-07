import Foundation
import Metal

/// Data provider for the `critter` look: reads the ledger LerpPulse keeps (see
/// `CritterLedger`) and hands the shader the creature's vitals and how much it
/// feels like doing each of its activities.
///
/// **Purity.** The project's rule is that a frame is a function of (shader,
/// time, seed, parameters). This look adds one input on purpose — the ledger,
/// i.e. how the Mac has been used — and keeps the rule everywhere else:
///
/// - Nothing accumulates across frames. The vitals are re-derived from the
///   ledger file and the wall clock (re-read at most every 20 s); the pose is a
///   pure function of `u.time` and `u.seed` in the shader.
/// - A host with no bundle identifier — `LerpPreview`, which renders the
///   snapshot suite and every gallery still — gets `CritterVitals.fixture`, so
///   stills stay reproducible byte for byte. Only the saver and the playground
///   see the live creature. `LERP_CRITTER_LIVE=1` overrides that for testing.
/// - The `mood` parameter swaps the ledger for a canned state, so the
///   playground can show every mood without anyone living through it.
public final class CritterData: LerpDataProvider {

    /// Must match `CritterState` in `metalPrelude`: seven float4s.
    struct State {
        var a: SIMD4<Float>   // growth, health, energy, joy
        var b: SIMD4<Float>   // calm, relief, awayDays, ageDays
        var c: SIMD4<Float>   // bloom, hour, month, identity
        var d: SIMD4<Float>   // makeShare, chatShare, playShare, unborn
        var w0: SIMD4<Float>  // activity weights 0…3
        var w1: SIMD4<Float>  // 4…7
        var w2: SIMD4<Float>  // 8…11
    }

    private let live: Bool
    private var cached: CritterVitals?
    private var cachedAt: TimeInterval = 0
    private var ledgerStamp: Date?
    private var ledger: CritterLedger?

    public init(device: MTLDevice) {
        let env = ProcessInfo.processInfo.environment["LERP_CRITTER_LIVE"]
        live = env == "1" || (env == nil && Bundle.main.bundleIdentifier != nil)
    }

    public var metalPrelude: String {
        """
        struct CritterState {
            float growth, health, energy, joy;
            float calm, relief, awayDays, ageDays;
            float bloom, hour, month, identity;
            float makeShare, chatShare, playShare, unborn;
            float4 w0, w1, w2;
        };
        """
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        let mood = Int(params?["mood"]?.scalarValue ?? 0)
        var v = mood > 0 ? Self.demo(mood) : currentVitals()
        if let clock = params?["clock"]?.scalarValue, clock >= 0 { v.hour = Float(clock) }
        var state = Self.pack(v)
        encoder.setFragmentBytes(&state, length: MemoryLayout<State>.stride, index: 1)
    }

    private func currentVitals() -> CritterVitals {
        guard live else { return .fixture }
        let now = Date()
        if let cached, now.timeIntervalSince1970 - cachedAt < 20 { return cached }
        cachedAt = now.timeIntervalSince1970
        if let url = CritterLedger.url {
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if stamp != ledgerStamp || ledger == nil {
                ledgerStamp = stamp
                ledger = CritterLedger.load(from: url)
            }
        }
        var v: CritterVitals
        if let ledger {
            v = CritterVitals(ledger: ledger, now: now)
        } else {
            // No sampler yet: an egg that has not started to hatch.
            v = CritterVitals(); v.unborn = true; v.growth = 0
            let comps = Calendar.current.dateComponents([.hour, .minute, .month], from: now)
            v.hour = Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60
            v.month = Float(comps.month ?? 6)
        }
        cached = v
        return v
    }

    /// How much the critter feels like each activity. Indices match the
    /// `ACT_*` constants in critter.metal.
    public static func weights(_ v: CritterVitals) -> [Float] {
        var w = [Float](repeating: 0, count: 12)
        let evening: Float = (v.hour >= 17 && v.hour < 21) ? 1 : 0
        let night: Float = (v.hour < 5.5 || v.hour >= 22.5) ? 1 : 0
        w[0] = 0.8                                             // idle, looking around
        w[1] = 2.2 * v.joy * v.energy * v.joy                  // hopping
        w[2] = 3.5 * (1 - v.energy) * (1 - v.energy) + 4 * night // asleep
        w[3] = 3.0 * pow(1 - v.calm, 1.5)                      // pacing, fretting
        w[4] = 5.0 * v.relief                                  // a long stretch
        w[5] = 1.6 * v.joy * v.energy                          // chasing a butterfly
        w[6] = 0.9 * v.calm + 1.2 * evening                    // sitting, watching the sea
        w[7] = v.awayDays >= 1 ? 4 : 0.4 * v.joy * v.joy       // waving at you
        w[8] = 4.0 * pow(max(0, 0.45 - v.health) / 0.45, 1.2)  // under the weather
        w[9] = 2.0 * min(1, v.makeShare * 1.5) * v.energy      // building a sandcastle
        return w
    }

    static func pack(_ v: CritterVitals) -> State {
        let w = weights(v)
        return State(a: SIMD4(v.growth, v.health, v.energy, v.joy),
                     b: SIMD4(v.calm, v.relief, v.awayDays, v.ageDays),
                     c: SIMD4(v.bloom, v.hour, v.month, v.identity),
                     d: SIMD4(v.makeShare, v.chatShare, v.playShare, v.unborn ? 1 : 0),
                     w0: SIMD4(w[0], w[1], w[2], w[3]),
                     w1: SIMD4(w[4], w[5], w[6], w[7]),
                     w2: SIMD4(w[8], w[9], w[10], w[11]))
    }

    /// Canned moods for the `mood` parameter.
    public static func demo(_ mood: Int) -> CritterVitals {
        var v = CritterVitals.fixture
        switch mood {
        case 1: // thriving
            v.growth = 12; v.ageDays = 34; v.health = 0.96; v.joy = 0.95; v.energy = 0.9
            v.calm = 0.9; v.bloom = 1; v.makeShare = 0.6; v.chatShare = 0.2
        case 2: // burnt out
            v.growth = 5; v.ageDays = 16; v.health = 0.22; v.joy = 0.2; v.energy = 0.15
            v.calm = 0.45; v.bloom = 0.07; v.todayHours = 11.5; v.makeShare = 0.2; v.hour = 19.5
        case 3: // night owl
            v.growth = 6; v.ageDays = 14; v.health = 0.5; v.joy = 0.45; v.energy = 0.1
            v.calm = 0.6; v.bloom = 0.35; v.hour = 2.6
        case 4: // scattered
            v.health = 0.55; v.joy = 0.4; v.calm = 0.05; v.energy = 0.6; v.bloom = 0.4; v.hour = 11
        case 5: // about to hatch
            v.growth = 0.2; v.ageDays = 0.2; v.health = 0.8; v.bloom = 0; v.hour = 8.5
        case 6: // a long run, finally a break
            v.relief = 1; v.health = 0.7; v.joy = 0.6; v.energy = 0.55; v.hour = 16.5
        default:
            break
        }
        return v
    }
}
