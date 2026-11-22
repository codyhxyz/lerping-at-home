import Foundation

public enum ArtifactKind: Int, CaseIterable, Codable, Sendable {
    case mug = 1, keycap = 2, cartridge = 3, cassette = 4, trophy = 5, hourglass = 6, photo = 7
}

public struct ArtifactPhotoMeta: Codable, Equatable, Sendable {
    public var slug: String
    public var title: String
    public var lore: String
    public var capturedAt: String?
    public var location: String?
    public var aspect: Float
    public var imagePath: String
    public var depthPath: String?
    public init(slug: String, title: String, lore: String, capturedAt: String?, location: String?, aspect: Float, imagePath: String, depthPath: String?) {
        self.slug = slug; self.title = title; self.lore = lore
        self.capturedAt = capturedAt; self.location = location; self.aspect = aspect
        self.imagePath = imagePath; self.depthPath = depthPath
    }
}

public struct ArtifactTelemetry: Equatable, Sendable {
    public var level: Int
    public var xpProgress: Float
    public var totalActiveHours: Double
    public var todayMinutes: Int
    public var longestStreak: Int
    public var lateMinutes: Int
    public var switches: Int
    public var breaks: Int
    public var dominantKind: CritterKind
    public var daysTracked: Int
    public var hour: Float
    public var weekday: Int
    public var moonPhase: Float
    public var activeProject: String
    public var customQuests: [String]
    public var photoRelics: [ArtifactPhotoMeta]
    public var isLive: Bool
    public static let fixture = ArtifactTelemetry(level: 14, xpProgress: 0.64, totalActiveHours: 164, todayMinutes: 195, longestStreak: 118, lateMinutes: 42, switches: 29, breaks: 3, dominantKind: .make, daysTracked: 41, hour: 22.5, weekday: 5, moonPhase: 0.52, activeProject: "LERPING@HOME", customQuests: [], photoRelics: [], isLive: false)
}

public struct ArtifactCard: Equatable, Sendable {
    public var kind: ArtifactKind
    public var title: String
    public var subtitle: String
    public var tipHeading: String
    public var loreBody: String
    public var statusLine: String
    public var level: Int
    public var xpProgress: Float
    public var labelPrimary: String
    public var labelSecondary: String
    public var photoRelic: ArtifactPhotoMeta?
}

public enum ArtifactLedger {
    public static func artifactsDirectories() -> [URL] {
        LerpFileLocations.homeDirectories(appending: "Library/Application Support/Lerping/Artifacts")
    }

    public static func loadLive(now: Date = Date()) -> ArtifactTelemetry {
        var ledger = CritterLedger(born: now.timeIntervalSince1970)
        if let url = CritterLedger.url, case .loaded(let loaded) = CritterLedger.read(from: url) { ledger = loaded }
        var photos: [ArtifactPhotoMeta] = [], quests: [String] = []
        var project = "LERPING@HOME"
        var slugs = Set<String>()
        for directory in artifactsDirectories() {
            if let text = try? String(contentsOf: directory.appendingPathComponent("quests.txt"), encoding: .utf8) {
                quests += text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("context.json")),
               let context = try? JSONDecoder().decode([String: String].self, from: data),
               let value = context["project"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { project = value }
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.hasSuffix(".relic.json") {
                guard let data = try? Data(contentsOf: file),
                      var photo = try? JSONDecoder().decode(ArtifactPhotoMeta.self, from: data),
                      photo.aspect.isFinite, photo.aspect > 0 else { continue }
                func resolve(_ path: String) -> String {
                    (path as NSString).isAbsolutePath ? path : directory.appendingPathComponent(path).path
                }
                photo.imagePath = resolve(photo.imagePath)
                guard FileManager.default.fileExists(atPath: photo.imagePath), slugs.insert(photo.slug).inserted else { continue }
                photo.depthPath = photo.depthPath.map(resolve).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                photos.append(photo)
            }
        }
        return telemetry(from: ledger, now: now, activeProject: project, customQuests: quests, photoRelics: photos)
    }

    public static func telemetry(from ledger: CritterLedger, now: Date, activeProject: String = "REAL LIFE", customQuests: [String] = [], photoRelics: [ArtifactPhotoMeta] = [], isLive: Bool = true) -> ArtifactTelemetry {
        let calendar = Calendar.current
        let today = ledger.days[CritterLedger.dayKey(now)] ?? CritterDay()
        let hours = ledger.days.values.reduce(0.0) { $0 + Double(max(0, $1.activeMinutes)) / 60 }
        // archivedGrowth is a weighted daily score, not archived minutes. Preserve
        // its progression credit without misrepresenting it as measured hours.
        let archive = ledger.archivedGrowth.isFinite ? max(0, ledger.archivedGrowth) : 0
        let days = ledger.days.values.filter { $0.activeMinutes > 0 }.count
        let streak = max(0, ledger.days.values.map(\.longestStreak).max() ?? 0)
        let progress = sqrt((hours + Double(days) * 2 + Double(streak) / 60 + archive * 3) / 8)
        let year = calendar.dateInterval(of: .year, for: now)
        let yearFraction = year.map { now.timeIntervalSince($0.start) / $0.duration } ?? 0
        let phase = now.timeIntervalSince1970 / 86400 - 10962.7597222222
        let lunar = phase / 29.53058867
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let dominant = CritterKind.allCases.max { today.minutes($0) < today.minutes($1) } ?? .other
        return ArtifactTelemetry(level: 1 + Int(progress), xpProgress: Float(min(1, max(0, progress == 0 ? yearFraction : progress - floor(progress)))), totalActiveHours: hours, todayMinutes: max(0, today.activeMinutes), longestStreak: streak, lateMinutes: max(0, today.lateMinutes), switches: max(0, today.switches), breaks: max(0, today.breaks), dominantKind: dominant, daysTracked: days, hour: Float(parts.hour ?? 0) + Float(parts.minute ?? 0) / 60, weekday: parts.weekday ?? 1, moonPhase: Float(lunar - floor(lunar)), activeProject: activeProject, customQuests: customQuests, photoRelics: photoRelics, isLive: isLive)
    }

    public static func card(telemetry t: ArtifactTelemetry, requestedRelic: Int, time: Float, seed: Float) -> ArtifactCard {
        let chapter = floor(Double(time.isFinite ? time : 0) / 48) + Double(seed.isFinite ? seed : 0)
        func index(_ count: Int, offset: Int = 0) -> Int {
            let remainder = (floor(chapter) + Double(offset)).truncatingRemainder(dividingBy: Double(count))
            return Int(remainder < 0 ? remainder + Double(count) : remainder)
        }
        var pool: [ArtifactKind] = [.mug, .keycap, .cartridge, .cassette, .trophy, .hourglass]
        if t.isLive {
            if t.lateMinutes >= 20 || t.hour >= 23 || t.hour < 5 { pool += [.mug, .mug] }
            if t.longestStreak >= 60 { pool += [.trophy, .trophy] }
            if t.switches >= 40 { pool += [.hourglass, .hourglass] }
            if t.dominantKind == .make { pool += [.keycap, .cartridge] }
            if t.hour >= 18 || t.weekday == 1 || t.weekday == 7 { pool += [.cassette] }
        }
        if !t.photoRelics.isEmpty { pool += [.photo, .photo] }
        var kind = ArtifactKind(rawValue: requestedRelic) ?? pool[index(pool.count)]
        let missing = kind == .photo && t.photoRelics.isEmpty
        if missing { kind = .mug }
        let photo = kind == .photo ? t.photoRelics[index(t.photoRelics.count)] : nil
        let titles = ["The Coffee Mug", "Command-S", "The Current Project", "Late-Night Playlist", "Personal Best", "The Hourglass", "Photo"]
        let subtitles = ["DESK · STILL HALF FULL", "KEYBOARD · MOST PRESSED", "WORKING TREE · STILL OPEN", "AUDIO · ON REPEAT", "FOCUS STREAK · UNINTERRUPTED", "CONTEXT SWITCHES · TODAY", "CAMERA ROLL · STILL ON THIS MAC"]
        let observations = [
            "You made this two hours ago, drank half, forgot about it, and will still take one cold sip before washing it.",
            "You already saved this file twice in the last four seconds. You are going to press it one more time just in case.",
            "Half of your open files are from a problem you already solved on Tuesday.",
            "You put on music to focus and spent the next twelve minutes reorganizing the queue.",
            "Your longest uninterrupted stretch was \(t.longestStreak) minutes. Nobody saw it, so here is a plastic trophy.",
            "You switched apps \(t.switches) times today, mostly to check whether anything changed in the last ninety seconds."
        ]
        var heading = "NOTE"
        var lore = observations[(kind.rawValue - 1) % observations.count]
        let register = requestedRelic == 0 ? index(3) : ((index(3) + kind.rawValue - 1) % 3)
        if register == 0 {
            if t.lateMinutes > 0 {
                lore = "You've been at this computer for \(t.todayMinutes / 60)h \(t.todayMinutes % 60)m today, switched apps \(t.switches) times, and took \(t.breaks) breaks. \(t.lateMinutes) minutes of that was after midnight."
            } else {
                lore = "You've been at this computer for \(t.todayMinutes / 60)h \(t.todayMinutes % 60)m today, switched apps \(t.switches) times, and took \(t.breaks) breaks. Longest stretch without getting distracted: \(t.longestStreak) minutes."
            }
        } else if register == 2 {
            if !t.customQuests.isEmpty { heading = "REMINDER"; lore = t.customQuests[index(t.customQuests.count)] }
            else if t.hour >= 2 && t.hour < 5 { lore = "It is \(String(format: "%.1f", t.hour)) AM. Whatever you are fixing right now is going to look much simpler after breakfast." }
            else if abs(t.moonPhase - 0.5) < 0.06 { lore = "There is a full moon outside right now. You are looking at a screensaver." }
            else if t.longestStreak >= 120 { lore = "You went \(t.longestStreak) minutes without standing up. Your lower back has noticed." }
        }
        if let photo { lore = photo.lore; heading = "PHOTO" }
        if missing { lore = "No personal photos added yet. Run make artifact-photo to float one here instead of this mug." }
        var primary = "STILL WARM", secondary = "LEVEL \(t.level)"
        switch kind {
        case .cartridge: primary = t.activeProject; secondary = "OPEN TABS · LVL \(t.level)"
        case .cassette: primary = "SIDE A · FOCUS MIX"; secondary = String(format: "%02d:%02d · DAY %d", Int(t.hour), Int(t.hour * 60) % 60, t.weekday)
        case .trophy: primary = "PERSONAL BEST"; secondary = "\(t.longestStreak) MIN"
        case .keycap: primary = "⌘S"; secondary = "JUST IN CASE"
        case .hourglass: primary = "CONTEXT SWITCHES"; secondary = "\(t.switches) TODAY"
        case .photo: primary = photo?.title ?? ""; secondary = photo?.location ?? ""
        case .mug: primary = "HALF FULL"
        }
        return ArtifactCard(kind: kind, title: photo?.title ?? titles[kind.rawValue - 1], subtitle: subtitles[kind.rawValue - 1], tipHeading: heading, loreBody: lore, statusLine: ["Still here...", "Waiting on you...", "Same desktop as before...", "Taking a second..."][index(4)], level: t.level, xpProgress: t.xpProgress, labelPrimary: primary, labelSecondary: secondary, photoRelic: photo)
    }

    public static func selfTest() -> String? {
        let now = Date(timeIntervalSince1970: 1_735_776_000)
        var ledger = CritterLedger(born: now.timeIntervalSince1970)
        let empty = telemetry(from: ledger, now: now)
        guard empty.level == 1, (0...1).contains(empty.xpProgress) else { return "Empty progression" }
        var day = CritterDay(); day.activeMinutes = 240; day.longestStreak = 120
        for n in 0..<90 { ledger.days[CritterLedger.dayKey(now.addingTimeInterval(Double(-n) * 86400))] = day }
        guard telemetry(from: ledger, now: now).level > empty.level else { return "Level progression" }
        let fixture = ArtifactTelemetry.fixture
        let still = card(telemetry: fixture, requestedRelic: 0, time: 0, seed: 0)
        guard still.kind == .mug, still == card(telemetry: fixture, requestedRelic: 0, time: 0, seed: 0) else { return "Fixture determinism" }
        for n in 1...7 {
            guard card(telemetry: fixture, requestedRelic: n, time: 0, seed: 0).kind.rawValue == (n == 7 ? 1 : n) else { return "Forced relic \(n)" }
        }
        var live = fixture; live.isLive = true; live.hour = 3; live.switches = 48; live.longestStreak = 150
        guard card(telemetry: live, requestedRelic: 0, time: 96, seed: 0).loreBody.contains("3.0") else { return "Late lore" }
        let trueLore = card(telemetry: live, requestedRelic: 0, time: 0, seed: 0).loreBody
        guard trueLore.contains("48"), trueLore.contains("150") || trueLore.contains("after midnight") else { return "Telemetry lore" }
        live.customQuests = ["Put the laundry away."]
        guard card(telemetry: live, requestedRelic: 0, time: 96, seed: 0).tipHeading == "REMINDER" else { return "Quest lore" }
        live.photoRelics = [.init(slug: "test", title: "Memory", lore: "Taken last fall.", capturedAt: nil, location: nil, aspect: 1, imagePath: "/fixture.png", depthPath: nil)]
        guard card(telemetry: live, requestedRelic: 7, time: 0, seed: 0).photoRelic == live.photoRelics.first else { return "Photo lore" }
        return nil
    }
}
