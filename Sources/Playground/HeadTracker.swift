import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os
import QuartzCore
import simd
import Vision

// Camera input for `u.viewer`: the Mac's camera, Vision's face landmarks, and
// a filter that turns where the eyes sit in the frame into where the head is
// in front of the screen.
//
// Playground only, like system audio, and for a stronger reason: the saver
// runs sandboxed inside Apple's `legacyScreenSaver` with no camera usage
// description, and a screensaver that watches the room is not one to ship.
// Everywhere but here the viewer is `.centered`, the plain camera.
//
// **Why the pupils and not the face box.** The box Vision draws round a face
// breathes from frame to frame and changes shape as the head tilts and turns,
// and its centre sits somewhere on the nose, not where the eye is. The two
// pupils are the point the scene should be seen from, and the distance
// between them is a fixed ~63 mm on everyone's face, so its size in the frame
// is a far steadier ruler for how far away they are. The box is kept as a
// fallback for frames where the detector found a face but not its landmarks.

/// One face as the detector saw it, in Vision's normalised image coordinates
/// (0...1 across each axis, origin bottom left).
struct FaceSample {
    var box: CGRect
    /// The two pupils or, failing those, the centres of the two eye outlines.
    /// Nil when the detector found the face but not its landmarks.
    var eyes: (SIMD2<Float>, SIMD2<Float>)?
    /// How far the head is turned left or right, in radians (0 facing the
    /// camera). Nil when the detector did not say.
    var yaw: Float?

    init(box: CGRect, eyes: (SIMD2<Float>, SIMD2<Float>)? = nil, yaw: Float? = nil) {
        self.box = box
        self.eyes = eyes
        self.yaw = yaw
    }

    /// The centroid of each eye's points (pupil, or else outline), normalised
    /// by `size`. `pupils` and `outlines` are (one eye, the other) in pixels.
    static func eyes(pupils: ([CGPoint], [CGPoint]), outlines: ([CGPoint], [CGPoint]),
                     size: CGSize) -> (SIMD2<Float>, SIMD2<Float>)? {
        func centroid(_ points: [CGPoint]) -> SIMD2<Float>? {
            guard !points.isEmpty, size.width > 0, size.height > 0 else { return nil }
            let sum = points.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2($1.x, $1.y) }
            let mean = sum / Double(points.count) / SIMD2(Double(size.width), Double(size.height))
            return SIMD2(Float(mean.x), Float(mean.y))
        }
        if let a = centroid(pupils.0), let b = centroid(pupils.1) { return (a, b) }
        if let a = centroid(outlines.0), let b = centroid(outlines.1) { return (a, b) }
        return nil
    }
}

/// Pure geometry and filtering: a `FaceSample` in, a `LerpViewer` out. No
/// AVFoundation in here, so a probe can drive it with synthetic faces.
///
/// **What the units are in millimetres.** `LerpViewer` is dimensionless: head
/// movement divided by the distance the watcher sat at when tracking was
/// calibrated (`D0`). With the typical inter-pupil distance and the camera's
/// field of view, `calibrationDistanceMM` estimates `D0`, so `x * D0` is how
/// many millimetres the eyes have moved across. A look whose glass should sit
/// exactly where the physical screen is wants `focal = D0 / (H / 2)`, `H`
/// being the screen's short side (`CGDisplayScreenSize`; see
/// `ViewingGeometry`), and a `parallax` gain of 1. Neither is applied here:
/// the viewer stays dimensionless, and `parallax` remains the look's own
/// knob. The camera sits above the screen rather than in its middle; that
/// offset is absorbed by calibration, which calls wherever the head was
/// "straight on".
struct HeadPoseEstimator {
    /// tan of half the camera's horizontal field of view.
    var tanHalfFOV: Float
    /// Image width / height, for the vertical half of the field of view.
    var aspect: Float = 4.0 / 3.0
    /// Whether the frames arrive mirrored, as some connections deliver them.
    var mirrored = false

    /// Head poses outside these are clamped: past them the face is leaving
    /// the frame and the estimate is mostly noise.
    static let lateral: Float = 0.8
    static let nearest: Float = 0.6, farthest: Float = -1.0
    /// A head turned further than this (radians) is not measured. The pupils
    /// close up as the head turns (by cos yaw, which is corrected for below
    /// this), and past it the far eye is half hidden and its landmark is a
    /// guess. The face is still there, so the caller holds the last pose
    /// rather than reporting it lost.
    static let maxYaw: Float = 35 * .pi / 180
    /// Adult inter-pupil distance, mm (the population mean; individuals run
    /// ~54–74). Only `calibrationDistanceMM` uses it: the pose itself is a
    /// ratio of spans, in which it cancels.
    static let typicalIPD: Float = 63

    /// Where the eyes were when tracking began (or was last recentred): the
    /// direction they were seen in, and the span between them as a fraction
    /// of the image width, which stands in for distance.
    private var reference: (direction: SIMD2<Float>, span: Float)?
    /// What the landmarks have taught about this face's box, for frames that
    /// have only the box: where the eye midpoint sits inside it (0...1 each
    /// way, origin bottom left) and the pupil span over the box's width.
    /// Seeded with a typical Vision face box.
    private var eyeInBox = SIMD2<Float>(0.5, 0.62)
    private var spanPerBoxWidth: Float = 0.42

    init(horizontalFOVDegrees: Float) {
        tanHalfFOV = tan(horizontalFOVDegrees * .pi / 360)
    }

    /// Make the next face seen the centre.
    mutating func recenter() {
        reference = nil
    }

    /// How far from the camera the watcher sat at calibration, in mm, if
    /// their pupils are `typicalIPD` apart and the field of view is right.
    /// Nil until a face has been seen.
    var calibrationDistanceMM: Float? {
        reference.map { Self.typicalIPD / ($0.span * 2 * tanHalfFOV) }
    }

    /// What one face says about where the head is: its pose, clamped, or
    /// `.turned` when it is there but turned too far to measure.
    enum Reading { case pose(SIMD3<Float>), turned }

    mutating func read(_ face: FaceSample) -> Reading {
        if let yaw = face.yaw, abs(yaw) > Self.maxYaw { return .turned }
        return .pose(simd_clamp(measure(face), SIMD3(-Self.lateral, -Self.lateral, Self.farthest),
                                SIMD3(Self.lateral, Self.lateral, Self.nearest)))
    }

    /// The head's pose from one face, before clamping or filtering, in units
    /// of the calibrated distance. The first face measured is the centre.
    private mutating func measure(_ face: FaceSample) -> SIMD3<Float> {
        let (eye, span) = locate(face)
        // The ray from the camera to the eyes, as slopes.
        let direction = (eye * 2 - 1) * SIMD2(tanHalfFOV, tanHalfFOV / aspect)
        let ref = reference ?? (direction, span)
        reference = ref
        // Distance now over distance at calibration: pupils half as far
        // apart are twice as far away. The head's offset across the screen
        // is then that distance times the slope, less where it started, all
        // in units of the calibrated distance. The camera faces the watcher,
        // so their right is the image's left unless the frame is mirrored.
        let r = ref.span / span
        let across = r * direction - ref.direction
        return SIMD3(mirrored ? across.x : -across.x, across.y, 1 - r)
    }

    /// The eye midpoint (normalised image coordinates) and the pupil span
    /// (a fraction of the image width), from the landmarks when there are
    /// any and from the box, as the landmarks last related to it, when not.
    private mutating func locate(_ face: FaceSample) -> (eye: SIMD2<Float>, span: Float) {
        let origin = SIMD2(Float(face.box.minX), Float(face.box.minY))
        let size = simd_max(SIMD2(Float(face.box.width), Float(face.box.height)), SIMD2(repeating: 1e-3))
        if let (a, b) = face.eyes {
            // Measured in units of the image width on both axes, so the length
            // is the same however the head rolls: tilting it sideways turns
            // the pupils' separation without shortening it. Turning it
            // (yaw) does shorten it, by cos yaw, which is undone here.
            var span = simd_length((b - a) * SIMD2(1, 1 / aspect))
            if let yaw = face.yaw { span /= max(cos(yaw), 0.5) }
            if span > 1e-3 {
                let eye = (a + b) / 2
                eyeInBox = simd_mix(eyeInBox, (eye - origin) / size, SIMD2(repeating: 0.2))
                spanPerBoxWidth = simd_mix(spanPerBoxWidth, span / size.x, 0.2)
                return (eye, span)
            }
        }
        return (origin + eyeInBox * size, spanPerBoxWidth * size.x)
    }
}

/// What `HeadPoseEstimator`'s dimensionless pose means on this desk.
struct ViewingGeometry: Sendable {
    /// Eye to camera at calibration, mm, assuming a typical inter-pupil
    /// distance and the guessed field of view (each good to ~10 %).
    var distanceMM: Float
    /// The main display's short side, mm, if it reports a physical size.
    var screenShortSideMM: Float?

    /// The `focal` that would put a look's glass (±1 on the short axis) at
    /// the physical screen, for `parallax` 1: `D0 / (H / 2)`.
    var physicalFocal: Float? {
        screenShortSideMM.map { distanceMM / ($0 / 2) }
    }

    /// `CGDisplayScreenSize` of the main display, short side; nil when the
    /// display does not report one (it returns zero then).
    static func mainDisplayShortSideMM() -> Float? {
        let size = CGDisplayScreenSize(CGMainDisplayID())
        let short = Float(min(size.width, size.height))
        return short > 0 ? short : nil
    }
}

/// The 1€ filter (Casiez, Roussel & Vogel, CHI 2012), per component: a
/// low-pass whose cutoff rises with speed, so a still head reads steady and a
/// moving one reads without lag. As `HeadPoseFilter`'s 2026 reference runs
/// it: besides the value it keeps a 5 Hz low-pass of the *output's* velocity,
/// which is what latency prediction extrapolates with.
struct OneEuroFilter {
    /// Hz. The cutoff at rest: lower is steadier and laggier.
    var minCutoff: Float
    /// How fast the cutoff rises with speed (Hz per pose-unit/s).
    var beta: Float
    /// Hz, for the speed estimate that drives the cutoff.
    var derivativeCutoff: Float = 1.0
    /// Hz, for `velocity`.
    static let velocityCutoff: Float = 5

    private var value: SIMD3<Float>?
    private var dx = SIMD3<Float>(repeating: 0)
    /// Low-passed velocity of the filtered output, pose units/s.
    private(set) var velocity = SIMD3<Float>(repeating: 0)
    private var time: Double = 0

    /// Per-component cutoffs, so depth can be smoothed harder than x and y.
    var cutoffScale = SIMD3<Float>(repeating: 1)

    init(minCutoff: Float, beta: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func reset() {
        value = nil
        dx = SIMD3(repeating: 0)
        velocity = SIMD3(repeating: 0)
    }

    mutating func callAsFunction(_ x: SIMD3<Float>, at t: Double) -> SIMD3<Float> {
        guard let previous = value else {
            value = x; time = t
            return x
        }
        let dt = Float(t - time)
        guard dt > 0 else { return previous }   // a duplicate or out-of-order frame
        time = t
        dx += Self.alpha(dt, SIMD3(repeating: derivativeCutoff)) * ((x - previous) / dt - dx)
        let cutoff = (minCutoff + beta * simd_abs(dx)) * cutoffScale
        let next = previous + Self.alpha(dt, cutoff) * (x - previous)
        velocity += Self.alpha(dt, SIMD3(repeating: Self.velocityCutoff)) * ((next - previous) / dt - velocity)
        value = next
        return next
    }

    private static func alpha(_ dt: Float, _ cutoff: SIMD3<Float>) -> SIMD3<Float> {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Irregular, late eye measurements (~30 Hz, ~50 ms behind) in; a smooth eye
/// position sampled every rendered frame out. A port of the pose stage of
/// VintagePhebe/head-tracked-3d-display (`src/tracking/headPose.ts`, October
/// 2026) — the MediaPipe + Kooima + 1€ pipeline this year's head-coupled
/// demos share — with its default settings, converted from metres to this
/// file's units (fractions of the calibrated viewing distance, `D0`):
///
/// - 1€ per axis, depth at 0.35× the cutoffs (depth from eye spacing is the
///   noisiest axis).
/// - Prediction over the pipeline latency plus the render smoother's own lag,
///   capped at 60 ms, and gated by head speed so velocity noise never makes a
///   still view wiggle.
/// - Render-rate exponential smoothing (160 ms still, 18 ms moving), so the
///   view moves continuously between camera frames instead of in 30 Hz steps.
/// - Tracking loss: hold the shown pose 0.6 s, then ease to centre over 1.2 s.
///   Frames that stop arriving for 0.4 s count as a loss. A face found again
///   restarts the filters and blends in from what is shown over 0.25 s.
///
/// Measurements arrive on the tracker's queue and samples are taken on the
/// main thread, so the state is behind a lock.
final class HeadPoseFilter: @unchecked Sendable {
    // The reference's DEFAULT_POSE_PARAMS, seconds.
    static let hold: Double = 0.6
    static let returning: Double = 1.2
    static let recover: Double = 0.25
    static let stale: Double = 0.4
    static let maxPredict: Double = 0.06
    static let stillTau: Double = 0.16
    static let moveTau: Double = 0.018
    /// Head speeds (m/s) below which it counts as still, above which as moving.
    static let stillSpeed: Float = 0.035
    static let moveSpeed: Float = 0.16
    /// `oneEuroFromSettings(0.5, 0.5)`, the reference's default sliders:
    /// 6·(0.3/6)^0.5 Hz, and 60·0.5^1.5 Hz per m/s.
    static let minCutoff: Float = 6 * (0.3 / 6 as Float).squareRoot()
    static let betaPerMetre: Float = 60 * pow(0.5, 1.5)
    static let depthCutoffScale: Float = 0.35
    /// The reference's default viewing distance, for converting its metric
    /// speeds until a face has calibrated the real one.
    static let defaultDistanceM: Float = 0.6

    private struct State {
        var filter: OneEuroFilter
        var distanceM: Float = HeadPoseFilter.defaultDistanceM
        var filtered = SIMD3<Float>(repeating: 0)
        var display = SIMD3<Float>(repeating: 0)
        var holdFrom = SIMD3<Float>(repeating: 0)
        var blendFrom = SIMD3<Float>(repeating: 0)
        var smoothed = SIMD3<Float>(repeating: 0)
        var smoothValid = false
        var lastSample: Double = 0
        var hasData = false
        var inLoss = false
        var lostSince: Double?
        var lastMeasurement: Double = 0
        var blendStart = -Double.infinity
    }

    private let state: OSAllocatedUnfairLock<State>

    init() {
        var filter = OneEuroFilter(minCutoff: Self.minCutoff, beta: Self.betaPerMetre * Self.defaultDistanceM)
        filter.cutoffScale = SIMD3(1, 1, Self.depthCutoffScale)
        state = OSAllocatedUnfairLock(initialState: State(filter: filter))
    }

    /// The calibrated viewing distance, once known: the reference's speeds
    /// and 1€ beta are per metre, and a pose unit is this many metres.
    func setDistance(mm: Float) {
        state.withLock { s in
            s.distanceM = mm / 1000
            s.filter.beta = Self.betaPerMetre * s.distanceM
        }
    }

    /// Forget all tracking history (the camera stopped).
    func reset() {
        state.withLock { s in
            s.hasData = false
            s.inLoss = false
            s.lostSince = nil
            s.smoothValid = false
            s.filter.reset()
        }
    }

    /// Treat the next measurement as a face found again: blend to it rather
    /// than filtering the jump (a recentre moves the zero under the filter).
    func restart() {
        state.withLock { s in if s.hasData { s.lostSince = s.lostSince ?? s.lastMeasurement } }
    }

    /// A face was measured in the frame captured at `time` (host seconds).
    func measured(_ pose: SIMD3<Float>, at time: Double) {
        state.withLock { s in
            if !s.hasData || s.inLoss || s.lostSince != nil {
                s.filter.reset()
                s.blendFrom = s.display
                s.blendStart = time
                s.smoothValid = false
            }
            s.filtered = s.filter(pose, at: time)
            s.lastMeasurement = time
            s.hasData = true
            s.inLoss = false
            s.lostSince = nil
        }
    }

    /// A frame was read but no face was found in it.
    func noFace(at time: Double) {
        state.withLock { s in if s.lostSince == nil { s.lostSince = time } }
    }

    /// The eye to render with at `now` (host seconds), as a viewer.
    func sample(at now: Double = CACurrentMediaTime()) -> LerpViewer {
        let out = state.withLock { s -> SIMD3<Float> in
            var out: SIMD3<Float>
            if !s.hasData {
                out = .zero
            } else if let lostAt = s.lostSince
                        ?? (now - s.lastMeasurement > Self.stale ? s.lastMeasurement + Self.stale : nil) {
                if !s.inLoss {
                    s.inLoss = true
                    s.holdFrom = s.display
                }
                let dt = now - lostAt
                let home = dt < Self.hold ? 0 : Self.smoothstep(Float((dt - Self.hold) / Self.returning))
                out = s.holdFrom * (1 - home)
            } else {
                var tracked = s.filtered
                // 0 = head still, 1 = clearly moving: gates prediction and
                // picks the render smoother's time constant.
                let v = s.filter.velocity * s.distanceM
                let speed = simd_length(SIMD3(v.x, v.y, v.z * 0.5))
                let motion = Self.smoothstep((speed - Self.stillSpeed) / (Self.moveSpeed - Self.stillSpeed))
                let tau = Self.stillTau + (Self.moveTau - Self.stillTau) * Double(motion)
                if motion > 0 {
                    let latency = min(max(now - s.lastMeasurement, 0), Self.maxPredict)
                    tracked += s.filter.velocity * Float(latency + tau) * motion
                }
                if s.smoothValid {
                    let dt = max(0, now - s.lastSample)
                    let axy = Float(1 - exp(-dt / max(0.001, tau)))
                    let az = Float(1 - exp(-dt / max(0.001, tau * Double(2 - motion))))
                    s.smoothed += (tracked - s.smoothed) * SIMD3(axy, axy, az)
                } else {
                    s.smoothed = tracked
                    s.smoothValid = true
                }
                let k = (now - s.blendStart) / Self.recover
                out = k < 1 ? simd_mix(s.blendFrom, s.smoothed, SIMD3(repeating: Self.smoothstep(Float(k))))
                            : s.smoothed
            }
            s.display = out
            s.lastSample = now
            return out
        }
        return LerpViewer(x: out.x, y: out.y, z: out.z)
    }

    private static func smoothstep(_ x: Float) -> Float {
        let t = simd_clamp(x, 0, 1)
        return t * t * (3 - 2 * t)
    }
}

/// The camera, feeding `viewer`. Start and stop on the main thread; frames
/// arrive on a private serial queue that alone touches the estimator.
final class HeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noCamera, unusable(String)
        var description: String {
            switch self {
            case .noCamera: return "no camera found"
            case .unusable(let why): return why
            }
        }
    }

    /// The eye to render with: sample it once per drawn frame.
    let pose = HeadPoseFilter()
    private(set) var cameraName = ""
    /// The pose's scale in millimetres, once a face has been seen. Any thread.
    var geometry: ViewingGeometry? { geometryLock.withLock { $0 } }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.hergenroeder.lerping.head-tracker",
                                      qos: .userInteractive)
    /// macOS 14–26: the Objective-C requests, newest revisions they have
    /// (3). The face box first, for yaw and to pick the face; its landmarks
    /// after, for that face alone.
    private let faces: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let landmarks: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()
    private let sequence = VNSequenceRequestHandler()
    /// Queue-only. On macOS 27 the Swift requests (revision 4, which the
    /// Objective-C API does not have) are async; a frame that arrives while
    /// one is still being read is dropped rather than queued behind it.
    private var detecting = false
    /// macOS does not report a camera's field of view (`videoFieldOfView` is
    /// iOS-only). Mac FaceTime cameras sit around 70° across; an error here
    /// only scales how far the scene moves, which `parallax` tunes anyway.
    private var estimator = HeadPoseEstimator(horizontalFOVDegrees: 70)
    /// Queue-only: the last pose measured, held while the face is turned away.
    private var lastPose = SIMD3<Float>(repeating: 0)
    private var screenShortSideMM: Float?
    private let geometryLock = OSAllocatedUnfairLock<ViewingGeometry?>(initialState: nil)
    /// Center Stage as it was before `start` turned it off, to put back.
    private var savedCenterStage: (mode: AVCaptureDevice.CenterStageControlMode, enabled: Bool)?

    /// Asks for camera access the first time (the prompt is worded by
    /// `NSCameraUsageDescription`) and answers on the main thread.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        default: done(false)
        }
    }

    deinit {
        session.stopRunning()
        restoreCenterStage()
    }

    func start() throws {
        guard let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
        else { throw Failure.noCamera }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw Failure.unusable("\(device.localizedName): \(error.localizedDescription)")
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        // A face needs far fewer pixels than the camera has; VGA keeps the
        // detector at a few milliseconds a frame.
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.unusable("\(device.localizedName) cannot stream video here")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        disableCenterStage(for: device)
        cameraName = device.localizedName
        screenShortSideMM = ViewingGeometry.mainDisplayShortSideMM()
        queue.async { [self] in session.startRunning() }
    }

    /// Releases the camera (its light goes off) and drops `viewer` back to
    /// `.centered`. The session keeps its configuration, so `resume()` can
    /// pick the same camera back up.
    func stop() {
        queue.async { [self] in session.stopRunning() }
        restoreCenterStage()
        pose.reset()
    }

    /// Takes the camera back after a `stop()` without building a second
    /// session — `start()` again would try to add the same input twice. The
    /// calibrated centre is kept: the watcher has not moved because nothing
    /// was looking. Desktop Mode pauses and resumes the tracker this way.
    func resume() {
        queue.async { [self] in if !session.isRunning { session.startRunning() } }
    }

    /// Wherever the watcher is now becomes the centre.
    func recenter() {
        queue.async { [self] in
            estimator.recenter()
            pose.restart()
        }
    }

    /// Center Stage pans and zooms a crop of the sensor to keep the face
    /// framed, which is exactly the motion being measured: with it on, the
    /// head drifting left reads as nothing, then as a jump when the crop
    /// catches up. The class properties are the app's, not the system's, and
    /// `.app` control greys out the Control Center toggle while tracking runs.
    private func disableCenterStage(for device: AVCaptureDevice) {
        guard savedCenterStage == nil, device.formats.contains(where: { $0.isCenterStageSupported })
        else { return }
        savedCenterStage = (AVCaptureDevice.centerStageControlMode, AVCaptureDevice.isCenterStageEnabled)
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false
    }

    private func restoreCenterStage() {
        guard let saved = savedCenterStage else { return }
        savedCenterStage = nil
        // Enabled can only be set under app or cooperative control, which
        // `.app` still is; the mode goes back last.
        AVCaptureDevice.isCenterStageEnabled = saved.enabled
        AVCaptureDevice.centerStageControlMode = saved.mode
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // On the host clock, which is what `HeadPoseFilter.sample` reads
        // (CACurrentMediaTime): the latency it predicts across is the gap.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let time = session.synchronizationClock.map {
            CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()).seconds
        } ?? CACurrentMediaTime()
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        estimator.aspect = Float(size.width) / Float(max(1, size.height))
        estimator.mirrored = connection.isVideoMirrored
        if #available(macOS 27, *) {
            guard !detecting else { return }
            detecting = true
            Task { [self] in
                let face = await Self.detect(in: pixels, size: size)
                queue.async { [self] in
                    detecting = false
                    publish(face, at: time)
                }
            }
        } else {
            publish(detectLegacy(in: pixels, size: size), at: time)
        }
    }

    /// Queue-only.
    private func publish(_ face: FaceSample?, at time: Double) {
        switch face.map({ estimator.read($0) }) {
        case .pose(let measured)?:
            lastPose = measured
            pose.measured(measured, at: time)
        case .turned?:
            // Still there, looking away: the head has not moved.
            pose.measured(lastPose, at: time)
        case nil:
            pose.noFace(at: time)
        }
        if let distance = estimator.calibrationDistanceMM {
            pose.setDistance(mm: distance)
            let geometry = ViewingGeometry(distanceMM: distance, screenShortSideMM: screenShortSideMM)
            geometryLock.withLock { $0 = geometry }
        }
    }

    /// The largest face is the nearest one: the person at the screen.
    private func detectLegacy(in pixels: CVPixelBuffer, size: CGSize) -> FaceSample? {
        try? sequence.perform([faces], on: pixels, orientation: .up)
        guard let face = faces.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }
        landmarks.inputFaceObservations = [face]
        try? sequence.perform([landmarks], on: pixels, orientation: .up)
        var eyes: (SIMD2<Float>, SIMD2<Float>)?
        if let marks = landmarks.results?.first?.landmarks {
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
                region?.pointsInImage(imageSize: size) ?? []
            }
            eyes = FaceSample.eyes(pupils: (points(marks.leftPupil), points(marks.rightPupil)),
                                   outlines: (points(marks.leftEye), points(marks.rightEye)), size: size)
        }
        return FaceSample(box: face.boundingBox, eyes: eyes, yaw: face.yaw?.floatValue)
    }

    @available(macOS 27, *)
    private static func detect(in pixels: CVPixelBuffer, size: CGSize) async -> FaceSample? {
        let handler = ImageRequestHandler(pixels, orientation: .up)
        guard let found = try? await handler.perform(DetectFaceRectanglesRequest(.revision4)),
              let face = found.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        else { return nil }
        var request = DetectFaceLandmarksRequest(.revision4)
        request.inputFaceObservations = [face]
        var eyes: (SIMD2<Float>, SIMD2<Float>)?
        if let marks = (try? await handler.perform(request))?.first?.landmarks {
            typealias Region = FaceObservation.Landmarks2D.Region
            func points(_ region: Region) -> [CGPoint] {
                region.pointsInImageCoordinates(size, origin: .lowerLeft)
            }
            eyes = FaceSample.eyes(pupils: (points(marks.leftPupil), points(marks.rightPupil)),
                                   outlines: (points(marks.leftEye), points(marks.rightEye)), size: size)
        }
        return FaceSample(box: face.boundingBox.cgRect, eyes: eyes,
                          yaw: Float(face.yaw.converted(to: .radians).value))
    }
}
