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

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            return Result(shader: shader.name, url: nil, error: "failed to encode PNG", meanLuminance: mean)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return Result(shader: shader.name, url: url, error: nil, meanLuminance: mean)
    }
}
