import simd

/// Turning a 3D look by hand: click and drag on the render and the scene
/// turns under the pointer, the way a globe turns under a hand.
///
/// **There is no new input path.** A look opts in by declaring one or both of
/// two ordinary parameters, in degrees:
///
///     // lerp-param: yaw   float -180 180 = 0 "Turn"
///     // lerp-param: pitch float -90  90  = 0 "Tilt"
///
/// and a drag moves them through the same `setParameter` a slider, a MIDI
/// knob or a hand pinch uses. So everything parameters already do, turning
/// does too, with no code of its own: the sliders show and set the angle,
/// Save keeps a framing as a preset (and the screensaver then plays it from
/// there), Learn binds a knob to it, `--param yaw=30` renders it, and the
/// declared range is the look's own limit — a terrain that must not look under
/// its ground declares a narrow `pitch`. At the default 0 the camera is the
/// look's own, bit for bit, which is what keeps the saver, the snapshots and
/// the gallery stills unchanged.
///
/// **Sign.** Positive `yaw` moves what is under the pointer right, positive
/// `pitch` moves it up — a drag right-and-up adds to both. The look decides
/// what it is holding: `lerpOrbit` swings the camera round a pivot (an object
/// in space), `lerpLook` turns it where it stands (a landscape, a corridor).
/// Both move the grabbed scene with the hand, so they turn the camera in
/// opposite directions for the same numbers.
public enum LerpTurn {
    public static let yawParameter = "yaw"
    public static let pitchParameter = "pitch"

    /// A drag across the render's short side turns the scene half a turn —
    /// about what the front of a globe does under a hand that sweeps it.
    public static let degreesPerShortSide = 180.0

    /// The parameters of `params` a drag moves, horizontal first. Empty for a
    /// look that does not turn, which is what makes a drag on it do nothing.
    public static func axes(of params: [LerpParam]) -> (yaw: LerpParam?, pitch: LerpParam?) {
        func scalar(_ name: String) -> LerpParam? {
            params.first { $0.name == name && $0.type == .float }
        }
        return (scalar(yawParameter), scalar(pitchParameter))
    }

    /// `value` turned by `degrees`. A range that spans a whole turn wraps, so
    /// a drag can keep spinning the scene round; anything narrower is the
    /// look's limit and holds at its end.
    public static func turned(_ param: LerpParam, from value: Double, by degrees: Double) -> Double {
        let span = param.max - param.min
        let next = value + degrees
        guard span >= 360 else { return Swift.min(Swift.max(next, param.min), param.max) }
        let wrapped = (next - param.min).truncatingRemainder(dividingBy: 360)
        return param.min + (wrapped < 0 ? wrapped + 360 : wrapped)
    }

    // MARK: - The camera, in Swift (for looks whose camera is built on the CPU)

    /// `lerpOrbit` for a camera built in Swift: swings `eye`, `right` and
    /// `fwd` together round `pivot`. `up` is the look's world-up hint, the axis
    /// a horizontal drag turns about; `right` is the look's own screen-right,
    /// whichever way round its cross product makes it.
    public static func orbit(yaw: Float, pitch: Float, pivot: SIMD3<Float>, up: SIMD3<Float>,
                             eye: inout SIMD3<Float>, right: inout SIMD3<Float>, fwd: inout SIMD3<Float>) {
        guard yaw != 0 || pitch != 0 else { return }
        let q = orbitRotation(yaw: yaw, pitch: pitch, up: up, right: right, fwd: fwd)
        eye = pivot + q.act(eye - pivot)
        right = q.act(right)
        fwd = q.act(fwd)
    }

    /// How `orbit` turns the camera, as one rotation. A look whose camera
    /// stays put and whose object turns instead applies the inverse to the
    /// object: the same picture, with the sign kept in one place.
    public static func orbitRotation(yaw: Float, pitch: Float, up: SIMD3<Float>,
                                     right: SIMD3<Float>, fwd: SIMD3<Float>) -> simd_quatf {
        let h = handedness(up: up, right: right, fwd: fwd)
        return frameRotation(yaw: yaw * h, pitch: -pitch * h, up: up, right: right)
    }

    /// `lerpLook` in Swift: turns `right` and `fwd` about the eye.
    public static func look(yaw: Float, pitch: Float, up: SIMD3<Float>,
                            right: inout SIMD3<Float>, fwd: inout SIMD3<Float>) {
        guard yaw != 0 || pitch != 0 else { return }
        let h = handedness(up: up, right: right, fwd: fwd)
        let q = frameRotation(yaw: -yaw * h, pitch: pitch * h, up: up, right: right)
        right = q.act(right)
        fwd = q.act(fwd)
    }

    /// +1 when the look's screen-right is `up × fwd` (most raymarchers here),
    /// -1 when it is `fwd × up` (a right-handed camera looking down -z).
    private static func handedness(up: SIMD3<Float>, right: SIMD3<Float>, fwd: SIMD3<Float>) -> Float {
        simd_dot(simd_cross(up, fwd), right) < 0 ? -1 : 1
    }

    /// Pitch about the camera's right, then yaw about world up, as one
    /// rotation applied rigidly to the whole frame — so the frame never
    /// degenerates, even turned over the pole. Angles in degrees.
    private static func frameRotation(yaw: Float, pitch: Float, up: SIMD3<Float>,
                                      right: SIMD3<Float>) -> simd_quatf {
        let toRadians = Float.pi / 180
        return simd_quatf(angle: yaw * toRadians, axis: simd_normalize(up))
             * simd_quatf(angle: pitch * toRadians, axis: simd_normalize(right))
    }

    // MARK: - The camera, in MSL

    /// Spliced into the prelude after `struct LerpUniforms`. The same math as
    /// `orbit`/`look` above; see the type comment for the sign convention.
    static let metalSource = """
    // Drag to turn — see LerpTurn.swift, which holds the same math in Swift.
    // Call between the look's `right` and its `up = cross(...)`, passing the
    // world-up hint `right` was crossed from; then build `up` and `rd` from
    // the turned frame exactly as before. With `yaw` and `pitch` at 0 (the
    // defaults, and everywhere nobody has dragged) both return untouched.
    static inline float3 lerpTurnAxis(float3 v, float3 k, float a) {
        float c = cos(a), s = sin(a);
        return v * c + cross(k, v) * s + k * (dot(k, v) * (1.0 - c));
    }
    static inline void lerpTurnFrame(float yaw, float pitch, float3 pivot, float3 upHint,
                                     thread float3& ro, thread float3& right, thread float3& fwd) {
        float3 k = normalize(upHint);
        float3 r = normalize(right);
        float a = yaw * (PI / 180.0), b = pitch * (PI / 180.0);
        ro = pivot + lerpTurnAxis(lerpTurnAxis(ro - pivot, r, b), k, a);
        fwd = lerpTurnAxis(lerpTurnAxis(fwd, r, b), k, a);
        right = lerpTurnAxis(right, k, a);
    }
    static inline float lerpTurnHandedness(float3 upHint, float3 right, float3 fwd) {
        return dot(cross(upHint, fwd), right) < 0.0 ? -1.0 : 1.0;
    }

    // Swings the camera round `pivot`: an object in space, held like a globe.
    static inline void lerpOrbit(float yaw, float pitch, float3 pivot, float3 upHint,
                                 thread float3& ro, thread float3& right, thread float3& fwd) {
        if (yaw == 0.0 && pitch == 0.0) return;
        float h = lerpTurnHandedness(upHint, right, fwd);
        lerpTurnFrame(yaw * h, -pitch * h, pivot, upHint, ro, right, fwd);
    }

    // Turns the camera where it stands: a landscape or a corridor, grabbed
    // and pulled round. `ro` does not move.
    static inline void lerpLook(float yaw, float pitch, float3 upHint,
                                thread float3& right, thread float3& fwd) {
        if (yaw == 0.0 && pitch == 0.0) return;
        float h = lerpTurnHandedness(upHint, right, fwd);
        float3 eye = float3(0.0);
        lerpTurnFrame(-yaw * h, pitch * h, eye, upHint, eye, right, fwd);
    }
    """
}
