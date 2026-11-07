import Foundation
import Metal
import simd

/// Photoreal 3D Gaussian splat captures, drawn the way 3DGS viewers draw them:
/// each splat's 3D covariance projected to a screen-space ellipse, sorted back
/// to front, and alpha-blended as an instanced quad. A look opts in with
///
///     // lerp-data: splat:<move>:<capture>
///
/// where `<capture>` names a `.lsplat` file (made by `scripts/splat-convert.py`
/// from `Sources/Splats/captures.json`) and `<move>` picks the camera:
///
///     orbit   circle (or sweep an arc of) the subject — turntables, places
///     dolly   dolly zoom: the lens zooms while the camera backs off, so the
///             subject keeps its size and the background compresses
///
/// A drag on the render (`LerpTurn`, for a look that declares `yaw`/`pitch`)
/// swings the camera round the point it looks at, which is right wherever the
/// subject is that point. A capture seen from inside — a square, a room — is
/// mostly far beyond it, and would move against the hand; `:look` on the end
/// (`splat:orbit:trogir-square:look`) turns that camera where it stands.
///
/// The engine draws one fullscreen fragment function, so the splats are drawn
/// here, in `encodeCompute`, into a texture this provider owns; the look's
/// fragment shader then reads it as `texture(1)` with the camera summary
/// `LerpSplatView` at `buffer(1)` and composites whatever the look adds (a
/// glass globe, a filter, a background).
///
/// **Purity.** The camera, the deformation and the sort are all derived from
/// `(time, seed, params)` every frame; the only thing kept between frames is
/// the decoded capture, which is input, not state.
public final class SplatData: LerpDataProvider {

    public enum Move: String { case orbit, dolly }

    let move: Move
    let captureName: String
    /// `:look`: a drag turns the camera where it stands, not round its target.
    let turnsInPlace: Bool
    private let device: MTLDevice
    private var target: MTLTexture?
    private var view = LerpSplatViewInfo()
    /// This frame's colour of every visible splat, view-dependent colour
    /// included; written by the `splatShade` kernel, read by the vertex stage.
    private var shaded: MTLBuffer?
    /// The look's `// lerp-caption…:` text, set as a texture (`texture(2)`).
    private lazy var captionLayer = LerpSplatCaptionLayer(device: device)

    /// Set by `ShaderLibrary.dataProvider(for:)` each time a look using this
    /// capture is installed.
    var caption: [LerpCaptionLine] {
        get { [] }
        set { captionLayer.set(newValue) }
    }

    // Sort scratch, reused every frame.
    private var depth: [Float] = []
    private var counts: [UInt32] = []
    static let sortChunks = max(4, min(16, ProcessInfo.processInfo.activeProcessorCount))

    /// Most pixels the splat pass draws, whatever the drawable. Splats are
    /// soft, so a 5K screen drawn at ~2.7K and filtered up is indistinguishable
    /// and costs a third of the fill.
    static let maxPixels: Float = 3_800_000

    public init?(device: MTLDevice, spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count == 3 || (parts.count == 4 && parts[3] == "look"),
              parts[0] == "splat", let move = Move(rawValue: parts[1]) else { return nil }
        self.device = device
        self.move = move
        self.captureName = parts[2]
        self.turnsInPlace = parts.count == 4
        // Decode off the render thread as soon as the look is known, so the
        // first frame usually finds it ready.
        LerpSplatAssets.prefetch(captureName, device: device)
    }

    public var metalPrelude: String { Self.lookPrelude }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        bind(to: encoder, uniforms: uniforms, params: nil)
    }

    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms,
                     params: LerpParameterValues?) {
        var info = view
        encoder.setFragmentBytes(&info, length: MemoryLayout<LerpSplatViewInfo>.stride, index: 1)
        if let target { encoder.setFragmentTexture(target, index: 1) }
        encoder.setFragmentTexture(captionLayer.bindable, index: 2)
    }

    public func encodeCompute(into commandBuffer: MTLCommandBuffer,
                              uniforms: LerpUniforms,
                              params: LerpParameterValues?) {
        let res = uniforms.resolution
        let scale = min(1, sqrt(Self.maxPixels / max(1, res.x * res.y)))
        let w = max(1, Int((res.x * scale).rounded())), h = max(1, Int((res.y * scale).rounded()))
        // A caption's glass and frost blur the capture behind them by reading
        // its mipmaps, so a captioned look keeps a mipmapped target.
        captionLayer.update(drawable: res, commandBuffer: commandBuffer)
        let mipmapped = !captionLayer.isEmpty
        if target?.width != w || target?.height != h || (target?.mipmapLevelCount ?? 1 > 1) != mipmapped {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w,
                                                             height: h, mipmapped: mipmapped)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            target = device.makeTexture(descriptor: d)
            target?.label = "splat.\(captureName)"
        }
        guard let target else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let asset = LerpSplatAssets.asset(captureName, device: device),
              let pipelines = LerpSplatPipeline.shared(for: device) else {
            // Missing capture: an empty (transparent) frame, so the look shows
            // its background rather than last frame's splats.
            commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            view = LerpSplatViewInfo(caption: captionLayer.rect)
            return
        }

        let cam = camera(uniforms: uniforms, params: params, size: SIMD2(Float(w), Float(h)))
        let deform = deformation(uniforms: uniforms, params: params)
        let visible = sort(asset: asset, cam: cam, deform: deform, size: SIMD2(Float(w), Float(h)))

        var u = LerpSplatUniforms(view: cam.view, focal: SIMD2(cam.focal, cam.focal),
                                  viewport: SIMD2(Float(w), Float(h)), principal: cam.principal,
                                  deform: deform)
        if shaded == nil || shaded!.length < asset.count * 8 {
            shaded = device.makeBuffer(length: max(8, asset.count * 8), options: .storageModePrivate)
            shaded?.label = "splat.shaded"
        }
        guard let shaded else { return }
        if let order = visible.buffer, visible.count > 0,
           let compute = commandBuffer.makeComputeCommandEncoder() {
            // View-dependent colour, once per visible splat: the direction from
            // the eye, turned back into the capture's own frame, through its
            // spherical harmonics.
            let eye = cam.view.inverse * SIMD4<Float>(0, 0, 0, 1)
            let r = asset.shRotation
            var sh = LerpSplatShade(eye: eye, r0: SIMD4(r[0], 0), r1: SIMD4(r[1], 0), r2: SIMD4(r[2], 0),
                                    coeffs: UInt32(asset.shCoeffs), count: UInt32(visible.count))
            compute.label = "splat shade \(captureName)"
            compute.setComputePipelineState(pipelines.shade)
            compute.setBytes(&u, length: MemoryLayout<LerpSplatUniforms>.stride, index: 0)
            compute.setBytes(&sh, length: MemoryLayout<LerpSplatShade>.stride, index: 1)
            compute.setBuffer(order, offset: 0, index: 2)
            compute.setBuffer(asset.positions, offset: 0, index: 3)
            compute.setBuffer(asset.colors, offset: 0, index: 4)
            compute.setBuffer(asset.shLabels, offset: 0, index: 5)
            compute.setBuffer(asset.shPalette, offset: 0, index: 6)
            compute.setBuffer(asset.shCodebook, offset: 0, index: 7)
            compute.setBuffer(shaded, offset: 0, index: 8)
            let width = pipelines.shade.threadExecutionWidth
            compute.dispatchThreads(MTLSize(width: visible.count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width * 4, height: 1, depth: 1))
            compute.endEncoding()
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "splat \(captureName)"
        if let order = visible.buffer, visible.count > 0 {
            encoder.setRenderPipelineState(pipelines.render)
            encoder.setVertexBytes(&u, length: MemoryLayout<LerpSplatUniforms>.stride, index: 0)
            encoder.setVertexBuffer(order, offset: 0, index: 1)
            encoder.setVertexBuffer(asset.positions, offset: 0, index: 2)
            encoder.setVertexBuffer(asset.covariances, offset: 0, index: 3)
            encoder.setVertexBuffer(shaded, offset: 0, index: 4)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: visible.count)
        }
        encoder.endEncoding()
        if target.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "splat mipmaps \(captureName)"
            blit.generateMipmaps(for: target)
            blit.endEncoding()
        }

        // Where the subject (origin, radius 1) lands, in drawable pixels, for
        // looks that frame something around it.
        let o = cam.view * SIMD4<Float>(0, 0, 0, 1)
        let z = max(0.01, -o.z)
        let focalDrawable = cam.focal / scale
        let shift = cam.principal / scale
        view = LerpSplatViewInfo(
            center: SIMD2(res.x * 0.5 + focalDrawable * o.x / z + shift.x,
                          res.y * 0.5 - focalDrawable * o.y / z - shift.y),
            radius: focalDrawable * cam.subjectRadius / z,
            fovy: cam.fovy, ready: 1, phase: deform.phase, splats: Float(visible.count), pad: 0,
            caption: captionLayer.rect)
    }

    // MARK: - Camera

    struct Camera {
        var view: simd_float4x4
        var focal: Float      // pixels of the splat target
        var fovy: Float
        /// Where the image centre sits, in pixels of the splat target from the
        /// middle, y up. Zero but for a tracked viewer (`applyViewer`).
        var principal = SIMD2<Float>(0, 0)
        var subjectRadius: Float = 1
        /// Splats nearer than this are not drawn. A capture is only well
        /// formed near the cameras that photographed it; a camera that backs
        /// away (the dolly) looks through the floaters and foliage it left
        /// behind, so those are cut away in front of the subject.
        var near: Float = 0.02
    }

    private func param(_ p: LerpParameterValues?, _ name: String, _ fallback: Float) -> Float {
        guard let v = p?[name]?.scalarValue else { return fallback }
        return Float(v)
    }

    private func camera(uniforms: LerpUniforms, params: LerpParameterValues?, size: SIMD2<Float>) -> Camera {
        var cam = movingCamera(uniforms: uniforms, params: params, size: size)
        Self.applyViewer(uniforms.viewer, gain: LerpViewer.gain(in: params), to: &cam, size: size)
        return cam
    }

    /// The look's own camera move, before any viewer is applied.
    private func movingCamera(uniforms: LerpUniforms, params: LerpParameterValues?, size: SIMD2<Float>) -> Camera {
        let t = max(0, uniforms.time)
        let speed = param(params, "speed", 1)
        let distance = param(params, "distance", 3)
        let height = param(params, "height", 0.35)
        let lookHeight = param(params, "lookHeight", 0)
        let startAngle = param(params, "angle", 0) * .pi / 180
        let arc = param(params, "arc", 360) * .pi / 180
        let period = max(4, param(params, "period", 60)) / max(0.01, speed)
        let seedTurn = uniforms.seed * 2 * .pi
        let target = SIMD3<Float>(0, lookHeight, 0)

        switch move {
        case .orbit:
            let fovy = param(params, "fov", 35) * .pi / 180
            let angle: Float
            if arc >= 2 * .pi - 0.001 {
                // Full turntable; the seed picks where in the turn a launch starts.
                angle = startAngle + seedTurn + 2 * .pi * t / period
            } else {
                // Sweep an arc and back, eased at the ends.
                let s = 0.5 - 0.5 * cos(2 * .pi * (t / period + uniforms.seed))
                angle = startAngle + (s - 0.5) * arc
            }
            let bob = param(params, "bob", 0) * sin(2 * .pi * (t / (period * 0.37) + uniforms.seed))
            let eye = SIMD3(sin(angle) * distance, height + bob, cos(angle) * distance)
            let focal = 0.5 * size.y / tan(fovy * 0.5)
            let clip = param(params, "clip", 0)
            return Camera(view: turnedView(eye: eye, target: target, params: params), focal: focal, fovy: fovy,
                          near: clip > 0 ? max(0.02, simd_length(eye - target) - clip) : 0.02)

        case .dolly:
            // VoxelKei's telephoto compression, as a move: the field of view
            // swings between wide and long, and the camera distance follows
            // d = r / tan(fov / 2) so the subject's framed size never changes.
            let wide = param(params, "wideFov", 70) * .pi / 180
            let long = param(params, "longFov", 9) * .pi / 180
            let s = 0.5 - 0.5 * cos(2 * .pi * (t / period + uniforms.seed))
            // Interpolate in log-tangent space so the zoom feels even.
            let lt = log(tan(wide * 0.5)) * (1 - s) + log(tan(long * 0.5)) * s
            let half = atan(exp(lt))
            let framing = param(params, "framing", 1.4)   // subject radii above/below centre
            let d = framing / tan(half)
            let drift = param(params, "drift", 0) * .pi / 180 * sin(2 * .pi * (t / (period * 1.7)))
            let angle = startAngle + drift
            let dir = SIMD3(sin(angle), 0, cos(angle))
            let eye = target + dir * d + SIMD3(0, height * d / distance, 0)
            let focal = 0.5 * size.y / tan(half)
            let clip = param(params, "clip", 1.5)
            return Camera(view: turnedView(eye: eye, target: target, params: params), focal: focal, fovy: 2 * half,
                          near: max(0.02, simd_length(eye - target) - clip))
        }
    }

    /// `lookAt`, after a drag has swung the eye round the target or, for a
    /// `:look` capture, turned it where it stands (`LerpTurn`). The distance
    /// to the target is unchanged, so the clip plane measured from it holds.
    private func turnedView(eye: SIMD3<Float>, target: SIMD3<Float>, params: LerpParameterValues?) -> simd_float4x4 {
        let yaw = param(params, LerpTurn.yawParameter, 0), pitch = param(params, LerpTurn.pitchParameter, 0)
        guard yaw != 0 || pitch != 0 else { return Self.lookAt(eye: eye, target: target) }
        let up = SIMD3<Float>(0, 1, 0)
        var eye = eye, fwd = simd_normalize(target - eye)
        var right = simd_normalize(simd_cross(fwd, up))
        if turnsInPlace {
            LerpTurn.look(yaw: yaw, pitch: pitch, up: up, right: &right, fwd: &fwd)
        } else {
            LerpTurn.orbit(yaw: yaw, pitch: pitch, pivot: target, up: up, eye: &eye, right: &right, fwd: &fwd)
        }
        return Self.lookAt(eye: eye, target: eye + fwd, up: simd_cross(right, fwd))
    }

    /// `LerpViewer.eye` as a rasteriser applies it: the eye steps by `e`
    /// without turning, the image centre shifts by `e.xy`, and the focal length
    /// shrinks to the glass's new distance — so a point at the look's own
    /// screen distance stays on the same pixel. Leaves `cam` untouched for a
    /// centred viewer or a look with no `parallax` gain.
    static func applyViewer(_ viewer: LerpViewer, gain: Float, to cam: inout Camera, size: SIMD2<Float>) {
        guard gain != 0, viewer != .centered else { return }
        let half = 0.5 * size.y                 // pixels per unit of the short-axis screen
        let screen = cam.focal / half           // the glass's distance, in those units
        let e = viewer.eye(focal: screen, gain: gain)
        // Camera space looks down -z, so stepping forward is -z there.
        cam.view.columns.3 -= SIMD4(e.x, e.y, -e.z, 0)
        cam.focal *= max(0.2, screen - e.z) / screen
        cam.principal = SIMD2(e.x, e.y) * half
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float> = SIMD3(0, 1, 0)) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        var r = simd_cross(f, up)
        if simd_length(r) < 1e-5 { r = SIMD3(1, 0, 0) }
        r = simd_normalize(r)
        let u = simd_cross(r, f)
        // Rows r, u, -f: camera space x right, y up, looking down -z.
        return simd_float4x4(rows: [
            SIMD4(r, -simd_dot(r, eye)),
            SIMD4(u, -simd_dot(u, eye)),
            SIMD4(-f, simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    // MARK: - Deformation

    private func deformation(uniforms: LerpUniforms, params: LerpParameterValues?) -> LerpSplatDeform {
        var d = LerpSplatDeform()
        d.mode = UInt32(max(0, param(params, "deform", 0)))
        d.time = max(0, uniforms.time) * param(params, "speed", 1) + 97 * uniforms.seed
        d.amount = param(params, "amount", 0.08) * (1 + 3 * uniforms.audio.bass)
        d.frequency = param(params, "frequency", 6)
        let cycle = max(4, param(params, "cycle", 24))
        d.phase = (max(0, uniforms.time) / cycle + uniforms.seed).truncatingRemainder(dividingBy: 1)
        return d
    }

    // MARK: - Sort

    private var orderBuffers: LerpBufferRing?
    private var orderBufferCount = 0

    /// Back-to-front order of the splats in front of the camera, as a 16-bit
    /// counting sort over view depth. Depths of displaced splats come from the
    /// same displacement the vertex shader applies (`LerpSplatDeform.apply`),
    /// so a dissolving capture still blends in the right order.
    private func sort(asset: LerpSplatAsset, cam: Camera, deform: LerpSplatDeform,
                      size: SIMD2<Float>) -> (buffer: MTLBuffer?, count: Int) {
        let n = asset.count
        if depth.count < n { depth = [Float](repeating: 0, count: n) }
        if orderBufferCount < n {
            orderBufferCount = n
            orderBuffers = LerpBufferRing(device: device, length: max(4, n * 4), label: "splat.order")
        }
        guard let orderBuffer = orderBuffers?.next() else { return (nil, 0) }

        let v = cam.view
        let r0 = SIMD4(v[0][0], v[1][0], v[2][0], v[3][0])
        let r1 = SIMD4(v[0][1], v[1][1], v[2][1], v[3][1])
        let r2 = SIMD4(v[0][2], v[1][2], v[2][2], v[3][2])
        let halfW = size.x * 0.5 / cam.focal * 1.25, halfH = size.y * 0.5 / cam.focal * 1.25
        let shift = cam.principal / cam.focal   // image-centre offset, as a slope
        let near = cam.near
        let displaced = deform.movesSplats

        // Every pass splits the splats into the same contiguous chunks and
        // runs them in parallel; the scatter keeps each chunk's splats in
        // index order within a bucket, so the result is the same order a
        // single-threaded counting sort would produce, whatever the timing.
        let chunks = Self.sortChunks
        let bins = 1 << 16
        if counts.count < chunks * bins { counts = [UInt32](repeating: 0, count: chunks * bins) }
        var mins = [Float](repeating: .infinity, count: chunks)
        var maxs = [Float](repeating: -.infinity, count: chunks)
        let pos = asset.positions.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let dbase = depth.withUnsafeMutableBufferPointer { $0.baseAddress! }
        mins.withUnsafeMutableBufferPointer { mn in
            maxs.withUnsafeMutableBufferPointer { mx in
                let mnb = mn.baseAddress!, mxb = mx.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let lo = n * c / chunks, hi = n * (c + 1) / chunks
                    var zmin = Float.infinity, zmax = -Float.infinity
                    for i in lo..<hi {
                        var p = pos[i]
                        p.w = 1
                        if displaced { p = SIMD4(deform.apply(SIMD3(p.x, p.y, p.z), index: UInt32(i)), 1) }
                        let z = -simd_dot(r2, p)
                        // Cull behind the camera and well outside the frustum
                        // (with margin, for splats whose centre is off screen
                        // but whose footprint is not).
                        if z < near { dbase[i] = -1; continue }
                        let x = simd_dot(r0, p), y = simd_dot(r1, p)
                        if abs(x + shift.x * z) > z * halfW + 0.5 || abs(y + shift.y * z) > z * halfH + 0.5 {
                            dbase[i] = -1; continue
                        }
                        dbase[i] = z
                        zmin = min(zmin, z); zmax = max(zmax, z)
                    }
                    mnb[c] = zmin; mxb[c] = zmax
                }
            }
        }
        let zmin = mins.min() ?? 0, zmax = maxs.max() ?? 0
        guard zmax >= zmin else { return (orderBuffer, 0) }
        let k = Float(bins - 1) / max(1e-6, zmax - zmin)

        let order = orderBuffer.contents().bindMemory(to: UInt32.self, capacity: n)
        let cbase = counts.withUnsafeMutableBufferPointer { $0.baseAddress! }
        // Per-chunk histograms. Key 0 is the farthest splat.
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let h = cbase + c * bins
            h.update(repeating: 0, count: bins)
            for i in (n * c / chunks)..<(n * (c + 1) / chunks) where dbase[i] >= 0 {
                h[Int((zmax - dbase[i]) * k)] &+= 1
            }
        }
        // Bucket-major, chunk-minor prefix sum: each chunk's slice of a bucket
        // follows the previous chunk's.
        var running: UInt32 = 0
        for b in 0..<bins {
            for c in 0..<chunks {
                let slot = cbase + c * bins + b
                let count = slot.pointee
                slot.pointee = running
                running &+= count
            }
        }
        let visible = Int(running)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let h = cbase + c * bins
            for i in (n * c / chunks)..<(n * (c + 1) / chunks) where dbase[i] >= 0 {
                let b = Int((zmax - dbase[i]) * k)
                order[Int(h[b])] = UInt32(i)
                h[b] &+= 1
            }
        }
        return (orderBuffer, visible)
    }

    // MARK: - Metal

    /// Spliced into every look that declares a splat provider.
    static let lookPrelude = """
    // ---- splat captures (SplatData.swift) --------------------------------------
    // texture(1): the capture drawn this frame, premultiplied RGBA, possibly at a
    // lower resolution than the drawable (sample it with lerpSplatSample).
    // buffer(1): LerpSplatView.
    struct LerpSplatView {
        float2 center;   // the subject's centre, drawable pixels, y down
        float  radius;   // the subject's radius (1 capture unit), drawable pixels
        float  fovy;     // radians
        float  ready;    // 0 while the capture is missing
        float  phase;    // deform cycle phase, 0..1
        float  splats;   // splats drawn this frame
        float  pad;
        float4 caption;  // the caption's panel: x, y, w, h in drawable px, y down (w = 0: none)
    };

    static inline float4 lerpSplatSample(texture2d<half> t, float2 px, float2 res) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(t.sample(s, px / res));
    }

    // Captures are trained against sRGB photos; the layer is Display P3.
    static inline float3 lerpSplatToP3(float3 c) {
        float3 lin = select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
        const float3x3 m = float3x3(float3(0.8225, 0.0332, 0.0171),
                                    float3(0.1774, 0.9669, 0.0724),
                                    float3(0.0000, 0.0000, 0.9108));
        float3 p = max(m * lin, 0.0);
        return select(1.055 * pow(p, 1.0 / 2.4) - 0.055, p * 12.92, p <= 0.0031308);
    }

    // The capture over a background, colour converted on unpremultiplied values.
    static inline float3 lerpSplatOver(float4 s, float3 bg) {
        float3 c = s.a > 1e-4 ? lerpSplatToP3(saturate(s.rgb / s.a)) : float3(0.0);
        return c * s.a + (1.0 - s.a) * bg;
    }

    // ---- captions ----------------------------------------------------------
    // texture(2): the look's `// lerp-caption…:` lines as glyph coverage,
    // mipmapped, covering exactly V.caption. A captioned look's texture(1) is
    // mipmapped too, so the panel can blur what is behind it.

    // Signed distance to a rounded rectangle, in pixels; negative inside.
    static inline float lerpCaptionBox(float2 p, float2 c, float2 half_, float r) {
        float2 q = abs(p - c) - half_ + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // The capture over `bg`, blurred by about `radiusPx` drawable pixels: a
    // 3×3 tent read from the mip level that size lands on.
    static inline float3 lerpSplatBlur(texture2d<half> t, float2 px, float2 res, float radiusPx, float3 bg) {
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
        float k = float(t.get_width()) / res.x;
        float lod = clamp(log2(max(radiusPx * k, 1.0)), 0.0, float(t.get_num_mip_levels()) - 1.0);
        float stepPx = exp2(lod) / k;
        float4 acc = 0.0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float w = (i == 0 ? 2.0 : 1.0) * (j == 0 ? 2.0 : 1.0);
                acc += w * float4(t.sample(s, (px + float2(i, j) * stepPx) / res, level(lod)));
            }
        }
        return lerpSplatOver(acc / 16.0, bg);
    }

    // The caption over `color` (the capture over `bg` at this pixel), in one
    // of four treatments, faded by `fade`:
    //   1 frosted       a rounded panel of heavily blurred, tinted capture
    //   2 liquid glass  a clear slab: light blur, edges that refract what is
    //                   beyond them, a lit rim and a soft shadow
    //   3 diffuse       no edge at all; the capture blurs and dims in a soft
    //                   cloud behind the type
    //   4 label         type alone, held off the image by a soft dark halo
    // Frosted and glass pick dark or light type from what is behind them.
    static inline float3 lerpSplatCaption(float3 color, float3 bg, float2 px, float2 res,
                                          constant LerpSplatView& V, texture2d<half> splat,
                                          texture2d<half> label, int style, float fade) {
        if (style <= 0 || V.caption.z <= 0.0 || fade <= 0.0) return color;
        float H = res.y;
        float2 org = V.caption.xy, size = V.caption.zw, c = org + 0.5 * size;
        float radius = style == 2 ? min(0.5 * size.y, 0.04 * H) : 0.009 * H;
        float d = lerpCaptionBox(px, c, 0.5 * size, radius);
        if (d > 0.12 * H) return color;

        constexpr sampler ts(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 tuv = (px - org) / size;
        float glyph = float(label.sample(ts, tuv, level(0.0)).r);
        float halo = saturate(1.8 * float(label.sample(ts, tuv, level(2.5)).r));
        float inside = 1.0 - smoothstep(-0.75, 0.75, d);

        float3 behind = lerpSplatBlur(splat, c, res, 0.5 * max(size.x, size.y), bg);
        bool dark = dot(behind, float3(0.2126, 0.7152, 0.0722)) > 0.5;
        float3 ink = dark ? float3(0.05, 0.05, 0.06) : float3(1.0);
        float3 out = color;

        if (style == 1) {
            // Smoked, not grey: the blurred capture under a dark tint that
            // lifts a shade toward the top, a single lit edge along the top
            // instead of an outline, and a shadow that only darkens.
            float3 frost = lerpSplatBlur(splat, px, res, 0.035 * H, bg);
            float rise = saturate((c.y - px.y) / (0.5 * size.y));      // 1 at the top edge
            float3 tint = dark ? float3(0.97) : float3(0.035, 0.037, 0.042) + 0.018 * rise;
            float3 panel = mix(frost, tint, dark ? 0.55 : 0.62);
            panel += (fract(sin(dot(px, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.012;
            float edge = 1.0 - smoothstep(0.0, 1.0, abs(d + 0.5));
            panel += edge * (0.015 + 0.09 * pow(rise, 3.0));
            float shadow = 0.35 * (1.0 - smoothstep(0.0, 0.03 * H, d)) * step(0.0, d);
            out = mix(color * (1.0 - shadow), panel, inside);
            out = mix(out, ink, glyph);
        } else if (style == 2) {
            // Outward normal of the panel's edge.
            float e = 1.0;
            float2 n = float2(lerpCaptionBox(px + float2(e, 0), c, 0.5 * size, radius) -
                              lerpCaptionBox(px - float2(e, 0), c, 0.5 * size, radius),
                              lerpCaptionBox(px + float2(0, e), c, 0.5 * size, radius) -
                              lerpCaptionBox(px - float2(0, e), c, 0.5 * size, radius));
            n = length(n) > 1e-4 ? normalize(n) : float2(0.0);
            // A slab with a rounded rim: clear in the middle, and toward the
            // edge it bends in what lies beyond it, fringed by dispersion.
            float band = 0.9 * radius;
            float t = saturate(1.0 + d / band);        // 0 in the middle, 1 at the edge
            float bend = pow(t, 2.5) * band * 1.8;
            float2 lens = c + (px - c) * 0.985;        // a touch of magnification
            float blurPx = 0.0025 * H;
            float3 slab = float3(lerpSplatBlur(splat, lens + n * bend * 1.12, res, blurPx, bg).r,
                                 lerpSplatBlur(splat, lens + n * bend, res, blurPx, bg).g,
                                 lerpSplatBlur(splat, lens + n * bend * 0.88, res, blurPx, bg).b);
            slab = mix(slab, dark ? float3(1.0) : float3(0.0), dark ? 0.16 : 0.2) * 1.04 + 0.01;
            float2 light = normalize(float2(-0.55, -0.85));
            float rim = exp(-pow((d + 1.4) / 1.3, 2.0));
            float lit = 0.25 + 0.75 * pow(saturate(dot(n, light)), 1.5)
                      + 0.35 * pow(saturate(dot(n, -light)), 3.0);
            slab += rim * lit * 0.55 + pow(t, 6.0) * 0.06;
            float shadow = 0.22 * (1.0 - smoothstep(0.0, 0.05 * H, d)) * step(0.0, d);
            out = mix(color * (1.0 - shadow), slab, inside);
            out *= 1.0 - (dark ? 0.0 : 0.5 * halo * inside);
            out = mix(out, ink, glyph);
        } else if (style == 3) {
            float feather = 0.08 * H;
            float m = 1.0 - smoothstep(-0.35 * feather, feather, d);
            float3 haze = lerpSplatBlur(splat, px, res, 0.045 * H, bg) * 0.5;
            out = mix(color, haze, 0.9 * m * m);
            out *= 1.0 - 0.45 * halo;
            out = mix(out, float3(1.0), glyph);
        } else {
            float wide = saturate(2.2 * float(label.sample(ts, tuv, level(3.5)).r));
            out = color * (1.0 - 0.45 * wide) * (1.0 - 0.55 * halo);
            out = mix(out, float3(1.0), glyph);
        }
        return mix(color, out, fade);
    }
    """
}

/// Camera summary handed to the look (`LerpSplatView` in MSL).
struct LerpSplatViewInfo {
    var center = SIMD2<Float>(0, 0)
    var radius: Float = 0
    var fovy: Float = 0
    var ready: Float = 0
    var phase: Float = 0
    var splats: Float = 0
    var pad: Float = 0
    var caption = SIMD4<Float>(0, 0, 0, 0)
}

/// Per-splat displacement, applied identically by the vertex shader and by the
/// CPU sort (`apply`). Must match `LerpSplatDeform` and `splatDeform` in
/// `LerpSplatPipeline.source`.
///
///     0 none
///     1 ripple   rings spreading across the ground plane (y)
///     2 wall     waves rolling across a facade, pushed toward the camera (z)
///     3 twist    the capture wrung about its vertical axis
///     4 dissolve splats drift apart from the bottom up and come back
struct LerpSplatDeform {
    var mode: UInt32 = 0
    var time: Float = 0
    var amount: Float = 0
    var frequency: Float = 6
    var phase: Float = 0
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0

    /// Only the modes that move splats far enough to change their order are
    /// worth repeating on the CPU.
    var movesSplats: Bool { mode == 3 || mode == 4 }

    static func hash(_ x: UInt32) -> UInt32 {
        var v = x &* 747796405 &+ 2891336453
        v = ((v >> ((v >> 28) &+ 4)) ^ v) &* 277803737
        return (v >> 22) ^ v
    }

    static func unit(_ x: UInt32) -> Float { Float(hash(x) >> 8) / Float(1 << 24) }

    /// The dissolve envelope: 0 assembled, 1 fully scattered.
    static func scatter(phase: Float, height: Float) -> Float {
        // Hold, dissolve upward, hold apart briefly, reassemble downward.
        let w: Float
        if phase < 0.45 { w = 0 }
        else if phase < 0.65 { w = (phase - 0.45) / 0.20 }
        else if phase < 0.72 { w = 1 }
        else { w = 1 - (phase - 0.72) / 0.28 }
        let front = w * 1.6 - 0.3          // sweeps -0.3 … 1.3
        let x = min(1, max(0, (front - height) / 0.3))
        return x * x * (3 - 2 * x)
    }

    func apply(_ p: SIMD3<Float>, index i: UInt32) -> SIMD3<Float> {
        switch mode {
        case 3:
            let a = amount * 4 * p.y * sin(time * 0.35)
            let c = cos(a), s = sin(a)
            return SIMD3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z)
        case 4:
            let h = min(1, max(0, (p.y + 1) * 0.5))
            let e = LerpSplatDeform.scatter(phase: phase, height: h)
            if e <= 0 { return p }
            let a = LerpSplatDeform.unit(i &* 3) * 2 * .pi
            let z = LerpSplatDeform.unit(i &* 3 &+ 1) * 2 - 1
            let r = sqrt(max(0, 1 - z * z))
            let dir = SIMD3(r * cos(a), z, r * sin(a))
            let dist = (0.4 + 1.2 * LerpSplatDeform.unit(i &* 3 &+ 2)) * amount * 10
            return p + (dir * dist + SIMD3(0, 0.6, 0) * dist) * e
        default:
            return p
        }
    }
}

/// Must match `SplatUniforms` in `LerpSplatPipeline.source`.
struct LerpSplatUniforms {
    var view: simd_float4x4
    var focal: SIMD2<Float>
    var viewport: SIMD2<Float>
    var principal: SIMD2<Float>
    var deform: LerpSplatDeform
}

/// Must match `SplatShade` in `LerpSplatPipeline.source`.
struct LerpSplatShade {
    var eye: SIMD4<Float>             // camera position, normalised capture space
    var r0: SIMD4<Float>, r1: SIMD4<Float>, r2: SIMD4<Float>  // rows of the capture's rotation
    var coeffs: UInt32                // SH coefficients per channel past band 0: 0, 3, 8 or 15
    var count: UInt32                 // visible splats
    var pad0: UInt32 = 0, pad1: UInt32 = 0
}

// MARK: - Assets

/// A decoded capture, GPU-resident.
final class LerpSplatAsset {
    let count: Int
    let positions: MTLBuffer    // float4: xyz, opacity
    let covariances: MTLBuffer  // 2 × float4 a splat: xx xy xz yy, yz zz 0 0
    let colors: MTLBuffer       // uchar4: sRGB-encoded rgb (SH band 0), opacity
    /// View-dependent colour: per splat a palette entry (`shLabels`, uint),
    /// per entry `shCoeffs` × 3 codebook indices (`shPalette`, uchar,
    /// coefficient-major), and the 256-float codebook. With no SH,
    /// `shCoeffs` is 0 and the buffers are placeholders.
    let shCoeffs: Int
    let shLabels: MTLBuffer
    let shPalette: MTLBuffer
    let shCodebook: MTLBuffer
    /// Rows of the rotation that took the capture into its normalised frame;
    /// its transpose takes a view direction back to where the SH live.
    let shRotation: [SIMD3<Float>]

    init(count: Int, positions: MTLBuffer, covariances: MTLBuffer, colors: MTLBuffer,
         shCoeffs: Int, shLabels: MTLBuffer, shPalette: MTLBuffer, shCodebook: MTLBuffer,
         shRotation: [SIMD3<Float>]) {
        self.count = count
        self.positions = positions
        self.covariances = covariances
        self.colors = colors
        self.shCoeffs = shCoeffs
        self.shLabels = shLabels
        self.shPalette = shPalette
        self.shCodebook = shCodebook
        self.shRotation = shRotation
    }

    static func load(_ url: URL, device: MTLDevice) throws -> LerpSplatAsset {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 48, data.prefix(4) == Data("LSPL".utf8) else {
            throw LerpSplatError.format("\(url.lastPathComponent) is not an .lsplat file")
        }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func f32(_ o: Int) -> Float { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Float.self) } }
        let version = u32(4)
        guard version == 1 || version == 2 else { throw LerpSplatError.format("unknown .lsplat version \(version)") }
        let n = Int(u32(8))
        let lo = SIMD3(f32(16), f32(20), f32(24)), hi = SIMD3(f32(28), f32(32), f32(36))
        let payloadSize = Int(u32(40))
        // Version 2 carries view-dependent colour; its header grows by
        // rotation (9 floats, row-major), coefficient count, palette size and
        // the 256-float codebook.
        let extra = version == 2 ? Int(u32(44)) : 0
        var shCoeffs = 0, paletteCount = 0
        var rotation = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        var codebook = [Float](repeating: 0, count: 256)
        if version == 2 {
            guard extra >= 44 + 1024, data.count >= 48 + extra else { throw LerpSplatError.format("truncated header") }
            rotation = (0..<3).map { r in SIMD3(f32(48 + 12 * r), f32(52 + 12 * r), f32(56 + 12 * r)) }
            shCoeffs = Int(u32(84))
            paletteCount = Int(u32(88))
            for k in 0..<256 { codebook[k] = f32(92 + 4 * k) }
        }
        let start = 48 + extra
        guard data.count >= start + payloadSize else { throw LerpSplatError.format("truncated") }
        let planes = try (data.subdata(in: start..<(start + payloadSize)) as NSData).decompressed(using: .zlib) as Data
        let expected = n * (6 + 4 + 3 + 4) + (shCoeffs > 0 ? n * 3 + paletteCount * shCoeffs * 3 : 0)
        guard planes.count == expected else {
            throw LerpSplatError.format("payload is \(planes.count) bytes, expected \(expected)")
        }
        guard let posBuf = device.makeBuffer(length: max(16, n * 16), options: .storageModeShared),
              let covBuf = device.makeBuffer(length: max(32, n * 32), options: .storageModeShared),
              let colBuf = device.makeBuffer(length: max(4, n * 4), options: .storageModeShared) else {
            throw LerpSplatError.format("out of GPU memory for \(n) splats")
        }
        posBuf.label = "splat.positions"; covBuf.label = "splat.cov"; colBuf.label = "splat.colors"
        let pos = posBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let cov = covBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n * 2)
        let col = colBuf.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: n)
        let span = (hi - lo) / 65535
        let logMin: Float = -10, logStep: Float = 12 / 255

        planes.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self).baseAddress!
            let qx = UnsafeRawPointer(b), qy = qx + 2 * n, qz = qy + 2 * n
            let cr = b + 6 * n, cg = cr + n, cbl = cg + n, ca = cbl + n
            let sx = ca + n, sy = sx + n, sz = sy + n
            let rw = sz + n, rx = rw + n, ry = rx + n, rz = ry + n
            DispatchQueue.concurrentPerform(iterations: 8) { c in
                for i in (n * c / 8)..<(n * (c + 1) / 8) {
                    let p = SIMD3(Float(qx.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)),
                                  Float(qy.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)),
                                  Float(qz.loadUnaligned(fromByteOffset: 2 * i, as: UInt16.self)))
                    let world = lo + p * span
                    let alpha = Float(ca[i]) / 255
                    pos[i] = SIMD4(world, alpha)
                    col[i] = SIMD4(cr[i], cg[i], cbl[i], ca[i])
                    let s = SIMD3(exp(logMin + Float(sx[i]) * logStep),
                                  exp(logMin + Float(sy[i]) * logStep),
                                  exp(logMin + Float(sz[i]) * logStep))
                    var q = simd_quatf(ix: Float(rx[i]) / 127.5 - 1, iy: Float(ry[i]) / 127.5 - 1,
                                       iz: Float(rz[i]) / 127.5 - 1, r: Float(rw[i]) / 127.5 - 1)
                    q = q.length > 1e-6 ? q.normalized : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                    let r = simd_float3x3(q)
                    let m = r * simd_float3x3(diagonal: s)
                    let sigma = m * m.transpose
                    cov[2 * i] = SIMD4(sigma[0][0], sigma[0][1], sigma[0][2], sigma[1][1])
                    cov[2 * i + 1] = SIMD4(sigma[1][2], sigma[2][2], 0, 0)
                }
            }
        }
        let labelBuf = device.makeBuffer(length: max(4, shCoeffs > 0 ? n * 4 : 4), options: .storageModeShared)
        let paletteBuf = device.makeBuffer(length: max(4, paletteCount * shCoeffs * 3), options: .storageModeShared)
        let bookBuf = device.makeBuffer(bytes: codebook, length: 256 * 4, options: .storageModeShared)
        guard let labelBuf, let paletteBuf, let bookBuf else {
            throw LerpSplatError.format("out of GPU memory for \(n) splats' colour")
        }
        labelBuf.label = "splat.shLabels"; paletteBuf.label = "splat.shPalette"; bookBuf.label = "splat.shCodebook"
        if shCoeffs > 0 {
            planes.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self).baseAddress! + 17 * n
                let l0 = b, l1 = b + n, l2 = b + 2 * n
                let labels = labelBuf.contents().bindMemory(to: UInt32.self, capacity: n)
                for i in 0..<n {
                    labels[i] = UInt32(l0[i]) | UInt32(l1[i]) << 8 | UInt32(l2[i]) << 16
                }
                paletteBuf.contents().copyMemory(from: b + 3 * n, byteCount: paletteCount * shCoeffs * 3)
            }
        }
        return LerpSplatAsset(count: n, positions: posBuf, covariances: covBuf, colors: colBuf,
                              shCoeffs: shCoeffs, shLabels: labelBuf, shPalette: paletteBuf,
                              shCodebook: bookBuf, shRotation: rotation)
    }
}

enum LerpSplatError: Error, CustomStringConvertible {
    case format(String)
    var description: String { if case .format(let s) = self { return s }; return "" }
}

/// Where captures are found, and the decoded ones kept. The installed saver
/// reads `Resources/Splats` in its bundle; a development host also reads
/// `build/splats` beside whichever `Sources/Shaders` it was pointed at.
public enum LerpSplatAssets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var extraDirectories: [URL] = []
    nonisolated(unsafe) private static var cache: [String: LerpSplatAsset] = [:]
    nonisolated(unsafe) private static var recent: [String] = []
    nonisolated(unsafe) private static var loading: [String: NSCondition] = [:]
    nonisolated(unsafe) private static var failed: Set<String> = []
    private static let keep = 2

    /// Called by `ShaderLibrary` with its source-tree search URLs.
    static func addSourceRoots(_ shaderDirectories: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for dir in shaderDirectories {
            let splats = dir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/splats").standardizedFileURL
            if !extraDirectories.contains(splats) { extraDirectories.append(splats) }
        }
    }

    static func url(for name: String) -> URL? {
        lock.lock()
        var dirs = extraDirectories
        lock.unlock()
        if let repo = ShaderLocations.repoShaderDirectory() {
            dirs.append(repo.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/splats"))
        }
        dirs = LerpBundleResources.directories(named: "Splats") + dirs
        return dirs.map { $0.appendingPathComponent(name + ".lsplat") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func prefetch(_ name: String, device: MTLDevice) {
        DispatchQueue.global(qos: .userInitiated).async { _ = asset(name, device: device) }
    }

    /// The decoded capture, loading it on this thread if no other thread is
    /// already doing so (then waiting for that one). nil if it is missing or
    /// unreadable; that is logged once and not retried.
    static func asset(_ name: String, device: MTLDevice) -> LerpSplatAsset? {
        lock.lock()
        while true {
            if let a = cache[name] {
                recent.removeAll { $0 == name }; recent.append(name)
                lock.unlock(); return a
            }
            if failed.contains(name) { lock.unlock(); return nil }
            if let cond = loading[name] {
                lock.unlock()
                cond.lock(); cond.wait(until: Date().addingTimeInterval(0.05)); cond.unlock()
                lock.lock()
                continue
            }
            break
        }
        let cond = NSCondition()
        loading[name] = cond
        lock.unlock()

        var loaded: LerpSplatAsset?
        if let url = url(for: name) {
            do { loaded = try LerpSplatAsset.load(url, device: device) }
            catch { NSLog("Lerping: splat capture %@ failed to load: %@", name, "\(error)") }
        } else {
            NSLog("Lerping: splat capture %@.lsplat not found (run `make splats`)", name)
        }

        lock.lock()
        loading[name] = nil
        if let loaded {
            cache[name] = loaded
            recent.removeAll { $0 == name }; recent.append(name)
            while recent.count > keep { cache[recent.removeFirst()] = nil }
        } else {
            failed.insert(name)
        }
        lock.unlock()
        cond.lock(); cond.broadcast(); cond.unlock()
        return loaded
    }
}

// MARK: - Pipeline

enum LerpSplatPipeline {
    private static let lock = NSLock()
    struct Pipelines {
        let render: MTLRenderPipelineState
        let shade: MTLComputePipelineState
    }
    nonisolated(unsafe) private static var pipelines: [UInt64: Pipelines] = [:]

    static func shared(for device: MTLDevice) -> Pipelines? {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[device.registryID] { return p }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.label = "splat"
            d.vertexFunction = library.makeFunction(name: "splatVertex")
            d.fragmentFunction = library.makeFunction(name: "splatFragment")
            let c = d.colorAttachments[0]!
            c.pixelFormat = .rgba16Float
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            guard let shadeFn = library.makeFunction(name: "splatShade") else { return nil }
            let p = Pipelines(render: try device.makeRenderPipelineState(descriptor: d),
                              shade: try device.makeComputePipelineState(function: shadeFn))
            pipelines[device.registryID] = p
            return p
        } catch {
            NSLog("Lerping: splat pipeline failed: %@", "\(error)")
            return nil
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct SplatDeform {
        uint mode; float time; float amount; float frequency;
        float phase; float pad0, pad1, pad2;
    };
    struct SplatUniforms {
        float4x4 view;
        float2 focal;
        float2 viewport;
        float2 principal;   // image-centre offset, pixels, y up (a tracked viewer)
        SplatDeform deform;
    };
    struct SplatOut {
        float4 position [[position]];
        float2 uv;
        half4 color;
    };

    static inline uint splatHash(uint x) {
        uint v = x * 747796405u + 2891336453u;
        v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
        return (v >> 22u) ^ v;
    }
    static inline float splatUnit(uint x) { return float(splatHash(x) >> 8) / float(1u << 24); }

    static inline float splatScatter(float phase, float height) {
        float w;
        if (phase < 0.45) w = 0.0;
        else if (phase < 0.65) w = (phase - 0.45) / 0.20;
        else if (phase < 0.72) w = 1.0;
        else w = 1.0 - (phase - 0.72) / 0.28;
        float front = w * 1.6 - 0.3;
        float x = saturate((front - height) / 0.3);
        return x * x * (3.0 - 2.0 * x);
    }

    // Displacement; the CPU sort repeats modes 3 and 4 (LerpSplatDeform.apply).
    static inline float3 splatDeform(float3 p, uint i, constant SplatDeform& D, thread float& fade) {
        fade = 1.0;
        if (D.mode == 1u) {
            // Rings across the ground. Captures are normalised so the subject
            // stands on y = -1; only what lies near that plane moves.
            float r = length(p.xz);
            float wave = sin(D.frequency * r * 3.0 - D.time * 2.2);
            float ground = saturate(1.0 - (p.y + 1.0) / 0.35);
            p.y += D.amount * wave * ground * exp(-r * 0.35);
        } else if (D.mode == 2u) {
            float wave = sin(D.frequency * p.x - D.time * 1.6) * cos(D.frequency * 0.6 * p.y + D.time * 0.9);
            p.z += D.amount * 2.0 * wave;
        } else if (D.mode == 3u) {
            float a = D.amount * 4.0 * p.y * sin(D.time * 0.35);
            float c = cos(a), s = sin(a);
            p = float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
        } else if (D.mode == 4u) {
            float h = saturate((p.y + 1.0) * 0.5);
            float e = splatScatter(D.phase, h);
            if (e > 0.0) {
                float a = splatUnit(i * 3u) * 2.0 * M_PI_F;
                float z = splatUnit(i * 3u + 1u) * 2.0 - 1.0;
                float r = sqrt(max(0.0, 1.0 - z * z));
                float3 dir = float3(r * cos(a), z, r * sin(a));
                float dist = (0.4 + 1.2 * splatUnit(i * 3u + 2u)) * D.amount * 10.0;
                p += (dir * dist + float3(0.0, 0.6, 0.0) * dist) * e;
                fade = 1.0 - 0.6 * e;
            }
        }
        return p;
    }

    struct SplatShade {
        float4 eye;
        float4 r0, r1, r2;   // rows of the capture's rotation
        uint coeffs;         // SH coefficients per channel past band 0
        uint count;
        uint pad0, pad1;
    };

    // Colour of each visible splat for this eye: band 0 (stored, already
    // offset by 0.5) plus bands 1-3 from the palette, the standard 3DGS
    // evaluation. Opacity, with any dissolve fade, rides in .a.
    kernel void splatShade(uint gid [[thread_position_in_grid]],
                           constant SplatUniforms& U [[buffer(0)]],
                           constant SplatShade& H [[buffer(1)]],
                           device const uint* order [[buffer(2)]],
                           device const float4* posOp [[buffer(3)]],
                           device const uchar4* rgba [[buffer(4)]],
                           device const uint* labels [[buffer(5)]],
                           device const uchar* palette [[buffer(6)]],
                           constant float* book [[buffer(7)]],
                           device half4* shaded [[buffer(8)]]) {
        if (gid >= H.count) return;
        uint i = order[gid];
        float fade;
        float3 p = splatDeform(posOp[i].xyz, i, U.deform, fade);
        float4 base = float4(rgba[i]) / 255.0;
        float3 c = base.rgb;
        if (H.coeffs > 0u) {
            float3 d = normalize(p - H.eye.xyz);
            d = H.r0.xyz * d.x + H.r1.xyz * d.y + H.r2.xyz * d.z;
            float x = d.x, y = d.y, z = d.z;
            float xx = x * x, yy = y * y, zz = z * z;
            float b[15] = {
                -0.4886025119029199 * y, 0.4886025119029199 * z, -0.4886025119029199 * x,
                1.0925484305920792 * x * y, -1.0925484305920792 * y * z,
                0.31539156525252005 * (2.0 * zz - xx - yy),
                -1.0925484305920792 * x * z, 0.5462742152960396 * (xx - yy),
                -0.5900435899266435 * y * (3.0 * xx - yy), 2.890611442640554 * x * y * z,
                -0.4570457994644658 * y * (4.0 * zz - xx - yy),
                0.3731763325901154 * z * (2.0 * zz - 3.0 * xx - 3.0 * yy),
                -0.4570457994644658 * x * (4.0 * zz - xx - yy),
                1.445305721320277 * z * (xx - yy), -0.5900435899266435 * x * (xx - 3.0 * yy)
            };
            device const uchar* e = palette + labels[i] * H.coeffs * 3u;
            for (uint j = 0u; j < H.coeffs; j++) {
                c += b[j] * float3(book[e[3u * j]], book[e[3u * j + 1u]], book[e[3u * j + 2u]]);
            }
        }
        shaded[i] = half4(half3(max(c, 0.0)), half(base.a * fade));
    }

    vertex SplatOut splatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                constant SplatUniforms& U [[buffer(0)]],
                                device const uint* order [[buffer(1)]],
                                device const float4* posOp [[buffer(2)]],
                                device const float4* cov [[buffer(3)]],
                                device const half4* shaded [[buffer(4)]]) {
        SplatOut o;
        o.position = float4(0.0, 0.0, 2.0, 1.0);   // clipped
        o.uv = float2(0.0);
        o.color = half4(0.0h);
        uint i = order[iid];
        float fade;
        float3 p = splatDeform(posOp[i].xyz, i, U.deform, fade);
        float4 v = U.view * float4(p, 1.0);
        float z = -v.z;
        if (z < 0.02) return o;

        float4 c0 = cov[2u * i], c1 = cov[2u * i + 1u];
        float3x3 S = float3x3(float3(c0.x, c0.y, c0.z),
                              float3(c0.y, c0.w, c1.x),
                              float3(c0.z, c1.x, c1.y));
        float fx = U.focal.x, fy = U.focal.y;
        float3x3 J = float3x3(float3(fx / z, 0.0, 0.0),
                              float3(0.0, fy / z, 0.0),
                              float3(fx * v.x / (z * z), fy * v.y / (z * z), 0.0));
        float3x3 W = float3x3(U.view[0].xyz, U.view[1].xyz, U.view[2].xyz);
        float3x3 T = J * W;
        float3x3 C = T * S * transpose(T);
        float a = C[0][0] + 0.3, b = C[0][1], d = C[1][1] + 0.3;

        float mid = 0.5 * (a + d);
        float rad = length(float2(0.5 * (a - d), b));
        float l1 = mid + rad, l2 = max(mid - rad, 0.1);
        float2 axis = abs(b) > 1e-7 ? normalize(float2(b, l1 - a))
                                    : (a >= d ? float2(1.0, 0.0) : float2(0.0, 1.0));
        float2 major = min(sqrt(2.0 * l1), 2048.0) * axis;
        float2 minor = min(sqrt(2.0 * l2), 2048.0) * float2(axis.y, -axis.x);

        float2 corner = float2((vid & 1u) ? 1.0 : -1.0, (vid & 2u) ? 1.0 : -1.0) * 2.0;
        float2 centre = float2(fx * v.x / z, fy * v.y / z) + U.principal;
        float2 px = centre + corner.x * major + corner.y * minor;
        o.position = float4(px / (0.5 * U.viewport), 0.0, 1.0);
        o.uv = corner;
        o.color = shaded[i];
        (void)fade;
        return o;
    }

    fragment half4 splatFragment(SplatOut in [[stage_in]]) {
        float r2 = dot(in.uv, in.uv);
        if (r2 > 4.0) discard_fragment();
        float alpha = exp(-r2) * float(in.color.a);
        if (alpha < 1.0 / 255.0) discard_fragment();
        alpha = min(alpha, 0.99);
        return half4(in.color.rgb * half(alpha), half(alpha));
    }
    """
}
