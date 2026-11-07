// Loads each .usdz with SceneKit (the importer the scene lane uses) and prints
// every named node: its position (pivot) in its parent, its world-space
// bounding box, triangle count, and material names, so the naming/pivot
// convention in CRITTER3D can be checked against what SceneKit actually sees.
//
//   swiftc -O tools/critter-assets/inspect.swift -o /tmp/inspect
//   /tmp/inspect Sources/Critter/*.usdz [--render out.png]
import SceneKit
import Metal
import AppKit

func f(_ v: SCNVector3) -> String { String(format: "(%6.3f, %6.3f, %6.3f)", v.x, v.y, v.z) }

func worldBox(_ n: SCNNode) -> (SCNVector3, SCNVector3)? {
    var lo = SCNVector3(Float.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
    var hi = SCNVector3(-Float.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
    var any = false
    n.enumerateHierarchy { c, _ in
        guard let g = c.geometry else { return }
        let (a, b) = g.boundingBox
        for i in 0..<8 {
            let p = SCNVector3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z)
            let w = c.convertPosition(p, to: nil)
            lo = SCNVector3(min(lo.x, w.x), min(lo.y, w.y), min(lo.z, w.z))
            hi = SCNVector3(max(hi.x, w.x), max(hi.y, w.y), max(hi.z, w.z))
            any = true
        }
    }
    return any ? (lo, hi) : nil
}

func tris(_ n: SCNNode) -> Int {
    var t = 0
    n.enumerateHierarchy { c, _ in
        for e in c.geometry?.elements ?? [] where e.primitiveType == .triangles { t += e.primitiveCount }
    }
    return t
}

var args = Array(CommandLine.arguments.dropFirst())
var renderPath: String?
if let i = args.firstIndex(of: "--render") { renderPath = args[i + 1]; args.removeSubrange(i...i + 1) }

var total = 0
let world = SCNScene()
for path in args {
    let scene = try! SCNScene(url: URL(fileURLWithPath: path))
    print("== \(URL(fileURLWithPath: path).lastPathComponent)")
    func walk(_ n: SCNNode, _ depth: Int) {
        let name = n.name ?? "?"
        let geo = n.geometry.map { g -> String in
            let srcs = g.sources.map { $0.semantic.rawValue }.joined(separator: ",")
            let mats = g.materials.map { $0.name ?? "?" }.joined(separator: ",")
            return " geo[\(srcs)] mats[\(mats)]"
        } ?? ""
        let box = worldBox(n).map { " box \(f($0.0))..\(f($0.1))" } ?? ""
        let rot = n.eulerAngles
        let r = (abs(rot.x) + abs(rot.y) + abs(rot.z)) > 1e-4 ? " rot \(f(rot))" : ""
        let sc = n.scale.x != 1 || n.scale.y != 1 || n.scale.z != 1 ? " scale \(f(n.scale))" : ""
        print(String(repeating: "  ", count: depth) + "\(name) pos \(f(n.position))\(r)\(sc) tris \(tris(n))\(box)\(geo)")
        for c in n.childNodes { walk(c, depth + 1) }
    }
    for c in scene.rootNode.childNodes { walk(c, 0) }
    let t = tris(scene.rootNode); total += t
    print("   triangles: \(t)")
    for c in scene.rootNode.childNodes where c.name != "materials" {
        // laid out on a grid, each scaled to unit size, for the --render sheet
        let k = world.rootNode.childNodes.count
        let n = c.clone()
        if let (lo, hi) = worldBox(c) {
            let s: CGFloat = 1.0 / max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
            n.scale = SCNVector3(s, s, s)
            let gx = CGFloat(k % 6) * 1.25, gy = -CGFloat(k / 6) * 1.25
            let cx: CGFloat = (lo.x + hi.x) / 2, cz: CGFloat = (lo.z + hi.z) / 2
            let px: CGFloat = gx - cx * s, py: CGFloat = gy - lo.y * s
            n.position = SCNVector3(px, py, -cz * s)
        }
        world.rootNode.addChildNode(n)
    }
}
print("TOTAL triangles: \(total)")

if let out = renderPath {
    let dev = MTLCreateSystemDefaultDevice()!
    let (lo, hi) = worldBox(world.rootNode)!
    let cam = SCNNode(); cam.camera = SCNCamera()
    let c = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
    let ext = max(hi.x - lo.x, hi.y - lo.y)
    cam.position = SCNVector3(c.x, c.y + ext * 0.25, c.z + ext * 1.05); cam.look(at: c)
    world.rootNode.addChildNode(cam)
    let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.eulerAngles = SCNVector3(-0.8, 0.5, 0)
    world.rootNode.addChildNode(key)
    let amb = SCNNode(); amb.light = SCNLight(); amb.light!.type = .ambient; amb.light!.intensity = 400
    world.rootNode.addChildNode(amb)
    let r = SCNRenderer(device: dev, options: nil); r.scene = world; r.pointOfView = cam
    let W = 600, H = 375
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
    let tex = dev.makeTexture(descriptor: td)!
    let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
    dd.usage = .renderTarget; dd.storageMode = .private
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.78, blue: 0.95, alpha: 1)
    rp.colorAttachments[0].storeAction = .store
    rp.depthAttachment.texture = dev.makeTexture(descriptor: dd)!; rp.depthAttachment.loadAction = .clear
    let cb = dev.makeCommandQueue()!.makeCommandBuffer()!
    r.render(atTime: 0, viewport: CGRect(x: 0, y: 0, width: W, height: H), commandBuffer: cb, passDescriptor: rp)
    cb.commit(); cb.waitUntilCompleted()
    var px = [UInt8](repeating: 0, count: W * H * 4)
    tex.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32)!
    for i in 0..<(W * H) {
        rep.bitmapData![i * 4] = px[i * 4 + 2]; rep.bitmapData![i * 4 + 1] = px[i * 4 + 1]
        rep.bitmapData![i * 4 + 2] = px[i * 4]; rep.bitmapData![i * 4 + 3] = 255
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("rendered \(out)")
}
