import Foundation
import Metal
import QuartzCore

/// The fixed 32-byte head of `struct LerpUniforms` in LerpPrelude.source.
/// A shader's declared `// lerp-param:` values are appended straight after it
/// in the same fragment buffer 0 binding — see `LerpParamLayout`.
public struct LerpUniforms {
    public var resolution: SIMD2<Float>
    public var time: Float
    public var seed: Float
    /// Smoothed loudness of whatever the Mac is playing. Laid out flat as
    /// `audioLevel, audioBass, audioMid, audioTreble` straight after `seed`.
    /// Zero unless a host feeds it — see `LerpAudioLevels`.
    public var audio: LerpAudioLevels

    public init(resolution: SIMD2<Float>, time: Float, seed: Float,
                audio: LerpAudioLevels = .silent) {
        self.resolution = resolution
        self.time = time
        self.seed = seed
        self.audio = audio
    }
}

/// The four audio uniforms, each roughly 0…1. `.silent` is what every render
/// gets unless a host opts in: the saver, `--snapshot` and the gallery stills
/// never do, so they stay a pure function of (shader, time, seed, parameters).
/// Only the playground's live view, with its toggle on, ever sees non-zero
/// values — audio is live input, the one thing a frame may depend on that is
/// not in that tuple, and it is never recorded into anything that persists.
public struct LerpAudioLevels: Equatable, Sendable {
    public var level: Float
    public var bass: Float
    public var mid: Float
    public var treble: Float

    public init(level: Float = 0, bass: Float = 0, mid: Float = 0, treble: Float = 0) {
        self.level = level
        self.bass = bass
        self.mid = mid
        self.treble = treble
    }

    public static let silent = LerpAudioLevels()
}

/// Thin stateless encoder: draws one fullscreen-triangle pass of the given
/// pipeline into any texture or drawable. Shared by the live view and the
/// offscreen snapshot path.
public final class LerpRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    public init?(device: MTLDevice? = nil) {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    /// `params` carries the values for whatever the shader declared with
    /// `// lerp-param:`; they ride along in the same fragment buffer 0 binding,
    /// straight after the 32-byte uniform head. `data` is the optional
    /// `LerpDataProvider` the shader declared, binding fragment indices 1 and
    /// up. A shader with neither encodes byte-for-byte as it always did.
    @discardableResult
    public func encodePass(target: MTLTexture,
                           pipeline: MTLRenderPipelineState,
                           uniforms: LerpUniforms,
                           params: LerpParameterValues? = nil,
                           data: LerpDataProvider? = nil) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        let headerSize = LerpParamLayout.headerSize
        if let tail = params?.packedTail, !tail.isEmpty {
            var block = [UInt8](repeating: 0, count: headerSize + tail.count)
            withUnsafeBytes(of: uniforms) { header in
                precondition(header.count == headerSize,
                             "LerpUniforms value bytes must exactly fill its ABI header")
                block.replaceSubrange(0..<headerSize, with: header)
            }
            block.replaceSubrange(headerSize..<block.count, with: tail)
            encoder.setFragmentBytes(block, length: block.count, index: 0)
        } else {
            var u = uniforms
            encoder.setFragmentBytes(&u, length: headerSize, index: 0)
        }
        data?.bind(to: encoder, uniforms: uniforms, params: params)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commandBuffer
    }

    public func draw(drawable: CAMetalDrawable,
                     pipeline: MTLRenderPipelineState,
                     uniforms: LerpUniforms,
                     params: LerpParameterValues? = nil,
                     data: LerpDataProvider? = nil) {
        guard let commandBuffer = encodePass(target: drawable.texture,
                                             pipeline: pipeline,
                                             uniforms: uniforms,
                                             params: params,
                                             data: data) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
