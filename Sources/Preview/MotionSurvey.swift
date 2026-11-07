import Foundation
import Metal

/// `LerpPreview --motion`: how fast each look moves on screen, so a look that
/// reads as a still picture can be found by number instead of by someone
/// noticing it on the lock screen.
///
/// Speed is estimated per pair of frames `dt` apart as
///
///     mean |L(t + dt) − L(t)|  /  mean |∇L|  ·  π/2  /  dt
///
/// For a picture sliding by v pixels, |ΔL| ≈ |∇L|·|v|·|cos θ|, and |cos θ|
/// averages 2/π over directions, so this is the slide in pixels per second.
/// For anything else (morphing, fading, flicker) it is the slide that would
/// change the picture as much: an equivalent speed. It is reported as a
/// percentage of the short side per second so it does not depend on `--size`.
///
/// A rigid, slow camera drift scores what it is: slow. That is deliberate.
/// `reaction-diffusion/Worms` changed 25% of its pixels every two seconds
/// through its drift and still read on the lock screen as "completely still".
enum MotionSurvey {

    static func run(args: [String], extraSearch: [URL]) {
        let (renderer, library) = PreviewMain.makeLibrary(extraSearch)
        let (width, height) = PreviewMain.size(args, default: (676, 439))
        let dt = Float(PreviewMain.flagValue(args, "--dt") ?? "") ?? 0.25
        let seed = Float(PreviewMain.flagValue(args, "--seed") ?? "") ?? 0.37
        let times = (PreviewMain.flagValue(args, "--times") ?? "8,45,120,240")
            .split(separator: ",").compactMap { Float($0) }
        let only = PreviewMain.flagValue(args, "--shader")

        var shaders = library.discover()
        if let only { shaders = shaders.filter { $0.name == only } }
        guard !shaders.isEmpty else { PreviewMain.fail("no shaders found") }
        let looks = RotationThumbnails.jobs(for: shaders)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
            PreviewMain.fail("could not allocate a \(width)x\(height) target")
        }
        let shortSide = Float(min(width, height))

        func luma(_ pipeline: MTLRenderPipelineState, _ data: LerpDataProvider?,
                  _ params: LerpParameterValues, _ time: Float) -> [Float]? {
            let uniforms = LerpUniforms(resolution: SIMD2<Float>(Float(width), Float(height)),
                                        time: time, seed: seed)
            guard let buffer = renderer.encodePass(target: target, pipeline: pipeline,
                                                   uniforms: uniforms, params: params, data: data)
            else { return nil }
            buffer.commit()
            buffer.waitUntilCompleted()
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            var out = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                out[i] = 0.114 * Float(bytes[4 * i]) + 0.587 * Float(bytes[4 * i + 1])
                    + 0.299 * Float(bytes[4 * i + 2])
            }
            return blurred(out)
        }

        /// Two box passes each way, about a 0.6% of the short side Gaussian.
        /// Film grain, dither and halftone dots are all edge and no motion: left
        /// in, they swamp the gradient term and a look sweeping its whole
        /// picture through a halftone screen measured as still. What the eye
        /// follows is the picture under the screen.
        func blurred(_ image: [Float]) -> [Float] {
            let r = max(1, Int((0.006 * shortSide).rounded()))
            var a = image, b = image
            for _ in 0..<2 {
                for y in 0..<height {
                    var sum: Float = 0
                    for x in -r...r { sum += a[y * width + min(width - 1, max(0, x))] }
                    for x in 0..<width {
                        b[y * width + x] = sum / Float(2 * r + 1)
                        sum += a[y * width + min(width - 1, x + r + 1)] - a[y * width + max(0, x - r)]
                    }
                }
                for x in 0..<width {
                    var sum: Float = 0
                    for y in -r...r { sum += b[min(height - 1, max(0, y)) * width + x] }
                    for y in 0..<height {
                        a[y * width + x] = sum / Float(2 * r + 1)
                        sum += b[min(height - 1, y + r + 1) * width + x] - b[max(0, y - r) * width + x]
                    }
                }
            }
            return a
        }

        /// Speeds in % of the short side per second: (total, global drift,
        /// local change once that drift is taken out).
        ///
        /// The drift is one whole-image Lucas–Kanade fit: the shift v that
        /// best explains ΔL ≈ −∇L·v. What it cannot explain — shapes growing,
        /// turning, parting, a camera's parallax — is the local change. A
        /// still picture panned across the screen is all drift and no local
        /// change, and with no relative motion to compare against, the eye
        /// barely sees a slow drift at all.
        func speed(_ a: [Float], _ b: [Float]) -> (total: Float, drift: Float, local: Float) {
            let count = (width - 2) * (height - 2)
            var gxs = [Float](repeating: 0, count: count), gys = gxs, dts = gxs
            var sxx: Float = 0, sxy: Float = 0, syy: Float = 0, sxt: Float = 0, syt: Float = 0
            var diff: Float = 0, grad: Float = 0
            var k = 0
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    let gx = 0.25 * (a[i + 1] - a[i - 1] + b[i + 1] - b[i - 1])
                    let gy = 0.25 * (a[i + width] - a[i - width] + b[i + width] - b[i - width])
                    let d = b[i] - a[i]
                    gxs[k] = gx; gys[k] = gy; dts[k] = d; k += 1
                    sxx += gx * gx; sxy += gx * gy; syy += gy * gy
                    sxt += gx * d; syt += gy * d
                    diff += abs(d)
                    grad += (gx * gx + gy * gy).squareRoot()
                }
            }
            guard grad > 0 else { return (0, 0, 0) }
            let det = sxx * syy - sxy * sxy
            var vx: Float = 0, vy: Float = 0
            if det > 1e-6 * (sxx + syy) * (sxx + syy) {
                vx = -(syy * sxt - sxy * syt) / det
                vy = -(sxx * syt - sxy * sxt) / det
            }
            var residual: Float = 0
            for k in 0..<count { residual += abs(dts[k] + gxs[k] * vx + gys[k] * vy) }
            let scale = 100 / dt / shortSide
            return ((diff / grad) * (.pi / 2) * scale,
                    (vx * vx + vy * vy).squareRoot() * scale,
                    min(diff, residual) / grad * (.pi / 2) * scale)
        }

        var rows: [(key: String, total: [Float], drift: [Float], local: [Float])] = []
        for look in looks {
            let pipeline: MTLRenderPipelineState
            let data: LerpDataProvider?
            do {
                pipeline = try library.pipeline(for: look.shader)
                data = try library.dataProvider(for: look.shader)
            } catch {
                print("FAIL  \(look.entry.key): \(error)")
                continue
            }
            let params = look.shader.parameterValues(for: look.entry)
            var total: [Float] = [], drift: [Float] = [], local: [Float] = []
            for t in times {
                guard let a = luma(pipeline, data, params, t),
                      let b = luma(pipeline, data, params, t + dt) else { continue }
                let s = speed(a, b)
                total.append(s.total); drift.append(s.drift); local.append(s.local)
            }
            rows.append((look.entry.key, total, drift, local))
            FileHandle.standardError.write(".".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\n".data(using: .utf8)!)

        print("Motion at \(width)x\(height), dt=\(dt)s, seed=\(seed), times \(times.map { String(format: "%g", $0) }.joined(separator: ",")).")
        print("Speeds in % of the short side per second, median over the times: total, global")
        print("drift, and local change with the drift taken out. Least local change first.\n")
        func median(_ v: [Float]) -> Float { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        func pad(_ s: String) -> String { s.padding(toLength: max(44, s.count), withPad: " ", startingAt: 0) }
        print(pad("look") + "    total    drift    local   local per time")
        for row in rows.sorted(by: { median($0.local) < median($1.local) }) {
            print(pad(row.key) + String(format: " %8.2f %8.2f %8.2f   %@",
                         median(row.total), median(row.drift), median(row.local),
                         row.local.map { String(format: "%.2f", $0) }.joined(separator: " ") as NSString))
        }
    }
}
