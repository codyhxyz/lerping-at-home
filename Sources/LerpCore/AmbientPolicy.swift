import AppKit

/// Power rules for unattended windows, not the interactive editor or saver.
@MainActor
final class AmbientSurfacePolicy {
    static let shared = AmbientSurfacePolicy()
    static let didChangeNotification = Notification.Name("LerpAmbientSurfacePolicyDidChange")

    enum Hold: String {
        case sleeping = "the display is asleep"
        case lowPower = "Low Power Mode is on"
        case thermal = "the Mac is running hot"
        case occluded = "the window is covered"
    }

    struct Decision {
        let hold: Hold?
        let onBattery: Bool

        func renderScale(_ preferred: Double) -> Double {
            onBattery ? min(preferred, 0.65) : preferred
        }

        func extendedDynamicRange(_ preferred: Bool) -> Bool { preferred && !onBattery }
    }

    private let power = LerpPowerMonitor.shared
    private var displaysSleeping = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [LerpPowerMonitor.didChangeNotification, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.displaysSleeping = note.name == NSWorkspace.screensDidSleepNotification
                    self?.changed()
                }
            })
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func isDisplayAsleep(_ display: CGDirectDisplayID?) -> Bool {
        displaysSleeping || (display.map { CGDisplayIsAsleep($0) != 0 } ?? false)
    }

    /// Machine-wide reasons only, for surfaces that display a status message.
    var systemHold: Hold? {
        if displaysSleeping { return .sleeping }
        if power.state.lowPowerMode { return .lowPower }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return .thermal
        default: return nil
        }
    }

    func decision(display: CGDirectDisplayID?, visible: Bool) -> Decision {
        let hold: Hold? = isDisplayAsleep(display) ? .sleeping : systemHold ?? (visible ? nil : .occluded)
        // Raw power truth: the editor opts out of the monitor's own EDR gating.
        return Decision(hold: hold, onBattery: power.state.onBattery)
    }
}
