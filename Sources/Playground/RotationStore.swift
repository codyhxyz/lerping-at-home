import Foundation
import ScreenSaver

/// The playground is the sole writer of the ByHost `rotationState` record.
/// Gallery edits and App Intents serialize all writes here, without touching
/// the saver's own settings in Apple's sandbox container.
enum RotationStore {
    static let module = LerpDefaults.module
    static let writerName = LerpDefaults.playgroundWriter
    private static let writeLock = NSLock()

    static func saverDefaults() -> UserDefaults? {
        ScreenSaverDefaults(forModuleWithName: module)
    }

    // MARK: - Reading

    static func state(discovered: [LerpRotationEntry],
                      from defaults: UserDefaults?) -> LerpRotationState {
        LerpRotation.read(defaults, discovered: discovered)
    }

    static var profiles: [RotationProfile] { LerpRotation.read(saverDefaults()).profiles }
    static var activeProfileID: UUID { LerpRotation.read(saverDefaults()).activeID }

    static func selection(discovered: [LerpRotationEntry],
                          from defaults: UserDefaults?) -> LerpRotationSelection {
        LerpRotation.selection(discovered: discovered,
                               in: state(discovered: discovered, from: defaults))
    }

    static func rotation(discovered: [LerpRotationEntry],
                         from defaults: UserDefaults?) -> [LerpRotationEntry] {
        selection(discovered: discovered, from: defaults).playable
    }

    // MARK: - Writing

    @discardableResult
    static func save(_ selection: LerpRotationSelection,
                     to defaults: UserDefaults?) -> LerpRotationState {
        writeLock.withLock { LerpRotation.write(selection, writer: writerName, to: defaults) }
    }

    /// Refresh the picker after a write made outside the gallery.
    static let changedElsewhere = Notification.Name("LerpRotationChangedElsewhere")

    private static func update<Result>(_ defaults: UserDefaults?,
                                       _ change: (inout LerpRotationState) throws -> Result) throws -> Result {
        let (result, changed) = try writeLock.withLock {
            guard let defaults else { throw RotationProfileError.notSaved }
            let before = LerpRotation.read(defaults)
            var next = before
            let result = try change(&next)
            guard next != before else { return (result, false) }
            guard LerpRotation.persist(&next, writer: writerName, to: defaults) else {
                throw RotationProfileError.notSaved
            }
            return (result, true)
        }
        if changed {
            if Thread.isMainThread {
                NotificationCenter.default.post(name: changedElsewhere, object: nil)
            } else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: changedElsewhere, object: nil) }
            }
        }
        return result
    }

    // MARK: - Named playlists

    @discardableResult
    static func createProfile(name: String, admission: RotationProfile.Admission,
                              initialLooks: some Sequence<LerpRotationEntry>, catalog: [LerpRotationEntry],
                              defaults: UserDefaults? = saverDefaults()) throws -> RotationProfile {
        try update(defaults) {
            try $0.createProfile(name: name, admission: admission, initialLooks: initialLooks, catalog: catalog)
        }
    }

    static func renameProfile(id: UUID, to name: String, defaults: UserDefaults? = saverDefaults()) throws {
        try update(defaults) { try $0.renameProfile(id: id, to: name) }
    }

    static func deleteProfile(id: UUID, defaults: UserDefaults? = saverDefaults()) throws {
        try update(defaults) { try $0.deleteProfile(id: id) }
    }

    @discardableResult
    static func setActiveProfile(id: UUID, catalog: [LerpRotationEntry],
                                 defaults: UserDefaults? = saverDefaults()) throws -> Bool {
        try update(defaults) {
            let changed = $0.activeID != id
            try $0.setActiveProfile(id: id, catalog: catalog)
            return changed
        }
    }

    static func addExactLook(key: String, toProfile id: UUID, catalog: [LerpRotationEntry],
                             defaults: UserDefaults? = saverDefaults()) throws {
        try update(defaults) { try $0.addExactLook(LerpRotationEntry(key: key), toProfile: id, catalog: catalog) }
    }

    /// Discover and Import add exact looks to whichever profile is active at
    /// the time of the write, without overwriting concurrent Shortcuts edits.
    static func addLooks(_ looks: Set<LerpRotationEntry>, catalog: [LerpRotationEntry],
                         defaults: UserDefaults?) throws -> LerpRotationSelection {
        try update(defaults) { state in
            for look in catalog where looks.contains(look) {
                try state.addExactLook(look, toProfile: state.activeID, catalog: catalog)
            }
            return LerpRotation.selection(discovered: catalog, in: state)
        }
    }

    // MARK: - One look at a time

    @discardableResult
    static func setLook(_ entry: LerpRotationEntry, enabled: Bool,
                        discovered: [LerpRotationEntry] = LookCatalog.discovered(),
                        defaults: UserDefaults? = saverDefaults()) throws -> Bool {
        guard !discovered.isEmpty else { throw LookIntentError.noLooks }
        guard !entry.isWholeShader, discovered.contains(entry) else { throw LookIntentError.unknownLook(entry.key) }
        do {
            return try update(defaults) { state in
                let before = LerpRotation.selection(discovered: discovered, in: state)
                guard before.plays(entry) != enabled else { return false }
                if enabled {
                    try state.addExactLook(entry, toProfile: state.activeID, catalog: discovered)
                } else {
                    let after = before.applying { $0.setLook(entry, on: false) }
                    guard !after.playable.isEmpty else { throw LookIntentError.lastLook(entry.key) }
                    state.disabled = after.disabled
                    state.roster = after.roster
                }
                return true
            }
        } catch RotationProfileError.notSaved {
            throw LookIntentError.notSaved(entry.key)
        }
    }
}
