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
/// domain to open, and the guard that keeps the tests out of the live one.
///
/// The write path stays narrow on purpose: the rotation keys and nothing else,
/// so the playground can never clobber the frame rate, the pinned shader or the
/// wallpaper opt-in.
///
/// `--selftest` asserts every invariant this has to keep (empty means all,
/// entirely-stale means all, entries discovered since the last save join
/// automatically, a renamed preset does *not* count as discovered-since, a
/// pre-preset `enabledShaders` list still migrates, a stale writer cannot undo
/// a newer click) and then checks the result against the real `.saver` bundle's
/// own Options sheet.
enum RotationStore {

    /// The screensaver's defaults module — the string `LerpSaverView` passes to
    /// `ScreenSaverDefaults(forModuleWithName:)`. Not the playground's bundle
    /// identifier, on purpose.
    ///
    /// Honours `LERP_DEFAULTS_MODULE` exactly as `LerpSaverView` does. It used
    /// to hardcode the live domain while the saver read the environment, so the
    /// one switch that was supposed to keep a test off the user's real rotation
    /// only ever covered half the code. `--selftest` then wrote the user's
    /// deliberate selection through `PlaygroundWindowController`'s
    /// `rotationDefaults` default argument, which resolved through here before
    /// the test could redirect it, and switched two shaders off for real.
    static let module = ProcessInfo.processInfo.environment["LERP_DEFAULTS_MODULE"]
        ?? productionModule

    /// What `module` resolves to when nothing redirects it: the real
    /// screensaver's ByHost domain. Kept separate so the redirect cannot be
    /// mistaken for the live domain, and so `testModule` and `isLiveModule`
    /// stay anchored to the thing that must be protected rather than to
    /// whatever this process happens to be pointed at.
    static let productionModule = "com.hergenroeder.lerping"

    /// A ByHost domain of the same shape, and no user's.
    ///
    /// `--selftest` clicks tiles and then reads the result back out of cfprefsd
    /// to prove the click landed where the screensaver reads it. It used to do
    /// that in `module` itself — the user's live rotation — backing it up first
    /// and restoring it in `finish()`. That is a landmine: a run killed between
    /// the first click and the restore leaves the user's deliberate selection
    /// rewritten, and a "restore" from a stale backup is how genuinely chosen
    /// settings get thrown away. A domain nobody's screensaver reads costs the
    /// test nothing — it is the same class, the same call and the same keys —
    /// and it cannot destroy anything.
    static let testModule = productionModule + ".uitest"

    /// Whether the module a run is pointed at is the user's live one. Nothing in
    /// the test suite may answer true. Compares against `productionModule`, not
    /// `module`: a redirected run must still recognise the live domain as the
    /// one thing it may not write.
    static func isLiveModule(_ name: String) -> Bool { name == productionModule }

    /// The versioned rotation state — the schema, the migrations and the
    /// stale-writer merge all live in `LerpRotation`.
    static let stateKey = LerpRotation.stateKey
    /// `LerpRotationEntry.key`s the user wants in the shuffle rotation. Legacy,
    /// still written so an older build finds a sane rotation.
    static let enabledEntriesKey = LerpRotation.enabledEntriesKey
    /// Every entry that existed when the rotation was last saved.
    static let knownEntriesKey = LerpRotation.knownEntriesKey
    /// The pre-preset shape of the same two keys — sets of shader *names*.
    static let enabledShadersKey = LerpRotation.enabledShadersKey
    static let knownShadersKey = LerpRotation.knownShadersKey

    /// Every key this file will ever touch.
    static let allKeys = LerpRotation.allKeys

    /// Which host this is, in the saved state's `writer` field.
    static let writerName = "playground"

    /// The screensaver's own defaults. `ScreenSaverDefaults` resolves to
    /// `~/Library/Preferences/ByHost/com.hergenroeder.lerping.<hardware UUID>.plist`,
    /// which is the file the saver and its Options sheet both read.
    ///
    /// `module` is a parameter so a test can be handed `testModule` and reach
    /// the same class through the same call without going anywhere near the
    /// user's settings.
    static func saverDefaults(module: String = module) -> UserDefaults? {
        ScreenSaverDefaults(forModuleWithName: module)
    }

    /// Removes a whole ByHost domain. Only ever called on `testModule`; the
    /// guard is there so a future edit cannot point it at the live one.
    static func deleteDomain(_ name: String) {
        guard !isLiveModule(name) else { return }
        allKeys.forEach {
            CFPreferencesSetValue($0 as CFString, nil, name as CFString,
                                  kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
        CFPreferencesSynchronize(name as CFString, kCFPreferencesCurrentUser,
                                 kCFPreferencesCurrentHost)
    }

    // MARK: - Reading

    /// The shuffle rotation implied by saved defaults, or nil for "every entry".
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
    static func load(discovered: [LerpRotationEntry],
                     from defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        LerpRotation.enabled(discovered: discovered, in: defaults)
    }

    /// The persisted state behind `load`, for a caller that is going to write
    /// and therefore needs to know what it is writing on top of.
    static func state(discovered: [LerpRotationEntry],
                      from defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.read(defaults, discovered: discovered)
    }

    /// What the screensaver will actually shuffle through, given what is saved
    /// and what exists. The "empty means all" policy is `Config.rotation`'s, not
    /// this file's.
    static func rotation(discovered: [LerpRotationEntry],
                         from defaults: UserDefaults?) -> [LerpRotationEntry] {
        LerpMetalView.Config.rotation(of: load(discovered: discovered, from: defaults),
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
    /// `base` is the state the caller last read. Pass the real one from any
    /// window with a checkbox in it: it is what stops a gallery that has been
    /// sitting open from undoing an Options… sheet that was pressed in the
    /// meantime. Omitting it declares the rotation outright, which is what a
    /// test fixture wants and a UI does not. The state actually written comes
    /// back, for the caller to adopt as its next base.
    @discardableResult
    static func save(_ enabled: Set<LerpRotationEntry>?,
                     entries: [LerpRotationEntry],
                     base: LerpRotationState? = nil,
                     to defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.write(enabled: enabled, base: base, discovered: entries,
                           writer: writerName, to: defaults)
    }
}
