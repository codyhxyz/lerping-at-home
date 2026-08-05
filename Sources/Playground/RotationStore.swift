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
/// The load/save policy below is a *transcription* of the `Settings` struct at
/// the bottom of `Sources/Saver/LerpSaverView.swift`, which is private to the
/// saver and so cannot be called from here. The transcription is deliberate and
/// narrow: the four rotation keys and nothing else, so the playground can never
/// clobber the frame rate, the pinned shader or the wallpaper opt-in. The one
/// piece of policy that is *not* transcribed is the "empty means all" rule —
/// that lives in `LerpMetalView.Config.rotation(of:from:)` in LerpCore and is
/// called, here and in the saver, rather than restated.
///
/// `--selftest` asserts every invariant this file has to keep (empty means all,
/// entirely-stale means all, entries discovered since the last save join
/// automatically, a pre-preset `enabledShaders` list still migrates) and then
/// checks the result against the real `.saver` bundle's own Options sheet.
enum RotationStore {

    /// The screensaver's defaults module — the string `LerpSaverView` passes to
    /// `ScreenSaverDefaults(forModuleWithName:)`. Not the playground's bundle
    /// identifier, on purpose.
    static let module = "com.hergenroeder.lerping"

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
    static let testModule = module + ".uitest"

    /// Whether the module a run is pointed at is the user's live one. Nothing in
    /// the test suite may answer true.
    static func isLiveModule(_ name: String) -> Bool { name == module }

    /// `LerpRotationEntry.key`s the user wants in the shuffle rotation.
    static let enabledEntriesKey = "enabledEntries"
    /// Every entry that existed when the rotation was last saved; anything
    /// discovered later counts as new and joins automatically.
    static let knownEntriesKey = "knownEntries"
    /// The pre-preset shape of the same two keys — sets of shader *names*. Read
    /// for migration and still written, so an older build finds a sane subset.
    static let enabledShadersKey = "enabledShaders"
    static let knownShadersKey = "knownShaders"

    /// Every key this file will ever touch.
    static let allKeys = [enabledEntriesKey, knownEntriesKey, enabledShadersKey, knownShadersKey]

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
    /// Transcribed from `Settings.savedRotation`. The four cases it has to keep:
    ///
    /// - Nothing ever saved: nil, i.e. the full rotation. Never an empty one.
    /// - Saved entries that no longer exist are dropped.
    /// - Entries discovered since the last save default to enabled, so a new
    ///   `.metal` file — or a new preset on a file that was already there — does
    ///   not silently sit out of the rotation.
    /// - A rotation saved before presets counted holds shader *names*; every
    ///   look of a shader that was in it joins.
    static func load(discovered: [LerpRotationEntry],
                     from defaults: UserDefaults?) -> Set<LerpRotationEntry>? {
        guard let defaults else { return nil }
        let all = Set(discovered)
        if let saved = defaults.stringArray(forKey: enabledEntriesKey) {
            // No roster saved: take the saved list at face value, nothing is "new".
            let known = Set((defaults.stringArray(forKey: knownEntriesKey) ?? discovered.map(\.key))
                .map(LerpRotationEntry.init(key:)))
            let enabled = all.intersection(saved.map(LerpRotationEntry.init(key:)))
                .union(all.subtracting(known))
            return enabled.isEmpty ? nil : enabled
        }
        guard let legacy = defaults.stringArray(forKey: enabledShadersKey) else { return nil }
        let shaders = Set(discovered.map(\.shader))
        let knownShaders = Set(defaults.stringArray(forKey: knownShadersKey) ?? Array(shaders))
        let picked = shaders.intersection(legacy).union(shaders.subtracting(knownShaders))
        let enabled = all.filter { picked.contains($0.shader) }
        return enabled.isEmpty ? nil : enabled
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

    /// Writes the rotation the way `Settings.save` writes it, and nothing else.
    ///
    /// `entries` is the full rotation in display order; an empty one leaves the
    /// saved rotation alone, so a host that discovered nothing cannot wipe it.
    /// An empty *selection* is persisted as the full rotation, because
    /// `Config.rotation` says an empty rotation means all of them — the saver
    /// does exactly this, and it is why a deselect-all can never black the
    /// screensaver out.
    static func save(_ enabled: Set<LerpRotationEntry>?,
                     entries: [LerpRotationEntry],
                     to defaults: UserDefaults?) {
        guard let defaults, !entries.isEmpty else { return }
        let picked = LerpMetalView.Config.rotation(of: enabled, from: entries)
        defaults.set(picked.map(\.key), forKey: enabledEntriesKey)
        defaults.set(entries.map(\.key), forKey: knownEntriesKey)
        // A shader counts as in the pre-preset rotation when any of its looks
        // is, so the legacy keys keep saying something true.
        defaults.set(shaderNames(of: picked), forKey: enabledShadersKey)
        defaults.set(shaderNames(of: entries), forKey: knownShadersKey)
        defaults.synchronize()
    }

    /// The shaders these entries name, once each, in order.
    private static func shaderNames(of entries: [LerpRotationEntry]) -> [String] {
        var seen = Set<String>()
        return entries.map(\.shader).filter { seen.insert($0).inserted }
    }

}
