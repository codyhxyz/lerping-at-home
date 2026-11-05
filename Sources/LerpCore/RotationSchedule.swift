import Foundation

/// Which look is due right now — a pure function of the wall clock, the
/// eligible set, and nothing else.
///
/// # What this replaces, and why
///
/// The rotation used to be a mutable cursor. Each view shuffled its own copy of
/// the eligible list with `Array.shuffled()`, remembered where it had got to in
/// `lastShuffleSwitch`, and stepped forward when its **own display link**
/// noticed the interval had elapsed. Three separate complaints came out of that
/// one design, and all three were the same mistake — a rotation that lived in
/// per-view mutable state, driven by the render clock:
///
/// 1. **It stopped rotating whenever the view parked.** `park()` takes the
///    display link away, and the display link was the only thing that called
///    the advance. Measured on the real host: `gem-smoke` went up at 19:46:05,
///    the view parked fourteen seconds later, and the next look did not appear
///    until 02:54 the following morning — seven hours, and only because a new
///    session started. The screensaver is parked for most of its life by
///    design, so this was the common case, not the corner.
///
/// 2. **Every session restarted the shuffle.** `legacyScreenSaver` never
///    destroys a view; it builds a *new* one per session and keeps the old
///    ones. Each new view rolled a fresh `shuffled()` and began at its index 0,
///    so the rotation never progressed — it just re-drew. `game-of-life/Day &
///    Night` opened two consecutive days.
///
/// 3. **Retained views disagreed with each other.** Two views alive in one
///    process each held their own order and their own cursor, so the displays
///    showed unrelated looks: at 20:03:03 one view held `gem-smoke` while
///    another held `game-of-life`.
///
/// Making the schedule a pure function of the clock kills all three at once,
/// because there is no longer anything to get out of step. Two views, two
/// processes, or a view that has just been created after eleven hours parked
/// all compute the same answer from the same `Date()` — so a look change is
/// something they *observe*, not something each of them has to remember to do.
///
/// # The shape
///
/// Time is cut into `interval`-sized slots numbered from the reference date.
/// Slot *n* plays position `n mod count` of an order of the rotation's
/// *shaders* that is itself a pure function of the cycle number `n / count` —
/// so the list is re-shuffled once per complete pass, deterministically, and
/// every host re-derives the same pass without anyone persisting it. Each
/// shader then plays its next look, by the same arithmetic one level down; see
/// `rotation(_:at:interval:offset:)` for why airtime is shared that way.
///
/// The shuffle is `LerpSplitMix64`, not `Array.shuffled()`, for the reason
/// spelled out in `Hashing.swift`: the standard library's randomness is salted
/// per process, so two hosts asking the same question would get different
/// answers, which is precisely the failure this file exists to remove.
public enum LerpRotationSchedule {

    /// Whether an interval is one the clock can actually divide by.
    ///
    /// `RotationPreview` passes `.infinity` to mean "hold this one look" and a
    /// hand-edited domain can produce a zero or a negative. All three mean the
    /// same thing here — never advance — and answering them with slot 0 keeps
    /// every caller free of its own special case.
    public static func advances(every interval: TimeInterval) -> Bool {
        interval.isFinite && interval > 0
    }

    /// Which `interval`-sized slot of the timeline `date` falls in.
    ///
    /// Measured on `timeIntervalSinceReferenceDate` — an absolute wall clock,
    /// deliberately not `CACurrentMediaTime()`. The media clock stops while the
    /// machine is asleep and restarts from zero at boot, so it cannot answer
    /// "which look is due" for a host that has just woken up, and two processes
    /// started an hour apart never agree on it.
    public static func slot(at date: Date, interval: TimeInterval) -> Int {
        guard advances(every: interval) else { return 0 }
        let slots = (date.timeIntervalSinceReferenceDate / interval).rounded(.down)
        // A clock this far out is a corrupt date rather than a real one, and
        // `Int(_:)` on an out-of-range Double traps. Slot 0 is the safe answer.
        guard slots.isFinite, slots.magnitude < 9e15 else { return 0 }
        return Int(slots)
    }

    /// When the slot containing `date` ends — the moment the next look is due.
    ///
    /// nil when the interval never advances, which is a caller's signal not to
    /// arm a timer at all rather than to arm one that fires immediately.
    public static func nextBoundary(after date: Date, interval: TimeInterval) -> Date? {
        guard advances(every: interval) else { return nil }
        let boundary = Date(timeIntervalSinceReferenceDate:
                                Double(slot(at: date, interval: interval) + 1) * interval)
        // Floating-point floor can land exactly on `date` at a boundary. A
        // timer armed for the instant that just passed spins; push it a whole
        // interval out instead.
        return boundary > date ? boundary : date.addingTimeInterval(interval)
    }

    /// A deterministic Fisher-Yates over `items`, seeded by the cycle number
    /// (and, for one shader's looks, by that shader's name).
    ///
    /// Seeded by the cycle and not by the set, so that toggling one look in the
    /// gallery does not re-roll the position of everything else mid-pass. The
    /// set change alters which items are in the list; it does not have to alter
    /// the order of the ones that stayed.
    private static func shuffle<Item>(_ items: [Item], cycle: Int, salt: UInt64) -> [Item] {
        var rng = LerpSplitMix64(state: (UInt64(bitPattern: Int64(cycle)) ^ salt) &* LerpSplitMix64.gamma)
        var shuffled = items
        for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(index, rng.below(index + 1))
        }
        return shuffled
    }

    /// The order cycle `cycle` is played in.
    ///
    /// Every item appears exactly once per cycle, and — the part the raw
    /// shuffle does not give you — no item is ever played twice in a row across
    /// a cycle boundary. Two passes are independently shuffled, so roughly one
    /// boundary in `count` would otherwise end and begin on the same item,
    /// leaving it on screen for two full intervals. On a 34-look rotation that
    /// is a ten-minute stretch of one shader every few hours, which is
    /// indistinguishable from the rotation having stopped — the exact report
    /// this whole area of the code exists to stop generating.
    ///
    /// The previous cycle is re-derived rather than remembered, so this stays a
    /// pure function of `(items, cycle)` and two hosts computing it separately
    /// still agree. Looking back exactly one cycle is enough, and it terminates:
    /// the swap below moves position 0, and with more than two items that
    /// cannot change which item is last, so the previous cycle's raw shuffle and
    /// its adjusted order always end on the same one.
    public static func order<Item: Equatable>(_ items: [Item], cycle: Int,
                                              salt: UInt64 = 0) -> [Item] {
        guard items.count > 1 else { return items }
        var shuffled = shuffle(items, cycle: cycle, salt: salt)
        // Two items are excluded because there the swap *does* change the
        // last element, so the reasoning above stops holding. Two alternate on
        // their own well enough.
        guard items.count > 2,
              let previousLast = shuffle(items, cycle: cycle - 1, salt: salt).last,
              shuffled[0] == previousLast
        else { return shuffled }
        shuffled.swapAt(0, 1)
        return shuffled
    }

    /// Which cycle and which position within it `date` lands on.
    ///
    /// `offset` is a manual nudge — the playground's step controls and
    /// `LerpMetalView.advanceShuffle(by:)` — added to the slot number so that
    /// stepping by hand and waiting for the clock go through exactly the same
    /// arithmetic. Integer floor division rather than `Double`, so a negative
    /// offset that walks back past the reference date still lands on a real
    /// position instead of rounding towards zero into someone else's cycle.
    public static func position(in count: Int, at date: Date,
                                interval: TimeInterval, offset: Int = 0) -> (cycle: Int, index: Int) {
        guard count > 0 else { return (0, 0) }
        return split(slot(at: date, interval: interval) &+ offset, by: count)
    }

    /// Floor division and its remainder, for cycle numbers that can be
    /// negative (a manual nudge back past the reference date).
    private static func split(_ step: Int, by count: Int) -> (cycle: Int, index: Int) {
        var cycle = step / count
        if step % count != 0, step < 0 { cycle -= 1 }
        return (cycle, step - cycle * count)
    }

    /// The whole answer: the order to walk and where in it to be.
    ///
    /// # Airtime goes to shaders, then to looks
    ///
    /// The rotation used to be one flat shuffle of looks, so a shader's share
    /// of the screen was however many presets its author had written:
    /// `sierpinski-pyramid`, with seven looks, played three and a half times as
    /// often as `torque`, with two, and writing a preset quietly turned a shader
    /// up. Nobody had chosen that.
    ///
    /// So the schedule has two levels now, and both are still pure functions of
    /// the clock. Slots walk a shuffle of the *shaders* that have anything on —
    /// each one exactly once per cycle, with the same no-repeat-across-the-seam
    /// rule as before. Each time a shader comes round it plays its next look:
    /// visit *n* of a shader is position `n mod looks` of that shader's own
    /// shuffle, which re-rolls once per pass through its looks and is salted by
    /// the shader's name so two shaders with the same look count do not step in
    /// lockstep. A shader's visits are a whole cycle apart, so its looks never
    /// sit back to back either.
    ///
    /// The returned order has one look per shader — the one each will play
    /// this cycle — which is what `ShaderLibrary.firstStep` needs to step past a
    /// look that will not compile: to the next shader, not to a sibling preset
    /// that very likely fails the same way.
    public static func rotation(_ entries: [LerpRotationEntry], at date: Date,
                                interval: TimeInterval,
                                offset: Int = 0) -> (order: [LerpRotationEntry], index: Int) {
        var shaders: [String] = []
        var looks: [String: [LerpRotationEntry]] = [:]
        for entry in entries {
            if looks[entry.shader] == nil { shaders.append(entry.shader) }
            looks[entry.shader, default: []].append(entry)
        }
        let position = position(in: shaders.count, at: date, interval: interval, offset: offset)
        let order = order(shaders, cycle: position.cycle).map { shader -> LerpRotationEntry in
            let own = looks[shader] ?? []
            guard own.count > 1 else { return own[0] }
            let visit = split(position.cycle, by: own.count)
            return order(own, cycle: visit.cycle, salt: LerpHash.fnv1a(shader))[visit.index]
        }
        return (order, position.index)
    }
}
