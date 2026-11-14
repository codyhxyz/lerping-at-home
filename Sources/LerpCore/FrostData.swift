import Foundation
import Metal
import os

/// A deliberately simplified hex-lattice deposition toy, not a physical
/// snow-crystal solver. Inspired by the diffusion/attachment split in
/// Libbrecht, https://arxiv.org/abs/0807.2616; the attachment
/// threshold and replenishment here are artistic choices, not their model.
/// Epochs cap cold replay at 179 dispatches; camera never enters the state.
public final class FrostData: LerpDataProvider {
    private let simulation: LerpGPUSimulation?
    private let placeholder: MTLTexture?
    private var texture: MTLTexture?
    private var frame = Frame(ready: 0, fade: 1)
    private struct Frame { var ready: UInt32; var fade: Float }

    public init(device: MTLDevice) {
        do {
            simulation = try LerpGPUSimulation(device: device, label: "frost", source: Self.kernels,
                planes: [.init("ice-vapor", pixelFormat: .rg32Float)],
                seed: [.init("frostSeed")], step: [.init("frostStep")])
        } catch {
            Logger(subsystem: LerpDefaults.productionModule, category: "frost").error("compute: \(error.localizedDescription)")
            simulation = nil
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        placeholder = device.makeTexture(descriptor: d)
    }
    public var metalPrelude: String { "struct LerpFrostFrame { uint ready; float fade; };" }
    public func bind(to encoder: MTLRenderCommandEncoder, uniforms: LerpUniforms) {
        var f = frame
        encoder.setFragmentBytes(&f, length: MemoryLayout<Frame>.size, index: 1)
        encoder.setFragmentTexture(texture ?? placeholder, index: 1)
    }
    public func encodeCompute(into commandBuffer: MTLCommandBuffer, uniforms: LerpUniforms, params: LerpParameterValues?) {
        let speed = max(0, params?["speed"]?.scalarValue.map(Float.init) ?? 2)
        let clock = max(0, uniforms.time) * speed + 50
        let epoch = Int(floor(clock / 180))
        let step = Int(clock.truncatingRemainder(dividingBy: 180))
        let aspect = max(0.5, uniforms.resolution.x / max(1, uniforms.resolution.y))
        let key = LerpGPUSimulation.Key(seed: uniforms.seed, epoch: epoch,
                                        width: Int(ceil(160 * aspect)) + 80, height: 160)
        let phase = Float(step) / 180
        let fade = min(1, min(phase / 0.08, (1 - phase) / 0.08))
        if let result = simulation?.advance(commandBuffer, to: step, of: key) {
            texture = result[0]; frame = Frame(ready: 1, fade: fade)
        } else { texture = nil; frame = Frame(ready: 0, fade: 1) }
    }
    private static let kernels = """
    kernel void frostSeed(texture2d<float, access::write> out [[texture(1)]],
                          constant LerpSimFrame& f [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (any(p >= f.size)) return;
        float ice = 0.0;
        // Fixed seeded nuclei, separated on the lattice. Hash determines each
        // location; no atomics or cross-thread writes are needed.
        for (uint i = 0; i < 10; ++i) {
            uint salt = f.seed ^ (f.epoch * 0x9e3779b9u);
            float2 c = float2(lerpSimHash(i, 1, salt), lerpSimHash(i, 2, salt)) * float2(f.size);
            if (distance(float2(p), c) < 1.2) ice = 1.0;
        }
        out.write(float4(ice, 1.0 - ice, 0, 0), p);
    }
    kernel void frostStep(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          constant LerpSimFrame& f [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (any(p >= f.size)) return;
        float2 s = src.read(p).rg;
        constexpr int2 dirs[6] = { int2(1,0), int2(-1,0), int2(0,1), int2(0,-1), int2(1,-1), int2(-1,1) };
        float vap = 0.0, neighbors = 0.0;
        for (int i = 0; i < 6; ++i) {
            int2 q = clamp(int2(p) + dirs[i], int2(0), int2(f.size)-1);
            float2 n = src.read(uint2(q)).rg;
            vap += n.y; neighbors += n.x;
        }
        vap = mix(s.y, vap / 6.0, 0.7);
        vap += 0.008 * (1.0 - vap);
        // Exposed sites preferentially grow; crowded sites fill more slowly.
        float chance = neighbors > 0.5 ? 0.12 * vap / (1.0 + 0.35 * max(0.0, neighbors - 1.0)) : 0.0;
        float r = lerpSimHash(p.x, p.y, f.seed ^ f.epoch ^ (f.step * 0x85ebca6bu));
        float ice = max(s.x, r < chance ? 1.0 : 0.0);
        out.write(float4(ice, ice > 0.5 ? 0.0 : vap, 0, 0), p);
    }
    """
}
