import Foundation
import Metal
import ImageIO
import CoreGraphics

struct ArtifactUniforms {
    var params0 = SIMD4<Float>.zero
    var params1 = SIMD4<Float>.zero
    var params2 = SIMD4<Float>.zero
    var params3 = SIMD4<Float>.zero
}

/// Render-thread state; only the locked loader and group-published scene cross queues.
public final class ArtifactData: LerpDataProvider, @unchecked Sendable {
    private let device: MTLDevice
    private let live: Bool
    private let lock = NSLock()
    private var latest = ArtifactTelemetry.fixture
    private var loading = false
    private var snapshot = ArtifactTelemetry.fixture
    private var seed: Float?
    private var lastTime: Float = 0
    private var lastWall: TimeInterval = 0
    private var startWall: TimeInterval = 0
    private let building = DispatchGroup()
    private var scene: ArtifactScene?
    private let hud: ArtifactHUDLayer
    private let ring: LerpBufferRing?
    private var buffer: MTLBuffer?
    private var color: MTLTexture?
    private var depth: MTLTexture?
    private var targets: [MTLTexture] = []
    private var photos: [String: MTLTexture] = [:]
    private var attempted = Set<String>()
    private lazy var blank: MTLTexture? = {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)
        var bytes: UInt32 = 0
        t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        return t
    }()

    public init(device: MTLDevice, mode: LerpRenderMode = .live) {
        self.device = device
        live = mode == .live && (Bundle.main.bundleIdentifier != nil || ProcessInfo.processInfo.environment["LERP_ARTIFACTS_LIVE"] == "1")
        hud = ArtifactHUDLayer(device: device)
        ring = LerpBufferRing(device: device, length: MemoryLayout<ArtifactUniforms>.stride, count: 3, label: "artifact uniforms")
        if live { refresh() }
        DispatchQueue.global(qos: .userInitiated).async(group: building) { [self] in
            let s = ArtifactScene(device: device)
            s.precompile()
            scene = s
        }
    }

    private func refresh() {
        lock.lock()
        guard !loading else { lock.unlock(); return }
        loading = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { [self] in
            let value = ArtifactLedger.loadLive()
            lock.lock()
            latest = value
            loading = false
            lock.unlock()
        }
    }

    public var metalPrelude: String {
        """
        struct ArtifactUniforms {
            float4 params0;
            float4 params1;
            float4 params2;
            float4 params3;
        };
        constexpr sampler lerpArtifactSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        """
    }

    private func photo(_ path: String, depth: Bool) -> MTLTexture? {
        let key = (depth ? "depth:" : "color:") + path
        if attempted.contains(key) { return photos[key] }
        attempted.insert(key)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if depth {
            photos[key] = LerpImageAssets.loadDepth(url, device: device)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096
                  ] as CFDictionary) {
            let w = image.width, h = image.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.displayP3),
                      let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            if ok {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
                d.storageMode = .shared
                if let t = device.makeTexture(descriptor: d) {
                    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
                    if let cb = device.makeCommandQueue()?.makeCommandBuffer(), let b = cb.makeBlitCommandEncoder() {
                        b.generateMipmaps(for: t); b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
                    }
                    photos[key] = t
                }
            }
        }
        return photos[key]
    }

    public func encodeCompute(into commandBuffer: MTLCommandBuffer, uniforms u: LerpUniforms, params: LerpParameterValues?) {
        func p(_ name: String, _ fallback: Float) -> Float { params?[name]?.scalarValue.map(Float.init) ?? fallback }
        let wall = Date.timeIntervalSinceReferenceDate
        if seed != u.seed || u.time < lastTime || wall - lastWall > 20 {
            seed = u.seed; startWall = wall
            if live { lock.lock(); snapshot = latest; lock.unlock(); refresh() }
        }
        if live && wall - startWall <= 0.75 { lock.lock(); snapshot = latest; lock.unlock() }
        lastWall = wall; lastTime = u.time
        let card = ArtifactLedger.card(telemetry: snapshot, requestedRelic: Int(p("relic", 0)), time: u.time, seed: u.seed)
        let res = u.resolution
        let visible = p("hud", 1) > 0.02 && res.y >= 180
        var isPhoto = false, hasDepth = false
        color = blank; depth = blank
        if card.kind == .photo, let meta = card.photoRelic, let t = photo(meta.imagePath, depth: false) {
            color = t; isPhoto = true
            if let path = meta.depthPath, let d = photo(path, depth: true) { depth = d; hasDepth = true }
        }
        if !isPhoto {
            building.wait()
            let fit = min(1, sqrt(Float(2560 * 1600) / max(1, res.x * res.y)))
            let w = max(1, Int(res.x * fit)), h = max(1, Int(res.y * fit))
            if targets.first?.width != w || targets.first?.height != h {
                targets = []
                for i in 0..<4 {
                    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: i % 2 == 0 ? ArtifactScene.colorFormat : .depth32Float, width: w, height: h, mipmapped: false)
                    d.sampleCount = i < 2 ? ArtifactScene.samples : 1
                    d.textureType = i < 2 ? .type2DMultisample : .type2D
                    d.storageMode = .private
                    d.usage = i < 2 ? .renderTarget : [.renderTarget, .shaderRead]
                    if let t = device.makeTexture(descriptor: d) { targets.append(t) }
                }
            }
            if targets.count == 4, let pass = ArtifactScene.pass(color: targets[0], depth: targets[1], resolveColor: targets[2], resolveDepth: targets[3]) {
                let v = u.viewer.offset
                scene?.render(card: card, time: u.time, seed: u.seed, speed: p("speed", 0.5), yaw: p("yaw", 0), pitch: p("pitch", 0), magnify: p("magnify", 0), viewer: SIMD3(v.x, v.y, v.z), parallax: p("parallax", 0.8), hudVisible: visible, aspect: res.x / max(1, res.y), viewport: CGSize(width: w, height: h), commandBuffer: commandBuffer, passDescriptor: pass)
                color = targets[2]; depth = targets[3]
            }
        }
        hud.update(card: card, drawable: res, showStatus: snapshot.isLive && visible, commandBuffer: commandBuffer)
        var a = ArtifactUniforms()
        a.params0 = SIMD4(isPhoto ? 1 : 0, visible ? p("hud", 1) : 0, card.photoRelic?.aspect ?? 1, Float(card.kind.rawValue))
        a.params1 = SIMD4(0.12, 0.15, 0.20, p("fog", 0.65))
        a.params2 = SIMD4(p("yaw", 0) * .pi / 180, p("pitch", 0) * .pi / 180, exp(p("magnify", 0)), sin(u.time * 0.4) * 0.015)
        a.params3 = SIMD4(visible ? 1 : 0, u.time, hasDepth ? 1 : 0, snapshot.isLive ? 1 : 0)
        buffer = ring?.next()
        if let buffer { withUnsafeBytes(of: &a) { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(color ?? blank, index: 1)
        encoder.setFragmentTexture(depth ?? blank, index: 2)
        encoder.setFragmentTexture(hud.bindable ?? blank, index: 3)
    }
}
