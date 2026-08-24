import Foundation

/// The screensaver defaults identity shared by every host that reads or writes
/// it — and the one gate that decides who is allowed to write the user's real
/// rotation.
///
/// # Why there is a gate
///
/// The live rotation on this machine was found carrying `writer: "writeprobe"`,
/// a name that appears nowhere in this repository: a throwaway probe from some
/// earlier debugging session had written the user's real selection and left.
/// Every look the screensaver played for the next two days came from a harness
/// rather than from anything the user clicked, and — worse for the three
/// rounds of "the rotation is fixed now" that followed — the harness was both
/// setting the state *and* checking it, so it agreed with itself no matter what
/// the screensaver did.
///
/// This was not the first time. `4b91f56 "Stop the self-test writing the
/// user's real rotation"` fixed one instance of it by hand; `writeprobe`
/// arrived afterwards. Fixing instances does not work, because writing to the
/// production domain was the *default* behaviour and staying out of it took an
/// act of care from every new throwaway binary.
///
/// So the default is inverted here. A host that wants the production domain
/// must be one of `trustedWriters`; anything else either sets
/// `LERP_DEFAULTS_MODULE` and gets its own domain, or has its writes refused
/// and logged. Reads are never restricted — a probe that wants to *look* at the
/// real rotation is exactly what a probe is for.
public enum LerpDefaults {

    /// The domain the user's real screensaver reads. Under the sandbox this
    /// names the ByHost plist that `LerpSaverView` reads by hand, because
    /// `ScreenSaverDefaults` inside `legacyScreenSaver` resolves to Apple's
    /// container instead.
    public static let productionModule = "com.hergenroeder.lerping"

    /// Set this in the environment to send a host at its own scratch domain.
    /// The whole of what a harness has to do to be safe.
    public static let moduleOverrideVariable = "LERP_DEFAULTS_MODULE"

    /// The domain this process actually uses.
    public static let module: String = {
        guard let override = ProcessInfo.processInfo.environment[moduleOverrideVariable],
              !override.isEmpty
        else { return productionModule }
        return override
    }()

    /// Whether this process is pointed at the user's real settings.
    public static var isProduction: Bool { module == productionModule }

    /// The two hosts that legitimately own the user's rotation: the
    /// screensaver's Options… sheet and the playground's rotation gallery.
    ///
    /// Held here rather than as a `writerName` constant in each of them. They
    /// were declared separately before, which meant the set of legitimate
    /// writers was not written down anywhere and could not be checked against.
    public static let saverWriter = "saver"
    public static let playgroundWriter = "playground"
    public static let trustedWriters: Set<String> = [saverWriter, playgroundWriter]

    /// Whether `writer` may write the domain this process resolved to.
    ///
    /// Anything outside the production domain is a scratch domain and is
    /// nobody's business but its owner's, so the check is only ever about the
    /// real one.
    public static func mayWrite(writer: String) -> Bool {
        !isProduction || trustedWriters.contains(writer)
    }
}
