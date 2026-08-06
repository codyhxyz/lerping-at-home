import Foundation

/// Everything the shuffle rotation persists, in one place, for every host.
///
/// This used to be written twice: `Settings.savedRotation` in the saver and
/// `RotationStore.load` in the playground, each a hand transcription of the
/// other. They agreed the day they were written. This file exists so that the
/// question "is this look in the rotation?" has exactly one answer, computed by
/// exactly one function, wherever it is asked.
///
/// # What is stored, and why it is the *off* set
///
/// The old schema stored `enabledEntries` — the looks that are in — beside
/// `knownEntries`, the roster of everything that existed at save time. Anything
/// missing from the roster counted as new and joined automatically, which is the
/// behaviour you want for a shader someone just dropped in.
///
/// The trouble is that a *renamed* preset is indistinguishable from a new one
/// under that scheme, and it is worse than merely ambiguous: renaming
/// `SineWave` to `Sine Wave` retires the old key (so it falls out of
/// `enabledEntries`) and mints a new one (so it is not in `knownEntries` and
/// joins). A look the user deliberately switched off comes back on, silently,
/// because somebody edited a comment. That has destroyed a real selection twice.
///
/// So this schema stores the **disabled** set instead. It is the smaller list,
/// it is the only thing the user has actually expressed an opinion *about*, and
/// it does not have to be rewritten every time the library grows. "Not
/// mentioned" means in, which is what makes a genuinely new look join without a
/// roster entry having to say so.
///
/// # Telling a rename from a new look
///
/// The roster is still kept, but it now records each shader's presets **in
/// declaration order** rather than as a flat set of keys. That is enough to
/// align the old list against the new one: a preset name present in both is
/// itself; a name that vanished and a name that appeared *at the same position*
/// are the same look under a new name, and the disabled flag travels with it. A
/// new name with no vanished partner is genuinely new and joins the rotation.
/// See `renamePairs(from:to:)`.
///
/// # Why there is a revision number
///
/// Two processes write this: the screensaver's Options… sheet and the
/// playground's rotation window. Neither used to know the other existed, so a
/// sheet opened before a click in the playground would, on OK, write back the
/// selection it had read minutes earlier and quietly undo it. Every write now
/// carries a monotonic `revision`; a writer whose base revision is behind the
/// live one does not get to blanket-overwrite. It contributes only the entries
/// it actually toggled, three-way merged onto whatever landed in the meantime.
/// A stale writer loses everything it did not touch.
public struct LerpRotationState: Equatable, Sendable {

    /// Schema version of the `rotationState` dictionary. Bumped when the shape
    /// changes; older shapes are migrated in `LerpRotation.read`.
    public static let currentVersion = 2

    /// Whether anything was ever saved. False only for `.empty`, and the
    /// difference matters: "no opinions" and "no rotation has ever been stored"
    /// both light every look up, but only the second one is reported to callers
    /// as nil — which is the answer `LerpMetalView.Config.rotation` reads as
    /// "every entry", and the answer a fresh install has always given.
    public var stored: Bool
    public var version: Int
    /// Monotonic, bumped once per write. `0` means "migrated from an older
    /// schema and never written since", so the first real write is `1`.
    public var revision: Int
    public var updatedAt: Date
    /// Which host wrote this last. Diagnostics only; nothing branches on it.
    public var writer: String
    /// The looks the user has switched off. Anything not in here is in the
    /// rotation, including looks nothing has ever heard of.
    public var disabled: Set<LerpRotationEntry>
    /// Shader name → its declared preset names, in declaration order. The
    /// defaults look is implicit: every shader in this map has one.
    public var roster: [String: [String]]

    public init(stored: Bool = false,
                version: Int = LerpRotationState.currentVersion,
                revision: Int = 0,
                updatedAt: Date = Date(timeIntervalSince1970: 0),
                writer: String = "",
                disabled: Set<LerpRotationEntry> = [],
                roster: [String: [String]] = [:]) {
        self.stored = stored
        self.version = version
        self.revision = revision
        self.updatedAt = updatedAt
        self.writer = writer
        self.disabled = disabled
        self.roster = roster
    }

    /// Nothing has ever been saved: no opinions, no roster, so every look is in.
    public static let empty = LerpRotationState()

    /// One line for the log. The revision and the writer are the two facts that
    /// make "who turned this back on?" answerable next time.
    public var summary: String {
        "rev=\(revision) writer=\(writer.isEmpty ? "-" : writer) "
            + "off=\(disabled.count) shaders=\(roster.count) "
            + "at=\(updatedAt.timeIntervalSince1970 > 0 ? ISO8601DateFormatter().string(from: updatedAt) : "never")"
    }
}

/// Reading and writing `LerpRotationState`, and the policy that turns it into
/// the list the shuffle walks.
public enum LerpRotation {

    // MARK: - Keys

    /// The versioned state. Everything below it is legacy.
    public static let stateKey = "rotationState"
    /// v1: the looks that are in, plus the roster of everything that existed.
    /// Still written, so a downgrade to an older build finds a sane rotation.
    public static let enabledEntriesKey = "enabledEntries"
    public static let knownEntriesKey = "knownEntries"
    /// v0: the same two, before the rotation counted presets — shader names only.
    public static let enabledShadersKey = "enabledShaders"
    public static let knownShadersKey = "knownShaders"

    /// Every key this file will ever touch.
    public static let allKeys = [stateKey, enabledEntriesKey, knownEntriesKey,
                                 enabledShadersKey, knownShadersKey]

    // MARK: - Not being the only writer

    /// A digest of the v1 keys exactly as the last v2 write left them, stored
    /// inside the v2 state.
    ///
    /// Both are written together, every time. So if the v1 keys are present and
    /// *do not* match this, somebody wrote them who did not write the v2 state —
    /// an older build of the saver, or a `defaults write` by hand — and their
    /// version is the newer one. Without this the v2 state would silently win
    /// forever and a downgrade-then-upgrade would quietly restore a rotation the
    /// user had changed in between.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds its hasher per process, so
    /// `hashValue` is not the same number twice and would make every read
    /// distrust every write.
    static func digest(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in parts.joined(separator: "\u{0}").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// The digest of whatever the v1 keys hold right now, or nil when they are
    /// not there at all — in which case there is nothing to disagree with.
    static func legacyDigest(_ defaults: UserDefaults) -> String? {
        guard let enabled = defaults.stringArray(forKey: enabledEntriesKey) else { return nil }
        return digest(enabled + ["\u{1}"] + (defaults.stringArray(forKey: knownEntriesKey) ?? []))
    }

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
    /// treated as deleted (its opinion is dropped). Both are the pre-existing
    /// behaviour; the pairs are the only thing this adds.
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

    // MARK: - Reading

    /// The saved state, migrated forward from whatever schema is on disk and
    /// re-expressed against the looks that exist **now**.
    ///
    /// Never writes. Every host calls this, including ones that will never save,
    /// so it has to be free of side effects: a screensaver reading its rotation
    /// must not be able to change it.
    ///
    /// - `discovered`: every look on disk, in `rotationEntries()` order.
    public static func read(_ defaults: UserDefaults?,
                            discovered: [LerpRotationEntry]) -> LerpRotationState {
        guard let defaults else { return .empty }
        return reconcile(stored(defaults, discovered: discovered), with: discovered)
    }

    /// The state exactly as persisted, migrated to the current shape but *not*
    /// yet mapped onto what is on disk. Split out so `reconcile` can be tested
    /// against a state that was never stored.
    static func stored(_ defaults: UserDefaults,
                       discovered: [LerpRotationEntry]) -> LerpRotationState {
        if let dictionary = defaults.dictionary(forKey: stateKey),
           let version = dictionary["version"] as? Int, version >= 2,
           // …unless somebody has written the v1 keys since. See `legacyDigest`.
           legacyDigest(defaults).map({ $0 == dictionary["legacy"] as? String }) ?? true {
            return LerpRotationState(
                stored: true,
                version: version,
                revision: dictionary["revision"] as? Int ?? 0,
                updatedAt: Date(timeIntervalSince1970: dictionary["updatedAt"] as? Double ?? 0),
                writer: dictionary["writer"] as? String ?? "",
                disabled: Set((dictionary["disabled"] as? [String] ?? []).map(LerpRotationEntry.init(key:))),
                roster: dictionary["roster"] as? [String: [String]] ?? [:])
        }

        // v1 — `enabledEntries` names what is in, `knownEntries` the roster it
        // was chosen from. Everything in the roster and not in the selection was
        // switched off; that is the whole of what the user told us.
        if let saved = defaults.stringArray(forKey: enabledEntriesKey) {
            // A selection with no roster beside it is taken at face value:
            // nothing is "new", so everything on disk that is not selected is
            // off. That is what the v1 reader did, and reproducing it exactly is
            // the point of migrating rather than starting over.
            let known = defaults.stringArray(forKey: knownEntriesKey) ?? discovered.map(\.key)
            let enabled = Set(saved)
            let disabled = known.filter { !enabled.contains($0) }.map(LerpRotationEntry.init(key:))
            return LerpRotationState(stored: true, revision: 0,
                                     writer: "migrated-v1",
                                     disabled: Set(disabled),
                                     roster: roster(of: known.map(LerpRotationEntry.init(key:))))
        }

        // v0 — shader names only, from before the rotation counted presets. A
        // shader that was out is out in all its looks; a shader nobody had heard
        // of is in, which is how the presets arrived in the first place.
        if let legacy = defaults.stringArray(forKey: enabledShadersKey) {
            let enabled = Set(legacy)
            let known = Set(defaults.stringArray(forKey: knownShadersKey)
                            ?? discovered.map(\.shader))
            let off = known.subtracting(enabled)
            let disabled = discovered.filter { off.contains($0.shader) }
            let seen = discovered.filter { known.contains($0.shader) }
            return LerpRotationState(stored: true, revision: 0,
                                     writer: "migrated-v0",
                                     disabled: Set(disabled),
                                     roster: roster(of: seen))
        }

        return .empty
    }

    /// A saved state re-expressed in today's keys: renames carried across,
    /// deleted looks forgotten, genuinely new looks left out of the disabled set
    /// so they join the rotation.
    ///
    /// Idempotent, and safe to run on every read — which it is, because nothing
    /// writes the reconciled roster back until something actually saves.
    static func reconcile(_ state: LerpRotationState,
                          with discovered: [LerpRotationEntry]) -> LerpRotationState {
        let now = roster(of: discovered)
        var disabled: Set<LerpRotationEntry> = []

        for (shader, presets) in now {
            // A shader nobody has seen before is new in all its looks. Not being
            // in the disabled set is what puts it in the rotation.
            guard let before = state.roster[shader] else { continue }

            let defaults = LerpRotationEntry(shader: shader)
            if state.disabled.contains(defaults) { disabled.insert(defaults) }

            let kept = Set(before).intersection(presets)
            for preset in presets where kept.contains(preset) {
                let entry = LerpRotationEntry(shader: shader, preset: preset)
                if state.disabled.contains(entry) { disabled.insert(entry) }
            }
            for pair in renamePairs(from: before, to: presets) {
                guard state.disabled.contains(LerpRotationEntry(shader: shader, preset: pair.old))
                else { continue }
                disabled.insert(LerpRotationEntry(shader: shader, preset: pair.new))
            }
        }

        var reconciled = state
        reconciled.version = LerpRotationState.currentVersion
        reconciled.disabled = disabled
        reconciled.roster = now
        return reconciled
    }

    // MARK: - The rotation itself

    /// The looks the shuffle may play, or nil for "every one of them".
    ///
    /// nil rather than a full set only where the old reader answered nil, so
    /// that `LerpMetalView.Config.rotation` sees exactly what it always saw:
    /// no readable defaults at all, and a selection that has gone entirely
    /// stale. Both mean the full rotation; neither may mean an empty one.
    public static func enabled(discovered: [LerpRotationEntry],
                               in defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        guard defaults != nil else { return nil }
        let state = read(defaults, discovered: discovered)
        guard state.stored else { return nil }
        let enabled = Set(discovered).subtracting(state.disabled)
        return enabled.isEmpty ? nil : enabled
    }

    // MARK: - Writing

    /// Persists a selection, three-way merged against whatever is live.
    ///
    /// - `enabled`: the looks the caller wants in. nil or empty means "all of
    ///   them", which is `LerpMetalView.Config.rotation`'s policy and not
    ///   restated here.
    /// - `base`: the state the caller *read* before the user started clicking.
    ///   If the live revision has moved on since, the caller is stale and only
    ///   the entries it actually toggled are applied; everything else stays as
    ///   the newer writer left it.
    ///
    ///   nil means the caller is not playing: it is declaring the rotation
    ///   outright, and whatever is there is replaced. That is the right answer
    ///   for a test fixture or a migration, and the wrong one for a window with
    ///   a checkbox in it — both UIs in this project pass a real base, which is
    ///   what makes them safe to leave open beside each other.
    /// - `discovered`: every look on disk, in `rotationEntries()` order. An
    ///   empty one saves nothing, so a host that discovered no shaders cannot
    ///   wipe a rotation.
    ///
    /// Returns the state as written, so a long-lived caller can adopt it as its
    /// new base and stop being stale.
    @discardableResult
    public static func write(enabled: Set<LerpRotationEntry>?,
                             base: LerpRotationState?,
                             discovered: [LerpRotationEntry],
                             writer: String,
                             to defaults: UserDefaults?) -> LerpRotationState {
        guard let defaults, !discovered.isEmpty else { return base ?? .empty }

        let all = Set(discovered)
        // An empty selection is stored as an empty *disabled* set, because
        // `Config.rotation` reads "nothing chosen" as "all of them" and the
        // sheet says so out loud. Storing it as "everything off" would be a
        // rotation that renders all of them while claiming none.
        let picked = Set(LerpMetalView.Config.rotation(of: enabled, from: discovered))
        let wanted = all.subtracting(picked)

        let live = read(defaults, discovered: discovered)
        let merged: Set<LerpRotationEntry>
        if let base, live.revision != base.revision {
            // Stale. Contribute the toggles this caller made and nothing else:
            // whatever it never touched belongs to whoever wrote more recently.
            let turnedOff = wanted.subtracting(base.disabled)
            let turnedOn = base.disabled.subtracting(wanted)
            merged = live.disabled.subtracting(turnedOn).union(turnedOff)
        } else {
            merged = wanted
        }

        let state = LerpRotationState(
            stored: true,
            version: LerpRotationState.currentVersion,
            revision: max(live.revision, base?.revision ?? 0) + 1,
            updatedAt: Date(),
            writer: writer,
            // Only looks that exist. A shader that has gone takes its opinions
            // with it, exactly as the v1 reader dropped stale keys.
            disabled: merged.intersection(all),
            roster: roster(of: discovered))

        // The v1 and v0 keys first, so a downgrade to an older build — or the
        // `defaults read` somebody reaches for when this misbehaves — still
        // finds the same rotation rather than an empty one. First because the
        // v2 record carries a digest of them, which is how a *later* write to
        // them by an older build is noticed rather than ignored.
        let inRotation = discovered.filter { !state.disabled.contains($0) }
        let enabledKeys = inRotation.map(\.key), knownKeys = discovered.map(\.key)
        defaults.set(enabledKeys, forKey: enabledEntriesKey)
        defaults.set(knownKeys, forKey: knownEntriesKey)
        defaults.set(shaderNames(of: inRotation), forKey: enabledShadersKey)
        defaults.set(shaderNames(of: discovered), forKey: knownShadersKey)

        defaults.set([
            "version": state.version,
            "revision": state.revision,
            "updatedAt": state.updatedAt.timeIntervalSince1970,
            "writer": state.writer,
            "disabled": state.disabled.map(\.key).sorted(),
            "roster": state.roster,
            "legacy": digest(enabledKeys + ["\u{1}"] + knownKeys),
        ] as [String: Any], forKey: stateKey)
        defaults.synchronize()
        return state
    }

    /// The shaders these looks name, once each, in order. A shader counts as in
    /// the pre-preset rotation when any of its looks is, so the v0 keys keep
    /// saying something true.
    static func shaderNames(of entries: [LerpRotationEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.shader).filter { seen.insert($0).inserted }
    }
}
