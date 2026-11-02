import AppIntents
import Foundation
import Metal

/// Shortcuts and Spotlight actions for the screensaver's rotation.
///
/// These are not a second writer. App Intents run inside the app that declares
/// them, so every `perform()` here executes in LerpPlayground's own process and
/// writes through `RotationStore.setLook` — the same `RotationStore.save` →
/// `LerpRotation.write` path a click in the gallery takes, into the same ByHost
/// `rotationState` record, with no keys of its own. If the playground is not
/// running, the system launches it to run the action.
///
/// What is deliberately not here: pinning. The pin (`shader` / `preset` in the
/// saver's own settings) belongs to the screensaver's Options… sheet and lives
/// in Apple's sandbox container, where only that sheet writes it. A pin intent
/// would be a second writer of a second store — the exact shape of every bug
/// AGENTS.md's "Where the rotation lives" was written to end. "Solo this look"
/// (switch every other one off) is not offered either: it overwrites a
/// selection nobody could reconstruct afterwards.
///
/// The metadata Shortcuts reads (`Contents/Resources/Metadata.appintents`) is
/// produced by the Makefile running `appintentsmetadataprocessor` over the
/// compiler's `.swiftconstvalues`, the step Xcode would otherwise do. Keep the
/// static titles, descriptions and phrases below as plain literals: they are
/// read at build time from the constant-value dump, not at run time.

// MARK: - The look

/// One look — a shader and one of its presets, or its declared defaults — as
/// Shortcuts sees it. The identifier is `LerpRotationEntry.key`, the same
/// string the `rotationState` record stores, so it round-trips exactly.
struct LookEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Look"
    static let defaultQuery = LookQuery()

    var id: String

    @Property(title: "Shader")
    var shader: String

    @Property(title: "Preset")
    var preset: String

    @Property(title: "In Rotation")
    var inRotation: Bool

    init(entry: LerpRotationEntry, inRotation: Bool) {
        id = entry.key
        shader = entry.shader
        preset = entry.displayName
        self.inRotation = inRotation
    }

    var entry: LerpRotationEntry { LerpRotationEntry(key: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(shader) — \(preset)",
            subtitle: inRotation ? "In the rotation" : "Switched off")
    }
}

/// Every look on disk, and which of them the screensaver will shuffle through.
/// Read fresh on every call: a Shortcut can run long after the library or the
/// rotation last changed.
enum LookCatalog {
    struct Snapshot {
        let discovered: [LerpRotationEntry]
        let enabled: Set<LerpRotationEntry>

        var looks: [LookEntity] {
            discovered.map { LookEntity(entry: $0, inRotation: enabled.contains($0)) }
        }
    }

    /// The same discovery the editor window does: the checkout `RepoLocation`
    /// settled on, plus the user's custom-shader folder.
    static func discovered() -> [LerpRotationEntry] {
        guard let device = MTLCreateSystemDefaultDevice() else { return [] }
        return ShaderLibrary(device: device, extraSearchURLs: RepoLocation.searchURLs)
            .discover().rotationEntries()
    }

    static func snapshot(defaults: UserDefaults? = RotationStore.saverDefaults()) -> Snapshot {
        let discovered = discovered()
        return Snapshot(discovered: discovered,
                        enabled: RotationStore.resolved(discovered: discovered, from: defaults))
    }
}

struct LookQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [LookEntity.ID]) async throws -> [LookEntity] {
        let looks = LookCatalog.snapshot().looks
        return identifiers.compactMap { id in looks.first { $0.id == id } }
    }

    /// All of them, in the gallery's order. Shortcuts' picker searches this
    /// list itself, so 123 looks is not too many to hand over.
    @MainActor
    func suggestedEntities() async throws -> [LookEntity] {
        LookCatalog.snapshot().looks
    }

    @MainActor
    func entities(matching string: String) async throws -> [LookEntity] {
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let looks = LookCatalog.snapshot().looks
        guard !needle.isEmpty else { return looks }
        return looks.filter {
            $0.id.localizedCaseInsensitiveContains(needle)
                || $0.preset.localizedCaseInsensitiveContains(needle)
        }
    }
}

// MARK: - Errors

enum LookIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLooks
    case unknownLook(String)
    case lastLook(String)
    case notSaved(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLooks:
            return "LerpPlayground found no shaders, so there is no rotation to change."
        case let .unknownLook(key):
            return "There is no look called \(key) any more."
        case let .lastLook(key):
            return "\(key) is the last look in the rotation. The rotation must keep at least one look."
        case let .notSaved(key):
            return "The rotation could not be saved, so \(key) was not changed."
        }
    }
}

// MARK: - Intents

struct AddLookToRotationIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Look to Rotation"
    static let description = IntentDescription(
        "Puts a look back into the Lerping@Home screensaver's shuffle rotation.")

    @Parameter(title: "Look")
    var look: LookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$look) to the screensaver rotation")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LookEntity> & ProvidesDialog {
        let changed = try RotationStore.setLook(look.entry, enabled: true)
        let result = LookEntity(entry: look.entry, inRotation: true)
        let name = result.displayRepresentation.title
        return .result(value: result,
                       dialog: changed ? "Added \(name) to the rotation."
                                       : "\(name) was already in the rotation.")
    }
}

struct RemoveLookFromRotationIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove Look from Rotation"
    static let description = IntentDescription(
        "Switches a look off in the Lerping@Home screensaver's shuffle rotation. The last look cannot be removed.")

    @Parameter(title: "Look")
    var look: LookEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$look) from the screensaver rotation")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<LookEntity> & ProvidesDialog {
        let changed = try RotationStore.setLook(look.entry, enabled: false)
        let result = LookEntity(entry: look.entry, inRotation: false)
        let name = result.displayRepresentation.title
        return .result(value: result,
                       dialog: changed ? "Removed \(name) from the rotation."
                                       : "\(name) was already switched off.")
    }
}

enum LookFilter: String, AppEnum {
    case all
    case inRotation
    case switchedOff

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Which Looks"
    static let caseDisplayRepresentations: [LookFilter: DisplayRepresentation] = [
        .all: "All Looks",
        .inRotation: "In the Rotation",
        .switchedOff: "Switched Off",
    ]
}

struct ListLooksIntent: AppIntent {
    static let title: LocalizedStringResource = "List Looks"
    static let description = IntentDescription(
        "Lists the Lerping@Home looks — every shader and preset — and whether each is in the screensaver rotation.")

    @Parameter(title: "Which", default: .all)
    var filter: LookFilter

    static var parameterSummary: some ParameterSummary {
        Summary("List \(\.$filter)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[LookEntity]> {
        let looks = LookCatalog.snapshot().looks
        switch filter {
        case .all: return .result(value: looks)
        case .inRotation: return .result(value: looks.filter(\.inRotation))
        case .switchedOff: return .result(value: looks.filter { !$0.inRotation })
        }
    }
}

// MARK: - Shortcuts app / Spotlight

struct LerpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddLookToRotationIntent(),
                    phrases: ["Add a look to the \(.applicationName) rotation"],
                    shortTitle: "Add to Rotation",
                    systemImageName: "plus.circle")
        AppShortcut(intent: RemoveLookFromRotationIntent(),
                    phrases: ["Remove a look from the \(.applicationName) rotation"],
                    shortTitle: "Remove from Rotation",
                    systemImageName: "minus.circle")
        AppShortcut(intent: ListLooksIntent(),
                    phrases: ["List \(.applicationName) looks"],
                    shortTitle: "List Looks",
                    systemImageName: "square.grid.3x3")
    }
}
