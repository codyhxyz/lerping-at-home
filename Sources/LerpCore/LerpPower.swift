import Foundation
import IOKit.ps
import os

/// The power conditions EDR gives way to. Frame rate gives way to none of them.
///
/// There used to be frame-rate caps of our own here: 20 fps on battery, 15 in
/// Low Power Mode, 15 and 10 under serious and critical thermal pressure. macOS
/// manages all three itself — its Low Power Mode throttle reaches every app's
/// display link, and under thermal pressure it slows the GPU, which the pacer
/// in `LerpMetalView` then measures like any other slow frame. macOS's own
/// screensavers carry no caps of their own. Neither do ours now.
///
/// EDR: held back on battery and in Low Power Mode in the screensaver, where
/// a 16-bit pass to brighten highlights nobody is watching is the wrong trade.
/// The playground opts out (`LerpPowerMonitor.savesPower`): it is the thing
/// the user is looking at.
public struct LerpPowerState: Equatable, Sendable {
    public var lowPowerMode: Bool
    /// The machine is running on battery. `onBattery` and `lowPowerMode` are
    /// always the truth, whether or not this process acts on them — see
    /// `savesPower`.
    public var onBattery: Bool
    /// Whether battery and Low Power Mode hold back EDR in this process.
    /// False in the playground.
    public var savesPower: Bool

    public init(lowPowerMode: Bool = false, onBattery: Bool = false, savesPower: Bool = true) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.savesPower = savesPower
    }

    /// Low Power Mode, in a process that holds back for it.
    public var throttledByLowPowerMode: Bool { lowPowerMode && savesPower }
    /// On battery, in a process that holds back for it.
    public var throttledByBattery: Bool { onBattery && savesPower }

    /// For the log: every condition, so a transition line says what changed.
    public var summary: String {
        let ignored = savesPower ? "" : " (EDR not held back here)"
        return "\(onBattery ? "battery" : "AC"), lowPower=\(lowPowerMode ? "on" : "off")\(ignored)"
    }
}

/// One per process: reads `LerpPowerState`, watches both of its sources, and
/// logs when the answer moves. `LerpEDR.blocker` reads `state` as it draws.
///
/// Process-wide rather than per view because the conditions are, and because
/// a `legacyScreenSaver` host can hold one view per display: each building its
/// own IOKit run-loop source would log every transition once per screen.
@MainActor
public final class LerpPowerMonitor {
    public static let shared = LerpPowerMonitor()
    /// Whether battery and Low Power Mode hold back EDR in this process. Set
    /// it before anything touches `shared` — the first read, and its log line,
    /// happen then. The playground sets it false at launch.
    public static var savesPower = true

    /// Same subsystem as every other Lerping line — see `LerpMetalView.log`.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "power")

    public private(set) var state: LerpPowerState
    private var observers: [NSObjectProtocol] = []

    private init() {
        state = Self.read()
        // `.notice` so it reaches the on-disk store: why EDR was off during a
        // session is exactly the kind of thing somebody asks about days later.
        // See `LerpMetalView.loadEntry`.
        Self.log.notice("power: \(self.state.summary, privacy: .public)")

        // Posted on whatever thread noticed the change.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LerpPowerMonitor.shared.refresh("low power mode") }
        })

        // AC/battery has no Foundation notification; IOKit's is a run-loop
        // source that fires on every power-source change (including each
        // percent of charge, which `refresh` drops as no change). The callback
        // is a C function pointer and cannot capture, hence `shared`. If the
        // sandbox refuses the source, the state read above is all there is and
        // `onBattery` simply never moves — nothing worse than before this
        // existed.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { LerpPowerMonitor.shared.refresh("power source") } }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        } else {
            Self.log.error("power: no IOKit power-source notifications; AC/battery will not be tracked")
        }
    }

    private func refresh(_ trigger: String) {
        let new = Self.read()
        guard new != state else { return }
        let old = state
        state = new
        Self.log.notice("power: \(old.summary, privacy: .public) → \(new.summary, privacy: .public) (\(trigger, privacy: .public))")
    }

    private static func read() -> LerpPowerState {
        let info = ProcessInfo.processInfo
        return LerpPowerState(lowPowerMode: info.isLowPowerModeEnabled,
                              onBattery: providingSourceIsBattery(),
                              savesPower: savesPower)
    }

    /// Unreadable counts as AC: an unknown answer must not dim the saver.
    private static func providingSourceIsBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
