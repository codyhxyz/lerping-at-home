import Foundation

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
}
