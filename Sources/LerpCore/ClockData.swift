import Foundation
import Metal

/// Data provider `clock`: the Mac's local time of day, for looks that follow
/// it (`sea-and-moon`). Binds `LerpClock` at fragment buffer 1.
///
/// **Purity.** As with the critter's sun (`CritterData`), the wall clock is
/// read once per *session* and anchored to `u.time == 0`: `hourAtZero` is the
/// local hour at time 0, and the shader's `hourAtZero + u.time / 3600` is the
/// real time of day for the rest of the session, moving at real speed, once.
/// A session starts on a new `u.seed`, the clock put back, or a frame after
/// `sessionGap` seconds without one (a new screensaver session, the look coming
/// round again in a rotation). Within a session the frame is a pure function of
/// `(time, seed, params)`, so the playground's scrubber moves the sun.
///
/// A `.still` library (every gallery still and its hover preview) and a host
/// with no bundle identifier (`LerpPreview`'s snapshot suite) get midnight on
/// an equinox day, so stills are reproducible byte for byte.
///
/// The `clock` parameter, when a look declares one and sets it to 0…24, pins
/// the hour at time 0 — also on an equinox day (sunrise 6, sunset 18), so a
/// pinned hour means the same light whatever the date.
public final class ClockData: LerpDataProvider {

    /// Mirrors `struct LerpClock` in `metalPrelude`.
    struct Clock {
        var hourAtZero: Float
        var sunrise: Float
        var sunset: Float
        var pad: Float = 0
    }

    static let sessionGap: TimeInterval = 5
    static let equinox = Clock(hourAtZero: 0, sunrise: 6, sunset: 18)

    private let live: Bool
    private var session: Clock?
    private var sessionSeed: Float = -1
    private var lastTime: Float = 0
    private var lastWall: TimeInterval = 0

    public init(mode: LerpRenderMode) {
        live = mode == .live && Bundle.main.bundleIdentifier != nil
    }

    public var metalPrelude: String {
        """
        // ---- lerp-data: clock -------------------------------------------------
        // Fragment buffer 1: the local time of day. Hour now, 0..24:
        //   fmod(clock.hourAtZero + u.time / 3600.0, 24.0)
        struct LerpClock {
            float hourAtZero; // local hour at u.time == 0
            float sunrise;    // today's approximate sunrise, local hours
            float sunset;     // and sunset
            float pad;
        };
        """
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        var c = resolve(uniforms, pinned: params?["clock"]?.scalarValue)
        encoder.setFragmentBytes(&c, length: MemoryLayout<Clock>.stride, index: 1)
    }

    private func resolve(_ u: LerpUniforms, pinned: Double?) -> Clock {
        if let pinned, pinned >= 0 {
            var c = Self.equinox
            c.hourAtZero = Float(pinned)
            return c
        }
        guard live else { return Self.equinox }
        let wall = Date().timeIntervalSince1970
        let newSession = session == nil
            || sessionSeed != u.seed
            || u.time < lastTime - 0.5
            || wall - lastWall > Self.sessionGap
        lastTime = u.time; lastWall = wall
        if newSession {
            let now = Date(timeIntervalSince1970: wall)
            let (rise, set) = Self.sunTimes(now)
            var h = (Self.clockHour(now) - u.time / 3600).truncatingRemainder(dividingBy: 24)
            if h < 0 { h += 24 }
            session = Clock(hourAtZero: h, sunrise: rise, sunset: set)
            sessionSeed = u.seed
        }
        return session!
    }

    static func clockHour(_ now: Date) -> Float {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        return Float(c.hour ?? 0) + Float(c.minute ?? 0) / 60 + Float(c.second ?? 0) / 3600
    }

    /// Sunrise and sunset in local clock hours, for a mid-latitude (~40°) site
    /// with solar noon at 12:00 standard time, shifted by the time zone's
    /// daylight saving offset. No location is read: this is "dark by five in
    /// November, light past eight in June", not an almanac. The southern
    /// hemisphere is not modelled.
    static func sunTimes(_ now: Date) -> (Float, Float) {
        let day = Double(Calendar.current.ordinality(of: .day, in: .year, for: now) ?? 172)
        let halfDay = 6.05 + 1.45 * cos(2 * .pi * (day - 172) / 365.25)
        let dst = TimeZone.current.daylightSavingTimeOffset(for: now) / 3600
        return (Float(12 - halfDay + dst), Float(12 + halfDay + dst))
    }
}
