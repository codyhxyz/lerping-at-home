import Foundation
import os

/// Everything the shuffle rotation persists, in one place, for every host.
///
/// # One representation
///
/// This file used to write four keys that all claimed to answer the same
/// question, plus a hash to referee them:
///
/// - `rotationState.disabled` — the looks that are out (v2, authoritative)
/// - `enabledEntries` / `knownEntries` — the looks that are in (v1)
/// - `enabledShaders` / `knownShaders` — the *shaders* that are in (v0)
/// - `rotationState.legacy` — a digest of the v1 keys, so a v2 reader could
///   notice that someone had written v1 afterwards
///
/// The user's live plist showed what that costs. `enabledEntries` listed bare
/// `fluted-glass` but none of its three presets; it listed seven
/// `game-of-life/*` presets but no bare `game-of-life`; `enabledShaders` listed
/// `metaballs`, `water` and `halftone-cmyk` as in the rotation while
/// `enabledEntries` had switched off every look those shaders own except one
/// apiece. All three were *correct* under their own schema — v0 genuinely
/// cannot express "one preset of this shader" and reports the shader as in — but
/// anything that read the coarser key got a broader answer than the user gave,
/// and the digest existed only to arbitrate between copies that should never
/// have existed.
///
/// So there is now exactly one: the `rotationState` record. The v1 keys are
/// still *read*, once, by a domain that has no v2 record — that is a real
/// migration and it costs ten lines. They are never written again, and
/// `write` deletes them, so the disagreement cannot re-form. With one
/// representation there is nothing for a digest to referee, and it is gone too.
///
/// # Why the stored set is the *off* set
///
/// The v1 schema stored the looks that are in, beside a roster of everything
/// that existed at save time. Anything missing from the roster counted as new
/// and joined automatically, which is the behaviour you want for a shader
/// someone just dropped in.
///
/// The trouble is that a *renamed* preset is indistinguishable from a new one
/// under that scheme, and it is worse than merely ambiguous: renaming
/// `SineWave` to `Sine Wave` retires the old key (so it falls out of the
/// selection) and mints a new one (so it is not in the roster and joins). A look
/// the user deliberately switched off comes back on, silently, because somebody
/// edited a comment. That has destroyed a real selection twice.
///
/// So this schema stores the **disabled** set. It is the smaller list, it is the
/// only thing the user has actually expressed an opinion *about*, and it does
/// not have to be rewritten every time the library grows. "Not mentioned" means
/// in, which is what makes a genuinely new look join without a roster entry
/// having to say so.
///
/// # Telling a rename from a new look
///
/// The roster records each shader's presets **in declaration order** rather than
/// as a flat set of keys. That is enough to align the old list against the new
/// one: a preset name present in both is itself; a name that vanished and a name
/// that appeared *at the same position* are the same look under a new name, and
/// the disabled flag travels with it. A new name with no vanished partner is
/// genuinely new and joins the rotation. See `renamePairs(from:to:)`.
///
/// # One writer
///
/// There used to be two — the playground's gallery and the screensaver's
/// Options… sheet — and because the sheet runs sandboxed inside
/// `legacyScreenSaver` they wrote to two *different* stores: the playground to
/// the user's ByHost plist, the sheet to Apple's container. One truth in two
/// files, reconciled by a hand-rolled "whose revision is higher" comparison, and
/// a three-way merge inside this file to stop a sheet left open from undoing a
/// click made in the playground.
///
/// The sheet's gallery is now read-only (see `LerpSaverView`), so the playground
/// is the only writer and the ByHost plist is the only store. Everything that
/// existed to arbitrate between them — `revision`, the base/stale comparison,
/// the three-way merge, the container-versus-ByHost newer-than check — is
/// deleted. A single writer does not need to merge with itself.
public struct LerpRotationState: Equatable, Sendable {

    /// Schema version of the `rotationState` dictionary.
    public static let currentVersion = 2

    /// Whether anything was ever saved. False only for `.empty`, and the
    /// difference matters: "no opinions" and "no rotation has ever been stored"
    /// both light every look up, but only the second one is reported to callers
    /// as nil — which is the answer `LerpMetalView.Config.rotation` reads as
    /// "every entry", and the answer a fresh install has always given.
    public var stored: Bool
    public var version: Int
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
                updatedAt: Date = Date(timeIntervalSince1970: 0),
                writer: String = "",
                disabled: Set<LerpRotationEntry> = [],
                roster: [String: [String]] = [:]) {
        self.stored = stored
        self.version = version
        self.updatedAt = updatedAt
        self.writer = writer
        self.disabled = disabled
        self.roster = roster
    }

    /// Nothing has ever been saved: no opinions, no roster, so every look is in.
    public static let empty = LerpRotationState()

    /// One line for the log.
    public var summary: String {
        "writer=\(writer.isEmpty ? "-" : writer) "
            + "off=\(disabled.count) shaders=\(roster.count) "
            + "at=\(updatedAt.timeIntervalSince1970 > 0 ? ISO8601DateFormatter().string(from: updatedAt) : "never")"
    }
}

/// Reading and writing `LerpRotationState`, and the policy that turns it into
/// the list the shuffle walks.
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

    // MARK: - Reading

    /// The saved state, migrated forward from whatever schema is on disk and
    /// re-expressed against the looks that exist **now**.
    ///
    /// Never writes. Every host calls this, including ones that will never save,
    /// so it has to be free of side effects: a screensaver reading its rotation
    /// must not be able to change it.
    public static func read(_ defaults: UserDefaults?,
                            discovered: [LerpRotationEntry]) -> LerpRotationState {
        guard let defaults else { return .empty }
        return read(plist: [
            stateKey: defaults.dictionary(forKey: stateKey) as Any,
            legacyKeys[0]: defaults.stringArray(forKey: legacyKeys[0]) as Any,
            legacyKeys[1]: defaults.stringArray(forKey: legacyKeys[1]) as Any,
        ], discovered: discovered)
    }

    /// The same, from a property list read straight off disk.
    ///
    /// This is how the screensaver reads its rotation, and it is deliberately
    /// not a `UserDefaults` lookup. Inside `legacyScreenSaver` the saver is
    /// sandboxed under *Apple's* bundle identifier, so `ScreenSaverDefaults`
    /// resolves to Apple's container rather than the user's ByHost file. The
    /// previous code worked around that by loading the ByHost plist and
    /// installing it with `register(defaults:)` — the *lowest* precedence
    /// domain, so any value that had ever been written into the container
    /// outranked the file the user actually edits, and a hand-rolled
    /// "is the shared record newer?" comparison had to delete container keys to
    /// stop it winning.
    ///
    /// Reading the file by path removes the question. There is no precedence
    /// order to reason about, no second domain that can hold an older answer,
    /// and no `cfprefsd` cache in between: the bytes the playground wrote are
    /// the bytes the saver parses.
    public static func read(plist: [String: Any]?,
                            discovered: [LerpRotationEntry]) -> LerpRotationState {
        guard let plist else { return .empty }
        return reconcile(stored(plist), with: discovered)
    }

    /// The state exactly as persisted, migrated to the current shape but *not*
    /// yet mapped onto what is on disk.
    static func stored(_ plist: [String: Any]) -> LerpRotationState {
        // The v2 record is authoritative whenever it exists, full stop. It used
        // to have to prove itself against a digest of the v1 keys first, because
        // both were written together and either could be the newer one. Only one
        // of them is written now, so the newest thing on disk is the only thing
        // on disk.
        if let record = plist[stateKey] as? [String: Any],
           (record["version"] as? Int ?? 0) >= 2 {
            return LerpRotationState(
                stored: true,
                version: LerpRotationState.currentVersion,
                updatedAt: Date(timeIntervalSince1970: record["updatedAt"] as? Double ?? 0),
                writer: record["writer"] as? String ?? "",
                disabled: Set((record["disabled"] as? [String] ?? []).map(LerpRotationEntry.init(key:))),
                roster: record["roster"] as? [String: [String]] ?? [:])
        }

        // No v2 record: migrate the v1 keys, once. `enabledEntries` named what
        // was in and `knownEntries` the roster it was chosen from, so everything
        // in the roster and not in the selection was switched off. That is the
        // whole of what the user told the old schema.
        //
        // The v0 keys (`enabledShaders`/`knownShaders`) are deliberately *not*
        // consulted, even as a last resort. They cannot express a per-preset
        // choice, so migrating from them would take a user who had switched off
        // eleven of `game-of-life`'s twelve looks and turn all twelve back on —
        // widening a selection while claiming to preserve it. A domain old
        // enough to have only v0 keys gets `.empty`, which lights everything up
        // and is at least honest about having no opinion to carry.
        if let saved = plist[legacyKeys[0]] as? [String] {
            let enabled = Set(saved.map(LerpRotationEntry.init(key:)))
            let known = (plist[legacyKeys[1]] as? [String] ?? saved).map(LerpRotationEntry.init(key:))
            return LerpRotationState(stored: true, writer: "migrated-v1",
                                     disabled: Set(known).subtracting(enabled),
                                     roster: roster(of: known))
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
        // Every denial whose look is still on disk, carried across unchanged.
        // This does not consult the roster, and that is the point: a look the
        // user switched off stays off even if the roster has lost the shader it
        // belongs to. The roster's job is to *find renames*, not to decide
        // whether a decision counts.
        var disabled = state.disabled.intersection(discovered)

        for (shader, presets) in now {
            // Rename detection needs something to align against. A shader with
            // no roster entry is one nobody has catalogued, so its looks are new
            // — except for any the line above already carried, which were named
            // explicitly and are not new to anyone.
            guard let before = state.roster[shader] else { continue }
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
    /// nil means exactly one thing: **nobody has ever chosen**. No readable
    /// defaults, or a domain with no rotation in it — a fresh install, or an
    /// upgrade from a build that predates the setting. `Config.rotation` reads
    /// that as the full library, which is the right default and the only
    /// remaining path to one.
    ///
    /// It does *not* mean "the answer came out awkward". A stored selection is
    /// returned as it stands, including an empty one. That case is unreachable
    /// through the gallery, which will not let the last look be switched off.
    public static func enabled(discovered: [LerpRotationEntry],
                               in defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        guard let defaults else { return nil }
        return enabled(discovered: discovered, in: read(defaults, discovered: discovered))
    }

    /// The same, from a state the caller has already read.
    public static func enabled(discovered: [LerpRotationEntry],
                               in state: LerpRotationState) -> Set<LerpRotationEntry>? {
        guard state.stored else { return nil }
        return Set(discovered).subtracting(state.disabled)
    }

    // MARK: - Writing

    /// Persists a selection.
    ///
    /// - `enabled`: the looks the caller wants in. nil means "all of them",
    ///   which is `LerpMetalView.Config.rotation`'s policy and not restated
    ///   here. An empty set means an empty rotation and is written as such;
    ///   keeping that unreachable is the gallery's job, not this one's.
    /// - `discovered`: every look on disk, in `rotationEntries()` order. An
    ///   empty one saves nothing, so a host that discovered no shaders cannot
    ///   wipe a rotation.
    ///
    /// Returns the state as written.
    @discardableResult
    public static func write(enabled: Set<LerpRotationEntry>?,
                             discovered: [LerpRotationEntry],
                             writer: String,
                             to defaults: UserDefaults?) -> LerpRotationState {
        guard let defaults, !discovered.isEmpty else { return .empty }

        // What the process *is*, not what it calls itself. See `LerpDefaults`.
        guard LerpDefaults.mayWriteProduction else {
            log.error("""
                refusing rotation write from an unbundled process (writer \
                '\(writer, privacy: .public)') to the production domain \
                '\(LerpDefaults.productionModule, privacy: .public)'. Set \
                \(LerpDefaults.moduleOverrideVariable, privacy: .public) to a scratch domain.
                """)
            return read(defaults, discovered: discovered)
        }

        let all = Set(discovered)
        let picked = Set(LerpMetalView.Config.rotation(of: enabled, from: discovered))

        let state = LerpRotationState(
            stored: true,
            version: LerpRotationState.currentVersion,
            updatedAt: Date(),
            writer: writer,
            // Only looks that exist. A shader that has gone takes its opinions
            // with it.
            disabled: all.subtracting(picked),
            roster: roster(of: discovered))

        defaults.set([
            "version": state.version,
            "updatedAt": state.updatedAt.timeIntervalSince1970,
            "writer": state.writer,
            "disabled": state.disabled.map(\.key).sorted(),
            "roster": state.roster,
        ] as [String: Any], forKey: stateKey)

        // The old schemas, removed rather than left to rot. A stale
        // `enabledEntries` sitting beside a live `rotationState` is the exact
        // shape of the bug this file was rewritten to end: two answers to one
        // question, with the older one still readable.
        legacyKeys.forEach(defaults.removeObject(forKey:))

        defaults.synchronize()
        return state
    }
}