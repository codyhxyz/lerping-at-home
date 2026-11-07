import Foundation

// The critter's memory of how this Mac has been used, and what that does to it.
//
// Two programs share this file and nothing else:
//
// - **LerpPulse** (Sources/Pulse), a small LaunchAgent, is the only writer. Once
//   a minute it asks the system how long since the last keypress or mouse move,
//   whether the screen is locked, and which app is in front, and folds that
//   minute into today's tally. It keeps per-day totals only: no app names, no
//   window titles, no keystrokes — an app is reduced to one of five kinds the
//   moment it is seen.
// - **CritterData** (the `critter` look's data provider) reads the ledger by
//   path and turns it into `CritterVitals`, the numbers the shader draws.
//
// The saver cannot be the sampler. It only runs while nobody is using the
// machine, inside Apple's sandboxed host, which can read the real home folder
// but write nowhere outside its own container. Measuring how the computer is
// used is a job for something that runs while it is being used.
//
// Everything here is Foundation-only so the agent can be compiled from this one
// file without linking Metal.

public enum CritterKind: String, Codable, CaseIterable, Sendable {
    /// Making things: editors, terminals, design, music and video tools.
    case make
    /// Talking to people: messages, chat, calls.
    case chat
    /// Web browsers — could be anything, so it counts for neither side.
    case browse
    /// Games and entertainment.
    case play
    /// Everything else (Finder, Mail, System Settings…).
    case other
}

/// One local calendar day of use.
public struct CritterDay: Codable, Equatable, Sendable {
    /// Minutes with input in the last 90 s and the screen unlocked.
    public var activeMinutes: Int = 0
    /// Active minutes between midnight and 5 am.
    public var lateMinutes: Int = 0
    /// Longest run of use with no break of 5 minutes or more.
    public var longestStreak: Int = 0
    /// Breaks of 5+ minutes that ended a run of at least 20 minutes.
    public var breaks: Int = 0
    /// Times the frontmost app changed while in use.
    public var switches: Int = 0
    /// Active minutes by kind of app in front.
    public var kinds: [String: Int] = [:]
    /// Active minutes per local hour, 24 entries.
    public var hours: [Int] = Array(repeating: 0, count: 24)

    public init() {}

    public func minutes(_ kind: CritterKind) -> Int { kinds[kind.rawValue] ?? 0 }
}

/// What the sampler knew at its last tick: the run of use in progress and the
/// one before it, so the critter can tell "you just stepped away after four
/// hours" from "you have been gone all afternoon".
public struct CritterLive: Codable, Equatable, Sendable {
    /// Wall-clock time of the last sample.
    public var sampledAt: Double = 0
    /// Start of the run of use in progress, if there is one.
    public var streakStart: Double?
    /// Last moment that run was seen in use.
    public var lastActive: Double?
    /// Consecutive inactive minutes since then.
    public var idleRun: Int = 0
    /// Length in minutes of the last run that ended, and when it ended.
    public var lastStreakMinutes: Int = 0
    public var lastStreakEnded: Double?
    /// App switches in each of the last 60 sampled minutes (newest last), for a
    /// sense of how scattered the last hour was.
    public var recentSwitches: [Int] = []

    public init() {}
}

public struct CritterLedger: Codable, Equatable, Sendable {
    public var version = 1
    /// When the critter was born: the first time the sampler ever ran.
    public var born: Double
    /// Local day ("yyyy-MM-dd") → tally. Days nobody used the Mac are absent.
    public var days: [String: CritterDay] = [:]
    public var live = CritterLive()

    public init(born: Double) { self.born = born }

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

    public static func load(from url: URL) -> CritterLedger? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CritterLedger.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Drop days older than `keep` so the file stays small.
    public mutating func prune(now: Date, keep: Int = 120, calendar: Calendar = .current) {
        guard days.count > keep,
              let cutoff = calendar.date(byAdding: .day, value: -keep, to: now) else { return }
        let oldest = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }
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
    /// Calm, 0…1: falls when the last hour was all app-switching.
    public var calm: Float = 0.8
    /// 0…1, how much the break that started the screensaver was needed: high
    /// right after a long unbroken run of use.
    public var relief: Float = 0
    /// Whole days since the last day with any use (0 = used today).
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
    /// use at all is not in the ledger; callers score it as rest.
    public static func score(_ d: CritterDay) -> Float {
        let hours = Float(d.activeMinutes) / 60
        let screen = 1 - smooth(6, 11, hours)
        let streak = 1 - smooth(90, 210, Float(d.longestStreak))
        let late = 1 - smooth(20, 120, Float(d.lateMinutes))
        let perHour = Float(d.switches) / max(hours, 0.5)
        let scattered = 1 - smooth(45, 130, perHour)
        return 0.35 * screen + 0.25 * streak + 0.25 * late + 0.15 * scattered
    }

    static let restScore: Float = 0.9

    public init(ledger: CritterLedger, now: Date, calendar: Calendar = .current) {
        self.init()
        let born = Date(timeIntervalSince1970: ledger.born)
        ageDays = Float(max(0, now.timeIntervalSince(born)) / 86_400)
        let comps = calendar.dateComponents([.hour, .minute, .month], from: now)
        hour = Float(comps.hour ?? 12) + Float(comps.minute ?? 0) / 60
        month = Float(comps.month ?? 6)
        var h = UInt64(bitPattern: Int64(ledger.born * 1000))
        h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33
        identity = Float(h % 10_000) / 10_000

        let todayKey = CritterLedger.dayKey(now, calendar: calendar)
        let today = ledger.days[todayKey] ?? CritterDay()

        // Every calendar day from birth to today, oldest first.
        var keys: [String] = []
        var cursor = calendar.startOfDay(for: born)
        let end = calendar.startOfDay(for: now)
        while cursor <= end, keys.count < 400 {
            keys.append(CritterLedger.dayKey(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // Growth: each day adds its score, scaled by how much of a day there
        // was to judge. A day off counts as a good one.
        growth = 0
        for key in keys {
            if let d = ledger.days[key] {
                let weight = min(1, Float(d.activeMinutes) / 180)
                growth += Self.score(d) * weight
            } else if key != todayKey {
                growth += Self.restScore
            }
        }

        // Health: the last 7 days, today included, newer days counting more.
        var total: Float = 0, weights: Float = 0
        for (i, key) in keys.suffix(7).reversed().enumerated() {
            let w = pow(0.8, Float(i))
            let s: Float
            if let d = ledger.days[key] {
                // Today has barely started being judged at 9 am; lean it toward
                // neutral until there are a few hours in it.
                s = key == todayKey
                    ? Self.score(d) * min(1, Float(d.activeMinutes) / 240)
                      + 0.75 * (1 - min(1, Float(d.activeMinutes) / 240))
                    : Self.score(d)
            } else {
                s = key == todayKey ? 0.75 : Self.restScore
            }
            total += s * w; weights += w
        }
        health = weights > 0 ? total / weights : 0.8

        // Flowers: good days of the last 14 (days off included).
        let recent = keys.suffix(14)
        let good = recent.filter { key in
            guard let d = ledger.days[key] else { return key != todayKey }
            return Self.score(d) >= 0.7
        }.count
        bloom = recent.isEmpty ? 0 : Float(good) / 14

        // Away: days since the last day with use.
        if let lastUsed = keys.last(where: { (ledger.days[$0]?.activeMinutes ?? 0) > 0 }),
           let idx = keys.lastIndex(of: lastUsed) {
            awayDays = Float(keys.count - 1 - idx)
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
        let yesterday = keys.count >= 2 ? ledger.days[keys[keys.count - 2]] : nil
        let lastNight = Float(today.lateMinutes) + Float(yesterday?.lateMinutes ?? 0) * 0.5
        energy = 1 - 0.6 * Self.smooth(4, 11, todayHours) - 0.35 * Self.smooth(15, 120, lastNight)
        if hour < 5.5 || hour >= 23 { energy = min(energy, 0.25) }
        energy = max(0, energy)

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

        // Relief: the run that ended when the screensaver came on.
        if let ended = ledger.live.lastStreakEnded {
            let since = Float(now.timeIntervalSince1970 - ended) / 60
            relief = Self.smooth(45, 150, Float(ledger.live.lastStreakMinutes))
                   * (1 - Self.smooth(20, 60, since))
        }
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
