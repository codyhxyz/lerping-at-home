import Foundation
import simd

/// What the critter is doing, as a pure function of (time, seed, params,
/// vitals). STUB: Lane BEHAVIOR ports the old shader's story/pose/camera/
/// placement/light logic here. See CritterFrame.swift for the contract.
public enum CritterBehavior {
    /// Ground height of the island at (x, z) — the old shader's groundH.
    public static func groundHeight(_ xz: SIMD2<Float>, identity: Float) -> Float { 0.04 }

    public static func frame(vitals: CritterVitals, time: Float, seed: Float,
                             params: LerpParameterValues?) -> CritterFrame {
        var f = CritterFrame()
        f.time = time
        return f
    }
}
