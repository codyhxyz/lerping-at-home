import Foundation
import Metal
import simd

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
/// - A `.still` library (`LerpRenderMode`) — every gallery still and the
///   gallery's hover preview, in every host — and a host with no bundle
///   identifier (`LerpPreview`, which renders the snapshot suite) get
///   `CritterVitals.fixture`, so a still is reproducible byte for byte and the
///   preview carries on from it. Only a `.live` view in the saver or the
///   playground sees the live creature. `LERP_CRITTER_LIVE=1` overrides the
///   bundle-identifier test, never `.still` (a command-line host then waits
///   for the first read, having no render thread to protect).
/// - The `mood` parameter swaps the ledger for a canned state, so the
///   playground can show every mood without anyone living through it.
public final class CritterData: LerpDataProvider {

    /// Must match `CritterState` in `metalPrelude`: what the compositor needs
    /// to draw the 2D overlays over the rendered scene. World positions are
    /// in the rolled world (dropped by bend·|xz − focus|², as the scene's
    /// vertices are), so they project onto what the scene drew.
    struct State {
        var cam0: SIMD4<Float>  = .zero   // camera position, focal
        var cam1: SIMD4<Float>  = .zero   // forward, zNear
        var cam2: SIMD4<Float>  = .zero   // right, zFar
        var cam3: SIMD4<Float>  = .zero   // up, unused
        var head: SIMD4<Float>  = .zero   // just above its head, size s
        var feet: SIMD4<Float>  = .zero   // its feet, stage
        var cloud: SIMD4<Float> = .zero   // its cloud, cloud scale
        var body: SIMD4<Float>  = .zero   // where the season's particles keep clear of, radius (world)
        var fx0: SIMD4<Float>   = .zero   // zzz, love, glee, sick
        var fx1: SIMD4<Float>   = .zero   // storm, flash, sweat, bang
        var fx2: SIMD4<Float>   = .zero   // frazzle, dtake, butterfly, trail points
        var sky: SIMD4<Float>   = .zero   // night, golden, season, time
        var light: SIMD4<Float> = .zero   // sun direction, health
        var fly: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                  SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
            = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
        var trail: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
            = (.zero, .zero, .zero, .zero, .zero, .zero)
    }
    static let fireflies = 14
    static let trailPoints = 6

    /// No frame for this long means the next one starts a new session.
    static let sessionGap: TimeInterval = 20
    /// How long after a session starts a fresh ledger read may still replace
    /// the snapshot it started on. Shorter than the 1.5 s crossfade in.
    static let adoptWindow: TimeInterval = 0.75
    /// Most pixels the scene is rendered at, whatever the drawable; past it
    /// the compositor upsamples (4× MSAA keeps edges clean). 2560×1600.
    static let maxScenePixels = 2560 * 1600

    private let live: Bool
    private let loader: Loader?
    private let device: MTLDevice

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
    private struct VitalsKey: Equatable { var mood: Int; var clock: Float; var generation: Int; var hour: Float }
    private var vitalsKey: VitalsKey?
    private var vitals = CritterVitals.fixture

    // The 3D scene and what it rendered this frame. Built (and its
    // pipelines compiled) off the render thread when the provider is made;
    // the first frame waits for it.
    private var built: CritterScene?
    private let building = DispatchGroup()
    private var builtScene: CritterScene?
    private var state = State()
    private struct Targets {
        let width: Int, height: Int
        let msColor: MTLTexture, msDepth: MTLTexture
        let color: MTLTexture          // resolved; CritterLook writes display-encoded colour
        let depth: MTLTexture          // resolved
    }
    private var targets: Targets?
    private lazy var blank: (color: MTLTexture?, depth: MTLTexture?) = {
        let c = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        c.usage = .shaderRead; c.storageMode = .shared
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        let ct = device.makeTexture(descriptor: c), dt = device.makeTexture(descriptor: d)
        var px: [UInt8] = [0, 0, 0, 0]; var one: Float = 1
        ct?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        dt?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &one, bytesPerRow: 4)
        return (ct, dt)
    }()

    public init(device: MTLDevice, mode: LerpRenderMode = .live) {
        self.device = device
        let env = ProcessInfo.processInfo.environment["LERP_CRITTER_LIVE"]
        live = mode == .live && (env == "1" || (env == nil && Bundle.main.bundleIdentifier != nil))
        loader = live ? Loader() : nil
        loader?.refresh()   // prefetch, so the first session rarely waits
        // The models are read, the graph built and its pipelines compiled
        // off the render thread; the first frame waits for whatever is left.
        DispatchQueue.global(qos: .userInitiated).async(group: building) { [self] in
            let scene = CritterScene(device: device)
            scene.apply(CritterBehavior.frame(vitals: .fixture, time: 0, seed: 0, params: nil), aspect: 1.6)
            scene.precompile()
            builtScene = scene
        }
    }

    public var metalPrelude: String {
        """
        struct CritterState {
            float4 cam0, cam1, cam2, cam3;
            float4 head, feet, cloud, body;
            float4 fx0, fx1, fx2, sky, light;
            float4 fly[\(Self.fireflies)];
            float4 trail[\(Self.trailPoints)];
        };
        """
    }

    // MARK: - Per frame

    public func encodeCompute(into commandBuffer: MTLCommandBuffer,
                              uniforms: LerpUniforms,
                              params: LerpParameterValues?) {
        let v = resolvedVitals(uniforms, params: params)
        let frame = CritterBehavior.frame(vitals: v, time: uniforms.time, seed: uniforms.seed, params: params)
        let res = uniforms.resolution
        let fit = min(1, (Float(Self.maxScenePixels) / max(res.x * res.y, 1)).squareRoot())
        let width = max(1, Int((res.x * fit).rounded())), height = max(1, Int((res.y * fit).rounded()))
        if built == nil {
            building.wait()
            built = builtScene
        }
        guard let scene = built, let t = targets(width: width, height: height) else { return }
        scene.apply(frame, aspect: res.x / max(res.y, 1))

        guard let pass = CritterScene.pass(color: t.msColor, depth: t.msDepth,
                                           resolveColor: t.color, resolveDepth: t.depth) else { return }
        scene.renderer.render(atTime: TimeInterval(frame.time),
                              viewport: CGRect(x: 0, y: 0, width: width, height: height),
                              commandBuffer: commandBuffer, passDescriptor: pass)
        state = Self.pack(frame)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        encoder.setFragmentTexture(targets?.color ?? blank.color, index: 1)
        encoder.setFragmentTexture(targets?.depth ?? blank.depth, index: 2)
        var s = state
        encoder.setFragmentBytes(&s, length: MemoryLayout<State>.stride, index: 1)
    }

    /// The colour and depth the scene renders into, sized to the drawable
    /// (under `maxScenePixels`). Not sRGB: CritterLook's shaders write
    /// display-encoded colour themselves. The multisampled attachments are
    /// memoryless: they live in tile memory for the pass and cost no RAM.
    private func targets(width: Int, height: Int) -> Targets? {
        if let t = targets, t.width == width, t.height == height { return t }
        let memoryless = device.supportsFamily(.apple1)
        func make(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = samples > 1 && memoryless ? .memoryless : .private
            return device.makeTexture(descriptor: d)
        }
        let n = CritterScene.samples
        guard let msColor = make(CritterScene.colorFormat, samples: n, usage: .renderTarget),
              let msDepth = make(.depth32Float, samples: n, usage: .renderTarget),
              let color = make(CritterScene.colorFormat, samples: 1, usage: [.renderTarget, .shaderRead]),
              let depth = make(.depth32Float, samples: 1, usage: [.renderTarget, .shaderRead]) else { return nil }
        msColor.label = "critter scene MSAA"; color.label = "critter scene"; depth.label = "critter depth"
        targets = Targets(width: width, height: height, msColor: msColor, msDepth: msDepth,
                          color: color, depth: depth)
        return targets
    }

    /// The compositor's view of a frame: the camera exactly as the scene's,
    /// and the anchors the overlays hang off, dropped into the rolled world.
    static func pack(_ f: CritterFrame) -> State {
        let fw = simd_normalize(f.camTarget - f.camPos)
        let rt = simd_normalize(simd_cross(fw, f.camUp))
        let up = simd_cross(rt, fw)
        let drop = f.rolled
        let s = f.size
        let egg = f.stage == 0
        var st = State()
        st.cam0 = SIMD4(f.camPos, f.camFocal)
        st.cam1 = SIMD4(fw, CritterScene.zNear)
        st.cam2 = SIMD4(rt, CritterScene.zFar)
        st.cam3 = SIMD4(up, 0)
        st.head = SIMD4(drop(f.position + SIMD3(0, 2.1 * s, 0)), s)
        st.feet = SIMD4(drop(f.position), Float(f.stage))
        st.cloud = SIMD4(drop(f.cloudPos), f.cloud)
        st.body = SIMD4(drop(f.position + SIMD3(0, egg ? 0.42 : s * f.squash, 0)), egg ? 0.5 : 1.25 * s)
        st.fx0 = SIMD4(f.zzz, f.love, f.glee, f.sick)
        st.fx1 = SIMD4(f.storm, f.flash, f.sweat, f.bang)
        // The butterfly's dotted trail, newest first.
        let trail = f.butterflyTrail.prefix(trailPoints).map { SIMD4(drop($0), 1) }
        st.fx2 = SIMD4(f.frazzle, f.dtake, f.butterfly, Float(trail.count))
        withUnsafeMutableBytes(of: &st.trail) { raw in
            trail.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        st.sky = SIMD4(f.night, f.golden, Float(f.season), f.time)
        st.light = SIMD4(simd_normalize(f.sunDir), f.health)
        // Fireflies over the meadow on a good night (the old fxFireflies).
        var fly = [SIMD4<Float>](repeating: .zero, count: fireflies)
        if f.night > 0.2 && f.health > 0.4 {
            let count = Int(4 + 10 * f.health)
            for i in 0..<min(count, fireflies) {
                let fi = Float(i)
                let a = fi * 2.4 + tphase(f.time, 0.05 + 0.04 * CritterHash.h11(fi)) + f.identity * 3
                let r = 1.8 + 3.5 * CritterHash.h11(fi * 3.3)
                let xz = SIMD2(cos(a), sin(a)) * r
                let y = CritterBehavior.groundHeight(xz, identity: f.identity) + 0.35
                    + 0.25 * sin(tphase(f.time, 0.7) + fi)
                let pulse = 0.5 + 0.5 * sin(tphase(f.time, 2) + fi * 1.7)
                fly[i] = SIMD4(drop(SIMD3(xz.x, y, xz.y)), pulse)
            }
        }
        withUnsafeMutableBytes(of: &st.fly) { raw in
            fly.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return st
    }

    // MARK: - Vitals

    /// The vitals this frame is drawn from: the session's snapshot (or the
    /// fixture, or a canned `mood`), with `hour` the hour at `u.time == 0`
    /// (the `clock` parameter when set) — `CritterBehavior` adds `time / 3600`
    /// to it, so the sun moves at real speed from there, once.
    private func resolvedVitals(_ uniforms: LerpUniforms, params: LerpParameterValues?) -> CritterVitals {
        let mood = Int(params?["mood"]?.scalarValue ?? 0)
        let clock = params?["clock"]?.scalarValue.map(Float.init) ?? -1
        var generation = 0, hour: Float = 0
        // The clock is the session's whatever the mood: a canned mood changes
        // how the critter is, never what time it is (that is `clock`).
        if live {
            let s = sessionVitals(uniforms)
            generation = s.generation; hour = s.hourAtZero
        }
        let key = VitalsKey(mood: mood, clock: clock, generation: generation, hour: hour)
        if key != vitalsKey {
            var v: CritterVitals
            if mood > 0 {
                v = Self.demo(mood)
                if live {
                    v.hour = hour
                    if let month = session?.vitals?.month { v.month = month }
                }
            } else if live {
                v = session?.vitals ?? Self.unhatched()
                v.hour = hour
            } else {
                v = .fixture
            }
            if clock >= 0 { v.hour = clock }
            vitals = v
            vitalsKey = key
        }
        return vitals
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
