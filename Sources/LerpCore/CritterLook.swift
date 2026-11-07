import Foundation
import SceneKit

/// Materials for the 3D critter: toon light, outlines, the rolled world, face
/// decals, sea, sky. STUB: Lane LOOK fills this in. See CritterFrame.swift.
public enum CritterLook {
    /// Once, after the scene graph is built: assign materials/shader modifiers.
    public static func prepare(scene: SCNScene) {}
    /// Every frame: push per-frame values (time, light, bend, expression…).
    public static func update(scene: SCNScene, frame: CritterFrame) {}
}
