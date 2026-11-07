import Foundation
import Metal
import CoreGraphics
import ImageIO
import CryptoKit

/// LerpRecord — renders every rotation look to an H.264 clip, frame-exact,
/// through the same LerpRenderer path the saver draws with.
///
///   LerpRecord OUTDIR [--size WxH] [--fps N] [--start T] [--seconds S]
///                     [--speed X] [--seed S] [--only shader[/preset]] [--shard i/n]
///                     [--param name=number|#RRGGBBAA ...] [--name OUTPUT-STEM]
///                     [--shaders DIR] [--wordmark PROCESSED.png] [--list]
///                     [--store DIR --salt-pure S --salt-data S [--label L]]
///
/// `--only` may repeat. `--list` prints every look key and exits.
///
/// With `--store`, clips are content-addressed: STORE/<look>/<key>.mp4, where
/// the key hashes everything that decides the pixels — the exact Metal source
/// the library compiles (prelude + shader), the look's parameter values and
/// drifts, the render settings, and a salt for the Swift that runs the frame
/// (`--salt-pure` for plain shaders, `--salt-data` for ones with a data
/// provider, whose CPU/compute code is engine code). OUTDIR/<look>.mp4 is a
/// hard link to the current key. A look whose key is already stored is linked,
/// not rendered; a replaced clip that was never in the store is kept as
/// STORE/<look>/legacy-<date>.mp4. STORE/<look>/history.tsv logs each render.
///
/// A frame is a pure function of (shader, time, seed, params) — see the purity
/// contract in DataProvider.swift — so frame k is rendered at
/// `start + k * speed / fps` with no warm-up and no wall clock.
@main
enum RecordMain {
    static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), args.count > i + 1 else { return nil }
        return args[i + 1]
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1, !args[1].hasPrefix("--") else { fail("usage: LerpRecord OUTDIR [flags]") }
        let outDir = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let size = (flag(args, "--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let (width, height) = (size[0], size[1])
        let fps = Int(flag(args, "--fps") ?? "60")!
        let start = Float(flag(args, "--start") ?? "6")!
        let seconds = Float(flag(args, "--seconds") ?? "6")!
        let speed = Float(flag(args, "--speed") ?? "1")!
        let seed = Float(flag(args, "--seed") ?? "0.37")!
        let shard = (flag(args, "--shard") ?? "0/1").split(separator: "/").compactMap { Int($0) }
        let store = flag(args, "--store").map { URL(fileURLWithPath: $0) }
        if store != nil, flag(args, "--salt-pure") == nil || flag(args, "--salt-data") == nil {
            fail("--store needs --salt-pure and --salt-data")
        }
        let onlies = args.indices.filter { args[$0] == "--only" && $0 + 1 < args.count }.map { args[$0 + 1] }
        let overrides = args.indices.filter { args[$0] == "--param" && $0 + 1 < args.count }.map { args[$0 + 1] }

        guard let renderer = LerpRenderer() else { fail("no Metal device") }
        WordmarkData.path = flag(args, "--wordmark") ?? ""
        LerpDataProviders.register("wordmark") { device, _ in WordmarkData(device: device) }
        let extra = (flag(args, "--shaders").map { [URL(fileURLWithPath: $0)] } ?? []) + ShaderLocations.repoSearchURLs()
        let library = ShaderLibrary(device: renderer.device, extraSearchURLs: extra)
        let shaders = library.discover()
        var jobs = RotationThumbnails.jobs(for: shaders)
        if args.contains("--list") {
            for job in jobs { print(job.entry.key) }
            return
        }
        if !onlies.isEmpty {
            let slugOf = { (key: String) in key.replacingOccurrences(of: "/", with: "--").replacingOccurrences(of: " ", with: "_") }
            for only in onlies where !jobs.contains(where: { $0.entry.key == only || $0.entry.shader == only || slugOf($0.entry.key) == only }) {
                print("MISS  \(only): no such look")
            }
            // An exact look (key or slug) means just that look; a bare shader name
            // that is no look's key means every preset of it.
            let exact = { (job: RotationThumbnails.Job, only: String) in job.entry.key == only || slugOf(job.entry.key) == only }
            jobs = jobs.filter { job in onlies.contains { only in
                exact(job, only) || (job.entry.shader == only && !jobs.contains { exact($0, only) }) } }
        }
        jobs = jobs.enumerated().filter { $0.offset % shard[1] == shard[0] }.map(\.element)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { fail("no texture") }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let frames = Int(seconds * Float(fps))

        for job in jobs {
            let slug = (flag(args, "--name") ?? job.entry.key).replacingOccurrences(of: "/", with: "--").replacingOccurrences(of: " ", with: "_")
            let url = outDir.appendingPathComponent(slug + ".mp4")
            if store == nil, FileManager.default.fileExists(atPath: url.path) { print("SKIP  \(job.entry.key)"); continue }
            let pipeline: MTLRenderPipelineState
            let data: LerpDataProvider?
            do {
                pipeline = try library.pipeline(for: job.shader)
                data = try library.dataProvider(for: job.shader)
            } catch { print("FAIL  \(job.entry.key): \(error)"); continue }
            var params = job.shader.parameterValues(for: job.entry)
            for arg in overrides {
                let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                if let number = Double(kv[1]) {
                    params.set(kv[0], to: number)
                } else if case .color(let color)? = try? LerpParamParser.parseColor(kv[1], line: 0, text: arg) {
                    params.set(kv[0], .color(color))
                }
            }

            // Content-addressed store: link a stored render instead of making it again.
            var stored: URL?
            if let store {
                var hash = SHA256()
                func feed(_ s: String) { hash.update(data: Data((s + "\u{0}").utf8)) }
                feed("lerprecord-store-v1")
                feed("\(width)x\(height) fps=\(fps) start=\(start) seconds=\(seconds) speed=\(speed) seed=\(seed)")
                feed(LerpPrelude.source(parameters: job.shader.parameters, extra: data?.metalPrelude ?? "") + job.shader.source)
                hash.update(data: Data(params.packedTail))
                feed(params.animations.keys.sorted().map { "\($0)=\(String(describing: params.animations[$0]!))" }.joined(separator: ";"))
                feed(params.pinned.sorted().joined(separator: ","))
                feed(overrides.joined(separator: ";"))
                feed(data == nil ? flag(args, "--salt-pure")! : "data:" + flag(args, "--salt-data")!)
                let key = hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
                let dir = store.appendingPathComponent(slug)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let target = dir.appendingPathComponent(key + ".mp4")
                if FileManager.default.fileExists(atPath: target.path) {
                    print(publish(target, at: url) ? "HIT   \(job.entry.key)  \(key)  (relinked)" : "HIT   \(job.entry.key)  \(key)")
                    continue
                }
                stored = target
            }

            let ffmpeg = Process()
            ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            ffmpeg.arguments = ["-y", "-loglevel", "error",
                                "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", "\(fps)", "-i", "-",
                                "-c:v", "libx264", "-preset", "medium", "-crf", "14", "-x264-params", "aq-mode=3",
                                "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                                "-movflags", "+faststart", url.path + ".part.mp4"]
            let pipe = Pipe()
            ffmpeg.standardInput = pipe
            do { try ffmpeg.run() } catch { fail("ffmpeg: \(error)") }

            let began = CFAbsoluteTimeGetCurrent()
            for k in 0..<frames {
                let uniforms = LerpUniforms(resolution: SIMD2(Float(width), Float(height)),
                                            time: start + Float(k) * speed / Float(fps), seed: seed)
                guard let cb = renderer.encodePass(target: texture, pipeline: pipeline, uniforms: uniforms,
                                                   params: params, data: data) else { fail("encode") }
                cb.commit()
                cb.waitUntilCompleted()
                bytes.withUnsafeMutableBytes {
                    texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                     from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                pipe.fileHandleForWriting.write(Data(bytes))
            }
            try? pipe.fileHandleForWriting.close()
            ffmpeg.waitUntilExit()
            guard ffmpeg.terminationStatus == 0 else { print("FAIL  \(job.entry.key): ffmpeg \(ffmpeg.terminationStatus)"); continue }
            if let stored {
                try? FileManager.default.moveItem(atPath: url.path + ".part.mp4", toPath: stored.path)
                _ = publish(stored, at: url)
                let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(stored.deletingPathExtension().lastPathComponent)\t\(flag(args, "--label") ?? "-")\n"
                let log = stored.deletingLastPathComponent().appendingPathComponent("history.tsv")
                if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                else { try? Data(line.utf8).write(to: log) }
            } else {
                try? FileManager.default.moveItem(atPath: url.path + ".part.mp4", toPath: url.path)
            }
            print(String(format: "OK    %@  %.1fs", job.entry.key, CFAbsoluteTimeGetCurrent() - began))
        }
    }
}

/// Points `link` at `stored` (a hard link, so the edit sees an ordinary file).
/// A clip already there that is not in the store is moved into it as a legacy
/// render rather than deleted. Returns whether anything changed.
@discardableResult
func publish(_ stored: URL, at link: URL) -> Bool {
    let fm = FileManager.default
    func attrs(_ u: URL) -> [FileAttributeKey: Any]? { try? fm.attributesOfItem(atPath: u.path) }
    guard let target = attrs(stored) else { return false }
    if let current = attrs(link) {
        if (current[.systemFileNumber] as? Int) == (target[.systemFileNumber] as? Int) { return false }
        if (current[.referenceCount] as? Int ?? 1) <= 1 {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
            let stamp = f.string(from: current[.modificationDate] as? Date ?? Date())
            try? fm.moveItem(at: link, to: stored.deletingLastPathComponent().appendingPathComponent("legacy-\(stamp).mp4"))
        } else {
            try? fm.removeItem(at: link)
        }
    }
    try? fm.linkItem(at: stored, to: link)
    return true
}

/// Binds the Poisson-processed wordmark (recorder/process_wordmark.py: R = edge
/// field, G = opacity) at fragment texture 1, for liquid-metal-wordmark.metal.
/// Static data, so the purity contract holds trivially.
final class WordmarkData: LerpDataProvider {
    static var path = ""
    private let texture: MTLTexture?

    init(device: MTLDevice) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: WordmarkData.path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            RecordMain.fail("cannot read wordmark texture at '\(WordmarkData.path)' (pass --wordmark PNG)")
        }
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        texture = device.makeTexture(descriptor: descriptor)
        texture?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
    }

    var metalPrelude: String {
        """
        // ---- lerp-data: wordmark ---- fragment texture 1: R = edge field, G = opacity
        constexpr sampler lerpWordmarkSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        """
    }

    func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        if let texture { encoder.setFragmentTexture(texture, index: 1) }
    }
}
