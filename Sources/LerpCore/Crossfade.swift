import Foundation
import Metal

/// Dissolving one look into the next instead of cutting to it.
///
/// For the length of a fade, and only then, `LerpMetalView` renders the
/// outgoing look into a scratch texture the size of the drawable, renders the
/// incoming look into the drawable exactly as it would any other frame, and
/// lays the scratch texture over it at falling opacity. Each look is encoded
/// with its own pipeline, parameters, data provider and `LerpUniforms`, so
/// both keep animating through the fade and the purity contract in
/// `DataProvider.swift` holds for each of them. Outside a fade nothing here
/// runs: no scratch texture exists and the frame is the single pass it always
/// was.
public enum LerpCrossfade {

    /// How long a fade lasts, in seconds of the view's shader clock — so a
    /// paused view holds its fade where it is and resumes it, the same way it
    /// holds the animation.
    public static let duration: CFTimeInterval = 1.5

    /// The incoming look's weight `progress` (0…1) of the way through a fade.
    /// Smoothstep, so neither end of the fade starts or stops with a jolt.
    public static func weight(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }

    /// The outgoing look's frame, ready to be laid over the incoming one.
    public struct Overlay {
        public let texture: MTLTexture
        public let pipeline: MTLRenderPipelineState
        /// 1 shows only the outgoing look, 0 only the incoming one.
        public let opacity: Float
    }

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        vertex float4 lerpFadeVertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            return float4(p * 2.0 - 1.0, 0.0, 1.0);
        }

        fragment half4 lerpFadeFragment(float4 pos [[position]],
                                        texture2d<half> outgoing [[texture(0)]],
                                        constant float& opacity [[buffer(0)]]) {
            return half4(outgoing.read(uint2(pos.xy)).rgb, half(opacity));
        }
        """

    private struct Key: Hashable {
        let device: UInt64
        let format: UInt
    }

    nonisolated(unsafe) private static var pipelines: [Key: MTLRenderPipelineState] = [:]
    private static let lock = NSLock()

    /// The composite pipeline for drawables of `pixelFormat`, if `prepare` has
    /// built it. Never compiles: this is asked mid-frame on the main thread,
    /// and a view that gets nil cuts instead of waiting.
    static func pipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = Key(device: device.registryID, format: pixelFormat.rawValue)
        return lock.withLock { pipelines[key] }
    }

    /// Builds the composite pipeline once per device and pixel format.
    /// Blocking — `LerpMetalView` calls it on its compile queue, beside the
    /// look it is about to fade to. The lock is not held across the compile,
    /// so two views racing here waste one tiny compile rather than stalling.
    static func prepare(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard pipeline(device: device, pixelFormat: pixelFormat) == nil,
              let library = try? device.makeLibrary(source: source, options: nil),
              let vertex = library.makeFunction(name: "lerpFadeVertex"),
              let fragment = library.makeFunction(name: "lerpFadeFragment")
        else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Lerping/crossfade"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = pixelFormat
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        // Leave the drawable's alpha alone: the layer is opaque.
        color.alphaBlendOperation = .add
        color.sourceAlphaBlendFactor = .zero
        color.destinationAlphaBlendFactor = .one
        guard let state = try? device.makeRenderPipelineState(descriptor: descriptor) else { return }
        let key = Key(device: device.registryID, format: pixelFormat.rawValue)
        lock.withLock { pipelines[key] = state }
    }

    /// A scratch target matching `target`, for the outgoing look's pass.
    /// Private storage: it is written and read by the GPU and never by us.
    static func makeScratch(device: MTLDevice, like target: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat,
                                                                  width: target.width,
                                                                  height: target.height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Lerping/crossfade.outgoing"
        return texture
    }

    /// Blends `overlay` onto whatever `target` already holds, as one more
    /// pass in `commandBuffer`.
    static func encode(_ overlay: Overlay, onto target: MTLTexture,
                       in commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Lerping/crossfade"
        encoder.setRenderPipelineState(overlay.pipeline)
        encoder.setFragmentTexture(overlay.texture, index: 0)
        var opacity = overlay.opacity
        encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
