import Foundation
import Metal
import QuartzCore

/// Must match `struct LerpUniforms` in LerpPrelude.source (16 bytes).
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

    @discardableResult
    public func encodePass(target: MTLTexture,
                           pipeline: MTLRenderPipelineState,
                           uniforms: LerpUniforms) -> MTLCommandBuffer? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<LerpUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commandBuffer
    }

    public func draw(drawable: CAMetalDrawable,
                     pipeline: MTLRenderPipelineState,
                     uniforms: LerpUniforms) {
        guard let commandBuffer = encodePass(target: drawable.texture,
                                             pipeline: pipeline,
                                             uniforms: uniforms) else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
