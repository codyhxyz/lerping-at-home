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
        public let meanLuminance: Double
    }

    public static func render(shader: LerpShader,
                              library: ShaderLibrary,
                              renderer: LerpRenderer,
                              width: Int, height: Int,
                              time: Float, seed: Float,
                              params: LerpParameterValues? = nil,
                              to url: URL) -> Result {
        let pipeline: MTLRenderPipelineState
        let data: LerpDataProvider?
        do {
            pipeline = try library.pipeline(for: shader)
            data = try library.dataProvider(for: shader)
        } catch {
            return Result(shader: shader.name, url: nil, error: String(describing: error), meanLuminance: 0)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
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
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
