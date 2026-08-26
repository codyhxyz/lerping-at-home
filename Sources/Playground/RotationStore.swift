import Foundation
import ScreenSaver

/// The screensaver's shuffle rotation, read and written *where the screensaver
/// reads it* — the ByHost domain `com.hergenroeder.lerping`, reached through the
/// same `ScreenSaverDefaults(forModuleWithName:)` call `LerpSaverView` makes.
///
/// The playground is a separate app (`com.hergenroeder.lerping.playground`) with
/// a preferences domain of its own, and none of that domain is of any use here:
/// a rotation the screensaver cannot see is a rotation that does nothing. So
/// this writes into the saver's domain, under the saver's key names, in the
/// saver's format. There is no second store and no sync step.
///
/// The load/save policy used to be a hand *transcription* of the `Settings`
/// struct at the bottom of `Sources/Saver/LerpSaverView.swift`. Two copies of a
/// rule about which of a user's looks may appear on their screen is one copy too
/// many, and they had already begun to matter separately. Both now call
/// `LerpRotation` in LerpCore, which is the single statement of the policy;
/// what is left here is the part that is genuinely the playground's — which
/// domain to open.
///
/// The write path stays narrow on purpose: the rotation keys and nothing else,
/// so the playground can never clobber the frame rate, the pinned shader or the
/// wallpaper opt-in.
enum RotationStore {

    /// The screensaver's defaults module — the string `LerpSaverView` passes to
    /// `ScreenSaverDefaults(forModuleWithName:)`. Not the playground's bundle
    /// identifier, on purpose.
    ///
    static let module = LerpDefaults.module

    /// Which host this is, in the saved state's `writer` field. Diagnostics
    /// only — it is what makes "who turned this back on?" answerable in a log.
    static let writerName = LerpDefaults.playgroundWriter

    /// The screensaver's own defaults. `ScreenSaverDefaults` resolves to
    /// `~/Library/Preferences/ByHost/com.hergenroeder.lerping.<hardware UUID>.plist`,
    /// which is the file the saver and its Options sheet both read.
    ///
    static func saverDefaults() -> UserDefaults? {
        ScreenSaverDefaults(forModuleWithName: module)
    }

    // MARK: - Reading

    /// The persisted state, for a caller that is going to write and therefore
    /// needs to know what it is writing on top of.
    static func state(discovered: [LerpRotationEntry],
                      from defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.read(defaults, discovered: discovered)
    }

    /// What the screensaver's saved rotation comes to for these looks — the one
    /// spelling of it the playground uses, so the gallery window and the toolbar
    /// popover cannot come up disagreeing about what is in.
    ///
    /// `LerpRotation.enabled` is the policy; the cases it has to keep:
    ///
    /// - Nothing ever saved: nil, i.e. the full rotation. Never an empty one.
    /// - Saved entries that no longer exist are dropped.
    /// - Entries discovered since the last save default to enabled, so a new
    ///   `.metal` file — or a new preset on a file that was already there — does
    ///   not silently sit out of the rotation.
    /// - A preset that was *renamed* is not "discovered since": it keeps
    ///   whatever the user decided about it under its old name.
    /// - A rotation saved before presets counted holds shader *names*; every
    ///   look of a shader that was in it joins.
    static func resolved(discovered: [LerpRotationEntry],
                         from defaults: UserDefaults?) -> Set<LerpRotationEntry> {
        let state = state(discovered: discovered, from: defaults)
        return Set(LerpMetalView.Config.rotation(
            of: LerpRotation.enabled(discovered: discovered, in: state), from: discovered))
    }

    /// What the screensaver will actually shuffle through, given what is saved
    /// and what exists. The "empty means all" policy is `Config.rotation`'s, not
    /// this file's.
    static func rotation(discovered: [LerpRotationEntry],
                         from defaults: UserDefaults?) -> [LerpRotationEntry] {
        LerpMetalView.Config.rotation(of: resolved(discovered: discovered, from: defaults),
                                      from: discovered)
    }

    // MARK: - Writing

    /// Writes the rotation the way the saver's Options sheet writes it, and
    /// nothing else.
    ///
    /// `entries` is the full rotation in display order; an empty one leaves the
    /// saved rotation alone, so a host that discovered nothing cannot wipe it.
    /// An empty *selection*, though, is written as an empty rotation and means
    /// it: `Config.rotation` takes the set literally, and it no longer widens an
    /// empty one back to everything. What stops a deselect-all blacking the
    /// screensaver out is the gallery refusing the last look, not this.
    ///
    /// There is no `base` any more, and nothing to merge against. The
    /// playground is the rotation's only writer: the saver's Options… sheet
    /// shows the gallery but no longer writes it, because it runs sandboxed and
    /// could only ever write Apple's container rather than the file the saver
    /// reads. Two writers needed a revision number and a three-way merge to stop
    /// one silently undoing the other; one writer needs neither.
    @discardableResult
    static func save(_ enabled: Set<LerpRotationEntry>?,
                     entries: [LerpRotationEntry],
                     to defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.write(enabled: enabled, discovered: entries,
                           writer: writerName, to: defaults)
    }
}
