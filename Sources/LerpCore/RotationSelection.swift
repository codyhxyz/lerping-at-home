import Foundation

/// The rotation as the user expressed it, and the one statement of what that
/// comes to on screen.
///
/// # Two kinds of opinion, one set
///
/// People decide about the rotation at two levels. Most of the time it is a
/// whole shader — on the user's own machine, 46 of the 60 shaders they had
/// touched were all on or all off — and some of the time it is one shader's
/// looks, four of eleven. The old gallery stored only the second kind, so the
/// first had to be faked out of it: switching a shader off wrote every one of
/// its looks into the off set, and switching it back on deleted them all again,
/// taking a hand-picked four of eleven with it. The shader heading was a
/// three-state checkbox whose "mixed" state could only be left by destroying
/// what made it mixed.
///
/// So the off set now holds both, as keys in one grammar:
///
/// - `kleinian` — the shader's Defaults look is off
/// - `kleinian/Pearl Halls` — that look is off
/// - `kleinian/*` — the shader is switched off as a whole
///
/// A look plays when neither it nor its shader's `/*` is in the set. Switching
/// a shader off adds the `/*` key and leaves its per-look keys alone, so
/// switching it back on removes one key and the curation underneath is exactly
/// as it was. A preset written later joins an *on* shader, as new looks always
/// have, and stays out of an *off* one, because the `/*` covers looks nobody has
/// heard of yet.
///
/// It is still one representation. The stored record is the same
/// `rotationState.disabled` list it has always been — it simply has a third
/// shape of key in it — so there is no second set for a reader to forget, and
/// `verify-rotation.py` judges the same list the saver reads.
///
/// # Why this type exists
///
/// "Does this look play?" used to be answered by subtracting the off set from
/// the discovered list, spelled out separately by the saver, the playground's
/// store, its window, its picker and the Shortcuts actions. With a `/*` key in
/// the set, every one of those subtractions would have been wrong in the same
/// way. This is the only place the rule is written; everything else asks it.
public struct LerpRotationSelection: Equatable, Sendable {

    /// Every look on disk, in `rotationEntries()` order.
    public let discovered: [LerpRotationEntry]

    /// The off set exactly as it is stored: looks that are off, plus `shader/*`
    /// for each shader switched off whole. Only keys that mean something today —
    /// a look on disk, or the `/*` of a shader on disk — survive `init`.
    public private(set) var disabled: Set<LerpRotationEntry>

    public init(discovered: [LerpRotationEntry], disabled: Set<LerpRotationEntry> = []) {
        self.discovered = discovered
        let looks = Set(discovered)
        let shaders = Set(discovered.map(\.shader))
        self.disabled = disabled.filter {
            $0.isWholeShader ? shaders.contains($0.shader) : looks.contains($0)
        }
    }

    // MARK: What plays

    /// Whether `shader` is switched off as a whole.
    public func isSwitchedOff(_ shader: String) -> Bool {
        disabled.contains(.wholeShader(shader))
    }

    /// The per-look choice on its own, ignoring the shader's switch: what a
    /// card's "keeps 4 of 11" counts, so a switched-off shader still shows which of its
    /// looks would come back with it.
    public func isPicked(_ look: LerpRotationEntry) -> Bool {
        !disabled.contains(look)
    }

    /// Whether `look` reaches the screen.
    public func plays(_ look: LerpRotationEntry) -> Bool {
        isPicked(look) && !isSwitchedOff(look.shader)
    }

    /// The looks the shuffle walks, in display order.
    public var playable: [LerpRotationEntry] { discovered.filter(plays) }

    /// `shader`'s looks, in display order.
    public func looks(of shader: String) -> [LerpRotationEntry] {
        discovered.filter { $0.shader == shader }
    }

    /// Whether any of `shader`'s looks reaches the screen — what its card's
    /// frame says.
    public func shaderPlays(_ shader: String) -> Bool {
        looks(of: shader).contains(where: plays)
    }

    // MARK: Changing it

    /// Puts one look in or takes it out.
    ///
    /// Putting a look of a switched-off shader in switches the shader back on:
    /// you asked for that look to play, and it cannot while the `/*` stands.
    /// The shader's other looks come back as they were picked.
    public mutating func setLook(_ look: LerpRotationEntry, on: Bool) {
        if on {
            disabled.remove(look)
            disabled.remove(.wholeShader(look.shader))
        } else {
            disabled.insert(look)
        }
    }

    /// Several looks at once — Select All and Deselect All, over whatever the
    /// filter shows.
    public mutating func setLooks(_ looks: some Sequence<LerpRotationEntry>, on: Bool) {
        for look in looks { setLook(look, on: on) }
    }

    /// Switches a whole shader on or off, keeping its per-look picks.
    ///
    /// The one case that touches them: switching on a shader none of whose looks
    /// is picked. Removing the `/*` alone would change nothing on screen, and a
    /// switch that does nothing reads as broken — so it brings every look in,
    /// which is what "switch this shader on" means when there is no curation to
    /// restore.
    public mutating func setShader(_ shader: String, on: Bool) {
        if on {
            disabled.remove(.wholeShader(shader))
            let looks = looks(of: shader)
            if !looks.contains(where: isPicked) { disabled.subtract(looks) }
        } else {
            disabled.insert(.wholeShader(shader))
        }
    }

    /// A copy with `change` applied — for asking "would this empty the
    /// rotation?" before doing it.
    public func applying(_ change: (inout LerpRotationSelection) -> Void) -> LerpRotationSelection {
        var copy = self
        change(&copy)
        return copy
    }
}
