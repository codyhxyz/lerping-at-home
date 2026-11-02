import Foundation
import IOKit.ps
import os

/// The machine conditions that cap how fast a `LerpMetalView` may draw.
///
/// A screensaver is the one thing on the machine nobody is waiting for, so it
/// is the first thing that should give way: on battery it is spending charge
/// the user will want later, in Low Power Mode the user has said so outright,
/// and under thermal pressure every frame it draws is heat the fans have to
/// move. None of these stop it — a black screensaver is a bug — they only
/// lower the ceiling the host's own frame-rate setting is clamped to.
public struct LerpPowerState: Equatable, Sendable {
    public var lowPowerMode: Bool
    public var onBattery: Bool
    public var thermal: ProcessInfo.ThermalState

    public init(lowPowerMode: Bool = false, onBattery: Bool = false,
                thermal: ProcessInfo.ThermalState = .nominal) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.thermal = thermal
    }

    /// The highest frame rate these conditions allow, or nil for no cap. The
    /// strictest condition wins; they do not compound.
    ///
    /// Every cap divides both 60 and 120, so a fixed-rate panel and a
    /// ProMotion one land on the same cadence instead of the display link
    /// rounding an awkward number to whatever its refresh divides into.
    public var frameRateCap: Int? {
        switch thermal {
        case .critical: return 10
        case .serious: return 15
        default: break
        }
        if lowPowerMode { return 15 }
        if onBattery { return 20 }
        return nil
    }

    /// The rate to actually ask the display for, given what the host wants.
    public func frameRate(for requested: Int) -> Int {
        frameRateCap.map { min(requested, $0) } ?? requested
    }

    /// For the log: every condition, so a transition line says what changed.
    public var summary: String {
        let thermalName: String
        switch thermal {
        case .nominal: thermalName = "nominal"
        case .fair: thermalName = "fair"
        case .serious: thermalName = "serious"
        case .critical: thermalName = "critical"
        @unknown default: thermalName = "unknown(\(thermal.rawValue))"
        }
        return "\(onBattery ? "battery" : "AC"), lowPower=\(lowPowerMode ? "on" : "off"), thermal=\(thermalName)"
    }
}

/// One per process: reads `LerpPowerState`, watches all three of its sources,
/// and posts `didChange` on the main queue when the answer moves.
///
/// Process-wide rather than per view because the conditions are, and because
/// a `legacyScreenSaver` host can hold one view per display: each building its
/// own IOKit run-loop source would log every transition once per screen.
@MainActor
public final class LerpPowerMonitor {
    public static let shared = LerpPowerMonitor()
    public static let didChange = Notification.Name("LerpPowerStateDidChange")

    /// Same subsystem as every other Lerping line — see `LerpMetalView.log`.
    static let log = Logger(subsystem: LerpDefaults.productionModule, category: "power")

    public private(set) var state: LerpPowerState
    private var observers: [NSObjectProtocol] = []

    private init() {
        state = Self.read()
        // `.notice` so it reaches the on-disk store: a frame-rate ceiling that
        // was in force during a session is exactly the kind of thing somebody
        // asks about days later. See `LerpMetalView.loadEntry`.
        Self.log.notice("power: \(self.state.summary, privacy: .public), frame-rate cap \(Self.describe(self.state.frameRateCap), privacy: .public)")

        // Both of these are posted on whatever thread noticed the change.
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,
                     ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let trigger = note.name == .NSProcessInfoPowerStateDidChange ? "low power mode" : "thermal state"
                MainActor.assumeIsolated { LerpPowerMonitor.shared.refresh(trigger) }
            })
        }

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
        Self.log.notice("""
            power: \(old.summary, privacy: .public) → \(new.summary, privacy: .public) \
            (\(trigger, privacy: .public)); frame-rate cap \(Self.describe(old.frameRateCap), privacy: .public) \
            → \(Self.describe(new.frameRateCap), privacy: .public)
            """)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private static func describe(_ cap: Int?) -> String {
        cap.map { "\($0) fps" } ?? "none"
    }

    private static func read() -> LerpPowerState {
        let info = ProcessInfo.processInfo
        return LerpPowerState(lowPowerMode: info.isLowPowerModeEnabled,
                              onBattery: providingSourceIsBattery(),
                              thermal: info.thermalState)
    }

    /// Unreadable counts as AC: an unknown answer must not slow the saver.
    private static func providingSourceIsBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
