import Foundation

/// The two deterministic number generators this project needs in more than one
/// place, and the reason both are written out rather than taken from the
/// standard library: **Swift seeds `Hasher` per process**, so `hashValue` is not
/// the same number twice and `SystemRandomNumberGenerator` is not reproducible
/// at all. Everything here has to survive a relaunch —
///
/// - a gallery still's filename, baked into a `.saver` at build time and looked
///   for again at runtime (`RotationThumbnails.hash`),
/// - a digest of what the last write left in `UserDefaults`, compared against
///   what is there now (`LerpRotation.digest`),
/// - a shader's frame, which is a pure function of `(source, params, time,
///   seed)` and therefore of whatever a data provider derives from the seed
///   (`PipesData`, `HeatmapData`),
///
/// — so none of it may use anything the runtime is free to salt.
///
/// Both were transcribed twice before this file existed, with the same magic
/// constants written out in two spellings each. The numbers they produce are
/// load-bearing in files on disk, so a copy that drifted would not be a bug you
/// could see: it would be a cache that never hits and a rotation digest that
/// never matches.

// MARK: - FNV-1a

/// 64-bit FNV-1a over a string's UTF-8. Callers format the result themselves,
/// because the two of them format it differently and both spellings are already
/// written down: `%016llx` in every cached still's filename, bare
/// `String(_:radix:)` in the saved rotation's legacy digest.
public enum LerpHash {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325

    /// FNV-1a's 64-bit prime, 2^40 + 2^8 + 0xb3.
    public static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// The multiplier `LerpRotation.digest` has always used: FNV's with one
    /// extra zero in the middle of it.
    ///
    /// A transcription slip, and one that has to stay. The digest's whole job is
    /// to be compared against the number the *last* write left in
    /// `UserDefaults`, so correcting the constant would make every rotation
    /// already saved on every machine look, exactly once, as though an older
    /// build had written the legacy keys behind the current record's back — the
    /// one condition this digest exists to detect. It recovers from that (the v1
    /// keys are written by the same call and say the same thing, so the same set
    /// comes back) but it recovers by losing the record's `updatedAt` and
    /// relabelling its writer, and no amount of tidiness is worth spending a
    /// user's saved state on.
    ///
    /// Nothing depends on the multiplier being FNV's. Avalanche is all this
    /// needs and any odd multiplier with high bits set gives it; what it needs
    /// and *does* have is to be the same number next launch. The name was the
    /// only thing that was wrong, and it is now the parameter rather than a
    /// silent literal.
    static let rotationDigestPrime: UInt64 = 0x1000_0000_01b3

    public static func fnv1a(_ text: String, prime: UInt64 = prime) -> UInt64 {
        var value = offsetBasis
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* prime
        }
        return value
    }
}

// MARK: - splitmix64

/// Sebastiano Vigna's splitmix64: one multiply-xorshift finaliser over a
/// counter, which is all a data provider needs to turn `u.seed` into a stream of
/// choices. Fast, allocation-free, and — the part that matters here — a pure
/// function of its state, so a provider that rebuilds its whole world from
/// `(seed, time)` every frame gets the same world every time.
///
/// The state is public and set directly by the caller: each provider stirs the
/// raw seed bits its own way, and those recipes are what its existing pictures
/// were rendered from.
public struct LerpSplitMix64 {

    /// The 64-bit golden-ratio constant, splitmix64's increment. Providers also
    /// use it to stir a raw `Float` seed before it reaches the state — same
    /// constant, same job.
    public static let gamma: UInt64 = 0x9E37_79B9_7F4A_7C15

    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        state = state &+ Self.gamma
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A whole number in `0..<n`.
    public mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }

    /// A `Double` in `[0, 1)`, from the top 53 bits.
    public mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}
