import AppKit
import Metal
import QuartzCore

/// Opt-in EDR (extended dynamic range) output.
///
/// Shaders still write `half4` in 0..1, display-referred, the way every look in
/// the library was authored (by eye, on a P3 panel, through an untagged
/// `bgra8Unorm` layer — which macOS shows in the display's native space). The
/// EDR path renders the shader unchanged into an `rgba16Float` texture, then a
/// tiny post pass decodes the sRGB transfer curve to linear and lifts only the
/// highlights into the headroom above 1.0, writing an `rgba16Float` drawable
/// tagged `extendedLinearDisplayP3`. Below the knee the result is the SDR
/// picture; above it is light an SDR layer cannot show.
///
/// Nothing in `LerpUniforms` or the prelude changes: headroom reaches the post
/// pass in its own buffer, so no shader has to know EDR exists.
public enum LerpEDR {

    /// The colourspace for the SDR layer. Display P3 rather than sRGB because
    /// the untagged layer this replaces was shown in the panel's native space,
    /// which on every Mac this was authored on is P3: tagging it sRGB would
    /// desaturate every look the user has tuned. Tagging it at all is what makes
    /// an external sRGB monitor colour-match instead of guessing.
    public static let sdrColorSpace = CGColorSpace(name: CGColorSpace.displayP3)
    /// Same primaries as the SDR tag, linear transfer, values above 1.0 allowed.
    public static let edrColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)

    public static let shaderPixelFormat: MTLPixelFormat = .rgba16Float

    /// Applies the layer state for one mode. Safe to call repeatedly.
    public static func configure(_ layer: CAMetalLayer, edr: Bool) {
        layer.wantsExtendedDynamicRangeContent = edr
        layer.pixelFormat = edr ? .rgba16Float : .bgra8Unorm
        layer.colorspace = edr ? edrColorSpace : sdrColorSpace
        // The EDR path draws the drawable from a post pass, which only needs it
        // as a render target, so framebufferOnly stays true either way.
        layer.framebufferOnly = true
    }

    /// The headroom the screen will give EDR content right now, as a multiple
    /// of SDR white. 1.0 means none: brightness at max, a non-HDR panel, or
    /// macOS has not ramped it up yet (it raises it once EDR content appears).
    public static func currentHeadroom(of screen: NSScreen?) -> Float {
        Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    /// The most headroom the panel can ever offer (16 on an XDR panel).
    public static func potentialHeadroom(of screen: NSScreen?) -> Float {
        Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    /// Highlights go to at most 4× SDR white unless a host says otherwise:
    /// enough to read as light rather than paint, short of the 16× an XDR
    /// panel offers, which is a lot to leave running in a dark room.
    public static let defaultPeak: Float = 4.0

    /// How often a view re-asks `blocker(on:)` while drawing.
    public static let recheckInterval: CFTimeInterval = 2.0

    /// Why EDR must not engage on `screen` right now, or nil if it may.
    ///
    /// The one predicate every EDR decision goes through, kept small so the
    /// frame-pacing work's power/thermal observation can fold into it:
    /// - a screen with no potential headroom gains nothing and pays the
    ///   16-bit bandwidth and the extra pass anyway;
    /// - on battery and in Low Power Mode the 8-bit path is the cheaper one,
    ///   and a screensaver that drains a laptop to show brighter highlights is
    ///   the wrong trade.
    public static func blocker(on screen: NSScreen?) -> String? {
        if potentialHeadroom(of: screen) <= 1.0 { return "screen has no EDR headroom" }
        // One reader of the power state per process: LerpPowerMonitor, which
        // also sets the frame-rate cap and logs every change.
        let power = LerpPowerMonitor.shared.state
        if power.lowPowerMode { return "Low Power Mode" }
        if power.onBattery { return "on battery" }
        return nil
    }

    /// Layout matches `EDRParams` in `postSource`.
    public struct Params {
        /// Peak the brightest highlight is lifted to, as a multiple of SDR white.
        public var headroom: Float
        /// Linear-light level (max channel) where the lift starts. 0.4 linear
        /// is about 0.66 encoded: midtones and shadows are untouched.
        public var knee: Float = 0.4
        /// 0 = identical to SDR, 1 = the full lift.
        public var strength: Float = 1.0
        public var pad: Float = 0

        public init(headroom: Float, knee: Float = 0.4, strength: Float = 1.0) {
            self.headroom = headroom
            self.knee = knee
            self.strength = strength
        }
    }

    static let postSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EDRParams { float headroom; float knee; float strength; float pad; };

    vertex float4 edrVertex(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        return float4(p[vid], 0.0, 1.0);
    }

    fragment half4 edrExpand(float4 pos [[position]],
                             texture2d<half, access::read> src [[texture(0)]],
                             constant EDRParams& p [[buffer(0)]]) {
        float3 e = clamp(float3(src.read(uint2(pos.xy)).rgb), 0.0, 1.0);
        // sRGB / Display P3 transfer curve -> linear light.
        float3 lin = select(pow((e + 0.055) / 1.055, 2.4), e / 12.92, e <= 0.04045);
        float peak = max(lin.r, max(lin.g, lin.b));
        // Gain rises from 1 at the knee to `headroom` at SDR white. It is
        // increasing in `peak`, so the curve is monotonic: no highlight can
        // overtake a brighter one. Hue is kept by scaling all three channels.
        float t = smoothstep(p.knee, 1.0, peak);
        float gain = 1.0 + (max(p.headroom, 1.0) - 1.0) * p.strength * t * t;
        return half4(half3(lin * gain), 1.0h);
    }
    """

    /// Compiled once per device by the host that turns EDR on.
    public static func makePostPipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: postSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Lerping/edr-expand"
        descriptor.vertexFunction = library.makeFunction(name: "edrVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "edrExpand")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Encodes the post pass from `source` (the shader's rgba16Float output)
    /// into `target` on an existing command buffer.
    public static func encodeExpand(into commandBuffer: MTLCommandBuffer,
                                    source: MTLTexture, target: MTLTexture,
                                    pipeline: MTLRenderPipelineState, params: Params) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        var p = params
        encoder.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
