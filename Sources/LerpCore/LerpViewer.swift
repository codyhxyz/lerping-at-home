import simd

/// Where the person watching is, for looks that draw the screen as a window
/// onto their scene (head-coupled perspective). Laid out as `u.viewer`, a
/// `float4`, straight after the audio levels.
///
/// The screen stays pinned and the eye moves: every pixel's ray starts at the
/// watcher's eye and passes through that pixel's own spot on the glass, so the
/// scene behind the glass shifts the way a view through a real window does.
///
/// **Units.** `x` right and `y` up are how far the head has moved across the
/// screen, and `z` how much nearer it has come, all divided by the distance
/// the watcher sat at when tracking was calibrated. They are dimensionless —
/// near enough the tangent of the angle the head has swung through — so they
/// mean the same on a 13" laptop as on a 32" display, and a look scales them
/// into its own scene by its own focal length (`eye(focal:gain:)`). `w` is
/// padding, always 0.
///
/// `.centered` is what every render gets unless a host opts in. The saver,
/// `--snapshot` (without `--viewer`) and the gallery stills never do, and a
/// centred viewer reproduces the plain camera exactly, so those stay a pure
/// function of (shader, time, seed, parameters). Only the playground's live
/// view, with Shader › Track Head on, ever moves it — see `HeadTracker`.
public struct LerpViewer: Equatable, Sendable {
    public var offset: SIMD4<Float>

    public init(x: Float = 0, y: Float = 0, z: Float = 0) {
        offset = SIMD4(x, y, z, 0)
    }

    public static let centered = LerpViewer()

    /// A look responds to the viewer exactly when it declares a parameter of
    /// this name; its value scales the effect (0 = a plain camera). One
    /// declaration both opts a look in and makes its strength tunable:
    ///
    ///     // lerp-param: parallax float 0 2 = 1 "Head parallax"
    public static let gainParameter = "parallax"

    /// The declared gain in `params`, or 0 for a look that does not declare
    /// one — which is what keeps every other look still.
    public static func gain(in params: LerpParameterValues?) -> Float {
        params?[gainParameter]?.scalarValue.map { Float($0) } ?? 0
    }

    /// Whether a look wearing `params` responds to the viewer at all.
    public static func isUsed(by params: LerpParameterValues?) -> Bool {
        params?[gainParameter] != nil
    }

    /// The eye's displacement in camera space — x right, y up, z forward — for
    /// a camera whose screen spans ±1 on its short axis at distance `focal`.
    ///
    /// This is the whole off-axis camera, and `metalSource` is the same thing
    /// in MSL: move the eye by `e`, keep looking straight ahead, and aim each
    /// ray at its pixel's fixed spot on the glass, `(uv, focal)`. That is a
    /// perspective camera whose image centre shifts by `e.xy` and whose focal
    /// length becomes `focal - e.z`, which is how a rasterising look
    /// (`SplatData`) applies it. Scaling by `focal` is what makes the glass sit
    /// where the look's own screen does: a point at that depth stays pinned,
    /// nearer ones swing against the head, farther ones follow it.
    public func eye(focal: Float, gain: Float) -> SIMD3<Float> {
        SIMD3(offset.x, offset.y, offset.z) * (focal * gain)
    }

    /// Spliced into the prelude after `struct LerpUniforms`.
    static let metalSource = """
    // Head-coupled ("window") camera — see LerpViewer.swift, which holds the
    // same math in Swift. With u.viewer at 0 (everywhere but the playground's
    // Track Head) both return the plain pinhole camera unchanged.
    static inline float3 lerpViewerEye(constant LerpUniforms& u, float focal, float gain) {
        return u.viewer.xyz * (focal * gain);
    }

    // Moves `ro` to the watcher's eye and returns the ray through this pixel's
    // spot on the glass. A drop-in for
    //     rd = normalize(uv.x * right + uv.y * up + focal * fwd)
    // Pass the look's `parallax` parameter as `gain`.
    static inline float3 lerpViewerRay(constant LerpUniforms& u, float gain, float2 uv, float focal,
                                       float3 right, float3 up, float3 fwd, thread float3& ro) {
        float3 e = lerpViewerEye(u, focal, gain);
        ro += e.x * right + e.y * up + e.z * fwd;
        return normalize((uv.x - e.x) * right + (uv.y - e.y) * up + (focal - e.z) * fwd);
    }
    """
}
