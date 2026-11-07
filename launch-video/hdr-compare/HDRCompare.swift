import Foundation
import Metal
import MetalKit

/// HDRCompare — the SDR/HDR side-by-side as a real HDR video.
///
///   HDRCompare OUT.mp4 --looks a,b/Preset,... [--seconds-each 4.5] [--peak 4]
///
/// Run from a checkout root (shaders are found under Sources/Shaders) and
/// build against the LerpCore that has LerpEDR (EDR phase 1, cf7ebd1).
///
/// Each frame renders the look twice at the window's pixel size: once through
/// the plain bgra8Unorm path (what the saver shows today) and once into
/// rgba16Float followed by LerpEDR's own expand pass, the exact code the live
/// --edr window runs, at a fixed `--peak` headroom instead of whatever the
/// screen offered at that moment. Both go into plate.png's windows
/// (build_plate.py) in linear Display P3, then out as HLG BT.2020, SDR white at
/// the BT.2408 reference of 203 nits, so the SDR window and the desktop look
/// like SDR and only the HDR window's highlights go above.
@main
enum HDRCompare {
    static func flag(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), a.count > i + 1 else { return nil }
        return a[i + 1]
    }

    static func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

    static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Rects { int4 sdr; int4 hdr; float4 white; };   // white.x = SDR white in nits

    float3 decode(float3 e) {   // sRGB / Display P3 transfer -> linear
        e = clamp(e, 0.0, 1.0);
        return select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
    }

    float hlgOETF(float e) {
        const float a = 0.17883277, b = 0.28466892, c = 0.55991073;
        return e <= 1.0 / 12.0 ? sqrt(3.0 * e) : a * log(12.0 * e - b) + c;
    }

    kernel void composite(texture2d<float, access::read> plate [[texture(0)]],
                          texture2d<float, access::read> mask [[texture(1)]],
                          texture2d<float, access::read> sdr [[texture(2)]],
                          texture2d<float, access::read> hdr [[texture(3)]],
                          texture2d<float, access::write> out [[texture(4)]],
                          constant Rects& r [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
        float3 lin = decode(plate.read(gid).rgb);
        float m = mask.read(gid).r;
        int2 p = int2(gid);
        if (m > 0.0) {
            if (all(p >= r.sdr.xy) && all(p < r.sdr.xy + r.sdr.zw)) {
                lin = mix(lin, decode(sdr.read(uint2(p - r.sdr.xy)).rgb), m);
            } else if (all(p >= r.hdr.xy) && all(p < r.hdr.xy + r.hdr.zw)) {
                lin = mix(lin, max(hdr.read(uint2(p - r.hdr.xy)).rgb, 0.0), m);
            }
        }
        // Display P3 linear -> BT.2020 linear, as display light on a 1000-nit HLG display.
        const float3x3 p3to2020 = float3x3(float3(0.753833, 0.045744, -0.001210),
                                           float3(0.198597, 0.941777, 0.017601),
                                           float3(0.047570, 0.012479, 0.983609));
        float3 fd = max(p3to2020 * lin, 0.0) * (r.white.x / 1000.0);
        // Inverse HLG OOTF (system gamma 1.2 at 1000 nits), then the OETF.
        float yd = dot(fd, float3(0.2627, 0.6780, 0.0593));
        float3 es = yd > 0.0 ? fd * pow(yd, (1.0 - 1.2) / 1.2) : float3(0.0);
        es = min(es, 1.0);
        out.write(float4(hlgOETF(es.r), hlgOETF(es.g), hlgOETF(es.b), 1.0), gid);
    }
    """

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else { fail("usage: HDRCompare OUT.mp4 --looks a,b/Preset,...") }
        let outPath = args[1]
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        let looks = (flag("--looks") ?? "liquid-metal").split(separator: ",").map(String.init)
        let secondsEach = Double(flag("--seconds-each") ?? "4.5")!
        let peak = Float(flag("--peak") ?? "4")!
        let fps = 60
        // Cut frames are rounded from the running total, so a non-integer
        // --seconds-each (a music bar length) never drifts off the beat.
        func cut(_ i: Int) -> Int { Int((Double(i) * secondsEach * Double(fps)).rounded()) }

        guard let renderer = LerpRenderer() else { fail("no Metal device") }
        let device = renderer.device
        let library = ShaderLibrary(device: device, extraSearchURLs: ShaderLocations.repoSearchURLs())
        let jobs = RotationThumbnails.jobs(for: library.discover())
        let post = try! LerpEDR.makePostPipeline(device: device)
        let kernelLib = try! device.makeLibrary(source: kernelSource, options: nil)
        let composite = try! device.makeComputePipelineState(function: kernelLib.makeFunction(name: "composite")!)

        struct Rect: Decodable { let x, y, w, h: Int32 }
        let rects = try! JSONDecoder().decode([Rect].self, from: Data(contentsOf: URL(fileURLWithPath: "\(here)/layout.json")))
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                                                     .textureStorageMode: MTLStorageMode.private.rawValue]
        let plate = try! loader.newTexture(URL: URL(fileURLWithPath: "\(here)/plate.png"), options: opts)
        let mask = try! loader.newTexture(URL: URL(fileURLWithPath: "\(here)/mask.png"), options: opts)
        let (W, H) = (plate.width, plate.height)
        let (cw, ch) = (Int(rects[0].w), Int(rects[0].h))

        func tex(_ f: MTLPixelFormat, _ w: Int, _ h: Int, _ u: MTLTextureUsage, shared: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
            d.usage = u
            d.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: d)!
        }
        let sdrTex = tex(.bgra8Unorm, cw, ch, [.renderTarget, .shaderRead])
        let edrSrc = tex(.rgba16Float, cw, ch, [.renderTarget, .shaderRead])
        let hdrTex = tex(.rgba16Float, cw, ch, [.renderTarget, .shaderRead])
        let outTex = tex(.rgba16Unorm, W, H, [.shaderWrite], shared: true)
        var bytes = [UInt8](repeating: 0, count: W * H * 8)
        var rectsBuf: (SIMD4<Int32>, SIMD4<Int32>, SIMD4<Float>) = (
            SIMD4(rects[0].x, rects[0].y, rects[0].w, rects[0].h),
            SIMD4(rects[1].x, rects[1].y, rects[1].w, rects[1].h), SIMD4(203, 0, 0, 0))

        let ffmpeg = Process()
        ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        ffmpeg.arguments = ["-y", "-loglevel", "error",
                            "-f", "rawvideo", "-pix_fmt", "rgba64le", "-s", "\(W)x\(H)", "-r", "\(fps)", "-i", "-",
                            "-vf", "scale=out_color_matrix=bt2020:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le",
                            "-c:v", "libx265", "-preset", "medium", "-crf", "16", "-tag:v", "hvc1",
                            "-x265-params", "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:range=limited:log-level=error",
                            "-color_primaries", "bt2020", "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-color_range", "tv",
                            "-movflags", "+faststart", outPath]
        let pipe = Pipe()
        ffmpeg.standardInput = pipe
        try! ffmpeg.run()

        for (index, look) in looks.enumerated() {
            guard let job = jobs.first(where: { $0.entry.key == look }) else { fail("no look \(look)") }
            let framesEach = cut(index + 1) - cut(index)
            let sdrPipe = try! library.pipeline(for: job.shader, pixelFormat: .bgra8Unorm)
            let edrPipe = try! library.pipeline(for: job.shader, pixelFormat: .rgba16Float)
            let data = try! library.dataProvider(for: job.shader)
            let params = job.shader.parameterValues(for: job.entry)
            let began = CFAbsoluteTimeGetCurrent()
            for k in 0..<framesEach {
                let u = LerpUniforms(resolution: SIMD2(Float(cw), Float(ch)), time: 6 + Float(k) / Float(fps), seed: 0.37)
                renderer.encodePass(target: sdrTex, pipeline: sdrPipe, uniforms: u, params: params, data: data)!.commit()
                let cb = renderer.encodePass(target: edrSrc, pipeline: edrPipe, uniforms: u, params: params, data: data)!
                LerpEDR.encodeExpand(into: cb, source: edrSrc, target: hdrTex, pipeline: post, params: LerpEDR.Params(headroom: peak))
                let enc = cb.makeComputeCommandEncoder()!
                enc.setComputePipelineState(composite)
                for (i, t) in [plate, mask, sdrTex, hdrTex, outTex].enumerated() { enc.setTexture(t, index: i) }
                enc.setBytes(&rectsBuf, length: MemoryLayout.size(ofValue: rectsBuf), index: 0)
                enc.dispatchThreads(MTLSize(width: W, height: H, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                bytes.withUnsafeMutableBytes {
                    outTex.getBytes($0.baseAddress!, bytesPerRow: W * 8, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
                }
                pipe.fileHandleForWriting.write(Data(bytes))
            }
            print(String(format: "OK  %@  %.1fs", look, CFAbsoluteTimeGetCurrent() - began))
        }
        try? pipe.fileHandleForWriting.close()
        ffmpeg.waitUntilExit()
        print("-> \(outPath)")
    }
}
