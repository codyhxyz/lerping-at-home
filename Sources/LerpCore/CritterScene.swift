import AppKit
import Foundation
import Metal
import SceneKit
import simd

// The 3D critter's scene graph: the models from Sources/Critter/*.usdz (or
// primitive stand-ins with the same names and pivots while a model is
// missing), the island ground and the sea generated here, and everything
// placed and posed from one `CritterFrame` per frame. Rendered offscreen by
// `CritterData` into a texture that critter.metal composites.
//
// Purity: `apply(_:)` sets every transform and visibility it owns explicitly
// from the frame — there are no actions, physics, particle systems or
// implicit animations in this graph — and `render` draws at the frame's own
// time. The caches below (ground mesh, flower patch, tree pool) are pure
// functions of their keys, so a frame reproduces byte for byte whatever was
// drawn before it.

// MARK: - Where the models are

/// Finds the critter's `.usdz` models and loads their templates once per
/// process. The installed saver reads `Resources/Critter` in its bundle; a
/// development host (the playground, LerpPreview) reads `Sources/Critter`
/// beside whichever `Sources/Shaders` it was pointed at, the same way
/// `LerpSplatAssets` finds `build/splats`.
public enum CritterAssets {
    /// The bundle folder `make saver-build` copies the models into.
    public static let bundledFolder = "Critter"

    private static let lock = NSLock()          // sourceDirectories
    private static let loadLock = NSLock()      // loaded, loadedFrom
    nonisolated(unsafe) private static var sourceDirectories: [URL] = []
    nonisolated(unsafe) private static var loaded: [String: SCNNode]?
    nonisolated(unsafe) private static var loadedFrom: [URL] = []

    /// Called by `ShaderLibrary` with its source-tree search URLs
    /// (`…/Sources/Shaders`); remembers `…/Sources/Critter` beside each.
    static func addSourceRoots(_ shaderDirectories: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for dir in shaderDirectories {
            let critter = dir.deletingLastPathComponent()
                .appendingPathComponent("Critter").standardizedFileURL
            if !sourceDirectories.contains(critter) { sourceDirectories.append(critter) }
        }
    }

    /// Every directory that may hold the models, bundle first.
    static func directories() -> [URL] {
        lock.lock()
        var dirs = sourceDirectories
        lock.unlock()
        if let repo = ShaderLocations.repoShaderDirectory() {
            let critter = repo.deletingLastPathComponent().appendingPathComponent("Critter").standardizedFileURL
            if !dirs.contains(critter) { dirs.append(critter) }
        }
        return LerpBundleResources.directories(named: bundledFolder) + dirs
    }

    /// The `.usdz` files of the first directory that has any, in name order.
    static func modelURLs() -> [URL] {
        for dir in directories() {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.lowercased() == "usdz" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !files.isEmpty { return files }
        }
        return []
    }

    /// Every template the scene clones, by name. Top-level templates; the
    /// posed parts (`body`, `armL`, `wingL`, …) are found inside them.
    static let templateNames = [
        "critter", "egg", "nest",
        "treeRound", "treePine", "treeFruit",
        "flowerDaisy", "flowerTulip", "flowerBell",
        "cloudPuff", "cloudStorm", "butterfly", "castle", "rockA", "rockB",
    ]

    /// The templates, loaded once per process: each is a node named after
    /// the template whose child is the model, with the model's own rotation
    /// and scale from the file kept and its position in the file (layout in
    /// the .blend) dropped. A name no file has is a primitive stand-in.
    /// Callers get their own copies from `instantiate()`.
    static func templates() -> [String: SCNNode] {
        loadLock.lock(); defer { loadLock.unlock() }
        if let loaded { return loaded }
        var found: [String: SCNNode] = [:]
        let urls = modelURLs()
        for url in urls {
            guard let scene = try? SCNScene(url: url, options: [.checkConsistency: false]) else {
                NSLog("Lerping: critter model %@ failed to load", url.lastPathComponent)
                continue
            }
            for name in templateNames where found[name] == nil {
                guard let node = breadthFirst(scene.rootNode, named: name) else { continue }
                found[name] = wrap(node, name: name)
            }
        }
        var standIns: [String] = []
        for name in templateNames where found[name] == nil {
            found[name] = CritterStandIns.make(name)
            standIns.append(name)
        }
        if !standIns.isEmpty {
            NSLog("Lerping: critter models %@ — stand-ins for: %@",
                  urls.isEmpty ? "not found" : urls.map(\.lastPathComponent).joined(separator: ", "),
                  standIns.joined(separator: " "))
        }
        loaded = found
        loadedFrom = urls
        return found
    }

    /// A copy of every template for one scene, with its own geometry and
    /// material objects (vertex data is shared): `CritterLook` may change
    /// materials per frame, and two displays are two scenes on two threads.
    static func instantiate() -> [String: SCNNode] {
        templates().mapValues { deepCopy($0) }
    }

    static func deepCopy(_ node: SCNNode) -> SCNNode {
        let copy = node.clone()
        copy.enumerateHierarchy { n, _ in
            guard let g = n.geometry, let g2 = g.copy() as? SCNGeometry else { return }
            g2.materials = g.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            n.geometry = g2
        }
        return copy
    }

    /// The outermost node with this name (`childNode(withName:recursively:)`
    /// does not promise which one it returns).
    static func breadthFirst(_ root: SCNNode, named name: String) -> SCNNode? {
        var queue = [root]
        var i = 0
        while i < queue.count {
            let n = queue[i]; i += 1
            if n.name == name { return n }
            queue.append(contentsOf: n.childNodes)
        }
        return nil
    }

    private static func wrap(_ node: SCNNode, name: String) -> SCNNode {
        let model = node.clone()
        var m = node.simdWorldTransform
        m.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        model.simdTransform = m
        model.name = name + "Model"
        let wrapper = SCNNode()
        wrapper.name = name
        wrapper.addChildNode(model)
        return wrapper
    }
}

// MARK: - The scene

final class CritterScene {
    let scene = SCNScene()
    let renderer: SCNRenderer
    let device: MTLDevice

    private let cameraNode = SCNNode()
    private let sunNode = SCNNode()
    private let ambientNode = SCNNode()
    private let groundNode = SCNNode()
    private let seaNode = SCNNode()
    private let treesGroup = SCNNode()
    private let flowersGroup = SCNNode()
    private let rocksGroup = SCNNode()
    private let skyGroup = SCNNode()

    private let templates: [String: SCNNode]
    private let critter: SCNNode
    private let egg: SCNNode
    private let nest: SCNNode
    private let stormCloud: SCNNode
    private let castle: SCNNode
    private let butterfly: SCNNode
    private var parts: [String: Part] = [:]

    /// A posed node and the transform it had in the model: poses are applied
    /// on top of it, so a model's pivots and rest orientation are its own.
    private struct Part {
        let node: SCNNode
        let rest: simd_float4x4
        /// -1 when it sits on the −x side of its parent, +1 on +x: which way
        /// round a limb, leaf or wing turns to go up.
        var side: Float { rest.columns.3.x < 0 ? -1 : 1 }
        var restPosition: SIMD3<Float> { SIMD3(rest.columns.3.x, rest.columns.3.y, rest.columns.3.z) }
        var restLinear: simd_float4x4 { var m = rest; m.columns.3 = SIMD4(0, 0, 0, 1); return m }
    }

    // Caches, each a pure function of its key.
    private var groundIdentity: Float = .nan
    private struct TreeKey: Equatable { var identity: Float }
    private var treeKey: TreeKey?
    private var treeNodes: [SCNNode] = []
    private var rockKey: TreeKey?
    private var rockNodes: [SCNNode] = []
    private struct FlowerKey: Equatable { var identity: Float; var bloom: Float }
    private var flowerKey: FlowerKey?
    private struct Flower { let node: SCNNode; let base: SIMD3<Float>; let phase: Float; let spin: Float; let size: Float }
    private var flowers: [Flower] = []
    private var skyClouds: [SCNNode] = []

    static let islandRadius: Float = 7
    static let seaLevel: Float = -0.2
    static let zNear: Float = 0.05
    static let zFar: Float = 90

    init(device: MTLDevice) {
        self.device = device
        renderer = SCNRenderer(device: device, options: nil)
        templates = CritterAssets.instantiate()
        critter = templates["critter"]!
        egg = templates["egg"]!
        nest = templates["nest"]!
        stormCloud = templates["cloudStorm"]!
        castle = templates["castle"]!
        butterfly = templates["butterfly"]!

        let root = scene.rootNode
        scene.background.contents = nil
        for (node, name) in [(groundNode, "ground"), (seaNode, "sea"), (treesGroup, "trees"),
                             (flowersGroup, "flowers"), (rocksGroup, "rocks"), (skyGroup, "sky")] {
            node.name = name
            root.addChildNode(node)
        }
        for node in [critter, egg, nest, stormCloud, castle, butterfly] { root.addChildNode(node) }

        for name in ["body", "eyeL", "eyeR", "armL", "armR", "footL", "footR", "sprout", "leafL", "leafR", "blossom"] {
            if let n = CritterAssets.breadthFirst(critter, named: name) { parts[name] = Part(node: n, rest: n.simdTransform) }
        }
        for name in ["wingL", "wingR"] {
            if let n = CritterAssets.breadthFirst(butterfly, named: name) { parts[name] = Part(node: n, rest: n.simdTransform) }
        }

        seaNode.geometry = Self.seaGeometry()
        seaNode.simdPosition = SIMD3(0, Self.seaLevel, 0)
        seaNode.castsShadow = false

        // Far-off sky clouds: a few puffs round the horizon.
        for _ in 0..<6 {
            let puff = templates["cloudPuff"]!.clone()
            puff.name = "cloudPuff"
            puff.enumerateHierarchy { n, _ in n.castsShadow = false }
            skyGroup.addChildNode(puff)
            skyClouds.append(puff)
        }

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = false
        camera.zNear = Double(Self.zNear)
        camera.zFar = Double(Self.zFar)
        cameraNode.camera = camera
        cameraNode.name = "camera"
        root.addChildNode(cameraNode)

        let sun = SCNLight()
        sun.type = .directional
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.orthographicScale = 9
        sun.shadowRadius = 3
        sun.shadowSampleCount = 8
        sun.shadowMode = .forward
        sun.zNear = 1
        sun.zFar = 60
        sun.shadowColor = NSColor(srgbRed: 0.42, green: 0.36, blue: 0.62, alpha: 0.55)
        sunNode.light = sun
        sunNode.name = "sun"
        root.addChildNode(sunNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambientNode.light = ambient
        ambientNode.name = "ambient"
        root.addChildNode(ambientNode)

        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        renderer.usesReverseZ = false     // critter.metal linearises the depth it reads
        renderer.isJitteringEnabled = false

        orderDraws(root)
        CritterLook.prepare(scene: scene)
    }

    /// Every node gets its own `renderingOrder`, from a walk of the graph in
    /// child order. Left at 0, SceneKit orders draws by object addresses,
    /// which differ from run to run, and wherever two surfaces tie for a
    /// sample (an eye set into the body, a flower's core in its petals) the
    /// first drawn wins — so a still came out a few pixels different each
    /// time. `base` keeps a rebuilt group's nodes in their own range; the
    /// range is 0…<1 000 000, so CritterLook can order anything that needs it
    /// (water, outlines) after all of it.
    private func orderDraws(_ node: SCNNode, base: Int = 0) {
        var i = base
        var queue = [node]
        var k = 0
        while k < queue.count {
            let n = queue[k]; k += 1
            n.renderingOrder = i; i += 1
            queue.append(contentsOf: n.childNodes)
        }
    }

    // MARK: Per frame

    /// Puts the whole graph where `f` says. `aspect` is the drawable's
    /// width / height, for the field of view on the short side.
    func apply(_ f: CritterFrame, aspect: Float) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0

        if f.identity != groundIdentity {
            groundNode.geometry = Self.groundGeometry(identity: f.identity)
            groundIdentity = f.identity
        }
        placeCritter(f)
        placeProps(f)
        placeTrees(f)
        placeRocks(f)
        placeFlowers(f)
        placeSky(f)
        placeCamera(f, aspect: aspect)
        placeLights(f)

        CritterLook.update(scene: scene, frame: f)
        SCNTransaction.commit()
        SCNTransaction.flush()
    }

    private func ground(_ x: Float, _ z: Float, _ f: CritterFrame) -> Float {
        CritterBehavior.groundHeight(SIMD2(x, z), identity: f.identity)
    }

    private func placeCritter(_ f: CritterFrame) {
        let hatched = f.stage > 0
        critter.isHidden = !hatched
        egg.isHidden = hatched
        nest.isHidden = hatched
        let yaw = rotY(f.yaw)
        if !hatched {
            egg.simdTransform = translate(f.position) * yaw * rotZ(f.wobble)
            nest.simdTransform = translate(f.position) * yaw
            return
        }
        let sq = max(f.squash, 0.05)
        let hz = 1 / sqrt(sq)
        critter.simdTransform = translate(f.position) * yaw * rotX(f.lean) * rotZ(-f.roll)
            * scale(SIMD3(f.size * hz, f.size * sq, f.size * hz))

        // Arms: hanging (0), out to the side (π/2), overhead (~2.9); `reach`
        // swings them forward. The direction is the old shader's hand vector.
        for name in ["armL", "armR"] {
            guard let p = parts[name] else { continue }
            let a = name == "armL" ? f.armL : f.armR
            let rc = f.reach
            let d = simd_normalize(SIMD3<Float>(p.side * (sin(a) * (1 - rc) + 0.15 * rc),
                                                -cos(a),
                                                0.3 + (sin(a) - 0.3) * rc))
            let q = simd_quatf(from: SIMD3(0, -1, 0), to: d)
            p.node.simdTransform = translate(p.restPosition) * simd_float4x4(q) * p.restLinear
        }
        // Feet: they swing by `stride` on `step`; sitting puts them out in front.
        let sw = 0.13 * f.stride * sin(f.step)
        for name in ["footL", "footR"] {
            guard let p = parts[name] else { continue }
            let swing = name == "footL" ? sw : -sw
            let delta = SIMD3<Float>(p.side * -0.05 * f.sit, -0.1 * f.sit, 0.42 * f.sit + swing)
            p.node.simdTransform = translate(p.restPosition + delta) * p.restLinear
        }
        // The sprout: longer with each stage, wilting forward on a bad week,
        // one leaf hanging further than the other.
        if let p = parts["sprout"] {
            let dir = SIMD2<Float>(1 - 0.75 * f.droop, 0.1 + 1.3 * f.droop)
            let bend = atan2(dir.y, dir.x) - atan2(Float(0.1), Float(1))
            let grow = (0.95 + 0.2 * Float(min(max(f.stage, 1), 3))) / 1.35
            p.node.simdTransform = translate(p.restPosition) * rotX(bend) * p.restLinear * scale(SIMD3(repeating: grow))
        }
        for (name, droop) in [("leafL", 0.8 * f.droop), ("leafR", 1.9 * f.droop)] {
            guard let p = parts[name] else { continue }
            p.node.simdTransform = translate(p.restPosition) * rotZ(-p.side * droop) * p.restLinear
        }
        parts["blossom"]?.node.isHidden = f.stage < 3
        // Eyes open and close, and flatten into arcs when it is happy or
        // asleep (the arcs and lids themselves are CritterLook's).
        let open = 0.12 * min(max(f.eye, 0), 1) + 0.02
        let h = abs(min(max(f.happy, -1), 1))
        let eyeY = max((open + (0.032 - open) * h) / 0.14, 0.05)
        for name in ["eyeL", "eyeR"] {
            guard let p = parts[name] else { continue }
            p.node.simdTransform = p.rest * scale(SIMD3(1, eyeY, 1))
        }
    }

    private func placeProps(_ f: CritterFrame) {
        // Its own cloud: a rain cloud, or a storm cloud that shivers.
        stormCloud.isHidden = f.cloud < 0.01
        if !stormCloud.isHidden {
            let jit = f.cloudDark * 0.03 * sin(f.time * 23) * f.cloud
            stormCloud.simdTransform = translate(f.cloudPos + SIMD3(jit, 0, 0)) * rotY(f.yaw)
                * scale(SIMD3(repeating: f.cloud))
        }
        // The sandcastle rises out of the sand as it is built.
        castle.isHidden = f.castle < 0.001
        if !castle.isHidden {
            let c = min(f.castle, 1)
            let xz = SIMD2(f.castlePos.x, f.castlePos.z)
            let base = SIMD3(xz.x, ground(xz.x, xz.y, f), xz.y)
            castle.simdTransform = translate(base) * rotY(atan2(-xz.x, -xz.y))
                * scale(SIMD3(0.75 + 0.25 * c, c, 0.75 + 0.25 * c))
        }
        // The butterfly: wings beat about its body axis.
        butterfly.isHidden = f.butterfly < 0.01
        if !butterfly.isHidden {
            butterfly.simdTransform = translate(f.butterflyPos) * rotY(f.butterflyYaw)
                * scale(SIMD3(repeating: min(f.butterfly, 1)))
            for name in ["wingL", "wingR"] {
                guard let p = parts[name] else { continue }
                p.node.simdTransform = translate(p.restPosition) * rotZ(p.side * f.flap) * p.restLinear
            }
        }
    }

    private func placeTrees(_ f: CritterFrame) {
        let key = TreeKey(identity: f.identity)
        if key != treeKey {
            treeNodes.forEach { $0.removeFromParentNode() }
            treeNodes = (0..<8).map { i in
                let pick = CritterHash.h11(Float(i) * 5.17 + f.identity * 37)
                let name = pick < 0.4 ? "treeRound" : (pick < 0.7 ? "treePine" : "treeFruit")
                let n = templates[name]!.clone()
                n.name = name
                treesGroup.addChildNode(n)
                return n
            }
            orderDraws(treesGroup, base: 100_000)
            treeKey = key
        }
        let fruit = f.health > 0.55 && f.season != 3
        for (i, node) in treeNodes.enumerated() {
            guard i < f.treeCount, i < f.trees.count else { node.isHidden = true; continue }
            let t = f.trees[i]
            let size = t.z, sink = t.w
            if size <= 0 || sink > 0.995 { node.isHidden = true; continue }
            node.isHidden = false
            let y = ground(t.x, t.y, f) - sink * 2.1 * size
            let spin = CritterHash.h11(Float(i) * 3.3 + f.identity * 17) * 2 * .pi
            node.simdTransform = translate(SIMD3(t.x, y, t.y)) * rotY(spin) * scale(SIMD3(repeating: size))
            node.enumerateHierarchy { n, _ in if n.name == "fruit" { n.isHidden = !fruit } }
        }
    }

    private func placeRocks(_ f: CritterFrame) {
        let key = TreeKey(identity: f.identity)
        if key != rockKey || rockNodes.count < f.rocks.count {
            rockNodes.forEach { $0.removeFromParentNode() }
            rockNodes = (0..<max(3, f.rocks.count)).map { i in
                let name = i % 2 == 0 ? "rockA" : "rockB"
                let n = templates[name]!.clone()
                n.name = name
                rocksGroup.addChildNode(n)
                return n
            }
            orderDraws(rocksGroup, base: 200_000)
            rockKey = key
        }
        for (i, node) in rockNodes.enumerated() {
            guard i < f.rocks.count, f.rocks[i].z > 0 else { node.isHidden = true; continue }
            let r = f.rocks[i]
            node.isHidden = false
            let spin = CritterHash.h11(Float(i) * 9.1 + f.identity * 5) * 2 * .pi
            node.simdTransform = translate(SIMD3(r.x, ground(r.x, r.y, f) + 0.05, r.y)) * rotY(spin)
                * scale(SIMD3(repeating: r.z))
        }
    }

    /// The meadow: one flower per 0.6 cell at most, as the old shader's
    /// sdFlowers placed them, but gathered into patches by a slow noise, and
    /// kept off the critter's patch of grass in the middle.
    private func placeFlowers(_ f: CritterFrame) {
        let key = FlowerKey(identity: f.identity, bloom: (f.bloom * 100).rounded() / 100)
        if key != flowerKey {
            flowers.forEach { $0.node.removeFromParentNode() }
            flowers = []
            let cell: Float = 0.6
            let density = 0.04 + 0.32 * key.bloom
            let reach = Int((Self.islandRadius / cell).rounded(.up))
            for cz in -reach...reach {
                for cx in -reach...reach {
                    let c = SIMD2<Float>(Float(cx), Float(cz))
                    let jit = (CritterHash.h22(c + 17) - 0.5) * 0.2
                    let center = (c + 0.5) * cell + jit
                    let dc = simd_length(center)
                    if dc < 1.35 || dc > Self.islandRadius - 1.4 { continue }
                    let pres = CritterHash.h21(c * 1.37 + 3.1 + key.identity * 11)
                    let patch = CritterHash.smoothstep(0.3, 0.72, CritterHash.noise(center * 0.42 + key.identity * 13))
                    if pres > density * (0.3 + 1.5 * patch) { continue }
                    let pick = CritterHash.h21(c + 5.5)
                    let name = pick < 0.45 ? "flowerDaisy" : (pick < 0.75 ? "flowerTulip" : "flowerBell")
                    let n = templates[name]!.clone()
                    n.name = name
                    n.enumerateHierarchy { n, _ in n.castsShadow = false }
                    flowersGroup.addChildNode(n)
                    let base = SIMD3(center.x, CritterBehavior.groundHeight(center, identity: key.identity), center.y)
                    let size = 0.85 + 0.35 * CritterHash.h21(c + 9.1)
                    flowers.append(Flower(node: n, base: base, phase: pres * 40 + center.x,
                                          spin: 2 * .pi * CritterHash.h21(c + 2.3), size: size))
                }
            }
            orderDraws(flowersGroup, base: 300_000)
            flowerKey = key
        }
        // Sway: a slow gust over the whole meadow, each flower on its own beat.
        for fl in flowers {
            let gust = 0.6 + 0.4 * sin(tphase(f.time, 0.31) + fl.base.x * 0.4)
            let ax = 0.16 * gust * sin(tphase(f.time, 1.7) + fl.phase)
            let az = 0.16 * gust * cos(tphase(f.time, 1.3) + fl.phase * 0.6 + fl.base.z)
            fl.node.simdTransform = translate(fl.base) * rotX(ax) * rotZ(az) * rotY(fl.spin)
                * scale(SIMD3(repeating: fl.size))
        }
    }

    private func placeSky(_ f: CritterFrame) {
        for (i, puff) in skyClouds.enumerated() {
            let fi = Float(i)
            let a = fi * 1.047 + f.identity * 3 + 0.004 * f.time + 0.3 * CritterHash.h11(fi * 7.7)
            let r = 17 + 5 * CritterHash.h11(fi * 3.1 + 1)
            let y = 6.5 + 2.5 * CritterHash.h11(fi * 5.3 + 2)
            let s = 1.8 + 1.6 * CritterHash.h11(fi * 1.9 + 3)
            puff.simdTransform = translate(SIMD3(cos(a) * r, y, sin(a) * r)) * rotY(-a) * scale(SIMD3(repeating: s))
        }
    }

    private func placeCamera(_ f: CritterFrame, aspect: Float) {
        guard let camera = cameraNode.camera else { return }
        // focal 2.7: the short side spans 2 units at distance 2.7.
        camera.projectionDirection = aspect >= 1 ? .vertical : .horizontal
        camera.fieldOfView = CGFloat(2 * atan(1 / max(f.camFocal, 0.1)) * 180 / .pi)
        cameraNode.simdPosition = f.camPos
        cameraNode.simdLook(at: f.camTarget, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    private func placeLights(_ f: CritterFrame) {
        let l = simd_normalize(f.lightDir)
        sunNode.simdPosition = l * 25
        sunNode.simdLook(at: .zero, up: abs(l.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0),
                         localFront: SIMD3(0, 0, -1))
        let sc = f.sunColor
        let m = max(sc.x, sc.y, sc.z, 1e-3)
        sunNode.light?.color = NSColor(srgbRed: CGFloat(sc.x / m), green: CGFloat(sc.y / m),
                                       blue: CGFloat(sc.z / m), alpha: 1)
        sunNode.light?.intensity = CGFloat(1000 * m * m * 1.05)
        let a = f.skyAmbient
        let am = max(a.x, a.y, a.z, 1e-3)
        ambientNode.light?.color = NSColor(srgbRed: CGFloat(a.x / am), green: CGFloat(a.y / am),
                                           blue: CGFloat(a.z / am), alpha: 1)
        ambientNode.light?.intensity = CGFloat(1000 * am * am * 0.55)
    }

    // MARK: Generated geometry

    /// The island: a radial grid over groundHeight, out past the shore where
    /// the beach has gone under the sea. Vertex colours are grass inland and
    /// sand toward the water (CritterLook may replace them).
    static func groundGeometry(identity: Float) -> SCNGeometry {
        let rings = 72, segments = 160
        let outer: Float = islandRadius + 1.6
        var positions: [SIMD3<Float>] = [SIMD3(0, CritterBehavior.groundHeight(.zero, identity: identity), 0)]
        var radii: [Float] = [0]
        for r in 1...rings {
            // Finer near the middle, where the camera is.
            let t = Float(r) / Float(rings)
            radii.append(outer * (0.55 * t + 0.45 * t * t))
        }
        for r in 1...rings {
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                let xz = SIMD2(cos(a), sin(a)) * radii[r]
                positions.append(SIMD3(xz.x, CritterBehavior.groundHeight(xz, identity: identity), xz.y))
            }
        }
        var normals: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        normals.reserveCapacity(positions.count)
        colors.reserveCapacity(positions.count)
        let grass = srgbToLinear(SIMD3(0x86, 0xD1, 0x6A) / 255)
        let sand = srgbToLinear(SIMD3(0xF2, 0xDD, 0xA4) / 255)
        let e: Float = 0.02
        for p in positions {
            let xz = SIMD2(p.x, p.z)
            let hx = CritterBehavior.groundHeight(xz + SIMD2(e, 0), identity: identity)
                - CritterBehavior.groundHeight(xz - SIMD2(e, 0), identity: identity)
            let hz = CritterBehavior.groundHeight(xz + SIMD2(0, e), identity: identity)
                - CritterBehavior.groundHeight(xz - SIMD2(0, e), identity: identity)
            normals.append(simd_normalize(SIMD3(-hx / (2 * e), 1, -hz / (2 * e))))
            let d = simd_length(xz)
            let beach = max(CritterHash.smoothstep(islandRadius - 1.5, islandRadius - 0.7, d),
                            CritterHash.smoothstep(0.02, -0.08, p.y))
            let c = grass + (sand - grass) * beach
            colors.append(SIMD4(c, 1))
        }
        var indices: [UInt32] = []
        for s in 0..<segments {
            let a = UInt32(1 + s), b = UInt32(1 + (s + 1) % segments)
            indices += [0, b, a]
        }
        for r in 1..<rings {
            let base0 = 1 + (r - 1) * segments, base1 = 1 + r * segments
            for s in 0..<segments {
                let s1 = (s + 1) % segments
                let a = UInt32(base0 + s), b = UInt32(base0 + s1)
                let c = UInt32(base1 + s), d = UInt32(base1 + s1)
                indices += [a, b, c, b, d, c]
            }
        }
        let g = makeGeometry(positions: positions, normals: normals, colors: colors, indices: indices)
        let m = SCNMaterial()
        m.name = "ground"
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor.white
        g.materials = [m]
        g.name = "ground"
        return g
    }

    /// The sea: a flat disc at sea level, dense near the island so the rolled
    /// world's bend (a per-vertex drop) curves it smoothly toward the horizon.
    static func seaGeometry() -> SCNGeometry {
        let rings = 64, segments = 128
        let outer: Float = 70
        var positions: [SIMD3<Float>] = [.zero]
        var radii: [Float] = [0]
        for r in 1...rings {
            let t = Float(r) / Float(rings)
            radii.append(outer * (0.12 * t + 0.88 * t * t * t))
        }
        for r in 1...rings {
            for s in 0..<segments {
                let a = Float(s) / Float(segments) * 2 * .pi
                positions.append(SIMD3(cos(a) * radii[r], 0, sin(a) * radii[r]))
            }
        }
        let shallow = srgbToLinear(SIMD3(0x59, 0xD8, 0xCF) / 255)
        let deep = srgbToLinear(SIMD3(0x24, 0x75, 0xB8) / 255)
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count)
        let colors = positions.map { p -> SIMD4<Float> in
            let t = CritterHash.smoothstep(islandRadius - 0.5, islandRadius + 4, simd_length(SIMD2(p.x, p.z)))
            return SIMD4(shallow + (deep - shallow) * t, 1)
        }
        var indices: [UInt32] = []
        for s in 0..<segments { indices += [0, UInt32(1 + (s + 1) % segments), UInt32(1 + s)] }
        for r in 1..<rings {
            let base0 = 1 + (r - 1) * segments, base1 = 1 + r * segments
            for s in 0..<segments {
                let s1 = (s + 1) % segments
                let a = UInt32(base0 + s), b = UInt32(base0 + s1)
                let c = UInt32(base1 + s), d = UInt32(base1 + s1)
                indices += [a, b, c, b, d, c]
            }
        }
        let g = makeGeometry(positions: positions, normals: normals, colors: colors, indices: indices)
        let m = SCNMaterial()
        m.name = "sea"
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor.white
        g.materials = [m]
        g.name = "sea"
        return g
    }

    private static func makeGeometry(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                     colors: [SIMD4<Float>], indices: [UInt32]) -> SCNGeometry {
        func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, components: Int, count: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                              componentsPerVector: components, bytesPerComponent: 4, dataOffset: 0,
                              dataStride: components * 4)
        }
        let p = positions.flatMap { [$0.x, $0.y, $0.z] }
        let n = normals.flatMap { [$0.x, $0.y, $0.z] }
        let c = colors.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        let sources = [
            source(p.withUnsafeBytes { Data($0) }, .vertex, components: 3, count: positions.count),
            source(n.withUnsafeBytes { Data($0) }, .normal, components: 3, count: normals.count),
            source(c.withUnsafeBytes { Data($0) }, .color, components: 4, count: colors.count),
        ]
        let element = SCNGeometryElement(data: indices.withUnsafeBytes { Data($0) }, primitiveType: .triangles,
                                         primitiveCount: indices.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: sources, elements: [element])
    }

    private static func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2))
    }
}

// MARK: - Small maths

/// sin(t·w) for a clock that has run for hours, as critter.metal's tphase.
@inline(__always) func tphase(_ t: Float, _ w: Float) -> Float {
    let x = t * (w / (2 * .pi))
    return 2 * .pi * (x - x.rounded(.down))
}
@inline(__always) private func translate(_ v: SIMD3<Float>) -> simd_float4x4 {
    var m = matrix_identity_float4x4
    m.columns.3 = SIMD4(v, 1)
    return m
}
@inline(__always) private func scale(_ v: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(v, 1))
}
@inline(__always) private func rotX(_ a: Float) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: a, axis: SIMD3(1, 0, 0))) }
@inline(__always) private func rotY(_ a: Float) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: a, axis: SIMD3(0, 1, 0))) }
@inline(__always) private func rotZ(_ a: Float) -> simd_float4x4 { simd_float4x4(simd_quatf(angle: a, axis: SIMD3(0, 0, 1))) }

/// The prelude's hashes (paper-design/shaders, Apache-2.0), in Swift, so the
/// meadow lands where the old shader's sdFlowers put it.
enum CritterHash {
    @inline(__always) static func fract(_ x: Float) -> Float { x - x.rounded(.down) }
    static func h11(_ p0: Float) -> Float {
        var p = fract(p0 * 0.3183099) + 0.1
        p *= p + 19.19
        return fract(p * p)
    }
    static func h21(_ p0: SIMD2<Float>) -> Float {
        var p = SIMD2(fract(p0.x * 0.3183099), fract(p0.y * 0.3678794)) + 0.1
        p += simd_dot(p, p + 19.19)
        return fract(p.x * p.y)
    }
    static func h22(_ p0: SIMD2<Float>) -> SIMD2<Float> {
        var p = SIMD2(fract(p0.x * 0.3183099), fract(p0.y * 0.3678794)) + 0.1
        p += simd_dot(p, SIMD2(p.y, p.x) + 19.19)
        return SIMD2(fract(p.x * p.y), fract(p.x + p.y))
    }
    static func noise(_ st: SIMD2<Float>) -> Float {
        let i = SIMD2(st.x.rounded(.down), st.y.rounded(.down))
        let f = st - i
        let a = h21(i), b = h21(i + SIMD2(1, 0)), c = h21(i + SIMD2(0, 1)), d = h21(i + SIMD2(1, 1))
        let u = f * f * (3 - 2 * f)
        return (a + (b - a) * u.x) + ((c + (d - c) * u.x) - (a + (b - a) * u.x)) * u.y
    }
    static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

// MARK: - Stand-ins

/// Primitive stand-ins for models not made yet, with the template names,
/// child names and pivots of CRITTER3D's model conventions, so the whole
/// pipeline runs before (and without) the Blender models.
enum CritterStandIns {
    static func make(_ name: String) -> SCNNode {
        let root = SCNNode()
        root.name = name
        switch name {
        case "critter": critter(root)
        case "egg":
            root.addChildNode(ellipsoid(SIMD3(0.29, 0.4, 0.29), at: SIMD3(0, 0.4, 0), color: 0xFFF3DA, name: "shell"))
        case "nest":
            let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.3, pipeRadius: 0.1))
            ring.geometry?.materials = [material(0x9A6A45)]
            ring.simdPosition = SIMD3(0, 0.06, 0)
            ring.name = "ring"
            root.addChildNode(ring)
        case "treeRound", "treeFruit": tree(root, fruit: name == "treeFruit", round: true)
        case "treePine": tree(root, fruit: false, round: false)
        case "flowerDaisy", "flowerTulip", "flowerBell": flower(root, kind: name)
        case "cloudPuff": cloud(root, color: 0xFFFFFF)
        case "cloudStorm": cloud(root, color: 0x8C8FA8)
        case "butterfly": butterfly(root)
        case "castle": castle(root)
        case "rockA", "rockB":
            let r = ellipsoid(SIMD3(1, 0.62, 0.85), at: .zero, color: name == "rockA" ? 0x9C9AA6 : 0xB0A89A,
                              name: "stone", segments: 7)
            root.addChildNode(r)
        default: break
        }
        return root
    }

    private static func critter(_ root: SCNNode) {
        let body = ellipsoid(SIMD3(1, 0.95, 0.92), at: SIMD3(0, 0.95, 0), color: 0x9EE07A, name: "body")
        root.addChildNode(body)
        for (name, x) in [("eyeL", Float(-0.34)), ("eyeR", Float(0.34))] {
            let e = ellipsoid(SIMD3(0.085, 0.14, 0.07), at: SIMD3(x, 1.05, 0.8), color: 0x1E1A2A, name: name)
            root.addChildNode(e)
        }
        for (name, x) in [("armL", Float(-0.74)), ("armR", Float(0.74))] {
            let arm = SCNNode()
            arm.name = name
            arm.simdPosition = SIMD3(x, 1.03, 0.08)
            let cap = SCNNode(geometry: SCNCapsule(capRadius: 0.095, height: 0.84))
            cap.geometry?.materials = [material(0x9EE07A)]
            cap.simdPosition = SIMD3(0, -0.42, 0)
            arm.addChildNode(cap)
            let mitt = SCNNode(geometry: SCNSphere(radius: 0.145))
            mitt.geometry?.materials = [material(0x9EE07A)]
            mitt.simdPosition = SIMD3(0, -0.84, 0)
            arm.addChildNode(mitt)
            root.addChildNode(arm)
        }
        for (name, x) in [("footL", Float(-0.42)), ("footR", Float(0.42))] {
            root.addChildNode(ellipsoid(SIMD3(0.21, 0.13, 0.27), at: SIMD3(x, 0.12, 0.24), color: 0x7FC761, name: name))
        }
        let sprout = SCNNode()
        sprout.name = "sprout"
        sprout.simdPosition = SIMD3(0, 1.87, 0)
        let stem = SCNNode(geometry: SCNCylinder(radius: 0.035, height: 0.36))
        stem.geometry?.materials = [material(0x4FA35E)]
        stem.simdPosition = SIMD3(0, 0.15, 0)
        sprout.addChildNode(stem)
        for (name, x) in [("leafL", Float(-1)), ("leafR", Float(1))] {
            let leaf = SCNNode()
            leaf.name = name
            leaf.simdPosition = SIMD3(0.02 * x, 0.32, 0)
            leaf.simdOrientation = simd_quatf(angle: -0.5 * x, axis: SIMD3(0, 0, 1))
            leaf.addChildNode(ellipsoid(SIMD3(0.19, 0.035, 0.1), at: SIMD3(0.18 * x, 0, 0), color: 0x5DBA5A, name: "blade"))
            sprout.addChildNode(leaf)
        }
        let blossom = SCNNode()
        blossom.name = "blossom"
        blossom.simdPosition = SIMD3(0, 0.36, 0)
        blossom.addChildNode(ellipsoid(SIMD3(0.22, 0.06, 0.22), at: .zero, color: 0xFFC4D6, name: "petals"))
        blossom.addChildNode(ellipsoid(SIMD3(0.07, 0.07, 0.07), at: SIMD3(0, 0.04, 0), color: 0xF4C64A, name: "core"))
        sprout.addChildNode(blossom)
        root.addChildNode(sprout)
    }

    private static func tree(_ root: SCNNode, fruit: Bool, round: Bool) {
        let trunk = SCNNode(geometry: SCNCone(topRadius: 0.07, bottomRadius: 0.11, height: 1.1))
        trunk.geometry?.materials = [material(0x9A6A45)]
        trunk.simdPosition = SIMD3(0, 0.45, 0)
        trunk.name = "trunk"
        root.addChildNode(trunk)
        let canopy = SCNNode()
        canopy.name = "canopy"
        if round {
            for (c, r) in [(SIMD3<Float>(0, 1.25, 0), Float(0.6)), (SIMD3(0.3, 1.05, 0.14), 0.42),
                           (SIMD3(-0.27, 1.08, -0.12), 0.42), (SIMD3(0.02, 1.62, 0.03), 0.36)] {
                canopy.addChildNode(ellipsoid(SIMD3(repeating: r), at: c, color: 0x5DBA5A, name: "puff", segments: 14))
            }
        } else {
            for (i, (y, r)) in [(Float(0.9), Float(0.62)), (1.3, 0.5), (1.68, 0.36)].enumerated() {
                let cone = SCNNode(geometry: SCNCone(topRadius: 0, bottomRadius: CGFloat(r), height: CGFloat(r * 1.3)))
                cone.geometry?.materials = [material(0x3F9152)]
                cone.simdPosition = SIMD3(0, y, 0)
                cone.name = "tier\(i)"
                canopy.addChildNode(cone)
            }
        }
        root.addChildNode(canopy)
        if fruit {
            let f = SCNNode()
            f.name = "fruit"
            for c in [SIMD3<Float>(0.5, 1.12, 0.38), SIMD3(-0.32, 1.35, 0.5), SIMD3(0.12, 0.98, -0.6)] {
                f.addChildNode(ellipsoid(SIMD3(repeating: 0.075), at: c, color: 0xE2603A, name: "apple"))
            }
            root.addChildNode(f)
        }
    }

    private static func flower(_ root: SCNNode, kind: String) {
        let stem = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.2))
        stem.geometry?.materials = [material(0x4FA35E)]
        stem.simdPosition = SIMD3(0, 0.1, 0)
        stem.name = "stem"
        root.addChildNode(stem)
        let head = SCNNode()
        head.name = "head"
        head.simdPosition = SIMD3(0, 0.2, 0)
        switch kind {
        case "flowerTulip":
            head.addChildNode(ellipsoid(SIMD3(0.05, 0.075, 0.05), at: SIMD3(0, 0.03, 0), color: 0xE2603A, name: "cup"))
        case "flowerBell":
            let bell = SCNNode(geometry: SCNCone(topRadius: 0.015, bottomRadius: 0.06, height: 0.08))
            bell.geometry?.materials = [material(0x8F8CF0)]
            bell.name = "bell"
            head.addChildNode(bell)
        default:
            head.addChildNode(ellipsoid(SIMD3(0.085, 0.022, 0.085), at: .zero, color: 0xFFFFFF, name: "petals"))
            head.addChildNode(ellipsoid(SIMD3(repeating: 0.03), at: SIMD3(0, 0.015, 0), color: 0xF4C64A, name: "core"))
        }
        root.addChildNode(head)
    }

    private static func cloud(_ root: SCNNode, color: UInt32) {
        for (c, r) in [(SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.46, 0.2, 0.32)), (SIMD3(0.28, 0.08, 0.04), SIMD3(repeating: 0.24)),
                       (SIMD3(-0.3, 0.06, -0.03), SIMD3(repeating: 0.22)), (SIMD3(0.02, 0.2, 0.02), SIMD3(repeating: 0.25))] {
            root.addChildNode(ellipsoid(r, at: c, color: color, name: "puff", segments: 16))
        }
    }

    private static func butterfly(_ root: SCNNode) {
        let body = SCNNode(geometry: SCNCapsule(capRadius: 0.012, height: 0.11))
        body.geometry?.materials = [material(0x2A1E30)]
        body.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        body.name = "bbody"
        root.addChildNode(body)
        for (name, x) in [("wingL", Float(-1)), ("wingR", Float(1))] {
            let wing = SCNNode()
            wing.name = name
            wing.simdPosition = SIMD3(0.006 * x, 0, 0)
            wing.addChildNode(ellipsoid(SIMD3(0.06, 0.004, 0.045), at: SIMD3(0.06 * x, 0, 0.02), color: 0x59A8FF, name: "fore"))
            wing.addChildNode(ellipsoid(SIMD3(0.04, 0.004, 0.035), at: SIMD3(0.04 * x, 0, -0.04), color: 0x59A8FF, name: "hind"))
            root.addChildNode(wing)
        }
    }

    private static func castle(_ root: SCNNode) {
        for (c, r, h) in [(SIMD3<Float>(0, 0.07, 0), Float(0.32), Float(0.16)), (SIMD3(0, 0.2, 0), 0.21, 0.17),
                          (SIMD3(0.18, 0.22, 0.12), 0.08, 0.35), (SIMD3(-0.17, 0.22, -0.1), 0.08, 0.35),
                          (SIMD3(0, 0.35, 0), 0.1, 0.17)] {
            let n = SCNNode(geometry: SCNCylinder(radius: CGFloat(r), height: CGFloat(h)))
            n.geometry?.materials = [material(0xF2DDA4)]
            n.simdPosition = c
            n.name = "tower"
            root.addChildNode(n)
        }
    }

    private static func ellipsoid(_ r: SIMD3<Float>, at c: SIMD3<Float>, color: UInt32, name: String,
                                  segments: Int = 24) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = segments
        sphere.materials = [material(color)]
        let n = SCNNode(geometry: sphere)
        n.simdPosition = c
        n.simdScale = r
        n.name = name
        return n
    }

    private static func material(_ hex: UInt32) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                                     green: CGFloat((hex >> 8) & 0xFF) / 255,
                                     blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        return m
    }
}
