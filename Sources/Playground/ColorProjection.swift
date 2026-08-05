import Foundation

/// What one CC does to a `color` parameter, and the colour space it does it in.
///
/// A colour is four numbers and a knob is one, so a binding has to say *which*
/// axis it drives. Doing that in RGB is useless — "more red" is not a thing a
/// palette wants — so the knob turns in OKLCH, the cylindrical form of Oklab.
///
/// **Why not HSV.** Equal steps of HSV hue are not equal perceptual steps:
/// yellow and cyan read far brighter than blue at the same S/V, so a knob
/// sweeping HSV hue feels lumpy and drags the lightness of the picture around
/// with it. That matters here more than usual: the repo has 31 shaders with
/// hand-tuned palettes where a near-black background has to stay a near-black
/// background and a bright accent has to stay bright, whatever the knob is
/// doing. Oklab was fitted so that equal steps *are* near-equal perceptual
/// steps, and its L is a perceptual lightness, so rotating H at fixed L and C
/// moves only the thing the user asked to move.
///
/// The conversions below are Björn Ottosson's published matrices, transcribed
/// directly. They are twenty lines and exact; a dependency would be worse.
enum Oklch {

    /// Lightness 0…1, chroma (0…~0.33 inside sRGB), hue in degrees 0…360.
    struct LCH: Equatable {
        var l: Double
        var c: Double
        var h: Double
    }

    // MARK: - sRGB transfer function

    static func linearized(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    // MARK: - sRGB ↔ Oklab ↔ OKLCH

    static func lab(fromSRGB rgb: SIMD3<Double>) -> SIMD3<Double> {
        let r = linearized(rgb.x), g = linearized(rgb.y), b = linearized(rgb.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// The inverse. The result is **not** clamped: outside the sRGB gamut it
    /// comes back with components below 0 or above 1, which is exactly what
    /// `maxChroma` needs in order to find the boundary.
    static func srgb(fromLab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(encoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     encoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     encoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    static func lch(fromSRGB rgb: SIMD3<Double>) -> LCH {
        let lab = lab(fromSRGB: rgb)
        let hue = atan2(lab.z, lab.y) * 180 / .pi
        return LCH(l: lab.x, c: (lab.y * lab.y + lab.z * lab.z).squareRoot(),
                   h: hue < 0 ? hue + 360 : hue)
    }

    static func srgb(fromLCH lch: LCH) -> SIMD3<Double> {
        let radians = lch.h * .pi / 180
        return srgb(fromLab: SIMD3(lch.l, lch.c * cos(radians), lch.c * sin(radians)))
    }

    // MARK: - Gamut

    /// Components inside 0…1. The tolerance is there because the whole point of
    /// `maxChroma` is to sit on the boundary, and a boundary found by bisection
    /// is only ever *approximately* on it.
    static func isInGamut(_ rgb: SIMD3<Double>, tolerance: Double = 0) -> Bool {
        rgb.min() >= -tolerance && rgb.max() <= 1 + tolerance
    }

    /// The largest chroma that is still inside sRGB at this lightness and hue.
    ///
    /// Bisection rather than Ottosson's analytic approximation: it is a handful
    /// of microseconds, it is exact to the tolerance asked for, and — the part
    /// that matters — it returns a value that is *known* in gamut rather than
    /// one that is nearly in gamut, so nothing downstream has to clip.
    static func maxChroma(lightness: Double, hue: Double, steps: Int = 24) -> Double {
        guard lightness > 0, lightness < 1 else { return 0 }
        var low = 0.0, high = 0.5
        for _ in 0 ..< steps {
            let mid = (low + high) / 2
            if isInGamut(srgb(fromLCH: LCH(l: lightness, c: mid, h: hue))) { low = mid } else { high = mid }
        }
        return low
    }

    /// The largest chroma that is in gamut at this lightness **at every hue** —
    /// i.e. the chroma a hue knob could hold constant all the way round.
    ///
    /// The projection deliberately does *not* clamp to this (see
    /// `ColorProjection`); it is the reference the near-grey floor is measured
    /// against, and the number the self-test quotes when it reports what the
    /// alternative would have cost.
    ///
    /// Memoised, because a hue sweep asks for the same lightness 128 times in a
    /// row and the answer is a pure function of one number.
    static func safeChroma(lightness: Double) -> Double {
        let key = Int((lightness * 4096).rounded())
        if let cached = cache.read(key) { return cached }
        let quantized = Double(key) / 4096
        var lowest = Double.greatestFiniteMagnitude
        // 1° is fine: the boundary is smooth in hue except at the three primary
        // corners, and a coarser sweep measurably overshoots there.
        for degree in 0 ..< 360 {
            lowest = Swift.min(lowest, maxChroma(lightness: quantized, hue: Double(degree)))
        }
        cache.write(key, lowest)
        return lowest
    }

    /// A hue sweep asks for the same lightness 128 times in a row and the answer
    /// is a pure function of one number, so it is worth not recomputing. Locked
    /// rather than main-thread-only because nothing else in this file cares
    /// which thread it is on and this is two lines.
    private final class ChromaCache: @unchecked Sendable {
        private var entries: [Int: Double] = [:]
        private let lock = NSLock()
        func read(_ key: Int) -> Double? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }
        func write(_ key: Int, _ value: Double) {
            lock.lock(); defer { lock.unlock() }
            entries[key] = value
        }
    }

    private static let cache = ChromaCache()
}

// MARK: - Which axis a knob drives

/// A colour is four numbers and a CC is one. This is the choice of which.
///
/// It is a field on `MIDIBinding` rather than a separate kind of binding, so
/// one CC on `.hue` and three CCs on `.hue`/`.chroma`/`.lightness` of the same
/// parameter are the same mechanism used once and three times — there is no
/// "colour binding" code path.
enum ColorComponent: String, Codable, Hashable, CaseIterable {
    /// Rotates around the hue circle, keeping the base colour's lightness and
    /// chroma. The default, and the one that cannot wreck a composition.
    case hue
    /// 0 at neutral grey, 1 at the most saturated colour that is in gamut at
    /// every hue for this lightness.
    case chroma
    /// Perceptual lightness, 0 (black) to 1 (white).
    case lightness
    /// Straight onto the alpha channel, for the shaders that give it meaning.
    case alpha

    var label: String {
        switch self {
        case .hue:       "Hue (OKLCH)"
        case .chroma:    "Chroma"
        case .lightness: "Lightness"
        case .alpha:     "Alpha"
        }
    }

    /// Short form for the row's pull-down title, next to the CC number.
    var shortLabel: String {
        switch self {
        case .hue: "H"; case .chroma: "C"; case .lightness: "L"; case .alpha: "α"
        }
    }
}

// MARK: - Knob position ↔ colour

/// The projection itself: knob position in, colour out.
///
/// Every component follows the same three steps — decompose the colour that is
/// on screen into OKLCH, overwrite the one axis this binding owns, put chroma
/// back inside the gamut — so the axes compose. Three CCs on the same parameter
/// each rewrite their own coordinate and leave the other two alone, which is
/// what makes the multi-CC case fall out of the single-CC one.
///
/// ## The gamut decision, and the measurements behind it
///
/// At a fixed lightness, sRGB holds far more chroma at some hues than others,
/// so "rotate H, keep L and C" leaves the gamut constantly. Measured over the
/// 128 `color` defaults this repo's shaders declare: **86 of them (67%) leave
/// sRGB somewhere on the circle, for an average of 220° of the 360°.** It is
/// the common case, not an edge case, and it has to be handled.
///
/// Two ways out, both measured over the same 128 colours × 128 knob positions:
///
/// - **Hold C at the minimum achievable across all hues.** Perfectly even
///   perceptual steps (max/min step size 1.00). But it desaturates the palette
///   the instant a knob is touched: mean ΔC of 0.049 *at knob centre*, worst
///   0.228 — `grain-gradient`'s deep ultramarine drops from C 0.306 to 0.079,
///   a 3.9× desaturation of a colour the author chose. And it is not even
///   reliably in gamut: sampling the hue circle at 1° to find that minimum
///   still let 38/16384 sweep colours out, because the true minimum sits
///   between samples.
/// - **Clip C per hue** (this one). **0/16384 out of gamut, at tolerance
///   exactly 0** — in gamut by construction, because the bisection returns a
///   chroma it has *verified* rather than one it extrapolated. Knob centre
///   reproduces the author's colour exactly (mean ΔC 0.0015, and all of that
///   is the near-grey floor below, not clipping). The cost is that step size
///   varies as chroma follows the gamut boundary: median 1.98×, p90 6.4×,
///   worst 25× on the single most saturated colour in the repo.
///
/// So the brief's instinct — clamp, it will only be "slightly duller" — does
/// not survive contact with these palettes: "slightly" is a 3.9× desaturation
/// of the shader's own accent colour, and it buys evenness that HSV needed
/// (median 5.2× step ratio) but that per-hue clipping mostly already has. What
/// actually wrecks a composition is lightness moving, and lightness is exactly
/// constant here — 0.000 swing, against 0.228 median for HSV. Per-hue clipping
/// is also what CSS Color 4 does with an out-of-gamut `oklch()`, so a knob and
/// a browser agree on what the colour is.
///
/// (Re-spacing the 128 positions by arc length would make the steps even *and*
/// keep the vividness. It would also make hue non-linear in knob angle and
/// need a per-colour table to invert for encoders — more machinery than a
/// median 1.98× buys back. Noted, not built.)
enum ColorProjection {

    /// Full travel on `.hue` is one turn of the circle, centred on the base
    /// colour: knob at the middle is the palette exactly as the shader author
    /// wrote it, and either direction departs from it. Being a full turn, the
    /// two ends land on the same hue — that is what a circle does, and it stays
    /// true at 14-bit resolution where shaving a step off the span would not.
    static let hueSpan = 360.0

    /// Below this fraction of the achievable chroma, a hue knob is invisible:
    /// the colour is grey and rotating grey gives grey. A binding on `.hue`
    /// therefore lifts chroma to here rather than sitting there doing nothing.
    ///
    /// 0.22 is measured, not guessed. Across the repo's 128 colours it lifts 3
    /// of them, by at most ΔC 0.0034 at knob centre — below the threshold of a
    /// visible change to the palette, while making the sweep plainly visible.
    /// (0.30 would lift 5 by up to 0.0126, which *is* visible on
    /// `halftone-cmyk`'s paper; 0.10 lifts nothing and leaves the knob dead.)
    static let hueChromaFloor = 0.22

    /// True when this colour has no hue worth rotating — the six colours in
    /// this repo below 22% of their achievable chroma, three of which are pure
    /// black or pure white where no floor can help because the gamut is a
    /// single point there.
    ///
    /// Two things read this. Learn picks `.lightness` instead of `.hue` for
    /// these, because that is the axis with actual range; and the row's menu
    /// says so out loud, so a knob that has been quietly given a chroma floor
    /// is not doing it behind the user's back.
    static func isNearGrey(_ color: SIMD4<Float>) -> Bool {
        let lch = Oklch.lch(fromSRGB: SIMD3(Double(color.x), Double(color.y), Double(color.z)))
        let safe = Oklch.safeChroma(lightness: lch.l)
        return safe <= 1e-6 || lch.c < hueChromaFloor * safe
    }

    /// The axis Learn binds when the parameter is a colour and the user has not
    /// said which. Hue everywhere it has room to move, lightness where it does
    /// not.
    static func defaultComponent(for color: SIMD4<Float>) -> ColorComponent {
        isNearGrey(color) ? .lightness : .hue
    }

    /// `position` is 0…1 along the binding's travel. `current` is what is on
    /// screen; `base` is the parameter's declared default, which is the fixed
    /// reference a hue knob rotates about (using `current` would make the knob
    /// compound its own output and stop being absolute).
    static func apply(_ component: ColorComponent, position: Double,
                      to current: SIMD4<Float>, base: SIMD4<Float>) -> SIMD4<Float> {
        var lch = Oklch.lch(fromSRGB: SIMD3(Double(current.x), Double(current.y), Double(current.z)))
        let baseLCH = Oklch.lch(fromSRGB: SIMD3(Double(base.x), Double(base.y), Double(base.z)))
        var alpha = Double(current.w)
        var floor = 0.0

        switch component {
        case .hue:
            // A grey has no hue of its own to keep, so rotate about the
            // palette's instead of about `atan2(0, 0)`.
            if lch.c < 1e-4 { lch.h = baseLCH.h }
            lch.h = wrapped(baseLCH.h + (position - 0.5) * hueSpan)
            // Measured against the all-hue minimum rather than the ceiling at
            // this particular hue, so a lifted grey sweeps at a *constant*
            // small chroma instead of pulsing.
            floor = hueChromaFloor * Oklch.safeChroma(lightness: lch.l)
        case .chroma:
            lch.c = position * Oklch.maxChroma(lightness: lch.l, hue: lch.h)
            if lch.c < 1e-4 { lch.h = baseLCH.h }
        case .lightness:
            lch.l = position
        case .alpha:
            alpha = position
        }

        // The one gamut rule, and every axis needs it: rotating hue at a chroma
        // this hue cannot hold and pushing lightness towards white at a chroma
        // only mid-lightness can hold are the same mistake. `maxChroma` returns
        // a value it has verified in gamut, so nothing downstream clips.
        let ceiling = Oklch.maxChroma(lightness: lch.l, hue: lch.h)
        lch.c = Swift.min(Swift.max(lch.c, Swift.min(floor, ceiling)), ceiling)
        let rgb = Oklch.srgb(fromLCH: lch)
        return SIMD4<Float>(Float(clamp01(rgb.x)), Float(clamp01(rgb.y)),
                            Float(clamp01(rgb.z)), Float(clamp01(alpha)))
    }

    /// Where a colour already sits along one axis, 0…1. This is what makes an
    /// endless encoder work on a colour: a relative knob needs somewhere to
    /// nudge *from*.
    static func position(of component: ColorComponent, in current: SIMD4<Float>,
                         base: SIMD4<Float>) -> Double {
        let lch = Oklch.lch(fromSRGB: SIMD3(Double(current.x), Double(current.y), Double(current.z)))
        switch component {
        case .hue:
            let baseHue = Oklch.lch(fromSRGB: SIMD3(Double(base.x), Double(base.y), Double(base.z))).h
            var offset = wrapped(lch.h - baseHue)
            if offset > 180 { offset -= 360 }
            return offset / hueSpan + 0.5
        case .chroma:
            let ceiling = Oklch.maxChroma(lightness: lch.l, hue: lch.h)
            return ceiling > 0 ? Swift.min(lch.c / ceiling, 1) : 0
        case .lightness:
            return lch.l
        case .alpha:
            return Double(current.w)
        }
    }

    /// Degrees into 0 ..< 360.
    private static func wrapped(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    private static func clamp01(_ v: Double) -> Double { Swift.min(Swift.max(v, 0), 1) }
}
