import Foundation
import MIDIDeps

/// Everything that touches Core MIDI. One `MIDIManager`, one input connection
/// to every output endpoint in the system, and control-change messages handed to
/// the main thread as plain values.
///
/// Nothing above this line in the app knows the MIDI library exists, and nothing
/// here fails hard: a machine with no interface plugged in gets `isAvailable ==
/// false` and the playground runs exactly as it did before.
///
/// `@unchecked Sendable` because the receive closure Core MIDI calls is
/// `@Sendable` and needs a reference back here to hop to the main thread. Every
/// stored property is written and read on the main thread only; the closure
/// itself touches nothing but `DispatchQueue.main`.
final class MIDIController: @unchecked Sendable {

    /// A control-change message, already flattened out of `MIDIEvent`.
    struct Message {
        let channel: UInt4
        let cc: UInt7
        let value: UInt8
        let sourceID: String
        let sourceName: String
    }

    struct Source: Equatable {
        let id: String
        let name: String
    }

    private(set) var isAvailable = false
    /// Why MIDI is off, when it is off. Shown in the panel instead of silence.
    private(set) var unavailableReason: String?
    private(set) var sources: [Source] = []

    /// Called on the main thread for every inbound CC.
    var onMessage: ((Message) -> Void)?
    /// Called on the main thread when endpoints come or go.
    var onSourcesChanged: (() -> Void)?

    private var manager: MIDIManager?

    /// Opens the Core MIDI client and connects to every output endpoint,
    /// including ones that appear later. Safe to call when no hardware exists.
    func start() {
        let manager = MIDIManager(clientName: "LerpPlayground",
                                  model: "Lerping@Home Playground",
                                  manufacturer: "Lerping@Home")
        manager.notificationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshSources() }
        }
        do {
            try manager.start()
            try manager.addInputConnection(
                to: .allOutputs,
                tag: "lerp-playground-in",
                receiver: .events(options: [.filterActiveSensingAndClock]) { [weak self] events, _, source in
                    let id = source.map { String(describing: $0.uniqueID) } ?? ""
                    let name = source?.displayName ?? ""
                    let messages = events.compactMap { event -> Message? in
                        guard case let .cc(cc) = event else { return nil }
                        return Message(channel: cc.channel, cc: cc.controller.number,
                                       value: UInt8(cc.value.midi1Value),
                                       sourceID: id, sourceName: name)
                    }
                    guard !messages.isEmpty else { return }
                    DispatchQueue.main.async {
                        guard let self else { return }
                        messages.forEach { self.onMessage?($0) }
                    }
                })
        } catch {
            unavailableReason = String(describing: error)
            return
        }
        self.manager = manager
        isAvailable = true
        refreshSources()
    }

    private func refreshSources() {
        guard let manager else { return }
        let found = manager.endpoints.outputs.map {
            Source(id: String(describing: $0.uniqueID), name: $0.displayName)
        }
        guard found != sources else { return }
        sources = found
        onSourcesChanged?()
    }

    /// Human-readable one-liner for the panel's first row.
    var summary: String {
        guard isAvailable else { return "Core MIDI unavailable" }
        return sources.isEmpty ? "No MIDI devices connected" : sources.map(\.name).joined(separator: ", ")
    }
}
