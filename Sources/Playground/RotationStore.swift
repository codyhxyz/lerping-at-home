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

    /// The saved rotation as something to ask and edit — the one spelling of
    /// it the playground uses, so the gallery window and the toolbar popover
    /// cannot come up disagreeing about what is in.
    ///
    /// The policy is `LerpRotationSelection`'s; the cases it keeps:
    ///
    /// - Nothing ever saved: no opinions, so everything plays. Never an empty
    ///   rotation.
    /// - Saved keys that no longer mean anything are dropped.
    /// - Looks discovered since the last save play, so a new `.metal` file — or
    ///   a new preset on a file that was already there — does not silently sit
    ///   out of the rotation. Unless its shader is switched off whole, which
    ///   covers looks nobody had heard of when it was switched off.
    /// - A preset that was *renamed* is not "discovered since": it keeps
    ///   whatever the user decided about it under its old name.
    static func selection(discovered: [LerpRotationEntry],
                          from defaults: UserDefaults?) -> LerpRotationSelection {
        LerpRotation.selection(discovered: discovered,
                               in: state(discovered: discovered, from: defaults))
    }

    /// What the screensaver will actually shuffle through, given what is saved
    /// and what exists.
    static func rotation(discovered: [LerpRotationEntry],
                         from defaults: UserDefaults?) -> [LerpRotationEntry] {
        selection(discovered: discovered, from: defaults).playable
    }

    // MARK: - Writing

    /// Writes the rotation, and nothing else.
    ///
    /// A selection that discovered nothing leaves the saved rotation alone, so
    /// a host that found no shaders cannot wipe it. An empty *rotation*, though,
    /// is written as one and means it: what stops a deselect-all blacking the
    /// screensaver out is the gallery refusing the last look, not this.
    ///
    /// There is no `base` any more, and nothing to merge against. The
    /// playground is the rotation's only writer: the saver's Options… sheet
    /// shows the gallery but no longer writes it, because it runs sandboxed and
    /// could only ever write Apple's container rather than the file the saver
    /// reads. Two writers needed a revision number and a three-way merge to stop
    /// one silently undoing the other; one writer needs neither.
    @discardableResult
    static func save(_ selection: LerpRotationSelection,
                     to defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.write(selection, writer: writerName, to: defaults)
    }

    // MARK: - One look at a time

    /// Posted after a write that did not come from a grid — a Shortcuts action
    /// — so the gallery window and the picker popover, which hold the rotation
    /// in memory, show what is on disk instead of saving their stale copy over
    /// it on the next click.
    static let changedElsewhere = Notification.Name("LerpRotationChangedElsewhere")

    /// Puts one look in or out of the rotation, the way clicking its tile does:
    /// read what is saved, change that one look, `save` the result. Returns
    /// whether anything changed; asking for the state a look is already in
    /// writes nothing.
    ///
    /// The gallery's floor holds here too: the last look in the rotation
    /// cannot be switched off, because `Config.rotation` takes an empty set
    /// literally and the screensaver would have nothing to show.
    @discardableResult
    static func setLook(_ entry: LerpRotationEntry, enabled: Bool,
                        discovered: [LerpRotationEntry] = LookCatalog.discovered(),
                        defaults: UserDefaults? = saverDefaults()) throws -> Bool {
        guard !discovered.isEmpty else { throw LookIntentError.noLooks }
        guard discovered.contains(entry) else { throw LookIntentError.unknownLook(entry.key) }
        let before = selection(discovered: discovered, from: defaults)
        guard before.plays(entry) != enabled else { return false }
        let after = before.applying { $0.setLook(entry, on: enabled) }
        guard !after.playable.isEmpty else { throw LookIntentError.lastLook(entry.key) }
        // `write` can decline (no defaults, or the production guard in
        // `LerpDefaults`) and hands back what is on disk instead. Say so rather
        // than reporting a change that did not happen.
        let written = save(after, to: defaults)
        let nowIn = LerpRotation.selection(discovered: discovered, in: written).plays(entry)
        guard nowIn == enabled else { throw LookIntentError.notSaved(entry.key) }
        NotificationCenter.default.post(name: changedElsewhere, object: nil)
        return true
    }
}
