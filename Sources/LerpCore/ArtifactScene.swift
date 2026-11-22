import SceneKit
import Metal
import AppKit
import CoreGraphics
import CoreText
import simd

final class ArtifactScene {
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let samples = 4
    static let zNear: Float = 0.05
    static let zFar: Float = 30
    private let device: MTLDevice
    private let renderer: SCNRenderer
    private let scene = SCNScene()
    private let camera = SCNNode()
    private var roots: [ArtifactKind: SCNNode] = [:]
    private var reels: [SCNNode] = []
    private var labels: [ArtifactKind: SCNMaterial] = [:]
    private var labelKeys: [ArtifactKind: String] = [:]
    private var sand: [SCNNode] = []
    init(device: MTLDevice) {
        self.device = device; renderer = SCNRenderer(device: device, options: nil)
        scene.background.contents = NSColor.clear
        camera.camera = SCNCamera(); camera.camera?.zNear = Double(Self.zNear); camera.camera?.zFar = Double(Self.zFar)
        camera.camera?.fieldOfView = 38
        scene.rootNode.addChildNode(camera); renderer.scene = scene; renderer.pointOfView = camera
        for (p, color, energy) in [(SCNVector3(-3.2, 4.8, 4.2), NSColor(red: 0.98, green: 0.89, blue: 0.78, alpha: 1), 980.0),
                                   (SCNVector3(3.4, 4.2, -3.2), NSColor(red: 0.68, green: 0.82, blue: 1.0, alpha: 1), 1950.0),
                                   (SCNVector3(-2.8, -3.2, 2.4), NSColor(red: 0.72, green: 0.76, blue: 0.85, alpha: 1), 240.0)] {
            let n = SCNNode(); n.light = SCNLight(); n.light?.type = .omni; n.light?.color = color; n.light?.intensity = energy; n.position = p; scene.rootNode.addChildNode(n)
        }
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 45; scene.rootNode.addChildNode(ambient)
        for kind in ArtifactKind.allCases where kind != .photo { let n = build(kind); roots[kind] = n; scene.rootNode.addChildNode(n); n.isHidden = true }
        var order = 0
        scene.rootNode.enumerateChildNodes { n, _ in n.renderingOrder = order; order += 1 }
    }
    private func build(_ kind: ArtifactKind) -> SCNNode {
        let root = SCNNode()
        let dark = NSColor(white: 0.12, alpha: 1), gold = NSColor(red: 0.65, green: 0.42, blue: 0.16, alpha: 1)
        @discardableResult func add(_ g: SCNGeometry, _ p: SCNVector3, _ color: NSColor, metal: CGFloat = 0) -> SCNNode {
            let m = SCNMaterial(); m.lightingModel = .physicallyBased; m.diffuse.contents = color; m.metalness.contents = metal; m.roughness.contents = metal > 0 ? 0.3 : 0.65
            if let c = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.setFillColor(color.cgColor); c.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
                c.setFillColor(NSColor(white: 0.7, alpha: 0.045).cgColor)
                for i in 0..<900 { c.fillEllipse(in: CGRect(x: (i * 73) % 128, y: (i * 37 + i / 128) % 128, width: 1, height: 1)) }
                m.diffuse.contents = c.makeImage()
            }
            g.materials = [m]; let n = SCNNode(geometry: g); n.position = p; root.addChildNode(n); return n
        }
        func box(_ w: CGFloat, _ h: CGFloat, _ d: CGFloat, _ p: SCNVector3, _ c: NSColor) { add(SCNBox(width: w, height: h, length: d, chamferRadius: 0.06), p, c) }
        switch kind {
        case .mug:
            add(SCNTube(innerRadius: 0.57, outerRadius: 0.68, height: 1.3), SCNVector3Zero, dark)
            add(SCNTorus(ringRadius: 0.625, pipeRadius: 0.055), SCNVector3(0, 0.65, 0), dark)
            add(SCNCylinder(radius: 0.57, height: 0.03), SCNVector3(0, 0.42, 0), NSColor(white: 0.025, alpha: 1)).geometry?.firstMaterial?.roughness.contents = 0.08
            let handle = add(SCNTorus(ringRadius: 0.42, pipeRadius: 0.11), SCNVector3(0.78, 0, 0), dark); handle.eulerAngles.x = .pi / 2
            let chip = add(SCNSphere(radius: 0.055), .init(-0.3, 0.65, 0.55), .init(white: 0.67, alpha: 1)); chip.scale = .init(1, 0.4, 0.7)
            add(SCNCylinder(radius: 0.62, height: 0.1), .init(0, -0.6, 0), dark)
        case .keycap:
            // Compact smoked mechanical switch housing + glowing under-plate + brass solder pins
            box(0.86, 0.42, 0.86, SCNVector3(0, -0.34, 0), NSColor(white: 0.14, alpha: 0.78))
            let collar = add(SCNBox(width: 0.94, height: 0.08, length: 0.94, chamferRadius: 0.02), .init(0, -0.12, 0), NSColor(white: 0.1, alpha: 1))
            collar.geometry?.firstMaterial?.roughness.contents = 0.5
            let glow = add(SCNBox(width: 0.82, height: 0.04, length: 0.82, chamferRadius: 0.015), .init(0, -0.56, 0), gold)
            glow.geometry?.firstMaterial?.emission.contents = NSColor(red: 0.75, green: 0.42, blue: 0.12, alpha: 1)
            for x: Float in [-0.24, 0.24] { add(SCNCylinder(radius: 0.036, height: 0.38), SCNVector3(x, -0.74, 0), gold, metal: 0.95) }
            // Sculpted stepped PBT keycap (wider skirt tapering smoothly into a rounded top dish)
            add(SCNBox(width: 1.18, height: 0.26, length: 1.18, chamferRadius: 0.09), SCNVector3(0, 0.14, 0), NSColor(white: 0.16, alpha: 1))
            add(SCNBox(width: 1.04, height: 0.22, length: 1.04, chamferRadius: 0.09), SCNVector3(0, 0.31, 0), NSColor(white: 0.18, alpha: 1))
            add(SCNBox(width: 0.92, height: 0.08, length: 0.92, chamferRadius: 0.04), SCNVector3(0, 0.40, 0), NSColor(white: 0.15, alpha: 1))
        case .cartridge:
            box(1.8, 1.8, 0.34, .init(0, 0, 0), NSColor(white: 0.14, alpha: 1))
            box(1.5, 0.16, 0.40, .init(0, 0.80, 0), NSColor(white: 0.16, alpha: 1))
            box(1.36, 0.94, 0.03, .init(0, 0.05, 0.175), NSColor(white: 0.09, alpha: 1))
            for i in 0..<12 { box(0.065, 0.20, 0.04, .init(Float(i) * 0.11 - 0.6, -0.87, 0), gold) }
            for i in 0..<6 { for x: Float in [-0.84, 0.84] { box(0.08, 0.028, 0.38, .init(x, Float(i) * 0.15 - 0.35, 0), .init(white: 0.06, alpha: 1)) } }
        case .cassette:
            // Smoked polycarbonate shell + bottom trapezoid bridge + recessed dark tape window
            box(2.2, 1.38, 0.28, .init(0, 0, 0), NSColor(white: 0.15, alpha: 0.88))
            box(1.54, 0.24, 0.34, .init(0, -0.57, 0), NSColor(white: 0.11, alpha: 1))
            box(1.56, 0.56, 0.04, .init(0, -0.06, 0.135), NSColor(white: 0.05, alpha: 1))
            for x: Float in [-0.48, 0.48] {
                let tape = add(SCNCylinder(radius: 0.25, height: 0.04), .init(x, -0.06, 0.145), NSColor(red: 0.14, green: 0.11, blue: 0.09, alpha: 1))
                tape.eulerAngles.x = .pi / 2
                let hub = add(SCNTube(innerRadius: 0.075, outerRadius: 0.145, height: 0.055), .init(x, -0.06, 0.152), NSColor(white: 0.82, alpha: 1))
                hub.eulerAngles.x = .pi / 2
                let reel = SCNNode(); reel.position = .init(x, -0.06, 0.165); root.addChildNode(reel); reels.append(reel)
                for i in 0..<6 {
                    let tooth = SCNNode(geometry: SCNBox(width: 0.032, height: 0.065, length: 0.03, chamferRadius: 0.005))
                    let a = Float(i) * .pi / 3
                    tooth.position = .init(cos(a) * 0.092, sin(a) * 0.092, 0)
                    tooth.eulerAngles.z = CGFloat(a + .pi / 2)
                    tooth.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.86, alpha: 1)
                    reel.addChildNode(tooth)
                }
            }
        case .trophy:
            let satinGold = NSColor(red: 0.78, green: 0.62, blue: 0.30, alpha: 1)
            let royalBlue = NSColor(red: 0.10, green: 0.24, blue: 0.56, alpha: 1)
            box(1.36, 0.30, 0.96, .init(0, -0.92, 0), NSColor(white: 0.11, alpha: 1))
            box(1.16, 0.08, 0.78, .init(0, -0.74, 0), NSColor(white: 0.16, alpha: 1))
            add(SCNCylinder(radius: 0.28, height: 0.10), .init(0, -0.66, 0), satinGold, metal: 0.85)
            add(SCNCylinder(radius: 0.13, height: 0.54), .init(0, -0.35, 0), satinGold, metal: 0.88)
            add(SCNSphere(radius: 0.18), .init(0, -0.08, 0), satinGold, metal: 0.88)
            add(SCNTube(innerRadius: 0.44, outerRadius: 0.52, height: 0.68), .init(0, 0.30, 0), satinGold, metal: 0.90)
            add(SCNTorus(ringRadius: 0.48, pipeRadius: 0.045), .init(0, 0.64, 0), satinGold, metal: 0.92)
            for x: Float in [-0.58, 0.58] { let n = add(SCNTorus(ringRadius: 0.26, pipeRadius: 0.042), .init(x, 0.30, 0), satinGold, metal: 0.90); n.eulerAngles.x = .pi / 2 }
            // Satin royal-blue award rosette & angled tails pinned cleanly to the plinth front-right
            let tailL = add(SCNBox(width: 0.14, height: 0.50, length: 0.025, chamferRadius: 0.005), .init(0.46, -0.96, 0.49), royalBlue)
            tailL.eulerAngles.z = -0.14
            let tailR = add(SCNBox(width: 0.14, height: 0.50, length: 0.025, chamferRadius: 0.005), .init(0.56, -0.96, 0.485), royalBlue)
            tailR.eulerAngles.z = 0.14
            let badge = add(SCNCylinder(radius: 0.145, height: 0.045), .init(0.51, -0.73, 0.505), royalBlue)
            badge.eulerAngles.x = .pi / 2
            let centerDisc = add(SCNCylinder(radius: 0.075, height: 0.055), .init(0.51, -0.73, 0.512), satinGold, metal: 0.85)
            centerDisc.eulerAngles.x = .pi / 2
        case .hourglass:
            let brass = NSColor(red: 0.68, green: 0.52, blue: 0.24, alpha: 1)
            let warmSand = NSColor(red: 0.88, green: 0.71, blue: 0.36, alpha: 1)
            for y: Float in [-0.95, 0.95] { add(SCNCylinder(radius: 0.68, height: 0.13), .init(0, y, 0), brass, metal: 0.88) }
            for i in 0..<3 { let a = Float(i) * 2 * .pi / 3; add(SCNCylinder(radius: 0.042, height: 1.9), .init(cos(a) * 0.58, 0, sin(a) * 0.58), brass, metal: 0.88) }
            for sign: Float in [-1, 1] {
                let n = add(SCNCone(topRadius: 0.035, bottomRadius: 0.48, height: 0.86), .init(0, sign * 0.43, 0), NSColor(white: 0.85, alpha: 0.16))
                if sign > 0 { n.eulerAngles.z = .pi }
                n.geometry?.firstMaterial?.roughness.contents = 0.05
            }
            let lowerSand = add(SCNCone(topRadius: 0.01, bottomRadius: 0.38, height: 0.56), .init(0, -0.60, 0), warmSand)
            sand.append(lowerSand)
            let upperSand = add(SCNCone(topRadius: 0.34, bottomRadius: 0.015, height: 0.50), .init(0, 0.32, 0), warmSand)
            sand.append(upperSand)
            let thread = add(SCNCylinder(radius: 0.010, height: 0.90), .init(0, -0.44, 0), warmSand)
            thread.geometry?.firstMaterial?.emission.contents = NSColor(red: 0.65, green: 0.46, blue: 0.14, alpha: 1)
        case .photo: break
        }
        if [.keycap, .cartridge, .cassette, .trophy].contains(kind) {
            let size: (CGFloat, CGFloat) = switch kind {
            case .keycap: (0.76, 0.76)
            case .cartridge: (1.26, 0.84)
            case .cassette: (1.58, 0.34)
            default: (0.72, 0.18)
            }
            let plane = SCNPlane(width: size.0, height: size.1)
            let material = SCNMaterial(); material.lightingModel = .physicallyBased
            material.roughness.contents = kind == .keycap ? 0.38 : 0.48; plane.materials = [material]
            labels[kind] = material
            let node = SCNNode(geometry: plane)
            switch kind {
            case .keycap: node.position = .init(0, 0.443, 0); node.eulerAngles.x = -.pi / 2
            case .cartridge: node.position = .init(0, 0.05, 0.194)
            case .cassette: node.position = .init(0, 0.42, 0.146)
            default: node.position = .init(-0.10, -0.92, 0.486)
            }
            root.addChildNode(node)
        }
        return root
    }
    private func updateLabel(_ card: ArtifactCard) {
        let key = "\(card.labelPrimary)|\(card.labelSecondary)|\(card.level)"
        guard labelKeys[card.kind] != key, let material = labels[card.kind] else { return }
        let texW = 1024, texH = card.kind == .keycap ? 1024 : (card.kind == .cartridge ? 680 : 300)
        guard let c = CGContext(data: nil, width: texW, height: texH, bitsPerComponent: 8, bytesPerRow: texW * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let cap = card.kind == .keycap
        let bgColor: NSColor = switch card.kind {
        case .keycap: NSColor(white: 0.15, alpha: 1)
        case .cartridge: NSColor(red: 0.84, green: 0.79, blue: 0.68, alpha: 1)
        case .cassette: NSColor(red: 0.86, green: 0.82, blue: 0.73, alpha: 1)
        default: NSColor(red: 0.78, green: 0.63, blue: 0.32, alpha: 1)
        }
        c.setFillColor(bgColor.cgColor)
        c.fill(CGRect(x: 0, y: 0, width: texW, height: texH))
        if card.kind == .cartridge {
            c.setFillColor(NSColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: texH - 165, width: texW, height: 165))
            c.setFillColor(NSColor(red: 0.68, green: 0.30, blue: 0.18, alpha: 1).cgColor)
            c.fill(CGRect(x: 0, y: texH - 182, width: texW, height: 17))
        }
        // Deterministic subtle hairline wear
        c.setStrokeColor(NSColor(white: cap ? 0.35 : 0.15, alpha: 0.11).cgColor)
        for i in 0..<60 {
            let x = CGFloat((i * 193) % texW), y = CGFloat((i * 71) % texH)
            c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + CGFloat(i % 70 + 8), y: y + 2)); c.strokePath()
        }
        if cap {
            let font = NSFont.systemFont(ofSize: 340, weight: .regular)
            let a = NSAttributedString(string: "⌘S", attributes: [.font: font, .foregroundColor: NSColor(red: 0.92, green: 0.89, blue: 0.82, alpha: 1)])
            let sz = a.size()
            c.textPosition = CGPoint(x: (CGFloat(texW) - sz.width) * 0.5, y: (CGFloat(texH) - sz.height) * 0.52)
            CTLineDraw(CTLineCreateWithAttributedString(a), c)
        } else {
            let lines = [card.labelPrimary, card.labelSecondary]
            for (i, line) in lines.enumerated() where !line.isEmpty {
                var fontSize: CGFloat = card.kind == .cartridge ? (i == 0 ? 78 : 48) : (i == 0 ? 74 : 44)
                let fontName = card.kind == .cassette ? "Noteworthy-Bold" : "Optima-Bold"
                while fontSize > 18 {
                    let f = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
                    if (line as NSString).size(withAttributes: [.font: f]).width <= CGFloat(texW - 96) { break }
                    fontSize -= 2
                }
                let font = NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
                let textColor: NSColor = (card.kind == .cartridge && i == 0) ? NSColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1) : NSColor(white: 0.10, alpha: 1)
                let a = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: textColor])
                let y: CGFloat = card.kind == .cartridge ? (i == 0 ? CGFloat(texH) - 118 : CGFloat(texH) - 310) : (i == 0 ? CGFloat(texH) - 125 : 70)
                c.textPosition = CGPoint(x: 48, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(a), c)
            }
        }
        material.diffuse.contents = c.makeImage(); labelKeys[card.kind] = key
    }
    static func pass(color: MTLTexture?, depth: MTLTexture?, resolveColor: MTLTexture?, resolveDepth: MTLTexture?) -> MTLRenderPassDescriptor? {
        guard let color, let depth, let resolveColor, let resolveDepth else { return nil }
        let p = MTLRenderPassDescriptor(); p.colorAttachments[0].texture = color; p.colorAttachments[0].resolveTexture = resolveColor
        p.colorAttachments[0].loadAction = .clear; p.colorAttachments[0].storeAction = .multisampleResolve
        p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        p.depthAttachment.texture = depth; p.depthAttachment.resolveTexture = resolveDepth; p.depthAttachment.loadAction = .clear
        p.depthAttachment.clearDepth = 1; p.depthAttachment.storeAction = .multisampleResolve; p.depthAttachment.depthResolveFilter = .sample0
        return p
    }
    func precompile() {
        guard let q = device.makeCommandQueue(), let cb = q.makeCommandBuffer() else { return }
        func make(_ f: MTLPixelFormat, _ samples: Int) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: 64, height: 40, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D; d.sampleCount = samples; d.storageMode = .private
            d.usage = samples > 1 ? .renderTarget : [.renderTarget, .shaderRead]; return device.makeTexture(descriptor: d)
        }
        guard let p = Self.pass(color: make(Self.colorFormat, 4), depth: make(.depth32Float, 4), resolveColor: make(Self.colorFormat, 1), resolveDepth: make(.depth32Float, 1)) else { return }
        for root in roots.values { root.isHidden = false }
        camera.position = .init(0, 1, 6); camera.look(at: SCNVector3Zero)
        renderer.render(atTime: 0, viewport: CGRect(x: 0, y: 0, width: 64, height: 40), commandBuffer: cb, passDescriptor: p)
        cb.commit(); cb.waitUntilCompleted()
    }
    func render(card: ArtifactCard, time: Float, seed: Float, speed: Float, yaw: Float, pitch: Float, magnify: Float, viewer: SIMD3<Float>, parallax: Float, hudVisible: Bool, aspect: Float, viewport: CGSize, commandBuffer: MTLCommandBuffer, passDescriptor: MTLRenderPassDescriptor) {
        SCNTransaction.begin(); SCNTransaction.disableActions = true
        for (kind, root) in roots {
            root.isHidden = kind != card.kind
            root.position.y = CGFloat(sin(time * 0.7) * 0.06)
            root.eulerAngles = .init(0.04 * sin(time * 0.3), 0.35 + time * speed * 0.12, 0.03 * sin(time * 0.4))
        }
        updateLabel(card)
        let cycle = 0.5 + 0.38 * sin(time * 2 * .pi / 60)
        if sand.count == 2 {
            let loS = pow(cycle, 0.55), hiS = pow(1 - cycle, 0.55)
            sand[0].simdScale = .init(loS, cycle, loS); sand[0].position.y = CGFloat(-0.88 + cycle * 0.28)
            sand[1].simdScale = .init(hiS, 1 - cycle, hiS); sand[1].position.y = CGFloat(0.05 + (1 - cycle) * 0.26)
        }
        for reel in reels { reel.eulerAngles.z = CGFloat(time * 0.15) }
        var eye = SIMD3<Float>(0, 1.1, 6), right = SIMD3<Float>(1, 0, 0), fwd = simd_normalize(-eye)
        LerpTurn.orbit(yaw: yaw, pitch: pitch, magnify: magnify, pivot: .zero, up: .init(0, 1, 0), eye: &eye, right: &right, fwd: &fwd)
        eye += viewer * parallax * 0.1
        camera.simdPosition = eye
        camera.look(at: SCNVector3(hudVisible && aspect > 1.25 ? 0.75 : 0, 0, 0))
        SCNTransaction.commit()
        renderer.render(atTime: Double(time), viewport: CGRect(origin: .zero, size: viewport), commandBuffer: commandBuffer, passDescriptor: passDescriptor)
    }
}
