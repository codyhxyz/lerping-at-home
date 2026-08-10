import AppKit

/// The MIDI strip under the parameter list: what is plugged in, which mapping
/// bank is live, and what the last knob did.
///
/// Switching banks is the popup; the same popup carries new/rename/delete so the
/// whole feature is one control plus two labels. Per-parameter Learn lives on
/// the parameter rows themselves, where the parameter is.
final class MIDIPanel: NSView {

    enum Action { case select(String), new, rename, delete }

    var onAction: ((Action) -> Void)?

    private let devices = Chrome.label("MIDI off", size: 10.5)
    private let mappings = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = Chrome.label("", size: 10.5)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        mappings.controlSize = .small
        mappings.font = .systemFont(ofSize: 11)
        mappings.target = self
        mappings.action = #selector(mappingChanged)
        mappings.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        let body = Chrome.pane([
            Chrome.bar([Chrome.label("MIDI", size: 10.5, color: EditorTheme.text),
                        devices, Chrome.flexible()], height: 28),
            Chrome.bar([Chrome.label("Mapping", size: 10.5, color: EditorTheme.text),
                        mappings, Chrome.flexible()], height: 30),
            Chrome.bar([status, Chrome.flexible()], height: 24),
        ])
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func showDevices(_ text: String) { devices.stringValue = text }

    func showStatus(_ text: String, tint: NSColor = EditorTheme.dim) {
        status.stringValue = text
        status.textColor = tint
    }

    /// Rebuilds the bank list. The editing commands ride along at the bottom of
    /// the same menu so the panel needs no button row.
    func showMappings(_ names: [String], selected: String?, enabled: Bool) {
        mappings.removeAllItems()
        mappings.menu?.autoenablesItems = false   // the per-item states below are the truth
        mappings.isEnabled = enabled
        if names.isEmpty {
            mappings.addItem(withTitle: "None")
            mappings.lastItem?.isEnabled = false
        }
        for name in names { mappings.addItem(withTitle: name) }
        mappings.menu?.addItem(.separator())
        for (title, action) in [("New Mapping…", Action.new), ("Rename…", .rename), ("Delete", .delete)] {
            let item = NSMenuItem(title: title, action: #selector(command), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionBox(action)
            item.isEnabled = enabled && (names.isEmpty ? action == .new : true)
            mappings.menu?.addItem(item)
        }
        if let selected, names.contains(selected) { mappings.selectItem(withTitle: selected) }
    }

    /// Steps to the next bank, for the "Next Mapping" menu command. Returns the
    /// newly selected name, or nil when there is nothing to step through.
    @discardableResult
    func cycleMapping() -> String? {
        let names = mappings.itemArray.prefix { $0.representedObject == nil && $0.isEnabled }.map(\.title)
        guard names.count > 1, let current = mappings.titleOfSelectedItem,
              let index = names.firstIndex(of: current) else { return nil }
        let next = names[(index + 1) % names.count]
        mappings.selectItem(withTitle: next)
        onAction?(.select(next))
        return next
    }

    private final class ActionBox {
        let action: Action
        init(_ action: Action) { self.action = action }
    }

    @objc private func mappingChanged() {
        guard let title = mappings.titleOfSelectedItem,
              mappings.selectedItem?.representedObject == nil else { return }
        onAction?(.select(title))
    }

    @objc private func command(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        onAction?(box.action)
    }
}

extension MIDIPanel.Action: Equatable {}
