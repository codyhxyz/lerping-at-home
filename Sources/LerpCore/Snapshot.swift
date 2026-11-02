import Foundation
import Metal
import CoreGraphics
import ImageIO

/// Offscreen still-frame rendering — used by `LerpPreview --snapshot` to verify
/// every shader compiles and produces a sane image, and to generate the
/// System Settings thumbnail.
public enum LerpSnapshot {

    public struct Result {
        public let shader: String
        public let url: URL?
        public let error: String?
        /// Mean luminance 0..1 — a cheap "did it render something" signal.
        /// For an HDR still, of the SDR-clamped picture, so the number means
        /// the same thing either way.
        public let meanLuminance: Double
        /// Brightest linear channel value in an HDR still (1.0 = SDR white);
        /// 1.0 for an SDR one.
        public var peak: Double = 1.0
    }

    /// The tag on every SDR still. Display P3 — the same space the live layer
    /// is tagged with (`LerpEDR.sdrColorSpace`) — so a gallery tile and the
    /// look it stands for are the same colours. These used to be tagged sRGB
    /// while the live view showed the same numbers in P3, which made every
    /// tile a little duller than the look it opened.
    public static let colorSpace = LerpEDR.sdrColorSpace!

    /// `hdrPeak` non-nil renders through the EDR path instead — the shader in
    /// rgba16Float, then `LerpEDR`'s highlight lift to at most `hdrPeak`× SDR
    /// white — and writes a float still tagged extended-linear Display P3. The
    /// container comes from `url`'s extension: `.exr` (OpenEXR, linear float),
    /// `.heic`/`.avif` (SDR base + ISO gain map on macOS 15+, plain SDR on 14),
    /// anything else a float PNG.
    public static func render(shader: LerpShader,
                              library: ShaderLibrary,
                              renderer: LerpRenderer,
                              width: Int, height: Int,
                              time: Float, seed: Float,
                              params: LerpParameterValues? = nil,
                              hdrPeak: Float? = nil,
                              to url: URL) -> Result {
        let format: MTLPixelFormat = hdrPeak == nil ? .bgra8Unorm : LerpEDR.shaderPixelFormat
        let pipeline: MTLRenderPipelineState
        let data: LerpDataProvider?
        do {
            pipeline = try library.pipeline(for: shader, pixelFormat: format)
            data = try library.dataProvider(for: shader)
        } catch {
            return Result(shader: shader.name, url: nil, error: String(describing: error), meanLuminance: 0)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = hdrPeak == nil ? [.renderTarget] : [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor),
              let commandBuffer = renderer.encodePass(
                target: texture,
                pipeline: pipeline,
                uniforms: LerpUniforms(resolution: SIMD2<Float>(Float(width), Float(height)),
                                      time: time, seed: seed),
                params: params ?? shader.defaultParameterValues(),
                data: data) else {
            return Result(shader: shader.name, url: nil, error: "failed to create texture/command buffer", meanLuminance: 0)
        }

        if let hdrPeak {
            return finishHDR(shader: shader, renderer: renderer, source: texture,
                             commandBuffer: commandBuffer, peak: hdrPeak, to: url)
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        var luminance = 0.0
        var index = 0
        let sampleStride = max(1, (width * height) / 10_000) * 4
        var samples = 0
        while index + 2 < bytes.count {
            // BGRA order
            luminance += (0.114 * Double(bytes[index]) + 0.587 * Double(bytes[index + 1]) + 0.299 * Double(bytes[index + 2])) / 255.0
            samples += 1
            index += sampleStride
        }
        let mean = samples > 0 ? luminance / Double(samples) : 0

        // A `.heic` URL is a gallery still (see `RotationThumbnails.fileExtension`)
        // and is written opaque: the screen never shows the frame's alpha, and an
        // alpha plane is a second HEVC image in the file. Anything else is PNG.
        let heic = url.pathExtension.lowercased() == "heic"
        let alpha: CGImageAlphaInfo = heic ? .noneSkipFirst : .premultipliedFirst
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            return Result(shader: shader.name, url: nil, error: "failed to make CGImage", meanLuminance: mean)
        }
        // HEIC first, PNG under the same name if the HEVC encoder will not
        // run (a host or sandbox without one): ImageIO reads by content, not by
        // extension, so the still still decodes and the gallery still fills.
        guard (heic && write(image, as: "public.heic", quality: heicQuality, to: url))
                || write(image, as: "public.png", quality: nil, to: url) else {
            return Result(shader: shader.name, url: nil, error: "failed to encode image", meanLuminance: mean)
        }
        return Result(shader: shader.name, url: url, error: nil, meanLuminance: mean)
    }

    /// The HDR half of `render`: the highlight lift into a second float
    /// texture, read back as half floats, and written as an extended-range still.
    private static func finishHDR(shader: LerpShader, renderer: LerpRenderer, source: MTLTexture,
                                  commandBuffer: MTLCommandBuffer, peak: Float,
                                  to url: URL) -> Result {
        let width = source.width, height = source.height
        func failure(_ message: String) -> Result {
            Result(shader: shader.name, url: nil, error: message, meanLuminance: 0)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let post: MTLRenderPipelineState
        do { post = try LerpEDR.makePostPipeline(device: renderer.device) } catch {
            return failure("EDR post pass failed to compile: \(error)")
        }
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else {
            return failure("failed to create HDR texture")
        }
        LerpEDR.encodeExpand(into: commandBuffer, source: source, target: target,
                             pipeline: post, params: LerpEDR.Params(headroom: max(1, peak)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let rowBytes = width * 8
        var halves = [Float16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            target.getBytes(buffer.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // Luminance of the SDR-clamped, re-encoded picture, so it lines up with
        // the SDR path's number; peak of the linear values, which is the point.
        var luminance = 0.0, samples = 0, brightest: Float = 0
        let sampleStride = max(1, (width * height) / 10_000) * 4
        func encode(_ linear: Float) -> Double {
            let c = Double(min(max(linear, 0), 1))
            return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        var index = 0
        while index + 2 < halves.count {
            let r = Float(halves[index]), g = Float(halves[index + 1]), b = Float(halves[index + 2])
            luminance += 0.299 * encode(r) + 0.587 * encode(g) + 0.114 * encode(b)
            brightest = max(brightest, r, g, b)
            samples += 1
            index += sampleStride
        }
        let mean = samples > 0 ? luminance / Double(samples) : 0

        let type: String
        switch url.pathExtension.lowercased() {
        case "exr": type = "com.ilm.openexr-image"
        case "heic": type = "public.heic"
        case "avif": type = "public.avif"
        default: type = "public.png"
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let space = LerpEDR.edrColorSpace,
              let provider = CGDataProvider(data: halves.withUnsafeBytes { Data($0) } as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes,
                                  space: space, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            return failure("failed to encode HDR still as \(type)")
        }
        var output = image
        var options: [CFString: Any] = [:]
        if #available(macOS 15.0, *), type == "public.heic" || type == "public.avif" {
            // An SDR base plus an ISO 21496-1 gain map: SDR viewers get the
            // SDR picture, HDR ones the lift. Measured on macOS 27: ImageIO
            // only derives the gain map from a PQ-tagged source — handed the
            // extended-linear image, or asked for ISOHDR instead, it silently
            // tone-maps to SDR (decoded peak 1.0 either way).
            if let pq = toPQ(image) {
                output = pq
                options[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            }
        }
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return failure("ImageIO could not write \(type) to \(url.path)")
        }
        var result = Result(shader: shader.name, url: url, error: nil, meanLuminance: mean)
        result.peak = Double(brightest)
        return result
    }

    /// `image` colour-converted (not reinterpreted) to Rec. 2100 PQ, half float.
    private static func toPQ(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                        | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// 1.0, not something lower, and measured rather than picked: over all 123
    /// gallery stills it is 69% of the PNG bytes with no channel off by more
    /// than 3/255. Every setting below 1.0 drops ImageIO's HEVC encoder into
    /// 4:2:0 chroma, which is fine for the soft looks and ruinous for the
    /// halftone ones — 17.5 dB PSNR at 0.6 *and* at 0.95, coloured dots
    /// smeared to mud. A tile that misrepresents its look is not a saving.
    static let heicQuality = 1.0

    private static func write(_ image: CGImage, as type: String, quality: Double?, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            return false
        }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, options)
        return CGImageDestinationFinalize(destination)
    }
}
