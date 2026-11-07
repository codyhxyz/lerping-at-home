import Foundation
import simd

// The contract between the parts of the 3D critter (SceneKit + Blender models).
//
//   CritterBehavior.frame(…) -> CritterFrame     what it is doing this frame (pure)
//   CritterScene                                 SceneKit graph: places/poses nodes from a frame,
//                                                renders offscreen into a texture each frame
//   CritterLook                                  materials: toon light, outlines, the rolled
//                                                world, face decals, sea, sky
//   Sources/Critter/*.usdz                       models made by tools/critter-assets (Blender)
//   critter.metal                                compositor: the scene texture + 2D overlays
//
// Coordinates: SceneKit's, Y up, one unit = one unit of the old raymarched
// scene. The island is centred on the origin, ground near y = 0, radius 7,
// sea level y = -0.2. Every value here is a pure function of (time, seed,
// parameters, vitals): nothing in the 3D critter may accumulate across frames
// (LerpPreview stills must reproduce byte for byte).

/// Everything that varies per frame, in world units, unbent (the bend is
/// applied by CritterLook's geometry modifier around `focus`).
public struct CritterFrame: Equatable, Sendable {
    // ---- who it is
    public var stage: Int = 2              // 0 egg, 1 baby, 2 child, 3 grown
    public var size: Float = 0.42          // body radius `s`; the critter node is scaled by this
    public var season: Int = 0             // 0 spring 1 summer 2 autumn 3 winter
    public var identity: Float = 0.31
    public var health: Float = 0.85
    public var bloom: Float = 0.7
    public var ageDays: Float = 9
    public var hatch: Float = 0            // egg cracks 0…1
    public var wobble: Float = 0           // egg roll, radians

    // ---- its pose (same meanings as the old shader's Pose/Scene fields)
    public var position = SIMD3<Float>(0, 0, 0)   // its feet, world space
    public var yaw: Float = 0              // local +Z (its face) points along (sin yaw, 0, cos yaw)
    public var lean: Float = 0             // forward tilt about its feet, radians
    public var roll: Float = 0             // sideways tilt, radians
    public var squash: Float = 1           // vertical scale; horizontal is 1/sqrt(squash)
    public var armL: Float = 0.35          // 0 hanging, π/2 out to the side, ~2.9 overhead
    public var armR: Float = 0.35
    public var reach: Float = 0            // 0…1 arms swing forward
    public var sit: Float = 0              // 0…1 seated, feet forward
    public var stride: Float = 0           // walking amplitude
    public var step: Float = 0             // walking phase, radians
    public var eye: Float = 1              // 0 shut … 1 open
    public var lid: Float = 0              // 0…0.85 eyelid down
    public var lidTilt: Float = 0          // + worried/sad, − cross
    public var happy: Float = 0            // 1 ^^ arcs, −1 closed sleeping arcs
    public var mouth: Float = 0.5          // −1 frown … 1 smile
    public var mouthO: Float = 0           // 0…1 open mouth
    public var bags: Float = 0             // 0…1 under-eye shadows
    public var droop: Float = 0            // 0…1 sprout wilts

    // ---- its things
    public var cloud: Float = 0            // storm/rain cloud scale, 0 = none
    public var cloudDark: Float = 0        // 1 storm (pacing), 0 rain (poorly)
    public var cloudPos = SIMD3<Float>(0, 1.5, 0)
    public var castle: Float = 0           // sandcastle built 0…1 (0 = none)
    public var castlePos = SIMD3<Float>(0.5, 0, 0.3)
    public var butterfly: Float = 0        // visibility 0…1
    public var butterflyPos = SIMD3<Float>(1, 1, 0)
    public var butterflyYaw: Float = 0
    public var flap: Float = 0             // wing angle, radians

    // ---- the island's record
    public var treeCount: Int = 2
    /// (x, z, size, sink 0…1) per tree; sink 1 = sunk out of the camera's way.
    public var trees: [SIMD4<Float>] = []
    /// (x, z, size) per rock.
    public var rocks: [SIMD3<Float>] = []

    // ---- camera (pinhole; focal 2.7 means the short screen side spans
    // 2 units at distance 2.7, i.e. vertical FOV = 2·atan(1/focal) on landscape)
    public var camPos = SIMD3<Float>(0, 2.4, 3.6)
    public var camTarget = SIMD3<Float>(0, 0.6, 0)
    public var camFocal: Float = 2.7
    public var focus = SIMD2<Float>(0, 0) // centre of the rolled world
    public var bend: Float = 0.011        // world y drops by bend·|xz − focus|²

    // ---- light from the clock
    public var hour: Float = 14.5
    public var night: Float = 0
    public var golden: Float = 0
    public var sunDir = SIMD3<Float>(0, 1, 0)
    public var moonDir = SIMD3<Float>(-0.4, 0.75, -0.5)
    public var lightDir = SIMD3<Float>(0, 1, 0)   // the one that lights (sun or moon)
    public var sunColor = SIMD3<Float>(1.12, 1.04, 0.92)
    public var skyAmbient = SIMD3<Float>(0.55, 0.7, 0.95)

    // ---- story, for the 2D overlays (each 0…1 how much is showing)
    public var act: Int = 0
    public var prevAct: Int = 0
    public var k: Float = 1
    public var zzz: Float = 0
    public var love: Float = 0             // hearts
    public var glee: Float = 0             // sparkles
    public var sick: Float = 0             // rain
    public var storm: Float = 0            // lightning, scribble
    public var flash: Float = 0            // lightning flash this frame
    public var sweat: Float = 0
    public var bang: Float = 0             // "!" double-take
    public var time: Float = 0

    public init() {}
}
