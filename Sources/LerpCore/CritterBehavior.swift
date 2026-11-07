import Foundation
import simd

/// What the critter is doing, as a pure function of (vitals, time, seed,
/// params): the old raymarched shader's behaviour (critter.metal at 6b776ec —
/// setupCritter, tellStory, makePose, blendPose, addBeat, doubleTake,
/// poseCritter, placeProps, setupCamera, placeIsland, lightFromClock and the
/// overlay amounts) ported line for line to Float32 Swift. Same constants,
/// same hashes (Prelude's hash11/hash21/hash22), same order of operations, so
/// the story it tells — which activity, when, from which side the camera
/// comes in — is the one the shader told.
///
/// Spaces. "World" here is the shader's bent space `q` (where every object
/// was modelled): the island centred on the origin, ground at `groundHeight`.
/// The rolled world (`bend`, `focus`) is applied afterwards, by CritterLook's
/// geometry modifier; the camera lives in the rolled (view) space, exactly as
/// the shader's ray did. `CritterFrame.rolled(_:)` maps a world point there.
///
/// Nothing here keeps state between calls.
public enum CritterBehavior {

    // ------------------------------------------------------------ constants

    static let islandR: Float = 7.0
    static let seaY: Float = -0.2
    static let chapterLength: Float = 36.0

    public static let actIdle = 0, actHop = 1, actSleep = 2, actPace = 3, actStretch = 4
    public static let actChase = 5, actSit = 6, actWave = 7, actSick = 8, actBuild = 9

    // ------------------------------------------------------------ the island

    /// Ground height of the island at (x, z) — the old shader's groundH.
    public static func groundHeight(_ xz: SIMD2<Float>, identity: Float) -> Float {
        let ident = identity
        let d = simd_length(xz)
        var hills = 0.11 * sin(xz.x * 0.55 + ident * 7.0) * sin(xz.y * 0.5 + ident * 3.0)
                  + 0.035 * sin(xz.x * 1.7 + ident * 11.0 + sin(xz.y * 1.3)) * sin(xz.y * 1.9 - ident * 5.0)
        hills *= smoothstep(1.4, 3.6, d)
        let shore = smoothstep(islandR - 1.7, islandR + 0.9, d)
        return 0.04 + hills * (1.0 - shore) - 0.8 * shore
    }

    // ------------------------------------------------------------ the frame

    public static func frame(vitals S: CritterVitals, time: Float, seed: Float,
                             params: LerpParameterValues?) -> CritterFrame {
        let drift = Float(params?["drift"]?.scalarValue ?? 0.35)
        let actParam = Int32((params?["act"]?.scalarValue ?? -1).rounded())
        let turnYaw = Float(params?["yaw"]?.scalarValue ?? 0)
        let turnPitch = Float(params?["pitch"]?.scalarValue ?? 0)
        let magnify = Float(params?["magnify"]?.scalarValue ?? 0)
        let w = CritterData.weights(S)

        var f = CritterFrame()
        f.time = time

        // ---- setupCritter: who it is today
        let g = S.growth
        let stage = g < 0.25 ? 0 : (g < 3.0 ? 1 : (g < 10.0 ? 2 : 3))
        let s = mix(0.3, 0.5, smoothstep(0.25, 12.0, g))
        let unborn: Float = S.unborn ? 1 : 0
        let hatch = smoothstep(0.06, 0.25, g) * (1.0 - unborn)
        let wobble = (0.03 * sin(time * 1.3) + (0.06 + 0.12 * hatch) * sin(time * 11.0)
                      * step(0.8 - 0.25 * hatch, fract(time * 0.13 + seed))) * (1.0 - 0.7 * unborn)
        let m = Int(S.month)
        let season = (m >= 3 && m <= 5) ? 0 : ((m >= 6 && m <= 8) ? 1 : ((m >= 9 && m <= 11) ? 2 : 3))
        let droop = clamp((0.6 - S.health) / 0.45, 0.0, 1.0)
        let ident = S.identity
        f.stage = stage; f.size = s; f.season = season; f.identity = ident
        f.health = S.health; f.bloom = S.bloom; f.ageDays = S.ageDays
        f.hatch = hatch; f.wobble = wobble; f.droop = droop
        f.bend = 0.011

        // ---- tellStory: what it is doing
        let az = twoPi * fract(seed * 7.31 + ident) + time * 0.02 * drift
        let right = SIMD2<Float>(cos(az), -sin(az))
        let tl = time + seed * 997.0
        let chapter = floor(time / chapterLength)
        let inCh = time - chapter * chapterLength
        let castle2 = right * 0.5 + SIMD2<Float>(sin(az), cos(az)) * 0.35
        let act = stage == 0 ? actIdle : (actParam >= 0 ? Int(actParam) : pickActivity(chapter, seed, w))
        // DEVIATION (bug): the shader picked an egg's previous activity like
        // anyone's, so each chapter opened with a castle sinking, a butterfly
        // or a cloud fading round the egg. An egg was idle then too.
        let prevAct = (chapter < 0.5 || actParam >= 0 || stage == 0) ? act : pickActivity(chapter - 1.0, seed, w)
        let rr = hash11(chapter * 3.7 + seed * 17.0)
        let rp = hash11((chapter - 1.0) * 3.7 + seed * 17.0)
        let k = chapter < 0.5 ? 1.0 : smoothstep(0.0, 2.5, inCh)
        let dtake: Float = (stage > 0 && act != actSleep && chapter < 0.5) ? 1.0 - smoothstep(3.4, 4.3, time) : 0.0
        let sick = (act == actSick ? k : 0.0) + (prevAct == actSick ? 1.0 - k : 0.0)
        let storm = (act == actPace ? k : 0.0) + (prevAct == actPace ? 1.0 - k : 0.0)
        f.act = act; f.prevAct = prevAct; f.k = k

        // ---- poseCritter
        var P = makePose(act, tl, rr, s, az, right, castle2, S)
        if k < 1.0 {
            // DEVIATION (continuity): the turn between the two poses is
            // unwrapped from where it stood when the blend began, so a facing
            // that swings through the half-turn mid-blend (a chase, a pace)
            // no longer snaps by 2π·k. Identical to the shader otherwise.
            let tl0 = chapter * chapterLength + seed * 997.0
            let ref = makePose(act, tl0, rr, s, az, right, castle2, S).yaw
                    - makePose(prevAct, tl0, rp, s, az, right, castle2, S).yaw
            P = blendPose(makePose(prevAct, tl, rp, s, az, right, castle2, S), P, k, turnFrom: ref)
        }
        // DEVIATION (continuity): the shader faded a beat in with k² but never
        // out, so a beat under way when a chapter ended vanished in a frame
        // (a mouth snapping from a smile to a frown). The last chapter's beat
        // now fades out with (1 − k)² as this one's fades in.
        if k < 1.0 && beats(prevAct) { addBeat(&P, tl, seed, prevAct, (1.0 - k) * (1.0 - k)) }
        if beats(act) { addBeat(&P, tl, seed, act, k * k) }
        if dtake > 0.0 {
            // Unwrapped from 3.4 s, where the blend out of the double-take starts.
            var ref: Float? = nil
            if dtake < 1.0 {
                let t0: Float = 3.4
                ref = doubleTake(P, t0, az, s).yaw - makePose(act, t0 + seed * 997.0, rr, s, az, right, castle2, S).yaw
            }
            P = blendPose(P, doubleTake(P, time, az, s), dtake, turnFrom: ref)
        }
        if stage == 0 { P.pos = .zero; P.yaw = az }
        let cxz = SIMD2<Float>(P.pos.x, P.pos.z)
        var cpos = SIMD3<Float>(cxz.x, groundHeight(cxz, identity: ident) + P.pos.y, cxz.y)
        let sag = clamp((0.65 - S.health) / 0.45, 0.0, 1.0)
        let sq = P.sq * (1.0 - 0.1 * sag)
        f.yaw = P.yaw; f.squash = sq; f.lean = P.lean; f.roll = P.roll
        f.armL = P.armL; f.armR = P.armR; f.eye = P.eye; f.step = P.step; f.mouth = P.mouth
        f.lid = clamp(P.lid, 0.0, 0.85); f.lidTilt = P.lidTilt; f.happy = clamp(P.happy, -1.0, 1.0)
        f.mouthO = clamp(P.mouthO, 0.0, 1.0); f.stride = P.stride; f.reach = P.reach; f.sit = P.sit
        f.bags = clamp(0.9 * max(1.0 - 1.6 * S.energy, 0.0) + 0.6 * sag, 0.0, 1.0)
        let hz = 1.0 / sqrt(sq)
        let bc = SIMD3<Float>(0.0, 0.95 * s * sq, 0.0)
        // It turns about its feet, so a pose that tips it over (lying face
        // down) would push its body into the ground: lift it until the lowest
        // point of the body rests on the grass.
        f.position = cpos
        if stage > 0 {
            let upL = f.critterLocal(cpos + SIMD3<Float>(0, 1, 0)) - f.critterLocal(cpos)
            let reach = simd_length(upL * SIMD3<Float>(1.0 * hz, 0.95 * sq, 0.92 * hz) * s)
            let lowest = f.critterWorld(bc).y - reach
            cpos.y += max(0.0, groundHeight(SIMD2(cpos.x, cpos.z), identity: ident) - lowest)
            f.position = cpos
        }
        // Arm directions, as the shader built its mittens.
        let rc = f.reach
        let aL = SIMD2<Float>(sin(f.armL), cos(f.armL)), aR = SIMD2<Float>(sin(f.armR), cos(f.armR))
        f.armDirL = simd_normalize(SIMD3<Float>(-aL.x * (1.0 - rc) - 0.15 * rc, -aL.y, mix(0.3, aL.x, rc)))
        f.armDirR = simd_normalize(SIMD3<Float>(aR.x * (1.0 - rc) + 0.15 * rc, -aR.y, mix(0.3, aR.x, rc)))

        // ---- placeProps: its cloud and its sandcastle
        f.cloud = max(sick, storm) * mix(0.8, 1.0, s)
        f.cloudDark = storm
        f.cloudPos = SIMD3<Float>(cpos.x, cpos.y + 2.1 * s + 0.53 + 0.04 * sin(time * 1.3), cpos.z)
        f.castle = (act == actBuild ? k * mix(0.3, 1.0, smoothstep(1.0, chapterLength * 0.8, inCh)) : 0.0)
                 + (prevAct == actBuild ? 1.0 - k : 0.0)
        f.castlePos = SIMD3<Float>(castle2.x, groundHeight(castle2, identity: ident), castle2.y)

        // ---- setupCamera: close, swung toward its face, then drag to turn
        let fsz = stage == 0 ? 0.42 : s
        let zoom = mix(1.0, fsz / 0.5, 0.75)
        let target = SIMD3<Float>(cpos.x * 0.65, 0.15 + 1.1 * fsz + 0.35 * f.cloud, cpos.z * 0.65)
        f.focus = SIMD2(target.x, target.z)
        let dist = 3.6 * zoom, height = 1.85 * zoom
        let faceW = mix(camFaceWeight(prevAct), camFaceWeight(act), k)
        let caz = az + faceW * sin(f.yaw - az)
        var ro = target + SIMD3<Float>(sin(caz) * dist, height, cos(caz) * dist)
        var fw = simd_normalize(target - ro)
        var rt = simd_normalize(simd_cross(fw, SIMD3<Float>(0, 1, 0)))
        LerpTurn.orbit(yaw: turnYaw, pitch: turnPitch, magnify: magnify, pivot: target,
                       up: SIMD3<Float>(0, 1, 0), eye: &ro, right: &rt, fwd: &fw)
        f.camPos = ro
        f.camTarget = target
        f.camUp = simd_cross(rt, fw)
        f.camFocal = 2.7

        // ---- placeIsland: trees by age (sunk out of the camera's way), rocks
        let treeCount = Int(clamp(2.0 + floor(S.ageDays / 3.0), 2.0, 8.0))
        let camDir = simd_normalize(SIMD2(ro.x, ro.z) - f.focus)
        f.treeCount = treeCount
        f.trees = []; f.treeBase = []
        for i in 0..<treeCount {
            let fi = Float(i)
            let a = fi * 2.39996 + ident * 6.283
            let r = 3.1 + hash11(fi * 7.13 + ident * 91.0) * 2.6
            let xz = SIMD2<Float>(cos(a), sin(a)) * r
            let born = max(0.0, fi - 1.0) * 3.0
            let size = 0.7 + 0.35 * clamp((S.ageDays - born) / 12.0, 0.0, 1.0)
            let sink = max(smoothstep(0.66, 0.8, simd_dot(simd_normalize(xz - f.focus), camDir)),
                           smoothstep(2.4, 1.3, simd_length(xz - SIMD2(ro.x, ro.z))))
            f.trees.append(SIMD4(xz.x, xz.y, sink > 0.995 ? 0.0 : size, sink))
            f.treeBase.append(groundHeight(xz, identity: ident) - sink * 2.1 * size)
        }
        f.rocks = []; f.rockBase = []
        for i in 0..<3 {
            let fi = Float(i)
            let a = fi * 2.1 + ident * 4.0 + 0.7
            let xz = SIMD2<Float>(cos(a), sin(a)) * (islandR - 0.4 + 0.3 * fi)
            f.rocks.append(SIMD3(xz.x, xz.y, 0.28 + 0.1 * fi))
            f.rockBase.append(groundHeight(xz, identity: ident) + 0.05)
        }

        // ---- lightFromClock (S.hour is the hour at time 0 of the session)
        let hour = S.hour + time / 3600.0
        let ha = (hour - 6.0) / 12.0 * Float.pi
        let sunUp = sin(ha)
        f.sunDir = simd_normalize(SIMD3<Float>(cos(ha) * 0.85, max(sunUp, -0.3) * 0.95 + 0.05, -0.45))
        f.moonDir = simd_normalize(SIMD3<Float>(-0.4, 0.75, -0.5))
        f.night = 1.0 - smoothstep(-0.12, 0.1, sunUp)
        f.golden = (1.0 - smoothstep(0.08, 0.42, sunUp)) * (1.0 - f.night)
        f.lightDir = simd_normalize(mix3(f.sunDir, f.moonDir, f.night))
        f.sunColor = mix3(mix3(SIMD3(1.12, 1.04, 0.92), SIMD3(1.25, 0.8, 0.52), f.golden),
                          SIMD3<Float>(0.45, 0.56, 0.95) * 0.75, f.night)
        f.skyAmbient = mix3(mix3(SIMD3(0.55, 0.7, 0.95), SIMD3(0.75, 0.6, 0.65), f.golden),
                            SIMD3(0.2, 0.27, 0.52), f.night)
        let wrapped = hour.truncatingRemainder(dividingBy: 24)
        f.hour = wrapped < 0 ? wrapped + 24 : wrapped

        // ---- overlay amounts (as fxZzz, fxHearts, … computed them)
        f.zzz = (act == actSleep ? k : 0.0) + (prevAct == actSleep ? 1.0 - k : 0.0)
        var love = ((act == actWave || act == actStretch) ? k : 0.0)
                 + ((prevAct == actWave || prevAct == actStretch) ? 1.0 - k : 0.0)
        love = max(love, dtake * smoothstep(1.6, 2.2, time))
        f.love = love
        f.glee = (((act == actHop || act == actChase) ? k : 0.0)
                + ((prevAct == actHop || prevAct == actChase) ? 1.0 - k : 0.0)) * smoothstep(0.55, 0.8, S.joy)
        f.sick = sick
        f.storm = storm
        f.flash = storm * step(0.9, fract(time * 0.37)) * step(0.4, fract(time * 9.0))
        let zzzOff = 1.0 - min(f.zzz, 1.0)
        let grown: Float = stage >= 1 ? 1 : 0
        f.frazzle = storm * zzzOff * (1.0 - dtake) * grown
        f.sweat = max(storm, sick) * zzzOff * (1.0 - dtake) * grown
        f.bang = dtake * smoothstep(0.5, 0.6, time) * (1.0 - smoothstep(1.9, 2.3, time))
        f.dtake = dtake

        // ---- the butterfly (fxButterfly): ahead of it on the chase circle,
        // just above head height; its phase runs on `tl`.
        f.butterfly = (act == actChase ? k : 0.0) + (prevAct == actChase ? 1.0 - k : 0.0)
        let a0 = tl * 0.55
        let fxz = SIMD2<Float>(cos(a0) * 1.45, sin(a0) * 1.45)
        let flyY = groundHeight(fxz, identity: ident) + 0.55 + 1.3 * s
        f.butterflyPos = SIMD3(fxz.x, flyY + 0.15 * sin(time * 3.1), fxz.y)
        f.butterflyYaw = atan2(-sin(a0), cos(a0))
        // The shader squeezed its 2D wings to 0.25…1 of their width; a wing
        // tipped up by acos(that) shows the same width from above.
        f.flap = acos(0.25 + 0.75 * abs(sin(time * 13.0)))
        f.butterflyTrail = []
        for j in 2...6 {
            let fj = Float(j)
            let tj = time - fj * 0.14
            let a = (tl - fj * 0.14) * 0.55
            f.butterflyTrail.append(SIMD3(cos(a) * 1.45, flyY + 0.15 * sin(tj * 3.1), sin(a) * 1.45))
        }
        return f
    }

    // ------------------------------------------------------------ behaviour

    struct Pose {
        var pos = SIMD3<Float>(0, 0, 0)
        var yaw: Float = 0, sq: Float = 1, lean: Float = 0, roll: Float = 0
        var armL: Float = 0, armR: Float = 0, eye: Float = 1, step: Float = 0, mouth: Float = 0
        var lid: Float = 0, lidTilt: Float = 0, happy: Float = 0, mouthO: Float = 0
        var stride: Float = 0, reach: Float = 0, sit: Float = 0
    }

    /// How far the camera turns toward the way the critter faces, by activity.
    static func camFaceWeight(_ act: Int) -> Float {
        switch act {
        case actIdle, actHop: return 0.35
        case actPace, actChase, actSit, actBuild: return 0.0
        default: return 0.8
        }
    }

    /// The first chapter is drawn by squared weight; later ones by weight.
    static func pickActivity(_ chapter: Float, _ seed: Float, _ weights: [Float]) -> Int {
        var w = (0..<10).map { $0 < weights.count ? weights[$0] : 0 }
        let sq = chapter < 0.5
        var total: Float = 0
        for i in 0..<10 { w[i] = max(w[i], 0); if sq { w[i] *= w[i] }; total += w[i] }
        var r = hash11(chapter * 12.9898 + seed * 78.233) * total
        for i in 0..<10 {
            r -= w[i]
            if r <= 0 { return i }
        }
        return 0
    }

    // `castle` is where the sandcastle stands (BUILD faces it and pats it).
    static func makePose(_ act: Int, _ t: Float, _ r: Float, _ s: Float, _ az: Float,
                         _ right: SIMD2<Float>, _ castle: SIMD2<Float>, _ S: CritterVitals) -> Pose {
        var P = Pose()
        let joy = S.joy
        let breath = sin(t * 1.8 + r * 6.0)
        P.pos = .zero
        P.yaw = az + 0.25 * sin(r * 12.0)
        P.sq = 1.0 + 0.025 * breath
        P.lean = 0; P.roll = 0
        P.armL = 0.5 + 0.05 * breath; P.armR = P.armL
        let bl = fract(t * 0.29 + r * 3.0)
        P.eye = 1.0 - (smoothstep(0.0, 0.02, bl) - smoothstep(0.02, 0.045, bl))
        P.step = t * 14.0; P.stride = 0
        P.mouth = mix(-0.8, 1.0, joy)
        let tired = clamp((0.55 - S.energy) / 0.45, 0.0, 1.0)
        P.lid = 0.45 * tired
        P.lidTilt = 0.7 * clamp((0.6 - joy) / 0.5, 0.0, 1.0)
        P.happy = 0; P.mouthO = 0; P.reach = 0; P.sit = 0
        switch act {
        case actIdle:
            P.yaw = az + 0.55 * sin(t * 0.37 + r * 6.0)
            P.roll = 0.07 * sin(t * 0.61 + r)
        case actHop:
            let ph = fract(t * 0.85)
            let air: Float = ph < 0.6 ? sin(ph / 0.6 * Float.pi) : 0.0
            let land: Float = ph >= 0.6 ? exp(-(ph - 0.6) * 18.0) : 0.0
            P.pos.y = 0.4 * s * air
            P.sq = 1.0 - 0.24 * land + 0.1 * air
            P.armL = 0.6 + 2.1 * air; P.armR = P.armL
            P.yaw = az + 0.45 * sin(t * 0.4 + r * 5.0)
            P.mouth = 1.0
            P.mouthO = 0.75 * air
            P.happy = air * smoothstep(0.55, 0.85, joy)
            P.lid = 0
        case actSleep:
            let worn = clamp((0.55 - S.health) / 0.3, 0.0, 1.0)
            P.sq = mix(0.82, 0.74, worn) + 0.035 * sin(t * 1.1)
            P.eye = 0; P.lid = 0; P.lidTilt = 0
            P.happy = -0.9
            P.roll = mix(0.4, 0.08, worn)
            P.lean = mix(-0.18, 0.6, worn)
            P.armL = mix(0.95, 1.45, worn); P.armR = P.armL
            P.reach = 0.7 * (1.0 - worn)
            P.yaw = az + mix(0.2, 0.35, worn)
            P.pos.y = -0.06 * s * worn
            P.mouth = mix(0.5, -0.3, worn)
        case actPace:
            let x = 1.15 * sin(t * 0.8 + r * 6.0)
            let vx = cos(t * 0.8 + r * 6.0)
            P.pos = SIMD3(right.x * x, abs(sin(t * 7.0)) * 0.05 * s, right.y * x)
            P.yaw = az + 1.5708 * clamp(vx * 3.0, -1.0, 1.0)
            P.stride = 1.0
            P.lean = 0.16
            P.armL = 0.45 + 0.25 * sin(t * 7.0); P.armR = 0.45 - 0.25 * sin(t * 7.0)
            P.lid = max(P.lid, 0.15); P.lidTilt = 0.75
            P.mouth = -0.7
        case actStretch:
            let c = fract(t / 7.0) * 7.0
            let k = smoothstep(0.3, 1.8, c) - smoothstep(4.6, 6.2, c)
            P.armL = mix(0.5, 2.9, k); P.armR = P.armL
            P.sq = 1.0 + 0.2 * k
            P.happy = k
            P.lid = P.lid * (1.0 - k)
            P.lean = 0
            P.roll = 0.03 * sin(t * 9.0) * k
            P.mouth = 1.0
            P.mouthO = 0.7 * k
        case actChase:
            let a = t * 0.55 - 0.55
            P.pos = SIMD3(cos(a) * 1.25, abs(sin(t * 7.0)) * 0.09 * s, sin(a) * 1.25)
            P.yaw = atan2(-sin(a), cos(a))
            P.stride = 1.0
            P.armL = 1.5 + 0.35 * sin(t * 7.0); P.armR = 1.5 - 0.35 * sin(t * 7.0)
            P.mouth = 1.0; P.mouthO = 0.45; P.lid = 0
        case actSit:
            let side: Float = r < 0.5 ? -1.0 : 1.0
            P.yaw = az + side * (0.85 + 0.25 * sin(t * 0.23 + r * 5.0))
            P.sq = 0.9 + 0.02 * breath
            P.lean = -0.25
            P.sit = 1.0
            P.roll = 0.05 * sin(t * 0.7)
            P.armL = 0.8; P.armR = 0.8; P.reach = 0.6
            P.lid = max(P.lid, 0.3)
            P.mouth = max(P.mouth, 0.4)
        case actWave:
            P.yaw = az
            P.armR = 2.7 + 0.35 * sin(t * 9.0)
            P.armL = 0.55
            P.pos.y = 0.03 * s * abs(sin(t * 4.5))
            P.mouth = 1.0; P.mouthO = 0.3
            P.happy = 0.85; P.lid = 0
        case actSick:
            P.sq = 0.86
            P.lean = 0.28
            P.eye = min(P.eye, 0.8)
            P.lid = max(P.lid, 0.45); P.lidTilt = 0.85
            P.armL = 0.3; P.armR = 0.3
            P.roll = 0.05 * sin(t * 38.0) * step(0.75, fract(t * 0.17))
            P.yaw = az + 0.25
            P.mouth = -0.9
        case actBuild:
            let u = simd_normalize(right * 0.8 + SIMD2<Float>(sin(az), cos(az)) * 0.55)
            let at = castle - u * (0.38 + 0.95 * s)
            P.pos = SIMD3(at.x, 0.0, at.y)
            P.yaw = atan2(u.x, u.y)
            let pat = abs(sin(t * 5.0))
            P.reach = 1.0
            P.armL = 0.95 + 0.45 * pat; P.armR = P.armL
            P.lean = 0.2 + 0.08 * pat
            P.sq = 0.96 - 0.04 * pat
            P.lid = max(P.lid, 0.25)
            P.mouth = 1.0
        default:
            break
        }
        return P
    }

    static func beats(_ act: Int) -> Bool {
        act == actIdle || act == actSit || act == actBuild || act == actPace || act == actSick
    }

    /// The shader's blendPose. `turnFrom` (the turn b.yaw − a.yaw when the
    /// blend began) picks the way round continuously; nil is the shader's own
    /// shortest way, which flips when the turn passes a half-turn.
    static func blendPose(_ a: Pose, _ b: Pose, _ k: Float, turnFrom: Float? = nil) -> Pose {
        var P = Pose()
        P.pos = a.pos + (b.pos - a.pos) * k
        var dy = b.yaw - a.yaw
        if let turnFrom {
            let d0 = turnFrom - twoPi * floor((turnFrom + Float.pi) / twoPi)
            var change = dy - d0
            change -= twoPi * floor((change + Float.pi) / twoPi)
            dy = d0 + change
        } else {
            dy -= twoPi * floor((dy + Float.pi) / twoPi)
        }
        P.yaw = a.yaw + dy * k
        P.sq = mix(a.sq, b.sq, k); P.lean = mix(a.lean, b.lean, k); P.roll = mix(a.roll, b.roll, k)
        P.armL = mix(a.armL, b.armL, k); P.armR = mix(a.armR, b.armR, k)
        P.eye = mix(a.eye, b.eye, k); P.step = b.step; P.mouth = mix(a.mouth, b.mouth, k)
        P.lid = mix(a.lid, b.lid, k); P.lidTilt = mix(a.lidTilt, b.lidTilt, k)
        P.happy = mix(a.happy, b.happy, k); P.mouthO = mix(a.mouthO, b.mouthO, k)
        P.stride = mix(a.stride, b.stride, k); P.reach = mix(a.reach, b.reach, k)
        P.sit = mix(a.sit, b.sit, k)
        return P
    }

    /// A little unscripted moment every 6–12 s: a yawn, a sneeze, sniffing a
    /// flower, looking up at a falling leaf, a shiver of delight.
    static func addBeat(_ P: inout Pose, _ t: Float, _ seed: Float, _ act: Int, _ w: Float) {
        let slot = floor(t / 9.0)
        let start = 1.0 + 4.5 * hash11(slot * 2.71 + seed * 13.0)
        let ph = (t - slot * 9.0 - start) / 2.4
        if ph <= 0.0 || ph >= 1.0 { return }
        let env = smoothstep(0.0, 0.2, ph) * smoothstep(1.0, 0.75, ph) * w
        let kind = act == actSick ? 1 : min(Int(hash11(slot * 5.13 + seed * 31.0) * 5.0), 4)
        if kind == 0 {            // yawn
            P.mouthO = mix(P.mouthO, 1.0, env)
            P.lid = mix(P.lid, 0.8, env); P.happy *= 1.0 - env
            P.lean -= 0.12 * env
            P.armL += 0.6 * env; P.armR += 0.6 * env
            P.sq += 0.06 * env
        } else if kind == 1 {     // sneeze: wind up… achoo
            let wind = smoothstep(0.05, 0.55, ph) * (1.0 - smoothstep(0.58, 0.62, ph))
            let jolt = smoothstep(0.57, 0.62, ph) * (1.0 - smoothstep(0.7, 0.95, ph))
            P.lean += (-0.18 * wind + 0.34 * jolt) * w
            P.lid = mix(P.lid, 0.7, wind * w)
            P.mouthO = mix(P.mouthO, 0.55, wind * w)
            P.eye = mix(P.eye, 0.0, jolt * w)
            P.sq -= 0.1 * jolt * w
            P.armL += 0.5 * jolt * w; P.armR += 0.5 * jolt * w
        } else if kind == 2 {     // sniff a flower
            P.lean += 0.38 * env
            P.happy = mix(P.happy, 0.9, env)
            P.mouth = mix(P.mouth, 0.8, env)
            P.sq += 0.025 * sin(t * 18.0) * env
        } else if kind == 3 {     // look up at a falling leaf
            P.lean -= 0.34 * env
            P.roll += 0.12 * env
            P.eye = mix(P.eye, 1.15, env); P.lid *= 1.0 - env
            P.mouthO = mix(P.mouthO, 0.35, env)
        } else {                  // a little shiver of delight
            P.roll += 0.06 * sin(t * 45.0) * env
            P.sq += 0.05 * sin(t * 30.0) * env
            P.happy = mix(P.happy, 1.0, env)
            P.mouth = mix(P.mouth, 1.0, env); P.mouthO = mix(P.mouthO, 0.25, env)
            P.armL += 0.4 * env; P.armR += 0.4 * env
        }
    }

    /// The first seconds of a session: it is looking off to one side, notices
    /// you (a jolt and a "!"), turns to face you and waves.
    static func doubleTake(_ P: Pose, _ time: Float, _ az: Float, _ s: Float) -> Pose {
        var D = P
        let jolt = smoothstep(0.55, 0.68, time) * (1.0 - smoothstep(0.7, 1.05, time))
        let turn = smoothstep(0.8, 1.45, time)
        let wv = smoothstep(1.35, 1.75, time)
        D.pos = SIMD3(0.0, 0.12 * s * jolt, 0.0)
        D.yaw = mix(az + 1.15 + 0.12 * sin(time * 1.7), az, turn)
        D.sq = 1.0 + 0.13 * jolt
        D.lean = -0.12 * jolt; D.roll = 0
        D.eye = mix(P.eye, 1.25, smoothstep(0.55, 0.65, time))
        D.lid = 0; D.lidTilt = 0
        D.happy = 0.9 * wv
        D.mouth = wv
        D.mouthO = 0.7 * smoothstep(0.55, 0.65, time) * (1.0 - smoothstep(1.1, 1.4, time)) + 0.3 * wv
        D.armL = 0.5 + 0.7 * jolt
        D.armR = mix(0.5 + 0.7 * jolt, 2.7 + 0.35 * sin(time * 9.0), wv)
        D.stride = 2.0 * turn * (1.0 - turn)
        D.reach = 0; D.sit = 0
        return D
    }

    // ------------------------------------------------------------ MSL helpers, Float32

    static let twoPi: Float = 6.28318530718

    @inline(__always) static func fract(_ x: Float) -> Float { x - floor(x) }
    @inline(__always) static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    @inline(__always) static func mix3(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
    @inline(__always) static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
    @inline(__always) static func step(_ edge: Float, _ x: Float) -> Float { x < edge ? 0 : 1 }
    @inline(__always) static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = clamp((x - e0) / (e1 - e0), 0, 1)
        return t * t * (3 - 2 * t)
    }

    // Procedural hashes, as Prelude.swift's MSL has them.
    static func hash11(_ x: Float) -> Float {
        var p = fract(x * 0.3183099) + 0.1
        p *= p + 19.19
        return fract(p * p)
    }
    static func hash21(_ x: SIMD2<Float>) -> Float {
        var p = SIMD2(fract(x.x * 0.3183099), fract(x.y * 0.3678794)) + 0.1
        p += simd_dot(p, p + 19.19)
        return fract(p.x * p.y)
    }
    static func hash22(_ x: SIMD2<Float>) -> SIMD2<Float> {
        var p = SIMD2(fract(x.x * 0.3183099), fract(x.y * 0.3678794)) + 0.1
        p += simd_dot(p, SIMD2(p.y, p.x) + 19.19)
        return SIMD2(fract(p.x * p.y), fract(p.x + p.y))
    }
    static func valueNoise(_ st: SIMD2<Float>) -> Float {
        let i = SIMD2(floor(st.x), floor(st.y))
        let f = st - i
        let a = hash21(i)
        let b = hash21(i + SIMD2(1, 0))
        let c = hash21(i + SIMD2(0, 1))
        let d = hash21(i + SIMD2(1, 1))
        let u = f * f * (3.0 - 2.0 * f)
        return mix(mix(a, b, u.x), mix(c, d, u.x), u.y)
    }
}
