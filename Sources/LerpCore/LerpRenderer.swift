import Foundation
import Metal
import QuartzCore

/// The fixed 16-byte head of `struct LerpUniforms` in LerpPrelude.source.
/// A shader's declared `// lerp-param:` values are appended straight after it
/// in the same fragment buffer 0 binding — see `LerpParamLayout`.
public struct LerpUniforms {
    public var resolution: SIMD2<Float>
    public var time: Float
    public var seed: Float

    public init(resolution: SIMD2<Float>, time: Float, seed: Float) {
        self.resolution = resolution
        self.time = time
        self.seed = seed
    }
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
    /// straight after the 16-byte uniform head. `data` is the optional
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
        if let tail = params?.packedTail, !tail.isEmpty {
            var block = [UInt8](repeating: 0, count: LerpParamLayout.headerSize + tail.count)
            withUnsafeBytes(of: uniforms) {
                block.replaceSubrange(0..<LerpParamLayout.headerSize, with: $0)
            }
            block.replaceSubrange(LerpParamLayout.headerSize..<block.count, with: tail)
            encoder.setFragmentBytes(block, length: block.count, index: 0)
        } else {
            var u = uniforms
            encoder.setFragmentBytes(&u, length: MemoryLayout<LerpUniforms>.stride, index: 0)
        }
        data?.bind(to: encoder, uniforms: uniforms)
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
