import AVFoundation
import CoreMedia
import Foundation
import simd
import Vision

// Camera input for `u.viewer`: the Mac's camera, Vision's face rectangles, and
// a filter that turns where the face sits in the frame into where the head is
// in front of the screen.
//
// Playground only, like system audio, and for a stronger reason: the saver
// runs sandboxed inside Apple's `legacyScreenSaver` with no camera usage
// description, and a screensaver that watches the room is not one to ship.
// Everywhere but here the viewer is `.centered`, the plain camera.

/// Pure geometry and filtering: a face box in, a `LerpViewer` out. No
/// AVFoundation in here, so a probe can drive it with synthetic boxes.
struct HeadPoseEstimator {
    /// tan of half the camera's horizontal field of view.
    var tanHalfFOV: Float
    /// Image width / height, for the vertical half of the field of view.
    var aspect: Float = 4.0 / 3.0
    /// Whether the frames arrive mirrored, as some connections deliver them.
    var mirrored = false

    /// A face that vanishes for a moment (a blink of the detector, a hand
    /// passing) holds its last pose this long before easing back to centre.
    static let hold: Double = 0.4
    /// How far ahead of the filtered pose to report, in seconds: the camera
    /// and the detector are ~50 ms behind the head, and leading by most of
    /// that is what keeps the scene from swimming after a quick move.
    static let lead: Float = 0.045
    /// Head poses outside these are clamped: past them the face is leaving
    /// the frame and the estimate is mostly noise.
    static let lateral: Float = 0.8
    static let nearest: Float = 0.6, farthest: Float = -1.0

    /// Where the face was when tracking began (or was last recentred): the
    /// direction it was seen in, and its width, which stands in for distance.
    private var reference: (direction: SIMD2<Float>, width: Float)?
    private var filter = OneEuroFilter()
    private var lastFace = -Double.infinity
    private var lastPose = SIMD3<Float>(0, 0, 0)

    init(horizontalFOVDegrees: Float) {
        tanHalfFOV = tan(horizontalFOVDegrees * .pi / 360)
    }

    /// Make the next face seen the centre.
    mutating func recenter() {
        reference = nil
        filter = OneEuroFilter()
    }

    /// One camera frame at `time` seconds. `face` is Vision's normalised
    /// bounding box (origin bottom left) of the face to follow, or nil when
    /// none was found.
    mutating func update(face: CGRect?, at time: Double) -> LerpViewer {
        var pose = SIMD3<Float>(0, 0, 0)
        if let face {
            let centre = SIMD2(Float(face.midX), Float(face.midY)) * 2 - 1
            // The ray from the camera to the face, as slopes.
            let direction = centre * SIMD2(tanHalfFOV, tanHalfFOV / aspect)
            let width = max(Float(face.width), 1e-3)
            let ref = reference ?? (direction, width)
            reference = ref
            // Distance now over distance at calibration: a face half as wide
            // is twice as far. The head's offset across the screen is then
            // that distance times the slope, less where it started, all in
            // units of the calibrated distance. The camera faces the watcher,
            // so their right is the image's left unless the frame is mirrored.
            let r = ref.width / width
            let across = r * direction - ref.direction
            pose = SIMD3(mirrored ? across.x : -across.x, across.y, 1 - r)
            lastFace = time
        } else if time - lastFace < Self.hold {
            pose = lastPose
        }
        lastPose = pose
        let smoothed = filter(simd_clamp(pose, SIMD3(-Self.lateral, -Self.lateral, Self.farthest),
                                         SIMD3(Self.lateral, Self.lateral, Self.nearest)), at: time)
        let led = smoothed + filter.velocity * Self.lead
        return LerpViewer(x: led.x, y: led.y, z: led.z)
    }
}

/// The 1€ filter (Casiez, Roussel & Vogel, CHI 2012), per component: a
/// low-pass whose cutoff rises with speed, so a still head reads steady and a
/// moving one reads without lag.
struct OneEuroFilter {
    /// Hz. The cutoff at rest: lower is steadier and laggier.
    var minCutoff: Float = 0.7
    /// How fast the cutoff rises with speed (per pose-unit/s).
    var beta: Float = 4.0
    /// Hz, for the speed estimate itself.
    var derivativeCutoff: Float = 1.0

    private var value: SIMD3<Float>?
    private(set) var velocity = SIMD3<Float>(0, 0, 0)
    private var time: Double = 0

    mutating func callAsFunction(_ x: SIMD3<Float>, at t: Double) -> SIMD3<Float> {
        guard let previous = value else {
            value = x; time = t
            return x
        }
        let dt = Float(max(1e-3, t - time))
        time = t
        velocity += Self.alpha(dt, derivativeCutoff) * ((x - previous) / dt - velocity)
        let cutoff = minCutoff + beta * simd_abs(velocity)
        let a = SIMD3(Self.alpha(dt, cutoff.x), Self.alpha(dt, cutoff.y), Self.alpha(dt, cutoff.z))
        let next = previous + a * (x - previous)
        value = next
        return next
    }

    private static func alpha(_ dt: Float, _ cutoff: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
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

    /// Goes back to `.centered` if frames stop arriving.
    let viewer = LiveInput<LerpViewer>(idle: .centered, staleAfter: 0.5)
    private(set) var cameraName = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.hergenroeder.lerping.head-tracker",
                                      qos: .userInteractive)
    private let faces = VNDetectFaceRectanglesRequest()
    private let sequence = VNSequenceRequestHandler()
    /// macOS does not report a camera's field of view (`videoFieldOfView` is
    /// iOS-only). Mac FaceTime cameras sit around 70° across; an error here
    /// only scales how far the scene moves, which `parallax` tunes anyway.
    private var estimator = HeadPoseEstimator(horizontalFOVDegrees: 70)

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

    deinit { session.stopRunning() }

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

        cameraName = device.localizedName
        queue.async { [self] in session.startRunning() }
    }

    /// Releases the camera (its light goes off) and drops `viewer` back to
    /// `.centered`. The session keeps its configuration, so `resume()` can
    /// pick the same camera back up.
    func stop() {
        queue.async { [self] in session.stopRunning() }
        viewer.reset()
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
        queue.async { [self] in estimator.recenter() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        try? sequence.perform([faces], on: pixels, orientation: .up)
        // The largest face is the nearest one: the person at the screen.
        let face = faces.results?.max { $0.boundingBox.width < $1.boundingBox.width }?.boundingBox
        estimator.aspect = Float(CVPixelBufferGetWidth(pixels)) / Float(max(1, CVPixelBufferGetHeight(pixels)))
        estimator.mirrored = connection.isVideoMirrored
        viewer.publish(estimator.update(face: face, at: time))
    }
}
