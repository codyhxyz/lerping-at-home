import Foundation
import os

/// A named playlist in the one ByHost `rotationState` record. Off keys remain
/// `shader`, `shader/Preset` and `shader/*`. The roster lists presets in catalog
/// order. In a closed profile, an empty-string name explicitly admits Defaults;
/// automatic profiles retain the v2 roster, which is used only to resolve renames.
public struct RotationProfile: Equatable, Identifiable, Sendable {
    public enum Admission: String, Sendable {
        case automatic, closed
    }

    public let id: UUID
    public internal(set) var name: String
    public let admission: Admission
    public internal(set) var disabled: Set<LerpRotationEntry>
    public internal(set) var roster: [String: [String]]

    public init(id: UUID = UUID(), name: String, admission: Admission,
                disabled: Set<LerpRotationEntry> = [], roster: [String: [String]] = [:]) {
        self.id = id
        self.name = name
        self.admission = admission
        self.disabled = disabled
        self.roster = roster
    }
}

/// The playground is the sole writer; the saver reads the same ByHost plist
/// directly. Legacy keys are read only in the absence of an authoritative record
/// and removed on the next write. There is no second copy of the active picks.
public struct LerpRotationState: Equatable, Sendable {
    public static let currentVersion = 3
    // Stable across processes and reads, including before the first v3 save.
    public static let libraryProfileID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    public var stored: Bool
    public var version: Int
    public var updatedAt: Date
    public var writer: String
    public private(set) var activeID: UUID
    public private(set) var profiles: [RotationProfile]
    // An unreadable or future record must not play everything or be overwritten.
    fileprivate var isReadable = true

    private var activeIndex: Int { profiles.firstIndex { $0.id == activeID }! }
    public var activeProfile: RotationProfile { profiles[activeIndex] }

    public var disabled: Set<LerpRotationEntry> {
        get { activeProfile.disabled }
        set { profiles[activeIndex].disabled = newValue }
    }
    public var roster: [String: [String]] {
        get { activeProfile.roster }
        set { profiles[activeIndex].roster = newValue }
    }

    public init(stored: Bool = false,
                version: Int = LerpRotationState.currentVersion,
                updatedAt: Date = Date(timeIntervalSince1970: 0),
                writer: String = "",
                disabled: Set<LerpRotationEntry> = [],
                roster: [String: [String]] = [:]) {
        self.init(stored: stored, version: version, updatedAt: updatedAt, writer: writer,
                  activeID: Self.libraryProfileID,
                  profiles: [RotationProfile(id: Self.libraryProfileID, name: "Library Rotation",
                                             admission: .automatic, disabled: disabled, roster: roster)])
    }

    fileprivate init(stored: Bool, version: Int = Self.currentVersion,
                     updatedAt: Date, writer: String, activeID: UUID, profiles: [RotationProfile]) {
        self.stored = stored
        self.version = version
        self.updatedAt = updatedAt
        self.writer = writer
        self.activeID = activeID
        self.profiles = profiles
    }

    public static let empty = LerpRotationState()

    fileprivate static var unreadable: LerpRotationState {
        var state = LerpRotationState(stored: true, updatedAt: Date(timeIntervalSince1970: 0), writer: "",
                                      activeID: libraryProfileID,
                                      profiles: [RotationProfile(id: libraryProfileID, name: "Unavailable",
                                                                 admission: .closed)])
        state.isReadable = false
        return state
    }

    public var summary: String {
        "writer=\(writer.isEmpty ? "-" : writer) "
            + "off=\(disabled.count) shaders=\(roster.count) "
            + "at=\(updatedAt.timeIntervalSince1970 > 0 ? ISO8601DateFormatter().string(from: updatedAt) : "never")"
    }

    // The store executes these mutations as one read/modify/write. Keeping the
    // rules here lets the preview test the same operations without writing ByHost.
    mutating func createProfile(name: String, admission: RotationProfile.Admission,
                                initialLooks: some Sequence<LerpRotationEntry>,
                                catalog: [LerpRotationEntry]) throws -> RotationProfile {
        let name = try Self.validName(name)
        let initial = Set(initialLooks)
        let visible = Set(catalog)
        if let unknown = initial.subtracting(visible).sorted(by: { $0.key < $1.key }).first {
            throw RotationProfileError.unknownLook(unknown.key)
        }
        let profile = RotationProfile(name: name, admission: admission,
                                      disabled: visible.subtracting(initial),
                                      roster: admission == .closed ? LerpRotation.closedRoster(of: catalog)
                                                                   : LerpRotation.roster(of: catalog))
        profiles.append(profile)
        return profile
    }

    mutating func renameProfile(id: UUID, to name: String) throws {
        let index = try profileIndex(id)
        profiles[index].name = try Self.validName(name)
    }

    mutating func deleteProfile(id: UUID) throws {
        let index = try profileIndex(id)
        guard id != activeID else { throw RotationProfileError.deleteActive }
        profiles.remove(at: index)
    }

    mutating func setActiveProfile(id: UUID, catalog: [LerpRotationEntry]) throws {
        let profile = profiles[try profileIndex(id)]
        guard !LerpRotation.selection(discovered: catalog, in: profile).playable.isEmpty else {
            throw RotationProfileError.emptyPlaylist(profile.name)
        }
        activeID = id
    }

    mutating func addExactLook(_ look: LerpRotationEntry, toProfile id: UUID,
                               catalog: [LerpRotationEntry]) throws {
        let index = try profileIndex(id)
        guard !look.isWholeShader, catalog.contains(look) else { throw RotationProfileError.unknownLook(look.key) }
        let previous = profiles[index]
        var selection = LerpRotation.selection(discovered: catalog, in: previous)
        guard !selection.plays(look) else { return }
        let liftingSwitch = selection.isSwitchedOff(look.shader)
        selection.addExactLook(look)
        profiles[index].disabled = selection.disabled
        profiles[index].roster = selection.roster
        if liftingSwitch, previous.admission == .automatic, let presets = previous.roster[look.shader] {
            // The automatic selection reconciles to what's on disk today. Put
            // missing, previously known siblings back as explicit off keys so
            // reconnecting their files doesn't bypass the old whole switch.
            let known = [LerpRotationEntry(shader: look.shader)] + presets.map {
                LerpRotationEntry(shader: look.shader, preset: $0)
            }
            let missing = Set(known).subtracting(catalog)
            profiles[index].disabled.formUnion(missing)
            let present = profiles[index].roster[look.shader] ?? []
            profiles[index].roster[look.shader] = present + presets.filter {
                missing.contains(LerpRotationEntry(shader: look.shader, preset: $0))
            }
        }
    }

    private func profileIndex(_ id: UUID) throws -> Int {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw RotationProfileError.unknownPlaylist }
        return index
    }

    private static func validName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RotationProfileError.emptyName }
        return trimmed
    }
}

enum RotationProfileError: LocalizedError {
    case emptyName, unknownPlaylist, deleteActive, notSaved
    case emptyPlaylist(String), unknownLook(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a name for the rotation playlist."
        case .unknownPlaylist: return "That rotation playlist no longer exists."
        case .deleteActive: return "Switch to another rotation playlist before deleting this one."
        case .notSaved: return "The rotation playlist could not be saved."
        case let .emptyPlaylist(name): return "Add at least one available preset to ‘\(name)’ before switching to it."
        case let .unknownLook(key): return "There is no preset called \(key) any more."
        }
    }
}

public enum LerpRotation {

    /// Same subsystem as every other host, so one `log show` predicate covers
    /// the whole story.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "rotation")

    // MARK: - Keys

    /// The one key that holds the rotation.
    public static let stateKey = "rotationState"

    /// Keys an older build of this project wrote. Read once by a domain with no
    /// `rotationState` in it; deleted on the next write; never written again.
    static let legacyKeys = ["enabledEntries", "knownEntries",
                             "enabledShaders", "knownShaders"]

    // MARK: - Roster

    /// Each shader's presets in declaration order, taken from a
    /// `rotationEntries()` list (which is exactly that order: a shader's
    /// defaults, then its presets as the file declares them).
    ///
    /// A shader with no presets maps to `[]` rather than being absent — the
    /// difference between "this shader is known and has no presets" and "this
    /// shader has never been seen" is the difference between a look that stays
    /// switched off and one that joins the rotation.
    public static func roster(of entries: [LerpRotationEntry]) -> [String: [String]] {
        var roster: [String: [String]] = [:]
        for entry in entries {
            var presets = roster[entry.shader] ?? []
            if let preset = entry.preset, !presets.contains(preset) { presets.append(preset) }
            roster[entry.shader] = presets
        }
        return roster
    }

    /// Which vanished preset names are which appeared ones, under a new name.
    ///
    /// A name in both lists is itself and is not a candidate either way. Of what
    /// is left, a vanished name and an appeared name that sit at the **same
    /// index** in their own shader's declaration list are taken to be the same
    /// look renamed — that is what a rename does to a file, and it is the only
    /// signal a `.metal` comment leaves behind. Whatever is still unpaired after
    /// that is matched up in order, so a rename stays a rename even when a
    /// preset was added or removed in the same edit.
    ///
    /// Deliberately conservative in one direction only: an unpaired *new* name
    /// is treated as new (it joins the rotation), and an unpaired *old* name is
    /// treated as deleted (its opinion is dropped).
    static func renamePairs(from old: [String], to new: [String]) -> [(old: String, new: String)] {
        let kept = Set(old).intersection(new)
        var oldLeft = old.filter { !kept.contains($0) }
        var newLeft = new.filter { !kept.contains($0) }
        guard !oldLeft.isEmpty, !newLeft.isEmpty else { return [] }

        var pairs: [(old: String, new: String)] = []
        // Same position in the file: the overwhelmingly common shape of a rename.
        for index in 0..<min(old.count, new.count) {
            let before = old[index], after = new[index]
            guard let o = oldLeft.firstIndex(of: before), let n = newLeft.firstIndex(of: after)
            else { continue }
            pairs.append((before, after))
            oldLeft.remove(at: o)
            newLeft.remove(at: n)
        }
        // Then whatever is left, in order.
        pairs += zip(oldLeft, newLeft).map { (old: $0, new: $1) }
        return pairs
    }

    static func closedRoster(of entries: [LerpRotationEntry]) -> [String: [String]] {
        var roster: [String: [String]] = [:]
        for entry in entries where !entry.isWholeShader {
            let name = entry.preset ?? ""
            if roster[entry.shader]?.contains(name) != true { roster[entry.shader, default: []].append(name) }
        }
        return roster
    }

    // MARK: - Reading

    /// Reads without writing or reconciling away missing keys. The legacy
    /// `discovered` argument is retained; only selection resolves the catalog.
    public static func read(_ defaults: UserDefaults?,
                            discovered: [LerpRotationEntry]) -> LerpRotationState {
        read(defaults)
    }

    static func read(_ defaults: UserDefaults?) -> LerpRotationState {
        guard let defaults else { return .empty }
        var plist: [String: Any] = [:]
        for key in [stateKey] + legacyKeys.prefix(2) { plist[key] = defaults.object(forKey: key) }
        return stored(plist)
    }

    /// The saver reads the ByHost file by path, not Apple's sandbox defaults.
    public static func read(plist: [String: Any]?,
                            discovered: [LerpRotationEntry]) -> LerpRotationState {
        stored(plist ?? [:])
    }

    static func stored(_ plist: [String: Any]) -> LerpRotationState {
        if let raw = plist[stateKey] {
            guard let record = raw as? [String: Any], let version = record["version"] as? Int else {
                return .unreadable
            }
            let updatedAt = Date(timeIntervalSince1970: record["updatedAt"] as? Double ?? 0)
            let writer = record["writer"] as? String ?? ""
            if version == 2 {
                return LerpRotationState(
                    stored: true, updatedAt: updatedAt, writer: writer,
                    disabled: Set((record["disabled"] as? [String] ?? []).map(LerpRotationEntry.init(key:))),
                    roster: record["roster"] as? [String: [String]] ?? [:])
            }
            if version == LerpRotationState.currentVersion {
                guard let id = (record["activeID"] as? String).flatMap(UUID.init(uuidString:)),
                      let records = record["profiles"] as? [[String: Any]] else { return .unreadable }
                let profiles = records.compactMap { profile -> RotationProfile? in
                    guard let id = (profile["id"] as? String).flatMap(UUID.init(uuidString:)),
                          let name = profile["name"] as? String,
                          let admission = (profile["admission"] as? String).flatMap(RotationProfile.Admission.init(rawValue:)),
                          let disabled = profile["disabled"] as? [String],
                          let roster = profile["roster"] as? [String: [String]] else { return nil }
                    return RotationProfile(id: id, name: name, admission: admission,
                                           disabled: Set(disabled.map(LerpRotationEntry.init(key:))), roster: roster)
                }
                let ids = Set(profiles.map(\.id))
                guard ids.count == records.count, ids.contains(id) else { return .unreadable }
                return LerpRotationState(stored: true, updatedAt: updatedAt, writer: writer,
                                         activeID: id, profiles: profiles)
            }
            if version > 1 { return .unreadable }
        }

        // v1 held enabled entries and their roster. v0 cannot express opinions
        // on individual looks, so it has never been used to widen a selection.
        if let saved = plist[legacyKeys[0]] as? [String] {
            let enabled = Set(saved.map(LerpRotationEntry.init(key:)))
            let known = (plist[legacyKeys[1]] as? [String] ?? saved).map(LerpRotationEntry.init(key:))
            return LerpRotationState(stored: true, writer: "migrated-v1",
                                     disabled: Set(known).subtracting(enabled), roster: roster(of: known))
        }
        return .empty
    }

    /// An automatic profile re-expressed in today's keys: renames carried across,
    /// deleted looks forgotten, genuinely new looks left out of the disabled set
    /// so they join the rotation.
    ///
    /// This only resolves a selection. Reading the plist itself is lossless.
    private static func reconcile(_ profile: RotationProfile,
                                  with discovered: [LerpRotationEntry]) -> RotationProfile {
        let now = roster(of: discovered)
        // Every denial whose look is still on disk, carried across unchanged.
        // This does not consult the roster, and that is the point: a look the
        // user switched off stays off even if the roster has lost the shader it
        // belongs to. The roster's job is to *find renames*, not to decide
        // whether a decision counts.
        //
        // A `shader/*` key is carried the same way, for as long as its shader
        // is on disk at all. It names no single look, so it can never be "the
        // same look under a new name"; it simply goes on covering whatever
        // looks the shader has.
        var disabled = LerpRotationSelection(discovered: discovered,
                                             disabled: profile.disabled).disabled

        let listed = Set(discovered)
        for (shader, presets) in now {
            // Rename detection needs something to align against. A shader with
            // no roster entry is one nobody has catalogued, so its looks are new
            // — except for any the line above already carried, which were named
            // explicitly and are not new to anyone.
            guard let before = profile.roster[shader] else { continue }
            let pairs = renamePairs(from: before, to: presets)
            for pair in pairs {
                guard profile.disabled.contains(LerpRotationEntry(shader: shader, preset: pair.old))
                else { continue }
                disabled.insert(LerpRotationEntry(shader: shader, preset: pair.new))
            }

            // The Defaults look is a rename too, of a kind the roster cannot
            // see. `rotationEntries` stops listing a shader's Defaults once a
            // named preset renders the same look, because the name is the more
            // useful label for it. So a user who switched Defaults off and then
            // saved those values as "Classic" had their bare `shader` key
            // dropped (nothing called that is on disk any more) while
            // "Classic", being new, joined the rotation — the look they had
            // switched off, back on screen under another name.
            //
            // The roster does not say which new name is the stand-in, so every
            // name that appeared since it was written inherits the off: a
            // preset that merely arrived in the same edit sits out with it,
            // which is the side to err on. A preset that was already declared
            // and has since been edited into the defaults keeps its own,
            // explicit, opinion.
            let defaults = LerpRotationEntry(shader: shader)
            if profile.disabled.contains(defaults), !listed.contains(defaults) {
                let renamed = Set(pairs.map(\.new))
                for preset in presets where !before.contains(preset) && !renamed.contains(preset) {
                    disabled.insert(LerpRotationEntry(shader: shader, preset: preset))
                }
            }
        }

        var reconciled = profile
        reconciled.disabled = disabled
        reconciled.roster = now
        return reconciled
    }

    // MARK: - The rotation itself

    /// Nil means no stored choice (the entire library); an empty set is literal.
    public static func enabled(discovered: [LerpRotationEntry],
                               in defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        enabled(discovered: discovered, in: read(defaults))
    }

    public static func enabled(discovered: [LerpRotationEntry],
                               in state: LerpRotationState) -> Set<LerpRotationEntry>? {
        guard state.stored else { return nil }
        return Set(selection(discovered: discovered, in: state).playable)
    }

    public static func selection(discovered: [LerpRotationEntry],
                                 in state: LerpRotationState) -> LerpRotationSelection {
        selection(discovered: discovered, in: state.activeProfile)
    }

    static func selection(discovered: [LerpRotationEntry],
                          in profile: RotationProfile) -> LerpRotationSelection {
        // A rename inference preserves earlier Library choices, but a closed
        // roster must not silently admit a different exact key.
        let resolved = profile.admission == .automatic ? reconcile(profile, with: discovered) : profile
        return LerpRotationSelection(discovered: discovered, disabled: resolved.disabled,
                                     admission: resolved.admission, roster: resolved.roster, profileID: resolved.id)
    }

    public static func playable(discovered: [LerpRotationEntry],
                                in state: LerpRotationState) -> [LerpRotationEntry] {
        selection(discovered: discovered, in: state).playable
    }

    // MARK: - Writing

    /// Persists the active selection without replacing any inactive profiles.
    @discardableResult
    public static func write(_ selection: LerpRotationSelection,
                             writer: String,
                             to defaults: UserDefaults?) -> LerpRotationState {
        var state = read(defaults)
        guard !selection.playable.isEmpty,
              selection.profileID == nil || selection.profileID == state.activeID,
              selection.admission == state.activeProfile.admission else { return state }
        state.disabled = selection.disabled
        state.roster = selection.roster
        return persist(&state, writer: writer, to: defaults) ? state : read(defaults)
    }

    /// Saves the complete record in one defaults assignment. The production
    /// guard applies equally to gallery and named playlist writes.
    static func persist(_ state: inout LerpRotationState, writer: String, to defaults: UserDefaults?) -> Bool {
        guard let defaults, state.isReadable else { return false }
        guard LerpDefaults.mayWriteProduction else {
            log.error("""
                refusing rotation write from an unbundled process (writer \
                '\(writer, privacy: .public)') to the production domain \
                '\(LerpDefaults.productionModule, privacy: .public)'. Set \
                \(LerpDefaults.moduleOverrideVariable, privacy: .public) to a scratch domain.
                """)
            return false
        }
        state.version = LerpRotationState.currentVersion
        state.stored = true
        state.updatedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        state.writer = writer
        defaults.set([
            "version": state.version,
            "updatedAt": state.updatedAt.timeIntervalSince1970,
            "writer": state.writer,
            "activeID": state.activeID.uuidString,
            "profiles": state.profiles.map { profile in
                ["id": profile.id.uuidString, "name": profile.name, "admission": profile.admission.rawValue,
                 "disabled": profile.disabled.map(\.key).sorted(), "roster": profile.roster] as [String: Any]
            },
        ] as [String: Any], forKey: stateKey)
        legacyKeys.forEach(defaults.removeObject(forKey:))
        let saved = defaults.synchronize()
        if saved {
            let summary = state.summary
            log.notice("rotation saved: \(summary, privacy: .public)")
        }
        return saved
    }
}
