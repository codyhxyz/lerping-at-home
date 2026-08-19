import Foundation

/// What the playground opens on when it launches.
///
/// It used to be whatever came first alphabetically — `aurora` — which is a look
/// like any other, except that the one thing we know about the user's opinion of
/// their looks is *which ones they took out of the screensaver's rotation*.
/// Opening on a look they deliberately deselected is the one answer their own
/// settings say is wrong, and "first alphabetically" hits it as readily as any
/// other. So the opening look is drawn from the rotation instead.
///
/// Two decisions worth stating out loud, because both could sensibly have gone
/// the other way:
///
/// **The draw is random, not the first enabled entry.** The screensaver shuffles;
/// a playground that opens on a different one of *your* looks each time is the
/// same pleasure, and it means the rotation is a rotation rather than a
/// tie-break. The usual objection — that an editor which opens somewhere
/// different every launch is worse to work in — is real, and it is answered
/// below rather than by giving up the shuffle.
///
/// **A remembered last-opened look beats the rotation.** Closing the window
/// mid-shader and reopening somewhere else loses your place, and no amount of
/// variety is worth that. So the random draw happens only when there is nothing
/// to return to: a first launch, or a remembered shader that has since been
/// deleted or broken. That is what makes the randomness free — it can never take
/// you away from work you were doing, because it only runs when there is none.
///
/// Everything here **reads** the screensaver's ByHost domain and never writes it.
/// Launching an editor must not touch a screensaver setting; the only thing this
/// file persists is the last-opened look, and that goes in the playground's own
/// preferences (`UserDefaults.standard`, i.e. this app's bundle identifier).
enum OpeningShader {

    // MARK: - Remembering where you were

    /// The playground's own preference key. Deliberately not one of
    /// `LerpRotation.allKeys` and deliberately not in the saver's domain: this
    /// is a fact about this app, not about the rotation.
    static let lastOpenedKey = "LerpLastOpenedEntry"

    static func remembered(in defaults: UserDefaults = .standard) -> LerpRotationEntry? {
        defaults.string(forKey: lastOpenedKey).map(LerpRotationEntry.init(key:))
    }

    static func remember(_ entry: LerpRotationEntry, in defaults: UserDefaults = .standard) {
        defaults.set(entry.key, forKey: lastOpenedKey)
    }

    static func forget(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastOpenedKey)
    }

    // MARK: - Choosing

    /// The look to open, or nil only when there are no shaders at all.
    ///
    /// - `discovered`: every shader on disk, in the order `ShaderLibrary` found
    ///   them.
    /// - `rotation`: the screensaver's defaults, read-only. nil — no ByHost
    ///   domain, no `ScreenSaverDefaults`, nothing readable — is not an error:
    ///   `RotationStore.rotation` turns that into every entry.
    /// - `remembered`: the last look this app opened, if any. Wins outright when
    ///   its shader is still on disk and still compiles.
    /// - `opens`: whether an entry can actually be put on screen — the shader
    ///   exists and its source compiles. Called at most once per shader by the
    ///   caller's memo.
    /// The fallbacks, in the order they fire, none of which may end in nothing:
    ///
    /// 1. A remembered look that still exists and compiles.
    /// 2. A random enabled entry — and if that one will not compile, the next
    ///    one along, wrapping once through the rotation. Skipping past a broken
    ///    shader rather than stopping on it is `LerpMetalView.loadEntry`'s rule,
    ///    for its reason: stopping shows the wrong thing and sticks there.
    /// 3. A random enabled entry that does *not* compile, when none of them
    ///    will. An editor has to open onto a file — that is where the
    ///    diagnostics are, and a window with nothing in it has no way back — but
    ///    it opens onto one of *your* looks, broken, rather than onto a working
    ///    look you took out of the rotation. This step used to widen to every
    ///    entry on disk, which is the same mistake the saver was making: the one
    ///    thing we know about the user's opinion of their looks is which ones
    ///    they deselected, and "the alternative was inconvenient" is not a
    ///    reason to overrule it.
    /// 4. The first entry there is, and only when the rotation is empty — which
    ///    the gallery does not let happen.
    static func choose(discovered: [LerpShader],
                       rotation: UserDefaults?,
                       remembered: LerpRotationEntry?,
                       opens: (LerpRotationEntry) -> Bool) -> LerpRotationEntry? {
        let all = discovered.rotationEntries()
        guard let fallback = all.first else { return nil }

        if let wanted = remembered.flatMap({ resolve($0, in: discovered) }), opens(wanted) {
            return wanted
        }

        // Ask RotationStore for the effective rotation rather than duplicating
        // its load-plus-filter policy here.
        let enabled = RotationStore.rotation(discovered: all, from: rotation)

        if let opening = firstThatOpens(in: enabled, opens: opens) { return opening }
        // Nothing enabled compiles. Open on an enabled look anyway rather than
        // on a working one that is out of the rotation.
        if let enabled = enabled.randomElement() { return enabled }
        return fallback
    }

    /// A remembered entry brought up to date with what is on disk: nil when the
    /// shader is gone, and stripped of a preset the file no longer declares
    /// (that look is the shader's defaults now, and saying so is better than
    /// asking for a preset nothing will apply). Also canonicalises the preset's
    /// spelling, since `preset(named:)` matches case-insensitively.
    private static func resolve(_ entry: LerpRotationEntry,
                                in discovered: [LerpShader]) -> LerpRotationEntry? {
        guard let shader = discovered.named(entry.shader) else { return nil }
        guard let wanted = entry.preset else { return LerpRotationEntry(shader: shader.name) }
        return LerpRotationEntry(shader: shader.name, preset: shader.preset(named: wanted)?.name)
    }

    /// The first entry that will open, starting at a random place in `order` and
    /// walking forward, wrapping once. nil when none of them will.
    ///
    /// The walk is `ShaderLibrary.firstStep`, which is where every cycle in this
    /// project lives — the ←/→ keys, the shuffle and this — rather than a fourth
    /// spelling of `(i + d + n) % n` around a fourth copy of "skip the ones that
    /// will not build".
    private static func firstThatOpens(in order: [LerpRotationEntry],
                                       opens: (LerpRotationEntry) -> Bool) -> LerpRotationEntry? {
        guard !order.isEmpty else { return nil }
        return ShaderLibrary.firstStep(in: order, after: nil,
                                       offset: Int.random(in: order.indices), where: opens)
    }
}
