import Foundation

/// The single policy for whether a discovered look plays. A closed profile
/// admits only rostered looks; a picked look still sits out while its shader's
/// `/*` switch is off. The switch preserves per-look picks underneath it.
public struct LerpRotationSelection: Equatable, Sendable {
    /// Every look on disk, in `rotationEntries()` order.
    public let discovered: [LerpRotationEntry]
    public private(set) var disabled: Set<LerpRotationEntry>
    public let admission: RotationProfile.Admission
    public private(set) var roster: [String: [String]]
    /// Protects a gallery edit from being applied to a different active profile.
    public let profileID: UUID?

    public init(discovered: [LerpRotationEntry], disabled: Set<LerpRotationEntry> = []) {
        self.init(discovered: discovered, disabled: disabled, admission: .automatic,
                  roster: LerpRotation.roster(of: discovered), profileID: nil)
    }

    init(discovered: [LerpRotationEntry], disabled: Set<LerpRotationEntry>,
         admission: RotationProfile.Admission, roster: [String: [String]], profileID: UUID?) {
        self.discovered = discovered
        self.admission = admission
        self.roster = roster
        self.profileID = profileID
        if admission == .closed {
            // A temporarily missing shader/preset must not lose its curation.
            self.disabled = disabled
        } else {
            let looks = Set(discovered)
            let shaders = Set(discovered.map(\.shader))
            self.disabled = disabled.filter {
                $0.isWholeShader ? shaders.contains($0.shader) : looks.contains($0)
            }
        }
    }

    // MARK: What plays

    /// Closed rosters represent the Defaults look explicitly as an empty name:
    /// some shaders expose only named presets, and admitting a preset must not
    /// implicitly admit those shaders' Defaults if they appear later.
    private func admits(_ look: LerpRotationEntry) -> Bool {
        admission == .automatic || roster[look.shader]?.contains(look.preset ?? "") == true
    }

    public func isSwitchedOff(_ shader: String) -> Bool {
        disabled.contains(.wholeShader(shader))
    }

    /// Per-look choice, ignoring the shader's switch.
    public func isPicked(_ look: LerpRotationEntry) -> Bool {
        !look.isWholeShader && admits(look) && !disabled.contains(look)
    }

    public func plays(_ look: LerpRotationEntry) -> Bool {
        isPicked(look) && !isSwitchedOff(look.shader)
    }

    public var playable: [LerpRotationEntry] { discovered.filter(plays) }

    public func looks(of shader: String) -> [LerpRotationEntry] {
        discovered.filter { $0.shader == shader }
    }

    public func shaderPlays(_ shader: String) -> Bool {
        looks(of: shader).contains(where: plays)
    }

    // MARK: Changing it

    /// Picking a look from the gallery restores the shader's previous picks.
    /// For a closed profile, the explicitly picked look also joins its roster.
    public mutating func setLook(_ look: LerpRotationEntry, on: Bool) {
        if on {
            if admission == .closed {
                guard !look.isWholeShader, discovered.contains(look) else { return }
                if !admits(look) {
                    let names = (roster[look.shader] ?? []) + [look.preset ?? ""]
                    let present = looks(of: look.shader).map { $0.preset ?? "" }.filter { names.contains($0) }
                    roster[look.shader] = present + names.filter { !present.contains($0) }
                }
            }
            disabled.remove(look)
            disabled.remove(.wholeShader(look.shader))
        } else {
            disabled.insert(look)
        }
    }

    /// Unlike gallery toggles, an exact add never restores sibling looks.
    public mutating func addExactLook(_ look: LerpRotationEntry) {
        guard !look.isWholeShader, discovered.contains(look) else { return }
        if isSwitchedOff(look.shader) {
            let siblings: [LerpRotationEntry]
            if admission == .closed {
                // Cover admitted siblings even if temporarily absent.
                siblings = (roster[look.shader] ?? []).map {
                    LerpRotationEntry(shader: look.shader, preset: $0.isEmpty ? nil : $0)
                }
            } else {
                siblings = looks(of: look.shader)
            }
            disabled.formUnion(siblings.filter { $0 != look })
        }
        setLook(look, on: true)
    }

    public mutating func setLooks(_ looks: some Sequence<LerpRotationEntry>, on: Bool) {
        for look in looks { setLook(look, on: on) }
    }

    /// Restore the shader's picks, or enable all its admitted looks if none
    /// were picked. A shader switch does not admit new looks to a closed list.
    public mutating func setShader(_ shader: String, on: Bool) {
        if on {
            disabled.remove(.wholeShader(shader))
            let looks = looks(of: shader).filter(admits)
            if !looks.contains(where: isPicked) { disabled.subtract(looks) }
        } else {
            disabled.insert(.wholeShader(shader))
        }
    }

    public func applying(_ change: (inout LerpRotationSelection) -> Void) -> LerpRotationSelection {
        var copy = self
        change(&copy)
        return copy
    }
}
