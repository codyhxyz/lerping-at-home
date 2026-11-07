import Foundation

// The critter's memory of how this Mac has been used, and what that does to it.
//
// Two programs share this file and nothing else:
//
// - **LerpPulse** (Sources/Pulse), a small LaunchAgent, is the only writer. Once
//   a minute it asks the system how long since the last keypress or mouse move,
//   whether the screen is locked, which app is in front and whether something
//   is being watched or a call is on, and hands that to `CritterLedger.fold`,
//   which folds the minute into today's tally. It keeps per-day totals only: no
//   app names, no window titles, no keystrokes — an app is reduced to one of
//   five kinds the moment it is seen.
// - **CritterData** (the `critter` look's data provider) reads the ledger by
//   path and turns it into `CritterVitals`, the numbers the shader draws.
//
// The saver cannot be the sampler. It only runs while nobody is using the
// machine, inside Apple's sandboxed host, which can read the real home folder
// but write nowhere outside its own container. Measuring how the computer is
// used is a job for something that runs while it is being used.
//
// Everything here is Foundation-only so the agent can be compiled from this one
// file without linking Metal. Everything that turns samples into a ledger, and
// a ledger into vitals, is a pure function here, so `LerpPreview
// --critter-selftest` can drive it with a synthetic clock; LerpPulse keeps only
// the system probes and the timer.

public enum CritterKind: String, Codable, CaseIterable, Sendable {
    /// Making things: editors, terminals, design, music and video tools.
    case make
    /// Talking to people: messages, chat, calls (a running microphone too).
    case chat
    /// Web browsers — could be anything, so it counts for neither side.
    case browse
    /// Games and entertainment.
    case play
    /// Everything else (Finder, Mail, Calendar, System Settings…).
    case other
}

/// One local calendar day of use.
public struct CritterDay: Codable, Equatable, Sendable {
    /// Minutes of use: input in the last 90 s with the screen unlocked, or no
    /// input but something holding the display awake (a film, a call) — see
    /// `passiveMinutes`.
    public var activeMinutes: Int = 0
    /// Active minutes between midnight and 5 am.
    public var lateMinutes: Int = 0
    /// Longest run of use with no break of 5 minutes or more. A run that
    /// started yesterday only counts its minutes since midnight here.
    public var longestStreak: Int = 0
    /// Breaks of 5+ minutes that ended a run of at least 10 minutes.
    public var breaks: Int = 0
    /// Times the *kind* of app in front changed while in use. Moving between
    /// two editors, or glancing at another app for under 10 s, is not one.
    public var switches: Int = 0
    /// Active minutes by kind of app in front (passive minutes by the kind of
    /// app being watched).
    public var kinds: [String: Int] = [:]
    /// Active minutes per local hour, 24 entries.
    public var hours: [Int] = Array(repeating: 0, count: 24)
    /// Of `activeMinutes`, those with no input: watching a film, listening on a
    /// call. Screen time all the same, but not a break.
    public var passiveMinutes: Int = 0

    public init() {}

    // Every field is optional on disk: a ledger written by an older LerpPulse
    // must load, not be replaced by a newborn.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activeMinutes = try c.decodeIfPresent(Int.self, forKey: .activeMinutes) ?? 0
        lateMinutes = try c.decodeIfPresent(Int.self, forKey: .lateMinutes) ?? 0
        longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0
        breaks = try c.decodeIfPresent(Int.self, forKey: .breaks) ?? 0
        switches = try c.decodeIfPresent(Int.self, forKey: .switches) ?? 0
        kinds = try c.decodeIfPresent([String: Int].self, forKey: .kinds) ?? [:]
        let h = try c.decodeIfPresent([Int].self, forKey: .hours) ?? []
        hours = Array((h + Array(repeating: 0, count: 24)).prefix(24))
        passiveMinutes = try c.decodeIfPresent(Int.self, forKey: .passiveMinutes) ?? 0
    }

    public func minutes(_ kind: CritterKind) -> Int { kinds[kind.rawValue] ?? 0 }
}

/// What the sampler knew at its last tick: the run of use in progress and the
/// one before it, so the critter can tell "you just stepped away after four
/// hours" from "you have been gone all afternoon".
public struct CritterLive: Codable, Equatable, Sendable {
    /// Wall-clock time of the last sample that was folded in.
    public var sampledAt: Double = 0
    /// Start of the run of use in progress, if there is one.
    public var streakStart: Double?
    /// Time of the last sample that was in use (input or watching).
    public var lastActive: Double?
    /// The last keypress or mouse move seen, to the second (sample time minus
    /// the HID idle time). The saver starts well inside a minute of it.
    public var lastInput: Double?
    /// Consecutive minutes not in use since then, unsampled minutes included.
    public var idleRun: Int = 0
    /// Length in minutes of the last run that ended, and when it ended.
    public var lastStreakMinutes: Int = 0
    public var lastStreakEnded: Double?
    /// Kind switches in each of the last 60 minutes in use (newest last), for
    /// a sense of how scattered the last hour was.
    public var recentSwitches: [Int] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sampledAt = try c.decodeIfPresent(Double.self, forKey: .sampledAt) ?? 0
        streakStart = try c.decodeIfPresent(Double.self, forKey: .streakStart)
        lastActive = try c.decodeIfPresent(Double.self, forKey: .lastActive)
        lastInput = try c.decodeIfPresent(Double.self, forKey: .lastInput)
        idleRun = try c.decodeIfPresent(Int.self, forKey: .idleRun) ?? 0
        lastStreakMinutes = try c.decodeIfPresent(Int.self, forKey: .lastStreakMinutes) ?? 0
        lastStreakEnded = try c.decodeIfPresent(Double.self, forKey: .lastStreakEnded)
        recentSwitches = try c.decodeIfPresent([Int].self, forKey: .recentSwitches) ?? []
    }
}

public struct CritterLedger: Codable, Equatable, Sendable {
    /// 2: switches count kind changes; passive minutes; growth archive.
    public var version = 2
    /// When the critter was born: the first time the sampler ever ran.
    public var born: Double
    /// Local day ("yyyy-MM-dd") → tally. Days nobody used the Mac are absent
    /// (or present with no active minutes). Only the last 120 are kept.
    public var days: [String: CritterDay] = [:]
    public var live = CritterLive()
    /// Growth already earned by every day from birth through `archivedThrough`
    /// — days pruned from `days`, and the days off between them — so pruning
    /// never changes how big the critter is.
    public var archivedGrowth: Double = 0
    public var archivedThrough: String?
    /// The most recent used day among those pruned, for `awayDays` after a
    /// very long absence.
    public var archivedLastUsed: String?

    public init(born: Double) { self.born = born }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        days = try c.decodeIfPresent([String: CritterDay].self, forKey: .days) ?? [:]
        live = try c.decodeIfPresent(CritterLive.self, forKey: .live) ?? CritterLive()
        archivedGrowth = try c.decodeIfPresent(Double.self, forKey: .archivedGrowth) ?? 0
        archivedThrough = try c.decodeIfPresent(String.self, forKey: .archivedThrough)
        archivedLastUsed = try c.decodeIfPresent(String.self, forKey: .archivedLastUsed)
        if let born = try c.decodeIfPresent(Double.self, forKey: .born) {
            self.born = born
        } else if let first = days.keys.min(), let date = Self.date(forKey: first) {
            self.born = date.timeIntervalSince1970
        } else {
            self.born = Date().timeIntervalSince1970
        }
    }

    // MARK: Where it lives

    /// `~/Library/Application Support/Lerping/Critter/ledger.json` in the real
    /// home, even from inside legacyScreenSaver's container (which can read it).
    public static var url: URL? {
        if let override = ProcessInfo.processInfo.environment["LERP_CRITTER_LEDGER"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: dir))
            .appendingPathComponent("Library/Application Support/Lerping/Critter/ledger.json")
    }

    public enum ReadResult {
        case missing
        case loaded(CritterLedger)
        /// There is a file and it cannot be read as a ledger.
        case unreadable(String)
    }

    public static func read(from url: URL) -> ReadResult {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            return FileManager.default.fileExists(atPath: url.path)
                ? .unreadable(error.localizedDescription) : .missing
        }
        do { return .loaded(try JSONDecoder().decode(CritterLedger.self, from: data)) } catch {
            return .unreadable(String(describing: error))
        }
    }

    /// The ledger at `url`, or nil when there is none or it cannot be read.
    public static func load(from url: URL) -> CritterLedger? {
        if case .loaded(let ledger) = read(from: url) { return ledger }
        return nil
    }

    public enum OpenResult {
        /// The ledger on disk.
        case existing(CritterLedger)
        /// There was none: a critter born now.
        case fresh(CritterLedger)
        /// The file could not be read. It was moved to `movedTo`, untouched,
        /// and a critter born now takes its place.
        case quarantined(CritterLedger, movedTo: URL, reason: String)
        /// The file could not be read and could not be moved aside either.
        /// Nothing may be written to `url` until this changes.
        case refused(String)
    }

    /// What the one writer opens. An unreadable ledger is never overwritten:
    /// it is renamed to `ledger.corrupt-<time>.json` next to itself first, and
    /// if that fails the caller gets `.refused` and must not save.
    public static func openForWriting(at url: URL, now: Date) -> OpenResult {
        switch read(from: url) {
        case .loaded(let ledger):
            return .existing(ledger)
        case .missing:
            return .fresh(CritterLedger(born: now.timeIntervalSince1970))
        case .unreadable(let reason):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            let stem = url.deletingPathExtension().lastPathComponent
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem).corrupt-\(f.string(from: now)).json")
            do {
                guard !FileManager.default.fileExists(atPath: aside.path) else {
                    return .refused("\(reason); \(aside.lastPathComponent) already exists")
                }
                try FileManager.default.moveItem(at: url, to: aside)
            } catch {
                return .refused("\(reason); could not move it aside: \(error.localizedDescription)")
            }
            return .quarantined(CritterLedger(born: now.timeIntervalSince1970), movedTo: aside, reason: reason)
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    // MARK: Days

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Start of the local day named by a `dayKey`.
    public static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func daysBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a),
                                to: calendar.startOfDay(for: b)).day ?? 0
    }

    /// The first day whose growth is not in `archivedGrowth`: the day after
    /// `archivedThrough`, or the day of birth.
    func firstUnarchivedDay(calendar: Calendar) -> Date {
        let bornDay = calendar.startOfDay(for: Date(timeIntervalSince1970: born))
        guard let through = archivedThrough, let d = Self.date(forKey: through, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: d) else { return bornDay }
        return max(bornDay, next)
    }

    /// Drop days older than `keep`, so the file stays small, after adding what
    /// every day before the cutoff earned (days off included) to
    /// `archivedGrowth`. Vitals are the same before and after.
    public mutating func prune(now: Date, keep: Int = 120, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -keep, to: today) else { return }
        var cursor = firstUnarchivedDay(calendar: calendar)
        while cursor < cutoff {
            let key = Self.dayKey(cursor, calendar: calendar)
            archivedGrowth += Double(CritterVitals.pastDayGrowth(days[key]))
            archivedThrough = key
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let cutoffKey = Self.dayKey(cutoff, calendar: calendar)
        for (key, day) in days where key < cutoffKey && day.activeMinutes > 0 {
            if archivedLastUsed.map({ $0 < key }) ?? true { archivedLastUsed = key }
        }
        days = days.filter { $0.key >= cutoffKey }
    }

    // MARK: Folding in a minute

    /// Samples closer together than this were already counted: a restarted
    /// agent ticks at once, and the minute it lands in has been folded.
    public static let minimumSampleGap: Double = 45
    /// No input for this long is not use, unless something is being watched.
    public static let idleAfter: Double = 90
    /// A run must be this long for the pause after it to count as a break.
    public static let breakAfterRun = 10
    /// Minutes not in use that end a run.
    public static let breakMinutes = 5

    /// Fold one sample into the ledger. Returns false when the sample was not
    /// counted (too soon after the last one, or the clock went back) — then the
    /// caller keeps its switch count for the next one.
    ///
    /// - idleSeconds: since the last keyboard/mouse/trackpad event.
    /// - kind: the kind of app in front (`.chat` while on a call).
    /// - switches: kind switches since the last folded sample.
    /// - passive: the kind of app holding the display awake (a film), or
    ///   `.chat` when the microphone is in use; nil when nothing is. A minute
    ///   with no input but `passive` set is screen time, not a break.
    @discardableResult
    public mutating func fold(now: Date, idleSeconds: Double, locked: Bool, kind: CritterKind,
                              switches: Int, passive: CritterKind? = nil,
                              calendar: Calendar = .current) -> Bool {
        let t = now.timeIntervalSince1970
        guard t.isFinite else { return false }
        if live.sampledAt > 0 {
            if t < live.sampledAt { return false }
            if t - live.sampledAt < Self.minimumSampleGap { return false }
        }

        version = max(version, 2)
        let key = Self.dayKey(now, calendar: calendar)
        var day = days[key] ?? CritterDay()
        if day.hours.count != 24 { day.hours = Array((day.hours + Array(repeating: 0, count: 24)).prefix(24)) }

        // Minutes nobody sampled — the Mac was asleep or this agent was not
        // running — were not minutes of use.
        if live.sampledAt > 0 {
            let missed = Int((t - live.sampledAt) / 60) - 1
            if missed > 0 { live.idleRun += missed }
        }

        let idle = idleSeconds.isFinite ? max(0, idleSeconds) : .infinity
        let input = !locked && idle < Self.idleAfter
        let watching = !locked && !input && passive != nil

        if input || watching {
            closeRunIfBreak(&day)
            if live.streakStart == nil { live.streakStart = t }
            live.idleRun = 0
            live.lastActive = t
            if input { live.lastInput = t - idle }
            day.activeMinutes += 1
            if watching { day.passiveMinutes += 1 }
            let hour = min(23, max(0, calendar.component(.hour, from: now)))
            day.hours[hour] += 1
            if hour < 5 { day.lateMinutes += 1 }
            let k = input ? kind : (passive ?? kind)
            day.kinds[k.rawValue, default: 0] += 1
            day.switches += max(0, switches)
            let run = Int((t - (live.streakStart ?? t)) / 60) + 1
            let sinceMidnight = Int(now.timeIntervalSince(calendar.startOfDay(for: now)) / 60) + 1
            day.longestStreak = max(day.longestStreak, min(run, sinceMidnight))
            live.recentSwitches.append(max(0, switches))
            if live.recentSwitches.count > 60 {
                live.recentSwitches.removeFirst(live.recentSwitches.count - 60)
            }
        } else {
            live.idleRun += 1
            closeRunIfBreak(&day)
        }
        live.sampledAt = t
        days[key] = day
        return true
    }

    /// Five minutes not in use end a run; a run of 10+ minutes that ends that
    /// way counts as a break taken, on the day the break is seen.
    private mutating func closeRunIfBreak(_ day: inout CritterDay) {
        guard live.idleRun >= Self.breakMinutes, let start = live.streakStart else { return }
        let end = live.lastActive ?? start
        let minutes = max(1, Int((end - start) / 60) + 1)
        live.lastStreakMinutes = minutes
        live.lastStreakEnded = end
        live.streakStart = nil
        if minutes >= Self.breakAfterRun { day.breaks += 1 }
    }
}

/// Turns app activations into switches worth counting: only a change in the
/// *kind* of app in front, and only once the new kind has stayed in front for
/// 10 s — so A → B → A inside ten seconds is nothing, and editor ↔ terminal
/// is nothing at all. The caller drops activations of apps that are not
/// ordinary windowed apps (launchers, password managers, menu-bar popovers).
public struct CritterSwitchCounter: Sendable {
    public static let settleSeconds: Double = 10

    /// The kind of the app in front now.
    public private(set) var front: CritterKind
    private var frontSince: Double
    private var settled: CritterKind
    /// Switches settled since the last `clear()`.
    public private(set) var pending = 0

    public init(front: CritterKind, at t: Double) {
        self.front = front; frontSince = t; settled = front
    }

    public mutating func activate(_ kind: CritterKind, at t: Double) {
        settle(at: t)
        if kind != front { front = kind; frontSince = t }
    }

    public mutating func settle(at t: Double) {
        if front != settled, t - frontSince >= Self.settleSeconds {
            pending += 1
            settled = front
        }
    }

    public mutating func clear() { pending = 0 }
}

// MARK: - Vitals

/// What the critter is like right now. Every field is derived from a ledger and
/// a moment in time; nothing is remembered between calls.
public struct CritterVitals: Equatable, Sendable {
    /// Continuous life progress: < 0.25 egg, < 3 baby, < 10 child, then grown.
    public var growth: Float = 0
    /// Long-run wellbeing, 0…1: the last week of days, weighted to recent ones.
    public var health: Float = 0.8
    /// Rest, 0…1: drained by today's screen time and by last night's.
    public var energy: Float = 0.8
    /// Cheer, 0…1: breaks taken, things made, people talked to.
    public var joy: Float = 0.7
    /// Calm, 0…1: falls when the last hour was all switching between kinds of
    /// app.
    public var calm: Float = 0.8
    /// 0…1, how much the break that started the screensaver was needed: high
    /// right after a long unbroken run of use.
    public var relief: Float = 0
    /// Whole days away: with no use yet today, days since the last day with
    /// use (1 = used yesterday); once today has use, the days with none
    /// between it and the previous used day (0 = used yesterday too), so a
    /// return after five days away reads 5 for the rest of that day.
    public var awayDays: Float = 0
    /// Days since birth.
    public var ageDays: Float = 0
    /// Share of the last 14 days that were good ones — how many flowers bloom.
    public var bloom: Float = 0
    /// Local hour of day, fractional, when the vitals were taken.
    public var hour: Float = 12
    /// Month 1…12, for the season.
    public var month: Float = 6
    /// Stable per-critter random number in [0, 1): its colours, its island.
    public var identity: Float = 0.5
    /// Today's active hours, longest streak (minutes), and the share of today
    /// spent in each kind of app.
    public var todayHours: Float = 0
    public var todayStreak: Float = 0
    public var makeShare: Float = 0
    public var chatShare: Float = 0
    public var playShare: Float = 0
    /// True when there is no ledger at all — the sampler is not installed.
    public var unborn = false

    public init() {}

    /// The state `LerpPreview` renders (snapshots, gallery stills): a happy
    /// child on an early-afternoon island. Fixed so stills are reproducible.
    public static let fixture: CritterVitals = {
        var v = CritterVitals()
        v.growth = 4.5; v.health = 0.85; v.energy = 0.8; v.joy = 0.8; v.calm = 0.85
        v.ageDays = 9; v.bloom = 0.7; v.hour = 14.5; v.month = 5; v.identity = 0.31
        v.todayHours = 3.2; v.todayStreak = 70; v.makeShare = 0.5; v.chatShare = 0.15
        return v
    }()

    public static func smooth(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// How good a day was for the person at the keyboard, 0…1. A day with no
    /// use at all is scored as rest by the callers (`restScore`).
    ///
    /// Late nights cost the most and a long unbroken run less: four hours deep
    /// in one thing is a better day than four hours of scrolling broken up by
    /// coffee. What the hours went on counts as much as how many there were —
    /// making and talking lift a day, long hours of play and browsing drag it.
    public static func score(_ d: CritterDay) -> Float {
        let hours = Float(d.activeMinutes) / 60
        let screen = 1 - smooth(6, 11, hours)
        let streak = 1 - smooth(120, 300, Float(d.longestStreak))
        let late = 1 - smooth(20, 120, Float(d.lateMinutes))
        let perHour = Float(d.switches) / max(hours, 0.5)
        let scattered = 1 - smooth(45, 130, perHour)
        let active = max(1, Float(d.activeMinutes))
        let lift = Float(d.minutes(.make) + d.minutes(.chat)) / active
        let driftHours = Float(d.minutes(.play) + d.minutes(.browse)) / 60
        let kind = min(1, max(0, 0.5 + 0.5 * lift - 0.5 * smooth(1.5, 5, driftHours)))
        return 0.25 * screen + 0.15 * streak + 0.25 * late + 0.10 * scattered + 0.25 * kind
    }

    /// What a day off scores.
    public static let restScore: Float = 0.9

    /// What a finished day adds to growth. A day's score counts in proportion
    /// to how much of a day there was to judge (full weight from 3 hours); the
    /// rest of it is rest — so an hour's good use grows at least as much as a
    /// day off, and a day off (nil) grows `restScore`.
    public static func pastDayGrowth(_ d: CritterDay?) -> Float {
        guard let d, d.activeMinutes > 0 else { return restScore }
        let w = min(1, Float(d.activeMinutes) / 180)
        return w * score(d) + (1 - w) * restScore
    }

    public init(ledger: CritterLedger, now: Date, calendar: Calendar = .current) {
        self.init()
        let born = Date(timeIntervalSince1970: ledger.born)
        ageDays = Float(max(0, now.timeIntervalSince(born)) / 86_400)
        let comps = calendar.dateComponents([.hour, .minute, .month], from: now)
        hour = Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60
        month = Float(comps.month ?? 6)
        var h = UInt64(bitPattern: Int64(ledger.born.isFinite ? ledger.born * 1000 : 0))
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        identity = Float(h % 10_000) / 10_000

        let todayStart = calendar.startOfDay(for: now)
        let bornDay = calendar.startOfDay(for: born)
        let todayKey = CritterLedger.dayKey(now, calendar: calendar)
        func used(_ key: String) -> CritterDay? {
            guard let d = ledger.days[key], d.activeMinutes > 0 else { return nil }
            return d
        }
        let today = bornDay <= todayStart ? (used(todayKey) ?? CritterDay()) : CritterDay()

        // The last 14 calendar days, today included and none before birth.
        var keys: [String] = []
        for back in (0..<14).reversed() {
            guard let d = calendar.date(byAdding: .day, value: -back, to: todayStart), d >= bornDay
            else { continue }
            keys.append(CritterLedger.dayKey(d, calendar: calendar))
        }

        // Growth: what the archive already earned, then every finished day
        // since — its score, the rest of it rest — then today's score so far.
        var grown = Float(ledger.archivedGrowth.isFinite ? ledger.archivedGrowth : 0)
        let start = ledger.firstUnarchivedDay(calendar: calendar)
        if start < todayStart {
            let span = CritterLedger.daysBetween(start, todayStart, calendar: calendar)
            let startKey = CritterLedger.dayKey(start, calendar: calendar)
            var counted = 0
            for (key, d) in ledger.days where key >= startKey && key < todayKey {
                grown += Self.pastDayGrowth(d); counted += 1
            }
            grown += Self.restScore * Float(max(0, span - counted))
        }
        if today.activeMinutes > 0 {
            grown += min(1, Float(today.activeMinutes) / 180) * Self.score(today)
        }
        growth = grown

        // Health: the last 7 days, today included, newer days counting more.
        var total: Float = 0, weights: Float = 0
        for (i, key) in keys.suffix(7).reversed().enumerated() {
            let w = pow(0.8, Float(i))
            let s: Float
            if let d = used(key) {
                if key == todayKey {
                    // Today has barely started being judged at 9 am; lean it
                    // toward a day off until there are a few hours in it.
                    let k = min(1, Float(d.activeMinutes) / 240)
                    s = Self.score(d) * k + Self.restScore * (1 - k)
                } else {
                    s = Self.score(d)
                }
            } else {
                s = Self.restScore
            }
            total += s * w; weights += w
        }
        health = weights > 0 ? total / weights : 0.8

        // Flowers: good days of the last 14 (days off included, today only
        // once it has been a good one).
        let good = keys.filter { key in
            guard let d = used(key) else { return key != todayKey }
            return Self.score(d) >= 0.7
        }.count
        bloom = Float(good) / 14

        // Away. See `awayDays`.
        let usedKeys = ledger.days.compactMap { $0.value.activeMinutes > 0 ? $0.key : nil }
        let todayUsed = today.activeMinutes > 0
        var prevKey = usedKeys.filter { $0 < todayKey }.max()
        if prevKey == nil, let archived = ledger.archivedLastUsed, archived < todayKey { prevKey = archived }
        if let prevKey, let prev = CritterLedger.date(forKey: prevKey, calendar: calendar) {
            let gap = CritterLedger.daysBetween(prev, todayStart, calendar: calendar)
            awayDays = Float(max(0, todayUsed ? gap - 1 : gap))
        } else if !todayUsed {
            awayDays = Float(max(0, CritterLedger.daysBetween(bornDay, todayStart, calendar: calendar)))
        }

        // Today.
        todayHours = Float(today.activeMinutes) / 60
        todayStreak = Float(today.longestStreak)
        let active = max(1, Float(today.activeMinutes))
        makeShare = Float(today.minutes(.make)) / active
        chatShare = Float(today.minutes(.chat)) / active
        playShare = Float(today.minutes(.play)) / active

        // Energy: today's hours, last night's late use, and the clock itself —
        // at 3 am the critter wants to be asleep whatever kind of day it was.
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart)
            .flatMap { used(CritterLedger.dayKey($0, calendar: calendar)) }
        let lastNight = Float(today.lateMinutes) + Float(yesterday?.lateMinutes ?? 0) * 0.5
        energy = 1 - 0.6 * Self.smooth(4, 11, todayHours) - 0.35 * Self.smooth(15, 120, lastNight)
        if hour < 5.5 || hour >= 23 { energy = min(energy, 0.25) }

        // Calm: switching in the last hour of samples, else today's average.
        let recentSwitches = ledger.live.recentSwitches.reduce(0, +)
        let recentActive = Float(ledger.live.recentSwitches.count)
        let perHour = recentActive >= 15
            ? Float(recentSwitches) * 60 / recentActive
            : Float(today.switches) / max(todayHours, 0.5)
        calm = 1 - Self.smooth(35, 120, perHour)

        // Joy: health underneath, lifted by breaks and by making and talking.
        let breaksPerTwoHours = Float(today.breaks) / max(todayHours / 2, 1)
        joy = 0.45 * health + 0.25 * min(1, breaksPerTwoHours)
            + 0.15 * min(1, makeShare * 1.6) + 0.15 * min(1, chatShare * 4)
        if todayHours < 0.5 { joy = max(joy, 0.6 * health + 0.3) }

        // Relief: the run that ended when the screensaver came on. The saver
        // starts before the sampler has seen five idle minutes, so a run still
        // open with no input for a minute is taken to have ended at its last
        // input.
        let t = now.timeIntervalSince1970
        var run: (minutes: Float, ended: Double)?
        if let start = ledger.live.streakStart,
           let last = ledger.live.lastInput ?? ledger.live.lastActive, t - last >= 60 {
            run = (Float(max(0, last - start)) / 60 + 1, last)
        } else if let ended = ledger.live.lastStreakEnded {
            run = (Float(ledger.live.lastStreakMinutes), ended)
        }
        if let run {
            let since = Float(t - run.ended) / 60
            relief = Self.smooth(45, 150, run.minutes) * (1 - Self.smooth(20, 60, since))
        }

        sanitize()
    }

    /// Every field finite and inside its documented range, whatever the
    /// ledger held.
    mutating func sanitize() {
        func unit(_ x: Float) -> Float { x.isFinite ? min(1, max(0, x)) : 0 }
        func nonNeg(_ x: Float) -> Float { x.isFinite ? max(0, x) : 0 }
        growth = nonNeg(growth)
        health = unit(health); energy = unit(energy); joy = unit(joy); calm = unit(calm)
        relief = unit(relief); bloom = unit(bloom)
        makeShare = unit(makeShare); chatShare = unit(chatShare); playShare = unit(playShare)
        awayDays = nonNeg(awayDays); ageDays = nonNeg(ageDays)
        todayHours = nonNeg(todayHours); todayStreak = nonNeg(todayStreak)
        hour = hour.isFinite ? min(max(hour, 0), 23.99) : 12
        month = month.isFinite ? min(max(month, 1), 12) : 6
        identity = identity.isFinite ? min(max(identity, 0), 0.9999) : 0.5
    }

    public var stageName: String {
        switch growth {
        case ..<0.25: return "egg"
        case ..<3: return "baby"
        case ..<10: return "child"
        default: return "grown"
        }
    }

    public var summary: String {
        func pct(_ x: Float) -> String { "\(Int((x * 100).rounded()))%" }
        return """
            stage \(stageName) (growth \(String(format: "%.2f", growth)), \
            \(String(format: "%.1f", ageDays)) days old)
            health \(pct(health))  energy \(pct(energy))  joy \(pct(joy))  \
            calm \(pct(calm))  relief \(pct(relief))  flowers \(pct(bloom))
            today \(String(format: "%.1f", todayHours)) h, longest run \(Int(todayStreak)) min; \
            make \(pct(makeShare)) chat \(pct(chatShare)) play \(pct(playShare)); \
            away \(Int(awayDays)) d
            """
    }
}
