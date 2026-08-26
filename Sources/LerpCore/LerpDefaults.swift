import Foundation

/// The screensaver defaults identity shared by every host that reads or writes
/// it, and the one rule about who may write the user's real rotation.
///
/// # Why there is a rule at all
///
/// The live rotation on this machine was found carrying `writer: "writeprobe"`,
/// a name that appears nowhere in this repository: a throwaway probe from an
/// earlier debugging session had written the user's real selection and left.
///
/// The first attempt at stopping that was an allowlist of *writer names*
/// (`trustedWriters = ["saver", "playground"]`). It has been deleted, because it
/// solved the problem the wrong way round in both directions:
///
/// - It could be walked through by any probe that passed `writer: "saver"`,
///   which is a five-character guess.
/// - It sat in the path between the user's click and the disk, and refused by
///   returning quietly. A host whose name was not on the list would have had
///   every rotation edit silently discarded — which is precisely the class of
///   bug this project keeps re-reporting.
///
/// What replaces it is a fact a probe cannot forge and a real host cannot lose:
/// **the two hosts that own this setting are application bundles, and a
/// throwaway command-line binary is not.** `Bundle.main.bundleIdentifier` is nil
/// for a bare `swiftc -o /tmp/probe` executable and non-nil for the saver (whose
/// host is `legacyScreenSaver.app`) and for `LerpPlayground.app`. So the gate
/// needs no registry of legitimate names, cannot be defeated by choosing a
/// better string, and cannot misfire on a real host, because a real host is a
/// bundle by construction — `make saver` and `make playground` cannot produce
/// anything else.
///
/// Reads are never restricted. A probe that wants to *look* at the real
/// rotation is exactly what a probe is for.
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

    /// Which host wrote a given state. Diagnostics only — nothing branches on
    /// it, and it is not a credential. It is what makes "who turned this back
    /// on?" answerable, which is the only job it ever did well.
    public static let saverWriter = "saver"
    public static let playgroundWriter = "playground"

    /// Whether this process may write the domain it resolved to.
    ///
    /// Anything outside the production domain is a scratch domain and is
    /// nobody's business but its owner's, so the check is only ever about the
    /// real one. See the type comment for why this asks what the process *is*
    /// rather than what it calls itself.
    public static var mayWriteProduction: Bool {
        !isProduction || Bundle.main.bundleIdentifier != nil
    }
}
