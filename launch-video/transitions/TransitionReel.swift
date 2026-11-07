import Foundation
import Metal

/// TransitionReel — renders a run of shots, each look drawn live from its
/// shader, with a transition (Transitions.metal) into every shot after the
/// first, and pipes the frames to ffmpeg as H.264.
///
///   TransitionReel SPEC.json OUT.mp4
///
/// SPEC: {"bpm": 133, "shots": [{"look": "gem-smoke--Fire", "beats": 4, "in": "burn"}, ...]}
/// `look` is the footage slug (shader--Preset). A shot's shader time is
/// 6 + start/60 + (frame - shotStart) * rate / 60, the same clock the montage's
/// footage plays (recorded from t = 6, played at `rate`, default 1.5), so a
/// transition's frames match the clips around it. Cuts are on rounded frames,
/// like timing.ts's beat().
///
/// Run from the repo root, so the shaders are found under Sources/Shaders.
@main
enum TransitionReel {
    struct Shot: Decodable {
        let look: String
        let beats: Double
        let rate: Double?
        let start: Double?
        let `in`: String?
        let pre: Double?
        let post: Double?
    }
    struct Spec: Decodable { let bpm: Double; let shots: [Shot] }

    /// Kind index (matches Transitions.metal) and its window around the cut, in beats.
    static let kinds: [String: (kind: Int32, pre: Double, post: Double)] = [
        "cut": (0, 0, 0.6),
        "burn": (1, 0.75, 0.25),
        "pour": (2, 0.6, 0.4),
        "ripple": (3, 0.5, 0.5),
        "melt": (4, 1.0, 0.25),
        "halftone": (5, 0.5, 0.5),
        "zoom": (6, 0.25, 0.25),
    ]

    static func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 2 else { fail("usage: TransitionReel SPEC.json OUT.mp4") }
        let spec = try! JSONDecoder().decode(Spec.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let outPath = args[2]
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let (W, H, fps) = (1920, 1080, 60.0)
        let spb = 60.0 / spec.bpm
        func beat(_ n: Double) -> Int { Int((n * spb * fps).rounded()) }

        guard let renderer = LerpRenderer() else { fail("no Metal device") }
        let device = renderer.device
        let library = ShaderLibrary(device: device, extraSearchURLs: ShaderLocations.repoSearchURLs())
        let jobs = RotationThumbnails.jobs(for: library.discover())
        func slug(_ key: String) -> String { key.replacingOccurrences(of: "/", with: "--").replacingOccurrences(of: " ", with: "_") }

        struct Live { let pipeline: MTLRenderPipelineState; let data: LerpDataProvider?; let params: LerpParameterValues }
        let live: [Live] = spec.shots.map { shot in
            guard let job = jobs.first(where: { slug($0.entry.key) == shot.look }) else { fail("no look \(shot.look)") }
            return Live(pipeline: try! library.pipeline(for: job.shader), data: try! library.dataProvider(for: job.shader),
                        params: job.shader.parameterValues(for: job.entry))
        }

        let source = try! String(contentsOfFile: "\(here)/Transitions.metal", encoding: .utf8)
        let kernel = try! device.makeComputePipelineState(
            function: try! device.makeLibrary(source: source, options: nil).makeFunction(name: "transition")!)

        func tex(_ f: MTLPixelFormat, _ u: MTLTextureUsage, shared: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: W, height: H, mipmapped: false)
            d.usage = u
            d.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: d)!
        }
        let texA = tex(.bgra8Unorm, [.renderTarget, .shaderRead])
        let texB = tex(.bgra8Unorm, [.renderTarget, .shaderRead])
        let out = tex(.rgba8Unorm, [.shaderWrite], shared: true)
        var bytes = [UInt8](repeating: 0, count: W * H * 4)

        // Shot i starts on frame starts[i]; the reel ends on starts.last.
        var starts = [0]
        var cursor = 0.0
        for shot in spec.shots { cursor += shot.beats; starts.append(beat(cursor)) }
        let total = starts.last!

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = ["-y", "-loglevel", "error",
                            "-f", "rawvideo", "-pix_fmt", "rgba", "-s", "\(W)x\(H)", "-r", "60", "-i", "-",
                            "-c:v", "libx264", "-preset", "medium", "-crf", "14", "-x264-params", "aq-mode=3",
                            "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                            "-movflags", "+faststart", outPath]
        let pipe = Pipe()
        ffmpeg.standardInput = pipe
        try! ffmpeg.run()

        func draw(_ i: Int, at frame: Int, into target: MTLTexture) {
            let shot = spec.shots[i]
            let t = 6 + (shot.start ?? 0) / fps + Double(frame - starts[i]) * (shot.rate ?? 1.5) / fps
            let u = LerpUniforms(resolution: SIMD2(Float(W), Float(H)), time: Float(t), seed: 0.37)
            let l = live[i]
            renderer.encodePass(target: target, pipeline: l.pipeline, uniforms: u, params: l.params, data: l.data)!.commit()
        }

        let began = CFAbsoluteTimeGetCurrent()
        for f in 0..<total {
            let current = starts.lastIndex(where: { $0 <= f })!
            // A transition into shot i covers [cut - pre, cut + post).
            var kind: Int32 = 7, p = 0.0, a = current, b = current
            for i in 1..<spec.shots.count {
                let name = spec.shots[i].in ?? "cut"
                guard let k = kinds[name] else { fail("unknown transition \(name)") }
                let lo = starts[i] - beat(spec.shots[i].pre ?? k.pre)
                let hi = starts[i] + beat(spec.shots[i].post ?? k.post)
                if f >= lo && f < hi {
                    (kind, p, a, b) = (k.kind, Double(f - lo) / Double(hi - lo), i - 1, i)
                    break
                }
            }
            draw(a, at: f, into: texA)
            if kind != 7 { draw(b, at: f, into: texB) }

            let cb = renderer.commandQueue.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(kernel)
            enc.setTexture(texA, index: 0)
            enc.setTexture(kind == 7 ? texA : texB, index: 1)
            enc.setTexture(out, index: 2)
            var params = (SIMD2<Float>(Float(W), Float(H)), Float(p), Float(Double(f) / fps), kind, Float(b) * 0.618, SIMD2<Float>(0, 0))
            enc.setBytes(&params, length: MemoryLayout.size(ofValue: params), index: 0)
            enc.dispatchThreads(MTLSize(width: W, height: H, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            bytes.withUnsafeMutableBytes {
                out.getBytes($0.baseAddress!, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
            }
            pipe.fileHandleForWriting.write(Data(bytes))
        }
        try? pipe.fileHandleForWriting.close()
        ffmpeg.waitUntilExit()
        print(String(format: "-> %@  %d frames  %.1fs", outPath, total, CFAbsoluteTimeGetCurrent() - began))
    }
}
