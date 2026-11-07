import Foundation

/// When a captioned look's label is on screen. The textless look is the
/// default: the label comes in with the look, says what it is, and goes,
/// and a host may hold it up for as long as someone wants it (the
/// playground does while the pointer moves over the picture, or while
/// Shader › Show Captions is on).
///
/// `age` is seconds on the shader clock since the look came in, so a paused
/// clock pauses the label with everything else, and scrubbing back brings it
/// back the way it first appeared.
public enum LerpCaptionSchedule {
    /// Seconds the label is held at full strength after its look comes in.
    public static let hold: Double = 6
    /// Seconds it then takes to fade away.
    public static let fade: Double = 1.6
    /// Seconds a host's reveal takes to come up or go down.
    public static let reveal: Double = 0.25

    public static func opacity(age: Double) -> Double {
        if age <= hold { return 1 }
        let x = min(1, (age - hold) / fade)
        return 1 - x * x * (3 - 2 * x)
    }
}
