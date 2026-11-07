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
/// - The vitals are a **per-session snapshot**. They are taken when a session
///   starts — a new `u.seed`, the clock put back, or the first frame after the
///   look has not been drawn for `sessionGap` seconds (a new screensaver
///   session, the look coming round again in a rotation, the playground
///   resuming) — and then held. So nothing in the picture can change under the
///   viewer mid-session: no activity switching without its blend, no flower or
///   tree popping in when the ledger is re-read. Within a session the pose is a
///   pure function of `u.time` and `u.seed` in the shader.
/// - The hour is anchored to the session's clock: `CritterState.hour` is the
///   wall-clock hour at `u.time == 0`, so the shader's `hour + time / 3600` is
///   the real time of day for the whole session and the sun moves at real
///   speed, once. (It used to be refreshed from the wall clock every 20 s *and*
///   advanced by `time`, which ran the sun at twice its speed.) The `clock`
///   parameter sets that hour-at-time-0 directly, so the sun still moves from
///   there at real speed; `--param clock=17.6 --time 5` is 17.6 h + 5 s.
/// - Reading the ledger (a stat, a file read, a JSON decode, a walk over every
///   calendar day of the critter's life) never happens on the render thread. A
///   utility queue does it — prefetched when the provider is made, and again
///   at the start of every session. A session starts on whatever the last read
///   produced and takes the fresh one if it lands within `adoptWindow` of the
///   session starting (in practice a few milliseconds, under the crossfade);
///   after that the snapshot is final.
/// - A host with no bundle identifier — `LerpPreview`, which renders the
///   snapshot suite and every gallery still — gets `CritterVitals.fixture`, so
///   stills stay reproducible byte for byte. Only the saver and the playground
///   see the live creature. `LERP_CRITTER_LIVE=1` overrides that for testing
///   (a command-line host then waits for the first read, having no render
///   thread to protect).
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

    /// No frame for this long means the next one starts a new session.
    static let sessionGap: TimeInterval = 20
    /// How long after a session starts a fresh ledger read may still replace
    /// the snapshot it started on. Shorter than the 1.5 s crossfade in.
    static let adoptWindow: TimeInterval = 0.75

    private let live: Bool
    private let loader: Loader?

    /// The snapshot this session is drawn from.
    private struct Session {
        var seed: Float
        var startWall: TimeInterval
        var generation: Int            // loader generation adopted
        var vitals: CritterVitals?     // nil until the first read lands
        var hourAtZero: Float          // wall-clock hour at u.time == 0
    }
    private var session: Session?
    private var lastTime: Float = 0
    private var lastWall: TimeInterval = 0
    private struct PackKey: Equatable { var mood: Int; var clock: Float; var generation: Int; var hour: Float }
    private var packedKey: PackKey?
    private(set) var packed = State(a: .zero, b: .zero, c: .zero, d: .zero, w0: .zero, w1: .zero, w2: .zero)

    public init(device: MTLDevice) {
        let env = ProcessInfo.processInfo.environment["LERP_CRITTER_LIVE"]
        live = env == "1" || (env == nil && Bundle.main.bundleIdentifier != nil)
        loader = live ? Loader() : nil
        loader?.refresh()   // prefetch, so the first session rarely waits
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
        let clock = params?["clock"]?.scalarValue.map(Float.init) ?? -1
        var generation = 0, hour: Float = 0
        // The clock is the session's whatever the mood: a canned mood changes
        // how the critter is, never what time it is (that is `clock`).
        if live {
            let s = sessionVitals(uniforms)
            generation = s.generation; hour = s.hourAtZero
        }
        let key = PackKey(mood: mood, clock: clock, generation: generation, hour: hour)
        if key != packedKey {
            var v: CritterVitals
            if mood > 0 {
                v = Self.demo(mood)
                if live {
                    v.hour = Self.wrapHour(hour + uniforms.time / 3600)
                    if let month = session?.vitals?.month { v.month = month }
                }
            } else if live {
                v = session?.vitals ?? Self.unhatched()
                v.hour = Self.wrapHour(hour + uniforms.time / 3600)   // now, for the weights
            } else {
                v = .fixture
            }
            // Weights see the real hour (or the `clock` the user set); the
            // shader is handed the hour at u.time == 0 (see the type comment).
            if clock >= 0 { v.hour = clock }
            var state = Self.pack(v)
            if clock < 0, live { state.c.y = hour }
            packed = state
            packedKey = key
        }
        var state = packed
        encoder.setFragmentBytes(&state, length: MemoryLayout<State>.stride, index: 1)
    }

    /// The session's snapshot, starting a new session when this frame is the
    /// first of one. Never touches the disk.
    private func sessionVitals(_ u: LerpUniforms) -> Session {
        let wall = Date().timeIntervalSince1970
        let newSession = session == nil
            || session!.seed != u.seed
            || u.time < lastTime - 0.5
            || wall - lastWall > Self.sessionGap
        lastTime = u.time; lastWall = wall
        guard let loader else { return Session(seed: u.seed, startWall: wall, generation: 0,
                                               vitals: nil, hourAtZero: 12) }
        if newSession {
            loader.refresh()
            if loader.latest() == nil, Bundle.main.bundleIdentifier == nil { loader.waitForFirst() }
            session = Session(seed: u.seed, startWall: wall, generation: -1, vitals: nil, hourAtZero: 0)
        }
        // Take a read that landed since the session began (or any read at all,
        // while there is none), then hold it.
        if let got = loader.latest(), got.generation != session!.generation,
           session!.vitals == nil || wall - session!.startWall < Self.adoptWindow {
            session!.vitals = got.vitals
            session!.generation = got.generation
            // The hour now, carried back to u.time == 0.
            let nowHour = Self.clockHour(Date(timeIntervalSince1970: wall))
            session!.hourAtZero = Self.wrapHour(nowHour - u.time / 3600)
        } else if session!.vitals == nil, session!.generation == -1 {
            session!.generation = -2
            session!.hourAtZero = Self.wrapHour(Self.clockHour(Date()) - u.time / 3600)
        }
        return session!
    }

    private static func wrapHour(_ h: Float) -> Float {
        let r = h.truncatingRemainder(dividingBy: 24)
        return r < 0 ? r + 24 : r
    }

    private static func clockHour(_ now: Date) -> Float {
        let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60 + Float(comps.second ?? 0) / 3600
    }

    /// No sampler yet: an egg that has not started to hatch.
    private static func unhatched() -> CritterVitals {
        var v = CritterVitals(); v.unborn = true; v.growth = 0
        v.month = Float(Calendar.current.component(.month, from: Date()))
        return v
    }

    /// Reads and scores the ledger off the render thread. Each finished read
    /// bumps `generation`; a read already under way absorbs further requests.
    private final class Loader: @unchecked Sendable {
        struct Result { var vitals: CritterVitals; var generation: Int }
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.hergenroeder.lerping.critter-ledger", qos: .utility)
        private let first = DispatchSemaphore(value: 0)
        private var result: Result?
        private var inFlight = false
        private var generation = 0
        // Touched only on `queue`.
        private var stamp: Date?
        private var ledger: CritterLedger?

        func latest() -> Result? {
            lock.lock(); defer { lock.unlock() }
            return result
        }

        func waitForFirst() {
            if first.wait(timeout: .now() + 5) == .success { first.signal() }
        }

        func refresh() {
            lock.lock()
            if inFlight { lock.unlock(); return }
            inFlight = true
            lock.unlock()
            queue.async { [self] in
                let now = Date()
                if let url = CritterLedger.url {
                    let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    if stamp != self.stamp || ledger == nil {
                        self.stamp = stamp
                        ledger = CritterLedger.load(from: url)
                    }
                }
                var v: CritterVitals
                if let ledger {
                    v = CritterVitals(ledger: ledger, now: now)
                } else {
                    v = CritterVitals(); v.unborn = true; v.growth = 0
                    v.hour = CritterData.clockHour(now)
                    v.month = Float(Calendar.current.component(.month, from: now))
                }
                lock.lock()
                generation += 1
                let isFirst = result == nil
                result = Result(vitals: v, generation: generation)
                inFlight = false
                lock.unlock()
                if isFirst { first.signal() }
            }
        }
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
            v.calm = 0.45; v.bloom = 0.07; v.todayHours = 11.5; v.makeShare = 0.2
        case 3: // night owl
            v.growth = 6; v.ageDays = 14; v.health = 0.5; v.joy = 0.45; v.energy = 0.1
            v.calm = 0.6; v.bloom = 0.35
        case 4: // scattered
            v.health = 0.55; v.joy = 0.4; v.calm = 0.05; v.energy = 0.6; v.bloom = 0.4
        case 5: // about to hatch
            v.growth = 0.2; v.ageDays = 0.2; v.health = 0.8; v.bloom = 0
        case 6: // a long run, finally a break
            v.relief = 1; v.health = 0.7; v.joy = 0.6; v.energy = 0.55
        default:
            break
        }
        return v
    }
}
