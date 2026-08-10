import Foundation

/// The screensaver defaults identity shared by every host that reads or writes it.
public enum LerpDefaults {
    public static let productionModule = "com.hergenroeder.lerping"
    public static let module = ProcessInfo.processInfo.environment["LERP_DEFAULTS_MODULE"]
        ?? productionModule
}
