import Foundation
import SceneKit
import simd

/// Materials for the 3D critter: toon light, ink outlines, the rolled world,
/// face decals, sea, sky. See CritterFrame.swift for the contract and
/// CritterLookShader.swift for what each shader modifier does.
///
/// Use:
///   1. Build the graph (load the USDZ, clone templates, generate `ground` and
///      `sea`), then call `prepare(scene:)` once. It is idempotent: call it
///      again after adding nodes and only the new ones are touched.
///   2. Every frame, after every transform is set, call `update(scene:frame:)`.
///
/// `prepare` assigns each mesh a role from its own name or its nearest named
/// ancestor (so a USD mesh prim under an Xform `trunk` is bark), keeps the
/// asset's base colour, switches the material to Lambert with the shared
/// shader modifiers, and gives each outlined mesh a child `<name>~ink` (an
/// inverted hull sharing the vertex data). It adds three nodes of its own:
/// `look.sky` (a dome drawn first, no depth), `look.key` (the one directional
/// light, with soft shadows) — nothing else in the scene should light it.
/// Missing nodes are fine: nothing is looked up by force.
public enum CritterLook {

    /// Mirrors the LK_* kinds in the shader.
    enum Kind: Int {
        case generic = 0, body, limb, eye, leaf, blossom, egg, nest, bark, canopy, fruit,
             petal, stem, skyCloud, storm, wing, castle, rock, ground, sea, sky
    }

    /// Nodes CritterLook adds: skip them when walking the graph by name.
    public static let skyName = "look.sky"
    public static let keyName = "look.key"
    /// Suffix of the ink hull child added under each outlined mesh.
    public static let inkSuffix = "~ink"

    /// Ink weight: a share of the screen's height (2.4 px at 1756), never
    /// under `inkMinPx`.
    static let inkFraction: Float = 0.00135
    static let inkMinPx: Float = 1.3

    /// The shared modifiers. One source for all, so few programs compile.
    static let modifiers: [SCNShaderModifierEntryPoint: String] = [
        .geometry: CritterLookShader.geometry,
        .lightingModel: CritterLookShader.lighting,
        .fragment: CritterLookShader.fragment,
    ]

    // ------------------------------------------------------------ prepare

    public static func prepare(scene: SCNScene) {
        let root = scene.rootNode
        if root.childNode(withName: skyName, recursively: false) == nil { root.addChildNode(makeSky()) }
        if root.childNode(withName: keyName, recursively: false) == nil { root.addChildNode(makeKey()) }

        // Collect first: adding ink children while enumerating would mutate.
        var meshes: [SCNNode] = []
        root.enumerateHierarchy { node, _ in
            if node.geometry != nil, !isOwn(node) { meshes.append(node) }
        }
        var inkCache: [ObjectIdentifier: SCNGeometry] = [:]
        for node in meshes {
            guard let geo = node.geometry else { continue }
            let kind = role(of: node)
            for mat in geo.materials {
                let k = refine(kind, mat)
                adopt(mat, kind: k, param: param(for: k, geometry: geo, node: node))
            }
            if outlined(kind), node.childNode(withName: (node.name ?? "") + inkSuffix, recursively: false) == nil {
                let key = ObjectIdentifier(geo)
                let inkGeo = inkCache[key] ?? makeInk(geo, kind: kind, node: node)
                inkCache[key] = inkGeo
                let ink = SCNNode(geometry: inkGeo)
                ink.name = (node.name ?? "") + inkSuffix
                ink.castsShadow = false
                ink.categoryBitMask = node.categoryBitMask
                node.addChildNode(ink)
            }
            if kind == .ground || kind == .sea { node.castsShadow = kind == .ground }
        }
    }

    /// A petal head's centre keeps its asset colour.
    private static func refine(_ kind: Kind, _ mat: SCNMaterial) -> Kind {
        guard kind == .petal, let n = mat.name?.lowercased() else { return kind }
        return ["center", "centre", "core", "pistil", "disc", "stamen"].contains(where: n.contains) ? .generic : kind
    }

    private static func isOwn(_ node: SCNNode) -> Bool {
        var n: SCNNode? = node
        while let x = n {
            if let name = x.name, name == skyName || name == keyName || name.hasSuffix(inkSuffix) { return true }
            n = x.parent
        }
        return false
    }

    /// The role of a mesh: its own name, else its nearest ancestor's.
    static func role(of node: SCNNode) -> Kind {
        var n: SCNNode? = node
        var own = true
        while let x = n {
            if let name = x.name, let k = kind(named: name, own: own) { return k }
            own = false
            n = x.parent
        }
        return .generic
    }

    static func kind(named name: String, own: Bool) -> Kind? {
        let l = name.lowercased()
        if own, ["center", "centre", "core", "pistil", "stamen"].contains(where: l.contains) { return .generic }
        switch name {
        case "body": return .body
        case "armL", "armR", "footL", "footR": return .limb
        case "eyeL", "eyeR": return .eye
        case "sprout", "leafL", "leafR": return .leaf
        case "blossom": return .blossom
        case "egg": return .egg
        case "nest": return .nest
        case "trunk": return .bark
        case "canopy": return .canopy
        case "fruit": return .fruit
        case "head": return .petal
        case "wingL", "wingR": return .wing
        case "castle": return .castle
        case "ground", "island": return .ground
        case "sea": return .sea
        case "cloudPuff": return .skyCloud
        case "cloudStorm": return .storm
        default: break
        }
        if name.hasPrefix("rock") { return .rock }
        if name.hasPrefix("flower") { return .stem }
        if name.hasPrefix("cloudPuff") { return .skyCloud }
        if name.hasPrefix("cloudStorm") { return .storm }
        if name.hasPrefix("castle") { return .castle }
        if name.hasPrefix("ground") || name.hasPrefix("island") { return .ground }
        if name.hasPrefix("sea") { return .sea }
        return nil
    }

    static func outlined(_ k: Kind) -> Bool {
        switch k {
        case .eye, .ground, .sea, .sky, .stem: return false
        default: return true
        }
    }

    static func inkScale(_ k: Kind) -> Float {
        switch k {
        case .petal, .leaf, .blossom, .fruit, .wing: return 0.7
        case .skyCloud: return 1.2
        default: return 1
        }
    }

    /// Eye: its radius (glint and lid are drawn in units of it). Egg: its height.
    static func param(for k: Kind, geometry: SCNGeometry, node: SCNNode? = nil) -> Float {
        switch k {
        case .canopy:
            // 1 = evergreen (under a `treePine…`): no blossom, no autumn
            var n = node
            while let x = n { if x.name?.hasPrefix("treePine") == true { return 1 }; n = x.parent }
            return 0
        case .eye:
            let (mn, mx) = geometry.boundingBox
            return Float(max(mx.x - mn.x, mx.y - mn.y)) * 0.5
        case .egg:
            let (mn, mx) = geometry.boundingBox
            return max(Float(mx.y - mn.y), 1e-3)
        default: return 0
        }
    }

    static func adopt(_ mat: SCNMaterial, kind: Kind, param: Float) {
        if mat.shaderModifiers?[.fragment] == CritterLookShader.fragment { return }
        // USDZ comes in physically based: keep the base colour, drop the rest.
        mat.lightingModel = .lambert
        mat.metalness.contents = nil
        mat.roughness.contents = nil
        mat.specular.contents = NSColor.black
        mat.emission.contents = NSColor.black
        mat.ambientOcclusion.contents = nil
        mat.selfIllumination.contents = nil
        mat.locksAmbientWithDiffuse = true
        if kind == .wing || kind == .petal || kind == .leaf { mat.isDoubleSided = true }
        mat.shaderModifiers = modifiers
        mat.setValue(NSValue(scnVector4: SCNVector4(Float(kind.rawValue), 0, param, 1)), forKey: "lookMat")
        mat.setValue(uniformData(LookUniforms()), forKey: "lookU")
    }

    static func makeInk(_ geo: SCNGeometry, kind: Kind, node: SCNNode) -> SCNGeometry {
        let ink = geo.copy() as! SCNGeometry   // shares the vertex data
        ink.materials = geo.materials.map { src in
            let m = SCNMaterial()
            m.diffuse.contents = src.diffuse.contents
            m.lightingModel = .constant
            m.cullMode = .front
            m.shaderModifiers = [.geometry: CritterLookShader.geometry, .fragment: CritterLookShader.fragment]
            let k = refine(kind, src)
            let p = param(for: k, geometry: geo, node: node)
            m.setValue(NSValue(scnVector4: SCNVector4(Float(k.rawValue), 1, p, inkScale(k))), forKey: "lookMat")
            m.setValue(uniformData(LookUniforms()), forKey: "lookU")
            return m
        }
        return ink
    }

    static func makeSky() -> SCNNode {
        let s = SCNSphere(radius: 40)
        s.segmentCount = 48
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.cullMode = .front
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.shaderModifiers = [.geometry: CritterLookShader.geometry, .fragment: CritterLookShader.fragment]
        m.setValue(NSValue(scnVector4: SCNVector4(Float(Kind.sky.rawValue), 0, 0, 1)), forKey: "lookMat")
        m.setValue(uniformData(LookUniforms()), forKey: "lookU")
        s.materials = [m]
        let n = SCNNode(geometry: s)
        n.name = skyName
        n.renderingOrder = -1000
        n.castsShadow = false
        return n
    }

    static func makeKey() -> SCNNode {
        let l = SCNLight()
        l.type = .directional
        l.color = NSColor.white
        l.intensity = 1000
        l.castsShadow = true
        l.shadowMode = .forward
        l.shadowMapSize = CGSize(width: 2048, height: 2048)
        l.shadowSampleCount = 12
        l.shadowRadius = 2.5
        l.shadowBias = 2
        l.shadowColor = NSColor.black
        l.automaticallyAdjustsShadowProjection = false
        l.orthographicScale = 9.5
        l.zNear = 1
        l.zFar = 60
        l.maximumShadowDistance = 22
        l.shadowCascadeCount = 1
        l.forcesBackFaceCasters = false
        let n = SCNNode()
        n.light = l
        n.name = keyName
        return n
    }

    // ------------------------------------------------------------ update

    public static func update(scene: SCNScene, frame f: CritterFrame) {
        let root = scene.rootNode
        var u = LookUniforms(f)
        // Face decals and the contact shadow work in the critter's own
        // space (feet at the origin, body radius 1); before it hatches, the egg's.
        let critter = root.childNode(withName: "critter", recursively: true)
        let egg = root.childNode(withName: "egg", recursively: true)
        if let c = critter, !c.isHidden || egg == nil {
            u.critterInv = c.simdWorldTransform.inverse
        } else if let e = egg {
            u.critterInv = e.simdWorldTransform.inverse
        }
        let data = uniformData(u)

        if let key = root.childNode(withName: keyName, recursively: false) {
            let L = simd_normalize(f.lightDir == .zero ? SIMD3<Float>(0, 1, 0) : f.lightDir)
            let up: SIMD3<Float> = abs(L.y) > 0.98 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
            key.simdPosition = L * 25   // a fixed box round the island: no swim as the camera moves
            key.simdLook(at: key.simdPosition - L, up: up, localFront: SIMD3(0, 0, -1))
            // moonlight casts softer, fainter shadows
            key.light?.shadowRadius = CGFloat(2.5 + 3 * f.night)
        }
        if let sky = root.childNode(withName: skyName, recursively: false) {
            sky.simdPosition = f.camPos
        }

        var seen = Set<ObjectIdentifier>()
        root.enumerateHierarchy { node, _ in
            guard let geo = node.geometry else { return }
            for mat in geo.materials where seen.insert(ObjectIdentifier(mat)).inserted {
                if mat.shaderModifiers?[.fragment] == CritterLookShader.fragment {
                    mat.setValue(data, forKey: "lookU")
                }
            }
        }
    }

    // ------------------------------------------------------------ uniforms

    /// Must match `LookU` in CritterLookShader.geometry.
    struct LookUniforms {
        var critterInv = matrix_identity_float4x4
        var light = SIMD4<Float>(0, 1, 0, 0)
        var sun = SIMD4<Float>(1.12, 1.04, 0.92, 0)
        var amb = SIMD4<Float>(0.55, 0.7, 0.95, 0)
        var bend = SIMD4<Float>(0.011, 0, 0, 14.5)
        var face = SIMD4<Float>(0.5, 0, 0, 0)
        var eyes = SIMD4<Float>(1, 0, 0, 0)
        var who = SIMD4<Float>(0, 0.85, 0.31, 2)
        var body = SIMD4<Float>(1, 0.66, 0.52, 0.7)
        var sunDir = SIMD4<Float>(0, 1, 0, 0)
        var moonDir = SIMD4<Float>(-0.4, 0.75, -0.5, 0)
        var fx = SIMD4<Float>(0, 0, 0, 0)
        var ink = SIMD4<Float>(CritterLook.inkFraction, CritterLook.inkMinPx, 0, 0)

        init() {}
        init(_ f: CritterFrame) {
            light = SIMD4(simd_normalize(f.lightDir == .zero ? SIMD3(0, 1, 0) : f.lightDir), f.night)
            sun = SIMD4(f.sunColor, f.golden)
            amb = SIMD4(f.skyAmbient, f.time)
            bend = SIMD4(f.bend, f.focus.x, f.focus.y, f.hour)
            face = SIMD4(f.mouth, f.mouthO, f.bags, f.happy)
            eyes = SIMD4(f.eye, f.lid, f.lidTilt, f.droop)
            who = SIMD4(Float(f.season), f.health, f.identity, Float(f.stage))
            body = SIMD4(CritterLook.bodyColor(identity: f.identity, health: f.health), f.bloom)
            sunDir = SIMD4(f.sunDir, f.hatch)
            moonDir = SIMD4(f.moonDir, f.wobble)
            fx = SIMD4(f.flash, f.cloudDark, f.storm, f.sick)
        }
    }

    static func uniformData(_ u: LookUniforms) -> Data {
        withUnsafeBytes(of: u) { Data($0) }
    }

    /// The critter's own colour (sRGB) by identity, a little greyed by a bad week.
    public static func bodyColor(identity: Float, health: Float) -> SIMD3<Float> {
        let palette: [SIMD3<Float>] = [SIMD3(0.5, 0.85, 0.66), SIMD3(1.0, 0.66, 0.52), SIMD3(1.0, 0.84, 0.42),
                                       SIMD3(0.74, 0.64, 0.96), SIMD3(0.52, 0.74, 1.0)]
        let i = Int(max(identity, 0) * 5) % 5
        let h = min(max(health, 0), 1)
        return simd_mix(palette[i], SIMD3(0.64, 0.66, 0.58), SIMD3(repeating: (1 - h) * 0.3))
    }
}
