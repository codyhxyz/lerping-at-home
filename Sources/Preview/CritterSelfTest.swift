import Foundation
import simd

/// `LerpPreview --critter-selftest`: the critter's ledger and vitals, driven by
/// a synthetic clock. CPU only — nothing is rendered, and the real ledger is
/// never read or written (corrupt-file handling runs in a temp directory).
///
/// Each check prints OK or FAIL; any FAIL exits nonzero.
enum CritterSelfTest {

    static var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    static let base = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2))!

    static func at(day: Int, hour: Double = 0) -> Date {
        calendar.date(byAdding: .day, value: day, to: base)!.addingTimeInterval(hour * 3600)
    }

    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "OK    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func run() {
        samples()
        invariants()
        breaks()
        ranges()
        growth()
        fairness()
        persistence()
        returnsAndRelief()
        moods()
        behavior()
        guard failures == 0 else {
            PreviewMain.fail("critter self-test: \(failures) check\(failures == 1 ? "" : "s") failed")
        }
        print("OK    critter: all checks passed")
    }

    // MARK: Helpers

    /// Fold `minutes` one-minute samples from `start`.
    @discardableResult
    static func use(_ l: inout CritterLedger, from start: Date, minutes: Int, kind: CritterKind = .make,
                    idle: Double = 5, switches: Int = 0, passive: CritterKind? = nil) -> Date {
        var t = start
        for _ in 0..<minutes {
            l.fold(now: t, idleSeconds: idle, locked: false, kind: kind, switches: switches,
                   passive: passive, calendar: calendar)
            t = t.addingTimeInterval(60)
        }
        return t
    }

    @discardableResult
    static func away(_ l: inout CritterLedger, from start: Date, minutes: Int) -> Date {
        var t = start
        for i in 0..<minutes {
            l.fold(now: t, idleSeconds: 120 + Double(i) * 60, locked: false, kind: .other,
                   switches: 0, calendar: calendar)
            t = t.addingTimeInterval(60)
        }
        return t
    }

    static func day(_ minutes: Int, kind: CritterKind = .make, streak: Int? = nil, late: Int = 0,
                    switches: Int = 0, breaks: Int = 0) -> CritterDay {
        var d = CritterDay()
        d.activeMinutes = minutes
        d.kinds[kind.rawValue] = minutes
        d.longestStreak = streak ?? min(minutes, 60)
        d.lateMinutes = late
        d.switches = switches
        d.breaks = breaks
        var left = minutes
        for h in 9..<24 where left > 0 { let m = min(60, left); d.hours[h] = m; left -= m }
        return d
    }

    static func vitals(_ l: CritterLedger, _ now: Date) -> CritterVitals {
        CritterVitals(ledger: l, now: now, calendar: calendar)
    }

    static func f(_ x: Float) -> String { String(format: "%.3f", x) }

    // MARK: 1. Samples

    static func samples() {
        var l = CritterLedger(born: at(day: 0, hour: 9).timeIntervalSince1970)
        let t0 = at(day: 0, hour: 9)
        l.fold(now: t0, idleSeconds: 3, locked: false, kind: .make, switches: 0, calendar: calendar)
        var extra = true
        for gap in [1.0, 30, 44] {
            var m = l
            extra = extra && !m.fold(now: t0.addingTimeInterval(gap), idleSeconds: 3, locked: false,
                                     kind: .make, switches: 2, calendar: calendar)
            extra = extra && m.days.values.map(\.activeMinutes).reduce(0, +) <= 1
        }
        check(extra, "two samples under 60 s apart (1, 30, 44 s) add at most 1 active minute")

        // Six restarts in twenty minutes, each ticking at once and then every
        // 60 s: no more active minutes than minutes elapsed.
        var r = CritterLedger(born: t0.timeIntervalSince1970)
        var t = t0
        for restart in 0..<6 {
            r.fold(now: t, idleSeconds: 3, locked: false, kind: .make, switches: 0, calendar: calendar)
            for _ in 0..<2 {
                t = t.addingTimeInterval(60)
                r.fold(now: t, idleSeconds: 3, locked: false, kind: .make, switches: 0, calendar: calendar)
            }
            t = t.addingTimeInterval(Double(10 + 7 * restart))
        }
        let elapsed = t.timeIntervalSince(t0) / 60
        let counted = r.days.values.map(\.activeMinutes).reduce(0, +)
        check(Double(counted) <= elapsed + 1,
              "restarts do not double-count: \(counted) active min in \(String(format: "%.1f", elapsed)) min")

        var b = l
        use(&b, from: t0.addingTimeInterval(60), minutes: 3)
        let before = b
        let back = b.fold(now: t0.addingTimeInterval(-3600), idleSeconds: 1, locked: false, kind: .play,
                          switches: 9, calendar: calendar)
        check(!back && b == before, "a clock jump back changes nothing")
    }

    // MARK: 2. Invariants

    static func invariants() {
        var l = CritterLedger(born: at(day: 0).timeIntervalSince1970)
        var t = at(day: 1, hour: 0.5)
        t = use(&l, from: t, minutes: 200, kind: .play)                       // 00:30 – 03:50
        t = away(&l, from: t, minutes: 300)
        t = use(&l, from: t, minutes: 90, kind: .make, switches: 1)
        t = use(&l, from: t, minutes: 30, kind: .browse, idle: 400, passive: .play)  // a film
        t = use(&l, from: t, minutes: 20, kind: .chat, idle: 200, passive: .chat)   // a call
        t = away(&l, from: t, minutes: 30)
        t = use(&l, from: t, minutes: 900, kind: .other)                      // 11:40 – 02:40
        var ok = true
        var late = true
        for (_, d) in l.days {
            let h = d.hours.reduce(0, +), k = d.kinds.values.reduce(0, +)
            ok = ok && h == d.activeMinutes && k == d.activeMinutes && d.hours.count == 24
            late = late && d.lateMinutes == d.hours[0..<5].reduce(0, +)
        }
        check(ok, "Σhours == activeMinutes == Σkinds on every day")
        check(late, "lateMinutes == hours[0..<5] on every day")
        let d1 = l.days[CritterLedger.dayKey(at(day: 1), calendar: calendar)] ?? CritterDay()
        check(d1.passiveMinutes == 50 && d1.minutes(.play) == 230 && d1.minutes(.chat) == 20,
              "watched minutes count as use, by the watched kind (passive \(d1.passiveMinutes))")
        let d2 = l.days[CritterLedger.dayKey(at(day: 2), calendar: calendar)] ?? CritterDay()
        let sinceMidnight = Int(t.timeIntervalSince(at(day: 2)) / 60)
        check(d2.longestStreak > 0 && d2.longestStreak <= sinceMidnight + 1,
              "a run across midnight counts only its minutes since midnight (\(d2.longestStreak) ≤ \(sinceMidnight + 1))")
    }

    // MARK: 3. Breaks

    static func breaks() {
        func run(_ minutes: Int, then idle: Int) -> (Int, Int) {
            var l = CritterLedger(born: at(day: 0).timeIntervalSince1970)
            var t = use(&l, from: at(day: 1, hour: 10), minutes: minutes)
            var beforeLast = 0
            for i in 0..<idle {
                if i == idle - 1 { beforeLast = l.days.values.map(\.breaks).reduce(0, +) }
                t = away(&l, from: t, minutes: 1)
            }
            return (beforeLast, l.days.values.map(\.breaks).reduce(0, +))
        }
        let four = run(15, then: 4).1
        let five = run(15, then: 5)
        let short = run(8, then: 10).1
        check(four == 0 && five.0 == 0 && five.1 == 1 && short == 0,
              "a break counts only after a run of 10+ min and 5 idle minutes (4 idle: \(four), 5 idle: \(five.1), 8-min run: \(short))")

        var s = CritterLedger(born: at(day: 0).timeIntervalSince1970)
        let t = use(&s, from: at(day: 1, hour: 10), minutes: 30)
        use(&s, from: t.addingTimeInterval(9 * 60), minutes: 2)   // Mac slept 10 minutes
        check(s.days.values.map(\.breaks).reduce(0, +) == 1, "an unsampled 10-minute gap (sleep) is a break")

        var w = CritterLedger(born: at(day: 0).timeIntervalSince1970)
        var tw = use(&w, from: at(day: 1, hour: 20), minutes: 30)
        tw = use(&w, from: tw, minutes: 90, kind: .browse, idle: 3000, passive: .play)
        check(w.days.values.map(\.breaks).reduce(0, +) == 0 && w.live.streakStart != nil,
              "an hour and a half of film with no input is not a break")
    }

    // MARK: 4. Ranges

    static func inRange(_ v: CritterVitals) -> Bool {
        let unit = [v.health, v.energy, v.joy, v.calm, v.relief, v.bloom, v.makeShare, v.chatShare, v.playShare]
        let all = unit + [v.growth, v.awayDays, v.ageDays, v.hour, v.month, v.identity, v.todayHours, v.todayStreak]
        return all.allSatisfy(\.isFinite) && unit.allSatisfy { $0 >= 0 && $0 <= 1 }
            && v.growth >= 0 && v.awayDays >= 0 && v.ageDays >= 0
            && v.hour >= 0 && v.hour < 24 && v.month >= 1 && v.month <= 12
            && v.identity >= 0 && v.identity < 1
    }

    static func ranges() {
        let now = at(day: 500, hour: 14)
        let empty = CritterLedger(born: now.timeIntervalSince1970)
        check(inRange(vitals(empty, now)), "vitals in range: empty ledger")
        let future = CritterLedger(born: now.addingTimeInterval(5 * 86_400).timeIntervalSince1970)
        let vf = vitals(future, now)
        check(inRange(vf) && vf.growth == 0 && vf.ageDays == 0, "vitals in range: born in the future")
        var d0 = CritterLedger(born: now.addingTimeInterval(-3600).timeIntervalSince1970)
        use(&d0, from: now.addingTimeInterval(-3000), minutes: 40)
        check(inRange(vitals(d0, now)), "vitals in range: day 0")
        var weird = d0
        weird.archivedGrowth = .nan
        weird.days["2026-01-01"] = day(5000, streak: 99_999, late: 4000, switches: 1_000_000)
        check(inRange(vitals(weird, now)), "vitals in range: nonsense numbers in the ledger")

        // 450 days old: good days, then a bad last week.
        let born = calendar.date(byAdding: .day, value: -450, to: calendar.startOfDay(for: now))!
        var old = CritterLedger(born: born.addingTimeInterval(9 * 3600).timeIntervalSince1970)
        for i in 0...450 {
            let date = calendar.date(byAdding: .day, value: i, to: born)!
            old.days[CritterLedger.dayKey(date, calendar: calendar)] =
                i >= 444 ? day(720, kind: .play, streak: 300, late: 150, switches: 400) : day(240)
        }
        var lastWeekOnly = CritterLedger(born: born.timeIntervalSince1970)
        lastWeekOnly.days = old.days.filter { $0.key >= CritterLedger.dayKey(
            calendar.date(byAdding: .day, value: -6, to: now)!, calendar: calendar) }
        let vo = vitals(old, now), vw = vitals(lastWeekOnly, now)
        check(inRange(vo), "vitals in range: 450 days old")
        check(vo.health < 0.5 && abs(vo.health - vw.health) < 1e-4,
              "at 450 days health tracks the last 7 days (\(f(vo.health)) vs \(f(vw.health)) from those days alone)")
        var pruned = old
        pruned.prune(now: now, calendar: calendar)
        let vp = vitals(pruned, now)
        check(inRange(vp) && abs(vp.health - vo.health) < 1e-4 && pruned.days.count <= 121,
              "at 450 days, pruned to \(pruned.days.count) days: same health, in range")
    }

    // MARK: 5. Growth

    static func growth() {
        var l = CritterLedger(born: at(day: 0, hour: 8).timeIntervalSince1970)
        var gs: [Float] = []
        for d in 0..<40 {
            let kinds: [CritterKind] = [.make, .browse, .play, .chat, .other]
            if d % 6 != 5 {
                var t = at(day: d, hour: 9)
                t = use(&l, from: t, minutes: 60 + (d * 37) % 400, kind: kinds[d % 5])
                t = away(&l, from: t, minutes: 20)
                use(&l, from: t, minutes: (d * 53) % 200, kind: kinds[(d + 2) % 5])
            }
            gs.append(vitals(l, at(day: d, hour: 23.98)).growth)
            gs.append(vitals(l, at(day: d + 1, hour: 0.02)).growth)
        }
        check(zip(gs, gs.dropFirst()).allSatisfy { $1 >= $0 - 1e-4 },
              "growth never falls from one day to the next (40 days, \(f(gs.first ?? 0)) → \(f(gs.last ?? 0)))")

        // Pruning: 300 days of mixed use, pruned day by day vs never.
        var full = CritterLedger(born: at(day: 0, hour: 8).timeIntervalSince1970)
        var rolling = full
        var worst: Float = 0
        for d in 0..<300 {
            if d % 4 != 3 {
                let entry = day(30 + (d * 71) % 700, kind: [.make, .play, .browse][d % 3],
                                streak: (d * 13) % 280, late: (d % 7 == 0) ? 90 : 0, switches: d % 50)
                full.days[CritterLedger.dayKey(at(day: d), calendar: calendar)] = entry
                rolling.days[CritterLedger.dayKey(at(day: d), calendar: calendar)] = entry
            }
            let now = at(day: d, hour: 22)
            rolling.prune(now: now, keep: 30, calendar: calendar)
            if d % 25 == 0 || d == 299 {
                worst = max(worst, abs(vitals(full, now).growth - vitals(rolling, now).growth))
            }
        }
        let gFull = vitals(full, at(day: 299, hour: 22)).growth
        check(worst < 1e-3 * max(1, gFull) && rolling.days.count <= 31,
              "pruning never changes growth (worst Δ \(String(format: "%.5f", worst)) of \(f(gFull)), \(rolling.days.count) days kept)")
        let after = vitals(full, at(day: 420, hour: 12)).growth
        check(after > gFull, "growth keeps rising past 400 days (\(f(gFull)) → \(f(after)))")
    }

    // MARK: 6. Fairness

    static func fairness() {
        // A 1 h good day vs a day off.
        let born = at(day: 0, hour: 8).timeIntervalSince1970
        var off = CritterLedger(born: born)
        var hour = off
        hour.days[CritterLedger.dayKey(at(day: 1), calendar: calendar)] = day(60, kind: .make)
        let gOff = vitals(off, at(day: 2, hour: 8)).growth
        let gHour = vitals(hour, at(day: 2, hour: 8)).growth
        check(gHour >= gOff, "an hour of good use grows at least as much as a day off (\(f(gHour)) ≥ \(f(gOff)))")
        off.days = [:]

        // Two 4-hour runs with a half-hour break: coding (editor ↔ terminal
        // every 30 s) vs doomscrolling (browser ↔ video every 10 min).
        func session(_ kinds: [CritterKind], every seconds: Double) -> CritterDay {
            var l = CritterLedger(born: born)
            var counter = CritterSwitchCounter(front: kinds[0], at: at(day: 1, hour: 9).timeIntervalSince1970)
            var t = at(day: 1, hour: 9)
            var i = 0
            for block in 0..<2 {
                for _ in 0..<240 {
                    let next = t.addingTimeInterval(60)
                    var a = t.addingTimeInterval(seconds)
                    while a < next {
                        i += 1
                        counter.activate(kinds[i % kinds.count], at: a.timeIntervalSince1970)
                        a = a.addingTimeInterval(seconds)
                    }
                    counter.settle(at: next.timeIntervalSince1970)
                    if l.fold(now: next, idleSeconds: 4, locked: false, kind: counter.front,
                              switches: counter.pending, calendar: calendar) { counter.clear() }
                    t = next
                }
                if block == 0 { t = away(&l, from: t, minutes: 30) }
            }
            return l.days[CritterLedger.dayKey(at(day: 1), calendar: calendar)] ?? CritterDay()
        }
        let coding = session([.make, .make], every: 30)
        let doom = session([.browse, .play], every: 600)
        let sc = CritterVitals.score(coding), sd = CritterVitals.score(doom)
        check(coding.activeMinutes == doom.activeMinutes && coding.breaks == doom.breaks && coding.switches == 0,
              "coding and doomscroll days: equal hours (\(coding.activeMinutes) min) and breaks (\(coding.breaks)); editor↔terminal is 0 switches")
        check(sc >= sd, "a coding day scores ≥ a doomscroll day of equal hours and breaks (\(f(sc)) vs \(f(sd)))")
        // The critique's case: 8 h of scrolling in 90-minute runs vs 8 h of
        // code in one long run.
        let scroll = day(480, kind: .browse, streak: 90, breaks: 5)
        var deep = day(480, kind: .make, streak: 240, switches: 40, breaks: 1)
        deep.kinds = ["make": 400, "browse": 50, "other": 30]
        check(CritterVitals.score(deep) > CritterVitals.score(scroll),
              "deep work with one long run beats 8 h of scrolling with breaks (\(f(CritterVitals.score(deep))) vs \(f(CritterVitals.score(scroll))))")
        let lateDay = day(480, kind: .make, streak: 90, late: 150, breaks: 4)
        check(CritterVitals.score(lateDay) < CritterVitals.score(deep),
              "late nights cost more than a long run (\(f(CritterVitals.score(lateDay))) < \(f(CritterVitals.score(deep))))")

        // Calm through an hour of editor ↔ terminal, twice a minute.
        var l = CritterLedger(born: born)
        let start = at(day: 1, hour: 14)
        var counter = CritterSwitchCounter(front: .make, at: start.timeIntervalSince1970)
        for m in 1...60 {
            let now = start.addingTimeInterval(Double(m) * 60)
            counter.activate(.make, at: now.timeIntervalSince1970 - 40)
            counter.activate(.make, at: now.timeIntervalSince1970 - 10)
            counter.settle(at: now.timeIntervalSince1970)
            if l.fold(now: now, idleSeconds: 2, locked: false, kind: counter.front,
                      switches: counter.pending, calendar: calendar) { counter.clear() }
        }
        let calm = vitals(l, start.addingTimeInterval(3630)).calm
        check(calm >= 0.7, "an hour of editor↔terminal at 2 switches/min keeps calm ≥ 0.7 (\(f(calm)))")

        var c = CritterSwitchCounter(front: .make, at: 0)
        c.activate(.browse, at: 100); c.activate(.make, at: 103); c.settle(at: 200)
        let blip = c.pending
        c.activate(.browse, at: 300); c.settle(at: 330)
        check(blip == 0 && c.pending == 1, "A→B→A inside 10 s is no switch; a kind held 30 s is one")
    }

    // MARK: 7. Persistence

    static func persistence() {
        let legacy = """
            {"born":1794011763.9,"days":{"2026-11-06":{"activeMinutes":29,"breaks":0,
            "hours":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,27,2,0,0,0,0,0,0],"kinds":{"make":20,"other":7,"browse":2},
            "lateMinutes":0,"longestStreak":26,"switches":76}},"live":{"idleRun":0,"lastActive":1794013299.8,
            "lastStreakMinutes":0,"recentSwitches":[0,4,3],"sampledAt":1794013299.8,"streakStart":1794011763.9},
            "version":1}
            """
        let old = try? JSONDecoder().decode(CritterLedger.self, from: Data(legacy.utf8))
        check(old?.days["2026-11-06"]?.activeMinutes == 29 && old?.born == 1794011763.9
              && old?.live.streakStart == 1794011763.9 && old?.archivedGrowth == 0,
              "a version-1 ledger (no new fields) loads with its values")
        let sparse = #"{"born":5,"days":{"2026-01-02":{"activeMinutes":3,"hours":[1,2]}},"live":{}}"#
        let s = try? JSONDecoder().decode(CritterLedger.self, from: Data(sparse.utf8))
        check(s?.days["2026-01-02"]?.hours.count == 24 && s?.days["2026-01-02"]?.activeMinutes == 3,
              "a ledger missing most keys loads; a short hours list is padded to 24")

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("lerp-critter-selftest-\(getpid())")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let now = at(day: 3, hour: 10)

        if case .fresh(let l) = CritterLedger.openForWriting(at: url, now: now) {
            check(l.born == now.timeIntervalSince1970, "no file: a critter born now")
        } else { check(false, "no file: a critter born now") }

        for (name, junk) in [("truncated JSON", #"{"born": 17940"#), ("a wrong type", #"{"born":"yesterday"}"#)] {
            try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(junk.utf8).write(to: url)
            var ok = false
            if case .quarantined(let fresh, let aside, _) = CritterLedger.openForWriting(at: url, now: now) {
                try? fresh.save(to: url)
                ok = (try? Data(contentsOf: aside)) == Data(junk.utf8)
                    && aside.lastPathComponent.hasPrefix("ledger.corrupt-")
                    && CritterLedger.load(from: url) != nil
            }
            check(ok, "a corrupt ledger (\(name)) is moved aside byte for byte, never overwritten")
        }

        // Cannot move it aside (read-only folder): refuse, leave it alone.
        try? fm.removeItem(at: dir); try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("garbage".utf8).write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let refused: Bool
        if case .refused = CritterLedger.openForWriting(at: url, now: now) { refused = true } else { refused = false }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        check(refused && (try? Data(contentsOf: url)) == Data("garbage".utf8),
              "a corrupt ledger that cannot be moved aside is refused and left as it was")

        // Round trip.
        var l = CritterLedger(born: at(day: 0).timeIntervalSince1970)
        use(&l, from: at(day: 1, hour: 9), minutes: 30, passive: nil)
        l.prune(now: at(day: 200), keep: 30, calendar: calendar)
        try? l.save(to: url)
        check(CritterLedger.load(from: url) == l, "save → load round-trips every field")
    }

    // MARK: 8. Returns and relief

    static func returnsAndRelief() {
        var l = CritterLedger(born: at(day: 0, hour: 8).timeIntervalSince1970)
        use(&l, from: at(day: 1, hour: 10), minutes: 120)
        use(&l, from: at(day: 7, hour: 10), minutes: 30)     // away days 2…6
        let back = vitals(l, at(day: 7, hour: 12))
        let evening = vitals(l, at(day: 7, hour: 21))
        check(back.awayDays >= 5 && evening.awayDays >= 5,
              "the day you come back after 5 days away reads awayDays ≥ 5 all day (\(Int(back.awayDays)), \(Int(evening.awayDays)))")
        use(&l, from: at(day: 8, hour: 10), minutes: 30)
        check(vitals(l, at(day: 8, hour: 12)).awayDays == 0, "used yesterday and today: awayDays 0")

        var r = CritterLedger(born: at(day: 0).timeIntervalSince1970)
        let end = use(&r, from: at(day: 1, hour: 9), minutes: 240)
        let lastSample = end.addingTimeInterval(-60)
        let v = vitals(r, lastSample.addingTimeInterval(180))
        check(v.relief > 0.5, "an open 4 h run, idle 3 min, gives relief \(f(v.relief)) > 0.5")
        var r2 = r
        away(&r2, from: end, minutes: 2)
        check(vitals(r2, end.addingTimeInterval(120)).relief > 0.5, "…and still after two idle samples")
        let fresh = vitals(r, lastSample.addingTimeInterval(20))
        check(fresh.relief == 0, "a run still in use gives no relief")
    }

    // MARK: 9. Moods

    static func moods() {
        let names = ["idle", "hop", "sleep", "pace", "stretch", "butterfly", "sit", "wave",
                     "unwell", "sandcastle", "10", "11"]
        let intended: [Int: (Set<Int>, String)] = [
            1: ([1, 5], "thriving → hopping / butterflies"),
            2: ([2], "burnt out → asleep after an 11-hour day"),
            3: ([2], "night owl → asleep"),
            4: ([3], "scattered → pacing"),
            6: ([4], "finally a break → stretching"),
        ]
        for mood in 1...6 {
            let v = CritterData.demo(mood)
            if mood == 5 {
                check(v.growth < 0.25, "mood 5 (about to hatch) is an egg (growth \(f(v.growth))); the shader idles eggs")
                continue
            }
            let w = CritterData.weights(v)
            let top = w.indices.max { w[$0] < w[$1] }!
            let (want, label) = intended[mood]!
            check(want.contains(top), "mood \(mood) \(label): top weight is \(names[top]) (\(f(w[top])))")
        }
    }

    // MARK: 10. Behaviour (CritterBehavior, the port of the shader's story)

    typealias B = CritterBehavior

    /// critter.metal's parameters, at their declared defaults.
    static func critterParams(act: Int? = nil, drift: Double? = nil, yaw: Double? = nil,
                              pitch: Double? = nil, magnify: Double? = nil) -> LerpParameterValues {
        var v = LerpParameterValues([
            LerpParam(name: "mood", type: .int, min: 0, max: 6, defaultValue: .scalar(0), label: "Mood"),
            LerpParam(name: "clock", type: .float, min: -1, max: 24, defaultValue: .scalar(-1), label: "Hour"),
            LerpParam(name: "drift", type: .float, min: 0, max: 1, defaultValue: .scalar(0.35), label: "Drift"),
            LerpParam(name: "act", type: .int, min: -1, max: 9, defaultValue: .scalar(-1), label: "Activity"),
            LerpParam(name: "yaw", type: .float, min: -180, max: 180, defaultValue: .scalar(0), label: "Turn"),
            LerpParam(name: "pitch", type: .float, min: -35, max: 20, defaultValue: .scalar(0), label: "Tilt"),
            LerpParam(name: "magnify", type: .float, min: -0.7, max: 0.6, defaultValue: .scalar(0), label: "Zoom"),
        ])
        if let act { v.set("act", to: Double(act)) }
        if let drift { v.set("drift", to: drift) }
        if let yaw { v.set("yaw", to: yaw) }
        if let pitch { v.set("pitch", to: pitch) }
        if let magnify { v.set("magnify", to: magnify) }
        return v
    }

    /// Every scalar in a frame, by name.
    static func scalars(_ f: CritterFrame) -> [(String, Float)] {
        var out: [(String, Float)] = [
            ("size", f.size), ("identity", f.identity), ("health", f.health), ("bloom", f.bloom),
            ("ageDays", f.ageDays), ("hatch", f.hatch), ("wobble", f.wobble), ("yaw", f.yaw),
            ("lean", f.lean), ("roll", f.roll), ("squash", f.squash), ("armL", f.armL), ("armR", f.armR),
            ("reach", f.reach), ("sit", f.sit), ("stride", f.stride), ("step", f.step), ("eye", f.eye),
            ("lid", f.lid), ("lidTilt", f.lidTilt), ("happy", f.happy), ("mouth", f.mouth),
            ("mouthO", f.mouthO), ("bags", f.bags), ("droop", f.droop), ("cloud", f.cloud),
            ("cloudDark", f.cloudDark), ("castle", f.castle), ("butterfly", f.butterfly),
            ("butterflyYaw", f.butterflyYaw), ("flap", f.flap), ("camFocal", f.camFocal), ("bend", f.bend),
            ("hour", f.hour), ("night", f.night), ("golden", f.golden), ("k", f.k), ("zzz", f.zzz),
            ("love", f.love), ("glee", f.glee), ("sick", f.sick), ("storm", f.storm), ("flash", f.flash),
            ("sweat", f.sweat), ("bang", f.bang), ("frazzle", f.frazzle), ("dtake", f.dtake), ("time", f.time),
        ]
        let vecs: [(String, SIMD3<Float>)] = [
            ("position", f.position), ("cloudPos", f.cloudPos), ("castlePos", f.castlePos),
            ("butterflyPos", f.butterflyPos), ("camPos", f.camPos), ("camTarget", f.camTarget),
            ("camUp", f.camUp), ("sunDir", f.sunDir), ("moonDir", f.moonDir), ("lightDir", f.lightDir),
            ("sunColor", f.sunColor), ("skyAmbient", f.skyAmbient), ("armDirL", f.armDirL), ("armDirR", f.armDirR),
        ]
        for (n, v) in vecs { out += [(n + ".x", v.x), (n + ".y", v.y), (n + ".z", v.z)] }
        out += [("focus.x", f.focus.x), ("focus.y", f.focus.y)]
        for (i, t) in f.trees.enumerated() { out += [("tree\(i).x", t.x), ("tree\(i).z", t.y), ("tree\(i).size", t.z), ("tree\(i).sink", t.w)] }
        for (i, y) in f.treeBase.enumerated() { out.append(("treeBase\(i)", y)) }
        for (i, r) in f.rocks.enumerated() { out += [("rock\(i).x", r.x), ("rock\(i).z", r.y), ("rock\(i).size", r.z)] }
        for (i, y) in f.rockBase.enumerated() { out.append(("rockBase\(i)", y)) }
        for (i, p) in f.butterflyTrail.enumerated() { out += [("trail\(i).x", p.x), ("trail\(i).y", p.y), ("trail\(i).z", p.z)] }
        return out
    }

    /// What is wrong with a frame, or nil.
    static func problem(_ f: CritterFrame) -> String? {
        for (n, x) in scalars(f) where !x.isFinite { return "\(n) = \(x)" }
        let unit: [(String, Float)] = [
            ("k", f.k), ("zzz", f.zzz), ("love", f.love), ("glee", f.glee), ("sick", f.sick),
            ("storm", f.storm), ("flash", f.flash), ("sweat", f.sweat), ("bang", f.bang), ("frazzle", f.frazzle),
            ("dtake", f.dtake), ("butterfly", f.butterfly), ("cloudDark", f.cloudDark), ("castle", f.castle),
            ("cloud", f.cloud), ("night", f.night), ("golden", f.golden), ("reach", f.reach), ("sit", f.sit),
            ("hatch", f.hatch), ("bags", f.bags), ("droop", f.droop), ("mouthO", f.mouthO), ("health", f.health),
        ]
        for (n, x) in unit where !(x >= 0 && x <= 1.0001) { return "\(n) = \(x) outside 0…1" }
        if !(f.lid >= 0 && f.lid <= 0.85) { return "lid = \(f.lid)" }
        if !(f.happy >= -1 && f.happy <= 1) { return "happy = \(f.happy)" }
        if !(f.eye >= 0 && f.eye <= 1.3) { return "eye = \(f.eye)" }
        if !(f.mouth >= -1 && f.mouth <= 1) { return "mouth = \(f.mouth)" }
        if !(f.squash > 0.6 && f.squash < 1.35) { return "squash = \(f.squash)" }
        if !(f.size >= 0.3 && f.size <= 0.5) { return "size = \(f.size)" }
        if !(f.stage >= 0 && f.stage <= 3 && f.season >= 0 && f.season <= 3) { return "stage/season" }
        if !((0...9).contains(f.act) && (0...9).contains(f.prevAct)) { return "act \(f.act)/\(f.prevAct)" }
        if !(f.hour >= 0 && f.hour < 24) { return "hour = \(f.hour)" }
        if !(f.flap >= 0 && f.flap <= 1.33) { return "flap = \(f.flap)" }
        if f.trees.count != f.treeCount || f.treeBase.count != f.treeCount || !(2...8).contains(f.treeCount) {
            return "trees \(f.trees.count)/\(f.treeCount)"
        }
        for t in f.trees where !(t.w >= 0 && t.w <= 1 && t.z >= 0 && t.z <= 1.05) { return "tree \(t)" }
        if f.rocks.count != 3 || f.rockBase.count != 3 || f.butterflyTrail.count != 5 { return "rocks/trail" }
        for (n, v) in [("sunDir", f.sunDir), ("moonDir", f.moonDir), ("lightDir", f.lightDir), ("camUp", f.camUp),
                       ("armDirL", f.armDirL), ("armDirR", f.armDirR)] where abs(simd_length(v) - 1) > 1e-3 {
            return "\(n) not unit: \(v)"
        }
        let xz = simd_length(SIMD2(f.position.x, f.position.z))
        if xz > 2.5 { return "critter wandered to r = \(xz)" }
        if f.position.y < B.groundHeight(SIMD2(f.position.x, f.position.z), identity: f.identity) - 0.05 {
            return "feet under the ground: \(f.position.y)"
        }
        let camD = simd_length(f.camPos - f.camTarget)
        if !(camD > 1 && camD < 8) { return "camera distance \(camD)" }
        if f.camPos.y < 0.3 { return "camera under the island: \(f.camPos.y)" }
        return nil
    }

    static let poseFields: [(String, (CritterFrame) -> Float)] = [
        ("x", { $0.position.x }), ("y", { $0.position.y }), ("z", { $0.position.z }),
        ("lean", { $0.lean }), ("roll", { $0.roll }), ("squash", { $0.squash }), ("armL", { $0.armL }),
        ("armR", { $0.armR }), ("reach", { $0.reach }), ("sit", { $0.sit }), ("lid", { $0.lid }),
        ("happy", { $0.happy }), ("mouth", { $0.mouth }), ("mouthO", { $0.mouthO }), ("stride", { $0.stride }),
        ("cam.x", { $0.camPos.x }), ("cam.y", { $0.camPos.y }), ("cam.z", { $0.camPos.z }),
    ]

    /// The biggest pose change between two frames (yaw by angle), and which field.
    static func poseJump(_ a: CritterFrame, _ b: CritterFrame) -> (Float, String) {
        var worst: (Float, String) = (0, "")
        for (n, get) in poseFields {
            let d = abs(get(a) - get(b))
            if d > worst.0 { worst = (d, n) }
        }
        var dy = (b.yaw - a.yaw).truncatingRemainder(dividingBy: 2 * .pi)
        if dy > .pi { dy -= 2 * .pi } else if dy < -.pi { dy += 2 * .pi }
        if abs(dy) > worst.0 { worst = (abs(dy), "yaw") }
        return worst
    }

    /// The lowest point of the body ellipsoid, sampled, and the ground under it.
    static func lowestBodyPoint(_ f: CritterFrame) -> (Float, Float) {
        let s = f.size, sq = f.squash, hz = 1 / sqrt(sq)
        let bc = SIMD3<Float>(0, 0.95 * s * sq, 0)
        let r = SIMD3<Float>(1.0 * hz, 0.95 * sq, 0.92 * hz) * s
        var low = SIMD3<Float>(0, 1e5, 0)
        for i in 0...90 {
            let th = Float(i) / 90 * .pi
            for j in 0..<180 {
                let ph = Float(j) / 180 * 2 * .pi
                let p = f.critterWorld(bc + r * SIMD3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph)))
                if p.y < low.y { low = p }
            }
        }
        return (low.y, B.groundHeight(SIMD2(low.x, low.z), identity: f.identity))
    }

    static func behavior() {
        let fixture = CritterVitals.fixture
        let defaults = critterParams()
        var vitalsSet: [(String, CritterVitals)] = [("fixture", fixture)]
        for mood in 1...6 { vitalsSet.append(("mood \(mood)", CritterData.demo(mood))) }
        var hatchling = CritterVitals.fixture; hatchling.growth = 1.2; vitalsSet.append(("baby", hatchling))
        var unborn = CritterVitals(); unborn.unborn = true; vitalsSet.append(("unborn", unborn))
        var winter = CritterVitals.fixture; winter.month = 12; winter.hour = 23.5; winter.ageDays = 40
        vitalsSet.append(("winter night, old", winter))

        // Determinism, and the defaults equal to no parameters at all.
        var same = true
        for (_, v) in vitalsSet {
            for t: Float in [0, 1, 4.2, 37, 500] {
                let a = B.frame(vitals: v, time: t, seed: 0.37, params: defaults)
                same = same && a == B.frame(vitals: v, time: t, seed: 0.37, params: defaults)
                    && a == B.frame(vitals: v, time: t, seed: 0.37, params: nil)
            }
        }
        check(same, "behaviour: same inputs give the same frame (and nil params = the declared defaults)")

        // Finite and in range over a grid.
        let times: [Float] = [0, 0.3, 0.62, 1.0, 1.5, 2.0, 3.9, 5, 17.3, 35.99, 36.0, 37.2, 38.6, 72.5, 200, 1000.7, 3600 * 3 + 0.4]
        let seeds: [Float] = [0, 0.137, 0.5, 0.913, 0.999]
        var bad: String?
        var count = 0
        for (name, v) in vitalsSet {
            for act in -1...9 {
                let p = critterParams(act: act)
                for t in times { for seed in seeds {
                    count += 1
                    if bad == nil, let why = problem(B.frame(vitals: v, time: t, seed: seed, params: p)) {
                        bad = "\(name) act \(act) t \(t) seed \(seed): \(why)"
                    }
                } }
            }
        }
        for (yaw, pitch, mag) in [(-180.0, -35.0, -0.7), (180, 20, 0.6), (90, 0, 0), (0, -35, 0.6)] {
            let p = critterParams(yaw: yaw, pitch: pitch, magnify: mag)
            for t in times {
                count += 1
                if bad == nil, let why = problem(B.frame(vitals: fixture, time: t, seed: 0.4, params: p)) {
                    bad = "turn \(yaw)/\(pitch)/\(mag) t \(t): \(why)"
                }
            }
        }
        check(bad == nil, "behaviour: \(count) frames finite and in range" + (bad.map { " — \($0)" } ?? ""))

        // Chapter edges: the frame either side of 36 s, 72 s, 108 s barely moves.
        var worst: (Float, String) = (0, "")
        var edges = 0
        for (name, v) in vitalsSet where !v.unborn && v.growth >= 0.25 {
            for i in 0..<60 {
                let seed = Float(i) / 60 + 0.004
                for edge: Float in [36, 72, 108] {
                    edges += 1
                    // The step across the edge, less what the activities
                    // themselves move in the steps either side of it.
                    let fr = [-3, -1, 1, 3].map {
                        B.frame(vitals: v, time: edge + Float($0) / 120, seed: seed, params: defaults)
                    }
                    for (n, get) in poseFields + [("yaw", { $0.yaw })] {
                        func d(_ i: Int) -> Float {
                            var x = abs(get(fr[i + 1]) - get(fr[i]))
                            if n == "yaw" { x = x.truncatingRemainder(dividingBy: 2 * .pi); x = min(x, 2 * .pi - x) }
                            return x
                        }
                        let excess = d(1) - max(d(0), d(2))
                        if excess > worst.0 {
                            worst = (excess, "\(name) seed \(f(seed)) at \(Int(edge)) s: \(n) \(fr[0].act)→\(fr[3].act)")
                        }
                    }
                }
            }
        }
        check(worst.0 < 0.02, "behaviour: \(edges) chapter edges: no 1/60 s step across one moves a pose field more "
              + "than the steps beside it (worst excess \(f(worst.0)), \(worst.1))")

        // The blend itself: over 2.5 s, no step bigger than the activities' own motion.
        var blendWorst: (Float, String) = (0, "")
        for i in 0..<12 {
            let seed = Float(i) / 12 + 0.01
            var prev = B.frame(vitals: fixture, time: 36, seed: seed, params: defaults)
            for n in 1...150 {
                let t = 36 + Float(n) / 60
                let cur = B.frame(vitals: fixture, time: t, seed: seed, params: defaults)
                let j = poseJump(prev, cur)
                if j.0 > blendWorst.0 && j.1 != "squash" {   // a hop's landing squash snaps by design
                    blendWorst = (j.0, "seed \(f(seed)) t \(f(t)): \(j.1) \(cur.prevAct)→\(cur.act)")
                }
                prev = cur
            }
        }
        check(blendWorst.0 < 0.25, "behaviour: through a chapter blend the biggest per-frame change is "
              + "\(f(blendWorst.0)) (\(blendWorst.1))")

        // Face-down sleep (a burnt-out week) rests its body on the grass.
        let burnt = CritterData.demo(2)
        var restWorst: Float = 0
        for t: Float in [3, 10, 20.5, 33] { for seed: Float in [0.1, 0.6] {
            let fr = B.frame(vitals: burnt, time: t, seed: seed, params: critterParams(act: B.actSleep))
            let (low, ground) = lowestBodyPoint(fr)
            restWorst = max(restWorst, abs(low - ground))
        } }
        let lying = B.frame(vitals: burnt, time: 10, seed: 0.1, params: critterParams(act: B.actSleep))
        check(restWorst < 0.006 && lying.lean > 0.5,
              "behaviour: face-down sleep (lean \(f(lying.lean))) rests on the ground: lowest body point "
              + "within \(String(format: "%.4f", restWorst)) of it")
        var floatWorst: Float = 1e5
        for act in 0...9 { for t: Float in [5, 12.3, 21.7] {
            let fr = B.frame(vitals: fixture, time: t, seed: 0.3, params: critterParams(act: act))
            let (low, ground) = lowestBodyPoint(fr)
            floatWorst = min(floatWorst, low - ground)
        } }
        check(floatWorst > -0.006, "behaviour: no activity pushes the body into the ground (lowest "
              + "\(String(format: "%.4f", floatWorst)) above it)")

        // The first chapter opens with the double-take: a "!" while it is noticed.
        var takes = 0, bangs = 0
        for i in 0..<40 {
            let seed = Float(i) / 40 + 0.003
            let first = B.frame(vitals: fixture, time: 0, seed: seed, params: defaults)
            guard first.act != B.actSleep else { continue }
            takes += 1
            let at1 = B.frame(vitals: fixture, time: 1.0, seed: seed, params: defaults)
            let at5 = B.frame(vitals: fixture, time: 5.0, seed: seed, params: defaults)
            let later = B.frame(vitals: fixture, time: 37.0, seed: seed, params: defaults)
            if first.dtake == 1 && at1.bang > 0.9 && at5.bang == 0 && at5.dtake == 0
                && later.bang == 0 && later.dtake == 0 { bangs += 1 }
        }
        let asleep = B.frame(vitals: fixture, time: 1, seed: 0.2, params: critterParams(act: B.actSleep))
        let egg = B.frame(vitals: CritterData.demo(5), time: 1, seed: 0.2, params: defaults)
        check(takes > 20 && bangs == takes && asleep.bang == 0 && egg.bang == 0,
              "behaviour: the first chapter's double-take shows \"!\" (\(bangs)/\(takes) seeds; none asleep or in the egg)")

        // Out of the double-take into every activity, without a snap.
        var dtWorst: (Float, String) = (0, "")
        for act in 0...9 where act != B.actSleep { for i in 0..<16 {
            let seed = Float(i) / 16 + 0.02
            let p = critterParams(act: act)
            var prev = B.frame(vitals: fixture, time: 0, seed: seed, params: p)
            for n in 1...300 {
                let cur = B.frame(vitals: fixture, time: Float(n) / 60, seed: seed, params: p)
                let j = poseJump(prev, cur)
                if j.0 > dtWorst.0 && j.1 != "squash" { dtWorst = (j.0, "act \(act) seed \(f(seed)) t \(f(Float(n) / 60)): \(j.1)") }
                prev = cur
            }
        } }
        check(dtWorst.0 < 0.25, "behaviour: the double-take hands over to every activity smoothly (biggest "
              + "per-frame change \(f(dtWorst.0)), \(dtWorst.1))")

        // Pinning the activity.
        var pinned = true
        for act in 0...9 { for t: Float in [0.5, 20, 40, 95] { for seed: Float in [0.2, 0.7] {
            let fr = B.frame(vitals: fixture, time: t, seed: seed, params: critterParams(act: act))
            pinned = pinned && fr.act == act && fr.prevAct == act
        } } }
        let eggPinned = B.frame(vitals: CritterData.demo(5), time: 5, seed: 0.2, params: critterParams(act: B.actHop))
        var eggQuiet = true
        for i in 0..<20 { for t: Float in [0.5, 36.5, 73] {
            let e = B.frame(vitals: CritterData.demo(5), time: t, seed: Float(i) / 20, params: defaults)
            eggQuiet = eggQuiet && e.act == B.actIdle && e.prevAct == B.actIdle && e.castle == 0
                && e.butterfly == 0 && e.cloud == 0 && e.zzz == 0 && e.bang == 0
        } }
        check(eggQuiet, "behaviour: an egg idles in every chapter, with no castle, butterfly, cloud or Zzz")
        check(pinned && eggPinned.act == B.actIdle && eggPinned.stage == 0,
              "behaviour: `act` pins every activity in every chapter (an egg still idles)")

        // Each activity's own signature.
        func at(_ act: Int, _ t: Float = 10, _ v: CritterVitals = fixture) -> CritterFrame {
            B.frame(vitals: v, time: t, seed: 0.42, params: critterParams(act: act))
        }
        let sigs: [(String, Bool)] = [
            ("asleep: zzz", at(B.actSleep).zzz == 1 && at(B.actSleep).eye == 0),
            ("pacing: storm cloud, scribble, sweat", at(B.actPace).cloud > 0.3 && at(B.actPace).cloudDark == 1
                && at(B.actPace).frazzle == 1 && at(B.actPace).sweat == 1),
            ("unwell: rain cloud and sweat", at(B.actSick).sick == 1 && at(B.actSick).cloudDark == 0
                && at(B.actSick).sweat == 1),
            ("building: a castle beside it", at(B.actBuild, 30).castle > 0.9 && at(B.actBuild).castle > 0.3),
            ("chasing: the butterfly", at(B.actChase).butterfly == 1 && at(B.actIdle).butterfly == 0),
            ("waving / stretching: hearts", at(B.actWave).love == 1 && at(B.actStretch).love == 1),
            ("hopping: sparkles on a happy week", at(B.actHop).glee > 0.9),
            ("no sweat when content", at(B.actIdle).sweat == 0 && at(B.actHop).sweat == 0 && at(B.actWave).sweat == 0),
        ]
        let missing = sigs.filter { !$0.1 }.map(\.0)
        check(missing.isEmpty, "behaviour: each activity brings its things" + (missing.isEmpty ? "" : " — not: \(missing)"))

        // Cross-checks against critter.metal, worked by hand for the fixture at
        // t = 5, seed 0 (see the report): chapter 0 draws BUILD (hash11(0) =
        // 0.721 of the squared weights' 5.098 lands in w9), the double-take is
        // over (dtake = 1 − smoothstep(3.4, 4.3, 5) = 0), BUILD's face weight is
        // 0, so the camera sits at the bare azimuth 2π·0.31 + 5·0.02·0.35.
        let x = B.frame(vitals: fixture, time: 5, seed: 0, params: nil)
        let wantCam = SIMD3<Float>(2.5935002, 2.0058287, -1.0662413)
        let wantTarget = SIMD3<Float>(-0.0103949, 0.5455256, 0.0716622)
        let camErr = simd_length(x.camPos - wantCam) + simd_length(x.camTarget - wantTarget)
        check(x.act == B.actBuild && x.stage == 2 && abs(x.size - 0.3595687) < 1e-5 && camErr < 1e-4
              && x.treeCount == 5 && x.night == 0 && x.golden == 0 && x.dtake == 0,
              "behaviour: matches the shader worked by hand at t = 5 (BUILD, s 0.3596, camera "
              + "(\(f(x.camPos.x)), \(f(x.camPos.y)), \(f(x.camPos.z))), error \(String(format: "%.1e", camErr)), 5 trees, day)")

        // The orientation helper composes as critterWorld does.
        var orientErr: Float = 0
        for t: Float in [3, 11, 50] {
            let fr = at(B.actSleep, t, burnt)
            for p in [SIMD3<Float>(0.3, 0.4, -0.2), SIMD3<Float>(-0.1, 0.9, 0.5)] {
                orientErr = max(orientErr, simd_length(fr.critterWorld(p) - (fr.position + fr.critterOrientation.act(p))))
                orientErr = max(orientErr, simd_length(fr.critterLocal(fr.critterWorld(p)) - p))
            }
        }
        check(orientErr < 1e-5, "behaviour: critterOrientation and critterLocal/World agree "
              + "(\(String(format: "%.1e", orientErr)))")

        // Turning by hand swings the camera round what it looks at.
        let turned = B.frame(vitals: fixture, time: 5, seed: 0, params: critterParams(yaw: 90))
        let r0 = simd_length(x.camPos - x.camTarget), r1 = simd_length(turned.camPos - turned.camTarget)
        let zoomed = B.frame(vitals: fixture, time: 5, seed: 0, params: critterParams(magnify: 1 / 2))
        check(abs(r0 - r1) < 1e-4 && simd_length(turned.camPos - x.camPos) > 1
              && abs(simd_length(zoomed.camPos - zoomed.camTarget) - r0 * pow(2, -0.5)) < 1e-4,
              "behaviour: yaw turns the camera round its target, magnify brings it nearer")
    }
}
